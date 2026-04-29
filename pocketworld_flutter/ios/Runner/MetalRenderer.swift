import CoreVideo
import Flutter
import IOSurface
import QuartzCore

// ─── Final iOS port — Scene IOSurface renderer bridge ─────────────────
//
// The Phase 5 iOS renderer drew a local Metal triangle. Final iOS port
// switches the texture implementation to the same C++ scene renderer used
// by macOS: Dawn renders DamagedHelmet + splat overlay into an IOSurface,
// Flutter reads that IOSurface through a CVPixelBuffer.
//
// Keep this file intentionally thin. Policy / GLB parsing / render passes
// live in aether_cpp; Swift owns only iOS lifecycle + Flutter texture glue.

@_silgen_name("aether_scene_renderer_create")
private func aether_scene_renderer_create(
    _ iosurface: UnsafeMutableRawPointer?,
    _ width: UInt32,
    _ height: UInt32
) -> OpaquePointer?

@_silgen_name("aether_scene_renderer_destroy")
private func aether_scene_renderer_destroy(_ renderer: OpaquePointer?)

@_silgen_name("aether_scene_renderer_load_glb")
private func aether_scene_renderer_load_glb(
    _ renderer: OpaquePointer?,
    _ path: UnsafePointer<CChar>
) -> Bool

@_silgen_name("aether_scene_renderer_render_full")
private func aether_scene_renderer_render_full(
    _ renderer: OpaquePointer?,
    _ viewMatrix: UnsafePointer<Float>,
    _ modelMatrix: UnsafePointer<Float>
)

/// Specific failure points during SharedNativeTexture allocation. Each maps
/// to a FlutterError code so native failures stay loud instead of becoming a
/// blank texture.
enum TextureCreateError: Error {
    case iosurfaceCreate
    case cvpixelbufferCreate(CVReturn)
    case rendererCreate
}

/// IOSurface-backed Flutter texture rendered by the C++ scene renderer.
class SharedNativeTexture: NSObject, FlutterTexture {
    private let pixelBuffer: CVPixelBuffer
    private let ioSurface: IOSurfaceRef
    private var rendererHandle: OpaquePointer?

    private var latestView: [Float] = SharedNativeTexture.identityMatrix()
    private var latestModel: [Float] = SharedNativeTexture.identityMatrix()

    // Same passRetained contract watch used by the macOS texture bridge.
    private var copyCount: UInt64 = 0
    private let leakCheckIntervalCalls: UInt64 = 60
    private let leakCheckThresholdRefs: CFIndex = 5

    private static func identityMatrix() -> [Float] {
        [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
    }

    init(width: Int = 256, height: Int = 256) throws {
        let ioProps: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .pixelFormat: Int(kCVPixelFormatType_32BGRA),
            .bytesPerElement: 4,
            .bytesPerRow: width * 4,
        ]
        guard let surface = IOSurface(properties: ioProps) else {
            throw TextureCreateError.iosurfaceCreate
        }

        var pbUnmanaged: Unmanaged<CVPixelBuffer>?
        let cvStatus = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            nil,
            &pbUnmanaged
        )
        guard cvStatus == kCVReturnSuccess,
              let buffer = pbUnmanaged?.takeRetainedValue() else {
            throw TextureCreateError.cvpixelbufferCreate(cvStatus)
        }

        let surfaceVoidPtr = unsafeBitCast(surface, to: UnsafeMutableRawPointer.self)
        guard let renderer = aether_scene_renderer_create(
            surfaceVoidPtr,
            UInt32(width),
            UInt32(height)
        ) else {
            throw TextureCreateError.rendererCreate
        }

        self.pixelBuffer = buffer
        self.ioSurface = surface
        self.rendererHandle = renderer
        super.init()

        NSLog("[SharedNativeTexture iOS] scene renderer created %dx%d BGRA8",
              width,
              height)
    }

    deinit {
        aether_scene_renderer_destroy(rendererHandle)
        rendererHandle = nil
    }

    /// Render one frame using the latest matrices pushed by Dart.
    @discardableResult
    func render() -> Double {
        guard let rendererHandle else { return 0.0 }
        let frameStart = CACurrentMediaTime()
        latestView.withUnsafeBufferPointer { viewBuf in
            latestModel.withUnsafeBufferPointer { modelBuf in
                guard let viewPtr = viewBuf.baseAddress,
                      let modelPtr = modelBuf.baseAddress else { return }
                aether_scene_renderer_render_full(rendererHandle, viewPtr, modelPtr)
            }
        }
        return (CACurrentMediaTime() - frameStart) * 1000.0
    }

    func setMatrices(view: [Float], model: [Float]) {
        if view.count == 16 { latestView = view }
        if model.count == 16 { latestModel = model }
    }

    func loadGlb(path: String) -> Bool {
        guard let rendererHandle else { return false }
        return path.withCString { cPath in
            aether_scene_renderer_load_glb(rendererHandle, cPath)
        }
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        _ = ioSurface  // Keep the IOSurface strongly retained for Flutter.
        copyCount &+= 1
        if copyCount % leakCheckIntervalCalls == 0 {
            let rc = CFGetRetainCount(pixelBuffer)
            if rc > leakCheckThresholdRefs {
                NSLog("[SharedNativeTexture iOS] passRetained contract WARNING: pixelBuffer retainCount=%ld after %llu copyPixelBuffer calls",
                      rc,
                      copyCount)
            }
        }
        return Unmanaged.passRetained(pixelBuffer)
    }
}
