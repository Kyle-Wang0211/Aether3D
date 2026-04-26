import Cocoa
import FlutterMacOS
import IOSurface
import Metal

// ─── Phase 4.1+4.5 + 4.2 — Flutter Texture widget on macOS desktop ──────
//
// 4.1+4.5 proved the FlutterTexture protocol → Texture(textureId:) widget
// pipeline using a CPU-filled CVPixelBuffer.
//
// 4.2 swaps the pixel source: now the CVPixelBuffer is wrapped around an
// IOSurface, the same IOSurface is also wrapped as an MTLTexture, and we
// fill via Metal's render encoder. Zero copy — Metal writes the IOSurface
// directly, Flutter reads the same bytes via the CVPixelBuffer.
//
// Visual: where Step 1 showed an R/G gradient (CPU-filled), Step 2 shows
// a solid orange clear-color (Metal clear). The visual change confirms
// the IOSurface bridge replaced the CPU pixel source.

/// 256×256 BGRA8 native-GPU-written texture, exposed to Flutter through
/// FlutterTexture protocol via a shared IOSurface.
class GradientTexture: NSObject, FlutterTexture {
    private let pixelBuffer: CVPixelBuffer
    private let mtlTexture: MTLTexture

    init?(device: MTLDevice, width: Int = 256, height: Int = 256) {
        // 1. Create the underlying IOSurface.
        let ioProps: [IOSurfacePropertyKey: Any] = [
            .width:           width,
            .height:          height,
            .pixelFormat:     Int(kCVPixelFormatType_32BGRA),
            .bytesPerElement: 4,
            .bytesPerRow:     width * 4,
        ]
        guard let ioSurface = IOSurface(properties: ioProps) else { return nil }

        // 2. Wrap the IOSurface as a CVPixelBuffer (this is what Flutter reads).
        // Note: CVPixelBufferCreateWithIOSurface returns via Unmanaged (unlike
        // CVPixelBufferCreate which returns via plain Optional). Use
        // takeRetainedValue() to balance the +1 refcount the API hands us.
        var pbUnmanaged: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            ioSurface,
            nil,
            &pbUnmanaged
        )
        guard status == kCVReturnSuccess,
              let buffer = pbUnmanaged?.takeRetainedValue() else { return nil }

        // 3. Wrap the SAME IOSurface as an MTLTexture (this is what Metal writes).
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .bgra8Unorm
        desc.width  = width
        desc.height = height
        desc.usage  = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(
            descriptor: desc,
            iosurface:  ioSurface,
            plane:      0
        ) else { return nil }

        self.pixelBuffer = buffer
        self.mtlTexture  = texture
        super.init()
    }

    /// Issue a Metal render pass that clears the shared texture to a
    /// bright orange. Synchronous — waits until the GPU work is done so
    /// Flutter doesn't sample mid-write on the first frame.
    func render(commandQueue: MTLCommandQueue) {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture     = mtlTexture
        pass.colorAttachments[0].loadAction  = .clear
        pass.colorAttachments[0].storeAction = .store
        // Bright orange: visibly different from Step 1's gradient so the
        // visual diff alone confirms Metal-side render landed in the
        // IOSurface and Flutter read it.
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0
        )
        guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        cb.commit()
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
                    message: "IOSurface / CVPixelBuffer / MTLTexture allocation failed",
                    details: nil
                ))
                return
            }
            texture.render(commandQueue: queue)
            let id = textures.register(texture)
            registered[id] = texture
            textures.textureFrameAvailable(id)
            result(NSNumber(value: id))
        default:
            result(FlutterMethodNotImplemented)
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
