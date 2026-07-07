import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../capture/depth_alignment_ffi.dart';
import '../capture/depth_meta.dart';

/// Dart-owned DA3 relative-depth -> metric-depth policy.
///
/// Native/FFI is allowed to run the numeric kernels only. Frame eligibility,
/// ARKit/VIO anchor projection, artifact naming, quality gates, and downstream
/// handoff live here so the metric scale contract stays cross-platform.
final class MetricDepthAlignmentSpec {
  const MetricDepthAlignmentSpec({
    this.schemaVersion = 'aether_metric_depth_alignment_spec_v1',
    this.producer = 'DA3-BASE K35@476x742 + ARKit/VIO sparse anchors',
    this.metricAuthority = 'arkit_vio_sparse_world_anchors',
    this.outputDir = 'metric_depth',
    this.minAnchorsPerFrame = 8,
    this.targetAnchorsPerFrame = 192,
    this.maxAnchorsPerFrame = 384,
    this.minMetricDepthM = 0.08,
    this.maxMetricDepthM = 6.0,
    this.inlierDistM = 0.05,
    this.residualSigmaPx = 48.0,
    this.residualClipM = 0.20,
    this.residualGain = 0.65,
    this.maxResidualPoints = 128,
    this.requireDenseSim3Passed = true,
  });

  final String schemaVersion;
  final String producer;
  final String metricAuthority;
  final String outputDir;
  final int minAnchorsPerFrame;
  final int targetAnchorsPerFrame;
  final int maxAnchorsPerFrame;
  final double minMetricDepthM;
  final double maxMetricDepthM;
  final double inlierDistM;
  final double residualSigmaPx;
  final double residualClipM;
  final double residualGain;
  final int maxResidualPoints;
  final bool requireDenseSim3Passed;

  SparseDepthPriorOptions toSparsePriorOptions() {
    return SparseDepthPriorOptions(
      align: ScaleAlignOptions(
        inlierDistM: inlierDistM,
        minAnchors: minAnchorsPerFrame,
        goodAnchors: targetAnchorsPerFrame,
        minDepthSpanM: 0.08,
        goodDepthSpanM: 0.45,
      ),
      residualSigmaPx: residualSigmaPx,
      residualClipM: residualClipM,
      residualGain: residualGain,
      minMetricDepthM: minMetricDepthM,
      maxMetricDepthM: maxMetricDepthM,
      maxResidualPoints: maxResidualPoints,
    );
  }

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'producer': producer,
    'metric_authority': metricAuthority,
    'output_dir': outputDir,
    'anchor_policy': {
      'source': 'per-photo ARKit rawFeaturePoints anchors_world sidecar',
      'projection': 'column_major_camera_to_world_world_anchor_to_camera_pixel',
      'coordinate_space': 'DA3 fixed input resolution after Dart stretch',
      'min_anchors_per_frame': minAnchorsPerFrame,
      'target_anchors_per_frame': targetAnchorsPerFrame,
      'max_anchors_per_frame': maxAnchorsPerFrame,
      'min_metric_depth_m': minMetricDepthM,
      'max_metric_depth_m': maxMetricDepthM,
    },
    'refine_policy': {
      'kernel': 'aether_sparse_depth_prior_refine',
      'inlier_dist_m': inlierDistM,
      'residual_sigma_px': residualSigmaPx,
      'residual_clip_m': residualClipM,
      'residual_gain': residualGain,
      'max_residual_points': maxResidualPoints,
    },
    'quality_gate': {
      'require_dense_sim3_passed': requireDenseSim3Passed,
      'frame_status_completed_when':
          'enough_projected_metric_anchors_and_sparse_prior_refine_ok',
      'missing_or_weak_arkit_anchors': 'skip_frame_without_metric_depth',
    },
    'algorithm_executor_boundary': const {
      'schemaVersion': 'aether_algorithm_executor_boundary_v1',
      'stageName': 'stage1.depth.metric_alignment',
      'hardRule':
          'Dart sealed spec -> thin executor -> Dart report/audit -> next stage',
      'policyOwner': 'Flutter/Dart',
      'executorRole': 'thin_executor_only',
      'dartOwns': [
        'whether DA3 relative depth may be converted to metric depth',
        'ARKit/VIO anchor projection policy',
        'frame quality gates and skip reasons',
        'metric-depth artifact naming',
        'depth_meta/depth_index report schema',
        'pointcloud handoff rule',
      ],
      'executorOwns': [
        'robust affine scale alignment kernel',
        'sparse residual diffusion kernel',
        'raw metric-depth float buffer',
      ],
      'executorMustNotOwn': [
        'metric authority selection',
        'frame acceptance thresholds',
        'downstream pointcloud or mesh policy',
        'product-visible geometry status',
      ],
    },
  };
}

