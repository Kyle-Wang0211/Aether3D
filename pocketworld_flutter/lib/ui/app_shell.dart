// AetherAppShell — 3-element bottom nav: Community (9-grid icon) ·
// CREATE button (filled black circle, fully inside the bar) · Me
// (person icon).
//
// "Create" — placeholder while we port Aether3D's capture pipeline
// (ARKit + DomeCoverageMap + FrameAnalyzer quality detection + A100
// remote pipeline) into Flutter. The previous Dawn-backed CapturePage
// + CaptureModeSelectionPage have been removed (2026-04-29).
//
// Cross-platform: pure Flutter widgets, no native code. Bottom nav is
// the same 76 px tall on iOS / Android / HarmonyOS / Web.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../me/import_glb_coordinator.dart';
import 'capture/capture_page.dart';
import 'design_system.dart';
import 'me_page.dart';
import 'vault_page.dart';

// 2026-04-28 IA reshape: bottom nav simplified to two tabs — Community
// (public feed of everyone's works) and Me (Instagram-style profile that
// includes the user's own works grid). The "Vault" tab is gone; own
// works live under Me, public works live under Community.
enum AetherRootTab { community, me }

extension _TabMeta on AetherRootTab {
  // Tab labels removed in 2026-04-29 redesign — bottom nav is icons-only
  // to mirror Polycam / Instagram. Localized strings still live in
  // AppL10n.tabCommunity / .tabMe in case we need them on the Me page
  // header or for accessibility.

  IconData get icon {
    switch (this) {
      case AetherRootTab.community:
        return Icons.apps_rounded;  // 9-grid (community grid view)
      case AetherRootTab.me:
        return Icons.person_outline_rounded;
    }
  }

  IconData get iconFilled {
    switch (this) {
      case AetherRootTab.community:
        return Icons.apps_rounded;  // same shape; selected state via color
      case AetherRootTab.me:
        return Icons.person_rounded;
    }
  }
}

class AetherAppShell extends StatefulWidget {
  const AetherAppShell({super.key});

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
        children: const [
          VaultPage(),
          MePage(),
        ],
      ),
      bottomNavigationBar: _BottomTabBar(
        current: _tab,
        onChange: (t) => setState(() => _tab = t),
        onCreate: _openCreate,
      ),
    );
  }

  /// Polycam-style "+" entry point: pops a bottom sheet with two
  /// side-by-side options — 拍摄 (push CapturePage) and 上传 (pick a
  /// .glb / .gltf and hand it to ImportGlbCoordinator). Both paths
  /// flip the bottom nav to Me afterwards so the new card is visible.
  ///
  /// Phase 6 originally lived as a `+` icon in the Me-tab header;
  /// merged here so all "create work" entries share one entry point
  /// and the Me header stays clean.
  Future<void> _openCreate() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AetherColors.bgCanvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Row(
            children: [
              Expanded(
                child: _CreateOption(
                  icon: Icons.photo_camera_outlined,
                  label: '拍摄',
                  onTap: () => Navigator.of(ctx).pop('capture'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _CreateOption(
                  icon: Icons.cloud_upload_outlined,
                  label: '上传',
                  onTap: () => Navigator.of(ctx).pop('upload'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'capture') {
      await _openCapture();
    } else if (action == 'upload') {
      await _importGlb();
    }
  }

  Future<void> _openCapture() async {
    // CapturePage returns `true` when the user tapped Stop and the
    // upload kicked off — that's our cue to flip the bottom nav to
    // Me so the freshly-created scan card is visible right away.
    final shouldShowMe = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => const CapturePage(),
      ),
    );
    if (!mounted) return;
    if (shouldShowMe == true && _tab != AetherRootTab.me) {
      setState(() => _tab = AetherRootTab.me);
    }
  }

  /// GLB import — moved here from MePage in 2026-05-06 redesign so the
  /// bottom-bar '+' is the single create entry point. Logic kept
  /// identical: pick file → ImportGlbCoordinator.start (which owns
  /// the worker isolate + persists a placeholder ScanRecord) → flip
  /// to Me tab so the user sees the importing card.
  Future<void> _importGlb() async {
    final messenger = ScaffoldMessenger.of(context);
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['glb', 'gltf'],
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('打开文件选择器失败: $e'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    if (picked == null || picked.files.isEmpty) return;
    final pickedFile = picked.files.single;
    final path = pickedFile.path;
    if (path == null || path.isEmpty) {
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('无法读取所选文件'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    final fileName = pickedFile.name;
    final bareName = fileName.contains('.')
        ? fileName.substring(0, fileName.lastIndexOf('.'))
        : fileName;
    ImportGlbCoordinator.instance.start(
      glbFile: File(path),
      name: bareName,
    );
    if (!mounted) return;
    messenger.showSnackBar(const SnackBar(
      content: Text('正在导入 GLB 模型…'),
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 2),
    ));
    if (_tab != AetherRootTab.me) {
      setState(() => _tab = AetherRootTab.me);
    }
  }
}

/// Square card used inside the bottom-sheet create menu — icon stacked
/// over a label, matching the Polycam-style "two big choices" pattern.
class _CreateOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _CreateOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 12),
        decoration: BoxDecoration(
          color: AetherColors.bg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AetherColors.border, width: 0.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: AetherColors.primary),
            const SizedBox(height: 12),
            Text(
              label,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AetherColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomTabBar extends StatelessWidget {
  final AetherRootTab current;
  final ValueChanged<AetherRootTab> onChange;
  final VoidCallback onCreate;

  const _BottomTabBar({
    required this.current,
    required this.onChange,
    required this.onCreate,
  });

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
        child: SizedBox(
          // Polycam-height bar (compact, no half-floating FAB). 56 px
          // accommodates a 44 px center "+" with 6 px vertical
          // breathing room above + below.
          height: 56,
          child: Row(
            children: [
              Expanded(
                child: _TabItem(
                  tab: AetherRootTab.community,
                  selected: current == AetherRootTab.community,
                  onTap: () => onChange(AetherRootTab.community),
                ),
              ),
              _CenterCreateButton(onTap: onCreate),
              Expanded(
                child: _TabItem(
                  tab: AetherRootTab.me,
                  selected: current == AetherRootTab.me,
                  onTap: () => onChange(AetherRootTab.me),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CenterCreateButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CenterCreateButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: AetherColors.primary,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.add_rounded,
            color: Colors.white,
            size: 24,
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
      child: Center(
        child: Icon(
          selected ? tab.iconFilled : tab.icon,
          size: 26,
          color: color,
        ),
      ),
    );
  }
}
