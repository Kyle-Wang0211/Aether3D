// VaultPage — "仓库" tab. Port of HomePage.swift.
//
// Layout:
//   • AETHER3D wordmark (big, centered)
//   • optional summary strip: "进行中 × N  待处理 × N" pills, only
//     shown when there are running / attention records.
//   • waterfall gallery: two columns, even-index records left, odd-
//     index right, deterministic height pattern per column.
//   • floating camera FAB at bottom-right → opens the capture mode
//     selection page (the "拍摄入口 先随便放一下" from today's spec;
//     final placement / affordance to be decided in a later round).

import 'package:flutter/material.dart';

import '../i18n/relative_time.dart';
import '../l10n/app_localizations.dart';
import 'capture_mode_selection_page.dart';
import 'capture_page.dart' show CapturePageBuilder;
import 'design_system.dart';
import 'home_view_model.dart';
import 'scan_record.dart';
import 'scan_record_cell.dart';

class VaultPage extends StatefulWidget {
  /// Carries the in-progress 3D Texture viewer state down into the
  /// capture page (wired through the mode selection page).
  final CapturePageBuilder capturePageBuilder;

  const VaultPage({super.key, required this.capturePageBuilder});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  final HomeViewModel _vm = HomeViewModel();

  @override
  void initState() {
    super.initState();
    _vm.addListener(_onVmChanged);
    _vm.loadRecords();
  }

  @override
  void dispose() {
    _vm.removeListener(_onVmChanged);
    _vm.dispose();
    super.dispose();
  }

  void _onVmChanged() {
    if (mounted) setState(() {});
  }

  void _openCapture() async {
    final chosen = await Navigator.of(context).push<CaptureMode>(
      MaterialPageRoute(
        builder: (_) => CaptureModeSelectionPage(
          capturePageBuilder: widget.capturePageBuilder,
        ),
        fullscreenDialog: false,
      ),
    );
    if (!mounted || chosen == null) return;
    // Nothing to persist for now — the mode selection page pushes the
    // capture page itself. Leaving this hook so the "last selected
    // mode" AppStorage shortcut from the prototype can be wired later.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AetherColors.bg,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: DesignBox(
                    kind: DesignKind.customizable,
                    label: 'Wordmark',
                    child: _Header(),
                  ),
                ),
                // Community feed shouldn't expose authoring/processing
                // state (Running / Attention pills moved to the owner-
                // facing "我的作品" section under Me).
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(
                    AetherSpacing.lg,
                    AetherSpacing.lg,
                    AetherSpacing.lg,
                    140,
                  ),
                  sliver: _vm.isLoading
                      ? const SliverFillRemaining(
                          hasScrollBody: false,
                          child: _LoadingState(),
                        )
                      : _vm.scanRecords.isEmpty
                          ? const SliverFillRemaining(
                              hasScrollBody: false,
                              child: _EmptyState(),
                            )
                          : SliverToBoxAdapter(
                              child: DesignBox(
                                kind: DesignKind.backendNeeded,
                                label: '作品瀑布流',
                                child: _Waterfall(
                                  vm: _vm,
                                  capturePageBuilder: widget.capturePageBuilder,
                                ),
                              ),
                            ),
                ),
              ],
            ),
          ),
          Positioned(
            right: AetherSpacing.xl,
            bottom: AetherSpacing.xl,
            child: DesignBox(
              kind: DesignKind.customizable,
              label: '拍摄入口',
              child: _CaptureFab(onTap: _openCapture),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.lg,
        AetherSpacing.md,
        AetherSpacing.lg,
        AetherSpacing.md,
      ),
      child: SizedBox(
        height: 56,
        child: Center(
          child: Text(AppL10n.of(context).appBrand,
              style: AetherTextStyles.wordmark),
        ),
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  final int running;
  final int attention;

  const _SummaryStrip({required this.running, required this.attention});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.lg,
        0,
        AetherSpacing.lg,
        AetherSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: _SummaryPill(
              title: AppL10n.of(context).communitySummaryRunning,
              value: running,
              dot: AetherColors.primary,
            ),
          ),
          const SizedBox(width: AetherSpacing.md),
          Expanded(
            child: _SummaryPill(
              title: AppL10n.of(context).communitySummaryAttention,
              value: attention,
              dot: AetherColors.danger,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryPill extends StatelessWidget {
  final String title;
  final int value;
  final Color dot;

  const _SummaryPill({
    required this.title,
    required this.value,
    required this.dot,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AetherSpacing.lg,
        vertical: AetherSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas,
        borderRadius: BorderRadius.circular(AetherRadii.pill),
        border: Border.all(color: AetherColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: AetherSpacing.sm),
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AetherColors.textPrimary,
            ),
          ),
          const Spacer(),
          Text(
            '$value',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: dot == AetherColors.danger
                  ? AetherColors.danger
                  : AetherColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(AetherColors.primary),
          ),
        ),
        const SizedBox(height: AetherSpacing.md),
        Text(AppL10n.of(context).communityLoading,
            style: AetherTextStyles.bodySm),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            color: AetherColors.bgCanvas,
            borderRadius: BorderRadius.circular(AetherRadii.xl),
            boxShadow: [
              BoxShadow(
                color: AetherColors.shadow,
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.view_in_ar_outlined,
            size: 38,
            color: AetherColors.primary,
          ),
        ),
        const SizedBox(height: AetherSpacing.lg),
        Text(AppL10n.of(context).communityEmptyTitle,
            style: AetherTextStyles.h2),
        const SizedBox(height: AetherSpacing.sm),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: AetherSpacing.xxl),
          child: Text(
            '点击右下角的相机按钮，选择采集方案，开始你的第一次扫描。',
            textAlign: TextAlign.center,
            style: AetherTextStyles.bodySm,
          ),
        ),
      ],
    );
  }
}

