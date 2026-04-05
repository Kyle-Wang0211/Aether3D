// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// GaussianSplatViewController.swift
// Aether3D
//
// MTKView-based viewer for 3D Gaussian Splatting rendering.
// Renders via C++ SplatRenderEngine (cross-platform: iOS/Android/HarmonyOS).
//
// Architecture:
//   - Engine lifecycle: NativeSplatEngineBridge → C API → SplatRenderEngine (C++)
//   - Metal pipelines: created by C++ engine via GPUDevice abstraction
//   - Per-frame: beginFrame → updateCamera → encodeSort → encodeRenderNative → endFrame
//   - Camera: touch-first 3D navigation (rotate, pan, zoom, reset)
//   - Data normalization: bounding sphere → "invisible cube" (fills screen)

import Aether3DCore
import MetalKit
import simd
import UIKit

#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

/// View controller for rendering 3D Gaussian Splatting scenes.
final class GaussianSplatViewController: UIViewController, UIGestureRecognizerDelegate {

    private struct PackedSplatSample {
        let position: SIMD3<Float>
        let weight: Float
    }

    private struct SceneOrientationEstimate {
        let up: SIMD3<Float>
        let sampleCount: Int
        let verticalSpan: Float
        let horizontalSpan: Float
        let supportBias: Float
        let confidence: Float
    }

    private struct AxisSupportMetrics {
        let bias: Float
        let coverage: Float
    }

    private struct OITSplatCameraUniforms {
        var viewMatrix: simd_float4x4 = matrix_identity_float4x4
        var projMatrix: simd_float4x4 = matrix_identity_float4x4
        var viewProjMatrix: simd_float4x4 = matrix_identity_float4x4
        var fx: Float = 0
        var fy: Float = 0
        var cx: Float = 0
        var cy: Float = 0
        var vpWidth: UInt32 = 0
        var vpHeight: UInt32 = 0
        var splatCount: UInt32 = 0
        var pad: UInt32 = 0
    }

    // MARK: - Properties

    private var metalView: MTKView!
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!

    // C++ engine bridge (PLY loading + GPU rendering — cross-platform)
    private var splatBridge: NativeSplatEngineBridge?

    // Swift-side OIT/hybrid transparency viewer path.
    private var oitAccumPSO: MTLRenderPipelineState?
    private var oitCompositePSO: MTLRenderPipelineState?
    private var oitPackedBuffer: MTLBuffer?
    private var oitIndexBuffer: MTLBuffer?
    private var oitSHBuffer: MTLBuffer?
    private var oitRegionIDBuffer: MTLBuffer?
    private var oitRegionFadeBuffer: MTLBuffer?
    private var oitCameraBuffer: MTLBuffer?
    private var oitAccumTexture: MTLTexture?
    private var oitRevealTexture: MTLTexture?
    private var oitTextureSize = SIMD2<Int>(0, 0)
    private var oitSplatCount: Int = 0
    private var oitViewerReady = false
    private var isViewerActive = true
    private var viewerWarmupActive = false
    private var viewerWarmupUntil: TimeInterval = 0
    private var viewerWarmupLastDraw: TimeInterval = 0

    // Camera interaction state
    private var navigationState = GaussianSplatNavigationState()
    private var isPinching = false

    // Bounding sphere of loaded data
    private var sceneCenter = SIMD3<Float>(0, 0, 0)
    private var sceneRadius: Float = 1.0
    private var defaultCameraDistance: Float = 3.0
    private var defaultCameraTarget = SIMD3<Float>(0, 0, 0)
    private var defaultCameraAzimuth: Float = 0.0
    private var defaultCameraPitch: Float = 0.0
    private var defaultCameraOrientation = GaussianSplatViewController.legacyDefaultCameraOrientation()
    private var sceneUpAxis = SIMD3<Float>(0, 1, 0)
    private var sceneOrientationEstimate: SceneOrientationEstimate?
    private var initialPoseSource: String = "legacy_default"
    private var initialPoseCacheStatus: String = "miss"
    private var activeArtifactCacheKey: String?
    private var appliedUprightCorrectionToken: Int = 0

    private var activeNavigationMode: ViewerNavigationMode {
        .orbit
    }

    private var viewerPathLabel: String {
        oitViewerReady ? "mobileOIT" : "nativeLegacy"
    }

    /// URL of the file to load (.ply or .spz).
    var fileURL: URL?
    var viewerInitialPose: ViewerInitialPose?
    var preferredSceneUp: SIMD3<Float>?
    var preferredSceneUpSource: String?
    var preferredSceneUpConfidence: Float?
    var onModelLoaded: (() -> Void)?
    var onViewerInitialPoseResolved: ((ViewerInitialPose) -> Void)?
    var onNavigationModeResolved: ((ViewerNavigationMode) -> Void)?

    /// Tracks if data was loaded successfully.
    private var dataLoaded = false

    // Frame counter for periodic debug logging
    private var frameCount: UInt64 = 0
    private var observationWindowStart = ProcessInfo.processInfo.systemUptime
    private var observationWindowFrames: UInt64 = 0
    private var observationWindowSlowFrames: UInt64 = 0
    private var observationWindowMaxCPUFrameMs: Double = 0
    private var hasReportedModelLoaded = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = mtlDevice
        self.commandQueue = device.makeCommandQueue()
        view.backgroundColor = .black

