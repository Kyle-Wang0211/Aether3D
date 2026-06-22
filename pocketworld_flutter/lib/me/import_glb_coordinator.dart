// ImportGlbCoordinator — process-lifetime singleton that owns in-flight
// "导入 GLB 模型" runs. Mirrors UploadCoordinator's lifecycle pattern so
// the user can leave MePage mid-import and the gallery card keeps
// updating.
//
// Flow per import:
//   1. [start] persists a placeholder ScanRecord with
//      jobStatus = ScanJobStatus.reconstructing IMMEDIATELY (no async
//      gap), so MePage's grid renders a card on the same frame as the
//      file picker close. Re-using the existing `reconstructing` enum
//      avoids touching the cross-locale ScanJobStatus model — the
//      visible label "正在生成 3D 模型" / "Training" is generic enough
//      to cover the on-device normalize step.
//   2. [_runImport] reads the GLB bytes off disk, hands them to
//      [GlbNormalizer.normalize] which transfers the input to a worker
//      isolate via TransferableTypedData and never blocks the UI.
//   3. On result.isOk we write the normalized bytes to
//      `app_documents/scans/{id}.glb` and flip the record:
//        clearJobStatus + artifactPath = file://...
//      → the grid card transitions to "已完成" and the tap handler
//      pushes MyWorkDetailPage which already renders any
//      `file://*.glb` via AetherCppCardDemo.
//   4. On any failure we set jobStatus = ScanJobStatus.failed +
//      failureMessage so MyWorkDetailPage's _FailedState shows the
//      reason.
//
// Thread / isolate model:
//   • Bytes read happens on the UI isolate (await readAsBytes — fast,
//     non-blocking).
//   • normalize() handles its own worker isolate internally (Phase 5
//     contract); progress callbacks fire on the UI isolate.
//   • File write on success is `await writeAsBytes` on the UI isolate,
//     which is fine — output GLBs are typically a few hundred KB to a
//     few MB, well under the 4 ms frame budget.
//
// Lifetime guarantee:
//   In-flight imports survive route changes / tab switches because the
//   StreamController + record persistence live on this singleton, NOT
//   on MePage state. They DO NOT survive a process kill — there is no
//   server-side resume here. If the user kills the app mid-import the
//   ScanRecord is left at jobStatus=reconstructing with no jobId and
//   the only way out is a manual delete via long-press → 删除. This is
//   acceptable for v1: imports are typically <1 s for the GLB sizes
//   we expect (Polycam exports are 5-50 MB; the slowest path is the
//   500K-face decimation cap which finishes well inside 5 s on iPhone
//   12-class hardware).
//
// TODO(server-upload-followup): broker-side support for direct GLB
//   uploads is out of scope for Phase 6. When it lands, this
//   coordinator should hand the normalized bytes to a new
//   CaptureUploader.uploadGlbDirect(...) so imported models appear in
//   the user's cloud gallery cross-device. Until then imports stay
//   local-only — the user can re-import on each device manually.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../glb_norm/glb_norm.dart';
import '../ui/scan_record.dart';
import 'scan_record_store.dart';

/// One progress event from an in-flight GLB import.
///
/// `phase` is one of:
///   • 'reading'      — input bytes being read from the picked file
///   • 'normalizing'  — inside [GlbNormalizer.normalize]
///   • 'persisting'   — writing normalized bytes to scans/{id}.glb
///   • 'done'         — terminal success
///   • 'failed'       — terminal failure
@immutable
class ImportProgress {
  final String phase;

  /// Monotonically non-decreasing 0..1.
  final double fraction;

  /// Optional human-readable detail. During the 'normalizing' phase
  /// this carries the C-side phase string ("parsing", "packing atlas",
  /// "decimating mesh", "encoding glb"). Null otherwise.
  final String? detail;

  const ImportProgress({
    required this.phase,
    required this.fraction,
    this.detail,
  });

  @override
  String toString() =>
      'ImportProgress($phase, ${(fraction * 100).toStringAsFixed(1)}%'
      '${detail == null ? '' : ', $detail'})';
}

class _ActiveImport {
  final StreamController<ImportProgress> ctrl;
  ImportProgress? lastProgress;
  _ActiveImport(this.ctrl);
}

class ImportGlbCoordinator {
  ImportGlbCoordinator._();
  static final ImportGlbCoordinator instance = ImportGlbCoordinator._();

  final ScanRecordStore _store = ScanRecordStore.instance;

  /// Active imports keyed by record id.
  final Map<String, _ActiveImport> _active = <String, _ActiveImport>{};

  /// Kick off an import. Returns the new local record id synchronously
  /// so callers can pass it to [progressStreamFor] in the same frame.
  ///
  /// [name] defaults to the file's basename without extension; pass a
  /// non-null override to use something else (e.g. the user typed a
  /// name in a dialog before picking the file).
  String start({required File glbFile, String? name}) {
    final now = DateTime.now();
    final recordId = 'import-${now.microsecondsSinceEpoch}';
    final defaultName = name ?? _basenameNoExt(glbFile.path);

    final record = ScanRecord(
      id: recordId,
      name: defaultName.isEmpty ? '导入的模型' : defaultName,
      createdAt: now,
      jobStatus: ScanJobStatus.reconstructing,
    );
    // Fire-and-forget — store writes are serialized internally and
    // failure (disk full / IO error) shouldn't block the import.
    unawaited(_store.addOrUpdate(record));

    final ctrl = StreamController<ImportProgress>.broadcast();
    final active = _ActiveImport(ctrl);
    _active[recordId] = active;

    const initial = ImportProgress(
      phase: 'reading',
      fraction: 0.0,
      detail: '读取文件',
    );
    active.lastProgress = initial;
    ctrl.add(initial);

    unawaited(_runImport(recordId: recordId, glbFile: glbFile));

    // ignore: avoid_print
    print('[ImportGlbCoordinator] $recordId started '
        '(file=${glbFile.path}, name="${record.name}")');
    return recordId;
  }

