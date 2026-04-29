// Dart port of App/ObjectModeV2/ObjectModeV2GuidanceEngine.swift.
//
// Real-time per-frame audit + dome-guidance engine. Consumes a visual
// frame sample (Laplacian variance, brightness, texture signature) plus
// the target zone anchor and produces:
//   • a GuidanceSnapshot with accepted-frame count, orbit completion,
//     hint text, stability score
//   • an AuditSummary rolled up to broker `pipelineAuditFields` at
//     scan-end so the cloud can cross-check the client's live audit.
//
// Keeps the hard-reject taxonomy exactly in sync with the Swift source:
//   HARD: blur / dark / bright / occupancy
//   SOFT: redundant / low_texture / weak_quality
//   HINT: recenter / new_angle / coverage
//
// The numerical thresholds live in frame_quality_constants.dart and
// are open to per-device tuning (Phase 7 device matrix).

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'frame_quality_constants.dart';

class GuidanceSnapshot {
  final int acceptedFrames;
  final double orbitCompletion;
  final String hintText;
  final double stabilityScore;
  final double? lastAcceptedTimestamp;

  const GuidanceSnapshot({
    required this.acceptedFrames,
    required this.orbitCompletion,
    required this.hintText,
    required this.stabilityScore,
    this.lastAcceptedTimestamp,
  });

  static const GuidanceSnapshot idle = GuidanceSnapshot(
    acceptedFrames: 0,
    orbitCompletion: 0,
    hintText: '将物体放在画面中央，开始后沿着主体缓慢绕一圈。',
    stabilityScore: 1,
  );
}

class GuidanceAuditSummary {
  int totalSamples;
  int hardRejectBlurCount;
  int hardRejectDarkCount;
  int hardRejectBrightCount;
  int hardRejectOccupancyCount;
  int softDowngradeRedundantCount;
  int softDowngradeLowTextureCount;
  int softDowngradeWeakQualityCount;
  int guidanceRecenterCount;
  int guidanceNewAngleCount;
  int guidanceCoverageCount;

  GuidanceAuditSummary({
    this.totalSamples = 0,
    this.hardRejectBlurCount = 0,
    this.hardRejectDarkCount = 0,
    this.hardRejectBrightCount = 0,
    this.hardRejectOccupancyCount = 0,
    this.softDowngradeRedundantCount = 0,
    this.softDowngradeLowTextureCount = 0,
    this.softDowngradeWeakQualityCount = 0,
    this.guidanceRecenterCount = 0,
    this.guidanceNewAngleCount = 0,
    this.guidanceCoverageCount = 0,
  });

  void reset() {
    totalSamples = 0;
    hardRejectBlurCount = 0;
    hardRejectDarkCount = 0;
    hardRejectBrightCount = 0;
    hardRejectOccupancyCount = 0;
    softDowngradeRedundantCount = 0;
    softDowngradeLowTextureCount = 0;
    softDowngradeWeakQualityCount = 0;
    guidanceRecenterCount = 0;
    guidanceNewAngleCount = 0;
    guidanceCoverageCount = 0;
  }
}

class VisualFrameSample {
  final double timestamp;
  final int signatureWidth;
  final int signatureHeight;
  final Uint8List signature;
  final double laplacianVariance;
  final double meanBrightness;
  final double globalVariance;

  const VisualFrameSample({
    required this.timestamp,
    required this.signatureWidth,
    required this.signatureHeight,
    required this.signature,
    required this.laplacianVariance,
    required this.meanBrightness,
    required this.globalVariance,
  });
}

class _TargetZoneMetrics {
  final double textureScore;
  final double contrastScore;
  const _TargetZoneMetrics(this.textureScore, this.contrastScore);
}

class GuidanceEngine {
  static const int _maxAcceptedFrames = 150;
  static const double _hardRejectTargetSignalThreshold = 0.10;
  static const double _softWarnTargetSignalThreshold = 0.16;

  void Function(GuidanceSnapshot)? onUpdate;

