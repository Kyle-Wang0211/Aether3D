// HomeViewModel — Flutter port of the prototype's HomeViewModel.
//
// Currently returns 6 stub ScanRecords covering the main lifecycle
// states (training / uploading / packaging / failed / completed) so the
// vault page's waterfall flow looks real while there's no backend yet.
// When a real scan record store lands, swap the `_seed()` call for an
// actual data source — the ChangeNotifier contract stays the same.

import 'package:flutter/foundation.dart';

import 'scan_record.dart';

class HomeViewModel extends ChangeNotifier {
  List<ScanRecord> _records = const [];
  bool _loading = false;

  List<ScanRecord> get scanRecords => _records;
  bool get isLoading => _loading;

  int get runningCount => _records.where((r) => r.isRunningTask).length;
  int get attentionCount => _records.where((r) => r.needsAttention).length;

  /// Left / right columns in the waterfall gallery. Even indices go
  /// left, odd go right — mirrors HomePage.swift's leftColumnRecords /
  /// rightColumnRecords partition.
  List<ScanRecord> get leftColumnRecords => [
        for (int i = 0; i < _records.length; i++)
          if (i.isEven) _records[i],
      ];
  List<ScanRecord> get rightColumnRecords => [
        for (int i = 0; i < _records.length; i++)
          if (i.isOdd) _records[i],
      ];

  /// Height pattern for thumbnails, reused per-column, mirrors the
  /// prototype. Produces varied but deterministic card heights so the
  /// waterfall reads as "curated" rather than random.
  static const List<double> leftHeights = [208, 260, 168, 224];
  static const List<double> rightHeights = [236, 196, 304, 212];

  double imageHeightFor({required int positionInColumn, required bool isLeft}) {
    final pattern = isLeft ? leftHeights : rightHeights;
    return pattern[positionInColumn % pattern.length];
  }

  Future<void> loadRecords() async {
    _loading = true;
    notifyListeners();
    // Yield once so the loading indicator can paint before the seed
    // pops in — avoids a single-frame "no loader ever shown" flicker
    // when the seed data is synchronous. Use a microtask (not
    // Future.delayed) so flutter_test doesn't see a pending Timer at
    // tear-down.
    await Future<void>.microtask(() {});
    _records = _seed();
    _loading = false;
    notifyListeners();
  }

  /// Delete a record (local only for the placeholder build — no backend
  /// delete request, no undo). Prototype uses this from the context menu
  /// on each card; we keep the API shape so the vault page wiring stays.
  void deleteRecord(ScanRecord record) {
    _records = [
      for (final r in _records) if (r.id != record.id) r,
    ];
    notifyListeners();
  }

  /// Human-readable relative time. Simplified vs the prototype's
  /// RelativeDateTimeFormatter output; enough for the placeholder.
  String relativeTimeString(DateTime createdAt) {
    final now = DateTime.now();
    final diff = now.difference(createdAt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()} 周前';
    return '${(diff.inDays / 30).floor()} 个月前';
  }

  /// Sample card IDs that resolve to bundled GLB assets shipped with the
  /// app. VaultPage taps on these IDs route to the Dawn/Filament PBR
  /// viewer with the corresponding GLB pre-loaded. Real cloud-backed
  /// records will eventually use `artifactPath` instead.
  static const String sampleHelmetId = 'sample-helmet';

