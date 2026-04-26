import Cocoa
import FlutterMacOS
import IOSurface
import QuartzCore
import CoreVideo  // CVPixelBuffer

// ─── Phase 6.4a — splat IOSurface bridge ───────────────────────────────
//
// Phase 4-5 used a hardcoded MSL triangle shader rendered directly via
// MTLRenderPipelineState. Phase 6.4a swaps the renderer for Aether3D's
// production splat pipeline: DawnGPUDevice writes 4 Gaussian splats into
// the same IOSurface that Flutter compositor samples. Zero copies; the
// bytes written by Dawn ARE the bytes Flutter reads.
//
// SharedNativeTexture's init / render / dispose are now thin wrappers
// over the C ABI in aether_cpp/include/aether/pocketworld/
// splat_iosurface_renderer.h:
//   aether_splat_renderer_create(iosurface, w, h)   — at construct time
//   aether_splat_renderer_render(handle, t_seconds)  — per displayLink tick
//   aether_splat_renderer_destroy(handle)            — at dispose
//
// The plugin (AetherTexturePlugin) — its lifecycle / method-channel /
// thermal handlers — is UNCHANGED. The renderer class swap was the
// architectural intent of the Phase 5.3 split (split + comment in iOS
// MetalRenderer.swift literally said "Future Dawn-iOS swap = replace
// this file's SharedNativeTexture implementation with a Dawn/WebGPU
// equivalent. The plugin code doesn't need to change.")
//
// Why dlopen+dlsym vs @_silgen_name: avoids needing the dylib linked at
// Xcode build time. We dlopen at first-renderer-create from a known dev
// path (aether_cpp/build/libaether3d_ffi.dylib) OR @rpath for production.
// If the dylib is missing OR a symbol can't be resolved, FFI.shared is
// nil and SharedNativeTexture.init throws TextureCreateError.ffiUnavailable
// → Flutter UI shows the error message instead of silently displaying
// a black widget (silent = catastrophe rule from Phase 6.3a).

// ─── FFI binding (dynamic dlsym; no Xcode link config needed) ─────────

private final class FFI {
    typealias CreateFn     = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> OpaquePointer?
    typealias DestroyFn    = @convention(c) (OpaquePointer?) -> Void
    typealias RenderFn     = @convention(c) (OpaquePointer?, Double) -> Void
    typealias RenderFullFn = @convention(c) (OpaquePointer?, UnsafePointer<Float>, UnsafePointer<Float>) -> Void

    let create:     CreateFn
    let destroy:    DestroyFn
    let render:     RenderFn
    let renderFull: RenderFullFn

    /// Returns nil (with NSLog diagnostic) if the dylib can't be found
    /// or any of the required symbols isn't present.
    static let shared: FFI? = {
        // 1. Try RTLD_DEFAULT first — symbols are already in the process
        //    namespace if Flutter linked the dylib via build config.
        if let f = FFI(handle: UnsafeMutableRawPointer(bitPattern: -2)!) {
            return f
        }

        // 2. Try several known dev paths. The fallback chain matches the
        //    iterative dev workflow (run cmake → flutter run).
        let candidates: [String] = [
            "aether_cpp/build/libaether3d_ffi.dylib",
            "../aether_cpp/build/libaether3d_ffi.dylib",
            "../../aether_cpp/build/libaether3d_ffi.dylib",
            Bundle.main.bundlePath + "/Contents/Frameworks/libaether3d_ffi.dylib",
            "libaether3d_ffi.dylib",
        ]
        for path in candidates {
            if let handle = dlopen(path, RTLD_LAZY | RTLD_GLOBAL) {
                NSLog("[AetherFFI] dlopen succeeded: %@", path)
                if let f = FFI(handle: handle) { return f }
            }
        }
        NSLog("[AetherFFI] FATAL: aether3d_ffi.dylib not found in any search path. "
            + "Build with `cmake --build aether_cpp/build` and ensure the dylib "
            + "is in one of: aether_cpp/build/, Runner.app/Contents/Frameworks/, "
            + "or DYLD_LIBRARY_PATH.")
        return nil
    }()

