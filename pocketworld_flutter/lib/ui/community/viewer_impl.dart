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

import '../../aether_view/scene_bridge.dart';

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
  Future<ModelBounds?> load(String url);

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
  Future<ModelBounds?> load(String url) async {
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
    final id = await SceneBridge.instance.createTexture(
      width: width.round().clamp(1, 4096),
      height: height.round().clamp(1, 4096),
    );
    _textureId = id;
    return id;
  }

  @override
  Future<ModelBounds?> load(String url) async {
    final id = _textureId;
    if (id == null) {
      throw StateError('AetherCppViewerImpl.load called before create');
    }
    // Strip the file:// scheme; native side opens with fopen().
    final path =
        url.startsWith('file://') ? Uri.parse(url).toFilePath() : url;
    await SceneBridge.instance.loadGlb(textureId: id, path: path);
    _loaded = true;
    // TODO(G4): native side already returns `bounds` in its
    // [Aether3D][scene_renderer] log line ("bounds [-0.95..0.94]");
    // surface that through the MethodChannel as a return value so
    // the camera fit math has real data. For now we return null and
    // the caller falls back to its widget.cameraDistance default.
    return null;
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

/// Master switch the LiveModelView consults to pick which impl to
/// instantiate. Default false during the migration; flipped per-call-
/// site in G4 (community feed first, detail page later) and globally
/// in G9 once thermion is removed.
const bool kAetherCppViewerEnabled = false;

/// Picks the impl. G4+ sites replace LiveModelView's direct
/// ViewerWidget usage with `ViewerImpl impl = createViewerImpl();
/// ...`.
ViewerImpl createViewerImpl() {
  return kAetherCppViewerEnabled
      ? AetherCppViewerImpl()
      : ThermionViewerImpl();
}
