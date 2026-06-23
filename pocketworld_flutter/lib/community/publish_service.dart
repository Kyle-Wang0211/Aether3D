// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// PublishService — publish a finished local ScanRecord to the public
// community feed. Re-introduces the "发布到社区" flow that was deleted in
// Plan G W2 (2026-05-16). See
// docs/superpowers/specs/2026-06-23-publish-to-community-design.md.
//
// Orchestration (client-only, NO server change — works table owner-insert
// + works bucket owner-write are both already live; only scans/thumbnails
// were broker-hardened on 2026-05-22):
//
//   read bytes (record.artifactPath, file://)
//     → normalize (community-tuned opts; idempotent + content-addressed)
//     → sha1(output)
//     → upload works/{uid}/{sha1}.glb (direct, upsert)
//     → insert public works row (visibility=public + published_at set)
//     → best-effort thumbnail via CommunityService.uploadAndSetThumbnail
//     → return PublishResult
//
// Invariant: the works row is inserted ONLY after the storage upload
// succeeds → there is never a feed row pointing at a missing model.
//
// Cross-platform: pure Dart on top of supabase_flutter + glb_norm. No
// Flutter-widget imports (mirrors CommunityService's portability rule).
// Does NOT touch ScanRecordStore — the UI marks cloudWorkId after a
// successful PublishResult, keeping this service store-agnostic and
// host-testable with no disk / no FFI.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../glb_norm/glb_norm.dart';
import '../ui/scan_record.dart';
import 'community_service.dart';

/// Community-tuned normalize preset. MORE aggressive than the local-
/// viewing default (`GlbNormOptions()` = 500K faces / 8K atlas) because
/// the community feed downloads the model over the network and renders
/// it in a multi-card feed.
///
/// Rationale (grounded — parallel spike + Polycam audit):
///   • Polycam's #1 fast-load lever is decimation, NOT geometry/texture
///     codecs (no Draco/meshopt/KTX2). PocketWorld's 500K local default
///     is 5–10× heavier than Polycam's 50k–100k feed budget.
///   • A parallel benchmark spike found texture/atlas-size is the bigger
///     byte lever and a 50K-face target is unreachable on the quality
///     path, so 150K faces is the validated v1 face budget.
///   • Atlas: the SAME spike (docs/p1_texture_compression_spike_2026-06-23.md)
///     measured that 8K→4K is a no-op here — source atlases are already
///     4096² and the merger only downscales a chart past 85% of side², so
///     8192/4096 are texel-equivalent (~3.8–4.1K px chart) and 4K is even
///     slightly LARGER in bytes. 2048 is the only real step down: PNG −65%,
///     GLB roughly halved (~25MB→~13.5MB), ~1900px chart — ample for a
///     phone-screen feed card. BOTH target+max must be pinned to 2048 or
///     the merger's retry loop regrows `side` back toward 8K.
/// See docs/polycam_fast_loading_research_2026-06-23.md §四,
/// docs/polycam_replication_oss_blueprint_2026-06-23.md P0, and
/// docs/p1_texture_compression_spike_2026-06-23.md.
const GlbNormOptions kCommunityNormOptions = GlbNormOptions(
  targetFaceCount: 150000, // spike-validated v1 face budget (vs 500K default).
  targetAtlasSize: 2048, // 2K = the real byte lever; 4K==8K here (spike).
  maxAtlasSize: 2048, // pin BOTH or the merger regrows toward 8K.
);

/// Signature matching [GlbNormalizer.normalize] so tests can fake the
/// native (non-host-testable) normalize. Real impl forwards to
/// GlbNormalizer.normalize.
typedef GlbNormalizeFn = Future<GlbNormResult> Function({
  required Uint8List input,
  GlbNormOptions opts,
  void Function(double fraction, String phase)? onProgress,
});

/// Direct GLB upload seam. Real impl calls
/// `client.storage.from('works').uploadBinary(...)`. Injectable so the
/// orchestration test never touches a live Supabase / sealed storage API.
typedef UploadGlbFn = Future<String> Function({
  required String path,
  required Uint8List bytes,
});

/// `works` row insert seam. Real impl calls
/// `client.from('works').insert(row).select('id').single()` and returns
/// the read-back id. Injectable for the same reason as [UploadGlbFn].
typedef InsertWorkFn = Future<String> Function({
  required Map<String, dynamic> row,
});

