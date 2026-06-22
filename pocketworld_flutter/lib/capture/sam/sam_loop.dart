// SamLoop — coordinates the 5 Hz cadence of:
//   1. Pull a 1024×1024 RGBA snapshot from native (SamFrameProvider)
//   2. Run MobileSAM segmentation on it (MobileSamInference, which
//      itself uses an internal OrtIsolateSession so we never block
//      the Dart main isolate)
//   3. RLE-encode the resulting binary mask into a SubjectMaskData
//      (cheap, ~1 ms for 1024² with typical foreground ratio)
//   4. Cache the mask by capture timestamp so the upload curate
//      step can attach the temporally-nearest mask to each curated
//      frame's manifest entry
//
// What this is NOT:
//   • A subscription to ARFrame events — we pull on a Timer, not push.
//     See sam_frame_provider.dart for the why.
//   • A 1:1 mapping between captured frames and SAM masks. ARKit
//     fires ARFrames at 30/60 Hz, dome ingest sees ~6 Hz, SAM runs
//     at 5 Hz; the curate step does temporal nearest-neighbour
//     matching to associate.
//
// Lifecycle:
//   • startIfHighTier() during capture session start. Returns false
//     on LOW-tier devices (iPhone 11/12, 4 GB RAM) — they should
//     skip SAM entirely to stay under iOS jetsam threshold.
//   • stop() during capture session stop / dispose. Cancels the
//     timer, drops in-flight inference, releases SAM resources.
//   • The mask cache survives stop() so the upload step can read
//     it post-stop. clearMasks() drops the cache when starting a
//     fresh session.
//
// Backpressure handling:
//   If a SAM inference is still in flight when the next 200 ms tick
//   fires, we SKIP that tick. Skipping is preferred over queueing
//   because:
//     • Stale frames have less value than fresh ones (camera moved)
//     • Queueing would let memory grow unboundedly if SAM stalled
//     • In practice on iPhone 12 Pro+ A14, SAM finishes in 30–50 ms,
//       so skips should be rare (~0% under normal conditions).

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'mobile_sam_inference.dart';
import 'sam_frame_provider.dart';
import 'subject_mask_data.dart';

/// Diagnostic switch — when true, prints one log line per inference
/// completion and per skipped tick so a tester can see the loop
/// running without cracking open the manifest.
const bool _kDiagLog = true;

/// One captured + segmented frame in the in-memory cache. Held until
/// the capture session's curate step looks it up by timestamp.
class _TimedMask {
  /// When the underlying ARFrame was pulled from native (NOT when
  /// SAM finished). Matches [SamFrameSnapshot.receivedAt].
  final DateTime captureTime;

  /// Compressed mask, ready to drop straight into curated.json.
  final SubjectMaskData mask;

  const _TimedMask({required this.captureTime, required this.mask});
}

/// Hooks the capture session injects so SamLoop can stamp each mask
/// with the dome frame_uuid that was current at the moment of the SAM
/// pull. Returns null when no current frame is available (e.g. dome
/// ingest hasn't fired yet on this session).
typedef CurrentFrameIdGetter = String? Function();

class SamLoop {
  final SamFrameProvider _frameProvider;
  final MobileSamInference _inference;

  /// Cadence between SAM pulls. 200 ms = 5 Hz. Lower = more masks per
  /// curated frame (more accurate temporal match) but proportionally
  /// more battery + CPU. iOS Aether3D's reference cadence and KIRI
  /// Engine's public writeup both hover around 5 Hz; we match.
  final Duration cadence;

  /// Maximum window the curate step will accept for "nearest mask
  /// to this frame". Beyond this, the frame goes unmasked. 250 ms
  /// chosen to bracket cadence (200 ms) plus a tick of slack — at
  /// 5 Hz, every captured frame should have a mask within 200 ms,
  /// but headroom prevents a one-tick stall from de-masking 6 frames.
  final Duration maxMatchWindow;

  /// Mask resolution requested from the native bridge. Default is the
  /// SAM training-input ceiling 1024 (see kRecommendedMaskSize in
  /// subject_mask_data.dart for the full tradeoff math).
  final int maskSize;

  /// Hook the capture session installs so we can stamp each mask
  /// with the current dome frame_uuid for downstream auditing. May
  /// be null — masks then carry a synthetic uuid prefix `msk-` and
  /// the upload step matches purely by timestamp.
  CurrentFrameIdGetter? currentFrameIdGetter;

