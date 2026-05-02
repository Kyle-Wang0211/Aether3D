import UIKit
import Flutter

// ─── Final iOS port — Flutter Texture plugin glue ─────────────────────
//
// This file is the FlutterPlugin glue: method-channel routing, lifecycle
// hooks, CADisplayLink ticking. The renderer implementation lives in
// MetalRenderer.swift, which now wraps the shared C++ scene IOSurface
// renderer instead of the old Phase 5 triangle.
//
// 1:1 port of pocketworld_flutter/macos/Runner/MainFlutterWindow.swift
// (plugin parts) with these iOS API substitutions:
//   • import FlutterMacOS → import Flutter
//   • import Cocoa        → import UIKit
//   • NSScreen.main?.displayLink(target:selector:) (macOS 14+)
//                          → CADisplayLink(target:selector:) (iOS 3.1+)
//   • #available(macOS 14, *) wrappers around displayLink → removed
//                          (CADisplayLink predates iOS 4)
//   • registrar.messenger / registrar.textures (properties on macOS)
//                          → registrar.messenger() / registrar.textures()
//                            (methods on iOS)
//
// Lifecycle / sync / errors / observability fixes carry over — they're
// API-agnostic:
//   #1 disposeTexture clean tear-down
//   #2 pause/resume through CADisplayLink
//   #4 specific error codes per init/load failure point
//   #5 loud native diagnostics instead of silent blank texture
//
// Phase 5.3 also added 4 NotificationCenter lifecycle hooks (background,
// foreground, memory warning, thermal) + thermal-aware fps targeting.
// See applyThermalPolicy / handle*() below.

class AetherTexturePlugin: NSObject, FlutterPlugin {
    private let textures: FlutterTextureRegistry
    // Hold strong refs so the textures aren't deallocated while Flutter
    // is consuming them. Keyed by textureId.
    private var registered: [Int64: SharedNativeTexture] = [:]

    // Animation state. CADisplayLink is the canonical type on iOS (no
    // availability gate needed unlike the macOS port which guards macOS 14+).
    //
    // G4 NOTE: prior to this commit the displayLink rendered a single
    // `animatedTexture` per tick (Phase 6.4e single-renderer home-screen
    // pattern). The community feed needs every PostCard's texture to
    // render every frame, so the tick now iterates `registered`. The
    // animatedTextureId / animatedTexture fields are kept for
    // backward-compat of pause/resume + log lines but no longer gate
    // rendering.
    private var displayLink: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    private var animatedTextureId: Int64?
    private var animatedTexture: SharedNativeTexture?
    private var frameCount: Int = 0
    private var frameStatsLogTime: CFTimeInterval = 0

    // Phase 5.3 production hooks state.
    //
    // Target frame rate is driven by ProcessInfo.thermalState:
    //   .nominal / .fair  → 60 (full speed)
    //   .serious          → 30 (degrade gracefully, signal "device warm")
    //   .critical         → 0  (pause + warning UI)
    // Stored separately from CADisplayLink's preferredFramesPerSecond so
    // the policy is queryable without accessing displayLink directly.
    private var targetFps: Int = 60
    // True when a lifecycle event has paused the loop (background, critical
    // thermal). Distinct from `displayLink == nil` which means "never started"
    // vs `isPaused = true` which means "started but on hold; resume when
    // condition clears".
    private var isPaused: Bool = false
    // Channel used to push thermal/lifecycle warnings up to Dart. Created on
    // first register so failure to plumb it through (registrar can't make a
    // channel) doesn't crash the plugin.
    private var warningChannel: FlutterMethodChannel?

