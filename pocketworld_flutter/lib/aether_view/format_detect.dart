// Format detection for the viewer pipeline.
//
// Decides whether a downloaded byte blob should go through the GLB
// mesh path (aether_scene_renderer_load_glb) or the splat path
// (aether_splat_load_ply / aether_splat_load_spz).
//
// This file is part of G2 (skeleton). G5 fills in the actual sniffing.

import 'dart:typed_data';

enum ViewerFormat {
  /// glTF binary container — magic `glTF` (0x46546C67) at byte 0.
  /// Routes to `aether_scene_renderer_load_glb`.
  glb,

  /// PLY ASCII / binary header WITHOUT 3DGS-specific properties.
  /// Plain triangulated mesh. NOT supported in v1 — return error.
  plyMesh,

  /// PLY with the gsplat property convention: `f_dc_0..2`, `scale_*`,
  /// `rot_*`, `opacity` per vertex. The de-facto 3D Gaussian Splat
  /// distribution format. Routes to `aether_splat_load_ply`.
  plyGsplat,

  /// Niantic compressed Gaussian Splat. Magic `SPZ\0` at byte 0.
  /// Routes to `aether_splat_load_spz`.
  spz,

  /// Three.js / antimatter "splat" format (binary, fixed-stride).
  /// Currently treated as splat path; G5 confirms format details.
  splat,

  /// Couldn't classify. Caller treats as load failure.
  unknown,
}

abstract class FormatDetector {
  /// Sniff [bytes] for a known viewer format. Header-based detection;
  /// returns within microseconds without allocating. G5 implements.
  static ViewerFormat detect(Uint8List bytes) {
    // TODO(G5): real detection. For now everything that doesn't reach
    // here through the existing thermion (pure-GLB) path is unknown.
    return ViewerFormat.unknown;
  }

  /// Hint based on URL extension only — useful for routing the load
  /// before the bytes are fetched (e.g. choosing which engine to
  /// pre-warm).
  static ViewerFormat hintFromUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.endsWith('.glb') || lower.endsWith('.gltf')) {
      return ViewerFormat.glb;
    }
    if (lower.endsWith('.ply')) {
      // Conservative: PLY without sniff defaults to splat (since
      // gsplat PLY is the dominant PLY shape on this app's feed). G5
      // upgrades this to a real header sniff.
      return ViewerFormat.plyGsplat;
    }
    if (lower.endsWith('.spz')) return ViewerFormat.spz;
    if (lower.endsWith('.splat')) return ViewerFormat.splat;
    return ViewerFormat.unknown;
  }
}
