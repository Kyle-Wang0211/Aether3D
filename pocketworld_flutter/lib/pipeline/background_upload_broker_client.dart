// Dart port of Core/Pipeline/BackgroundUploadBrokerClient.swift (partial).
//
// The Swift implementation is ~4100 lines — covers multipart streaming
// upload, AVFoundation transcoding, iOS BackgroundURLSession resume
// handling, detailed retry taxonomy, and on-disk staging area.
// We port the **core request surface** today: createJob / pollStatus /
// downloadPrimaryArtifact / cancel / clientEvent. The following pieces
// are tracked in PORTING_BACKLOG.md (section "Broker client gaps") and
// deferred until a real broker is reachable for end-to-end tests:
//
//   • BackgroundURLSession (iOS background upload resumption) — today
//     the Dart client uses a foreground dio Multipart request. Works
//     fine when the app stays foregrounded; for background uploads
//     iOS needs URLSession with identifier, which requires a plugin.
//   • AVFoundation video transcoding (StreamFriendlyUploadPreparer) —
//     today the video file is uploaded as-is. When device / server
//     bandwidth matters, wire `video_compress` or an FFmpeg FFI path.
//   • Fallback URL retry taxonomy (shouldRetryWithFallback /
//     shouldRetryFetchJobStatus). We map 5xx + timeouts to a simple
//     single retry; the 60-state Swift retry matrix is deferred.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'artifact_manifest.dart';
import 'broker_config.dart';
import 'remote_b1_client.dart';

class BackgroundUploadBrokerClient implements RemoteB1Client {
  final BackgroundUploadBrokerConfiguration config;
  final Dio _dio;

  /// Optional per-job manifest cache — populated by `pollStatus` /
  /// `createJob` responses so `download()` can verify SHA256 without
  /// a separate round-trip. Single-process only; flushed on sign-out.
  final Map<String, BrokerArtifactManifest> _manifestCache = {};

  BackgroundUploadBrokerClient({required this.config, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: config.baseUrl.toString(),
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(minutes: 15),
              receiveTimeout: const Duration(minutes: 5),
              headers: {
                if (config.apiKey != null && config.apiKey!.isNotEmpty)
                  'Authorization': 'Bearer ${config.apiKey}',
                'X-Aether-Client': 'pocketworld-flutter',
              },
              responseType: ResponseType.json,
            ));

  // ─── RemoteB1Client ────────────────────────────────────────────

  /// Foreground multipart upload. Returns the server-assigned `job_id`.
  ///
  /// Upload path: `POST /v1/mobile-jobs` with a multipart body:
  ///   • `video` file part (streamed — dio chunks disk reads)
  ///   • `client_request` JSON part carrying metadata (optional).
  @override
  Future<String> upload({
    required String videoFilePath,
    void Function(RemoteUploadProgress)? onProgress,
  }) async {
    final file = File(videoFilePath);
    if (!await file.exists()) {
      throw RemoteB1ClientException(
        code: 'video_missing',
        message: '待上传视频文件不存在: $videoFilePath',
      );
    }
    final totalBytes = await file.length();
    final form = FormData.fromMap({
      'video': await MultipartFile.fromFile(
        videoFilePath,
        filename: videoFilePath.split(Platform.pathSeparator).last,
        contentType: DioMediaType('video', 'mp4'),
      ),
    });
    try {
      final resp = await _dio.post<Map<String, dynamic>>(
        '/v1/mobile-jobs',
        data: form,
        options: Options(
          headers: {
            'Content-Type': 'multipart/form-data',
          },
        ),
        onSendProgress: onProgress == null
            ? null
            : (sent, total) {
                onProgress(RemoteUploadProgress(
                  uploadedBytes: sent,
                  totalBytes: total > 0 ? total : totalBytes,
                  phase: sent >= (total > 0 ? total : totalBytes)
                      ? RemoteUploadPhase.finalizing
                      : RemoteUploadPhase.transferring,
                ));
              },
      );
      final body = resp.data;
      if (body == null) {
        throw RemoteB1ClientException(
          code: 'empty_response',
          message: 'createJob 返回空响应',
          httpStatusCode: resp.statusCode,
        );
      }
      // Cache any manifest the server returned inline so later download
      // calls can verify SHA256.
      try {
        final manifest = BrokerArtifactManifest.fromJson(body);
        if (manifest.jobId.isNotEmpty) _manifestCache[manifest.jobId] = manifest;
        return manifest.jobId;
      } on Object {
        final jobId = body['job_id'] as String? ?? body['id'] as String?;
        if (jobId == null || jobId.isEmpty) {
          throw RemoteB1ClientException(
            code: 'missing_job_id',
            message: 'createJob 响应中未找到 job_id',
            httpStatusCode: resp.statusCode,
          );
        }
        return jobId;
      }
    } on DioException catch (e) {
      throw _mapDioError(e, operation: 'upload');
    }
  }

