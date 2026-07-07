// material_classifier.dart
//
// SigLIP-base zero-shot binary reflective/diffuse material classifier.
// Cross-platform Dart facade over native ML inference. Used by capture flow
// as material telemetry/preflight. DA3 model selection is owned by
// ModelLoader/AetherModelPolicy and stays on commercial-safe DA3-BASE tiers.
//
// Native side (iOS): ios/Runner/MaterialClassifierPlugin.swift
//   SigLIP vision encoder CoreML mlpackage + pre-computed 6-prompt text
//   embeddings JSON. ODR `tier:high` group, downloaded with the high-tier
//   local model stack.
//
// Native side (Android / HarmonyOS / Web): TODO — same MethodChannel API,
// runtime-specific (TFLite GPU delegate for SD8 Gen 5 NPU / MindSpore Lite
// for Kirin / ORT-WebGPU). Stubs throw NOT_IMPLEMENTED until ported.
//
// Grounded numbers (Mac CoreML fp16, 2026-05-20 spike):
//   - AUC 0.997 on Ref-NeRF Shiny Blender + NeRF Synthetic lego
//   - 0 false positives at threshold 0.5
//   - 75% recall — 15/60 reflective frames slip to default material handling
//   - 40 ms / image Mac CPU_ONLY → estimate ~44 ms iPhone 14 Pro CPU

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum MaterialDescriptorLabel { reflective, diffuse, unknown }

String materialDescriptorLabelName(MaterialDescriptorLabel label) {
  switch (label) {
    case MaterialDescriptorLabel.reflective:
      return 'reflective';
    case MaterialDescriptorLabel.diffuse:
      return 'diffuse';
    case MaterialDescriptorLabel.unknown:
      return 'unknown';
  }
}

/// Dart-owned material policy. Native executors must not own thresholds,
/// prompt-set selection, cache scope, or highlight/downstream semantics.
@immutable
class MaterialDescriptorSpec {
  const MaterialDescriptorSpec({
    this.schemaVersion = 'aether_material_descriptor_spec_v1',
    this.promptSetVersion = 'siglip_reflective_diffuse_v1',
    this.reflectiveThreshold = 0.5,
    this.cacheScope = 'capture_session',
    this.highlightPolicyRole = 'reflective_risk_hint_only',
  });

  static const defaultSpec = MaterialDescriptorSpec();

  final String schemaVersion;
  final String promptSetVersion;
  final double reflectiveThreshold;
  final String cacheScope;
  final String highlightPolicyRole;

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'algorithm_executor_boundary': {
      'schemaVersion': 'aether_algorithm_executor_boundary_v1',
      'hardRule':
          'Dart sealed spec -> thin executor -> Dart report/audit -> next stage',
      'policyOwner': 'Flutter/Dart',
      'executorRole': 'thin_executor_only',
      'dartOwns': [
        'prompt-set version',
        'reflective threshold',
        'cache scope',
        'when material telemetry is sampled',
        'how material risk influences highlight strategy',
      ],
      'executorOwns': [
        'model load',
        'image tensor preprocessing required by the sealed model',
        'SigLIP/CoreML forward pass',
        'raw score and inference telemetry',
      ],
      'executorMustNotOwn': [
        'reflective/diffuse decision threshold',
        'capture acceptance gates',
        'highlight policy',
        'product state',
      ],
    },
    'prompt_set_version': promptSetVersion,
    'reflective_threshold': reflectiveThreshold,
    'cache_scope': cacheScope,
    'highlight_policy_role': highlightPolicyRole,
  };
}

/// Raw native score from one SigLIP forward pass.
///
/// This is deliberately not the material decision. Thresholding and
/// highlight meaning live in [MaterialDescriptorSpec].
@immutable
class MaterialRawScore {
  const MaterialRawScore({required this.pReflective, required this.inferMs});

  /// P(reflective) ∈ [0, 1]. Default decision threshold is 0.5.
  final double pReflective;

  /// Native-side inference time (vision encoder forward + dot product +
  /// sigmoid scoring). Logged for telemetry; capture flow doesn't gate on
  /// this value.
  final double inferMs;

