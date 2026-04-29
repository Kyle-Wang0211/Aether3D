// CaptureModeSelectionPage — port of the SwiftUI prototype page of the
// same name. 3 mode cards + hero + step strip + detail card + confirm
// CTA. Selecting "confirm" pushes the actual capture page built by
// the `capturePageBuilder` closure (wired from main.dart so the
// capture page sees the live Dawn texture / gesture state).

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'capture_page.dart';
import 'design_system.dart';
import 'scan_record.dart';

class CaptureModeSelectionPage extends StatefulWidget {
  final CaptureMode initialMode;
  final CapturePageBuilder capturePageBuilder;

  const CaptureModeSelectionPage({
    super.key,
    this.initialMode = CaptureMode.newRemote,
    required this.capturePageBuilder,
  });

  @override
  State<CaptureModeSelectionPage> createState() =>
      _CaptureModeSelectionPageState();
}

class _CaptureModeSelectionPageState extends State<CaptureModeSelectionPage> {
  late CaptureMode _selected = widget.initialMode;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AetherColors.bg,
      body: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                AetherSpacing.lg,
                AetherSpacing.md,
                AetherSpacing.lg,
                180,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DesignBox(
                    kind: DesignKind.customizable,
                    label: '顶栏',
                    child: _TopBar(),
                  ),
                  const SizedBox(height: AetherSpacing.lg),
                  DesignBox(
                    kind: DesignKind.customizable,
                    label: 'Hero',
                    child: _Hero(),
                  ),
                  const SizedBox(height: AetherSpacing.lg),
                  DesignBox(
                    kind: DesignKind.customizable,
                    label: '步骤条',
                    child: _StepStrip(),
                  ),
                  const SizedBox(height: AetherSpacing.lg),
                  DesignBox(
                    kind: DesignKind.customizable,
                    label: '方案卡',
                    child: _ModeCards(
                      selected: _selected,
                      onChanged: (m) => setState(() => _selected = m),
                    ),
                  ),
                  const SizedBox(height: AetherSpacing.lg),
                  DesignBox(
                    kind: DesignKind.customizable,
                    label: '详情',
                    child: _DetailCard(mode: _selected),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: DesignBox(
              kind: DesignKind.customizable,
              label: '底部动作栏',
              child: _BottomActions(
                onConfirm: _confirm,
                onCancel: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _confirm() {
    final chosen = _selected;
    // Push the capture page; pop returns the selected mode to the caller
    // in case it wants to remember "last used mode" (prototype does this
    // via @AppStorage — Flutter can store in SharedPreferences later).
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => widget.capturePageBuilder(ctx, chosen),
        fullscreenDialog: false,
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AetherColors.bgCanvas,
              shape: BoxShape.circle,
              border: Border.all(color: AetherColors.border),
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.chevron_left_rounded,
              size: 20,
              color: AetherColors.textPrimary,
            ),
          ),
        ),
        const Spacer(),
        Text(AppL10n.of(context).captureModePageTitle,
            style: AetherTextStyles.h2),
        const Spacer(),
        const SizedBox(width: 40, height: 40),
      ],
    );
  }
}

class _Hero extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AetherSpacing.xl),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppL10n.of(context).captureModePageHero,
              style: AetherTextStyles.displayLarge),
          const SizedBox(height: AetherSpacing.md),
        ],
      ),
    );
  }
}

class _StepStrip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Row(
      children: [
        Expanded(
            child: _StepChip(
                index: '1', title: l.captureModePageStep1, active: true)),
        const SizedBox(width: AetherSpacing.md),
        Expanded(
            child: _StepChip(
                index: '2', title: l.captureModePageStep2, active: true)),
        const SizedBox(width: AetherSpacing.md),
        Expanded(
            child: _StepChip(
                index: '3', title: l.captureModePageStep3, active: false)),
      ],
    );
  }
}

class _StepChip extends StatelessWidget {
  final String index;
  final String title;
  final bool active;

