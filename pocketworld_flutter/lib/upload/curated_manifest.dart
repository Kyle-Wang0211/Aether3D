// CuratedManifest — turns the `DomeCoverageMap.curateForUpload(...)`
// result into the `curated.json` blob the server-side worker reads.
//
// On the server, `extract_frames.py` looks for the auxiliary file named
// "curated.json" with role "client_curation". When present, the worker
// extracts EXACTLY the listed frame timestamps from the uploaded video
// and skips its own az×el binning pass — i.e. trusts our on-device
// quality + spread judgement.
//
// JSON shape (kept compatible with the Aether3D iOS client's writer):
//
//   {
//     "version": 1,
//     "capture_origin": "pocketworld_v1",
//     "frame_count": 80,
//     "frames": [
//       {
//         "frame_id":   "cap-0042",
//         "timestamp_ms": 1234,
//         "az_bin": 3,
//         "el_bin": 2,
//         "az_rad": 1.57,
//         "el_rad": 0.05,
//         "sharpness": 712.3,
//         "motion_score": 0.18,
//         "exposure_score": 0.95,
//         "quality_score": 302.1,
//         "cell_state": "excellent",
//         "cell_rank_in_top_k": 0
//       },
//       ...
//     ]
//   }
//
// `timestamp_ms` is the offset from recording start in MILLISECONDS — the
// worker's ffmpeg frame extractor uses this to pull the matching video
// frame. The same monotonic clock that stamps `CapturedFrameSample.timestamp`
// (CaptureSession's Stopwatch) also stamps the frame numbers, so they
// correlate one-to-one.

import 'dart:convert';
import 'dart:typed_data';

import '../capture/dome/dome_cell_state.dart';
import '../capture/dome/dome_target_points.dart';
import '../capture/pose_drift_tracker.dart';
import '../capture/sam/subject_mask_data.dart';

class CuratedManifest {
  final String captureOrigin;
  final List<CuratedFrame> frames;

  /// Tier 1 pose-drift health summary for this session. Optional —
  /// when omitted (e.g. capture_uploader callers that haven't been
  /// updated yet, or a retry path that lost the tracker state) the
  /// `pose_drift_report` field is dropped from the JSON, preserving
  /// the pre-Task-2 manifest shape.
  ///
  /// Server worker treats this as additive diagnostic only — old
  /// workers ignore it; new workers can log/aggregate it. NOT used
  /// to gate or weight reconstruction.
  final PoseDriftReport? poseDriftReport;

  /// Per-frame MobileSAM subject masks, keyed by `CapturedFrameSample.frameId`.
  /// When a frame's id is present in this map, its `subject_mask` block is
  /// emitted into the manifest; absent ids produce no `subject_mask` field
  /// (worker stage gracefully no-ops that frame).
  ///
  /// Defaults to empty so pre-Task-3 callers, retry paths, and platforms
  /// where MobileSAM isn't supported (Web / HarmonyOS in onnxruntime
  /// 1.4.1) keep producing the byte-identical pre-Task-3 manifest shape.
  /// Server-side `apply_subject_mask` stage is env-gated off by default
  /// during rollout, so even a manifest WITH masks is safe against an
  /// untouched worker fleet.
  final Map<String, SubjectMaskData> subjectMasks;

  const CuratedManifest({
    required this.captureOrigin,
    required this.frames,
    this.poseDriftReport,
    this.subjectMasks = const <String, SubjectMaskData>{},
  });

