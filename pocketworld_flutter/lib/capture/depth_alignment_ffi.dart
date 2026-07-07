// Native bridge for P0/P1/P2 metric-depth algorithms in aether_cpp.
//
// P0/P1:
//   aether_scale_align_adaptive
//     robust DA3-relative-depth -> metric-depth affine fit, with
//     session/chunk priors and continuous reliability.
//
// P2:
//   aether_sparse_depth_prior_refine
//     converts a DA3 relative-depth map into metric depth and diffuses sparse
//     metric anchor residuals into a local correction field.

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../aether_ffi.dart';
import 'depth_meta.dart';

class DepthAlignmentFfiError implements Exception {
  final String message;
  const DepthAlignmentFfiError(this.message);

  @override
  String toString() => 'DepthAlignmentFfiError: $message';
}

final class _ScaleAlignResultRaw extends Struct {
  @Float()
  external double scale;

  @Float()
  external double translation;

  @Float()
  external double rmse;

  @Int32()
  external int nUsed;

  @Int32()
  external int nInput;

  @Int32()
  external int ok;
}

final class _ScaleAlignOptionsRaw extends Struct {
  @Float()
  external double inlierDistM;

  @Float()
  external double priorScale;

  @Float()
  external double priorTranslation;

  @Int32()
  external int minAnchors;

  @Int32()
  external int goodAnchors;

  @Float()
  external double minDepthSpanM;

  @Float()
  external double goodDepthSpanM;

  @Float()
  external double goodRmseM;

  @Float()
  external double maxRmseM;

  @Float()
  external double minInlierRatio;

  @Float()
  external double goodInlierRatio;

  @Float()
  external double translationFitGain;

  @Float()
  external double maxTranslationDeltaM;
}

final class _ScaleAlignAdaptiveResultRaw extends Struct {
  external _ScaleAlignResultRaw raw;

  @Float()
  external double scale;

  @Float()
  external double translation;

  @Float()
  external double reliability;

  @Float()
  external double inlierRatio;

  @Float()
  external double aiDepthSpan;

  @Float()
  external double metricDepthSpan;

  @Float()
  external double scalePriorWeight;

  @Float()
  external double translationPriorWeight;

  @Int32()
  external int usedPrior;
}

final class _SparseDepthPriorOptionsRaw extends Struct {
  external _ScaleAlignOptionsRaw align;

  @Float()
  external double residualSigmaPx;

  @Float()
  external double residualClipM;

  @Float()
  external double residualGain;

  @Float()
  external double minMetricDepthM;

  @Float()
  external double maxMetricDepthM;

  @Float()
  external double confLow;

  @Float()
  external double confHigh;

  @Int32()
  external int maxResidualPoints;
}

final class _SparseDepthPriorResultRaw extends Struct {
  external _ScaleAlignAdaptiveResultRaw alignment;

  @Int32()
  external int sparseInput;

  @Int32()
  external int sparseUsed;

  @Float()
  external double meanAbsResidualM;

  @Float()
  external double maxAbsResidualM;

  @Int32()
  external int ok;
}

typedef _ScaleAlignAdaptiveNative =
    Int32 Function(
      Pointer<Float>,
      Pointer<Float>,
      Int32,
      Pointer<_ScaleAlignOptionsRaw>,
      Pointer<_ScaleAlignAdaptiveResultRaw>,
    );
typedef _ScaleAlignAdaptiveDart =
    int Function(
      Pointer<Float>,
      Pointer<Float>,
      int,
      Pointer<_ScaleAlignOptionsRaw>,
      Pointer<_ScaleAlignAdaptiveResultRaw>,
    );

typedef _SparseDepthPriorRefineNative =
    Int32 Function(
      Pointer<Float>,
      Pointer<Float>,
      Int32,
      Int32,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      Int32,
      Pointer<_SparseDepthPriorOptionsRaw>,
      Pointer<Float>,
      Pointer<_SparseDepthPriorResultRaw>,
    );
typedef _SparseDepthPriorRefineDart =
    int Function(
      Pointer<Float>,
      Pointer<Float>,
      int,
      int,
      Pointer<Float>,
      Pointer<Float>,
      Pointer<Float>,
      int,
      Pointer<_SparseDepthPriorOptionsRaw>,
      Pointer<Float>,
      Pointer<_SparseDepthPriorResultRaw>,
    );

class ScaleAlignRawResult {
  final double scale;
  final double translation;
  final double rmse;
  final int nUsed;
  final int nInput;
  final bool ok;

