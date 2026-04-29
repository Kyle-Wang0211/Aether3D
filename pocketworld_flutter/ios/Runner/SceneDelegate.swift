import Flutter
import UIKit

// EXP 9 (2026-04-28): Flutter stable 3.41.8 on iOS 26 requires Scene-based
// lifecycle — Info.plist must declare UIApplicationSceneManifest with
// UISceneDelegateClassName pointing here, and the class must inherit
// FlutterSceneDelegate so Flutter's engine can reliably attach its
// FlutterView to the active UIWindowScene. Without this, the Flutter view
// never gets a window, the raster thread stays parked in mach_msg_receive,
// and the first frame never flips. Copied verbatim from
// /tmp/hello_stable/ios/Runner/SceneDelegate.swift, which paints fine on
// iPhone 14 Pro / iOS 26.3.1.

class SceneDelegate: FlutterSceneDelegate {
}
