import Cocoa
import FlutterMacOS
import IOSurface
import QuartzCore
import CoreVideo  // CVPixelBuffer
import Darwin
import Metal

// ─── Phase 6.4b stage 2 — Scene IOSurface bridge (mesh + splat) ────────
//
// Phase 6.4a wired a splat-only renderer; stage 2 replaced it with the
// scene renderer (mesh PBR + splat overlay in a single IOSurface), and
// Phase 6.4 cleanup retired the legacy splat-only renderer entirely
// (scene renderer with no GLB loaded covers the splat-only case).
//
// FFI surface:
//   1. dlsym the aether_scene_renderer_* symbols.
//   2. loadGlb method-channel handler — Dart resolves the asset path
//      and pushes it down to C ABI aether_scene_renderer_load_glb().
//   3. render_full(view, model) per displayLink tick (no time-based fn).
//
// Mesh DOES respond to gesture matrices through Filament-style PBR. The
// splat overlay currently still uses hardcoded screen-space coords
// (Phase 6.4f tracks the upgrade to Brush full-pipeline integration).
//
// SharedNativeTexture's init / render / dispose remain thin wrappers
// over the C ABI in aether_cpp/include/aether/pocketworld/
// scene_iosurface_renderer.h:
//   aether_scene_renderer_create(iosurface, w, h)        — at construct
//   aether_scene_renderer_load_glb(handle, path)         — on demand
//   aether_scene_renderer_render_full(handle, view, model) — per tick
//   aether_scene_renderer_destroy(handle)                — at dispose
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
    typealias LoadGlbFn    = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> Bool
    typealias RenderFullFn = @convention(c) (OpaquePointer?, UnsafePointer<Float>, UnsafePointer<Float>) -> Void

    let create:     CreateFn
    let destroy:    DestroyFn
    let loadGlb:    LoadGlbFn
    let renderFull: RenderFullFn

    private static func ancestorDirectories(for path: String) -> [String] {
        guard !path.isEmpty else { return [] }
        let fm = FileManager.default
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            url.deleteLastPathComponent()
        }

        var results: [String] = []
        while true {
            let current = url.path
            if results.last != current {
                results.append(current)
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == current { break }
            url = parent
        }
        return results
    }

    private static func candidateLibraryPaths() -> [String] {
        var candidates: [String] = []
        var seen: Set<String> = []

        func add(_ path: String) {
            guard !path.isEmpty else { return }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            if seen.insert(normalized).inserted {
                candidates.append(normalized)
            }
        }

        if let frameworksPath = Bundle.main.privateFrameworksPath {
            add((frameworksPath as NSString).appendingPathComponent("libaether3d_ffi.dylib"))
        }

        let roots = [
            FileManager.default.currentDirectoryPath,
            Bundle.main.bundlePath,
            Bundle.main.executablePath ?? "",
        ]
        for root in roots {
            for ancestor in ancestorDirectories(for: root) {
                add((ancestor as NSString).appendingPathComponent("aether_cpp/build/libaether3d_ffi.dylib"))
                add((ancestor as NSString).appendingPathComponent("Contents/Frameworks/libaether3d_ffi.dylib"))
                add((ancestor as NSString).appendingPathComponent("Frameworks/libaether3d_ffi.dylib"))
            }
        }

        // Xcode Run launches the macOS app from DerivedData, not from
        // pocketworld_flutter/build. Those ancestors never include the
        // repo checkout, so keep an explicit dev-tree fallback for local
        // verification. Production still prefers Contents/Frameworks.
        add("/Users/kaidongwang/Documents/Aether3D-cross/aether_cpp/build/libaether3d_ffi.dylib")
        add("libaether3d_ffi.dylib")
        return candidates
    }

    /// Returns nil (with NSLog diagnostic) if the dylib can't be found
    /// or any of the required symbols isn't present.
    static let shared: FFI? = {
        // 1. Try RTLD_DEFAULT first — symbols are already in the process
        //    namespace if Flutter linked the dylib via build config.
        if let f = FFI(handle: UnsafeMutableRawPointer(bitPattern: -2)!) {
            return f
        }

        // 2. Walk from cwd + bundle/executable ancestors so direct
        //    `.app` launches still find the sibling aether_cpp/build dylib.
        let candidates = candidateLibraryPaths()
        var errors: [String] = []
        for path in candidates {
            if let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) {
                NSLog("[AetherFFI] dlopen succeeded: %@", path)
                if let f = FFI(handle: handle) { return f }
            } else if let cErr = dlerror() {
                errors.append("\(path) :: \(String(cString: cErr))")
            }
        }
        NSLog("[AetherFFI] FATAL: aether3d_ffi.dylib not found in any search path. "
            + "Tried %@",
              candidates.joined(separator: " | "))
        if !errors.isEmpty {
            NSLog("[AetherFFI] dlopen errors: %@", errors.joined(separator: " || "))
        }
        return nil
    }()

    private init?(handle: UnsafeMutableRawPointer) {
        guard let cSym  = dlsym(handle, "aether_scene_renderer_create"),
              let dSym  = dlsym(handle, "aether_scene_renderer_destroy"),
              let lgSym = dlsym(handle, "aether_scene_renderer_load_glb"),
              let rfSym = dlsym(handle, "aether_scene_renderer_render_full") else {
            return nil
        }
        self.create     = unsafeBitCast(cSym,  to: CreateFn.self)
        self.destroy    = unsafeBitCast(dSym,  to: DestroyFn.self)
        self.loadGlb    = unsafeBitCast(lgSym, to: LoadGlbFn.self)
        self.renderFull = unsafeBitCast(rfSym, to: RenderFullFn.self)
    }
}

