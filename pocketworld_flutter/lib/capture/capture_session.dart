// CaptureSession — composes ARPoseProvider + GuidanceEngine +
// DomeCoverageMap into one start/stop unit driven entirely by the AR
// camera buffer. Single-source-of-truth for capture state.
//
// Why we DON'T use the Flutter `camera` plugin's image stream / video
// recording: ARKit on iOS holds exclusive AVCaptureDevice access while
// ARWorldTrackingConfiguration is running. Trying to run a separate
// AVCaptureSession (which is what `camera.startImageStream` needs)
// produces `FigCaptureSourceRemote err=-17281` (server not responding)
// and the image stream silently dies — diagnosed live from a user's
// Xcode console log, see `[CaptureSession] _onCameraImage tick #1`
// only ever firing once. iOS Aether3D's
// `ObjectModeV2CaptureRecorder` reads everything off ARFrame's
// pixel buffer instead; we mirror that.
//
// Data flow:
//   AR backend (Swift ARSession on iOS / synthetic mock elsewhere)
//      │
//      │  per ARFrame, throttled to 6 Hz, native runs Laplacian +
//      │  brightness + signature on `ARFrame.capturedImage`'s Y
//      │  plane and packs it into the pose event.
//      ▼
//   PlatformARPoseProvider → ARPose with optional `quality` block
//      │
//      ▼
//   CaptureSession.poseStream
//      │
//      ├─ guidance.processVisualSample (UI counter + hint text)
//      └─ targetPoints.ingest (visual = data, 1:1: nearest-point
//                              routing → per-point ring buffer +
//                              5-gate v1 promotion → fires
//                              pointVisitedStream when promoted)
//
// Video recording happens natively (AVAssetWriter on iOS), the .mov
// file path comes back via `stopRecording`.

import 'dart:async';

import 'package:camera/camera.dart' show XFile;
import 'package:flutter/widgets.dart' show Offset;

import '../dome/ar_pose.dart';
import '../dome/platform_pose_provider.dart';
import '../quality/frame_quality_constants.dart';
import '../quality/guidance_engine.dart';
import 'dome/captured_frame_sample.dart';
import 'dome/dome_config.dart';
import 'dome/dome_target_points.dart';
import 'orientation_tracker.dart';
import 'pose_drift_tracker.dart';

class CaptureSession {
  final ARPoseProvider poseProvider;
  final GuidanceEngine guidance;

  /// Sole coverage signal — visual = data, 1:1. Each visible target
  /// point owns its own [RingBufferCell] with v1's strict 5-gate
  /// promotion. Replaced the old [DomeCoverageMap] (60-cell separate
  /// data layer) in v6 — see dome_target_points.dart header.
  final DomeTargetPoints targetPoints;

  /// Where on screen the user is asked to keep the subject. Default is
  /// dead-center because there's no on-screen target box yet.
  final Offset targetZoneAnchor;
  final TargetZoneMode targetZoneMode;

  /// Stream of pose updates the dome view subscribes to.
  Stream<ARPose> get poseStream => _poseCtrl.stream;

  /// Stream of GuidanceEngine snapshots — accepted-frame count, hint
  /// text, orbit-completion fraction.
  Stream<GuidanceSnapshot> get guidanceStream => _guidanceCtrl.stream;

  final StreamController<ARPose> _poseCtrl =
      StreamController<ARPose>.broadcast();
  final StreamController<GuidanceSnapshot> _guidanceCtrl =
      StreamController<GuidanceSnapshot>.broadcast();
  StreamSubscription<ARPose>? _poseSub;

  ARPose? _lastPose;

  /// True once `lockOrigin()` has succeeded.
  bool get hasLockedOrigin => _lastPose?.hasOrigin ?? false;

  // Monotonic clock starting from each `start()` so ring-buffer
  // timeSpread checks (excellentMinTimeSpreadSec) work consistently.
  final Stopwatch _clock = Stopwatch();
  int _frameSeq = 0;
  bool _attached = false;
  bool _started = false;
  bool _disposed = false;
  bool _loggedFirstPose = false;
  bool _loggedFirstHasOrigin = false;
  bool _loggedFirstQuality = false;

