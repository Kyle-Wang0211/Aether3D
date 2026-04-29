// CapturePage — real "scan recording" UI reached from
// CaptureModeSelectionPage.
//
// Composition (bottom-up):
//   • camera-preview area    — hosts the live 3D Texture widget (Dawn
//                               DamagedHelmet mock until the camera
//                               plugin lands; gesture detector still
//                               drives OrbitControls so the mock
//                               object can be inspected during capture)
//   • top-right dome overlay — DomeView + CoverageMap, fed by the
//                               PlatformARPoseProvider (falls back to
//                               MockARPoseProvider when no native AR)
//   • long-press debug HUD   — QualityDebugOverlay reading mock
//                               QualityDebugStats
//   • guidance strip         — real GuidanceEngine output: accepted
//                               frames + orbit completion + live hint
//   • tool row               — flash / grid / timer / hdr / cloud
//   • big record button      — starts/stops GuidanceEngine +
//                               MockFrameDriver
//
// When the camera + GPU quality pipeline are wired (PORTING_BACKLOG D2),
// the MockFrameDriver gets swapped for a real AVFoundation → FFI path;
// everything else stays the same.

import 'package:flutter/material.dart';

import '../dome/coverage_map.dart';
import '../dome/dome_view.dart';
import '../l10n/app_localizations.dart';
import '../orbit_controls.dart';
import '../quality/guidance_engine.dart';
import '../quality/mock_frame_driver.dart';
import '../quality/quality_debug_overlay.dart';
import 'design_system.dart';
import 'scan_record.dart';

typedef CaptureScaleCallback = void Function(
  double scale,
  Offset focalDelta,
  double rotation,
  int pointerCount,
  Size widgetSize,
);

typedef CapturePageBuilder = Widget Function(
  BuildContext context,
  CaptureMode mode, {
  bool viewerMode,
  String? viewerTitle,
  String? viewerGlbAsset,
});

enum _RecordingState { idle, recording, finished }

class CapturePage extends StatefulWidget {
  final CaptureMode mode;

  final int? textureId;
  final String? textureError;
  final bool isRetrying;
  final VoidCallback onRetryTexture;

  final String? meshStatus;
  final bool meshStatusBusy;
  final bool meshStatusError;

  final OrbitControls orbit;
  final Size textureWidgetSize;
  final CaptureScaleCallback onScaleUpdate;
  final String Function() resolveVersionFooter;

  /// When true, the page renders as a read-only viewer: keeps the top bar
  /// and the 3D main stage, hides the guidance strip / tool row / record
  /// button. Used by Vault sample cards (e.g. 样板·头盔) that just want
  /// to inspect a baked GLB without any capture pipeline.
  final bool viewerMode;

  /// Optional override for the top-bar title in viewer mode (defaults to
  /// "查看" when viewerMode is true and no override is given).
  final String? viewerTitle;

  const CapturePage({
    super.key,
    required this.mode,
    required this.textureId,
    required this.textureError,
    required this.isRetrying,
    required this.onRetryTexture,
    required this.meshStatus,
    required this.meshStatusBusy,
    required this.meshStatusError,
    required this.orbit,
    required this.textureWidgetSize,
    required this.onScaleUpdate,
    required this.resolveVersionFooter,
    this.viewerMode = false,
    this.viewerTitle,
  });

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  final GuidanceEngine _guidance = GuidanceEngine();
  final CoverageMap _coverage = CoverageMap();
  MockFrameDriver? _frameDriver;
  GuidanceSnapshot _snap = GuidanceSnapshot.idle;
  QualityDebugStats? _debugStats;
  bool _debugHudVisible = false;
  _RecordingState _state = _RecordingState.idle;

  @override
  void initState() {
    super.initState();
    _guidance.onUpdate = (snap) {
      if (mounted) setState(() => _snap = snap);
    };
    _guidance.startMonitoring();
  }

  @override
  void dispose() {
    _frameDriver?.dispose();
    super.dispose();
  }

