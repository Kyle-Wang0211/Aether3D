// glomap_ffi.dart — Dart FFI binding for the on-device GLOMAP global-mapper core.
// Cross-platform (iOS/Android/HarmonyOS/desktop): the same C ABI `glomap_bench`
// is exposed from libglomap_core; Swift/Kotlin/ArkTS only need a thin shell to
// load the library + surface this Dart API.
//
// C ABI (glomap_bench.cc):
//   int glomap_bench(const char* db_path, char* out_json, int out_cap);
//   returns 0 on success; writes a JSON result string into out_json.

import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

typedef _GlomapBenchC = Int32 Function(
    Pointer<Utf8> dbPath, Pointer<Utf8> outJson, Int32 outCap);
typedef _GlomapBenchDart = int Function(
    Pointer<Utf8> dbPath, Pointer<Utf8> outJson, int outCap);

class GlomapCore {
  final DynamicLibrary _lib;
  late final _GlomapBenchDart _bench =
      _lib.lookupFunction<_GlomapBenchC, _GlomapBenchDart>('glomap_bench');

  GlomapCore._(this._lib);

  /// Loads libglomap_core. On iOS the symbols are statically linked into the
  /// app/process, so `DynamicLibrary.process()` is used; other platforms load
  /// the shared object by name.
  factory GlomapCore.open() {
    final DynamicLibrary lib = Platform.isIOS || Platform.isMacOS
        ? DynamicLibrary.process()
        : DynamicLibrary.open('libglomap_core.so');
    return GlomapCore._(lib);
  }

  /// Runs rotation averaging + global positioning + global BA on a COLMAP
  /// database and returns the parsed JSON result
  /// (solve_ms, n_registered, n_tracks, ...). The db file must be writable.
  Map<String, dynamic> runBenchmark(String dbPath) {
    final dbPtr = dbPath.toNativeUtf8();
    const cap = 4096;
    final outPtr = malloc.allocate<Uint8>(cap).cast<Utf8>();
    try {
      final rc = _bench(dbPtr, outPtr, cap);
      final json = outPtr.toDartString();
      final result = jsonDecode(json) as Map<String, dynamic>;
      result['rc'] = rc;
      return result;
    } finally {
      malloc.free(dbPtr);
      malloc.free(outPtr);
    }
  }
}
