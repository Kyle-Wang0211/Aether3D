// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 5 — Flutter wrapper for the cross-platform GLB normalizer
// (aether_cpp/src/glb_norm). Public surface is FFI-free so call sites
// stay portable to the wasm web build (lib/glb_norm/_glb_norm_ffi_web).
//
// Threading: the native call is offloaded to a worker isolate via
// Isolate.run so the UI isolate stays at 60fps even for 8K-atlas runs
// (~256 MB raw / ~30 MB compressed peak). Progress callbacks created
// via NativeCallable.listener post events back to the calling isolate;
// the worker isolate is blocked inside aether_glb_norm_run, so the
// listener has to live on the caller side or the events would queue
// behind the blocking call.
//
// Memory: input bytes move to the worker via TransferableTypedData so
// the 50 MB+ input GLBs we expect from Polycam / KIRI exports do not
// pay a double-allocation tax across the isolate boundary.

import 'dart:async';
import 'dart:typed_data';

import '_glb_norm_ffi_native.dart'
    if (dart.library.js_interop) '_glb_norm_ffi_web.dart' as ffi;

/// Tunables for [GlbNormalizer.normalize].
///
/// Defaults match the C ABI's `aether_glb_norm_options_default`:
/// auto-pick atlas size, 8K cap, 500 K face decimation, no oversize.
class GlbNormOptions {
  /// Target atlas side in pixels. 0 = auto-pick smallest power-of-2
  /// that holds all charts at ~70% utilization, capped at
  /// [maxAtlasSize]. Tested values: 1024, 2048, 4096, 8192, 16384.
  final int targetAtlasSize;

  /// Hard ceiling on the output atlas. iOS 14+ guarantees 8K texture
  /// support; 16K is safe on iPhone 12+ / Android Vulkan-class but
  /// not universal — default 8K avoids per-device surprises.
  final int maxAtlasSize;

  /// Mesh decimation target. 0 = no decimation. Otherwise the output
  /// mesh is simplified to at most this many triangles via
  /// meshoptimizer's quadric-error metric.
  final int targetFaceCount;

  /// If true, keep the original 4K-or-larger atlas instead of
  /// downscaling to fit [maxAtlasSize]. Default false.
  final bool allowOversizeTextures;

  const GlbNormOptions({
    this.targetAtlasSize = 0,
    this.maxAtlasSize = 8192,
    this.targetFaceCount = 500000,
    this.allowOversizeTextures = false,
  });
}

/// Mirror of `aether_glb_norm_stats_t`. Filled even on failure with
/// whatever was learned before the error so callers can surface
/// useful diagnostics.
class GlbNormStats {
  final int inputPrimitiveCount;
  final int inputMaterialCount;
  final int inputFaceCount;
  final int outputPrimitiveCount;
  final int outputMaterialCount;
  final int outputFaceCount;
  final int outputAtlasSize;
  final double elapsedSeconds;

  const GlbNormStats({
    this.inputPrimitiveCount = 0,
    this.inputMaterialCount = 0,
    this.inputFaceCount = 0,
    this.outputPrimitiveCount = 0,
    this.outputMaterialCount = 0,
    this.outputFaceCount = 0,
    this.outputAtlasSize = 0,
    this.elapsedSeconds = 0.0,
  });

  @override
  String toString() =>
      'GlbNormStats(in: $inputPrimitiveCount prim/$inputMaterialCount mat/'
      '$inputFaceCount face → out: $outputPrimitiveCount prim/'
      '$outputMaterialCount mat/$outputFaceCount face @ '
      '${outputAtlasSize}px atlas, ${elapsedSeconds.toStringAsFixed(3)}s)';
}

/// Mirror of `aether_glb_norm_result_t`. Stable order — keep new
/// values appended at the end so the wire ABI matches the C enum.
enum GlbNormStatus {
  ok,
  invalidGlb,
  noMaterials,
  noTextures,
  pngDecode,
  packingFailed,
  pngEncode,
  outOfMemory,
  cancelled,
  unsupported,
  internal,
}

/// Result of one normalize pass.
///
/// On [GlbNormStatus.ok] [output] holds the freshly-allocated GLB
/// bytes. On any error [output] is null and [error] carries the
/// human-readable code (matches `aether_glb_norm_result_str`).
class GlbNormResult {
  final Uint8List? output;
  final GlbNormStats stats;
  final GlbNormStatus status;
  final String? error;

  const GlbNormResult({
    required this.output,
    required this.stats,
    required this.status,
    this.error,
  });

  bool get isOk => status == GlbNormStatus.ok;
}

/// Static entry point. Always offloads to a worker isolate.
///
/// Throws [GlbNormUnavailable] if the native symbols are not linked
/// into the current binary (e.g. running unit tests on a host where
/// the iOS pod / Android .so is not on the search path).
class GlbNormalizer {
  GlbNormalizer._();

  /// Normalize one GLB. Pure function; safe to call multiple times
  /// concurrently — each call gets its own worker isolate.
  ///
  /// - [input] is the raw GLB bytes. Caller retains ownership; the
  ///   worker copies into native memory before returning.
  /// - [opts] picks atlas / face-count limits.
  /// - [onProgress] (if supplied) fires on the calling isolate, not
  ///   the worker. `fraction` is monotonically non-decreasing 0..1;
  ///   `phase` is one of "parsing", "packing atlas", "decimating
  ///   mesh", "encoding glb" (subject to the C side).
  static Future<GlbNormResult> normalize({
    required Uint8List input,
    GlbNormOptions opts = const GlbNormOptions(),
    void Function(double fraction, String phase)? onProgress,
  }) {
    return ffi.runOnWorkerIsolate(
      input: input,
      opts: opts,
      onProgress: onProgress,
    );
  }
}

/// Thrown from [GlbNormalizer.normalize] when the native FFI surface
/// cannot be resolved (e.g. test runner without the static library
/// linked, or release build that stripped the symbols).
class GlbNormUnavailable implements Exception {
  final String message;
  const GlbNormUnavailable(this.message);
  @override
  String toString() => 'GlbNormUnavailable: $message';
}
