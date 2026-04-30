// Supabase queries that power the community feed.
//
// Three responsibilities:
//   • fetchPublicFeed — a paginated read of public works joined with
//     authoring profiles, plus a bulk work_likes lookup so each card
//     knows whether the current user has liked it.
//   • toggleLike       — flips the current user's like on a work.
//                        Schema-side trigger maintains works.likes_count.
//   • thumbnailUrlFor / modelUrlFor — turn storage paths into
//     publicly-resolvable URLs (or signed URLs for private buckets).
//
// Cross-platform: pure Dart on top of supabase_flutter, runs identically
// on iOS / Android / HarmonyOS / Web.

import 'package:supabase_flutter/supabase_flutter.dart';

import 'feed_models.dart';

/// How the community feed is ordered.
///   • recent  → published_at desc (the "发现 / Discover" tab).
///   • hot     → likes_count desc, then published_at desc as tiebreaker
///               (the "热门 / Hot" tab).
enum FeedSort { recent, hot }

class CommunityService {
  final SupabaseClient _client;
  CommunityService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  /// Public works joined with profile (display_name + avatar_url) and the
  /// current user's like state.
  ///
  /// Empty database returns []. Network / auth errors throw.
  Future<List<FeedWork>> fetchPublicFeed({
    int limit = 20,
    int offset = 0,
    FeedSort sortBy = FeedSort.recent,
    String? query,
  }) async {
    // 1) Public works. Visibility filter belongs in code even though RLS
    // would already enforce it — public clients should never get a row
    // they shouldn't, but explicit is clearer.
    var filter = _client
        .from('works')
        .select(
          'id, user_id, title, description, format, '
          'model_storage_path, thumbnail_storage_path, '
          'likes_count, views_count, published_at',
        )
        .eq('visibility', 'public')
        .not('published_at', 'is', null);
    final trimmedQuery = query?.trim();
    if (trimmedQuery != null && trimmedQuery.isNotEmpty) {
      // ilike is parameterized — pattern is sent as-is and matches as a
      // case-insensitive substring. Wildcards in the user's input
      // collapse to literals on the wire (PostgREST escapes them).
      filter = filter.ilike('title', '%$trimmedQuery%');
    }
    final transformed = switch (sortBy) {
      FeedSort.recent => filter.order('published_at', ascending: false),
      FeedSort.hot => filter
          .order('likes_count', ascending: false)
          .order('published_at', ascending: false),
    };
    final worksRes = await transformed.range(offset, offset + limit - 1);
    final works = (worksRes as List).cast<Map<String, dynamic>>();
    if (works.isEmpty) return const [];

    // 2) Profiles for the unique authors.
    final userIds = works.map((w) => w['user_id'] as String).toSet().toList();
    final profilesRes = await _client
        .from('profiles')
        .select('id, display_name, avatar_url')
        .inFilter('id', userIds);
    final profilesById = {
      for (final p in (profilesRes as List).cast<Map<String, dynamic>>())
        p['id'] as String: p,
    };

    // 3) Current user's likes for these works (one round trip, not N).
    final myId = _client.auth.currentUser?.id;
    final myLikes = <String>{};
    if (myId != null) {
      final workIds = works.map((w) => w['id'] as String).toList();
      final likesRes = await _client
          .from('work_likes')
          .select('work_id')
          .eq('user_id', myId)
          .inFilter('work_id', workIds);
      for (final r in (likesRes as List).cast<Map<String, dynamic>>()) {
        myLikes.add(r['work_id'] as String);
      }
    }

    return works.map((w) {
      final profile = profilesById[w['user_id'] as String] ?? const {};
      final publishedAtStr = w['published_at'] as String?;
      return FeedWork(
        id: w['id'] as String,
        userId: w['user_id'] as String,
        title: (w['title'] as String?) ?? '',
        description: w['description'] as String?,
        format: (w['format'] as String?) ?? 'glb',
        modelStoragePath: w['model_storage_path'] as String?,
        thumbnailStoragePath: w['thumbnail_storage_path'] as String?,
        likesCount: (w['likes_count'] as int?) ?? 0,
        viewsCount: (w['views_count'] as int?) ?? 0,
        publishedAt:
            publishedAtStr == null ? null : DateTime.parse(publishedAtStr),
        authorDisplayName:
            (profile['display_name'] as String?) ?? 'unknown',
        authorAvatarUrl: profile['avatar_url'] as String?,
        likedByMe: myLikes.contains(w['id'] as String),
      );
    }).toList();
  }

  /// Toggle the current user's like on a work. Returns the new
  /// like state (true = now liked, false = now unliked). Throws if the
  /// user is signed out — call sites should already gate on that.
  Future<bool> toggleLike({
    required String workId,
    required bool currentlyLiked,
  }) async {
    final myId = _client.auth.currentUser?.id;
    if (myId == null) {
      throw StateError('Cannot toggle like — no signed-in user.');
    }
    if (currentlyLiked) {
      await _client
          .from('work_likes')
          .delete()
          .eq('user_id', myId)
          .eq('work_id', workId);
      return false;
    } else {
      // Upsert tolerates a race where two taps fire concurrently — the
      // (user_id, work_id) PK keeps the row unique either way.
      await _client.from('work_likes').upsert(
        {'user_id': myId, 'work_id': workId},
        onConflict: 'user_id,work_id',
        ignoreDuplicates: true,
      );
      return true;
    }
  }

  /// Record a view on the given work. The schema's unique index dedups
  /// (work_id, viewer_id, hour-bucket), so calling this on every detail-
  /// page open is safe — the same viewer reopening within the hour
  /// silently 23505s and the counter is not double-incremented.
  ///
  /// Returns the new total views_count if the bump was effective, or
  /// the prior value if this hour already counted. Errors (network,
  /// auth) are swallowed so the viewer never breaks; views are a
  /// nice-to-have, not load-bearing.
  Future<int?> recordView(String workId) async {
    try {
      final myId = _client.auth.currentUser?.id;
      // upsert with ignoreDuplicates so the dedup index does its job
      // without raising 23505.
      await _client.from('work_views').upsert(
        <String, dynamic>{
          'work_id': workId,
          'viewer_id': ?myId,
        },
        onConflict: 'work_id, coalesce(viewer_id::text, \'anon\'), view_bucket',
        ignoreDuplicates: true,
      );
      // Re-read views_count so the UI can show the bumped number
      // immediately. Cheap query, public read.
      final row = await _client
          .from('works')
          .select('views_count')
          .eq('id', workId)
          .maybeSingle();
      return (row?['views_count'] as int?);
    } catch (_) {
      return null;
    }
  }

  /// Public URL for a thumbnails/-bucket asset path. Thumbnails are a
  /// public bucket (RLS allows anon SELECT), so getPublicUrl returns a
  /// stable URL with no token.
  String thumbnailUrlFor(String path) {
    return _client.storage.from('thumbnails').getPublicUrl(path);
  }

  /// Returns a URL the client can use to fetch the model file.
  ///
  /// works/ is conditionally readable (public when works.visibility='public',
  /// else owner-only). For public works getPublicUrl is enough; for
  /// private works we'd need createSignedUrl. Feed only shows public
  /// works so the public path is correct here.
  String modelUrlFor(String path) {
    return _client.storage.from('works').getPublicUrl(path);
  }
}
