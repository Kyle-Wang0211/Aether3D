// Plan G W2 P4 + P0/P1/P2: depth_meta.jsonl sidecar — per-frame DA3
// confidence statistics, metric alignment diagnostics, sparse-prior
// refinement diagnostics, and the skip decision for pointcloud + SAP/3DGS.
//
// Lifecycle (Plan G 全本地 photos-on-disk arch, 2026-05-16):
//   1. Capture writes `<photosDir>/cell_<i>_slot_<j>.jpg` + sibling
//      `.json` metadata for every cell-admitted frame.
//   2. When W3 runs (post-stop, local on-device DA3 inference per JPEG),
//      it appends one [DepthMetaEntry] per frame to a paired sidecar
//      `<photosDir>/depth_meta.jsonl` (or sibling `<jpeg>.depth.json`).
//   3. W3's pointcloud + 3DGS stages call [DepthMetaSidecar.isFrameSkipped]
//      to skip frames the model flagged as untrusted (conf median at
//      DA3's "I don't know" floor, ~1.0). Cross-platform Dart so
//      iOS / Android / HarmonyOS / Web depth runtimes share one policy.
//
// Format (JSON Lines, one object per line):
//
//   { "frame": 12,              // .mov frame index (curated, post-P2)
//     "conf_median": 1.000,     // float, ≥1.0 from DA3
//     "conf_mean":   1.043,     // float
//     "conf_min":    1.000,     // float
//     "conf_max":    1.821,     // float
//     "skip": true,             // = (conf_median <= kDepthSkipConfThreshold)
//     "inference_ms": 2342.5,       // optional, perf telemetry
//     "relative_depth_path": "...", // DA3 relative-depth artifact
//     "metric_depth_path": "...",   // P0/P1/P2 metric-depth artifact
//     "align_mode": "session_chunk_adaptive",
//     "align_scale": 1.72,
//     "align_translation": 0.03,
//     "align_reliability": 0.84,
//     "sparse_prior_used": true }
//
// Skip semantics: the W3 reader treats a missing entry as "not yet
// inferred — process normally"; only an explicit `skip: true` excludes
// the frame from pointcloud unproject + 3DGS training contributions.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Plan G W2 P4 untrusted-conf floor. DA3 conf heads bottom out near 1.0
/// when the model has zero per-pixel confidence. 1.05 leaves a small margin
/// for fp16 CoreML noise until the DA3-BASE benchmark locks a tighter value.
///
/// Lives in Dart — the iOS / Android / HarmonyOS / Web depth runtimes
/// just ship the raw conf buffer back; the threshold + skip decision is
/// shared Dart code.
const double kDepthSkipConfThreshold = 1.05;

/// Current JSONL payload version. Version 1 was confidence-only; version 2
/// adds the P0/P1/P2 metric-depth fields.
const int kDepthMetaSchemaVersion = 2;

const String kDepthAlignModeSessionChunkAdaptive = 'session_chunk_adaptive';
const String kDepthAlignModeFramePriorFallback = 'frame_prior_fallback';
const String kSparsePriorModeResidualField = 'sparse_residual_field';

/// Per-frame depth_conf summary. Computed from the raw fp32 conf buffer
/// returned by whichever platform's depth runtime ran (CoreML on iOS,
/// TFLite/ONNX on Android, HMS ML on HarmonyOS, ONNX Runtime Web on Web).
///
/// Median is the canonical "skip vs keep" signal — robust against
/// single-pixel outliers, pegged to the DA3 floor (1.0) when the model
/// can't reconstruct depth at all. Mean / min / max are diagnostic.
class DepthConfStats {
  final double median;
  final double mean;
  final double min;
  final double max;

  const DepthConfStats({
    required this.median,
    required this.mean,
    required this.min,
    required this.max,
  });