  const ScaleAlignRawResult({
    required this.scale,
    required this.translation,
    required this.rmse,
    required this.nUsed,
    required this.nInput,
    required this.ok,
  });

  factory ScaleAlignRawResult._fromRaw(_ScaleAlignResultRaw raw) {
    return ScaleAlignRawResult(
      scale: raw.scale,
      translation: raw.translation,
      rmse: raw.rmse,
      nUsed: raw.nUsed,
      nInput: raw.nInput,
      ok: raw.ok != 0,
    );
  }
}

class ScaleAlignOptions {
  final double inlierDistM;
  final double priorScale;
  final double priorTranslation;
  final int minAnchors;
  final int goodAnchors;
  final double minDepthSpanM;
  final double goodDepthSpanM;
  final double goodRmseM;
  final double maxRmseM;
  final double minInlierRatio;
  final double goodInlierRatio;
  final double translationFitGain;
  final double maxTranslationDeltaM;

  const ScaleAlignOptions({
    this.inlierDistM = 0.05,
    this.priorScale = 1.0,
    this.priorTranslation = 0.0,
    this.minAnchors = 8,
    this.goodAnchors = 60,
    this.minDepthSpanM = 0.08,
    this.goodDepthSpanM = 0.50,
    this.goodRmseM = 0.015,
    this.maxRmseM = 0.080,
    this.minInlierRatio = 0.35,
    this.goodInlierRatio = 0.80,
    this.translationFitGain = 0.35,
    this.maxTranslationDeltaM = 0.25,
  });

  void _writeTo(_ScaleAlignOptionsRaw raw) {
    raw.inlierDistM = inlierDistM;
    raw.priorScale = priorScale;
    raw.priorTranslation = priorTranslation;
    raw.minAnchors = minAnchors;
    raw.goodAnchors = goodAnchors;
    raw.minDepthSpanM = minDepthSpanM;
    raw.goodDepthSpanM = goodDepthSpanM;
    raw.goodRmseM = goodRmseM;
    raw.maxRmseM = maxRmseM;
    raw.minInlierRatio = minInlierRatio;
    raw.goodInlierRatio = goodInlierRatio;
    raw.translationFitGain = translationFitGain;
    raw.maxTranslationDeltaM = maxTranslationDeltaM;
  }
}

class ScaleAlignAdaptiveResult {
  final ScaleAlignRawResult raw;
  final double scale;
  final double translation;
  final double reliability;
  final double inlierRatio;
  final double aiDepthSpan;
  final double metricDepthSpan;
  final double scalePriorWeight;
  final double translationPriorWeight;
  final bool usedPrior;

  const ScaleAlignAdaptiveResult({
    required this.raw,
    required this.scale,
    required this.translation,
    required this.reliability,
    required this.inlierRatio,
    required this.aiDepthSpan,
    required this.metricDepthSpan,
    required this.scalePriorWeight,
    required this.translationPriorWeight,
    required this.usedPrior,
  });

  factory ScaleAlignAdaptiveResult._fromRaw(_ScaleAlignAdaptiveResultRaw raw) {
    return ScaleAlignAdaptiveResult(
      raw: ScaleAlignRawResult._fromRaw(raw.raw),
      scale: raw.scale,
      translation: raw.translation,
      reliability: raw.reliability,
      inlierRatio: raw.inlierRatio,
      aiDepthSpan: raw.aiDepthSpan,
      metricDepthSpan: raw.metricDepthSpan,
      scalePriorWeight: raw.scalePriorWeight,
      translationPriorWeight: raw.translationPriorWeight,
      usedPrior: raw.usedPrior != 0,
    );
  }
}

class SparseDepthPriorOptions {
  final ScaleAlignOptions align;
  final double residualSigmaPx;
  final double residualClipM;
  final double residualGain;
  final double minMetricDepthM;
  final double maxMetricDepthM;
  final double confLow;
  final double confHigh;
  final int maxResidualPoints;

  const SparseDepthPriorOptions({
    this.align = const ScaleAlignOptions(),
    this.residualSigmaPx = 48.0,
    this.residualClipM = 0.20,
    this.residualGain = 0.65,
    this.minMetricDepthM = 0.05,
    this.maxMetricDepthM = 8.0,
    this.confLow = 1.0,
    this.confHigh = 8.0,
    this.maxResidualPoints = 96,
  });

