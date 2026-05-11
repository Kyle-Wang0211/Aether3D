// HTTP client for the PocketWorld control plane (https://api.pocketworld.io)
// — formerly api.aether-3d.com; the legacy domain still resolves and is
// served by the same NYC backend so old installs keep working during
// rollout, but new builds canonical-target the new domain.
// + the presigned upload URLs it hands back.
//
// Three endpoints in v1:
//   • POST /v1/mobile-jobs        → create a job, get presigned upload URLs
//   • PUT  <presigned URL>        → push file bytes (DigitalOcean Spaces,
//                                   matching the worker's
//                                   sfo3.digitaloceanspaces.com bucket)
//   • GET  /v1/jobs/{id}          → poll job state
//
// What we deliberately punt on for v1:
//   • Multipart upload — single-PUT works up to ~100 MB, and 1080p × 30s
//     captures cap around 50 MB. Add when typical scans grow past that.
//   • Presigned URL fallback (multi-region failover) — the iOS reference
//     has a `fallbackBaseURL`. We start without; can add once the v1
//     control plane has a real fallback configured.
//
// 2026-05-04: putFile() now goes through background_downloader instead
// of dio. The plugin wraps URLSessionConfiguration.background on iOS
// (and WorkManager on Android), so an upload survives the user switching
// apps, locking the screen, or iOS reclaiming the app's memory. The
// only thing that still kills it is the user force-quitting the app
// from the App Switcher — that's an iOS platform constraint, not ours.
// putBytes() (curated.json sidecar, ~few KB) stays on dio because it
// completes in milliseconds; backgrounding adds zero value there.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';

import 'aether_api_models.dart';

class AetherApiException implements Exception {
  final String code;
  final String? detail;
  const AetherApiException(this.code, [this.detail]);
  @override
  String toString() =>
      detail == null ? 'AetherApiException($code)' : 'AetherApiException($code, $detail)';
}

class AetherApiClient {
  /// Base URL of the control plane. Defaults to the production endpoint
  /// from Aether3D's iOS Info.plist; override for staging.
  final Uri baseUrl;
  /// Bearer token for the Authorization header. Null = unauthenticated
  /// request (control plane will reject with 401, but the call is still
  /// made so error reporting points at the right spot).
  final String? Function() getApiKey;
  /// Optional callback invoked exactly once when an authenticated call
  /// returns 401. The callback is expected to refresh the underlying
  /// auth state (typically `Supabase.instance.client.auth.refreshSession`)
  /// and return true if a fresh token is now available; the client
  /// will then retry the original request once. Returning false (or
  /// throwing) makes the 401 surface as `AetherApiException` to the
  /// caller — same as if the callback weren't supplied.
  ///
  /// Why this exists: Supabase access tokens expire after 1 h. The
  /// supabase_flutter SDK caches the most recently issued token in
  /// `currentSession?.accessToken` and only auto-refreshes opportun-
  /// istically; an app that's been backgrounded across the expiry
  /// boundary will read a stale token and the control plane (which
  /// cross-checks with Supabase /auth/v1/user) returns
  /// `jwt_invalid / Fail to fetch data from the url, HTTP 401`.
  /// Refresh-and-retry on the FIRST 401 fixes this transparently.
  final Future<bool> Function()? refreshAccessToken;
  final Dio _dio;

