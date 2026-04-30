// Flutter port of ScanRecordCell.swift — the waterfall-gallery card.
//
// Visual rules (black & white minimalist — 2026-04-27 direction):
//   • white background, 32pt radius, hairline shadow
//   • thumbnail placeholder = neutral gray gradient + muted cube glyph
//     (no chroma). Swap for real image loader when backend ships.
//   • status badge top-right when a job is in flight — near-black pill,
//     white text. Danger state (failed) flips to the one allowed accent
//     (AetherColors.danger) so failure never blends in.
//   • info block: 15pt semibold name + 12pt secondary subtitle.

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'design_system.dart';
import 'scan_record.dart';

class ScanRecordCell extends StatelessWidget {
  final ScanRecord record;
  final String subtitle;
  final double imageHeight;
  final VoidCallback? onTap;

  /// When false, hide the top-right "已完成 / Training / Failed" pill
  /// and the pipeline-stage progress strip. The community feed sets
  /// this false so public cards stay clean (visitors don't need to
  /// see other authors' authoring state); the "我的作品" grid under
  /// Me keeps it true so the owner sees their own processing state.
  final bool showStatusBadge;

  const ScanRecordCell({
    super.key,
    required this.record,
    required this.subtitle,
    required this.imageHeight,
    this.onTap,
    this.showStatusBadge = true,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
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
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AetherRadii.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ThumbnailSection(
                record: record,
                imageHeight: imageHeight,
                showStatusBadge: showStatusBadge,
              ),
              _InfoSection(
                record: record,
                subtitle: subtitle,
                showPipelineStage: showStatusBadge,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThumbnailSection extends StatelessWidget {
  final ScanRecord record;
  final double imageHeight;
  final bool showStatusBadge;

  const _ThumbnailSection({
    required this.record,
    required this.imageHeight,
    required this.showStatusBadge,
  });

  @override
  Widget build(BuildContext context) {
    final status = record.jobStatus;
    final dimmed = status == ScanJobStatus.failed;
    return SizedBox(
      height: imageHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Opacity(
            opacity: dimmed ? 0.55 : 1.0,
            child: _PlaceholderThumbnail(mode: record.preferredCaptureMode),
          ),
          if (showStatusBadge && status != null)
            Positioned(
              top: AetherSpacing.md,
              right: AetherSpacing.md,
              child: _StatusBadge(status: status),
            ),
          if (showStatusBadge &&
              record.hasCompletedArtifact &&
              status == null)
            const Positioned(
              top: AetherSpacing.md,
              right: AetherSpacing.md,
              child: _CompletedBadge(),
            ),
        ],
      ),
    );
  }
}

/// Gray-scale gradient placeholder with a subtle dot-grid overlay that
/// visually hints at "point cloud / scanning". Keeps the card from
/// looking broken while we have no real thumbnails.
class _PlaceholderThumbnail extends StatelessWidget {
  final CaptureMode mode;

  const _PlaceholderThumbnail({required this.mode});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: AetherGradients.thumbnailPlaceholder,
          ),
        ),
        const Positioned.fill(
          child: CustomPaint(painter: _DotPointCloudPainter()),
        ),
        Center(
          child: Icon(
            mode.icon,
            size: 36,
            color: Colors.white.withValues(alpha: 0.78),
          ),
        ),
      ],
    );
  }
}

/// Deterministic "point cloud" dots. Stable across rebuilds so the
/// waterfall doesn't flicker.
class _DotPointCloudPainter extends CustomPainter {
  const _DotPointCloudPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.22);
    // Simple hash-walk. Not pretty, just consistent.
    int x = 0x9e3779b1;
    for (int i = 0; i < 110; i++) {
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      final px = (x % 1000) / 1000.0 * size.width;
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      final py = (x % 1000) / 1000.0 * size.height;
      x = (x * 1103515245 + 12345) & 0x7fffffff;
      final r = 0.7 + (x % 15) / 10.0;
      canvas.drawCircle(Offset(px, py), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DotPointCloudPainter old) => false;
}

class _StatusBadge extends StatelessWidget {
  final ScanJobStatus status;

  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final isFailed = status == ScanJobStatus.failed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: isFailed ? AetherColors.danger : AetherColors.primary,
        borderRadius: BorderRadius.circular(AetherRadii.pill),
        boxShadow: [
          BoxShadow(
            color: AetherColors.shadow,
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status.isRunning) ...[
            const SizedBox(
              width: 8,
              height: 8,
              child: CircularProgressIndicator(
                strokeWidth: 1.2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(status.localizedTitle(AppL10n.of(context)),
              style: AetherTextStyles.pill),
        ],
      ),
    );
  }
}

class _CompletedBadge extends StatelessWidget {
  const _CompletedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(AetherRadii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_rounded,
              size: 12, color: AetherColors.primary),
          const SizedBox(width: 4),
          Text(
            AppL10n.of(context).scanLifecycleCompleted,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AetherColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoSection extends StatelessWidget {
  final ScanRecord record;
  final String subtitle;
  final bool showPipelineStage;

  const _InfoSection({
    required this.record,
    required this.subtitle,
    required this.showPipelineStage,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AetherSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            record.name,
            style: AetherTextStyles.cardTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (record.authorHandle != null) ...[
            const SizedBox(height: 2),
            Text(
              record.authorHandle!,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AetherColors.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: AetherTextStyles.caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (record.caption != null && record.caption!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              record.caption!,
              style: AetherTextStyles.bodySm,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          if (showPipelineStage &&
              record.pipelineStage != null &&
              (record.jobStatus == ScanJobStatus.training ||
                  record.jobStatus == ScanJobStatus.packaging ||
                  record.jobStatus == ScanJobStatus.uploading)) ...[
            const SizedBox(height: 4),
            Text(
              record.pipelineStage!,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AetherColors.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
