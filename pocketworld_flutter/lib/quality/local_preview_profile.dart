// Dart port of App/LocalPreview/LocalPreviewProductProfile.swift.
//
// Workflow phase enum + progress-basis keys + copy for the 6 stages of
// the local-preview (subject-first) pipeline. Used by the broker-side
// progress parser to map a job's `progress_basis` string to a
// human-readable phase name + expected fraction window — this lets
// the UI show a reasonable progress bar even when the broker reports
// progress in a way the client-side doesn't recognize.

enum LocalPreviewWorkflowPhase {
  depth,
  seed,
  refine,
  cutout,
  cleanup,
  export;

  String get rawValue {
    switch (this) {
      case LocalPreviewWorkflowPhase.depth:
        return 'depth';
      case LocalPreviewWorkflowPhase.seed:
        return 'seed';
      case LocalPreviewWorkflowPhase.refine:
        return 'refine';
      case LocalPreviewWorkflowPhase.cutout:
        return 'cutout';
      case LocalPreviewWorkflowPhase.cleanup:
        return 'cleanup';
      case LocalPreviewWorkflowPhase.export:
        return 'export';
    }
  }

  String get title {
    switch (this) {
      case LocalPreviewWorkflowPhase.depth:
        return '深度先验';
      case LocalPreviewWorkflowPhase.seed:
        return '初始化高斯';
      case LocalPreviewWorkflowPhase.refine:
        return '本地 refine';
      case LocalPreviewWorkflowPhase.cutout:
        return '主体裁切';
      case LocalPreviewWorkflowPhase.cleanup:
        return '边角清理';
      case LocalPreviewWorkflowPhase.export:
        return '导出结果';
    }
  }

  String get progressBasis => 'local_subject_first_$rawValue';
  String get legacyProgressBasis => 'local_preview_$rawValue';

  /// Fraction at the start of this phase (0..1). Used to paint a
  /// continuous progress bar even when the broker only reports the
  /// current phase (no numerical fraction within phase).
  double get startFraction {
    switch (this) {
      case LocalPreviewWorkflowPhase.depth:
        return 0.08;
      case LocalPreviewWorkflowPhase.seed:
        return 0.30;
      case LocalPreviewWorkflowPhase.refine:
        return 0.52;
      case LocalPreviewWorkflowPhase.cutout:
        return 0.74;
      case LocalPreviewWorkflowPhase.cleanup:
        return 0.84;
      case LocalPreviewWorkflowPhase.export:
        return 0.92;
    }
  }

  /// Default animated fraction when the phase is active but no finer
  /// progress is reported (chosen so a healthy phase visually animates
  /// from `startFraction` toward this value).
  double get defaultActiveFraction {
    switch (this) {
      case LocalPreviewWorkflowPhase.depth:
        return 0.18;
      case LocalPreviewWorkflowPhase.seed:
        return 0.38;
      case LocalPreviewWorkflowPhase.refine:
        return 0.64;
      case LocalPreviewWorkflowPhase.cutout:
        return 0.79;
      case LocalPreviewWorkflowPhase.cleanup:
        return 0.88;
      case LocalPreviewWorkflowPhase.export:
        return 0.96;
    }
  }

  String get detailMessage {
    switch (this) {
      case LocalPreviewWorkflowPhase.depth:
        return '正在做多帧单目深度先验，先把可用于本地结果生成的几何线索补齐。';
      case LocalPreviewWorkflowPhase.seed:
        return '正在根据深度先验初始化高斯种子，筛掉不稳定和低质量 seed。';
      case LocalPreviewWorkflowPhase.refine:
        return '正在做有上限的本地 refine，只追求尽快得到一个能看的本地结果。';
      case LocalPreviewWorkflowPhase.cutout:
        return '正在沿着主体主簇做显式 cutout，先把能看的主体边界站住。';
      case LocalPreviewWorkflowPhase.cleanup:
        return '正在保守清理低覆盖碎边和浮空小块，同时尽量保住主体和接触面。';
      case LocalPreviewWorkflowPhase.export:
        return '本地训练已经收口，正在导出可交互结果。';
    }
  }

  String get completedProgressText => '已完成';
}

class LocalPreviewProductProfile {
  LocalPreviewProductProfile._();

  static const String defaultCloudPipelineMode = 'monocular_ref_depth';
  static const String defaultSubjectFirstPipelineMode =
      'monocular_subject_first_result';
  static const String depthPriorSource = 'depthanything_v2_coreml';
  static const String depthPriorTransport = 'ref_depth';
  static const String depthPriorProfile = 'small_only_fast_native';

  /// Maps a broker `progress_basis` string or phase name to a
  /// `LocalPreviewWorkflowPhase`. Null when the string doesn't match
  /// any known phase (caller should fall back to the opaque phase
  /// string from the broker).
  static LocalPreviewWorkflowPhase? phase({
    String? progressBasis,
    String? phaseName,
  }) {
    final name = phaseName?.trim().toLowerCase();
    if (name != null && name.isNotEmpty) {
      for (final p in LocalPreviewWorkflowPhase.values) {
        if (p.rawValue == name) return p;
      }
    }
    final basis = progressBasis?.trim().toLowerCase();
    if (basis != null && basis.isNotEmpty) {
      for (final p in LocalPreviewWorkflowPhase.values) {
        if (p.progressBasis == basis || p.legacyProgressBasis == basis) {
          return p;
        }
      }
    }
    return null;
  }
}