  GuidanceSnapshot _snapshot = GuidanceSnapshot.idle;
  DateTime? _recordingStartedAt;
  double? _lastAcceptedAt;
  Uint8List _lastAcceptedSignature = Uint8List(0);
  double _coverageCredits = 0;
  double _smoothedQuality = 0;
  final GuidanceAuditSummary _auditSummary = GuidanceAuditSummary();

  GuidanceAuditSummary get auditSummary => _auditSummary;
  GuidanceSnapshot get snapshot => _snapshot;

  void startMonitoring() => _publish(_snapshot);

  void stopMonitoring() {}

  void beginRecording() {
    _recordingStartedAt = DateTime.now();
    _lastAcceptedAt = null;
    _lastAcceptedSignature = Uint8List(0);
    _coverageCredits = 0;
    _smoothedQuality = 0;
    _auditSummary.reset();
    _publish(const GuidanceSnapshot(
      acceptedFrames: 0,
      orbitCompletion: 0,
      hintText: '很好，开始缓慢绕主体移动，系统会自动挑选有效帧。',
      stabilityScore: 1,
    ));
  }

  void endRecording() {
    _recordingStartedAt = null;
    _publish(_snapshot);
  }

  /// Flat key/value payload that mirrors the Swift `pipelineAuditFields`
  /// output. Meant to be merged into the broker's job-start payload so
  /// the cloud can cross-check the client's live audit against the
  /// server-side audit.
  Map<String, String> pipelineAuditFields({
    required Offset targetZoneAnchor,
    required TargetZoneMode targetZoneMode,
  }) {
    return {
      'visual_policy_version': 'v2_unified_capture_audit',
      'visual_min_target_signal':
          _hardRejectTargetSignalThreshold.toStringAsFixed(4),
      'visual_warn_target_signal':
          _softWarnTargetSignalThreshold.toStringAsFixed(4),
      'visual_min_orb_features':
          '${FrameQualityConstants.minOrbFeaturesForSfm}',
      'visual_warn_orb_features':
          '${FrameQualityConstants.warnOrbFeaturesForSfm}',
      'target_zone_anchor_x': targetZoneAnchor.dx.toStringAsFixed(4),
      'target_zone_anchor_y': targetZoneAnchor.dy.toStringAsFixed(4),
      'target_zone_mode_runtime': targetZoneMode.rawValue,
      'client_live_total_samples': '${_auditSummary.totalSamples}',
      'client_live_hard_reject_blur_count':
          '${_auditSummary.hardRejectBlurCount}',
      'client_live_hard_reject_dark_count':
          '${_auditSummary.hardRejectDarkCount}',
      'client_live_hard_reject_bright_count':
          '${_auditSummary.hardRejectBrightCount}',
      'client_live_hard_reject_occupancy_count':
          '${_auditSummary.hardRejectOccupancyCount}',
      'client_live_soft_redundant_count':
          '${_auditSummary.softDowngradeRedundantCount}',
      'client_live_soft_low_texture_count':
          '${_auditSummary.softDowngradeLowTextureCount}',
      'client_live_soft_weak_quality_count':
          '${_auditSummary.softDowngradeWeakQualityCount}',
      'client_live_guidance_recenter_count':
          '${_auditSummary.guidanceRecenterCount}',
      'client_live_guidance_new_angle_count':
          '${_auditSummary.guidanceNewAngleCount}',
      'client_live_guidance_coverage_count':
          '${_auditSummary.guidanceCoverageCount}',
    };
  }

