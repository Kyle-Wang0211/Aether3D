// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// dart:ffi backend for GlbNormalizer. Confined to this file so the
// public surface in glb_norm.dart can be imported on web (which uses
// the sibling _glb_norm_ffi_web.dart wasm shim instead).
//
// Threading model: caller stays on the UI isolate. We spin a worker
// via Isolate.run, transfer the input bytes through
// TransferableTypedData (no double-copy), and send progress updates
// from the worker back to a ReceivePort on the calling isolate via a
// SendPort. The native progress callback is created with
// NativeCallable.isolateLocal — it has to live AND be invoked on the
// worker isolate because the C signature returns int (cancel flag),
// and NativeCallable.listener cannot return values to C.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'glb_norm.dart';

// ─── C ABI struct layouts ──────────────────────────────────────────
// Must mirror aether_cpp/include/aether_glb_norm_c.h field-for-field.

final class _OptionsRaw extends Struct {
  @Int32()
  external int targetAtlasSize;
  @Int32()
  external int maxAtlasSize;
  @Uint32()
  external int targetFaceCount;
  @Int32()
  external int allowOversizeTextures;
}

final class _BufferRaw extends Struct {
  external Pointer<Uint8> data;
  @Size()
  external int size;
}

final class _StatsRaw extends Struct {
  @Uint32()
  external int inputPrimitiveCount;
  @Uint32()
  external int inputMaterialCount;
  @Uint32()
  external int inputFaceCount;
  @Uint32()
  external int outputPrimitiveCount;
  @Uint32()
  external int outputMaterialCount;
  @Uint32()
  external int outputFaceCount;
  @Int32()
  external int outputAtlasSize;
  @Float()
  external double elapsedSeconds;
}

// C signature: int (*)(float, const char*, void*).
typedef _ProgressFnNative = Int32 Function(
  Float,
  Pointer<Utf8>,
  Pointer<Void>,
);

// ─── Function-pointer typedefs ─────────────────────────────────────

typedef _GlbNormOptionsDefaultNative = Void Function(Pointer<_OptionsRaw>);
typedef _GlbNormOptionsDefaultDart = void Function(Pointer<_OptionsRaw>);

typedef _GlbNormBufferFreeNative = Void Function(Pointer<_BufferRaw>);
typedef _GlbNormBufferFreeDart = void Function(Pointer<_BufferRaw>);

typedef _GlbNormRunNative = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<_OptionsRaw>,
  Pointer<NativeFunction<_ProgressFnNative>>,
  Pointer<Void>,
  Pointer<_BufferRaw>,
  Pointer<_StatsRaw>,
);
typedef _GlbNormRunDart = int Function(
  Pointer<Uint8>,
  int,
  Pointer<_OptionsRaw>,
  Pointer<NativeFunction<_ProgressFnNative>>,
  Pointer<Void>,
  Pointer<_BufferRaw>,
  Pointer<_StatsRaw>,
);

typedef _GlbNormResultStrNative = Pointer<Utf8> Function(Int32);
typedef _GlbNormResultStrDart = Pointer<Utf8> Function(int);

// ─── Library resolution ────────────────────────────────────────────
// iOS: -force_load'd into Runner — DynamicLibrary.process() finds it.
// Android: shipped as libaether3d_c.so via the Gradle aar/jniLibs path.
// macOS dev: aether_cpp/build/libaether3d_ffi.dylib next to the binary.
// HarmonyOS / Linux / Windows: equivalent shared object name.
//
// We try process() first (iOS / when statically linked), then fall
// back to platform-specific shared libraries.

DynamicLibrary? _cachedLib;

// Sentinel symbol that we probe after opening any candidate library —
// it MUST come from the GLB-norm translation unit, so a
// libaether3d_ffi.dylib that only exposes aether_version_string fails
// the probe and we move on (or surface GlbNormUnavailable). Don't
// reuse the version symbol here; that's exactly the false-positive
// trap.
const String _probeSymbol = 'aether_glb_norm_options_default';

bool _hasProbeSymbol(DynamicLibrary lib) {
  try {
    lib.lookup<NativeFunction<_GlbNormOptionsDefaultNative>>(_probeSymbol);
    return true;
  } catch (_) {
    return false;
  }
}

