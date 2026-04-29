import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'aether_prefs.dart';
import 'object_transform.dart';
import 'orbit_controls.dart';

class LifecycleObserver with WidgetsBindingObserver {
  static const _channel = MethodChannel('aether_texture');
  // v1 → v2 bumped 2026-04-27 when OrbitControls migrated from
  // polar/azimuth euler angles to a quaternion-based arcball. Old v1
  // blobs are intentionally ignored on restore (not migrated): a single
  // drag after cold-start re-establishes the view, which is cheaper
  // than a schema-upgrade path that runs once and is then dead code.
  static const _orbitKey = 'pocketworld.orbit_state.v2';
  static const _objectKey = 'pocketworld.object_state.v1';

  final OrbitControls orbit;
  final ObjectTransform obj;
  final VoidCallback onStateChanged;
  bool _disposed = false;

  LifecycleObserver({
    required this.orbit,
    required this.obj,
    required this.onStateChanged,
  }) {
    WidgetsBinding.instance.addObserver(this);
    unawaited(restore());
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(save());
  }

  Future<void> save() async {
    try {
      final prefs = await AetherPrefs.getInstance();
      await prefs.setString(_orbitKey, jsonEncode({
        'distance': orbit.distance,
        // Quaternion components (w, x, y, z). Arcball orientation — see
        // orbit_controls.dart. Kept as a flat object (not nested) so the
        // JSON diff stays readable in debug logs.
        'orientW': orbit.orientation.w,
        'orientX': orbit.orientation.x,
        'orientY': orbit.orientation.y,
        'orientZ': orbit.orientation.z,
        'targetX': orbit.target.x,
        'targetY': orbit.target.y,
        'targetZ': orbit.target.z,
      }));
      await prefs.setString(_objectKey, jsonEncode({
        'positionX': obj.position.x,
        'positionY': obj.position.y,
        'positionZ': obj.position.z,
        'rotationY': obj.rotationY,
      }));
    } catch (e, st) {
      debugPrint('[LifecycleObserver] save error: $e\n$st');
    }
  }

  Future<void> restore() async {
    try {
      final prefs = await AetherPrefs.getInstance();
      final orbitJson = await prefs.getString(_orbitKey);
      if (orbitJson != null) {
        final m = jsonDecode(orbitJson) as Map<String, dynamic>;
        orbit.distance = (m['distance'] as num).toDouble();
        // Re-normalize after deserialize: a saved unit quaternion can
        // drift by a few ULPs through JSON round-trip; better to eat the
        // normalize cost once at startup than to risk subtle rotation
        // creep over many save/restore cycles.
        orbit.orientation.setValues(
          (m['orientX'] as num).toDouble(),
          (m['orientY'] as num).toDouble(),
          (m['orientZ'] as num).toDouble(),
          (m['orientW'] as num).toDouble(),
        );
        orbit.orientation.normalize();
        orbit.target.x = (m['targetX'] as num).toDouble();
        orbit.target.y = (m['targetY'] as num).toDouble();
        orbit.target.z = (m['targetZ'] as num).toDouble();
      }
      final objectJson = await prefs.getString(_objectKey);
      if (objectJson != null) {
        final m = jsonDecode(objectJson) as Map<String, dynamic>;
        obj.position.x = (m['positionX'] as num).toDouble();
        obj.position.y = (m['positionY'] as num).toDouble();
        obj.position.z = (m['positionZ'] as num).toDouble();
        obj.rotationY = (m['rotationY'] as num).toDouble();
      }
      onStateChanged();
      debugPrint('[LifecycleObserver] restore complete');
    } catch (e, st) {
      debugPrint('[LifecycleObserver] restore error: $e\n$st');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('[LifecycleObserver] state: $state');
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(save());
        _channel.invokeMethod('pauseRendering').catchError((e) {
          debugPrint('[LifecycleObserver] pauseRendering error: $e');
        });
        break;
      case AppLifecycleState.resumed:
        _channel.invokeMethod('resumeRendering').catchError((e) {
          debugPrint('[LifecycleObserver] resumeRendering error: $e');
        });
        break;
      case AppLifecycleState.detached:
        unawaited(save());
        break;
    }
  }
}