  /// O(n log n) sort to find the median; O(n) for the rest. For 588×1036
  /// = 609,408 floats, sort runs ~10-20 ms in pure Dart on iPhone 14 Pro
  /// — negligible next to the 2.3 s DA3 forward pass.
  factory DepthConfStats.fromBuffer(List<double> conf) {
    if (conf.isEmpty) {
      return const DepthConfStats(median: 1.0, mean: 1.0, min: 1.0, max: 1.0);
    }
    var minV = conf[0];
    var maxV = conf[0];
    var sum = 0.0;
    for (final v in conf) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
      sum += v;
    }
    final mean = sum / conf.length;
    final sorted = List<double>.from(conf)..sort();
    final median = sorted[sorted.length ~/ 2];
    return DepthConfStats(median: median, mean: mean, min: minV, max: maxV);
  }

  /// Faster path for Float32List (typed) buffers — what the platform
  /// MethodChannels typically marshal as. Avoids the double-conversion
  /// hop required by [fromBuffer].
  factory DepthConfStats.fromFloat32List(Float32List conf) {
    if (conf.isEmpty) {
      return const DepthConfStats(median: 1.0, mean: 1.0, min: 1.0, max: 1.0);
    }
    var minV = conf[0];
    var maxV = conf[0];
    var sum = 0.0;
    for (final v in conf) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
      sum += v;
    }
    final mean = sum / conf.length;
    final sorted = Float32List.fromList(conf)..sort();
    final median = sorted[sorted.length ~/ 2];
    return DepthConfStats(
      median: median.toDouble(),
      mean: mean,
      min: minV.toDouble(),
      max: maxV.toDouble(),
    );
  }

  /// Whether [median] hits the untrusted-conf floor. Capture-side W3
  /// pipelines call this to short-circuit pointcloud unproject + 3DGS
  /// training contributions for frames the model itself flagged.
  bool get isSkipCandidate => median <= kDepthSkipConfThreshold;
}

/// One frame's depth_meta record. `skip` is derived from `confMedian`
/// at write time so the consumer doesn't have to know the threshold
/// (and a future threshold change is rebackfilled by re-running W3).
class DepthMetaEntry {
  /// Curated .mov frame index (post-P2 curation).
  final int frame;
  final double confMedian;
  final double confMean;
  final double confMin;
  final double confMax;
  final bool skip;
  final double? inferenceMs;
  final String? relativeDepthPath;
  final String? metricDepthPath;

  /// P0/P1 metric alignment fields. P0 writes a session/chunk prior; P1 may
  /// write a per-frame fallback that is regularized by that prior.
  final String? alignMode;
  final double? alignScale;
  final double? alignTranslation;
  final double? alignReliability;
  final double? alignRmse;
  final double? alignInlierRatio;
  final double? alignAiDepthSpan;
  final double? alignMetricDepthSpan;
  final double? alignScalePriorWeight;
  final double? alignTranslationPriorWeight;
  final int? alignAnchorCount;
  final int? alignAnchorUsed;
  final bool? alignUsedPrior;

  /// P2 sparse-prior residual refinement fields. This is internal telemetry
  /// for scheduler/SAP weighting, not user-visible capture feedback.
  final String? sparsePriorMode;
  final bool? sparsePriorUsed;
  final int? sparsePriorAnchorCount;
  final int? sparsePriorAnchorUsed;
  final double? sparsePriorMeanAbsResidualM;
  final double? sparsePriorMaxAbsResidualM;

  const DepthMetaEntry({
    required this.frame,
    required this.confMedian,
    required this.confMean,
    required this.confMin,
    required this.confMax,
    required this.skip,
    this.inferenceMs,
    this.relativeDepthPath,
    this.metricDepthPath,
    this.alignMode,
    this.alignScale,
    this.alignTranslation,
    this.alignReliability,
    this.alignRmse,
    this.alignInlierRatio,
    this.alignAiDepthSpan,
    this.alignMetricDepthSpan,
    this.alignScalePriorWeight,
    this.alignTranslationPriorWeight,
    this.alignAnchorCount,
    this.alignAnchorUsed,
    this.alignUsedPrior,
    this.sparsePriorMode,
    this.sparsePriorUsed,
    this.sparsePriorAnchorCount,
    this.sparsePriorAnchorUsed,
    this.sparsePriorMeanAbsResidualM,
    this.sparsePriorMaxAbsResidualM,
  });

