// ViewerImpl — abstraction over thermion (current) vs aether_cpp scene
// renderer (target).
//
// LiveModelView talks to a ViewerImpl, not directly to ViewerWidget,
// so the migration from thermion → aether_cpp is a one-line swap of
// the concrete class behind a feature flag. See
// aether_cpp/PHASE_FLUTTER_VIEWER_PLAN.md for the staged plan.
//
// G3 (this file): AetherCppViewerImpl is wired to lib/aether_view/
// scene_bridge.dart's MethodChannel API (the same plugin home-screen
// uses since Phase 6.4e). ThermionViewerImpl is still a stub — its
// fill-in lands in G4 once we move the existing inline thermion code
// out of LiveModelView.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart' as v64;

import '../../aether_view/format_detect.dart';
import '../../aether_view/scene_bridge.dart';
import '../../community/glb_cache.dart';

/// Thrown when the viewer is asked to load a format the current
/// platform / native build doesn't support yet. Lets the caller show
/// a "format not supported" placeholder instead of a generic crash
/// dialog. G5 keeps PLY / SPZ / SPLAT routed here pending the native
/// Phase 6.4f splat pipeline integration.
class UnsupportedViewerFormatError implements Exception {
  final ViewerFormat format;
  final String url;
  final String reason;

  const UnsupportedViewerFormatError({
    required this.format,
    required this.url,
    required this.reason,
  });

  @override
  String toString() => 'UnsupportedViewerFormatError($format, $url): $reason';
}

/// Loaded-model bounds the caller uses to drive its own camera fit
/// math (the model-viewer-derived `r / sin(fov/2)` formula in
/// `live_model_view.dart` already operates on this shape).
class ModelBounds {
  /// Local-space half-extents (i.e. (max - min) / 2 on each axis).
  final v64.Vector3 halfExtents;

  /// Local-space center (i.e. (max + min) / 2). Often non-zero for
  /// re-exported scan GLBs.
  final v64.Vector3 center;

  const ModelBounds({required this.halfExtents, required this.center});

  /// AABB-diagonal sphere radius — what the fit formula consumes.
  double get sphereRadius => halfExtents.length;
}

/// One viewer instance per LiveModelView. Lifecycle is initState →
/// create → load → many render(...) calls → dispose.
/// Quality hint controlling splat-scene memory use vs visual fidelity.
///
/// Phase 6.4f hotfix: feed thumbnails were loading 786 k splats × full
/// SH degree 3 (~141 MB GPU memory per scene), causing memory warnings
/// + reload churn within a few cards. The capped path drops higher-order
/// SH (DC only) and subsamples to 200 k splats, fitting in ~3 MB —
/// imperceptible at 256-768 px thumbnail size. Detail page keeps `full`
/// for best quality during user interaction.
enum ViewerQuality {
  /// Detail-page / interactive mode — no caps, native loader gets full
  /// SH + every splat in the file.
  full,

  /// Feed card — `max_sh_degree=0, max_splats=200000`. Native side
  /// honors this only for splat formats (PLY/SPZ); GLB path ignores
  /// the hint (mesh files don't have splat caps).
  feedThumbnail,
}

/// Phase 6.4f.5 — per-asset overrides for the splat viewer tunables.
///
/// `splatScaleMultiplier` and `max3dScale` are Niantic-tuned defaults
/// in [AetherCppViewerImpl.load]; some captures (Polycam scans,
/// user-trained scenes) authored at different splat density / halo
/// scale want different values. Callers can pass these when they have
/// per-work metadata — e.g., a future `FeedWork.viewerOverrides` field
/// populated from the upload pipeline. Until that schema lands, the
/// default `null` here keeps the per-quality presets in effect.
class SplatViewerOverrides {
  /// Multiplier applied to every splat's authored 3D scale before
  /// projection. Niantic SPZ defaults to 4.0 (compensates for
  /// AR-density splats at thumbnail distance). Polycam might want
  /// 1.0–2.0; user-uploaded high-res scans may want 1.0.
  final double? splatScaleMultiplier;

  /// Max authored 3D scale (max of xyz, world units) above which a
  /// splat is culled. Default 0.3 drops the soft halo around Niantic
  /// captures. Cleaner captures may want 1.0+ (don't cull anything)
  /// or this could be 0 to disable the cull entirely.
  final double? max3dScale;

  const SplatViewerOverrides({
    this.splatScaleMultiplier,
    this.max3dScale,
  });

  /// All-default overrides. Equivalent to passing `null`.
  static const SplatViewerOverrides none = SplatViewerOverrides();
}

