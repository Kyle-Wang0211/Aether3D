import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Phase 5.1: register AetherTexturePlugin alongside the generated
  // plugins. The implicit-engine bridge is invoked by Flutter once the
  // engine is ready; both the auto-registrant and our hand-rolled
  // plugin attach to the same FlutterPluginRegistry on the same engine.
  //
  // If registrar(forPlugin:) returns nil (Flutter regression on this
  // pattern), AetherTexturePlugin won't register and Dart's
  // MethodChannel('aether_texture').invokeMethod would surface a
  // MissingPluginException — main.dart's _requestTexture() already
  // catches that and renders the error path.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AetherTexturePlugin") {
      AetherTexturePlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: AetherTexturePlugin) returned nil — texture widget will be blank")
    }
  }
}