  /// Per-frame processing. Called at ~24-30 Hz from the camera pipeline
  /// (still TBD — see PORTING_BACKLOG.md).
  void processVisualSample(
    VisualFrameSample sample, {
    required Offset targetZoneAnchor,
    required TargetZoneMode targetZoneMode,
  }) {
    final startedAt = _recordingStartedAt;
    if (startedAt == null) return;

    final targetMetrics = _targetZoneMetrics(
      sample,
      anchor: targetZoneAnchor,
      mode: targetZoneMode,
    );
    final sharpnessScore = _clamp01(
      sample.laplacianVariance /
          (FrameQualityConstants.blurThresholdLaplacian * 1.35),
    );
    final brightnessScore = _normalizedBrightnessScore(sample.meanBrightness);
    final occupancyScore = _clamp01(
      targetMetrics.textureScore * 0.55 + targetMetrics.contrastScore * 0.45,
    );
    final noveltyScore = _novelty(
      current: sample.signature,
      previous: _lastAcceptedSignature,
    );
    final similarityScore = _clamp01(1 - noveltyScore);
    final targetSignal =
        targetMetrics.textureScore * 0.55 + targetMetrics.contrastScore * 0.45;
    final qualityScore = _clamp01(
      sharpnessScore * 0.58 + brightnessScore * 0.18 + occupancyScore * 0.24,
    );
    _smoothedQuality = _smoothedQuality == 0
        ? qualityScore
        : _smoothedQuality * 0.72 + qualityScore * 0.28;

    final now = sample.timestamp;
    final recordingAge = DateTime.now()
        .difference(startedAt)
        .inMilliseconds /
        1000.0;
    final enoughTimePassed =
        _lastAcceptedAt == null ? true : (now - _lastAcceptedAt!) > 0.28;
    final qualityThreshold = _acceptanceThreshold(_snapshot.acceptedFrames);
    final maxSimilarity = _maximumSimilarity(targetZoneMode);
    final lowTexture =
        sample.globalVariance < FrameQualityConstants.minLocalVarianceForTexture;

    int accepted = _snapshot.acceptedFrames;
    bool acceptedNew = false;
    _auditSummary.totalSamples += 1;

    if (sample.laplacianVariance < FrameQualityConstants.blurThresholdLaplacian) {
      _auditSummary.hardRejectBlurCount += 1;
    }
    if (sample.meanBrightness < FrameQualityConstants.darkThresholdBrightness) {
      _auditSummary.hardRejectDarkCount += 1;
    }
    if (sample.meanBrightness > FrameQualityConstants.brightThresholdBrightness) {
      _auditSummary.hardRejectBrightCount += 1;
    }
    if (targetSignal < _hardRejectTargetSignalThreshold) {
      _auditSummary.hardRejectOccupancyCount += 1;
    }
    if (similarityScore > maxSimilarity) {
      _auditSummary.softDowngradeRedundantCount += 1;
      _auditSummary.guidanceNewAngleCount += 1;
    }
    if (lowTexture) {
      _auditSummary.softDowngradeLowTextureCount += 1;
    }
    if (qualityScore < qualityThreshold) {
      _auditSummary.softDowngradeWeakQualityCount += 1;
    }
    if (targetSignal < _softWarnTargetSignalThreshold) {
      _auditSummary.guidanceRecenterCount += 1;
    }
    if (_orbitCompletionHint(accepted, _coverageCredits) < 0.70) {
      _auditSummary.guidanceCoverageCount += 1;
    }

    if (accepted == 0) {
      if (recordingAge > 0.35 &&
          sharpnessScore > 0.20 &&
          brightnessScore > 0.32 &&
          occupancyScore > 0.10) {
        accepted = 1;
        acceptedNew = true;
      }
    } else if (accepted < _maxAcceptedFrames &&
        enoughTimePassed &&
        sharpnessScore > 0.24 &&
        brightnessScore > 0.28 &&
        occupancyScore > 0.10 &&
        similarityScore <= maxSimilarity &&
        qualityScore >= qualityThreshold) {
      accepted += 1;
      acceptedNew = true;
    }

    if (acceptedNew) {
      _lastAcceptedAt = now;
      _lastAcceptedSignature = sample.signature;
      _coverageCredits = math.min(
        1,
        _coverageCredits + math.max(0.06, math.min(noveltyScore * 1.8, 0.16)),
      );
    }

    final orbitCompletion = _orbitCompletionHint(accepted, _coverageCredits);
    final hint = _hintFor(
      accepted: accepted,
      targetSignal: targetSignal,
      orbitCompletion: orbitCompletion,
      sharpnessScore: sharpnessScore,
    );

    _publish(GuidanceSnapshot(
      acceptedFrames: accepted,
      orbitCompletion: orbitCompletion,
      hintText: hint,
      stabilityScore: _clamp01(1 - (1 - _smoothedQuality) * 0.8),
      lastAcceptedTimestamp: _lastAcceptedAt,
    ));
  }

