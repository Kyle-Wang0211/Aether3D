// AetherCppCardDemo — minimal viable replacement for the thermion-
// backed LiveModelView, used only when PostCard's
// `kPostCardUseAetherCppViewer` flag is flipped to true.
//
// Goals (G4 scope):
//   • Prove the SceneBridge MethodChannel + AetherCppViewerImpl path
//     end-to-end for a single PostCard.
//   • Keep the surface dead-simple — no _LoadCover crossfade, no
//     orbit gesture, no auto-fit-from-bounds. Just: create texture,
//     load GLB, drive a Ticker that pushes view+model matrices once
//     per frame, render through `Texture(textureId:)`.
//   • Feed parity (auto-rotate + tap-to-detail) lands in G5+ as
//     this stabilizes.
//
// Once we're confident the multi-texture displayLink (Native G4a) is
// happy and the native side returns model bounds (G4b TBD pending a
// new C API method), this widget grows into a full LiveModelView
// replacement and `kAetherCppViewerEnabled` flips globally (G9).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:vector_math/vector_math_64.dart' as v64;

import 'viewer_impl.dart';

class AetherCppCardDemo extends StatefulWidget {
  /// HTTPS or file:// URL to the GLB. Format detection (G5) lands later;
  /// for now this widget assumes GLB.
  final String modelUrl;

  /// Auto-rotate speed (radians per second). Matches LiveModelView's
  /// 0.6 rad/s default.
  final double autoRotateSpeed;

  /// Background color shown behind the texture while it's still
  /// loading or when the GPU produces a transparent frame.
  final Color background;

  const AetherCppCardDemo({
    super.key,
    required this.modelUrl,
    this.autoRotateSpeed = 0.6,
    this.background = Colors.white,
  });

  @override
  State<AetherCppCardDemo> createState() => _AetherCppCardDemoState();
}

class _AetherCppCardDemoState extends State<AetherCppCardDemo>
    with SingleTickerProviderStateMixin {
  AetherCppViewerImpl? _viewer;
  int? _textureId;
  bool _loadFailed = false;
  bool _disposedFlag = false;

  // Auto-rotate state — same dt-integration pattern LiveModelView uses
  // (see live_model_view.dart's _onTick / _restartRotateTicker).
  Ticker? _ticker;
  Duration? _lastTickElapsed;
  double _angle = 0.0;

  // Initial fit distance — until the native side returns real model
  // bounds (G4b), we use a conservative default that frames most
  // GLBs in our seeded feed at roughly 70-90% of the viewport. See
  // PHASE_FLUTTER_VIEWER_PLAN.md for the full rationale.
  static const double _kFallbackCameraDistance = 4.0;

  @override
  void initState() {
    super.initState();
    // Defer to post-frame so MediaQuery / context.size are available.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (_disposedFlag || !mounted) return;
    try {
      final size = context.size ?? const Size(360, 360);
      final mq = MediaQuery.maybeOf(context);
      final scale = mq?.devicePixelRatio ?? 2.0;
      final pxW = (size.width * scale).round().clamp(1, 4096);
      final pxH = (size.height * scale).round().clamp(1, 4096);

      final impl = AetherCppViewerImpl();
      _viewer = impl;
      final id = await impl.create(
        width: pxW.toDouble(),
        height: pxH.toDouble(),
      );
      if (_disposedFlag || !mounted || id == null) return;
      setState(() => _textureId = id);

      await impl.load(widget.modelUrl);
      if (_disposedFlag || !mounted) return;

      _ticker = createTicker(_onTick)..start();
    } catch (e, s) {
      debugPrint('[AetherCppCardDemo] start failed: $e\n$s');
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  void _onTick(Duration elapsed) {
    if (_disposedFlag || !mounted) return;
    final last = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    if (last == null) return; // first tick = baseline only.
    final dt = (elapsed - last).inMicroseconds / 1e6;
    final clamped = dt.clamp(0.0, 0.05);
    _angle += clamped * widget.autoRotateSpeed;
    if (_angle > 2 * math.pi) _angle -= 2 * math.pi;
    unawaited(_pushFrame());
  }

  Future<void> _pushFrame() async {
    final viewer = _viewer;
    if (viewer == null) return;
    // Camera orbits around origin in the XZ plane, looking down Y=0.
    // Native scene_iosurface_renderer derives projection from the
    // texture aspect (square), so we only push view + model.
    final eye = v64.Vector3(
      _kFallbackCameraDistance * math.sin(_angle),
      _kFallbackCameraDistance * 0.05,
      _kFallbackCameraDistance * math.cos(_angle),
    );
    final view = v64.makeViewMatrix(
      eye,
      v64.Vector3.zero(),
      v64.Vector3(0, 1, 0),
    );
    final model = v64.Matrix4.identity();
    await viewer.render(viewMatrix: view, modelMatrix: model);
  }

  @override
  void dispose() {
    _disposedFlag = true;
    _ticker?.dispose();
    _ticker = null;
    final v = _viewer;
    _viewer = null;
    _textureId = null;
    if (v != null) {
      // Fire-and-forget — dispose is async on the bridge.
      unawaited(v.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loadFailed) {
      return ColoredBox(
        color: widget.background,
        child: const Center(
          child: Icon(
            Icons.error_outline_rounded,
            size: 36,
            color: Colors.grey,
          ),
        ),
      );
    }
    final id = _textureId;
    if (id == null) {
      return ColoredBox(
        color: widget.background,
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return ColoredBox(
      color: widget.background,
      child: Texture(textureId: id),
    );
  }
}
