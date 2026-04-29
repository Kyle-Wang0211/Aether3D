// Drop-in replacement for the handful of `shared_preferences` calls
// the app actually uses.
//
// Reason for existing: shared_preferences_foundation 2.5.6 crashes
// iOS 26.3.1 at direct launch (SharedPreferencesPlugin.register(with:)
// hits EXC_BAD_ACCESS inside swift_getObjectType — known Flutter /
// iOS Swift-plugin metadata-registration race). Routing through an
// in-Runner MethodChannel (`aether_prefs`) handled by
// AetherPrefsPlugin.swift — which lives inside the Runner target, not
// a pod — bypasses the race entirely.
//
// Only the subset the app uses is implemented (getString / setString /
// getInt / setInt / remove). Grow on demand.
//
// For tests: `AetherPrefs.setMockInitialValues({...})` mirrors
// `SharedPreferences.setMockInitialValues` so widget tests don't need
// the MethodChannel mock boilerplate.

import 'package:flutter/services.dart';

class AetherPrefs {
  AetherPrefs._();

  static const _channel = MethodChannel('aether_prefs');

  static Map<String, Object?>? _mockStore;

  /// Populate an in-memory store used by `flutter test` and non-iOS
  /// platforms where the native channel isn't wired. After calling
  /// this, every subsequent read/write goes through the mock store
  /// — the native channel is not invoked.
  static void setMockInitialValues(Map<String, Object?> values) {
    _mockStore = Map<String, Object?>.from(values);
  }

  /// Convenience singleton so call sites look identical to
  /// `SharedPreferences.getInstance()` (returns `this` — there is no
  /// real async init, but keeping the shape eases future migration
  /// back to shared_preferences if the Flutter bug gets fixed).
  static Future<AetherPrefs> getInstance() async => _instance;
  static final AetherPrefs _instance = AetherPrefs._();

  Future<String?> getString(String key) async {
    if (_mockStore != null) return _mockStore![key] as String?;
    try {
      return await _channel
          .invokeMethod<String>('getString', {'key': key});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> setString(String key, String value) async {
    if (_mockStore != null) {
      _mockStore![key] = value;
      return true;
    }
    try {
      final ok = await _channel
          .invokeMethod<bool>('setString', {'key': key, 'value': value});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<int?> getInt(String key) async {
    if (_mockStore != null) {
      final v = _mockStore![key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      return null;
    }
    try {
      final v = await _channel.invokeMethod<int>('getInt', {'key': key});
      return v;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> setInt(String key, int value) async {
    if (_mockStore != null) {
      _mockStore![key] = value;
      return true;
    }
    try {
      final ok = await _channel
          .invokeMethod<bool>('setInt', {'key': key, 'value': value});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> remove(String key) async {
    if (_mockStore != null) {
      _mockStore!.remove(key);
      return true;
    }
    try {
      final ok =
          await _channel.invokeMethod<bool>('remove', {'key': key});
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