  /// Build from a freshly computed [DepthConfStats]. The skip decision
  /// is derived from the stats' [DepthConfStats.isSkipCandidate], so the
  /// threshold lives in one place.
  factory DepthMetaEntry.fromStats({
    required int frame,
    required DepthConfStats stats,
    double? inferenceMs,
    String? relativeDepthPath,
    String? metricDepthPath,
  }) {
    return DepthMetaEntry(
      frame: frame,
      confMedian: stats.median,
      confMean: stats.mean,
      confMin: stats.min,
      confMax: stats.max,
      skip: stats.isSkipCandidate,
      inferenceMs: inferenceMs,
      relativeDepthPath: relativeDepthPath,
      metricDepthPath: metricDepthPath,
    );
  }

  DepthMetaEntry copyWith({
    int? frame,
    double? confMedian,
    double? confMean,
    double? confMin,
    double? confMax,
    bool? skip,
    double? inferenceMs,
    String? relativeDepthPath,
    String? metricDepthPath,
    String? alignMode,
    double? alignScale,
    double? alignTranslation,
    double? alignReliability,
    double? alignRmse,
    double? alignInlierRatio,
    double? alignAiDepthSpan,
    double? alignMetricDepthSpan,
    double? alignScalePriorWeight,
    double? alignTranslationPriorWeight,
    int? alignAnchorCount,
    int? alignAnchorUsed,
    bool? alignUsedPrior,
    String? sparsePriorMode,
    bool? sparsePriorUsed,
    int? sparsePriorAnchorCount,
    int? sparsePriorAnchorUsed,
    double? sparsePriorMeanAbsResidualM,
    double? sparsePriorMaxAbsResidualM,
  }) {
    return DepthMetaEntry(
      frame: frame ?? this.frame,
      confMedian: confMedian ?? this.confMedian,
      confMean: confMean ?? this.confMean,
      confMin: confMin ?? this.confMin,
      confMax: confMax ?? this.confMax,
      skip: skip ?? this.skip,
      inferenceMs: inferenceMs ?? this.inferenceMs,
      relativeDepthPath: relativeDepthPath ?? this.relativeDepthPath,
      metricDepthPath: metricDepthPath ?? this.metricDepthPath,
      alignMode: alignMode ?? this.alignMode,
      alignScale: alignScale ?? this.alignScale,
      alignTranslation: alignTranslation ?? this.alignTranslation,
      alignReliability: alignReliability ?? this.alignReliability,
      alignRmse: alignRmse ?? this.alignRmse,
      alignInlierRatio: alignInlierRatio ?? this.alignInlierRatio,
      alignAiDepthSpan: alignAiDepthSpan ?? this.alignAiDepthSpan,
      alignMetricDepthSpan: alignMetricDepthSpan ?? this.alignMetricDepthSpan,
      alignScalePriorWeight:
          alignScalePriorWeight ?? this.alignScalePriorWeight,
      alignTranslationPriorWeight:
          alignTranslationPriorWeight ?? this.alignTranslationPriorWeight,
      alignAnchorCount: alignAnchorCount ?? this.alignAnchorCount,
      alignAnchorUsed: alignAnchorUsed ?? this.alignAnchorUsed,
      alignUsedPrior: alignUsedPrior ?? this.alignUsedPrior,
      sparsePriorMode: sparsePriorMode ?? this.sparsePriorMode,
      sparsePriorUsed: sparsePriorUsed ?? this.sparsePriorUsed,
      sparsePriorAnchorCount:
          sparsePriorAnchorCount ?? this.sparsePriorAnchorCount,
      sparsePriorAnchorUsed:
          sparsePriorAnchorUsed ?? this.sparsePriorAnchorUsed,
      sparsePriorMeanAbsResidualM:
          sparsePriorMeanAbsResidualM ?? this.sparsePriorMeanAbsResidualM,
      sparsePriorMaxAbsResidualM:
          sparsePriorMaxAbsResidualM ?? this.sparsePriorMaxAbsResidualM,
    );
  }

