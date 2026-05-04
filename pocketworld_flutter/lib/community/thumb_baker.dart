// Phase 6.4f.10 — first-viewer thumbnail baker.
//
// Why this exists:
//   PostCard's feed layer uses `thumbnail_storage_path` as the static
//   poster image (Phase 6.4f.9). Works without a thumb fall through to
//   `_GradientBackdrop`, which the user reported on 2026-05-04 as
//   "点云项目一直是灰色的". Our capture pipeline auto-generates a thumb
//   from the .mov when uploading a GLB; SPZ uploads (the rare 2B path)
//   don't go through that pipeline so they arrive thumb-less.
//
//   Rather than asking 2B uploaders to mint thumbs themselves, we bake
//   on the first qualified viewer's detail-page open. Whoever is first
//   to view the SPZ in detail pays no extra cost (they were rendering
//   live splat anyway); after the bake completes, every subsequent feed
//   viewer sees the JPG instead of gray.
//
// "First qualified viewer" = today, only the work owner (RLS on `works`
// only allows owner UPDATE on `thumbnail_storage_path`). Future patch
// can add a public RPC `bake_thumb_if_missing(work_id, bytes)` that
// validates server-side and lifts the owner-only constraint.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../ui/community/viewer_impl.dart';
import 'community_service.dart';
import 'feed_models.dart';

class ThumbBaker {
  final CommunityService _service;
  final SupabaseClient _client;

  // Per-process dedup. If two PostCard / detail-page mounts race the
  // bake (e.g. user taps detail, scrolls back, taps detail again before
  // the first round-trip finishes), the second call short-circuits.
  final Set<String> _inFlight = <String>{};
  final Set<String> _completed = <String>{};

  ThumbBaker({
    required CommunityService service,
    SupabaseClient? client,
  })  : _service = service,
        _client = client ?? Supabase.instance.client;

  /// Snapshot the viewer's current frame and upload it as the work's
  /// canonical thumbnail, but only if:
  ///   • the work has no `thumbnailStoragePath` yet, AND
  ///   • the current user is the work's owner (RLS gate), AND
  ///   • we haven't already baked / are baking this work in-process.
  ///
  /// Returns the new storage path on success, null on any "skip"
  /// condition or upstream failure. Always safe to call — failures are
  /// swallowed so the detail page UX is never blocked.
  Future<String?> maybeBake({
    required FeedWork work,
    required AetherCppViewerImpl viewer,
  }) async {
    // Fast path: already has one.
    if (work.thumbnailStoragePath != null &&
        work.thumbnailStoragePath!.isNotEmpty) {
      return null;
    }

    // Per-process dedup.
    if (_completed.contains(work.id) || _inFlight.contains(work.id)) {
      return null;
    }

    // Auth gate. RLS will reject UPDATE from non-owner anyway, but the
    // pre-check avoids a wasted upload to storage and a logged 401.
    final myId = _client.auth.currentUser?.id;
    if (myId == null || myId != work.userId) {
      debugPrint(
          '[ThumbBaker] skipping ${work.id} — caller=$myId, owner=${work.userId}');
      return null;
    }

    _inFlight.add(work.id);
    try {
      // Tiny delay so the viewer's first push frame fully settles
      // through Dawn submit + present before we lock the IOSurface.
      // Without this the snapshot occasionally lands mid-frame and
      // shows a partially-rendered scene.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final bytes = await viewer.captureThumb(quality: 0.85);
      if (bytes == null || bytes.isEmpty) {
        debugPrint('[ThumbBaker] ${work.id} — captureThumb returned empty');
        return null;
      }

      final storagePath = await _service.uploadAndSetThumbnail(
        workId: work.id,
        jpegBytes: bytes,
      );
      if (storagePath != null) {
        _completed.add(work.id);
      }
      return storagePath;
    } catch (e, s) {
      debugPrint('[ThumbBaker] ${work.id} bake failed: $e\n$s');
      return null;
    } finally {
      _inFlight.remove(work.id);
    }
  }

  /// Reset per-process state. Useful for tests; not normally called.
  @visibleForTesting
  void reset() {
    _inFlight.clear();
    _completed.clear();
  }
}
