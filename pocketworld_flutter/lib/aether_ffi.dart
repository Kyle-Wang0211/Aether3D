// Phase 5.4 — Flutter library binding for aether_cpp FFI surface.
//
// This is the production-app-side counterpart to tool/aether_ffi_smoke.dart
// (the P3.4 macOS Dart CLI smoke). The smoke validated dart:ffi can call C
// via DynamicLibrary.open(<dylib path>); this library validates the same
// lookup against the runtime-resolved process binary, which is the only
// form that works on iOS where the static .a is -force_load'd into
// Runner.debug.dylib (Phase 5.0).
//
// Usage:
//   import 'package:pocketworld_flutter/aether_ffi.dart';
//   Text(AetherFfi.versionString())
//
// Failure mode:
//   AetherFfi.versionString() throws a clear FfiResolutionError if the
//   symbol can't be resolved (e.g. the static lib didn't land in the
//   binary). The UI catches and displays the error; this is the
//   deliberate Phase 5.4 verification path — if the version string flips
//   from 'v0.1.0-phase2' (P2.4 placeholder) to 'aether 0.1.0-phase3'
//   (P3.3 ABI), the FFI bridge is alive end-to-end.

import 'dart:ffi';
import 'package:ffi/ffi.dart';

/// FFI lookup or call failed. Carries a human-readable reason; not meant
/// to be caught and recovered from — surfaced to UI for diagnosis.
class FfiResolutionError implements Exception {
  final String message;
  const FfiResolutionError(this.message);
  @override
  String toString() => 'FfiResolutionError: $message';
}

typedef _AetherVersionStringNative = Pointer<Utf8> Function();
typedef _AetherVersionStringDart = Pointer<Utf8> Function();

/// Static-only namespace for aether_cpp FFI calls. No state — every
/// call resolves the symbol fresh against `DynamicLibrary.process()` so
/// hot-reload doesn't cache stale function pointers.
class AetherFfi {
  AetherFfi._();

  /// Returns the version string baked into aether_cpp's `version.cpp`.
  /// Format on Phase 3 is `"aether 0.1.0-phase3"` (subject to the C ABI
  /// in include/aether/aether_version.h — no formal contract beyond
  /// "starts with 'aether ' followed by something").
  ///
  /// Throws [FfiResolutionError] if:
  ///   - the symbol isn't in the running binary (Phase 5.0 link-stage
  ///     issue — `-force_load` didn't pull the .a in)
  ///   - the C function returned NULL (program bug; not currently
  ///     possible per the C source but documented for safety)
  ///
  /// Cost: the lookup is process-symbol-table search (microseconds).
  /// Calling this every widget rebuild is fine; no need to memoize.
  static String versionString() {
    final lib = DynamicLibrary.process();
    final fn = lib.lookupFunction<_AetherVersionStringNative,
        _AetherVersionStringDart>('aether_version_string');
    final ptr = fn();
    if (ptr == nullptr) {
      throw const FfiResolutionError(
          'aether_version_string() returned NULL — C ABI bug');
    }
    return ptr.toDartString();
  }
}