  void _writeTo(_SparseDepthPriorOptionsRaw raw) {
    align._writeTo(raw.align);
    raw.residualSigmaPx = residualSigmaPx;
    raw.residualClipM = residualClipM;
    raw.residualGain = residualGain;
    raw.minMetricDepthM = minMetricDepthM;
    raw.maxMetricDepthM = maxMetricDepthM;
    raw.confLow = confLow;
    raw.confHigh = confHigh;
    raw.maxResidualPoints = maxResidualPoints;
  }
}

class SparseDepthPriorResult {
  final ScaleAlignAdaptiveResult alignment;
  final int sparseInput;
  final int sparseUsed;
  final double meanAbsResidualM;
  final double maxAbsResidualM;
  final bool ok;

  const SparseDepthPriorResult({
    required this.alignment,
    required this.sparseInput,
    required this.sparseUsed,
    required this.meanAbsResidualM,
    required this.maxAbsResidualM,
    required this.ok,
  });

  factory SparseDepthPriorResult._fromRaw(_SparseDepthPriorResultRaw raw) {
    return SparseDepthPriorResult(
      alignment: ScaleAlignAdaptiveResult._fromRaw(raw.alignment),
      sparseInput: raw.sparseInput,
      sparseUsed: raw.sparseUsed,
      meanAbsResidualM: raw.meanAbsResidualM,
      maxAbsResidualM: raw.maxAbsResidualM,
      ok: raw.ok != 0,
    );
  }
}

class SparseDepthPriorOutput {
  final Float32List metricDepth;
  final SparseDepthPriorResult result;

  const SparseDepthPriorOutput({
    required this.metricDepth,
    required this.result,
  });
}

extension ScaleAlignAdaptiveResultDepthMeta on ScaleAlignAdaptiveResult {
  DepthMetaEntry mergeIntoDepthMeta(
    DepthMetaEntry entry, {
    String mode = kDepthAlignModeSessionChunkAdaptive,
    String? metricDepthPath,
  }) {
    return entry.copyWith(
      metricDepthPath: metricDepthPath,
      alignMode: mode,
      alignScale: scale,
      alignTranslation: translation,
      alignReliability: reliability,
      alignRmse: raw.rmse,
      alignInlierRatio: inlierRatio,
      alignAiDepthSpan: aiDepthSpan,
      alignMetricDepthSpan: metricDepthSpan,
      alignScalePriorWeight: scalePriorWeight,
      alignTranslationPriorWeight: translationPriorWeight,
      alignAnchorCount: raw.nInput,
      alignAnchorUsed: raw.nUsed,
      alignUsedPrior: usedPrior,
    );
  }
}

extension SparseDepthPriorResultDepthMeta on SparseDepthPriorResult {
  DepthMetaEntry mergeIntoDepthMeta(
    DepthMetaEntry entry, {
    String alignMode = kDepthAlignModeSessionChunkAdaptive,
    String? metricDepthPath,
  }) {
    return alignment
        .mergeIntoDepthMeta(
          entry,
          mode: alignMode,
          metricDepthPath: metricDepthPath,
        )
        .copyWith(
          sparsePriorMode: kSparsePriorModeResidualField,
          sparsePriorUsed: ok,
          sparsePriorAnchorCount: sparseInput,
          sparsePriorAnchorUsed: sparseUsed,
          sparsePriorMeanAbsResidualM: meanAbsResidualM,
          sparsePriorMaxAbsResidualM: maxAbsResidualM,
        );
  }
}

class DepthAlignmentFfi {
  DepthAlignmentFfi._();

  static DynamicLibrary? _lib;
  static _ScaleAlignAdaptiveDart? _scaleAlignAdaptive;
  static _SparseDepthPriorRefineDart? _sparseDepthPriorRefine;

  static DynamicLibrary _resolveLibrary() {
    return _lib ??= AetherFfi.resolveLibraryForBindings();
  }

  static _ScaleAlignAdaptiveDart _resolveScaleAlignAdaptive() {
    return _scaleAlignAdaptive ??= _resolveLibrary()
        .lookupFunction<_ScaleAlignAdaptiveNative, _ScaleAlignAdaptiveDart>(
          'aether_scale_align_adaptive',
        );
  }

  static _SparseDepthPriorRefineDart _resolveSparseDepthPriorRefine() {
    return _sparseDepthPriorRefine ??= _resolveLibrary()
        .lookupFunction<
          _SparseDepthPriorRefineNative,
          _SparseDepthPriorRefineDart
        >('aether_sparse_depth_prior_refine');
  }

  static Float32List _asFloat32(List<double> values) {
    return values is Float32List ? values : Float32List.fromList(values);
  }

