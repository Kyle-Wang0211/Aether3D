// Plan G W6 D1: local pipeline orchestrator.
//
// Drives the post-capture stages (Stage 1 Depth → Stage 5 Compress) on
// device. Each stage:
//   - Reads checkpoint from disk: skip if already complete.
//   - Performs work, writes its output(s) under
//     `<captureDir>/stages/<stageName>/`.
//   - Writes a `done.json` checkpoint marker on success.
//   - On error: emits PipelineErrorEvent, leaves partial state so
//     retry-from-disk works (caller can wipe stages/<name>/ to force
//     a single-stage rerun).
//
// Lifecycle:
//   final runner = LocalPipelineRunner(captureDir: capDir);
//   runner.stream.listen((event) => updateUiProgress(event));
//   await runner.run();   // chains all 5 stages serially
//
// Per-stage abstraction lets W7 substitute "quick preview" mode that
// runs a subset (e.g. Stage 1+2 only with BallPivoting fallback for a
// 30-60 s preview mesh).
//
// Algorithm executor boundary:
//   - Every new algorithm stage must start with a Dart sealed spec plus
//     a Dart report/audit schema.
//   - Swift/CUDA/C++/Metal/FFI may only be a thin executor for hardware
//     access, inference, kernels, encoding, and telemetry probes.
//   - Product policy, quality gates, naming, cache strategy, windowing,
//     thresholds, and downstream handoff stay in Dart.
// See docs/ALGORITHM_EXECUTOR_BOUNDARY.md.
//
// What this file is NOT (yet):
//   - W6 D2/D3 thermal + memory monitors are not wired here yet.
//     Hooks live as `// TODO(W6 D2)` and `// TODO(W6 D3)` comments
//     between stage steps.
//   - W3 / W4 / W5 native FFI is stubbed; each Stage*Runner has a
//     `// TODO(W3/W4/W5 ...)` marker where the real FFI lands.
//   - UI wiring (capture_session.dart, main.dart) is W7.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:aether_capture_services/aether_capture_services.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image;

import '../capture/depth_meta.dart';
import 'geometry_verification.dart';
import 'metric_depth_alignment.dart';

// ─── Public types ───────────────────────────────────────────────────

/// The five post-capture stages, in execution order.
///
/// Stage 1 depth consumes the photo bundle's `photosHighresDir`, or the
/// legacy `<captureDir>/photos/` directory when no bundle manifest exists.
/// Subsequent stages consume the previous stage's output dir.
enum PipelineStage {
  /// DA3-BASE K35 official image-only depth/conf/pose outputs plus a
  /// single `depth_index.json` enumerating geometry outputs.
  depth,

  /// Depth + intrinsics + per-photo extrinsics → world-space points →
  /// voxel-dedup → `pointcloud.ply`.
  pointcloud,

  /// PoissonRecon V18.76 → `mesh.ply` (water-tight surface).
  mesh,

  /// xatlas UV unwrap + atlas bake from photos → `mesh.obj` +
  /// `atlas.png`.
  texture,

  /// meshoptimizer simplify + KTX2 texture compress → final
  /// `output.glb`.
  compress,
}

/// Human-readable lowercase name for the stage (also used as the on-disk
/// directory name under `<captureDir>/stages/`).
String pipelineStageName(PipelineStage s) {
  switch (s) {
    case PipelineStage.depth:
      return 'depth';
    case PipelineStage.pointcloud:
      return 'pointcloud';
    case PipelineStage.mesh:
      return 'mesh';
    case PipelineStage.texture:
      return 'texture';
    case PipelineStage.compress:
      return 'compress';
  }
}

/// Snapshot of progress within a single stage.
///
/// `stageFraction` is the within-stage 0..1 fraction (e.g. fraction of
/// depth-frames processed). `overallFraction` is `(stageIndex +
/// stageFraction) / totalStages` — a simple linear blend that's
/// sufficient for UI progress-bar work without per-stage weighting.
class PipelineProgress {
  final PipelineStage stage;

  /// 0..1 within the current stage.
  final double stageFraction;

  /// 0..1 across the entire 5-stage pipeline.
  final double overallFraction;

  /// Optional human string for diagnostics ("depth 47/118",
  /// "skipped (cached)", "writing point cloud").
  final String? detail;

  /// Wall-clock elapsed since `LocalPipelineRunner.run()` was awaited.
  final Duration elapsed;

  const PipelineProgress({
    required this.stage,
    required this.stageFraction,
    required this.overallFraction,
    required this.elapsed,
    this.detail,
  });

  @override
  String toString() =>
      'PipelineProgress(${pipelineStageName(stage)} '
      'stage=${stageFraction.toStringAsFixed(2)} '
      'overall=${overallFraction.toStringAsFixed(2)} '
      'detail=$detail elapsed=${elapsed.inMilliseconds} ms)';
}

/// A stage failed.
///
/// `isRetryable` is the runner's best guess at whether the caller can
/// re-invoke `run()` and expect a different outcome (e.g. transient
/// disk-full vs. malformed input). The W6 D2/D3 monitors will fold
/// thermal-abort and OOM-abort into this code in their own diff.
class PipelineError {
  final PipelineStage stage;

  /// Short machine-readable code (`stage_threw`, `thermal_critical`,
  /// `oom_aborted`, etc.).
  final String code;

  /// Human-readable detail; safe to surface to a `Text()` widget.
  final String message;

  final bool isRetryable;

  const PipelineError({
    required this.stage,
    required this.code,
    required this.message,
    required this.isRetryable,
  });

  @override
  String toString() =>
      'PipelineError(${pipelineStageName(stage)} $code: $message '
      'retryable=$isRetryable)';
}

/// Event sealed-hierarchy emitted on `LocalPipelineRunner.stream`.
///
/// Three concrete subclasses cover the full lifecycle:
///   - `PipelineProgressEvent` — repeated, 3-5 per stage + 1 per
///     skipped-stage notice.
///   - `PipelineErrorEvent` — terminal; the runner returns after
///     emitting this and does not advance to the next stage.
///   - `PipelineCompletedEvent` — terminal on success; carries the
///     final `.glb` File path + total wall-clock elapsed.
abstract class PipelineEvent {
  const PipelineEvent();
}

class PipelineProgressEvent extends PipelineEvent {
  final PipelineProgress progress;
  const PipelineProgressEvent(this.progress);

  @override
  String toString() => 'PipelineProgressEvent($progress)';
}

class PipelineErrorEvent extends PipelineEvent {
  final PipelineError error;
  const PipelineErrorEvent(this.error);

  @override
  String toString() => 'PipelineErrorEvent($error)';
}

class PipelineCompletedEvent extends PipelineEvent {
  final File outputGlb;
  final Duration totalElapsed;
  const PipelineCompletedEvent({
    required this.outputGlb,
    required this.totalElapsed,
  });

  @override
  String toString() =>
      'PipelineCompletedEvent(glb=${outputGlb.path} '
      'elapsed=${totalElapsed.inMilliseconds} ms)';
}

// ─── Device health policy ───────────────────────────────────────────

enum DeviceHealthAction { proceed, markHighRisk, pause, abort }

String deviceHealthActionName(DeviceHealthAction action) {
  switch (action) {
    case DeviceHealthAction.proceed:
      return 'proceed';
    case DeviceHealthAction.markHighRisk:
      return 'mark_high_risk';
    case DeviceHealthAction.pause:
      return 'pause';
    case DeviceHealthAction.abort:
      return 'abort';
  }
}

/// Raw device telemetry from native. Policy decisions do not live here.
class DeviceHealthSnapshot {
  const DeviceHealthSnapshot({
    required this.status,
    required this.sampledAtUtc,
    this.source = 'unknown',
    this.thermalState,
    this.rssMB,
    this.availableMemoryMB,
    this.jetsamAvailableMB,
    this.cpuDeviceNormalizedPercent,
    this.cpuOneCorePercent,
    this.raw = const <String, Object?>{},
  });

  final String status;
  final DateTime sampledAtUtc;
  final String source;
  final String? thermalState;
  final double? rssMB;
  final double? availableMemoryMB;
  final double? jetsamAvailableMB;
  final double? cpuDeviceNormalizedPercent;
  final double? cpuOneCorePercent;
  final Map<String, Object?> raw;

  static DeviceHealthSnapshot unavailable({
    String source = 'none',
    String reason = 'device health probe not configured',
  }) {
    return DeviceHealthSnapshot(
      status: 'unavailable',
      sampledAtUtc: DateTime.now().toUtc(),
      source: source,
      raw: {'reason': reason},
    );
  }

  factory DeviceHealthSnapshot.fromNative(Map<Object?, Object?> native) {
    final raw = native.map((key, value) => MapEntry('$key', value));
    final status = _asString(raw['status'], fallback: 'ok');
    return DeviceHealthSnapshot(
      status: status,
      sampledAtUtc:
          DateTime.tryParse(_asString(raw['sampledAtUtc'])) ??
          DateTime.now().toUtc(),
      source: _asString(raw['source'], fallback: 'native'),
      thermalState: _nullableString(raw['thermalState']),
      rssMB: _nullableDouble(raw['rssMB']),
      availableMemoryMB: _nullableDouble(raw['availableMemoryMB']),
      jetsamAvailableMB: _nullableDouble(raw['jetsamAvailableMB']),
      cpuDeviceNormalizedPercent: _nullableDouble(
        raw['cpuDeviceNormalizedPercent'],
      ),
      cpuOneCorePercent: _nullableDouble(raw['cpuOneCorePercent']),
      raw: raw,
    );
  }

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_device_health_snapshot_v1',
    'status': status,
    'sampled_at_utc': sampledAtUtc.toIso8601String(),
    'source': source,
    if (thermalState != null) 'thermal_state': thermalState,
    if (rssMB != null) 'rss_mb': rssMB,
    if (availableMemoryMB != null) 'available_memory_mb': availableMemoryMB,
    if (jetsamAvailableMB != null) 'jetsam_available_mb': jetsamAvailableMB,
    if (cpuDeviceNormalizedPercent != null)
      'cpu_device_normalized_percent': cpuDeviceNormalizedPercent,
    if (cpuOneCorePercent != null) 'cpu_one_core_percent': cpuOneCorePercent,
    if (raw.isNotEmpty) 'raw': raw,
  };
}

class DeviceHealthDecision {
  const DeviceHealthDecision({
    required this.action,
    required this.code,
    required this.message,
    this.pause = Duration.zero,
    this.isRetryable = true,
  });

  final DeviceHealthAction action;
  final String code;
  final String message;
  final Duration pause;
  final bool isRetryable;

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_device_health_decision_v1',
    'action': deviceHealthActionName(action),
    'code': code,
    'message': message,
    'pause_ms': pause.inMilliseconds,
    'is_retryable': isRetryable,
  };
}

abstract class DeviceHealthProbe {
  const DeviceHealthProbe();

  Future<DeviceHealthSnapshot> sample({
    required PipelineStage stage,
    required String reason,
  });
}

class NoopDeviceHealthProbe extends DeviceHealthProbe {
  const NoopDeviceHealthProbe();

  @override
  Future<DeviceHealthSnapshot> sample({
    required PipelineStage stage,
    required String reason,
  }) async {
    return DeviceHealthSnapshot.unavailable(
      source: 'noop',
      reason: 'native raw telemetry probe not installed',
    );
  }
}

/// Optional native raw telemetry bridge.
///
/// Native must only return numbers/strings. Pause/continue/abort stays in
/// [DeviceHealthPolicy].
class MethodChannelDeviceHealthProbe extends DeviceHealthProbe {
  const MethodChannelDeviceHealthProbe({
    this.channel = const MethodChannel('pocketworld/device_health'),
  });

  final MethodChannel channel;

  @override
  Future<DeviceHealthSnapshot> sample({
    required PipelineStage stage,
    required String reason,
  }) async {
    try {
      final raw = await channel.invokeMethod<Map<Object?, Object?>>(
        'sampleDeviceHealth',
        <String, Object?>{'stage': pipelineStageName(stage), 'reason': reason},
      );
      if (raw == null) {
        return DeviceHealthSnapshot.unavailable(
          source: 'method_channel',
          reason: 'native returned null',
        );
      }
      return DeviceHealthSnapshot.fromNative(raw);
    } on MissingPluginException catch (e) {
      return DeviceHealthSnapshot.unavailable(
        source: 'method_channel',
        reason: e.message ?? 'missing native device health plugin',
      );
    } on PlatformException catch (e) {
      return DeviceHealthSnapshot.unavailable(
        source: 'method_channel',
        reason: '${e.code}: ${e.message ?? 'platform exception'}',
      );
    } catch (e) {
      return DeviceHealthSnapshot.unavailable(
        source: 'method_channel',
        reason: '$e',
      );
    }
  }
}

class DeviceHealthPolicy {
  const DeviceHealthPolicy({
    this.minAvailableMemoryMB = 200,
    this.minJetsamAvailableMB = 200,
    this.pauseOnSeriousThermal = false,
    this.seriousThermalPause = const Duration(seconds: 60),
  });

  final double minAvailableMemoryMB;
  final double minJetsamAvailableMB;
  final bool pauseOnSeriousThermal;
  final Duration seriousThermalPause;

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_device_health_policy_v1',
    'owner': 'Flutter/Dart',
    'native_role': 'raw_probe_only',
    'min_available_memory_mb': minAvailableMemoryMB,
    'min_jetsam_available_mb': minJetsamAvailableMB,
    'pause_on_serious_thermal': pauseOnSeriousThermal,
    'serious_thermal_pause_ms': seriousThermalPause.inMilliseconds,
    'rules': [
      'critical thermal -> abort retryable',
      'available/jetsam memory below threshold -> abort retryable',
      'serious thermal -> mark high risk by default because DA3 real-device runs are expected to be hot',
      'unavailable probe -> proceed and record missing telemetry',
    ],
  };

  DeviceHealthDecision evaluate({
    required PipelineStage stage,
    required DeviceHealthSnapshot snapshot,
  }) {
    final thermal = snapshot.thermalState?.toLowerCase();
    if (thermal == 'critical') {
      return DeviceHealthDecision(
        action: DeviceHealthAction.abort,
        code: 'thermal_critical',
        message:
            '${pipelineStageName(stage)} blocked: native thermal state is critical',
      );
    }

    final available = snapshot.availableMemoryMB;
    if (available != null && available < minAvailableMemoryMB) {
      return DeviceHealthDecision(
        action: DeviceHealthAction.abort,
        code: 'available_memory_low',
        message:
            '${pipelineStageName(stage)} blocked: available memory ${available.toStringAsFixed(1)} MB < ${minAvailableMemoryMB.toStringAsFixed(1)} MB',
      );
    }

    final jetsam = snapshot.jetsamAvailableMB;
    if (jetsam != null && jetsam < minJetsamAvailableMB) {
      return DeviceHealthDecision(
        action: DeviceHealthAction.abort,
        code: 'jetsam_available_low',
        message:
            '${pipelineStageName(stage)} blocked: jetsam available ${jetsam.toStringAsFixed(1)} MB < ${minJetsamAvailableMB.toStringAsFixed(1)} MB',
      );
    }

    if (thermal == 'serious') {
      if (pauseOnSeriousThermal) {
        return DeviceHealthDecision(
          action: DeviceHealthAction.pause,
          code: 'thermal_serious_pause',
          message:
              '${pipelineStageName(stage)} pausing before stage: native thermal state is serious',
          pause: seriousThermalPause,
        );
      }
      return DeviceHealthDecision(
        action: DeviceHealthAction.markHighRisk,
        code: 'thermal_serious_continue',
        message:
            '${pipelineStageName(stage)} continues in serious thermal state; telemetry is recorded for audit',
      );
    }

    if (snapshot.status == 'unavailable') {
      return DeviceHealthDecision(
        action: DeviceHealthAction.proceed,
        code: 'probe_unavailable_continue',
        message:
            '${pipelineStageName(stage)} continues; native health probe unavailable',
      );
    }

    return DeviceHealthDecision(
      action: DeviceHealthAction.proceed,
      code: 'health_ok',
      message: '${pipelineStageName(stage)} device health policy passed',
    );
  }
}

// ─── Stage protocol ─────────────────────────────────────────────────

/// A single pipeline stage.
///
/// Implementations must be idempotent w.r.t. `done.json`:
///   - If `done.json` already exists, the orchestrator skips
///     [run]; [isComplete] is the source of truth.
///   - [run] writes its artifacts under [outputDir], then writes
///     `done.json` as the very last step (so a crash mid-stage leaves
///     `done.json` absent → retry will re-run from scratch).
abstract class PipelineStageRunner {
  const PipelineStageRunner();

  PipelineStage get stage;

  /// Sub-directory name under `<captureDir>/stages/`. Conventionally
  /// matches `pipelineStageName(stage)`.
  String get outputDirName;

  /// Actually do the work.
  ///
  /// `inputDir` is the previous stage's output dir, or
  /// `<captureDir>/photos/` for [PipelineStage.depth].
  /// `outputDir` is pre-created (may contain partial leftovers from a
  /// previous failed attempt; impl is responsible for clearing / over-
  /// writing). `progressSink` accepts within-stage 0..1 fractions; the
  /// orchestrator translates these into [PipelineProgressEvent]s with
  /// overall-fraction filled in.
  Future<void> run({
    required Directory inputDir,
    required Directory outputDir,
    required StreamSink<StageProgress> progressSink,
  });

