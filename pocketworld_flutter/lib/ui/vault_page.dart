// VaultPage — community feed (the "社区 / Community" tab).
//
// 2026-04-30 redesign:
//   • Sticky top: search bar + 3-tab segmented control (热门 / 附近 /
//     发现). Tapping a tab refetches the feed with a different sort key;
//     "附近 / Nearby" is a coming-soon stub since profiles.location is
//     plain text and we have no geo schema yet.
//   • Below: the same vertical PostCard list as before, sourced from
//     CommunityService.fetchPublicFeed(sortBy, query).
//
// Cross-platform: pure Flutter widgets + supabase_flutter. No native
// code, no platform conditionals — same UI on iOS / Android / HarmonyOS
// / Web.

import 'package:flutter/material.dart' hide View;
// thermion_flutter re-declares `VoidCallback` as an ffi pointer typedef,
// which clashes with Flutter's `void Function()` typedef of the same
// name. We don't use thermion's version here, so hide it.
import 'package:thermion_flutter/thermion_flutter.dart' hide VoidCallback;
import 'package:vector_math/vector_math_64.dart' as v64;

import '../community/anchor_viewer.dart';
import '../community/community_service.dart';
import '../community/feed_models.dart';
import '../l10n/app_localizations.dart';
import 'community/post_card.dart';
import 'community/work_detail_page.dart';
import 'design_system.dart';

enum _CommunityTab { hot, nearby, discover }

class VaultPage extends StatefulWidget {
  const VaultPage({super.key});

  @override
  State<VaultPage> createState() => _VaultPageState();
}

class _VaultPageState extends State<VaultPage> {
  final CommunityService _service = CommunityService();
  final TextEditingController _searchController = TextEditingController();
  late Future<List<FeedWork>> _feed;
  _CommunityTab _tab = _CommunityTab.discover;
  String _query = '';

  // Per-card visibility tracking. PostCards report their visibility
  // fraction via onVisibilityChanged; we pick the highest-visibility
  // work as the "focused" one (Polycam-style — the most-centered card
  // is the one whose 3D model auto-rotates).
  final Map<String, double> _visibilityByWorkId = {};
  String? _focusedWorkId;
  static const double _focusThreshold = 0.55;

