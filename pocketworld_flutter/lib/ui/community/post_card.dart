// PostCard — 1:1 square community card.
//
// Visual structure (bottom-up):
//   • Square frame (aspect 1:1).
//   • Background = live 3D rendering of the work's .glb via Thermion
//     (Filament-backed; renders into a Flutter Texture). Multiple
//     cards each run their own Filament View — they all stay live as
//     you scroll. Auto-rotate is on only for the "focused" card
//     (most-centered in viewport); the rest sit still. Cards that
//     fall below the visibility threshold drop the live viewer and
//     show a static thumbnail so we don't keep N Filament textures
//     alive off-screen.
//   • Glass info plate floats over the bottom of the model. Because
//     Thermion writes pixels into the Flutter framebuffer (not an iOS
//     hardware overlay like the previous WKWebView path), liquid_glass
//     can SAMPLE the helmet behind the plate for REAL refraction.
//
// Cross-platform: Thermion (Filament FFI on iOS / Android / macOS /
// Windows; WASM/WebGL on Web) + visibility_detector + Flutter stock
// widgets. HarmonyOS rides on whichever Flutter-on-ohos channel impl
// is current (officially unsupported by Thermion upstream).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../community/community_service.dart';
import '../../community/feed_models.dart';
import '../design_system.dart';
import 'live_model_view.dart';

class PostCard extends StatefulWidget {
  final FeedWork work;
  final CommunityService service;
  /// True when this card is the most-centered card in the feed —
  /// computed by the parent VaultPage from per-card visibility metrics.
  /// Drives ModelViewer autoRotate.
  final bool isFocused;
  /// Bubbled up so the parent can compute focus across cards.
  final void Function(double visibleFraction)? onVisibilityChanged;
  final ValueChanged<FeedWork>? onWorkUpdated;
  final VoidCallback? onTap;

  const PostCard({
    super.key,
    required this.work,
    required this.service,
    required this.isFocused,
    this.onVisibilityChanged,
    this.onWorkUpdated,
    this.onTap,
  });

  @override
  State<PostCard> createState() => _PostCardState();
}

class _PostCardState extends State<PostCard> {
  late FeedWork _work;
  bool _likeInflight = false;
  // Local visibility fraction. Drives whether we mount a live Filament
  // viewer (heavy: GPU + memory) or just show the placeholder (cheap).
  // Kept independent of isFocused — visibility is "is this on screen at
  // all", isFocused is "is this the most-centered one".
  double _visibility = 0;

  // Above this fraction, the card is on-screen enough that mounting a
  // live Thermion viewer is worth the Filament-instance cost. Tuned for
  // the 1:1 vertical scroll: two adjacent cards typically hover around
  // 0.4–0.6 each while the most-centered one is near 1.0, so threshold
  // 0.3 gives us ~3 live viewers max during a slow scroll, dropping to
  // 1–2 between snaps.
  static const double _liveMountThreshold = 0.3;

  // ─── Sticky-mount with delayed unmount ───────────────────────────────
  // Once a card has loaded a viewer, we keep it mounted for at least
  // [_unmountDelay] after it falls off-screen. This catches the
  // "user pushed detail page → feed visibility momentarily drops to
  // 0 → viewer would unmount → pop back → reload" pattern: the 5-second
  // grace window is long enough that any normal navigation transition
  // returns before the unmount fires, so the model stays loaded and
  // the user never sees the load-in cover.
  //
  // Real "scrolled past" cards still get released after the delay so
  // the feed doesn't grow unbounded GPU memory over a long session.
  bool _isLive = false;
  Timer? _unmountTimer;
  static const Duration _unmountDelay = Duration(seconds: 5);

  // Memoized so register/unregister see the same callback identity.
  // Without `late final`, every `_forceUnmount` tear-off would be a
  // fresh closure and the registry's _alive list could neither match
  // for unregister nor remove its own entry post-eviction.
  late final void Function() _forceUnmountCallback = _forceUnmount;

  @override
  void initState() {
    super.initState();
    _work = widget.work;
  }

  @override
  void didUpdateWidget(covariant PostCard old) {
    super.didUpdateWidget(old);
    if (!_likeInflight && widget.work.id == old.work.id) {
      _work = widget.work;
    } else if (widget.work.id != old.work.id) {
      _work = widget.work;
    }
  }