  /// Live progress events for [recordId]. Returns null if no import is
  /// currently active for that id (already finished, failed, or never
  /// started here). The returned stream is broadcast and replays the
  /// most recent event so a card mounted mid-import sees current state.
  Stream<ImportProgress>? progressStreamFor(String recordId) {
    final active = _active[recordId];
    if (active == null) return null;
    final last = active.lastProgress;
    if (last == null) return active.ctrl.stream;
    final replay = StreamController<ImportProgress>.broadcast();
    replay.add(last);
    final passthrough = active.ctrl.stream.listen(
      replay.add,
      onError: replay.addError,
      onDone: replay.close,
    );
    replay.onCancel = () => passthrough.cancel();
    return replay.stream;
  }

  /// True iff there's an in-flight import for [recordId].
  bool isActive(String recordId) => _active.containsKey(recordId);

  Future<void> _runImport({
    required String recordId,
    required File glbFile,
  }) async {
    final active = _active[recordId];
    if (active == null) return;

    var terminal = false;
    try {
      // 1) read input bytes
      _emit(active, const ImportProgress(
        phase: 'reading',
        fraction: 0.05,
        detail: '读取文件',
      ));
      if (!await glbFile.exists()) {
        throw StateError('selected file no longer exists: ${glbFile.path}');
      }
      final bytes = await glbFile.readAsBytes();
      if (bytes.isEmpty) {
        throw StateError('selected file is empty');
      }

      // 2) normalize on worker isolate
      _emit(active, const ImportProgress(
        phase: 'normalizing',
        fraction: 0.1,
        detail: '准备处理',
      ));
      final result = await GlbNormalizer.normalize(
        input: bytes,
        onProgress: (fraction, phase) {
          // Native fraction is 0..1 across the full normalize step; map
          // into [0.10, 0.90] so the bar leaves headroom for read +
          // persist before / after.
          final mapped = 0.10 + 0.80 * fraction.clamp(0.0, 1.0);
          _emit(active, ImportProgress(
            phase: 'normalizing',
            fraction: mapped,
            detail: phase.isEmpty ? null : phase,
          ));
        },
      );

      if (!result.isOk) {
        final reason = result.error ??
            'normalize failed (status=${result.status.name})';
        await _failRecord(recordId: recordId, message: '导入失败: $reason');
        _emit(active, ImportProgress(
          phase: 'failed',
          fraction: 1.0,
          detail: reason,
        ));
        terminal = true;
        return;
      }

      // 3) persist normalized GLB
      _emit(active, const ImportProgress(
        phase: 'persisting',
        fraction: 0.92,
        detail: '保存到本地',
      ));
      final outFile = await _store.glbFileFor(recordId);
      await outFile.writeAsBytes(result.output!, flush: true);

      // 4) promote record: clear running status + set artifactPath.
      //    MyWorkDetailPage's "viewable" branch fires when jobStatus is
      //    null and artifactPath is non-null.
      final cur = _store.byId(recordId);
      if (cur != null) {
        await _store.addOrUpdate(cur.copyWith(
          clearJobStatus: true,
          clearFailureMessage: true,
          artifactPath: 'file://${outFile.path}',
        ));
      }

      _emit(active, const ImportProgress(
        phase: 'done',
        fraction: 1.0,
      ));
      terminal = true;
      // ignore: avoid_print
      print('[ImportGlbCoordinator] $recordId done — ${result.stats}');
    } catch (e, st) {
      debugPrint('[ImportGlbCoordinator] $recordId failed: $e\n$st');
      await _failRecord(recordId: recordId, message: '导入失败: $e');
      _emit(active, ImportProgress(
        phase: 'failed',
        fraction: 1.0,
        detail: e.toString(),
      ));
      terminal = true;
    } finally {
      if (terminal) {
        final still = _active.remove(recordId);
        if (still != null && !still.ctrl.isClosed) {
          await still.ctrl.close();
        }
      }
    }
  }

  void _emit(_ActiveImport active, ImportProgress p) {
    active.lastProgress = p;
    if (!active.ctrl.isClosed) active.ctrl.add(p);
  }

  Future<void> _failRecord({
    required String recordId,
    required String message,
  }) async {
    final cur = _store.byId(recordId);
    if (cur == null) return;
    await _store.addOrUpdate(cur.copyWith(
      jobStatus: ScanJobStatus.failed,
      failureMessage: message,
    ));
  }

  static String _basenameNoExt(String path) {
    final slash = path.lastIndexOf(Platform.pathSeparator);
    final altSlash = path.lastIndexOf('/');
    final cut = slash > altSlash ? slash : altSlash;
    final name = cut >= 0 ? path.substring(cut + 1) : path;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }
}