  bool isReflective({double threshold = 0.5}) => pReflective > threshold;

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_material_raw_score_v1',
    'p_reflective': pReflective,
    'infer_ms': inferMs,
  };

  @override
  String toString() =>
      'MaterialRawScore(p_reflective=$pReflective, '
      'infer_ms=${inferMs.toStringAsFixed(1)})';
}

/// Backwards-compatible name for older capture code.
typedef MaterialClassification = MaterialRawScore;

@immutable
class MaterialDescriptorReport {
  const MaterialDescriptorReport({
    required this.spec,
    required this.raw,
    required this.label,
    required this.status,
  });

  final MaterialDescriptorSpec spec;
  final MaterialRawScore? raw;
  final MaterialDescriptorLabel label;
  final String status;

  bool get isReflective => label == MaterialDescriptorLabel.reflective;

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_material_descriptor_report_v1',
    'status': status,
    'spec': spec.toJson(),
    'label': materialDescriptorLabelName(label),
    if (raw != null) 'raw_classification': raw!.toJson(),
    'decision': {
      'threshold_owner': 'Flutter/Dart',
      'p_reflective': raw?.pReflective,
      'reflective_threshold': spec.reflectiveThreshold,
      'highlight_policy_role': spec.highlightPolicyRole,
    },
  };
}

abstract class MaterialRawScoreExecutor {
  const MaterialRawScoreExecutor();

  Future<void> warmup();

  Future<MaterialRawScore?> score({
    required Uint8List rgba,
    required int width,
    required int height,
  });

  MaterialRawScore? get cachedRawScore;
}

abstract class MaterialDescriptorExecutor {
  const MaterialDescriptorExecutor();

  Future<MaterialDescriptorReport> describe({
    required Uint8List rgba,
    required int width,
    required int height,
    MaterialDescriptorSpec spec = const MaterialDescriptorSpec(),
  });
}

/// Thrown when the native side reports a model-load or inference failure.
class MaterialClassifierException implements Exception {
  const MaterialClassifierException(this.message, {this.cause});
  final String message;
  final Object? cause;
  @override
  String toString() =>
      'MaterialClassifierException: $message'
      '${cause == null ? '' : ' (cause: $cause)'}';
}

/// Thin platform executor. It only asks native for raw score + telemetry.
class MethodChannelMaterialRawScoreExecutor extends MaterialRawScoreExecutor {
  MethodChannelMaterialRawScoreExecutor({
    MethodChannel channel = const MethodChannel(
      'pocketworld/material_classifier',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;
  MaterialRawScore? _cachedRawScore;

  @override
  MaterialRawScore? get cachedRawScore => _cachedRawScore;

  /// Future for an in-flight warmup, used to deduplicate concurrent calls.
  Future<void>? _warmupFuture;

  /// Trigger model load on the native side. Call at app launch or capture
  /// page mount so the first real classify() doesn't pay the ~600 ms load
  /// cost. Idempotent + safe to call repeatedly.
  @override
  Future<void> warmup() {
    final existing = _warmupFuture;
    if (existing != null) return existing;
    final fresh = _doWarmup();
    _warmupFuture = fresh;
    return fresh;
  }

  Future<void> _doWarmup() async {
    try {
      await _channel.invokeMethod<Map<dynamic, dynamic>>('warmup');
    } on MissingPluginException {
      // No native impl on this platform yet (Android / Web / HarmonyOS) —
      // do nothing. classify() will return null and capture continues without
      // a material hint.
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('[MaterialRawScoreExecutor] warmup failed: ${e.message}');
    }
  }

  /// Score a single RGBA frame.
  ///
  /// [rgba] is row-major RGBA uint8 (`width * height * 4` bytes). Any size
  /// is accepted; native resizes to 224×224 via SigLIP's standard pipeline.
  ///
  /// Returns null if the native plugin is missing (platform without
  /// implementation).
  @override
  Future<MaterialRawScore?> score({
    required Uint8List rgba,
    required int width,
    required int height,
  }) async {
    final expected = width * height * 4;
    if (rgba.length != expected) {
      throw ArgumentError(
        'rgba.length=${rgba.length} does not match width*height*4=$expected',
      );
    }
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'classify',
        <String, dynamic>{'rgba': rgba, 'width': width, 'height': height},
      );
      if (result == null) return null;
      final p = (result['p_reflective'] as num?)?.toDouble();
      final ms = (result['infer_ms'] as num?)?.toDouble();
      if (p == null || ms == null) {
        throw const MaterialClassifierException(
          'native raw score executor returned malformed result',
        );
      }
      final m = MaterialRawScore(pReflective: p, inferMs: ms);
      _cachedRawScore = m;
      return m;
    } on MissingPluginException {
      // Plugin missing — descriptor policy decides how to degrade.
      return null;
    } on PlatformException catch (e) {
      throw MaterialClassifierException(
        e.message ?? 'raw score failed',
        cause: e,
      );
    }
  }
}

/// Dart policy executor: raw score in, material report out.
class DartMaterialDescriptorExecutor extends MaterialDescriptorExecutor {
  DartMaterialDescriptorExecutor({
    required MaterialRawScoreExecutor rawExecutor,
  }) : _rawExecutor = rawExecutor;