  @override
  void initState() {
    super.initState();
    _feed = _loadFeed();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<List<FeedWork>> _loadFeed() {
    if (_tab == _CommunityTab.nearby) {
      // Geo schema isn't in place yet; return empty so the coming-soon
      // state takes over without burning a query.
      return Future.value(const <FeedWork>[]);
    }
    return _service.fetchPublicFeed(
      limit: 20,
      sortBy: _tab == _CommunityTab.hot ? FeedSort.hot : FeedSort.recent,
      query: _query.isEmpty ? null : _query,
    );
  }

  Future<void> _refresh() async {
    final next = _loadFeed();
    setState(() {
      _feed = next;
      _visibilityByWorkId.clear();
      _focusedWorkId = null;
    });
    await next;
  }

  void _onTabChanged(_CommunityTab next) {
    if (next == _tab) return;
    setState(() {
      _tab = next;
      _feed = _loadFeed();
      _visibilityByWorkId.clear();
      _focusedWorkId = null;
    });
  }

  void _onQuerySubmitted(String value) {
    final trimmed = value.trim();
    if (trimmed == _query) return;
    setState(() {
      _query = trimmed;
      _feed = _loadFeed();
      _visibilityByWorkId.clear();
      _focusedWorkId = null;
    });
  }

  void _onClearQuery() {
    if (_query.isEmpty && _searchController.text.isEmpty) return;
    _searchController.clear();
    setState(() {
      _query = '';
      _feed = _loadFeed();
      _visibilityByWorkId.clear();
      _focusedWorkId = null;
    });
  }

  /// Recompute which card should rotate. Picks the card with the highest
  /// visibility fraction above the focus threshold.
  void _recomputeFocus() {
    String? next;
    double bestVisibility = _focusThreshold;
    for (final entry in _visibilityByWorkId.entries) {
      if (entry.value > bestVisibility) {
        bestVisibility = entry.value;
        next = entry.key;
      }
    }
    if (next != _focusedWorkId) {
      setState(() => _focusedWorkId = next);
    }
  }

  void _onCardVisibilityChanged(String workId, double fraction) {
    _visibilityByWorkId[workId] = fraction;
    _recomputeFocus();
  }

  void _onWorkUpdated(int index, FeedWork updated) {
    // PostCard already keeps its own copy in State so the parent doesn't
    // need to rebuild on a like toggle. Hook left in for the day we
    // hoist feed state into a ChangeNotifier.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AetherSpacing.lg,
                    AetherSpacing.md,
                    AetherSpacing.lg,
                    AetherSpacing.sm,
                  ),
                  child: _SearchBar(
                    controller: _searchController,
                    hasQuery: _query.isNotEmpty,
                    onSubmitted: _onQuerySubmitted,
                    onClear: _onClearQuery,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AetherSpacing.lg,
                    0,
                    AetherSpacing.lg,
                    AetherSpacing.sm,
                  ),
                  child: _CommunityTabBar(
                    selected: _tab,
                    onChanged: _onTabChanged,
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _refresh,
                    child: _buildFeed(),
                  ),
                ),
              ],
            ),
            // 1×1 invisible "anchor" Filament viewer. Stays mounted for
            // the lifetime of VaultPage; every shared .glb asset is
            // loaded through it (lib/community/glb_asset_cache.dart).
            const Positioned(
              left: 0,
              top: 0,
              width: 1,
              height: 1,
              child: IgnorePointer(child: _AnchorHost()),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeed() {
    return FutureBuilder<List<FeedWork>>(
      future: _feed,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _LoadingState();
        }
        if (snap.hasError) {
          return _ErrorState(
            message: snap.error.toString(),
            onRetry: _refresh,
          );
        }
        final works = snap.data ?? const <FeedWork>[];
        if (_tab == _CommunityTab.nearby) {
          return const _NearbyComingSoonState();
        }
        if (works.isEmpty) {
          return const _EmptyState();
        }
        return ListView.separated(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(
            AetherSpacing.lg,
            AetherSpacing.md,
            AetherSpacing.lg,
            140,
          ),
          itemCount: works.length,
          separatorBuilder: (_, _) =>
              const SizedBox(height: AetherSpacing.lg),
          itemBuilder: (ctx, i) {
            final w = works[i];
            return PostCard(
              work: w,
              service: _service,
              isFocused: _focusedWorkId == w.id,
              onVisibilityChanged: (fraction) =>
                  _onCardVisibilityChanged(w.id, fraction),
              onWorkUpdated: (updated) => _onWorkUpdated(i, updated),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      WorkDetailPage(work: w, service: _service),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final bool hasQuery;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onClear;

  const _SearchBar({
    required this.controller,
    required this.hasQuery,
    required this.onSubmitted,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: AetherColors.bgElevated,
        borderRadius: BorderRadius.circular(AetherRadii.pill),
        border: Border.all(color: AetherColors.border),
      ),
      child: Row(
        children: [
          const SizedBox(width: AetherSpacing.md),
          const Icon(
            Icons.search_rounded,
            size: 18,
            color: AetherColors.textTertiary,
          ),
          const SizedBox(width: AetherSpacing.sm),
          Expanded(
            child: TextField(
              controller: controller,
              textInputAction: TextInputAction.search,
              onSubmitted: onSubmitted,
              style: AetherTextStyles.body,
              decoration: InputDecoration(
                hintText: l.communitySearchHint,
                hintStyle: AetherTextStyles.body.copyWith(
                  color: AetherColors.textTertiary,
                ),
                isDense: true,
                border: InputBorder.none,
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
          if (hasQuery)
            GestureDetector(
              onTap: onClear,
              behavior: HitTestBehavior.opaque,
              child: const Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: AetherSpacing.md,
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: AetherColors.textTertiary,
                ),
              ),
            )
          else
            const SizedBox(width: AetherSpacing.md),
        ],
      ),
    );
  }
}

class _CommunityTabBar extends StatelessWidget {
  final _CommunityTab selected;
  final ValueChanged<_CommunityTab> onChanged;

  const _CommunityTabBar({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final tabs = <(_CommunityTab, String)>[
      (_CommunityTab.hot, l.communityTabHot),
      (_CommunityTab.nearby, l.communityTabNearby),
      (_CommunityTab.discover, l.communityTabDiscover),
    ];
    return Row(
      children: [
        for (int i = 0; i < tabs.length; i++) ...[
          Expanded(
            child: _CommunityTabPill(
              label: tabs[i].$2,
              selected: tabs[i].$1 == selected,
              onTap: () => onChanged(tabs[i].$1),
            ),
          ),
          if (i < tabs.length - 1) const SizedBox(width: AetherSpacing.sm),
        ],
      ],
    );
  }
}

class _CommunityTabPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CommunityTabPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? AetherColors.primary : AetherColors.bgElevated,
          borderRadius: BorderRadius.circular(AetherRadii.pill),
          border: Border.all(
            color: selected ? AetherColors.primary : AetherColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected
                ? AetherColors.bgCanvas
                : AetherColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Mounts the long-lived "anchor" Filament viewer that owns every shared
/// .glb asset in this session. Its ViewerWidget is sized 1×1 inside an
/// IgnorePointer in VaultPage's Stack, so it doesn't show or steal hit
/// tests, but the underlying Filament viewer stays alive for as long as
/// the community feed page is on the route stack.
class _AnchorHost extends StatelessWidget {
  const _AnchorHost();

  @override
  Widget build(BuildContext context) {
    return ViewerWidget(
      initial: const SizedBox.shrink(),
      background: const Color(0x00000000),
      manipulatorType: ManipulatorType.NONE,
      transformToUnitCube: false,
      postProcessing: false,
      destroyEngineOnUnload: false,
      initialCameraPosition: v64.Vector3(0, 0, 5),
      onViewerAvailable: (v) async {
        AnchorViewer.set(v);
      },
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      // Has to be scrollable so RefreshIndicator works above an empty
      // initial state.
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 200),
        Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(AetherColors.primary),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 160),
        const Icon(
          Icons.view_in_ar_rounded,
          size: 56,
          color: AetherColors.textTertiary,
        ),
        const SizedBox(height: AetherSpacing.lg),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              l.communityEmptyTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AetherColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _NearbyComingSoonState extends StatelessWidget {
  const _NearbyComingSoonState();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 160),
        const Icon(
          Icons.near_me_outlined,
          size: 56,
          color: AetherColors.textTertiary,
        ),
        const SizedBox(height: AetherSpacing.lg),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              l.communityNearbyComingSoon,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AetherColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 160),
        const Icon(Icons.error_outline_rounded,
            size: 48, color: AetherColors.danger),
        const SizedBox(height: AetherSpacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: AetherColors.textTertiary,
            ),
          ),
        ),
        const SizedBox(height: AetherSpacing.lg),
        Center(
          child: TextButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ),
      ],
    );
  }
}
