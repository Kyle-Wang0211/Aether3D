//
// PointCloudOIRPipeline.swift
// Aether3D
//
// Point Cloud + Order-Independent 3DGS Rendering Pipeline.
// Replaces ScanGuidanceRenderPipeline (wedge-based guidance).
//
// Architecture:
//   Pass 1: Point cloud rendering (instanced point sprites, DAv2 depth)
//   Pass 2: OIR 3DGS accumulation (Weighted Blended OIT, no sort)
//   Pass 3: OIR composite (full-screen triangle, final output)
//
// Memory: ~10MB GPU (vs ~39MB for wedge system)
// GPU time: ~3ms total (point cloud 0.5ms + OIR 2.5ms)
//

import Foundation
#if canImport(simd)
import simd
#endif

#if canImport(Metal)
import Metal

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Protocol Conformance
// ═══════════════════════════════════════════════════════════════════════

/// Minimal overlay encoder protocol matching ScanGuidanceOverlayEncoder.
/// ARCameraPreview.Coordinator calls encode(into:renderPassDescriptor:).
public protocol OverlayEncodable: AnyObject {
    func encode(
        into commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    )
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - Uniform Types (match Metal shader structs)
// ═══════════════════════════════════════════════════════════════════════

// IMPORTANT: Uses individual Float fields (NOT SIMD3<Float>) to guarantee
// byte-identical layout with Metal's packed_float3. SIMD3<Float> in Swift
// is backed by SIMD4 storage (16 bytes), but Metal's packed_float3 is 12 bytes.
// Using scalar Floats: each field = 4 bytes → layout matches Metal exactly.
// Total: 112 bytes (matches Metal struct size).
struct PointCloudUniforms {
    var viewProjection: simd_float4x4 = matrix_identity_float4x4  // 64 bytes @ 0
    var globalAlpha: Float = 1.0       // 4 bytes @ 64
    var pointSizeScale: Float = 2.0    // 4 bytes @ 68
    var _pad0: Float = 0               // 4 bytes @ 72
    var _pad1: Float = 0               // 4 bytes @ 76
    var cameraPositionX: Float = 0     // 4 bytes @ 80   ─┐
    var cameraPositionY: Float = 0     // 4 bytes @ 84    │ packed_float3 cameraPosition
    var cameraPositionZ: Float = 0     // 4 bytes @ 88   ─┘
    var _pad2: Float = 0               // 4 bytes @ 92
    var cameraBackX: Float = 0         // 4 bytes @ 96   ─┐
    var cameraBackY: Float = 0         // 4 bytes @ 100   │ packed_float3 cameraBack
    var cameraBackZ: Float = 0         // 4 bytes @ 104  ─┘
    var _pad3: Float = 0               // 4 bytes @ 108
}

struct OIRCameraUniforms {
    var viewMatrix: simd_float4x4 = matrix_identity_float4x4
    var projMatrix: simd_float4x4 = matrix_identity_float4x4
    var viewProjMatrix: simd_float4x4 = matrix_identity_float4x4
    var focal: SIMD2<Float> = .zero
    var viewport: SIMD2<Float> = .zero
    var nearPlane: Float = 0.001
    var farPlane: Float = 1000.0
}

// ═══════════════════════════════════════════════════════════════════════
// MARK: - PointCloudOIRPipeline
// ═══════════════════════════════════════════════════════════════════════

public final class PointCloudOIRPipeline: OverlayEncodable {

    // ─── Constants ───
    private static let kMaxInflightBuffers = 3
    private static let kMaxPointCloudVertices: Int = 300_000  // Match C++ 500K cap; GPU renders up to 300K
    private static let kPointCloudVertexStride = 32    // packed_float3 + packed_float3 + float + float
    private static let kMaxSplats: Int = 500_000
    private static let kSplatStride = 16               // OIRPackedSplat = 16 bytes
    private static let kMaxOverlayVertices: Int = 50_000 // Match C++ kMaxOverlayPoints (1 per TSDF block)
    private static let kOverlayVertexStride = 32       // float3 pos + float3 normal + float size + float alpha

    // ─── Device ───
    private let device: MTLDevice

    // ─── Pipeline States ───
    private var pointCloudPSO: MTLRenderPipelineState?
    private var overlayPSO: MTLRenderPipelineState?
    private var oirAccumPSO: MTLRenderPipelineState?
    private var oirCompositePSO: MTLRenderPipelineState?
    private var depthWriteState: MTLDepthStencilState?
    private var depthReadState: MTLDepthStencilState?
    private var depthDisabledState: MTLDepthStencilState?

