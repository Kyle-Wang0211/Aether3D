// PublishService — uploads a local GLB to the `works` bucket and
// inserts/updates the matching `public.works` row so it shows up on the
// community feed.
//
// Two paths:
//   • First publish: bucket UPLOAD + works INSERT with visibility =
//     'public'. The works row's id becomes the ScanRecord's
//     publishedWorkId.
//   • Subsequent edits: works UPDATE only — title / description /
//     visibility. We don't re-upload the GLB unless the user re-runs
//     the scan (which produces a fresh ScanRecord).
//
// RLS:
//   • storage.works expects `<auth.uid()>/...` as the path prefix
//     (works_insert_self policy).
//   • public.works INSERT requires `auth.uid() = user_id`.
//   • UPDATE / DELETE require `auth.uid() = user_id`.
//
// Title validation:
//   1..100 chars (matches DB CHECK). Caller should already enforce in
//   the form, but we double-check here so a bad payload doesn't burn a
//   storage upload before the DB INSERT rejects.
//
// Description validation:
//   ≤ 5000 chars (matches DB CHECK).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ui/scan_record.dart';
import 'scan_record_store.dart';

class PublishException implements Exception {
  final String code;
  final String? detail;
  const PublishException(this.code, [this.detail]);
  @override
  String toString() =>
      detail == null ? 'PublishException($code)' : 'PublishException($code, $detail)';
}

class PublishService {
  PublishService({
    SupabaseClient? client,
    ScanRecordStore? store,
  })  : _client = client ?? Supabase.instance.client,
        _store = store ?? ScanRecordStore.instance;

  static final PublishService instance = PublishService();

  final SupabaseClient _client;
  final ScanRecordStore _store;