  static Pointer<Float> _copyFloats(Float32List values) {
    final ptr = calloc<Float>(values.length);
    ptr.asTypedList(values.length).setAll(0, values);
    return ptr;
  }

  /// P0/P1 adaptive alignment over either a session/chunk anchor set or one
  /// frame's fallback anchor set.
  static ScaleAlignAdaptiveResult scaleAlignAdaptive({
    required List<double> zAi,
    required List<double> zMetric,
    ScaleAlignOptions options = const ScaleAlignOptions(),
  }) {
    if (zAi.length != zMetric.length) {
      throw DepthAlignmentFfiError(
        'zAi/zMetric length mismatch: ${zAi.length} vs ${zMetric.length}',
      );
    }
    final n = zAi.length;
    final zAi32 = _asFloat32(zAi);
    final zMetric32 = _asFloat32(zMetric);
    final zAiPtr = _copyFloats(zAi32);
    final zMetricPtr = _copyFloats(zMetric32);
    final optionsPtr = calloc<_ScaleAlignOptionsRaw>();
    final resultPtr = calloc<_ScaleAlignAdaptiveResultRaw>();

    try {
      options._writeTo(optionsPtr.ref);
      final rc = _resolveScaleAlignAdaptive()(
        zAiPtr,
        zMetricPtr,
        n,
        optionsPtr,
        resultPtr,
      );
      if (rc != 0) {
        throw DepthAlignmentFfiError(
          'aether_scale_align_adaptive failed rc=$rc',
        );
      }
      return ScaleAlignAdaptiveResult._fromRaw(resultPtr.ref);
    } finally {
      calloc.free(resultPtr);
      calloc.free(optionsPtr);
      calloc.free(zMetricPtr);
      calloc.free(zAiPtr);
    }
  }

  /// P2 sparse-prior refinement. Returns a metric-depth buffer in row-major
  /// order with the same width/height as [relativeDepth].
  static SparseDepthPriorOutput refineSparsePrior({
    required Float32List relativeDepth,
    Float32List? conf,
    required int width,
    required int height,
    required List<double> sparseU,
    required List<double> sparseV,
    required List<double> sparseMetricDepth,
    SparseDepthPriorOptions options = const SparseDepthPriorOptions(),
  }) {
    final pixelCount = width * height;
    if (width <= 0 || height <= 0 || relativeDepth.length != pixelCount) {
      throw DepthAlignmentFfiError(
        'invalid depth shape: $width x $height, len=${relativeDepth.length}',
      );
    }
    if (conf != null && conf.length != pixelCount) {
      throw DepthAlignmentFfiError(
        'conf length ${conf.length} != depth length $pixelCount',
      );
    }
    if (sparseU.length != sparseV.length ||
        sparseU.length != sparseMetricDepth.length) {
      throw DepthAlignmentFfiError(
        'sparse arrays must have equal length: '
        'u=${sparseU.length} v=${sparseV.length} '
        'depth=${sparseMetricDepth.length}',
      );
    }

    final sparseCount = sparseU.length;
    final relativePtr = _copyFloats(relativeDepth);
    final confPtr = conf == null ? nullptr : _copyFloats(conf);
    final uPtr = _copyFloats(_asFloat32(sparseU));
    final vPtr = _copyFloats(_asFloat32(sparseV));
    final metricPtr = _copyFloats(_asFloat32(sparseMetricDepth));
    final optionsPtr = calloc<_SparseDepthPriorOptionsRaw>();
    final outPtr = calloc<Float>(pixelCount);
    final resultPtr = calloc<_SparseDepthPriorResultRaw>();

    try {
      options._writeTo(optionsPtr.ref);
      final rc = _resolveSparseDepthPriorRefine()(
        relativePtr,
        confPtr,
        width,
        height,
        uPtr,
        vPtr,
        metricPtr,
        sparseCount,
        optionsPtr,
        outPtr,
        resultPtr,
      );
      if (rc != 0) {
        throw DepthAlignmentFfiError(
          'aether_sparse_depth_prior_refine failed rc=$rc',
        );
      }
      return SparseDepthPriorOutput(
        metricDepth: Float32List.fromList(outPtr.asTypedList(pixelCount)),
        result: SparseDepthPriorResult._fromRaw(resultPtr.ref),
      );
    } finally {
      calloc.free(resultPtr);
      calloc.free(outPtr);
      calloc.free(optionsPtr);
      calloc.free(metricPtr);
      calloc.free(vPtr);
      calloc.free(uPtr);
      if (confPtr != nullptr) calloc.free(confPtr);
      calloc.free(relativePtr);
    }
  }
}