abstract class ViewerImpl {
  /// Allocate the underlying renderer. Returns the Flutter texture id
  /// the caller should hand to a `Texture(textureId: ...)` widget,
  /// OR null if this impl doesn't use a Flutter Texture (in which
  /// case the caller mounts the impl's own widget — thermion's
  /// `ViewerWidget` is its own thing).
  Future<int?> create({
    required double width,
    required double height,
  });

  /// Fetch + parse the model at [url]. Format detection happens
  /// inside (see `format_detect.dart`); GLB → mesh path, PLY/SPZ/
  /// SPLAT → splat engine. Returns the model's local-space bounds
  /// for camera fit. May return `null` if the impl doesn't surface
  /// bounds (legacy thermion path keeps doing its own bounding-box
  /// query inside).
  ///
  /// [quality] controls splat-scene memory use — see [ViewerQuality].
  /// [overrides] lets the caller dial the splat-scene tunables on a
  /// per-asset basis (creator-side metadata or per-URL hardcoded
  /// overrides). Default uses the per-quality presets.
  Future<ModelBounds?> load(String url, {
    ViewerQuality quality,
    SplatViewerOverrides overrides,
  });

  /// One frame. View + model matrices are 4×4 column-major. Note
  /// that aether_cpp's API takes view + MODEL — projection is
  /// derived from the texture's width/height aspect ratio inside
  /// scene_iosurface_renderer.cpp (Filament-style). Callers that
  /// already compute their own projection can ignore the projection
  /// matrix.
  Future<void> render({
    required v64.Matrix4 viewMatrix,
    required v64.Matrix4 modelMatrix,
  });

  Future<void> dispose();
}

/// Thermion-backed implementation. Stub until G4 moves the existing
/// inline `_LiveModelViewState._onViewerReady` / `_loadAsset` /
/// camera-tick code from live_model_view.dart into here. Until then,
/// LiveModelView keeps driving thermion directly — this class is just
/// a placeholder so the type system is ready.
class ThermionViewerImpl implements ViewerImpl {
  @override
  Future<int?> create({required double width, required double height}) async {
    throw UnimplementedError(
      'G4: move the existing ViewerWidget setup from '
      '_LiveModelViewState._onViewerReady into here. Until then '
      'LiveModelView ignores ViewerImpl and keeps driving thermion '
      'inline.',
    );
  }

  @override
  Future<ModelBounds?> load(String url,
      {ViewerQuality quality = ViewerQuality.full,
      SplatViewerOverrides overrides = SplatViewerOverrides.none}) async {
    throw UnimplementedError(
        'G4: move existing GlbAssetCache.getOrLoad + addToScene here.');
  }

  @override
  Future<void> render({
    required v64.Matrix4 viewMatrix,
    required v64.Matrix4 modelMatrix,
  }) async {
    throw UnimplementedError('G4: move existing camera.lookAt here.');
  }

  @override
  Future<void> dispose() async {
    throw UnimplementedError(
        'G4: move existing dispose ordering (flag → ticker → null fields) here.');
  }
}

/// aether_cpp-backed implementation. G3 shipped — uses SceneBridge
/// (the existing `aether_texture` MethodChannel that home-screen
/// already runs through). Per-PostCard texture instance; load_glb
/// path is the canonical scene_iosurface_renderer.cpp 2-pass mesh +
/// splat overlay rendering.
///
/// Limitations as of G3:
///   • iOS only (Android stub lands in G6, Web in G8).
///   • GLB only (PLY / SPZ / SPLAT in G5 once native side adds the
///     load_ply / load_spz method-channel methods).
///   • The native displayLink currently animates one texture at a
///     time (single-renderer home-screen pattern). Multi-card feed
///     animation is a G4 follow-up — for now, render() invocations
///     from the Dart Ticker drive each card explicitly via
///     setMatrices, which the native side renders synchronously on
///     receipt.
class AetherCppViewerImpl implements ViewerImpl {
  int? _textureId;
  bool _loaded = false;

  @override
  Future<int?> create({
    required double width,
    required double height,
  }) async {
    if (_textureId != null) return _textureId;
    if (!kAetherSceneBridgeAvailable) {
      // G6 / G8: Android + Web don't have the native plugin yet.
      // Raise the same typed exception the format-dispatch path uses
      // so PostCard's catch-and-cover logic handles both uniformly.
      // Caller should ideally check kAetherSceneBridgeAvailable before
      // even instantiating us, but this is the belt-and-suspenders
      // path.
      throw const UnsupportedViewerFormatError(
        format: ViewerFormat.unknown,
        url: '',
        reason: 'aether_texture MethodChannel not registered on this '
            'platform. iOS + macOS only until G6 (Android via '
            'SurfaceTexture + Dawn-Vulkan) and G8 (Web via Dawn '
            'emscripten) land.',
      );
    }
    final id = await SceneBridge.instance.createTexture(
      width: width.round().clamp(1, 4096),
      height: height.round().clamp(1, 4096),
    );
    _textureId = id;
    return id;
  }

