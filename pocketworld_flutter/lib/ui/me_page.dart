// MePage — minimal "个人 / Me" tab. Only the user's account card and
// their own works grid live here; everything secondary (notifications,
// privacy, language, about, sign-out) sits behind the gear icon at the
// top-left, which pushes MeSettingsPage.

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/auth_scope.dart';
import '../i18n/relative_time.dart';
import '../l10n/app_localizations.dart';
import '../me/my_works_sync_service.dart';
import '../me/scan_record_store.dart';
import '../me/upload_coordinator.dart';
import 'design_system.dart';
import 'home_view_model.dart';
import 'me/my_work_detail_page.dart';
import 'me_settings_page.dart';
import 'me_stats_view_model.dart';
import 'scan_record.dart';
import 'scan_record_cell.dart';

class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  // Lives on the parent so MeSettingsPage receives the same instance and
  // doesn't have to re-fetch profiles / notification_settings every time
  // it's pushed.
  final MeStatsViewModel _stats = MeStatsViewModel();

  @override
  void initState() {
    super.initState();
    _stats.load();
    // Fire-and-forget: pull whatever the user has published from the
    // cloud into the local store on first paint of the Me tab. Without
    // this, accounts that published from another device (or had works
    // seeded into Supabase by tooling) show an empty grid until the
    // user discovers the pull-to-refresh gesture. Failures are silent —
    // the user can still pull-to-refresh manually for a snackbar.
    unawaited(MyWorksSyncService.instance.refreshFromCloud().catchError(
      (Object e, StackTrace s) {
        debugPrint('[MePage] auto-sync failed: $e\n$s');
        return 0;
      },
    ));
  }

  @override
  void dispose() {
    _stats.dispose();
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MeSettingsPage(stats: _stats),
    ));
  }

  Future<void> _onRefresh() async {
    final l = AppL10n.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final added = await MyWorksSyncService.instance.refreshFromCloud();
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(added > 0
            ? l.meSyncAddedWorks(added)
            : l.meSyncUpToDate),
        behavior: SnackBarBehavior.floating,
      ));
      // While we're at it, refresh notif/privacy too — cheap and keeps
      // the settings page consistent.
      await _stats.load();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('${l.meSyncFailed}: $e'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    // 2026-04-28: defensive — in release builds, AuthScope.of's null assert
    // is stripped, so reading via the inherited widget directly + null
    // guard avoids tearing down the IndexedStack when AuthScope hasn't
    // been plumbed through yet.
    final scope = context.dependOnInheritedWidgetOfExactType<AuthScope>();
    final currentUser = scope?.notifier;
    final user = currentUser?.signedInUser;
    final l = AppL10n.of(context);
    if (user == null) {
      return Scaffold(
        backgroundColor: AetherColors.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              l.splashRestoringSession,
              textAlign: TextAlign.center,
              style: AetherTextStyles.caption,
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: AetherColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _onRefresh,
          color: AetherColors.primary,
          backgroundColor: AetherColors.bgCanvas,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(
              parent: BouncingScrollPhysics(),
            ),
            padding: const EdgeInsets.fromLTRB(
              AetherSpacing.lg,
              AetherSpacing.md,
              AetherSpacing.lg,
              140,
            ),
            children: [
            SizedBox(
              height: 56,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Text(l.appBrand, style: AetherTextStyles.wordmark),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      color: AetherColors.textPrimary,
                      tooltip: l.meSettingsTitle,
                      onPressed: _openSettings,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AetherSpacing.lg),
            DesignBox(
              kind: DesignKind.backendNeeded,
              label: '用户卡',
              child: _ProfileCard(user: user),
            ),
            const SizedBox(height: AetherSpacing.xl),
            const DesignBox(
              kind: DesignKind.partial,
              label: '我的作品',
              child: _MyWorksSection(),
            ),
          ],
          ),
        ),
      ),
    );
  }
}

/// 2-column waterfall of the user's own ScanRecords. No bundled samples
/// and no author handle — this section is implicitly "yours."
class _MyWorksSection extends StatefulWidget {
  const _MyWorksSection();

  @override
  State<_MyWorksSection> createState() => _MyWorksSectionState();
}

class _MyWorksSectionState extends State<_MyWorksSection> {
  final HomeViewModel _vm = HomeViewModel();

  @override
  void initState() {
    super.initState();
    _vm.addListener(_rebuild);
    _vm.loadRecords();
  }

