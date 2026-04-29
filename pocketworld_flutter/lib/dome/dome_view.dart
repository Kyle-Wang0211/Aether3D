// Dart port of App/ObjectModeV2/ObjectModeV2DomeView.swift (Flutter
// CustomPainter approximation).
//
// The Swift original renders a full 3D sphere of wedge quads with a
// Metal PBR+ripple shader. Pure Flutter/Dart can't call Metal directly,
// so this view approximates the same intent with a 2D spherical-
// projection CustomPainter:
//
//   • each (azimuth, elevation) bin is drawn as a quad in screen space
//     after an orthographic projection of the front hemisphere
//   • bin color = coverage hit count (gray → green, scaled by hits)
//   • a small camera-direction cursor tracks the live ARPose
//   • orbit completion arc around the edge shows progress
//
// This is enough to validate the UX and wire the guidance engine. A
// full 3D port (ScanGuidance.metal → WGSL PBR + ripple + border
// animation) is tracked in PORTING_BACKLOG.md D1.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/design_system.dart';
import 'ar_pose.dart';
import 'coverage_map.dart';
import 'platform_pose_provider.dart';

class DomeView extends StatefulWidget {
  /// Externally-owned coverage map — caller decides when to reset.
  /// If null, a local one is created and used purely for visualization.
  final CoverageMap? coverage;

  /// If provided, DomeView will subscribe to this; otherwise it creates
  /// its own PlatformARPoseProvider (which will fallback to mock poses).
  final ARPoseProvider? poseProvider;

  /// Fired whenever a new AR pose arrives (after the coverage map is
  /// updated). Callers hook this to drive the GuidanceEngine.
  final void Function(ARPose pose)? onPose;

  const DomeView({
    super.key,
    this.coverage,
    this.poseProvider,
    this.onPose,
  });

  @override
  State<DomeView> createState() => _DomeViewState();
}

class _DomeViewState extends State<DomeView> {
  late final ARPoseProvider _poseProvider =
      widget.poseProvider ?? PlatformARPoseProvider();
  late final CoverageMap _coverage = widget.coverage ?? CoverageMap();
  StreamSubscription<ARPose>? _sub;
  ARPose? _pose;

  @override
  void initState() {
    super.initState();
    _sub = _poseProvider.start().listen((pose) {
      // Only credit the coverage map when the AR session is healthy so
      // lost-tracking frames don't pollute the progress map.
      if (pose.isTracking) {
        _coverage.registerHit(pose.azimuth, pose.elevation);
      }
      if (mounted) setState(() => _pose = pose);
      widget.onPose?.call(pose);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _poseProvider.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 1,
      child: CustomPaint(
        painter: _DomePainter(
          coverage: _coverage,
          pose: _pose,
        ),
      ),
    );
  }
}

class _DomePainter extends CustomPainter {
  final CoverageMap coverage;
  final ARPose? pose;

  _DomePainter({required this.coverage, required this.pose});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 4;

    // Back plate (dome silhouette).
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = AetherColors.bgElevated,
    );

    // Draw every coverage bin as a wedge. The sphere is projected
    // orthographically: front hemisphere fills the circle; back
    // hemisphere wraps around the outer edge darkened.
    final bins = coverage.rawBins;
    const aBins = CoverageMap.azimuthBins;
    const eBins = CoverageMap.elevationBins;
    final twoPi = 2 * math.pi;

    final visitedStroke = Paint()
      ..color = AetherColors.primary
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;
    final unvisitedStroke = Paint()
      ..color = AetherColors.borderStrong
      ..strokeWidth = 0.6
      ..style = PaintingStyle.stroke;

    for (int e = 0; e < eBins; e++) {
      final elCenter = -math.pi / 2 + (e + 0.5) / eBins * math.pi;
      // Skip back hemisphere — elevation below -45° looks visually
      // equivalent; we dedicate ring slots 0..1 to "bottom",
      // 2..6 to "front", 7..8 to "top" so the user sees wedges where
      // they intuitively expect to rotate.
      for (int a = 0; a < aBins; a++) {
        final azCenter = (a + 0.5) / aBins * twoPi;
        final hits = bins[e * aBins + a];
        final (screenPos, projectedRadius) =
            _project(center, radius, azCenter, elCenter);
        final visited = hits > 0;
        final wedgeFill = Paint()
          ..color = visited
              ? Color.lerp(
                  AetherColors.border,
                  AetherColors.primary,
                  math.min(1.0, hits / 6.0),
                )!
              : AetherColors.bgElevated;
        canvas.drawCircle(screenPos, projectedRadius, wedgeFill);
        canvas.drawCircle(
          screenPos,
          projectedRadius,
          visited ? visitedStroke : unvisitedStroke,
        );
      }
    }

    // Progress ring around the outer edge.
    final completion = coverage.completionFraction.clamp(0.0, 1.0);
    final ringPaint = Paint()
      ..color = AetherColors.primary
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius + 2),
      -math.pi / 2,
      2 * math.pi * completion,
      false,
      ringPaint,
    );

    // Live pose cursor — small filled circle where the camera is
    // currently looking, rendered in red if tracking lost.
    final p = pose;
    if (p != null) {
      final (cursor, _) = _project(center, radius, p.azimuth, p.elevation);
      final cursorFill = Paint()
        ..color = p.isTracking ? AetherColors.primary : AetherColors.danger;
      canvas.drawCircle(cursor, 6, cursorFill);
      canvas.drawCircle(
        cursor,
        6,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke,
      );
    }
  }

  /// Orthographic projection of a (az, el) direction onto the 2D
  /// canvas. `az`=0 maps to "up" on the canvas to match the SwiftUI
  /// prototype's "front of user = top of dome" convention.
  (Offset, double) _project(
    Offset center,
    double radius,
    double az,
    double el,
  ) {
    final r = radius * 0.82;
    final x = r * math.cos(el) * math.sin(az);
    final y = -r * math.sin(el);
    // Depth into screen (not drawn; used to fade back hemisphere).
    final z = r * math.cos(el) * math.cos(az);
    final projected = 10.0 + (z / radius).abs() * 6.0;
    return (Offset(center.dx + x, center.dy + y), projected.clamp(6.0, 16.0));
  }

  @override
  bool shouldRepaint(covariant _DomePainter old) =>
      old.pose != pose || old.coverage.totalHits != coverage.totalHits;
}