  List<ScanRecord> _seed() {
    final now = DateTime.now();
    return [
      // ───── Sample bundled GLB cards (tap-to-view 3D) ────────────────
      ScanRecord(
        id: sampleHelmetId,
        name: 'Damaged Helmet · Battle Worn',
        createdAt: now.subtract(const Duration(minutes: 7)),
        authorHandle: '@kyle',
        caption:
            'PBR sample · scratched plate metal, baked AO, IBL specular. Dawn + Filament reference.',
        preferredCaptureMode: CaptureMode.local,
        artifactPath: 'asset://models/DamagedHelmet.glb',
        bundledGlbAsset: 'DamagedHelmet.glb',
      ),
      ScanRecord(
        id: 'sample-avocado',
        name: 'Hass Avocado',
        createdAt: now.subtract(const Duration(minutes: 38)),
        authorHandle: '@studio.lin',
        caption:
            'Single avocado, 360° turntable capture · subsurface sheen + bumpy peel preserved.',
        preferredCaptureMode: CaptureMode.newRemote,
        artifactPath: 'asset://models/Avocado.glb',
        bundledGlbAsset: 'Avocado.glb',
      ),
      ScanRecord(
        id: 'sample-boombox',
        name: 'Vintage Boombox',
        createdAt: now.subtract(const Duration(hours: 2, minutes: 12)),
        authorHandle: '@ana.morales',
        caption:
            'Found at a Brooklyn flea market — chrome dials, dual cassette, label paint chipping.',
        preferredCaptureMode: CaptureMode.newRemote,
        artifactPath: 'asset://models/BoomBox.glb',
        bundledGlbAsset: 'BoomBox.glb',
      ),
      ScanRecord(
        id: 'sample-waterbottle',
        name: 'Hiking Bottle',
        createdAt: now.subtract(const Duration(hours: 5, minutes: 41)),
        authorHandle: '@trail.dust',
        caption:
            'Anodized aluminum, brushed cap. Caught the morning light just right.',
        preferredCaptureMode: CaptureMode.local,
        artifactPath: 'asset://models/WaterBottle.glb',
        bundledGlbAsset: 'WaterBottle.glb',
      ),
      ScanRecord(
        id: 'sample-duck',
        name: 'Rubber Duck',
        createdAt: now.subtract(const Duration(hours: 9)),
        authorHandle: '@tofu',
        caption:
            'Bath time mascot. Very smooth, very yellow, mildly judgmental.',
        preferredCaptureMode: CaptureMode.local,
        artifactPath: 'asset://models/Duck.glb',
        bundledGlbAsset: 'Duck.glb',
      ),
      ScanRecord(
        id: 'sample-lantern',
        name: 'Garden Lantern',
        createdAt: now.subtract(const Duration(days: 1, hours: 4)),
        authorHandle: '@nakamura.h',
        caption:
            'Cast iron lantern from a garden in Kyoto, shot at golden hour. Frosted glass + vine details.',
        preferredCaptureMode: CaptureMode.newRemote,
        artifactPath: 'asset://models/Lantern.glb',
        bundledGlbAsset: 'Lantern.glb',
      ),
      // ───── In-flight / training cards (no preview yet) ──────────────
      ScanRecord(
        id: 'r-training-1',
        name: 'Concrete Bench, Riverside Park',
        createdAt: now.subtract(const Duration(minutes: 22)),
        authorHandle: '@aviva',
        caption:
            'First scan after the latest pipeline update. Curious to see how moss reads in PBR.',
        jobStatus: ScanJobStatus.training,
        pipelineStage: 'Training · 240 / 400 steps',
        preferredCaptureMode: CaptureMode.newRemote,
      ),
      ScanRecord(
        id: 'r-uploading',
        name: 'Studio Plant',
        createdAt: now.subtract(const Duration(minutes: 49)),
        authorHandle: '@maya.r',
        caption:
            'Monstera leaf veins are ridiculously hard to capture, fingers crossed.',
        jobStatus: ScanJobStatus.uploading,
        pipelineStage: 'Uploading · 23%',
        preferredCaptureMode: CaptureMode.newRemote,
      ),
      ScanRecord(
        id: 'r-failed',
        name: 'Sketch from last night',
        createdAt: now.subtract(const Duration(hours: 11)),
        authorHandle: '@kyle',
        caption: 'Dimly lit pencil sketch — fully expected this to fail.',
        jobStatus: ScanJobStatus.failed,
        failureMessage:
            'Lighting too low — model failed to converge after 320 steps.',
        preferredCaptureMode: CaptureMode.newRemote,
      ),
      ScanRecord(
        id: 'r-packaging',
        name: 'Park Bench at Dusk',
        createdAt: now.subtract(const Duration(days: 1, hours: 8)),
        authorHandle: '@ej.collins',
        caption:
            'Side bench on the loop trail. Wood grain finally readable in v6.4e.',
        jobStatus: ScanJobStatus.packaging,
        pipelineStage: 'Exporting · 92%',
        preferredCaptureMode: CaptureMode.remoteLegacy,
      ),
    ];
  }
}