  @override
  void dispose() {
    _vm.removeListener(_rebuild);
    _vm.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // _vm.loadRecords subscribes to ScanRecordStore.changes and notifies
    // us, so reading the store directly here stays in sync.
    final mine = ScanRecordStore.instance.records;
    if (mine.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AetherSpacing.lg),
        child: Text(
          l.meMyWorksEmpty,
          textAlign: TextAlign.center,
          style: AetherTextStyles.bodySm,
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _MyWorksColumn(
            records: [
              for (int i = 0; i < mine.length; i++)
                if (i.isEven) mine[i],
            ],
            isLeft: true,
            vm: _vm,
            onTap: _onTap,
            onLongPress: _confirmDelete,
          ),
        ),
        const SizedBox(width: AetherSpacing.lg),
        Expanded(
          child: _MyWorksColumn(
            records: [
              for (int i = 0; i < mine.length; i++)
                if (i.isOdd) mine[i],
            ],
            isLeft: false,
            vm: _vm,
            onTap: _onTap,
            onLongPress: _confirmDelete,
          ),
        ),
      ],
    );
  }

  void _onTap(ScanRecord record) {
    // The detail page only renders when there's a viewable artifact
    // (artifactPath != null). For everything else — in-flight,
    // failed, cancelled, or queued — show a contextual SnackBar
    // instead of pushing an empty detail page that just shows
    // "Processing failed". The recovery path for failed scans is
    // long-press → 重新上传素材, which the existing menu surfaces.
    if (record.artifactPath == null) {
      final l = AppL10n.of(context);
      final status = record.jobStatus;
      final hint = (status?.isRunning ?? false)
          ? l.meTapHintInProgress
          : l.meTapHintTapToRetry;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(hint),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MyWorkDetailPage(recordId: record.id),
    ));
  }

  /// Long-press handler — opens a bottom sheet with up to three actions
  /// (改名 / 重新上传素材 / 删除). Polycam-style. The sheet itself isn't a
  /// destructive surface; the destructive 删除 still triggers a follow-up
  /// confirmation dialog so a stray hold doesn't nuke a scan in one tap.
  /// 重新上传素材 is only shown when the record's upload failed AND the
  /// persisted .mov + curated.json are still on disk (the prep was far
  /// enough along to save them).
  Future<void> _confirmDelete(ScanRecord record) async {
    // Check retry availability up-front so we know whether to render
    // the row. Async, but very fast — two File.exists() calls.
    final canRetry =
        await UploadCoordinator.instance.canRetry(record.id);
    if (!mounted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AetherColors.bgCanvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('改名'),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            if (canRetry)
              ListTile(
                leading: const Icon(Icons.cloud_upload_outlined),
                title: const Text('重新上传素材'),
                onTap: () => Navigator.of(ctx).pop('retry'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: AetherColors.danger),
              title: const Text('删除',
                  style: TextStyle(color: AetherColors.danger)),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'rename') {
      await _renameRecord(record);
    } else if (action == 'retry') {
      await _retryUpload(record);
    } else if (action == 'delete') {
      await _confirmAndDelete(record);
    }
  }

  Future<void> _renameRecord(ScanRecord record) async {
    final controller = TextEditingController(text: record.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('改名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == record.name) return;
    await ScanRecordStore.instance
        .addOrUpdate(record.copyWith(name: newName));
  }

  /// Re-run the upload for [record] from the persisted .mov + curated.json.
  /// Surface success/failure via SnackBar; the card itself updates
  /// reactively because UploadCoordinator.retry() flips the record's
  /// status back to uploading and the gallery rebuilds on store change.
  Future<void> _retryUpload(ScanRecord record) async {
    try {
      await UploadCoordinator.instance.retry(record.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已开始重新上传'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('重新上传失败: $e'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _confirmAndDelete(ScanRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这次扫描?'),
        content: Text('"${record.name}" 将从你的作品里移除。'
            '已发布到社区的内容不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AetherColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _vm.deleteRecord(record);
  }
}

class _MyWorksColumn extends StatelessWidget {
  final List<ScanRecord> records;
  final bool isLeft;
  final HomeViewModel vm;
  final void Function(ScanRecord) onTap;
  final void Function(ScanRecord) onLongPress;

  const _MyWorksColumn({
    required this.records,
    required this.isLeft,
    required this.vm,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Column(
      children: [
        for (int i = 0; i < records.length; i++) ...[
          ScanRecordCell(
            record: records[i],
            subtitle: _subtitleFor(l, records[i]),
            imageHeight: vm.imageHeightFor(
              positionInColumn: i,
              isLeft: isLeft,
            ),
            onTap: () => onTap(records[i]),
            onLongPress: () => onLongPress(records[i]),
          ),
          if (i < records.length - 1)
            const SizedBox(height: AetherSpacing.lg),
        ],
      ],
    );
  }

  String _subtitleFor(AppL10n l, ScanRecord r) {
    final relative = formatRelativeTime(l, r.createdAt);
    if (r.jobStatus != null) {
      return '$relative · ${r.localizedLifecycleTitle(l)}';
    }
    return relative;
  }
}

class _ProfileCard extends StatelessWidget {
  final AuthenticatedUser? user;

  const _ProfileCard({required this.user});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Container(
      padding: const EdgeInsets.all(AetherSpacing.lg),
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas,
        borderRadius: BorderRadius.circular(AetherRadii.xl),
        boxShadow: [
          BoxShadow(
            color: AetherColors.shadow,
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: AetherColors.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              _initialFor(user),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: AetherSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user?.displayName ?? user?.email ?? '—',
                  style: AetherTextStyles.h2,
                ),
                const SizedBox(height: 2),
                Text(
                  user?.email ?? user?.phone ?? '',
                  style: AetherTextStyles.bodySm,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AetherSpacing.md,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: AetherColors.bgElevated,
              borderRadius: BorderRadius.circular(AetherRadii.pill),
              border: Border.all(color: AetherColors.border),
            ),
            child: Text(
              l.meEdit,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AetherColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _initialFor(AuthenticatedUser? user) {
  if (user == null) return 'A';
  final source = user.displayName?.trim().isNotEmpty == true
      ? user.displayName!
      : user.email ?? user.phone ?? 'A';
  final trimmed = source.trim();
  if (trimmed.isEmpty) return 'A';
  final first = trimmed.runes.first;
  return String.fromCharCode(first).toUpperCase();
}
