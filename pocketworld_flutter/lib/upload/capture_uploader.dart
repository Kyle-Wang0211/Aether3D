// CaptureUploader — high-level orchestrator that runs the
// "stop recording → ship to A100" handshake.
//
// Sequence per capture session:
//   1. Caller hands us the recorded .mov file path + the populated
//      DomeCoverageMap.
//   2. We call coverage.curateForUpload(targetTotal: 80) → 80 best
//      frames balanced across cells.
//   3. Encode that into a curated.json bytes blob.
//   4. POST /v1/mobile-jobs with the .mov file's metadata + a
//      `auxiliary_files` declaration for curated.json. Server returns
//      presigned upload URLs for the .mov AND for curated.json.
//   5. PUT the .mov bytes to its presigned URL (with progress).
//   6. PUT the curated.json bytes to its presigned URL.
//   7. Return the jobId so the caller can either poll status or just
//      tell the user "扫描已上传，训练中".
//
// Progress reporting:
//   The progress stream emits a sequence of phases: prepare → create
//   job → upload video (with byte progress) → upload curated → done.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'aether_api_client.dart';
import 'aether_api_models.dart';
import 'curated_manifest.dart';

import '../capture/dome/dome_target_points.dart';
import '../capture/pose_drift_tracker.dart';
import '../capture/sam/sam_loop.dart';
import '../capture/sam/subject_mask_data.dart';

/// One progress notification for the upload UI.
class UploadProgress {
  /// "preparing" | "creating_job" | "uploading_video" |
  /// "uploading_curated" | "done"
  final String phase;
  /// 0..1 across the whole pipeline (not per-phase). The video upload
  /// is weighted as ~80% of total since it dominates wall-clock time.
  final double overallFraction;
  final String? detail;

  const UploadProgress({
    required this.phase,
    required this.overallFraction,
    this.detail,
  });
}

class CaptureUploadResult {
  final String jobId;
  final String storageKey;
  const CaptureUploadResult({
    required this.jobId,
    required this.storageKey,
  });
}

class CaptureUploader {
  final AetherApiClient api;
  /// Origin tag the server logs against this job. Used to distinguish
  /// PocketWorld submissions from the original iOS Aether3D client.
  final String captureOrigin;
  /// Total frames to send in curated.json. Default 118 = exact 1:1 with
  /// v6's 118 visual target points (1 best frame per visited point).
  /// A100-80GB ceiling test: VGGT at 118 frames is well within budget
  /// (linear extrapolation from the 80/100/120/160 sweep ≈ 33 GB peak).
  final int curatedFrameTarget;

  CaptureUploader({
    AetherApiClient? api,
    this.captureOrigin = 'pocketworld_v1',
    this.curatedFrameTarget = 118,
  }) : api = api ?? AetherApiClient();

  /// Run the full upload. Yields [UploadProgress] events; ends with the
  /// returned [CaptureUploadResult] (the future resolves after the last
  /// progress event).
  ///
  /// Curates frames from [targetPoints] up-front and delegates to
  /// [uploadPersisted]. Use [uploadPersisted] directly when retrying a
  /// failed scan from disk-persisted manifest bytes — the live
  /// DomeTargetPoints object is gone by then, but the curated bytes
  /// captured at the original upload-start are sufficient.
  Stream<UploadProgress> upload({
    required File videoFile,
    required DomeTargetPoints targetPoints,
    String? clientRecordId,
    PoseDriftReport? poseDriftReport,
    Map<String, SubjectMaskData> subjectMasks =
        const <String, SubjectMaskData>{},
    SamLoop? samLoop,
    DateTime? recordingStartedAt,
    void Function(CaptureUploadResult result)? onCompleted,
  }) async* {
    yield const UploadProgress(
      phase: 'preparing',
      overallFraction: 0.02,
      detail: '正在挑选要上传的关键帧',
    );

    final manifestBytes = curateManifestBytes(
      targetPoints,
      poseDriftReport: poseDriftReport,
      subjectMasks: subjectMasks,
      samLoop: samLoop,
      recordingStartedAt: recordingStartedAt,
    );
    yield* uploadPersisted(
      videoFile: videoFile,
      manifestBytes: manifestBytes,
      clientRecordId: clientRecordId,
      onCompleted: onCompleted,
    );
  }