  void _toggleRecord() {
    switch (_state) {
      case _RecordingState.idle:
        _guidance.beginRecording();
        _coverage.reset();
        _frameDriver?.dispose();
        _frameDriver = MockFrameDriver(
          engine: _guidance,
          onDebugStats: (s) {
            if (mounted) setState(() => _debugStats = s);
          },
        )..start();
        setState(() => _state = _RecordingState.recording);
      case _RecordingState.recording:
        _guidance.endRecording();
        _frameDriver?.stop();
        setState(() => _state = _RecordingState.finished);
      case _RecordingState.finished:
        // Reset to idle — user can start again.
        _coverage.reset();
        setState(() {
          _state = _RecordingState.idle;
          _snap = GuidanceSnapshot.idle;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AetherColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            DesignBox(
              kind: DesignKind.customizable,
              label: '顶栏',
              child: _TopBar(
                mode: widget.mode,
                viewerMode: widget.viewerMode,
                viewerTitle: widget.viewerTitle,
              ),
            ),
            Expanded(
              child: DesignBox(
                kind: DesignKind.partial,
                label: '主视图',
                child: _MainStage(
                  textureId: widget.textureId,
                  textureError: widget.textureError,
                  isRetrying: widget.isRetrying,
                  onRetryTexture: widget.onRetryTexture,
                  meshStatus: widget.meshStatus,
                  meshStatusBusy: widget.meshStatusBusy,
                  meshStatusError: widget.meshStatusError,
                  textureWidgetSize: widget.textureWidgetSize,
                  onScaleUpdate: widget.onScaleUpdate,
                  coverage: _coverage,
                  debugHudVisible: _debugHudVisible,
                  debugStats: _debugStats,
                  onToggleHud: () => setState(
                    () => _debugHudVisible = !_debugHudVisible,
                  ),
                  recordingActive: _state == _RecordingState.recording,
                  viewerMode: widget.viewerMode,
                ),
              ),
            ),
            if (!widget.viewerMode) ...[
              DesignBox(
                kind: DesignKind.customizable,
                label: '引导提示',
                child: _GuidanceStrip(
                  snap: _snap,
                  audit: _guidance.auditSummary,
                  recordingActive: _state == _RecordingState.recording,
                ),
              ),
              DesignBox(
                kind: DesignKind.customizable,
                label: '工具栏',
                child: _CaptureToolbar(),
              ),
              DesignBox(
                kind: DesignKind.customizable,
                label: '录制按钮',
                child: _RecordButtonRow(
                  state: _state,
                  onTap: _toggleRecord,
                  onOpenGallery: () => _notImplemented(
                    context,
                    AppL10n.of(context).captureRecordGallery,
                  ),
                  onOpenSettings: () => _notImplemented(
                    context,
                    AppL10n.of(context).captureRecordSettings,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static void _notImplemented(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppL10n.of(context).captureNotImplemented(feature)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

// ─── Top bar ────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final CaptureMode mode;
  final bool viewerMode;
  final String? viewerTitle;

  const _TopBar({
    required this.mode,
    this.viewerMode = false,
    this.viewerTitle,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final mainTitle =
        viewerMode ? (viewerTitle ?? l.captureViewerTitleFallback) : l.captureRecording;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.md,
        AetherSpacing.sm,
        AetherSpacing.md,
        AetherSpacing.sm,
      ),
      child: Row(
        children: [
          _CircleIconButton(
            icon: Icons.chevron_left_rounded,
            onTap: () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          Column(
            children: [
              Text(
                mainTitle,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: AetherColors.textPrimary,
                ),
              ),
              if (!viewerMode) ...[
                const SizedBox(height: 2),
                Text(mode.localizedTitle(l), style: AetherTextStyles.caption),
              ],
            ],
          ),
          const Spacer(),
          _CircleIconButton(icon: Icons.more_horiz_rounded, onTap: () {}),
        ],
      ),
    );
  }
}

class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _CircleIconButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AetherColors.bgCanvas,
          shape: BoxShape.circle,
          border: Border.all(color: AetherColors.border),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 18, color: AetherColors.textPrimary),
      ),
    );
  }
}

// ─── Main stage: camera preview + dome overlay + debug HUD ────────

class _MainStage extends StatelessWidget {
  final int? textureId;
  final String? textureError;
  final bool isRetrying;
  final VoidCallback onRetryTexture;
  final String? meshStatus;
  final bool meshStatusBusy;
  final bool meshStatusError;
  final Size textureWidgetSize;
  final CaptureScaleCallback onScaleUpdate;
  final CoverageMap coverage;
  final bool debugHudVisible;
  final QualityDebugStats? debugStats;
  final VoidCallback onToggleHud;
  final bool recordingActive;
  final bool viewerMode;

  const _MainStage({
    required this.textureId,
    required this.textureError,
    required this.isRetrying,
    required this.onRetryTexture,
    required this.meshStatus,
    required this.meshStatusBusy,
    required this.meshStatusError,
    required this.textureWidgetSize,
    required this.onScaleUpdate,
    required this.coverage,
    required this.debugHudVisible,
    required this.debugStats,
    required this.onToggleHud,
    required this.recordingActive,
    this.viewerMode = false,
  });

  @override
  Widget build(BuildContext context) {
    // Viewer mode: full-screen black canvas with full-screen scale gesture.
    // The Texture stays at its native IOSurface size (textureWidgetSize)
    // and is just centred — we don't upscale it because Flutter's Texture
    // widget has no intrinsic size and stretching a 256² IOSurface to a
    // phone-screen Rect would blur the GLB. Gestures are picked up across
    // the whole black region (not just the texture rectangle), which is
    // what users expect from an inspection viewer.
    if (viewerMode) {
      return Container(
        color: Colors.black,
        child: GestureDetector(
          onScaleUpdate: (d) => onScaleUpdate(
            d.scale,
            d.focalPointDelta,
            d.rotation,
            d.pointerCount,
            textureWidgetSize,
          ),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: textureId == null
                ? const SizedBox.shrink()
                : SizedBox(
                    width: textureWidgetSize.width,
                    height: textureWidgetSize.height,
                    child: Texture(textureId: textureId!),
                  ),
          ),
        ),
      );
    }
    return Stack(
      children: [
        // Camera preview placeholder — black with texture widget in
        // the center until a real camera plugin lands.
        Positioned.fill(
          child: GestureDetector(
            onLongPress: onToggleHud,
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: _ViewerBody(
                textureId: textureId,
                textureError: textureError,
                isRetrying: isRetrying,
                onRetry: onRetryTexture,
                size: textureWidgetSize,
                onScaleUpdate: onScaleUpdate,
                meshStatusBusy: meshStatusBusy,
              ),
            ),
          ),
        ),
        // Capture-only chrome: subject bounds hairline, recording badge,
        // dome / coverage map, mesh status pill. Viewer mode skips all of
        // these so the GLB stage is a clean inspection canvas.
        if (!viewerMode) ...[
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(painter: _ViewfinderGuidesPainter()),
            ),
          ),
          if (recordingActive)
            const Positioned(
              top: AetherSpacing.md,
              left: AetherSpacing.md,
              child: _RecordingBadge(),
            ),
          Positioned(
            top: AetherSpacing.md,
            right: AetherSpacing.md,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _FloatingMiniDome(coverage: coverage),
                if (debugHudVisible) ...[
                  const SizedBox(height: AetherSpacing.sm),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: QualityDebugOverlay(stats: debugStats),
                  ),
                ],
              ],
            ),
          ),
          if (meshStatus != null)
            Positioned(
              bottom: AetherSpacing.md,
              left: AetherSpacing.md,
              right: AetherSpacing.md,
              child: Align(
                child: _MeshStatusPill(
                  message: meshStatus!,
                  isBusy: meshStatusBusy,
                  isError: meshStatusError,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _ViewerBody extends StatelessWidget {
  final int? textureId;
  final String? textureError;
  final bool isRetrying;
  final VoidCallback onRetry;
  final Size size;
  final CaptureScaleCallback onScaleUpdate;
  final bool meshStatusBusy;

  const _ViewerBody({
    required this.textureId,
    required this.textureError,
    required this.isRetrying,
    required this.onRetry,
    required this.size,
    required this.onScaleUpdate,
    required this.meshStatusBusy,
  });

  @override
  Widget build(BuildContext context) {
    if (textureId == null) {
      return Container(
        width: size.width,
        height: size.height,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(AetherSpacing.lg),
        color: Colors.black,
        child: textureError != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    textureError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  const SizedBox(height: AetherSpacing.md),
                  ElevatedButton(
                    onPressed: isRetrying ? null : onRetry,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AetherColors.primary,
                    ),
                    child: Text(isRetrying ? '重试中…' : '重试'),
                  ),
                ],
              )
            : const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  SizedBox(height: AetherSpacing.sm),
                  Text(
                    '正在唤醒 3D 引擎…',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
      );
    }
    return SizedBox(
      width: size.width,
      height: size.height,
      child: GestureDetector(
        onScaleUpdate: (d) => onScaleUpdate(
          d.scale,
          d.focalPointDelta,
          d.rotation,
          d.pointerCount,
          size,
        ),
        child: Texture(textureId: textureId!),
      ),
    );
  }
}

class _FloatingMiniDome extends StatelessWidget {
  final CoverageMap coverage;

  const _FloatingMiniDome({required this.coverage});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 104,
      height: 104,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AetherRadii.lg),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 0.5,
        ),
      ),
      child: DomeView(coverage: coverage),
    );
  }
}