  /// Default checkpoint check: presence of `done.json`.
  ///
  /// Stage impls can override (e.g. depth stage may want to verify the
  /// expected `depth_<i>_<j>.bin` count matches the photos input) but
  /// `done.json`-only is the safe default.
  Future<bool> isComplete(Directory outputDir) async {
    final marker = File('${outputDir.path}/done.json');
    return marker.existsSync();
  }

  /// Helper for impls: write the `done.json` marker as the very last
  /// step. Pass any stage-specific metadata in [extra]; the
  /// orchestrator does not consume it but human / future-stage code
  /// may.
  Future<void> writeDoneMarker(
    Directory outputDir, {
    Map<String, Object?> extra = const {},
  }) async {
    final marker = File('${outputDir.path}/done.json');
    final payload = <String, Object?>{
      'stage': pipelineStageName(stage),
      'completed_at_utc': DateTime.now().toUtc().toIso8601String(),
      'schema_version': 1,
      ...extra,
    };
    await marker.writeAsString(jsonEncode(payload), flush: true);
  }
}

/// Within-stage progress emitted by a [PipelineStageRunner.run] to its
/// internal sink. The orchestrator wraps these into
/// [PipelineProgressEvent]s on the public stream, filling in the
/// overall fraction.
class StageProgress {
  /// 0..1 within the current stage.
  final double stageFraction;

  /// Optional human-readable detail string.
  final String? detail;

  /// Optional machine-readable diagnostics for file-based trace logs.
  final Map<String, Object?> metadata;
  const StageProgress(
    this.stageFraction, [
    this.detail,
    this.metadata = const <String, Object?>{},
  ]);
}

class _PipelineTraceLog {
  _PipelineTraceLog(Directory captureDir)
    : _file = File('${captureDir.path}/pipeline_trace.jsonl');

  final File _file;

  void append(String event, Map<String, Object?> fields) {
    try {
      _file.writeAsStringSync(
        '${jsonEncode({'schema_version': 'aether_local_pipeline_trace_v1', 'event': event, 'timestamp_utc': DateTime.now().toUtc().toIso8601String(), ...fields})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Trace must never affect the pipeline itself.
    }
  }
}

// ─── DA3 depth runner contract ──────────────────────────────────────

class Da3DepthFrameSpec {
  const Da3DepthFrameSpec({
    required this.frameID,
    required this.frameIndex,
    required this.imagePath,
    required this.imageRelativePath,
    this.imageTensorFloat32ChwPath,
    this.imageTensorFloat32ChwRelativePath,
    this.sourceImagePath,
    this.sourceImageRelativePath,
    this.cameraTransform = const <double>[],
    this.intrinsics = const <double>[],
    this.cameraExtrinsicOpenCvW2c4x4 = const <double>[],
    this.cameraIntrinsic3x3 = const <double>[],
    this.imageWidth,
    this.imageHeight,
    this.timestamp,
    this.inputWidth,
    this.inputHeight,
    this.preprocessTransform = const <String, Object?>{},
  });

  final String frameID;
  final int frameIndex;
  final String imagePath;
  final String imageRelativePath;
  final String? imageTensorFloat32ChwPath;
  final String? imageTensorFloat32ChwRelativePath;
  final String? sourceImagePath;
  final String? sourceImageRelativePath;
  final List<double> cameraTransform;
  final List<double> intrinsics;
  final List<double> cameraExtrinsicOpenCvW2c4x4;
  final List<double> cameraIntrinsic3x3;
  final int? imageWidth;
  final int? imageHeight;
  final double? timestamp;
  final int? inputWidth;
  final int? inputHeight;
  final Map<String, Object?> preprocessTransform;

  Map<String, Object?> toJson() => {
    'frameID': frameID,
    'frameIndex': frameIndex,
    'imagePath': imagePath,
    'imageRelativePath': imageRelativePath,
    if (imageTensorFloat32ChwPath != null)
      'imageTensorFloat32ChwPath': imageTensorFloat32ChwPath,
    if (imageTensorFloat32ChwRelativePath != null)
      'imageTensorFloat32ChwRelativePath': imageTensorFloat32ChwRelativePath,
    if (sourceImagePath != null) 'sourceImagePath': sourceImagePath,
    if (sourceImageRelativePath != null)
      'sourceImageRelativePath': sourceImageRelativePath,
    'cameraTransform': cameraTransform,
    'intrinsics': intrinsics,
    if (cameraExtrinsicOpenCvW2c4x4.isNotEmpty)
      'cameraExtrinsicOpenCvW2c4x4': cameraExtrinsicOpenCvW2c4x4,
    if (cameraIntrinsic3x3.isNotEmpty) 'cameraIntrinsic3x3': cameraIntrinsic3x3,
    if (imageWidth != null) 'imageWidth': imageWidth,
    if (imageHeight != null) 'imageHeight': imageHeight,
    if (inputWidth != null) 'inputWidth': inputWidth,
    if (inputHeight != null) 'inputHeight': inputHeight,
    if (preprocessTransform.isNotEmpty)
      'preprocessTransform': preprocessTransform,
    if (timestamp != null) 'timestamp': timestamp,
  };
}

class Da3DepthWindowRequest {
  const Da3DepthWindowRequest({
    required this.captureDir,
    required this.outputDir,
    required this.model,
    required this.windowID,
    required this.window,
    required this.frames,
  });

  final Directory captureDir;
  final Directory outputDir;
  final Map<String, Object?> model;
  final String windowID;
  final Map<String, Object?> window;
  final List<Da3DepthFrameSpec> frames;

  Map<String, Object?> toJson() => {
    'captureDir': captureDir.path,
    'outputDir': outputDir.path,
    'model': model,
    'windowID': windowID,
    'window': window,
    'frames': frames.map((frame) => frame.toJson()).toList(growable: false),
    'inputSizePolicy': {
      'locked': model['inputWidth'] != null && model['inputHeight'] != null,
      'source': 'model_policy.json',
      'status': _asString(
        model['inputSizeStatus'],
        fallback: 'not_locked_by_policy',
      ),
      if (model['inputWidth'] != null) 'width': model['inputWidth'],
      if (model['inputHeight'] != null) 'height': model['inputHeight'],
    },
    'runtimeContract': _da3RuntimeContract(model),
  };
}

class Da3DepthFrameResult {
  const Da3DepthFrameResult({
    required this.frameID,
    required this.status,
    this.windowID,
    this.relativeDepthPath,
    this.confidencePath,
    this.metricDepthPath,
    this.predExtrinsicsPath,
    this.predIntrinsicsPath,
    this.depthWidth,
    this.depthHeight,
    this.inferenceMs,
    this.confStats,
    this.message,
  });

  final String frameID;
  final String status;
  final String? windowID;
  final String? relativeDepthPath;
  final String? confidencePath;
  final String? metricDepthPath;
  final String? predExtrinsicsPath;
  final String? predIntrinsicsPath;
  final int? depthWidth;
  final int? depthHeight;
  final double? inferenceMs;
  final DepthConfStats? confStats;
  final String? message;

  bool get isCompleted => status == 'completed';
  bool get isPending => status == 'pending';
  bool get isFailed => status == 'failed';

  Map<String, Object?> toIndexJson(Da3DepthFrameSpec? source) => {
    'frameID': frameID,
    if (source != null) 'frameIndex': source.frameIndex,
    if (source != null) 'imageRelativePath': source.imageRelativePath,
    if (windowID != null) 'windowID': windowID,
    'status': status,
    if (relativeDepthPath != null) 'relativeDepthPath': relativeDepthPath,
    if (confidencePath != null) 'confidencePath': confidencePath,
    if (metricDepthPath != null) 'metricDepthPath': metricDepthPath,
    if (predExtrinsicsPath != null) 'predExtrinsicsPath': predExtrinsicsPath,
    if (predIntrinsicsPath != null) 'predIntrinsicsPath': predIntrinsicsPath,
    if (depthWidth != null) 'depthWidth': depthWidth,
    if (depthHeight != null) 'depthHeight': depthHeight,
    if (inferenceMs != null) 'inferenceMs': inferenceMs,
    if (confStats != null) ...{
      'confMedian': confStats!.median,
      'confMean': confStats!.mean,
      'confMin': confStats!.min,
      'confMax': confStats!.max,
    },
    if (message != null) 'message': message,
  };

  static Da3DepthFrameResult pending(
    Da3DepthFrameSpec frame,
    String windowID,
    String message,
  ) {
    return Da3DepthFrameResult(
      frameID: frame.frameID,
      windowID: windowID,
      status: 'pending',
      message: message,
    );
  }

  static Da3DepthFrameResult failed(
    Da3DepthFrameSpec frame,
    String windowID,
    String message,
  ) {
    return Da3DepthFrameResult(
      frameID: frame.frameID,
      windowID: windowID,
      status: 'failed',
      message: message,
    );
  }

  static Da3DepthFrameResult fromJson(
    Map<String, Object?> json, {
    required String fallbackWindowID,
  }) {
    final stats = _confStatsFromJson(json);
    return Da3DepthFrameResult(
      frameID: _asString(json['frameID'], fallback: _asString(json['id'])),
      windowID: _asString(json['windowID'], fallback: fallbackWindowID),
      status: _asString(json['status'], fallback: 'completed'),
      relativeDepthPath:
          _nullableString(json['relativeDepthPath']) ??
          _nullableString(json['relative_depth_path']),
      confidencePath:
          _nullableString(json['confidencePath']) ??
          _nullableString(json['confidence_path']),
      metricDepthPath:
          _nullableString(json['metricDepthPath']) ??
          _nullableString(json['metric_depth_path']),
      predExtrinsicsPath:
          _nullableString(json['predExtrinsicsPath']) ??
          _nullableString(json['pred_extrinsics_path']),
      predIntrinsicsPath:
          _nullableString(json['predIntrinsicsPath']) ??
          _nullableString(json['pred_intrinsics_path']),
      depthWidth:
          _nullableInt(json['depthWidth']) ?? _nullableInt(json['depth_width']),
      depthHeight:
          _nullableInt(json['depthHeight']) ??
          _nullableInt(json['depth_height']),
      inferenceMs:
          _nullableDouble(json['inferenceMs']) ??
          _nullableDouble(json['inference_ms']),
      confStats: stats,
      message: _nullableString(json['message']),
    );
  }
}

class Da3DepthWindowResult {
  const Da3DepthWindowResult({
    required this.windowID,
    required this.frames,
    this.status = 'completed',
    this.telemetry = const <String, Object?>{},
    this.message,
  });

  final String windowID;
  final String status;
  final List<Da3DepthFrameResult> frames;
  final Map<String, Object?> telemetry;
  final String? message;

  static Da3DepthWindowResult pending(
    Da3DepthWindowRequest request,
    String message,
  ) {
    return Da3DepthWindowResult(
      windowID: request.windowID,
      status: 'pending',
      message: message,
      frames: [
        for (final frame in request.frames)
          Da3DepthFrameResult.pending(frame, request.windowID, message),
      ],
    );
  }

  static Da3DepthWindowResult failed(
    Da3DepthWindowRequest request,
    String message,
  ) {
    return Da3DepthWindowResult(
      windowID: request.windowID,
      status: 'failed',
      message: message,
      frames: [
        for (final frame in request.frames)
          Da3DepthFrameResult.failed(frame, request.windowID, message),
      ],
    );
  }

  static Da3DepthWindowResult fromJson(
    Da3DepthWindowRequest request,
    Map<String, Object?> json,
  ) {
    final rawFrames = _maps(json['frames']);
    final frames = rawFrames.isEmpty
        ? [
            for (final frame in request.frames)
              Da3DepthFrameResult.fromJson({
                'frameID': frame.frameID,
                ...json,
              }, fallbackWindowID: request.windowID),
          ]
        : [
            for (final frame in rawFrames)
              Da3DepthFrameResult.fromJson(
                frame,
                fallbackWindowID: request.windowID,
              ),
          ];
    return Da3DepthWindowResult(
      windowID: _asString(json['windowID'], fallback: request.windowID),
      status: _asString(json['status'], fallback: 'completed'),
      telemetry: _mapValue(json['telemetry']),
      message: _nullableString(json['message']),
      frames: frames,
    );
  }
}

abstract class Da3DepthRunner {
  const Da3DepthRunner();

  Future<Da3DepthWindowResult> runWindow(Da3DepthWindowRequest request);
}

class MethodChannelDa3DepthRunner extends Da3DepthRunner {
  const MethodChannelDa3DepthRunner({
    this.channel = const MethodChannel('pocketworld/da3_depth'),
  });

  final MethodChannel channel;

  @override
  Future<Da3DepthWindowResult> runWindow(Da3DepthWindowRequest request) async {
    _appendDartChannelLog(request, 'invoke_begin', {
      'frameCount': request.frames.length,
      'resourceName': _asString(request.model['resourceName']),
      'windowSize': _nullableInt(request.model['windowSize']),
      'inputHeight': _nullableInt(request.model['inputHeight']),
      'inputWidth': _nullableInt(request.model['inputWidth']),
    });
    try {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'runDa3DepthWindow',
        request.toJson(),
      );
      if (result == null) {
        _appendDartChannelLog(request, 'invoke_null_result');
        return Da3DepthWindowResult.pending(
          request,
          'native DA3 depth runner returned null',
        );
      }
      _appendDartChannelLog(request, 'invoke_done', {
        'status': _asString(result['status']),
        'frameCount': _maps(result['frames']).length,
        'message': _nullableString(result['message']),
        'telemetry': _mapValue(result['telemetry']),
      });
      return Da3DepthWindowResult.fromJson(
        request,
        result.cast<String, Object?>(),
      );
    } on MissingPluginException {
      _appendDartChannelLog(request, 'missing_plugin');
      return Da3DepthWindowResult.pending(
        request,
        'native DA3 depth runner is not registered',
      );
    } on PlatformException catch (e) {
      _appendDartChannelLog(request, 'platform_exception', {
        'code': e.code,
        'message': e.message,
        if (e.details != null) 'details': '${e.details}',
      });
      return Da3DepthWindowResult.failed(request, e.message ?? e.code);
    } catch (e) {
      _appendDartChannelLog(request, 'invoke_error', {'error': '$e'});
      return Da3DepthWindowResult.pending(
        request,
        'native DA3 depth runner unavailable: $e',
      );
    }
  }

  void _appendDartChannelLog(
    Da3DepthWindowRequest request,
    String phase, [
    Map<String, Object?> fields = const <String, Object?>{},
  ]) {
    try {
      final file = File('${request.outputDir.path}/da3_dart_channel_log.jsonl');
      file.writeAsStringSync(
        '${jsonEncode({'schema_version': 'aether_da3_dart_channel_log_v1', 'time_utc': DateTime.now().toUtc().toIso8601String(), 'windowID': request.windowID, 'phase': phase, ...fields})}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // Diagnostics must not affect DA3 execution.
    }
  }
}

// ─── Stage stub implementations ─────────────────────────────────────
//
// W6 D1 just scaffolds; each stage's real impl lands in its own week.
// All five stubs simulate work via [stubDelay] + write a stub artifact
// + emit 4 progress events at 0.25 / 0.50 / 0.75 / 1.00.

/// Number of intermediate progress ticks each stub stage emits
/// (in addition to the final 1.00 tick).
const int _kStubTicks = 4;

Future<void> _emitStubProgress(
  StreamSink<StageProgress> sink,
  Duration totalDelay,
  String detailPrefix,
) async {
  // Emit 4 progress events at 0.25 / 0.50 / 0.75 / 1.00, with a delay
  // between each tick that sums to totalDelay.
  final perTick = Duration(
    microseconds: totalDelay.inMicroseconds ~/ _kStubTicks,
  );
  for (var i = 1; i <= _kStubTicks; i++) {
    await Future<void>.delayed(perTick);
    final f = i / _kStubTicks;
    sink.add(StageProgress(f, '$detailPrefix tick $i/$_kStubTicks'));
  }
}

class DepthStage extends PipelineStageRunner {
  // Stage 1 is policy-driven for photo bundles:
  //   photo_bundle.json + model_policy.json + da3_k_windows.json
  // decide what DA3-BASE runner receives. The official baseline keeps only
  // K=35 as the product constraint; image preprocessing follows DA3
  // process_res=504 upper_bound_resize + patch align before native inference.
  final Duration stubDelay;
  final Da3DepthRunner depthRunner;
  final VisualLoopRetrievalExecutor visualLoopRetrievalExecutor;
  final DenseSim3Verifier denseSim3Verifier;
  final MetricDepthAlignmentExecutor metricDepthAlignmentExecutor;
  const DepthStage({
    this.stubDelay = const Duration(seconds: 2),
    this.depthRunner = const MethodChannelDa3DepthRunner(),
    this.visualLoopRetrievalExecutor =
        const ContractOnlyVisualLoopRetrievalExecutor(),
    this.denseSim3Verifier = const DartDenseSim3Verifier(),
    this.metricDepthAlignmentExecutor = const FfiMetricDepthAlignmentExecutor(),
  });