class _Waterfall extends StatelessWidget {
  final HomeViewModel vm;
  final CapturePageBuilder capturePageBuilder;

  const _Waterfall({required this.vm, required this.capturePageBuilder});

  @override
  Widget build(BuildContext context) {
    // 2026-04-28: community switched to a single-column feed (per user
    // direction). The owner-facing "我的作品" grid under Me keeps the
    // two-column waterfall — visitors see one card per row, full
    // width, IG-feed style.
    return _Column(
      records: vm.scanRecords,
      isLeft: true,
      vm: vm,
      capturePageBuilder: capturePageBuilder,
    );
  }
}

class _Column extends StatelessWidget {
  final List<ScanRecord> records;
  final bool isLeft;
  final HomeViewModel vm;
  final CapturePageBuilder capturePageBuilder;

  const _Column({
    required this.records,
    required this.isLeft,
    required this.vm,
    required this.capturePageBuilder,
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
            // Community feed = single column → cards span the full
            // width, so the thumbnail is taller than in the two-column
            // "我的作品" grid (which keeps the prototype's variable
            // height pattern for waterfall feel).
            imageHeight: 360,
            onTap: () => _openRecord(context, records[i]),
            // Community feed stays clean — no per-card authoring or
            // processing badges. Owner-facing state lives only in the
            // "我的作品" grid under Me.
            showStatusBadge: false,
          ),
          if (i < records.length - 1)
            const SizedBox(height: AetherSpacing.lg),
        ],
      ],
    );
  }

  String _subtitleFor(AppL10n l, ScanRecord r) {
    // Per user direction: handles / titles / captions are user content
    // and don't get translated. Fall back to "You" for records without
    // an author (own scans).
    final owner = r.authorHandle ?? 'You';
    final relative = formatRelativeTime(l, r.createdAt);
    if (r.jobStatus != null) {
      return l.communityRecordSubtitleWithStatus(
        owner,
        relative,
        r.localizedLifecycleTitle(l),
      );
    }
    return l.communityRecordSubtitle(owner, relative);
  }

  void _openRecord(BuildContext context, ScanRecord record) {
    // Sample DamagedHelmet card re-uses the capturePageBuilder (which in
    // production mounts CapturePage with the shared Dawn texture and
    // orbit controller from HomeScreen's state). That gives us a fully
    // rendered PBR mesh + gestures without wiring a separate viewer yet.
    // CaptureMode.local is the no-upload path, suitable for read-only
    // inspection of an already-loaded GLB.
    // Any record with a bundled GLB asset is viewable on-device. The
    // builder hot-swaps the running Dawn scene to the requested GLB
    // before mounting the viewer-mode CapturePage.
    if (record.bundledGlbAsset != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (ctx) => capturePageBuilder(
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

class _CaptureFab extends StatelessWidget {
  final VoidCallback onTap;

  const _CaptureFab({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 62,
        height: 62,
        decoration: BoxDecoration(
          color: AetherColors.primary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Icon(
          Icons.camera_alt_rounded,
          color: Colors.white,
          size: 24,
        ),
      ),
    );
  }
}
