// GlbAssetCache — process-lifetime cache of loaded ThermionAssets,
// keyed by .glb URL.
//
// Pairs with AnchorViewer (lib/community/anchor_viewer.dart): the
// anchor viewer is the ONE viewer that loads every asset and keeps
// it alive. Per-card viewers just `addToScene(cachedAsset)` — they
// never load, so when they dispose nothing breaks the asset.
//
// Lookup flow:
//   1. Same URL already cached → return immediately (~1µs).
//   2. Same URL load in flight → coalesce onto the in-flight Future
//      (so two PostCards for the same model on the same frame don't
//      double-load).
//   3. Cold load: GlbCache (bytes, mem+disk) → anchor.loadGltfFromBuffer
//      with addToScene:false (we don't want it rendering in the
//      invisible anchor). Cache the asset.
//
// Memory: bounded LRU. Past v1 we ran with no eviction at all, which
// was fine for ≤10 unique models. As soon as community feeds grow past
// that, we drop the LRU entry from THIS map but don't aggressively
// remove the asset from the underlying Filament engine — other viewers
// may still hold it on screen, and Filament cleans up when its engine
// tears down. The cap protects the in-process map from unbounded
// growth; it isn't a hard GPU memory cap.

import 'dart:async';
import 'dart:collection';

import 'package:thermion_flutter/thermion_flutter.dart';

import 'anchor_viewer.dart';
import 'glb_cache.dart';

class GlbAssetCache {
  GlbAssetCache._();
  static final GlbAssetCache instance = GlbAssetCache._();

  /// Soft cap on the cache map size. Above this we drop the LRU
  /// entry from the map (see file header for the reasoning).
  static const int _maxAssets = 12;

  // LinkedHashMap so we get insertion-order iteration → cheapest LRU.
  // get-or-load promotes the touched key by remove+reinsert.
  final LinkedHashMap<String, ThermionAsset> _assets =
      LinkedHashMap<String, ThermionAsset>();
  final Map<String, Future<ThermionAsset>> _inflight =
      <String, Future<ThermionAsset>>{};

  Future<ThermionAsset> getOrLoad(String url) {
    final cached = _assets[url];
    if (cached != null) {
      // LRU bump: most-recently-used moves to the end.
      _assets.remove(url);
      _assets[url] = cached;
      return Future.value(cached);
    }
    final pending = _inflight[url];
    if (pending != null) return pending;
    final future = _load(url);
    _inflight[url] = future;
    // Same .ignore() pattern as GlbCache.fetch — without it a load
    // failure leaks an unhandled async error into runZonedGuarded
    // which then triggers main.dart's disaster fallback runApp().
    future.whenComplete(() => _inflight.remove(url)).ignore();
    return future;
  }

  Future<ThermionAsset> _load(String url) async {
    final bytes = await GlbCache.instance.fetch(url);
    // The anchor is what owns the asset for the rest of the session.
    final anchor = await AnchorViewer.future;
    // addToScene:false → asset doesn't show in the anchor's scene
    // (which is sized 1×1 invisible anyway, but cleaner this way).
    // Per-card viewers will addToScene on their own scenes.
    final asset = await anchor.loadGltfFromBuffer(bytes, addToScene: false);
    _assets[url] = asset;
    if (_assets.length > _maxAssets) {
      // Evict the LRU (oldest insertion) entry. Don't remove from any
      // viewer's scene here — other PostCards may still be displaying
      // the asset; Filament cleans up GPU resources when its engine
      // tears down.
      final oldestKey = _assets.keys.first;
      _assets.remove(oldestKey);
    }
    return asset;
  }

  /// Drop every cached asset reference. Called by the anchor host's
  /// dispose so that after the underlying Filament viewer is torn down
  /// (typically on sign-out, when AuthGate swaps HomeScreen out), no
  /// LiveModelView ever gets a ThermionAsset whose Filament-side
  /// pointers are stale. Without this, the next sign-in's per-card
  /// `addToScene(cachedAsset)` calls into freed Filament objects and
  /// the RenderThread panics with "Object doesn't exist (double free?)"
  /// followed by EXC_BAD_ACCESS in dart::InvokeDartCode.
  void clear() {
    _assets.clear();
    _inflight.clear();
  }
}
