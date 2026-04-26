import Cocoa
import FlutterMacOS
import IOSurface
import Metal
import QuartzCore

// ─── Phase 4 — Flutter Texture widget on macOS desktop ─────────────────
//
// Pipeline: Swift Metal (vs/fs MSL) writes an IOSurface-backed MTLTexture;
// Flutter samples the same IOSurface zero-copy via a CVPixelBuffer wrapper
// returned from FlutterTexture.copyPixelBuffer(). 60 fps animation driven
// by NSScreen's CADisplayLink.
//
// Post-DoD polish landed in this file (separate chore commit, not a
// Phase 4.7 sub-step):
//   #1 disposeTexture lifecycle path so repeated create calls don't leak
//   #2 waitUntilCompleted only on first render (not per frame in steady state)
//   #4 specific error codes per failure point (instead of one umbrella)
//   #5 GPU command-buffer completion handler logs device errors

private let kTriangleShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float3 color;
};

vertex VertexOut vs_main(uint vid [[vertex_id]],
                          constant float& angle [[buffer(0)]]) {
    float2 positions[3] = {
        float2( 0.0,  0.7),
        float2(-0.7, -0.7),
        float2( 0.7, -0.7),
    };
    float3 colors[3] = {
        float3(1.0, 0.0, 0.0),
        float3(0.0, 1.0, 0.0),
        float3(0.0, 0.0, 1.0),
    };
    float c = cos(angle);
    float s = sin(angle);
    float2 p = positions[vid];
    p = float2(c * p.x - s * p.y, s * p.x + c * p.y);

    VertexOut out;
    out.position = float4(p, 0.0, 1.0);
    out.color    = colors[vid];
    return out;
}

