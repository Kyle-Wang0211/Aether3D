//
// ScanGuidanceRenderPipeline.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Metal Render Pipeline
// Metal 6-pass render orchestrator with triple buffering
// Apple-platform only (import Metal)
// Phase 2: Implements wedge fill + border passes only
//

import Foundation
#if canImport(simd)
import simd
#endif
import Aether3DCore

/// Backend-neutral frame packet for scan-guidance overlay rendering.
public struct ScanGuidanceFrameInput {
    public let displaySnapshot: [String: Double]
    public let colorStates: [String: ColorState]
    public let meshTriangles: [ScanTriangle]
    public let borderDepthMode: ScanOverlayDepthMode
    public let lightEstimate: Any?
    public let cameraTransform: simd_float4x4
    public let viewMatrix: simd_float4x4?
    public let projectionMatrix: simd_float4x4?
    public let frameDeltaTime: TimeInterval
    public let precomputedFlipAngles: [Float]?
    public let precomputedRippleAmplitudes: [Float]?
    public let precomputedFlipAxisData: [(origin: SIMD3<Float>, direction: SIMD3<Float>)]?
    public let gpuDurationMs: Double?

    public init(
        displaySnapshot: [String: Double],
        colorStates: [String: ColorState],
        meshTriangles: [ScanTriangle],
        borderDepthMode: ScanOverlayDepthMode = .lessEqual,
        lightEstimate: Any?,
        cameraTransform: simd_float4x4,
        viewMatrix: simd_float4x4? = nil,
        projectionMatrix: simd_float4x4? = nil,
        frameDeltaTime: TimeInterval,
        precomputedFlipAngles: [Float]? = nil,
        precomputedRippleAmplitudes: [Float]? = nil,
        precomputedFlipAxisData: [(origin: SIMD3<Float>, direction: SIMD3<Float>)]? = nil,
        gpuDurationMs: Double? = nil
    ) {
        self.displaySnapshot = displaySnapshot
        self.colorStates = colorStates
        self.meshTriangles = meshTriangles
        self.borderDepthMode = borderDepthMode
        self.lightEstimate = lightEstimate
        self.cameraTransform = cameraTransform
        self.viewMatrix = viewMatrix
        self.projectionMatrix = projectionMatrix
        self.frameDeltaTime = frameDeltaTime
        self.precomputedFlipAngles = precomputedFlipAngles
        self.precomputedRippleAmplitudes = precomputedRippleAmplitudes
        self.precomputedFlipAxisData = precomputedFlipAxisData
        self.gpuDurationMs = gpuDurationMs
    }
}

/// Unified rendering backend protocol (shared contract across iOS/Android/HarmonyOS).
public protocol ScanGuidanceRenderingBackend: AnyObject {
    func update(frame: ScanGuidanceFrameInput)
    func resetPersistentVisualState()
}

#if !canImport(Metal)
public protocol ScanGuidanceOverlayEncoder: ScanGuidanceRenderingBackend {}

public enum ScanGuidanceRenderingBackendFactory {
    public static func makeDefaultBackend() -> (any ScanGuidanceRenderingBackend)? {
        nil
    }

    public static func overlayEncoder(
        from backend: (any ScanGuidanceRenderingBackend)?
    ) -> (any ScanGuidanceOverlayEncoder)? {
        _ = backend
        return nil
    }
}
#endif

#if canImport(Metal)
import Metal
import MetalKit
import QuartzCore  // for CACurrentMediaTime — OK in App/

/// Overlay encoder interface used by platform-specific drawable surfaces.
public protocol ScanGuidanceOverlayEncoder: ScanGuidanceRenderingBackend {
    func encode(
        into commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    )
}

public enum ScanGuidanceRenderingBackendFactory {
    public static func makeDefaultBackend() -> (any ScanGuidanceRenderingBackend)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return try? ScanGuidanceRenderPipeline(device: device)
    }

    public static func overlayEncoder(
        from backend: (any ScanGuidanceRenderingBackend)?
    ) -> (any ScanGuidanceOverlayEncoder)? {
        backend as? (any ScanGuidanceOverlayEncoder)
    }
}

public final class ScanGuidanceRenderPipeline: ScanGuidanceOverlayEncoder {
    private static let buildFingerprint = "SGRP_2026_02_25_0215_BUFFER_SNAPSHOT_V3"
    private typealias ShaderThresholds = (
        rippleMinAmplitude: Float,
        rippleBoostScale: Float,
        fillDitherStart: Float,
        fillDitherEnd: Float,
        borderMinWidth: Float,
        borderMinAlpha: Float,
        borderAAFactor: Float,
        borderFwidthEpsilon: Float,
        borderDiscardAlpha: Float
    )

    private struct DrawBuffers {
        let vertex: MTLBuffer
        let index: MTLBuffer
        let uniforms: MTLBuffer
        let perTriangle: MTLBuffer
    }

    public static let kMaxInflightBuffers: Int = ScanGuidanceConstants.kMaxInflightBuffers
    private let inflightSemaphore: DispatchSemaphore
    private var currentBufferIndex: Int = 0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var wedgeFillPipeline: MTLRenderPipelineState?
    private var borderStrokePipeline: MTLRenderPipelineState?
    private var metallicLightingPipeline: MTLRenderPipelineState?
    private var colorCorrectionPipeline: MTLRenderPipelineState?
    private var ambientOcclusionPipeline: MTLRenderPipelineState?
    private var postProcessPipeline: MTLRenderPipelineState?
    private var fillDepthStencilState: MTLDepthStencilState?
    private var overlayDepthStencilStateLess: MTLDepthStencilState?
    private var overlayDepthStencilStateLessEqual: MTLDepthStencilState?
    private var borderDepthMode: ScanOverlayDepthMode = .lessEqual
    private var currentVertexCount: Int = 0
    private var currentIndexCount: Int = 0
    private var lastWrittenBufferIndex: Int = 0
    private var debugEncodeFrameCounter: Int = 0