  Future<void> _toggleLike() async {
    if (_likeInflight) return;
    final wasLiked = _work.likedByMe;
    setState(() {
      _likeInflight = true;
      _work = _work.copyWith(
        likedByMe: !wasLiked,
        likesCount: _work.likesCount + (wasLiked ? -1 : 1),
      );
    });
    widget.onWorkUpdated?.call(_work);
    try {
      final nowLiked = await widget.service.toggleLike(
        workId: _work.id,
        currentlyLiked: wasLiked,
      );
      if (nowLiked != !wasLiked) {
        setState(() {
          _work = _work.copyWith(
            likedByMe: nowLiked,
            likesCount: _work.likesCount + (nowLiked ? 1 : -1),
          );
        });
        widget.onWorkUpdated?.call(_work);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _work = _work.copyWith(
          likedByMe: wasLiked,
          likesCount: _work.likesCount + (wasLiked ? 1 : -1),
        );
      });
      widget.onWorkUpdated?.call(_work);
    } finally {
      if (mounted) setState(() => _likeInflight = false);
    }
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    final next = info.visibleFraction;
    if ((next - _visibility).abs() > 0.02) {
      setState(() => _visibility = next);
    }
    widget.onVisibilityChanged?.call(next);

    // Sticky-mount logic: rising past the threshold mounts immediately
    // and cancels any pending unmount; falling below schedules an
    // unmount but only after [_unmountDelay] elapses with the card
    // still off-screen. Detail-page push/pop is well under that delay,
    // so the model stays loaded across navigation transitions.
    if (next >= _liveMountThreshold) {
      _unmountTimer?.cancel();
      _unmountTimer = null;
      if (!_isLive) _setLive(true);
    } else if (_isLive && _unmountTimer == null) {
      _unmountTimer = Timer(_unmountDelay, () {
        if (mounted) _setLive(false);
        _unmountTimer = null;
      });
    }
  }

  /// Coalesces _isLive setState with the global instance registry.
  /// Going live → register, may evict the LRU peer (which calls back
  /// into _forceUnmount on the victim). Going dead → unregister.
  void _setLive(bool next) {
    if (next == _isLive) return;
    if (next) {
      _LiveInstanceRegistry.register(_forceUnmountCallback);
    } else {
      _LiveInstanceRegistry.unregister(_forceUnmountCallback);
    }
    setState(() => _isLive = next);
  }

  /// Called by _LiveInstanceRegistry when this card is the LRU peer
  /// being evicted to make room for a newly-mounted card. The registry
  /// has already removed our callback from its _alive list, so we just
  /// flip _isLive false (which unmounts the LiveModelView) without
  /// re-routing through unregister.
  void _forceUnmount() {
    if (!mounted || !_isLive) return;
    setState(() => _isLive = false);
  }

  @override
  void dispose() {
    _unmountTimer?.cancel();
    _unmountTimer = null;
    if (_isLive) {
      _LiveInstanceRegistry.unregister(_forceUnmountCallback);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final modelPath = _work.modelStoragePath;
    final modelUrl =
        modelPath == null ? null : widget.service.modelUrlFor(modelPath);
    final shouldMountLive = _isLive && modelUrl != null;

    return VisibilityDetector(
      key: Key('post-card-${_work.id}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AspectRatio(
          aspectRatio: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AetherRadii.lg),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (shouldMountLive)
                  // LiveModelView with manipulatorType: NONE has no
                  // built-in gestures, so the parent GestureDetector
                  // (single-tap → detail page) wins on its own. No
                  // IgnorePointer needed here — Thermion writes to a
                  // Texture, not a WKWebView, so iOS long-press/text-
                  // select can't latch onto it.
                  LiveModelView(
                    key: ValueKey('mv-${_work.id}'),
                    modelUrl: modelUrl,
                    autoRotate: widget.isFocused,
                  )
                else
                  const _ThumbnailPlaceholder(),
                // Inset from the card edges so the plate reads as a
                // separate floating element, not a banner glued to the
                // bottom. Matches the user's "嵌套关系" sketch.
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: _GlassInfoPlate(
                    work: _work,
                    likeBusy: _likeInflight,
                    onToggleLike: _toggleLike,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.grey.shade100, Colors.grey.shade200],
        ),
      ),
      child: const Center(
        child: Icon(
          Icons.view_in_ar_rounded,
          color: AetherColors.textTertiary,
          size: 48,
        ),
      ),
    );
  }
}

class _GlassInfoPlate extends StatelessWidget {
  final FeedWork work;
  final bool likeBusy;
  final VoidCallback onToggleLike;

  const _GlassInfoPlate({
    required this.work,
    required this.likeBusy,
    required this.onToggleLike,
  });