  const _StepChip({
    required this.index,
    required this.title,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AetherSpacing.md,
        vertical: AetherSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas,
        borderRadius: BorderRadius.circular(AetherRadii.md),
        border: Border.all(color: AetherColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: active ? AetherColors.primary : AetherColors.border,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              index,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: active ? Colors.white : AetherColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AetherColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeCards extends StatelessWidget {
  final CaptureMode selected;
  final ValueChanged<CaptureMode> onChanged;

  const _ModeCards({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final mode in CaptureMode.values) ...[
          _ModeCard(
            mode: mode,
            selected: mode == selected,
            onTap: () => onChanged(mode),
          ),
          if (mode != CaptureMode.values.last)
            const SizedBox(height: AetherSpacing.md),
        ],
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  final CaptureMode mode;
  final bool selected;
  final VoidCallback onTap;

  const _ModeCard({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(AetherSpacing.lg),
        decoration: BoxDecoration(
          color: AetherColors.bgCanvas,
          borderRadius: BorderRadius.circular(AetherRadii.xl),
          border: Border.all(
            color: selected ? AetherColors.primary : AetherColors.border,
            width: selected ? 2 : 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AetherColors.shadow,
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ]
              : const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: selected
                        ? AetherColors.primary
                        : AetherColors.bgElevated,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    mode.icon,
                    size: 18,
                    color: selected
                        ? Colors.white
                        : AetherColors.textPrimary,
                  ),
                ),
                const SizedBox(width: AetherSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(mode.title, style: AetherTextStyles.h3),
                          if (mode.shortBadge != null) ...[
                            const SizedBox(width: AetherSpacing.sm),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AetherColors.primary,
                                borderRadius: BorderRadius.circular(
                                  AetherRadii.pill,
                                ),
                              ),
                              child: Text(
                                mode.shortBadge!,
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(mode.subtitle, style: AetherTextStyles.bodySm),
                    ],
                  ),
                ),
                const SizedBox(width: AetherSpacing.sm),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected
                          ? AetherColors.primary
                          : AetherColors.borderStrong,
                      width: 2,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: selected
                      ? Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            color: AetherColors.primary,
                            shape: BoxShape.circle,
                          ),
                        )
                      : null,
                ),
              ],
            ),
            const SizedBox(height: AetherSpacing.md),
            Container(
              padding: const EdgeInsets.all(AetherSpacing.md),
              decoration: BoxDecoration(
                color: AetherColors.bgElevated,
                borderRadius: BorderRadius.circular(AetherRadii.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mode.detailTitle,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AetherColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(mode.detailBody, style: AetherTextStyles.bodySm),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  final CaptureMode mode;

  const _DetailCard({required this.mode});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AetherSpacing.lg),
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas,
        borderRadius: BorderRadius.circular(AetherRadii.xl),
        border: Border.all(color: AetherColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(AppL10n.of(context).captureModePageWillHappen,
              style: AetherTextStyles.h2),
          const SizedBox(height: AetherSpacing.md),
          _DetailRow(label: '当前选择', body: mode.title),
          _DetailRow(
            label: '进入页面',
            body: mode == CaptureMode.newRemote ? '对象模式 Beta 拍摄页' : '扫描拍摄页',
          ),
          _DetailRow(
            label: '结果反馈',
            body: mode == CaptureMode.newRemote
                ? '先给出 Preview，再逐步升级结果质量。'
                : '完成后直接保存本地结果，并在首页与任务页可见。',
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String body;

  const _DetailRow({required this.label, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AetherSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AetherColors.textSecondary,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            body,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AetherColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomActions extends StatelessWidget {
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  const _BottomActions({required this.onConfirm, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AetherColors.bg.withValues(alpha: 0.94),
        border: const Border(
          top: BorderSide(color: AetherColors.border, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AetherSpacing.lg,
            AetherSpacing.md,
            AetherSpacing.lg,
            AetherSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AetherPrimaryButton(
                label: '确认进入拍摄',
                icon: Icons.arrow_forward_rounded,
                onTap: onConfirm,
              ),
              const SizedBox(height: AetherSpacing.sm),
              AetherSecondaryButton(label: '取消', onTap: onCancel),
            ],
          ),
        ),
      ),
    );
  }
}