  // ── Hybrid ARKit + IMU pose state ────────────────────────────────────
  //
  // Why this exists: ARKit's visual SLAM falls into `.limited(...)` in
  // low-texture / thermal-throttled environments (wood floors, paper
  // bags, hot device). The original capture path treated `isTracking
  // == false` as "skip this frame" (CaptureSession._onPoseTick had
  // `if (!pose.isTracking) return`), which means a long limited window
  // produced ZERO ingested frames — user's "走一圈只点亮 6/118 个点"
  // bug was almost entirely this. The fix:
  //
  //   • Run an OrientationTracker (Madgwick AHRS over phone IMU) in
  //     parallel with ARKit, always-on while attached.
  //   • While ARKit is .normal, record the offset between ARKit's
  //     position-based azimuth/elevation and IMU's yaw/pitch.
  //   • While ARKit is .limited, dead-reckon az/el from IMU + offset.
  //
  // This is correct enough for the dome's coverage classification
  // (which only needs to bin frames into 11×variable rings) — IMU
  // drift over a 30-60 s scan is well under the bin width. It is NOT
  // good enough for reconstruction — but server-side VGGT solves pose
  // from images directly (see arxiv 2503.11651, model.forward(images)
  // takes no pose input), so the manifest ARKit pose was always
  // metadata-only. Each curated frame carries `pose_source` so the
  // server can log the IMU-vs-ARKit ratio.
  final OrientationTracker _orientation = OrientationTracker();
  bool _orientationStarted = false;

  // ── Tier 1 pose-drift health aggregator ──────────────────────────────
  //
  // Listens to the RAW provider trackingStateName (NOT the post-hybrid
  // resolved pose), counts time per bucket + transitions. Snapshot is
  // pulled at stop time and embedded in curated.json so the worker
  // can log/diagnose bad scans post-hoc. Purely diagnostic — no UI
  // surface (dome cell colors already convey real-time AR health).
  final PoseDriftTracker _driftTracker = PoseDriftTracker();
  /// `true` once we've ever seen ARKit `.normal` after the world origin
  /// was locked. Until then the IMU-vs-ARKit offset is undefined and we
  /// fall back to the legacy "skip frame" behaviour rather than
  /// dead-reckon from a meaningless anchor.
  bool _hybridAnchored = false;
  double _arkitImuOffsetAz = 0;
  double _arkitImuOffsetEl = 0;
  /// Last pose's source after hybrid resolution. Sampled into each
  /// CapturedFrameSample so the curator can split the manifest into
  /// arkit-pose vs imu-pose buckets.
  String _lastPoseSource = 'arkit';
  // Diagnostics
  int _diagArkitPoses = 0;
  int _diagImuPoses = 0;

  // ── IMU→ARKit transition delta-compensation ramp ─────────────────────
  //
  // The first hybrid implementation hard-switched az/el back to the raw
  // ARKit value the moment ARKit returned to .normal. That produced a
  // visible jump on the dome whenever the IMU dead-reckoning had drifted
  // off the ARKit ground truth (which is the common case — IMU is meant
  // to be a coarser substitute, not a perfect tracker). User feedback
  // was unambiguous: "球的角度完全不能发生变化".
  //
  // Continuity proof for the ARKit→IMU direction (no ramp needed):
  //   t=k:   displayed = arkit.az_old
  //          offset    = arkit.az_old - imu.yaw_old           (just refreshed)
  //   t=k+1: tracking dropped → estimated = imu.yaw_new + offset
  //                            = imu.yaw_new + arkit.az_old - imu.yaw_old
  //                            = arkit.az_old + Δimu.yaw  (~0 over 30 ms)
  //          ≈ arkit.az_old → continuous ✓
  //
  // The IMU→ARKit direction is where the jump is. Fix:
  //   • At the moment ARKit recovers, compute
  //         Δ = arkit.az_real − imu_estimated_az_last
  //         (this is the gap that would have caused the jump)
  //   • For the next 600 ms output
  //         az = arkit.az_real − Δ × (1 − t)
  //     where t ramps from 0 (equal to imu_estimated, i.e. the displayed
  //     value at t=k) to 1 (full ARKit). Smooth Hermite t² ⋅ (3 − 2t)
  //     instead of linear so the start and end have zero derivative —
  //     keeps even the rate-of-change continuous.
  //
  // Same logic mirrored for elevation.
  static const Duration _imuToArkitRampDuration = Duration(milliseconds: 600);
  double _switchDeltaAz = 0;
  double _switchDeltaEl = 0;
  DateTime? _switchTransitionStart;