// ─── Texture creation error codes ─────────────────────────────────────

private enum SurfacePixelConfig: String {
    case bgra8 = "BGRA8"
    case rgba16Half = "RGBA16F"

    var cvPixelFormat: OSType {
        switch self {
        case .bgra8:
            return kCVPixelFormatType_32BGRA
        case .rgba16Half:
            return kCVPixelFormatType_64RGBAHalf
        }
    }

    var bytesPerElement: Int {
        switch self {
        case .bgra8:
            return 4
        case .rgba16Half:
            return 8
        }
    }

    var mtlPixelFormat: MTLPixelFormat {
        switch self {
        case .bgra8:
            return .bgra8Unorm
        case .rgba16Half:
            return .rgba16Float
        }
    }
}

private enum MacDeviceTier: String {
    case flagship
    case high
    case mid
}

private struct MacDisplayCapabilities {
    let tier: MacDeviceTier
    let hardwareModel: String
    let preferredSurfaceConfig: SurfacePixelConfig
    let supportsEDR: Bool
    let supportsMetalFX: Bool
}

private func currentHardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
        return "unknown"
    }
    var model = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else {
        return "unknown"
    }
    return String(cString: model)
}

private func detectMacDeviceTier(model: String) -> MacDeviceTier {
    if model.contains("Mac15") || model.contains("Mac16") {
        return .flagship
    }
    if model.contains("Mac14") || model.contains("MacBookPro18") {
        return .high
    }
    return .mid
}

private func detectMacDisplayCapabilities() -> MacDisplayCapabilities {
    let model = currentHardwareModel()
    let tier = detectMacDeviceTier(model: model)
    let preferredSurfaceConfig: SurfacePixelConfig = (tier == .mid) ? .bgra8 : .rgba16Half
    let edrHeadroom =
        NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
    return MacDisplayCapabilities(
        tier: tier,
        hardwareModel: model,
        preferredSurfaceConfig: preferredSurfaceConfig,
        supportsEDR: edrHeadroom > 1.0,
        supportsMetalFX: ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        )
    )
}

