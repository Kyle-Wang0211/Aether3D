// Tiny URL → bytes cache for .glb files used by LiveModelView.
//
// Two-tier:
//   • In-memory map keyed by URL — survives within a session, shared
//     across cards so the same model viewed in feed + detail page is
//     downloaded once.
//   • Disk cache under getTemporaryDirectory()/glb_cache/<sha1>.glb —
//     survives app restarts. The OS may evict /tmp at will, which is
//     fine: next visit re-downloads.
//
// Thermion's loadGltfFromBuffer(Uint8List) takes raw bytes, sidestepping
// any "is this an asset path or a file path" ambiguity in loadGltf. So
// the cache returns Uint8List, not File.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class GlbCache {
  GlbCache._();
  static final GlbCache instance = GlbCache._();

  final Dio _dio = Dio(BaseOptions(
    responseType: ResponseType.bytes,
    connectTimeout: const Duration(seconds: 15),
    // 17MB+ GLBs (e.g. AntiqueCamera Khronos sample) need more than the
    // old 60s ceiling on slower mobile networks — a typical 2-3 Mbps
    // cellular link takes 50-70s alone, then add backoff/jitter and
    // we'd reliably time out. 180s gives comfortable headroom; the
    // user can still kill the request by scrolling away.
    receiveTimeout: const Duration(seconds: 180),
  ));

  final Map<String, Uint8List> _mem = <String, Uint8List>{};
  final Map<String, Future<Uint8List>> _inflight = <String, Future<Uint8List>>{};

  Future<Uint8List> fetch(String url) {
    final cached = _mem[url];
    if (cached != null) return Future.value(cached);
    final pending = _inflight[url];
    if (pending != null) return pending;
    final future = _load(url);
    _inflight[url] = future;
    // `whenComplete` returns a NEW future that mirrors the original's
    // error — if we don't await/catch it, an _load() failure bubbles
    // up as an unhandled async error, runZonedGuarded's onError fires,
    // and main.dart's fallback runApp() kicks in (creating a fresh
    // mock-auth CurrentUser → state goes SignedOut → user ends up
    // staring at AuthRootView even though they were happily signed in).
    // `.ignore()` swallows the propagation on this secondary future
    // while the original `future` we return below still surfaces the
    // error to the caller's catch.
    future.whenComplete(() => _inflight.remove(url)).ignore();
    return future;
  }

  Future<Uint8List> _load(String url) async {
    // file:// — local artifact (downloaded by JobStatusWatcher into the
    // app docs dir). Read straight from disk; don't double-cache to
    // /tmp because the source IS the durable store.
    if (url.startsWith('file://')) {
      final path = Uri.parse(url).toFilePath();
      final f = File(path);
      if (!await f.exists()) {
        throw StateError('Local .glb missing at $path');
      }
      final bytes = await f.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('Empty local .glb at $path');
      }
      _mem[url] = bytes;
      return bytes;
    }
    final file = await _diskFile(url);
    if (await file.exists()) {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _mem[url] = bytes;
          return bytes;
        }
      } catch (_) {/* corrupt cache → fall through to redownload */}
    }
    final res = await _dio.get<List<int>>(url);
    final bytes = Uint8List.fromList(res.data ?? const <int>[]);
    if (bytes.isEmpty) {
      throw StateError('Empty .glb response for $url');
    }
    _mem[url] = bytes;
    // Persist async — failure to write disk cache must not break load.
    unawaited(_persist(file, bytes));
    return bytes;
  }

  Future<File> _diskFile(String url) async {
    final dir = await getTemporaryDirectory();
    final hash = sha1.convert(utf8.encode(url)).toString();
    return File('${dir.path}/glb_cache/$hash.glb');
  }

  Future<void> _persist(File file, Uint8List bytes) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: false);
    } catch (_) {/* best-effort */}
  }
}
