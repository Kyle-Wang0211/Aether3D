import UIKit
import Flutter
import IOSurface
import Metal
import QuartzCore

// ─── Phase 5.1 — iOS port of Phase 4 macOS Flutter Texture plugin ──────
//
// 1:1 port of pocketworld_flutter/macos/Runner/MainFlutterWindow.swift
// (the AetherTexturePlugin + GradientTexture parts) with these API
// substitutions for iOS:
//   • import FlutterMacOS → import Flutter
//   • import Cocoa        → import UIKit (drives CACurrentMediaTime,
//                            otherwise both targets pull QuartzCore)
//   • NSScreen.main?.displayLink(target:selector:) (macOS 14+)
//                          → CADisplayLink(target:selector:) (iOS 3.1+)
//   • #available(macOS 14, *) wrappers around displayLink → removed
//                          (CADisplayLink predates iOS 4)
//   • registrar.messenger / registrar.textures (properties on macOS)
//                          → registrar.messenger() / registrar.textures()
//                            (methods on iOS)
//
// Lifecycle / sync / errors / observability fixes from chore commit
// 3370eb54 carry over verbatim — they're API-agnostic:
//   #1 disposeTexture clean tear-down
//   #2 waitUntilCompleted only on first render
//   #4 specific error codes per init failure point
//   #5 GPU command-buffer completion handler logs device errors
//
// When this file diverges from the macOS file, the divergence MUST be
// here in this header comment plus a TODO marker at the divergent line —
// otherwise future bugfixes go to one platform and the other rots.

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

/// Specific failure points during GradientTexture allocation. Each one
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
class GradientTexture: NSObject, FlutterTexture {
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
        // CVPixelBufferCreateWithIOSurface returns via Unmanaged
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
        cb.label = "GradientTexture.render"

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

        // GPU command-buffer completion handler. Catches device loss /
        // out-of-memory / shader runtime errors that would otherwise be
        // silent (the widget would just freeze on the last good frame).
        // For Phase 5.3 / production this should escalate back to Dart
        // via an event channel; for now logging is enough because this
        // surface is dev-only and a sustained 60 fps confirms no errors
        // are firing in the steady state.
        cb.addCompletedHandler { cmdBuf in
            if let error = cmdBuf.error {
                NSLog("[GradientTexture] GPU error: status=%d error=%@",
                      cmdBuf.status.rawValue, "\(error)")
            }
        }

        cb.commit()
        // Only wait on the first frame (so widget mounts on a populated
        // buffer). Steady state lets Metal pipeline overlap with the
        // next display-link tick — required to keep 60 fps once GPU work
        // grows past trivial.
        if !hasRenderedOnce {
            cb.waitUntilCompleted()
            hasRenderedOnce = true
        }
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        // CONTRACT: Flutter docs (Flutter 3.41.7) require passRetained;
        // Flutter's texture compositor releases the CVPixelBuffer after
        // the frame composes. If a future Flutter SDK upgrade changes
        // this contract, the symptom is silent CVPixelBuffer leaks
        // (Xcode → Debug Navigator → Memory of pocketworld_flutter
        // climbs). Re-verify on every Flutter SDK bump.
        return Unmanaged.passRetained(pixelBuffer)
    }
}

class AetherTexturePlugin: NSObject, FlutterPlugin {
    private let textures: FlutterTextureRegistry
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    // Hold strong refs so the textures aren't deallocated while Flutter
    // is consuming them. Keyed by textureId.
    private var registered: [Int64: GradientTexture] = [:]

    // Animation state. CADisplayLink is the canonical type on iOS (no
    // availability gate needed unlike the macOS port which guards macOS 14+).
    private var displayLink: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    private var animatedTextureId: Int64?
    private var animatedTexture: GradientTexture?
    private var frameCount: Int = 0
    private var frameStatsLogTime: CFTimeInterval = 0

    static func register(with registrar: FlutterPluginRegistrar) {
        // iOS API divergence: registrar.messenger() / .textures() are
        // methods on iOS, properties on macOS.
        let channel = FlutterMethodChannel(
            name: "aether_texture",
            binaryMessenger: registrar.messenger()
        )
        let device = MTLCreateSystemDefaultDevice()
        let queue  = device?.makeCommandQueue()
        let instance = AetherTexturePlugin(
            textures: registrar.textures(),
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

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {

        case "createGradientTexture":
            guard let device = device, let queue = commandQueue else {
                result(FlutterError(
                    code: "NO_METAL",
                    message: "MTLCreateSystemDefaultDevice returned nil",
                    details: nil
                ))
                return
            }
            do {
                let texture = try GradientTexture(device: device)
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

    /// Tear down a texture's lifecycle. Stops the display-link loop if
    /// it was animating this texture, unregisters from the
    /// FlutterTextureRegistry, drops our strong ref. Safe to call on an
    /// unknown id (no-op).
    private func disposeTexture(id: Int64) {
        if animatedTextureId == id {
            stopAnimation()
        }
        textures.unregisterTexture(id)
        registered.removeValue(forKey: id)
    }

    private func startAnimation(textureId: Int64, texture: GradientTexture) {
        guard displayLink == nil else { return }  // already running
        animatedTextureId = textureId
        animatedTexture   = texture
        animationStart    = CACurrentMediaTime()
        frameStatsLogTime = animationStart
        frameCount        = 0

        // iOS divergence: use CADisplayLink(target:selector:) initializer
        // directly. macOS 14+ requires NSScreen.main?.displayLink(...);
        // iOS has had CADisplayLink since 3.1.
        let dl = CADisplayLink(target: self, selector: #selector(displayLinkTick))
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }

    private func stopAnimation() {
        displayLink?.invalidate()
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

        // 1 Hz fps log. On iOS NSLog routes to os_log → Console.app /
        // Xcode debug console. (On macOS the Flutter GUI launch path
        // keeps NSLog on stderr only — see macOS plugin comment.)
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