fragment float4 fs_main(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
"""

/// Specific failure points during SharedNativeTexture allocation. Each one
/// maps to a distinct FlutterError code so a Dart-side log identifies
/// the exact failure without binary-search bisection through the init.
enum TextureCreateError: Error {
    case iosurfaceCreate
    case cvpixelbufferCreate(CVReturn)
    case mtlTextureCreate
    case shaderCompile(Error)
    case shaderFunctionMissing(String)
    case renderPipelineCreate(Error)
}

/// 256×256 BGRA8 native-GPU-written texture, exposed to Flutter through
/// FlutterTexture protocol via a shared IOSurface. Renders a colored
/// triangle (R/G/B at the three vertices, barycentric blend).
class SharedNativeTexture: NSObject, FlutterTexture {
    private let pixelBuffer: CVPixelBuffer
    private let mtlTexture: MTLTexture
    private let renderPipeline: MTLRenderPipelineState
    private var hasRenderedOnce = false

    init(device: MTLDevice, width: Int = 256, height: Int = 256) throws {
        // 1. IOSurface
        let ioProps: [IOSurfacePropertyKey: Any] = [
            .width:           width,
            .height:          height,
            .pixelFormat:     Int(kCVPixelFormatType_32BGRA),
            .bytesPerElement: 4,
            .bytesPerRow:     width * 4,
        ]
        guard let ioSurface = IOSurface(properties: ioProps) else {
            throw TextureCreateError.iosurfaceCreate
        }

        // 2. CVPixelBuffer wrapping the IOSurface (Flutter reads).
        // Note: CVPixelBufferCreateWithIOSurface returns via Unmanaged
        // (unlike the plain-Optional CVPixelBufferCreate); takeRetainedValue
        // balances the +1 refcount the API hands us.
        var pbUnmanaged: Unmanaged<CVPixelBuffer>?
        let cvStatus = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, ioSurface, nil, &pbUnmanaged
        )
        guard cvStatus == kCVReturnSuccess,
              let buffer = pbUnmanaged?.takeRetainedValue() else {
            throw TextureCreateError.cvpixelbufferCreate(cvStatus)
        }

        // 3. MTLTexture wrapping the SAME IOSurface (Metal writes).
        let texDesc = MTLTextureDescriptor()
        texDesc.pixelFormat = .bgra8Unorm
        texDesc.width  = width
        texDesc.height = height
        texDesc.usage  = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let texture = device.makeTexture(
            descriptor: texDesc, iosurface: ioSurface, plane: 0
        ) else {
            throw TextureCreateError.mtlTextureCreate
        }

        // 4. Compile shaders.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: kTriangleShaderSource, options: nil)
        } catch {
            throw TextureCreateError.shaderCompile(error)
        }
        guard let vertexFn = library.makeFunction(name: "vs_main") else {
            throw TextureCreateError.shaderFunctionMissing("vs_main")
        }
        guard let fragmentFn = library.makeFunction(name: "fs_main") else {
            throw TextureCreateError.shaderFunctionMissing("fs_main")
        }

        // 5. Render pipeline state.
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction   = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            throw TextureCreateError.renderPipelineCreate(error)
        }

        self.pixelBuffer    = buffer
        self.mtlTexture     = texture
        self.renderPipeline = pipeline
        super.init()
    }

    /// Draw a triangle into the shared texture. `angle` rotates vertex
    /// positions in-shader (radians). Synchronous on the FIRST frame so
    /// the widget mounts on populated content; async thereafter so the
    /// 60 Hz display-link tick doesn't block on GPU completion.
    func render(commandQueue: MTLCommandQueue, angle: Float) {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        cb.label = "SharedNativeTexture.render"

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture     = mtlTexture
        pass.colorAttachments[0].loadAction  = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0
        )

        guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "triangle pass"
        encoder.setRenderPipelineState(renderPipeline)
        var a = angle
        encoder.setVertexBytes(&a, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // Fix #5: GPU command-buffer completion handler. Catches device
        // loss / out-of-memory / shader runtime errors that would
        // otherwise be silent (the widget would just freeze on the last
        // good frame). For Phase 5 / splat workloads this should escalate
        // back to Dart via an event channel; for now logging is enough
        // because this surface is dev-only and a sustained 60 fps
        // confirms no errors are firing in the steady state.
        cb.addCompletedHandler { cmdBuf in
            if let error = cmdBuf.error {
                NSLog("[SharedNativeTexture] GPU error: status=%d error=%@",
                      cmdBuf.status.rawValue, "\(error)")
            }
        }

        cb.commit()
        // Fix #2: only wait on the first frame (so widget mounts on a
        // populated buffer). Steady state lets Metal pipeline overlap
        // with the next display-link tick — required to keep 60 fps once
        // GPU work grows past trivial (Phase 5 splat: ~5–10 ms per frame
        // on M3 Pro instead of ~0.1 ms for one triangle).
        if !hasRenderedOnce {
            cb.waitUntilCompleted()
            hasRenderedOnce = true
        }
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        // CONTRACT: Flutter docs (FlutterMacOS 3.41.7) require passRetained;
        // Flutter's texture compositor releases the CVPixelBuffer after
        // the frame composes. If a future Flutter SDK upgrade changes
        // this contract, the symptom is silent CVPixelBuffer leaks
        // (Activity Monitor → Memory of pocketworld_flutter climbs).
        // Re-verify on every Flutter SDK bump.
        return Unmanaged.passRetained(pixelBuffer)
    }
}

class AetherTexturePlugin: NSObject, FlutterPlugin {
    private let textures: FlutterTextureRegistry
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    // Hold strong refs so the textures aren't deallocated while Flutter
    // is consuming them. Keyed by textureId.
    private var registered: [Int64: SharedNativeTexture] = [:]

    // Animation state. displayLink stored as Any? to avoid hoisting
    // CADisplayLink's macOS 14.0 availability requirement onto the
    // property declaration (Flutter scaffold deployment target is 10.14).
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
        let device = MTLCreateSystemDefaultDevice()
        let queue  = device?.makeCommandQueue()
        let instance = AetherTexturePlugin(
            textures: registrar.textures,
            device:   device,
            commandQueue: queue
        )
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(textures: FlutterTextureRegistry, device: MTLDevice?, commandQueue: MTLCommandQueue?) {
        self.textures = textures
        self.device = device
        self.commandQueue = commandQueue
        super.init()
    }

    /// Phase 4 polish #9: parse a texture-dimension arg from Dart side.
    /// Same shape as the iOS plugin's parseTextureDimension; kept inline
    /// here (vs shared helper) because the macOS plugin lives in
    /// MainFlutterWindow.swift while the iOS plugin lives in
    /// AetherTexturePlugin.swift — no module to share through.
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
            guard let device = device, let queue = commandQueue else {
                result(FlutterError(
                    code: "NO_METAL",
                    message: "MTLCreateSystemDefaultDevice returned nil",
                    details: nil
                ))
                return
            }
            // Phase 4 polish #9: parametrize 256×256 hardcoded size.
            let args = call.arguments as? [String: Any] ?? [:]
            let width  = parseTextureDimension(args["width"],  default: 256)
            let height = parseTextureDimension(args["height"], default: 256)
            do {
                let texture = try SharedNativeTexture(device: device, width: width, height: height)
                let id = textures.register(texture)
                registered[id] = texture
                texture.render(commandQueue: queue, angle: 0)
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
            } catch TextureCreateError.mtlTextureCreate {
                result(FlutterError(
                    code: "MTLTEXTURE_FAILED",
                    message: "device.makeTexture(descriptor:iosurface:plane:) returned nil",
                    details: nil))
            } catch TextureCreateError.shaderCompile(let err) {
                result(FlutterError(
                    code: "SHADER_COMPILE_FAILED",
                    message: "device.makeLibrary(source:options:) threw: \(err)",
                    details: nil))
            } catch TextureCreateError.shaderFunctionMissing(let name) {
                result(FlutterError(
                    code: "SHADER_FUNCTION_MISSING",
                    message: "library.makeFunction(name: \"\(name)\") returned nil",
                    details: nil))
            } catch TextureCreateError.renderPipelineCreate(let err) {
                result(FlutterError(
                    code: "PIPELINE_FAILED",
                    message: "device.makeRenderPipelineState threw: \(err)",
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

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    /// Fix #1: tear down a texture's lifecycle. Stops the display-link
    /// loop if it was animating this texture, unregisters from the
    /// FlutterTextureRegistry, drops our strong ref. Safe to call on an
    /// unknown id (no-op).
    private func disposeTexture(id: Int64) {
        if animatedTextureId == id {
            stopAnimation()
        }
        textures.unregisterTexture(id)
        registered.removeValue(forKey: id)
    }

    private func startAnimation(textureId: Int64, texture: SharedNativeTexture) {
        guard displayLink == nil else { return }  // already running
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
        guard let queue = commandQueue,
              let id = animatedTextureId,
              let texture = animatedTexture else { return }
        let now     = CACurrentMediaTime()
        let elapsed = Float(now - animationStart)
        // ~1 rad/sec rotation; full revolution every ~6.28 s.
        texture.render(commandQueue: queue, angle: elapsed)
        textures.textureFrameAvailable(id)

        // 1 Hz fps log so the DoD verification window can see the
        // sustained rate in stderr (run binary directly to capture; not
        // surfaced to unified log because NSLog in Flutter's GUI launch
        // path stays on stderr only).
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
