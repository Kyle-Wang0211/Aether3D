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
import 'dart:io';
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

/// Static-only namespace for aether_cpp FFI calls.
///
/// iOS resolves symbols from the running process (the static archive is
/// force-loaded into the app binary). macOS supports that path too, but
/// direct `.app` launches often need an explicit `DynamicLibrary.open()`
/// against the sibling `aether_cpp/build/libaether3d_ffi.dylib`.
class AetherFfi {
  AetherFfi._();

  static DynamicLibrary? _cachedLibrary;
  static _AetherVersionStringDart? _cachedVersionFn;

  static Iterable<String> _ancestorDirectories(String path) sync* {
    if (path.isEmpty) return;
    var entity = FileSystemEntity.typeSync(path);
    var dir = (entity == FileSystemEntityType.directory)
        ? Directory(path)
        : File(path).parent;
    while (true) {
      final current = dir.absolute.path;
      yield current;
      final parent = dir.parent.absolute.path;
      if (parent == current) break;
      dir = dir.parent;
    }
  }

  static List<String> _candidateLibraryPaths() {
    final candidates = <String>[];
    final seen = <String>{};

    void add(String path) {
      if (path.isEmpty) return;
      final normalized = File(path).absolute.path;
      if (seen.add(normalized)) {
        candidates.add(normalized);
      }
    }

    for (final root in <String>[
      Directory.current.path,
      Platform.resolvedExecutable,
    ]) {
      for (final ancestor in _ancestorDirectories(root)) {
        add('$ancestor/aether_cpp/build/libaether3d_ffi.dylib');
        add('$ancestor/Contents/Frameworks/libaether3d_ffi.dylib');
        add('$ancestor/Frameworks/libaether3d_ffi.dylib');
      }
    }
    add('libaether3d_ffi.dylib');
    return candidates;
  }

  static DynamicLibrary _resolveLibrary() {
    if (_cachedLibrary != null) return _cachedLibrary!;

    Object? processError;
    try {
      final lib = DynamicLibrary.process();
      lib.lookup<NativeFunction<_AetherVersionStringNative>>(
          'aether_version_string');
      _cachedLibrary = lib;
      return lib;
    } catch (e) {
      processError = e;
    }

    if (!Platform.isMacOS) {
      throw FfiResolutionError(
          'Failed to resolve aether_version_string from process: $processError');
    }

    Object? lastOpenError;
    final existingCandidates = <String>[];
    for (final path in _candidateLibraryPaths()) {
      if (!File(path).existsSync()) continue;
      existingCandidates.add(path);
      try {
        final lib = DynamicLibrary.open(path);
        lib.lookup<NativeFunction<_AetherVersionStringNative>>(
            'aether_version_string');
        _cachedLibrary = lib;
        return lib;
      } catch (e) {
        lastOpenError = e;
      }
    }

    final searched = existingCandidates.isEmpty
        ? 'no existing dylib candidates'
        : existingCandidates.join(', ');
    throw FfiResolutionError(
        'Failed to resolve aether_version_string from process or dylib candidates. '
        'processError=$processError; searched=$searched; lastOpenError=$lastOpenError');
  }

  static _AetherVersionStringDart _resolveVersionFn() {
    if (_cachedVersionFn != null) return _cachedVersionFn!;
    final lib = _resolveLibrary();
    _cachedVersionFn = lib.lookupFunction<_AetherVersionStringNative,
        _AetherVersionStringDart>('aether_version_string');
    return _cachedVersionFn!;
  }

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
  /// Cost: after the first successful resolution the function pointer is
  /// cached for the life of the process.
  static String versionString() {
    final fn = _resolveVersionFn();
    final ptr = fn();
    if (ptr == nullptr) {
      throw const FfiResolutionError(
          'aether_version_string() returned NULL — C ABI bug');
    }
    return ptr.toDartString();
  }
}