final class MetricDepthAlignmentFrame {
  const MetricDepthAlignmentFrame({
    required this.frameID,
    required this.frameIndex,
    required this.status,
    required this.sourceImageRelativePath,
    required this.relativeDepthPath,
    required this.confidencePath,
    required this.depthWidth,
    required this.depthHeight,
    required this.imageWidth,
    required this.imageHeight,
    required this.cameraTransform,
    required this.intrinsics,
    required this.preprocessTransform,
  });

  final String frameID;
  final int frameIndex;
  final String status;
  final String? sourceImageRelativePath;
  final String? relativeDepthPath;
  final String? confidencePath;
  final int? depthWidth;
  final int? depthHeight;
  final int? imageWidth;
  final int? imageHeight;
  final List<double> cameraTransform;
  final List<double> intrinsics;
  final Map<String, Object?> preprocessTransform;

  bool get isCompleted => status == 'completed';
}

final class MetricDepthAlignmentRequest {
  const MetricDepthAlignmentRequest({
    required this.captureDir,
    required this.depthOutputDir,
    required this.frames,
    required this.denseSim3Verification,
    this.spec = const MetricDepthAlignmentSpec(),
  });

  final Directory captureDir;
  final Directory depthOutputDir;
  final List<MetricDepthAlignmentFrame> frames;
  final Map<String, Object?> denseSim3Verification;
  final MetricDepthAlignmentSpec spec;
}

abstract class MetricDepthAlignmentExecutor {
  const MetricDepthAlignmentExecutor();

  Future<MetricDepthAlignmentReport> align(MetricDepthAlignmentRequest request);
}

final class MetricDepthFrameAlignment {
  const MetricDepthFrameAlignment({
    required this.frameID,
    required this.frameIndex,
    required this.status,
    required this.reason,
    this.metricDepthPath,
    this.anchorInputCount = 0,
    this.anchorProjectedCount = 0,
    this.anchorUsedCount = 0,
    this.projectionConvention,
    this.alignment,
    this.sparsePrior,
    this.error,
  });

  final String frameID;
  final int frameIndex;
  final String status;
  final String reason;
  final String? metricDepthPath;
  final int anchorInputCount;
  final int anchorProjectedCount;
  final int anchorUsedCount;
  final String? projectionConvention;
  final ScaleAlignAdaptiveResult? alignment;
  final SparseDepthPriorResult? sparsePrior;
  final String? error;

  bool get isCompleted => status == 'completed';

  Map<String, Object?> toJson() => {
    'frameID': frameID,
    'frameIndex': frameIndex,
    'status': status,
    'reason': reason,
    if (metricDepthPath != null) 'metricDepthPath': metricDepthPath,
    'anchorInputCount': anchorInputCount,
    'anchorProjectedCount': anchorProjectedCount,
    'anchorUsedCount': anchorUsedCount,
    if (projectionConvention != null)
      'projectionConvention': projectionConvention,
    if (alignment != null) 'alignment': _alignmentJson(alignment!),
    if (sparsePrior != null) 'sparsePrior': _sparsePriorJson(sparsePrior!),
    if (error != null) 'error': error,
  };

