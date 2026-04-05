//
// ARCameraPreview.swift
// Aether3D
//
// PR#7 Scan Guidance UI — AR Camera Preview
// UIViewRepresentable wrapping ARSCNView with delegate forwarding
// Apple-platform only (ARKit + SwiftUI)
//

import Foundation

#if canImport(ARKit) && canImport(SwiftUI)
@preconcurrency import SwiftUI
@preconcurrency import ARKit
import SceneKit
#if canImport(simd)
import simd
#endif
#if canImport(CoreMotion)
import CoreMotion
#endif

struct LightEstimateSnapshot: Sendable {
    let ambientIntensity: Float
    let primaryLightDirection: SIMD3<Float>?
    let sphericalHarmonicsCoefficients: [SIMD3<Float>]?

    init(
        ambientIntensity: Float,
        primaryLightDirection: SIMD3<Float>? = nil,
        sphericalHarmonicsCoefficients: [SIMD3<Float>]? = nil
    ) {
        self.ambientIntensity = ambientIntensity
        self.primaryLightDirection = primaryLightDirection
        self.sphericalHarmonicsCoefficients = sphericalHarmonicsCoefficients
    }
}

/// UIViewRepresentable wrapping ARSCNView
///
/// Architecture:
///   - ARSCNView handles real-time camera + SceneKit rendering
///   - Coordinator acts as both ARSCNViewDelegate and ARSessionDelegate
///   - Per-frame ARSession delegate forwards to ScanViewModel.processARFrame()
/// Safety:
///   - Camera feed remains clean; scan guidance is shown via HUD toasts/haptics only
///   - dismantleUIView pauses AR session (prevents resource leak)
///   - sessionWasInterrupted auto-pauses capture (phone call safety)
///   - session(didFailWithError:) transitions to .failed (prevents stuck state)
///   - Task { @MainActor } for ALL delegate→ViewModel calls (thread safety)
struct ARCameraPreview: UIViewRepresentable {
    let viewModel: ScanViewModel
    let prefersMinimalRuntime: Bool
    let shouldAcquireHeavyFrameInputs: Bool
    let shouldRequestSceneDepth: Bool
    let shouldProcessLiveFrames: Bool
    let renderPresentationPolicy: ScanRenderPresentationPolicy

    func makeUIView(context: Context) -> ARSCNView {
        let arView = PreviewARView()
        arView.delegate = context.coordinator
        arView.session.delegate = context.coordinator
        arView.rendersContinuously = true
        arView.isPlaying = true
        arView.scene.isPaused = false
        context.coordinator.markCameraPreviewCreated()
        arView.automaticallyUpdatesLighting = false
        arView.rendersCameraGrain = false
        arView.debugOptions = []  // No debug overlay in production

        context.coordinator.configureCaptureInputPolicy(
            prefersMinimalRuntime: prefersMinimalRuntime,
            shouldAcquireHeavyFrameInputs: shouldAcquireHeavyFrameInputs,
            shouldRequestSceneDepth: shouldRequestSceneDepth,
            shouldProcessLiveFrames: shouldProcessLiveFrames
        )
        context.coordinator.attach(arView)

        // Capture blackout layer (camera feed blocker). Core policy decides visibility.
        let captureBlackout = UIView(frame: .zero)
        captureBlackout.translatesAutoresizingMaskIntoConstraints = false
        captureBlackout.backgroundColor = .black
        captureBlackout.isUserInteractionEnabled = false
        captureBlackout.isHidden = !renderPresentationPolicy.forceBlackBackground
        context.coordinator.configureCaptureBlackoutView(captureBlackout)
        arView.addSubview(captureBlackout)
        NSLayoutConstraint.activate([
            captureBlackout.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
            captureBlackout.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
            captureBlackout.topAnchor.constraint(equalTo: arView.topAnchor),
            captureBlackout.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
        ])

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.configureCaptureInputPolicy(
            prefersMinimalRuntime: prefersMinimalRuntime,
            shouldAcquireHeavyFrameInputs: shouldAcquireHeavyFrameInputs,
            shouldRequestSceneDepth: shouldRequestSceneDepth,
            shouldProcessLiveFrames: shouldProcessLiveFrames
        )
        if let previewView = uiView as? PreviewARView {
            context.coordinator.attach(previewView)
        }
        context.coordinator.configureOverlayAppearance(policy: renderPresentationPolicy)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        coordinator.teardown()
        uiView.delegate = nil
        uiView.session.delegate = nil
        uiView.session.pause()
    }