    private init?(handle: UnsafeMutableRawPointer) {
        guard let cSym  = dlsym(handle, "aether_splat_renderer_create"),
              let dSym  = dlsym(handle, "aether_splat_renderer_destroy"),
              let rSym  = dlsym(handle, "aether_splat_renderer_render"),
              let rfSym = dlsym(handle, "aether_splat_renderer_render_full") else {
            return nil
        }
        self.create     = unsafeBitCast(cSym,  to: CreateFn.self)
        self.destroy    = unsafeBitCast(dSym,  to: DestroyFn.self)
        self.render     = unsafeBitCast(rSym,  to: RenderFn.self)
        self.renderFull = unsafeBitCast(rfSym, to: RenderFullFn.self)
    }
}

// ─── Texture creation error codes ─────────────────────────────────────

enum TextureCreateError: Error {
    case ffiUnavailable              // dylib not found or symbols missing
    case iosurfaceCreate
    case cvpixelbufferCreate(CVReturn)
    case rendererCreate              // C ABI returned NULL
}

/// 256×256 BGRA8 IOSurface-backed texture, exposed to Flutter through
/// FlutterTexture protocol. Phase 4-5 rendered a rotating triangle via
/// MTLRenderPipelineState; Phase 6.4a renders 4 Gaussian splats via the
/// Aether3D production pipeline (DawnGPUDevice → splat_render.wgsl).
class SharedNativeTexture: NSObject, FlutterTexture {
    private let pixelBuffer: CVPixelBuffer
    private let ioSurface: IOSurfaceRef
    private let rendererHandle: OpaquePointer
    private var hasRenderedOnce = false

    // Phase 6.4c: latest gesture-derived matrices, pushed by Dart via
    // setMatrices method channel. Identity by default so the first frame
    // (before any gesture) renders the static cross_validate baseline.
    private var latestView: [Float] = SharedNativeTexture.identityMatrix()
    private var latestModel: [Float] = SharedNativeTexture.identityMatrix()

    // Phase 4 polish #3: passRetained contract assertion. Carried forward
    // unchanged — same CVPixelBuffer lifecycle as before.
    private var copyCount: UInt64 = 0
    private let leakCheckIntervalCalls: UInt64 = 60
    private let leakCheckThresholdRefs: CFIndex = 5

    private static func identityMatrix() -> [Float] {
        return [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
    }

    init(width: Int = 256, height: Int = 256) throws {
        guard let ffi = FFI.shared else {
            throw TextureCreateError.ffiUnavailable
        }

        // 1. IOSurface (BGRA8, the IOSurface-canonical pixel format).
        let ioProps: [IOSurfacePropertyKey: Any] = [
            .width:           width,
            .height:          height,
            .pixelFormat:     Int(kCVPixelFormatType_32BGRA),
            .bytesPerElement: 4,
            .bytesPerRow:     width * 4,
        ]
        guard let surface = IOSurface(properties: ioProps) else {
            throw TextureCreateError.iosurfaceCreate
        }
        let surfaceRef = surface as IOSurfaceRef

        // 2. CVPixelBuffer wrapping the IOSurface (Flutter compositor reads).
        var pbUnmanaged: Unmanaged<CVPixelBuffer>?
        let cvStatus = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surfaceRef, nil, &pbUnmanaged
        )
        guard cvStatus == kCVReturnSuccess,
              let buffer = pbUnmanaged?.takeRetainedValue() else {
            throw TextureCreateError.cvpixelbufferCreate(cvStatus)
        }

        // 3. Aether3D splat renderer over the same IOSurface (Dawn writes).
        // IOSurfaceRef cast to void* — Dawn internally CFRetains for the
        // lifetime of the renderer.
        let surfaceVoidPtr = unsafeBitCast(surfaceRef, to: UnsafeMutableRawPointer.self)
        guard let handle = ffi.create(surfaceVoidPtr, UInt32(width), UInt32(height)) else {
            throw TextureCreateError.rendererCreate
        }

        self.pixelBuffer    = buffer
        self.ioSurface      = surfaceRef
        self.rendererHandle = handle
        self.ffi            = ffi
        super.init()
    }

    deinit {
        // Free the renderer's GPU resources. C ABI is NULL-safe.
        ffi.destroy(rendererHandle)
    }

