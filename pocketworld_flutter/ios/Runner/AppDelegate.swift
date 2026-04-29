import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // In-Runner-target Swift plugins. AetherPrefsPlugin replaces
    // shared_preferences because the pod-shipped Swift plugin hit a
    // plugin-registrar metadata race on iOS 26 direct-launch.
    // AetherTexturePlugin bridges the Flutter Texture widget to the
    // aether3d_ffi native scene renderer (Dawn/Filament PBR + splat).
    if let registrar = self.registrar(forPlugin: "AetherTexturePlugin") {
      AetherTexturePlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: AetherTexturePlugin) nil — texture widget will be blank")
    }
    if let registrar = self.registrar(forPlugin: "AetherPrefsPlugin") {
      AetherPrefsPlugin.register(with: registrar.messenger())
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