    // MARK: - Coordinator

    final class PreviewARView: ARSCNView {
        var onAttachedToWindow: ((PreviewARView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            onAttachedToWindow?(self)
        }
    }

    /// Bridges ARKit delegate callbacks to ScanViewModel
    class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate, @unchecked Sendable {
        let viewModel: ScanViewModel
        private weak var captureBlackoutView: UIView?
        private weak var previewView: PreviewARView?
        private var lastOverlayPolicySignature: String = ""
        private let startupTraceLock = NSLock()
        private var cameraPreviewCreatedUptime: TimeInterval = 0
        private var firstARFrameUptime: TimeInterval?
        private var firstPreviewFrameUptime: TimeInterval?
        private let captureInputPolicyLock = NSLock()
        private var prefersMinimalRuntime: Bool = false
        private var shouldAcquireHeavyFrameInputs: Bool = true
        private var shouldRequestSceneDepth: Bool = true
        private var shouldProcessLiveFrames: Bool = true
        private let frameLock = NSLock()
        private var isProcessingFrame = false
        private var tearingDown = false
        private var hasStartedSession = false
        private var hasSignaledReady = false
        private var lastInterfaceOrientation: UIInterfaceOrientation = .portrait
        private var lastViewportSize: CGSize = .zero
#if canImport(CoreMotion)
        private let motionManager = CMMotionManager()
        private let motionQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.qualityOfService = .userInitiated
            return queue
        }()
        private let motionLock = NSLock()
        private var latestDeviceGravity: SIMD3<Double>?
#endif

        init(viewModel: ScanViewModel) {
            self.viewModel = viewModel
        }

        @MainActor
        func attach(_ view: PreviewARView) {
            previewView = view
            view.onAttachedToWindow = { [weak self] attachedView in
                Task { @MainActor in
                    self?.startSessionIfNeeded(on: attachedView)
                }
            }
            guard view.window != nil else { return }
            updateViewportSnapshot(from: view)
            startSessionIfNeeded(on: view)
        }

        @MainActor
        func configureCaptureBlackoutView(_ view: UIView) {
            captureBlackoutView = view
        }

        func markCameraPreviewCreated() {
            let now = ProcessInfo.processInfo.systemUptime
            startupTraceLock.lock()
            cameraPreviewCreatedUptime = now
            firstARFrameUptime = nil
            firstPreviewFrameUptime = nil
            startupTraceLock.unlock()
            hasSignaledReady = false
            NSLog("[Aether3D][Startup] scan_camera_view_created uptime=%.3f", now)
        }

        @MainActor
        func configureCaptureInputPolicy(
            prefersMinimalRuntime: Bool,
            shouldAcquireHeavyFrameInputs: Bool,
            shouldRequestSceneDepth: Bool,
            shouldProcessLiveFrames: Bool
        ) {
            captureInputPolicyLock.lock()
            self.prefersMinimalRuntime = prefersMinimalRuntime
            self.shouldAcquireHeavyFrameInputs = shouldAcquireHeavyFrameInputs
            self.shouldRequestSceneDepth = shouldRequestSceneDepth
            self.shouldProcessLiveFrames = shouldProcessLiveFrames
            captureInputPolicyLock.unlock()
        }

        func teardown() {
            frameLock.lock()
            tearingDown = true
            isProcessingFrame = false
            frameLock.unlock()
            hasStartedSession = false
            hasSignaledReady = false
#if canImport(CoreMotion)
            stopMotionUpdates()
#endif
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureBlackoutView = nil
                self.previewView = nil
            }
        }

        @MainActor
        private func startSessionIfNeeded(on view: PreviewARView) {
            if hasStartedSession {
                refreshPreviewDisplay(on: view)
                return
            }

            let inputPolicy = captureInputPolicy()
            let configuration = ARWorldTrackingConfiguration()
            configuration.environmentTexturing = .none
            configuration.isLightEstimationEnabled = !inputPolicy.prefersMinimalRuntime
            if inputPolicy.shouldRequestSceneDepth,
               ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }

            let runOptions: ARSession.RunOptions = inputPolicy.prefersMinimalRuntime
                ? []
                : [.resetTracking, .removeExistingAnchors]
            view.preferredFramesPerSecond = inputPolicy.prefersMinimalRuntime ? 30 : 60
            view.rendersContinuously = true
            view.isPlaying = true
            view.scene.isPaused = false
#if canImport(CoreMotion)
            startMotionUpdatesIfNeeded()
#endif
            view.session.run(configuration, options: runOptions)
            hasStartedSession = true
            refreshPreviewDisplay(on: view)
            let refreshDelays: [TimeInterval] = [0.0, 0.08, 0.20, 0.45]
            for delay in refreshDelays {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak view] in
                    guard let self, let view else { return }
                    self.refreshPreviewDisplay(on: view)
                }
            }
        }

        @MainActor
        private func refreshPreviewDisplay(on view: PreviewARView) {
            updateViewportSnapshot(from: view)
            view.isHidden = false
            view.alpha = 1.0
            view.rendersContinuously = true
            view.isPlaying = true
            view.scene.isPaused = false
            view.setNeedsLayout()
            view.layoutIfNeeded()
            view.layer.setNeedsDisplay()
            view.setNeedsDisplay()
            CATransaction.flush()
        }

        @MainActor
        private func updateViewportSnapshot(from view: PreviewARView) {
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let size = view.bounds.size
            lastInterfaceOrientation = orientation
            lastViewportSize = size == .zero ? UIScreen.main.bounds.size : size
        }

        private func markSessionReadyIfNeeded() {
            guard !hasSignaledReady else { return }
            hasSignaledReady = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.viewModel.scanState == .initializing {
                    self.viewModel.transition(to: .ready)
                }
                if let previewView = self.previewView {
                    self.refreshPreviewDisplay(on: previewView)
                }
            }
        }

        private func releaseFrameProcessingLock() {
            frameLock.lock()
            isProcessingFrame = false
            frameLock.unlock()
        }

        private func shouldDropFrame() -> Bool {
            frameLock.lock()
            let shouldDrop = tearingDown || isProcessingFrame
            if !shouldDrop {
                isProcessingFrame = true
            }
            frameLock.unlock()
            return shouldDrop
        }

        private func captureInputPolicy() -> (
            prefersMinimalRuntime: Bool,
            shouldAcquireHeavyFrameInputs: Bool,
            shouldRequestSceneDepth: Bool,
            shouldProcessLiveFrames: Bool
        ) {
            captureInputPolicyLock.lock()
            let policy = (
                prefersMinimalRuntime: prefersMinimalRuntime,
                shouldAcquireHeavyFrameInputs: shouldAcquireHeavyFrameInputs,
                shouldRequestSceneDepth: shouldRequestSceneDepth,
                shouldProcessLiveFrames: shouldProcessLiveFrames
            )
            captureInputPolicyLock.unlock()
            return policy
        }

        private func recordFirstARFrameIfNeeded() {
            let now = ProcessInfo.processInfo.systemUptime
            startupTraceLock.lock()
            defer { startupTraceLock.unlock() }
            guard firstARFrameUptime == nil else { return }
            firstARFrameUptime = now
            let delta = cameraPreviewCreatedUptime > 0 ? (now - cameraPreviewCreatedUptime) : 0
            NSLog(
                "[Aether3D][Startup] first_ar_frame uptime=%.3f delta_from_view_created=%.3fs",
                now,
                delta
            )
        }

        private func recordFirstPreviewFrameIfNeeded(renderTime: TimeInterval) {
            startupTraceLock.lock()
            defer { startupTraceLock.unlock() }
            guard firstPreviewFrameUptime == nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            firstPreviewFrameUptime = now
            let deltaFromViewCreated = cameraPreviewCreatedUptime > 0 ? (now - cameraPreviewCreatedUptime) : 0
            let deltaFromARFrame = firstARFrameUptime.map { now - $0 } ?? 0
            NSLog(
                "[Aether3D][Startup] first_preview_frame uptime=%.3f delta_from_view_created=%.3fs delta_from_first_ar_frame=%.3fs render_time=%.3f",
                now,
                deltaFromViewCreated,
                deltaFromARFrame,
                renderTime
            )
        }