private func firstMetalLayer(in layer: CALayer?) -> CAMetalLayer? {
    guard let layer else { return nil }
    if let metalLayer = layer as? CAMetalLayer {
        return metalLayer
    }
    for sublayer in layer.sublayers ?? [] {
        if let found = firstMetalLayer(in: sublayer) {
            return found
        }
    }
    return nil
}

private func firstMetalLayer(in view: NSView) -> CAMetalLayer? {
    if let layer = firstMetalLayer(in: view.layer) {
        return layer
    }
    for subview in view.subviews {
        if let layer = firstMetalLayer(in: subview) {
            return layer
        }
    }
    return nil
}

private func configureWideColorOutput(for view: NSView) {
    let caps = detectMacDisplayCapabilities()
    guard let metalLayer = firstMetalLayer(in: view) else {
        NSLog("[AetherTexture] WCG layer config skipped — CAMetalLayer not found")
        return
    }
    metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
    if caps.supportsEDR {
        metalLayer.wantsExtendedDynamicRangeContent = true
    }
    NSLog("[AetherTexture] output tier=%@ model=%@ surface=%@ edr=%@",
          caps.tier.rawValue,
          caps.hardwareModel,
          caps.preferredSurfaceConfig.rawValue,
          caps.supportsEDR.description)
}

private final class DrsController {
    private static let rollingWindow = 30
    private static let targetMs = 16.6
    private static let minScale = 0.5
    private static let maxScale = 1.0
    private static let decayRate = 0.05
    private static let recoveryRate = 0.02
    private static let hysteresisHigh = 1.1
    private static let hysteresisLow = 0.9

    private var recent = Array(repeating: 0.0, count: DrsController.rollingWindow)
    private var index = 0
    private var filled = 0
    private(set) var currentScale = 1.0
    private var enabled = false

    func onFrameDone(frameMs: Double) {
        guard enabled else { return }
        recent[index] = frameMs
        index = (index + 1) % Self.rollingWindow
        if filled < Self.rollingWindow { filled += 1 }
        guard filled >= 5 else { return }

        let avg = recent.prefix(filled).reduce(0, +) / Double(filled)
        if avg > Self.targetMs * Self.hysteresisHigh {
            currentScale = max(Self.minScale, currentScale - Self.decayRate)
        } else if avg < Self.targetMs * Self.hysteresisLow && currentScale < Self.maxScale {
            currentScale = min(Self.maxScale, currentScale + Self.recoveryRate)
        }
    }

    func renderSizeFor(nativeWidth: Int, nativeHeight: Int) -> (Int, Int) {
        guard enabled else { return (nativeWidth, nativeHeight) }
        let width = max(8, Int(Double(nativeWidth) * currentScale))
        let height = max(8, Int(Double(nativeHeight) * currentScale))
        return ((width + 7) & ~7, (height + 7) & ~7)
    }
}

enum TextureCreateError: Error {
    case ffiUnavailable              // dylib not found or symbols missing
    case iosurfaceCreate
    case cvpixelbufferCreate(CVReturn)
    case metalUnavailable
    case commandQueueCreate
    case mtltextureCreate(String)
    case upsamplerCreate(String)
    case rendererCreate              // C ABI returned NULL
}

/// 256×256 Flutter display texture with a separate render IOSurface.
/// Dawn renders into `renderSurface` (RGBA16F on high tiers), then MetalFX
/// or a bilinear Metal pass writes into the BGRA8 `displaySurface` that
/// FlutterMacOS can composite.
class SharedNativeTexture: NSObject, FlutterTexture {
    private let displayPixelBuffer: CVPixelBuffer
    private let displaySurface: IOSurfaceRef
    private let displayTexture: MTLTexture
    private let displayWidth: Int
    private let displayHeight: Int
    private let renderSurfaceConfig: SurfacePixelConfig
    private var renderSurface: IOSurfaceRef?
    private var renderTexture: MTLTexture?
    private var rendererHandle: OpaquePointer?
    private var renderWidth: Int = 0
    private var renderHeight: Int = 0
    private var hasRenderedOnce = false