  Map<String, dynamic> toJson() => {
    'schema_version': kDepthMetaSchemaVersion,
    'frame': frame,
    'conf_median': confMedian,
    'conf_mean': confMean,
    'conf_min': confMin,
    'conf_max': confMax,
    'skip': skip,
    if (inferenceMs != null) 'inference_ms': inferenceMs,
    if (relativeDepthPath != null) 'relative_depth_path': relativeDepthPath,
    if (metricDepthPath != null) 'metric_depth_path': metricDepthPath,
    if (alignMode != null) 'align_mode': alignMode,
    if (alignScale != null) 'align_scale': alignScale,
    if (alignTranslation != null) 'align_translation': alignTranslation,
    if (alignReliability != null) 'align_reliability': alignReliability,
    if (alignRmse != null) 'align_rmse': alignRmse,
    if (alignInlierRatio != null) 'align_inlier_ratio': alignInlierRatio,
    if (alignAiDepthSpan != null) 'align_ai_depth_span': alignAiDepthSpan,
    if (alignMetricDepthSpan != null)
      'align_metric_depth_span_m': alignMetricDepthSpan,
    if (alignScalePriorWeight != null)
      'align_scale_prior_weight': alignScalePriorWeight,
    if (alignTranslationPriorWeight != null)
      'align_translation_prior_weight': alignTranslationPriorWeight,
    if (alignAnchorCount != null) 'align_anchor_count': alignAnchorCount,
    if (alignAnchorUsed != null) 'align_anchor_used': alignAnchorUsed,
    if (alignUsedPrior != null) 'align_used_prior': alignUsedPrior,
    if (sparsePriorMode != null) 'sparse_prior_mode': sparsePriorMode,
    if (sparsePriorUsed != null) 'sparse_prior_used': sparsePriorUsed,
    if (sparsePriorAnchorCount != null)
      'sparse_prior_anchor_count': sparsePriorAnchorCount,
    if (sparsePriorAnchorUsed != null)
      'sparse_prior_anchor_used': sparsePriorAnchorUsed,
    if (sparsePriorMeanAbsResidualM != null)
      'sparse_prior_mean_abs_residual_m': sparsePriorMeanAbsResidualM,
    if (sparsePriorMaxAbsResidualM != null)
      'sparse_prior_max_abs_residual_m': sparsePriorMaxAbsResidualM,
  };

  static DepthMetaEntry fromJson(Map<String, dynamic> obj) {
    return DepthMetaEntry(
      frame: (obj['frame'] as num).toInt(),
      confMedian: (obj['conf_median'] as num).toDouble(),
      confMean: (obj['conf_mean'] as num).toDouble(),
      confMin: (obj['conf_min'] as num).toDouble(),
      confMax: (obj['conf_max'] as num).toDouble(),
      skip: (obj['skip'] as bool?) ?? false,
      inferenceMs: (obj['inference_ms'] as num?)?.toDouble(),
      relativeDepthPath: obj['relative_depth_path'] as String?,
      metricDepthPath: obj['metric_depth_path'] as String?,
      alignMode: obj['align_mode'] as String?,
      alignScale: (obj['align_scale'] as num?)?.toDouble(),
      alignTranslation: (obj['align_translation'] as num?)?.toDouble(),
      alignReliability: (obj['align_reliability'] as num?)?.toDouble(),
      alignRmse: (obj['align_rmse'] as num?)?.toDouble(),
      alignInlierRatio: (obj['align_inlier_ratio'] as num?)?.toDouble(),
      alignAiDepthSpan: (obj['align_ai_depth_span'] as num?)?.toDouble(),
      alignMetricDepthSpan: (obj['align_metric_depth_span_m'] as num?)
          ?.toDouble(),
      alignScalePriorWeight: (obj['align_scale_prior_weight'] as num?)
          ?.toDouble(),
      alignTranslationPriorWeight:
          (obj['align_translation_prior_weight'] as num?)?.toDouble(),
      alignAnchorCount: (obj['align_anchor_count'] as num?)?.toInt(),
      alignAnchorUsed: (obj['align_anchor_used'] as num?)?.toInt(),
      alignUsedPrior: obj['align_used_prior'] as bool?,
      sparsePriorMode: obj['sparse_prior_mode'] as String?,
      sparsePriorUsed: obj['sparse_prior_used'] as bool?,
      sparsePriorAnchorCount: (obj['sparse_prior_anchor_count'] as num?)
          ?.toInt(),
      sparsePriorAnchorUsed: (obj['sparse_prior_anchor_used'] as num?)?.toInt(),
      sparsePriorMeanAbsResidualM:
          (obj['sparse_prior_mean_abs_residual_m'] as num?)?.toDouble(),
      sparsePriorMaxAbsResidualM:
          (obj['sparse_prior_max_abs_residual_m'] as num?)?.toDouble(),
    );
  }
}