#if canImport(CoreMotion)
        private func startMotionUpdatesIfNeeded() {
            guard motionManager.isDeviceMotionAvailable else { return }
            if motionManager.isDeviceMotionActive { return }
            motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
            motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
                guard let self, let motion else { return }
                let gravity = motion.gravity
                self.motionLock.lock()
                self.latestDeviceGravity = SIMD3<Double>(gravity.x, gravity.y, gravity.z)
                self.motionLock.unlock()
            }
        }

        private func stopMotionUpdates() {
            if motionManager.isDeviceMotionActive {
                motionManager.stopDeviceMotionUpdates()
            }
            motionLock.lock()
            latestDeviceGravity = nil
            motionLock.unlock()
        }

        private func captureWorldUp(from cameraTransform: simd_float4x4) -> SIMD3<Float>? {
            motionLock.lock()
            let gravityDevice = latestDeviceGravity
            motionLock.unlock()
            guard let gravityDevice else { return nil }
            let gravityCam = SIMD3<Float>(
                Float(gravityDevice.x),
                Float(gravityDevice.y),
                Float(-gravityDevice.z)
            )
            let worldGravity4 = cameraTransform * SIMD4<Float>(gravityCam.x, gravityCam.y, gravityCam.z, 0)
            let worldGravity = SIMD3<Float>(worldGravity4.x, worldGravity4.y, worldGravity4.z)
            let length = simd_length(worldGravity)
            guard length > 1e-5 else { return nil }
            return -worldGravity / length
        }
