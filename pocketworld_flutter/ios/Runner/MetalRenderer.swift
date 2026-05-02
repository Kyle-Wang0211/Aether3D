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

// Phase 6.4f stubs (return false until the implementation lands).
@_silgen_name("aether_scene_renderer_load_ply")
private func aether_scene_renderer_load_ply(
    _ renderer: OpaquePointer?,
    _ path: UnsafePointer<CChar>
) -> Bool

@_silgen_name("aether_scene_renderer_load_spz")
private func aether_scene_renderer_load_spz(
    _ renderer: OpaquePointer?,
    _ path: UnsafePointer<CChar>
) -> Bool

// Phase 6.4f.3.b — memory-capped load entry points. `maxSplats=0` means
// no cap; `maxShDegree<3` truncates higher-order spherical harmonics.
@_silgen_name("aether_scene_renderer_load_ply_capped")
private func aether_scene_renderer_load_ply_capped(
    _ renderer: OpaquePointer?,
    _ path: UnsafePointer<CChar>,
    _ maxSplats: UInt32,
    _ maxShDegree: UInt8
) -> Bool

@_silgen_name("aether_scene_renderer_load_spz_capped")
private func aether_scene_renderer_load_spz_capped(
    _ renderer: OpaquePointer?,
    _ path: UnsafePointer<CChar>,
    _ maxSplats: UInt32,
    _ maxShDegree: UInt8
) -> Bool

@_silgen_name("aether_scene_renderer_render_full")
private func aether_scene_renderer_render_full(
    _ renderer: OpaquePointer?,
    _ viewMatrix: UnsafePointer<Float>,
    _ modelMatrix: UnsafePointer<Float>
)

// G4: get_bounds surfaces the loaded mesh's local AABB. Returns false if
// no mesh loaded; the caller can fall back to a hardcoded distance.
@_silgen_name("aether_scene_renderer_get_bounds")
private func aether_scene_renderer_get_bounds(
    _ renderer: OpaquePointer?,
    _ outMin: UnsafeMutablePointer<Float>,
    _ outMax: UnsafeMutablePointer<Float>
) -> Bool

/// Local-space AABB returned from `SharedNativeTexture.loadGlb`. Six
/// floats; the Flutter side packs them into ModelBounds.
struct LoadedBounds {
    let minX: Float
    let minY: Float
    let minZ: Float
    let maxX: Float
    let maxY: Float
    let maxZ: Float
}

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
    // G4-bugfix: dirty flag so the displayLink doesn't re-render every
    // texture every tick. Pre-G4 the displayLink rendered ONE texture
    // (the home-screen DamagedHelmet). G4's multi-texture iteration
    // multiplied that by N≈5 cards × 60fps = 300 IOSurface→MTLTexture
    // re-imports per second through dawn::native::metal::
    // SharedTextureMemory::CreateMtlTextures, which on iOS 17+ devices
    // crashes inside [device newTextureWithDescriptor:iosurface:plane:]
    // (Dawn's NSPRef AcquireNSPRef abort path). Throttling to "render
    // only when matrices changed" drops the rate back near 60fps total
    // (focused card auto-rotates each Ticker tick, static cards render
    // exactly once after load and then sleep until they're tapped /
    // become focused). dirty starts true so the very first frame after
    // create lands on the texture.
    private var dirty: Bool = true

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
        // Bug-fix log: if aether_scene_renderer_create crashes inside
        // Dawn's SharedTextureMemory::CreateMtlTextures (the iOS 17+
        // failure mode where [device newTextureWithDescriptor:
        // iosurface:plane:] returns nil and Dawn DAWN_INVALID_IFs),
        // this NSLog is the last breadcrumb before the abort, so the
        // diagnostic shows exactly which size + which texture
        // sequence number was the trigger.
        NSLog("[SharedNativeTexture iOS] importing IOSurface %dx%d into Dawn",
              width, height)
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
    /// Returns 0.0 immediately if the texture isn't dirty — the
    /// displayLinkTick checks `consumeIfDirty()` instead of calling
    /// this unconditionally.
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
        // Mark dirty regardless of whether matrices actually changed —
        // the Dart caller only calls setMatrices when it has a new
        // frame to push, so every call is a render request. (Dart-side
        // gating happens in AetherCppCardDemo._onTick / LiveModelView's
        // ticker; if a card is "static" it just doesn't call this.)
        dirty = true
    }

    /// G4-bugfix: returns true once if there's a pending render, then
    /// flips the flag back to false. The displayLinkTick uses this to
    /// skip un-changed textures, which keeps Dawn's per-frame
    /// IOSurface→MTLTexture import rate sane.
    func consumeIfDirty() -> Bool {
        if dirty {
            dirty = false
            return true
        }
        return false
    }

    func loadGlb(path: String) -> Bool {
        guard let rendererHandle else { return false }
        return path.withCString { cPath in
            aether_scene_renderer_load_glb(rendererHandle, cPath)
        }
    }

    /// 3DGS PLY. Phase 6.4f.3.b adds `maxSplats` (0 = unlimited) and
    /// `maxShDegree` (3 = full quality, 0 = DC only) for memory-bound
    /// load paths — feed thumbnails should pass a small cap; detail
    /// pages keep defaults.
    func loadPly(path: String, maxSplats: UInt32 = 0, maxShDegree: UInt8 = 3) -> Bool {
        guard let rendererHandle else { return false }
        return path.withCString { cPath in
            aether_scene_renderer_load_ply_capped(
                rendererHandle, cPath, maxSplats, maxShDegree)
        }
    }

    /// Niantic Lightship SPZ. Same cap semantics as `loadPly`.
    func loadSpz(path: String, maxSplats: UInt32 = 0, maxShDegree: UInt8 = 3) -> Bool {
        guard let rendererHandle else { return false }
        return path.withCString { cPath in
            aether_scene_renderer_load_spz_capped(
                rendererHandle, cPath, maxSplats, maxShDegree)
        }
    }

    /// G4: read the local AABB of the just-loaded mesh. Call AFTER a
    /// successful loadGlb. Returns nil if no mesh is loaded.
    func getBounds() -> LoadedBounds? {
        guard let rendererHandle else { return nil }
        var minBuf: [Float] = [0, 0, 0]
        var maxBuf: [Float] = [0, 0, 0]
        let ok = minBuf.withUnsafeMutableBufferPointer { minBp -> Bool in
            maxBuf.withUnsafeMutableBufferPointer { maxBp -> Bool in
                guard let minPtr = minBp.baseAddress,
                      let maxPtr = maxBp.baseAddress else { return false }
                return aether_scene_renderer_get_bounds(rendererHandle,
                                                        minPtr, maxPtr)
            }
        }
        guard ok else { return nil }
        return LoadedBounds(
            minX: minBuf[0], minY: minBuf[1], minZ: minBuf[2],
            maxX: maxBuf[0], maxY: maxBuf[1], maxZ: maxBuf[2]
        )
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