        setupMetalView()
        setupGestures()
        setupSplatEngine()
        setupLifecycleObservers()
        loadFileIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateDrawableSizeForCurrentViewerMode()
    }

    // MARK: - Metal View Setup

    private func setupMetalView() {
        metalView = MTKView(frame: view.bounds, device: device)
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1.0)
        metalView.autoResizeDrawable = false
        metalView.delegate = self
        metalView.preferredFramesPerSecond = Self.defaultPreferredFramesPerSecond
        metalView.isPaused = false
        metalView.backgroundColor = .black

        view.addSubview(metalView)
    }

    // MARK: - Gestures

    private func setupGestures() {
        let orbitPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleOrbitPan(_:)))
        orbitPanGesture.maximumNumberOfTouches = 1
        orbitPanGesture.delegate = self
        metalView.addGestureRecognizer(orbitPanGesture)

        let translationPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleTranslationPan(_:)))
        translationPanGesture.minimumNumberOfTouches = 2
        translationPanGesture.maximumNumberOfTouches = 2
        translationPanGesture.delegate = self
        metalView.addGestureRecognizer(translationPanGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        metalView.addGestureRecognizer(pinchGesture)

        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotationGesture.delegate = self
        metalView.addGestureRecognizer(rotationGesture)

        let resetTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleResetTap(_:)))
        resetTapGesture.numberOfTapsRequired = 2
        metalView.addGestureRecognizer(resetTapGesture)
    }

    @objc private func handleOrbitPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.numberOfTouches <= 1 else {
            gesture.setTranslation(.zero, in: metalView)
            return
        }
        let translation = gesture.translation(in: metalView)
        navigationState.applySingleFingerDrag(
            screenTranslation: SIMD2<Float>(Float(translation.x), Float(translation.y))
        )
        gesture.setTranslation(.zero, in: metalView)
    }

    @objc private func handleTranslationPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.numberOfTouches >= 2 else {
            gesture.setTranslation(.zero, in: metalView)
            return
        }
        let translation = gesture.translation(in: metalView)
        navigationState.applyTwoFingerPan(
            screenTranslation: SIMD2<Float>(Float(translation.x), Float(translation.y)),
            viewportSize: SIMD2<Float>(Float(metalView.bounds.width), Float(metalView.bounds.height))
        )
        gesture.setTranslation(.zero, in: metalView)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            guard gesture.numberOfTouches >= 2 else {
                gesture.scale = 1.0
                return
            }
            isPinching = true
            navigationState.applyPinch(scale: Float(gesture.scale), velocity: Float(gesture.velocity))
            gesture.scale = 1.0
        case .ended, .cancelled, .failed:
            isPinching = false
            gesture.scale = 1.0
        default:
            break
        }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            guard gesture.numberOfTouches >= 2 else {
                gesture.rotation = 0.0
                return
            }
            navigationState.applyTwoFingerRotation(rotationRadians: Float(gesture.rotation))
            gesture.rotation = 0.0
        case .ended, .cancelled, .failed:
            gesture.rotation = 0.0
        default:
            break
        }
    }

    @objc private func handleResetTap(_ gesture: UITapGestureRecognizer) {
        resetCameraToDefault()
    }

    // MARK: - Splat Engine (C++ cross-platform rendering)

    private func setupSplatEngine() {
        #if canImport(CAetherNativeBridge)
        let mtlDevicePtr = Unmanaged.passUnretained(device).toOpaque()
        guard let gpuDevice = aether_gpu_device_create_metal(mtlDevicePtr) else {
            #if DEBUG
            print("[Aether3D][Viewer] ERROR: GPU device wrapper creation failed")
            #endif
            return
        }
        splatBridge = NativeSplatEngineBridge(
            gpuDevicePtr: UnsafeMutableRawPointer(gpuDevice)
        )
        setupOITViewer()
        #else
        #if DEBUG
        print("[Aether3D][Viewer] ERROR: CAetherNativeBridge not available")
        #endif
        #endif
    }

    private func setupOITViewer() {
        do {
            try buildOITPipelineStates()
            guard let cameraBuffer = device.makeBuffer(
                length: MemoryLayout<OITSplatCameraUniforms>.stride,
                options: .storageModeShared
            ),
            let regionFadeBuffer = device.makeBuffer(
                length: Self.oitRegionFadeCount * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ) else {
                oitViewerReady = false
            NSLog("%@", "[Aether3D][Viewer][MobileOIT] init_failed=buffer_allocation")
                return
            }

            oitCameraBuffer = cameraBuffer
            oitRegionFadeBuffer = regionFadeBuffer

            let fadeValues = [Float](repeating: 1.0, count: Self.oitRegionFadeCount)
            fadeValues.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                memcpy(regionFadeBuffer.contents(), base, bytes.count)
            }

            oitViewerReady = oitAccumPSO != nil && oitCompositePSO != nil
            NSLog("%@", "[Aether3D][Viewer][MobileOIT] pipeline=\(oitViewerReady ? "ready" : "fallback") cameraUniformStride=\(MemoryLayout<OITSplatCameraUniforms>.stride)")
        } catch {
            oitViewerReady = false
            NSLog("%@", "[Aether3D][Viewer][MobileOIT] init_failed=\(error.localizedDescription)")
        }
    }

    private func buildOITPipelineStates() throws {
        guard let library = device.makeDefaultLibrary() else {
            throw NSError(
                domain: "GaussianSplatViewController",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Metal library for OIT viewer"]
            )
        }

        if let vertexFn = library.makeFunction(name: "splatVertex"),
           let fragmentFn = library.makeFunction(name: "splatAccumFragmentOIT") {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Viewer OIT Accumulation"
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .one
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .one

            desc.colorAttachments[1].pixelFormat = .r16Float
            desc.colorAttachments[1].isBlendingEnabled = true
            desc.colorAttachments[1].sourceRGBBlendFactor = .zero
            desc.colorAttachments[1].destinationRGBBlendFactor = .oneMinusSourceColor
            desc.colorAttachments[1].sourceAlphaBlendFactor = .zero
            desc.colorAttachments[1].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            desc.depthAttachmentPixelFormat = .invalid
            oitAccumPSO = try device.makeRenderPipelineState(descriptor: desc)
        }

        if let vertexFn = library.makeFunction(name: "splatCompositeVertex"),
           let fragmentFn = library.makeFunction(name: "splatCompositeFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Viewer OIT Composite"
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = false
            desc.depthAttachmentPixelFormat = .invalid
            oitCompositePSO = try device.makeRenderPipelineState(descriptor: desc)
        }
    }

    private func rebuildOITResources(from bridge: NativeSplatEngineBridge) {
        guard oitAccumPSO != nil, oitCompositePSO != nil else {
            oitViewerReady = false
            return
        }

        let packedCount = bridge.getPackedCount()
        guard packedCount > 0, let packedBase = bridge.getPackedData() else {
            oitPackedBuffer = nil
            oitIndexBuffer = nil
            oitSHBuffer = nil
            oitRegionIDBuffer = nil
            oitSplatCount = 0
            oitViewerReady = false
            NSLog("%@", "[Aether3D][Viewer][MobileOIT] scene_ready=no reason=no_packed_data")
            return
        }

        let actualSHFloatCount = bridge.getSHFloatCount()
        let shFloatCount = max(actualSHFloatCount, packedCount * Self.shFloatCountPerSplat)
        let packedByteCount = packedCount * Self.packedSplatStride
        let shByteCount = shFloatCount * MemoryLayout<Float>.stride
        let packedRaw = UnsafeRawBufferPointer(start: packedBase, count: packedByteCount)
        let selectedIndices = Self.selectMobileOITIndices(
            from: packedRaw,
            totalCount: packedCount,
            keepMass: Self.mobileContributionKeepMass
        )
        let renderIndices = selectedIndices.isEmpty
            ? (0..<packedCount).map { UInt32($0) }
            : selectedIndices
        let renderCount = renderIndices.count

        guard let packedBuffer = device.makeBuffer(length: packedByteCount, options: .storageModeShared),
              let indexBuffer = device.makeBuffer(length: renderCount * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let shBuffer = device.makeBuffer(length: shByteCount, options: .storageModeShared),
              let regionIDBuffer = device.makeBuffer(length: renderCount, options: .storageModeShared)
        else {
            oitViewerReady = false
            NSLog("%@", "[Aether3D][Viewer][MobileOIT] scene_ready=no reason=buffer_alloc")
            return
        }

        memcpy(packedBuffer.contents(), packedBase, packedByteCount)

        renderIndices.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            memcpy(indexBuffer.contents(), base, bytes.count)
        }

        let shPtr = bridge.getSHData()
        let shRaw = shBuffer.contents().assumingMemoryBound(to: UInt8.self)
        shRaw.initialize(repeating: 0, count: shByteCount)
        if let shBase = shPtr {
            let copiedSHBytes = min(actualSHFloatCount, shFloatCount) * MemoryLayout<Float>.stride
            memcpy(shBuffer.contents(), shBase, copiedSHBytes)
        }

        let ridRaw = regionIDBuffer.contents().assumingMemoryBound(to: UInt8.self)
        ridRaw.initialize(repeating: 0, count: renderCount)

        oitPackedBuffer = packedBuffer
        oitIndexBuffer = indexBuffer
        oitSHBuffer = shBuffer
        oitRegionIDBuffer = regionIDBuffer
        oitSplatCount = renderCount
        oitViewerReady = true

        NSLog(
            "%@",
            "[Aether3D][Viewer][MobileOIT] scene_ready=yes splats=\(renderCount)/\(packedCount) keepMass=\(Self.format(Self.mobileContributionKeepMass, digits: 2)) shFloats=\(shFloatCount)"
        )
    }

    private func setupLifecycleObservers() {
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(handleAppDidBecomeActive),
                           name: UIApplication.didBecomeActiveNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(handleAppDidBecomeActive),
                           name: UIApplication.willEnterForegroundNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(handleAppDidResignActive),
                           name: UIApplication.willResignActiveNotification,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(handleAppDidResignActive),
                           name: UIApplication.didEnterBackgroundNotification,
                           object: nil)
    }

    private func setViewerActive(_ active: Bool) {
        guard isViewerActive != active else { return }
        isViewerActive = active
        metalView?.isPaused = !active
        if active {
            refreshViewerWarmupIfNeeded(now: ProcessInfo.processInfo.systemUptime)
            metalView?.draw()
        }
        NSLog("%@", "[Aether3D][Viewer] active=\(active ? "yes" : "no")")
    }

    private func beginViewerWarmup() {
        viewerWarmupActive = true
        viewerWarmupUntil = ProcessInfo.processInfo.systemUptime + Self.viewerWarmupDuration
        viewerWarmupLastDraw = 0
        metalView?.preferredFramesPerSecond = Self.viewerWarmupPreferredFramesPerSecond
        updateDrawableSizeForCurrentViewerMode()
        let warmupCap = min(splatBridge?.splatCount ?? 0, Self.viewerWarmupSplatCap)
        NSLog(
            "%@",
            "[Aether3D][ViewerWarmup] active=yes fps=\(Self.viewerWarmupPreferredFramesPerSecond) scale=\(Self.format(Double(Self.viewerWarmupRenderScale), digits: 2)) cap=\(warmupCap) duration=\(Self.format(Self.viewerWarmupDuration, digits: 1))s splats=\(splatBridge?.splatCount ?? 0) radius=\(Self.format(sceneRadius)) distance=\(Self.format(defaultCameraDistance))"
        )
    }

    private func refreshViewerWarmupIfNeeded(now: TimeInterval) {
        guard viewerWarmupActive else { return }
        guard now >= viewerWarmupUntil else { return }
        viewerWarmupActive = false
        viewerWarmupLastDraw = 0
        metalView?.preferredFramesPerSecond = Self.defaultPreferredFramesPerSecond
        updateDrawableSizeForCurrentViewerMode()
        NSLog(
            "%@",
            "[Aether3D][ViewerWarmup] active=no fps=\(Self.defaultPreferredFramesPerSecond)"
        )
    }

    private func updateDrawableSizeForCurrentViewerMode() {
        guard let metalView else { return }
        let bounds = metalView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }

        let screenScale = view.window?.screen.nativeScale ?? UIScreen.main.nativeScale
        let renderScale = viewerWarmupActive ? Self.viewerWarmupRenderScale : 1.0
        let targetWidth = max(1.0, floor(bounds.width * screenScale * renderScale))
        let targetHeight = max(1.0, floor(bounds.height * screenScale * renderScale))
        metalView.drawableSize = CGSize(width: targetWidth, height: targetHeight)
    }

    @objc private func handleAppDidBecomeActive() {
        setViewerActive(true)
    }

    @objc private func handleAppDidResignActive() {
        setViewerActive(false)
    }

    private func ensureOITTextures(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if oitTextureSize.x == width, oitTextureSize.y == height,
           oitAccumTexture != nil, oitRevealTexture != nil {
            return
        }

        let accumDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        accumDesc.usage = [.renderTarget, .shaderRead]
        accumDesc.storageMode = .private
        oitAccumTexture = device.makeTexture(descriptor: accumDesc)
        oitAccumTexture?.label = "Viewer OIT Accum"

        let revealDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        revealDesc.usage = [.renderTarget, .shaderRead]
        revealDesc.storageMode = .private
        oitRevealTexture = device.makeTexture(descriptor: revealDesc)
        oitRevealTexture?.label = "Viewer OIT Reveal"

        oitTextureSize = SIMD2<Int>(width, height)
    }

    private func encodeOITFrame(
        commandBuffer: MTLCommandBuffer,
        drawable: CAMetalDrawable,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        fx: Float,
        fy: Float,
        vpWidth: UInt32,
        vpHeight: UInt32
    ) -> Bool {
        guard oitViewerReady,
              let accumPSO = oitAccumPSO,
              let compositePSO = oitCompositePSO,
              let packedBuffer = oitPackedBuffer,
              let indexBuffer = oitIndexBuffer,
              let shBuffer = oitSHBuffer,
              let regionIDBuffer = oitRegionIDBuffer,
              let regionFadeBuffer = oitRegionFadeBuffer,
              let cameraBuffer = oitCameraBuffer,
              oitSplatCount > 0 else {
            return false
        }

        ensureOITTextures(width: Int(vpWidth), height: Int(vpHeight))
        guard let accumTexture = oitAccumTexture,
              let revealTexture = oitRevealTexture else {
            return false
        }

        let renderSplatCount = viewerWarmupActive
            ? min(oitSplatCount, Self.viewerWarmupSplatCap)
            : oitSplatCount
        guard renderSplatCount > 0 else { return false }

        var cameraUniforms = OITSplatCameraUniforms()
        cameraUniforms.viewMatrix = viewMatrix
        cameraUniforms.projMatrix = projectionMatrix
        cameraUniforms.viewProjMatrix = projectionMatrix * viewMatrix
        cameraUniforms.fx = fx
        cameraUniforms.fy = fy
        cameraUniforms.cx = Float(vpWidth) * 0.5
        cameraUniforms.cy = Float(vpHeight) * 0.5
        cameraUniforms.vpWidth = vpWidth
        cameraUniforms.vpHeight = vpHeight
        cameraUniforms.splatCount = UInt32(renderSplatCount)
        memcpy(cameraBuffer.contents(), &cameraUniforms, MemoryLayout<OITSplatCameraUniforms>.stride)

        let accumRPD = MTLRenderPassDescriptor()
        accumRPD.colorAttachments[0].texture = accumTexture
        accumRPD.colorAttachments[0].loadAction = .clear
        accumRPD.colorAttachments[0].storeAction = .store
        accumRPD.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        accumRPD.colorAttachments[1].texture = revealTexture
        accumRPD.colorAttachments[1].loadAction = .clear
        accumRPD.colorAttachments[1].storeAction = .store
        accumRPD.colorAttachments[1].clearColor = MTLClearColorMake(1, 0, 0, 0)

        guard let accumEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: accumRPD) else {
            return false
        }
        accumEncoder.label = "Viewer OIT Accumulation"
        accumEncoder.setRenderPipelineState(accumPSO)
        accumEncoder.setVertexBuffer(packedBuffer, offset: 0, index: 0)
        accumEncoder.setVertexBuffer(indexBuffer, offset: 0, index: 1)
        accumEncoder.setVertexBuffer(cameraBuffer, offset: 0, index: 2)
        accumEncoder.setVertexBuffer(shBuffer, offset: 0, index: 3)
        accumEncoder.setVertexBuffer(regionIDBuffer, offset: 0, index: 4)
        accumEncoder.setVertexBuffer(regionFadeBuffer, offset: 0, index: 5)
        accumEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: renderSplatCount)
        accumEncoder.endEncoding()

        let compositeRPD = MTLRenderPassDescriptor()
        compositeRPD.colorAttachments[0].texture = drawable.texture
        compositeRPD.colorAttachments[0].loadAction = .clear
        compositeRPD.colorAttachments[0].storeAction = .store
        compositeRPD.colorAttachments[0].clearColor = metalView.clearColor

        guard let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositeRPD) else {
            return false
        }
        compositeEncoder.label = "Viewer OIT Composite"
        compositeEncoder.setRenderPipelineState(compositePSO)
        compositeEncoder.setFragmentTexture(accumTexture, index: 0)
        compositeEncoder.setFragmentTexture(revealTexture, index: 1)
        compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        compositeEncoder.endEncoding()

        return true
    }

    // MARK: - Data Loading

    private func loadFileIfNeeded() {
        guard let url = fileURL, let bridge = splatBridge else { return }

        var loaded = false
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "ply":
            loaded = bridge.loadPLY(path: url.path)
        case "spz":
            if let data = try? Data(contentsOf: url) {
                loaded = bridge.loadSPZ(data: data)
            }
        default:
            break
        }

        guard loaded else {
            #if DEBUG
            print("[Aether3D][Viewer] LOAD FAILED: \(url.lastPathComponent)")
            #endif
            return
        }

        dataLoaded = true
        hasReportedModelLoaded = false
        rebuildOITResources(from: bridge)

        // Auto-center camera on bounding sphere
        if let bounds = bridge.getBounds() {
            sceneCenter = bounds.center
            sceneRadius = max(bounds.radius, 0.001)
            activeArtifactCacheKey = Self.artifactCacheKey(for: url)
            initialPoseCacheStatus = "miss"
            initialPoseSource = "legacy_default"
            sceneOrientationEstimate = nil
            sceneUpAxis = Self.canonicalWorldUp
            if let artifactCacheKey = activeArtifactCacheKey,
               let cachedPose = cachedViewerInitialPose(for: artifactCacheKey) {
                initialPoseCacheStatus = "hit"
                initialPoseSource = cachedPose.source
                resetCameraToDefault(cachedPose: cachedPose)
            } else {
                resetCameraToDefault()
            }
            logLoadObservation(fileURL: url, bridge: bridge)
            reportModelLoadedIfNeeded()
            beginViewerWarmup()
        }

        #if DEBUG
        if !bridge.isInitialized {
            print("[Aether3D][Viewer] SHADER LOAD FAILED | splats=\(bridge.splatCount)")
        }
        #endif
    }

    // MARK: - Camera Math

    private func viewMatrix() -> simd_float4x4 {
        let pose = navigationState.cameraPose
        return lookAt(eye: pose.eye, center: pose.center, up: pose.up)
    }

    private func cameraForwardVector() -> SIMD3<Float> {
        navigationState.cameraPose.forward
    }

    private func cameraRightVector() -> SIMD3<Float> {
        navigationState.cameraPose.right
    }

    private func cameraUpVector() -> SIMD3<Float> {
        navigationState.cameraPose.up
    }

    private func cameraEyePosition() -> SIMD3<Float> {
        navigationState.cameraPose.eye
    }

    private func projectionMatrix() -> simd_float4x4 {
        let aspect = Float(metalView.drawableSize.width / metalView.drawableSize.height)
        let nearPlane = navigationState.currentNearPlaneDistance
        return perspectiveProjection(fovY: Self.defaultFovY,
                                     aspect: aspect,
                                     near: nearPlane,
                                     far: 200.0)
    }

    private func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>,
                        up: SIMD3<Float>) -> simd_float4x4 {
        let f = normalize(center - eye)
        var stableUp = Self.normalizedOrFallback(up, fallback: SIMD3<Float>(0, 1, 0))
        var side = simd_cross(f, stableUp)
        if simd_length_squared(side) < 1e-6 {
            stableUp = Self.orthogonalUnitVector(to: f)
            side = simd_cross(f, stableUp)
        }
        let s = normalize(side)
        let u = simd.cross(s, f)

        var result = matrix_identity_float4x4
        result[0][0] = s.x; result[1][0] = s.y; result[2][0] = s.z
        result[0][1] = u.x; result[1][1] = u.y; result[2][1] = u.z
        result[0][2] = -f.x; result[1][2] = -f.y; result[2][2] = -f.z
        result[3][0] = -simd.dot(s, eye)
        result[3][1] = -simd.dot(u, eye)
        result[3][2] = simd.dot(f, eye)
        return result
    }

    private func currentNearPlaneDistance() -> Float {
        navigationState.currentNearPlaneDistance
    }

    private func resetCameraToDefault(cachedPose: ViewerInitialPose? = nil) {
        let splatCount = splatBridge?.splatCount ?? 0
        let fitMultiplier: Float = splatCount >= Self.heavySceneSplatThreshold
            ? Self.heavySceneFitDistanceMultiplier
            : Self.defaultSceneFitDistanceMultiplier
        let fitDistance = max(sceneRadius * fitMultiplier, Self.minimumStartupFitDistance)
        defaultCameraDistance = fitDistance
        defaultCameraTarget = sceneCenter
        if let cachedPose {
            sceneUpAxis = Self.leveledVerticalAxis(matching: Self.sceneUpVector(from: cachedPose))
            defaultCameraOrientation = Self.orientationQuaternion(from: cachedPose)
        } else if let preferredSceneUp {
            sceneUpAxis = Self.leveledVerticalAxis(matching: preferredSceneUp)
            defaultCameraOrientation = sceneAwareDefaultCameraOrientation()
            initialPoseSource = preferredSceneUpSource ?? "capture_gravity_metadata"
            if let confidence = preferredSceneUpConfidence {
                sceneOrientationEstimate = SceneOrientationEstimate(
                    up: sceneUpAxis,
                    sampleCount: 0,
                    verticalSpan: 0,
                    horizontalSpan: 0,
                    supportBias: 0,
                    confidence: confidence
                )
            }
        } else {
            sceneUpAxis = Self.canonicalWorldUp
            defaultCameraOrientation = Self.legacyDefaultCameraOrientation()
        }
        syncDefaultOrbitStateFromDefaultOrientation()
        navigationState.configureScene(center: sceneCenter, radius: sceneRadius, up: sceneUpAxis)
        navigationState.configureDefaults(
            target: defaultCameraTarget,
            distance: defaultCameraDistance,
            azimuth: defaultCameraAzimuth,
            pitch: defaultCameraPitch,
            suggestedMode: .orbit
        )
        navigationState.setRequestedNavigationMode(.orbit)
    }

    private static let defaultFovY: Float = .pi / 3.0
    private static let defaultPitchDownRadians: Float = 0.25
    private static let defaultPreferredFramesPerSecond = 60
    private static let viewerWarmupPreferredFramesPerSecond = 18
    private static let viewerWarmupDuration: TimeInterval = 2.5
    private static let viewerWarmupRenderScale: CGFloat = 0.6
    private static let viewerWarmupSplatCap = 12_000
    private static let defaultSceneFitDistanceMultiplier: Float = 5.0
    private static let heavySceneFitDistanceMultiplier: Float = 6.5
    private static let minimumStartupFitDistance: Float = 2.5
    private static let heavySceneSplatThreshold = 25_000
    private static let maxOrientationSamples = 4096
    private static let packedSplatStride = 16
    private static let shFloatCountPerSplat = 12
    private static let mobileContributionKeepMass: Float = 0.96
    private static let oitRegionFadeCount = 32
    private static let observationLogInterval: TimeInterval = 2.0
    private static let slowFrameThresholdMs: Double = 20.0
    private static let viewerInitialPoseCacheVersion = 7
    private static let canonicalWorldUp = SIMD3<Float>(0, 1, 0)
    private static let gravityAlignmentBiasThreshold: Float = 0.55
    private static let defaultInitialUpSign: Float = -1.0

    private static func leveledVerticalAxis(matching vector: SIMD3<Float>) -> SIMD3<Float> {
        GaussianSplatNavigationState.leveledVerticalAxis(matching: vector)
    }

    private func resolveInitialSceneOrientation(
        from estimated: SceneOrientationEstimate?
    ) -> (estimate: SceneOrientationEstimate?, up: SIMD3<Float>, source: String) {
        guard let estimated else {
            let defaultUp = Self.canonicalWorldUp * Self.defaultInitialUpSign
            return (nil, defaultUp, "global_default_inverted")
        }

        let estimatedUp = Self.normalizedOrFallback(estimated.up, fallback: Self.canonicalWorldUp)
        let correctedEstimatedUp = Self.leveledVerticalAxis(matching: estimatedUp * Self.defaultInitialUpSign)
        let gravityAlignment = abs(simd_dot(estimatedUp, Self.canonicalWorldUp))
        guard gravityAlignment >= Self.gravityAlignmentBiasThreshold else {
            let correctedEstimate = SceneOrientationEstimate(
                up: correctedEstimatedUp,
                sampleCount: estimated.sampleCount,
                verticalSpan: estimated.verticalSpan,
                horizontalSpan: estimated.horizontalSpan,
                supportBias: estimated.supportBias,
                confidence: estimated.confidence
            )
            return (correctedEstimate, correctedEstimatedUp, "estimated_default_inverted")
        }

        let defaultUp = Self.canonicalWorldUp * Self.defaultInitialUpSign
        let gravityEstimate = SceneOrientationEstimate(
            up: defaultUp,
            sampleCount: estimated.sampleCount,
            verticalSpan: estimated.verticalSpan,
            horizontalSpan: estimated.horizontalSpan,
            supportBias: estimated.supportBias,
            confidence: max(estimated.confidence, gravityAlignment)
        )
        return (gravityEstimate, defaultUp, "gravity_aligned_default_inverted")
    }

    private func sceneAwareDefaultCameraOrientation() -> simd_quatf {
        let sceneUp = Self.normalizedOrFallback(sceneUpAxis, fallback: SIMD3<Float>(0, 1, 0))
        let horizontalForward = fallbackHorizontalForward(for: sceneUp)
        let forward = simd_normalize(
            horizontalForward * cos(Self.defaultPitchDownRadians) -
            sceneUp * sin(Self.defaultPitchDownRadians)
        )
        return Self.orientation(forward: forward, up: sceneUp)
    }

    private static func legacyDefaultCameraOrientation() -> simd_quatf {
        simd_normalize(simd_quatf(angle: -Self.defaultPitchDownRadians, axis: SIMD3<Float>(1, 0, 0)))
    }

    private static func legacyDefaultForwardDirection() -> SIMD3<Float> {
        legacyDefaultCameraOrientation().act(SIMD3<Float>(0, 0, -1))
    }

    private func syncDefaultOrbitStateFromDefaultOrientation() {
        let sceneUp = Self.leveledVerticalAxis(matching: sceneUpAxis)
        let referenceForward = fallbackHorizontalForward(for: sceneUp)
        let forward = Self.normalizedOrFallback(
            defaultCameraOrientation.act(SIMD3<Float>(0, 0, -1)),
            fallback: referenceForward
        )
        defaultCameraPitch = GaussianSplatNavigationState.softClampedPitchRadians(
            Self.pitchRadians(forward: forward, sceneUp: sceneUp)
        )
        let horizontalForward = Self.horizontalForwardComponent(from: forward, sceneUp: sceneUp)
        let sinAzimuth = simd_dot(simd_cross(referenceForward, horizontalForward), sceneUp)
        let cosAzimuth = simd_dot(referenceForward, horizontalForward)
        defaultCameraAzimuth = atan2(sinAzimuth, cosAzimuth)
    }

    func setNavigationMode(_ mode: ViewerNavigationMode) {
        _ = mode
        navigationState.setRequestedNavigationMode(.orbit)
    }

    private func suggestedNavigationMode() -> ViewerNavigationMode {
        return .orbit
    }

    private func reportModelLoadedIfNeeded() {
        guard dataLoaded, !hasReportedModelLoaded else { return }
        hasReportedModelLoaded = true
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.onModelLoaded?()
        }
    }

    private func fallbackHorizontalForward(for up: SIMD3<Float>) -> SIMD3<Float> {
        var candidate = Self.legacyDefaultForwardDirection() - simd_dot(Self.legacyDefaultForwardDirection(), up) * up
        if simd_length_squared(candidate) < 1e-6 {
            candidate = SIMD3<Float>(0, 0, -1) - simd_dot(SIMD3<Float>(0, 0, -1), up) * up
        }
        if simd_length_squared(candidate) < 1e-6 {
            candidate = SIMD3<Float>(1, 0, 0) - simd_dot(SIMD3<Float>(1, 0, 0), up) * up
        }
        return Self.normalizedOrFallback(candidate, fallback: SIMD3<Float>(0, 0, -1))
    }

    private func estimateSceneOrientation(using bridge: NativeSplatEngineBridge) -> SceneOrientationEstimate? {
        let samples = samplePackedSplats(from: bridge)
        guard samples.count >= 64 else { return nil }

        let sampleCount = Float(samples.count)
        var centroid = SIMD3<Float>(repeating: 0)
        for sample in samples {
            centroid += sample.position
        }
        centroid /= sampleCount

        var covariance = simd_float3x3(columns: (
            SIMD3<Float>(repeating: 0),
            SIMD3<Float>(repeating: 0),
            SIMD3<Float>(repeating: 0)
        ))
        for sample in samples {
            let delta = sample.position - centroid
            covariance += Self.outerProduct(delta, delta)
        }
        covariance *= (1.0 / sampleCount)

        let principalAxes = Self.principalAxes(of: covariance)
        let spans = principalAxes.map { axis in
            projectedSpan(on: axis, samples: samples, center: centroid)
        }

        let candidateMetrics = principalAxes.enumerated().map { index, axis -> (index: Int, span: Float, horizontalSpan: Float, support: AxisSupportMetrics, gravityAlignment: Float, score: Float) in
            let span = spans[index]
            let horizontalSpan = spans.enumerated()
                .filter { $0.offset != index }
                .map(\.element)
                .max() ?? span
            let support = supportMetrics(on: axis, samples: samples, center: centroid, span: span)
            let compactness = max(0, 1.0 - (span / max(horizontalSpan, 1e-4)))
            let gravityAlignment = abs(simd_dot(Self.normalizedOrFallback(axis, fallback: Self.canonicalWorldUp), Self.canonicalWorldUp))
            let supportConfidence = min(abs(support.bias) / 0.18, 1.0)
            let score = compactness * 0.42 + support.coverage * 0.24 + supportConfidence * 0.14 + gravityAlignment * 0.20
            return (index: index,
                    span: span,
                    horizontalSpan: horizontalSpan,
                    support: support,
                    gravityAlignment: gravityAlignment,
                    score: score)
        }

        guard let bestCandidate = candidateMetrics.max(by: { $0.score < $1.score }) else {
            return nil
        }

        let verticalSpan = bestCandidate.span
        let horizontalSpan = bestCandidate.horizontalSpan
        var sceneUp = Self.normalizedOrFallback(principalAxes[bestCandidate.index], fallback: Self.canonicalWorldUp)
        let rawSupportBias = bestCandidate.support.bias
        if bestCandidate.gravityAlignment >= Self.gravityAlignmentBiasThreshold {
            if simd_dot(sceneUp, Self.canonicalWorldUp) < 0 {
                sceneUp = -sceneUp
            }
        } else if rawSupportBias < 0 {
            sceneUp = -sceneUp
        }

        let spanSeparation = max(0, 1.0 - (verticalSpan / max(horizontalSpan, 1e-4)))
        let supportConfidence = min(abs(rawSupportBias) / 0.18, 1.0)
        let confidence = min(1.0, spanSeparation * 0.35 + bestCandidate.support.coverage * 0.25 + supportConfidence * 0.15 + bestCandidate.gravityAlignment * 0.25)
        guard confidence >= 0.08 else { return nil }

        return SceneOrientationEstimate(
            up: Self.normalizedOrFallback(sceneUp, fallback: Self.canonicalWorldUp),
            sampleCount: samples.count,
            verticalSpan: verticalSpan,
            horizontalSpan: horizontalSpan,
            supportBias: abs(rawSupportBias),
            confidence: confidence
        )
    }

    private func samplePackedSplats(from bridge: NativeSplatEngineBridge) -> [PackedSplatSample] {
        let totalCount = bridge.getPackedCount()
        guard totalCount > 0, let baseAddress = bridge.getPackedData() else { return [] }

        let step = max(totalCount / Self.maxOrientationSamples, 1)
        let raw = UnsafeRawBufferPointer(
            start: baseAddress,
            count: totalCount * Self.packedSplatStride
        )
        var samples: [PackedSplatSample] = []
        samples.reserveCapacity(min(totalCount, Self.maxOrientationSamples))

        for index in stride(from: 0, to: totalCount, by: step) {
            let base = index * Self.packedSplatStride
            guard base + (Self.packedSplatStride - 1) < raw.count else { break }

            let xBits = Self.readUInt16LE(raw, at: base + 4)
            let yBits = Self.readUInt16LE(raw, at: base + 6)
            let zBits = Self.readUInt16LE(raw, at: base + 8)
            let opacityByte = raw[base + 3]

            let position = SIMD3<Float>(
                Self.decodeFloat16(bitPattern: xBits),
                Self.decodeFloat16(bitPattern: yBits),
                Self.decodeFloat16(bitPattern: zBits)
            )
            let weight = max(Float(opacityByte) / 255.0, 0.05)
            samples.append(PackedSplatSample(position: position, weight: weight))
        }

        return samples
    }

    private func projectedSpan(
        on axis: SIMD3<Float>,
        samples: [PackedSplatSample],
        center: SIMD3<Float>
    ) -> Float {
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        for sample in samples {
            let projection = simd_dot(sample.position - center, axis)
            minimum = min(minimum, projection)
            maximum = max(maximum, projection)
        }
        return max(maximum - minimum, 1e-4)
    }

    private func supportMetrics(
        on axis: SIMD3<Float>,
        samples: [PackedSplatSample],
        center: SIMD3<Float>,
        span: Float
    ) -> AxisSupportMetrics {
        let halfSpan = max(span * 0.5, 1e-4)
        let slabThickness = max(span * 0.14, 1e-4)
        var bottomMass: Float = 0
        var topMass: Float = 0
        var totalMass: Float = 0

        for sample in samples {
            totalMass += sample.weight
            let projection = simd_dot(sample.position - center, axis)
            if projection <= (-halfSpan + slabThickness) {
                bottomMass += sample.weight
            } else if projection >= (halfSpan - slabThickness) {
                topMass += sample.weight
            }
        }

        let extremeMass = max(bottomMass + topMass, 1e-4)
        return AxisSupportMetrics(
            bias: (bottomMass - topMass) / extremeMass,
            coverage: min(extremeMass / max(totalMass, 1e-4), 1.0)
        )
    }

    func applyManualUprightCorrection(token: Int) {
        guard token > 0, token != appliedUprightCorrectionToken else { return }
        appliedUprightCorrectionToken = token

        sceneUpAxis = Self.leveledVerticalAxis(matching: -sceneUpAxis)
        initialPoseSource = "manual_upright_correction"

        if let estimate = sceneOrientationEstimate {
            sceneOrientationEstimate = SceneOrientationEstimate(
                up: sceneUpAxis,
                sampleCount: estimate.sampleCount,
                verticalSpan: estimate.verticalSpan,
                horizontalSpan: estimate.horizontalSpan,
                supportBias: estimate.supportBias,
                confidence: estimate.confidence
            )
        }

        resetCameraToDefault()
        persistViewerInitialPoseIfNeeded()
        NSLog("%@", "[Aether3D][Viewer][Pose] manual_upright_correction file=\(fileURL?.lastPathComponent ?? "unknown")")
    }

    private func logLoadObservation(fileURL: URL, bridge: NativeSplatEngineBridge) {
        let center = sceneCenter
        let viewerPath = viewerPathLabel
        if let estimate = sceneOrientationEstimate {
            let message = "[Aether3D][Viewer][Load] file=\(fileURL.lastPathComponent) " +
                "splats=\(bridge.splatCount) radius=\(Self.format(sceneRadius)) " +
                "center=(\(Self.format(center.x)), \(Self.format(center.y)), \(Self.format(center.z))) " +
                "viewer=\(viewerPath) " +
                "mode=\(activeNavigationMode.rawValue) " +
                "cache=\(initialPoseCacheStatus) source=\(initialPoseSource) " +
                "up=(\(Self.format(estimate.up.x)), \(Self.format(estimate.up.y)), \(Self.format(estimate.up.z))) " +
                "samples=\(estimate.sampleCount) verticalSpan=\(Self.format(estimate.verticalSpan)) " +
                "horizontalSpan=\(Self.format(estimate.horizontalSpan)) supportBias=\(Self.format(estimate.supportBias)) " +
                "confidence=\(Self.format(estimate.confidence))"
            NSLog("%@", message)
        } else {
            let message = "[Aether3D][Viewer][Load] file=\(fileURL.lastPathComponent) " +
                "splats=\(bridge.splatCount) radius=\(Self.format(sceneRadius)) " +
                "center=(\(Self.format(center.x)), \(Self.format(center.y)), \(Self.format(center.z))) " +
                "viewer=\(viewerPath) " +
                "mode=\(activeNavigationMode.rawValue) " +
                "cache=\(initialPoseCacheStatus) source=\(initialPoseSource) " +
                "up=(\(Self.format(sceneUpAxis.x)), \(Self.format(sceneUpAxis.y)), \(Self.format(sceneUpAxis.z)))"
            NSLog("%@", message)
        }
    }

    private func observeFrame(stats: aether_splat_stats_t, cpuFrameMs: Double) {
        observationWindowFrames += 1
        if cpuFrameMs >= Self.slowFrameThresholdMs {
            observationWindowSlowFrames += 1
        }
        observationWindowMaxCPUFrameMs = max(observationWindowMaxCPUFrameMs, cpuFrameMs)

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - observationWindowStart
        guard elapsed >= Self.observationLogInterval else { return }

        let fps = Double(observationWindowFrames) / max(elapsed, 1e-6)
        let averageCPUFrameMs = elapsed * 1000.0 / Double(max(observationWindowFrames, 1))
        let sortSummary = stats.sort_time_ms > 0 ? String(format: "%.2f", stats.sort_time_ms) : "n/a"
        let renderSummary = stats.render_time_ms > 0 ? String(format: "%.2f", stats.render_time_ms) : "n/a"
        let sortModeLabel: String
        switch stats.sort_mode {
        case 1:
            sortModeLabel = "cpuStable"
        case 2:
            sortModeLabel = "gpu"
        case 3:
            sortModeLabel = "htgsCoreTail"
        default:
            sortModeLabel = "none"
        }
        let nearPlaneMm = currentNearPlaneDistance() * 1000.0
        let pitchDegrees = currentLookPitchDegrees()
        let sceneSummary: String
        if let estimate = sceneOrientationEstimate {
            sceneSummary = String(
                format: " up=(%.2f, %.2f, %.2f) conf=%.2f",
                estimate.up.x,
                estimate.up.y,
                estimate.up.z,
                estimate.confidence
            )
        } else {
            sceneSummary = " up=fallback"
        }

        let message = "[Aether3D][Viewer][Observe] file=\(fileURL?.lastPathComponent ?? "unknown") " +
            "fps=\(Self.format(fps, digits: 1)) cpuAvg=\(Self.format(averageCPUFrameMs))ms " +
            "cpuMax=\(Self.format(observationWindowMaxCPUFrameMs))ms " +
            "slow=\(observationWindowSlowFrames)/\(observationWindowFrames) " +
            "splats=\(stats.total_splats) visible=\(stats.visible_splats) " +
            "sortMode=\(sortModeLabel) sort=\(sortSummary) gpuRender=\(renderSummary) " +
            "mode=\(activeNavigationMode.rawValue) dist=\(Self.format(activeNavigationDistance())) near=\(Self.format(nearPlaneMm))mm pitch=\(Self.format(pitchDegrees, digits: 1))deg " +
            "thermal=\(Self.thermalLabel(for: ProcessInfo.processInfo.thermalState))\(sceneSummary)"
        NSLog("%@", message)

        observationWindowStart = now
        observationWindowFrames = 0
        observationWindowSlowFrames = 0
        observationWindowMaxCPUFrameMs = 0
    }

    private func observeOITFrame(cpuFrameMs: Double) {
        observationWindowFrames += 1
        if cpuFrameMs >= Self.slowFrameThresholdMs {
            observationWindowSlowFrames += 1
        }
        observationWindowMaxCPUFrameMs = max(observationWindowMaxCPUFrameMs, cpuFrameMs)

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - observationWindowStart
        guard elapsed >= Self.observationLogInterval else { return }

        let fps = Double(observationWindowFrames) / max(elapsed, 1e-6)
        let averageCPUFrameMs = elapsed * 1000.0 / Double(max(observationWindowFrames, 1))
        let nearPlaneMm = currentNearPlaneDistance() * 1000.0
        let pitchDegrees = currentLookPitchDegrees()
        let sceneSummary: String
        if let estimate = sceneOrientationEstimate {
            sceneSummary = String(
                format: " up=(%.2f, %.2f, %.2f) conf=%.2f",
                estimate.up.x,
                estimate.up.y,
                estimate.up.z,
                estimate.confidence
            )
        } else {
            sceneSummary = " up=fallback"
        }

        let message = "[Aether3D][Viewer][Observe] file=\(fileURL?.lastPathComponent ?? "unknown") " +
            "fps=\(Self.format(fps, digits: 1)) cpuAvg=\(Self.format(averageCPUFrameMs))ms " +
            "cpuMax=\(Self.format(observationWindowMaxCPUFrameMs))ms " +
            "slow=\(observationWindowSlowFrames)/\(observationWindowFrames) " +
            "splats=\(oitSplatCount) visible=\(oitSplatCount) " +
            "sortMode=mobileOIT sort=n/a gpuRender=n/a " +
            "mode=\(activeNavigationMode.rawValue) dist=\(Self.format(activeNavigationDistance())) near=\(Self.format(nearPlaneMm))mm pitch=\(Self.format(pitchDegrees, digits: 1))deg " +
            "thermal=\(Self.thermalLabel(for: ProcessInfo.processInfo.thermalState))\(sceneSummary)"
        NSLog("%@", message)

        observationWindowStart = now
        observationWindowFrames = 0
        observationWindowSlowFrames = 0
        observationWindowMaxCPUFrameMs = 0
    }

    private static func thermalLabel(for state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private func currentLookPitchDegrees() -> Float {
        navigationState.currentPitchDegrees
    }

    private func activeNavigationDistance() -> Float {
        navigationState.activeDistanceToSceneCenter
    }

    private static func principalAxes(of covariance: simd_float3x3) -> [SIMD3<Float>] {
        let first = dominantEigenvector(of: covariance, seed: SIMD3<Float>(0.1, 0.9, 0.3))
        let firstLambda = simd_dot(first, covariance * first)
        let deflated = covariance - outerProduct(first, first) * firstLambda

        var second = dominantEigenvector(of: deflated, seed: orthogonalUnitVector(to: first))
        second -= simd_dot(second, first) * first
        second = normalizedOrFallback(second, fallback: orthogonalUnitVector(to: first))

        let third = normalizedOrFallback(simd_cross(first, second), fallback: orthogonalUnitVector(to: first))
        return [first, second, third]
    }

    private static func dominantEigenvector(
        of matrix: simd_float3x3,
        seed: SIMD3<Float>
    ) -> SIMD3<Float> {
        var vector = normalizedOrFallback(seed, fallback: SIMD3<Float>(0, 1, 0))
        for _ in 0..<10 {
            let next = matrix * vector
            if simd_length_squared(next) < 1e-8 {
                break
            }
            vector = simd_normalize(next)
        }
        return normalizedOrFallback(vector, fallback: SIMD3<Float>(0, 1, 0))
    }

    private static func orientation(forward: SIMD3<Float>, up: SIMD3<Float>) -> simd_quatf {
        let f = normalizedOrFallback(forward, fallback: SIMD3<Float>(0, 0, -1))
        var u = up - simd_dot(up, f) * f
        u = normalizedOrFallback(u, fallback: SIMD3<Float>(0, 1, 0))
        let r = normalizedOrFallback(simd_cross(f, u), fallback: SIMD3<Float>(1, 0, 0))
        let correctedUp = normalizedOrFallback(simd_cross(r, f), fallback: SIMD3<Float>(0, 1, 0))
        let basis = simd_float3x3(columns: (r, correctedUp, -f))
        return simd_normalize(simd_quatf(basis))
    }

    private static func pitchRadians(forward: SIMD3<Float>, sceneUp: SIMD3<Float>) -> Float {
        asin(max(-1.0, min(1.0, -simd_dot(forward, sceneUp))))
    }

    private static func horizontalForwardComponent(
        from forward: SIMD3<Float>,
        sceneUp: SIMD3<Float>
    ) -> SIMD3<Float> {
        let horizontal = forward - simd_dot(forward, sceneUp) * sceneUp
        return normalizedOrFallback(horizontal, fallback: orthogonalUnitVector(to: sceneUp))
    }

    private static func orthogonalUnitVector(to axis: SIMD3<Float>) -> SIMD3<Float> {
        let reference = abs(axis.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let orthogonal = simd_cross(axis, reference)
        return normalizedOrFallback(orthogonal, fallback: SIMD3<Float>(0, 0, -1))
    }

    private static func outerProduct(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> simd_float3x3 {
        simd_float3x3(columns: (
            a * b.x,
            a * b.y,
            a * b.z
        ))
    }

    private static func normalizedOrFallback(
        _ vector: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(vector)
        if lengthSquared < 1e-8 {
            return simd_normalize(fallback)
        }
        return simd_normalize(vector)
    }

    private static func decodeFloat16(bitPattern: UInt16) -> Float {
        Float(Float16(bitPattern: bitPattern))
    }

    private static func decodeLogScaleByte(_ encoded: UInt8) -> Float {
        let normalized = Float(encoded) / 255.0
        return exp(normalized * 16.0 - 8.0)
    }

    private static func readUInt16LE(_ raw: UnsafeRawBufferPointer, at offset: Int) -> UInt16 {
        UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
    }

    private static func mobileContributionScore(
        from raw: UnsafeRawBufferPointer,
        at base: Int
    ) -> Float {
        let opacity = Float(raw[base + 3]) / 255.0
        guard opacity > 0 else { return 0 }

        let sx = decodeLogScaleByte(raw[base + 12])
        let sy = decodeLogScaleByte(raw[base + 13])
        let sz = decodeLogScaleByte(raw[base + 14])
        let geometricMeanScale = pow(max(sx * sy * sz, 1e-12), 1.0 / 3.0)
        return max(opacity * geometricMeanScale, 0)
    }

    private static func selectMobileOITIndices(
        from raw: UnsafeRawBufferPointer,
        totalCount: Int,
        keepMass: Float
    ) -> [UInt32] {
        guard totalCount > 0, keepMass < 1 else {
            return (0..<totalCount).map { UInt32($0) }
        }

        var scored: [(index: UInt32, score: Float)] = []
        scored.reserveCapacity(totalCount)
        var totalScore: Float = 0

        for index in 0..<totalCount {
            let base = index * packedSplatStride
            guard base + (packedSplatStride - 1) < raw.count else { break }
            let score = mobileContributionScore(from: raw, at: base)
            scored.append((UInt32(index), score))
            totalScore += score
        }

        guard totalScore > 1e-8, !scored.isEmpty else {
            return (0..<totalCount).map { UInt32($0) }
        }

        scored.sort { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.index < rhs.index
            }
            return lhs.score > rhs.score
        }

        let targetMass = totalScore * max(0.0, min(keepMass, 1.0))
        var cumulative: Float = 0
        var selected: [UInt32] = []
        selected.reserveCapacity(scored.count)

        for entry in scored {
            selected.append(entry.index)
            cumulative += entry.score
            if cumulative >= targetMass {
                break
            }
        }

        selected.sort()
        return selected.isEmpty ? (0..<totalCount).map { UInt32($0) } : selected
    }

    private static func format<T: BinaryFloatingPoint>(_ value: T, digits: Int = 3) -> String {
        String(format: "%.\(digits)f", Double(value))
    }

    private func cachedViewerInitialPose(for artifactCacheKey: String) -> ViewerInitialPose? {
        guard let viewerInitialPose, viewerInitialPose.artifactCacheKey == artifactCacheKey else {
            return nil
        }
        return viewerInitialPose
    }

    private func persistViewerInitialPoseIfNeeded() {
        guard let artifactCacheKey = activeArtifactCacheKey else { return }
        let pose = ViewerInitialPose(
            artifactCacheKey: artifactCacheKey,
            orientationW: defaultCameraOrientation.real,
            orientationX: defaultCameraOrientation.imag.x,
            orientationY: defaultCameraOrientation.imag.y,
            orientationZ: defaultCameraOrientation.imag.z,
            sceneUpX: sceneUpAxis.x,
            sceneUpY: sceneUpAxis.y,
            sceneUpZ: sceneUpAxis.z,
            source: initialPoseSource,
            confidence: sceneOrientationEstimate?.confidence
        )
        viewerInitialPose = pose
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.onViewerInitialPoseResolved?(pose)
        }
    }

    private static func artifactCacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modifiedMs = Int((values?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000.0)
        return "viewerPoseV\(viewerInitialPoseCacheVersion)|\(url.lastPathComponent)|\(size)|\(modifiedMs)"
    }

    private static func orientationQuaternion(from pose: ViewerInitialPose) -> simd_quatf {
        let imaginary = SIMD3<Float>(pose.orientationX, pose.orientationY, pose.orientationZ)
        let quaternion = simd_quatf(ix: imaginary.x, iy: imaginary.y, iz: imaginary.z, r: pose.orientationW)
        return simd_normalize(quaternion)
    }

    private static func sceneUpVector(from pose: ViewerInitialPose) -> SIMD3<Float> {
        normalizedOrFallback(
            SIMD3<Float>(pose.sceneUpX, pose.sceneUpY, pose.sceneUpZ),
            fallback: SIMD3<Float>(0, 1, 0)
        )
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            if pan.maximumNumberOfTouches == 1 {
                return pan.numberOfTouches <= 1
            }
            if pan.minimumNumberOfTouches >= 2 {
                return pan.numberOfTouches >= 2
            }
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let isOrbitPan: (UIGestureRecognizer) -> Bool = { recognizer in
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            return pan.maximumNumberOfTouches == 1
        }

        if isOrbitPan(gestureRecognizer) || isOrbitPan(otherGestureRecognizer) {
            return false
        }

        let allowsTwoFingerBlend: (UIGestureRecognizer) -> Bool = { recognizer in
            recognizer is UIPinchGestureRecognizer ||
            recognizer is UIRotationGestureRecognizer ||
            ((recognizer as? UIPanGestureRecognizer)?.minimumNumberOfTouches ?? 0) >= 2
        }

        return allowsTwoFingerBlend(gestureRecognizer) && allowsTwoFingerBlend(otherGestureRecognizer)
    }

    private func perspectiveProjection(fovY: Float, aspect: Float,
                                        near: Float, far: Float) -> simd_float4x4 {
        let y = 1.0 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)

        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * near, 0)
        ))
    }
}

