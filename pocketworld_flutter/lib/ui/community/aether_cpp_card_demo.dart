// AetherCppCardDemo — feed-card surface backed by aether_cpp's
// scene_iosurface_renderer (Phase 6.4b stage 2 SHIPPED) instead of
// thermion. Replaces LiveModelView for community feed cards once
// `kPostCardUseAetherCppViewer` flips to true.
//
// G4 scope (this file):
//   • SceneBridge MethodChannel + AetherCppViewerImpl path end-to-end
//     for a single PostCard.
//   • Bounds-driven fit (model-viewer formula: dist = r / sin(fov/2))
//     using the AABB the native side now surfaces through
//     `aether_scene_renderer_get_bounds`. Falls back to a hardcoded
//     distance when bounds are missing (older Runner / non-mesh path).
//   • _LoadCover crossfade matching LiveModelView so the user never
//     sees a flash of clear color before the first textured frame.
//   • Auto-rotate + tap-to-detail (handled by the parent PostCard's
//     GestureDetector, same as LiveModelView).
//
// Out of scope (deferred):
//   • Orbit gesture (interactive=true) — feed cards never orbit, only
//     auto-rotate. The detail page still uses LiveModelView until G5
//     promotes this widget into a full LiveModelView replacement.
//   • PLY / SPZ / SPLAT format dispatch — G5 once aether_cpp's C ABI
//     gains load_ply / load_spz.

import 'dart:async';

import '../../aether_view/scene_bridge.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:vector_math/vector_math_64.dart' as v64;

import '../design_system.dart';
import 'viewer_impl.dart';

class AetherCppCardDemo extends StatefulWidget {
  /// HTTPS or file:// URL to the GLB.
  final String modelUrl;

  /// True when this card is the most-centered card in the feed (parent
  /// VaultPage drives this). Mirrors LiveModelView's `autoRotate` —
  /// only the focused card animates, the rest sit static. CRITICAL for
  /// the G4-bugfix path: the native displayLink only re-renders dirty
  /// textures (consumeIfDirty), and only setMatrices marks dirty. So
  /// if every card kept calling setMatrices each frame, every card
  /// would also keep re-rendering and we'd be back to the 5×60fps
  /// IOSurface→MTLTexture import storm that crashed Dawn.
  ///
  /// Ignored when [interactive] is true — interactive mode replaces
  /// auto-rotate with user gestures.
  final bool isFocused;

  /// Detail-page mode: 1-finger drag = orbit, 2-finger pinch = zoom.
  /// Auto-rotate is disabled. The widget wraps itself in a
  /// GestureDetector that owns scale events; the parent should NOT
  /// also have a scale handler or they'll fight. Single-tap still
  /// reaches the parent via HitTestBehavior.translucent.
  final bool interactive;

  /// Auto-rotate speed (radians per second). Matches LiveModelView's
  /// 0.6 rad/s default.
  final double autoRotateSpeed;

  /// Background color shown behind the texture while it's still
  /// loading or when the GPU produces a transparent frame.
  final Color background;

  /// Fallback camera distance used when the native side doesn't
  /// surface bounds (older Runner / no-mesh path). Matches
  /// LiveModelView's `cameraDistance` default for parity.
  final double fallbackCameraDistance;

  /// Phase 6.4f.5 — per-asset splat tunables (creator-side metadata
  /// hook). Default `none` keeps the Niantic-tuned per-quality
  /// presets in [AetherCppViewerImpl.load].
  final SplatViewerOverrides splatOverrides;

  /// Phase 6.4f.9 — fired exactly once after the first valid frame has
  /// been pushed into the IOSurface (i.e. the moment the Texture widget
  /// will start showing real pixels rather than the freshly-allocated
  /// IOSurface's default fill). PostCard uses this to keep its thumbnail
  /// backdrop visible UNDER the viewer until this callback fires, then
  /// crossfades the viewer in. Without this, scroll-back to a card in
  /// the SplatDataCache window briefly flashes the empty IOSurface
  /// (the user-perceived "灰色 reload" even though the cache HIT made
  /// the actual decode 52ms-fast).
  ///
  /// Fires after `_pushFrame()` resolves AND `setState(_modelReady)`
  /// has run, so the widget is paint-ready when this lands. Also fires
  /// after a memory-warning rebuild's first frame.
  final VoidCallback? onFirstFrameReady;

