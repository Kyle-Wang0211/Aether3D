// Unit tests for PoseDriftTracker — Tier 1 pose-drift health
// aggregation. Pure-Dart, no Flutter binding needed.

import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/capture/pose_drift_tracker.dart';

void main() {
  group('PoseDriftTracker', () {
    test('empty tracker returns empty report with healthRatio = 1.0', () {
      final tracker = PoseDriftTracker();
      final report = tracker.snapshot();
      expect(report.totalDuration, Duration.zero);
      expect(report.transitionsToDegraded, 0);
      expect(report.healthRatio, 1.0);
      expect(report.reasonBreakdown, isEmpty);
    });

    test(
        'normal→limited→normal→limited→normal '
        'over 10 s gives correct ratio + 2 transitions', () {
      final tracker = PoseDriftTracker();

      // Use a fake monotonic baseline so test is deterministic.
      final t0 = DateTime.utc(2026, 5, 11, 0, 0, 0);

      // 0 s: normal (baseline)
      // 3 s: limited_excessive_motion (1st degrade)
      // 5 s: normal               (recovery)
      // 7 s: limited_insufficient_features (2nd degrade)
      // 9 s: normal               (recovery)
      // Stop snapshot at "10 s" — but snapshot uses DateTime.now()
      // for the tail, so we'll snapshot right at the 9 s event with
      // an "elapsed since last event = 0" guarantee by feeding a
      // final 10 s normal event right before snapshot.
      tracker.onPoseEvent(
          trackingStateName: 'normal', t: t0);
      tracker.onPoseEvent(
          trackingStateName: 'limited_excessive_motion',
          t: t0.add(const Duration(seconds: 3)));
      tracker.onPoseEvent(
          trackingStateName: 'normal',
          t: t0.add(const Duration(seconds: 5)));
      tracker.onPoseEvent(
          trackingStateName: 'limited_insufficient_features',
          t: t0.add(const Duration(seconds: 7)));
      tracker.onPoseEvent(
          trackingStateName: 'normal',
          t: t0.add(const Duration(seconds: 9)));
      // Final tick to give the trailing "normal" bucket a full
      // second of credit before snapshot. Without this, snapshot
      // would credit (now - 9s_event_t) ≈ wall-clock-elapsed micros
      // to the trailing bucket, which makes the test non-deterministic.
      tracker.onPoseEvent(
          trackingStateName: 'normal',
          t: t0.add(const Duration(seconds: 10)));

      // Deterministic "now" — without `at:` the snapshot would credit
      // (DateTime.now() - 2026-05-11 baseline) seconds to the
      // trailing bucket, swamping the test signal.
      final report = tracker.snapshot(at: t0.add(const Duration(seconds: 10)));

      // The buckets per the design — the "current" state's time is
      // attributed when the NEXT event arrives. So:
      //   normal:     [0, 3) + [5, 7) + [9, 10) = 6 s
      //   excessive:  [3, 5)                    = 2 s
      //   insuff:     [7, 9)                    = 2 s
      // Plus the snapshot tail (now - 10 s event) gets attributed
      // to "normal" too — which is what we want for the
      // `healthRatio = healthy/total` reading. The tail will be
      // some small wall-clock time depending on how fast the test
      // ran, so we test inequalities rather than exact equality.
      expect(report.transitionsToDegraded, 2);
      expect(report.reasonBreakdown.keys,
          containsAll(<String>[
            'normal',
            'limited_excessive_motion',
            'limited_insufficient_features',
          ]));
      // Bucket times — exact for the closed intervals.
      expect(report.reasonBreakdown['limited_excessive_motion'],
          const Duration(seconds: 2));
      expect(report.reasonBreakdown['limited_insufficient_features'],
          const Duration(seconds: 2));
      // Normal got at least 6 s (the closed [0,3)+[5,7)+[9,10)
      // intervals); the tail can add a few more ms but not seconds.
      expect(report.timeInNormal,
          greaterThanOrEqualTo(const Duration(seconds: 6)));
      expect(report.timeInLimited, const Duration(seconds: 4));
      expect(report.timeInNotAvailable, Duration.zero);
      // Longest degraded run = max(2, 2) = 2 s.
      expect(report.longestDegradedRun, const Duration(seconds: 2));
      // healthRatio: ~6 / ~10 ≈ 0.6 (the tail nudges it slightly
      // higher); definitely between 0.55 and 0.75.
      expect(report.healthRatio, greaterThan(0.55));
      expect(report.healthRatio, lessThan(0.75));
    });

    test('null trackingStateName is treated as "normal"', () {
      final tracker = PoseDriftTracker();
      final t0 = DateTime.utc(2026, 5, 11);
      tracker.onPoseEvent(trackingStateName: null, t: t0);
      tracker.onPoseEvent(
          trackingStateName: null, t: t0.add(const Duration(seconds: 5)));
      final report = tracker.snapshot(at: t0.add(const Duration(seconds: 5)));
      expect(report.transitionsToDegraded, 0);
      expect(report.reasonBreakdown.keys, contains('normal'));
      expect(report.reasonBreakdown.keys,
          isNot(contains('limited_excessive_motion')));
      expect(report.healthRatio, 1.0);
    });

    test('first event already degraded does NOT count as transition', () {
      final tracker = PoseDriftTracker();
      final t0 = DateTime.utc(2026, 5, 11);
      tracker.onPoseEvent(
          trackingStateName: 'limited_initializing', t: t0);
      tracker.onPoseEvent(
          trackingStateName: 'normal',
          t: t0.add(const Duration(seconds: 2)));
      final report = tracker.snapshot(at: t0.add(const Duration(seconds: 2)));
      // No "fall from healthy" — we started already degraded.
      expect(report.transitionsToDegraded, 0);
      expect(report.reasonBreakdown['limited_initializing'],
          const Duration(seconds: 2));
    });

    test('reset clears all state', () {
      final tracker = PoseDriftTracker();
      final t0 = DateTime.utc(2026, 5, 11);
      tracker.onPoseEvent(trackingStateName: 'normal', t: t0);
      tracker.onPoseEvent(
          trackingStateName: 'limited_excessive_motion',
          t: t0.add(const Duration(seconds: 3)));
      tracker.onPoseEvent(
          trackingStateName: 'normal',
          t: t0.add(const Duration(seconds: 5)));
      // Confirm there's something to reset.
      expect(
          tracker
              .snapshot(at: t0.add(const Duration(seconds: 5)))
              .transitionsToDegraded,
          1);

      tracker.reset();
      final report = tracker.snapshot();
      expect(report.transitionsToDegraded, 0);
      expect(report.totalDuration, Duration.zero);
      expect(report.reasonBreakdown, isEmpty);
    });

    test('toJson emits the documented shape', () {
      final tracker = PoseDriftTracker();
      final t0 = DateTime.utc(2026, 5, 11);
      tracker.onPoseEvent(trackingStateName: 'normal', t: t0);
      tracker.onPoseEvent(
          trackingStateName: 'limited_excessive_motion',
          t: t0.add(const Duration(seconds: 3)));
      tracker.onPoseEvent(
          trackingStateName: 'normal',
          t: t0.add(const Duration(seconds: 5)));
      tracker.onPoseEvent(
          trackingStateName: 'normal',
          t: t0.add(const Duration(seconds: 6)));

      final json = tracker
          .snapshot(at: t0.add(const Duration(seconds: 6)))
          .toJson();
      // Required top-level keys.
      expect(
          json.keys,
          containsAll(<String>[
            'total_duration_sec',
            'time_in_normal_sec',
            'time_in_limited_sec',
            'time_in_not_available_sec',
            'transitions_to_degraded',
            'longest_degraded_run_sec',
            'health_ratio',
            'reason_breakdown',
          ]));
      // Number types — durations are floats, transitions are int.
      expect(json['total_duration_sec'], isA<double>());
      expect(json['transitions_to_degraded'], isA<int>());
      expect(json['health_ratio'], isA<double>());
      expect(json['reason_breakdown'], isA<Map<String, dynamic>>());

      // ignore: avoid_print
      print('[PoseDriftTracker test] sample report: $json');
    });
  });
}
