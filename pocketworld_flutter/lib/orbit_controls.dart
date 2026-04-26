// Phase 6.4c — Three.js OrbitControls Dart port (camera-centric).
//
// Source of truth (math semantics):
//   https://github.com/mrdoob/three.js/blob/master/src/controls/OrbitControls.js
//   MIT licensed.
//
// What's ported:
//   - rotate(): single-finger drag → orbit around target (azimuth + polar)
//   - dolly():  two-finger pinch → distance to target
//   - viewMatrix(): produces a 4x4 column-major lookAt matrix for the FFI
//
// What's deliberately NOT ported (Phase 7+ work, decision pin):
//   - panning the camera target (object.pan handles object translate instead)
//   - damping / inertia (decision pin: zero tutorial, deterministic feel)
//   - automatic rotation
//   - touches.ONE / touches.TWO custom remapping (we want platform-default)

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Size;
import 'package:vector_math/vector_math_64.dart' as v;

class OrbitControls {
  /// World-space point the camera orbits around. The default (0,0,0) places
  /// the splat scene at the world origin (matches the cross_validate baseline
  /// in splat_iosurface_renderer.cpp).
  final v.Vector3 target = v.Vector3.zero();

  /// Radial distance from camera to target. Phase 6.4c default places the
  /// camera 5 units away; gestures clamp into [minDistance, maxDistance].
  double distance = 5.0;

  /// Polar angle in radians: 0 = looking down from above, π = looking up
  /// from below. π/2 = horizontal. Clamped to (0, π) to avoid the
  /// gimbal-lock zone at the poles.
  double polar = math.pi / 2;

  /// Azimuthal angle in radians. Wraps freely (no clamp) so users can
  /// orbit indefinitely.
  double azimuth = 0.0;

  /// Distance clamps. Phase 6.4c defaults; future tiers may tune them
  /// per-scene (huge environments need larger maxDistance).
  double minDistance = 0.5;
  double maxDistance = 50.0;

  /// Polar clamps — keep ε away from the poles to avoid degenerate
  /// lookAt math (eye coincides with target's vertical axis).
  double minPolar = 0.05;
  double maxPolar = math.pi - 0.05;

  /// Sensitivity. 1.0 = stock Three.js feel.
  double rotateSpeed = 1.0;
  double zoomSpeed = 1.0;

  /// Single-finger drag → orbit. Three.js translates pixel-delta to a
  /// fraction of the viewport then maps to a 2π-radian sweep — same here.
  /// Dragging from one edge to the other = full revolution at rotateSpeed=1.
  void rotate(double dxPixels, double dyPixels, Size viewSize) {
    azimuth -= 2 * math.pi * dxPixels / viewSize.width * rotateSpeed;
    polar -= 2 * math.pi * dyPixels / viewSize.height * rotateSpeed;
    polar = polar.clamp(minPolar, maxPolar);
  }

  /// Two-finger pinch → dolly. `scaleFactor` is Flutter's
  /// `ScaleUpdateDetails.scale` semantic: 1.0 = no change, > 1 = pinch open
  /// (zoom in / closer), < 1 = pinch close (zoom out / farther). We invert
  /// so distance shrinks on zoom-in.
  void dolly(double scaleFactor) {
    if (scaleFactor <= 0.0) return; // defensive — Flutter sometimes emits 0
    distance =
        (distance / math.pow(scaleFactor, zoomSpeed)).clamp(minDistance, maxDistance);
  }

  /// 16-float column-major view matrix for FFI upload. Eye position is
  /// derived from spherical (target, distance, polar, azimuth); up is
  /// world-Y. Matches the convention DawnGPUDevice's WGSL expects
  /// (column-major mat4x4f, applied as `viewmat * world_position`).
  Float32List viewMatrix() {
    final eye = v.Vector3(
      target.x + distance * math.sin(polar) * math.sin(azimuth),
      target.y + distance * math.cos(polar),
      target.z + distance * math.sin(polar) * math.cos(azimuth),
    );
    final up = v.Vector3(0, 1, 0);
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