    /// Render one frame using the stored latest view + model matrices.
    /// Driven from displayLinkTick. The matrices are updated via
    /// setMatrices() (called from Dart's gesture handlers via
    /// MethodChannel). Without any gesture, both default to identity.
    func render() {
        latestView.withUnsafeBufferPointer { viewBuf in
            latestModel.withUnsafeBufferPointer { modelBuf in
                ffi.renderFull(rendererHandle, viewBuf.baseAddress!, modelBuf.baseAddress!)
            }
        }
        hasRenderedOnce = true
    }

    /// Update the matrices used for the next render frame. Called from
    /// the AetherTexturePlugin's setMatrices method-channel handler when
    /// Dart pushes new orbit/object state.
    func setMatrices(view: [Float], model: [Float]) {
        // Defensive: caller may pass wrong-length arrays from a buggy
        // FlutterStandardTypedData decode; clamp to 16 floats and pad
        // with identity values rather than crashing.
        if view.count == 16  { latestView  = view  }
        if model.count == 16 { latestModel = model }
    }

    private let ffi: FFI

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        // Same passRetained contract assertion as Phase 4 polish #3.
        copyCount &+= 1
        if copyCount % leakCheckIntervalCalls == 0 {
            let rc = CFGetRetainCount(pixelBuffer)
            if rc > leakCheckThresholdRefs {
                NSLog("[SharedNativeTexture] passRetained contract WARNING: pixelBuffer retainCount=%ld after %llu copyPixelBuffer calls. Flutter compositor may not be releasing.",
                      rc, copyCount)
            }
        }
        return Unmanaged.passRetained(pixelBuffer)
    }
}

// ─── Plugin (lifecycle / channels) — unchanged from Phase 4 ────────────

class AetherTexturePlugin: NSObject, FlutterPlugin {
    private let textures: FlutterTextureRegistry
    // Phase 6.4a: device + commandQueue removed — the renderer is now
    // managed entirely by the C ABI (singleton DawnGPUDevice inside
    // aether3d_ffi). Plugin no longer needs Metal directly.

    private var registered: [Int64: SharedNativeTexture] = [:]

