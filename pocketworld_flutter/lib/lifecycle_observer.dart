import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'object_transform.dart';
import 'orbit_controls.dart';

class LifecycleObserver with WidgetsBindingObserver {
  static const _channel = MethodChannel('aether_texture');
  static const _orbitKey = 'pocketworld.orbit_state.v1';
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
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_orbitKey, jsonEncode({
        'distance': orbit.distance,
        'azimuth': orbit.azimuth,
        'polar': orbit.polar,
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
      final prefs = await SharedPreferences.getInstance();
      final orbitJson = prefs.getString(_orbitKey);
      if (orbitJson != null) {
        final m = jsonDecode(orbitJson) as Map<String, dynamic>;
        orbit.distance = (m['distance'] as num).toDouble();
        orbit.azimuth = (m['azimuth'] as num).toDouble();
        orbit.polar = (m['polar'] as num).toDouble();
        orbit.target.x = (m['targetX'] as num).toDouble();
        orbit.target.y = (m['targetY'] as num).toDouble();
        orbit.target.z = (m['targetZ'] as num).toDouble();
      }
      final objectJson = prefs.getString(_objectKey);
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
