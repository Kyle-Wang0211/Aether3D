//
// ScanGuidanceRenderPipeline.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Metal Render Pipeline
// Metal 6-pass render orchestrator with triple buffering
// Apple-platform only (import Metal)
// Phase 2: Implements wedge fill + border passes only
//

#if canImport(Metal)
import Metal
import MetalKit
import simd
import QuartzCore  // for CACurrentMediaTime — OK in App/

public final class ScanGuidanceRenderPipeline {

    public static let kMaxInflightBuffers: Int = ScanGuidanceConstants.kMaxInflightBuffers
    private let inflightSemaphore: DispatchSemaphore
    private var currentBufferIndex: Int = 0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var wedgeFillPipeline: MTLRenderPipelineState!
    private var borderStrokePipeline: MTLRenderPipelineState!
    // Phase 2: Metallic lighting pipeline not implemented yet
    // private var metallicLightingPipeline: MTLRenderPipelineState!

    // Sub-systems (Core/ pure algorithms)
    private let wedgeGenerator: WedgeGeometryGenerator
    private let flipController: FlipAnimationController
    private let rippleEngine: RipplePropagationEngine
    private let borderCalculator: AdaptiveBorderCalculator
    private let thermalAdapter: ThermalQualityAdapter

    // Sub-systems (App/ platform-specific)
    private let lightEstimator: EnvironmentLightEstimator
    private let grayscaleMapper: GrayscaleMapper

    // Triple-buffered Metal buffers
    private var vertexBuffers: [MTLBuffer] = []
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
        self.lightEstimator = EnvironmentLightEstimator()
        self.flipController = FlipAnimationController()
        self.rippleEngine = RipplePropagationEngine()
        self.borderCalculator = AdaptiveBorderCalculator()
        self.thermalAdapter = ThermalQualityAdapter()
        self.grayscaleMapper = GrayscaleMapper()
        
        // Initialize triple buffers
        for _ in 0..<Self.kMaxInflightBuffers {
            vertexBuffers.append(device.makeBuffer(length: 1024 * 1024, options: [])!)  // 1MB initial
            uniformBuffers.append(device.makeBuffer(length: 1024, options: [])!)  // 1KB
            perTriangleBuffers.append(device.makeBuffer(length: 64 * 1024, options: [])!)  // 64KB
        }
        
        // Create render pipeline states
        try createRenderPipelines()
    }

    /// Per-frame update — reads from PatchDisplayMap snapshot, no coverage dependency
    /// v7.0.2: displaySnapshot is [String: Double], converted from [DisplayEntry]
    ///         by caller (see Part A.2 for conversion pattern)
    /// Phase 5: Integrated thermal control
    public func update(
        displaySnapshot: [String: Double],
        colorStates: [String: ColorState],
        meshTriangles: [ScanTriangle],
        lightEstimate: Any?,  // ARLightEstimate on iOS
        cameraTransform: simd_float4x4,
        frameDeltaTime: TimeInterval,
        gpuDurationMs: Double? = nil
    ) {
        // Update thermal adapter with frame timing
        if let gpuDuration = gpuDurationMs {
            thermalAdapter.updateFrameTiming(gpuDurationMs: gpuDuration)
        }
        
        let tier = thermalAdapter.currentTier
        let lodLevel = tier.lodLevel
        
        // Limit triangles based on thermal tier
        let maxTriangles = tier.maxTriangles
        let limitedTriangles = Array(meshTriangles.prefix(maxTriangles))

        let wedgeData = wedgeGenerator.generate(
            triangles: limitedTriangles,
            displayValues: displaySnapshot,
            lod: lodLevel
        )

        let lightState = lightEstimator.update(
            lightEstimate: lightEstimate,
            cameraImage: nil,
            timestamp: CACurrentMediaTime()
        )

        // Phase 3: Animations (disabled at critical tier)
        let flipAngles: [Float]
        let rippleAmplitudes: [Float]
        
        if tier.enableFlipAnimation {
            flipAngles = flipController.tick(deltaTime: frameDeltaTime)
        } else {
            flipAngles = []
        }
        
        if tier.enableRipple {
            rippleAmplitudes = rippleEngine.tick(currentTime: CACurrentMediaTime())
        } else {
            rippleAmplitudes = []
        }
        
        let medianArea: Float = limitedTriangles.isEmpty ? 1.0 : limitedTriangles.map { $0.areaSqM }.sorted()[limitedTriangles.count / 2]
        let borderWidths = borderCalculator.calculate(
            displayValues: displaySnapshot,
            triangles: limitedTriangles,
            medianArea: medianArea
        )

        uploadToBuffers(
            wedgeData: wedgeData,
            lightState: lightState,
            flipAngles: flipAngles,
            rippleAmplitudes: rippleAmplitudes,
            borderWidths: borderWidths,
            cameraTransform: cameraTransform,
            qualityTier: tier.rawValue
        )
    }

    /// Encode all render passes into command buffer
    /// Phase 2: Only encodes wedge fill + border stroke passes
    public func encode(
        into commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        inflightSemaphore.wait()
        commandBuffer.addCompletedHandler { [weak self] _ in
            self?.inflightSemaphore.signal()
        }
        let bufferIndex = currentBufferIndex
        currentBufferIndex = (currentBufferIndex + 1) % Self.kMaxInflightBuffers

        guard let encoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else { return }

        encodeWedgeFill(encoder: encoder, bufferIndex: bufferIndex)
        encodeBorderStroke(encoder: encoder, bufferIndex: bufferIndex)
        // Phase 2: Metallic lighting pass not implemented
        // encodeMetallicLighting(encoder: encoder, bufferIndex: bufferIndex)
        encoder.endEncoding()
    }

    public func applyRenderTier(_ tier: ThermalQualityAdapter.RenderTier) {
        thermalAdapter.forceRenderTier(tier)
    }

    // MARK: - Private Methods

    private func createRenderPipelines() throws {
        // Phase 2: Create wedge fill and border stroke pipelines
        // Implementation will be completed when Metal shaders are ready
        fatalError("createRenderPipelines() not implemented in Phase 2")
    }

    private func encodeWedgeFill(encoder: MTLRenderCommandEncoder, bufferIndex: Int) {
        // Phase 2: Encode wedge fill pass
        // Implementation will be completed when Metal shaders are ready
    }

    private func encodeBorderStroke(encoder: MTLRenderCommandEncoder, bufferIndex: Int) {
        // Phase 2: Encode border stroke pass
        // Implementation will be completed when Metal shaders are ready
    }

    private func uploadToBuffers(
        wedgeData: WedgeVertexData,
        lightState: EnvironmentLightEstimator.LightState,
        flipAngles: [Float],
        rippleAmplitudes: [Float],
        borderWidths: [Float],
        cameraTransform: simd_float4x4,
        qualityTier: Int
    ) {
        // Phase 5: Upload data to Metal buffers with quality tier
        // Implementation will be completed when Metal shaders are ready
    }
}

/// Scan Guidance Error
public enum ScanGuidanceError: Error {
    case deviceInitializationFailed
    case pipelineCreationFailed(String)
    case bufferAllocationFailed
}

#endif