    private var displayLink: Any?
    private var animationStart: CFTimeInterval = 0
    private var animatedTextureId: Int64?
    private var animatedTexture: SharedNativeTexture?
    private var frameCount: Int = 0
    private var frameStatsLogTime: CFTimeInterval = 0

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "aether_texture",
            binaryMessenger: registrar.messenger
        )
        let instance = AetherTexturePlugin(textures: registrar.textures)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(textures: FlutterTextureRegistry) {
        self.textures = textures
        super.init()
    }

    private func parseTextureDimension(_ raw: Any?, default fallback: Int) -> Int {
        let n: Int?
        switch raw {
        case let v as Int:    n = v
        case let v as Int32:  n = Int(v)
        case let v as Int64:  n = Int(v)
        case let v as NSNumber: n = v.intValue
        default: n = nil
        }
        guard let v = n, v > 0, v <= 4096 else { return fallback }
        return v
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "createSharedNativeTexture":
            let args = call.arguments as? [String: Any] ?? [:]
            let width  = parseTextureDimension(args["width"],  default: 256)
            let height = parseTextureDimension(args["height"], default: 256)
            do {
                let texture = try SharedNativeTexture(width: width, height: height)
                let id = textures.register(texture)
                registered[id] = texture
                texture.render()
                textures.textureFrameAvailable(id)
                startAnimation(textureId: id, texture: texture)
                result(NSNumber(value: id))
            } catch TextureCreateError.ffiUnavailable {
                result(FlutterError(
                    code: "FFI_UNAVAILABLE",
                    message: "aether3d_ffi.dylib not loaded — see Console.app for [AetherFFI] dlopen diagnostic. Build dylib with `cmake --build aether_cpp/build` and ensure it's in aether_cpp/build/, Runner.app/Contents/Frameworks/, or DYLD_LIBRARY_PATH.",
                    details: nil))
            } catch TextureCreateError.iosurfaceCreate {
                result(FlutterError(
                    code: "IOSURFACE_FAILED",
                    message: "IOSurface(properties:) returned nil",
                    details: nil))
            } catch TextureCreateError.cvpixelbufferCreate(let cvret) {
                result(FlutterError(
                    code: "CVPIXELBUFFER_FAILED",
                    message: "CVPixelBufferCreateWithIOSurface returned CVReturn=\(cvret)",
                    details: nil))
            } catch TextureCreateError.rendererCreate {
                result(FlutterError(
                    code: "RENDERER_FAILED",
                    message: "aether_splat_renderer_create returned NULL — see stderr for diagnostic (Dawn device init / IOSurface import / pipeline creation failed)",
                    details: nil))
            } catch {
                result(FlutterError(
                    code: "UNKNOWN_TEXTURE_ERROR",
                    message: "\(error)",
                    details: nil))
            }

        case "disposeTexture":
            guard let args = call.arguments as? [String: Any],
                  let id = (args["textureId"] as? NSNumber)?.int64Value else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "disposeTexture requires {textureId: int}",
                    details: nil))
                return
            }
            disposeTexture(id: id)
            result(nil)

        case "setMatrices":
            // Phase 6.4c — Dart pushes orbit/obj-derived matrices on
            // gesture events. We store them on the per-texture state;
            // the next displayLinkTick will read them.
            guard let args = call.arguments as? [String: Any],
                  let id = (args["textureId"] as? NSNumber)?.int64Value,
                  let viewData  = args["view"]  as? FlutterStandardTypedData,
                  let modelData = args["model"] as? FlutterStandardTypedData else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "setMatrices requires {textureId: int, view: Float32List(16), model: Float32List(16)}",
                    details: nil))
                return
            }
            guard let texture = registered[id] else {
                // Late call after dispose — silent ignore (gesture
                // events can race ahead of disposeTexture in shutdown).
                result(nil)
                return
            }
            // FlutterStandardTypedData carries Float32 as raw bytes; parse 16 floats.
            let viewArr  = viewData.data.toFloatArray()
            let modelArr = modelData.data.toFloatArray()
            texture.setMatrices(view: viewArr, model: modelArr)
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func disposeTexture(id: Int64) {
        if animatedTextureId == id {
            stopAnimation()
        }
        textures.unregisterTexture(id)
        registered.removeValue(forKey: id)
        // SharedNativeTexture's deinit calls aether_splat_renderer_destroy.
    }

    private func startAnimation(textureId: Int64, texture: SharedNativeTexture) {
        guard displayLink == nil else { return }
        animatedTextureId = textureId
        animatedTexture   = texture
        animationStart    = CACurrentMediaTime()
        frameStatsLogTime = animationStart
        frameCount        = 0

        if #available(macOS 14.0, *) {
            let dl = NSScreen.main?.displayLink(target: self, selector: #selector(displayLinkTick))
            dl?.add(to: .main, forMode: .common)
            displayLink = dl
        }
    }

    private func stopAnimation() {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.invalidate()
        }
        displayLink = nil
        animatedTextureId = nil
        animatedTexture = nil
    }

    @objc private func displayLinkTick() {
        guard let id = animatedTextureId,
              let texture = animatedTexture else { return }
        let now = CACurrentMediaTime()
        // Phase 6.4c: render uses Dart-pushed view/model matrices stored
        // on the texture (default identity until first gesture).
        texture.render()
        textures.textureFrameAvailable(id)

        frameCount += 1
        let dt = now - frameStatsLogTime
        if dt >= 1.0 {
            let fps = Double(frameCount) / dt
            NSLog("[AetherTexture] %.1f fps (frames=%d, dt=%.3f)", fps, frameCount, dt)
            frameStatsLogTime = now
            frameCount = 0
        }
    }
}

// ─── Float32List ↔ [Float] helper ─────────────────────────────────────

private extension Data {
    /// Decode the buffer's bytes as a `[Float]` (Float32 = 4 bytes each).
    /// Used to unpack `FlutterStandardTypedData(.float32)` from Dart.
    func toFloatArray() -> [Float] {
        let count = self.count / MemoryLayout<Float>.size
        return self.withUnsafeBytes { raw -> [Float] in
            let base = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: base.baseAddress, count: count))
        }
    }
}

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    AetherTexturePlugin.register(
      with: flutterViewController.registrar(forPlugin: "AetherTexturePlugin")
    )

    super.awakeFromNib()
  }
}
