// Phase 6.4c — Arcball camera orbit (quaternion-based).
//
// History: earlier this file ported Three.js OrbitControls (polar/azimuth
// with gimbal clamp [ε, π-ε]). That worked on desktop trackpads but on iOS
// touch screens two issues surfaced:
//   1. Vertical drag direction felt inverted — trackpad users want the
//      "push the camera" feel, touch users want "drag the object" feel.
//   2. The polar clamp locked rotation at ~180°, so users couldn't flip
//      over the top / bottom pole ("360° stuck at 180°" user feedback).
//
// Fix: switch to a quaternion-based arcball. The camera orientation is a
// single unit quaternion; gestures compose small rotations into it. Result:
//   - Horizontal drag → yaw around world-Y  (horizon stays level)
//   - Vertical drag   → pitch around camera-local right axis
//   - Both axes are UNCLAMPED: flip past the top and the scene just keeps
//     rotating — no dead zone, no up-vector collapse.
//
// Direct-manipulation convention (matches Polycam / KIRI / Scaniverse):
//   Finger moves right → object visually moves right (camera orbits left).
//   Finger moves down  → object visually moves down  (camera tilts up).
// If a macOS trackpad user reports the feel is now inverted (trackpad
// convention expects "push the camera", not "drag the object"), we add a
// platform-conditional sign flip — iOS stays the source of truth because
// touch is the primary input for this app.
//
// Public API preserved:
//   rotate(dx, dy, size) / dolly(scale) / viewMatrix() / target / distance
// plus persistable state is now `orientation` (Quaternion) + `distance`
// + `target` — LifecycleObserver migrated to v2 schema in lockstep.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Size;
import 'package:vector_math/vector_math_64.dart' as v;

class OrbitControls {
  /// World-space point the camera orbits around. The default (0,0,0) places
  /// the splat scene at the world origin (matches the cross_validate
  /// baseline in scene_iosurface_renderer.cpp's make_baseline_uniforms).
  final v.Vector3 target = v.Vector3.zero();

  /// Radial distance from camera to target. Default 5.0 — gestures clamp
  /// into [minDistance, maxDistance].
  double distance = 5.0;

  /// Camera-to-world orientation. Identity = camera at +Z looking at the
  /// origin, world-up (+Y) aligned with screen-up. Accumulated by `rotate`.
  /// Re-normalized after every update so float drift can't unstabilize the
  /// axis over long sessions.
  final v.Quaternion orientation = v.Quaternion.identity();

  double minDistance = 0.5;
  double maxDistance = 50.0;

  /// Sensitivity knobs. 1.0 = "dragging from one widget edge to the other
  /// is a full 2π sweep" on the respective axis.
  double rotateSpeed = 1.0;
  double zoomSpeed = 1.0;

  /// Single-finger drag → arcball orbit around target.
  ///
  /// Direction convention (2026-04-27 iPhone real-device UX pass):
  /// **push-the-camera**, matching Blender / Sketchfab / most 3D viewers —
  /// finger right → camera orbits right → object appears to move left.
  /// The earlier "drag the object" direct-manipulation convention was
  /// user-tested and felt inverted on both axes for the rotate task, so
  /// both signs were flipped 2026-04-27.
  ///
  /// Composition rule (explained for maintainers — every sign matters):
  ///   yaw  (Δx): rotate around WORLD Y by +2π·Δx/width  (right drag →
  ///              positive yaw → camera orbits right → object appears
  ///              to move left).
  ///   pitch(Δy): rotate around CAMERA-LOCAL +X by +2π·Δy/height (down
  ///              drag → positive pitch → camera tilts down → object
  ///              bottom comes into view; Flutter dy positive-down).
  ///
  /// Quaternion composition:
  ///   new = yawQ · old · pitchQ_local
  /// where yawQ is expressed in world frame (left-multiply) and
  /// pitchQ_local is expressed in the local frame (right-multiply).
  ///
  /// Why yaw on world-Y (not local-up): keeps the horizon level so the
  /// scene doesn't roll sideways during horizontal drag. Pitch is on a
  /// local axis so after flipping past the top, pitch direction remains
  /// consistent with what the user sees — true 360° freedom on both axes.
  ///
  /// Platform scope: iOS only today. If macOS trackpad users ever
  /// re-request direct-manipulation ("drag the object"), add a
  /// `Platform.isMacOS` sign flip on both signAngle lines below.
  void rotate(double dxPixels, double dyPixels, Size viewSize) {
    final double yawAngle =
        2 * math.pi * dxPixels / viewSize.width * rotateSpeed;
    final double pitchAngle =
        2 * math.pi * dyPixels / viewSize.height * rotateSpeed;

    final yawQ = v.Quaternion.axisAngle(v.Vector3(0, 1, 0), yawAngle);
    final pitchLocalQ = v.Quaternion.axisAngle(v.Vector3(1, 0, 0), pitchAngle);

    final composed = yawQ * orientation * pitchLocalQ;
    orientation
      ..setValues(composed.x, composed.y, composed.z, composed.w)
      ..normalize();
  }

  /// Two-finger pinch → dolly. `scaleFactor` is Flutter's
  /// `ScaleUpdateDetails.scale` semantic: 1.0 = no change, > 1 = pinch
  /// open (zoom in / closer), < 1 = pinch close (zoom out / farther).
  void dolly(double scaleFactor) {
    if (scaleFactor <= 0.0) return; // defensive — Flutter sometimes emits 0
    distance = (distance / math.pow(scaleFactor, zoomSpeed)).clamp(
      minDistance,
      maxDistance,
    );
  }

  /// 16-float column-major view matrix for FFI upload.
  ///
  /// Derivation from arcball state:
  ///   forward_world = orientation · (0, 0, -1)     (camera looks along -Z
  ///                                                 in its local frame)
  ///   up_world      = orientation · (0, 1, 0)      (camera's local +Y,
  ///                                                 expressed in world)
  ///   eye           = target - forward_world * distance
  ///
  /// Because up_world is derived from orientation (not hardcoded to
  /// (0,1,0)), it stays perpendicular to forward even after flipping past
  /// a pole — no gimbal lock, no lookAt cross-product degeneracy.
  Float32List viewMatrix() {
    final forward = orientation.rotated(v.Vector3(0, 0, -1));
    final up = orientation.rotated(v.Vector3(0, 1, 0));
    final eye = target - forward * distance;
    final m = v.makeViewMatrix(eye, target, up);
    // Matrix4.storage is column-major Float64List of length 16.
    // Convert to Float32List (FFI expects float, not double).
    final out = Float32List(16);
    for (int i = 0; i < 16; ++i) {
      out[i] = m.storage[i];
    }
    return out;
  }
}