  /// Curate-only helper exposed so callers (UploadCoordinator) can run
  /// the curate step once on upload-start, persist the produced bytes
  /// to disk, and reuse them later in [uploadPersisted] for retry.
  /// Throws [AetherApiException] with code 'no_curated_frames' when
  /// the live DomeTargetPoints didn't produce a usable manifest (e.g.
  /// recording too short).
  ///
  /// `poseDriftReport`, when supplied, is embedded into the manifest's
  /// session-level `pose_drift_report` block — server-side worker
  /// logs/aggregates it for scan-quality diagnostics. Optional
  /// (defaults to null) so retry paths that have lost the live
  /// CaptureSession can still rebuild the manifest from disk-only
  /// state without crashing.
  Uint8List curateManifestBytes(
    DomeTargetPoints targetPoints, {
    PoseDriftReport? poseDriftReport,
    Map<String, SubjectMaskData> subjectMasks =
        const <String, SubjectMaskData>{},
    SamLoop? samLoop,
    DateTime? recordingStartedAt,
  }) {
    final curated =
        targetPoints.curateForUpload(targetTotal: curatedFrameTarget);
    if (curated.isEmpty) {
      throw const AetherApiException(
        'no_curated_frames',
        'target points produced 0 curated frames — was the recording too short?',
      );
    }

    // Phase B SAM mask map. If both samLoop and recordingStartedAt
    // are supplied AND the loop has cached masks, walk curated frames
    // and ask SamLoop for the temporally-nearest mask per frame.
    // Frames are stamped with monotonic-clock seconds-since-recording-
    // start (CapturedFrameSample.timestamp); we add that to the wall-
    // clock baseline to get DateTime for matching against SamLoop's
    // wall-clock-stamped masks.
    //
    // Falls through to the explicit `subjectMasks` parameter if SAM
    // wasn't running this session (e.g. retry path that lost session
    // state, or LOW-tier device where startIfHighTier returned false).
    var resolvedMasks = subjectMasks;
    if (samLoop != null &&
        recordingStartedAt != null &&
        samLoop.cachedMaskCount > 0 &&
        resolvedMasks.isEmpty) {
      final framesWithWallTime = curated
          .map((cf) => (
                frameId: cf.sample.frameId,
                captureTime: recordingStartedAt.add(
                  Duration(microseconds: (cf.sample.timestamp * 1e6).round()),
                ),
              ))
          .toList(growable: false);
      resolvedMasks = samLoop.buildMaskMap(framesWithWallTime);
    }

    final manifest = CuratedManifest(
      captureOrigin: captureOrigin,
      frames: curated,
      poseDriftReport: poseDriftReport,
      subjectMasks: resolvedMasks,
    );
    return manifest.encode();
  }