  /// Read-only access to the live audit summary the GuidanceEngine
  /// keeps. Uploaded with the curated manifest at stop time.
  GuidanceAuditSummary get auditSummary => guidance.auditSummary;

  /// Snapshot of pose-drift health since the most recent
  /// [start]/[reset]. Embedded in curated.json so the worker can
  /// diagnose bad scans post-hoc. Safe to call at any time;
  /// [PoseDriftTracker.snapshot] internally closes out the in-flight
  /// bucket so a mid-session call returns "what's been observed so
  /// far". The capture page calls this right before persisting the
  /// manifest at stop-recording.
  PoseDriftReport get poseDriftReport => _driftTracker.snapshot();

  /// Last recorded video. Populated after `stop()` if the native side
  /// (AetherARKitPlugin's AVAssetWriter pipeline) successfully wrote
  /// an .mov file. Null when running on the mock provider or when
  /// recording failed.
  XFile? get videoFile => _videoFile;
  XFile? _videoFile;

  CaptureSession({
    ARPoseProvider? poseProvider,
    GuidanceEngine? guidance,
    DomeTargetPoints? targetPoints,
    DomePointConfig pointConfig = DomePointConfig.defaults,
    this.targetZoneAnchor = const Offset(0.5, 0.5),
    this.targetZoneMode = TargetZoneMode.subject,
  })  : poseProvider = poseProvider ?? PlatformARPoseProvider(),
        guidance = guidance ?? GuidanceEngine(),
        targetPoints =
            targetPoints ?? DomeTargetPoints(config: pointConfig) {
    this.guidance.onUpdate = (snap) {
      if (!_guidanceCtrl.isClosed) _guidanceCtrl.add(snap);
    };
  }

  bool get isRunning => _started;
  bool get isAttached => _attached;

  /// Pre-warm the AR session: start the platform pose provider so
  /// ARKit's tracking can settle into `.normal` while the user frames
  /// the subject. Does NOT begin recording — `_onPoseTick` ignores
  /// events until `start()` flips `_started = true`. Idempotent.
  ///
  /// Why this is split from `start()`: lockOrigin needs `tracking ==
  /// .normal` to succeed. If we cold-start ARKit on Record tap, the
  /// retry loop fires lockOrigin during the warm-up window — the user
  /// was visibly moving the phone while ARKit raced to `.normal`,
  /// so the captured worldYaw was meaningless. Pre-warming on page
  /// open lets tracking stabilize so the lock baseline reflects the
  /// pose the user actually wanted to anchor to.
  Future<void> attach() async {
    if (_disposed) {
      throw StateError('CaptureSession used after dispose');
    }
    if (_attached) return;
    _attached = true;

    // Start the IMU stream alongside ARKit. OrientationTracker is safe
    // to start even when sensor APIs aren't available (sensors_plus
    // streams just stay silent on simulator/web) — `current.yaw/pitch`
    // will sit at 0 and the hybrid path will degrade to the legacy
    // "skip ARKit-limited frames" behaviour.
    if (!_orientationStarted) {
      _orientation.start();
      _orientationStarted = true;
    }

    _poseSub = poseProvider.start().listen((rawPose) {
      // Feed the RAW pose to the drift tracker BEFORE hybrid
      // resolution. The drift tracker wants the underlying ARKit
      // truth (limited_excessive_motion, etc.), not the hybrid
      // resolver's "I forced isTracking back to true" output —
      // otherwise the diagnostic would always read "100% healthy"
      // because IMU dead-reckoning paints over the underlying issue.
      // Only feed events while a recording is active; the warm-up
      // period before `start()` doesn't count toward session health.
      if (_started) {
        _driftTracker.onPose(rawPose);
      }

      if (!_loggedFirstPose) {
        _loggedFirstPose = true;
        // ignore: avoid_print
        print(
          '[CaptureSession] first ARPose received '
          '(isTracking=${rawPose.isTracking}, '
          'hasOrigin=${rawPose.hasOrigin})',
        );
      }
      if (!_loggedFirstHasOrigin && rawPose.hasOrigin) {
        _loggedFirstHasOrigin = true;
        // ignore: avoid_print
        print(
          '[CaptureSession] first ARPose with hasOrigin=true — '
          'dome ingest path now active',
        );
      }
      if (!_loggedFirstQuality && rawPose.quality != null) {
        _loggedFirstQuality = true;
        // ignore: avoid_print
        print(
          '[CaptureSession] first quality block received '
          '(sharp=${rawPose.quality!.sharpness.toStringAsFixed(0)}, '
          'brightness=${rawPose.quality!.meanBrightness.toStringAsFixed(0)})',
        );
      }

      // Resolve hybrid pose. Subscribers (dome view, ingest pipeline)
      // see the resolved pose, never the raw ARPose. The raw pose can
      // still be inspected via `lastRawArkitPose` if a future caller
      // wants to surface "ARKit is limited" specifically.
      final p = _resolveHybridPose(rawPose);
      _lastPose = p;
      if (!_poseCtrl.isClosed) _poseCtrl.add(p);
      _onPoseTick(p);
    });
  }