/// Narrow view of [CommunityService] used by [PublishService] — just the
/// thumbnail broker. Lets the unit test fake it without a live Supabase.
/// [CommunityService] satisfies this implicitly (same method shape); the
/// real wiring adapts it via [_CommunityAdapter] below.
abstract class CommunityServiceLike {
  Future<String?> uploadAndSetThumbnail({
    required String workId,
    required Uint8List jpegBytes,
  });
}

/// Adapts the concrete [CommunityService] to [CommunityServiceLike].
class _CommunityAdapter implements CommunityServiceLike {
  final CommunityService _inner;
  _CommunityAdapter(this._inner);

  @override
  Future<String?> uploadAndSetThumbnail({
    required String workId,
    required Uint8List jpegBytes,
  }) =>
      _inner.uploadAndSetThumbnail(workId: workId, jpegBytes: jpegBytes);
}

/// One progress event from an in-flight publish. Mirrors the shape of
/// `ImportProgress` so the modal-progress UI can reuse the same
/// phase/fraction rendering.
@immutable
class PublishProgress {
  /// 'reading' | 'normalizing' | 'uploading' | 'inserting' | 'thumbnail'
  /// | 'done' | 'failed'
  final String phase;

  /// Monotonic 0..1.
  final double fraction;

  /// C-side normalize phase string during 'normalizing', else null.
  final String? detail;

  const PublishProgress({
    required this.phase,
    required this.fraction,
    this.detail,
  });

  @override
  String toString() =>
      'PublishProgress($phase, ${(fraction * 100).toStringAsFixed(1)}%'
      '${detail == null ? '' : ', $detail'})';
}

/// Terminal result of a successful publish.
@immutable
class PublishResult {
  /// works.id (uuid) from the insert .select('id').single().
  final String workId;

  /// '{uid}/{sha1}.glb'.
  final String modelStoragePath;

  /// Normalized GLB byte length.
  final int fileSizeBytes;

  /// null if the best-effort bake failed (first-viewer covers later).
  final String? thumbnailStoragePath;

  const PublishResult({
    required this.workId,
    required this.modelStoragePath,
    required this.fileSizeBytes,
    this.thumbnailStoragePath,
  });
}

/// Thrown on any non-recoverable publish failure. [phase] says where it
/// died so the UI snackbar can be specific. NO `works` row is ever left
/// orphaned (insert only happens AFTER upload succeeds).
class PublishException implements Exception {
  /// 'reading' | 'normalizing' | 'uploading' | 'inserting'
  final String phase;
  final String message;
  const PublishException(this.phase, this.message);

  @override
  String toString() => 'PublishException($phase): $message';
}

class PublishService {
  final String? Function() _uid;
  final CommunityServiceLike _community;
  final GlbNormalizeFn _normalize;
  final UploadGlbFn _uploadGlb;
  final InsertWorkFn _insertWork;

  PublishService._({
    required String? Function() uid,
    required CommunityServiceLike community,
    required GlbNormalizeFn normalize,
    required UploadGlbFn uploadGlb,
    required InsertWorkFn insertWork,
  })  : _uid = uid,
        _community = community,
        _normalize = normalize,
        _uploadGlb = uploadGlb,
        _insertWork = insertWork;

  /// Production constructor. Wires the real Supabase client + a fresh
  /// [CommunityService] + the real native [GlbNormalizer.normalize] by
  /// default. Inject collaborators to override (e.g. a shared
  /// CommunityService instance).
  factory PublishService({
    SupabaseClient? client,
    CommunityService? community,
    GlbNormalizeFn? normalize,
  }) {
    final c = client ?? Supabase.instance.client;
    final comm = community ?? CommunityService(client: c);
    return PublishService._(
      uid: () => c.auth.currentUser?.id,
      community: _CommunityAdapter(comm),
      normalize: normalize ?? GlbNormalizer.normalize,
      uploadGlb: ({required path, required bytes}) async {
        // Direct owner-write to the `works` bucket. The 2026-05-22
        // broker-hardening migration left `works` direct-write intact
        // (works_insert_self / works_update_self). upsert dedups a
        // content-addressed re-publish.
        return c.storage.from('works').uploadBinary(
              path,
              bytes,
              fileOptions: const FileOptions(
                contentType: 'model/gltf-binary',
                upsert: true,
                cacheControl: '604800', // 7 days — content-addressed.
              ),
            );
      },
      insertWork: ({required row}) async {
        final inserted =
            await c.from('works').insert(row).select('id').single();
        return inserted['id'] as String;
      },
    );
  }