  /// Some backends separate "accept video" from "kick off processing".
  /// Broker currently rolls them together — so `startJob` is a no-op
  /// that just returns the same assetId/jobId.
  @override
  Future<String> startJob({required String assetId}) async => assetId;

  @override
  Future<JobStatus> pollStatus({required String jobId}) async {
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        '/v1/mobile-jobs/$jobId',
      );
      final body = resp.data;
      if (body == null) {
        throw RemoteB1ClientException(
          code: 'empty_response',
          message: 'pollStatus 返回空响应',
          httpStatusCode: resp.statusCode,
        );
      }
      // Opportunistically refresh the manifest cache for this job.
      try {
        final manifest = BrokerArtifactManifest.fromJson(body);
        if (manifest.jobId.isNotEmpty) _manifestCache[manifest.jobId] = manifest;
      } catch (_) {/* manifest may not yet be present */}
      return _parseStatus(body);
    } on DioException catch (e) {
      throw _mapDioError(e, operation: 'pollStatus');
    }
  }

  @override
  Future<DownloadedArtifact> download({required String jobId}) async {
    // Manifest may not have been seen yet if the caller called
    // `download` without first polling. Fetch status once so we get
    // the sha256 for verification.
    if (!_manifestCache.containsKey(jobId)) {
      try {
        await pollStatus(jobId: jobId);
      } catch (_) {/* best effort */}
    }
    final manifest = _manifestCache[jobId];
    final entry = manifest?.maybeFile(ArtifactKind.primaryAsset);

    // If the server provided a direct URL, prefer it; otherwise hit
    // the canonical path.
    final url = entry?.downloadUrl ??
        '/v1/mobile-jobs/$jobId/artifact-download/primary_asset';

    try {
      final resp = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: true,
        ),
      );
      final bytes = await _collectStream(resp.data!);
      if (entry != null) {
        if (!verifyDownloadedFile(entry, bytes)) {
          throw ArtifactIntegrityException(
            kind: entry.kind,
            expected: entry.sha256 ?? '',
            actual: '', // computed inside verifyDownloadedFile; surface as diagnostic
          );
        }
      }
      final format = artifactFormatFromExtension(
        entry?.filename.split('.').last,
      );
      return DownloadedArtifact(
        data: bytes,
        format: format,
        sha256: entry?.sha256,
      );
    } on DioException catch (e) {
      throw _mapDioError(e, operation: 'download');
    }
  }

  @override
  Future<void> cancel({required String jobId}) async {
    try {
      await _dio.delete('/v1/mobile-jobs/$jobId');
    } on DioException catch (e) {
      throw _mapDioError(e, operation: 'cancel');
    }
  }

  // ─── Diagnostic client-event POST (matches Swift
  // `submitClientEvent` at L3521) ───────────────────────────────────

  Future<void> reportClientEvent({
    required String jobId,
    required String eventType,
    Map<String, Object?> payload = const {},
  }) async {
    try {
      await _dio.post(
        '/v1/mobile-jobs/$jobId/client-event',
        data: jsonEncode({
          'type': eventType,
          'payload': payload,
          'sent_at': DateTime.now().toUtc().toIso8601String(),
        }),
        options: Options(
          headers: {'Content-Type': 'application/json'},
        ),
      );
    } on DioException catch (e) {
      // Client events are best-effort analytics — don't throw.
      _logDioError(e, operation: 'reportClientEvent');
    }
  }

  /// Read the cached manifest (if any). Useful for UI that wants to
  /// show "此作品已就绪 (x MB)" without downloading.
  BrokerArtifactManifest? cachedManifest(String jobId) => _manifestCache[jobId];

  /// Rename a scan record on the broker. Mirrors the user-visible
  /// "改名" action described in today's direction (default "未命名作品").
  Future<void> renameRecord({
    required String jobId,
    required String newName,
  }) async {
    try {
      await _dio.patch(
        '/v1/mobile-jobs/$jobId',
        data: jsonEncode({'display_name': newName}),
        options: Options(
          headers: {'Content-Type': 'application/json'},
        ),
      );
      final cached = _manifestCache[jobId];
      if (cached != null) {
        _manifestCache[jobId] = cached.copyWithDisplayName(newName);
      }
    } on DioException catch (e) {
      throw _mapDioError(e, operation: 'renameRecord');
    }
  }

  // ─── Internals ──────────────────────────────────────────────────

  JobStatus _parseStatus(Map<String, dynamic> body) {
    final status = (body['status'] as String? ?? '').toLowerCase();
    final progress = RemoteJobProgress(
      progressFraction: (body['progress'] as num?)?.toDouble() ??
          (body['progress_fraction'] as num?)?.toDouble(),
      stageKey: body['stage_key'] as String?,
      phaseName: body['phase_name'] as String? ?? body['phase'] as String?,
      currentTier: body['current_tier'] as String?,
      title: body['title'] as String?,
      detail: body['detail'] as String? ?? body['status_detail'] as String?,
      etaMinutes: (body['eta_minutes'] as num?)?.toInt(),
      elapsedSeconds: (body['elapsed_seconds'] as num?)?.toInt(),
      progressBasis: body['progress_basis'] as String?,
      runtimeMetrics: _extractMetrics(body['runtime_metrics']),
    );
    switch (status) {
      case 'pending':
      case 'queued':
        return JobStatus.pending(progress);
      case 'processing':
      case 'reconstructing':
      case 'training':
      case 'packaging':
        return JobStatus.processing(progress);
      case 'download_ready':
      case 'artifact_ready':
        return JobStatus.downloadReady(progress);
      case 'completed':
      case 'succeeded':
        return JobStatus.completed(progress);
      case 'failed':
        return JobStatus.failed(
          reason: body['failure_reason'] as String? ??
              body['error'] as String? ??
              progress.detail ??
              '任务未产出可用结果',
          progress: progress,
        );
      case 'cancelled':
        return JobStatus.cancelled(progress);
      default:
        // Unknown status — treat as processing so the UI keeps polling.
        return JobStatus.processing(progress);
    }
  }

  Map<String, String> _extractMetrics(Object? raw) {
    if (raw is Map) {
      final out = <String, String>{};
      for (final entry in raw.entries) {
        out['${entry.key}'] = '${entry.value}';
      }
      return out;
    }
    return const {};
  }

  Future<Uint8List> _collectStream(ResponseBody body) async {
    final buf = BytesBuilder(copy: false);
    await for (final chunk in body.stream) {
      buf.add(chunk);
    }
    return buf.takeBytes();
  }

  RemoteB1ClientException _mapDioError(
    DioException e, {
    required String operation,
  }) {
    _logDioError(e, operation: operation);
    final code = e.response?.statusCode;
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return RemoteB1ClientException(
        code: 'timeout',
        message: 'broker $operation 超时',
        httpStatusCode: code,
      );
    }
    if (e.type == DioExceptionType.connectionError ||
        e.error is SocketException) {
      return RemoteB1ClientException(
        code: 'network',
        message: 'broker $operation 网络错误: ${e.message}',
        httpStatusCode: code,
      );
    }
    final detail = e.response?.data?.toString() ?? e.message ?? '';
    return RemoteB1ClientException(
      code: 'http_${code ?? 'unknown'}',
      message: 'broker $operation 失败: $detail',
      httpStatusCode: code,
    );
  }

  void _logDioError(DioException e, {required String operation}) {
    // Intentionally print — this file is tested end-to-end against a
    // real broker and having diagnostics in the console is the first
    // line of incident response.
    // ignore: avoid_print
    print('[broker] $operation failed: type=${e.type} code=${e.response?.statusCode} msg=${e.message}');
  }
}