  Map<String, Object?> toDepthIndexJson() => {
    if (metricDepthPath != null) 'metricDepthPath': metricDepthPath,
    'metricDepthAlignmentStatus': status,
    'metricDepthAlignmentReason': reason,
    'metricDepthAnchorProjectedCount': anchorProjectedCount,
    'metricDepthAnchorUsedCount': anchorUsedCount,
    if (alignment != null) ...{
      'metricDepthAlignScale': alignment!.scale,
      'metricDepthAlignTranslation': alignment!.translation,
      'metricDepthAlignReliability': alignment!.reliability,
      'metricDepthAlignRmse': alignment!.raw.rmse,
      'metricDepthAlignInlierRatio': alignment!.inlierRatio,
    },
  };

  DepthMetaEntry mergeIntoDepthMeta(DepthMetaEntry entry) {
    final sparse = sparsePrior;
    final align = alignment;
    if (sparse != null) {
      return sparse.mergeIntoDepthMeta(entry, metricDepthPath: metricDepthPath);
    }
    if (align != null) {
      return align.mergeIntoDepthMeta(entry, metricDepthPath: metricDepthPath);
    }
    return entry.copyWith(metricDepthPath: metricDepthPath);
  }

  static Map<String, Object?> _alignmentJson(ScaleAlignAdaptiveResult result) =>
      {
        'scale': result.scale,
        'translation': result.translation,
        'reliability': result.reliability,
        'rmse': result.raw.rmse,
        'inlierRatio': result.inlierRatio,
        'aiDepthSpan': result.aiDepthSpan,
        'metricDepthSpan': result.metricDepthSpan,
        'anchorInputCount': result.raw.nInput,
        'anchorUsedCount': result.raw.nUsed,
        'usedPrior': result.usedPrior,
      };

  static Map<String, Object?> _sparsePriorJson(SparseDepthPriorResult result) =>
      {
        'ok': result.ok,
        'sparseInput': result.sparseInput,
        'sparseUsed': result.sparseUsed,
        'meanAbsResidualM': result.meanAbsResidualM,
        'maxAbsResidualM': result.maxAbsResidualM,
        'alignment': _alignmentJson(result.alignment),
      };
}

final class MetricDepthAlignmentReport {
  const MetricDepthAlignmentReport({
    required this.status,
    required this.spec,
    required this.frames,
    required this.counts,
    required this.elapsedMs,
    this.reason,
  });

  final String status;
  final MetricDepthAlignmentSpec spec;
  final List<MetricDepthFrameAlignment> frames;
  final Map<String, Object?> counts;
  final int elapsedMs;
  final String? reason;

  Map<String, MetricDepthFrameAlignment> get byFrameID => {
    for (final frame in frames) frame.frameID: frame,
  };

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_metric_depth_alignment_report_v1',
    'status': status,
    if (reason != null) 'reason': reason,
    'spec': spec.toJson(),
    'counts': counts,
    'elapsedMs': elapsedMs,
    'frames': [for (final frame in frames) frame.toJson()],
  };
}