  AetherApiClient({
    Uri? baseUrl,
    String? Function()? getApiKey,
    this.refreshAccessToken,
    Dio? dio,
  })  : baseUrl = baseUrl ?? Uri.parse('https://api.pocketworld.io'),
        getApiKey = getApiKey ?? _noKey,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
              sendTimeout: const Duration(seconds: 600), // long for big videos
            ));

  static String? _noKey() => null;

  // ─── Job creation ────────────────────────────────────────────────────

  /// Re-queue a FAILED mobile job server-side without re-uploading the
  /// .mov. The control plane preserves the input on R2 across FAILED
  /// transitions (see `_cleanup_terminal_job_storage`'s retention
  /// policy), so this endpoint just resets the job's state from FAILED
  /// to QUEUED so workers can pick it up again.
  ///
  /// Used when the local .mov is gone (cleared app data, restored from
  /// a backup that didn't include `Documents/scans/`) and the regular
  /// reupload-from-local path therefore can't run.
  ///
  /// Throws [AetherApiException] with code `rerun_not_allowed_in_state`
  /// (server returned 409) when the job isn't in FAILED state, or
  /// `input_no_longer_available` (server returned 410) when the R2
  /// object got cleaned up despite the FAILED retention policy
  /// (e.g. stale FAILED row from before the policy change went live).
  Future<void> rerunMobileJob(String jobId) async {
    final url = baseUrl.replace(
      path: '${baseUrl.path}/v1/mobile-jobs/$jobId/rerun',
    );
    final headers = <String, String>{};
    final apiKey = getApiKey();
    if (apiKey != null && apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    try {
      final resp = await _dio.postUri<Map<String, dynamic>>(
        url,
        options: Options(headers: headers),
      );
      if (resp.statusCode != 200) {
        throw AetherApiException(
          'rerun_unexpected_status',
          'expected 200, got ${resp.statusCode}',
        );
      }
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      final detail = e.response?.data is Map
          ? (e.response!.data as Map)['detail']?.toString()
          : null;
      if (code == 409 && detail != null) {
        throw AetherApiException('rerun_not_allowed_in_state', detail);
      }
      if (code == 410) {
        throw const AetherApiException(
          'input_no_longer_available',
          'server-side input .mov was cleaned up; please re-shoot and re-upload',
        );
      }
      if (code == 404) {
        throw AetherApiException('job_not_found', 'jobId=$jobId');
      }
      rethrow;
    }
  }

  Future<CreateMobileJobResponse> createMobileJob(
    CreateMobileJobRequest req,
  ) async {
    final url = baseUrl.replace(path: '${baseUrl.path}/v1/mobile-jobs');
    Future<Response<Map<String, dynamic>>> doPost() {
      final headers = <String, String>{'Content-Type': 'application/json'};
      final apiKey = getApiKey();
      if (apiKey != null && apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer $apiKey';
      }
      return _dio.postUri<Map<String, dynamic>>(
        url,
        data: req.toJson(),
        options: Options(
          headers: headers,
          responseType: ResponseType.json,
        ),
      );
    }

    try {
      Response<Map<String, dynamic>> resp;
      try {
        // ignore: avoid_print
        print('[AetherAPI] createMobileJob → POST $url');
        resp = await doPost();
        // ignore: avoid_print
        print('[AetherAPI] createMobileJob ← ${resp.statusCode}');
      } on DioException catch (e) {
        // ignore: avoid_print
        print(
          '[AetherAPI] createMobileJob DioException: '
          'status=${e.response?.statusCode} body=${e.response?.data}',
        );
        if (e.response?.statusCode == 401 &&
            await _tryRefreshToken()) {
          // Refresh-and-retry once. If the retry ALSO 401s the refresh
          // token is dead too — surface as `session_expired` so the UI
          // can show "请重新登录" instead of a raw HTTP error dump.
          try {
            // ignore: avoid_print
            print('[AetherAPI] createMobileJob retry after refresh');
            resp = await doPost();
            // ignore: avoid_print
            print('[AetherAPI] createMobileJob retry ← ${resp.statusCode}');
          } on DioException catch (e2) {
            // ignore: avoid_print
            print(
              '[AetherAPI] createMobileJob retry DioException: '
              'status=${e2.response?.statusCode} body=${e2.response?.data}',
            );
            if (e2.response?.statusCode == 401) {
              throw const AetherApiException(
                'session_expired',
                'Your sign-in session has expired. Please sign in again.',
              );
            }
            rethrow;
          }
        } else if (e.response?.statusCode == 401) {
          // No refresh callback configured, or refresh failed. Same UX.
          throw const AetherApiException(
            'session_expired',
            'Your sign-in session has expired. Please sign in again.',
          );
        } else {
          rethrow;
        }
      }
      final data = resp.data;
      if (data == null) {
        throw const AetherApiException('empty_response');
      }
      return CreateMobileJobResponse.fromJson(data);
    } on DioException catch (e) {
      throw AetherApiException(
        'create_job_failed',
        '${e.response?.statusCode}: ${e.response?.data ?? e.message}',
      );
    }
  }

  /// Refresh the auth token through the supplied callback, if one was
  /// configured. Returns false (without throwing) if no refresh is
  /// available or the refresh itself failed — caller should rethrow
  /// the original 401 in that case.
  Future<bool> _tryRefreshToken() async {
    final cb = refreshAccessToken;
    if (cb == null) return false;
    try {
      return await cb();
    } catch (_) {
      return false;
    }
  }

  // ─── File upload (single-PUT presigned URL) ──────────────────────────

  /// PUT the contents of [file] to the presigned URL described by
  /// [upload], with progress notifications.
  ///
  /// Uses background_downloader so the upload keeps running when the
  /// app goes to the background or the screen is locked.
  ///
  /// `onProgress(sent, total)` is converted from the plugin's
  /// fractional progress (0..1). `total` is always the file's actual
  /// byte length (we know it ahead of time).
  Future<void> putFile({
    required UploadRequest upload,
    required File file,
    void Function(int sent, int total)? onProgress,
  }) async {
    if (upload.isMultipart) {
      return _putFileMultipart(
        upload: upload,
        file: file,
        onProgress: onProgress,
      );
    }
    final url = upload.url;
    if (url == null || url.isEmpty) {
      throw const AetherApiException('upload_url_missing');
    }
    final method = (upload.method ?? 'PUT').toUpperCase();
    if (method != 'PUT') {
      throw AetherApiException(
        'upload_method_unsupported',
        'expected PUT, got $method',
      );
    }

    final length = await file.length();

    // Task.split converts an absolute file path into the
    // (BaseDirectory, directory, filename) triple the plugin uses to
    // re-resolve the file across app restarts — important because a
    // background upload may outlive the Dart isolate that started it.
    // If the path doesn't sit under one of the standard app dirs
    // (documents / temp / etc.), Task.split returns BaseDirectory.root
    // with the absolute directory path; that's still acceptable for
    // single-session uploads, just less robust to OS-driven UUID
    // changes between launches.
    final (baseDir, directory, filename) =
        await Task.split(filePath: file.path);

    final headers = <String, String>{};
    upload.headers.forEach((k, v) => headers[k] = v.toString());
    // S3-style endpoints reject streamed PUTs without Content-Length,
    // so set it explicitly — dio used to do this for us.
    headers[HttpHeaders.contentLengthHeader] = length.toString();

    final task = UploadTask(
      url: url,
      filename: filename,
      baseDirectory: baseDir,
      directory: directory,
      httpRequestMethod: 'PUT',
      // 'binary' = raw file bytes in the request body, no multipart
      // boundary. Required for presigned-PUT to S3 / DO Spaces.
      post: 'binary',
      headers: headers,
      updates: Updates.statusAndProgress,
      // 1080p×30s captures peak around 50 MB; allow up to 30 min on a
      // slow cellular connection before the system gives up.
      retries: 3,
    );

    final result = await FileDownloader().upload(
      task,
      onProgress: onProgress == null
          ? null
          : (frac) {
              // frac is 0..1; convert to (sent, total) bytes for the
              // existing UploadProgress UI.
              final clamped = frac.clamp(0.0, 1.0);
              onProgress((clamped * length).round(), length);
            },
    );

    if (result.status != TaskStatus.complete) {
      // Surface as much as we can from S3 / DO Spaces — they put the
      // actual rejection reason in the response body XML
      // (`<Error><Code>SignatureDoesNotMatch</Code><Message>...`),
      // which the plugin captures in `responseBody`. Without this the
      // only signal is HTTP status and we can't tell signature mismatch
      // from object-policy reject from quota error.
      final code = result.responseStatusCode;
      final body = result.responseBody;
      // Truncate XML body if huge (some 5xx responses include stack
      // traces); 800 chars is plenty to surface S3 error code + message.
      final bodyExcerpt = body == null
          ? ''
          : (body.length > 800 ? '${body.substring(0, 800)}…' : body);
      // ignore: avoid_print
      print('[CaptureUploader] upload PUT failed: '
          'status=${result.status.name} '
          'httpStatus=$code '
          'url=${url.length > 120 ? "${url.substring(0, 120)}…" : url} '
          'fileSize=$length '
          'sentHeaders=${headers.keys.toList()} '
          'exception=${result.exception} '
          'responseBody=$bodyExcerpt');
      throw AetherApiException(
        'upload_put_failed',
        'background upload status=${result.status.name}'
        '${code != null ? " httpStatus=$code" : ""}'
        '${result.exception != null ? " err=${result.exception}" : ""}'
        '${body != null && body.isNotEmpty ? " body=${body.length > 200 ? "${body.substring(0, 200)}…" : body}" : ""}',
      );
    }
  }

  /// Same shape as putFile but for in-memory blobs (the curated.json
  /// manifest is small enough we never bother going through a temp file).
  Future<void> putBytes({
    required UploadRequest upload,
    required List<int> bytes,
  }) async {
    if (upload.isMultipart) {
      throw const AetherApiException(
        'multipart_upload_unsupported',
        'v1 only supports single-PUT presigned URLs',
      );
    }
    final url = upload.url;
    if (url == null || url.isEmpty) {
      throw const AetherApiException('upload_url_missing');
    }
    // The aux/sidecar upload URL is on our own control plane (e.g.
    // /v1/mobile-jobs/{id}/auxiliary/curated.json/upload), proxied to
    // S3 server-side. The control plane's JWT middleware gates every
    // /v1/mobile-jobs/* path, so PUT here MUST carry the Bearer token
    // — without it we get 401 `upload_put_bytes_failed` after the main
    // video has already uploaded successfully (it went straight to
    // S3 via a presigned URL and didn't need Bearer).
    //
    // Only attach the bearer when the URL is on our own host: if a
    // future contract returns a real S3 presigned URL here, an extra
    // Authorization header could clash with the query-string signature
    // SigV4 expects.
    final parsed = Uri.parse(url);
    final isControlPlane = parsed.host == baseUrl.host;
    final apiKey = isControlPlane ? getApiKey() : null;

    Future<Response<dynamic>> doPut() {
      return _dio.requestUri<dynamic>(
        parsed,
        data: Stream.fromIterable([bytes]),
        options: Options(
          method: (upload.method ?? 'PUT').toUpperCase(),
          headers: <String, dynamic>{
            ...upload.headers,
            HttpHeaders.contentLengthHeader: bytes.length,
            if (apiKey != null && apiKey.isNotEmpty)
              'Authorization': 'Bearer $apiKey',
          },
          responseType: ResponseType.bytes,
        ),
      );
    }

    try {
      try {
        await doPut();
      } on DioException catch (e) {
        // 401 + refresh-and-retry, mirroring the createMobileJob path.
        if (e.response?.statusCode == 401 &&
            isControlPlane &&
            await _tryRefreshToken()) {
          try {
            await doPut();
          } on DioException catch (e2) {
            if (e2.response?.statusCode == 401) {
              throw const AetherApiException(
                'session_expired',
                'Your sign-in session has expired. Please sign in again.',
              );
            }
            rethrow;
          }
        } else {
          rethrow;
        }
      }
    } on DioException catch (e) {
      throw AetherApiException(
        'upload_put_bytes_failed',
        '${e.response?.statusCode}: ${e.message}',
      );
    }
  }

  // ─── Status polling ──────────────────────────────────────────────────

  Future<JobStatusResponse> getJobStatus(String jobId) async {
    // /v1/mobile-jobs/{id} per the server's `pollPath` in
    // CreateMobileJobResponse — NOT /v1/jobs/{id} (that one is the
    // worker-facing path, doesn't carry the same wire shape).
    final url =
        baseUrl.replace(path: '${baseUrl.path}/v1/mobile-jobs/$jobId');
    Future<Response<Map<String, dynamic>>> doGet() {
      final headers = <String, String>{};
      final apiKey = getApiKey();
      if (apiKey != null && apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer $apiKey';
      }
      return _dio.getUri<Map<String, dynamic>>(
        url,
        options: Options(
          headers: headers,
          responseType: ResponseType.json,
        ),
      );
    }

    try {
      Response<Map<String, dynamic>> resp;
      try {
        resp = await doGet();
      } on DioException catch (e) {
        if (e.response?.statusCode == 401 &&
            await _tryRefreshToken()) {
          try {
            resp = await doGet();
          } on DioException catch (e2) {
            if (e2.response?.statusCode == 401) {
              throw const AetherApiException(
                'session_expired',
                'Your sign-in session has expired. Please sign in again.',
              );
            }
            rethrow;
          }
        } else if (e.response?.statusCode == 401) {
          throw const AetherApiException(
            'session_expired',
            'Your sign-in session has expired. Please sign in again.',
          );
        } else {
          rethrow;
        }
      }
      final data = resp.data;
      if (data == null) {
        throw const AetherApiException('empty_response');
      }
      return JobStatusResponse.fromJson(data);
    } on DioException catch (e) {
      throw AetherApiException(
        'get_status_failed',
        '${e.response?.statusCode}: ${e.message}',
      );
    }
  }

  /// Poll job status every [interval] until it reaches a terminal state
  /// (completed / failed). Yields each status snapshot. Terminates when
  /// terminal or after [timeout].
  Stream<JobStatusResponse> pollJobStatus(
    String jobId, {
    Duration interval = const Duration(seconds: 4),
    Duration timeout = const Duration(minutes: 15),
  }) async* {
    final stopAt = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(stopAt)) {
      final st = await getJobStatus(jobId);
      yield st;
      if (st.state == 'completed' || st.state == 'failed') return;
      await Future<void>.delayed(interval);
    }
    throw const AetherApiException('poll_timeout');
  }

  // ─── Multipart upload ────────────────────────────────────────────────
  //
  // When server's `createMobileJob` decides the input video exceeds
  // `CONTROL_PLANE_OBJECT_STORAGE_MULTIPART_THRESHOLD_BYTES` (5 MB by
  // default, so essentially every 4K capture longer than 2 seconds),
  // it returns:
  //
  //   {
  //     "kind": "multipart",
  //     "url": null,              // not used for multipart
  //     "uploadId": "...",        // opaque, pass back to complete/abort
  //     "storageKey": "...",      // S3/Spaces object key
  //     "partSizeBytes": 16777216,// 16 MB per part typically
  //     "maxConcurrency": 20,
  //     "parts": [                // one presigned PUT URL per part
  //       {partNumber: 1, method: "PUT", url: "...", headers: {}},
  //       ...
  //     ],
  //     "partReadyURL":  "https://.../multipart-part-ready",  // optional notify
  //     "completeURL":   "https://.../multipart-complete",
  //     "abortURL":      "https://.../multipart-abort"
  //   }
  //
  // Flow:
  //   1. Read file, partition into N parts of partSizeBytes (last part
  //      may be smaller).
  //   2. Concurrently PUT each part to its presigned URL (limited by
  //      Semaphore to maxConcurrency). Each part PUT returns an ETag in
  //      the response headers — S3 sends it quoted, we preserve verbatim
  //      because the server's S3 CompleteMultipartUpload call needs the
  //      same byte-identical value.
  //   3. Optional: fire-and-forget POST to partReadyURL after each part
  //      so the server can drive "streaming-receive while client is
  //      still uploading" UX.
  //   4. After all parts done, POST completeURL with the part list +
  //      sizeBytes. Server calls S3 CompleteMultipartUpload, atomic-
  //      assembles the object, and flips job state to QUEUED.
  //   5. On any part-PUT failure (after retries), POST abortURL
  //      best-effort to release the upload-id, then rethrow.
  //
  // Retry behaviour: each part gets up to 3 attempts with exponential
  // backoff (1 s, 2 s, 4 s). If all 3 fail we abort the whole upload.
  // Whole-upload retry is the user's job (they tap "上传" again on the
  // failed draft, and the entire create-job → upload flow re-runs with
  // a new uploadId).
  //
  // Why not background_downloader (which the single-PUT path uses):
  // background_downloader wraps URLSessionConfiguration.background for
  // ONE task at a time, not a fan-out of N concurrent uploads. iOS
  // background URLSession does support multiple tasks per session, but
  // the plugin's task-completion semantics assume one Task per call
  // and would serialize them. Foreground multipart over Dio finishes
  // 200 MB in 5–15 s on a good connection, so user-perceived "click
  // upload → done" latency is fine without backgrounding.
  Future<void> _putFileMultipart({
    required UploadRequest upload,
    required File file,
    void Function(int sent, int total)? onProgress,
  }) async {
    final parts = upload.parts ?? const <MultipartPart>[];
    if (parts.isEmpty) {
      throw const AetherApiException(
        'multipart_missing_parts',
        'server returned multipart upload but no parts list',
      );
    }
    final uploadId = upload.uploadId;
    if (uploadId == null || uploadId.isEmpty) {
      throw const AetherApiException(
        'multipart_missing_upload_id',
        'server returned multipart upload but no uploadId',
      );
    }
    final completeURL = upload.completeURL;
    if (completeURL == null || completeURL.isEmpty) {
      throw const AetherApiException(
        'multipart_missing_complete_url',
        'server returned multipart upload but no completeURL',
      );
    }
    final partSize = upload.partSizeBytes;
    if (partSize == null || partSize <= 0) {
      throw const AetherApiException(
        'multipart_missing_part_size',
        'server returned multipart upload but no partSizeBytes',
      );
    }
    // Concurrency cap — DigitalOcean's default `maxConcurrency=20` is
    // server-side advice ("S3 won't throttle if you stay under this").
    // It's NOT a recommendation for client memory: 20 × 16 MB part = 320
    // MB of in-flight buffer, which on a 4 GB device (iPhone 11/12 once
    // the Android ARCore plugin lands and ships 1080p captures) can
    // push phys_footprint past the iOS jetsam threshold mid-upload.
    //
    // 8 is the compromise:
    //   • Bandwidth: 8 concurrent PUT-16MB easily saturates 100 Mbps up
    //     (a typical good wifi / 5G uplink), so we don't lose throughput
    //   • Memory: 8 × 16 MB = 128 MB peak resident, safe even on top of
    //     a 1.5 GB just-stopped-capture working set
    //   • Server: 8 is well below DO Spaces' actual rate ceiling
    //
    // Server still gets to set the floor (small file with 2 parts → 2
    // concurrent), and the env-overridable `maxConcurrency` default
    // (4 if server omits the field entirely) survives.
    const kClientMaxConcurrency = 8;
    final maxConcurrency = math.max(
      1,
      math.min(kClientMaxConcurrency, upload.maxConcurrency ?? 4),
    );
    final totalBytes = await file.length();

    // ignore: avoid_print
    print('[AetherApi] multipart upload start: parts=${parts.length} '
        'partSize=$partSize maxConcurrency=$maxConcurrency '
        'totalBytes=$totalBytes uploadId=$uploadId');

    final etags = <int, String>{};
    final uploadedBytesPerPart = <int, int>{};
    final sem = _Semaphore(maxConcurrency);

    Future<void> runOne(MultipartPart part) async {
      final partNumber = part.partNumber;
      final offset = (partNumber - 1) * partSize;
      final end = math.min(offset + partSize, totalBytes);
      final chunkSize = end - offset;
      if (chunkSize <= 0) {
        throw AetherApiException(
          'multipart_part_out_of_range',
          'partNumber=$partNumber offset=$offset totalBytes=$totalBytes',
        );
      }

      // Read this chunk into memory. Up to partSizeBytes (default 16 MB)
      // per concurrent part; with maxConcurrency=4 that's 64 MB resident
      // at peak — fine on a 6 GB phone, but bounding maxConcurrency is
      // why we floor at min(N, default 4) instead of obeying server's
      // suggested 20.
      final raf = await file.open();
      Uint8List bytes;
      try {
        await raf.setPosition(offset);
        bytes = await raf.read(chunkSize);
      } finally {
        await raf.close();
      }

      // Retry up to 3 attempts per part with exponential backoff.
      Object? lastError;
      String? etag;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          final response = await _dio.requestUri<dynamic>(
            Uri.parse(part.url),
            data: Stream<List<int>>.fromIterable([bytes]),
            options: Options(
              method: part.method.toUpperCase(),
              headers: <String, dynamic>{
                ...part.headers,
                HttpHeaders.contentLengthHeader: chunkSize,
              },
              // The S3-like response for PUT-part is empty body + ETag
              // header. Bytes response type so we don't try to JSON-parse
              // a possibly-empty body and trip up.
              responseType: ResponseType.bytes,
              validateStatus: (s) => s != null && s >= 200 && s < 300,
              // Generous send timeout because a 16 MB chunk over slow
              // cellular can take 10+ s.
              sendTimeout: const Duration(minutes: 5),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );
          // S3 returns ETag header with quotes (e.g. `"5d41402a..."`).
          // We preserve verbatim because the server-side
          // CompleteMultipartUpload XML expects the same byte string.
          final etagHeader = response.headers.value('etag') ??
              response.headers.value('ETag');
          if (etagHeader == null) {
            throw AetherApiException(
              'multipart_part_missing_etag',
              'part #$partNumber response missing ETag header',
            );
          }
          etag = etagHeader;
          break;
        } catch (e) {
          lastError = e;
          if (attempt < 3) {
            final delay = Duration(seconds: 1 << (attempt - 1));
            // ignore: avoid_print
            print('[AetherApi] multipart part #$partNumber attempt $attempt '
                'failed ($e); retrying in ${delay.inSeconds}s');
            await Future<void>.delayed(delay);
          }
        }
      }

      if (etag == null) {
        throw AetherApiException(
          'multipart_part_put_failed',
          'part #$partNumber failed after 3 attempts; last error: $lastError',
        );
      }

      etags[partNumber] = etag;
      uploadedBytesPerPart[partNumber] = chunkSize;

      // Aggregate progress across all completed parts. Note: parts
      // complete out of order due to concurrency; sum-by-part is the
      // honest "bytes acknowledged by S3" number.
      final totalUploaded =
          uploadedBytesPerPart.values.fold<int>(0, (a, b) => a + b);
      onProgress?.call(totalUploaded, totalBytes);

      // Best-effort partReady notify. Server uses this to surface
      // upload progress in real time on the Me page and to flip job
      // state to UPLOADING. Failure is non-fatal — the final
      // complete call carries the same info.
      if (upload.partReadyURL != null) {
        unawaited(_postMultipartPartReadyBestEffort(
          url: upload.partReadyURL!,
          uploadId: uploadId,
          storageKey: upload.storageKey,
          partNumber: partNumber,
          etag: etag,
          uploadedBytes: chunkSize,
          completedPartCount: etags.length,
          totalPartCount: parts.length,
        ));
      }
    }

    try {
      await Future.wait(
        parts.map((p) async {
          await sem.acquire();
          try {
            await runOne(p);
          } finally {
            sem.release();
          }
        }),
      );
    } catch (e) {
      // Abort the multipart so the upload-id doesn't linger server-side.
      // Best-effort; if the user retries, server will issue a fresh
      // uploadId anyway via create-job, and the old one expires on its
      // own per S3's lifecycle policy.
      // ignore: avoid_print
      print('[AetherApi] multipart upload aborting due to: $e');
      if (upload.abortURL != null) {
        unawaited(_postMultipartAbortBestEffort(
          url: upload.abortURL!,
          uploadId: uploadId,
          storageKey: upload.storageKey,
        ));
      }
      rethrow;
    }

    // ignore: avoid_print
    print('[AetherApi] multipart upload all parts done, finalizing...');
    await _postMultipartComplete(
      url: completeURL,
      uploadId: uploadId,
      storageKey: upload.storageKey,
      // Sort by partNumber. server forwards directly to S3
      // CompleteMultipartUpload which requires ascending order.
      parts: (parts.toList()
            ..sort((a, b) => a.partNumber.compareTo(b.partNumber)))
          .map((p) => <String, dynamic>{
                'partNumber': p.partNumber,
                'etag': etags[p.partNumber]!,
              })
          .toList(growable: false),
      sizeBytes: totalBytes,
    );
    // ignore: avoid_print
    print('[AetherApi] multipart upload complete: '
        'parts=${parts.length} totalBytes=$totalBytes');
  }

  Future<void> _postMultipartPartReadyBestEffort({
    required String url,
    required String uploadId,
    required String storageKey,
    required int partNumber,
    required String etag,
    required int uploadedBytes,
    required int completedPartCount,
    required int totalPartCount,
  }) async {
    try {
      final apiKey = getApiKey();
      await _dio.postUri<dynamic>(
        Uri.parse(url),
        data: <String, dynamic>{
          'uploadId': uploadId,
          'storageKey': storageKey,
          'partNumber': partNumber,
          'etag': etag,
          'uploadedBytes': uploadedBytes,
          'completedPartCount': completedPartCount,
          'totalPartCount': totalPartCount,
        },
        options: Options(
          contentType: 'application/json',
          headers: <String, dynamic>{
            if (apiKey != null && apiKey.isNotEmpty)
              'Authorization': 'Bearer $apiKey',
          },
          validateStatus: (s) => s != null && s >= 200 && s < 300,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
    } catch (e) {
      // ignore: avoid_print
      print('[AetherApi] multipart_part_ready notify failed (non-fatal): '
          'part=$partNumber err=$e');
    }
  }

  Future<void> _postMultipartAbortBestEffort({
    required String url,
    required String uploadId,
    required String storageKey,
  }) async {
    try {
      final apiKey = getApiKey();
      await _dio.postUri<dynamic>(
        Uri.parse(url),
        data: <String, dynamic>{
          'uploadId': uploadId,
          'storageKey': storageKey,
        },
        options: Options(
          contentType: 'application/json',
          headers: <String, dynamic>{
            if (apiKey != null && apiKey.isNotEmpty)
              'Authorization': 'Bearer $apiKey',
          },
          validateStatus: (s) => s != null && s >= 200 && s < 300,
          sendTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
    } catch (e) {
      // ignore: avoid_print
      print('[AetherApi] multipart_abort failed (non-fatal): $e');
    }
  }

  Future<void> _postMultipartComplete({
    required String url,
    required String uploadId,
    required String storageKey,
    required List<Map<String, dynamic>> parts,
    required int sizeBytes,
  }) async {
    Future<Response<dynamic>> doPost() {
      final apiKey = getApiKey();
      return _dio.postUri<dynamic>(
        Uri.parse(url),
        data: <String, dynamic>{
          'uploadId': uploadId,
          'storageKey': storageKey,
          'parts': parts,
          'sizeBytes': sizeBytes,
        },
        options: Options(
          contentType: 'application/json',
          headers: <String, dynamic>{
            if (apiKey != null && apiKey.isNotEmpty)
              'Authorization': 'Bearer $apiKey',
          },
          validateStatus: (s) => s != null && s >= 200 && s < 300,
          // Server invokes S3 CompleteMultipartUpload which can take
          // multiple seconds to atomically stitch parts. Generous
          // timeout.
          sendTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 120),
        ),
      );
    }

    try {
      await doPost();
    } on DioException catch (e) {
      // Same 401 refresh-and-retry as the other authenticated paths.
      if (e.response?.statusCode == 401 && await _tryRefreshToken()) {
        try {
          await doPost();
          return;
        } on DioException catch (e2) {
          throw AetherApiException(
            'multipart_complete_failed',
            'status=${e2.response?.statusCode ?? "?"} '
            'body=${e2.response?.data}',
          );
        }
      }
      throw AetherApiException(
        'multipart_complete_failed',
        'status=${e.response?.statusCode ?? "?"} '
        'body=${e.response?.data}',
      );
    }
  }
}

/// Minimal counting semaphore for bounding multipart upload concurrency.
/// Dart's standard library doesn't ship one and pulling in `package:pool`
/// just for this would be overkill — the semantics are 12 lines.
class _Semaphore {
  final int maxPermits;
  int _available;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  _Semaphore(this.maxPermits) : _available = maxPermits;

  Future<void> acquire() {
    if (_available > 0) {
      _available--;
      return Future<void>.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _available++;
    }
  }
}

/// Convenience for callers that want to log raw JSON.
String prettyJson(Object o) =>
    const JsonEncoder.withIndent('  ').convert(o);