  Timer? _timer;
  bool _running = false;
  bool _inferenceInFlight = false;
  int _consecutiveSkips = 0;
  int _totalRuns = 0;
  int _totalSkips = 0;
  int _totalNullPulls = 0;

  /// Append-only list — masks are only ever added, never mutated. Read
  /// at curate time. ~150 entries per 30 s session (5 Hz × 30 s), each
  /// ~30 KB RLE-compressed → ~4.5 MB cache peak. Acceptable on HIGH-tier
  /// devices (which have 6+ GB RAM, hundreds of MB headroom).
  final List<_TimedMask> _masks = <_TimedMask>[];

  SamLoop({
    SamFrameProvider? frameProvider,
    MobileSamInference? inference,
    this.cadence = const Duration(milliseconds: 200),
    this.maxMatchWindow = const Duration(milliseconds: 250),
    this.maskSize = kRecommendedMaskSize,
  })  : _frameProvider = frameProvider ?? SamFrameProvider(),
        _inference = inference ?? MobileSamInference();

  /// True between [startIfHighTier] and [stop] (both inclusive of the
  /// "starting up" phase before the first SAM result lands).
  bool get isRunning => _running;

  /// Total count of in-cache masks. Useful for diagnostics ("did SAM
  /// produce anything at all this session?").
  int get cachedMaskCount => _masks.length;

  /// Try to start the SAM loop. Returns false (and does NOT start) if:
  ///   • Device is LOW tier (would OOM during 4K AR + AVAssetWriter)
  ///   • SAM warmup fails (asset missing, native ORT load error)
  ///
  /// Returning false is normal and expected on iPhone 11/12 and on
  /// non-iOS platforms — caller (CaptureSession) just proceeds with
  /// no masks; the upload manifest will omit `subject_mask` and the
  /// worker stage will no-op.
  Future<bool> startIfHighTier() async {
    if (_running) return true;

    final tier = await _frameProvider.getDeviceTier();
    if (tier != DeviceTier.high) {
      if (_kDiagLog) {
        debugPrint('[SamLoop] device tier=${tier.name}, NOT starting SAM');
      }
      return false;
    }

    // Warmup is async + may take a few hundred ms (CoreML compile
    // step). We fire and check the flag after — caller doesn't have
    // to await this at the cost of skipping the very first tick.
    await _inference.warmup();
    if (!_inference.isReady) {
      if (_kDiagLog) {
        debugPrint('[SamLoop] inference warmup failed, NOT starting SAM');
      }
      return false;
    }

    _running = true;
    _consecutiveSkips = 0;
    _totalRuns = 0;
    _totalSkips = 0;
    _totalNullPulls = 0;
    _timer = Timer.periodic(cadence, (_) => _tick());

    if (_kDiagLog) {
      debugPrint(
        '[SamLoop] STARTED: tier=high, maskSize=$maskSize, '
        'cadence=${cadence.inMilliseconds}ms',
      );
    }
    return true;
  }

  /// Cancel the timer and release SAM resources. Mask cache is preserved
  /// so the upload step can still read it. Use [clearMasks] to drop
  /// the cache for a fresh session.
  void stop() {
    if (!_running) return;
    _timer?.cancel();
    _timer = null;
    _running = false;
    if (_kDiagLog) {
      debugPrint(
        '[SamLoop] STOPPED: total runs=$_totalRuns skips=$_totalSkips '
        'null pulls=$_totalNullPulls cached masks=${_masks.length}',
      );
    }
  }

  /// Drop all cached masks. Call when starting a fresh capture
  /// session so the previous session's masks don't bleed into this
  /// one's manifest.
  void clearMasks() {
    _masks.clear();
  }

  /// Release SAM resources permanently. After this, the loop can't
  /// be restarted. Use [stop] for between-session pauses.
  void dispose() {
    stop();
    _inference.dispose();
    _masks.clear();
  }

  // ── Curate-time helpers ─────────────────────────────────────────────

