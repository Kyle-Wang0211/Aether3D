// ViewerImpl — abstraction over thermion (current) vs aether_cpp scene
// renderer (target).
//
// LiveModelView talks to a ViewerImpl, not directly to ViewerWidget,
// so the migration from thermion → aether_cpp is a one-line swap of
// the concrete class behind a feature flag. See
// aether_cpp/PHASE_FLUTTER_VIEWER_PLAN.md for the staged plan.
//
// G2 ships only the interface + two empty concrete classes. G3+ fill
// in the actual rendering paths.

import 'dart:ui' show Color;

import 'package:vector_math/vector_math_64.dart' as v64;

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
  /// the caller should hand to a `Texture(textureId: ...)` widget.
  /// Background color is what shows behind the model and during the
  /// load-in cover (see `_LoadCover` in live_model_view.dart).
  Future<int> create({
    required double width,
    required double height,
    required Color background,
  });

  /// Fetch + parse the model at [url]. Format is detected internally
  /// (see `format_detect.dart`) and routed to the appropriate
  /// underlying engine (mesh PBR for GLB, splat engine for PLY/SPZ).
  /// Returns the model's local-space bounds for camera fit.
  Future<ModelBounds> load(String url);

  /// One frame. View + projection matrices are 4×4 column-major
  /// (matches both `vector_math_64.Matrix4.storage` and Filament).
  Future<void> render({
    required v64.Matrix4 viewMatrix,
    required v64.Matrix4 projMatrix,
  });

  Future<void> dispose();
}

/// Thermion-backed implementation. This is the CURRENT behaviour —
/// G2 shipped as a stub that the existing LiveModelView wiring will
/// be migrated INTO in G3. Until G3 lands, LiveModelView still holds
/// the thermion calls inline; this class just reserves the type
/// shape so callers can program against `ViewerImpl`.
class ThermionViewerImpl implements ViewerImpl {
  @override
  Future<int> create({
    required double width,
    required double height,
    required Color background,
  }) async {
    throw UnimplementedError(
      'G3: move the existing ViewerWidget setup from '
      '_LiveModelViewState._onViewerReady into here.',
    );
  }

  @override
  Future<ModelBounds> load(String url) async {
    throw UnimplementedError(
        'G3: move existing GlbAssetCache.getOrLoad + addToScene here.');
  }

  @override
  Future<void> render({
    required v64.Matrix4 viewMatrix,
    required v64.Matrix4 projMatrix,
  }) async {
    throw UnimplementedError('G3: move existing camera.lookAt here.');
  }

  @override
  Future<void> dispose() async {
    throw UnimplementedError(
        'G3: move existing dispose ordering (flag → ticker → null fields) here.');
  }
}

/// aether_cpp-backed implementation. This is the TARGET — once G3+
/// fill it in, flipping `kAetherCppViewerEnabled` to true on a
/// PostCard / detail page swaps from thermion to aether_cpp without
/// touching any UI code.
class AetherCppViewerImpl implements ViewerImpl {
  @override
  Future<int> create({
    required double width,
    required double height,
    required Color background,
  }) async {
    throw UnimplementedError(
      'G4: SceneRendererBindings.create(...) → return Flutter '
      'texture id allocated by AetherTexturePlugin (iOS) / '
      'platform-equivalent (Android/Web).',
    );
  }

  @override
  Future<ModelBounds> load(String url) async {
    throw UnimplementedError(
      'G4 (GLB) / G5 (PLY,SPZ): FormatDetector.detect(bytes) → '
      'aether_scene_renderer_load_glb OR aether_splat_load_ply.',
    );
  }

  @override
  Future<void> render({
    required v64.Matrix4 viewMatrix,
    required v64.Matrix4 projMatrix,
  }) async {
    throw UnimplementedError(
      'G4: pin Float buffers for the two 4×4 matrices, call '
      'SceneRendererBindings.renderFull(handle, view, proj).',
    );
  }

  @override
  Future<void> dispose() async {
    throw UnimplementedError(
      'G4: SceneRendererBindings.destroy(handle) + free pinned '
      'matrix buffers.',
    );
  }
}

/// Master switch the LiveModelView consults to pick which impl to
/// instantiate. Default false during the migration; flipped per-call-site
/// in G4 (community feed first, detail page later) and globally in G9
/// once thermion is removed.
const bool kAetherCppViewerEnabled = false;

/// Picks the impl. Replace LiveModelView's direct ViewerWidget usage
/// with `ViewerImpl impl = createViewerImpl(); ...`.
ViewerImpl createViewerImpl() {
  return kAetherCppViewerEnabled ? AetherCppViewerImpl() : ThermionViewerImpl();
}
