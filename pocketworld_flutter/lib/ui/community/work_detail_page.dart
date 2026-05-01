// WorkDetailPage — full-screen 3D viewer for a single work.
//
// Pushed when the user taps a PostCard in the community feed. White
// background, LiveModelView (Thermion / Filament) filling the safe
// area, ORBIT manipulator on (drag to orbit, pinch to zoom). Auto-
// rotate off — the user drives.
//
// Cross-platform: same Thermion-backed LiveModelView as PostCard, so
// iOS / Android / Web all render identically.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../community/community_service.dart';
import '../../community/feed_models.dart';
import '../design_system.dart';
import 'live_model_view.dart';

class WorkDetailPage extends StatefulWidget {
  final FeedWork work;
  final CommunityService service;

  const WorkDetailPage({
    super.key,
    required this.work,
    required this.service,
  });

  @override
  State<WorkDetailPage> createState() => _WorkDetailPageState();
}

class _WorkDetailPageState extends State<WorkDetailPage> {
  late int _viewsCount = widget.work.viewsCount;

  @override
  void initState() {
    super.initState();
    // Record a view as soon as the page mounts. The hour-bucket dedup
    // makes this safe to call unconditionally; we still update the
    // local view count if the server reports a bump.
    unawaited(_recordView());
  }

  Future<void> _recordView() async {
    final updated = await widget.service.recordView(widget.work.id);
    if (!mounted || updated == null) return;
    if (updated != _viewsCount) setState(() => _viewsCount = updated);
  }

  @override
  Widget build(BuildContext context) {
    final modelPath = widget.work.modelStoragePath;
    final modelUrl =
        modelPath == null ? null : widget.service.modelUrlFor(modelPath);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.chevron_left_rounded,
            color: AetherColors.textPrimary,
          ),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          widget.work.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: AetherColors.textPrimary,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: modelUrl == null
                  ? const _NoModelState()
                  : LiveModelView(
                      key: ValueKey('detail-${widget.work.id}'),
                      modelUrl: modelUrl,
                      interactive: true,
                      cameraDistance: 5.0,
                      // User-captured scans ship baked lighting in
                      // their baseColor. Stacking IBL on top double-
                      // lights the model — see LiveModelView's
                      // useEnvironmentLighting doc.
                      useEnvironmentLighting: false,
                    ),
            ),
            _MetaRow(
              viewsCount: _viewsCount,
              likesCount: widget.work.likesCount,
              author: widget.work.authorDisplayName,
              description: widget.work.description,
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final int viewsCount;
  final int likesCount;
  final String author;
  final String? description;

  const _MetaRow({
    required this.viewsCount,
    required this.likesCount,
    required this.author,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          top: BorderSide(color: AetherColors.border, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  author,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AetherColors.textPrimary,
                  ),
                ),
              ),
              _CountChip(
                icon: Icons.remove_red_eye_outlined,
                value: viewsCount,
              ),
              const SizedBox(width: 12),
              _CountChip(
                icon: Icons.favorite_border_rounded,
                value: likesCount,
              ),
            ],
          ),
          if (description != null && description!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              description!,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: AetherTextStyles.bodySm,
            ),
          ],
        ],
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  final IconData icon;
  final int value;
  const _CountChip({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: AetherColors.textSecondary),
        const SizedBox(width: 4),
        Text(
          '$value',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AetherColors.textSecondary,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _NoModelState extends StatelessWidget {
  const _NoModelState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.view_in_ar_rounded,
            size: 56,
            color: AetherColors.textTertiary,
          ),
          SizedBox(height: AetherSpacing.md),
          Text(
            'Model unavailable',
            style: TextStyle(
              fontSize: 13,
              color: AetherColors.textTertiary,
            ),
          ),
        ],
      ),
    );
  }
}
