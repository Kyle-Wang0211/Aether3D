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
            NSLog("[AetherTexture iOS] loadGlb succeeded: %@", path)
            result(nil)

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
        // Drop all GPU resources. Flutter's _HomeScreenState catches the
        // MissingPluginException-style symptom on its next createSharedNativeTexture
        // call (or repaints with the existing _textureError state).
        NSLog("[AetherTexture] memory warning — disposing %d textures", registered.count)
        warningChannel?.invokeMethod("warning", arguments: [
            "kind": "memory",
            "message": "Memory warning — textures released; widget will rebuild"
        ])
        for id in Array(registered.keys) {
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
        // needs to advance every frame. Iteration order is whatever the
        // dictionary returns — order doesn't matter because each
        // texture is independent (no shared GPU state across them
        // beyond what aether_cpp's shared anchor manages internally).
        if registered.isEmpty { return }
        let now = CACurrentMediaTime()
        var totalRenderMs: Double = 0
        let count = registered.count
        for (id, texture) in registered {
            totalRenderMs += texture.render()
            textures.textureFrameAvailable(id)
        }

        // 1 Hz fps log. On iOS NSLog routes to os_log → Console.app /
        // Xcode debug console. (On macOS the Flutter GUI launch path
        // keeps NSLog on stderr only — see macOS plugin comment.)
        frameCount += 1
        let dt = now - frameStatsLogTime
        if dt >= 1.0 {
            let fps = Double(frameCount) / dt
            NSLog("[AetherTexture] %.1f fps (frames=%d, dt=%.3f, totalRenderMs=%.2f, textures=%d)",
                  fps,
                  frameCount,
                  dt,
                  totalRenderMs,
                  count)
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