  /// Build the per-frame mask map the upload manifest writer wants.
  ///
  /// For each frame_uuid in `frames`, finds the cached mask whose
  /// captureTime is closest to that frame's captureTime AND within
  /// [maxMatchWindow]. Frames with no qualifying mask are omitted —
  /// the manifest writer simply doesn't emit `subject_mask` for them
  /// and the worker stage no-ops that frame.
  ///
  /// Caller passes `frames` as `(frame_uuid, frame_capture_time)`
  /// pairs because CapturedFrameSample's timestamp is monotonic-clock
  /// seconds, not wall-clock — we need the wall-clock equivalent at
  /// the moment of capture to match against [_TimedMask.captureTime]
  /// (which is wall-clock).
  Map<String, SubjectMaskData> buildMaskMap(
    List<({String frameId, DateTime captureTime})> frames,
  ) {
    if (_masks.isEmpty || frames.isEmpty) {
      return const <String, SubjectMaskData>{};
    }
    final out = <String, SubjectMaskData>{};
    for (final f in frames) {
      final nearest = _findNearestMask(f.captureTime);
      if (nearest != null) {
        out[f.frameId] = nearest;
      }
    }
    if (_kDiagLog) {
      debugPrint(
        '[SamLoop] buildMaskMap: ${out.length}/${frames.length} '
        'frames matched a mask within ${maxMatchWindow.inMilliseconds}ms',
      );
    }
    return out;
  }

  SubjectMaskData? _findNearestMask(DateTime captureTime) {
    SubjectMaskData? best;
    int bestDeltaMicros = maxMatchWindow.inMicroseconds;
    for (final m in _masks) {
      final delta = (m.captureTime.difference(captureTime)).inMicroseconds.abs();
      if (delta < bestDeltaMicros) {
        bestDeltaMicros = delta;
        best = m.mask;
      }
    }
    return best;
  }

  // ── Internal tick ───────────────────────────────────────────────────

  Future<void> _tick() async {
    if (!_running) return;

    if (_inferenceInFlight) {
      _consecutiveSkips++;
      _totalSkips++;
      if (_kDiagLog && _consecutiveSkips % 5 == 0) {
        debugPrint(
          '[SamLoop] backpressure: skipped $_consecutiveSkips ticks '
          '(SAM running slower than ${cadence.inMilliseconds}ms cadence)',
        );
      }
      return;
    }
    _consecutiveSkips = 0;
    _inferenceInFlight = true;

    try {
      final snap = await _frameProvider.requestFrame(size: maskSize);
      if (snap == null) {
        _totalNullPulls++;
        return;
      }

      // Materialize the transferred RGBA bytes. After this call, the
      // TransferableTypedData is consumed — the main isolate now owns
      // the buffer (we ARE the main isolate here; there's no actual
      // hop yet — the transfer was for forward-compat with a future
      // architecture where SamLoop runs in a dedicated isolate).
      final rgba = snap.transferableRgba.materialize().asUint8List();

      // SAM segment uses default prompt at center (snap.width/2,
      // snap.height/2). Output mask matches snap dimensions because
      // we pass them as orig_im_size to the decoder.
      final result = await _inference.segment(
        rgbaBytes: rgba,
        width: snap.width,
        height: snap.height,
        promptX: snap.width ~/ 2,
        promptY: snap.height ~/ 2,
      );
      if (result == null) return;

      // Compress to wire format. Mask UUID = current frame id when
      // available, else a synthetic monotonic `msk-N` (the manifest
      // doesn't actually require uniqueness across sessions).
      final frameId = currentFrameIdGetter?.call();
      final maskUuid = frameId != null
          ? 'msk-from-$frameId'
          : 'msk-${snap.receivedAt.microsecondsSinceEpoch}';
      final mask = SubjectMaskData.fromBinaryMask(
        mask: result.mask,
        width: result.width,
        height: result.height,
        centerProb: result.centerProb,
        fillRatio: result.fillRatio,
        maskUuid: maskUuid,
      );

      _masks.add(_TimedMask(captureTime: snap.receivedAt, mask: mask));
      _totalRuns++;

      if (_kDiagLog && _totalRuns <= 3) {
        debugPrint(
          '[SamLoop] mask #$_totalRuns: ${result.width}x${result.height} '
          'centerProb=${result.centerProb.toStringAsFixed(2)} '
          'fillRatio=${result.fillRatio.toStringAsFixed(3)}',
        );
      }
    } catch (e, st) {
      debugPrint('[SamLoop] tick error: $e\n$st');
    } finally {
      _inferenceInFlight = false;
    }
  }
}