    static func register(with registrar: FlutterPluginRegistrar) {
        // iOS API divergence: registrar.messenger() / .textures() are
        // methods on iOS, properties on macOS.
        let channel = FlutterMethodChannel(
            name: "aether_texture",
            binaryMessenger: registrar.messenger()
        )
        // Phase 5.3: separate channel for native → Dart push (warnings,
        // lifecycle events). Co-named with the main channel for grep-ability.
        let warningChannel = FlutterMethodChannel(
            name: "aether_texture/warning",
            binaryMessenger: registrar.messenger()
        )
        let instance = AetherTexturePlugin(
            textures: registrar.textures(),
            warningChannel: warningChannel
        )
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(textures: FlutterTextureRegistry,
         warningChannel: FlutterMethodChannel? = nil) {
        self.textures = textures
        self.warningChannel = warningChannel
        super.init()

        // Phase 5.3 production lifecycle hooks. Registered eagerly so even
        // before the first texture is created, the plugin sees app-level
        // signals (e.g. memory warning during cold-start texture create
        // would be the worst time to ignore one).
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleMemoryWarning),
                       name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleThermalChange),
                       name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        // Initialize fps from current thermal state — could be .serious already
        // if the device was hot when the app launched.
        applyThermalPolicy(ProcessInfo.processInfo.thermalState, sourceLog: "init")
    }

    deinit {
        // Match alloc with free (Phase 4 review fix #1 generalized): unbind
        // every observer so a re-instantiated plugin doesn't double-fire.
        NotificationCenter.default.removeObserver(self)
    }

    /// Phase 4 polish #9: parse a texture-dimension arg from Dart side.
    /// Dart sends ints via NSNumber; FlutterMethodChannel may also surface
    /// them as Int / Int32 / Int64 depending on platform-channel codec
    /// version. Treat 0 / negative / unreasonably large (>4096) as
    /// invalid → fall back to default. 4096 cap is deliberate: bigger
    /// than max MTLTexture for any iPhone shipped through 2026, big
    /// enough to never be the real bottleneck.
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
            // Phase 4 polish #9: parametrize 256×256 hardcoded size. Dart
            // can pass {width, height} args derived from MediaQuery and
            // device pixel ratio; if absent or invalid, fall back to the
            // 256×256 default that's been the Phase 4/5 baseline.
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
                    message: "aether_scene_renderer_create returned NULL — see Xcode Console for [Aether3D][scene_renderer] diagnostic",
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
            guard texture.loadGlb(path: path) else {
                result(FlutterError(
                    code: "GLB_LOAD_FAILED",
                    message: "aether_scene_renderer_load_glb returned false for path=\(path)",
                    details: nil))
                return
            }
            // G4: surface the local-space AABB so the Flutter caller can
            // run its model-viewer fit. nil bounds = native side failed
            // to compute; Dart falls back to its own widget.cameraDistance.
            let bounds = texture.getBounds()
            if let b = bounds {
                NSLog("[AetherTexture iOS] loadGlb succeeded: %@ bounds=([%.2f..%.2f],[%.2f..%.2f],[%.2f..%.2f])",
                      path, b.minX, b.maxX, b.minY, b.maxY, b.minZ, b.maxZ)
                result([
                    "bounds": [
                        "minX": Double(b.minX),
                        "minY": Double(b.minY),
                        "minZ": Double(b.minZ),
                        "maxX": Double(b.maxX),
                        "maxY": Double(b.maxY),
                        "maxZ": Double(b.maxZ),
                    ]
                ])
            } else {
                NSLog("[AetherTexture iOS] loadGlb succeeded: %@ (no bounds)", path)
                result([:])
            }

        // Phase 6.4f STUB. Native side returns false until the Brush
        // 8-kernel pipeline lands. Dart-side catch surfaces this as
        // "splat preview coming soon" placeholder. Both PLY and SPZ
        // share the same routing — the file extension already routed
        // them to the right method on the Flutter side.
        case "loadPly":
            guard let args = call.arguments as? [String: Any],
                  let id = (args["textureId"] as? NSNumber)?.int64Value,
                  let path = args["path"] as? String else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "loadPly requires {textureId: int, path: String}",
                    details: nil))
                return
            }
            guard let texture = registered[id] else {
                result(FlutterError(
                    code: "NO_SUCH_TEXTURE",
                    message: "loadPly called with textureId=\(id) which is not registered",
                    details: nil))
                return
            }
            // Phase 6.4f.3.b — accept memory caps from Dart side.
            let maxSplats = (args["maxSplats"] as? NSNumber)?.uint32Value ?? 0
            let maxShDegree = (args["maxShDegree"] as? NSNumber)?.uint8Value ?? 3
            if !texture.loadPly(path: path,
                                maxSplats: maxSplats,
                                maxShDegree: maxShDegree) {
                result(FlutterError(
                    code: "PLY_LOAD_FAILED",
                    message: "aether_scene_renderer_load_ply returned false for path=\(path)",
                    details: nil))
                return
            }
            // Surface splat-scene AABB so AetherCppCardDemo can fit
            // the camera. Same pattern as loadGlb / loadSpz.
            let plyBounds = texture.getBounds()
            if let b = plyBounds {
                NSLog("[AetherTexture iOS] loadPly succeeded: %@ bounds=([%.2f..%.2f],[%.2f..%.2f],[%.2f..%.2f])",
                      path, b.minX, b.maxX, b.minY, b.maxY, b.minZ, b.maxZ)
                result([
                    "bounds": [
                        "minX": Double(b.minX),
                        "minY": Double(b.minY),
                        "minZ": Double(b.minZ),
                        "maxX": Double(b.maxX),
                        "maxY": Double(b.maxY),
                        "maxZ": Double(b.maxZ),
                    ]
                ])
            } else {
                NSLog("[AetherTexture iOS] loadPly succeeded: %@ (no bounds)", path)
                result([:])
            }

        case "loadSpz":
            guard let args = call.arguments as? [String: Any],
                  let id = (args["textureId"] as? NSNumber)?.int64Value,
                  let path = args["path"] as? String else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "loadSpz requires {textureId: int, path: String}",
                    details: nil))
                return
            }
            guard let texture = registered[id] else {
                result(FlutterError(
                    code: "NO_SUCH_TEXTURE",
                    message: "loadSpz called with textureId=\(id) which is not registered",
                    details: nil))
                return
            }
            // Phase 6.4f.3.b — accept memory caps from Dart side.
            let maxSplats = (args["maxSplats"] as? NSNumber)?.uint32Value ?? 0
            let maxShDegree = (args["maxShDegree"] as? NSNumber)?.uint8Value ?? 3
            if !texture.loadSpz(path: path,
                                maxSplats: maxSplats,
                                maxShDegree: maxShDegree) {
                result(FlutterError(
                    code: "SPZ_LOAD_FAILED",
                    message: "aether_scene_renderer_load_spz returned false for path=\(path)",
                    details: nil))
                return
            }
            // Surface splat-scene AABB so AetherCppCardDemo can fit
            // the camera (same shape as loadGlb above). Without this,
            // Dart falls back to widget.fallbackCameraDistance and
            // the camera ends up INSIDE the splat cloud — see the
            // 2026-05-02 user-reported "灰雾" / no-bounds bug.
            let spzBounds = texture.getBounds()
            if let b = spzBounds {
                NSLog("[AetherTexture iOS] loadSpz succeeded: %@ bounds=([%.2f..%.2f],[%.2f..%.2f],[%.2f..%.2f])",
                      path, b.minX, b.maxX, b.minY, b.maxY, b.minZ, b.maxZ)
                result([
                    "bounds": [
                        "minX": Double(b.minX),
                        "minY": Double(b.minY),
                        "minZ": Double(b.minZ),
                        "maxX": Double(b.maxX),
                        "maxY": Double(b.maxY),
                        "maxZ": Double(b.maxZ),
                    ]
                ])
            } else {
                NSLog("[AetherTexture iOS] loadSpz succeeded: %@ (no bounds)", path)
                result([:])
            }

        case "setMatrices":
            guard let args = call.arguments as? [String: Any],
                  let id = (args["textureId"] as? NSNumber)?.int64Value,
                  let viewData = args["view"] as? FlutterStandardTypedData,
                  let modelData = args["model"] as? FlutterStandardTypedData else {
                result(FlutterError(
                    code: "BAD_ARGS",
                    message: "setMatrices requires {textureId: int, view: Float32List(16), model: Float32List(16)}",
                    details: nil))
                return
            }
            guard let texture = registered[id] else {
                // Late gesture after dispose; safe no-op.
                result(nil)
                return
            }
            texture.setMatrices(
                view: viewData.data.toFloatArray(),
                model: modelData.data.toFloatArray()
            )
            result(nil)

        case "pauseRendering":
            pauseAnimation(reason: "dart lifecycle")
            result(nil)

        case "resumeRendering":
            applyThermalPolicy(ProcessInfo.processInfo.thermalState, sourceLog: "dart lifecycle")
            if !isCriticalThermal(ProcessInfo.processInfo.thermalState) {
                resumeAnimation(reason: "dart lifecycle")
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Tear down a texture's lifecycle. Unregisters from the
    /// FlutterTextureRegistry, drops our strong ref. Safe to call on an
    /// unknown id (no-op).
    ///
    /// G4: only stop the display-link loop when EVERY registered
    /// texture is gone. The feed runs many textures concurrently —
    /// disposing one card mustn't pause the other cards' animation.
    private func disposeTexture(id: Int64) {
        textures.unregisterTexture(id)
        registered.removeValue(forKey: id)
        if animatedTextureId == id {
            animatedTextureId = nil
            animatedTexture = nil
        }
        if registered.isEmpty {
            stopAnimation()
        }
    }

    private func startAnimation(textureId: Int64, texture: SharedNativeTexture) {
        guard displayLink == nil else { return }  // already running
        animatedTextureId = textureId
        animatedTexture   = texture
        animationStart    = CACurrentMediaTime()
        frameStatsLogTime = animationStart
        frameCount        = 0
        isPaused          = false

        // iOS divergence: use CADisplayLink(target:selector:) initializer
        // directly. macOS 14+ requires NSScreen.main?.displayLink(...);
        // iOS has had CADisplayLink since 3.1.
        let dl = CADisplayLink(target: self, selector: #selector(displayLinkTick))
        dl.preferredFramesPerSecond = targetFps  // Phase 5.3: thermal-aware
        dl.add(to: .main, forMode: .common)
        displayLink = dl
        NSLog("[AetherTexture] startAnimation targetFps=%d", targetFps)
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        animatedTextureId = nil
        animatedTexture = nil
        isPaused = false
    }

    // ─── Phase 5.3 lifecycle / thermal handlers ─────────────────────────

    /// Pause the displayLink without losing animatedTexture state. Reverse
    /// with `resumeAnimation`. Distinct from `stopAnimation` (which fully
    /// tears down). iOS prohibits GPU work while in background; failing to
    /// pause = mysterious crash on resume in some iOS versions.
    private func pauseAnimation(reason: String) {
        guard let dl = displayLink, !isPaused else { return }
        dl.isPaused = true
        isPaused = true
        NSLog("[AetherTexture] pauseAnimation reason=%@", reason)
    }

    private func resumeAnimation(reason: String) {
        guard let dl = displayLink, isPaused else { return }
        dl.isPaused = false
        isPaused = false
        NSLog("[AetherTexture] resumeAnimation reason=%@", reason)
    }

    @objc private func handleBackground() {
        pauseAnimation(reason: "background")
    }

    @objc private func handleForeground() {
        // Re-evaluate thermal first — device may have cooled while in background,
        // OR may have heated up if we were quickly toggled.
        applyThermalPolicy(ProcessInfo.processInfo.thermalState, sourceLog: "foreground")
        if !isCriticalThermal(ProcessInfo.processInfo.thermalState) {
            resumeAnimation(reason: "foreground")
        }
    }

    @objc private func handleMemoryWarning() {
        // Selective LRU dispose: keep the most-recently-rendered
        // texture (= the focused card the user is actively looking at)
        // alive so they DON'T see a flash. Dispose the rest — those
        // are static cards behind/ahead in scroll that the user can't
        // currently see; their PostCard will lazily remount on
        // visibility-detector signal when scrolled back.
        //
        // Why this matters: previous behavior disposed ALL textures
        // including the focused one. The Dart-side warning handler
        // would then trigger a full rebuild (create → load → fit →
        // render), and the user saw the loading-cover crossfade as
        // their visible model briefly disappeared. Unacceptable UX
        // per 2026-05-02 user feedback.
        //
        // "Most recently rendered" = highest lastRenderTimestamp.
        // SharedNativeTexture tracks this in its render() method.
        // Static cards that load once + sleep have an old timestamp;
        // the focused card (Ticker driving setMatrices each frame)
        // has the newest.
        let total = registered.count
        guard total > 0 else { return }
        var sortedByRecency = registered.sorted { lhs, rhs in
            lhs.value.lastRenderTimestamp > rhs.value.lastRenderTimestamp
        }
        // Keep the most recent ONE (the focused card). Dispose the
        // rest. Tighten this if memory pressure is severe (e.g. keep
        // 0 in critical), but for typical iOS warnings 1 is enough.
        let keepCount = 1
        let disposeIds = sortedByRecency.dropFirst(keepCount).map { $0.key }
        NSLog("[AetherTexture] memory warning — disposing %d/%d textures (keeping focused)",
              disposeIds.count, total)
        warningChannel?.invokeMethod("warning", arguments: [
            "kind": "memory",
            "disposedIds": disposeIds.map { NSNumber(value: $0) },
            "message": "Memory warning — non-focused textures released"
        ])
        for id in disposeIds {
            disposeTexture(id: id)
        }
    }

    @objc private func handleThermalChange() {
        applyThermalPolicy(ProcessInfo.processInfo.thermalState, sourceLog: "thermalDidChange")
    }

    /// Maps thermalState → fps target + pause behavior. Pure function-style:
    /// caller passes the state explicitly so init-time and notification-time
    /// share the same logic. `sourceLog` lets the log distinguish entry points.
    private func applyThermalPolicy(_ state: ProcessInfo.ThermalState, sourceLog: String) {
        let newFps: Int
        let warning: String?
        switch state {
        case .nominal, .fair:
            newFps = 60
            warning = nil
        case .serious:
            newFps = 30
            warning = "Performance reduced (device warm)"
        case .critical:
            newFps = 0
            warning = "Animation paused (device too hot)"
        @unknown default:
            // Future-proofing: treat unknown as nominal so a new thermalState
            // doesn't accidentally pause the animation forever.
            newFps = 60
            warning = nil
        }
        let stateName = thermalStateName(state)
        NSLog("[AetherTexture] thermal=%@ targetFps=%d source=%@", stateName, newFps, sourceLog)

        targetFps = newFps
        if let dl = displayLink {
            dl.preferredFramesPerSecond = max(newFps, 1)  // 0 not legal
        }
        if newFps == 0 {
            pauseAnimation(reason: "thermal=\(stateName)")
        } else if !isPaused {
            // Don't auto-resume from background-triggered pause; only thermal
            // pause is auto-released here.
            // (resumeAnimation is a no-op if not paused.)
        }
        if let w = warning {
            warningChannel?.invokeMethod("warning", arguments: [
                "kind": "thermal",
                "state": stateName,
                "message": w
            ])
        }
    }

    private func isCriticalThermal(_ state: ProcessInfo.ThermalState) -> Bool {
        if case .critical = state { return true }
        return false
    }

    private func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    @objc private func displayLinkTick() {
        // G4: render every registered texture, not just animatedTexture.
        // The community feed mounts one renderer per PostCard; each
        // needs to advance every frame.
        //
        // G4-bugfix: only render textures whose `dirty` flag is set
        // (consumeIfDirty flips it back to false). Without this,
        // displayLinkTick re-renders every IOSurface every tick even
        // when matrices haven't changed — at N=5 cards × 60fps that's
        // 300 IOSurface→MTLTexture re-imports per second, which trips
        // an iOS 17+ Dawn assertion in dawn::native::metal::
        // SharedTextureMemory::CreateMtlTextures (see SharedNativeTexture
        // for the full diagnosis). The Dart Ticker on the focused
        // (auto-rotating) card calls setMatrices every Flutter frame
        // and stays dirty, so visually the focused card animates at
        // ~60fps as before; static cards render exactly once after
        // load and then stop.
        if registered.isEmpty { return }
        let now = CACurrentMediaTime()
        var totalRenderMs: Double = 0
        var rendered = 0
        let count = registered.count
        for (id, texture) in registered {
            if !texture.consumeIfDirty() { continue }
            totalRenderMs += texture.render()
            textures.textureFrameAvailable(id)
            rendered += 1
        }

        // 1 Hz fps log. On iOS NSLog routes to os_log → Console.app /
        // Xcode debug console. (On macOS the Flutter GUI launch path
        // keeps NSLog on stderr only — see macOS plugin comment.)
        frameCount += 1
        let dt = now - frameStatsLogTime
        if dt >= 1.0 {
            let fps = Double(frameCount) / dt
            NSLog("[AetherTexture] %.1f fps (frames=%d, dt=%.3f, totalRenderMs=%.2f, textures=%d, rendered=%d)",
                  fps,
                  frameCount,
                  dt,
                  totalRenderMs,
                  count,
                  rendered)
            frameStatsLogTime = now
            frameCount = 0
        }
    }
}

private extension Data {
    func toFloatArray() -> [Float] {
        let count = self.count / MemoryLayout<Float>.size
        return self.withUnsafeBytes { raw -> [Float] in
            let base = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: base.baseAddress, count: count))
        }
    }
}