  @override
  PipelineStage get stage => PipelineStage.depth;

  @override
  String get outputDirName => pipelineStageName(stage);

  @override
  Future<void> run({
    required Directory inputDir,
    required Directory outputDir,
    required StreamSink<StageProgress> progressSink,
  }) async {
    final captureDir = inputDir.parent;
    final hasPolicyInputs =
        File('${captureDir.path}/photo_bundle.json').existsSync() &&
        File('${captureDir.path}/model_policy.json').existsSync() &&
        File('${captureDir.path}/da3_k_windows.json').existsSync();
    if (hasPolicyInputs) {
      await _runDa3BaseDepth(
        captureDir: captureDir,
        inputDir: inputDir,
        outputDir: outputDir,
        progressSink: progressSink,
      );
      return;
    }

    await _runLegacyScaffold(outputDir, progressSink);
  }

  Future<void> _runLegacyScaffold(
    Directory outputDir,
    StreamSink<StageProgress> progressSink,
  ) async {
    final idx = File('${outputDir.path}/depth_index.json');
    await idx.writeAsString(
      jsonEncode({
        'schema_version': 'aether_depth_index_v1',
        'status': 'legacy_scaffold',
        'frames': [],
        'depth_meta_schema_version': kDepthMetaSchemaVersion,
        'alignment_schema': 'depth_meta_schema.json',
      }),
      flush: true,
    );

    final schema = File('${outputDir.path}/depth_meta_schema.json');
    await schema.writeAsString(
      jsonEncode({
        'schema_version': kDepthMetaSchemaVersion,
        'sidecar': 'depth_meta.jsonl',
        'relative_depth': {
          'producer': 'DA3',
          'path_field': 'relative_depth_path',
          'confidence_fields': [
            'conf_median',
            'conf_mean',
            'conf_min',
            'conf_max',
          ],
        },
        'p0_alignment': {
          'mode': kDepthAlignModeSessionChunkAdaptive,
          'scale_field': 'align_scale',
          'translation_field': 'align_translation',
          'reliability_field': 'align_reliability',
        },
        'p1_fallback': {
          'mode': kDepthAlignModeFramePriorFallback,
          'raw_diagnostic_fields': [
            'align_rmse',
            'align_inlier_ratio',
            'align_anchor_count',
            'align_anchor_used',
          ],
        },
        'p2_sparse_prior': {
          'mode': kSparsePriorModeResidualField,
          'metric_depth_path_field': 'metric_depth_path',
          'diagnostic_fields': [
            'sparse_prior_anchor_count',
            'sparse_prior_anchor_used',
            'sparse_prior_mean_abs_residual_m',
            'sparse_prior_max_abs_residual_m',
          ],
        },
      }),
      flush: true,
    );

    await _emitStubProgress(progressSink, stubDelay, 'depth');

    await writeDoneMarker(
      outputDir,
      extra: {
        'frame_count': 0,
        'depth_meta_schema_version': kDepthMetaSchemaVersion,
        'alignment_mode': kDepthAlignModeSessionChunkAdaptive,
        'fallback_mode': kDepthAlignModeFramePriorFallback,
        'sparse_prior_mode': kSparsePriorModeResidualField,
      },
    );
  }

  Future<void> _runDa3BaseDepth({
    required Directory captureDir,
    required Directory inputDir,
    required Directory outputDir,
    required StreamSink<StageProgress> progressSink,
  }) async {
    final manifest = await _readJsonMap(
      File('${captureDir.path}/photo_bundle.json'),
    );
    final modelPolicy = await _readJsonMap(
      File('${captureDir.path}/model_policy.json'),
    );
    final kWindowsPlan = await _readJsonMap(
      File('${captureDir.path}/da3_k_windows.json'),
    );
    final da3InputManifestFile = File(
      '${captureDir.path}/da3_input_manifest.json',
    );
    final da3InputManifest = da3InputManifestFile.existsSync()
        ? await _readJsonMap(da3InputManifestFile)
        : const <String, Object?>{};

    final model = _mapValue(modelPolicy['selectedDepthModel']).isNotEmpty
        ? _mapValue(modelPolicy['selectedDepthModel'])
        : _mapValue(kWindowsPlan['model']);
    _assertCommercialDa3Base(model);

    await _writeDepthMetaSchema(outputDir);

    final frameSpecs = _frameSpecsFromManifest(
      captureDir: captureDir,
      inputDir: inputDir,
      manifest: manifest,
      da3InputManifest: da3InputManifest,
    );
    final frameByID = {for (final frame in frameSpecs) frame.frameID: frame};
    final windows = _maps(kWindowsPlan['windows']);
    final byFrameID = <String, Da3DepthFrameResult>{};
    final windowReports = <Map<String, Object?>>[];

    if (windows.isEmpty) {
      for (final frame in frameSpecs) {
        byFrameID[frame.frameID] = Da3DepthFrameResult.pending(
          frame,
          'no_window',
          'da3_k_windows.json has no windows',
        );
      }
      progressSink.add(const StageProgress(0.96, 'da3 no K-windows'));
    } else {
      for (var i = 0; i < windows.length; i++) {
        final window = windows[i];
        final windowID = _asString(
          window['id'],
          fallback: 'window_${i.toString().padLeft(3, '0')}',
        );
        final frameIDs = _strings(window['frameIDs']);
        final requestFrames = <Da3DepthFrameSpec>[
          for (final id in frameIDs)
            if (frameByID[id] != null) frameByID[id]!,
        ];
        final request = Da3DepthWindowRequest(
          captureDir: captureDir,
          outputDir: outputDir,
          model: model,
          windowID: windowID,
          window: window,
          frames: requestFrames,
        );
        progressSink.add(
          StageProgress(
            (i / windows.length) * 0.96,
            'da3 ${i + 1}/${windows.length} $windowID running',
          ),
        );
        final result = requestFrames.isEmpty
            ? Da3DepthWindowResult.pending(
                request,
                'K-window has no frames present in photo_bundle.json',
              )
            : await depthRunner.runWindow(request);
        final downstreamFrameIDs = _downstreamFrameIDsForWindow(window);
        windowReports.add(
          {
            'windowID': result.windowID,
            'status': result.status,
            'message': result.message,
            'frameCount': result.frames.length,
            'selectionMode': _nullableString(window['selectionMode']),
            'seedFrameID': _nullableString(window['seedFrameID']),
            'parentWindowID': _nullableString(window['parentWindowID']),
            'bridgeRule': _nullableString(window['bridgeRule']),
            'bridgeFrameIDs': _strings(window['bridgeFrameIDs']),
            'coreFrameIDs': _strings(window['coreFrameIDs']),
            'officialSaveFrameIDs': _strings(window['officialSaveFrameIDs']),
            'downstreamFrameIDs': downstreamFrameIDs.toList(growable: false),
            'officialSaveLocalIndices': _ints(
              window['officialSaveLocalIndices'],
            ),
            'uniqueFrameIDs': _strings(window['uniqueFrameIDs']),
            'bridgeValidation': _mapValue(window['bridgeValidation']),
            'telemetry': result.telemetry,
            'frames': [
              for (final frame in result.frames) frame.toIndexJson(null),
            ],
          }..removeWhere((_, value) => value == null),
        );
        for (final frameResult in result.frames) {
          if (downstreamFrameIDs.isNotEmpty &&
              !downstreamFrameIDs.contains(frameResult.frameID)) {
            continue;
          }
          final existing = byFrameID[frameResult.frameID];
          if (existing == null ||
              (!existing.isCompleted && frameResult.isCompleted)) {
            byFrameID[frameResult.frameID] = frameResult;
          }
        }
        progressSink.add(
          StageProgress(
            ((i + 1) / windows.length) * 0.96,
            'da3 ${i + 1}/${windows.length} $windowID ${result.status}',
          ),
        );
      }
    }

    for (final frame in frameSpecs) {
      byFrameID.putIfAbsent(
        frame.frameID,
        () => Da3DepthFrameResult.pending(
          frame,
          'unselected',
          'frame was not selected by da3_k_windows.json',
        ),
      );
    }

    final orderedResults = [
      for (final frame in frameSpecs) byFrameID[frame.frameID]!,
    ];
    final completed = orderedResults.where((r) => r.isCompleted).length;
    final pending = orderedResults.where((r) => r.isPending).length;
    final failed = orderedResults.where((r) => r.isFailed).length;
    final stageStatus = _depthStageStatus(
      total: orderedResults.length,
      completed: completed,
      pending: pending,
      failed: failed,
    );

    progressSink.add(
      const StageProgress(0.98, 'visual loop retrieval contract'),
    );
    final visualLoopRetrievalReport = await visualLoopRetrievalExecutor
        .retrieve(
          VisualLoopRetrievalRequest(
            captureDir: captureDir,
            depthOutputDir: outputDir,
            kWindowGraph: {
              'windowing_policy': _mapValue(kWindowsPlan['windowingPolicy']),
              'bridge_graph': _maps(kWindowsPlan['bridgeGraph']),
              'loop_closure_policy': _mapValue(
                kWindowsPlan['loopClosurePolicy'],
              ),
              'loop_candidates': _maps(kWindowsPlan['loopCandidates']),
              'uncovered_frame_ids': _strings(
                kWindowsPlan['uncoveredFrameIDs'],
              ),
            },
            windowReports: windowReports,
          ),
        );
    final visualLoopRetrievalJson = visualLoopRetrievalReport.toJson();
    await File(
      '${outputDir.path}/visual_loop_retrieval_report.json',
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert(visualLoopRetrievalJson),
      flush: true,
    );

    progressSink.add(const StageProgress(0.99, 'dense Sim3 verification'));
    final denseSim3Report = await denseSim3Verifier.verify(
      DenseSim3VerificationRequest(
        captureDir: captureDir,
        depthOutputDir: outputDir,
        kWindowGraph: {
          'windowing_policy': _mapValue(kWindowsPlan['windowingPolicy']),
          'bridge_graph': _maps(kWindowsPlan['bridgeGraph']),
          'loop_closure_policy': _mapValue(kWindowsPlan['loopClosurePolicy']),
          'loop_candidates': _maps(kWindowsPlan['loopCandidates']),
          'uncovered_frame_ids': _strings(kWindowsPlan['uncoveredFrameIDs']),
        },
        windowReports: windowReports,
        visualLoopRetrievalReport: visualLoopRetrievalJson,
      ),
    );
    final denseSim3Json = denseSim3Report.toJson();
    await File(
      '${outputDir.path}/dense_sim3_verification_report.json',
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert(denseSim3Json),
      flush: true,
    );
    final geometryGateStatus = _asString(
      denseSim3Json['status'],
      fallback: 'unknown',
    );
    final geometryGatePassed = geometryGateStatus == 'passed';
    final streamingAlignmentJson = _mapValue(
      denseSim3Json['streaming_alignment'],
    );
    final streamingWindowTransformsByID = _streamingWindowTransformsByID(
      streamingAlignmentJson,
    );
    progressSink.add(const StageProgress(0.995, 'DA3 metric-depth alignment'));
    final metricDepthAlignmentReport = await metricDepthAlignmentExecutor.align(
      MetricDepthAlignmentRequest(
        captureDir: captureDir,
        depthOutputDir: outputDir,
        denseSim3Verification: denseSim3Json,
        frames: _metricDepthAlignmentFrames(
          frameSpecs: frameSpecs,
          orderedResults: orderedResults,
        ),
      ),
    );
    final metricDepthAlignmentJson = metricDepthAlignmentReport.toJson();
    await File(
      '${outputDir.path}/metric_depth_alignment_report.json',
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert(metricDepthAlignmentJson),
      flush: true,
    );
    final metricAlignmentByFrameID = metricDepthAlignmentReport.byFrameID;
    final da3RuntimeContract = _da3RuntimeContract(model);
    final da3ModelInputContract = _da3ModelInputContract(model);
    final algorithmExecutorBoundary = _mapValue(
      da3RuntimeContract['algorithmExecutorBoundary'],
    );

    final da3AuditJson = _buildDa3RealDeviceAudit(
      model: model,
      kWindowsPlan: kWindowsPlan,
      windowReports: windowReports,
      orderedResults: orderedResults,
      visualLoopRetrieval: visualLoopRetrievalJson,
      denseSim3Verification: denseSim3Json,
    );
    await File('${outputDir.path}/da3_real_device_audit.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(da3AuditJson),
      flush: true,
    );

    final depthMetaEntries = <DepthMetaEntry>[];
    for (final result in orderedResults) {
      final source = frameByID[result.frameID];
      if (source == null || result.confStats == null) continue;
      final metricAlignment = metricAlignmentByFrameID[result.frameID];
      final metricDepthPath =
          metricAlignment?.metricDepthPath ?? result.metricDepthPath;
      final entry = DepthMetaEntry.fromStats(
        frame: source.frameIndex,
        stats: result.confStats!,
        inferenceMs: result.inferenceMs,
        relativeDepthPath: result.relativeDepthPath,
        metricDepthPath: metricDepthPath,
      );
      depthMetaEntries.add(metricAlignment?.mergeIntoDepthMeta(entry) ?? entry);
    }
    await DepthMetaSidecar.writeAll(
      '${outputDir.path}/depth_meta.jsonl',
      depthMetaEntries,
    );

    final frameIndex = [
      for (final result in orderedResults)
        {
          ...result.toIndexJson(frameByID[result.frameID]),
          if (metricAlignmentByFrameID[result.frameID] != null)
            ...metricAlignmentByFrameID[result.frameID]!.toDepthIndexJson(),
          if (streamingWindowTransformsByID[result.windowID] != null)
            'windowToRootSim3':
                streamingWindowTransformsByID[result.windowID]!['sim3'],
          if (streamingWindowTransformsByID[result.windowID] != null)
            'streamingAlignmentStatus':
                streamingWindowTransformsByID[result.windowID]!['status'],
        }..removeWhere((_, value) => value == null),
    ];
    final depthIndex = {
      'schema_version': 'aether_depth_index_v1',
      'status': stageStatus,
      'source_manifest': 'photo_bundle.json',
      'model_policy_path': 'model_policy.json',
      'k_windows_path': 'da3_k_windows.json',
      'input_size_locked':
          model['inputWidth'] != null && model['inputHeight'] != null,
      'input_size_status': _asString(
        model['inputSizeStatus'],
        fallback: 'not_locked_by_policy',
      ),
      if (model['inputWidth'] != null) 'input_width': model['inputWidth'],
      if (model['inputHeight'] != null) 'input_height': model['inputHeight'],
      'model': model,
      'runtime_contract': da3RuntimeContract,
      'algorithm_executor_boundary': algorithmExecutorBoundary,
      'k_window_graph': {
        'windowing_policy': _mapValue(kWindowsPlan['windowingPolicy']),
        'bridge_graph': _maps(kWindowsPlan['bridgeGraph']),
        'loop_closure_policy': _mapValue(kWindowsPlan['loopClosurePolicy']),
        'loop_candidates': _maps(kWindowsPlan['loopCandidates']),
        'uncovered_frame_ids': _strings(kWindowsPlan['uncoveredFrameIDs']),
      },
      'visual_loop_retrieval_report_path': 'visual_loop_retrieval_report.json',
      'visual_loop_retrieval': visualLoopRetrievalJson,
      'dense_sim3_verification_report_path':
          'dense_sim3_verification_report.json',
      'dense_sim3_verification': denseSim3Json,
      'streaming_alignment': streamingAlignmentJson,
      'geometry_gate_status': geometryGateStatus,
      'geometry_gate_blocks_downstream': !geometryGatePassed,
      'metric_depth_alignment_report_path':
          'metric_depth_alignment_report.json',
      'metric_depth_alignment': metricDepthAlignmentJson,
      'metric_depth_alignment_blocks_pointcloud':
          metricDepthAlignmentReport.status != 'completed' &&
          metricDepthAlignmentReport.status != 'partial_completed',
      'da3_real_device_audit_report_path': 'da3_real_device_audit.json',
      'da3_real_device_audit': da3AuditJson,
      'window_count': windows.length,
      'frame_count': orderedResults.length,
      'completed_count': completed,
      'pending_count': pending,
      'failed_count': failed,
      'depth_meta_schema_version': kDepthMetaSchemaVersion,
      'alignment_schema': 'depth_meta_schema.json',
      'depth_meta_path': 'depth_meta.jsonl',
      'confidence_contract': {
        'schema_version': 'aether_da3_confidence_contract_v1',
        'official_source':
            'Depth-Anything-3 da3_streaming.py predictions.conf -= 1.0 before save_depth_conf_result',
        'confidence_path_field': 'confidencePath',
        'stats_fields': ['confMedian', 'confMean', 'confMin', 'confMax'],
        'stored_confidence_semantics':
            'official_da3_streaming_confidence_minus_one',
        'downstream_must_not_use_raw_depth_confidence': true,
        'pointcloud_consumer':
            'consume depth_index frames[].confidencePath/stats after official confidence-minus-one',
      },
      'geometry_contract': {
        'producer': 'DA3-BASE CoreML',
        'model_resource': _asString(model['resourceName']),
        'da3_input_contract': da3ModelInputContract,
        'official_streaming_baseline': _isOfficialDa3StreamingImageOnlyModel(
          model,
        ),
        'pose_outputs': ['predExtrinsicsPath', 'predIntrinsicsPath'],
        'depth_outputs': [
          'relativeDepthPath',
          'confidencePath',
          'metricDepthPath',
        ],
        'confidence_policy': 'official_da3_streaming_confidence_minus_one',
        'metric_depth_authority':
            'DA3 relative depth aligned by capture metadata anchors outside the official DA3 input contract',
        'downstream_consumers': [
          'pointcloud',
          'mesh',
          'texture',
          'highlight_specular',
        ],
        'window_graph_outputs': [
          'k_window_graph.bridge_graph',
          'k_window_graph.loop_candidates',
          'depth_runner_report.json windows[].bridgeFrameIDs',
        ],
        'loop_edges_require': [
          'visual_retrieval_similarity',
          'dense_sim3_geometry_verification',
        ],
        'truth_gate_outputs': [
          'visual_loop_retrieval_report.json',
          'dense_sim3_verification_report.json',
          'metric_depth_alignment_report.json',
          'dense_sim3_verification.streaming_alignment.windowTransforms',
          'da3_real_device_audit.json',
        ],
        'accepted_window_edges':
            'dense_sim3_verification.bridge_edges[status=accepted]',
        'window_alignment_transform':
            'frames[].windowToRootSim3, copied from dense_sim3_verification.streaming_alignment.windowTransforms[].sim3',
        'downstream_blocked_when': 'geometry_gate_status != passed',
      },
      'frames': frameIndex,
    };
    await File('${outputDir.path}/depth_index.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(depthIndex),
      flush: true,
    );

    final report = {
      'schema_version': 'aether_da3_depth_runner_report_v1',
      'status': stageStatus,
      'rule':
          'Flutter/Dart owns DA3 model policy, K-windowing, locked input size, and downstream geometry contract; native runners only adapt platform inference',
      'model': model,
      'runtime_contract': da3RuntimeContract,
      'algorithm_executor_boundary': algorithmExecutorBoundary,
      'k_window_graph': {
        'windowing_policy': _mapValue(kWindowsPlan['windowingPolicy']),
        'bridge_graph': _maps(kWindowsPlan['bridgeGraph']),
        'loop_closure_policy': _mapValue(kWindowsPlan['loopClosurePolicy']),
        'loop_candidates': _maps(kWindowsPlan['loopCandidates']),
      },
      'visual_loop_retrieval': visualLoopRetrievalJson,
      'dense_sim3_verification': denseSim3Json,
      'streaming_alignment': streamingAlignmentJson,
      'geometry_gate_status': geometryGateStatus,
      'geometry_gate_blocks_downstream': !geometryGatePassed,
      'da3_real_device_audit': da3AuditJson,
      'windows': windowReports,
      'counts': {
        'frames': orderedResults.length,
        'completed': completed,
        'pending': pending,
        'failed': failed,
      },
    };
    await File('${outputDir.path}/depth_runner_report.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );

    await writeDoneMarker(
      outputDir,
      extra: {
        'stage_status': stageStatus,
        'frame_count': orderedResults.length,
        'completed_count': completed,
        'pending_count': pending,
        'failed_count': failed,
        'model_id': _asString(model['id']),
        'model_resource': _asString(model['resourceName']),
        'input_size_locked':
            model['inputWidth'] != null && model['inputHeight'] != null,
        if (model['inputWidth'] != null) 'input_width': model['inputWidth'],
        if (model['inputHeight'] != null) 'input_height': model['inputHeight'],
        'depth_meta_schema_version': kDepthMetaSchemaVersion,
        'alignment_mode': kDepthAlignModeSessionChunkAdaptive,
        'fallback_mode': kDepthAlignModeFramePriorFallback,
        'sparse_prior_mode': kSparsePriorModeResidualField,
        'geometry_gate_status': geometryGateStatus,
        'geometry_gate_blocks_downstream': !geometryGatePassed,
      },
    );
  }

  Future<void> _writeDepthMetaSchema(Directory outputDir) async {
    final schema = File('${outputDir.path}/depth_meta_schema.json');
    await schema.writeAsString(
      jsonEncode({
        'schema_version': kDepthMetaSchemaVersion,
        'sidecar': 'depth_meta.jsonl',
        'relative_depth': {
          'producer': 'DA3',
          'path_field': 'relative_depth_path',
          'confidence_policy': 'official_da3_streaming_confidence_minus_one',
          'confidence_fields': [
            'conf_median',
            'conf_mean',
            'conf_min',
            'conf_max',
          ],
        },
        'p0_alignment': {
          'mode': kDepthAlignModeSessionChunkAdaptive,
          'scale_field': 'align_scale',
          'translation_field': 'align_translation',
          'reliability_field': 'align_reliability',
        },
        'p1_fallback': {
          'mode': kDepthAlignModeFramePriorFallback,
          'raw_diagnostic_fields': [
            'align_rmse',
            'align_inlier_ratio',
            'align_anchor_count',
            'align_anchor_used',
          ],
        },
        'p2_sparse_prior': {
          'mode': kSparsePriorModeResidualField,
          'metric_depth_path_field': 'metric_depth_path',
          'diagnostic_fields': [
            'sparse_prior_anchor_count',
            'sparse_prior_anchor_used',
            'sparse_prior_mean_abs_residual_m',
            'sparse_prior_max_abs_residual_m',
          ],
        },
      }),
      flush: true,
    );
  }
}

class PointCloudStage extends PipelineStageRunner {
  // Mobile replay of the official DA3 downstream path:
  // stages/depth/depth_index.json frames[] -> binary little-endian PLY.
  // Research/desktop should run Depth-Anything-3/da3_streaming/npz_output_process.py directly.
  // This intentionally does not read full K-window reports or withheld slots.
  final Duration stubDelay;
  const PointCloudStage({this.stubDelay = const Duration(seconds: 2)});