  /// Hybrid pose resolution. Returns either:
  ///   • [raw] verbatim — ARKit `.normal`, or pre-lock, or
  ///     post-lock-but-pre-anchor ARKit limited (no IMU offset to apply
  ///     yet, so we leave isTracking=false and the legacy gate skips).
  ///   • A copy with IMU-derived az/el and isTracking=true — ARKit was
  ///     `.limited(...)` but we have a recent ARKit-normal anchor for
  ///     the offset.
  ///
  /// Side effects: refreshes `_arkitImuOffsetAz/El` whenever ARKit is
  /// healthy, and updates `_lastPoseSource` for ingest tagging.
  ARPose _resolveHybridPose(ARPose raw) {
    if (!raw.hasOrigin) {
      // Pre-lock: there's no world frame to compare against; the dome
      // ingest pipeline already filters on hasOrigin so the source tag
      // doesn't matter.
      _lastPoseSource = 'arkit';
      return raw;
    }

    if (raw.isTracking) {
      // ARKit healthy.
      final imu = _orientation.current;

      // ── Detect IMU→ARKit transition; arm the delta-compensation ramp
      // BEFORE refreshing offset, so the "imu_estimated_az_last" we
      // compute uses the offset that produced the previous frame's
      // displayed value (continuity at t=k vs t=k+1).
      if (_lastPoseSource == 'imu' && _hybridAnchored) {
        final imuEstimatedAz = imu.yaw + _arkitImuOffsetAz;
        final imuEstimatedEl = imu.pitch + _arkitImuOffsetEl;
        _switchDeltaAz = raw.azimuth - imuEstimatedAz;
        _switchDeltaEl = raw.elevation - imuEstimatedEl;
        _switchTransitionStart = DateTime.now();
        // ignore: avoid_print
        print(
          '[CaptureSession] IMU→ARKit transition: '
          'Δaz=${_switchDeltaAz.toStringAsFixed(3)} '
          'Δel=${_switchDeltaEl.toStringAsFixed(3)} — '
          'will ramp over ${_imuToArkitRampDuration.inMilliseconds}ms',
        );
      }

      // Refresh offset (always do this in steady-state ARKit; future
      // ARKit→IMU transitions need the most recent offset).
      _arkitImuOffsetAz = raw.azimuth - imu.yaw;
      _arkitImuOffsetEl = raw.elevation - imu.pitch;
      if (!_hybridAnchored) {
        _hybridAnchored = true;
        // ignore: avoid_print
        print(
          '[CaptureSession] hybrid anchor established — '
          'IMU dead-reckoning ready as fallback '
          '(arkit.az=${raw.azimuth.toStringAsFixed(2)} '
          'imu.yaw=${imu.yaw.toStringAsFixed(2)})',
        );
      }
      _lastPoseSource = 'arkit';
      _diagArkitPoses++;

      // ── Apply delta-compensation ramp if we're in the post-transition
      // window. Smoothstep (Hermite) interpolation t² × (3 − 2t) so the
      // velocity at t=0 and t=1 is zero — no derivative discontinuity.
      if (_switchTransitionStart != null) {
        final elapsedMs =
            DateTime.now().difference(_switchTransitionStart!).inMilliseconds;
        final tLin =
            (elapsedMs / _imuToArkitRampDuration.inMilliseconds)
                .clamp(0.0, 1.0);
        if (tLin >= 1.0) {
          // Ramp complete — snap to direct ARKit values for the rest of
          // this normal window.
          _switchTransitionStart = null;
          _switchDeltaAz = 0;
          _switchDeltaEl = 0;
          return raw;
        }
        final t = tLin * tLin * (3.0 - 2.0 * tLin); // smoothstep
        final adjAz = raw.azimuth - _switchDeltaAz * (1.0 - t);
        final adjEl = raw.elevation - _switchDeltaEl * (1.0 - t);
        return raw.copyWith(azimuth: adjAz, elevation: adjEl);
      }

      return raw;
    }

    // ARKit .limited(...) — substitute IMU dead-reckoning if anchored.
    if (_hybridAnchored) {
      // If we were mid-ramp from a previous IMU→ARKit transition and
      // ARKit drops again immediately, abandon the ramp — use the
      // current (possibly stale) offset for continuity rather than
      // bouncing back to a half-rampped value.
      _switchTransitionStart = null;
      _switchDeltaAz = 0;
      _switchDeltaEl = 0;

      final imu = _orientation.current;
      _lastPoseSource = 'imu';
      _diagImuPoses++;
      return raw.copyWith(
        azimuth: imu.yaw + _arkitImuOffsetAz,
        elevation: imu.pitch + _arkitImuOffsetEl,
        // Flip back to "tracking" so downstream consumers (dome view,
        // ingest pipeline) treat the IMU pose as usable. The raw value
        // is preserved on the underlying provider for callers that
        // really want to know ARKit is unhappy.
        isTracking: true,
      );
    }

    // Post-lock, ARKit limited, no IMU anchor yet — pass through with
    // isTracking=false. _onPoseTick still has its legacy gate to skip.
    _lastPoseSource = 'arkit';
    return raw;
  }

