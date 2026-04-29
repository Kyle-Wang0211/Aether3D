// Cross-platform AR pose abstraction.
//
// Design rule: business logic (dome view, coverage map, guidance
// engine) depends on this interface ONLY. Per-platform AR backends
// (ARKit, ARCore, HarmonyOS AR Engine, WebXR) implement it behind
// a MethodChannel. This keeps the Dart side 100% portable.
//
// Current state (2026-04-27): `MockARPoseProvider` ships working today
// (drives the dome demo with a synthetic orbit). Platform-specific
// bindings are stubbed via `PlatformARPoseProvider` which tries
// `MethodChannel('aether_arkit')` first and falls back to Mock if the
// channel is unregistered. Native plugin implementation is tracked in
// PORTING_BACKLOG.md under D1.

import 'dart:async';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// Camera pose at one AR frame. All values in world space with the
/// scene's origin at the captured object's approximate center (set by
/// the AR runtime's world-tracking initialization).
class ARPose {
  /// Camera position in world space, meters.
  final Vector3 position;

  /// Camera orientation (unit quaternion). `rotate(Vector3(0, 0, -1))`
  /// is the camera's forward axis.
  final Quaternion orientation;

  /// Azimuth (radians, `atan2(x, z)` convention) — yaw of the camera
  /// around the world's Y axis. Cached so the dome coverage map
  /// doesn't have to recompute per frame.
  final double azimuth;

  /// Elevation (radians, positive = looking up) — pitch relative to
  /// horizontal.
  final double elevation;

  /// Tracking state. Dome UI hides guidance when not tracking.
  final bool isTracking;

  /// Wall-clock timestamp (seconds since app start) for smoothing /
  /// delta-velocity calculations.
  final double timestamp;

  const ARPose({
    required this.position,
    required this.orientation,
    required this.azimuth,
    required this.elevation,
    required this.isTracking,
    required this.timestamp,
  });

  static ARPose fromPositionOrientation({
    required Vector3 position,
    required Quaternion orientation,
    required double timestamp,
    bool isTracking = true,
  }) {
    // Forward = orientation · (0, 0, -1).
    final forward = orientation.rotated(Vector3(0, 0, -1));
    final azimuth = math.atan2(forward.x, forward.z);
    final elevation = math.asin(forward.y.clamp(-1.0, 1.0));
    return ARPose(
      position: position,
      orientation: orientation,
      azimuth: azimuth,
      elevation: elevation,
      isTracking: isTracking,
      timestamp: timestamp,
    );
  }
}

abstract class ARPoseProvider {
  /// Start receiving pose updates. Returns a stream that the dome view
  /// subscribes to. Safe to call multiple times — implementations
  /// should be idempotent.
  Stream<ARPose> start();

  /// Stop the AR session. Does not dispose the provider; a subsequent
  /// `start()` call must work.
  Future<void> stop();

  /// Most recent pose synchronously accessible (null if not started yet).
  ARPose? get lastPose;
}