#endif

        @MainActor
        func configureOverlayAppearance(policy: ScanRenderPresentationPolicy) {
            captureBlackoutView?.isHidden = !policy.forceBlackBackground
            #if DEBUG
            let alphaText = String(format: "%.2f", policy.overlayClearAlpha)
            let signature =
                "\(policy.forceBlackBackground)|\(policy.overlayOpaque)|"
                + "\(alphaText)|\(policy.borderDepthMode.rawValue)"
            if signature != lastOverlayPolicySignature {
                lastOverlayPolicySignature = signature
                print(
                    "[Aether3D][Policy] overlay forceBlack=\(policy.forceBlackBackground) "
                    + "overlayOpaque=\(policy.overlayOpaque) "
                    + "clearAlpha=\(alphaText) "
                    + "depthMode=\(policy.borderDepthMode.rawValue)"
                )
            }
            #endif
        }

        // ARSessionDelegate — called per frame (~60 FPS)
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            autoreleasepool {
                if shouldDropFrame() {
                    return
                }
                recordFirstARFrameIfNeeded()
                markSessionReadyIfNeeded()
                let inputPolicy = captureInputPolicy()
                if !inputPolicy.shouldProcessLiveFrames {
                    releaseFrameProcessingLock()
                    return
                }
                let timestamp = frame.timestamp
                let cameraTransform = frame.camera.transform
#if canImport(CoreMotion)
                if let worldUp = captureWorldUp(from: cameraTransform) {
                    Task { @MainActor in
                        self.viewModel.ingestCaptureGravity(worldUp: worldUp)
                    }
                }
#endif
                let lightEstimateSnapshot = makeLightEstimateSnapshot(frame.lightEstimate)
                // Snapshot sparse feature points on delegate thread so we never
                // retain ARFrame/ARPointCloud objects across actor hops.
                let featurePointsSnapshot: [SIMD3<Float>] = {
                    guard inputPolicy.shouldAcquireHeavyFrameInputs else { return [] }
                    guard let cloud = frame.rawFeaturePoints else { return [] }
                    let maxPoints = min(cloud.points.count, 512)
                    return Array(cloud.points.prefix(maxPoints))
                }()
                let viewMatrix: simd_float4x4?
                let projectionMatrix: simd_float4x4?
                if inputPolicy.shouldAcquireHeavyFrameInputs {
                    #if os(iOS)
                    let orientation = lastInterfaceOrientation
                    let viewportSize = lastViewportSize
                    viewMatrix = frame.camera.viewMatrix(for: orientation)
                    projectionMatrix = frame.camera.projectionMatrix(
                        for: orientation,
                        viewportSize: viewportSize,
                        zNear: 0.001,
                        zFar: 1000.0
                    )
                    #else
                    viewMatrix = simd_inverse(frame.camera.transform)
                    projectionMatrix = matrix_identity_float4x4
                    #endif
                } else {
                    viewMatrix = nil
                    projectionMatrix = nil
                }

                // Detach ARKit-owned pixel buffers on the delegate thread so the
                // original ARFrame can be released before crossing actor hops.
                guard let pixelBuffer = Self.clonePixelBuffer(frame.capturedImage) else {
                    releaseFrameProcessingLock()
                    return
                }
                let cameraIntrinsics = frame.camera.intrinsics
                // LiDAR depth: sceneDepth on LiDAR devices, nil on non-LiDAR (pure DAv2 path)
                let lidarDepthBuffer: CVPixelBuffer? = inputPolicy.shouldRequestSceneDepth
                    ? (frame.sceneDepth?.depthMap ?? frame.smoothedSceneDepth?.depthMap).flatMap(Self.clonePixelBuffer)
                    : nil

                Task { @MainActor in
                    self.configureOverlayAppearance(policy: self.viewModel.scanState.renderPresentationPolicy)
                    viewModel.processARFrame(
                        timestamp: timestamp,
                        cameraTransform: cameraTransform,
                        lightEstimate: lightEstimateSnapshot,
                        meshAnchors: [],
                        viewMatrix: viewMatrix,
                        projectionMatrix: projectionMatrix,
                        pixelBuffer: pixelBuffer,
                        cameraIntrinsics: cameraIntrinsics,
                        lidarDepthBuffer: lidarDepthBuffer,
                        featurePoints: featurePointsSnapshot
                    )
                    self.releaseFrameProcessingLock()
                }
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            recordFirstPreviewFrameIfNeeded(renderTime: time)
        }

        // ARSession error handling
        func session(_ session: ARSession, didFailWithError error: Error) {
            Task { @MainActor in
                viewModel.handleSessionFailure("相机会话中断了，请返回主页重新开始一次扫描。")
            }
        }

        // Session interrupted (phone call, notification, etc.)
        func sessionWasInterrupted(_ session: ARSession) {
            Task { @MainActor in
                viewModel.handleSessionInterrupted()
            }
        }

        // Session interruption ended
        func sessionInterruptionEnded(_ session: ARSession) {
            // Session automatically resumes — user can tap to continue
        }

        private static func clonePixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            let pixelFormat = CVPixelBufferGetPixelFormatType(source)
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]

            var destination: CVPixelBuffer?
            guard CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                pixelFormat,
                attrs as CFDictionary,
                &destination
            ) == kCVReturnSuccess,
            let destination else {
                return nil
            }

            CVPixelBufferLockBaseAddress(source, .readOnly)
            CVPixelBufferLockBaseAddress(destination, [])
            defer {
                CVPixelBufferUnlockBaseAddress(destination, [])
                CVPixelBufferUnlockBaseAddress(source, .readOnly)
            }

            let planeCount = CVPixelBufferGetPlaneCount(source)
            if planeCount > 0 {
                for plane in 0..<planeCount {
                    guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                          let dstBase = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else {
                        return nil
                    }
                    let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                    let dstStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                    let rows = CVPixelBufferGetHeightOfPlane(source, plane)
                    let bytesPerRow = min(srcStride, dstStride)
                    for row in 0..<rows {
                        memcpy(
                            dstBase.advanced(by: row * dstStride),
                            srcBase.advanced(by: row * srcStride),
                            bytesPerRow
                        )
                    }
                }
                return destination
            }

            guard let srcBase = CVPixelBufferGetBaseAddress(source),
                  let dstBase = CVPixelBufferGetBaseAddress(destination) else {
                return nil
            }
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(destination)
            let rows = CVPixelBufferGetHeight(source)
            let bytesPerRow = min(srcStride, dstStride)
            for row in 0..<rows {
                memcpy(
                    dstBase.advanced(by: row * dstStride),
                    srcBase.advanced(by: row * srcStride),
                    bytesPerRow
                )
            }
            return destination
        }

        private func makeLightEstimateSnapshot(_ estimate: ARLightEstimate?) -> LightEstimateSnapshot? {
            guard let estimate else { return nil }

            var direction: SIMD3<Float>?
            var shCoeffs: [SIMD3<Float>]?

            if let directional = estimate as? ARDirectionalLightEstimate {
                let dir = directional.primaryLightDirection
                direction = SIMD3<Float>(Float(dir.x), Float(dir.y), Float(dir.z))
                let data = directional.sphericalHarmonicsCoefficients
                let floatCount = data.count / MemoryLayout<Float>.size
                if floatCount >= 27 {
                    var values: [SIMD3<Float>] = []
                    values.reserveCapacity(9)
                    data.withUnsafeBytes { ptr in
                        let floats = ptr.bindMemory(to: Float.self)
                        for i in 0..<9 {
                            values.append(
                                SIMD3<Float>(
                                    floats[i * 3],
                                    floats[i * 3 + 1],
                                    floats[i * 3 + 2]
                                )
                            )
                        }
                    }
                    shCoeffs = values
                }
            }

            return LightEstimateSnapshot(
                ambientIntensity: Float(estimate.ambientIntensity),
                primaryLightDirection: direction,
                sphericalHarmonicsCoefficients: shCoeffs
            )
        }
    }
}

#endif
