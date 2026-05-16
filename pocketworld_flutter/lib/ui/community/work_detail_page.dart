// WorkDetailPage — full-screen 3D viewer for a single work.
//
// Pushed when the user taps a PostCard in the community feed. White
// background, AetherCppCardDemo (aether_cpp scene renderer) filling
// the safe area, auto-rotate on so the user can see the model from
// all angles without gestures.
//
// Migrated from LiveModelView (thermion) to AetherCppCardDemo on
// 2026-05-02 because thermion's GLB loader doesn't apply node
// transforms (the cgltf scene-walk fix only lives in aether_cpp's
// glb_loader.cpp), so e.g. the Khronos ToyCar arrived with
// sphereR=540 and tripped thermion into "Error: invalid renderable"
// on iOS 17+. The cost: orbit / pinch gestures are temporarily gone
// — auto-rotate substitutes. Adding orbit to AetherCppCardDemo is a
// follow-up tracked in PHASE_FLUTTER_VIEWER_PLAN.md G9.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../community/community_service.dart';
import '../../community/feed_models.dart';
import '../../community/thumb_baker.dart';
import '../design_system.dart';
import 'aether_cpp_card_demo.dart';
import 'viewer_impl.dart';

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
  // Phase 6.4f.10 — first-viewer thumbnail baker. Fires once when the
  // viewer signals first-frame-ready IF the work has no thumb yet AND
  // the current user is the work owner (RLS gate). After successful
  // bake, all feed viewers see the JPG instead of the gradient
  // fallback that the user reported as "灰色" on 2026-05-04.
  late final ThumbBaker _thumbBaker = ThumbBaker(service: widget.service);

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

  /// Phase 6.4f.10 — fires when AetherCppCardDemo's underlying viewer
  /// has painted its first frame into the IOSurface. Hands off to
  /// ThumbBaker which checks the gate conditions (no existing thumb +
  /// caller is owner) and skips quietly if either fails.
  void _onViewerReady(AetherCppViewerImpl viewer) {
    unawaited(_thumbBaker.maybeBake(
      work: widget.work,
      viewer: viewer,
    ));
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
                  : AetherCppCardDemo(
                      key: ValueKey('detail-aether-${widget.work.id}'),
                      modelUrl: modelUrl,
                      // Detail page: orbit + pinch gestures, no
                      // auto-rotate. Ported 2026-05-02 from the
                      // LiveModelView path.
                      interactive: true,
                      // Phase 6.4f.10 — bake feed thumbnail on first
                      // valid frame. ThumbBaker.maybeBake() checks
                      // pre-conditions (work has no thumb yet + caller
                      // is owner) and silently skips if either fails.
                      onViewerReady: _onViewerReady,
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
