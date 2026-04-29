import Flutter
import Foundation
import UIKit

// AetherPrefs — in-Runner-binary NSUserDefaults bridge.
//
// Replaces shared_preferences_foundation for the Aether3D app because
// that plugin triggers an iOS 26 Swift class-metadata registration race
// (crashes direct-launch with EXC_BAD_ACCESS inside
// `SharedPreferencesPlugin.register(with:) +88` — swift_getObjectType
// returns NULL).
//
// By embedding this Swift class directly in the Runner target (not a
// pod), its class metadata is part of the app binary's __TEXT section
// and is registered with the ObjC runtime as part of normal app init
// — no plugin-registrar race.
//
// API (MethodChannel `aether_prefs`) is a thin subset of what
// shared_preferences_foundation offers, covering the keys the app
// actually uses today:
//   getString(key)         → String?
//   setString(key, value)  → Bool
//   getInt(key)            → Int?
//   setInt(key, value)     → Bool
//   remove(key)            → Bool
//   clearAll()             → Bool
//
// Extend when additional types are needed.

class AetherPrefsPlugin: NSObject {
  private let defaults = UserDefaults.standard

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "aether_prefs", binaryMessenger: messenger)
    let plugin = AetherPrefsPlugin()
    channel.setMethodCallHandler { call, result in
      plugin.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getString":
      result(defaults.string(forKey: keyOf(call)))
    case "setString":
      guard let args = call.arguments as? [String: Any],
            let key = args["key"] as? String,
            let value = args["value"] as? String
      else {
        result(FlutterError(code: "BAD_ARGS", message: "setString requires {key, value}", details: nil))
        return
      }
      defaults.set(value, forKey: key)
      result(true)
    case "getInt":
      let key = keyOf(call)
      if defaults.object(forKey: key) == nil {
        result(nil)
      } else {
        result(defaults.integer(forKey: key))
      }
    case "setInt":
      guard let args = call.arguments as? [String: Any],
            let key = args["key"] as? String,
            let value = args["value"] as? Int
      else {
        result(FlutterError(code: "BAD_ARGS", message: "setInt requires {key, value}", details: nil))
        return
      }
      defaults.set(value, forKey: key)
      result(true)
    case "remove":
      defaults.removeObject(forKey: keyOf(call))
      result(true)
    case "clearAll":
      // We intentionally don't clear the whole domain — would nuke
      // unrelated app state (e.g. Flutter's own UIView autosave). We
      // only clear keys that start with "Aether3D.".
      for key in defaults.dictionaryRepresentation().keys
      where key.hasPrefix("Aether3D.") {
        defaults.removeObject(forKey: key)
      }
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func keyOf(_ call: FlutterMethodCall) -> String {
    if let args = call.arguments as? [String: Any],
       let key = args["key"] as? String {
      return key
    }
    if let key = call.arguments as? String {
      return key
    }
    return ""
  }
}
