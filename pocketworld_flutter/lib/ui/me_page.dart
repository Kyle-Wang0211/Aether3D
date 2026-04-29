// MePage — minimal "个人 / Me" tab. Account + settings + sign-out.
//
// All user-visible strings come from AppL10n (lib/l10n/*.arb). The
// "语言 / Language" row pushes a dialog that flips LocaleNotifier; the
// whole MaterialApp rebuilds on that flip via main.dart's
// AnimatedBuilder.

import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/auth_scope.dart';
import '../i18n/locale_notifier.dart';
import '../i18n/relative_time.dart';
import '../l10n/app_localizations.dart';
import 'capture_page.dart';
import 'design_system.dart';
import 'home_view_model.dart';
import 'scan_record.dart';
import 'scan_record_cell.dart';

/// IG-style profile owner handle. In production, this is the signed-in
/// user's @handle. The mock data uses '@kyle' for own works so the
/// "My works" grid resolves the right cards. Records with no
/// authorHandle are also treated as own (legacy mock seeds).
const String kCurrentUserHandle = '@kyle';

class MePage extends StatelessWidget {
  /// Wired from AppShell so the "My works" grid can hand off to the
  /// shared Dawn viewer (same builder VaultPage uses).
  final CapturePageBuilder? capturePageBuilder;

  const MePage({super.key, this.capturePageBuilder});

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
              child: Center(
                child: Text(l.appBrand, style: AetherTextStyles.wordmark),
              ),
            ),
            const SizedBox(height: AetherSpacing.lg),
            DesignBox(
              kind: DesignKind.backendNeeded,
              label: '用户卡',
              child: _ProfileCard(user: user),
            ),
            const SizedBox(height: AetherSpacing.xl),
            DesignBox(
              kind: DesignKind.customizable,
              label: '设置',
              child: const _SettingsSection(),
            ),
            const SizedBox(height: AetherSpacing.xl),
            DesignBox(
              kind: DesignKind.partial,
              label: '我的作品',
              child: _MyWorksSection(capturePageBuilder: capturePageBuilder),
            ),
            const SizedBox(height: AetherSpacing.xl),
            DesignBox(
              kind: DesignKind.backendNeeded,
              label: '退出登录',
              child: const _SignOutButton(),
            ),
          ],
        ),
      ),
    );
  }
}

/// IG-like "my works" section — title row + 2-column grid of the
/// current user's ScanRecords. Re-uses the same ScanRecordCell as the
/// community feed for visual consistency.
class _MyWorksSection extends StatefulWidget {
  final CapturePageBuilder? capturePageBuilder;

