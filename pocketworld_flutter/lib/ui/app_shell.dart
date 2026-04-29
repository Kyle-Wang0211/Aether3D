// AetherAppShell — 2-tab bottom navigation (仓库 / 个人).
//
// Ported structure from the SwiftUI prototype's AetherAppShell but
// simplified per user direction (2026-04-27): strictly black & white,
// drop social / discovery tabs, capture entry lives on the vault page.

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'capture_page.dart';
import 'design_system.dart';
import 'me_page.dart';
import 'vault_page.dart';

// 2026-04-28 IA reshape: bottom nav simplified to two tabs — Community
// (public feed of everyone's works) and Me (Instagram-style profile that
// includes the user's own works grid). The "Vault" tab is gone; own
// works live under Me, public works live under Community.
enum AetherRootTab { community, me }

extension _TabMeta on AetherRootTab {
  String localizedTitle(AppL10n l) {
    switch (this) {
      case AetherRootTab.community:
        return l.tabCommunity;
      case AetherRootTab.me:
        return l.tabMe;
    }
  }

  IconData get icon {
    switch (this) {
      case AetherRootTab.community:
        return Icons.public_rounded;
      case AetherRootTab.me:
        return Icons.person_outline_rounded;
    }
  }

  IconData get iconFilled {
    switch (this) {
      case AetherRootTab.community:
        return Icons.public;
      case AetherRootTab.me:
        return Icons.person_rounded;
    }
  }
}

class AetherAppShell extends StatefulWidget {
  /// Builder that produces the capture page for a given capture mode.
  /// Wired from main.dart so the capture page sees the live Dawn
  /// texture / gesture state. Passed through to VaultPage (which
  /// forwards it to the mode selection page).
  final CapturePageBuilder capturePageBuilder;

  const AetherAppShell({super.key, required this.capturePageBuilder});

  @override
  State<AetherAppShell> createState() => _AetherAppShellState();
}

class _AetherAppShellState extends State<AetherAppShell> {
  AetherRootTab _tab = AetherRootTab.community;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AetherColors.bg,
      extendBody: true,
      body: IndexedStack(
        index: AetherRootTab.values.indexOf(_tab),
        children: [
          VaultPage(capturePageBuilder: widget.capturePageBuilder),
          MePage(capturePageBuilder: widget.capturePageBuilder),
        ],
      ),
      bottomNavigationBar: DesignBox(
        kind: DesignKind.customizable,
        label: '底部 TabBar',
        child: _BottomTabBar(
          current: _tab,
          onChange: (t) => setState(() => _tab = t),
        ),
      ),
    );
  }
}

class _BottomTabBar extends StatelessWidget {
  final AetherRootTab current;
  final ValueChanged<AetherRootTab> onChange;

  const _BottomTabBar({required this.current, required this.onChange});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas.withValues(alpha: 0.96),
        border: const Border(
          top: BorderSide(color: AetherColors.border, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AetherSpacing.xxl,
            vertical: AetherSpacing.sm,
          ),
          child: Row(
            children: [
              for (final t in AetherRootTab.values)
                Expanded(
                  child: _TabItem(
                    tab: t,
                    selected: t == current,
                    onTap: () => onChange(t),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  final AetherRootTab tab;
  final bool selected;
  final VoidCallback onTap;

  const _TabItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AetherColors.primary : AetherColors.textTertiary;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AetherSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              selected ? tab.iconFilled : tab.icon,
              size: 24,
              color: color,
            ),
            const SizedBox(height: 4),
            Text(
              tab.localizedTitle(AppL10n.of(context)),
              style: TextStyle(
                fontSize: 11,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: color,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
