// ignore_for_file: dead_code
// (Experiment-mode flag `kKeepInputAfterCompletion` lives below; while
// it's true, the post-GLB cleanup branch is "dead" by analyzer rules.
// Both branches need to stay in source so we can flip without an edit.)
//
// JobStatusWatcher — bridges the upload-side `pollJobStatus` stream to
// the local ScanRecordStore.
//
// Loop per-record:
//   1. Subscribe to `api.pollJobStatus(jobId)`.
//   2. On every status snapshot, update the corresponding ScanRecord's
//      jobStatus / pipelineStage / failureMessage. The store fires to
//      its broadcast listeners, so HomeViewModel rebuilds the gallery
//      automatically.
//   3. On `state == 'completed'` AND the response carries a download
//      URL, fetch the GLB into `app_documents/scans/<id>.glb` and clear
//      the record's jobStatus (artifactPath now points at the local
//      file).
//   4. On `state == 'failed'`, just persist the failure status; no
//      artifact download.
//
// Resilience:
//   - Network blips inside the polling stream are caught and the
//     record's jobStatus stays as-is so the UI doesn't oscillate; the
//     watcher will try again on next app launch (resume() walks every
//     in-flight record at startup and re-attaches a poll for each).
//   - Multiple watch() calls for the same jobId coalesce onto the same
//     stream subscription — second caller is a no-op.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ui/scan_record.dart';
import '../upload/aether_api_client.dart';
import '../upload/aether_api_models.dart';
import '../upload/authed_api_client.dart';
import 'scan_record_store.dart';