  const AetherCppCardDemo({
    super.key,
    required this.modelUrl,
    this.isFocused = false,
    this.interactive = false,
    this.autoRotateSpeed = 0.6,
    this.background = Colors.white,
    this.fallbackCameraDistance = 5.5,
    this.splatOverrides = SplatViewerOverrides.none,
    this.onFirstFrameReady,
  });

  @override
  State<AetherCppCardDemo> createState() => _AetherCppCardDemoState();
}

class _AetherCppCardDemoState extends State<AetherCppCardDemo>
    with SingleTickerProviderStateMixin {
  AetherCppViewerImpl? _viewer;
  int? _textureId;
  bool _loadFailed = false;
  bool _modelReady = false;
  bool _disposedFlag = false;

  // Subscribed at initState. The native side broadcasts BOTH thermal
  // and memory warnings on the same stream; we only react when the
  // event truly invalidates THIS card's textureId — see
  // [WarningEvent.affects]. Thermal warnings are silently ignored
  // (native didn't dispose anything), and memory warnings on cards
  // whose texture is still alive (because the focused-card LRU kept it)
  // are also no-ops.
  StreamSubscription<WarningEvent>? _warningSub;

  // Auto-rotate state — same dt-integration pattern LiveModelView uses
  // (see live_model_view.dart's _onTick / _restartRotateTicker).
  Ticker? _ticker;
  Duration? _lastTickElapsed;
  double _angle = 0.0;

  // Fit state. Until load completes, distance + center fall back to
  // widget.fallbackCameraDistance + origin so the very first ticker
  // tick has something sensible to push.
  double _fitDistance = 0.0;
  v64.Vector3 _modelCenter = v64.Vector3.zero();

  // ─── Interactive orbit state (mirrors LiveModelView's pattern) ─────
  // Azimuth around the world-Y axis, in radians. 0 = camera at +Z,
  // looking down -Z toward modelCenter. Drag-X accumulates here.
  double _orbitAzimuth = 0.0;
  // Elevation: 0 = horizontal, +π/2 = looking down from above,
  // -π/2 = looking up from below. Slight tilt at start so we don't
  // stare exactly at the equator.
  double _orbitElevation = 0.05;
  // Orbit radius (distance from modelCenter). Initialized to
  // _fitDistance after _computeFit; pinch updates it within
  // [_minRadius, _maxRadius].
  double _orbitRadius = 0.0;
  // Pinch reference point — captured in _onScaleStart so the radius
  // tracks the gesture's full multiplier (not just the per-event
  // delta).
  double _pinchStartRadius = 0.0;
  // Bounds on the orbit radius. Sized off the fitted distance in
  // _computeFit so they scale per-model: small models get a tighter
  // pinch range than huge ones (a fixed [1.5, 20] doesn't work for
  // both Corset r=0.04 and any future r=20+ scan).
  double _minRadius = 0.5;
  double _maxRadius = 20.0;

  // Drag sensitivity — match LiveModelView's hand-tuned 0.005 rad/px
  // (≈5× thermion's stock). y_inversion=1.0 means drag-down → look
  // down (elevation increases), which feels natural per user spec
  // "drag down → see top of model".
  static const double _kTouchSensitivity = 0.005;
  static const double _kYInversion = 1.0;

  // Native renderer's projection FOV (must match
  // scene_iosurface_renderer.cpp's hardcoded 60° vertical FOV — if that
  // changes there, change here too. The fit formula r / sin(fov/2)
  // *must* use the same FOV the GPU is actually rendering with).
  static const double _kNativeFovRad = 60.0 * math.pi / 180.0;

  // Padding multiplier for the fit distance — pulls the camera back so
  // the silhouette only fills 80% of the viewport (10% top + 10% bottom
  // margin matches the user-spec'd framing).
  static const double _kFitPadding = 1.25;

  // Hard cap on the per-card IOSurface dimension. Dawn's iOS Metal
  // backend has a SharedTextureMemory creation path
  // (dawn::native::metal::SharedTextureMemory::CreateMtlTextures →
  // [device newTextureWithDescriptor:iosurface:plane:]) that returns
  // nil under multi-instance + large-IOSurface conditions on iOS 17+,
  // tripping `DAWN_INVALID_IF` and SIGABRT. Home-screen has been
  // happy for weeks at 256×256; feed cards on iPhone Pro Max would
  // otherwise allocate 1080×1080 (393pt × 3 dpr) per card, and the
  // Nth concurrent allocation hits the failure case.
  //
  // 768 is the minimum that still looks crisp on a 360pt card at 3×
  // dpr (would natively want 1080, but the texture is filtered down
  // by Flutter's compositor when the source is bigger than the
  // display rect — 768 is ~2.1× dpr, indistinguishable from 3× at
  // arm's length). If this cap turns out to still trip Dawn we drop
  // to 512.
  static const int _kMaxTexDim = 768;

  @override
  void initState() {
    super.initState();
    _fitDistance = widget.fallbackCameraDistance;
    // Defer to post-frame so MediaQuery / context.size are available.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
    _warningSub = SceneBridge.instance.warnings.listen(_handleNativeWarning);
  }

  void _handleNativeWarning(WarningEvent event) {
    if (_disposedFlag || !mounted) return;
    if (!event.affects(_textureId)) {
      // Either thermal (informational; native kept everything alive),
      // OR memory event that disposed OTHER cards' textures (the LRU
      // kept ours alive because we're the focused card). Either way no
      // tear-down needed; the user keeps seeing the model uninterrupted.
      return;
    }
    debugPrint('[AetherCppCardDemo] native warning kind=${event.kind} '
        '— textureId=$_textureId destroyed; rebuilding');
    // Drop all GPU references (the native SharedNativeTexture is gone)
    // + reset state, then re-run the create/load/fit chain. The cover
    // crossfade hides the flash.
    _ticker?.dispose();
    _ticker = null;
    _lastTickElapsed = null;
    final dead = _viewer;
    _viewer = null;
    if (dead != null) {
      // Fire-and-forget — destroyTexture on a dead id is a no-op
      // native-side; safe to call.
      unawaited(dead.dispose());
    }
    setState(() {
      _textureId = null;
      _modelReady = false;
      _loadFailed = false;
    });
    // Re-run the cold start. Defer to post-frame so any pending
    // build / layout settles first.
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (_disposedFlag || !mounted) return;
    try {
      final size = context.size ?? const Size(360, 360);
      final mq = MediaQuery.maybeOf(context);
      final scale = mq?.devicePixelRatio ?? 2.0;
      // Cap at _kMaxTexDim so multi-card feed doesn't trip the Dawn
      // SharedTextureMemory::CreateMtlTextures crash on iOS 17+
      // (see _kMaxTexDim doc).
      //
      // ASPECT-PRESERVING CLAMP: independently clamping width and
      // height each to _kMaxTexDim flattens the IOSurface to a square
      // when the widget is portrait/landscape (e.g. detail page is
      // 393×601pt, dpr=3 → naïve clamp = 768×768; widget then
      // stretches the square texture into a 1.53:1 portrait rect, so
      // the model arrives geometrically squashed). Scaling both
      // dimensions by the same factor preserves the widget's aspect
      // ratio in the IOSurface; the native renderer's projection
      // (computed from texture w/h) then matches what the Flutter
      // texture widget will display.
      final pxWRaw = (size.width * scale).round();
      final pxHRaw = (size.height * scale).round();
      final longSide = pxWRaw > pxHRaw ? pxWRaw : pxHRaw;
      final scaleDown = longSide > _kMaxTexDim
          ? _kMaxTexDim / longSide
          : 1.0;
      // Round up to multiples of 4 — Metal IOSurface validation
      // requires bytesPerRow aligned to 16 bytes, and BGRA8 = 4 bytes/
      // pixel, so width must be a multiple of 4 for stride to land on
      // 16-byte boundaries. The detail-page failure was:
      //   widget = 393×583pt @ dpr=3, naive scale → 517×768
      //   bytesPerRow = 517 * 4 = 2068, NOT aligned to 16
      //   _mtlValidateStrideTextureParameters assertion → no IOSurface
      // Rounding up to 520 → 520 * 4 = 2080 ✓ aligned. Three extra
      // pixels at the right edge are never sampled because Flutter
      // displays at the original widget size.
      int alignUp4(int v) => ((v + 3) ~/ 4) * 4;
      final pxW = alignUp4((pxWRaw * scaleDown).round()).clamp(1, _kMaxTexDim);
      final pxH = alignUp4((pxHRaw * scaleDown).round()).clamp(1, _kMaxTexDim);

      final impl = AetherCppViewerImpl();
      _viewer = impl;
      debugPrint('[AetherCppCardDemo] create ${widget.modelUrl} '
          'size=${size.width.toInt()}x${size.height.toInt()}pt '
          'dpr=$scale → ${pxW}x${pxH}px');
      final id = await impl.create(
        width: pxW.toDouble(),
        height: pxH.toDouble(),
      );
      if (_disposedFlag || !mounted || id == null) return;
      setState(() => _textureId = id);

      // Phase 6.4f hotfix: feed cards (interactive=false) cap splat
      // memory to ~3 MB / scene by dropping higher-order SH and
      // subsampling. Detail page (interactive=true) keeps full quality.
      final bounds = await impl.load(
        widget.modelUrl,
        quality: widget.interactive
            ? ViewerQuality.full
            : ViewerQuality.feedThumbnail,
        overrides: widget.splatOverrides,
      );
      if (_disposedFlag || !mounted) return;

      if (bounds != null) {
        // model-viewer formula: dist = r / sin(fov/2). r is the AABB
        // half-diagonal (sphere that bounds the box). Padding 1.25
        // pulls camera back so silhouette is ~80% of the frame.
        final r = bounds.sphereRadius;
        if (r.isFinite && r > 0) {
          final sinHalfFov = math.sin(_kNativeFovRad * 0.5);
          final dist = (r / sinHalfFov) * _kFitPadding;
          if (dist.isFinite && dist > 0) {
            _fitDistance = dist;
            _modelCenter = bounds.center;
            // Interactive orbit defaults: start at fitted distance,
            // pinch range = [r * 1.05 (just outside the model), 4×
            // dist (zoom out enough to see neighborhood without
            // tripping the native far plane, which is sized at
            // r*100 in scene_iosurface_renderer.cpp's render_full).
            _orbitRadius = dist;
            _minRadius = math.max(r * 1.05, dist * 0.5);
            _maxRadius = dist * 4.0;
            debugPrint('[AetherCppCardDemo] fit ${widget.modelUrl}: '
                'r=${r.toStringAsFixed(2)} '
                'center=(${bounds.center.x.toStringAsFixed(2)},'
                '${bounds.center.y.toStringAsFixed(2)},'
                '${bounds.center.z.toStringAsFixed(2)}) '
                '→ dist=${dist.toStringAsFixed(2)}');
          }
        }
      } else {
        debugPrint('[AetherCppCardDemo] fit ${widget.modelUrl}: '
            'no bounds — fallback dist=$_fitDistance');
        _orbitRadius = _fitDistance;
        _minRadius = _fitDistance * 0.5;
        _maxRadius = _fitDistance * 4.0;
      }

      // Push the fitted camera frame BEFORE deciding whether to spin
      // up the ticker so the first textured frame is already framed.
      // Without this, the user sees an un-framed (camera at fallback
      // distance) flash for one frame on mount.
      await _pushFrame();
      if (_disposedFlag || !mounted) return;

      // Phase 6.4f hotfix: wait for the native displayLink to actually
      // render at least one frame into the IOSurface before flipping
      // _modelReady (which fades the loading cover out). _pushFrame
      // above only calls setMatrices → marks the texture dirty; the
      // actual GPU render happens on the next displayLinkTick (16 ms
      // at 60 fps, 33 ms at 30 fps thermal-throttled). Without this
      // wait the cover fades while the IOSurface is still empty, and
      // the user sees a ~30 ms "small dark dot" flash between the
      // spinner and the rendered model — a visually-distinct third
      // viewer state with no UX justification. 80 ms covers worst-case
      // 30 fps + a few ticks of CPU jitter while staying well below
      // perception threshold.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (_disposedFlag || !mounted) return;

      // Bug-fix: only run the auto-rotate ticker when this card is the
      // focused feed card. Static cards push exactly one frame (the
      // fitted pose above) and let the native displayLink's dirty-flag
      // gate skip them on subsequent ticks.
      //
      // Interactive mode (detail page) replaces auto-rotate with user
      // gestures — the ticker stays off; setMatrices fires only when
      // the user moves a finger (in _applyOrbit). Skipping the ticker
      // also keeps the model still until first touch, matching the
      // detail-page expectation.
      if (widget.isFocused && !widget.interactive) {
        _ticker = createTicker(_onTick)..start();
      }
      // Even in interactive mode the first frame should reflect the
      // user's expected initial pose (orbit angle 0, fitted distance,
      // tilt 0.05). _pushFrame uses the auto-rotate path's eye
      // computation when not interactive, so push an interactive-
      // shaped frame here too.
      if (widget.interactive) {
        unawaited(_applyOrbit());
      }
      // Texture has its first valid frame; flip the cover off.
      setState(() => _modelReady = true);
      // Phase 6.4f.9: notify parent (PostCard) so it can crossfade out
      // its thumbnail backdrop. Wrapped in a try because the callback
      // is owned by the parent and may throw — we don't want a parent
      // bug to mark this card as failed.
      try {
        widget.onFirstFrameReady?.call();
      } catch (e, s) {
        debugPrint('[AetherCppCardDemo] onFirstFrameReady threw: $e\n$s');
      }
    } on UnsupportedViewerFormatError catch (e) {
      // G5: typed error path for "format we know about but can't
      // render yet" (PLY / SPZ / SPLAT pre-Phase-6.4f). Logs in a
      // distinct flavor so the diagnostic call site is easy to grep.
      debugPrint('[AetherCppCardDemo] unsupported format: $e');
      if (mounted) setState(() => _loadFailed = true);
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
    // Camera orbits around the AABB center on the XZ plane with a
    // small (~3°) tilt down so the top of the model is visible.
    // Looking at modelCenter, NOT origin — many GLBs have AABBs
    // offset from local origin (re-exported scans, multi-mesh
    // scenes). Aiming at origin would just stare past the model.
    final eye = v64.Vector3(
      _modelCenter.x + _fitDistance * math.sin(_angle),
      _modelCenter.y + _fitDistance * 0.05,
      _modelCenter.z + _fitDistance * math.cos(_angle),
    );
    final view = v64.makeViewMatrix(
      eye,
      _modelCenter,
      v64.Vector3(0, 1, 0),
    );
    final model = v64.Matrix4.identity();
    await viewer.render(viewMatrix: view, modelMatrix: model);
  }

  // ─── Interactive orbit (detail page) ─────────────────────────────
  // Mirrors LiveModelView's _onScaleStart / _onScaleUpdate /
  // _applyOrbit triplet, ported on 2026-05-02 when the detail page
  // migrated from LiveModelView (thermion) to AetherCppCardDemo.

  void _onScaleStart(ScaleStartDetails d) {
    _pinchStartRadius = _orbitRadius;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_disposedFlag || !mounted) return;
    if (d.pointerCount >= 2) {
      // 2+ fingers: pinch-zoom. d.scale is the cumulative scale from
      // gesture start (1.0 = no change, >1 = pinching out / zoom in,
      // <1 = pinching in / zoom out). Inverse-scale the start radius.
      final prevRadius = _orbitRadius;
      final next = _pinchStartRadius / d.scale;
      _orbitRadius = next.clamp(_minRadius, _maxRadius);
      // Phase 6.4f hotfix diagnostic — user reports SPZ detail page
      // pinch doesn't visibly zoom while GLB works. Log so we can
      // tell whether the pinch is firing at all and how it maps.
      debugPrint('[AetherCppCardDemo] pinch '
          'scale=${d.scale.toStringAsFixed(3)} '
          '${prevRadius.toStringAsFixed(2)} → ${_orbitRadius.toStringAsFixed(2)} '
          '(min=${_minRadius.toStringAsFixed(2)} '
          'max=${_maxRadius.toStringAsFixed(2)} '
          'pointers=${d.pointerCount})');
    } else {
      // 1 finger: drag-orbit.
      _orbitAzimuth -= d.focalPointDelta.dx * _kTouchSensitivity;
      _orbitElevation +=
          d.focalPointDelta.dy * _kTouchSensitivity * _kYInversion;
      _orbitElevation =
          _orbitElevation.clamp(-math.pi / 2 + 0.05, math.pi / 2 - 0.05);
    }
    unawaited(_applyOrbit());
  }

  Future<void> _applyOrbit() async {
    final viewer = _viewer;
    if (viewer == null) return;
    final cosE = math.cos(_orbitElevation);
    final eye = v64.Vector3(
      _modelCenter.x + _orbitRadius * cosE * math.sin(_orbitAzimuth),
      _modelCenter.y + _orbitRadius * math.sin(_orbitElevation),
      _modelCenter.z + _orbitRadius * cosE * math.cos(_orbitAzimuth),
    );
    final view = v64.makeViewMatrix(
      eye,
      _modelCenter,
      v64.Vector3(0, 1, 0),
    );
    final model = v64.Matrix4.identity();
    await viewer.render(viewMatrix: view, modelMatrix: model);
  }

  @override
  void didUpdateWidget(covariant AetherCppCardDemo oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Track parent-driven focus changes so a card that becomes the
    // most-centered one in the feed starts auto-rotating without
    // remounting (and stops when scrolled away). Mirrors LiveModelView's
    // autoRotate=widget.isFocused passthrough.
    if (oldWidget.isFocused == widget.isFocused) return;
    if (!_modelReady) return;
    if (widget.isFocused) {
      _ticker ??= createTicker(_onTick)..start();
    } else {
      _ticker?.dispose();
      _ticker = null;
      _lastTickElapsed = null;
    }
  }

  @override
  void dispose() {
    _disposedFlag = true;
    _warningSub?.cancel();
    _warningSub = null;
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
    final id = _textureId;
    final inner = ColoredBox(
      color: widget.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Texture goes BEHIND the cover. Until the texture id is
          // assigned (i.e. createTexture returned), drop in a
          // SizedBox.shrink() so the Stack has only the cover layer
          // showing the spinner.
          if (id != null) Texture(textureId: id) else const SizedBox.shrink(),
          // Cover layer — same crossfade pattern LiveModelView uses
          // (see live_model_view.dart Stack tree comment for the
          // rationale; condensed: the 300ms fade hides the race
          // between "createTexture returned" and "first frame
          // pushed via setMatrices").
          IgnorePointer(
            ignoring: _modelReady,
            child: AnimatedOpacity(
              opacity: _modelReady ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: _AetherCardCover(failed: _loadFailed),
            ),
          ),
        ],
      ),
    );
    // Interactive (detail page) — wrap in a GestureDetector that owns
    // 1-finger drag (orbit) + 2-finger pinch (zoom). Both go through
    // ScaleStart/Update because Flutter's GestureArena routes a
    // 1-pointer drag through the Scale gesture too (with scale=1 and
    // pointerCount=1), so we don't need a separate Pan handler.
    // HitTestBehavior.translucent lets parent gestures still receive
    // taps that don't translate into a scale (e.g. the back button
    // on detail page chrome).
    if (widget.interactive) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        child: inner,
      );
    }
    return inner;
  }
}

/// Loading / failure cover. Visually identical to LiveModelView's
/// _LoadCover but without retry — the feed card lifecycle remounts on
/// scroll-back so a transient failure self-heals on the next visit.
class _AetherCardCover extends StatelessWidget {
  final bool failed;

  const _AetherCardCover({required this.failed});

  @override
  Widget build(BuildContext context) {
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.grey.shade100, Colors.grey.shade200],
    );
    if (failed) {
      return DecoratedBox(
        decoration: BoxDecoration(gradient: gradient),
        child: const Center(
          child: Icon(
            Icons.error_outline_rounded,
            size: 32,
            color: AetherColors.textTertiary,
          ),
        ),
      );
    }
    // Loading state per UX direction (2026-05-02): clean gradient cover
    // with NO spinner. Even bumped to 48×48, the spinner read as a
    // separate "indicator" state distinct from "loading vs display",
    // adding cognitive overhead. Modern feed-style viewers (Polycam /
    // KIRI / Pinterest masonry) all use bare placeholder gradients —
    // the absence of content is itself the signal that content is
    // being fetched. The 300 ms cross-fade to the rendered Texture
    // gives the perceptual cue that something just arrived.
    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
    );
  }
}