final class FfiMetricDepthAlignmentExecutor
    extends MetricDepthAlignmentExecutor {
  const FfiMetricDepthAlignmentExecutor();

  @override
  Future<MetricDepthAlignmentReport> align(
    MetricDepthAlignmentRequest request,
  ) async {
    final stopwatch = Stopwatch()..start();
    final spec = request.spec;
    final denseStatus = _asString(request.denseSim3Verification['status']);
    final metricDir = Directory(
      _joinPath(request.depthOutputDir.path, spec.outputDir),
    );
    metricDir.createSync(recursive: true);

    await File(
      _joinPath(
        request.depthOutputDir.path,
        'metric_depth_alignment_spec.json',
      ),
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert(spec.toJson()),
      flush: true,
    );

    if (spec.requireDenseSim3Passed && denseStatus != 'passed') {
      final skipped = [
        for (final frame in request.frames)
          MetricDepthFrameAlignment(
            frameID: frame.frameID,
            frameIndex: frame.frameIndex,
            status: 'skipped',
            reason: 'dense_sim3_status_$denseStatus',
          ),
      ];
      return _report(
        status: 'skipped',
        spec: spec,
        frames: skipped,
        elapsedMs: stopwatch.elapsedMilliseconds,
        reason: 'dense Sim3 geometry gate did not pass',
      );
    }

    final reports = <MetricDepthFrameAlignment>[];
    for (final frame in request.frames) {
      reports.add(await _alignFrame(request, metricDir, frame));
    }

    return _report(
      status: _overallStatus(reports),
      spec: spec,
      frames: reports,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }

  Future<MetricDepthFrameAlignment> _alignFrame(
    MetricDepthAlignmentRequest request,
    Directory metricDir,
    MetricDepthAlignmentFrame frame,
  ) async {
    if (!frame.isCompleted) {
      return MetricDepthFrameAlignment(
        frameID: frame.frameID,
        frameIndex: frame.frameIndex,
        status: 'skipped',
        reason: 'da3_frame_not_completed',
      );
    }
    final width = frame.depthWidth ?? 0;
    final height = frame.depthHeight ?? 0;
    if (width <= 0 || height <= 0) {
      return MetricDepthFrameAlignment(
        frameID: frame.frameID,
        frameIndex: frame.frameIndex,
        status: 'skipped',
        reason: 'missing_depth_shape',
      );
    }
    if (frame.relativeDepthPath == null || frame.relativeDepthPath!.isEmpty) {
      return MetricDepthFrameAlignment(
        frameID: frame.frameID,
        frameIndex: frame.frameIndex,
        status: 'skipped',
        reason: 'missing_relative_depth_path',
      );
    }

    final sidecar = _sidecarFile(request.captureDir, frame);
    if (sidecar == null || !sidecar.existsSync()) {
      return MetricDepthFrameAlignment(
        frameID: frame.frameID,
        frameIndex: frame.frameIndex,
        status: 'skipped',
        reason: 'missing_arkit_anchor_sidecar',
      );
    }

    Map<String, Object?> sidecarJson;
    try {
      sidecarJson = _readJsonMap(sidecar);
    } catch (e) {
      return MetricDepthFrameAlignment(
        frameID: frame.frameID,
        frameIndex: frame.frameIndex,
        status: 'failed',
        reason: 'invalid_arkit_anchor_sidecar',
        error: '$e',
      );
    }

    final projected = _projectMetricAnchors(
      frame: frame,
      sidecar: sidecarJson,
      spec: request.spec,
      depthWidth: width,
      depthHeight: height,
    );
    if (projected.sparseU.length < request.spec.minAnchorsPerFrame) {
      return MetricDepthFrameAlignment(
        frameID: frame.frameID,
        frameIndex: frame.frameIndex,
        status: 'skipped',
        reason: 'not_enough_projected_arkit_anchors',
        anchorInputCount: projected.anchorInputCount,
        anchorProjectedCount: projected.sparseU.length,
        projectionConvention: projected.projectionConvention,
      );
    }

    try {
      final relative = await _readFloat32File(
        _resolveRelativeFile(request.depthOutputDir, frame.relativeDepthPath),
        expectedLength: width * height,
      );
      final confPath = frame.confidencePath;
      final conf = confPath == null || confPath.isEmpty
          ? null
          : await _readFloat32File(
              _resolveRelativeFile(request.depthOutputDir, confPath),
              expectedLength: width * height,
            );
      final output = DepthAlignmentFfi.refineSparsePrior(
        relativeDepth: relative,
        conf: conf,
        width: width,
        height: height,
        sparseU: projected.sparseU,
        sparseV: projected.sparseV,
        sparseMetricDepth: projected.sparseMetricDepth,
        options: request.spec.toSparsePriorOptions(),
      );
      final metricPath =
          '${request.spec.outputDir}/${_safeID(frame.frameID)}.f32';
      await _writeFloat32File(
        _joinPath(request.depthOutputDir.path, metricPath),
        output.metricDepth,
      );
      return MetricDepthFrameAlignment(
        frameID: frame.frameID,
        frameIndex: frame.frameIndex,
        status: output.result.ok ? 'completed' : 'failed',
        reason: output.result.ok
            ? 'metric_depth_written'
            : 'sparse_prior_refine_not_ok',
        metricDepthPath: output.result.ok ? metricPath : null,
        anchorInputCount: projected.anchorInputCount,
        anchorProjectedCount: projected.sparseU.length,
        anchorUsedCount: output.result.sparseUsed,
        projectionConvention: projected.projectionConvention,
        alignment: output.result.alignment,
        sparsePrior: output.result,
      );
    } catch (e) {
      return MetricDepthFrameAlignment(
        frameID: frame.frameID,
        frameIndex: frame.frameIndex,
        status: 'failed',
        reason: 'metric_alignment_executor_error',
        anchorInputCount: projected.anchorInputCount,
        anchorProjectedCount: projected.sparseU.length,
        projectionConvention: projected.projectionConvention,
        error: '$e',
      );
    }
  }

  static MetricDepthAlignmentReport _report({
    required String status,
    required MetricDepthAlignmentSpec spec,
    required List<MetricDepthFrameAlignment> frames,
    required int elapsedMs,
    String? reason,
  }) {
    final completed = frames
        .where((frame) => frame.status == 'completed')
        .length;
    final skipped = frames.where((frame) => frame.status == 'skipped').length;
    final failed = frames.where((frame) => frame.status == 'failed').length;
    final projected = frames.fold<int>(
      0,
      (sum, frame) => sum + frame.anchorProjectedCount,
    );
    final used = frames.fold<int>(
      0,
      (sum, frame) => sum + frame.anchorUsedCount,
    );
    return MetricDepthAlignmentReport(
      status: status,
      spec: spec,
      frames: frames,
      elapsedMs: elapsedMs,
      reason: reason,
      counts: {
        'frame_total': frames.length,
        'frame_completed': completed,
        'frame_skipped': skipped,
        'frame_failed': failed,
        'projected_anchor_total': projected,
        'used_anchor_total': used,
      },
    );
  }

  static String _overallStatus(List<MetricDepthFrameAlignment> frames) {
    if (frames.isEmpty) return 'empty';
    final completed = frames
        .where((frame) => frame.status == 'completed')
        .length;
    final failed = frames.where((frame) => frame.status == 'failed').length;
    if (completed == frames.length) return 'completed';
    if (completed > 0 && failed == 0) return 'partial_completed';
    if (completed > 0) return 'partial_failed';
    if (failed > 0) return 'failed';
    return 'skipped';
  }
}

final class _MetricAnchorSet {
  const _MetricAnchorSet({
    required this.anchorInputCount,
    required this.sparseU,
    required this.sparseV,
    required this.sparseMetricDepth,
    required this.projectionConvention,
  });

  final int anchorInputCount;
  final List<double> sparseU;
  final List<double> sparseV;
  final List<double> sparseMetricDepth;
  final String projectionConvention;
}

_MetricAnchorSet _projectMetricAnchors({
  required MetricDepthAlignmentFrame frame,
  required Map<String, Object?> sidecar,
  required MetricDepthAlignmentSpec spec,
  required int depthWidth,
  required int depthHeight,
}) {
  final anchors = _worldAnchors(sidecar['anchors_world']);
  final transform = _doubleList(sidecar['extrinsic']).length == 16
      ? _doubleList(sidecar['extrinsic'])
      : frame.cameraTransform;
  final intrinsics = _doubleList(sidecar['intrinsics_fxfycxcy']).length >= 4
      ? _doubleList(sidecar['intrinsics_fxfycxcy'])
      : frame.intrinsics;
  if (anchors.isEmpty || transform.length != 16 || intrinsics.length < 4) {
    return _MetricAnchorSet(
      anchorInputCount: anchors.length,
      sparseU: const [],
      sparseV: const [],
      sparseMetricDepth: const [],
      projectionConvention: 'unprojectable_missing_pose_or_intrinsics',
    );
  }

  final sourceWidth = _positiveInt(
    sidecar['image_w'],
    fallback: frame.imageWidth ?? depthWidth,
  );
  final sourceHeight = _positiveInt(
    sidecar['image_h'],
    fallback: frame.imageHeight ?? depthHeight,
  );
  final scaleX = _positiveDouble(
    frame.preprocessTransform['scaleX'],
    fallback: depthWidth / math.max(sourceWidth, 1),
  );
  final scaleY = _positiveDouble(
    frame.preprocessTransform['scaleY'],
    fallback: depthHeight / math.max(sourceHeight, 1),
  );
  final offsetX = _asDouble(frame.preprocessTransform['offsetX']);
  final offsetY = _asDouble(frame.preprocessTransform['offsetY']);

  final plusY = _projectWithConvention(
    anchors: anchors,
    transform: transform,
    intrinsics: intrinsics,
    depthWidth: depthWidth,
    depthHeight: depthHeight,
    scaleX: scaleX,
    scaleY: scaleY,
    offsetX: offsetX,
    offsetY: offsetY,
    spec: spec,
    flipImageY: false,
  );
  final flippedY = _projectWithConvention(
    anchors: anchors,
    transform: transform,
    intrinsics: intrinsics,
    depthWidth: depthWidth,
    depthHeight: depthHeight,
    scaleX: scaleX,
    scaleY: scaleY,
    offsetX: offsetX,
    offsetY: offsetY,
    spec: spec,
    flipImageY: true,
  );
  final chosen = flippedY.sparseU.length > plusY.sparseU.length
      ? flippedY
      : plusY;
  return _MetricAnchorSet(
    anchorInputCount: anchors.length,
    sparseU: chosen.sparseU,
    sparseV: chosen.sparseV,
    sparseMetricDepth: chosen.sparseMetricDepth,
    projectionConvention: chosen.projectionConvention,
  );
}

_MetricAnchorSet _projectWithConvention({
  required List<List<double>> anchors,
  required List<double> transform,
  required List<double> intrinsics,
  required int depthWidth,
  required int depthHeight,
  required double scaleX,
  required double scaleY,
  required double offsetX,
  required double offsetY,
  required MetricDepthAlignmentSpec spec,
  required bool flipImageY,
}) {
  final fx = intrinsics[0];
  final fy = intrinsics[1];
  final cx = intrinsics[2];
  final cy = intrinsics[3];
  final c0x = transform[0], c0y = transform[1], c0z = transform[2];
  final c1x = transform[4], c1y = transform[5], c1z = transform[6];
  final c2x = transform[8], c2y = transform[9], c2z = transform[10];
  final tx = transform[12], ty = transform[13], tz = transform[14];
  final projected = <_ProjectedMetricAnchor>[];
  for (final point in anchors) {
    final dx = point[0] - tx;
    final dy = point[1] - ty;
    final dz = point[2] - tz;
    final camX = dx * c0x + dy * c0y + dz * c0z;
    final camY = dx * c1x + dy * c1y + dz * c1z;
    final camZ = dx * c2x + dy * c2y + dz * c2z;
    final metricDepth = -camZ;
    if (!metricDepth.isFinite ||
        metricDepth < spec.minMetricDepthM ||
        metricDepth > spec.maxMetricDepthM) {
      continue;
    }
    final uSource = fx * (camX / metricDepth) + cx;
    final vSource = flipImageY
        ? cy - fy * (camY / metricDepth)
        : fy * (camY / metricDepth) + cy;
    final u = uSource * scaleX + offsetX;
    final v = vSource * scaleY + offsetY;
    if (!u.isFinite ||
        !v.isFinite ||
        u < 0 ||
        v < 0 ||
        u >= depthWidth ||
        v >= depthHeight) {
      continue;
    }
    projected.add(_ProjectedMetricAnchor(u, v, metricDepth));
  }

  final sampled = _downsampleAnchors(projected, spec.maxAnchorsPerFrame);
  return _MetricAnchorSet(
    anchorInputCount: anchors.length,
    sparseU: [for (final item in sampled) item.u],
    sparseV: [for (final item in sampled) item.v],
    sparseMetricDepth: [for (final item in sampled) item.metricDepth],
    projectionConvention: flipImageY
        ? 'arkit_column_major_cam_to_world_flip_image_y'
        : 'arkit_column_major_cam_to_world_plus_image_y',
  );
}

final class _ProjectedMetricAnchor {
  const _ProjectedMetricAnchor(this.u, this.v, this.metricDepth);

  final double u;
  final double v;
  final double metricDepth;
}

List<_ProjectedMetricAnchor> _downsampleAnchors(
  List<_ProjectedMetricAnchor> anchors,
  int maxCount,
) {
  if (anchors.length <= maxCount) return anchors;
  final out = <_ProjectedMetricAnchor>[];
  final step = anchors.length / maxCount;
  for (var i = 0; i < maxCount; i += 1) {
    out.add(anchors[(i * step).floor().clamp(0, anchors.length - 1)]);
  }
  return out;
}

Future<Float32List> _readFloat32File(
  File file, {
  required int expectedLength,
}) async {
  final bytes = await file.readAsBytes();
  if (bytes.lengthInBytes != expectedLength * 4) {
    throw FormatException(
      'float32 tensor length mismatch ${file.path}: '
      '${bytes.lengthInBytes} bytes vs expected ${expectedLength * 4}',
    );
  }
  final view = ByteData.sublistView(bytes);
  final out = Float32List(expectedLength);
  for (var i = 0; i < expectedLength; i += 1) {
    out[i] = view.getFloat32(i * 4, Endian.little);
  }
  return out;
}

Future<void> _writeFloat32File(String path, Float32List values) async {
  final bytes = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i += 1) {
    bytes.setFloat32(i * 4, values[i], Endian.little);
  }
  await File(path).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
}