/// File-backed reader/writer for `<stem>.depth_meta.jsonl`. Both the
/// reader and writer treat the file as append-only JSONL; a partial
/// write (e.g. W3 stage crashed midway) still yields a valid prefix
/// when re-read, and resumes can pick up at the next frame index.
class DepthMetaSidecar {
  /// Returns the canonical depth-meta path for a curated .mov:
  /// `<stem>.depth_meta.jsonl`. Caller is responsible for choosing
  /// `<stem>` consistent with the curated.mov + curated.anchors paths.
  static String pathForCuratedMov(String curatedMovPath) {
    // Strip ".curated.mov" → "<stem>" → append ".curated.depth_meta.jsonl"
    if (curatedMovPath.endsWith('.curated.mov')) {
      final stem = curatedMovPath.substring(
        0,
        curatedMovPath.length - '.curated.mov'.length,
      );
      return '$stem.curated.depth_meta.jsonl';
    }
    // Generic fallback for non-curated .mov:
    if (curatedMovPath.endsWith('.mov')) {
      final stem = curatedMovPath.substring(
        0,
        curatedMovPath.length - '.mov'.length,
      );
      return '$stem.depth_meta.jsonl';
    }
    return '$curatedMovPath.depth_meta.jsonl';
  }

  /// Read every entry from disk. Returns empty list if the file is
  /// missing, empty, or fully malformed. Malformed lines are silently
  /// skipped so a partial-write tail doesn't break the whole read.
  static Future<List<DepthMetaEntry>> read(String path) async {
    final f = File(path);
    if (!await f.exists()) return const <DepthMetaEntry>[];
    final lines = await f.readAsLines();
    final out = <DepthMetaEntry>[];
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final obj = jsonDecode(line) as Map<String, dynamic>;
        out.add(DepthMetaEntry.fromJson(obj));
      } catch (_) {
        // skip malformed
      }
    }
    return out;
  }

  /// Build a frame-keyed map. O(n) over the entries; W3 readers prefer
  /// this for fast `isFrameSkipped(int)` lookups.
  static Future<Map<int, DepthMetaEntry>> readMap(String path) async {
    final list = await read(path);
    return {for (final e in list) e.frame: e};
  }

  /// Append a single entry. The sidecar is opened in append-only mode
  /// so concurrent appenders from multiple frames produce a valid file
  /// even if they interleave (each line is its own atomic write).
  static Future<void> append(String path, DepthMetaEntry entry) async {
    final f = File(path);
    final sink = f.openWrite(mode: FileMode.append);
    sink.writeln(jsonEncode(entry.toJson()));
    await sink.flush();
    await sink.close();
  }

  /// Overwrite the whole sidecar with a fresh list. Used after a full
  /// re-inference pass (e.g. threshold change or model swap).
  static Future<void> writeAll(
    String path,
    Iterable<DepthMetaEntry> entries,
  ) async {
    final f = File(path);
    final sink = f.openWrite();
    for (final e in entries) {
      sink.writeln(jsonEncode(e.toJson()));
    }
    await sink.flush();
    await sink.close();
  }

  /// Quick lookup for W3 pointcloud / 3DGS stages: given the in-memory
  /// map from [readMap], should this frame's depth contribute? A
  /// missing entry means "not yet inferred — process normally"; only
  /// `skip: true` excludes the frame.
  static bool isFrameSkipped(Map<int, DepthMetaEntry> map, int frame) {
    final entry = map[frame];
    return entry?.skip ?? false;
  }
}