  @override
  Future<ModelBounds?> load(String url,
      {ViewerQuality quality = ViewerQuality.full,
      SplatViewerOverrides overrides = SplatViewerOverrides.none}) async {
    final id = _textureId;
    if (id == null) {
      throw StateError('AetherCppViewerImpl.load called before create');
    }
    // Phase 6.4f hotfix: feed thumbnails STRIDE-decimate to 200 k splats
    // so the per-frame compute cost (project_forward + project_visible
    // + 5-kernel sort) stays under the 16 ms budget for 60 fps. Without
    // this, 786 k splats × full sort runs ~40 ms/frame and the focused
    // card caps the displayLink at 25 Hz, which the user feels as
    // home-page scroll lag.
    //
    // The C++ load_spz_into_renderer / load_ply_into_renderer take this
    // as a STRIDE cap (every k-th splat), NOT octree_subsample_merged.
    // Octree merge inflates each representative's scale, which combined
    // with the 4× viewer-side splat_scale_multiplier produces enormous
    // blob splats (the "stippled net" pattern from the previous
    // attempt). Stride keeps each splat's authored scale, so 200 k
    // splats × 4× plumping reads as a continuous (slightly sparser)
    // surface — same density as 786 k × 1× would be without our scale
    // multiplier.
    //
    // Detail page passes max_splats=0 (no cap) for full quality; the
    // user is on the detail page intentionally and can wait the extra
    // few ms per frame for the full splat density.
    final int capMaxSplats =
        quality == ViewerQuality.feedThumbnail ? 200000 : 0;
    final int capMaxShDegree =
        quality == ViewerQuality.feedThumbnail ? 0 : 3;
    // Phase 6.4f hotfix — splat-scale multiplier. Niantic SPZ files
    // are authored at AR-viewing density (splat scales chosen for
    // viewing the model from ~1 m away in headset). At PocketWorld
    // fit distances (~3× the model bounding sphere) every splat
    // projects sub-pixel, leaving a halftone gap pattern.
    //
    // Both feed AND detail page apply the multiplier — detail page's
    // "high quality" comes from SH degree 3 (view-dependent color),
    // not from preserving the file's tiny splat scale. Without the
    // multiplier the detail page still renders as halftone noise.
    // 4× is the empirical sweet spot: 1× shows the gap pattern;
    // 2× is still grid-visible; 4× reads as a continuous surface;
    // 8× over-blurs feature detail. Re-evaluate per-asset if a
    // future SPZ has notably different authoring density.
    // Phase 6.4f.5 — per-asset overrides win over per-quality presets.
    // Niantic-tuned defaults (4.0 / 0.3) are the fallback; callers
    // with per-work metadata can pass tighter or looser values.
    final double splatScaleMultiplier = overrides.splatScaleMultiplier ?? 4.0;
    final double max3dScale = overrides.max3dScale ?? 0.3;
    // G5: dispatch by format. URL extension is the cheap pre-fetch
    // hint; once aether_cpp ships an HTTP-then-detect path (or once
    // the splat engine actually exists, we'll sniff the bytes on the
    // native side), this can upgrade to FormatDetector.detect on the
    // first KB. For now extension-based hint matches what the feed's
    // signed URLs already carry.
    final format = FormatDetector.hintFromUrl(url);
    // Native side opens with fopen() — can't take https:// URLs. For
    // remote URLs, route through GlbCache.fetchPath which downloads
    // (or hits the disk cache) and returns the on-disk path. file://
    // URLs already point at a local file so just strip the scheme.
    // (Naming is "GlbCache" but the cache is format-agnostic — bytes
    // are bytes; the disk-persisted path works for PLY/SPZ too.)
    final String path;
    if (url.startsWith('http://') || url.startsWith('https://')) {
      path = await GlbCache.instance.fetchPath(url);
    } else if (url.startsWith('file://')) {
      path = Uri.parse(url).toFilePath();
    } else {
      path = url;
    }

    final Map<String, double>? bounds;
    switch (format) {
      case ViewerFormat.glb:
        bounds = await SceneBridge.instance.loadGlb(
          textureId: id,
          path: path,
        );
        break;
      case ViewerFormat.plyGsplat:
        // Phase 6.4f stub: SceneBridge.loadPly calls the native C ABI
        // which currently returns false (logged as `PLY_LOAD_FAILED`
        // in the platform exception). This will start working
        // transparently once the Brush 8-kernel pipeline lands —
        // no Dart-side change required.
        bounds = await SceneBridge.instance.loadPly(
          textureId: id,
          path: path,
          maxSplats: capMaxSplats,
          maxShDegree: capMaxShDegree,
          splatScaleMultiplier: splatScaleMultiplier,
          max3dScale: max3dScale,
        );
        break;
      case ViewerFormat.spz:
        bounds = await SceneBridge.instance.loadSpz(
          textureId: id,
          path: path,
          maxSplats: capMaxSplats,
          maxShDegree: capMaxShDegree,
          splatScaleMultiplier: splatScaleMultiplier,
          max3dScale: max3dScale,
        );
        break;
      case ViewerFormat.splat:
        // antimatter15 .splat fixed-stride binary — no native
        // loader and probably won't get one (the format is dwindling
        // in favour of SPZ). Surface as unsupported.
        throw UnsupportedViewerFormatError(
          format: format,
          url: url,
          reason: '.splat fixed-stride format is not on the roadmap; '
              'use .ply or .spz instead.',
        );
      case ViewerFormat.plyMesh:
        throw UnsupportedViewerFormatError(
          format: format,
          url: url,
          reason: 'Plain triangulated PLY → mesh conversion is not '
              'planned. The aether_cpp scene renderer takes GLB only; '
              'export to GLB upstream.',
        );
      case ViewerFormat.unknown:
        throw UnsupportedViewerFormatError(
          format: format,
          url: url,
          reason: 'Could not classify the URL by extension. Supported '
              '.glb / .gltf (GLB), .ply (gsplat), .spz.',
        );
    }
    _loaded = true;
    // G4: native side now returns bounds_min / bounds_max from the C
    // ABI's aether_scene_renderer_get_bounds. Empty map = no mesh /
    // older runner; the caller (LiveModelView / AetherCppCardDemo)
    // falls back to its widget.cameraDistance default.
    if (bounds == null || bounds.isEmpty) return null;
    final minX = bounds['minX'];
    final minY = bounds['minY'];
    final minZ = bounds['minZ'];
    final maxX = bounds['maxX'];
    final maxY = bounds['maxY'];
    final maxZ = bounds['maxZ'];
    if (minX == null || minY == null || minZ == null ||
        maxX == null || maxY == null || maxZ == null) {
      return null;
    }
    final hx = (maxX - minX) * 0.5;
    final hy = (maxY - minY) * 0.5;
    final hz = (maxZ - minZ) * 0.5;
    final cx = (maxX + minX) * 0.5;
    final cy = (maxY + minY) * 0.5;
    final cz = (maxZ + minZ) * 0.5;
    return ModelBounds(
      halfExtents: v64.Vector3(hx, hy, hz),
      center: v64.Vector3(cx, cy, cz),
    );
  }