  const _MyWorksSection({required this.capturePageBuilder});

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
    final mine = _vm.scanRecords
        .where((r) =>
            r.authorHandle == null || r.authorHandle == kCurrentUserHandle)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: AetherSpacing.md),
          child: Text(l.meMyWorks, style: AetherTextStyles.h2),
        ),
        if (mine.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AetherSpacing.lg),
            child: Text(
              l.meMyWorksEmpty,
              textAlign: TextAlign.center,
              style: AetherTextStyles.bodySm,
            ),
          )
        else
          Row(
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
          ),
      ],
    );
  }

  void _onTap(ScanRecord record) {
    final builder = widget.capturePageBuilder;
    if (builder != null && record.bundledGlbAsset != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (ctx) => builder(
            ctx,
            CaptureMode.local,
            viewerMode: true,
            viewerTitle: record.name,
            viewerGlbAsset: record.bundledGlbAsset,
          ),
        ),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppL10n.of(context).scanRecordOpenPlaceholder(record.name),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
      return l.communityRecordSubtitleWithStatus(
        r.authorHandle ?? 'You',
        relative,
        r.localizedLifecycleTitle(l),
      );
    }
    return l.communityRecordSubtitle(r.authorHandle ?? 'You', relative);
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
      child: Column(
        children: [
          Row(
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
          const SizedBox(height: AetherSpacing.lg),
          const Divider(height: 1, color: AetherColors.border),
          const SizedBox(height: AetherSpacing.lg),
          Row(
            children: [
              _StatCell(value: '8', label: l.meWorks),
              const _StatDivider(),
              _StatCell(value: '3', label: l.meRunning),
              const _StatDivider(),
              _StatCell(value: '3', label: l.meRemainingCloudTrainings),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCell extends StatelessWidget {
  final String value;
  final String label;

  const _StatCell({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AetherColors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: AetherTextStyles.caption),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 24, color: AetherColors.border);
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final localeNotifier = LocaleScope.of(context);
    final isZh = localeNotifier.isChinese;
    final rows = <_SettingsRowSpec>[
      _SettingsRowSpec(
        icon: Icons.cloud_sync_outlined,
        title: l.meCloudSync,
        trailing: l.meCloudSyncSubtitle(l.relativeMinutesAgo(12)),
        onTap: null,
      ),
      _SettingsRowSpec(
        icon: Icons.model_training_outlined,
        title: l.meCloudTraining,
        trailing: l.meCloudTrainingRemaining(3),
        onTap: null,
      ),
      _SettingsRowSpec(
        icon: Icons.notifications_none_rounded,
        title: l.meNotifications,
        trailing: l.meNotificationsOn,
        onTap: null,
      ),
      _SettingsRowSpec(
        icon: Icons.lock_outline_rounded,
        title: l.mePrivacy,
        trailing: l.mePrivacyFollowersOnly,
        onTap: null,
      ),
      _SettingsRowSpec(
        icon: Icons.language_rounded,
        title: l.meLanguage,
        trailing: isZh ? l.meLanguageZh : l.meLanguageEn,
        onTap: () => _showLanguageDialog(context, localeNotifier),
      ),
      _SettingsRowSpec(
        icon: Icons.info_outline_rounded,
        title: l.meAbout,
        trailing: 'v6.4e · Phase 6',
        onTap: null,
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas,
        borderRadius: BorderRadius.circular(AetherRadii.xl),
        border: Border.all(color: AetherColors.border),
      ),
      child: Column(
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            _SettingsRow(spec: rows[i]),
            if (i < rows.length - 1)
              const Padding(
                padding: EdgeInsets.only(left: AetherSpacing.lg + 32),
                child: Divider(height: 1, color: AetherColors.border),
              ),
          ],
        ],
      ),
    );
  }

  static Future<void> _showLanguageDialog(
    BuildContext context,
    LocaleNotifier notifier,
  ) async {
    final l = AppL10n.of(context);
    final selected = await showDialog<_LangChoice>(
      context: context,
      builder: (ctx) {
        final current = notifier.isChinese ? _LangChoice.zh : _LangChoice.en;
        return AlertDialog(
          backgroundColor: AetherColors.bgCanvas,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AetherRadii.lg),
          ),
          title: Text(l.languageDialogTitle, style: AetherTextStyles.h2),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final choice in _LangChoice.values)
                RadioListTile<_LangChoice>(
                  title: Text(_choiceLabel(choice, l)),
                  value: choice,
                  groupValue: current,
                  onChanged: (v) => Navigator.of(ctx).pop(v),
                  activeColor: AetherColors.primary,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l.commonCancel),
            ),
          ],
        );
      },
    );
    if (selected == null) return;
    switch (selected) {
      case _LangChoice.zh:
        await notifier.set(const Locale('zh'));
      case _LangChoice.en:
        await notifier.set(const Locale('en'));
    }
  }

  static String _choiceLabel(_LangChoice c, AppL10n l) {
    switch (c) {
      case _LangChoice.zh:
        return l.languageDialogChinese;
      case _LangChoice.en:
        return l.languageDialogEnglish;
    }
  }
}

enum _LangChoice { zh, en }

class _SettingsRowSpec {
  final IconData icon;
  final String title;
  final String trailing;
  final VoidCallback? onTap;

  const _SettingsRowSpec({
    required this.icon,
    required this.title,
    required this.trailing,
    required this.onTap,
  });
}

class _SettingsRow extends StatelessWidget {
  final _SettingsRowSpec spec;

  const _SettingsRow({required this.spec});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: spec.onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AetherSpacing.lg,
          vertical: AetherSpacing.md + 2,
        ),
        child: Row(
          children: [
            Icon(spec.icon, size: 20, color: AetherColors.textPrimary),
            const SizedBox(width: AetherSpacing.md),
            Expanded(child: Text(spec.title, style: AetherTextStyles.body)),
            Text(spec.trailing, style: AetherTextStyles.caption),
            const SizedBox(width: AetherSpacing.xs),
            const Icon(
              Icons.chevron_right_rounded,
              color: AetherColors.textTertiary,
              size: 18,
            ),
          ],
        ),
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

class _SignOutButton extends StatelessWidget {
  const _SignOutButton();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return GestureDetector(
      onTap: () async {
        final currentUser = AuthScope.read(context);
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: AetherColors.bgCanvas,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AetherRadii.lg),
            ),
            title: Text(l.meSignOut, style: AetherTextStyles.h2),
            content: const SizedBox.shrink(),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l.commonCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: AetherColors.danger,
                ),
                child: Text(
                  l.commonOk,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await currentUser.signOut();
        }
      },
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: AetherColors.bgCanvas,
          borderRadius: BorderRadius.circular(AetherRadii.lg),
          border: Border.all(color: AetherColors.danger),
        ),
        alignment: Alignment.center,
        child: Text(
          l.meSignOut,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AetherColors.danger,
          ),
        ),
      ),
    );
  }
}
