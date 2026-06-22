// PoseDriftTracker — Tier 1 pose-drift health aggregation across a
// capture session.
//
// Why this exists:
//   ARKit (and ARCore, when its plugin lands) reports a per-frame
//   `trackingState` enum. When the state degrades to .limited(reason)
//   the visual SLAM has lost confidence — frames captured during that
//   window may carry stale pose data, and the worker's downstream
//   reconstruction has no easy way to know after the fact. The hybrid
//   IMU dead-reckoning in CaptureSession papers over the dome's
//   coverage classification, but the underlying truth — "X% of this
//   take ran in degraded tracking, with breakdown by root cause" —
//   is lost.
//
//   This tracker is the cheapest possible diagnostic: just count the
//   transitions and time spent in each trackingState bucket. The
//   resulting [PoseDriftReport] is forwarded into curated.json's
//   session-level health block so the worker can log/diagnose bad
//   scans post-hoc and we can build per-user / per-device dashboards
//   off the data later.
//
// What this is NOT:
//   • NOT a real-time UI widget — dome cell colors already convey AR
//     health to the user; the user-facing rejection of a top-bar
//     indicator was explicit ("不需要设计这些 ui 呀。不稳定小球就不
//     变白呀，AR 跟踪丢失，小球就不变白呀"). This file only produces a
//     post-hoc snapshot, never pushes events at the UI.
//   • NOT IMU-vs-ARKit ground-truth comparison (that is Tier 2, gated
//     by a separate ungated motion-anchor reference).
//   • NOT a re-run of the hybrid pose resolution that
//     CaptureSession._resolveHybridPose already does — the tracker
//     listens to the RAW provider trackingStateName, so the IMU
//     dead-reckoning path is intentionally counted as "limited"
//     because that IS the underlying ARKit reality.
//
// Tier ladder roadmap (for the future reader):
//   Tier 1 (this file): "what fraction of the take had healthy
//     tracking" + "what was the root cause of degradation"
//   Tier 2:             IMU dead-reckoning vs ARKit baseline residual,
//     surfaced as a per-frame drift estimate the worker can weight
//     individual frames against
//   Tier 3:             closed-loop comparison against the worker's
//     server-solved pose (VGGT camera matrices)

import '../dome/ar_pose.dart' show ARPose;

// Diagnostic log switch. When true, every normal↔limited transition
// prints a single line so testers running real-device captures can
// see WHEN tracking dropped without parsing curated.json. The dedupe
// state ensures back-to-back identical events stay quiet.
const bool _kDiagLog = true;

/// Aggregated tracking-state health for a single capture session.
class PoseDriftReport {
  /// Wall-clock duration the tracker observed events across.
  final Duration totalDuration;

  /// Total time the underlying AR runtime reported `"normal"`.
  final Duration timeInNormal;

  /// Total time the runtime was in any `"limited_*"` bucket.
  final Duration timeInLimited;

  /// Total time the runtime reported `"not_available"`. Should be
  /// rare in a real shoot — usually only at session warm-up before
  /// the first ARFrame arrives.
  final Duration timeInNotAvailable;

  /// Number of times the trackingState transitioned `normal → !normal`.
  /// Each transition counts once, regardless of how many limited
  /// reasons fired during the run. A bad scan is usually 1-3
  /// transitions; > 5 means the user was thrashing / device thermally
  /// throttled / scene was textureless and ARKit was bouncing.
  final int transitionsToDegraded;

  /// Wall-clock of the longest contiguous `!= "normal"` window.
  /// Useful to flag scans where ARKit gave up for >10 s (worker can
  /// downweight those frames hard).
  final Duration longestDegradedRun;

  /// Per-bucket breakdown — keys are the raw trackingStateName values
  /// (`"normal"`, `"limited_excessive_motion"`, etc.). Sums to
  /// `totalDuration`. Buckets with zero observed time are omitted.
  final Map<String, Duration> reasonBreakdown;