  /// The actual upload pipeline: create job → PUT video → PUT manifest.
  /// Used by [upload] (which curates first) and by retry flows that
  /// already have manifest bytes on disk.
  Stream<UploadProgress> uploadPersisted({
    required File videoFile,
    required Uint8List manifestBytes,
    String? clientRecordId,
    void Function(CaptureUploadResult result)? onCompleted,
  }) async* {
    final videoBytes = await videoFile.length();
    if (videoBytes <= 0) {
      throw const AetherApiException(
        'empty_video',
        'recorded file has zero bytes',
      );
    }

    yield UploadProgress(
      phase: 'creating_job',
      overallFraction: 0.05,
      detail: '正在向云端注册任务',
    );

    // pipeline profile — verbatim of iOS Aether3D's
    // ObjectModeV2CaptureViewModel.objectFastPublishPipelineProfile()
    // (lines 1322-1360). Core fields:
    //   strategy=object_slam3r_surface_v1 — selects the SLAM3R + Surface
    //     worker family. Without this, server defaults to "autofallback"
    //     and the workers' pipeline_families filter rejects the job in
    //     claim_next_job → worker never picks it up → A100 idle, job
    //     queued forever.
    //   first_result_kind=hq_mesh_glb — request the high-quality mesh
    //     output (matches what the client viewer can load).
    //   artifact_contract_version=object_publish_v1 — pins the artifact
    //     manifest schema; server uses this to dispatch to the right
    //     post-processing path.
    final pipelineProfile = <String, String>{
      'strategy': 'object_slam3r_surface_v1',
      'capture_mode': 'guided_object',
      'artifact_contract_version': 'object_publish_v1',
      'first_result_kind': 'hq_mesh_glb',
      'hq_refine': 'disabled',
      'optional_mesh_export': 'disabled',
      'target_zone_mode': 'subject',
      'visual_gate_version': 'v1_visual_curated',
    };

    final req = CreateMobileJobRequest(
      fileName: videoFile.uri.pathSegments.isNotEmpty
          ? videoFile.uri.pathSegments.last
          : 'capture.mov',
      fileSizeBytes: videoBytes,
      contentType: _videoContentType(videoFile.path),
      captureOrigin: captureOrigin,
      clientRecordId: clientRecordId,
      pipelineProfile: pipelineProfile,
      auxiliaryFiles: <AuxiliaryFileDeclaration>[
        AuxiliaryFileDeclaration(
          name: 'curated.json',
          fileSizeBytes: manifestBytes.length,
          contentType: 'application/json',
          role: 'client_curation',
        ),
      ],
    );

    final created = await api.createMobileJob(req);
    // ignore: avoid_print
    print(
      '[CaptureUploader] createMobileJob OK: jobId=${created.jobId} '
      'upload.url=${created.upload.url == null ? "null" : "set(${created.upload.url!.length}chars)"} '
      'isMultipart=${created.upload.isMultipart} '
      'storageKey=${created.upload.storageKey}',
    );
    final auxUpload = created.auxiliaryUploads?['curated.json'];
    if (auxUpload == null) {
      // ignore: avoid_print
      print('[CaptureUploader] no aux curated.json upload returned!');
      throw const AetherApiException(
        'server_missing_curated_upload',
        'server did not return an upload URL for curated.json',
      );
    }
    // ignore: avoid_print
    print(
      '[CaptureUploader] aux curated.json upload: '
      'url=${auxUpload.url == null ? "null" : "set"} '
      'isMultipart=${auxUpload.isMultipart}',
    );

    // ─── Video PUT (the long bit; ~80% of total wall-clock) ─────────
    StreamController<UploadProgress>? videoCtrl;
    void emitVideoProgress(int sent, int total) {
      final tot = total > 0 ? total : videoBytes;
      // 0.05..0.85 across the video upload band.
      final frac = 0.05 + 0.80 * (sent / tot).clamp(0.0, 1.0);
      videoCtrl?.add(UploadProgress(
        phase: 'uploading_video',
        overallFraction: frac,
        detail: '上传视频 ${(sent / 1024 / 1024).toStringAsFixed(1)} MB / '
            '${(tot / 1024 / 1024).toStringAsFixed(1)} MB',
      ));
    }

    // We can't easily yield from inside Dio's onSendProgress callback
    // (it's sync), so funnel it through a controller and forward.
    videoCtrl = StreamController<UploadProgress>();
    final videoFuture = api.putFile(
      upload: created.upload,
      file: videoFile,
      onProgress: emitVideoProgress,
    );
    // Forward video-progress events while the PUT runs.
    final videoSub = videoCtrl.stream.listen(null);
    final videoEvents = StreamController<UploadProgress>();
    videoSub.onData(videoEvents.add);
    unawaited(videoFuture.then(
      (_) async {
        await videoCtrl?.close();
        await videoEvents.close();
      },
      onError: (Object e, StackTrace s) async {
        videoEvents.addError(e, s);
        await videoCtrl?.close();
        await videoEvents.close();
      },
    ));
    yield* videoEvents.stream;
    await videoFuture;
    // ignore: avoid_print
    print('[CaptureUploader] video PUT done');

    // ─── Sidecar PUT ────────────────────────────────────────────────
    yield UploadProgress(
      phase: 'uploading_curated',
      overallFraction: 0.92,
      detail: '上传质量清单 ${manifestBytes.length} B',
    );
    await api.putBytes(upload: auxUpload, bytes: manifestBytes);
    // ignore: avoid_print
    print('[CaptureUploader] curated.json PUT done');

    final result = CaptureUploadResult(
      jobId: created.jobId,
      storageKey: created.upload.storageKey,
    );
    onCompleted?.call(result);

    yield UploadProgress(
      phase: 'done',
      overallFraction: 1.0,
      detail: 'jobId=${created.jobId}',
    );
    // ignore: avoid_print
    print('[CaptureUploader] all uploads complete, jobId=${created.jobId}');
  }

  static String _videoContentType(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    return 'application/octet-stream';
  }
}
