// Dart port of App/ObjectModeV2/ObjectModeV2CoverageMap.swift (partial).
//
// Bins the camera's (azimuth, elevation) direction into a 2D grid and
// tracks how thoroughly the user has circled the object. Dome UI reads
// this to color each sphere wedge (green = captured, gray = uncaptured).
//
// Grid resolution:
//   • azimuth: 24 bins (15° wide)     — full 2π sweep
//   • elevation: 9 bins (20° wide)    — -90°..+90°
//   These match the original Swift prototype's wedge count so the visual
//   density reads the same.

import 'dart:math' as math;

class CoverageMap {
  static const int azimuthBins = 24;
  static const int elevationBins = 9;

  /// 2D bin grid — index = elevation * azimuthBins + azimuth.
  /// Value semantics: 0 = not captured, >0 = hit count.
  final List<int> _bins =
      List<int>.filled(azimuthBins * elevationBins, 0, growable: false);

  /// Total count of accepted frames that contributed to the map.
  int _totalHits = 0;

  int get totalHits => _totalHits;

  /// Report that a frame was accepted at the given spherical direction.
  /// Caller is responsible for filtering (e.g. GuidanceEngine should
  /// only call this on frames that passed hard-reject filters).
  void registerHit(double azimuthRadians, double elevationRadians) {
    final idx = _binIndex(azimuthRadians, elevationRadians);
    _bins[idx] += 1;
    _totalHits += 1;
  }

  /// Returns the hit count for the bin covering (az, el). 0 means the
  /// user hasn't captured from that direction yet.
  int hitCount(double azimuthRadians, double elevationRadians) {
    return _bins[_binIndex(azimuthRadians, elevationRadians)];
  }

  /// Raw read-only access for the dome renderer to paint each wedge.
  /// `out[eIndex * azimuthBins + aIndex]` = hit count.
  List<int> get rawBins => List<int>.unmodifiable(_bins);

  /// Fraction of bins with at least one hit. 0..1. Drives the
  /// orbit-completion progress bar.
  double get completionFraction {
    if (_bins.isEmpty) return 0;
    int hit = 0;
    for (final b in _bins) {
      if (b > 0) hit += 1;
    }
    return hit / _bins.length;
  }

  /// Identify the first unvisited bin closest to current direction.
  /// Returns null if every bin has at least one hit.
  (double az, double el)? nearestUnvisited({
    required double currentAzimuth,
    required double currentElevation,
  }) {
    double bestDist = double.infinity;
    int bestIdx = -1;
    for (int e = 0; e < elevationBins; e++) {
      for (int a = 0; a < azimuthBins; a++) {
        final idx = e * azimuthBins + a;
        if (_bins[idx] > 0) continue;
        final (az, el) = _binCenter(a, e);
        final dAz = _shortestAngle(az - currentAzimuth);
        final dEl = el - currentElevation;
        final d = math.sqrt(dAz * dAz + dEl * dEl);
        if (d < bestDist) {
          bestDist = d;
          bestIdx = idx;
        }
      }
    }
    if (bestIdx < 0) return null;
    final e = bestIdx ~/ azimuthBins;
    final a = bestIdx % azimuthBins;
    return _binCenter(a, e);
  }

  void reset() {
    for (int i = 0; i < _bins.length; i++) {
      _bins[i] = 0;
    }
    _totalHits = 0;
  }

  // ─── Helpers ────────────────────────────────────────────────────

  int _binIndex(double az, double el) {
    // Normalize azimuth to [0, 2π).
    final twoPi = 2 * math.pi;
    double na = az % twoPi;
    if (na < 0) na += twoPi;
    // Clamp elevation to [-π/2, π/2].
    final ne = el.clamp(-math.pi / 2, math.pi / 2);
    final aIdx = (na / twoPi * azimuthBins).floor().clamp(0, azimuthBins - 1);
    final eFrac = (ne + math.pi / 2) / math.pi;
    final eIdx = (eFrac * elevationBins).floor().clamp(0, elevationBins - 1);
    return eIdx * azimuthBins + aIdx;
  }

  (double az, double el) _binCenter(int aIdx, int eIdx) {
    final twoPi = 2 * math.pi;
    final az = (aIdx + 0.5) / azimuthBins * twoPi;
    final el = -math.pi / 2 + (eIdx + 0.5) / elevationBins * math.pi;
    return (az, el);
  }

  double _shortestAngle(double delta) {
    final twoPi = 2 * math.pi;
    double d = (delta + math.pi) % twoPi;
    if (d < 0) d += twoPi;
    return d - math.pi;
  }
}