  const PoseDriftReport({
    required this.totalDuration,
    required this.timeInNormal,
    required this.timeInLimited,
    required this.timeInNotAvailable,
    required this.transitionsToDegraded,
    required this.longestDegradedRun,
    required this.reasonBreakdown,
  });

  /// Empty / zero-state report. Returned by [PoseDriftTracker.snapshot]
  /// when no events have been observed (e.g. immediately after
  /// `reset()` and before the first pose arrives) — keeps the
  /// manifest writer's downstream consumers null-free.
  static const PoseDriftReport empty = PoseDriftReport(
    totalDuration: Duration.zero,
    timeInNormal: Duration.zero,
    timeInLimited: Duration.zero,
    timeInNotAvailable: Duration.zero,
    transitionsToDegraded: 0,
    longestDegradedRun: Duration.zero,
    reasonBreakdown: <String, Duration>{},
  );

  /// Healthy fraction of the session in `[0.0, 1.0]`. Returns `1.0`
  /// when [totalDuration] is zero so an empty report doesn't read as
  /// "0% healthy" on the dashboard.
  double get healthRatio {
    final totalUs = totalDuration.inMicroseconds;
    if (totalUs <= 0) return 1.0;
    return timeInNormal.inMicroseconds / totalUs;
  }

  /// JSON form for embedding in `curated.json`'s session-level
  /// `pose_drift_report` block.
  ///
  /// Field naming uses snake_case + `_sec` suffix on durations to
  /// match the worker-side convention already used by
  /// `pose_source_counts` and friends in CuratedManifest.toJson().
  /// Floating-point seconds (microsecond resolution rounded to 3
  /// decimal places) chosen instead of milliseconds because the
  /// downstream Python worker reads it straight into `float` and the
  /// .000-ms tail isn't load-bearing.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'total_duration_sec': _toSec(totalDuration),
      'time_in_normal_sec': _toSec(timeInNormal),
      'time_in_limited_sec': _toSec(timeInLimited),
      'time_in_not_available_sec': _toSec(timeInNotAvailable),
      'transitions_to_degraded': transitionsToDegraded,
      'longest_degraded_run_sec': _toSec(longestDegradedRun),
      'health_ratio': _round3(healthRatio),
      'reason_breakdown': <String, double>{
        for (final entry in reasonBreakdown.entries)
          entry.key: _toSec(entry.value),
      },
    };
  }

  static double _toSec(Duration d) => _round3(d.inMicroseconds / 1e6);

  /// 3-decimal rounding so the manifest stays human-readable. Matches
  /// the precision other curated.json numerics (sharpness,
  /// quality_score) print at.
  static double _round3(double v) => (v * 1000).roundToDouble() / 1000;
}

/// Single-session tracker. NOT thread-safe — fed from the
/// CaptureSession pose listener which runs on the platform-channel
/// callback queue (effectively serial per-session).
class PoseDriftTracker {
  // The raw native value of the most recent observed pose event.
  // Null until `onPoseEvent` is first called after [reset].
  String? _lastState;

  // Wall-clock of the most recent observed event. Null until first
  // event after [reset]. The first event "starts the clock" — its
  // duration contribution is zero, the second event onwards is what
  // accumulates the bucket times.
  DateTime? _lastEventT;

  // Bucket accumulators in microseconds (Duration arithmetic is
  // marginally cheaper this way, and avoids tiny rounding drift over
  // many small dt's).
  final Map<String, int> _reasonMicros = <String, int>{};
  int _transitionsToDegraded = 0;

  // Currently-running degraded window. `_currentDegradedRunStart` is
  // null when we're in `"normal"`, set at the moment we transitioned
  // out of normal.
  DateTime? _currentDegradedRunStart;
  int _longestDegradedRunMicros = 0;