  /// Begin a new capture. Resets target points + clock and kicks off
  /// the native video recording.
  ///
  /// **autoLock**:
  ///   - `true` (default, legacy behavior): also kicks off the
  ///     `_lockOriginWhenReady` retry loop. Used when the caller wants
  ///     "tap record → everything happens automatically".
  ///   - `false` (v6+ aim-then-lock UX): caller is responsible for
  ///     invoking [lockOrigin] explicitly (typically when the user
  ///     taps a "lock" button after aiming the crosshair). Without
  ///     this, target points never see any frame with `hasOrigin`.
  Future<void> start({bool autoLock = true}) async {
    if (_disposed) {
      throw StateError('CaptureSession used after dispose');
    }
    if (_started) return;
    if (!_attached) await attach();

    targetPoints.reset();
    guidance.beginRecording();
    _driftTracker.reset();
    _frameSeq = 0;
    _videoFile = null;
    _diagArkitPoses = 0;
    _diagImuPoses = 0;
    // Clear hybrid anchor: a new recording means a new world origin
    // is about to be locked, so any IMU↔ARKit offset learned from
    // the previous session is stale.
    _hybridAnchored = false;
    _arkitImuOffsetAz = 0;
    _arkitImuOffsetEl = 0;
    _orientation.resetOrigin();
    _clock
      ..reset()
      ..start();

    _started = true;

    if (autoLock) {
      unawaited(_lockOriginWhenReady(distanceMeters: 1.0));
    }
    unawaited(_safeStartRecording());
  }

  Future<void> _safeStartRecording() async {
    try {
      await poseProvider.startRecording();
      // ignore: avoid_print
      print('[CaptureSession] recording started');
    } catch (e) {
      // ignore: avoid_print
      print('[CaptureSession] recording start failed: $e');
    }
  }