  @override
  PipelineStage get stage => PipelineStage.pointcloud;

  @override
  String get outputDirName => pipelineStageName(stage);

  @override
  Future<void> run({
    required Directory inputDir,
    required Directory outputDir,
    required StreamSink<StageProgress> progressSink,
  }) async {
    final spec = _stageKernelSpec(stage);
    final result = await _runDa3PointCloudMobileReplayIfReady(
      inputDir: inputDir,
      outputDir: outputDir,
    );
    await _writeStageKernelContract(
      outputDir: outputDir,
      spec: spec,
      status: result.status,
      outputs: result.toStageOutputs(),
    );

    await _emitStubProgress(progressSink, stubDelay, 'pointcloud');

    await writeDoneMarker(
      outputDir,
      extra: {
        'point_count': result.pointCount,
        'spec_path': 'stage_spec.json',
        'pointcloud_status': result.status,
        'mobile_replay_executed': result.executed,
        if (result.reason != null) 'reason': result.reason,
      },
    );
  }
}

Future<_PointCloudStageResult> _runDa3PointCloudMobileReplayIfReady({
  required Directory inputDir,
  required Directory outputDir,
}) async {
  final ply = File('${outputDir.path}/pointcloud.ply');
  final depthIndexFile = File('${inputDir.path}/depth_index.json');
  if (!await depthIndexFile.exists()) {
    await _writeBinaryLittleEndianPly(ply, const <_PlyVertex>[]);
    return const _PointCloudStageResult.stub(
      reason: 'missing stages/depth/depth_index.json',
    );
  }

  final depthIndex = await _readJsonMap(depthIndexFile);
  final captureDir = inputDir.parent.parent;
  final frames = _pointCloudFrameInputs(
    depthIndex: depthIndex,
    captureDir: captureDir,
    depthStageDir: inputDir,
  );
  if (frames.isEmpty) {
    await _writeBinaryLittleEndianPly(ply, const <_PlyVertex>[]);
    return const _PointCloudStageResult.stub(
      reason:
          'no completed depth_index frames with positive depthWidth/depthHeight',
    );
  }

  return _writeDa3PointCloudMobileReplay(
    frames: frames,
    outputPly: ply,
    confThresholdCoef: 0.5,
    sampleRatio: 0.015,
  );
}

List<_PointCloudFrameInput> _pointCloudFrameInputs({
  required Map<String, Object?> depthIndex,
  required Directory captureDir,
  required Directory depthStageDir,
}) {
  final frames = <_PointCloudFrameInput>[];
  for (final frame in _maps(depthIndex['frames'])) {
    if (_asString(frame['status'], fallback: 'completed') != 'completed') {
      continue;
    }
    final width = _nullableInt(frame['depthWidth']) ?? 0;
    final height = _nullableInt(frame['depthHeight']) ?? 0;
    if (width <= 0 || height <= 0) continue;

    final frameID = _asString(
      frame['frameID'],
      fallback: _asString(frame['id']),
    );
    final imagePath = _nullableString(frame['imageRelativePath']);
    final depthPath = _nullableString(frame['relativeDepthPath']);
    final confPath = _nullableString(frame['confidencePath']);
    final extrinsicsPath = _nullableString(frame['predExtrinsicsPath']);
    final intrinsicsPath = _nullableString(frame['predIntrinsicsPath']);
    final missing = <String>[
      if (imagePath == null) 'imageRelativePath',
      if (depthPath == null) 'relativeDepthPath',
      if (confPath == null) 'confidencePath',
      if (extrinsicsPath == null) 'predExtrinsicsPath',
      if (intrinsicsPath == null) 'predIntrinsicsPath',
    ];
    if (missing.isNotEmpty) {
      throw FormatException(
        'completed depth_index frame $frameID is missing ${missing.join(', ')}',
      );
    }

    frames.add(
      _PointCloudFrameInput(
        frameID: frameID,
        width: width,
        height: height,
        imageFile: _resolveRelativeFile(captureDir, imagePath!),
        depthFile: _resolveRelativeFile(depthStageDir, depthPath!),
        confidenceFile: _resolveRelativeFile(depthStageDir, confPath!),
        extrinsicsFile: _resolveRelativeFile(depthStageDir, extrinsicsPath!),
        intrinsicsFile: _resolveRelativeFile(depthStageDir, intrinsicsPath!),
        windowToRootSim3: _sim3FromDepthIndexFrame(frame),
      ),
    );
  }
  return frames;
}

Future<_PointCloudStageResult> _writeDa3PointCloudMobileReplay({
  required List<_PointCloudFrameInput> frames,
  required File outputPly,
  required double confThresholdCoef,
  required double sampleRatio,
}) async {
  var confSum = 0.0;
  var confCount = 0;
  for (final frame in frames) {
    final conf = await _readFloat32File(
      frame.confidenceFile,
      expectedCount: frame.pixelCount,
      label: 'confidencePath',
    );
    for (final value in conf) {
      confSum += value;
    }
    confCount += conf.length;
  }
  final confThreshold = confCount == 0
      ? 0.0
      : (confSum / confCount) * confThresholdCoef;

  var totalValid = 0;
  for (final frame in frames) {
    final conf = await _readFloat32File(
      frame.confidenceFile,
      expectedCount: frame.pixelCount,
      label: 'confidencePath',
    );
    for (final value in conf) {
      if (value >= confThreshold && value > 1e-5) totalValid += 1;
    }
  }

  final sampleCount = sampleRatio < 1.0
      ? (totalValid * sampleRatio).floor()
      : totalValid;
  if (sampleCount == 0) {
    await _writeBinaryLittleEndianPly(outputPly, const <_PlyVertex>[]);
    return _PointCloudStageResult.completed(
      pointCount: 0,
      validPointCountBeforeSampling: totalValid,
      confThreshold: confThreshold,
      confThresholdCoef: confThresholdCoef,
      sampleRatio: sampleRatio,
      frameCount: frames.length,
    );
  }

  final random = math.Random();
  final reservoir = <_PlyVertex>[];
  var seen = 0;

  void addSample(_PlyVertex vertex) {
    seen += 1;
    if (sampleRatio >= 1.0) {
      reservoir.add(vertex);
      return;
    }
    if (reservoir.length < sampleCount) {
      reservoir.add(vertex);
      return;
    }
    final replacement = random.nextInt(seen);
    if (replacement < sampleCount) {
      reservoir[replacement] = vertex;
    }
  }

  for (final frame in frames) {
    final decodedImage = image.decodeImage(await frame.imageFile.readAsBytes());
    if (decodedImage == null) {
      throw FormatException('unable to decode ${frame.imageFile.path}');
    }
    if (decodedImage.width != frame.width ||
        decodedImage.height != frame.height) {
      throw FormatException(
        'image/depth shape mismatch for ${frame.frameID}: '
        'image=${decodedImage.width}x${decodedImage.height} '
        'depth=${frame.width}x${frame.height}',
      );
    }

    final depth = await _readFloat32File(
      frame.depthFile,
      expectedCount: frame.pixelCount,
      label: 'relativeDepthPath',
    );
    final conf = await _readFloat32File(
      frame.confidenceFile,
      expectedCount: frame.pixelCount,
      label: 'confidencePath',
    );
    final intrinsics = await _readFloat32File(
      frame.intrinsicsFile,
      expectedCount: 9,
      label: 'predIntrinsicsPath',
    );
    final extrinsics = await _readFloat32File(
      frame.extrinsicsFile,
      expectedCount: 12,
      label: 'predExtrinsicsPath',
    );

    final kInv = _invert3x3(intrinsics);
    final rInv = _invert3x3(<double>[
      extrinsics[0],
      extrinsics[1],
      extrinsics[2],
      extrinsics[4],
      extrinsics[5],
      extrinsics[6],
      extrinsics[8],
      extrinsics[9],
      extrinsics[10],
    ]);
    final tx = extrinsics[3];
    final ty = extrinsics[7];
    final tz = extrinsics[11];

    for (var y = 0; y < frame.height; y += 1) {
      for (var x = 0; x < frame.width; x += 1) {
        final idx = y * frame.width + x;
        final c = conf[idx];
        if (c < confThreshold || c <= 1e-5) continue;
        final d = depth[idx];

        final px = kInv[0] * x + kInv[1] * y + kInv[2];
        final py = kInv[3] * x + kInv[4] * y + kInv[5];
        final pz = kInv[6] * x + kInv[7] * y + kInv[8];
        final cx = px * d;
        final cy = py * d;
        final cz = pz * d;
        final vx = cx - tx;
        final vy = cy - ty;
        final vz = cz - tz;
        var wx = rInv[0] * vx + rInv[1] * vy + rInv[2] * vz;
        var wy = rInv[3] * vx + rInv[4] * vy + rInv[5] * vz;
        var wz = rInv[6] * vx + rInv[7] * vy + rInv[8] * vz;

        final sim3 = frame.windowToRootSim3;
        if (sim3 != null) {
          final transformed = sim3.apply(wx, wy, wz);
          wx = transformed.$1;
          wy = transformed.$2;
          wz = transformed.$3;
        }

        final pixel = decodedImage.getPixel(x, y);
        addSample(
          _PlyVertex(
            wx,
            wy,
            wz,
            _uint8(pixel.r),
            _uint8(pixel.g),
            _uint8(pixel.b),
          ),
        );
      }
    }
  }

  await _writeBinaryLittleEndianPly(outputPly, reservoir);
  return _PointCloudStageResult.completed(
    pointCount: reservoir.length,
    validPointCountBeforeSampling: totalValid,
    confThreshold: confThreshold,
    confThresholdCoef: confThresholdCoef,
    sampleRatio: sampleRatio,
    frameCount: frames.length,
  );
}

Future<Float32List> _readFloat32File(
  File file, {
  required int expectedCount,
  required String label,
}) async {
  final bytes = await file.readAsBytes();
  final expectedBytes = expectedCount * Float32List.bytesPerElement;
  if (bytes.lengthInBytes != expectedBytes) {
    throw FormatException(
      '$label ${file.path} must contain $expectedBytes bytes '
      '($expectedCount float32 values); got ${bytes.lengthInBytes}',
    );
  }
  final data = ByteData.sublistView(bytes);
  final out = Float32List(expectedCount);
  for (var i = 0; i < expectedCount; i += 1) {
    out[i] = data.getFloat32(i * Float32List.bytesPerElement, Endian.little);
  }
  return out;
}

List<double> _invert3x3(List<num> m) {
  if (m.length != 9) {
    throw FormatException('3x3 matrix must contain 9 values; got ${m.length}');
  }
  final a = m.map((v) => v.toDouble()).toList(growable: false);
  final det =
      a[0] * (a[4] * a[8] - a[5] * a[7]) -
      a[1] * (a[3] * a[8] - a[5] * a[6]) +
      a[2] * (a[3] * a[7] - a[4] * a[6]);
  if (det.abs() < 1e-12) {
    throw const FormatException('3x3 matrix is singular');
  }
  final invDet = 1.0 / det;
  return <double>[
    (a[4] * a[8] - a[5] * a[7]) * invDet,
    (a[2] * a[7] - a[1] * a[8]) * invDet,
    (a[1] * a[5] - a[2] * a[4]) * invDet,
    (a[5] * a[6] - a[3] * a[8]) * invDet,
    (a[0] * a[8] - a[2] * a[6]) * invDet,
    (a[2] * a[3] - a[0] * a[5]) * invDet,
    (a[3] * a[7] - a[4] * a[6]) * invDet,
    (a[1] * a[6] - a[0] * a[7]) * invDet,
    (a[0] * a[4] - a[1] * a[3]) * invDet,
  ];
}

Future<void> _writeBinaryLittleEndianPly(
  File file,
  List<_PlyVertex> vertices,
) async {
  await file.parent.create(recursive: true);
  final header =
      'ply\n'
      'format binary_little_endian 1.0\n'
      'element vertex ${vertices.length}\n'
      'property float x\n'
      'property float y\n'
      'property float z\n'
      'property uchar red\n'
      'property uchar green\n'
      'property uchar blue\n'
      'end_header\n';
  final sink = file.openWrite();
  sink.add(utf8.encode(header));
  if (vertices.isNotEmpty) {
    final data = ByteData(vertices.length * 15);
    var offset = 0;
    for (final vertex in vertices) {
      data.setFloat32(offset, vertex.x, Endian.little);
      offset += 4;
      data.setFloat32(offset, vertex.y, Endian.little);
      offset += 4;
      data.setFloat32(offset, vertex.z, Endian.little);
      offset += 4;
      data.setUint8(offset, vertex.r);
      offset += 1;
      data.setUint8(offset, vertex.g);
      offset += 1;
      data.setUint8(offset, vertex.b);
      offset += 1;
    }
    sink.add(data.buffer.asUint8List());
  }
  await sink.close();
}

File _resolveRelativeFile(Directory base, String relativeOrAbsolutePath) {
  if (_isAbsolutePath(relativeOrAbsolutePath)) {
    return File(relativeOrAbsolutePath);
  }
  final normalized = relativeOrAbsolutePath
      .replaceAll('\\', Platform.pathSeparator)
      .replaceAll('/', Platform.pathSeparator);
  return File(_joinPath(base.path, normalized));
}

bool _isAbsolutePath(String path) =>
    path.startsWith('/') ||
    path.startsWith(r'\') ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

_Da3Sim3? _sim3FromDepthIndexFrame(Map<String, Object?> frame) {
  final sim3 = _mapValue(frame['windowToRootSim3']);
  if (sim3.isEmpty) return null;
  final scale =
      _nullableDouble(sim3['scale']) ??
      _nullableDouble(sim3['sim3_scale']) ??
      _nullableDouble(sim3['s']);
  final rotation = _firstNonEmptyDoubleList([
    sim3['rotation'],
    sim3['sim3_rotation'],
    sim3['R'],
  ]);
  final translation = _firstNonEmptyDoubleList([
    sim3['translation'],
    sim3['sim3_translation'],
    sim3['T'],
    sim3['t'],
  ]);
  if (scale == null || rotation.length != 9 || translation.length != 3) {
    throw FormatException(
      'windowToRootSim3 for ${_asString(frame['frameID'])} must expose '
      'scale/rotation[9]/translation[3]',
    );
  }
  return _Da3Sim3(scale, rotation, translation);
}

List<double> _firstNonEmptyDoubleList(List<Object?> values) {
  for (final value in values) {
    final parsed = _doubleList(value);
    if (parsed.isNotEmpty) return parsed;
  }
  return const <double>[];
}

int _uint8(num value) => value.round().clamp(0, 255).toInt();

final class _PointCloudFrameInput {
  const _PointCloudFrameInput({
    required this.frameID,
    required this.width,
    required this.height,
    required this.imageFile,
    required this.depthFile,
    required this.confidenceFile,
    required this.extrinsicsFile,
    required this.intrinsicsFile,
    required this.windowToRootSim3,
  });

  final String frameID;
  final int width;
  final int height;
  final File imageFile;
  final File depthFile;
  final File confidenceFile;
  final File extrinsicsFile;
  final File intrinsicsFile;
  final _Da3Sim3? windowToRootSim3;

  int get pixelCount => width * height;
}

final class _PointCloudStageResult {
  const _PointCloudStageResult._({
    required this.status,
    required this.executed,
    required this.pointCount,
    required this.validPointCountBeforeSampling,
    required this.confThreshold,
    required this.confThresholdCoef,
    required this.sampleRatio,
    required this.frameCount,
    this.reason,
  });

  const _PointCloudStageResult.stub({required String reason})
    : this._(
        status: 'stub_contract_only',
        executed: false,
        pointCount: 0,
        validPointCountBeforeSampling: 0,
        confThreshold: null,
        confThresholdCoef: 0.5,
        sampleRatio: 0.015,
        frameCount: 0,
        reason: reason,
      );

  const _PointCloudStageResult.completed({
    required int pointCount,
    required int validPointCountBeforeSampling,
    required double confThreshold,
    required double confThresholdCoef,
    required double sampleRatio,
    required int frameCount,
  }) : this._(
         status: 'completed',
         executed: true,
         pointCount: pointCount,
         validPointCountBeforeSampling: validPointCountBeforeSampling,
         confThreshold: confThreshold,
         confThresholdCoef: confThresholdCoef,
         sampleRatio: sampleRatio,
         frameCount: frameCount,
       );

  final String status;
  final bool executed;
  final int pointCount;
  final int validPointCountBeforeSampling;
  final double? confThreshold;
  final double confThresholdCoef;
  final double sampleRatio;
  final int frameCount;
  final String? reason;

  Map<String, Object?> toStageOutputs() => {
    'pointcloud_path': 'pointcloud.ply',
    'point_count': pointCount,
    'mobile_replay_of_official_npz_output_process': executed,
    'valid_point_count_before_sampling': validPointCountBeforeSampling,
    'frame_count': frameCount,
    'conf_threshold_coef': confThresholdCoef,
    'sample_ratio': sampleRatio,
    if (confThreshold != null) 'conf_threshold': confThreshold,
    if (reason != null) 'reason': reason,
  };
}

final class _Da3Sim3 {
  const _Da3Sim3(this.scale, this.rotation, this.translation);

  final double scale;
  final List<double> rotation;
  final List<double> translation;

  (double, double, double) apply(double x, double y, double z) {
    final rx = rotation[0] * x + rotation[1] * y + rotation[2] * z;
    final ry = rotation[3] * x + rotation[4] * y + rotation[5] * z;
    final rz = rotation[6] * x + rotation[7] * y + rotation[8] * z;
    return (
      scale * rx + translation[0],
      scale * ry + translation[1],
      scale * rz + translation[2],
    );
  }
}

final class _PlyVertex {
  const _PlyVertex(this.x, this.y, this.z, this.r, this.g, this.b);

  final double x;
  final double y;
  final double z;
  final int r;
  final int g;
  final int b;
}

class MeshStage extends PipelineStageRunner {
  // TODO(W3 D1-D5): replace stub with PoissonRecon V18.76 FFI. Reads
  // `pointcloud.ply`, writes `mesh.ply` (water-tight). Plan G chose
  // PoissonRecon over BallPivoting after the texture-less wall failure
  // mode survey — V18.76 is the latest as of 2026-05.
  final Duration stubDelay;
  const MeshStage({this.stubDelay = const Duration(seconds: 2)});

  @override
  PipelineStage get stage => PipelineStage.mesh;

  @override
  String get outputDirName => pipelineStageName(stage);

  @override
  Future<void> run({
    required Directory inputDir,
    required Directory outputDir,
    required StreamSink<StageProgress> progressSink,
  }) async {
    final spec = _stageKernelSpec(stage);
    await _writeStageKernelContract(
      outputDir: outputDir,
      spec: spec,
      status: 'stub_contract_only',
      outputs: const {'mesh_path': 'mesh.ply', 'face_count': 0},
    );

    final mesh = File('${outputDir.path}/mesh.ply');
    await mesh.writeAsString('', flush: true);

    await _emitStubProgress(progressSink, stubDelay, 'mesh');

    await writeDoneMarker(
      outputDir,
      extra: {'face_count': 0, 'spec_path': 'stage_spec.json'},
    );
  }
}

class TextureStage extends PipelineStageRunner {
  // TODO(W4 D1-D5): replace stub with xatlas UV-unwrap FFI + a baker
  // that walks the cell-admitted JPEGs (kept on disk after capture
  // because we need them here, not just the depth bins) and samples
  // each face's color from the best-incidence-angle camera. Writes
  // `mesh.obj` + `atlas.png`.
  final Duration stubDelay;
  const TextureStage({this.stubDelay = const Duration(seconds: 2)});

  @override
  PipelineStage get stage => PipelineStage.texture;

  @override
  String get outputDirName => pipelineStageName(stage);

  @override
  Future<void> run({
    required Directory inputDir,
    required Directory outputDir,
    required StreamSink<StageProgress> progressSink,
  }) async {
    final spec = _stageKernelSpec(stage);
    await _writeStageKernelContract(
      outputDir: outputDir,
      spec: spec,
      status: 'stub_contract_only',
      outputs: const {
        'mesh_obj_path': 'mesh.obj',
        'atlas_path': 'atlas.png',
        'atlas_size': 0,
      },
    );

    final obj = File('${outputDir.path}/mesh.obj');
    final atlas = File('${outputDir.path}/atlas.png');
    await obj.writeAsString('', flush: true);
    await atlas.writeAsBytes(const <int>[], flush: true);

    await _emitStubProgress(progressSink, stubDelay, 'texture');

    await writeDoneMarker(
      outputDir,
      extra: {'atlas_size': 0, 'spec_path': 'stage_spec.json'},
    );
  }
}

class CompressStage extends PipelineStageRunner {
  // TODO(W5 D1-D5): replace stub with meshoptimizer FFI (simplify +
  // strip + reorder for vertex-cache locality) followed by KTX2 +
  // BasisU compression of `atlas.png`. Final glTF Binary write.
  final Duration stubDelay;
  const CompressStage({this.stubDelay = const Duration(seconds: 2)});

  @override
  PipelineStage get stage => PipelineStage.compress;

  @override
  String get outputDirName => pipelineStageName(stage);

  @override
  Future<void> run({
    required Directory inputDir,
    required Directory outputDir,
    required StreamSink<StageProgress> progressSink,
  }) async {
    final spec = _stageKernelSpec(stage);
    await _writeStageKernelContract(
      outputDir: outputDir,
      spec: spec,
      status: 'stub_contract_only',
      outputs: const {'glb_path': 'output.glb', 'glb_bytes': 0},
    );

    // Final stub output — this is the file PipelineCompletedEvent.outputGlb
    // points at.
    final glb = File('${outputDir.path}/output.glb');
    await glb.writeAsBytes(const <int>[], flush: true);

    await _emitStubProgress(progressSink, stubDelay, 'compress');

    await writeDoneMarker(
      outputDir,
      extra: {'glb_bytes': 0, 'spec_path': 'stage_spec.json'},
    );
  }
}

Map<String, Object?> _stageKernelSpec(PipelineStage stage) {
  switch (stage) {
    case PipelineStage.depth:
      throw ArgumentError('DA3 depth uses _da3RuntimeContract');
    case PipelineStage.pointcloud:
      return _kernelStageSpec(
        stageName: 'pointcloud',
        schemaVersion: 'aether_pointcloud_stage_spec_v1',
        inputs: const [
          'stages/depth/depth_index.json',
          'stages/depth/depth_index.json frames[] only; do not read full K window reports',
          'frames[].imageRelativePath',
          'frames[].relativeDepthPath',
          'frames[].metricDepthPath',
          'frames[].confidencePath',
          'frames[].predExtrinsicsPath',
          'frames[].predIntrinsicsPath',
          'frames[].depthWidth',
          'frames[].depthHeight',
          'frames[].windowToRootSim3',
        ],
        dartOwns: const [
          'voxel_size_m',
          'frame_skip policy',
          'windowToRootSim3 application rule',
          'metric-depth required before world-space unprojection',
          'confidence filter',
          'normal estimation policy',
          'minimum point count quality gate',
          'official DA3 downstream input boundary: consume depth_index frames[] selected from downstreamFrameIDs',
          'label voxel/outlier/normal cleanup as product adaptation, never as official DA3 de-thickening',
        ],
        executorOwns: const [
          'depth pixel projection kernels',
          'voxel dedup kernels',
          'normal computation kernels',
          'PLY byte writes',
          'no frame selection beyond Dart depth_index frames[]',
        ],
        parameters: const {
          'official_replication_boundary':
              'input frame set is official save-frame/core downstream from DepthStage depth_index.json',
          'forbidden_inputs': [
            'mac_da3_window_reports.json full K frames',
            'da3_k_windows.json frameIDs as pointcloud input without depth_index frames[] filtering',
            'withheldForNextOverlapFrameIDs',
            'raw depth_conf before official predictions.conf -= 1.0',
            'native-side frame selection policy',
          ],
          'mobile_replay_of_official_da3_export':
              'mobile replay of results_output/frame_*.npz + npz_output_process.py semantics, using already-selected depth_index frames; official Python remains the oracle',
          'official_python_oracle':
              'Research/desktop must run official da3_streaming/npz_output_process.py directly when possible; Dart is only the product mobile replay, not the authority',
          'official_npz_output_process': {
            'npz_folder_equivalent':
                'stages/depth/depth_index.json frames[] with imageRelativePath/relativeDepthPath/confidencePath/pred intrinsics/depthWidth/depthHeight',
            'image_field_equivalent':
                'frames[].imageRelativePath is DA3 processed image, equivalent to frame_*.npz image',
            'depth_field_equivalent':
                'frames[].relativeDepthPath is DA3 predictions.depth, equivalent to frame_*.npz depth',
            'confidence_threshold_source':
                'compute mean(confs) from confidencePath float32 payload, not confMean telemetry',
            'intrinsics_field_equivalent':
                'frames[].predIntrinsicsPath stores [3,3] float32, equivalent to frame_*.npz intrinsics',
            'extrinsics_field_equivalent':
                'frames[].predExtrinsicsPath stores [3,4] OpenCV w2c; official pose_file c2w is inverted to w2c before depth_to_point_cloud_vectorized',
            'pose_file_equivalent':
                'frames[].predExtrinsicsPath/windowToRootSim3; pose count must equal consumed frame count',
            'sort_order': 'frame_*.npz numeric frame index order',
            'conf_threshold_formula': 'mean(confs) * conf_threshold_coef',
            'valid_conf_mask': '(conf >= conf_threshold) && (conf > 1e-5)',
            'conf_threshold_coef': 0.5,
            'sample_ratio': 0.015,
            'batch_size': 1000000,
            'ply_format':
                'binary_little_endian vertex x/y/z float32 + red/green/blue uint8',
          },
          'streaming_full_chunk_pcd_path_not_product_baseline': {
            'source':
                'da3_streaming.py pcd/{chunk_idx}_pcd.ply + combined_pcd.ply',
            'conf_threshold_coef_from_base_config': 0.75,
            'why_not_baseline':
                'uses full chunk/aligned chunk PLY path, not official save-frame/core results_output frame_*.npz downstream selected by DepthStage',
          },
          'product_adaptation_not_official_da3': [
            'metricDepthPath meter alignment',
            'voxel_downsample',
            'statistical_outlier_prune',
            'normal_estimation',
            'minimum point count quality gate',
          ],
          'voxel_size_m': 0.003,
          'frame_skip': 1,
          'confidence_min_policy':
              'consume depth_index confidencePath/stats after official DA3-Streaming predictions.conf -= 1.0; do not use raw depth_conf',
          'confidence_contract':
              'aether_da3_confidence_contract_v1: official_da3_streaming_confidence_minus_one',
          'depth_units':
              'official_relative_depth_from_relativeDepthPath; metricDepthPath is product adaptation only',
          'apply_window_to_root_sim3': true,
          'normal_policy': 'estimate_after_voxel_dedup',
          'quality_gate_min_points': 10000,
        },
      );
    case PipelineStage.mesh:
      return _kernelStageSpec(
        stageName: 'mesh',
        schemaVersion: 'aether_mesh_stage_spec_v1',
        inputs: const ['stages/pointcloud/pointcloud.ply'],
        dartOwns: const [
          'surface reconstruction algorithm choice',
          'Poisson depth and trimming parameters',
          'fallback policy',
          'watertightness/face count quality gates',
        ],
        executorOwns: const [
          'Poisson/BPA kernel execution',
          'mesh memory buffers',
          'mesh file writes',
        ],
        parameters: const {
          'primary_algorithm': 'poisson_reconstruction',
          'poisson_version': 'V18.76',
          'depth': 10,
          'samples_per_node': 1.5,
          'trim_policy': 'dart_quality_gate',
          'quality_gate_min_faces': 1000,
        },
      );
    case PipelineStage.texture:
      return _kernelStageSpec(
        stageName: 'texture',
        schemaVersion: 'aether_texture_stage_spec_v1',
        inputs: const [
          'stages/mesh/mesh.ply',
          'photo_bundle.json',
          'photos_highres/*.jpg',
          'stages/depth/depth_index.json',
        ],
        dartOwns: const [
          'UV unwrap parameters',
          'photo selection and incidence policy',
          'highlight/material handoff',
          'atlas size and quality gates',
          'failed-face fallback policy',
        ],
        executorOwns: const [
          'xatlas unwrap kernels',
          'texture bake sampling kernels',
          'image encode writes',
        ],
        parameters: const {
          'uv_unwrap': 'xatlas',
          'atlas_size_px': 2048,
          'photo_selection': 'best_incidence_angle_then_confidence',
          'highlight_material_role': 'consume_material_descriptor_report',
          'quality_gate_min_textured_face_ratio': 0.85,
        },
      );
    case PipelineStage.compress:
      return _kernelStageSpec(
        stageName: 'compress',
        schemaVersion: 'aether_compress_stage_spec_v1',
        inputs: const ['stages/texture/mesh.obj', 'stages/texture/atlas.png'],
        dartOwns: const [
          'target format',
          'meshoptimizer parameters',
          'KTX2/BasisU parameters',
          'LOD and fallback policy',
          'final artifact quality gate',
        ],
        executorOwns: const [
          'meshoptimizer calls',
          'texture compression calls',
          'GLB byte writes',
        ],
        parameters: const {
          'target_format': 'glb',
          'meshoptimizer': {
            'simplify_target_ratio': 0.65,
            'preserve_boundaries': true,
            'optimize_vertex_cache': true,
          },
          'texture_compression': {
            'format': 'ktx2_basisu',
            'quality': 'uastc_medium',
          },
          'quality_gate_output_exists': true,
        },
      );
  }
}

Map<String, Object?> _kernelStageSpec({
  required String stageName,
  required String schemaVersion,
  required List<String> inputs,
  required List<String> dartOwns,
  required List<String> executorOwns,
  required Map<String, Object?> parameters,
}) {
  return {
    'schema_version': schemaVersion,
    'stage': stageName,
    'owner': 'Flutter/Dart',
    'inputs': inputs,
    'parameters': parameters,
    'algorithm_executor_boundary': _algorithmExecutorBoundaryContract(
      stageName: 'stage.$stageName',
      dartOwns: dartOwns,
      executorOwns: executorOwns,
      executorMustNotOwn: const [
        'algorithm selection',
        'quality gates',
        'fallback policy',
        'artifact naming',
        'downstream consumption rules',
      ],
    ),
  };
}

Future<void> _writeStageKernelContract({
  required Directory outputDir,
  required Map<String, Object?> spec,
  required String status,
  required Map<String, Object?> outputs,
}) async {
  final report = {
    'schema_version': 'aether_kernel_stage_report_v1',
    'stage': spec['stage'],
    'status': status,
    'spec_path': 'stage_spec.json',
    'outputs': outputs,
    'quality_gate': {
      'owner': 'Flutter/Dart',
      'status': status == 'stub_contract_only' ? 'not_run_stub' : 'pass',
    },
  };
  await File('${outputDir.path}/stage_spec.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert(spec),
    flush: true,
  );
  await File('${outputDir.path}/stage_report.json').writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
}

// ─── Orchestrator ───────────────────────────────────────────────────

/// Runs the five post-capture stages serially with per-stage disk
/// checkpoint. See file-top comment for lifecycle + resume semantics.
class LocalPipelineRunner {
  /// Capture root: must already contain a `photos/` subdir with the
  /// cell-admitted JPEGs + JSONs the depth stage will consume.
  final Directory captureDir;

  /// Override the stage list (test seam — production callers leave
  /// this null and get the default 5-stage pipeline).
  final List<PipelineStageRunner> _stages;
  final PhotoBundleDerivationService _photoBundleDerivationService;
  final bool _derivePhotoBundleInBackground;
  final DeviceHealthProbe _deviceHealthProbe;
  final DeviceHealthPolicy _deviceHealthPolicy;

  final _controller = StreamController<PipelineEvent>.broadcast(sync: true);

  /// Subscribe before calling [run]; the controller is broadcast so
  /// multiple listeners are fine but late subscribers miss early
  /// events.
  Stream<PipelineEvent> get stream => _controller.stream;

  bool _disposed = false;

  LocalPipelineRunner({
    required this.captureDir,
    List<PipelineStageRunner>? stages,
    PhotoBundleDerivationService? photoBundleDerivationService,
    bool? derivePhotoBundleInBackground,
    DeviceHealthProbe? deviceHealthProbe,
    DeviceHealthPolicy? deviceHealthPolicy,
  }) : _photoBundleDerivationService =
           photoBundleDerivationService ??
           _defaultPhotoBundleDerivationService(),
       _derivePhotoBundleInBackground =
           derivePhotoBundleInBackground ??
           (photoBundleDerivationService == null),
       _deviceHealthProbe =
           deviceHealthProbe ?? const MethodChannelDeviceHealthProbe(),
       _deviceHealthPolicy = deviceHealthPolicy ?? const DeviceHealthPolicy(),
       _stages =
           stages ??
           const <PipelineStageRunner>[
             DepthStage(),
             PointCloudStage(),
             MeshStage(),
             TextureStage(),
             CompressStage(),
           ];

  /// Number of stages this runner will execute (5 in the default
  /// pipeline; test seam configs may shorten).
  int get stageCount => _stages.length;

  /// Run all stages serially. Resumable: any stage whose `done.json`
  /// already exists is skipped (caller can wipe `stages/<name>/` to
  /// force re-run of a specific stage).
  ///
  /// Returns when either:
  ///   - All stages succeed (emits [PipelineCompletedEvent]).
  ///   - A stage throws (emits [PipelineErrorEvent], returns
  ///     without advancing). Caller can call [run] again to retry from
  ///     the failed stage.
  Future<void> run() async {
    if (_disposed) {
      throw StateError('LocalPipelineRunner.run() after dispose()');
    }
    final started = DateTime.now();
    _appendPipelineTrace('run_start', {
      'captureDir': captureDir.path,
      'stageCount': _stages.length,
      'stages': [for (final stage in _stages) pipelineStageName(stage.stage)],
      'deviceHealthPolicy': _deviceHealthPolicy.toJson(),
    });

    try {
      await _derivePhotoBundleSidecarsIfPresent(started);
      _appendPipelineTrace('photo_bundle_derivation_done', {
        'captureDir': captureDir.path,
      });
    } catch (e) {
      _appendPipelineTrace('photo_bundle_derivation_error', {
        'captureDir': captureDir.path,
        'error': '$e',
      });
      _controller.add(
        PipelineErrorEvent(
          PipelineError(
            stage: PipelineStage.depth,
            code: 'photo_bundle_derivation_failed',
            message: '$e',
            isRetryable: true,
          ),
        ),
      );
      return;
    }

    final stagesRoot = Directory('${captureDir.path}/stages');
    if (!stagesRoot.existsSync()) {
      stagesRoot.createSync(recursive: true);
    }

    var prevOutputDir = _initialPhotoInputDir();

    for (var i = 0; i < _stages.length; i++) {
      final s = _stages[i];
      final outDir = Directory('${stagesRoot.path}/${s.outputDirName}');
      if (!outDir.existsSync()) {
        outDir.createSync(recursive: true);
      }
      _appendPipelineTrace('stage_prepare', {
        'stage': pipelineStageName(s.stage),
        'stageIndex': i,
        'outputDir': outDir.path,
      });

      if (await s.isComplete(outDir)) {
        // Skipped-stage notice so the UI can advance its progress bar
        // through cached stages. overallFraction lands at
        // (i + 1) / N — the same value the stage would reach on its
        // final tick.
        _emitProgress(
          stage: s.stage,
          stageFraction: 1.0,
          overallStageIndex: i,
          startedAt: started,
          detail: 'skipped (cached)',
          metadata: {'outputDir': outDir.path, 'reason': 'done_marker_present'},
        );
        prevOutputDir = outDir;
        continue;
      }

      final healthAllowsStage = await _applyDeviceHealthPolicy(
        stage: s.stage,
        overallStageIndex: i,
        startedAt: started,
        reason: 'pre_stage',
      );
      if (!healthAllowsStage) {
        return;
      }

      // Wire the stage's internal progress sink to the public event
      // stream. The stage emits StageProgress, we wrap it in
      // PipelineProgressEvent with overall-fraction filled in.
      final stageSink = StreamController<StageProgress>();
      final stageSub = stageSink.stream.listen((sp) {
        _emitProgress(
          stage: s.stage,
          stageFraction: sp.stageFraction,
          overallStageIndex: i,
          startedAt: started,
          detail: sp.detail,
          metadata: sp.metadata,
        );
      });

      try {
        _appendPipelineTrace('stage_start', {
          'stage': pipelineStageName(s.stage),
          'stageIndex': i,
          'inputDir': prevOutputDir.path,
          'outputDir': outDir.path,
        });
        await s.run(
          inputDir: prevOutputDir,
          outputDir: outDir,
          progressSink: stageSink.sink,
        );
        // Guarantee a final 1.00 tick even if the stage forgot to
        // emit one (defensive — stubs do, but real stages might).
        _emitProgress(
          stage: s.stage,
          stageFraction: 1.0,
          overallStageIndex: i,
          startedAt: started,
          detail: 'done',
          metadata: {'outputDir': outDir.path},
        );
        _appendPipelineTrace('stage_done', {
          'stage': pipelineStageName(s.stage),
          'stageIndex': i,
          'outputDir': outDir.path,
          'elapsedMs': DateTime.now().difference(started).inMilliseconds,
        });
      } catch (e, st) {
        _appendPipelineTrace('stage_error', {
          'stage': pipelineStageName(s.stage),
          'stageIndex': i,
          'outputDir': outDir.path,
          'error': '$e',
          'stack': '$st',
          'elapsedMs': DateTime.now().difference(started).inMilliseconds,
        });
        _controller.add(
          PipelineErrorEvent(
            PipelineError(
              stage: s.stage,
              code: 'stage_threw',
              message: '$e',
              isRetryable: true,
            ),
          ),
        );
        await stageSub.cancel();
        await stageSink.close();
        return;
      }

      await stageSub.cancel();
      await stageSink.close();
      prevOutputDir = outDir;
    }

    _controller.add(
      PipelineCompletedEvent(
        outputGlb: File('${prevOutputDir.path}/output.glb'),
        totalElapsed: DateTime.now().difference(started),
      ),
    );
    _appendPipelineTrace('run_done', {
      'captureDir': captureDir.path,
      'elapsedMs': DateTime.now().difference(started).inMilliseconds,
      'outputGlb': '${prevOutputDir.path}/output.glb',
    });
  }

  Future<bool> _applyDeviceHealthPolicy({
    required PipelineStage stage,
    required int overallStageIndex,
    required DateTime startedAt,
    required String reason,
  }) async {
    final snapshot = await _deviceHealthProbe.sample(
      stage: stage,
      reason: reason,
    );
    var decisionSnapshot = snapshot;
    var decision = _deviceHealthPolicy.evaluate(
      stage: stage,
      snapshot: snapshot,
    );
    _appendDeviceHealthTrace(
      stage: stage,
      reason: reason,
      snapshot: snapshot,
      decision: decision,
    );

    if (decision.action == DeviceHealthAction.pause) {
      _emitProgress(
        stage: stage,
        stageFraction: 0.0,
        overallStageIndex: overallStageIndex,
        startedAt: startedAt,
        detail: decision.message,
        metadata: {
          'deviceHealth': {
            'snapshot': snapshot.toJson(),
            'decision': decision.toJson(),
          },
        },
      );
      await Future<void>.delayed(decision.pause);

      final afterPause = await _deviceHealthProbe.sample(
        stage: stage,
        reason: 'post_policy_pause',
      );
      decision = _deviceHealthPolicy.evaluate(
        stage: stage,
        snapshot: afterPause,
      );
      decisionSnapshot = afterPause;
      _appendDeviceHealthTrace(
        stage: stage,
        reason: 'post_policy_pause',
        snapshot: afterPause,
        decision: decision,
      );
      if (decision.action == DeviceHealthAction.pause) {
        decision = DeviceHealthDecision(
          action: DeviceHealthAction.markHighRisk,
          code: 'thermal_serious_continue_after_single_pause',
          message:
              '${pipelineStageName(stage)} continues after one Dart-owned cooldown pause; native telemetry remains serious',
        );
        _appendDeviceHealthTrace(
          stage: stage,
          reason: 'post_policy_pause_fallback',
          snapshot: afterPause,
          decision: decision,
        );
      }
    }

    if (decision.action == DeviceHealthAction.markHighRisk) {
      _emitProgress(
        stage: stage,
        stageFraction: 0.0,
        overallStageIndex: overallStageIndex,
        startedAt: startedAt,
        detail: decision.message,
        metadata: {
          'deviceHealth': {
            'snapshot': decisionSnapshot.toJson(),
            'decision': decision.toJson(),
          },
        },
      );
      return true;
    }

    if (decision.action == DeviceHealthAction.abort) {
      _controller.add(
        PipelineErrorEvent(
          PipelineError(
            stage: stage,
            code: decision.code,
            message: decision.message,
            isRetryable: decision.isRetryable,
          ),
        ),
      );
      return false;
    }

    return true;
  }

  void _appendDeviceHealthTrace({
    required PipelineStage stage,
    required String reason,
    required DeviceHealthSnapshot snapshot,
    required DeviceHealthDecision decision,
  }) {
    _appendPipelineTrace('device_health_policy', {
      'stage': pipelineStageName(stage),
      'reason': reason,
      'policy': _deviceHealthPolicy.toJson(),
      'snapshot': snapshot.toJson(),
      'decision': decision.toJson(),
    });
  }

  Future<void> _derivePhotoBundleSidecarsIfPresent(DateTime started) async {
    final manifest = File('${captureDir.path}/photo_bundle.json');
    if (!manifest.existsSync()) return;

    _emitProgress(
      stage: PipelineStage.depth,
      stageFraction: 0.0,
      overallStageIndex: 0,
      startedAt: started,
      detail: 'deriving photo bundle sidecars',
    );
    final result = _derivePhotoBundleInBackground
        ? await _derivePhotoBundleSidecarsOnWorker(captureDir.path)
        : _PhotoBundleDerivationSummary.fromResult(
            await _photoBundleDerivationService.deriveDirectory(captureDir),
          );
    _emitProgress(
      stage: PipelineStage.depth,
      stageFraction: 0.0,
      overallStageIndex: 0,
      startedAt: started,
      detail:
          'photo bundle ${result.status}: ${result.frameCount} frames, ${result.edgeCount} graph edges, ${result.colmapFrameCount} COLMAP images',
    );
  }

  Directory _initialPhotoInputDir() {
    final manifest = File('${captureDir.path}/photo_bundle.json');
    if (!manifest.existsSync()) {
      return Directory('${captureDir.path}/photos');
    }
    try {
      final decoded = jsonDecode(manifest.readAsStringSync());
      if (decoded is Map<String, Object?>) {
        final photosDir = decoded['photosHighresDir'];
        if (photosDir is String && photosDir.trim().isNotEmpty) {
          return Directory(_joinPath(captureDir.path, photosDir.trim()));
        }
      }
    } catch (_) {
      // Derivation validation reports malformed manifests; this fallback keeps
      // legacy bundles retryable while preserving the old directory name.
    }
    return Directory('${captureDir.path}/photos_highres');
  }

  void _emitProgress({
    required PipelineStage stage,
    required double stageFraction,
    required int overallStageIndex,
    required DateTime startedAt,
    String? detail,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final overall =
        (overallStageIndex + stageFraction.clamp(0.0, 1.0)) / _stages.length;
    _appendPipelineTrace('progress', {
      'stage': pipelineStageName(stage),
      'stageFraction': stageFraction,
      'overallFraction': overall,
      'detail': detail,
      'elapsedMs': DateTime.now().difference(startedAt).inMilliseconds,
      if (metadata.isNotEmpty) 'metadata': metadata,
    });
    _controller.add(
      PipelineProgressEvent(
        PipelineProgress(
          stage: stage,
          stageFraction: stageFraction,
          overallFraction: overall,
          detail: detail,
          elapsed: DateTime.now().difference(startedAt),
        ),
      ),
    );
  }

  void _appendPipelineTrace(String event, Map<String, Object?> fields) {
    _PipelineTraceLog(captureDir).append(event, fields);
  }

  /// Closes the broadcast controller; safe to call once. Calling
  /// [run] after [dispose] throws.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _controller.close();
  }
}

String _joinPath(String left, String right) {
  if (left.endsWith(Platform.pathSeparator)) return '$left$right';
  return '$left${Platform.pathSeparator}$right';
}

Future<Map<String, Object?>> _readJsonMap(File file) async {
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) {
    throw FormatException('${file.path} is not a JSON object');
  }
  return decoded.cast<String, Object?>();
}

List<Da3DepthFrameSpec> _frameSpecsFromManifest({
  required Directory captureDir,
  required Directory inputDir,
  required Map<String, Object?> manifest,
  Map<String, Object?> da3InputManifest = const <String, Object?>{},
}) {
  final photosDir = _asString(
    manifest['photosHighresDir'],
    fallback: inputDir.path.split(Platform.pathSeparator).last,
  );
  final frames = _maps(manifest['frames']);
  final da3InputByID = <String, Map<String, Object?>>{
    for (final entry in _maps(da3InputManifest['frames']))
      _asString(entry['id']): entry,
  };
  return [
    for (var i = 0; i < frames.length; i++)
      _frameSpecFromManifestFrame(
        captureDir: captureDir,
        photosDir: photosDir,
        frame: frames[i],
        index: i,
        da3Input: da3InputByID[_asString(frames[i]['id'])],
      ),
  ];
}

Da3DepthFrameSpec _frameSpecFromManifestFrame({
  required Directory captureDir,
  required String photosDir,
  required Map<String, Object?> frame,
  required int index,
  Map<String, Object?>? da3Input,
}) {
  final id = _asString(
    frame['id'],
    fallback: 'frame_${index.toString().padLeft(4, '0')}',
  );
  final filename = _asString(
    frame['highresFilename'],
    fallback: _asString(frame['filename'], fallback: '$id.jpg'),
  );
  final sourceRelativePath = _joinRelativePath(photosDir, filename);
  final depthRelativePath = _asString(
    da3Input?['depthImageRelativePath'],
    fallback: sourceRelativePath,
  );
  final tensorRelativePath = _nullableString(
    da3Input?['imageTensorFloat32ChwRelativePath'],
  );
  final inputWidth = _nullableInt(da3Input?['inputWidth']);
  final inputHeight = _nullableInt(da3Input?['inputHeight']);
  final cameraTransform = _doubleList(frame['cameraTransform']);
  final intrinsics = _doubleList(frame['intrinsics']);
  final cameraExtrinsicOpenCvW2c4x4 = _da3CameraExtrinsicOpenCvW2c4x4(
    frame: frame,
    da3Input: da3Input,
    cameraTransform: cameraTransform,
  );
  final cameraIntrinsic3x3 = _da3CameraIntrinsic3x3(
    frame: frame,
    da3Input: da3Input,
    intrinsics: intrinsics,
    inputWidth: inputWidth,
    inputHeight: inputHeight,
  );
  return Da3DepthFrameSpec(
    frameID: id,
    frameIndex: index,
    imagePath: _joinPath(captureDir.path, depthRelativePath),
    imageRelativePath: depthRelativePath,
    imageTensorFloat32ChwPath: tensorRelativePath == null
        ? null
        : _joinPath(captureDir.path, tensorRelativePath),
    imageTensorFloat32ChwRelativePath: tensorRelativePath,
    sourceImagePath: _joinPath(captureDir.path, sourceRelativePath),
    sourceImageRelativePath: sourceRelativePath,
    cameraTransform: cameraTransform,
    intrinsics: intrinsics,
    cameraExtrinsicOpenCvW2c4x4: cameraExtrinsicOpenCvW2c4x4,
    cameraIntrinsic3x3: cameraIntrinsic3x3,
    imageWidth: _nullableInt(frame['imageWidth']),
    imageHeight: _nullableInt(frame['imageHeight']),
    inputWidth: inputWidth,
    inputHeight: inputHeight,
    preprocessTransform: _mapValue(da3Input?['transform']),
    timestamp: _nullableDouble(frame['timestamp']),
  );
}

List<double> _da3CameraExtrinsicOpenCvW2c4x4({
  required Map<String, Object?> frame,
  required Map<String, Object?>? da3Input,
  required List<double> cameraTransform,
}) {
  final precomputed = _doubleList(da3Input?['cameraExtrinsicOpenCvW2c4x4']);
  if (precomputed.length == 16) return precomputed;
  return Da3CameraContract.opencvWorldToCameraFromArkitCameraTransform(
    cameraTransform,
  );
}

List<double> _da3CameraIntrinsic3x3({
  required Map<String, Object?> frame,
  required Map<String, Object?>? da3Input,
  required List<double> intrinsics,
  required int? inputWidth,
  required int? inputHeight,
}) {
  final precomputed = _doubleList(da3Input?['cameraIntrinsic3x3']);
  if (precomputed.length == 9) return precomputed;

  final width = inputWidth ?? _nullableInt(frame['imageWidth']) ?? 0;
  final height = inputHeight ?? _nullableInt(frame['imageHeight']) ?? 0;
  final sourceWidth = _nullableInt(frame['imageWidth']) ?? width;
  final sourceHeight = _nullableInt(frame['imageHeight']) ?? height;
  final transform = _mapValue(da3Input?['intrinsicsTransform']);
  return Da3CameraContract.scaledIntrinsics3x3(
    intrinsics: intrinsics,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
    inputWidth: width,
    inputHeight: height,
    fxScale: _nullableDouble(transform['fxScale']),
    fyScale: _nullableDouble(transform['fyScale']),
    cxScale: _nullableDouble(transform['cxScale']),
    cyScale: _nullableDouble(transform['cyScale']),
    cxOffset: _nullableDouble(transform['cxOffset']) ?? 0.0,
    cyOffset: _nullableDouble(transform['cyOffset']) ?? 0.0,
  );
}

List<MetricDepthAlignmentFrame> _metricDepthAlignmentFrames({
  required List<Da3DepthFrameSpec> frameSpecs,
  required List<Da3DepthFrameResult> orderedResults,
}) {
  final sourceByID = {for (final frame in frameSpecs) frame.frameID: frame};
  return [
    for (final result in orderedResults)
      if (sourceByID[result.frameID] != null)
        MetricDepthAlignmentFrame(
          frameID: result.frameID,
          frameIndex: sourceByID[result.frameID]!.frameIndex,
          status: result.status,
          sourceImageRelativePath:
              sourceByID[result.frameID]!.sourceImageRelativePath,
          relativeDepthPath: result.relativeDepthPath,
          confidencePath: result.confidencePath,
          depthWidth: result.depthWidth,
          depthHeight: result.depthHeight,
          imageWidth: sourceByID[result.frameID]!.imageWidth,
          imageHeight: sourceByID[result.frameID]!.imageHeight,
          cameraTransform: sourceByID[result.frameID]!.cameraTransform,
          intrinsics: sourceByID[result.frameID]!.intrinsics,
          preprocessTransform: sourceByID[result.frameID]!.preprocessTransform,
        ),
  ];
}

String _depthStageStatus({
  required int total,
  required int completed,
  required int pending,
  required int failed,
}) {
  if (total == 0) return 'empty';
  if (failed > 0 && completed == 0) return 'failed';
  if (failed > 0) return 'partial_failed';
  if (pending > 0 && completed == 0) return 'pending';
  if (pending > 0) return 'partial_pending';
  return 'completed';
}

Map<String, Map<String, Object?>> _streamingWindowTransformsByID(
  Map<String, Object?> streamingAlignment,
) {
  final out = <String, Map<String, Object?>>{};
  for (final item in _maps(streamingAlignment['windowTransforms'])) {
    final windowID = _asString(item['windowID']);
    if (windowID.isEmpty) continue;
    out[windowID] = item;
  }
  return out;
}

Map<String, Object?> _buildDa3RealDeviceAudit({
  required Map<String, Object?> model,
  required Map<String, Object?> kWindowsPlan,
  required List<Map<String, Object?>> windowReports,
  required List<Da3DepthFrameResult> orderedResults,
  required Map<String, Object?> visualLoopRetrieval,
  required Map<String, Object?> denseSim3Verification,
}) {
  final windows = _maps(kWindowsPlan['windows']);
  final windowingPolicy = _mapValue(kWindowsPlan['windowingPolicy']);
  final bridgeGraph = _maps(kWindowsPlan['bridgeGraph']);
  final denseCounts = _mapValue(denseSim3Verification['counts']);
  final densePerformance = _mapValue(denseSim3Verification['performance']);
  final denseStatus = _asString(denseSim3Verification['status']);
  final streamingAlignment = _mapValue(
    denseSim3Verification['streaming_alignment'],
  );
  final streamingTransforms = _maps(streamingAlignment['windowTransforms']);
  final visualPolicy = _mapValue(visualLoopRetrieval['policy']);
  final algorithmExecutorBoundary = _mapValue(
    _da3RuntimeContract(model)['algorithmExecutorBoundary'],
  );
  final modelInputContract = _da3ModelInputContract(model);
  final officialImageOnlyModel = _isOfficialDa3StreamingImageOnlyModel(model);
  final poseConditionedModel = _isPoseConditionedDa3Model(model);
  final completedResults = orderedResults.where((r) => r.isCompleted).toList();
  final completedWindowReports = windowReports
      .where((window) => _asString(window['status']) == 'completed')
      .toList();
  final windowTelemetry = [
    for (final window in windowReports)
      if (_mapValue(window['telemetry']).isNotEmpty)
        {
          'windowID': _asString(window['windowID']),
          ..._mapValue(window['telemetry']),
        },
  ];
  final checks = <Map<String, Object?>>[
    _auditCheck(
      id: 'dart_spec_thin_executor_report_boundary_locked',
      passed:
          _asString(algorithmExecutorBoundary['schemaVersion']) ==
              'aether_algorithm_executor_boundary_v1' &&
          _asString(algorithmExecutorBoundary['policyOwner']) ==
              'Flutter/Dart' &&
          _asString(algorithmExecutorBoundary['executorRole']) ==
              'thin_executor_only',
      expected:
          'Dart sealed spec -> thin native executor -> Dart report/audit; no native-owned algorithm policy',
      observed: algorithmExecutorBoundary,
    ),
    _auditCheck(
      id: 'official_da3_base_k35_image_only_504x280',
      passed:
          _asString(model['id']) == 'DA3-BASE' &&
          _isAllowedDa3BaseK35Resource(model) &&
          _nullableInt(model['windowSize']) == 35 &&
          _nullableInt(model['inputWidth']) == 504 &&
          _nullableInt(model['inputHeight']) == 280 &&
          _isOfficialDa3StreamingImageOnlyModel(model),
      expected:
          'commercial DA3-BASE / K35 / official process_res=504 upper_bound_resize image-only resource',
      observed: {
        'id': model['id'],
        'resourceName': model['resourceName'],
        'windowSize': model['windowSize'],
        'inputWidth': model['inputWidth'],
        'inputHeight': model['inputHeight'],
        'processRes': model['processRes'],
        'processResMethod': model['processResMethod'],
        'da3InputContract': model['da3InputContract'],
      },
    ),
    _auditCheck(
      id: 'official_streaming_image_only_coreml_contract',
      passed: officialImageOnlyModel,
      expected:
          'official DA3-Streaming baseline uses image-only CoreML: image input, no extrinsics/intrinsics input',
      observed: {
        'resourceName': model['resourceName'],
        'da3InputContract': modelInputContract,
        'officialStreamingBaseline': _truthy(
          model['officialStreamingBaseline'],
        ),
        'officialStreamingBaselineStatus': _asString(
          model['officialStreamingBaselineStatus'],
        ),
        'poseConditionedCompatibilityModel': poseConditionedModel,
      },
    ),
    _auditCheck(
      id: 'official_streaming_windowing_not_pose_graph_adaptation',
      passed:
          _asString(windowingPolicy['kind']) ==
          'official_streaming_ordered_image_chunks_v1',
      expected:
          'official DA3-Streaming chunks ordered image sequences and does not use AR/VIO pose graph topology as model input policy',
      observed: {
        'kind': windowingPolicy['kind'],
        'officialReference': windowingPolicy['officialReference'],
        'officialStreamingDefaultMatch':
            windowingPolicy['officialStreamingDefaultMatch'],
      },
    ),
    _auditCheck(
      id: 'no_da3_large_or_noncommercial_resource',
      passed:
          !_asString(model['resourceName']).toUpperCase().contains('LARGE') &&
          !_asString(model['resourceName']).toUpperCase().contains('GIANT') &&
          !_asString(model['resourceName']).toUpperCase().contains('NESTED') &&
          _asString(model['license']).toLowerCase() == 'apache-2.0',
      expected: 'commercial-safe Apache-2.0 DA3-BASE only',
      observed: {
        'license': model['license'],
        'resourceName': model['resourceName'],
      },
    ),
    _auditCheck(
      id: 'all_windows_have_35_frame_slots',
      passed: windows.every(
        (window) => _strings(window['frameIDs']).length == 35,
      ),
      expected: 'every DA3 window has exactly 35 slots after padding',
      observed: {
        'windowCount': windows.length,
        'frameSlotCounts': [
          for (final window in windows)
            {
              'windowID': _asString(window['id']),
              'frameSlots': _strings(window['frameIDs']).length,
              'uniqueFrames': _strings(window['uniqueFrameIDs']).length,
            },
        ],
      },
    ),
    _auditCheck(
      id: 'bridge_overlap_policy_locked',
      passed:
          _nullableInt(windowingPolicy['targetBridgeOverlap']) == 18 &&
          _nullableInt(windowingPolicy['stepEquivalent']) == 17,
      expected: 'K35 half-window bridge: overlap 18, step equivalent 17',
      observed: {
        'targetBridgeOverlap': windowingPolicy['targetBridgeOverlap'],
        'stepEquivalent': windowingPolicy['stepEquivalent'],
      },
    ),
    _auditCheck(
      id: 'visual_retrieval_is_abstract_not_salad_bound',
      passed:
          _asString(visualLoopRetrieval['executor']) ==
              'VisualLoopRetrievalExecutor' &&
          _asString(visualPolicy['selectedBackend']) == 'SelaVPR++' &&
          _strings(
            visualPolicy['blockedBundledBackends'],
          ).contains('GPL-3.0 SALAD reference implementation'),
      expected:
          'pluggable commercial-safe descriptor backend defaults to SelaVPR++; no bundled GPL SALAD',
      observed: {
        'status': visualLoopRetrieval['status'],
        'executor': visualLoopRetrieval['executor'],
        'selectedBackend': visualPolicy['selectedBackend'],
        'blockedBundledBackends': visualPolicy['blockedBundledBackends'],
      },
    ),
    _auditCheck(
      id: 'dense_sim3_report_present',
      passed:
          _asString(denseSim3Verification['method']) ==
          'official_streaming_weighted_point_map_sim3_dart_v1',
      expected:
          'Dart dense Sim3 report written after DA3 with official DA3-Streaming-style point-map weighted Sim3',
      observed: {
        'status': denseSim3Verification['status'],
        'method': denseSim3Verification['method'],
      },
    ),
    _auditCheck(
      id: 'official_streaming_alignment_chain_present',
      passed:
          _asString(streamingAlignment['status']) ==
              'ready_for_downstream_application' &&
          streamingTransforms.length == windows.length &&
          streamingTransforms.every(
            (item) =>
                _asString(item['status']) == 'aligned' &&
                _mapValue(item['sim3']).isNotEmpty,
          ),
      expected:
          'dense Sim3 bridge transforms are accumulated into per-window window_to_root Sim3 before downstream geometry',
      observed: {
        'status': streamingAlignment['status'],
        'windowCount': windows.length,
        'transformCount': streamingTransforms.length,
        'alignedWindowCount': streamingAlignment['alignedWindowCount'],
        'unalignedWindowIDs': streamingAlignment['unalignedWindowIDs'],
      },
      warningWhenFalse: denseStatus != 'passed',
    ),
    _auditCheck(
      id: 'official_sim3_loop_optimizer_contract_present',
      passed:
          _asString(
            _mapValue(streamingAlignment['loopOptimizer'])['executor'],
          ).contains('OfficialSim3LoopOptimizer') &&
          _asString(
                _mapValue(streamingAlignment['loopOptimizer'])['policyOwner'],
              ) ==
              'Flutter/Dart',
      expected:
          'official DA3 Sim3LoopOptimizer is represented as a thin-executor contract after dense loop Sim3 constraints',
      observed: _mapValue(streamingAlignment['loopOptimizer']),
    ),
    _auditCheck(
      id: 'dense_sim3_truth_gate_passed',
      passed: denseStatus == 'passed',
      expected:
          'all required K-window bridge edges pass dense Sim3 before downstream geometry consumes DA3 outputs',
      observed: {
        'status': denseSim3Verification['status'],
        'bridgeTotal': denseCounts['bridge_total'],
        'bridgeAccepted': denseCounts['bridge_accepted'],
        'bridgeRejected': denseCounts['bridge_rejected'],
        'bridgeInconclusive': denseCounts['bridge_inconclusive'],
        'bridgePending': denseCounts['bridge_pending'],
      },
    ),
    _auditCheck(
      id: 'bridge_edges_sent_to_dense_sim3',
      passed: _nullableInt(denseCounts['bridge_total']) == bridgeGraph.length,
      expected: 'every K-window tree bridge appears in dense Sim3 verification',
      observed: {
        'kWindowBridgeEdges': bridgeGraph.length,
        'denseSim3BridgeEdges': denseCounts['bridge_total'],
        'denseSim3Accepted': denseCounts['bridge_accepted'],
        'denseSim3Inconclusive': denseCounts['bridge_inconclusive'],
        'denseSim3Rejected': denseCounts['bridge_rejected'],
      },
    ),
    _auditCheck(
      id: 'completed_frames_have_da3_outputs',
      passed:
          completedResults.isNotEmpty &&
          completedResults.every(
            (result) =>
                _nullableString(result.relativeDepthPath) != null &&
                _nullableString(result.confidencePath) != null &&
                _nullableString(result.predExtrinsicsPath) != null &&
                _nullableString(result.predIntrinsicsPath) != null,
          ),
      expected: 'every completed frame has depth/confidence/pred pose paths',
      observed: {
        'completed': completedResults.length,
        'total': orderedResults.length,
      },
      warningWhenFalse: completedResults.isEmpty,
    ),
    _auditCheck(
      id: 'native_window_telemetry_present',
      passed:
          completedWindowReports.isEmpty ||
          (windowTelemetry.length == completedWindowReports.length &&
              windowTelemetry.every((telemetry) {
                final cpu = _mapValue(telemetry['cpu']);
                return telemetry['loadMs'] != null &&
                    telemetry['inferenceMs'] != null &&
                    telemetry['rssPeakApproxMB'] != null &&
                    cpu['peakDeviceNormalizedPercent'] != null;
              })),
      expected:
          'completed iOS DA3 windows preserve load/infer/RSS/CPU telemetry',
      observed: {
        'completedWindows': completedWindowReports.length,
        'telemetryWindows': windowTelemetry.length,
        'telemetry': windowTelemetry,
      },
      warningWhenFalse: true,
    ),
  ];
  final failed = checks.where((check) => check['status'] == 'fail').length;
  final warnings = checks.where((check) => check['status'] == 'warning').length;
  final status = failed > 0 ? 'fail' : (warnings > 0 ? 'warning' : 'pass');
  return {
    'schema_version': 'aether_da3_real_device_audit_v1',
    'status': status,
    'created_at_utc': DateTime.now().toUtc().toIso8601String(),
    'purpose':
        'single place to audit a real-device DA3 K35 official-image-only capture after shooting',
    'algorithmExecutorBoundary': algorithmExecutorBoundary,
    'checks': checks,
    'windowTelemetry': windowTelemetry,
    'denseSim3Performance': densePerformance,
    'extractTheseFilesAfterCapture': [
      'photo_bundle.json',
      'model_policy.json',
      'da3_k_windows.json',
      'da3_input_manifest.json',
      'pipeline_trace.jsonl',
      'stages/depth/local_da3_run_log.jsonl',
      'stages/depth/da3_dart_channel_log.jsonl',
      'stages/depth/da3_native_run_log.jsonl',
      'stages/depth/depth_index.json',
      'stages/depth/depth_runner_report.json',
      'stages/depth/visual_loop_retrieval_report.json',
      'stages/depth/dense_sim3_verification_report.json',
      'stages/depth/da3_real_device_audit.json',
    ],
    'phoneBenchmarkLogFieldsToPreserve': [
      'model title/resource',
      'compile/load ms',
      'infer ms',
      'rss before/after/peak MB',
      'jetsam available before/after MB',
      'cpu peak/mean one-core percent',
      'cpu peak/mean device-normalized percent',
      'depth/conf finite nan inf stats',
    ],
    'nextReviewFocus': [
      'K35 official process_res=504 image-only model actually used on device',
      'every non-root window has bridge frames and dense Sim3 status',
      'dense Sim3 has no rejected bridge edge before pointcloud/mesh',
      'visual loop retrieval remains abstract unless a commercial-safe backend is configured',
      'native telemetry load/infer/RSS/CPU is present when iOS adapter supports it',
    ],
  };
}

Map<String, Object?> _auditCheck({
  required String id,
  required bool passed,
  required Object? expected,
  required Object? observed,
  bool warningWhenFalse = false,
}) {
  return {
    'id': id,
    'status': passed ? 'pass' : (warningWhenFalse ? 'warning' : 'fail'),
    'expected': expected,
    'observed': observed,
  };
}

void _assertCommercialDa3Base(Map<String, Object?> model) {
  final id = _asString(model['id']).toUpperCase();
  final license = _asString(model['license']).toLowerCase();
  final commercialSafe = model['commercialSafe'] != false;
  final resource = _asString(model['resourceName']).toUpperCase();
  final windowSize = _nullableInt(model['windowSize']);
  final inputWidth = _nullableInt(model['inputWidth']);
  final inputHeight = _nullableInt(model['inputHeight']);
  if (id != 'DA3-BASE' ||
      license != 'apache-2.0' ||
      !commercialSafe ||
      !_isAllowedDa3BaseK35Resource(model) ||
      windowSize != 35 ||
      inputWidth != 504 ||
      inputHeight != 280 ||
      !_isOfficialDa3StreamingImageOnlyModel(model) ||
      resource.contains('DA3LARGE') ||
      resource.contains('GIANT') ||
      resource.contains('NESTED')) {
    throw FormatException(
      'Stage 1 only accepts commercial-safe DA3-BASE K35 image-only with official process_res=504 upper_bound_resize output shape 504x280 for 16:9 sources',
    );
  }
}

bool _isAllowedDa3BaseK35Resource(Map<String, Object?> model) {
  final resource = _asString(model['resourceName']).toUpperCase();
  return resource == 'DA3BASE_280X504_N35_IMAGE_ONLY';
}

bool _isPoseConditionedDa3Model(Map<String, Object?> model) {
  final contract = _da3ModelInputContract(model).toLowerCase();
  final resource = _asString(model['resourceName']).toLowerCase();
  return contract.contains('pose_conditioned') || resource.endsWith('_pose');
}

bool _isOfficialDa3StreamingImageOnlyModel(Map<String, Object?> model) {
  final contract = _da3ModelInputContract(model);
  return _truthy(model['officialStreamingBaseline']) &&
      contract == 'image_only' &&
      !_isPoseConditionedDa3Model(model);
}

String _da3ModelInputContract(Map<String, Object?> model) {
  final explicit = _asString(model['da3InputContract']);
  if (explicit.isNotEmpty) return explicit;
  final resource = _asString(model['resourceName']).toLowerCase();
  if (resource.endsWith('_pose')) {
    return 'pose_conditioned_coreml_requires_image_extrinsics_intrinsics';
  }
  return 'image_only';
}

Map<String, Object?> _algorithmExecutorBoundaryContract({
  required String stageName,
  required List<String> dartOwns,
  required List<String> executorOwns,
  required List<String> executorMustNotOwn,
}) {
  return {
    'schemaVersion': 'aether_algorithm_executor_boundary_v1',
    'stageName': stageName,
    'hardRule':
        'Dart sealed spec -> thin executor -> Dart report/audit -> next stage',
    'policyOwner': 'Flutter/Dart',
    'executorRole': 'thin_executor_only',
    'requiredBeforeAddingNativeCode': [
      'Dart sealed spec',
      'Dart report schema',
      'Dart audit/quality gate',
      'artifact naming and downstream handoff contract',
    ],
    'dartOwns': dartOwns,
    'executorOwns': executorOwns,
    'executorMustNotOwn': executorMustNotOwn,
    'nativeMayOnlyReturn': [
      'raw results',
      'artifact paths',
      'hardware telemetry',
      'structured error codes',
    ],
    'auditRule':
        'Reports must preserve this boundary so real-device captures can prove strategy stayed in Dart.',
  };
}

Map<String, Object?> _da3RuntimeContract(Map<String, Object?> model) {
  final resourceName = _asString(model['resourceName']);
  final windowSize = _nullableInt(model['windowSize']);
  final inputWidth = _nullableInt(model['inputWidth']);
  final inputHeight = _nullableInt(model['inputHeight']);
  final inputLocked = inputWidth != null && inputHeight != null;
  final modelInputContract = _da3ModelInputContract(model);
  final officialImageOnlyModel = _isOfficialDa3StreamingImageOnlyModel(model);
  return {
    'schemaVersion': 'aether_da3_runtime_contract_v1',
    'owner': 'Flutter/Dart pipeline policy',
    'seal': {
      'date': '2026-05-25',
      'configuration':
          'K35 official process_res=504 upper_bound_resize image-only',
      'reason':
          'match official DA3 image-only preprocessing; only K=35 differs',
    },
    'algorithmExecutorBoundary': _algorithmExecutorBoundaryContract(
      stageName: 'stage1.depth.da3',
      dartOwns: const [
        'model allowlist and commercial license gate',
        'K-window graph and bridge-frame policy',
        'official process_res=504 upper_bound_resize + patch-aligned input dimensions',
        'input/output artifact naming',
        'visual loop retrieval abstraction',
        'dense Sim3 verification policy',
        'metric-depth alignment policy from capture metadata anchors outside the official DA3 input contract',
        'official DA3 streaming baseline gate',
        'streaming alignment accumulation and downstream handoff',
        'geometry quality gate and audit schema',
      ],
      executorOwns: const [
        'CoreML model loading',
        'fixed-size tensor preparation for the sealed Dart spec',
        'CoreML forward pass',
        'float32 tensor file writes',
        'RSS/CPU/thermal/jetsam telemetry probes',
      ],
      executorMustNotOwn: const [
        'which DA3 model or K/resolution is selected',
        'which frames belong to each window',
        'bridge/loop acceptance policy',
        'relative-depth to meter conversion policy',
        'geometry pass/fail policy',
        'downstream pointcloud/mesh/highlight consumption rules',
      ],
    ),
    'model': {
      'id': _asString(model['id']),
      'resourceName': resourceName,
      'windowSize': ?windowSize,
      'inputWidth': ?inputWidth,
      'inputHeight': ?inputHeight,
      'inputSizeLocked': inputLocked,
      'inputSizeStatus': _asString(
        model['inputSizeStatus'],
        fallback: 'not_locked_by_policy',
      ),
      'da3InputContract': modelInputContract,
      'officialStreamingBaseline': officialImageOnlyModel,
      'officialStreamingBaselineStatus': _asString(
        model['officialStreamingBaselineStatus'],
        fallback: officialImageOnlyModel
            ? 'ready'
            : 'blocked_until_image_only_coreml_signature',
      ),
    },
    'officialStreamingBaseline': {
      'requiredInputContract': 'image_only',
      'requiredExternalCameraInputs': false,
      'officialCall':
          'model.inference(images, ref_view_strategy=...) from DA3-Streaming',
      'currentInputContract': modelInputContract,
      'currentModelIsOfficialStreamingDefault': officialImageOnlyModel,
      'arkitVioRole': 'metadata_only_not_da3_input',
    },
    'runtimeBoundary': {
      'flutterOwns': [
        'commercial model selection',
        'K-window selection and padding',
        'official DA3 preprocess: process_res upper_bound_resize + patch align + ImageNet-normalized float tensor cache',
        'DA3 camera tensor convention conversion for pose-conditioned compat only',
        'output naming contract',
        'downstream geometry/highlight handoff',
        'metric depth alignment from DA3 relative depth to meters',
      ],
      'nativeAdapterOwns': [
        'platform model loading',
        'pre-normalized float tensor load into CoreML array',
        'CoreML inference',
        'binary tensor writes',
      ],
    },
    'preprocess': {
      'imageLayout': '1,K,3,H,W',
      'colorSpace': 'sRGB',
      'resize': _asString(
        model['preprocessContract'],
        fallback: inputLocked ? 'locked_input_size' : 'runtime_policy',
      ),
      'normalization': 'imagenet_rgb',
      'processRes': model['processRes'],
      'processResMethod': model['processResMethod'],
      'patchSize': model['patchSize'],
      'inputWidth': ?inputWidth,
      'inputHeight': ?inputHeight,
    },
    'inputs': {
      'framesField': 'frames',
      'imagePathField': 'imagePath',
      'imageTensorFloat32ChwPathField': 'imageTensorFloat32ChwPath',
      'officialStreamingImageOnlyFields': ['imageTensorFloat32ChwPath'],
      'cameraTransformField': 'cameraTransform',
      'intrinsicsField': 'intrinsics',
      'da3CameraExtrinsicField': 'cameraExtrinsicOpenCvW2c4x4',
      'da3CameraIntrinsicField': 'cameraIntrinsic3x3',
      'da3CameraFieldsOwner': 'Flutter/Dart da3_input_manifest.json',
      'da3CameraConvention':
          'source ARKit c2w column-major -> OpenCV w2c row-major before native execution',
      'cameraFieldsRole': officialImageOnlyModel
          ? 'metadata_only_not_da3_input'
          : 'pose_conditioned_compatibility_only; not official streaming baseline input',
    },
    'outputs': {
      'relativeDepthDir': 'relative_depth',
      'metricDepthDir': 'metric_depth',
      'confidenceDir': 'confidence',
      'predPoseDir': 'pred_pose',
      'depthFormat': 'float32_le',
      'confidenceFormat': 'float32_le',
      'poseFormat': 'float32_le',
      'frameIndexFields': [
        'imageRelativePath',
        'relativeDepthPath',
        'metricDepthPath',
        'confidencePath',
        'predExtrinsicsPath',
        'predIntrinsicsPath',
      ],
    },
    'downstreamConsumers': {
      'pointcloud': 'depth_index.json frames[] depth/conf + predicted pose',
      'mesh': 'stages/pointcloud/pointcloud.ply from DA3 geometry',
      'texture': 'texture_plan.json consumes locked DA3 geometry',
      'highlight':
          'highlightPolicy combines DA3 geometry with material reflective risk',
    },
  };
}

final class _PhotoBundleDerivationSummary {
  const _PhotoBundleDerivationSummary({
    required this.status,
    required this.frameCount,
    required this.edgeCount,
    required this.colmapFrameCount,
  });

