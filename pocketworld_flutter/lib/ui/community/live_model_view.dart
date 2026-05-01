// LiveModelView — Thermion (Filament) viewer that loads a .glb from a
// network URL at runtime and renders into a Flutter Texture.
//
// Why this exists: liquid_glass_renderer's GPU shader can only sample
// pixels that live in the Flutter framebuffer. WKWebView (the previous
// model_viewer_plus path) draws as an iOS hardware overlay, invisible
// to the shader → glass rendered as a flat dark color. Thermion writes
// straight into a Flutter Texture, so the helmet pixels are sampleable
// and the glass plate refracts them for real.
//
// Multi-instance: each ViewerWidget allocates its own Filament View /
// Scene / Camera / SwapChain off the shared FilamentApp. Mounting
// several at once (one per visible feed card) is supported; throttle
// via the parent's visibility threshold so we don't burn GPU on cards
// scrolling past.
//
// Loading: bytes flow GlbCache.fetch(url) → loadGltfFromBuffer. The
// raw-bytes path sidesteps loadGltf's path/asset/file:// resolution.
//
// ──── Two structural problems we fix here ─────────────────────────────
//
// (1) RED FLASH on mount/remount.
//     Thermion's stack: ViewerWidget → ThermionWidget → ThermionTextureWidget.
//     `ThermionTextureWidget.build` returns `Container(color: Colors.red)`
//     when its Flutter Texture descriptor isn't yet allocated, AND
//     `ViewerWidget` does NOT forward `initial` down to ThermionWidget,
//     so the inner red fallback is what shows for the ~few frames
//     between createViewer and texture allocation.
//
//     Fix: stack an opaque cover ABOVE the ViewerWidget, painted in
//     widget.background, kept until our asset has finished loading
//     (`_modelReady`). The cover is INSIDE LiveModelView's tree, so
//     it survives detail-page push/pop without flickering.
//
// (2) ROTATION FREEZE after detail-page pop (no red flash case).
//     Bare Dart `Timer.periodic` is NOT bound to Flutter's TickerMode.
//     During a route transition, the underlying route is moved offstage
//     and Filament's render loop pauses; my timer kept firing camera
//     updates into a stalled renderer, and on return the rendering
//     pipeline didn't pick the changes back up — model appeared frozen.
//
//     Fix: use a Flutter `Ticker` (via SingleTickerProviderStateMixin).
//     Tickers AUTOMATICALLY mute on offstage routes and resume on the
//     route returning to the foreground. No manual deactivate/activate
//     dance.
//
// ──── Camera + lighting ───────────────────────────────────────────────
//
// ViewerWidget owns the Camera; we cache a handle in onViewerAvailable
// so the rotation tick / orbit gestures don't FFI-call getActiveCamera
// per frame. Lighting is IBL-ONLY — a neutral environment cube loaded
// from `assets/ibl/default_env_ibl.ktx`, no directional lights. This
// matches Polycam / Luma AI / Scaniverse's "scan viewer" style: capture-
// baked lighting in baseColor textures shouldn't be double-lit by the
// viewer.
//
// ──── Color ───────────────────────────────────────────────────────────
//
// Postprocessing is ON (gives us FXAA), but we override Filament's
// default ACES tone mapper to LINEAR — ACES pushes a pure-white scene
// toward film-warm yellow. Filament's clear color is set to FULLY
// TRANSPARENT and the LiveModelView wraps everything in a
// ColoredBox(white) so Flutter's compositor paints the background.
//
// ──── Interaction ─────────────────────────────────────────────────────
//
// When [interactive] is true (detail page) we DON'T use Thermion's
// built-in ORBIT manipulator — its sensitivity is fixed at 0.001/event
// with no per-axis inversion knob. Instead we mount with NONE and drive
// the camera ourselves from a Flutter GestureDetector: 1-finger drag =
// orbit (Y inverted, ≈5× more responsive than Thermion default),
// 2-finger pinch = zoom.
//
// ──── Cross-platform ──────────────────────────────────────────────────
//
// Thermion supports iOS / Android / macOS / Windows / Web (WASM).
// HarmonyOS is best-effort like every other Flutter plugin without an
// official ohos channel impl.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart' hide View;
import 'package:flutter/scheduler.dart';
// thermion_flutter re-declares VoidCallback as an ffi pointer typedef
// that clashes with Flutter's `void Function()` of the same name. We
// don't use thermion's, so hide it.
import 'package:thermion_flutter/thermion_flutter.dart' hide VoidCallback;
import 'package:vector_math/vector_math_64.dart' as v64;

