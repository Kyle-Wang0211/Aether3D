// CapturePage v4 — minimalist layout (timer + valid-keyframes badge
// removed per user feedback; both UI and the bookkeeping behind them).
// Three structural regions over a full-bleed camera preview:
//
//   Top bar     38×38 X close button (right) + 8×8 tracking-state dot
//               (center). padding 16 horiz / 14 top.
//
//   Center      empty — camera preview shows through.
//
//   Bottom HUD  140×140 captureButtonOrDome dead-centered at the
//               bottom. Nothing else competes for attention.
//               padding 18 horiz / 18 bottom.
//
//   captureButtonOrDome: not-recording → 140×140 white ring + 119×119
//               black fill + central indicator. Recording → same
//               140×140 ring with the live dome inside; the whole thing
//               is the tap target that ends the capture.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../capture/capture_session.dart';
import '../../capture/dome/dome_target_points.dart';
import '../../dome/ar_pose.dart';
import '../../l10n/app_localizations.dart';
import '../../me/upload_coordinator.dart';
import '../../upload/capture_uploader.dart';
import 'dome_view.dart';

class CapturePage extends StatefulWidget {
  const CapturePage({super.key});

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage>
    with WidgetsBindingObserver {
  final DomeTargetPoints _targetPoints = DomeTargetPoints();
  CaptureSession? _session;
  StreamSubscription<ARPose>? _poseSub;

  String? _initError;
  bool _initializing = true;

  // Dome rotation target — driven by the AR pose stream's
  // position-based azimuth / elevation. Pre-lock both stay 0; once
  // the user taps to lock the world origin (Phase 5) the AR pose
  // populates them.
  double _yaw = 0;
  double _pitch = 0;
  bool _isTracking = true;
  bool _hasLockedOrigin = false;

  bool _recording = false;
  /// 3-state UX: idle → aim → recording.
  /// idle:      user has not started anything; tap → enter aim.
  /// aim:       crosshair shown center, tap → trigger lockOrigin AT
  ///            user's current aim direction. If lock succeeds, enter
  ///            recording. If fails, stay in aim with hint text.
  /// recording: video + dome live; tap → stop + upload.
  /// Replaces the legacy auto-lock UX where tapping record kicked off
  /// `_lockOriginWhenReady` retry loop in the background. User
  /// feedback: should be a deliberate "I'm aiming at the subject NOW"
  /// gesture, not a magic auto-lock.
  bool _isAiming = false;

  /// ARKit warm-up gate. False until trackingState has been continuously
  /// `.normal` for [_warmupSettleDuration]. While false, the center
  /// shutter button is disabled and a "正在初始化 AR…" hint replaces the
  /// "点击中心选择主体物" hint.
  ///
  /// Why this exists: on a thermally pressured device (e.g. user came
  /// from a home page that rendered spz models for a few minutes), if
  /// the user taps lock-subject the moment they hit the capture page,
  /// ARKit's visual SLAM is still warming up + may immediately drop to
  /// .notAvailable / .limited(initializing) for 1-2 s under
  /// `ARWorldTrackingTechnique resource constraints [33]`. The dome
  /// then freezes that whole time, which reads as "卡了几秒灰色". By
  /// gating the lock button until ARKit has been stably .normal for a
  /// short settle window, we ensure lockOrigin fires against a session
  /// that has actually settled, not one that's about to crash.
  bool _arWarmupComplete = false;
  Timer? _warmupTimer;
  static const Duration _warmupSettleDuration = Duration(milliseconds: 1500);

  // Pose-stream diagnostic — verifies events arrive at expected rate and
  // quality reports come at the throttled 6 Hz from the Swift side. Flip
  // `_kDiagLog` to false once the dome is debugged.
  static const bool _kDiagLog = true;
  final Stopwatch _diagPoseClock = Stopwatch()..start();
  int _diagPoseEvents = 0;
  int _diagQualityEvents = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  Future<void> _initCamera() async {
    // ARKit takes exclusive control of the back camera while the AR
    // session is running, so we DON'T initialize a Flutter `camera`
    // plugin CameraController in parallel — that produces
    // FigCaptureSourceRemote err=-17281 (camera service not
    // responding) and breaks both paths. The capture page operates
    // off the AR pose stream alone; native side reads pixel buffers
    // from `ARFrame.capturedImage` for the Laplacian / signature
    // pipeline.
    //
    // We call `session.attach()` here to start the ARSession as soon
    // as the page mounts. lockOrigin needs `tracking == .normal`,
    // which can take ~1-2 s after ARKit cold-start; by warming up
    // before the user taps Record, the lock fires against a stable
    // baseline pose instead of whatever angle ARKit happens to have
    // mid-warm-up while the user is still moving the phone.
    try {
      final session = CaptureSession(
        targetPoints: _targetPoints,
      );
      _poseSub = session.poseStream.listen((p) {
        if (!mounted) return;
        _diagPoseEvents++;
        if (p.quality != null) _diagQualityEvents++;
        if (_diagPoseClock.elapsedMilliseconds >= 5000) {
          final secs = _diagPoseClock.elapsedMilliseconds / 1000;
          if (_kDiagLog) {
            // ignore: avoid_print
            print('[CapturePage] 5s pose stream: '
                '$_diagPoseEvents events '
                '(${(_diagPoseEvents / secs).toStringAsFixed(1)} Hz), '
                '$_diagQualityEvents quality '
                '(${(_diagQualityEvents / secs).toStringAsFixed(1)} Hz), '
                'hasOrigin=${p.hasOrigin}');
          }
          _diagPoseEvents = 0;
          _diagQualityEvents = 0;
          _diagPoseClock.reset();
          _diagPoseClock.start();
        }
        setState(() {
          // `- π/2` offset matches ObjectModeV2ARDomeCoordinator line 721:
          //   uiView.updateRotation(targetYaw: snap.currentAzimuth - .pi/2, …)
          // Keeps the user's current cell pinned to the dome's +Z (screen
          // center) under iOS's vertex convention.
          _yaw = p.azimuth - math.pi / 2;
          _pitch = p.elevation;
          _isTracking = p.isTracking;
          _hasLockedOrigin = p.hasOrigin;
        });
        _checkArWarmup(p.isTracking);
      });
      await session.attach();
      if (!mounted) {
        await session.dispose();
        return;
      }
      setState(() {
        _session = session;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initError = AppL10n.of(context).captureInitFailed('$e');
        _initializing = false;
      });
    }
  }

  /// Track continuous time in `.normal` tracking. The first time we see
  /// isTracking=true we arm a 1.5 s timer; if tracking stays normal for
  /// the whole window the warmup gate flips open. If tracking drops back
  /// to limited / notAvailable mid-window, cancel the timer and try
  /// again on the next normal transition. Once the gate is open it
  /// stays open for the rest of the page's lifetime — recovering from
  /// transient tracking drops mid-capture is a separate concern handled
  /// by DomeView's frozen state.
  void _checkArWarmup(bool isTracking) {
    if (_arWarmupComplete) return;
    if (isTracking) {
      _warmupTimer ??= Timer(_warmupSettleDuration, () {
        if (!mounted) return;
        if (_kDiagLog) {
          // ignore: avoid_print
          print('[CapturePage] AR warmup complete after '
              '${_warmupSettleDuration.inMilliseconds}ms continuous '
              'tracking=normal; enabling lock button');
        }
        setState(() {
          _arWarmupComplete = true;
        });
      });
    } else {
      // Tracking dropped before the settle window finished — restart on
      // the next normal transition.
      if (_warmupTimer != null && _kDiagLog) {
        // ignore: avoid_print
        print('[CapturePage] AR warmup interrupted by tracking drop; '
            'will re-arm on next isTracking=true');
      }
      _warmupTimer?.cancel();
      _warmupTimer = null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_session == null) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Backgrounded — release the camera/sensor stack so the OS
      // doesn't kill us for holding the camera while inactive.
      _stopRecordingIfRunning();
    }
  }

