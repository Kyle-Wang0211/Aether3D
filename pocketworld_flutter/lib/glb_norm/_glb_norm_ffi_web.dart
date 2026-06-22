// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// dart:js_interop backend for GlbNormalizer on Web.
//
// Loaded only when dart.library.js_interop is available (web builds).
// The native (FFI) backend in _glb_norm_ffi_native.dart is used on
// every other platform.
//
// Status: scaffolding. The Phase 4 wasm artifact
// (aether_cpp/dist/libs/web/glb_norm.{wasm,js}) is not built yet, so
// runOnWorkerIsolate() throws GlbNormUnavailable. Once Phase 4 ships
// the wasm, this file gets the JS-interop bindings to load it,
// allocate input bytes inside the wasm heap, call the four exported
// functions, copy output bytes back, and free.
//
// The conditional-import shape stays so call sites in the rest of the
// app compile on web today — the failure surfaces at runtime with a
// clear message rather than at compile time.

import 'dart:async';
import 'dart:typed_data';

import 'glb_norm.dart';

Future<GlbNormResult> runOnWorkerIsolate({
  required Uint8List input,
  required GlbNormOptions opts,
  void Function(double fraction, String phase)? onProgress,
}) {
  throw const GlbNormUnavailable(
    'Web wasm backend not yet shipped. Phase 4 will produce '
    'aether_cpp/dist/libs/web/glb_norm.{wasm,js}; until then, route '
    'web users to the server-side normalizer.',
  );
}