  /// Place the world origin in front of the camera and capture
  /// worldYaw. Default 1.0 m matches the typical "stand 1-1.5 m from
  /// the subject" capture posture (chair, paper bag, figurine on a
  /// desk). iOS Aether3D's original 0.5 m was tuned for close-up
  /// handheld figurines; with the wider 1.0 m default + Swift-side
  /// raycast distance cap (1.5 m) the world origin ends up on the
  /// subject for the typical PocketWorld shoot.
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) {
    return poseProvider.lockOrigin(distanceMeters: distanceMeters);
  }

  Future<void> _lockOriginWhenReady({required double distanceMeters}) async {
    // Keep retrying as long as recording is active and we haven't locked
    // yet. The previous 50-attempt (5 s) cap was a bug: in low-texture
    // scenes (transparent / reflective subjects, smooth desks) ARKit
    // takes >5 s to leave `.limited(initializing)`, and once we gave up,
    // recording continued forever with `hasOrigin=false` — no coverage
    // ingest, no dome rotation, blank dark grid for the rest of the take.
    // Now we wait for ARKit to be ready however long that takes; the
    // user's stop-recording tap is the actual upper bound.
    int attempts = 0;
    while (_started) {
      attempts++;
      final result = await poseProvider.lockOrigin(
        distanceMeters: distanceMeters,
      );
      if (result != null) {
        // ignore: avoid_print
        print(
          '[CaptureSession] lockOrigin SUCCESS on attempt $attempts '
          '(worldYaw=${result.worldYaw.toStringAsFixed(3)})',
        );
        return;
      }
      // Progress log at 1 s, 5 s, then once per 5 s — so the user (and
      // we, reading the trace) can see the loop is still alive without
      // spamming the console at 10 Hz.
      if (attempts == 10 || attempts == 50 || attempts % 50 == 0) {
        // ignore: avoid_print
        print(
          '[CaptureSession] lockOrigin still pending after $attempts '
          'attempts (${attempts * 100} ms) — ARKit tracking not yet '
          '.normal; will keep retrying',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // Loop only exits when `_started` flips false — i.e., the user
    // stopped recording before ARKit ever stabilised.
    // ignore: avoid_print
    print(
      '[CaptureSession] lockOrigin abandoned: recording stopped after '
      '$attempts attempts before ARKit reached .normal tracking',
    );
  }

  /// End the recording window. Keeps the pose provider running so the
  /// user can tap Record again without paying ARKit's warm-up cost.
  /// Tear-down of the AR session happens in `dispose()` when the
  /// capture page is destroyed.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _clock.stop();
    guidance.endRecording();
    final imuRatio = (_diagArkitPoses + _diagImuPoses) == 0
        ? 0.0
        : _diagImuPoses / (_diagArkitPoses + _diagImuPoses);
    // ignore: avoid_print
    print(
      '[CaptureSession] hybrid pose stats this take: '
      'arkit=$_diagArkitPoses imu=$_diagImuPoses '
      '(${(imuRatio * 100).toStringAsFixed(1)}% IMU dead-reckoned)',
    );
    final clip = await poseProvider.stopRecording();
    if (clip != null) {
      _videoFile = XFile(clip.filePath);
      // ignore: avoid_print
      print(
        '[CaptureSession] recording stopped: ${clip.filePath} '
        '(${clip.durationSeconds.toStringAsFixed(1)}s, '
        '${clip.fileSizeBytes} bytes)',
      );
    } else {
      // ignore: avoid_print
      print('[CaptureSession] recording stopped: no clip produced');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_started) {
      _started = false;
      _clock.stop();
      guidance.endRecording();
    }
    await _poseSub?.cancel();
    _poseSub = null;
    if (_attached) {
      _attached = false;
      await poseProvider.stop();
    }
    if (_orientationStarted) {
      _orientation.dispose();
      _orientationStarted = false;
    }
    if (!_poseCtrl.isClosed) await _poseCtrl.close();
    if (!_guidanceCtrl.isClosed) await _guidanceCtrl.close();
  }

  // ─── Per-pose ingest ────────────────────────────────────────────────

  /// Drive GuidanceEngine + DomeCoverageMap from each pose event that
  /// carries a quality block. Native side throttles those to 6 Hz so
  /// we get exactly one ingest per ~167 ms — same as iOS's
  /// `visualSampleInterval`.
  void _onPoseTick(ARPose pose) {
    if (!_started) return;
    final report = pose.quality;
    if (report == null) return; // throttled-out frame, no quality data
    if (!pose.hasOrigin) return;
    // NOTE: we do NOT bail on `!pose.isTracking` anymore. The hybrid
    // resolver in attach() flips isTracking back to true whenever IMU
    // dead-reckoning is anchored, so the only `isTracking=false` that
    // reaches us here is the post-lock-but-pre-anchor window where
    // ARKit is .limited AND we don't have a valid IMU offset yet — in
    // which case az/el are stale and we should still skip.
    if (!pose.isTracking) return;

    final t = _clock.elapsedMicroseconds / 1e6;

    // GuidanceEngine — verbatim port of iOS Aether3D's multi-dim audit
    // (blur / dark / bright / occupancy / redundant / low-texture /
    // weak-quality / dynamic acceptance threshold / dark-adaptive
    // sharpness floor / 0.28 s throttle / first-frame special case).
    // Snapshot the acceptance count before/after so we can detect
    // "this exact frame was accepted" → use it to gate target_points.
    final beforeAccepted = guidance.snapshot.acceptedFrames;
    guidance.processVisualSample(
      VisualFrameSample(
        timestamp: t,
        signatureWidth: report.signatureWidth,
        signatureHeight: report.signatureHeight,
        signature: report.signature,
        laplacianVariance: report.sharpness,
        meanBrightness: report.meanBrightness,
        globalVariance: report.globalVariance,
      ),
      targetZoneAnchor: targetZoneAnchor,
      targetZoneMode: targetZoneMode,
    );
    final wasAccepted =
        guidance.snapshot.acceptedFrames > beforeAccepted;

    // TargetPoints — visual = data, 1:1. Ingest routes the frame to
    // the nearest target point; that point's own ring buffer +
    // 5-gate promotion will fire `pointVisitedStream` when the point
    // newly transitions to ok. `wasAccepted` is logged for diagnostic
    // (it's GuidanceEngine's verdict on whether this frame was
    // "accepted"; target_points uses its own simpler sharpness floor
    // so the two can disagree — a frame may be guidance-rejected but
    // sharp enough to be ingested into a buffer).
    _frameSeq++;
    if (_frameSeq == 1 || _frameSeq % 6 == 0) {
      // ignore: avoid_print
      print(
        '[CaptureSession] targetPoints.ingest #$_frameSeq '
        'az=${pose.azimuth.toStringAsFixed(2)} '
        'el=${pose.elevation.toStringAsFixed(2)} '
        'sharp=${report.sharpness.toStringAsFixed(0)} '
        'src=$_lastPoseSource '
        'accepted=$wasAccepted',
      );
    }
    // motionScore: when ARKit is reporting we use the legacy default
    // (no IMU read on the ARKit path of iOS Aether3D either); when we're
    // dead-reckoning from IMU, the OrientationTracker has the gyro RMS
    // already computed and that's a strictly better signal — surface it
    // so the coverage map's motion-stability gate sees real data.
    final motionScore = _lastPoseSource == 'imu'
        ? _orientation.current.motionScore
        : 0.2;
    // ARKit extrinsic/intrinsic are meaningless when the pose source is
    // IMU-only (camera→world matrix would be from a frame ARKit had
    // already abandoned). Drop them so the manifest doesn't ship stale
    // pose data tagged as ARKit ground truth.
    final extrinsic = _lastPoseSource == 'arkit' && pose.extrinsic4x4.isNotEmpty
        ? pose.extrinsic4x4
        : null;
    final intrinsic = _lastPoseSource == 'arkit' &&
            pose.intrinsicFxFyCxCy.isNotEmpty
        ? pose.intrinsicFxFyCxCy
        : null;
    targetPoints.ingest(CapturedFrameSample(
      timestamp: t,
      azimuth: pose.azimuth,
      elevation: pose.elevation,
      sharpness: report.sharpness,
      motionScore: motionScore,
      // Forward physical-units gyro magnitude so the dome ingest gate
      // can hard-reject frames captured during > 2 rad/s hand wobble
      // (Aether3D iOS angularVelocityLimit). _orientation always has
      // an EMA-smoothed value once IMU events have started flowing;
      // before then, the default 0.0 in CapturedFrameSample passes.
      angularVelocityRadPerSec: _orientation.angularVelocityRadPerSec,
      // Mean luma 0..255. Same value `report.meanBrightness` carries to
      // logging — exposing it on the sample lets the dome ingest gate
      // hard-reject too-dark / blown-out frames (Aether3D iOS thresholds
      // 60 / 200) before they ever enter a cell buffer.
      meanBrightness: report.meanBrightness,
      exposureScore: 0.95,
      frameId: 'cap-$_frameSeq',
      cameraExtrinsic4x4: extrinsic,
      cameraIntrinsicFxFyCxCy: intrinsic,
      poseSource: _lastPoseSource,
    ));
  }
}
