// Phase 6.4c — Object world-space transform.
//
// Two gestures act on the OBJECT (not the camera):
//   - Two-finger same-direction drag → translate (pan in world space)
//   - Two-finger counter-rotate     → rotate around world Y axis
//
// Decision pin 16: split camera-vs-object responsibilities. Pan and rotate
// are intuitively "moving the thing", while orbit and dolly are "moving
// the eye" — keeping them in separate classes makes the gesture-event
// fanout in main.dart trivially correct.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/painting.dart' show Offset, Size;
import 'package:vector_math/vector_math_64.dart' as v;

class ObjectTransform {
  /// World-space position. Default origin matches the splat scene's
  /// natural placement.
  final v.Vector3 position = v.Vector3.zero();

  /// Rotation around world Y axis (radians). Two-finger counter-rotate
  /// gesture accumulates here.
  double rotationY = 0.0;

  /// Scale (currently unused — kept for Phase 7 symmetric-pinch gesture).
  /// Identity = 1.0 along all axes.
  final v.Vector3 scale = v.Vector3.all(1.0);

  /// Two-finger same-direction drag → translate in world space.
  ///
  /// Approach: project pixel-delta onto the plane perpendicular to the
  /// camera's forward axis, then transform by the inverse-view to get a
  /// world-space delta. The exact projection uses the camera's vertical
  /// FOV (radians) and viewport aspect, so screen-pixel velocity maps to
  /// a consistent world velocity regardless of zoom level.
  ///
  /// Phase 6.4c uses a small-angle approximation (camera position is
  /// distance * direction, so worldDx ≈ pixelDx / vw * 2 * tan(fov/2) *
  /// distance * aspect). Phase 7 may swap to a true unprojection if
  /// users notice off-axis drift.
  ///
  /// @param viewMatrix         Current camera view matrix (16 floats column-major).
  /// @param fovYRadians        Camera vertical FOV in radians.
  /// @param distanceToTarget   Distance from camera to its orbit target
  ///                           (OrbitControls.distance) — controls the
  ///                           pixel-to-world ratio.
  /// @param viewSize           Widget size in pixels.
  void pan(Offset deltaPixels, Float32List viewMatrix, double fovYRadians,
      double distanceToTarget, Size viewSize) {
    final aspect = viewSize.width / viewSize.height;
    final tanHalf = math.tan(fovYRadians * 0.5);
    // Camera-space delta: pan one pixel → 2 * tan(fov/2) * distance / view.height world units.
    final cameraDx = deltaPixels.dx / viewSize.height * 2 * tanHalf * distanceToTarget * aspect;
    // Flip Y because screen-Y grows down while world/camera-Y grows up.
    final cameraDy = -deltaPixels.dy / viewSize.height * 2 * tanHalf * distanceToTarget;

    // Transform camera-space delta vector by inverse-view to get world-space delta.
    // We want only the rotation+translation part for direction; the position
    // component cancels (delta is a vector, not a point).
    final viewMat = v.Matrix4.fromFloat64List(_toFloat64(viewMatrix));
    final inv = v.Matrix4.inverted(viewMat);
    final cameraDelta = v.Vector4(cameraDx, cameraDy, 0.0, 0.0);
    final worldDelta = inv.transform(cameraDelta);
    position.add(v.Vector3(worldDelta.x, worldDelta.y, worldDelta.z));
  }

  /// Two-finger counter-rotate → rotate around Y axis.
  /// Flutter's `ScaleUpdateDetails.rotation` is in radians, accumulated
  /// from gesture start; we treat the per-update delta as the increment.
  void rotate(double radians) {
    rotationY += radians;
  }

  /// 16-float column-major model matrix: T(position) * R_y(rotation) * S(scale).
  Float32List modelMatrix() {
    final m = v.Matrix4.identity()
      ..translateByDouble(position.x, position.y, position.z, 1.0)
      ..rotateY(rotationY)
      ..scaleByDouble(scale.x, scale.y, scale.z, 1.0);
    final out = Float32List(16);
    for (int i = 0; i < 16; ++i) {
      out[i] = m.storage[i];
    }
    return out;
  }
}

Float64List _toFloat64(Float32List f32) {
  final f64 = Float64List(f32.length);
  for (int i = 0; i < f32.length; ++i) {
    f64[i] = f32[i];
  }
  return f64;
}