  @override
  Widget build(BuildContext context) {
    // Real-refraction glass via liquid_glass_renderer (GPU shader,
    // Impeller-only). Aligned with demos/glass.html parameters (the
    // user's reference Three.js MeshPhysicalMaterial demo):
    //
    //   demos/glass.html slider value  →  Flutter setting
    //   ───────────────────────────────────────────────────────
    //   thickness 3.0 (slider max)     →  thickness: 20
    //   ior 1.20                        →  refractiveIndex: 1.20
    //   roughness 0.30                  →  blur: 4
    //   attenuationColor 0xffffff       →  glassColor 0x08FFFFFF
    //                                       (3% white α — Three.js's
    //                                       attenuation is a TINT not a
    //                                       cover, so we use the
    //                                       lowest-α "barely there"
    //                                       white that still keeps the
    //                                       black text on the plate
    //                                       legible against the helmet)
    //   center thickness 0.50           →  lightIntensity 1.0 (default;
    //                                       MeshPhysicalMaterial doesn't
    //                                       expose a separate "center
    //                                       thickness" knob and our
    //                                       shader uses unit-thickness
    //                                       highlight intensity)
    //   squircle n=8.0                  →  LiquidRoundedSuperellipse
    //                                       borderRadius: 20 (corner
    //                                       roundness for the plate)
    //
    // User feedback path on this:
    //   • "更厚" → thickness 20→50  (overshot)
    //   • "更透明 + 太厚了" → thickness 50→20, α 0x14→0x08, IOR 1.45→1.20
    return LiquidGlassLayer(
      settings: const LiquidGlassSettings(
        thickness: 20,
        blur: 4,
        glassColor: Color(0x08FFFFFF),
        refractiveIndex: 1.20,
        lightIntensity: 1.0,
        saturation: 1.0,
      ),
      child: LiquidGlass(
        shape: const LiquidRoundedSuperellipse(borderRadius: 20),
        glassContainsChild: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      work.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: AetherColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${work.authorDisplayName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: AetherColors.textSecondary,
                      ),
                    ),
                    if (work.description != null &&
                        work.description!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        work.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w400,
                          color: AetherColors.textSecondary,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _LikeButton(
                    liked: work.likedByMe,
                    count: work.likesCount,
                    busy: likeBusy,
                    onTap: onToggleLike,
                  ),
                  const SizedBox(height: 4),
                  _ViewsChip(count: work.viewsCount),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LikeButton extends StatelessWidget {
  final bool liked;
  final int count;
  final bool busy;
  final VoidCallback onTap;

  const _LikeButton({
    required this.liked,
    required this.count,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              liked ? Icons.favorite_rounded : Icons.favorite_outline_rounded,
              size: 22,
              color: liked
                  ? AetherColors.danger
                  : AetherColors.textPrimary,
            ),
            const SizedBox(height: 2),
            Text(
              _formatCount(count),
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AetherColors.textPrimary,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatCount(int n) {
    if (n < 1000) return '$n';
    if (n < 10000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '${(n / 1000).round()}K';
  }
}

class _ViewsChip extends StatelessWidget {
  final int count;
  const _ViewsChip({required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.remove_red_eye_outlined,
            size: 18,
            color: AetherColors.textSecondary,
          ),
          const SizedBox(height: 2),
          Text(
            _LikeButton._formatCount(count),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AetherColors.textSecondary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Hard cap on simultaneously alive LiveModelView instances across the
/// whole app. Each one holds a Filament swap chain + 60fps render
/// thread; the visibility-driven _unmountTimer (5s grace) usually
/// keeps us in 1–3 range, but a fast fling-scroll past 6+ cards in
/// <1s briefly mounts all of them. That's been observed to spike GPU
/// and occasionally provoke thermion's "Object doesn't exist (double
/// free?)" RenderThread panic. The registry forces an immediate
/// eviction of the LRU peer so we never go above [_maxAlive] in
/// flight, regardless of scroll speed.
///
/// Number cited from compose-reels (manjees/compose-reels), an open-
/// source Jetpack Compose Reels implementation. Its README defines
/// `playerPoolSize >= (preloadCount * 2) + 1`; with preloadCount=2
/// (preload 2 ahead + 2 behind) that evaluates to 5 — the visible
/// card plus the four cards we'd want pre/post-loaded around it.
/// compose-reels itself defaults to 7 with two extra fling-time
/// slots, but our Filament viewer is heavier than ExoPlayer (full
/// Filament Engine + scene + IBL state per instance vs. ExoPlayer's
/// shared codec resources), so we take the hard minimum.
///
/// References:
///   • https://github.com/manjees/compose-reels (README — Configuration)
class _LiveInstanceRegistry {
  static const int _maxAlive = 5;
  static final List<void Function()> _alive = <void Function()>[];

  static void register(void Function() forceUnmount) {
    _alive.add(forceUnmount);
    while (_alive.length > _maxAlive) {
      // Evict the head (oldest mounted card) — list is insertion-
      // ordered so removeAt(0) is the LRU.
      final victim = _alive.removeAt(0);
      victim();
    }
  }

  static void unregister(void Function() forceUnmount) {
    _alive.remove(forceUnmount);
  }
}