DynamicLibrary _resolveLibrary() {
  final cached = _cachedLib;
  if (cached != null) return cached;

  final attempts = <String>[];

  // Process namespace first (iOS pod -force_load case, plus any host
  // that has the lib injected via DYLD_INSERT_LIBRARIES / LD_PRELOAD).
  try {
    final lib = DynamicLibrary.process();
    if (_hasProbeSymbol(lib)) {
      _cachedLib = lib;
      return lib;
    }
    attempts.add('process: probe symbol $_probeSymbol not found');
  } catch (e) {
    attempts.add('process: $e');
  }

  Iterable<String> candidates;
  if (Platform.isAndroid) {
    candidates = const ['libaether3d_c.so'];
  } else if (Platform.isMacOS) {
    candidates = _macDylibCandidates();
  } else if (Platform.isLinux) {
    candidates = const ['libaether3d_c.so'];
  } else if (Platform.isWindows) {
    candidates = const ['aether3d_c.dll'];
  } else {
    candidates = const <String>[];
  }

  for (final path in candidates) {
    // Only dev-tree paths are absolute; bare names rely on the
    // dynamic loader's search path so don't existsSync()-gate them.
    if (path.startsWith('/') && !File(path).existsSync()) continue;
    try {
      final lib = DynamicLibrary.open(path);
      if (_hasProbeSymbol(lib)) {
        _cachedLib = lib;
        return lib;
      }
      attempts.add('$path: opened but $_probeSymbol missing');
    } catch (e) {
      attempts.add('$path: $e');
    }
  }

  throw GlbNormUnavailable(
    'Could not resolve aether_glb_norm symbols on '
    '${Platform.operatingSystem}. Tried: ${attempts.join('; ')}. '
    'On iOS make sure the aether3d_ffi pod is force-loaded into '
    'Runner with the GLB-norm symbols built in (Phase 4). On '
    'Android make sure libaether3d_c.so is in jniLibs/<abi>/.',
  );
}