    private let caps: MacDisplayCapabilities
    private let metalDevice: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let upsampler: MetalFXUpsampler
    private let drs = DrsController()
    private var loadedGlbPath: String?
    private var lastUpsampleMethod: MetalFXUpsampler.Method?
    private var lastLoggedScale: Double = 1.0

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

    private static func makeIOSurface(
        width: Int,
        height: Int,
        config: SurfacePixelConfig
    ) throws -> IOSurfaceRef {
        let ioProps: [IOSurfacePropertyKey: Any] = [
            .width:           width,
            .height:          height,
            .pixelFormat:     Int(config.cvPixelFormat),
            .bytesPerElement: config.bytesPerElement,
            .bytesPerRow:     width * config.bytesPerElement,
        ]
        guard let surface = IOSurface(properties: ioProps) else {
            throw TextureCreateError.iosurfaceCreate
        }
        return surface as IOSurfaceRef
    }

    private static func makeMetalTexture(
        device: MTLDevice,
        surface: IOSurfaceRef,
        width: Int,
        height: Int,
        config: SurfacePixelConfig,
        usage: MTLTextureUsage,
        label: String
    ) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: config.mtlPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.storageMode = .shared
        desc.usage = usage
        guard let texture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else {
            throw TextureCreateError.mtltextureCreate(label)
        }
        texture.label = label
        return texture
    }

    private static func makeDisplayResources(
        width: Int,
        height: Int,
        device: MTLDevice
    ) throws -> (CVPixelBuffer, IOSurfaceRef, MTLTexture) {
        let surfaceRef = try makeIOSurface(width: width, height: height, config: .bgra8)

        var pbUnmanaged: Unmanaged<CVPixelBuffer>?
        let cvStatus = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, surfaceRef, nil, &pbUnmanaged
        )
        guard cvStatus == kCVReturnSuccess,
              let buffer = pbUnmanaged?.takeRetainedValue() else {
            throw TextureCreateError.cvpixelbufferCreate(cvStatus)
        }

        let texture = try makeMetalTexture(
            device: device,
            surface: surfaceRef,
            width: width,
            height: height,
            config: .bgra8,
            usage: [.renderTarget, .shaderRead, .shaderWrite],
            label: "Aether display BGRA8"
        )
        return (buffer, surfaceRef, texture)
    }

    private static func makeRenderResources(
        width: Int,
        height: Int,
        ffi: FFI,
        device: MTLDevice,
        config: SurfacePixelConfig
    ) throws -> (IOSurfaceRef, MTLTexture, OpaquePointer) {
        let surfaceRef = try makeIOSurface(width: width, height: height, config: config)
        let texture = try makeMetalTexture(
            device: device,
            surface: surfaceRef,
            width: width,
            height: height,
            config: config,
            usage: [.renderTarget, .shaderRead, .shaderWrite],
            label: "Aether render \(config.rawValue)"
        )
        let surfaceVoidPtr = unsafeBitCast(surfaceRef, to: UnsafeMutableRawPointer.self)
        guard let handle = ffi.create(surfaceVoidPtr, UInt32(width), UInt32(height)) else {
            throw TextureCreateError.rendererCreate
        }
        return (surfaceRef, texture, handle)
    }

    init(width: Int = 256, height: Int = 256) throws {
        guard let ffi = FFI.shared else {
            throw TextureCreateError.ffiUnavailable
        }
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw TextureCreateError.metalUnavailable
        }
        guard let commandQueue = metalDevice.makeCommandQueue() else {
            throw TextureCreateError.commandQueueCreate
        }

        let caps = detectMacDisplayCapabilities()
        let display = try SharedNativeTexture.makeDisplayResources(
            width: width,
            height: height,
            device: metalDevice
        )
        let upsampler: MetalFXUpsampler
        do {
            upsampler = try MetalFXUpsampler(device: metalDevice)
        } catch {
            throw TextureCreateError.upsamplerCreate("\(error)")
        }

        self.displayPixelBuffer = display.0
        self.displaySurface = display.1
        self.displayTexture = display.2
        self.displayWidth = width
        self.displayHeight = height
        self.renderSurfaceConfig = caps.preferredSurfaceConfig
        self.caps = caps
        self.metalDevice = metalDevice
        self.commandQueue = commandQueue
        self.upsampler = upsampler
        self.ffi = ffi
        super.init()
        try ensureRenderResources(width: width, height: height)
        NSLog("[SharedNativeTexture] created tier=%@ model=%@ renderSurface=%@ displaySurface=BGRA8 metalfx=%@ edr=%@",
              caps.tier.rawValue,
              caps.hardwareModel,
              renderSurfaceConfig.rawValue,
              caps.supportsMetalFX.description,
              caps.supportsEDR.description)
    }

    deinit {
        // Free the renderer's GPU resources. C ABI is NULL-safe.
        // (aether_scene_renderer_destroy releases the GLB if loaded.)
        ffi.destroy(rendererHandle)
    }

    /// Render one frame using the stored latest view + model matrices.
    /// Driven from displayLinkTick. The matrices are updated via
    /// setMatrices() (called from Dart's gesture handlers via
    /// MethodChannel). Without any gesture, both default to identity.
    @discardableResult
    func render() -> Double {
        let frameStart = CACurrentMediaTime()
        let desired = drs.renderSizeFor(nativeWidth: displayWidth, nativeHeight: displayHeight)
        do {
            try ensureRenderResources(width: desired.0, height: desired.1)
        } catch {
            NSLog("[SharedNativeTexture] render resource resize failed: %@", "\(error)")
        }
        guard let rendererHandle, let renderTexture else {
            return 0.0
        }

        latestView.withUnsafeBufferPointer { viewBuf in
            latestModel.withUnsafeBufferPointer { modelBuf in
                ffi.renderFull(rendererHandle, viewBuf.baseAddress!, modelBuf.baseAddress!)
            }
        }
        upsampleToDisplay(input: renderTexture)
        hasRenderedOnce = true
        let frameMs = (CACurrentMediaTime() - frameStart) * 1000.0
        drs.onFrameDone(frameMs: frameMs)
        if abs(drs.currentScale - lastLoggedScale) >= 0.049 {
            lastLoggedScale = drs.currentScale
            NSLog("[SharedNativeTexture] DRS scale=%.2f render=%dx%d display=%dx%d frameMs=%.2f",
                  drs.currentScale,
                  renderWidth,
                  renderHeight,
                  displayWidth,
                  displayHeight,
                  frameMs)
        }
        return frameMs
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

    /// Load a .glb file (KhronosGroup glTF-Sample-Models compatible)
    /// for the mesh pass. Replaces any previously-loaded GLB. Returns
    /// false (with stderr diagnostic from C) on parse / GPU upload /
    /// validation failure — the caller should surface this via
    /// FlutterError so the UI doesn't silently render with no mesh.
    func loadGlb(path: String) -> Bool {
        loadedGlbPath = path
        guard let rendererHandle else { return false }
        return path.withCString { cPath in
            return ffi.loadGlb(rendererHandle, cPath)
        }
    }

    private let ffi: FFI

    private func ensureRenderResources(width: Int, height: Int) throws {
        if rendererHandle != nil,
           renderTexture != nil,
           renderWidth == width,
           renderHeight == height {
            return
        }

        let configs: [SurfacePixelConfig] =
            (renderSurfaceConfig == .bgra8) ? [.bgra8] : [.rgba16Half, .bgra8]
        var lastError: Error?

        for config in configs {
            do {
                let resources = try SharedNativeTexture.makeRenderResources(
                    width: width,
                    height: height,
                    ffi: ffi,
                    device: metalDevice,
                    config: config
                )
                if let loadedGlbPath {
                    let ok = loadedGlbPath.withCString { cPath in
                        ffi.loadGlb(resources.2, cPath)
                    }
                    if !ok {
                        ffi.destroy(resources.2)
                        throw TextureCreateError.rendererCreate
                    }
                }

                let oldHandle = rendererHandle
                renderSurface = resources.0
                renderTexture = resources.1
                rendererHandle = resources.2
                renderWidth = width
                renderHeight = height
                ffi.destroy(oldHandle)
                NSLog("[SharedNativeTexture] render surface ready %@ %dx%d",
                      config.rawValue,
                      width,
                      height)
                return
            } catch {
                lastError = error
                if config != configs.last {
                    NSLog("[SharedNativeTexture] render %@ init failed; trying BGRA8. Error=%@",
                          config.rawValue,
                          "\(error)")
                }
            }
        }

        throw lastError ?? TextureCreateError.rendererCreate
    }

    private func upsampleToDisplay(input: MTLTexture) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            NSLog("[SharedNativeTexture] Metal upsample command buffer creation failed")
            return
        }
        commandBuffer.label = "Aether render-to-display upsample"
        let preferMetalFX = caps.supportsMetalFX &&
            (input.width != displayTexture.width || input.height != displayTexture.height)
        let method = upsampler.encode(
            commandBuffer: commandBuffer,
            input: input,
            output: displayTexture,
            preferMetalFX: preferMetalFX
        )
        commandBuffer.commit()
        if lastUpsampleMethod != method {
            lastUpsampleMethod = method
            NSLog("[SharedNativeTexture] upsample method=%@ input=%dx%d output=%dx%d",
                  method.rawValue,
                  input.width,
                  input.height,
                  displayTexture.width,
                  displayTexture.height)
        }
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        // Same passRetained contract assertion as Phase 4 polish #3.
        copyCount &+= 1
        if copyCount % leakCheckIntervalCalls == 0 {
            let rc = CFGetRetainCount(displayPixelBuffer)
            if rc > leakCheckThresholdRefs {
                NSLog("[SharedNativeTexture] passRetained contract WARNING: pixelBuffer retainCount=%ld after %llu copyPixelBuffer calls. Flutter compositor may not be releasing.",
                      rc, copyCount)
            }
        }
        return Unmanaged.passRetained(displayPixelBuffer)
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

    // Phase 6.4c verification: counts setMatrices method-channel hits.
    // Used by the rate-limited NSLog in the setMatrices handler so
    // Console.app shows a sample of every ~30th gesture event without
    // drowning in 60 Hz output.
    private var setMatricesCallCount: UInt64 = 0

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
            } catch TextureCreateError.metalUnavailable {
                result(FlutterError(
                    code: "NO_METAL",
                    message: "MTLCreateSystemDefaultDevice returned nil",
                    details: nil))
            } catch TextureCreateError.commandQueueCreate {
                result(FlutterError(
                    code: "COMMAND_QUEUE_FAILED",
                    message: "MTLDevice.makeCommandQueue returned nil",
                    details: nil))
            } catch TextureCreateError.mtltextureCreate(let label) {
                result(FlutterError(
                    code: "MTLTEXTURE_FAILED",
                    message: "MTLDevice.makeTexture failed for \(label)",
                    details: nil))
            } catch TextureCreateError.upsamplerCreate(let message) {
                result(FlutterError(
                    code: "UPSAMPLER_FAILED",
                    message: message,
                    details: nil))
            } catch TextureCreateError.rendererCreate {
                result(FlutterError(
                    code: "RENDERER_FAILED",
                    message: "aether_scene_renderer_create returned NULL — see stderr for diagnostic (Dawn device init / IOSurface import / pipeline creation failed)",
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

        case "loadGlb":
            // Phase 6.4b stage 2 — Dart tells us which GLB to load (it
            // resolves the asset path from rootBundle into an absolute
            // filesystem path before calling, so we just hand it down to
            // the C ABI). Returns true on success, throws FlutterError on
            // failure so the Dart caller can surface the diagnostic
            // (silent = catastrophe rule from Phase 6.3a).
            guard let args = call.arguments as? [String: Any],
                  let id = (args["textureId"] as? NSNumber)?.int64Value,
                  let path = args["path"] as? String else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "loadGlb requires {textureId: int, path: String}",
                    details: nil))
                return
            }
            guard let texture = registered[id] else {
                result(FlutterError(
                    code: "NO_SUCH_TEXTURE",
                    message: "loadGlb called with textureId=\(id) which is not registered",
                    details: nil))
                return
            }
            let ok = texture.loadGlb(path: path)
            if !ok {
                result(FlutterError(
                    code: "GLB_LOAD_FAILED",
                    message: "aether_scene_renderer_load_glb returned false for path=\(path) — see stderr / Console.app for [Aether3D][scene_renderer] diagnostic (cgltf parse / mesh upload / texture upload failed)",
                    details: nil))
                return
            }
            NSLog("[AetherTexture] loadGlb succeeded: %@", path)
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

            // Phase 6.4c verification log — fires on every gesture event
            // (sparse, only when fingers move). Rate-limited to once every
            // 30 calls (~ every 0.5 s of continuous gesture) so Console
            // doesn't drown in 60 Hz output. The viewArr[12..14] columns
            // = column-major translation column (= camera-to-target offset
            // for OrbitControls' lookAt). The modelArr[12..14] columns =
            // object position. Both visibly change as you gesture, so a
            // glance at Console.app confirms the matrix-push chain works
            // even though splat_render.wgsl currently ignores them
            // visually (Phase 6.4b stage 2 wires the visual feedback).
            setMatricesCallCount &+= 1
            if setMatricesCallCount % 30 == 0 || setMatricesCallCount == 1 {
                if viewArr.count == 16 && modelArr.count == 16 {
                    NSLog("[AetherTexture] setMatrices #%llu  view_t=(%.2f, %.2f, %.2f) model_t=(%.2f, %.2f, %.2f)",
                          setMatricesCallCount,
                          viewArr[12], viewArr[13], viewArr[14],
                          modelArr[12], modelArr[13], modelArr[14])
                }
            }
            result(nil)

        case "pauseRendering":
            pauseRendering()
            result(nil)

        case "resumeRendering":
            resumeRendering()
            result(nil)

        case "getDeviceCapabilities":
            let caps = detectMacDisplayCapabilities()
            let scale = NSScreen.main?.backingScaleFactor ?? 1.0
            let frame = NSScreen.main?.frame ?? .zero
            result([
                "tier": caps.tier.rawValue,
                "hardwareModel": caps.hardwareModel,
                "nativeDisplayW": Int(frame.width * scale),
                "nativeDisplayH": Int(frame.height * scale),
                "baseRenderW": 256,
                "baseRenderH": 256,
                "wcgSupported": caps.preferredSurfaceConfig == .rgba16Half,
                "edrSupported": caps.supportsEDR,
                "metalfxSupported": caps.supportsMetalFX,
                "targetFps": 60,
            ])

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
        // SharedNativeTexture's deinit calls aether_scene_renderer_destroy.
    }

    private func pauseRendering() {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.isPaused = true
        }
        NSLog("[AetherTexturePlugin] paused")
    }

    private func resumeRendering() {
        if #available(macOS 14.0, *) {
            (displayLink as? CADisplayLink)?.isPaused = false
        }
        NSLog("[AetherTexturePlugin] resumed")
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
        let renderMs = texture.render()
        textures.textureFrameAvailable(id)

        frameCount += 1
        let dt = now - frameStatsLogTime
        if dt >= 1.0 {
            let fps = Double(frameCount) / dt
            NSLog("[AetherTexture] %.1f fps (frames=%d, dt=%.3f, renderMs=%.2f)",
                  fps,
                  frameCount,
                  dt,
                  renderMs)
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

    DispatchQueue.main.async {
      configureWideColorOutput(for: flutterViewController.view)
    }

    super.awakeFromNib()
  }
}
