import Cocoa
import FlutterMacOS
import IOSurface
import Metal
import QuartzCore

// ─── Phase 4.1+4.5 + 4.2 + 4.3-degraded — Flutter Texture on macOS desktop ──
//
// 4.1+4.5 proved the FlutterTexture protocol → Texture(textureId:) widget
// pipeline using a CPU-filled CVPixelBuffer.
//
// 4.2 swapped the pixel source to an IOSurface wrapped simultaneously as
// CVPixelBuffer (Flutter reads) and MTLTexture (Metal writes). Zero copy.
//
// 4.3 (degraded path per D1: Dawn-iOS skipped under D2 macOS-first; Dawn
// vs Metal is implementation detail per DoD): Metal render pipeline draws
// a triangle into the shared MTLTexture instead of a clear color. Still
// rendered once at create-time; animation comes in the next commit (Step
// 5+6 — displayLink + per-frame textureFrameAvailable).

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

/// 256×256 BGRA8 native-GPU-written texture, exposed to Flutter through
/// FlutterTexture protocol via a shared IOSurface. Renders a colored
/// triangle (R/G/B at the three vertices, barycentric blend).
class GradientTexture: NSObject, FlutterTexture {
    private let pixelBuffer: CVPixelBuffer
    private let mtlTexture: MTLTexture
    private let renderPipeline: MTLRenderPipelineState

    init?(device: MTLDevice, width: Int = 256, height: Int = 256) {
        // 1. IOSurface
        let ioProps: [IOSurfacePropertyKey: Any] = [
            .width:           width,
            .height:          height,
            .pixelFormat:     Int(kCVPixelFormatType_32BGRA),
            .bytesPerElement: 4,
            .bytesPerRow:     width * 4,
        ]
        guard let ioSurface = IOSurface(properties: ioProps) else { return nil }

        // 2. CVPixelBuffer wrapping the IOSurface (Flutter reads).
        var pbUnmanaged: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, ioSurface, nil, &pbUnmanaged
        )
        guard status == kCVReturnSuccess,
              let buffer = pbUnmanaged?.takeRetainedValue() else { return nil }

        // 3. MTLTexture wrapping the SAME IOSurface (Metal writes).
        let texDesc = MTLTextureDescriptor()
        texDesc.pixelFormat = .bgra8Unorm
        texDesc.width  = width
        texDesc.height = height
        texDesc.usage  = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let texture = device.makeTexture(
            descriptor: texDesc, iosurface: ioSurface, plane: 0
        ) else { return nil }

        // 4. Compile shaders + build render pipeline state (one-time).
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: kTriangleShaderSource, options: nil)
        } catch {
            NSLog("GradientTexture: shader compile failed: \(error)")
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "vs_main"),
              let fragmentFn = library.makeFunction(name: "fs_main") else { return nil }

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction   = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDesc)
        else { return nil }

        self.pixelBuffer    = buffer
        self.mtlTexture     = texture
        self.renderPipeline = pipeline
        super.init()
    }

    /// Draw a triangle into the shared texture. `angle` rotates the
    /// vertex positions in-shader (radians).
    func render(commandQueue: MTLCommandQueue, angle: Float) {
        guard let cb = commandQueue.makeCommandBuffer() else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture     = mtlTexture
        pass.colorAttachments[0].loadAction  = .clear
        pass.colorAttachments[0].storeAction = .store
        // Same dark background as P1.7's hello_triangle.cpp.
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0
        )

        guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(renderPipeline)
        var a = angle
        encoder.setVertexBytes(&a, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        cb.commit()
        // No waitUntilCompleted in steady-state — Metal pipelines fine
        // running ahead. We do wait on the first render so Flutter doesn't
        // sample mid-write before any frame has landed.
        cb.waitUntilCompleted()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        // Flutter docs require passRetained: Flutter takes one reference,
        // balances it after the frame composes.
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

    // Animation state (Step 5+6: 60fps display-link-driven render).
    // displayLink stored as Any? to avoid hoisting CADisplayLink's
    // macOS 14.0 availability requirement onto the property declaration
    // (the Flutter macOS scaffold ships with deployment target 10.14).
    private var displayLink: Any?
    private var animationStart: CFTimeInterval = 0
    private var animatedTextureId: Int64?
    private var animatedTexture: GradientTexture?
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
            guard let texture = GradientTexture(device: device) else {
                result(FlutterError(
                    code: "TEXTURE_CREATE_FAILED",
                    message: "IOSurface / CVPixelBuffer / MTLTexture / pipeline allocation failed",
                    details: nil
                ))
                return
            }
            let id = textures.register(texture)
            registered[id] = texture
            // Render the first frame synchronously so the widget mounts on
            // a populated buffer, then hand over to the display-link loop
            // for steady-state animation.
            texture.render(commandQueue: queue, angle: 0)
            textures.textureFrameAvailable(id)
            startAnimation(textureId: id, texture: texture)
            result(NSNumber(value: id))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startAnimation(textureId: Int64, texture: GradientTexture) {
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
        // No fallback path — we know we're on macOS 26.1; if NSScreen.main
        // were nil at startup the app wouldn't be visible anyway.
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
        // sustained rate in Console.app or stderr.
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