  final MaterialRawScoreExecutor _rawExecutor;
  MaterialDescriptorReport? _cachedDescriptor;

  MaterialDescriptorReport? get cachedDescriptor => _cachedDescriptor;

  @override
  Future<MaterialDescriptorReport> describe({
    required Uint8List rgba,
    required int width,
    required int height,
    MaterialDescriptorSpec spec = const MaterialDescriptorSpec(),
  }) async {
    final raw = await _rawExecutor.score(
      rgba: rgba,
      width: width,
      height: height,
    );
    final report = raw == null
        ? MaterialDescriptorReport(
            spec: spec,
            raw: null,
            label: MaterialDescriptorLabel.unknown,
            status: 'native_executor_unavailable',
          )
        : MaterialDescriptorReport(
            spec: spec,
            raw: raw,
            label: raw.isReflective(threshold: spec.reflectiveThreshold)
                ? MaterialDescriptorLabel.reflective
                : MaterialDescriptorLabel.diffuse,
            status: 'completed',
          );
    _cachedDescriptor = report;
    return report;
  }

  void resetCache() {
    _cachedDescriptor = null;
  }
}

/// Backwards-compatible singleton facade. Policy still lives in Dart:
/// [MethodChannelMaterialRawScoreExecutor] gets raw numbers from native, then
/// [DartMaterialDescriptorExecutor] applies [MaterialDescriptorSpec].
class MaterialClassifier implements MaterialDescriptorExecutor {
  MaterialClassifier._()
    : _rawExecutor = MethodChannelMaterialRawScoreExecutor() {
    _descriptorExecutor = DartMaterialDescriptorExecutor(
      rawExecutor: _rawExecutor,
    );
  }

  static final MaterialClassifier instance = MaterialClassifier._();

  final MethodChannelMaterialRawScoreExecutor _rawExecutor;
  late final DartMaterialDescriptorExecutor _descriptorExecutor;

  MaterialClassification? get cached => _rawExecutor.cachedRawScore;
  MaterialDescriptorReport? get cachedDescriptor =>
      _descriptorExecutor.cachedDescriptor;

  Future<void> warmup() => _rawExecutor.warmup();

  Future<MaterialClassification?> classify({
    required Uint8List rgba,
    required int width,
    required int height,
  }) {
    return _rawExecutor.score(rgba: rgba, width: width, height: height);
  }

  @override
  Future<MaterialDescriptorReport> describe({
    required Uint8List rgba,
    required int width,
    required int height,
    MaterialDescriptorSpec spec = const MaterialDescriptorSpec(),
  }) {
    return _descriptorExecutor.describe(
      rgba: rgba,
      width: width,
      height: height,
      spec: spec,
    );
  }

  /// Synchronous helper for capture flow: returns previously cached result
  /// if available, else null. Use when you've already classified the first
  /// frame of this capture session and want to dispatch model loading
  /// without re-running the classifier.
  bool? isReflectiveCached({double threshold = 0.5}) {
    final c = _rawExecutor.cachedRawScore;
    if (c == null) return null;
    return c.isReflective(threshold: threshold);
  }

  /// Reset the cached classification — called between capture sessions so
  /// the next session re-evaluates the scene.
  void resetCache() {
    _rawExecutor._cachedRawScore = null;
    _descriptorExecutor.resetCache();
  }
}