  /// First-time publish. Uploads `record.artifactPath` (must be a local
  /// file:// URL) to the `works/{uid}/{recordId}.glb` storage path,
  /// then inserts a `works` row with visibility='public' and
  /// published_at=now(). Returns the new works.id and persists it on
  /// the ScanRecord.
  Future<String> publish({
    required ScanRecord record,
    required String title,
    String? description,
    String visibility = 'public',
  }) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) {
      throw const PublishException(
        'not_authenticated',
        'Sign in before publishing.',
      );
    }
    final artifact = record.artifactPath;
    if (artifact == null || !artifact.startsWith('file://')) {
      throw const PublishException(
        'no_local_artifact',
        'No local GLB to publish — wait until the scan finishes processing.',
      );
    }
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty || trimmedTitle.length > 100) {
      throw const PublishException(
        'invalid_title',
        'Title must be 1–100 characters.',
      );
    }
    final trimmedDesc = description?.trim();
    if (trimmedDesc != null && trimmedDesc.length > 5000) {
      throw const PublishException(
        'invalid_description',
        'Description must be ≤ 5000 characters.',
      );
    }
    if (record.publishedWorkId != null) {
      // Already published once — caller should use editPublished instead.
      return await editPublished(
        workId: record.publishedWorkId!,
        title: trimmedTitle,
        description: trimmedDesc,
        visibility: visibility,
        recordId: record.id,
      );
    }

    final localPath = Uri.parse(artifact).toFilePath();
    final localFile = File(localPath);
    if (!await localFile.exists()) {
      throw PublishException(
        'local_artifact_missing',
        'Local GLB at $localPath was not found.',
      );
    }
    final storagePath = '$uid/${record.id}.glb';
    try {
      await _client.storage.from('works').upload(
            storagePath,
            localFile,
            fileOptions: const FileOptions(
              contentType: 'model/gltf-binary',
              upsert: true,
            ),
          );
    } on StorageException catch (e) {
      throw PublishException('storage_upload_failed', e.message);
    }

    // Phase 6.4f.11 — upload the locally-extracted .mov thumbnail to
    // supabase alongside the GLB. Without this, every published work
    // arrives with `thumbnail_storage_path = NULL`, so PostCard's
    // backdrop falls through to the gradient — which the user
    // experiences as "正常的 GLB 文件也是 5 秒以上才刷新出来 live 3d"
    // (5 s of gray while Filament initializes, no static image to
    // bridge the gap). With the thumb in place, the feed shows the
    // .mov-extracted poster instantly; AetherCppCardDemo's live viewer
    // crossfades in over it once the first frame paints.
    //
    // Path layout: `<uid>/<recordId>.jpg` inside the `thumbnails`
    // bucket (mirrors the works bucket's `<uid>/<recordId>.glb`
    // layout). `upload_coordinator.dart` populated `thumbnailPath` at
    // capture time via video_thumbnail; if for some reason it didn't
    // (older record predating that code, or the .mov was never
    // recorded), we leave thumbnail_storage_path as null and fall back
    // to the gradient + Phase 6.4f.10 detail-page bake-on-first-view.
    String? thumbStoragePath;
    final localThumbPath = record.thumbnailPath;
    if (localThumbPath != null && localThumbPath.isNotEmpty) {
      final thumbFile = File(localThumbPath);
      if (await thumbFile.exists()) {
        final candidatePath = '$uid/${record.id}.jpg';
        try {
          await _client.storage.from('thumbnails').upload(
                candidatePath,
                thumbFile,
                fileOptions: const FileOptions(
                  contentType: 'image/jpeg',
                  upsert: true,
                  cacheControl: '604800',
                ),
              );
          thumbStoragePath = candidatePath;
          debugPrint(
              '[PublishService] uploaded thumb $candidatePath '
              '(${(await thumbFile.length() / 1024).toStringAsFixed(1)} KB) '
              'for record ${record.id}');
        } on StorageException catch (e) {
          // Soft-fail: thumbnail upload is best-effort. If it fails
          // (network blip, RLS misconfig), the GLB still publishes
          // and Phase 6.4f.10's detail-page bake covers later.
          debugPrint(
              '[PublishService] thumb upload soft-failed for '
              '${record.id}: ${e.message}');
        }
      } else {
        debugPrint(
            '[PublishService] thumb path $localThumbPath '
            'set on record but file missing; skipping thumb upload');
      }
    }

    final Map<String, dynamic> insertRow;
    try {
      insertRow = await _client
          .from('works')
          .insert(<String, dynamic>{
            'user_id': uid,
            'title': trimmedTitle,
            'description': trimmedDesc,
            'format': 'glb',
            'model_storage_path': storagePath,
            // Phase 6.4f.11 — null when the thumb upload above didn't
            // produce a path; the work still publishes correctly.
            'thumbnail_storage_path': ?thumbStoragePath,
            'visibility': visibility,
            'published_at': DateTime.now().toUtc().toIso8601String(),
          })
          .select('id')
          .single();
    } on PostgrestException catch (e) {
      throw PublishException('insert_failed', e.message);
    }
    final workId = insertRow['id'] as String;

    // Stamp the ScanRecord so the detail page can switch to "已发布".
    final fresh = _store.byId(record.id) ?? record;
    await _store.addOrUpdate(fresh.copyWith(
      publishedWorkId: workId,
      name: trimmedTitle,
      caption: trimmedDesc,
    ));
    return workId;
  }

  /// Update an already-published work. Returns the workId unchanged.
  Future<String> editPublished({
    required String workId,
    required String title,
    String? description,
    String visibility = 'public',
    String? recordId,
  }) async {
    final trimmedTitle = title.trim();
    if (trimmedTitle.isEmpty || trimmedTitle.length > 100) {
      throw const PublishException(
        'invalid_title',
        'Title must be 1–100 characters.',
      );
    }
    final trimmedDesc = description?.trim();
    if (trimmedDesc != null && trimmedDesc.length > 5000) {
      throw const PublishException(
        'invalid_description',
        'Description must be ≤ 5000 characters.',
      );
    }
    try {
      await _client.from('works').update(<String, dynamic>{
        'title': trimmedTitle,
        'description': trimmedDesc,
        'visibility': visibility,
      }).eq('id', workId);
    } on PostgrestException catch (e) {
      throw PublishException('update_failed', e.message);
    }
    if (recordId != null) {
      final fresh = _store.byId(recordId);
      if (fresh != null) {
        await _store.addOrUpdate(fresh.copyWith(
          name: trimmedTitle,
          caption: trimmedDesc,
        ));
      }
    }
    return workId;
  }

  /// Pull a published work back to private. Mostly for "I posted by
  /// accident" — we don't expose this in the UI yet but the API is
  /// here for the day we add it.
  Future<void> unpublish(String workId, {String? recordId}) async {
    try {
      await _client.from('works').update(<String, dynamic>{
        'visibility': 'private',
        'published_at': null,
      }).eq('id', workId);
    } on PostgrestException catch (e) {
      throw PublishException('update_failed', e.message);
    }
    if (recordId != null) {
      final fresh = _store.byId(recordId);
      if (fresh != null) {
        await _store.addOrUpdate(fresh.copyWith(clearPublishedWorkId: true));
      }
    }
  }
}