  /// Test-only constructor. Injects every external seam so the
  /// orchestration is host-testable with no FFI / no Supabase.
  @visibleForTesting
  factory PublishService.forTest({
    required String? Function() uid,
    required CommunityServiceLike community,
    required GlbNormalizeFn normalize,
    required UploadGlbFn uploadGlb,
    required InsertWorkFn insertWork,
  }) =>
      PublishService._(
        uid: uid,
        community: community,
        normalize: normalize,
        uploadGlb: uploadGlb,
        insertWork: insertWork,
      );

  /// Publish a finished local record to the public community feed.
  ///
  /// Preconditions (gated by the caller, re-checked here as defense in
  /// depth): signed in, `record.artifactPath` is a non-null file:// GLB,
  /// `record.cloudWorkId == null`. The CALLER marks the local record's
  /// cloudWorkId after a successful result — this service never touches
  /// the store.
  Future<PublishResult> publish({
    required ScanRecord record,
    required String title,
    String? description,
    Uint8List? thumbnailJpeg,
    void Function(PublishProgress)? onProgress,
  }) async {
    void emit(String phase, double fraction, [String? detail]) {
      onProgress?.call(
        PublishProgress(phase: phase, fraction: fraction, detail: detail),
      );
    }

    // 1) Preconditions.
    final uid = _uid();
    if (uid == null) {
      throw const PublishException('reading', 'signed out');
    }
    if (record.cloudWorkId != null) {
      throw const PublishException('reading', 'already published');
    }
    final artifact = record.artifactPath;
    if (artifact == null || !artifact.startsWith('file://')) {
      throw const PublishException(
          'reading', 'record has no local file:// GLB');
    }

    // 2) Read GLB bytes off disk.
    emit('reading', 0.02);
    final Uint8List bytes;
    try {
      final path = Uri.parse(artifact).toFilePath();
      final file = File(path);
      if (!await file.exists()) {
        throw const PublishException('reading', 'GLB file no longer exists');
      }
      bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        throw const PublishException('reading', 'GLB file is empty');
      }
    } on PublishException {
      rethrow;
    } catch (e) {
      throw PublishException('reading', e.toString());
    }

    // 3) Normalize (community opts). Map native 0..1 → [0.05, 0.55].
    emit('normalizing', 0.05);
    final GlbNormResult result;
    try {
      result = await _normalize(
        input: bytes,
        opts: kCommunityNormOptions,
        onProgress: (fraction, phase) {
          final mapped = 0.05 + 0.50 * fraction.clamp(0.0, 1.0);
          emit('normalizing', mapped, phase.isEmpty ? null : phase);
        },
      );
    } catch (e) {
      throw PublishException('normalizing', e.toString());
    }
    if (!result.isOk || result.output == null) {
      throw PublishException(
        'normalizing',
        result.error ?? 'normalize failed (status=${result.status.name})',
      );
    }
    final output = result.output!;

    // 4) Content-address. Same bytes → same path → upsert dedups.
    final hash = sha1.convert(output).toString();
    final storagePath = '$uid/$hash.glb';
    emit('uploading', 0.55);

    // 5) Direct upload. NO works row exists yet → nothing to orphan.
    try {
      await _uploadGlb(path: storagePath, bytes: output);
    } catch (e) {
      throw PublishException('uploading', e.toString());
    }

    // 6) Insert the public works row, read back the id.
    emit('inserting', 0.80);
    final trimmedDesc = description?.trim();
    final row = <String, dynamic>{
      'user_id': uid,
      'title': title,
      'description':
          (trimmedDesc == null || trimmedDesc.isEmpty) ? null : trimmedDesc,
      'format': 'glb',
      'model_storage_path': storagePath,
      'file_size_bytes': output.length,
      'visibility': 'public',
      'published_at': DateTime.now().toUtc().toIso8601String(),
    };
    final String workId;
    try {
      workId = await _insertWork(row: row);
    } catch (e) {
      throw PublishException('inserting', e.toString());
    }

    // 7) Best-effort thumbnail. NEVER throws — first-viewer ThumbBaker is
    // the fallback (work_detail_page first-frame hook).
    emit('thumbnail', 0.90);
    String? thumbPath;
    if (thumbnailJpeg != null) {
      try {
        thumbPath = await _community.uploadAndSetThumbnail(
          workId: workId,
          jpegBytes: thumbnailJpeg,
        );
      } catch (e) {
        debugPrint('[PublishService] thumbnail best-effort failed: $e');
        thumbPath = null;
      }
    }

    // 8) Done.
    emit('done', 1.0);
    return PublishResult(
      workId: workId,
      modelStoragePath: storagePath,
      fileSizeBytes: output.length,
      thumbnailStoragePath: thumbPath,
    );
  }
}