Iterable<String> _macDylibCandidates() sync* {
  // Walk ancestors of the running binary looking for the dev-tree
  // build artifact, then a couple of common bundled locations.
  final exe = Platform.resolvedExecutable;
  var dir = File(exe).parent;
  for (var i = 0; i < 8; i++) {
    final base = dir.path;
    yield '$base/aether_cpp/build/libaether3d_ffi.dylib';
    yield '$base/Frameworks/libaether3d_ffi.dylib';
    yield '$base/Contents/Frameworks/libaether3d_ffi.dylib';
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  // Pinned dev-tree fallback (matches lib/aether_ffi.dart).
  yield '/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/build/libaether3d_ffi.dylib';
  yield 'libaether3d_ffi.dylib';
}

// ─── Bound-function cache (per-isolate) ────────────────────────────

class _Bindings {
  final _GlbNormOptionsDefaultDart optionsDefault;
  final _GlbNormBufferFreeDart bufferFree;
  final _GlbNormRunDart run;
  final _GlbNormResultStrDart resultStr;

  _Bindings._(this.optionsDefault, this.bufferFree, this.run, this.resultStr);

  factory _Bindings.resolve() {
    final lib = _resolveLibrary();
    return _Bindings._(
      lib.lookupFunction<_GlbNormOptionsDefaultNative,
          _GlbNormOptionsDefaultDart>('aether_glb_norm_options_default'),
      lib.lookupFunction<_GlbNormBufferFreeNative, _GlbNormBufferFreeDart>(
        'aether_glb_norm_buffer_free',
      ),
      lib.lookupFunction<_GlbNormRunNative, _GlbNormRunDart>(
        'aether_glb_norm_run',
      ),
      lib.lookupFunction<_GlbNormResultStrNative, _GlbNormResultStrDart>(
        'aether_glb_norm_result_str',
      ),
    );
  }
}

// ─── Public entry called by glb_norm.dart ──────────────────────────

/// Run normalization on a worker isolate. UI isolate stays responsive.
/// Throws [GlbNormUnavailable] only if resolution fails on the worker
/// (the call site should treat it the same as any other failure to
/// load native code — surface to the user, no recovery).
Future<GlbNormResult> runOnWorkerIsolate({
  required Uint8List input,
  required GlbNormOptions opts,
  void Function(double fraction, String phase)? onProgress,
}) async {
  // Fail fast on the calling isolate so the caller doesn't spin up a
  // worker just to discover the symbols are missing. The probe uses
  // the same path the worker takes, so a successful probe here means
  // the worker will succeed too (modulo per-isolate dlopen quirks).
  _Bindings.resolve();

  ReceivePort? progressPort;
  StreamSubscription<dynamic>? progressSub;
  if (onProgress != null) {
    progressPort = ReceivePort();
    progressSub = progressPort.listen((msg) {
      if (msg is List && msg.length == 2) {
        final fraction = msg[0];
        final phase = msg[1];
        if (fraction is double && phase is String) {
          onProgress(fraction, phase);
        }
      }
    });
  }

  final transferable = TransferableTypedData.fromList([input]);
  final progressSendPort = progressPort?.sendPort;
  final capturedOpts = opts;

  try {
    return await Isolate.run<GlbNormResult>(() {
      final bytes = transferable.materialize().asUint8List();
      return _runOnThisIsolate(
        input: bytes,
        opts: capturedOpts,
        progressSendPort: progressSendPort,
      );
    });
  } finally {
    await progressSub?.cancel();
    progressPort?.close();
  }
}

GlbNormResult _runOnThisIsolate({
  required Uint8List input,
  required GlbNormOptions opts,
  required SendPort? progressSendPort,
}) {
  final bindings = _Bindings.resolve();

  final optsPtr = calloc<_OptionsRaw>();
  // Seed with C-side defaults, then override with caller's values so
  // any future fields the C struct grows pick up sensible defaults
  // even if Dart hasn't been updated to surface them.
  bindings.optionsDefault(optsPtr);
  optsPtr.ref.targetAtlasSize = opts.targetAtlasSize;
  optsPtr.ref.maxAtlasSize = opts.maxAtlasSize;
  optsPtr.ref.targetFaceCount = opts.targetFaceCount;
  optsPtr.ref.allowOversizeTextures = opts.allowOversizeTextures ? 1 : 0;

  final inputPtr = calloc<Uint8>(input.length);
  inputPtr.asTypedList(input.length).setAll(0, input);

  final bufPtr = calloc<_BufferRaw>();
  bufPtr.ref.data = nullptr;
  bufPtr.ref.size = 0;
  final statsPtr = calloc<_StatsRaw>();

  NativeCallable<_ProgressFnNative>? progressCallable;
  Pointer<NativeFunction<_ProgressFnNative>> progressPtr = nullptr;
  if (progressSendPort != null) {
    progressCallable = NativeCallable<_ProgressFnNative>.isolateLocal(
      (double fraction, Pointer<Utf8> phasePtr, Pointer<Void> userData) {
        // phase_label is `const char*` from string-literal storage on
        // the C side; safe to dereference synchronously here.
        final phase = phasePtr == nullptr ? '' : phasePtr.toDartString();
        progressSendPort.send(<dynamic>[fraction, phase]);
        return 0; // public API has no cancellation; never cancel.
      },
      exceptionalReturn: 0,
    );
    progressPtr = progressCallable.nativeFunction;
  }

  int statusCode;
  try {
    statusCode = bindings.run(
      inputPtr,
      input.length,
      optsPtr,
      progressPtr,
      nullptr,
      bufPtr,
      statsPtr,
    );
  } finally {
    progressCallable?.close();
  }

  final stats = _readStats(statsPtr.ref);
  Uint8List? output;
  if (statusCode == 0 && bufPtr.ref.data != nullptr && bufPtr.ref.size > 0) {
    // Copy out so we can free the C-owned buffer immediately and not
    // leak through the Future's lifetime.
    output = Uint8List.fromList(bufPtr.ref.data.asTypedList(bufPtr.ref.size));
  }

  // Always free, even on error — the C contract clears data/size on
  // failure but pairing the call defensively costs nothing.
  bindings.bufferFree(bufPtr);

  final status = _statusFromCode(statusCode);
  String? error;
  if (status != GlbNormStatus.ok) {
    final strPtr = bindings.resultStr(statusCode);
    error = strPtr == nullptr ? 'unknown' : strPtr.toDartString();
  }

  calloc.free(statsPtr);
  calloc.free(bufPtr);
  calloc.free(optsPtr);
  calloc.free(inputPtr);

  return GlbNormResult(
    output: output,
    stats: stats,
    status: status,
    error: error,
  );
}

GlbNormStatus _statusFromCode(int code) {
  if (code < 0 || code >= GlbNormStatus.values.length) {
    return GlbNormStatus.internal;
  }
  return GlbNormStatus.values[code];
}

GlbNormStats _readStats(_StatsRaw raw) {
  return GlbNormStats(
    inputPrimitiveCount: raw.inputPrimitiveCount,
    inputMaterialCount: raw.inputMaterialCount,
    inputFaceCount: raw.inputFaceCount,
    outputPrimitiveCount: raw.outputPrimitiveCount,
    outputMaterialCount: raw.outputMaterialCount,
    outputFaceCount: raw.outputFaceCount,
    outputAtlasSize: raw.outputAtlasSize,
    elapsedSeconds: raw.elapsedSeconds,
  );
}