import '../../community/glb_asset_cache.dart';
import '../design_system.dart';

class LiveModelView extends StatefulWidget {
  final String modelUrl;
  /// True → camera spins slowly around the model's Y axis. Off-focused
  /// cards pass false so they sit still (saves GPU + matches the
  /// Polycam-style "only the centered card animates" feel). Ignored
  /// when [interactive] is true — the user's gestures own the camera.
  final bool autoRotate;
  /// True → enable manual orbit gestures (1-finger drag = rotate, 2-
  /// finger pinch = zoom). Used by the detail page. Feed cards leave
  /// it false so the parent GestureDetector's single-tap → push-detail
  /// path wins.
  final bool interactive;
  /// Solid color shown both behind the model and as the cover that
  /// hides the load-in red flash. Painted by Flutter's compositor under
  /// a transparent Filament clear color so it's guaranteed pure.
  final Color background;
  /// Initial camera distance from the unit-cube origin. transformToUnitCube
  /// in ViewerWidget normalizes any glb to fit a 1-unit cube, but the
  /// cube's diagonal is ~1.73 — to consistently frame *the whole model*
  /// (including off-center / wide ones like ToyCar that previously hung
  /// out of frame) we need ~5.5 distance with a near-horizontal eye.
  final double cameraDistance;

  /// Whether to load the neutral environment IBL (Image-Based Lighting)
  /// cube into the Filament scene. Off by default on the detail page —
  /// captured GLBs are expected to ship baked lighting in their
  /// baseColor textures, and stacking IBL on top double-lights the
  /// model. Feed cards (small thumbnails) keep IBL on so generic
  /// PBR sample assets without baked lighting still read as material,
  /// not flat colour.
  final bool useEnvironmentLighting;

  const LiveModelView({
    super.key,
    required this.modelUrl,
    this.autoRotate = false,
    this.interactive = false,
    this.background = Colors.white,
    this.cameraDistance = 5.5,
    this.useEnvironmentLighting = true,
  });

  @override
  State<LiveModelView> createState() => _LiveModelViewState();
}