  /// Clears all aggregated state. Call at the start of each new
  /// capture session so the previous take's stats don't bleed in.
  void reset() {
    _lastState = null;
    _lastEventT = null;
    _reasonMicros.clear();
    _transitionsToDegraded = 0;
    _currentDegradedRunStart = null;
    _longestDegradedRunMicros = 0;
    if (_kDiagLog) {
      // ignore: avoid_print
      print('[PoseDrift] reset — tracker armed for new session');
    }
  }

  /// Consume one observed pose event.
  ///
  /// Pass the RAW native trackingStateName (i.e. the value coming off
  /// `ARPose.trackingStateName`, NOT the post-hybrid resolved one).
  /// Null is treated as `"normal"` — see ARPose.trackingStateName
  /// docstring for why.
  ///
  /// `t` is the wall-clock at which this event was observed; the
  /// tracker uses `t - lastEventT` to attribute time to the bucket
  /// that was active up until this event.
  void onPoseEvent({required String? trackingStateName, required DateTime t}) {
    final state = trackingStateName ?? 'normal';

    final lastT = _lastEventT;
    if (lastT == null) {
      // First event — establishes the baseline. We can't attribute
      // any time to a bucket yet (would have to invent a "session
      // started" wall-clock); accumulators stay at zero, and we
      // record the state for the next event's dt.
      _lastState = state;
      _lastEventT = t;
      if (state != 'normal') {
        // First event already degraded — start a degraded run from
        // this moment. No transition count: we have no `previous ==
        // normal` to compare against, so this isn't a "fall from
        // healthy" — it's "started in a bad state".
        _currentDegradedRunStart = t;
      }
      if (_kDiagLog) {
        // ignore: avoid_print
        print('[PoseDrift] first event: state=$state');
      }
      return;
    }

    // dt = wall-clock between the previous and current event. Clamp
    // negative dt's (shouldn't happen — DateTime.now() is monotonic
    // on iOS — but if a clock jump fired, ignore it rather than
    // poison the accumulators with a negative bucket).
    final dt = t.difference(lastT);
    if (dt.inMicroseconds < 0) {
      _lastState = state;
      _lastEventT = t;
      return;
    }

    // Attribute dt to the *previous* state's bucket. This is the
    // standard "events define interval boundaries" pattern — the
    // bucket for state X gets credit for the time we were in X
    // BEFORE the next observation arrived.
    final prevState = _lastState ?? 'normal';
    _reasonMicros[prevState] =
        (_reasonMicros[prevState] ?? 0) + dt.inMicroseconds;

    // Transition detection. We only count `normal → !normal` because
    // that's the user-experience edge ("tracking was healthy and
    // then degraded"). The reverse direction is recovery, not a
    // problem.
    final wasNormal = prevState == 'normal';
    final isNormal = state == 'normal';
    if (wasNormal && !isNormal) {
      _transitionsToDegraded++;
      _currentDegradedRunStart = t;
      if (_kDiagLog) {
        // ignore: avoid_print
        print('[PoseDrift] DEGRADED: normal → $state '
            '(transition #$_transitionsToDegraded)');
      }
    } else if (!wasNormal && isNormal) {
      // Recovery — close out the current degraded run, update the
      // record holder. Use the wall-clock between the run-start and
      // NOW (not the wall-clock between events) — those are the
      // same since the recovery event IS now.
      final runStart = _currentDegradedRunStart;
      int runMicros = 0;
      if (runStart != null) {
        runMicros = t.difference(runStart).inMicroseconds;
        if (runMicros > _longestDegradedRunMicros) {
          _longestDegradedRunMicros = runMicros;
        }
      }
      _currentDegradedRunStart = null;
      if (_kDiagLog) {
        final runSec = (runMicros / 1e6).toStringAsFixed(2);
        // ignore: avoid_print
        print('[PoseDrift] RECOVERED: $prevState → normal '
            '(degraded for ${runSec}s)');
      }
    } else if (!wasNormal && !isNormal && prevState != state) {
      // limited reason changed mid-degraded-run (e.g.
      // excessive_motion → insufficient_features). Worth logging
      // because the root cause shifted.
      if (_kDiagLog) {
        // ignore: avoid_print
        print('[PoseDrift] limited reason changed: '
            '$prevState → $state (still degraded)');
      }
    }
    // Same-bucket transitions (normal→normal, limited→limited, even
    // limited_excessive_motion→limited_initializing) are not
    // counted as transitions — only normal↔!normal flips matter for
    // the transition count. The reasonBreakdown still gets accurate
    // per-bucket time though.

    _lastState = state;
    _lastEventT = t;
  }