class _ViewfinderGuidesPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.24)
      ..strokeWidth = 0.8
      ..style = PaintingStyle.stroke;
    // Rule-of-thirds grid.
    final w = size.width;
    final h = size.height;
    canvas.drawLine(Offset(w / 3, 0), Offset(w / 3, h), paint);
    canvas.drawLine(Offset(w * 2 / 3, 0), Offset(w * 2 / 3, h), paint);
    canvas.drawLine(Offset(0, h / 3), Offset(w, h / 3), paint);
    canvas.drawLine(Offset(0, h * 2 / 3), Offset(w, h * 2 / 3), paint);
  }

  @override
  bool shouldRepaint(covariant _ViewfinderGuidesPainter old) => false;
}

class _RecordingBadge extends StatelessWidget {
  const _RecordingBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AetherColors.danger,
        borderRadius: BorderRadius.circular(AetherRadii.pill),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fiber_manual_record, size: 12, color: Colors.white),
          SizedBox(width: 4),
          Text(
            'REC',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

class _MeshStatusPill extends StatelessWidget {
  final String message;
  final bool isBusy;
  final bool isError;

  const _MeshStatusPill({
    required this.message,
    required this.isBusy,
    required this.isError,
  });

  @override
  Widget build(BuildContext context) {
    final color = isError
        ? AetherColors.danger
        : (isBusy ? Colors.white : Colors.white);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AetherRadii.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isBusy)
            SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(
                strokeWidth: 1.4,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            )
          else
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : Icons.check_circle_outline_rounded,
              size: 12,
              color: color,
            ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Guidance strip: hint + audit counters + progress ─────────────

class _GuidanceStrip extends StatelessWidget {
  final GuidanceSnapshot snap;
  final GuidanceAuditSummary audit;
  final bool recordingActive;

  const _GuidanceStrip({
    required this.snap,
    required this.audit,
    required this.recordingActive,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.lg,
        AetherSpacing.md,
        AetherSpacing.lg,
        AetherSpacing.sm,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                recordingActive
                    ? Icons.info_outline_rounded
                    : Icons.tips_and_updates_outlined,
                size: 16,
                color: AetherColors.textSecondary,
              ),
              const SizedBox(width: AetherSpacing.sm),
              Expanded(
                child: Text(
                  snap.hintText,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AetherColors.textPrimary,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: AetherSpacing.sm),
          Row(
            children: [
              _StatChip(
                label: '已采集',
                value: '${snap.acceptedFrames}',
              ),
              const SizedBox(width: AetherSpacing.sm),
              _StatChip(
                label: '完整度',
                value: '${(snap.orbitCompletion * 100).round()}%',
              ),
              const SizedBox(width: AetherSpacing.sm),
              _StatChip(
                label: '稳定',
                value: '${(snap.stabilityScore * 100).round()}%',
              ),
              const SizedBox(width: AetherSpacing.sm),
              _StatChip(
                label: '硬拒',
                value:
                    '${audit.hardRejectBlurCount + audit.hardRejectDarkCount + audit.hardRejectBrightCount + audit.hardRejectOccupancyCount}',
                dotColor: AetherColors.danger,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color? dotColor;

  const _StatChip({required this.label, required this.value, this.dotColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: AetherColors.bgElevated,
        borderRadius: BorderRadius.circular(AetherRadii.pill),
        border: Border.all(color: AetherColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              color: AetherColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 11,
              color: AetherColors.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Tool row ─────────────────────────────────────────────────────

class _CaptureToolbar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final tools = [
      (Icons.flash_off_rounded, l.captureToolFlash),
      (Icons.grid_on_rounded, l.captureToolGrid),
      (Icons.timer_outlined, l.captureToolTimer),
      (Icons.auto_fix_high_rounded, l.captureToolHdr),
      (Icons.model_training_rounded, l.captureToolCloudTraining),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.lg,
        AetherSpacing.xs,
        AetherSpacing.lg,
        AetherSpacing.sm,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AetherSpacing.md,
          vertical: AetherSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: AetherColors.bgElevated,
          borderRadius: BorderRadius.circular(AetherRadii.lg),
          border: Border.all(color: AetherColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: tools
              .map(
                (t) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(t.$1, size: 19, color: AetherColors.textPrimary),
                    const SizedBox(height: 2),
                    Text(t.$2, style: AetherTextStyles.caption),
                  ],
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

// ─── Record button row ────────────────────────────────────────────

class _RecordButtonRow extends StatelessWidget {
  final _RecordingState state;
  final VoidCallback onTap;
  final VoidCallback onOpenGallery;
  final VoidCallback onOpenSettings;

  const _RecordButtonRow({
    required this.state,
    required this.onTap,
    required this.onOpenGallery,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.xl,
        AetherSpacing.xs,
        AetherSpacing.xl,
        AetherSpacing.xl,
      ),
      child: Row(
        children: [
          _SideAction(
            icon: Icons.photo_library_outlined,
            label: AppL10n.of(context).captureRecordGallery,
            onTap: onOpenGallery,
          ),
          const Spacer(),
          _RecordButton(state: state, onTap: onTap),
          const Spacer(),
          _SideAction(
            icon: Icons.tune_rounded,
            label: AppL10n.of(context).captureRecordSettings,
            onTap: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

class _SideAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SideAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: AetherColors.bgElevated,
              shape: BoxShape.circle,
              border: Border.all(color: AetherColors.border),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 20, color: AetherColors.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(label, style: AetherTextStyles.caption),
        ],
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  final _RecordingState state;
  final VoidCallback onTap;

  const _RecordButton({required this.state, required this.onTap});

  @override
  Widget build(BuildContext context) {
    late final Widget inner;
    late final Color ringColor;
    switch (state) {
      case _RecordingState.idle:
        ringColor = AetherColors.primary;
        inner = Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(
            color: AetherColors.danger,
            shape: BoxShape.circle,
          ),
        );
      case _RecordingState.recording:
        ringColor = AetherColors.danger;
        inner = Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: AetherColors.danger,
            borderRadius: BorderRadius.circular(6),
          ),
        );
      case _RecordingState.finished:
        ringColor = AetherColors.primary;
        inner = Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(
            color: AetherColors.primary,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.check_rounded, color: Colors.white, size: 26),
        );
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 82,
        height: 82,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: ringColor, width: 4),
          boxShadow: [
            BoxShadow(
              color: ringColor.withValues(alpha: 0.28),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: inner,
      ),
    );
  }
}