  final String status;
  final int frameCount;
  final int edgeCount;
  final int colmapFrameCount;

  factory _PhotoBundleDerivationSummary.fromResult(
    PhotoBundleDerivationResult result,
  ) {
    return _PhotoBundleDerivationSummary(
      status: result.status,
      frameCount: result.frameCount,
      edgeCount: result.edgeCount,
      colmapFrameCount: result.colmapFrameCount,
    );
  }

  factory _PhotoBundleDerivationSummary.fromJson(Map<String, Object?> json) {
    return _PhotoBundleDerivationSummary(
      status: _asString(json['status'], fallback: 'unknown'),
      frameCount: _summaryInt(json['frameCount']),
      edgeCount: _summaryInt(json['edgeCount']),
      colmapFrameCount: _summaryInt(json['colmapFrameCount']),
    );
  }
}

Future<_PhotoBundleDerivationSummary> _derivePhotoBundleSidecarsOnWorker(
  String captureDirPath,
) async {
  final summary = await Isolate.run<Map<String, Object?>>(() async {
    final result = await _defaultPhotoBundleDerivationService().deriveDirectory(
      Directory(captureDirPath),
    );
    return <String, Object?>{
      'status': result.status,
      'frameCount': result.frameCount,
      'edgeCount': result.edgeCount,
      'colmapFrameCount': result.colmapFrameCount,
    };
  });
  return _PhotoBundleDerivationSummary.fromJson(summary);
}

PhotoBundleDerivationService _defaultPhotoBundleDerivationService() {
  final runner = Da3NativePreprocessRunner.tryOpen();
  if (runner == null) return const PhotoBundleDerivationService();
  return PhotoBundleDerivationService(da3PreprocessRunner: runner);
}

int _summaryInt(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

DepthConfStats? _confStatsFromJson(Map<String, Object?> json) {
  final nested = _mapValue(json['confStats']);
  final source = nested.isNotEmpty ? nested : json;
  final median =
      _nullableDouble(source['confMedian']) ??
      _nullableDouble(source['conf_median']);
  final mean =
      _nullableDouble(source['confMean']) ??
      _nullableDouble(source['conf_mean']);
  final min =
      _nullableDouble(source['confMin']) ?? _nullableDouble(source['conf_min']);
  final max =
      _nullableDouble(source['confMax']) ?? _nullableDouble(source['conf_max']);
  if (median == null || mean == null || min == null || max == null) {
    return null;
  }
  return DepthConfStats(median: median, mean: mean, min: min, max: max);
}

Map<String, Object?> _mapValue(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) return value.cast<String, Object?>();
  return const <String, Object?>{};
}

List<Map<String, Object?>> _maps(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  return [
    for (final item in value)
      if (item is Map) item.cast<String, Object?>(),
  ];
}

List<String> _strings(Object? value) {
  if (value is! List) return const <String>[];
  return [
    for (final item in value)
      if (item != null) item.toString(),
  ];
}

List<int> _ints(Object? value) {
  if (value is! List) return const <int>[];
  return [
    for (final item in value)
      if (_nullableInt(item) != null) _nullableInt(item)!,
  ];
}

Set<String> _downstreamFrameIDsForWindow(Map<String, Object?> window) {
  final downstream = _strings(window['downstreamFrameIDs']);
  if (downstream.isNotEmpty) return downstream.toSet();
  final officialSave = _strings(window['officialSaveFrameIDs']);
  if (officialSave.isNotEmpty) return officialSave.toSet();
  return const <String>{};
}

List<double> _doubleList(Object? value) {
  if (value is! List) return const <double>[];
  return [
    for (final item in value)
      if (item is num) item.toDouble(),
  ];
}

String _asString(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final text = value.toString();
  return text.isEmpty ? fallback : text;
}

String? _nullableString(Object? value) {
  if (value == null) return null;
  final text = value.toString();
  return text.isEmpty ? null : text;
}

int? _nullableInt(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _nullableDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

bool _truthy(Object? value) {
  if (value is bool) return value;
  final text = value?.toString().toLowerCase();
  return text == 'true' || text == '1' || text == 'yes';
}

String _joinRelativePath(String left, String right) {
  final cleanLeft = left.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  final cleanRight = right.replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '');
  if (cleanLeft.isEmpty) return cleanRight;
  if (cleanRight.isEmpty) return cleanLeft;
  return '$cleanLeft/$cleanRight';
}