    // ─── OIR Off-screen Textures ───
    private var accumTexture: MTLTexture?
    private var revealTexture: MTLTexture?
    private var currentTextureSize: SIMD2<Int> = .zero

    // ─── Triple-Buffered Data ───
    private let inflightSemaphore: DispatchSemaphore
    private var currentBufferIndex: Int = 0

    // Per-slot: pointCloudBuffer, splatBuffer, overlayBuffer, pcUniformBuffer, oirUniformBuffer
    private var pointCloudBuffers: [MTLBuffer] = []
    private var splatBuffers: [MTLBuffer] = []
    private var overlayBuffers: [MTLBuffer] = []
    private var pcUniformBuffers: [MTLBuffer] = []
    private var oirUniformBuffers: [MTLBuffer] = []

    // ─── Thread-safe State (main writes, MTKView reads) ───
    private let bufferLock = NSLock()
    private var lastWrittenBufferIndex: Int = 0
    private var lastPointCloudCount: Int = 0
    private var lastSplatCount: Int = 0
    private var lastOverlayCount: Int = 0
    private var hasUnconsumedUpdate: Bool = false

    // ─── Debug: Encode call counter (read from ScanViewModel for diagnostics) ───
    public private(set) var debugEncodeDrawCount: Int = 0
    public private(set) var debugEncodeSkipCount: Int = 0
    private var debugOverlayPSONilCount: Int = 0
    private var debugOverlayDrawLogCount: Int = 0
    private var debugUpdateLogCount: Int = 0
    private var pendingSemaphoreWaitCount: Int = 0
    private var isShutDown: Bool = false

    // ─── Synchronous Camera Pose (eliminates Task { @MainActor } latency) ───
    // Written by ARSession delegate (may be on any queue), read by draw().
    // This ensures overlay viewProjection always matches the displayed camera feed.
    private let poseLock = NSLock()
    private var latestViewMatrix: simd_float4x4 = matrix_identity_float4x4
    private var latestProjMatrix: simd_float4x4 = matrix_identity_float4x4
    private var hasSyncPose: Bool = false

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Init
    // ═══════════════════════════════════════════════════════════════════════