File? _sidecarFile(Directory captureDir, MetricDepthAlignmentFrame frame) {
  final rel = frame.sourceImageRelativePath;
  if (rel == null || rel.isEmpty) return null;
  final withoutExt = rel.replaceFirst(RegExp(r'\.[^.]+$'), '');
  return File(_joinPath(captureDir.path, '$withoutExt.json'));
}

File _resolveRelativeFile(Directory root, String? relativePath) {
  final path = relativePath ?? '';
  if (path.isEmpty) {
    throw const FormatException('missing relative tensor path');
  }
  if (path.startsWith('/')) return File(path);
  return File(_joinPath(root.path, path));
}

Map<String, Object?> _readJsonMap(File file) {
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) {
    throw FormatException('${file.path} is not a JSON object');
  }
  return decoded.cast<String, Object?>();
}

List<List<double>> _worldAnchors(Object? value) {
  if (value is! List) return const <List<double>>[];
  final out = <List<double>>[];
  for (final item in value) {
    if (item is! List || item.length < 3) continue;
    final x = item[0], y = item[1], z = item[2];
    if (x is num && y is num && z is num) {
      out.add([x.toDouble(), y.toDouble(), z.toDouble()]);
    }
  }
  return out;
}

List<double> _doubleList(Object? value) {
  if (value is! List) return const <double>[];
  return [
    for (final item in value)
      if (item is num) item.toDouble(),
  ];
}

String _asString(Object? value, {String fallback = ''}) {
  if (value is String && value.isNotEmpty) return value;
  return fallback;
}

double _asDouble(Object? value, {double fallback = 0.0}) {
  if (value is num) return value.toDouble();
  return fallback;
}

double _positiveDouble(Object? value, {required double fallback}) {
  final parsed = _asDouble(value, fallback: fallback);
  return parsed > 0 ? parsed : fallback;
}

int _positiveInt(Object? value, {required int fallback}) {
  if (value is int && value > 0) return value;
  if (value is num && value > 0) return value.toInt();
  return fallback;
}

String _safeID(String id) {
  return id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');
}

String _joinPath(String left, String right) {
  if (right.startsWith('/')) return right;
  if (left.endsWith(Platform.pathSeparator)) return '$left$right';
  return '$left${Platform.pathSeparator}$right';
}