  Map<String, dynamic> toJson() {
    // Aggregate IMU-vs-ARKit ratio so the server can log it without
    // having to parse every frame. VGGT solves pose from images
    // directly (arxiv 2503.11651, model.forward(images) takes no pose
    // input), so the client pose is metadata only — but knowing the
    // ratio per upload is useful both for monitoring tracking quality
    // in the wild and for deciding which frames the server might want
    // to weight differently in any future ARKit-pose-aware re-ranking.
    var arkitFrames = 0;
    var imuFrames = 0;
    for (final cf in frames) {
      if (cf.sample.poseSource == 'imu') {
        imuFrames++;
      } else {
        arkitFrames++;
      }
    }

    return <String, dynamic>{
      // contract_version is the field the server worker uses to dispatch
      // to the right curate path. Without it the worker fails with
      // `curate_from_client_unsupported_contract: None (only
      // 'client_curated_v1' is supported)` immediately after download.
      // Verbatim of iOS ObjectModeV2CoverageMap.swift::
      // CURATED_CONTRACT_VERSION = "client_curated_v1".
      'contract_version': 'client_curated_v1',
      'capture_origin': captureOrigin,
      // ARKit world reference frame info. Worker reads
      // `manifest.arkit.gravity_world` in curate_from_client.py:131
      // and feeds the up vector into the artifact metadata so the
      // viewer can spawn its initial camera with screen-up = world-up.
      //
      // ARSession runs with `worldAlignment = .gravity`
      // (AetherARKitPlugin.swift), which guarantees +Y is up in the
      // ARKit world frame — so the gravity direction in that frame
      // is the constant (0, -1, 0). No per-capture compute needed.
      'arkit': <String, dynamic>{
        'gravity_world': <double>[0.0, -1.0, 0.0],
      },
      // Aggregate pose-source counters. Per-frame `pose_source` field
      // below is the source of truth; this block is for cheap log /
      // dashboard consumption.
      'pose_source_counts': <String, int>{
        'arkit': arkitFrames,
        'imu': imuFrames,
      },
      // Tier 1 pose-drift report. Session-level health summary —
      // time per ARKit trackingState bucket, normal→degraded
      // transitions, longest degraded run. Server worker uses it
      // for diagnostic logging / dashboard rollups; old workers
      // simply skip the unknown field. Omitted entirely when the
      // caller didn't supply a report so the pre-Task-2 manifest
      // shape is byte-identical for backward compat.
      if (poseDriftReport != null)
        'pose_drift_report': poseDriftReport!.toJson(),
      // Aggregate count of frames carrying a MobileSAM subject mask.
      // Lets the server worker log "X / Y frames had masks" in one
      // glance without having to count `subject_mask` keys.
      'subject_mask_count': frames
          .where((cf) => subjectMasks.containsKey(cf.sample.frameId))
          .length,
      'frame_count': frames.length,
      'frames': frames
          .map((cf) => <String, dynamic>{
                // Field names match iOS CuratedFrameEntry CodingKeys
                // (CoverageMap.swift line 575-590) so the worker's
                // single parser can handle both clients.
                'frame_uuid': cf.sample.frameId,
                // Worker uses `ffmpeg -ss video_timestamp_sec` to
                // extract the frame from the .mov. Our CaptureSession
                // Stopwatch starts at 0 on Record-tap, so the sample's
                // timestamp IS the offset into the video — no first-
                // frame baseline subtraction needed.
                'video_timestamp_sec': cf.sample.timestamp,
                'capture_epoch_ms': (cf.sample.timestamp * 1000).round(),
                'az_bin': cf.azBin,
                'el_bin': cf.elBin,
                'az_rad': cf.sample.azimuth,
                'el_rad': cf.sample.elevation,
                'sharpness': cf.sample.sharpness,
                'motion_score': cf.sample.motionScore,
                'quality_score': cf.qualityScore,
                'cell_state': _stateName(cf.cellState),
                'cell_rank_in_top_k': cf.cellRankInTopK,
                // Where this frame's az/el came from. 'arkit' = ARKit
                // visual-inertial pose, 'imu' = IMU dead-reckoning
                // because ARKit was in `.limited(...)`. The server
                // should NOT trust 'imu' frames as ground-truth pose
                // for reconstruction (they're coarse), but VGGT solves
                // pose from images regardless so this is mostly for
                // logging.
                'pose_source': cf.sample.poseSource,
                if (cf.sample.cameraExtrinsic4x4 != null)
                  'arkit_extrinsic_4x4': cf.sample.cameraExtrinsic4x4,
                if (cf.sample.cameraIntrinsicFxFyCxCy != null)
                  'arkit_intrinsic_fx_fy_cx_cy':
                      cf.sample.cameraIntrinsicFxFyCxCy,
                // MobileSAM subject mask, RLE+base64 packed. Optional —
                // present only when the capture-side SAM loop (Task 3
                // Phase B, native pixel-buffer bridge required) was
                // running AND produced a mask within the temporal
                // matching window for this frame. Absent → worker
                // `apply_subject_mask` stage no-ops this frame.
                if (subjectMasks.containsKey(cf.sample.frameId))
                  'subject_mask': subjectMasks[cf.sample.frameId]!.toJson(),
              })
          .toList(growable: false),
    };
  }

  /// JSON-encoded UTF-8 bytes ready for upload as curated.json.
  Uint8List encode() {
    final json = const JsonEncoder().convert(toJson());
    return Uint8List.fromList(utf8.encode(json));
  }

  /// Pretty-printed string for debug logging.
  String toPrettyJson() =>
      const JsonEncoder.withIndent('  ').convert(toJson());

  static String _stateName(DomeCellState s) {
    switch (s) {
      case DomeCellState.empty:
        return 'empty';
      case DomeCellState.weak:
        return 'weak';
      case DomeCellState.ok:
        return 'ok';
      case DomeCellState.excellent:
        return 'excellent';
    }
  }
}
