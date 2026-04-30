// MeSettingsPage — pushed from MePage's gear icon. Holds the secondary
// account chrome (notifications, privacy, language, about, sign-out)
// that we don't want crowding the home Me tab.
//
// Notification / privacy trailing values come from MeStatsViewModel,
// which loads from public.notification_settings and public.profiles.

import 'package:flutter/material.dart';

import '../auth/auth_scope.dart';
import '../i18n/locale_notifier.dart';
import '../l10n/app_localizations.dart';
import 'design_system.dart';
import 'me_stats_view_model.dart';

class MeSettingsPage extends StatelessWidget {
  final MeStatsViewModel stats;

  const MeSettingsPage({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      backgroundColor: AetherColors.bg,
      appBar: AppBar(
        backgroundColor: AetherColors.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: AetherColors.textPrimary),
        title: Text(l.meSettingsTitle, style: AetherTextStyles.h2),
      ),
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
            AnimatedBuilder(
              animation: stats,
              builder: (_, _) => _SettingsSection(stats: stats),
            ),
            const SizedBox(height: AetherSpacing.xl),
            const _SignOutButton(),
          ],
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final MeStatsViewModel stats;

  const _SettingsSection({required this.stats});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final localeNotifier = LocaleScope.of(context);
    final isZh = localeNotifier.isChinese;
    final notifEnabled = stats.notificationsEnabled;
    final notificationsTrailing = notifEnabled == null
        ? l.meSettingNotConfigured
        : (notifEnabled ? l.meNotificationsOn : l.meNotificationsOff);
    final isPrivate = stats.isPrivate;
    final privacyTrailing = isPrivate == null
        ? l.meSettingNotConfigured
        : (isPrivate ? l.mePrivacyPrivate : l.mePrivacyPublic);
    final rows = <_SettingsRowSpec>[
      _SettingsRowSpec(
        icon: Icons.notifications_none_rounded,
        title: l.meNotifications,
        trailing: notificationsTrailing,
        onTap: null,
      ),
      _SettingsRowSpec(
        icon: Icons.lock_outline_rounded,
        title: l.mePrivacy,
        trailing: privacyTrailing,
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
