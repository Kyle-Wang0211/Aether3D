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
    private var depthStencilState: MTLDepthStencilState!
    private var currentVertexCount: Int = 0

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
        
        // Create depth stencil state
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)
    }

    /// Per-frame update — reads from PatchDisplayMap snapshot, no coverage dependency
    /// v7.0.2: displaySnapshot is [String: Double], converted from [DisplayEntry]
    ///         by caller (see Part A.2 for conversion pattern)
    /// v7.0.3: Always maximum quality — thermal tier used for telemetry only,
    ///         never for LOD/triangle/animation decisions
    public func update(
        displaySnapshot: [String: Double],
        colorStates: [String: ColorState],
        meshTriangles: [ScanTriangle],
        lightEstimate: Any?,  // ARLightEstimate on iOS
        cameraTransform: simd_float4x4,
        frameDeltaTime: TimeInterval,
        gpuDurationMs: Double? = nil
    ) {
        // Update thermal adapter for telemetry only (no rendering decisions)
        if let gpuDuration = gpuDurationMs {
            thermalAdapter.updateFrameTiming(gpuDurationMs: gpuDuration)
        }

        // v7.0.3: Always maximum quality — use all triangles and LOD0
        let allTriangles = meshTriangles

        let wedgeData = wedgeGenerator.generate(
            triangles: allTriangles,
            displayValues: displaySnapshot,
            lod: .full  // Always LOD0 (2-segment bevel)
        )

        let lightState = lightEstimator.update(
            lightEstimate: lightEstimate,
            cameraImage: nil,
            timestamp: CACurrentMediaTime()
        )

        // v7.0.3: Animations always enabled at maximum quality
        let flipAngles = flipController.getFlipAngles(for: Array(0..<allTriangles.count))
        _ = flipController.tick(deltaTime: frameDeltaTime)  // Advance animation state

        let rippleAmplitudes = rippleEngine.getRippleAmplitudes(
            for: Array(0..<allTriangles.count),
            currentTime: CACurrentMediaTime()
        )
        _ = rippleEngine.tick(currentTime: CACurrentMediaTime())  // Advance wave state

        let medianArea: Float = allTriangles.isEmpty ? 1.0 : allTriangles.map { $0.areaSqM }.sorted()[allTriangles.count / 2]
        let borderWidths = borderCalculator.calculate(
            displayValues: displaySnapshot,
            triangles: allTriangles,
            medianArea: medianArea
        )

        // Compute per-triangle flip axis data
        var flipAxisData: [(origin: SIMD3<Float>, direction: SIMD3<Float>)] = []
        for i in 0..<allTriangles.count {
            if let axis = flipController.getFlipAxis(for: i) {
                flipAxisData.append(axis)
            } else {
                flipAxisData.append((SIMD3<Float>(0,0,0), SIMD3<Float>(1,0,0)))
            }
        }

        // Compute per-triangle grayscale colors
        var grayscaleColors: [(Float, Float, Float)] = []
        for triangle in allTriangles {
            let display = displaySnapshot[triangle.patchId] ?? 0.0
            let (r, g, b) = grayscaleMapper.grayscale(for: display)
            grayscaleColors.append((r, g, b))
        }

        uploadToBuffers(
            wedgeData: wedgeData,
            lightState: lightState,
            flipAngles: flipAngles,
            rippleAmplitudes: rippleAmplitudes,
            borderWidths: borderWidths,
            flipAxisData: flipAxisData,
            grayscaleColors: grayscaleColors,
            cameraTransform: cameraTransform,
            qualityTier: 0  // Always nominal tier for shader
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
    }

    private func encodeWedgeFill(encoder: MTLRenderCommandEncoder, bufferIndex: Int) {
        guard wedgeFillPipeline != nil else { return }
        
        encoder.setRenderPipelineState(wedgeFillPipeline)
        encoder.setCullMode(.back)
        encoder.setDepthStencilState(depthStencilState)
        
        // Bind buffers
        encoder.setVertexBuffer(vertexBuffers[bufferIndex],
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.vertexData)
        encoder.setVertexBuffer(uniformBuffers[bufferIndex],
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.uniforms)
        encoder.setVertexBuffer(perTriangleBuffers[bufferIndex],
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.perTriangleData)
        
        // Fragment buffers
        encoder.setFragmentBuffer(uniformBuffers[bufferIndex],
                                 offset: 0,
                                 index: ScanGuidanceVertexDescriptor.BufferIndex.uniforms)
        
        // Draw indexed primitives
        if currentVertexCount > 0 {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentVertexCount)
        }
    }

    private func encodeBorderStroke(encoder: MTLRenderCommandEncoder, bufferIndex: Int) {
        guard borderStrokePipeline != nil else { return }
        
        encoder.setRenderPipelineState(borderStrokePipeline)
        encoder.setCullMode(.back)
        
        // Same buffer bindings as wedge fill
        encoder.setVertexBuffer(vertexBuffers[bufferIndex],
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.vertexData)
        encoder.setVertexBuffer(uniformBuffers[bufferIndex],
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.uniforms)
        encoder.setVertexBuffer(perTriangleBuffers[bufferIndex],
                               offset: 0,
                               index: ScanGuidanceVertexDescriptor.BufferIndex.perTriangleData)
        encoder.setFragmentBuffer(uniformBuffers[bufferIndex],
                                 offset: 0,
                                 index: ScanGuidanceVertexDescriptor.BufferIndex.uniforms)
        
        if currentVertexCount > 0 {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: currentVertexCount)
        }
    }

    private func uploadToBuffers(
        wedgeData: WedgeVertexData,
        lightState: LightState,
        flipAngles: [Float],
        rippleAmplitudes: [Float],
        borderWidths: [Float],
        flipAxisData: [(origin: SIMD3<Float>, direction: SIMD3<Float>)],
        grayscaleColors: [(Float, Float, Float)],
        cameraTransform: simd_float4x4,
        qualityTier: Int
    ) {
        let bufferIndex = currentBufferIndex
        
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
        
        // Copy vertex data
        let vertexPtr = vertexBuffers[bufferIndex].contents()
        for (i, vertex) in wedgeData.vertices.enumerated() {
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
            (base + 40).storeBytes(of: vertex.triangleId, as: UInt32.self)
        }
        
        self.currentVertexCount = vertexCount
        
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
            var shCoeffs: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>,
                           SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)  // offset 176
            var qualityTier: UInt32                      // offset 320
            var time: Float                             // offset 324
            var borderGamma: Float                      // offset 328
            var _pad1: Float = 0                        // offset 332 (align to 336)
        }
        
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
            viewProjectionMatrix: cameraTransform,
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
        let triCount = wedgeData.triangleCount
        let perTriStride = 48  // 12 floats: flipAngle(1) + rippleAmplitude(1) + borderWidth(1) + flipAxisOrigin(3) + flipAxisDirection(3) + grayscaleColor(3) = 12 floats = 48 bytes
        let requiredPerTriSize = triCount * perTriStride
        
        if requiredPerTriSize > perTriangleBuffers[bufferIndex].length {
            let newSize = max(requiredPerTriSize, perTriangleBuffers[bufferIndex].length * 2)
            if let newBuffer = device.makeBuffer(length: newSize, options: []) {
                perTriangleBuffers[bufferIndex] = newBuffer
            }
        }
        
        let triPtr = perTriangleBuffers[bufferIndex].contents()
        for i in 0..<triCount {
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
            
            // flipAxisOrigin (3 floats, packed_float3)
            let axisOrigin = i < flipAxisData.count ? flipAxisData[i].origin : SIMD3<Float>(0,0,0)
            (base + 12).storeBytes(of: axisOrigin.x, as: Float.self)
            (base + 16).storeBytes(of: axisOrigin.y, as: Float.self)
            (base + 20).storeBytes(of: axisOrigin.z, as: Float.self)
            
            // flipAxisDirection (3 floats, packed_float3)
            let axisDir = i < flipAxisData.count ? flipAxisData[i].direction : SIMD3<Float>(1,0,0)
            (base + 24).storeBytes(of: axisDir.x, as: Float.self)
            (base + 28).storeBytes(of: axisDir.y, as: Float.self)
            (base + 32).storeBytes(of: axisDir.z, as: Float.self)
            
            // grayscaleColor (3 floats, packed_float3)
            let grayColor = i < grayscaleColors.count ? grayscaleColors[i] : (Float(0.5), Float(0.5), Float(0.5))
            (base + 36).storeBytes(of: grayColor.0, as: Float.self)
            (base + 40).storeBytes(of: grayColor.1, as: Float.self)
            (base + 44).storeBytes(of: grayColor.2, as: Float.self)
        }
    }
}

/// Scan Guidance Error
public enum ScanGuidanceError: Error {
    case deviceInitializationFailed
    case pipelineCreationFailed(String)
    case bufferAllocationFailed
}

#endif