  // ─── Helpers ────────────────────────────────────────────────────

  double _clamp01(double v) => v.clamp(0.0, 1.0);

  double _normalizedBrightnessScore(double mean) {
    // BT.601 luma on the 0-255 scale. "Good" band is roughly 80-190.
    // Penalize both darkness and blowout symmetrically.
    final centered = 1.0 - ((mean - 135.0).abs() / 135.0);
    return _clamp01(centered);
  }

  double _novelty({required Uint8List current, required Uint8List previous}) {
    if (previous.isEmpty) return 1.0;
    final n = math.min(current.length, previous.length);
    if (n == 0) return 1.0;
    int differing = 0;
    for (int i = 0; i < n; i++) {
      if (current[i] != previous[i]) differing += 1;
    }
    return (differing / n).clamp(0.0, 1.0);
  }

  double _acceptanceThreshold(int accepted) {
    if (accepted < 20) return 0.32;
    if (accepted < 60) return 0.38;
    if (accepted < 110) return 0.42;
    return 0.48;
  }

  double _maximumSimilarity(TargetZoneMode mode) {
    switch (mode) {
      case TargetZoneMode.loose:
        return 0.80;
      case TargetZoneMode.balanced:
        return 0.72;
      case TargetZoneMode.strict:
        return 0.64;
    }
  }

  double _orbitCompletionHint(int accepted, double coverageCredits) {
    // Combine accepted-frame count saturation with coverage spread. A
    // scan that captured 60 frames from tightly-clustered angles gets
    // less completion than a scan with 40 well-spread frames.
    final frameFraction = accepted / _maxAcceptedFrames.toDouble();
    return _clamp01(frameFraction * 0.55 + coverageCredits * 0.45);
  }

  String _hintFor({
    required int accepted,
    required double targetSignal,
    required double orbitCompletion,
    required double sharpnessScore,
  }) {
    if (accepted == 0) {
      if (targetSignal < _hardRejectTargetSignalThreshold) {
        return '让物体充满中央画框后再开始。';
      }
      return '保持对准主体，系统正在评估第一帧。';
    }
    if (targetSignal < _softWarnTargetSignalThreshold) {
      return '稍微回到主体上方，再继续环绕。';
    }
    if (sharpnessScore < 0.30) {
      return '放慢一点，画面有点糊。';
    }
    if (orbitCompletion < 0.30) {
      return '继续沿着主体缓慢绕行。';
    }
    if (orbitCompletion < 0.70) {
      return '还剩下一段没扫到，绕远一点。';
    }
    if (orbitCompletion < 0.98) {
      return '收尾，把最后那段补齐。';
    }
    return '很好，采集完成，可以停下。';
  }

  _TargetZoneMetrics _targetZoneMetrics(
    VisualFrameSample sample, {
    required Offset anchor,
    required TargetZoneMode mode,
  }) {
    // Lightweight proxy — the real signature is produced by the GPU
    // pipeline (QualityMetrics shaders). Here we approximate "texture"
    // and "contrast" from the sample's coarse-grained signature bytes
    // without needing the full shader output. Precision refinement is
    // tracked in PORTING_BACKLOG.md D2.
    if (sample.signature.isEmpty) {
      return const _TargetZoneMetrics(0, 0);
    }
    double sumAbsDelta = 0;
    double sum = 0;
    for (int i = 1; i < sample.signature.length; i++) {
      sumAbsDelta += (sample.signature[i] - sample.signature[i - 1]).abs();
      sum += sample.signature[i];
    }
    final mean = sum / math.max(1, sample.signature.length - 1);
    final texture =
        _clamp01((sumAbsDelta / (sample.signature.length - 1)) / 96.0);
    // Contrast: brightness band from 80-190 is ideal; punish both tails.
    final contrast = _clamp01(1 - (mean - 135.0).abs() / 135.0);
    return _TargetZoneMetrics(texture, contrast);
  }

  void _publish(GuidanceSnapshot s) {
    _snapshot = s;
    final cb = onUpdate;
    if (cb != null) cb(s);
  }
}