  Future<void> _stopRecordingIfRunning() async {
    if (!_recording) return;
    await _session?.stop();
    if (!mounted) return;
    setState(() => _recording = false);
  }

  Future<void> _onCenterTap() async {
    final session = _session;
    if (session == null) return;

    if (_recording) {
      // RECORDING → STOP. The .mov + curated.json land in
      // Documents/scans/{id}.* as a DRAFT — no automatic network upload.
      // The user reviews the draft on the Me page Drafts tab and taps
      // "上传" when they choose to. (Pre-2026-05-10 we auto-uploaded;
      // user feedback was that they wanted explicit control over when
      // bytes leave the device, esp. on cellular.)
      await session.stop();
      if (!mounted) return;
      setState(() {
        _recording = false;
        _isAiming = false;
      });
      final curated = _targetPoints.curateForUpload(targetTotal: 118);
      if (curated.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppL10n.of(context).captureMaterialTooSparseHint),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      await _persistDraft();
      // Pop with `true` as a signal to AetherAppShell that it should
      // switch the active tab to Me Drafts (the user just created a
      // scan and expects to see it sitting in their drafts list).
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
      return;
    }

    if (_isAiming) {
      // AIM → try LOCK at user's current aim direction.
      // Single-shot (no retry loop). Failure leaves user in aim with
      // a hint snackbar so they can re-aim and retry.
      // 1.0 m: matches the typical "stand 1-1.5 m from a chair / bag /
      // small object" capture distance. iOS Aether3D's original 0.5 m
      // assumed close-up handheld figurines; PocketWorld users tend to
      // shoot floor-level objects at arm's length+, so the smaller
      // value put the world origin in the air in front of (rather than
      // ON) the subject, shrinking the dome's azimuth span.
      final result = await session.lockOrigin(distanceMeters: 1.0);
      if (!mounted) return;
      if (result == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppL10n.of(context).captureLockFailedHint),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      // Lock succeeded; proceed to recording (skip auto-retry loop).
      try {
        await session.start(autoLock: false);
        if (!mounted) return;
        setState(() {
          _isAiming = false;
          _recording = true;
        });
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(AppL10n.of(context).captureRecordingStartFailed('$e')),
          ),
        );
      }
      return;
    }

    // IDLE → enter AIM. Show crosshair, wait for the user to actively
    // aim at the subject and tap again to lock. No auto-anchor.
    // Gated by [_arWarmupComplete] — onTap on the parent button is
    // already null when warmup hasn't completed, but defensively
    // double-check so a programmatic tap can't slip past the gate.
    if (!_arWarmupComplete) return;
    setState(() {
      _isAiming = true;
    });
  }

  /// Persist the just-recorded .mov + curated.json as a DRAFT scan.
  /// No network upload — the user triggers that from the Me page.
  ///
  /// We curate the manifest bytes RIGHT HERE, synchronously, BEFORE
  /// the page pops. `_targetPoints.dispose()` runs in dispose() and
  /// flips `_disposed=true` — a deferred curate would early-return
  /// const [] and throw "no_curated_frames" even though dozens of
  /// points reached ok+ during the take.
  Future<void> _persistDraft() async {
    final video = _session?.videoFile;
    if (video == null) {
      // Concurrent video recording wasn't supported on this device —
      // dome data is good but no .mov to save.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppL10n.of(context).captureCameraConflict),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final Uint8List manifestBytes;
    try {
      // Pull the pose-drift snapshot from the live session BEFORE
      // dispose() drops it. The report is purely diagnostic — server
      // worker logs/aggregates it, no UI surfaces it (dome cell
      // colors already convey real-time AR health).
      final driftReport = _session?.poseDriftReport;
      manifestBytes = CaptureUploader().curateManifestBytes(
        _targetPoints,
        poseDriftReport: driftReport,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    try {
      await UploadCoordinator.instance.persistAsDraft(
        videoFile: File(video.path),
        manifestBytes: manifestBytes,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _warmupTimer?.cancel();
    _poseSub?.cancel();
    _session?.dispose();
    _targetPoints.dispose();
    super.dispose();
  }

  // ─── Layout ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera preview / init / error placeholder.
          Positioned.fill(child: _buildPreviewLayer()),

          // ─── Top bar: just the X close button (right).
          // Tracking dot was previously rendered dead-center here, but
          // it sat right under iOS's Dynamic Island (visually colliding
          // with the system camera-in-use indicator) and the abstract
          // green/red/white color carried no clear meaning to the user.
          // The IdleHintPill + DomeView + bottom button cover the same
          // information already, so this dot was pure noise. Removed.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: SizedBox(
                  height: 38,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _CloseButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
              ),
            ),
          ),


          // ─── Aim mode overlay: center crosshair + hint text.
          // Only rendered while `_isAiming` is true (between idle and
          // recording). User actively aligns the crosshair on the
          // subject and taps the bottom button to lock origin.
          if (_isAiming)
            const Positioned.fill(child: IgnorePointer(child: _AimOverlay())),

          // ─── Idle hint pill — sits just above the bottom button.
          // Shows "正在初始化 AR…" while ARKit is warming up, then
          // switches to "点击中心选择主体物" once the warmup gate opens.
          // Hidden during aim (the crosshair has its own hint) and
          // recording (no idle prompt needed). The pill is purely
          // visual — IgnorePointer so the bottom button still owns
          // taps in this region.
          if (!_isAiming && !_recording && _session != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 200,
              child: IgnorePointer(
                child: Center(
                  child: _IdleHintPill(
                    text: _arWarmupComplete
                        ? AppL10n.of(context).captureReadyHint
                        : AppL10n.of(context).captureWarmupHint,
                  ),
                ),
              ),
            ),

          // ─── Bottom HUD: just the 140×140 dome/shutter, dead-centered.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: Center(
                  child: _CaptureButtonOrDome(
                    recording: _recording,
                    aiming: _isAiming,
                    // Disabled in idle until ARKit has settled (see
                    // [_arWarmupComplete] doc). aim/recording stages
                    // bypass the warmup gate — once we're past idle, the
                    // session is already live and we don't want a
                    // mid-take tracking blip to disable the stop button.
                    enabled: _session != null &&
                        (_recording || _isAiming || _arWarmupComplete),
                    targetPoints: _targetPoints,
                    targetYaw: _yaw,
                    targetPitch: _pitch,
                    isTracking: _isTracking,
                    hasLockedOrigin: _hasLockedOrigin,
                    onTap: _session == null ||
                            (!_recording &&
                                !_isAiming &&
                                !_arWarmupComplete)
                        ? null
                        : _onCenterTap,
                  ),
                ),
              ),
            ),
          ),

        ],
      ),
    );
  }

  Widget _buildPreviewLayer() {
    if (_initializing) {
      return const ColoredBox(
        color: Color(0xFF111113),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
            ),
          ),
        ),
      );
    }
    if (_initError != null) {
      return ColoredBox(
        color: const Color(0xFF111113),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _initError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ),
      );
    }
    // iOS: live ARKit camera feed via UiKitView wrapping ARSCNView
    // attached to the same ARSession the plugin owns. Verbatim port of
    // ObjectModeV2ARKitPreview.swift which uses the same ARSCNView
    // strategy. Other platforms fall back to a dark backdrop until a
    // platform-specific preview is wired (Android ARCore / HarmonyOS).
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return const UiKitView(
        viewType: 'aether_arkit_preview',
        creationParams: <String, dynamic>{},
        creationParamsCodec: StandardMessageCodec(),
      );
    }
    return const ColoredBox(color: Color(0xFF111113));
  }
}