// MARK: - MTKViewDelegate

extension GaussianSplatViewController: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Viewport size change — camera projection will update on next draw
    }

    func draw(in view: MTKView) {
        guard isViewerActive, UIApplication.shared.applicationState == .active else { return }
        guard let bridge = splatBridge, dataLoaded else { return }
        let now = ProcessInfo.processInfo.systemUptime
        refreshViewerWarmupIfNeeded(now: now)
        if viewerWarmupActive {
            let minFrameInterval = 1.0 / Double(Self.viewerWarmupPreferredFramesPerSecond)
            if viewerWarmupLastDraw > 0, now - viewerWarmupLastDraw < minFrameInterval {
                return
            }
            viewerWarmupLastDraw = now
        }
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        let cpuFrameStart = ProcessInfo.processInfo.systemUptime

        let vpWidth = UInt32(view.drawableSize.width)
        let vpHeight = UInt32(view.drawableSize.height)

        frameCount += 1

        let viewMat = viewMatrix()
        let projMat = projectionMatrix()
        let fovY = Self.defaultFovY
        let fy = Float(vpHeight) / (2.0 * tan(fovY * 0.5))
        let fx = fy

        guard let rpd = view.currentRenderPassDescriptor else {
            return
        }

        if oitViewerReady {
            let rendered = encodeOITFrame(
                commandBuffer: commandBuffer,
                drawable: drawable,
                viewMatrix: viewMat,
                projectionMatrix: projMat,
                fx: fx,
                fy: fy,
                vpWidth: vpWidth,
                vpHeight: vpHeight
            )
            guard rendered else { return }

            let cpuFrameMs = (ProcessInfo.processInfo.systemUptime - cpuFrameStart) * 1000.0
            observeOITFrame(cpuFrameMs: cpuFrameMs)
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        // ── Step 1: Begin frame (advance triple buffer in C++) ──
        bridge.beginFrame()

        // ── Step 2: Build camera and send to C++ engine ──
        var camera = aether_splat_camera_t()

        // Copy view matrix (column-major float4x4 → float[16])
        withUnsafeMutablePointer(to: &camera.view) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 16) { floats in
                for col in 0..<4 {
                    for row in 0..<4 {
                        floats[col * 4 + row] = viewMat[col][row]
                    }
                }
            }
        }
        // Copy projection matrix
        withUnsafeMutablePointer(to: &camera.proj) { ptr in
            ptr.withMemoryRebound(to: Float.self, capacity: 16) { floats in
                for col in 0..<4 {
                    for row in 0..<4 {
                        floats[col * 4 + row] = projMat[col][row]
                    }
                }
            }
        }

        camera.fx = fx
        camera.fy = fy
        camera.cx = Float(vpWidth) * 0.5
        camera.cy = Float(vpHeight) * 0.5
        camera.vp_width = vpWidth
        camera.vp_height = vpHeight
        if viewerWarmupActive {
            camera.render_splat_limit = UInt32(min(bridge.splatCount, Self.viewerWarmupSplatCap))
        } else {
            camera.render_splat_limit = 0
        }

        bridge.updateCamera(camera)

        // ── Step 3: Encode sort pass (C++ → Metal compute shader) ──
        let cmdBufPtr = Unmanaged.passUnretained(commandBuffer as AnyObject).toOpaque()
        bridge.encodeSort(cmdBufferPtr: cmdBufPtr)

        // ── Step 4: Encode render pass (C++ → native MTLRenderPassDescriptor) ──
        let rpdPtr = Unmanaged.passUnretained(rpd).toOpaque()
        bridge.encodeRenderNative(cmdBufferPtr: cmdBufPtr, renderPassDescPtr: rpdPtr)

        // ── Step 5: End frame (collect stats from C++) ──
        let stats = bridge.endFrame()
        let cpuFrameMs = (ProcessInfo.processInfo.systemUptime - cpuFrameStart) * 1000.0
        observeFrame(stats: stats, cpuFrameMs: cpuFrameMs)

        // Present and commit
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