    public init(device: MTLDevice) throws {
        self.device = device
        self.inflightSemaphore = DispatchSemaphore(value: Self.kMaxInflightBuffers)

        // Allocate triple-buffered Metal buffers
        let pcBufSize = Self.kMaxPointCloudVertices * Self.kPointCloudVertexStride
        let splatBufSize = Self.kMaxSplats * Self.kSplatStride
        let overlayBufSize = Self.kMaxOverlayVertices * Self.kOverlayVertexStride

        for _ in 0..<Self.kMaxInflightBuffers {
            guard let pcBuf = device.makeBuffer(length: pcBufSize, options: .storageModeShared),
                  let splatBuf = device.makeBuffer(length: splatBufSize, options: .storageModeShared),
                  let overlayBuf = device.makeBuffer(length: overlayBufSize, options: .storageModeShared),
                  let pcUni = device.makeBuffer(length: MemoryLayout<PointCloudUniforms>.stride, options: .storageModeShared),
                  let oirUni = device.makeBuffer(length: MemoryLayout<OIRCameraUniforms>.stride, options: .storageModeShared)
            else {
                throw NSError(domain: "PointCloudOIRPipeline", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to allocate Metal buffers"])
            }
            pcBuf.label = "PointCloud Vertices"
            splatBuf.label = "OIR Splats"
            overlayBuf.label = "Quality Overlay"
            pcUni.label = "PointCloud Uniforms"
            oirUni.label = "OIR Uniforms"

            pointCloudBuffers.append(pcBuf)
            splatBuffers.append(splatBuf)
            overlayBuffers.append(overlayBuf)
            pcUniformBuffers.append(pcUni)
            oirUniformBuffers.append(oirUni)
        }

        // Build pipeline states
        try buildPipelineStates()
        buildDepthStencilStates()

        // ─── Pipeline creation diagnostic ───
        NSLog("[Aether3D][OverlayPipeline] PSO status: pointCloud=%@, overlay=%@, oirAccum=%@, oirComposite=%@",
              pointCloudPSO != nil ? "OK" : "NIL",
              overlayPSO != nil ? "OK" : "NIL",
              oirAccumPSO != nil ? "OK" : "NIL",
              oirCompositePSO != nil ? "OK" : "NIL")
        // Struct alignment verification (should be 112 size, 112 stride for Metal match)
        NSLog("[Aether3D][OverlayPipeline] PointCloudUniforms: size=%d stride=%d alignment=%d (Metal expects 112 bytes)",
              MemoryLayout<PointCloudUniforms>.size,
              MemoryLayout<PointCloudUniforms>.stride,
              MemoryLayout<PointCloudUniforms>.alignment)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Synchronous Camera Pose Update (zero-latency overlay tracking)
    // ═══════════════════════════════════════════════════════════════════════

    /// Store the latest camera matrices WITHOUT async dispatch.
    /// Called directly from ARSession delegate (any queue) to eliminate
    /// the ~1 frame latency caused by Task { @MainActor } scheduling.
    /// The stored pose is applied in applySyncPoseToCurrentSlot() during draw().
    public func storeSyncPose(viewMatrix: simd_float4x4, projectionMatrix: simd_float4x4) {
        poseLock.lock()
        latestViewMatrix = viewMatrix
        latestProjMatrix = projectionMatrix
        hasSyncPose = true
        poseLock.unlock()
    }

    /// Apply the latest synchronous pose to the uniform buffers.
    /// Called from draw() BEFORE encode() to ensure the overlay viewProjection
    /// matches the currently displayed camera feed (not the async-delayed one).
    /// This overwrites only the camera-dependent uniforms; vertex data is untouched.
    public func applySyncPoseToCurrentSlot() {
        poseLock.lock()
        guard hasSyncPose else { poseLock.unlock(); return }
        let vm = latestViewMatrix
        let pm = latestProjMatrix
        poseLock.unlock()

        bufferLock.lock()
        let slot = lastWrittenBufferIndex
        bufferLock.unlock()

        let vmInv = vm.inverse
        var pcUniforms = PointCloudUniforms()
        pcUniforms.viewProjection = pm * vm
        // Preserve existing globalAlpha and pointSizeScale from the last update()
        let existingPtr = pcUniformBuffers[slot].contents().bindMemory(
            to: PointCloudUniforms.self, capacity: 1)
        pcUniforms.globalAlpha = existingPtr.pointee.globalAlpha
        pcUniforms.pointSizeScale = existingPtr.pointee.pointSizeScale
        // Camera world position (column 3 of camera-to-world)
        pcUniforms.cameraPositionX = vmInv[3][0]
        pcUniforms.cameraPositionY = vmInv[3][1]
        pcUniforms.cameraPositionZ = vmInv[3][2]
        // Camera back direction (column 2 of camera-to-world)
        pcUniforms.cameraBackX = vmInv[2][0]
        pcUniforms.cameraBackY = vmInv[2][1]
        pcUniforms.cameraBackZ = vmInv[2][2]
        memcpy(pcUniformBuffers[slot].contents(), &pcUniforms,
               MemoryLayout<PointCloudUniforms>.stride)

        // Also update OIR uniforms for splat rendering consistency
        var oirUniforms = OIRCameraUniforms()
        oirUniforms.viewMatrix = vm
        oirUniforms.projMatrix = pm
        oirUniforms.viewProjMatrix = pm * vm
        let existingOIR = oirUniformBuffers[slot].contents().bindMemory(
            to: OIRCameraUniforms.self, capacity: 1)
        oirUniforms.focal = existingOIR.pointee.focal
        oirUniforms.viewport = existingOIR.pointee.viewport
        oirUniforms.nearPlane = existingOIR.pointee.nearPlane
        oirUniforms.farPlane = existingOIR.pointee.farPlane
        memcpy(oirUniformBuffers[slot].contents(), &oirUniforms,
               MemoryLayout<OIRCameraUniforms>.stride)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Shutdown (call before deallocation)
    // ═══════════════════════════════════════════════════════════════════════

    /// Drain inflight semaphore and mark pipeline inert.
    /// Prevents `update()` from blocking on semaphore and `encode()` from
    /// submitting new GPU work. Must be called before coordinator teardown
    /// to avoid deadlock where main thread waits on semaphore that GPU
    /// will never signal (because the Metal command queue is being torn down).
    public func shutdown() {
        bufferLock.lock()
        isShutDown = true
        let pending = pendingSemaphoreWaitCount
        pendingSemaphoreWaitCount = 0
        hasUnconsumedUpdate = false
        bufferLock.unlock()

        // Signal enough to unblock any pending update() calls + safety margin
        for _ in 0..<(Self.kMaxInflightBuffers + pending) {
            inflightSemaphore.signal()
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Pipeline Construction
    // ═══════════════════════════════════════════════════════════════════════

    private func buildPipelineStates() throws {
        guard let library = device.makeDefaultLibrary() else {
            throw NSError(domain: "PointCloudOIRPipeline", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create default Metal library"])
        }

        // ─── Pass 1: Point Cloud ───
        if let vertexFn = library.makeFunction(name: "pointCloudVertex"),
           let fragmentFn = library.makeFunction(name: "pointCloudFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "PointCloud Pipeline"
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .one               // Pre-multiplied alpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            desc.depthAttachmentPixelFormat = .depth32Float
            pointCloudPSO = try device.makeRenderPipelineState(descriptor: desc)
        }

        // ─── Pass 1.5: Quality Overlay (between point cloud and OIR) ───
        // Shader outputs premultiplied alpha: float4(color * alpha, alpha)
        //
        // BLEND MODE: RGB uses standard premultiplied alpha blending.
        // Alpha uses MIN operation so S6+ tiles (output alpha=0) can "erase"
        // the red clear-color background, revealing the camera feed below.
        //   RGB:   result = src_rgb + dst_rgb × (1 - src_alpha)   [standard]
        //   Alpha: result = min(src_alpha, dst_alpha)              [erase red bg]
        if let vertexFn = library.makeFunction(name: "overlayVertex"),
           let fragmentFn = library.makeFunction(name: "overlayFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Quality Overlay Pipeline"
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            // RGB: standard premultiplied alpha
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            // Alpha: MIN — allows S6+ tiles to reduce dest alpha to 0 (punch through red)
            desc.colorAttachments[0].alphaBlendOperation = .min
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .one
            desc.depthAttachmentPixelFormat = .depth32Float
            overlayPSO = try device.makeRenderPipelineState(descriptor: desc)
        }

        // ─── Pass 2: OIR Accumulation ───
        if let vertexFn = library.makeFunction(name: "oirSplatVertex"),
           let fragmentFn = library.makeFunction(name: "oirSplatAccumFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "OIR Accum Pipeline"
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn

            // Accumulation target (RGBA16Float): additive blending
            desc.colorAttachments[0].pixelFormat = .rgba16Float
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].sourceRGBBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor = .one
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .one

            // Revealage target (R16Float): multiplicative blending
            desc.colorAttachments[1].pixelFormat = .r16Float
            desc.colorAttachments[1].isBlendingEnabled = true
            desc.colorAttachments[1].sourceRGBBlendFactor = .zero
            desc.colorAttachments[1].destinationRGBBlendFactor = .oneMinusSourceColor
            desc.colorAttachments[1].sourceAlphaBlendFactor = .zero
            desc.colorAttachments[1].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            desc.depthAttachmentPixelFormat = .depth32Float
            oirAccumPSO = try device.makeRenderPipelineState(descriptor: desc)
        }

        // ─── Pass 3: OIR Composite (Framebuffer Fetch) ───
        // Blending is done MANUALLY in the shader via [[color(0)]] framebuffer fetch.
        // This is FREE on Apple TBDR GPUs (data stays in tile memory).
        // Hardware blending MUST be disabled to avoid double-blending.
        if let vertexFn = library.makeFunction(name: "oirCompositeVertex"),
           let fragmentFn = library.makeFunction(name: "oirCompositeFragment") {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "OIR Composite Pipeline"
            desc.vertexFunction = vertexFn
            desc.fragmentFunction = fragmentFn
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = false  // Manual blend via [[color(0)]]
            desc.depthAttachmentPixelFormat = .depth32Float
            oirCompositePSO = try device.makeRenderPipelineState(descriptor: desc)
        }
    }

    private func buildDepthStencilStates() {
        // Depth write (point cloud writes depth)
        let writeDesc = MTLDepthStencilDescriptor()
        writeDesc.depthCompareFunction = .less
        writeDesc.isDepthWriteEnabled = true
        depthWriteState = device.makeDepthStencilState(descriptor: writeDesc)

        // Depth read-only (OIR reads depth, no write)
        let readDesc = MTLDepthStencilDescriptor()
        readDesc.depthCompareFunction = .less
        readDesc.isDepthWriteEnabled = false
        depthReadState = device.makeDepthStencilState(descriptor: readDesc)

        // Depth disabled (composite pass)
        let disabledDesc = MTLDepthStencilDescriptor()
        disabledDesc.depthCompareFunction = .always
        disabledDesc.isDepthWriteEnabled = false
        depthDisabledState = device.makeDepthStencilState(descriptor: disabledDesc)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - OIR Texture Management
    // ═══════════════════════════════════════════════════════════════════════

    private func ensureOIRTextures(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        if currentTextureSize.x == width && currentTextureSize.y == height { return }

        // Accumulation texture: RGBA16Float
        let accumDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        accumDesc.usage = [.renderTarget, .shaderRead]
        accumDesc.storageMode = .private
        accumTexture = device.makeTexture(descriptor: accumDesc)
        accumTexture?.label = "OIR Accumulation"

        // Revealage texture: R16Float
        let revealDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: width, height: height, mipmapped: false)
        revealDesc.usage = [.renderTarget, .shaderRead]
        revealDesc.storageMode = .private
        revealTexture = device.makeTexture(descriptor: revealDesc)
        revealTexture?.label = "OIR Revealage"

        currentTextureSize = SIMD2<Int>(width, height)
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Update (Main Thread)
    // ═══════════════════════════════════════════════════════════════════════

    /// Called from main thread (ScanViewModel.processARFrame) with latest data.
    /// Must complete within triple-buffer budget (<2ms).
    public func update(
        pointCloudVertices: UnsafeRawPointer?,
        pointCloudCount: Int,
        splatData: UnsafeRawPointer?,
        splatCount: Int,
        overlayVertices: UnsafeRawPointer?,
        overlayCount: Int,
        viewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        cameraTransform: simd_float4x4,
        globalPointCloudAlpha: Float,
        focal: SIMD2<Float>,
        viewport: SIMD2<Float>
    ) {
        // Bail immediately if pipeline was shut down (prevents semaphore deadlock during teardown)
        bufferLock.lock()
        let shuttingDown = isShutDown
        bufferLock.unlock()
        if shuttingDown { return }

        // Wait for GPU to finish with this buffer slot.
        // Keep timeout SHORT (8ms) to avoid blocking main thread which causes:
        //  1. ARFrame retention (delegate holds 10+ frames → ARKit warning)
        //  2. draw(in:) starvation (MTKView can't fire → no GPU work submitted)
        //  3. UI jank (main thread frozen for semaphore wait duration)
        let waitResult = inflightSemaphore.wait(timeout: .now() + .milliseconds(8))
        if waitResult == .timedOut { return }

        let slot = currentBufferIndex % Self.kMaxInflightBuffers

        // ─── Point Cloud Buffer ───
        let clampedPCCount = min(pointCloudCount, Self.kMaxPointCloudVertices)
        if clampedPCCount > 0, let src = pointCloudVertices {
            let byteCount = clampedPCCount * Self.kPointCloudVertexStride
            memcpy(pointCloudBuffers[slot].contents(), src, byteCount)
        }

        // ─── Splat Buffer ───
        let clampedSplatCount = min(splatCount, Self.kMaxSplats)
        if clampedSplatCount > 0, let src = splatData {
            let byteCount = clampedSplatCount * Self.kSplatStride
            memcpy(splatBuffers[slot].contents(), src, byteCount)
        }

        // ─── Overlay Buffer (quality heatmap, ~63KB) ───
        let clampedOverlayCount = min(overlayCount, Self.kMaxOverlayVertices)
        if clampedOverlayCount > 0, let src = overlayVertices {
            let byteCount = clampedOverlayCount * Self.kOverlayVertexStride
            memcpy(overlayBuffers[slot].contents(), src, byteCount)
        }

        // ─── Overlay Diagnostic (throttled) ───
        // C++ generate_overlay_vertices() now applies Z-convention correction,
        // so positions arriving here should already be in correct ARKit world space.
        debugUpdateLogCount += 1
        if clampedOverlayCount > 0 && (debugUpdateLogCount <= 5 || debugUpdateLogCount % 200 == 0) {
            let vp = projectionMatrix * viewMatrix
            let floatsPerVertex = Self.kOverlayVertexStride / MemoryLayout<Float>.stride
            let allFloats = overlayBuffers[slot].contents().bindMemory(to: Float.self, capacity: clampedOverlayCount * floatsPerVertex)

            // Check first 3 vertices (or fewer if count < 3)
            let checkCount = min(3, clampedOverlayCount)
            for vi in 0..<checkCount {
                let base = vi * floatsPerVertex
                let pos = SIMD3<Float>(allFloats[base], allFloats[base+1], allFloats[base+2])
                let clip = vp * SIMD4<Float>(pos.x, pos.y, pos.z, 1.0)

                NSLog("[Aether3D][Overlay] #%d v%d: pos=(%.3f,%.3f,%.3f) clip_w=%.2f ndc=(%.2f,%.2f) q=%.3f sz=%.4f",
                      debugUpdateLogCount, vi,
                      pos.x, pos.y, pos.z, clip.w,
                      clip.w > 0.001 ? clip.x/clip.w : 999.0,
                      clip.w > 0.001 ? clip.y/clip.w : 999.0,
                      allFloats[base+7], allFloats[base+6])
            }
            // Summary: struct size verification (first 3 calls only)
            if debugUpdateLogCount <= 3 {
                let vmInv2 = viewMatrix.inverse
                let camPos = SIMD3<Float>(vmInv2[3][0], vmInv2[3][1], vmInv2[3][2])
                NSLog("[Aether3D][Overlay] PointCloudUniforms: size=%d stride=%d (Metal expects 112)",
                      MemoryLayout<PointCloudUniforms>.size, MemoryLayout<PointCloudUniforms>.stride)
                NSLog("[Aether3D][Overlay] cam=(%.2f,%.2f,%.2f) count=%d",
                      camPos.x, camPos.y, camPos.z, clampedOverlayCount)
            }
        }

        // ─── Point Cloud Uniforms (shared with overlay shader) ───
        let vmInv = viewMatrix.inverse
        var pcUniforms = PointCloudUniforms()
        pcUniforms.viewProjection = projectionMatrix * viewMatrix
        pcUniforms.globalAlpha = globalPointCloudAlpha
        pcUniforms.pointSizeScale = 2.0  // Retina scale
        // Camera world position (column 3 of camera-to-world matrix)
        pcUniforms.cameraPositionX = vmInv[3][0]
        pcUniforms.cameraPositionY = vmInv[3][1]
        pcUniforms.cameraPositionZ = vmInv[3][2]
        // Camera Z axis in world (column 2 of camera-to-world = points BEHIND camera)
        // Used by overlay shader for Z-convention correction (TSDF uses +Z forward,
        // ARKit uses -Z forward → TSDF blocks are reflected behind camera)
        pcUniforms.cameraBackX = vmInv[2][0]
        pcUniforms.cameraBackY = vmInv[2][1]
        pcUniforms.cameraBackZ = vmInv[2][2]
        memcpy(pcUniformBuffers[slot].contents(), &pcUniforms, MemoryLayout<PointCloudUniforms>.stride)

        // ─── OIR Uniforms ───
        var oirUniforms = OIRCameraUniforms()
        oirUniforms.viewMatrix = viewMatrix
        oirUniforms.projMatrix = projectionMatrix
        oirUniforms.viewProjMatrix = projectionMatrix * viewMatrix
        oirUniforms.focal = focal
        oirUniforms.viewport = viewport
        oirUniforms.nearPlane = 0.001
        oirUniforms.farPlane = 1000.0
        memcpy(oirUniformBuffers[slot].contents(), &oirUniforms, MemoryLayout<OIRCameraUniforms>.stride)

        // Publish
        bufferLock.lock()
        lastWrittenBufferIndex = slot
        lastPointCloudCount = clampedPCCount
        lastSplatCount = clampedSplatCount
        lastOverlayCount = clampedOverlayCount
        hasUnconsumedUpdate = true
        pendingSemaphoreWaitCount += 1
        bufferLock.unlock()

        currentBufferIndex += 1
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Encode (MTKView Delegate Thread)
    // ═══════════════════════════════════════════════════════════════════════

    public func encode(
        into commandBuffer: MTLCommandBuffer,
        renderPassDescriptor: MTLRenderPassDescriptor
    ) {
        bufferLock.lock()
        let shuttingDown = isShutDown
        let slot = lastWrittenBufferIndex
        let pcCount = lastPointCloudCount
        let splatCount = lastSplatCount
        let overlayCount = lastOverlayCount
        let shouldSignal = hasUnconsumedUpdate
        if shouldSignal { hasUnconsumedUpdate = false }
        let signalCount = pendingSemaphoreWaitCount
        if shouldSignal { pendingSemaphoreWaitCount = 0 }
        bufferLock.unlock()

        // Pipeline shut down — drain semaphore and bail
        if shuttingDown {
            if shouldSignal {
                for _ in 0..<signalCount {
                    inflightSemaphore.signal()
                }
            }
            return
        }

        // Skip ONLY if no overlay PSO at all — overlay always runs for red background.
        // Even with overlayCount=0, the clear-to-red pass must execute so the user
        // sees full-screen red at scan start (before any TSDF blocks exist).
        if pcCount == 0 && splatCount == 0 && overlayCount == 0 && overlayPSO == nil {
            debugEncodeSkipCount += 1
            if shouldSignal {
                for _ in 0..<signalCount {
                    inflightSemaphore.signal()
                }
            }
            return
        }
        debugEncodeDrawCount += 1

        // Ensure OIR textures sized to drawable
        if let colorAttach = renderPassDescriptor.colorAttachments[0].texture {
            ensureOIRTextures(width: colorAttach.width, height: colorAttach.height)
        }

        // ─── Pass 1: Point Cloud — DISABLED ───
        // User wants TSDF heatmap overlay only, not individual point cloud dots.
        // The quality overlay (Pass 1.5) provides the scanning visualization.
        // Point cloud data is still generated by C++ for TSDF/training use.
        //
        // NOTE: We still need a render pass to initialize the depth buffer for
        // subsequent overlay/OIR passes. Use a clear-only pass if no overlay.
        if pcCount > 0, let pso = pointCloudPSO {
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) {
                encoder.label = "PointCloud Pass"
                encoder.setRenderPipelineState(pso)
                encoder.setDepthStencilState(depthWriteState)
                encoder.setVertexBuffer(pointCloudBuffers[slot], offset: 0, index: 0)
                encoder.setVertexBuffer(pcUniformBuffers[slot], offset: 0, index: 1)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pcCount)
                encoder.endEncoding()
            }
        }

        // ─── Pass 1.5: Quality Overlay (to drawable, after point cloud depth) ───
        if overlayPSO == nil && overlayCount > 0 {
            debugOverlayPSONilCount += 1
            if debugOverlayPSONilCount <= 3 {
                NSLog("[Aether3D][OverlayPass] overlayPSO is NIL! overlayCount=%d — shader not compiled?", overlayCount)
            }
        }
        if let ovPSO = overlayPSO {
            // ── FULL-SCREEN RED BACKGROUND (ALWAYS RUNS) ──
            // This pass MUST execute even when overlayCount=0 (no TSDF blocks yet).
            // The .clear action fills the ENTIRE screen with semi-transparent red.
            // As TSDF blocks accumulate, overlay tiles draw on top:
            //   - Low quality tiles: red/orange (blends with red background)
            //   - S6+ tiles: alpha=0 erases red background via MIN alpha blend.
            // User sees: RED (unscanned) → ORANGE → YELLOW → GREEN → TRANSPARENT (S6+).
            let overlayRPD = MTLRenderPassDescriptor()
            overlayRPD.colorAttachments[0].texture = renderPassDescriptor.colorAttachments[0].texture
            overlayRPD.colorAttachments[0].loadAction = .clear
            overlayRPD.colorAttachments[0].clearColor = MTLClearColorMake(
                0.40 * 0.45,   // R: 0.40 * alpha (premultiplied)
                0.10 * 0.45,   // G: 0.10 * alpha
                0.09 * 0.45,   // B: 0.09 * alpha
                0.45           // A: semi-transparent red background
            )
            overlayRPD.colorAttachments[0].storeAction = .store
            overlayRPD.depthAttachment.texture = renderPassDescriptor.depthAttachment.texture
            overlayRPD.depthAttachment.loadAction = .clear
            overlayRPD.depthAttachment.clearDepth = 1.0
            overlayRPD.depthAttachment.storeAction = .store

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: overlayRPD) {
                encoder.label = "Quality Overlay Pass"
                encoder.setRenderPipelineState(ovPSO)
                // Depth test ON: cube-face tiles at different depths must occlude properly.
                // Without depth test, tiles from behind bleed through closer tiles.
                encoder.setDepthStencilState(depthWriteState)

                // Only draw overlay instances if there are tiles to draw.
                // When overlayCount=0, the clear-to-red still applies (full-screen red).
                if overlayCount > 0 {
                    encoder.setVertexBuffer(overlayBuffers[slot], offset: 0, index: 0)
                    encoder.setVertexBuffer(pcUniformBuffers[slot], offset: 0, index: 1)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                           vertexCount: 4, instanceCount: overlayCount)
                }
                encoder.endEncoding()

                debugOverlayDrawLogCount += 1
                if debugOverlayDrawLogCount <= 5 || debugOverlayDrawLogCount % 300 == 0 {
                    let texW = overlayRPD.colorAttachments[0].texture?.width ?? 0
                    let texH = overlayRPD.colorAttachments[0].texture?.height ?? 0
                    NSLog("[Aether3D][OverlayPass] overlayCount=%d  tex=%dx%d  slot=%d  splatCount=%d",
                          overlayCount, texW, texH, slot, splatCount)
                }
            }
        }

        // ─── Pass 2: OIR Accumulation (off-screen) ───
        if splatCount > 0, let accumPSO = oirAccumPSO,
           let accumTex = accumTexture, let revealTex = revealTexture {

            let accumRPD = MTLRenderPassDescriptor()

            // Accumulation target: clear to (0, 0, 0, 0)
            accumRPD.colorAttachments[0].texture = accumTex
            accumRPD.colorAttachments[0].loadAction = .clear
            accumRPD.colorAttachments[0].storeAction = .store
            accumRPD.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

            // Revealage target: clear to (1, 0, 0, 0) — fully transparent initially
            accumRPD.colorAttachments[1].texture = revealTex
            accumRPD.colorAttachments[1].loadAction = .clear
            accumRPD.colorAttachments[1].storeAction = .store
            accumRPD.colorAttachments[1].clearColor = MTLClearColorMake(1, 0, 0, 0)

            // Share depth from drawable
            accumRPD.depthAttachment.texture = renderPassDescriptor.depthAttachment.texture
            accumRPD.depthAttachment.loadAction = .load
            accumRPD.depthAttachment.storeAction = .dontCare

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: accumRPD) {
                encoder.label = "OIR Accum Pass"
                encoder.setRenderPipelineState(accumPSO)
                encoder.setDepthStencilState(depthReadState)
                encoder.setVertexBuffer(splatBuffers[slot], offset: 0, index: 0)
                encoder.setVertexBuffer(oirUniformBuffers[slot], offset: 0, index: 1)
                // Instanced quad rendering: 4 vertices per splat
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                       vertexCount: 4, instanceCount: splatCount)
                encoder.endEncoding()
            }

            // ─── Pass 3: OIR Composite (to drawable) ───
            if let compositePSO = oirCompositePSO {
                // Second render pass to the same drawable (load existing content)
                let compositeRPD = MTLRenderPassDescriptor()
                compositeRPD.colorAttachments[0].texture = renderPassDescriptor.colorAttachments[0].texture
                compositeRPD.colorAttachments[0].loadAction = .load
                compositeRPD.colorAttachments[0].storeAction = .store
                compositeRPD.depthAttachment.texture = renderPassDescriptor.depthAttachment.texture
                compositeRPD.depthAttachment.loadAction = .load
                compositeRPD.depthAttachment.storeAction = .dontCare

                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositeRPD) {
                    encoder.label = "OIR Composite Pass"
                    encoder.setRenderPipelineState(compositePSO)
                    encoder.setDepthStencilState(depthDisabledState)
                    encoder.setFragmentTexture(accumTex, index: 0)
                    encoder.setFragmentTexture(revealTex, index: 1)
                    // Background: shader reads existing drawable via [[color(0)]] framebuffer fetch.
                    // No need to bind background texture — Apple TBDR reads tile memory for FREE.
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    encoder.endEncoding()
                }
            }
        }

        // Signal semaphore on GPU completion
        if shouldSignal {
            let sem = inflightSemaphore
            let count = signalCount
            commandBuffer.addCompletedHandler { _ in
                for _ in 0..<count {
                    sem.signal()
                }
            }
        }
    }
}

#endif  // canImport(Metal)