  /// Convenience overload for direct ARPose plumbing.
  void onPose(ARPose pose, {DateTime? at}) {
    onPoseEvent(
      trackingStateName: pose.trackingStateName,
      t: at ?? DateTime.now(),
    );
  }

  /// Materialize the current state as an immutable [PoseDriftReport].
  /// Safe to call mid-session (CaptureSession.poseDriftReport returns
  /// a snapshot of "what's been observed so far", which is what the
  /// manifest writer wants at stop-recording time — the most recent
  /// in-flight bucket gets credit up to the moment of the snapshot
  /// because we close out an implicit "now" interval).
  ///
  /// `at` is exposed primarily for tests (so the wall-clock gap
  /// between the last fed event and the snapshot moment doesn't
  /// silently inflate the trailing bucket); production callers pass
  /// nothing and get `DateTime.now()`.
  PoseDriftReport snapshot({DateTime? at}) {
    if (_lastEventT == null) return PoseDriftReport.empty;

    // Take a working copy of the bucket map so calling snapshot()
    // mid-session doesn't double-count when subsequent onPoseEvent
    // calls also accumulate.
    final reasonMicros = <String, int>{..._reasonMicros};

    // Close out the in-flight bucket: attribute (now - lastEventT) to
    // the most recent state. Without this, snapshot() would always
    // be missing the tail since the last observed event.
    final now = at ?? DateTime.now();
    final tailMicros = now.difference(_lastEventT!).inMicroseconds;
    if (tailMicros > 0) {
      final tailState = _lastState ?? 'normal';
      reasonMicros[tailState] =
          (reasonMicros[tailState] ?? 0) + tailMicros;
    }

    var totalMicros = 0;
    var normalMicros = 0;
    var limitedMicros = 0;
    var notAvailableMicros = 0;
    for (final entry in reasonMicros.entries) {
      totalMicros += entry.value;
      if (entry.key == 'normal') {
        normalMicros += entry.value;
      } else if (entry.key == 'not_available') {
        notAvailableMicros += entry.value;
      } else {
        // Anything starting with `limited_` (or an unexpected new
        // bucket from a future SDK we don't recognise yet) — count
        // as "limited" so the headline split stays sensible.
        limitedMicros += entry.value;
      }
    }

    // Close out any in-flight degraded run for the longest-run check.
    var longestRunMicros = _longestDegradedRunMicros;
    final inflightRunStart = _currentDegradedRunStart;
    if (inflightRunStart != null) {
      final inflightMicros =
          now.difference(inflightRunStart).inMicroseconds;
      if (inflightMicros > longestRunMicros) longestRunMicros = inflightMicros;
    }

    return PoseDriftReport(
      totalDuration: Duration(microseconds: totalMicros),
      timeInNormal: Duration(microseconds: normalMicros),
      timeInLimited: Duration(microseconds: limitedMicros),
      timeInNotAvailable: Duration(microseconds: notAvailableMicros),
      transitionsToDegraded: _transitionsToDegraded,
      longestDegradedRun: Duration(microseconds: longestRunMicros),
      reasonBreakdown: <String, Duration>{
        for (final entry in reasonMicros.entries)
          entry.key: Duration(microseconds: entry.value),
      },
    );
  }
}