// ─── Top bar widgets ───────────────────────────────────────────────────

class _CloseButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CloseButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.close_rounded,
          size: 17,
          color: Colors.white.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}


// ─── Aim mode overlay ──────────────────────────────────────────────────
//
// Rendered while the user is in aim mode (between idle and recording).
// White center crosshair (open circle, no fill) + small hint text.
// IgnorePointer wrapper at the call site so the bottom record button
// still receives taps; this overlay is purely visual.
class _AimOverlay extends StatelessWidget {
  const _AimOverlay();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Center crosshair: 70×70 white open circle, 2.5px stroke,
        // alpha 0.85. Vertically centered slightly above middle (45%
        // of screen height) so it sits naturally on a desk-level
        // subject framed by a phone held at chest height.
        Align(
          alignment: const Alignment(0, -0.10),
          child: Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.85),
                width: 2.5,
              ),
            ),
            // Tiny center dot (4×4) to mark the exact aim point.
            child: Center(
              child: Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
        // Hint text below the crosshair.
        Align(
          alignment: const Alignment(0, 0.10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              AppL10n.of(context).captureAimHint,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// Small dark pill with white text used as the idle-state hint above the
// bottom shutter button. Same look as the in-aim hint pill so the
// transition idle → aim feels like the text just changes, not the chrome.
class _IdleHintPill extends StatelessWidget {
  final String text;
  const _IdleHintPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.9),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

// ─── Bottom HUD: 140×140 captureButtonOrDome ──────────────────────────

class _CaptureButtonOrDome extends StatelessWidget {
  final bool recording;
  /// True between user's first tap (entering aim mode) and the lock
  /// success that promotes to recording. Renders a checkmark instead
  /// of the white-dot shutter.
  final bool aiming;
  final bool enabled;
  final DomeTargetPoints targetPoints;
  final double targetYaw;
  final double targetPitch;
  final bool isTracking;
  final bool hasLockedOrigin;
  final VoidCallback? onTap;

  const _CaptureButtonOrDome({
    required this.recording,
    required this.aiming,
    required this.enabled,
    required this.targetPoints,
    required this.targetYaw,
    required this.targetPitch,
    required this.isTracking,
    required this.hasLockedOrigin,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ring = SizedBox(
      width: 140,
      height: 140,
      child: CustomPaint(painter: _WhiteRingPainter()),
    );

    if (recording) {
      // Aether3D pattern: dome layer + ring layer + transparent tap layer
      // (avoids hit-test fights between the SCNView and the button).
      return SizedBox(
        width: 140,
        height: 140,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Dome itself doesn't take pointers — the transparent tap
            // overlay above it does.
            IgnorePointer(
              child: ClipOval(
                child: SizedBox(
                  width: 140,
                  height: 140,
                  child: DomeView(
                    targetPoints: targetPoints,
                    targetYaw: targetYaw,
                    targetPitch: targetPitch,
                    trackingFrozen: !isTracking,
                    snapKey: hasLockedOrigin,
                  ),
                ),
              ),
            ),
            IgnorePointer(child: ring),
            GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(width: 140, height: 140),
            ),
          ],
        ),
      );
    }

    // Idle and aim share the same pre-capture chrome (white ring +
    // 119×119 black fill); only the central indicator differs:
    //   • idle: 28×28 white dot (the classic shutter)
    //   • aim:  white check icon — "tap to lock and start"
    final Widget centerIndicator = aiming
        ? const Icon(
            Icons.check_rounded,
            size: 56,
            color: Colors.white,
          )
        : Container(
            width: 28,
            height: 28,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          );

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: SizedBox(
          width: 140,
          height: 140,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ring,
              Container(
                width: 119,
                height: 119,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  shape: BoxShape.circle,
                ),
              ),
              centerIndicator,
            ],
          ),
        ),
      ),
    );
  }
}

class _WhiteRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.white;
    final r = (size.shortestSide - 4) / 2;
    canvas.drawCircle(size.center(Offset.zero), r, paint);
  }

  @override
  bool shouldRepaint(covariant _WhiteRingPainter oldDelegate) => false;
}