class JobStatusWatcher {
  JobStatusWatcher({
    AetherApiClient? api,
    ScanRecordStore? store,
    Dio? downloadClient,
  })  : _api = api,
        _store = store ?? ScanRecordStore.instance,
        _dl = downloadClient ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 5),
              responseType: ResponseType.stream,
            ));

  static final JobStatusWatcher instance = JobStatusWatcher();

  /// Lazily constructed because `Supabase.instance` isn't ready at
  /// module-load time (the watcher singleton is referenced before
  /// runApp on some code paths). buildAuthedApiClient reads
  /// `Supabase.instance.client.auth` so it must be deferred until
  /// `Supabase.initialize` has completed.
  AetherApiClient? _api;
  AetherApiClient get _client => _api ??= buildAuthedApiClient();

  final ScanRecordStore _store;
  final Dio _dl;

  /// Active polls keyed by record id (NOT jobId — a single record's
  /// jobId could in theory get reissued; record id is what the UI binds
  /// to).
  final Map<String, StreamSubscription<JobStatusResponse>> _watching =
      <String, StreamSubscription<JobStatusResponse>>{};

  /// Re-attach polls for every in-flight record. Call once after the
  /// store loads (typically at app startup).
  ///
  /// Also recovers "ghost" records — ones stuck at `uploading` with no
  /// jobId because the previous app session was killed mid-upload, after
  /// the local ScanRecord was written but before UploadCoordinator
  /// could promote it to queued. Without this recovery the card would
  /// sit on the spinner forever; the watcher can't poll a record with
  /// no jobId, so the only escape was deleting the record by hand.
  Future<void> resume() async {
    await _store.ensureLoaded();

    // Debug dump every record's terminal/transient state — gives us
    // visibility into failed records that the UI can't currently surface
    // (the detail page was removed by design). Without this the only
    // signal a user gets is "the card looks failed" with no reason.
    for (final r in _store.records) {
      if (r.jobStatus == ScanJobStatus.failed) {
        // ignore: avoid_print
        print(
          '[JobStatusWatcher] FAILED record dump: id=${r.id} '
          'jobId=${r.jobId} createdAt=${r.createdAt.toIso8601String()} '
          'videoSize=${r.videoSizeBytes} failureMessage="${r.failureMessage}"',
        );
      }
    }

    final inFlight = _store.inFlight();
    int watched = 0;
    int recoveredGhosts = 0;
    final now = DateTime.now();
    // Records older than this threshold with status=uploading but no
    // jobId are conservatively assumed to be ghosts from a killed
    // session. 90 s is generous — even a 100 MB upload over a slow
    // 4G link finishes inside that.
    const ghostThreshold = Duration(seconds: 90);
    for (final r in inFlight) {
      final jobId = r.jobId;
      if (jobId != null && jobId.isNotEmpty) {
        watch(recordId: r.id, jobId: jobId);
        watched++;
      } else if (r.jobStatus == ScanJobStatus.uploading &&
          now.difference(r.createdAt) > ghostThreshold) {
        recoveredGhosts++;
        await _store.addOrUpdate(r.copyWith(
          jobStatus: ScanJobStatus.failed,
          failureMessage:
              '上传过程中应用退出，任务未完成。删除这张卡片重试。',
        ));
      }
    }
    // ignore: avoid_print
    print(
      '[JobStatusWatcher] resume: ${inFlight.length} in-flight, '
      'watched=$watched, recoveredGhosts=$recoveredGhosts',
    );
  }

  /// Start polling for `jobId` and reflect every transition into the
  /// scan record with id `recordId`. No-op if a poll for this record id
  /// is already active.
  void watch({required String recordId, required String jobId}) {
    if (_watching.containsKey(recordId)) return;
    // ignore: avoid_print
    print('[JobStatusWatcher] watch start: record=$recordId job=$jobId');
    final sub = _client.pollJobStatus(jobId).listen(
      (st) => _onStatus(recordId: recordId, st: st),
      onError: (Object e, StackTrace st) {
        debugPrint('[JobStatusWatcher] poll error for $recordId: $e');
        _watching.remove(recordId)?.cancel();
      },
      onDone: () {
        // ignore: avoid_print
        print('[JobStatusWatcher] watch done: record=$recordId');
        _watching.remove(recordId);
      },
    );
    _watching[recordId] = sub;
  }

  /// Stop polling for `recordId`. The most recent persisted status
  /// stays in place.
  void cancel(String recordId) {
    _watching.remove(recordId)?.cancel();
  }

  Future<void> _onStatus({
    required String recordId,
    required JobStatusResponse st,
  }) async {
    final existing = _store.byId(recordId);
    if (existing == null) {
      // Record was deleted while polling. Drop the subscription.
      cancel(recordId);
      return;
    }
    final mapped = _mapServerState(st.state);
    if (st.state == 'completed') {
      // Download the GLB before flipping the record to "completed" — we
      // don't want the UI to show "可以查看了" then crash on a 404.
      final url = st.primaryArtifactDownloadURL;
      if (url == null || url.isEmpty) {
        debugPrint(
            '[JobStatusWatcher] $recordId completed without download_url');
        await _store.addOrUpdate(existing.copyWith(
          clearJobStatus: true,
          clearJobId: true,
          failureMessage: 'Cloud finished but did not return a download URL.',
          jobStatus: ScanJobStatus.failed,
        ));
        cancel(recordId);
        return;
      }
      try {
        final file = await _store.glbFileFor(recordId);
        await _downloadTo(url, file);
        await _store.addOrUpdate(existing.copyWith(
          clearJobStatus: true,
          clearJobId: true,
          clearFailureMessage: true,
          artifactPath: 'file://${file.path}',
        ));
        // GLB landed safely → normally we'd free the input .mov +
        // curated.json here. UploadCoordinator deliberately keeps these
        // around through the full job lifecycle (queued → assigned →
        // reconstructing → … → completed) so a worker-side FAILED can
        // still be retried from local bytes. Mirrors the server-side
        // R2 retention: input is only cleaned up on COMPLETED-and-
        // delivered (here) and CANCELLED (separate path).
        //
        // EXPERIMENT MODE (2026-05-11): keep .mov + curated.json on
        // disk even after GLB lands, so we can re-trigger the same
        // capture through different pipeline configurations
        // (depth=8/9/10, KEEP_TOP=1/5, with-without rembg mask, etc.)
        // without re-shooting. Flip kKeepInputAfterCompletion=false
        // when leaving experiment mode and shipping to production —
        // a 286 MB orphan per scan is too much for end-user devices.
        // Non-const so the dead-code analyzer doesn't constant-fold the
        // branch away — both branches stay live for easy flipping.
        final bool kKeepInputAfterCompletion = true;
        if (!kKeepInputAfterCompletion) {
          try {
            final video = await _store.videoFileFor(recordId);
            if (await video.exists()) {
              final bytes = await video.length();
              await video.delete();
              // ignore: avoid_print
              print('[JobStatusWatcher] $recordId deleted persisted .mov '
                  '(${(bytes / 1024 / 1024).toStringAsFixed(1)} MB) '
                  'after GLB landing');
            }
            final manifest = await _store.curatedManifestFileFor(recordId);
            if (await manifest.exists()) await manifest.delete();
          } catch (cleanupErr) {
            // Non-fatal — orphan file is at most ~280 MB and will go
            // when the user deletes the scan record.
            debugPrint('[JobStatusWatcher] $recordId source cleanup '
                'failed: $cleanupErr');
          }
        } else {
          // ignore: avoid_print
          print('[JobStatusWatcher] $recordId experiment mode — '
              'keeping .mov + curated.json on disk for re-runs');
        }
      } catch (e, sst) {
        debugPrint('[JobStatusWatcher] download failed for $recordId: $e\n$sst');
        await _store.addOrUpdate(existing.copyWith(
          jobStatus: ScanJobStatus.failed,
          failureMessage: 'Download failed: $e',
        ));
      }
      cancel(recordId);
      return;
    }
    if (st.state == 'failed') {
      await _store.addOrUpdate(existing.copyWith(
        jobStatus: ScanJobStatus.failed,
        failureMessage: st.detail ?? st.title ?? 'Job failed.',
      ));
      cancel(recordId);
      return;
    }
    // Non-terminal: just update the lifecycle status if we recognize the
    // server's state string; otherwise keep what we had.
    if (mapped != null && mapped != existing.jobStatus) {
      // ignore: avoid_print
      print(
        '[JobStatusWatcher] $recordId status: '
        '${existing.jobStatus?.name ?? "null"} → ${mapped.name} '
        '(server state="${st.state}")',
      );
      await _store.addOrUpdate(existing.copyWith(jobStatus: mapped));
    }
  }

  Future<void> _downloadTo(String url, File dest) async {
    if (await dest.parent.exists() == false) {
      await dest.parent.create(recursive: true);
    }
    final tmp = File('${dest.path}.partial');
    if (await tmp.exists()) await tmp.delete();
    // /v1/mobile-jobs/<id>/artifact-download is auth-gated (NYC verifies
    // the user owns the job via supabase JWT). DO Spaces presigned URLs
    // carry their own signature and need no Authorization header. Send
    // the bearer token only for our own host.
    final headers = <String, dynamic>{};
    if (Uri.tryParse(url)?.host == 'api.pocketworld.io') {
      final token = Supabase.instance.client.auth.currentSession?.accessToken;
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }
    final resp = await _dl.get<ResponseBody>(
      url,
      options: Options(responseType: ResponseType.stream, headers: headers),
    );
    final stream = resp.data;
    if (stream == null) {
      throw StateError('Empty stream from $url');
    }
    final sink = tmp.openWrite();
    try {
      await stream.stream.forEach(sink.add);
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await dest.exists()) await dest.delete();
    await tmp.rename(dest.path);
  }

  static ScanJobStatus? _mapServerState(String state) {
    switch (state) {
      case 'uploading':
        return ScanJobStatus.uploading;
      case 'queued':
        return ScanJobStatus.queued;
      case 'reconstructing':
        return ScanJobStatus.reconstructing;
      case 'training':
        return ScanJobStatus.training;
      case 'packaging':
        return ScanJobStatus.packaging;
      case 'failed':
        return ScanJobStatus.failed;
      case 'cancelled':
        return ScanJobStatus.cancelled;
      default:
        return null;
    }
  }
}