  @override
  Future<void> render({
    required v64.Matrix4 viewMatrix,
    required v64.Matrix4 modelMatrix,
  }) async {
    final id = _textureId;
    if (id == null || !_loaded) return;
    // vector_math's Matrix4.storage is Float64List; native side
    // wants Float32List (matches WGSL's f32 mat4x4). Down-cast in
    // place — 16-element copies are negligible.
    final viewF32 = Float32List.fromList(viewMatrix.storage);
    final modelF32 = Float32List.fromList(modelMatrix.storage);
    await SceneBridge.instance.setMatrices(
      textureId: id,
      view: viewF32,
      model: modelF32,
    );
  }

  @override
  Future<void> dispose() async {
    final id = _textureId;
    _textureId = null;
    _loaded = false;
    if (id != null) {
      try {
        await SceneBridge.instance.destroyTexture(id);
      } catch (e, s) {
        debugPrint('[AetherCppViewerImpl] destroyTexture($id) failed: $e\n$s');
      }
    }
  }
}

/// Master switch the LiveModelView / createViewerImpl() consult to
/// pick which impl to instantiate. G4 cutover: feed cards already go
/// through `kPostCardUseAetherCppViewer` in post_card.dart (which
/// instantiates AetherCppCardDemo directly, bypassing this factory).
/// This flag controls the LATER call sites that come through the
/// abstract ViewerImpl interface — currently no production caller
/// reads it, but G5+ work (PLY / SPZ format dispatch) lands here.
/// Stays true so once those call sites exist they pick aether_cpp by
/// default. G9 deletes the thermion branch entirely.
const bool kAetherCppViewerEnabled = true;

/// Picks the impl. G4+ sites replace LiveModelView's direct
/// ViewerWidget usage with `ViewerImpl impl = createViewerImpl();
/// ...`.
ViewerImpl createViewerImpl() {
  return kAetherCppViewerEnabled
      ? AetherCppViewerImpl()
      : ThermionViewerImpl();
}