class _LiveModelViewState extends State<LiveModelView>
    with SingleTickerProviderStateMixin {
  ThermionViewer? _viewer;
  // Cached at onViewerReady so the tick / gesture handlers don't FFI-
  // call viewer.getActiveCamera() per event AND so we have a stable
  // handle that can't get yanked out from under us mid-tick.
  Camera? _camera;

  // ─── Auto-rotate Ticker ──────────────────────────────────────────────
  // A Ticker (vs raw Timer.periodic) binds to Flutter's TickerMode and
  // auto-mutes when the widget is on an offstage route — that's what
  // pauses rotation cleanly during navigation. On pop, TickerMode flips
  // back on and the ticker resumes.
  //
  // Angle is accumulated DELTA-BY-DELTA from per-tick `dt`, NOT computed
  // as `(elapsed_since_start) × speed`. Why: when nav-push offstage and
  // pop back on, Ticker.elapsed pauses-and-resumes as expected, but
  // Flutter ALSO sometimes recreates the State (sticky-mount unmount
  // after 5s timeout, parent rebuilds with focus changes, etc.) and a
  // freshly-started ticker has elapsed=0 → would snap angle back to 0.
  // Worse, after a long pause Ticker.elapsed can lurch forward by the
  // pause duration on the first resumed tick → angle would jump mid-
  // rotation. Both bugs disappear when we just integrate dt frame-by-
  // frame and clamp dt to one frame's worth.
  Ticker? _rotateTicker;
  bool _tickInflight = false;
  // Last-tick elapsed reading — null on a fresh ticker so the very
  // first tick is "do nothing, just establish a baseline".
  Duration? _lastTickElapsed;
  // Persisted across ticker restarts (deliberately a State field, NOT
  // reset in _restartRotateTicker). Polycam-style: leaving freezes at
  // current angle, returning continues from there.
  double _angle = 0.0;

  // ─── Manual orbit (interactive mode) ─────────────────────────────────
  late double _orbitAzimuth = 0.0;
  // Near-horizontal default — sits the camera essentially on the model's
  // equator so wide / asymmetric models (cars, lying-down cameras) read
  // as "the whole thing" instead of "a top-down peek at the chassis".
  late double _orbitElevation = 0.05;
  late double _orbitRadius = widget.cameraDistance;

  // ─── Auto-fit ────────────────────────────────────────────────────────
  // `widget.cameraDistance` is only the initial / fallback value. After
  // the asset lands in the scene we ask thermion for its bounding box
  // and compute the distance that frames the model's post-transform
  // AABB given a KNOWN field of view we pin via setLensProjection.
  //
  // Background: thermion 0.3.4's Camera.getVerticalFieldOfView()
  // returned 46.4 in our test (≈ 2658° if interpreted as radians) —
  // that's clearly the focal length in mm, not a FOV. Whatever the
  // actual unit is, we don't trust it, so we set our own known focal
  // length and back the FOV out from sensor-height / 2 / focalLength,
  // which is the classic 35mm-equivalent definition Filament uses.
  // Pinned focal length we attempt to install on the camera; the
  // actual fit math reads the projection matrix directly so it's
  // resilient to setLensProjection no-oping.
  static const double _kFocalLengthMM = 50.0;

  double? _fittedDistance;
  double get _autoRotateDistance =>
      _fittedDistance ?? widget.cameraDistance;
  double _pinchStartRadius = 0.0;

  // ≈5× Thermion's stock 0.001/event so a half-screen drag rotates
  // ~120° instead of ~24° — matches the perceived feel from the
  // previous model_viewer_plus build.
  static const double _touchSensitivity = 0.005;
  // Y-axis sign — the user's standing preference is "drag DOWN → see
  // TOP of model". My elevation math: eye.y = r * sin(elevation), so
  // INCREASING elevation moves camera up → looks down → reveals top.
  // Drag DOWN = positive dy; need elevation to ADD → multiplier +1.0.
  // (Triple-check the math when changing — got this wrong twice.)
  static const double _yInversion = 1.0;
  static const double _minRadius = 1.5;
  static const double _maxRadius = 20.0;

  // ─── Load gating ─────────────────────────────────────────────────────
  // _modelReady stays false until the asset is in the scene + the first
  // textured frame has rendered. _loadFailed flips when the bytes /
  // parse / addToScene step gives up. The cover layer reads both: not-
  // ready shows a thumbnail + spinner; failed shows a tap-to-retry
  // affordance. Without _loadFailed the cover stays opaque forever on
  // any error and the user sees a permanently white card — that's the
  // "the feed never loads any model" complaint.
  bool _modelReady = false;
  bool _loadFailed = false;
  bool _disposed = false;

  Future<void> _onViewerReady(ThermionViewer viewer) async {
    if (_disposed) return;
    _viewer = viewer;
    try {
      await viewer.setToneMapping(ToneMapper.LINEAR);
      await viewer.setAntiAliasing(false, true, false);
      // Filament's clear color → fully transparent. The white we want
      // behind the model is painted by the outer ColoredBox in build().
      await viewer.setBackgroundColor(0.0, 0.0, 0.0, 0.0);
      // IBL-only ("Polycam style" — no directional lights). See file
      // header for the rationale; in short, double-lighting baked
      // scan textures looks wrong. Skipped when the caller has flagged
      // useEnvironmentLighting=false (typically the detail page on
      // a captured scan, where the baseColor already carries the
      // baked lighting from the original capture).
      if (widget.useEnvironmentLighting) {
        await viewer.loadIbl('assets/ibl/default_env_ibl.ktx',
            intensity: 30000);
      }

      if (_disposed) return;
      _camera = await viewer.getActiveCamera();
      if (_disposed) return;
      // Pin the lens to a known portrait focal length so _computeFit's
      // tan() math is grounded. Without this, thermion's default lens
      // produces FOVs that disagree with the getter's reported value
      // (the getter returned 46.4 in testing — clearly the focal length
      // in mm, not radians or degrees), which scaled the fit distance
      // down by ~10x and overshot every model into the camera.
      try {
        await _camera!.setLensProjection(
          focalLength: _kFocalLengthMM,
          aspect: 1.0,
        );
      } catch (e) {
        debugPrint('[LiveModelView] setLensProjection failed: $e');
      }
      await _loadAsset();
    } catch (e, st) {
      debugPrint('[LiveModelView] viewer init failed for ${widget.modelUrl}: '
          '$e\n$st');
      _markLoadFailed();
    }
  }

  /// Asset-only load step, factored out of _onViewerReady so retry
  /// (the failure-state tap target) can re-run it without redoing the
  /// expensive viewer setup.
  Future<void> _loadAsset() async {
    final viewer = _viewer;
    final camera = _camera;
    if (viewer == null || camera == null || _disposed) return;
    if (mounted) {
      setState(() {
        _loadFailed = false;
        _modelReady = false;
      });
    }
    try {
      // Asset is owned by the anchor viewer (lib/community/anchor_viewer.dart),
      // not by us — so when this card's viewer disposes, the asset stays
      // alive in GPU memory. First request for a URL pays the parse +
      // upload (~200ms); every subsequent mount, including detail-page
      // push and feed return, is just a scene-list bookkeeping op (~5ms).
      final asset = await _fetchAsset();
      if (_disposed) return;
      if (asset == null) {
        _markLoadFailed();
        return;
      }
      // Defensive: between this widget mounting and the asset coming
      // back from cache, Filament's underlying engine could have been
      // torn down (race during fast nav out + back). The FFI call
      // would then dereference a freed pointer → EXC_BAD_ACCESS at
      // SceneAsset_addToScene that brings down the whole process and
      // leaves iOS stuck on the launch screen. A try/catch around the
      // FFI calls converts that into a recoverable failure.
      try {
        await viewer.addToScene(asset);
        if (_disposed) return;
        await asset.setCastShadows(false);
      } catch (e, st) {
        debugPrint(
            '[LiveModelView] addToScene failed for ${widget.modelUrl} '
            '(probably viewer disposed mid-load): $e\n$st');
        _markLoadFailed();
        return;
      }

      // Auto-fit: thermion knows the asset's local-space AABB; the
      // unit-cube transform scales the longest axis to 1; combine with
      // Filament's FOV to land on a distance that frames the model
      // regardless of its proportions. Failures fall back to
      // widget.cameraDistance.
      await _computeFit(asset, camera);
      if (_disposed) return;

      if (widget.interactive) {
        await _applyOrbit();
      } else {
        _restartRotateTicker();
      }

      // Wait until the current Flutter frame finishes rasterizing, then
      // give thermion a short grace period so its async texture upload
      // / first scene render has actually landed on the GPU before we
      // start fading the cover out. Without this the cover sometimes
      // peels off one or two frames too early and the user sees the
      // raw red ThermionTextureWidget fallback.
      await SchedulerBinding.instance.endOfFrame;
      if (_disposed || !mounted) return;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (_disposed || !mounted) return;
      setState(() {
        _modelReady = true;
        _loadFailed = false;
      });
    } catch (e, st) {
      debugPrint(
          '[LiveModelView] load failed for ${widget.modelUrl}: $e\n$st');
      _markLoadFailed();
    }
  }

  void _markLoadFailed() {
    if (_disposed || !mounted) return;
    setState(() {
      _loadFailed = true;
      _modelReady = false;
    });
  }

  void _retryLoad() {
    if (_disposed) return;
    unawaited(_loadAsset());
  }

  Future<ThermionAsset?> _fetchAsset() async {
    try {
      return await GlbAssetCache.instance.getOrLoad(widget.modelUrl);
    } catch (e) {
      debugPrint(
          '[LiveModelView] asset load failed for ${widget.modelUrl}: $e');
      return null;
    }
  }

  // ─── Auto-rotate ─────────────────────────────────────────────────────

  void _restartRotateTicker() {
    _rotateTicker?.dispose();
    _rotateTicker = null;
    // _lastTickElapsed reset so the new ticker's first tick establishes
    // its own baseline; _angle deliberately preserved.
    _lastTickElapsed = null;
    if (!widget.autoRotate || widget.interactive || _viewer == null) return;
    _rotateTicker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    if (_disposed || _tickInflight) return;
    final last = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    // First tick after a (re)start: establish the baseline, contribute
    // zero rotation. Avoids attributing all of "elapsed since ticker
    // start" (potentially seconds, on a first-frame resume) to one tick.
    if (last == null) return;
    final dtSec = (elapsed - last).inMicroseconds / 1e6;
    // Clamp to one frame's worth (~16ms × a few). Catches the rare case
    // where Ticker.elapsed lurches after a long offstage pause; without
    // the cap that lurch would integrate into a visible angle jump.
    final clamped = dtSec.clamp(0.0, 0.05);
    // 0.6 rad/sec ≈ 34°/sec.
    _angle += clamped * 0.6;
    if (_angle > 2 * math.pi) _angle -= 2 * math.pi;
    unawaited(_applyAutoRotate());
  }

  Future<void> _applyAutoRotate() async {
    _tickInflight = true;
    try {
      var cam = _camera;
      if (cam == null) {
        final viewer = _viewer;
        if (viewer == null) return;
        cam = await viewer.getActiveCamera();
        if (_disposed) return;
        _camera = cam;
      }
      final r = _autoRotateDistance;
      // Near-horizontal eye (~3° tilt) on the orbit plane. Keeps wide
      // models like ToyCar fully in frame as the camera spins. Focus
      // is the unit-cube center (transformToUnitCube re-centers any
      // model there).
      final eye = v64.Vector3(
        r * math.sin(_angle),
        r * 0.05,
        r * math.cos(_angle),
      );
      if (_disposed) return;
      await cam.lookAt(eye, focus: v64.Vector3.zero());
    } catch (_) {
      // Drop cached camera so the next tick re-fetches; KEEP the
      // ticker running so rotation auto-recovers.
      _camera = null;
    } finally {
      _tickInflight = false;
    }
  }

  // ─── Manual orbit (interactive mode) ─────────────────────────────────

  void _onScaleStart(ScaleStartDetails d) {
    _pinchStartRadius = _orbitRadius;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_disposed) return;
    if (d.pointerCount >= 2) {
      final next = _pinchStartRadius / d.scale;
      _orbitRadius = next.clamp(_minRadius, _maxRadius);
    } else {
      _orbitAzimuth -= d.focalPointDelta.dx * _touchSensitivity;
      _orbitElevation +=
          d.focalPointDelta.dy * _touchSensitivity * _yInversion;
      _orbitElevation =
          _orbitElevation.clamp(-math.pi / 2 + 0.05, math.pi / 2 - 0.05);
    }
    unawaited(_applyOrbit());
  }

  Future<void> _applyOrbit() async {
    final cam = _camera;
    if (cam == null || _disposed) return;
    final cosE = math.cos(_orbitElevation);
    final eye = v64.Vector3(
      _orbitRadius * cosE * math.sin(_orbitAzimuth),
      _orbitRadius * math.sin(_orbitElevation),
      _orbitRadius * cosE * math.cos(_orbitAzimuth),
    );
    try {
      await cam.lookAt(eye, focus: v64.Vector3.zero());
    } catch (_) {
      _camera = null;
    }
  }

  /// Fit-to-bounds using post-transform AABB extents (NOT bounding
  /// sphere). The previous sphere-radius formula `sqrt(hx²+hy²+hz²) /
  /// maxAxis` always produced ~1.0 because transformToUnitCube
  /// normalizes the longest axis to 1, so every model — fat or thin —
  /// got framed at the same distance. That's wrong for elongated
  /// models like Corset (Y-axis dominant): the screen projection
  /// height = hy / distance × focal-factor, so a thin tall model
  /// actually overflows when the distance is tuned for an isotropic
  /// cube.
  ///
  /// New formula:
  ///   verticalRequired   = hy   / tan(fovV / 2)          // Y stays
  ///                                                       // fixed during
  ///                                                       // Y-axis spin
  ///   horizontalRequired = √(hx²+hz²) / tan(fovH / 2)    // worst-case
  ///                                                       // diagonal
  ///                                                       // during spin
  ///   distance = max(verticalRequired, horizontalRequired) × padding
  ///
  /// Padding bumped from 1.20 → 1.30 to leave a comfortable margin
  /// around the model's silhouette in the 1:1 PostCard frame.
  Future<void> _computeFit(ThermionAsset asset, Camera camera) async {
    try {
      final aabb = await asset.getBoundingBox();
      if (_disposed) return;
      // Local AABB half-extents (pre-transformToUnitCube).
      final hxLocal = (aabb.max.x - aabb.min.x) * 0.5;
      final hyLocal = (aabb.max.y - aabb.min.y) * 0.5;
      final hzLocal = (aabb.max.z - aabb.min.z) * 0.5;
      final maxAxis =
          math.max(hxLocal, math.max(hyLocal, hzLocal));
      if (!maxAxis.isFinite || maxAxis <= 0) return;
      // transformToUnitCube scales the longest axis to span [-1, 1].
      // Post-transform half-extents:
      final hxN = hxLocal / maxAxis;
      final hyN = hyLocal / maxAxis;
      final hzN = hzLocal / maxAxis;
      // Spin axis is Y, so horizontal silhouette swings between
      // max(hxN,hzN) (face on) and √(hxN²+hzN²) (corner on). Take the
      // diagonal as the worst case.
      final horizDiag = math.sqrt(hxN * hxN + hzN * hzN);
      // Read the projection matrix DIRECTLY rather than going through
      // setLensProjection + computed fov. setLensProjection in thermion
      // 0.3.4 has been observed to no-op silently in some cases (the
      // user reported a model still rendered ~20% of the viewport
      // when the math expected 80%, meaning the actual FOV was much
      // wider than our pinned 27° intent — i.e. thermion's lens was
      // still default).
      //
      // For a standard symmetric perspective projection:
      //   M[1][1] = cot(fovV/2) = 1 / tan(fovV/2)
      //   M[0][0] = cot(fovH/2)
      // The half-extent's NDC y projection at distance d is
      //   ndc_y = halfHeight × M[1][1] / d
      // We want ndc_y = 1.0 / padding (so the model fills 1/padding of
      // the visible NDC range), which gives:
      //   d = halfHeight × M[1][1] × padding
      // Same on the horizontal axis with M[0][0].
      final proj = await camera.getProjectionMatrix();
      if (_disposed) return;
      // vector_math Matrix4 is column-major: m[col * 4 + row].
      // entry(row, col) gives the math-textbook indexing.
      final m00 = proj.entry(0, 0);
      final m11 = proj.entry(1, 1);
      if (!m00.isFinite || m00 <= 0 || !m11.isFinite || m11 <= 0) return;
      const padding = 1.25; // 80% silhouette → 10% top + 10% bottom
      final dV = hyN * m11 * padding;
      final dH = horizDiag * m00 * padding;
      final dist = math.max(dV, dH);
      if (!dist.isFinite || dist <= 0) return;
      // Equivalent fov for the log only (NOT used in the math): so we
      // can spot when thermion's projection is wider/narrower than
      // expected without having to dump the whole matrix.
      final fovVdeg = 2 * math.atan(1.0 / m11) * 180 / math.pi;
      debugPrint('[LiveModelView] fit ${widget.modelUrl}: '
          'he=(${hxN.toStringAsFixed(2)}, ${hyN.toStringAsFixed(2)}, '
          '${hzN.toStringAsFixed(2)}) '
          'projM00=${m00.toStringAsFixed(2)} M11=${m11.toStringAsFixed(2)} '
          '(actual fovV≈${fovVdeg.toStringAsFixed(1)}°) '
          'dV=${dV.toStringAsFixed(2)} dH=${dH.toStringAsFixed(2)} '
          '→ ${dist.toStringAsFixed(2)}');
      _fittedDistance = dist;
      _orbitRadius = dist;
      if (mounted && !_disposed) {
        setState(() {});
      }
    } catch (e, s) {
      debugPrint('[LiveModelView] _computeFit failed: $e\n$s');
    }
  }

  // ─── Lifecycle ───────────────────────────────────────────────────────

  @override
  void didUpdateWidget(LiveModelView old) {
    super.didUpdateWidget(old);
    if (widget.autoRotate != old.autoRotate ||
        widget.interactive != old.interactive) {
      _restartRotateTicker();
    }
    if (widget.modelUrl != old.modelUrl) {
      debugPrint('[LiveModelView] modelUrl changed at runtime — '
          'caller should rebuild with a new ValueKey instead');
    }
  }

  @override
  void dispose() {
    // Order matters: flag first, kill ticker second, so any in-flight
    // tick that resumes after our awaits sees _disposed=true and bails
    // before re-touching FFI.
    _disposed = true;
    _rotateTicker?.dispose();
    _rotateTicker = null;
    // Don't call viewer.dispose() — ViewerWidget's own dispose runs
    // _tearDown() → viewer.dispose() already. Double-disposing races
    // on SceneAsset destruction → EXC_BAD_ACCESS in
    // thermion_dart`SceneAsset_destroy.
    _viewer = null;
    _camera = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget viewer = ViewerWidget(
      // The inner `ThermionTextureWidget` ignores this — see header
      // comment (1) — so we ALSO stack a cover above. Keeping this
      // matched anyway in case Thermion fixes the forwarding upstream.
      initial: ColoredBox(color: widget.background),
      // Transparent → outer ColoredBox shows through; matches the cover.
      background: const Color(0x00000000),
      manipulatorType: ManipulatorType.NONE,
      transformToUnitCube: true,
      postProcessing: true,
      destroyEngineOnUnload: false,
      // Match the eye in _applyAutoRotate / _applyOrbit so the very first
      // frame Filament renders is already framed correctly.
      initialCameraPosition:
          v64.Vector3(0, widget.cameraDistance * 0.05, widget.cameraDistance),
      onViewerAvailable: _onViewerReady,
    );

    if (widget.interactive) {
      viewer = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        child: viewer,
      );
    }

    return ColoredBox(
      color: widget.background,
      child: Stack(
        fit: StackFit.expand,
        children: [
          viewer,
          // Cover layer. Stays in the tree the whole time, fading from
          // opaque to transparent once _modelReady flips. The 300ms
          // crossfade covers the race between "asset added to scene"
          // and "Filament has rendered a textured frame", which a
          // hard switch occasionally leaks as a red ThermionTexture
          // flash for a frame or two. IgnorePointer flips off as soon
          // as we're ready so the underlying GestureDetector (in
          // interactive mode) gets hits.
          //
          // The cover's CONTENT depends on state:
          //   • loading (default): subtle gradient + small spinner so
          //     the user has a "something is happening" signal during
          //     the seconds-scale download of bigger GLBs.
          //   • failed: same gradient + a tap-to-retry affordance so
          //     a transient network blip doesn't leave a permanently
          //     blank card. Without this branch, an exception in
          //     _loadAsset leaves _modelReady=false forever and the
          //     user just sees a white card forever — that's the
          //     "feed never loads any model" symptom.
          IgnorePointer(
            ignoring: _modelReady,
            child: AnimatedOpacity(
              opacity: _modelReady ? 0.0 : 1.0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: _LoadCover(
                failed: _loadFailed,
                onRetry: _retryLoad,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadCover extends StatelessWidget {
  final bool failed;
  final VoidCallback onRetry;

  const _LoadCover({required this.failed, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Colors.grey.shade100, Colors.grey.shade200],
    );
    if (failed) {
      return GestureDetector(
        onTap: onRetry,
        behavior: HitTestBehavior.opaque,
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: gradient),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(
                  Icons.refresh_rounded,
                  size: 32,
                  color: AetherColors.textTertiary,
                ),
                SizedBox(height: 6),
                Text(
                  'Tap to retry',
                  style: TextStyle(
                    fontSize: 12,
                    color: AetherColors.textTertiary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(gradient: gradient),
      child: const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AetherColors.primary),
          ),
        ),
      ),
    );
  }
}
