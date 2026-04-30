// MyWorksSyncService — pulls the signed-in user's published works from
// Supabase and materializes any missing ones as local ScanRecords so the
// "我的作品" grid on MePage reflects what's actually in their account.
//
// Why this exists: ScanRecordStore is a local JSON file fed by the
// capture → upload → publish flow. If the user published from another
// device, reinstalled the app, or (today) had two seed works injected
// into Supabase from a tool script, the local store doesn't know about
// them and the Me tab shows nothing. Pull-to-refresh on MePage routes
// here.
//
// Idempotent: each work.id is pinned to ScanRecord.publishedWorkId, so
// running the sync twice is a no-op for already-materialized records.
// First-time materialization downloads the GLB into the same local path
// JobStatusWatcher uses (`app_documents/scans/<id>.glb`) so LiveModelView
// + GlbCache treat it identically to a freshly captured record.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ui/scan_record.dart';
import 'scan_record_store.dart';

class MyWorksSyncService {
  MyWorksSyncService({
    SupabaseClient? client,
    ScanRecordStore? store,
    Dio? dio,
  })  : _client = client ?? Supabase.instance.client,
        _store = store ?? ScanRecordStore.instance,
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 5),
            ));

  static final MyWorksSyncService instance = MyWorksSyncService();

  final SupabaseClient _client;
  final ScanRecordStore _store;
  final Dio _dio;

  /// Pulls the signed-in user's works rows and downloads any whose work
  /// id isn't already pinned to a local ScanRecord. Returns the count of
  /// records newly added. Throws on auth / network failures so callers
  /// can surface them; partial successes (some works downloaded, others
  /// failed) still complete and report the count.
  Future<int> refreshFromCloud() async {
    final uid = _client.auth.currentSession?.user.id;
    if (uid == null) {
      throw StateError('Not signed in.');
    }
    await _store.ensureLoaded();
    // Index by publishedWorkId so we can both check "do we already know
    // about this work" AND inspect the prior record's artifactPath when
    // we need to verify the local file is still present.
    final priorByWorkId = <String, ScanRecord>{
      for (final r in _store.records)
        if (r.publishedWorkId != null) r.publishedWorkId!: r,
    };

    final res = await _client
        .from('works')
        .select(
          'id, title, description, model_storage_path, '
          'published_at, created_at',
        )
        .eq('user_id', uid)
        .order('published_at', ascending: false, nullsFirst: false);
    final rows = (res as List).cast<Map<String, dynamic>>();

    int added = 0;
    for (final w in rows) {
      final workId = w['id'] as String?;
      final modelPath = w['model_storage_path'] as String?;
      if (workId == null || modelPath == null) continue;
      // Skip only if the prior record actually has its GLB on disk.
      // iOS occasionally migrates the app's container UUID across
      // reinstalls; the persisted ScanRecord's artifactPath is an
      // absolute file:// URL pointing at the OLD container, so the
      // record looks "known" while the underlying file is gone. Without
      // this check, LiveModelView would later throw "Local .glb missing"
      // and that error has been observed propagating into runZonedGuarded
      // and triggering the disaster-recovery fallback runApp() that
      // strands the user on AuthRootView. Re-download instead.
      final prior = priorByWorkId[workId];
      if (prior != null) {
        final priorPath = prior.artifactPath;
        if (priorPath != null && priorPath.startsWith('file://')) {
          try {
            if (await File(Uri.parse(priorPath).toFilePath()).exists()) {
              continue;
            }
          } catch (_) {/* fall through and re-download */}
        }
      }
      try {
        final dest = await _store.glbFileFor(workId);
        final url = _client.storage.from('works').getPublicUrl(modelPath);
        await _downloadTo(url, dest);
        final whenStr =
            (w['published_at'] ?? w['created_at']) as String?;
        final createdAt = whenStr != null
            ? DateTime.parse(whenStr).toLocal()
            : DateTime.now();
        await _store.addOrUpdate(ScanRecord(
          id: workId,
          name: (w['title'] as String?)?.trim().isNotEmpty == true
              ? (w['title'] as String).trim()
              : '—',
          createdAt: createdAt,
          caption: w['description'] as String?,
          artifactPath: 'file://${dest.path}',
          publishedWorkId: workId,
        ));
        added++;
      } catch (e, s) {
        // Per-row failures shouldn't abort the whole refresh — the user
        // can pull again, and the missing rows stay missing rather than
        // poisoning the store with a half-written record.
        debugPrint('[MyWorksSync] failed to materialize $workId: $e\n$s');
      }
    }
    return added;
  }

  Future<void> _downloadTo(String url, File dest) async {
    if (!await dest.parent.exists()) {
      await dest.parent.create(recursive: true);
    }
    final tmp = File('${dest.path}.partial');
    if (await tmp.exists()) await tmp.delete();
    final resp = await _dio.download(url, tmp.path);
    if (resp.statusCode != 200) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      throw StateError('Download failed: HTTP ${resp.statusCode}');
    }
    if (await dest.exists()) await dest.delete();
    await tmp.rename(dest.path);
  }
}