    /// Tracks whether update() has produced new data that encode() hasn't consumed yet.
    /// Prevents semaphore over-signaling: encode() only adds a GPU-completion signal()
    /// when there's a corresponding update() wait(). Without this, MTKView calling
    /// draw() faster than ARSession fires frames causes unbounded semaphore growth,
    /// breaking the triple-buffer protection guarantee.
    private var hasUnconsumedUpdate: Bool = false
    private var pendingSemaphoreWaitCount: Int = 0

    /// Protects currentIndexCount / lastWrittenBufferIndex / hasUnconsumedUpdate from
    /// concurrent read (encode on MTKView delegate thread) and write (update on main thread).
    /// Without this, encode() can read a partially-written bufferIndex or indexCount,
    /// causing Metal to draw from the wrong buffer or with a stale count.
    private let bufferLock = NSLock()

    // Sub-systems (Core/ pure algorithms)
    private let wedgeGenerator: WedgeGeometryGenerator
    private let borderCalculator: AdaptiveBorderCalculator
    private let thermalAdapter: ThermalQualityAdapter

    // Sub-systems (App/ platform-specific)
    private let lightEstimator: EnvironmentLightEstimator

    // Triple-buffered Metal buffers
    private var vertexBuffers: [MTLBuffer] = []
    private var indexBuffers: [MTLBuffer] = []
    private var uniformBuffers: [MTLBuffer] = []
    private var perTriangleBuffers: [MTLBuffer] = []

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw ScanGuidanceError.deviceInitializationFailed
        }
        self.commandQueue = queue
        self.inflightSemaphore = DispatchSemaphore(value: Self.kMaxInflightBuffers)
        self.wedgeGenerator = WedgeGeometryGenerator()
        self.borderCalculator = AdaptiveBorderCalculator()
        self.lightEstimator = EnvironmentLightEstimator()
        self.thermalAdapter = ThermalQualityAdapter()
        
        // Layer 4.3: Initialize triple buffers with guard-let instead of force unwrap.
        // device.makeBuffer() can return nil under memory pressure or with invalid
        // parameters, and force unwrap would crash the entire app.
        for _ in 0..<Self.kMaxInflightBuffers {
            // Wedge geometry expansion: each input triangle generates a 3D prism
            // with lod0TrianglesPerPrism (44) output triangles = 132 indices.
            // For 2000 input triangles: 2000 × 132 = 264K indices × 4 bytes = 1.06MB.
            // Use 4MB initial buffers to handle up to ~7500 input triangles without reallocation.
            guard let vb = device.makeBuffer(length: 4 * 1024 * 1024, options: []),   // 4MB vertex
                  let ib = device.makeBuffer(length: 4 * 1024 * 1024, options: []),   // 4MB index
                  let ub = device.makeBuffer(length: 1024, options: []),               // 1KB uniform
                  let ptb = device.makeBuffer(length: 256 * 1024, options: [])         // 256KB per-tri
            else {
                throw ScanGuidanceError.deviceInitializationFailed
            }
            vertexBuffers.append(vb)
            indexBuffers.append(ib)
            uniformBuffers.append(ub)
            perTriangleBuffers.append(ptb)
        }
        
        // Create render pipeline states
        try createRenderPipelines()
        
        // Create depth states:
        // - Fill pass writes depth.
        // - Border/composite passes read depth with lessEqual so coplanar fragments survive.
        let fillDepth = MTLDepthStencilDescriptor()
        fillDepth.depthCompareFunction = .less
        fillDepth.isDepthWriteEnabled = true
        self.fillDepthStencilState = device.makeDepthStencilState(descriptor: fillDepth)

        let overlayDepthLess = MTLDepthStencilDescriptor()
        overlayDepthLess.depthCompareFunction = .less
        overlayDepthLess.isDepthWriteEnabled = false
        self.overlayDepthStencilStateLess = device.makeDepthStencilState(descriptor: overlayDepthLess)

        let overlayDepthLessEqual = MTLDepthStencilDescriptor()
        overlayDepthLessEqual.depthCompareFunction = .lessEqual
        overlayDepthLessEqual.isDepthWriteEnabled = false
        self.overlayDepthStencilStateLessEqual = device.makeDepthStencilState(descriptor: overlayDepthLessEqual)

        #if DEBUG
        print("[Aether3D][Build] \(Self.buildFingerprint) file=\(#fileID)")
        #endif
    }

    deinit {
        bufferLock.lock()
        let pendingSignals = pendingSemaphoreWaitCount
        pendingSemaphoreWaitCount = 0
        hasUnconsumedUpdate = false
        bufferLock.unlock()

        if pendingSignals > 0 {
            for _ in 0..<pendingSignals {
                inflightSemaphore.signal()
            }
        }
    }

    public func update(frame: ScanGuidanceFrameInput) {
        update(
            displaySnapshot: frame.displaySnapshot,
            colorStates: frame.colorStates,
            meshTriangles: frame.meshTriangles,
            borderDepthMode: frame.borderDepthMode,
            lightEstimate: frame.lightEstimate,
            cameraTransform: frame.cameraTransform,
            viewMatrix: frame.viewMatrix,
            projectionMatrix: frame.projectionMatrix,
            frameDeltaTime: frame.frameDeltaTime,
            precomputedFlipAngles: frame.precomputedFlipAngles,
            precomputedRippleAmplitudes: frame.precomputedRippleAmplitudes,
            precomputedFlipAxisData: frame.precomputedFlipAxisData,
            gpuDurationMs: frame.gpuDurationMs
        )
    }

    /// Per-frame update — reads from PatchDisplayMap snapshot, no coverage dependency
    /// v7.0.2: displaySnapshot is [String: Double], converted from [DisplayEntry]
    ///         by caller (see Part A.2 for conversion pattern)
    /// v7.0.4: Thermal tier now drives LOD, triangle budget, animation toggles
    public func update(
        displaySnapshot: [String: Double],
        colorStates: [String: ColorState],
        meshTriangles: [ScanTriangle],
        borderDepthMode: ScanOverlayDepthMode = .lessEqual,
        lightEstimate: Any?,  // ARLightEstimate on iOS
        cameraTransform: simd_float4x4,
        viewMatrix: simd_float4x4? = nil,
        projectionMatrix: simd_float4x4? = nil,
        frameDeltaTime: TimeInterval,
        precomputedFlipAngles: [Float]? = nil,
        precomputedRippleAmplitudes: [Float]? = nil,
        precomputedFlipAxisData: [(origin: SIMD3<Float>, direction: SIMD3<Float>)]? = nil,
        gpuDurationMs: Double? = nil
    ) {
        // Layer 4.1: Acquire semaphore at start of update() to prevent writing
        // to a triple-buffer slot that the GPU is still reading from encode().
        // The signal() remains in encode()'s completedHandler.
        //
        // CRITICAL: Use wait(timeout:) instead of wait() to prevent deadlock.
        // If encode() is never called (MTKView paused, pipeline nil, app background),
        // the semaphore is never signaled → wait() blocks the main thread FOREVER.
        // With a 100ms timeout, we skip this frame instead of freezing the app.
        // 100ms = ~6 frames at 60fps, generous enough for GPU pipeline stalls.
        let waitResult = inflightSemaphore.wait(timeout: .now() + .milliseconds(100))
        if waitResult == .timedOut {
            // GPU is backed up — skip this update entirely instead of blocking.
            // The render pipeline will re-use the previous frame's data (stale but visible).
            #if DEBUG
            print("[Aether3D] ⚠️ Triple-buffer semaphore timed out — skipping frame update")
            #endif
            return
        }
        bufferLock.lock()
        pendingSemaphoreWaitCount += 1
        bufferLock.unlock()

        #if os(iOS) || os(macOS)
        thermalAdapter.updateThermalState(ProcessInfo.processInfo.thermalState)
        #endif

        if let gpuDuration = gpuDurationMs {
            thermalAdapter.updateFrameTiming(gpuDurationMs: gpuDuration)
        }

        self.borderDepthMode = borderDepthMode

        // Note: ScanViewModel already performs C++ multi-factor selection
        // (selectStableRenderTriangles) before passing meshTriangles here.
        // The thermal adapter's own tier limit is still applied as a safety cap.
        let tier = thermalAdapter.currentTier

        // v7.3: LOD budget calculation delegated to Core layer static method.
        let maxSafeInputTriangles = WedgeGeometryGenerator.LODLevel.maxSafeInputTriangles(
            lod: tier.lodLevel,
            maxTrianglesFromTier: tier.maxTriangles
        )
        let limitedTriangles = meshTriangles.count > maxSafeInputTriangles
            ? Array(meshTriangles.prefix(maxSafeInputTriangles))
            : meshTriangles
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        let wedgeData = wedgeGenerator.generate(
            triangles: limitedTriangles,
            displayValues: displaySnapshot,
            cameraPosition: cameraPosition,
            lod: tier.lodLevel
        )
        let renderTriangleCount = max(0, wedgeData.triangleCount)
        let parentTriangleIndices = wedgeGenerator.parentTriangleIndicesForLastGenerate()

        let lightState = lightEstimator.update(
            lightEstimate: lightEstimate,
            cameraImage: nil,
            timestamp: CACurrentMediaTime()
        )

        let flipAngles: [Float]
        if tier.enableFlipAnimation, let provided = precomputedFlipAngles {
            flipAngles = expandPerTriangleValues(
                provided,
                parentIndices: parentTriangleIndices,
                triangleCount: renderTriangleCount
            )
        } else {
            flipAngles = Array(repeating: 0, count: renderTriangleCount)
        }

        let rippleAmplitudes: [Float]
        if tier.enableRipple, let provided = precomputedRippleAmplitudes {
            rippleAmplitudes = expandPerTriangleValues(
                provided,
                parentIndices: parentTriangleIndices,
                triangleCount: renderTriangleCount
            )
        } else {
            rippleAmplitudes = Array(repeating: 0, count: renderTriangleCount)
        }

        let borderWidths = normalizePerTriangleArray(
            wedgeGenerator.borderWidthsForLastGenerate(),
            triangleCount: renderTriangleCount
        )
        let borderAlphas = normalizePerTriangleArray(
            wedgeGenerator.borderAlphasForLastGenerate(),
            triangleCount: renderTriangleCount
        )
        let shaderThresholds = normalizeShaderThresholdData(
            wedgeGenerator.shaderThresholdsForLastGenerate(),
            triangleCount: renderTriangleCount
        )

        // Compute per-triangle flip axis data
        let flipAxisData = expandFlipAxisData(
            precomputedFlipAxisData,
            parentIndices: parentTriangleIndices,
            triangleCount: renderTriangleCount
        )

        let grayscaleColors = normalizeGrayscaleColors(
            wedgeGenerator.grayscaleForLastGenerate(),
            triangleCount: renderTriangleCount
        )

        #if DEBUG
        // One-shot diagnostic: confirm buffer sizes on first frame
        if currentBufferIndex == 1 {  // After first advance (was 0 → 1)
            let ibLen = indexBuffers[0].length
            let vbLen = vertexBuffers[0].length
            print("[Aether3D] Pipeline: ib=\(ibLen) vb=\(vbLen) "
                + "wedge[v=\(wedgeData.vertices.count),i=\(wedgeData.indices.count)] "
                + "input=\(limitedTriangles.count) bufSlot=\(currentBufferIndex - 1)")
        }
        #endif

        uploadToBuffers(
            wedgeData: wedgeData,
            lightState: lightState,
            flipAngles: flipAngles,
            rippleAmplitudes: rippleAmplitudes,
            borderWidths: borderWidths,
            borderAlphas: borderAlphas,
            shaderThresholds: shaderThresholds,
            flipAxisData: flipAxisData,
            grayscaleColors: grayscaleColors,
            cameraTransform: cameraTransform,
            viewMatrix: viewMatrix ?? simd_inverse(cameraTransform),
            projectionMatrix: projectionMatrix ?? matrix_identity_float4x4,
            qualityTier: tier.rawValue
        )
    }

    /// Encode all render passes into command buffer
    /// Phase 2: Only encodes wedge fill + border stroke passes
    ///
    /// Layer 4.1: inflightSemaphore.wait() moved to update() to protect the WRITE
    /// side. Here we only register the signal handler — the semaphore was already
    /// acquired before uploadToBuffers() wrote data.
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        // Read shared state under lock to prevent tearing with update() on main thread.
        // Also consume the update flag: only signal the semaphore if update() produced
        // new data (paired wait/signal). Without this, MTKView calling draw() faster
        // than ARSession produces frames → extra signal() calls → semaphore count
        // grows beyond kMaxInflightBuffers → triple-buffer protection breaks.
        bufferLock.lock()
        let bufferIndex = lastWrittenBufferIndex
        let indexCountSnapshot = currentIndexCount
        let shouldSignalSemaphore = hasUnconsumedUpdate
        if shouldSignalSemaphore {
            pendingSemaphoreWaitCount = max(0, pendingSemaphoreWaitCount - 1)
        }
        hasUnconsumedUpdate = false
        let drawBuffers: DrawBuffers? = (bufferIndex >= 0 && bufferIndex < Self.kMaxInflightBuffers)
            ? DrawBuffers(
                vertex: vertexBuffers[bufferIndex],
                index: indexBuffers[bufferIndex],
                uniforms: uniformBuffers[bufferIndex],
                perTriangle: perTriangleBuffers[bufferIndex]
            )
            : nil
        bufferLock.unlock()

        // Safety: validate buffer snapshot is available.
        guard let drawBuffers else {
            if shouldSignalSemaphore {
                inflightSemaphore.signal()  // Balance the wait() from update()
            }
            return
        }

        // Safety: validate indexCount against actual buffer capacity.
        // If buffer growth failed (makeBuffer returned nil), indexCount may
        // exceed what the index buffer can hold → Metal validation crash.
        let maxSafeIndices = drawBuffers.index.length / MemoryLayout<UInt32>.stride
        let safeIndexCount = min(indexCountSnapshot, maxSafeIndices)
        #if DEBUG
        debugEncodeFrameCounter &+= 1
        if safeIndexCount != indexCountSnapshot {
            print(
                "[Aether3D][DrawClamp] requested=\(indexCountSnapshot) "
                + "safe=\(safeIndexCount) "
                + "indexBufferBytes=\(drawBuffers.index.length) "
                + "slot=\(bufferIndex)"
            )
        } else if debugEncodeFrameCounter % 60 == 0 {
            print(
                "[Aether3D][DrawStats] indexCount=\(safeIndexCount) "
                + "indexBufferBytes=\(drawBuffers.index.length) "
                + "slot=\(bufferIndex)"
            )
        }
        #endif

        if shouldSignalSemaphore {
            let semaphore = inflightSemaphore
            commandBuffer.addCompletedHandler { _ in
                semaphore.signal()
            }
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else { return }

        encodeWedgeFill(encoder: encoder, buffers: drawBuffers, indexCount: safeIndexCount)
        encodeBorderStroke(encoder: encoder, buffers: drawBuffers, indexCount: safeIndexCount)

        // Pass 3-6: thermal-aware pass mask from C++ engine
        let rawMask = thermalAdapter.passMask
        let mask = rawMask == 0 ? UInt32(0x03) : rawMask  // Safety: zero fallback → wedge + border only
        if mask & 0x04 != 0 {  // bit2: metallic lighting
            encodeAdditionalPass(encoder: encoder, buffers: drawBuffers, indexCount: safeIndexCount, pipeline: metallicLightingPipeline)
        }
        if mask & 0x08 != 0 {  // bit3: color correction
            encodeAdditionalPass(encoder: encoder, buffers: drawBuffers, indexCount: safeIndexCount, pipeline: colorCorrectionPipeline)
        }
        if mask & 0x10 != 0 {  // bit4: ambient occlusion
            encodeAdditionalPass(encoder: encoder, buffers: drawBuffers, indexCount: safeIndexCount, pipeline: ambientOcclusionPipeline)
        }
        if mask & 0x20 != 0 {  // bit5: post-processing
            encodeAdditionalPass(encoder: encoder, buffers: drawBuffers, indexCount: safeIndexCount, pipeline: postProcessPipeline)
        }

        encoder.endEncoding()
    }

    public func applyRenderTier(_ tier: ThermalQualityAdapter.RenderTier) {
        thermalAdapter.forceRenderTier(tier)
    }

    public func resetPersistentVisualState() {
        wedgeGenerator.resetPersistentVisualState()
        borderCalculator.resetPersistentBorderState()
    }

    // MARK: - Private Methods

    private func createRenderPipelines() throws {
        // Load Metal library from the app bundle
        guard let library = device.makeDefaultLibrary() else {
            throw ScanGuidanceError.pipelineCreationFailed("Failed to load Metal library")
        }
        
        // ── Pass 1: Wedge Fill Pipeline ──
        guard let wedgeVertexFn = library.makeFunction(name: "wedgeFillVertex"),
              let wedgeFragmentFn = library.makeFunction(name: "wedgeFillFragment") else {
            throw ScanGuidanceError.pipelineCreationFailed("Failed to load wedge fill shaders")
        }
        
        let wedgeDescriptor = MTLRenderPipelineDescriptor()
        wedgeDescriptor.label = "Aether3D Wedge Fill"
        wedgeDescriptor.vertexFunction = wedgeVertexFn
        wedgeDescriptor.fragmentFunction = wedgeFragmentFn
        wedgeDescriptor.vertexDescriptor = ScanGuidanceVertexDescriptor.create()
        
        // Color attachment: pre-multiplied alpha blending for AR overlay
        wedgeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        wedgeDescriptor.colorAttachments[0].isBlendingEnabled = true
        wedgeDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one  // pre-multiplied
        wedgeDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        wedgeDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        wedgeDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        // Depth
        wedgeDescriptor.depthAttachmentPixelFormat = .depth32Float
        
        do {
            wedgeFillPipeline = try device.makeRenderPipelineState(descriptor: wedgeDescriptor)
        } catch {
            throw ScanGuidanceError.pipelineCreationFailed("Failed to create wedge fill pipeline: \(error)")
        }
        
        // ── Pass 2: Border Stroke Pipeline ──
        guard let borderFragmentFn = library.makeFunction(name: "borderStrokeFragment") else {
            throw ScanGuidanceError.pipelineCreationFailed("Failed to load border stroke shader")
        }
        
        let borderDescriptor = MTLRenderPipelineDescriptor()
        borderDescriptor.label = "Aether3D Border Stroke"
        borderDescriptor.vertexFunction = wedgeVertexFn  // Same vertex shader
        borderDescriptor.fragmentFunction = borderFragmentFn
        borderDescriptor.vertexDescriptor = ScanGuidanceVertexDescriptor.create()
        
        // Additive blending for borders
        borderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        borderDescriptor.colorAttachments[0].isBlendingEnabled = true
        borderDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one  // pre-multiplied
        borderDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        borderDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        borderDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        borderDescriptor.depthAttachmentPixelFormat = .depth32Float
        
        do {
            borderStrokePipeline = try device.makeRenderPipelineState(descriptor: borderDescriptor)
        } catch {
            throw ScanGuidanceError.pipelineCreationFailed("Failed to create border stroke pipeline: \(error)")
        }

        // ── Pass 3-6: Additional rendering passes ──
        // All share wedgeFillVertex; differ only in fragment function and blend mode.
        // These passes are lightweight compositing layers — they fail gracefully if shader not found.

        let additionalPasses: [(name: String, fragmentFn: String, target: ReferenceWritableKeyPath<ScanGuidanceRenderPipeline, MTLRenderPipelineState?>)] = [
            ("Aether3D Metallic Lighting", "metallicLightingFragment", \.metallicLightingPipeline),
            ("Aether3D Color Correction", "colorCorrectionFragment", \.colorCorrectionPipeline),
            ("Aether3D Ambient Occlusion", "ambientOcclusionFragment", \.ambientOcclusionPipeline),
            ("Aether3D Post-Processing", "postProcessFragment", \.postProcessPipeline),
        ]

        for pass in additionalPasses {
            guard let fragmentFn = library.makeFunction(name: pass.fragmentFn) else {
                continue  // Graceful: skip passes whose shaders aren't compiled yet
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.label = pass.name
            desc.vertexFunction = wedgeVertexFn
            desc.fragmentFunction = fragmentFn
            desc.vertexDescriptor = ScanGuidanceVertexDescriptor.create()
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            desc.depthAttachmentPixelFormat = .depth32Float

            if let pipelineState = try? device.makeRenderPipelineState(descriptor: desc) {
                self[keyPath: pass.target] = pipelineState
            }
        }
    }

    private func encodeWedgeFill(encoder: MTLRenderCommandEncoder, buffers: DrawBuffers, indexCount: Int) {
        guard let wedgeFillPipeline else { return }

        encoder.setRenderPipelineState(wedgeFillPipeline)
        encoder.setTriangleFillMode(.fill)
        encoder.setCullMode(.back)
        if let fillDepthStencilState {
            encoder.setDepthStencilState(fillDepthStencilState)
        }

        // Bind buffers
        encoder.setVertexBuffer(buffers.vertex,
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.vertexData)
        encoder.setVertexBuffer(buffers.uniforms,
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.uniforms)
        encoder.setVertexBuffer(buffers.perTriangle,
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.perTriangleData)

        // Fragment buffers
        encoder.setFragmentBuffer(buffers.uniforms,
                                 offset: 0,
                                 index: ScanGuidanceVertexDescriptor.BufferIndex.uniforms)

        let maxSafeIndices = buffers.index.length / MemoryLayout<UInt32>.stride
        let safeDrawIndexCount = min(indexCount, maxSafeIndices)
        if safeDrawIndexCount > 0 {
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: safeDrawIndexCount,
                indexType: .uint32,
                indexBuffer: buffers.index,
                indexBufferOffset: 0
            )
        }
    }

    private func encodeBorderStroke(encoder: MTLRenderCommandEncoder, buffers: DrawBuffers, indexCount: Int) {
        guard let borderStrokePipeline else { return }

        encoder.setRenderPipelineState(borderStrokePipeline)
        encoder.setTriangleFillMode(.fill)
        // Border pass uses lessEqual and no depth write to stay visible on top of fill.
        if let depthState = currentOverlayDepthStencilState() {
            encoder.setDepthStencilState(depthState)
        }
        encoder.setCullMode(.back)

        // Same buffer bindings as wedge fill
        encoder.setVertexBuffer(buffers.vertex,
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.vertexData)
        encoder.setVertexBuffer(buffers.uniforms,
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.uniforms)
        encoder.setVertexBuffer(buffers.perTriangle,
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.perTriangleData)
        encoder.setFragmentBuffer(buffers.uniforms,
                                 offset: 0,
                                 index: ScanGuidanceVertexDescriptor.BufferIndex.uniforms)

        let maxSafeIndices = buffers.index.length / MemoryLayout<UInt32>.stride
        let safeDrawIndexCount = min(indexCount, maxSafeIndices)
        if safeDrawIndexCount > 0 {
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: safeDrawIndexCount,
                indexType: .uint32,
                indexBuffer: buffers.index,
                indexBufferOffset: 0
            )
        }
    }

    /// Encode an additional compositing pass (Pass 3-6).
    /// Reuses the same vertex/uniform/perTriangle buffers as wedge fill.
    private func encodeAdditionalPass(
        encoder: MTLRenderCommandEncoder,
        buffers: DrawBuffers,
        indexCount: Int,
        pipeline: MTLRenderPipelineState?
    ) {
        guard let pipeline else { return }
        guard indexCount > 0 else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setTriangleFillMode(.fill)
        encoder.setCullMode(.back)
        // Composite passes share overlay depth behavior with border pass.
        if let depthState = currentOverlayDepthStencilState() {
            encoder.setDepthStencilState(depthState)
        }

        encoder.setVertexBuffer(buffers.vertex,
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.vertexData)
        encoder.setVertexBuffer(buffers.uniforms,
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.uniforms)
        encoder.setVertexBuffer(buffers.perTriangle,
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.perTriangleData)
        encoder.setFragmentBuffer(buffers.uniforms,
                                 offset: 0,
                                 index: ScanGuidanceVertexDescriptor.BufferIndex.uniforms)

        let maxSafeIndices = buffers.index.length / MemoryLayout<UInt32>.stride
        let safeDrawIndexCount = min(indexCount, maxSafeIndices)
        guard safeDrawIndexCount > 0 else { return }
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: safeDrawIndexCount,
            indexType: .uint32,
            indexBuffer: buffers.index,
            indexBufferOffset: 0
        )
    }

    private func currentOverlayDepthStencilState() -> MTLDepthStencilState? {
        switch borderDepthMode {
        case .less:
            return overlayDepthStencilStateLess
        case .lessEqual:
            return overlayDepthStencilStateLessEqual
        }
    }

    private func uploadToBuffers(
        wedgeData: WedgeVertexData,
        lightState: LightState,
        flipAngles: [Float],
        rippleAmplitudes: [Float],
        borderWidths: [Float],
        borderAlphas: [Float],
        shaderThresholds: [ShaderThresholds],
        flipAxisData: [(origin: SIMD3<Float>, direction: SIMD3<Float>)],
        grayscaleColors: [(Float, Float, Float)],
        cameraTransform: simd_float4x4,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        qualityTier: Int
    ) {
        let bufferIndex = currentBufferIndex
        // Advance to next triple-buffer slot for the NEXT frame.
        // Without this, all frames write to slot 0 — CPU writes collide with
        // GPU reads on the same buffer, causing torn geometry and visual glitches.
        currentBufferIndex = (currentBufferIndex + 1) % Self.kMaxInflightBuffers
        bufferLock.lock()
        defer { bufferLock.unlock() }

        // Pre-compute per-triangle buffer safety before vertex/index writes.
        let perTriStride = 88  // 22 floats: style(13) + axisOrigin(3) + axisDir(3) + grayscale(3)
        let requestedTriCount = wedgeData.triangleCount
        let requiredPerTriSize = requestedTriCount * perTriStride
        if requiredPerTriSize > perTriangleBuffers[bufferIndex].length {
            let newSize = max(requiredPerTriSize, perTriangleBuffers[bufferIndex].length * 2)
            if let newBuffer = device.makeBuffer(length: newSize, options: []) {
                perTriangleBuffers[bufferIndex] = newBuffer
            }
        }
        let maxSafePerTriangleCount = perTriangleBuffers[bufferIndex].length / perTriStride
        let safePerTriangleCount = min(requestedTriCount, maxSafePerTriangleCount)
        if safePerTriangleCount <= 0 {
            self.lastWrittenBufferIndex = bufferIndex
            self.currentVertexCount = 0
            self.currentIndexCount = 0
            self.hasUnconsumedUpdate = true
            return
        }

        // CRITICAL: Do NOT publish lastWrittenBufferIndex yet!
        // encode() runs on the MTKView delegate thread and reads lastWrittenBufferIndex
        // to decide which buffer slot the GPU should draw from. If we publish the new
        // index here (before writing data), encode() will submit a draw call to a buffer
        // that the CPU is still filling → GPU reads half-written vertex/index/uniform
        // data → LLDB RPC server crash / GPU hang / visual corruption.
        // We publish AFTER all four buffer writes are complete (see end of method).

        // ── Vertex Buffer ──
        let vertexCount = wedgeData.vertices.count
        let stride = MemoryLayout<Float>.size * 10 + MemoryLayout<UInt32>.size  // 44 bytes
        let requiredVertexSize = vertexCount * stride

        // Grow buffer if needed
        if requiredVertexSize > vertexBuffers[bufferIndex].length {
            let newSize = max(requiredVertexSize, vertexBuffers[bufferIndex].length * 2)
            if let newBuffer = device.makeBuffer(length: newSize, options: []) {
                vertexBuffers[bufferIndex] = newBuffer
            }
        }

        // SAFETY CLAMP: ensure we don't write past buffer end
        let maxSafeVertexCount = vertexBuffers[bufferIndex].length / stride
        let safeVertexCount = min(vertexCount, maxSafeVertexCount)

        // Copy vertex data
        let vertexPtr = vertexBuffers[bufferIndex].contents()
        for i in 0..<safeVertexCount {
            let vertex = wedgeData.vertices[i]
            let base = vertexPtr + i * stride
            base.storeBytes(of: vertex.position.x, as: Float.self)
            (base + 4).storeBytes(of: vertex.position.y, as: Float.self)
            (base + 8).storeBytes(of: vertex.position.z, as: Float.self)
            (base + 12).storeBytes(of: vertex.normal.x, as: Float.self)
            (base + 16).storeBytes(of: vertex.normal.y, as: Float.self)
            (base + 20).storeBytes(of: vertex.normal.z, as: Float.self)
            (base + 24).storeBytes(of: vertex.metallic, as: Float.self)
            (base + 28).storeBytes(of: vertex.roughness, as: Float.self)
            (base + 32).storeBytes(of: vertex.display, as: Float.self)
            (base + 36).storeBytes(of: vertex.thickness, as: Float.self)
            let maxSafeTriId = UInt32(max(0, safePerTriangleCount - 1))
            let clampedTriId = min(vertex.triangleId, maxSafeTriId)
            (base + 40).storeBytes(of: clampedTriId, as: UInt32.self)
        }

        // ── Index Buffer ──
        let indexCount = wedgeData.indices.count
        let requiredIndexSize = indexCount * MemoryLayout<UInt32>.stride

        if requiredIndexSize > indexBuffers[bufferIndex].length {
            let newSize = max(requiredIndexSize, indexBuffers[bufferIndex].length * 2)
            if let newBuffer = device.makeBuffer(length: newSize, options: []) {
                indexBuffers[bufferIndex] = newBuffer
            }
        }

        // SAFETY CLAMP: if buffer growth failed (nil from makeBuffer), clamp indices
        // to what the current buffer can hold. Prevents Metal validation crash:
        // "indexBufferOffset + indexCount * 4 must be <= indexBuffer.length"
        let maxSafeIndexCount = indexBuffers[bufferIndex].length / MemoryLayout<UInt32>.stride
        let safeIndexCount = min(indexCount, maxSafeIndexCount)

        // VERTEX-INDEX COHERENCE: if vertices were clamped (safeVertexCount < vertexCount),
        // some indices may reference vertex IDs >= safeVertexCount. The GPU would read
        // uninitialized vertex memory, causing garbage rendering or validation crashes.
        // Solution: copy indices but clamp any out-of-range vertex references.
        if safeIndexCount > 0 {
            let maxVertexId = UInt32(max(0, safeVertexCount - 1))
            let ibPtr = indexBuffers[bufferIndex].contents().bindMemory(to: UInt32.self, capacity: safeIndexCount)
            for i in 0..<safeIndexCount {
                let idx = wedgeData.indices[i]
                ibPtr[i] = min(idx, maxVertexId)
            }
        }

        // ── Uniform Buffer ──
        // v7.0.3 FIX: Removed _pad0 — Metal float3 in struct is 16-byte aligned,
        // and Swift SIMD3<Float> also has 16-byte stride, so no manual padding needed
        // between consecutive SIMD3<Float> fields. _pad0 was SHIFTING all downstream
        // fields by 4 bytes, causing Metal↔Swift memory layout mismatch.
        //
        // Metal layout:
        //   offset 0:   viewProjectionMatrix (float4x4, 64 bytes)
        //   offset 64:  modelMatrix (float4x4, 64 bytes)
        //   offset 128: cameraPosition (float3, 16 bytes with padding)
        //   offset 144: primaryLightDirection (float3, 16 bytes with padding)
        //   offset 160: primaryLightIntensity (float, 4 bytes)
        //   offset 164: [12 bytes padding to align float3 array]
        //   offset 176: shCoeffs[9] (9 × float3 = 9 × 16 = 144 bytes)
        //   offset 320: qualityTier (uint, 4 bytes)
        //   offset 324: time (float, 4 bytes)
        //   offset 328: borderGamma (float, 4 bytes)
        //   offset 332: [4 bytes padding to align struct to 16]
        //   Total: 336 bytes
        struct GPUUniforms {
            var viewProjectionMatrix: simd_float4x4      // offset 0
            var modelMatrix: simd_float4x4               // offset 64
            var cameraPosition: SIMD3<Float>             // offset 128 (stride 16)
            var primaryLightDirection: SIMD3<Float>      // offset 144 (stride 16)
            var primaryLightIntensity: Float             // offset 160
            // [12 bytes implicit padding to align SIMD3<Float> to 16 bytes]
            var shCoeffs: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>,
                           SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)  // offset 176
            var qualityTier: UInt32                      // offset 320
            var time: Float                             // offset 324
            var borderGamma: Float                      // offset 328
            var _pad1: Float = 0                        // offset 332 (align to 336)
        }
        // Layer 4.5: Compile-time assertion to catch layout mismatches between
        // Swift GPUUniforms and Metal ScanGuidanceUniforms. Any change to either
        // side must keep them in sync — a mismatch silently corrupts SH lighting.
        assert(MemoryLayout<GPUUniforms>.size == 336,
               "GPUUniforms size mismatch: expected 336 bytes, got \(MemoryLayout<GPUUniforms>.size)")
        
        // Extract camera position from transform
        let camPos = SIMD3<Float>(cameraTransform.columns.3.x,
                                   cameraTransform.columns.3.y,
                                   cameraTransform.columns.3.z)
        
        // Build SH coefficients tuple
        let sh = lightState.shCoeffs
        let shTuple = (
            sh.count > 0 ? sh[0] : SIMD3<Float>(0,0,0),
            sh.count > 1 ? sh[1] : SIMD3<Float>(0,0,0),
            sh.count > 2 ? sh[2] : SIMD3<Float>(0,0,0),
            sh.count > 3 ? sh[3] : SIMD3<Float>(0,0,0),
            sh.count > 4 ? sh[4] : SIMD3<Float>(0,0,0),
            sh.count > 5 ? sh[5] : SIMD3<Float>(0,0,0),
            sh.count > 6 ? sh[6] : SIMD3<Float>(0,0,0),
            sh.count > 7 ? sh[7] : SIMD3<Float>(0,0,0),
            sh.count > 8 ? sh[8] : SIMD3<Float>(0,0,0)
        )
        
        var uniforms = GPUUniforms(
            viewProjectionMatrix: projectionMatrix * viewMatrix,
            modelMatrix: matrix_identity_float4x4,
            cameraPosition: camPos,
            primaryLightDirection: lightState.direction,
            primaryLightIntensity: lightState.intensity,
            shCoeffs: shTuple,
            qualityTier: UInt32(qualityTier),
            time: Float(CACurrentMediaTime()),
            borderGamma: Float(ScanGuidanceConstants.borderGamma)
        )
        
        // v7.0.3: Use .stride (not .size) to include trailing padding for Metal alignment
        memcpy(uniformBuffers[bufferIndex].contents(), &uniforms, MemoryLayout<GPUUniforms>.stride)
        
        // ── Per-Triangle Data Buffer ──
        let triPtr = perTriangleBuffers[bufferIndex].contents()
        for i in 0..<safePerTriangleCount {
            let base = triPtr + i * perTriStride
            
            // flipAngle
            let flipAngle: Float = i < flipAngles.count ? flipAngles[i] : 0.0
            base.storeBytes(of: flipAngle, as: Float.self)
            
            // rippleAmplitude
            let rippleAmp: Float = i < rippleAmplitudes.count ? rippleAmplitudes[i] : 0.0
            (base + 4).storeBytes(of: rippleAmp, as: Float.self)
            
            // borderWidth
            let bw: Float = i < borderWidths.count ? borderWidths[i] : 0.0
            (base + 8).storeBytes(of: bw, as: Float.self)

            // borderAlpha
            let ba: Float = i < borderAlphas.count ? borderAlphas[i] : 0.0
            (base + 12).storeBytes(of: ba, as: Float.self)

            let thresholds: ShaderThresholds = i < shaderThresholds.count
                ? shaderThresholds[i]
                : (
                    rippleMinAmplitude: 0.0,
                    rippleBoostScale: 0.0,
                    fillDitherStart: 0.0,
                    fillDitherEnd: 0.0,
                    borderMinWidth: 0.0,
                    borderMinAlpha: 0.0,
                    borderAAFactor: 0.0,
                    borderFwidthEpsilon: 0.0,
                    borderDiscardAlpha: 0.0
                )
            (base + 16).storeBytes(of: thresholds.rippleMinAmplitude, as: Float.self)
            (base + 20).storeBytes(of: thresholds.rippleBoostScale, as: Float.self)
            (base + 24).storeBytes(of: thresholds.fillDitherStart, as: Float.self)
            (base + 28).storeBytes(of: thresholds.fillDitherEnd, as: Float.self)
            (base + 32).storeBytes(of: thresholds.borderMinWidth, as: Float.self)
            (base + 36).storeBytes(of: thresholds.borderMinAlpha, as: Float.self)
            (base + 40).storeBytes(of: thresholds.borderAAFactor, as: Float.self)
            (base + 44).storeBytes(of: thresholds.borderFwidthEpsilon, as: Float.self)
            (base + 48).storeBytes(of: thresholds.borderDiscardAlpha, as: Float.self)
            
            // flipAxisOrigin (3 floats, packed_float3)
            let axisOrigin = i < flipAxisData.count ? flipAxisData[i].origin : SIMD3<Float>(0,0,0)
            (base + 52).storeBytes(of: axisOrigin.x, as: Float.self)
            (base + 56).storeBytes(of: axisOrigin.y, as: Float.self)
            (base + 60).storeBytes(of: axisOrigin.z, as: Float.self)
            
            // flipAxisDirection (3 floats, packed_float3)
            let axisDir = i < flipAxisData.count ? flipAxisData[i].direction : SIMD3<Float>(1,0,0)
            (base + 64).storeBytes(of: axisDir.x, as: Float.self)
            (base + 68).storeBytes(of: axisDir.y, as: Float.self)
            (base + 72).storeBytes(of: axisDir.z, as: Float.self)
            
            // grayscaleColor (3 floats, packed_float3)
            let grayColor = i < grayscaleColors.count ? grayscaleColors[i] : (Float(0.5), Float(0.5), Float(0.5))
            (base + 76).storeBytes(of: grayColor.0, as: Float.self)
            (base + 80).storeBytes(of: grayColor.1, as: Float.self)
            (base + 84).storeBytes(of: grayColor.2, as: Float.self)
        }

        // ── ATOMIC PUBLISH ──
        // ALL four buffers (vertex, index, uniform, perTriangle) for this slot are
        // now fully written. Publish the new state under a single lock so encode()
        // sees a consistent snapshot: either the PREVIOUS frame's data (all old) or
        // THIS frame's data (all new). Never a mix of old counts with new buffers
        // or vice versa.
        //
        // This is the fix for the LLDB RPC server crash: previously,
        // lastWrittenBufferIndex was set at the TOP of this method, so encode()
        // could submit a draw call referencing a buffer mid-write.
        self.lastWrittenBufferIndex = bufferIndex
        self.currentVertexCount = safeVertexCount
        self.currentIndexCount = safeIndexCount
        self.hasUnconsumedUpdate = true
    }

    private func normalizePerTriangleArray(
        _ values: [Float],
        triangleCount: Int
    ) -> [Float] {
        guard triangleCount > 0 else { return [] }
        if values.count == triangleCount {
            return values
        }
        if values.count > triangleCount {
            return Array(values.prefix(triangleCount))
        }
        return values + Array(repeating: 0, count: triangleCount - values.count)
    }

    private func normalizeShaderThresholdData(
        _ values: [ShaderThresholds],
        triangleCount: Int
    ) -> [ShaderThresholds] {
        guard triangleCount > 0 else { return [] }
        if values.count == triangleCount {
            return values
        }
        if values.count > triangleCount {
            return Array(values.prefix(triangleCount))
        }
        let fallback: ShaderThresholds = (
            rippleMinAmplitude: 0.0,
            rippleBoostScale: 0.0,
            fillDitherStart: 0.0,
            fillDitherEnd: 0.0,
            borderMinWidth: 0.0,
            borderMinAlpha: 0.0,
            borderAAFactor: 0.0,
            borderFwidthEpsilon: 0.0,
            borderDiscardAlpha: 0.0
        )
        return values + Array(repeating: fallback, count: triangleCount - values.count)
    }

    private func expandPerTriangleValues(
        _ values: [Float],
        parentIndices: [Int],
        triangleCount: Int
    ) -> [Float] {
        guard triangleCount > 0 else { return [] }
        guard parentIndices.count == triangleCount else {
            return normalizePerTriangleArray(values, triangleCount: triangleCount)
        }
        var expanded = Array(repeating: Float(0), count: triangleCount)
        for i in 0..<triangleCount {
            let parent = parentIndices[i]
            if parent >= 0, parent < values.count {
                expanded[i] = values[parent]
            }
        }
        return expanded
    }

    private func expandFlipAxisData(
        _ data: [(origin: SIMD3<Float>, direction: SIMD3<Float>)]?,
        parentIndices: [Int],
        triangleCount: Int
    ) -> [(origin: SIMD3<Float>, direction: SIMD3<Float>)] {
        guard triangleCount > 0 else { return [] }
        var expanded = Array(
            repeating: (origin: SIMD3<Float>(0, 0, 0), direction: SIMD3<Float>(1, 0, 0)),
            count: triangleCount
        )
        guard let data, !data.isEmpty else { return expanded }
        guard parentIndices.count == triangleCount else {
            for i in 0..<min(data.count, triangleCount) {
                expanded[i] = data[i]
            }
            return expanded
        }
        for i in 0..<triangleCount {
            let parent = parentIndices[i]
            if parent >= 0, parent < data.count {
                expanded[i] = data[parent]
            }
        }
        return expanded
    }

    private func normalizeGrayscaleColors(
        _ colors: [(Float, Float, Float)],
        triangleCount: Int
    ) -> [(Float, Float, Float)] {
        guard triangleCount > 0 else { return [] }
        var normalized = Array(repeating: (Float(0), Float(0), Float(0)), count: triangleCount)
        for i in 0..<min(colors.count, triangleCount) {
            normalized[i] = colors[i]
        }
        return normalized
    }
}

/// Scan Guidance Error
public enum ScanGuidanceError: Error {
    case deviceInitializationFailed
    case pipelineCreationFailed(String)
    case bufferAllocationFailed
}

#endif
