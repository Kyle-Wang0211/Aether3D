// MePage — minimal "个人 / Me" tab. Only the user's account card and
// their own works grid live here; everything secondary (notifications,
// privacy, language, about, sign-out) sits behind the gear icon at the
// top-left, which pushes MeSettingsPage.

import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/auth_scope.dart';
import '../i18n/relative_time.dart';
import '../l10n/app_localizations.dart';
import '../me/scan_record_store.dart';
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
        child: ListView(
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
          ),
        ),
      ],
    );
  }

  void _onTap(ScanRecord record) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MyWorkDetailPage(recordId: record.id),
    ));
  }
}

class _MyWorksColumn extends StatelessWidget {
  final List<ScanRecord> records;
  final bool isLeft;
  final HomeViewModel vm;
  final void Function(ScanRecord) onTap;

  const _MyWorksColumn({
    required this.records,
    required this.isLeft,
    required this.vm,
    required this.onTap,
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
