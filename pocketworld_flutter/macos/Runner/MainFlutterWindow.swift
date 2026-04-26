import Cocoa
import FlutterMacOS

// ─── Phase 4.1 — Flutter Texture widget plumbing on macOS desktop ───────
// Plugin code is intentionally inline here for the Step 1 hello-world.
// When it grows (Phase 4.2 IOSurface bridge, 4.3 Dawn render, etc.)
// extract to a dedicated file + add to project.pbxproj.

/// 256×256 BGRA8 CPU-rendered gradient.
/// R varies horizontally (0..255 left→right),
/// G varies vertically (0..255 top→bottom),
/// B fixed at 128, A = 255.
class GradientTexture: NSObject, FlutterTexture {
    private let pixelBuffer: CVPixelBuffer

    init?(width: Int = 256, height: Int = 256) {
        var pb: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width, height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                ptr[i + 0] = 128                  // B
                ptr[i + 1] = UInt8(y & 0xFF)      // G
                ptr[i + 2] = UInt8(x & 0xFF)      // R
                ptr[i + 3] = 255                  // A
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        self.pixelBuffer = buffer
        super.init()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        // Flutter docs require passRetained: Flutter takes one reference,
        // balances it after the frame composes.
        return Unmanaged.passRetained(pixelBuffer)
    }
}

class AetherTexturePlugin: NSObject, FlutterPlugin {
    private let textures: FlutterTextureRegistry
    // Hold strong refs so the textures aren't deallocated while Flutter
    // is consuming them. Keyed by textureId.
    private var registered: [Int64: GradientTexture] = [:]

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

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "createGradientTexture":
            guard let texture = GradientTexture() else {
                result(FlutterError(
                    code: "TEXTURE_CREATE_FAILED",
                    message: "CVPixelBuffer create failed",
                    details: nil
                ))
                return
            }
            let id = textures.register(texture)
            registered[id] = texture
            // Static content — signal frame-available once so Flutter
            // samples the buffer after the widget mounts.
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
