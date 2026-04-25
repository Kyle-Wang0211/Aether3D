// Phase 3.4 macOS Dart CLI smoke test for the aether_cpp FFI binding.
//
// Validates that dart:ffi can:
//   1. Open libaether3d_ffi.dylib via DynamicLibrary.open
//   2. Look up the aether_version_string symbol
//   3. Call it via the modern Pointer<Utf8> typedef
//   4. Convert the returned C string into a Dart String
//
// Run:
//   cd pocketworld_flutter
//   dart run tool/aether_ffi_smoke.dart
//
// Expected output:
//   === aether_ffi_smoke (P3.4) ===
//   loaded: <path>/libaether3d_ffi.dylib
//   aether_version_string(): "aether 0.1.0-phase3"
//   PASS
//
// On iOS (Phase 3.5+) the dylib is replaced by a vendored xcframework, but
// the Dart binding code (lookupFunction signature + Utf8 conversion) is
// identical — that's why we validate on the macOS Dart CLI first.

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef _AetherVersionStringNative = Pointer<Utf8> Function();
typedef AetherVersionStringDart = Pointer<Utf8> Function();

void main() {
  // Locate the dylib relative to repo root. This script is run from
  // pocketworld_flutter/, so go up one and into aether_cpp/build/.
  final repoRoot = Directory.current.parent;
  final dylibPath =
      '${repoRoot.path}/aether_cpp/build/libaether3d_ffi.dylib';

  print('=== aether_ffi_smoke (P3.4) ===');

  if (!File(dylibPath).existsSync()) {
    stderr.writeln(
        'FAIL: dylib not found at $dylibPath\n'
        'Build it first: cmake --build aether_cpp/build --target aether3d_ffi');
    exit(1);
  }

  final lib = DynamicLibrary.open(dylibPath);
  print('loaded: $dylibPath');

  final aetherVersionString =
      lib.lookupFunction<_AetherVersionStringNative, AetherVersionStringDart>(
          'aether_version_string');

  final ptr = aetherVersionString();
  if (ptr == nullptr) {
    stderr.writeln('FAIL: aether_version_string() returned null');
    exit(1);
  }

  final str = ptr.toDartString();
  print('aether_version_string(): "$str"');

  if (str.isEmpty) {
    stderr.writeln('FAIL: empty string');
    exit(1);
  }
  if (!str.startsWith('aether ')) {
    stderr.writeln('FAIL: unexpected format (expected "aether <version>")');
    exit(1);
  }

  print('PASS');
}
