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

  /// Variant of [fetch] that returns the on-disk path instead of the
  /// bytes. Required by the aether_cpp scene renderer path (cgltf
  /// uses fopen/fread inside `cgltf_parse_file`; it can't accept an
  /// HTTPS URL or an in-memory buffer through that entry point). The
  /// thermion path doesn't use this — it consumes the Uint8List
  /// directly via `loadGltfFromBuffer`.
  ///
  /// For `file://` URLs returns the local path immediately. For
  /// HTTPS URLs ensures bytes are downloaded + persisted to disk
  /// (re-using fetch's mem + disk caches) and returns the disk path.
  Future<String> fetchPath(String url) async {
    if (url.startsWith('file://')) {
      return Uri.parse(url).toFilePath();
    }
    // Force a fetch so the bytes are guaranteed to have been written
    // to disk by _persist(). _persist is fire-and-forget though, so
    // we ALSO check existence + write synchronously here if needed —
    // a race where fetch returned bytes but _persist hasn't completed
    // yet would otherwise hand cgltf an empty file.
    await fetch(url);
    final file = await _diskFile(url);
    if (!await file.exists()) {
      // _persist hasn't finished; do it synchronously so cgltf finds
      // the file on its first fopen call.
      final bytes = _mem[url];
      if (bytes == null) {
        throw StateError('GlbCache.fetchPath: bytes vanished mid-fetch');
      }
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
    }
    return file.path;
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
    // Preserve the source URL's extension so the native loader sees a
    // sensible file name. Originally this hardcoded `.glb` (when the
    // cache only held GLB), but Phase 6.4f routes PLY/SPZ through here
    // too. The native spz parser uses extension as a hint for which
    // decoder to invoke when both PLY and SPZ are accepted, and the
    // log line `load_spz: parse/decode failed status=-1 path='...glb'`
    // is exactly that hint going wrong.
    final ext = _extensionForUrl(url);
    return File('${dir.path}/glb_cache/$hash$ext');
  }

  /// Extract the file extension (e.g. `.spz`, `.ply`, `.glb`) from a
  /// URL, stripping any query string / fragment. Falls back to `.glb`
  /// for legacy compatibility with the cache's original purpose.
  String _extensionForUrl(String url) {
    final lower = url.toLowerCase();
    final qIdx = lower.indexOf('?');
    final hashIdx = lower.indexOf('#');
    final cut = [qIdx, hashIdx]
        .where((i) => i >= 0)
        .fold<int>(lower.length, (a, b) => a < b ? a : b);
    final path = lower.substring(0, cut);
    for (final ext in const ['.spz', '.ply', '.gltf', '.splat', '.glb']) {
      if (path.endsWith(ext)) return ext;
    }
    return '.glb';
  }

  Future<void> _persist(File file, Uint8List bytes) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: false);
    } catch (_) {/* best-effort */}
  }
}
