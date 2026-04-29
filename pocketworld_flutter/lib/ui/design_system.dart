// Aether3D design system — black & white minimalist tokens + Design Inspector.
//
// Inspired by the TestFlight (SwiftUI) prototype's chrome palette, but
// the user has further constrained the visual direction to "strictly
// black & white, maximally minimal, let the details be decided later".
//
// When Figma designs land, **replace the token classes** (AetherColors /
// AetherSpacing / AetherRadii / AetherTextStyles / AetherGradients) —
// most widgets read tokens through these constants, so a swap
// propagates automatically.
//
// The `DesignInspector` / `DesignBox` widgets at the bottom remain an
// opt-in dev tool: tap the 🎨 floating button to toggle a dashed-border
// overlay that tags each UI region with a role (customizable / partial /
// iOS-locked / backend-needed). Remove the Inspector chrome when Figma
// designs freeze; `DesignBox` calls are no-ops when Inspector is off,
// so leaving them in place through the redesign costs nothing.

import 'package:flutter/material.dart';

// ─── Color tokens ───────────────────────────────────────────────────
//
// Strict grayscale. Single accent color reserved for destructive state
// (danger) so failure never gets lost visually. Keep gray ramp shallow
// but varied enough to layer cards over background without needing
// borders everywhere.

class AetherColors {
  AetherColors._();

  // Surfaces — near-white / white / soft gray (light theme).
  static const Color bg = Color(0xFFFAFAFA); // app背景 — 暖白
  static const Color bgCanvas = Color(0xFFFFFFFF); // 卡片 / sheet / modal
  static const Color bgElevated = Color(0xFFF3F3F2); // 第三层 — 内嵌面板
  static const Color bgOverlay = Color(0xE6FAFAFA); // 半透明覆盖

  // Ink — pure(ish) blacks for type and primary actions.
  static const Color primary = Color(0xFF111111); // 近黑 主色
  static const Color primarySoft = Color(0xFF3A3A3A); // 深灰 按下/secondary

  // Text ramp.
  static const Color textPrimary = Color(0xFF111111);
  static const Color textSecondary = Color(0xFF6B6B6B);
  static const Color textTertiary = Color(0xFF9B9B9B);

  // Borders / dividers — hairline light gray.
  static const Color border = Color(0xFFE4E4E4);
  static const Color borderStrong = Color(0xFFCCCCCC);

  // Shadows — intentional, very gentle.
  static const Color shadow = Color(0x14000000); // alpha ~8% black

  // Status — minimal. Danger is the one allowed chromatic accent, so
  // failure states can't be misread as "just another card". Success /
  // info stay grayscale and rely on iconography.
  static const Color danger = Color(0xFFC83E3E);
  static const Color success = Color(0xFF111111);
  static const Color warning = Color(0xFF6B6B6B);
  static const Color info = Color(0xFF6B6B6B);

  // Inspector (dev-time overlay colors — intentionally chromatic so the
  // overlay is unmissable against the black-and-white chrome).
  static const Color inspCustomizable = Color(0xFF34D399); // 绿 — 全可定制
  static const Color inspPartial = Color(0xFFFBBF24); // 黄 — 部分可改
  static const Color inspLocked = Color(0xFFF87171); // 红 — iOS 系统锁
  static const Color inspBackend = Color(0xFF3B82F6); // 蓝 — 需后端接入
}

class AetherSpacing {
  AetherSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double huge = 48;
}

class AetherRadii {
  AetherRadii._();

  static const double sm = 12;
  static const double md = 18;
  static const double lg = 24;
  static const double xl = 32;
  static const double pill = 999;
}

class AetherTextStyles {
  AetherTextStyles._();

  // Wordmark — set very large and bold, mimics "AETHER3D" header in the
  // SwiftUI prototype (26pt rounded, letterSpacing -0.7). We don't ship
  // SF Pro Rounded on Flutter by default — the default system font on
  // iOS Flutter IS SF Pro, so the "rounded" look is achieved via weight
  // + letterSpacing; Figma phase can decide whether to bundle a
  // rounded-variant webfont.
  static const TextStyle wordmark = TextStyle(
    fontSize: 26,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.9,
    color: AetherColors.primary,
  );

  static const TextStyle displayLarge = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    color: AetherColors.textPrimary,
  );
  static const TextStyle h1 = TextStyle(
    fontSize: 23,
    fontWeight: FontWeight.w700,
    color: AetherColors.textPrimary,
  );
  static const TextStyle h2 = TextStyle(
    fontSize: 19,
    fontWeight: FontWeight.w700,
    color: AetherColors.textPrimary,
  );
  static const TextStyle h3 = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    color: AetherColors.textPrimary,
  );
  static const TextStyle cardTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: AetherColors.textPrimary,
    height: 1.25,
  );
  static const TextStyle body = TextStyle(
    fontSize: 14,
    color: AetherColors.textPrimary,
    height: 1.45,
  );
  static const TextStyle bodySm = TextStyle(
    fontSize: 13,
    color: AetherColors.textSecondary,
    height: 1.4,
  );
  static const TextStyle caption = TextStyle(
    fontSize: 12,
    color: AetherColors.textTertiary,
    letterSpacing: 0.1,
  );
  static const TextStyle pill = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    color: Colors.white,
  );
}

class AetherGradients {
  AetherGradients._();

  /// Splash gradient: barely-there so the splash reads as "blank + logo"
  /// rather than "designed gradient". When Figma brings a brand gradient,
  /// swap this one value and the splash picks it up.
  static const LinearGradient splash = LinearGradient(
    colors: [Color(0xFFFFFFFF), Color(0xFFF3F3F2)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  /// Placeholder for card thumbnails when no real image is available —
  /// a neutral grayscale gradient so the card's visual weight is
  /// preserved but doesn't commit to any chromatic direction.
  static const LinearGradient thumbnailPlaceholder = LinearGradient(
    colors: [Color(0xFFE8E8E7), Color(0xFFCFCFCE)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

// ─── Design Inspector ───────────────────────────────────────────────

enum DesignKind {
  customizable,
  partial,
  iosLocked,
  backendNeeded,
}

extension DesignKindColor on DesignKind {
  Color get color {
    switch (this) {
      case DesignKind.customizable:
        return AetherColors.inspCustomizable;
      case DesignKind.partial:
        return AetherColors.inspPartial;
      case DesignKind.iosLocked:
        return AetherColors.inspLocked;
      case DesignKind.backendNeeded:
        return AetherColors.inspBackend;
    }
  }

  String get shortLabel {
    switch (this) {
      case DesignKind.customizable:
        return '可定制';
      case DesignKind.partial:
        return '部分';
      case DesignKind.iosLocked:
        return 'iOS 锁';
      case DesignKind.backendNeeded:
        return '需后端';
    }
  }
}

class DesignInspector extends InheritedWidget {
  final bool isEnabled;
  final VoidCallback toggle;

  const DesignInspector({
    super.key,
    required this.isEnabled,
    required this.toggle,
    required super.child,
  });

  static DesignInspector? of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<DesignInspector>();
  }

  @override
  bool updateShouldNotify(DesignInspector oldWidget) =>
      isEnabled != oldWidget.isEnabled;
}

class DesignInspectorHost extends StatefulWidget {
  final Widget child;

  const DesignInspectorHost({super.key, required this.child});

  @override
  State<DesignInspectorHost> createState() => _DesignInspectorHostState();
}

class _DesignInspectorHostState extends State<DesignInspectorHost> {
  bool _enabled = false;

  @override
  Widget build(BuildContext context) {
    return DesignInspector(
      isEnabled: _enabled,
      toggle: () => setState(() => _enabled = !_enabled),
      child: Stack(
        children: [
          widget.child,
          Positioned(
            right: AetherSpacing.lg,
            bottom: AetherSpacing.lg + 76,
            child: _InspectorToggleButton(
              enabled: _enabled,
              onTap: () => setState(() => _enabled = !_enabled),
            ),
          ),
          if (_enabled)
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: IgnorePointer(child: _InspectorLegend()),
            ),
        ],
      ),
    );
  }
}

class _InspectorToggleButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _InspectorToggleButton({required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: enabled ? AetherColors.primary : AetherColors.bgCanvas,
          shape: BoxShape.circle,
          border: Border.all(
            color: enabled ? AetherColors.primary : AetherColors.border,
          ),
          boxShadow: [
            BoxShadow(
              color: AetherColors.shadow,
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          enabled
              ? Icons.visibility_off_rounded
              : Icons.auto_awesome_rounded,
          color: enabled ? Colors.white : AetherColors.textSecondary,
          size: 20,
        ),
      ),
    );
  }
}

class _InspectorLegend extends StatelessWidget {
  const _InspectorLegend();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AetherSpacing.lg,
        vertical: AetherSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas.withValues(alpha: 0.96),
        border: const Border(top: BorderSide(color: AetherColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: const [
            _LegendItem(kind: DesignKind.customizable, label: '可定制'),
            _LegendItem(kind: DesignKind.partial, label: '部分'),
            _LegendItem(kind: DesignKind.iosLocked, label: 'iOS 锁'),
            _LegendItem(kind: DesignKind.backendNeeded, label: '需后端'),
          ],
        ),
      ),
    );
  }
}

class _LegendItem extends StatelessWidget {
  final DesignKind kind;
  final String label;

  const _LegendItem({required this.kind, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: kind.color.withValues(alpha: 0.25),
            border: Border.all(color: kind.color, width: 1.5),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: AetherSpacing.sm),
        Text(
          label,
          style: AetherTextStyles.bodySm.copyWith(fontSize: 11),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class DesignBox extends StatelessWidget {
  final DesignKind kind;
  final String label;
  final Widget child;

  const DesignBox({
    super.key,
    required this.kind,
    required this.label,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final inspector = DesignInspector.of(context);
    if (inspector == null || !inspector.isEnabled) {
      return child;
    }
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: _DashedBorderPainter(color: kind.color)),
          ),
        ),
        Positioned(
          top: 2,
          left: 2,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: kind.color,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: Colors.black,
                  letterSpacing: 0.2,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;

  _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    const dash = 6.0;
    const gap = 3.0;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, 0),
        Offset((x + dash).clamp(0, size.width), 0),
        paint,
      );
      x += dash + gap;
    }
    double y = 0;
    while (y < size.height) {
      canvas.drawLine(
        Offset(size.width, y),
        Offset(size.width, (y + dash).clamp(0, size.height)),
        paint,
      );
      y += dash + gap;
    }
    x = 0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, size.height),
        Offset((x + dash).clamp(0, size.width), size.height),
        paint,
      );
      x += dash + gap;
    }
    y = 0;
    while (y < size.height) {
      canvas.drawLine(
        Offset(0, y),
        Offset(0, (y + dash).clamp(0, size.height)),
        paint,
      );
      y += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter old) => color != old.color;
}

// ─── Shared small components ────────────────────────────────────────

/// Black pill button (primary action). Figma phase can restyle but
/// component contract stays: icon (optional) + label, full-width
/// friendly, 56pt tall.
class AetherPrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  const AetherPrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: AetherColors.primary,
          borderRadius: BorderRadius.circular(AetherRadii.lg),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: AetherSpacing.sm),
            ],
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Outlined secondary button, same height rhythm as primary.
class AetherSecondaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;

  const AetherSecondaryButton({super.key, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: AetherColors.bgCanvas,
          borderRadius: BorderRadius.circular(AetherRadii.md),
          border: Border.all(color: AetherColors.border),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: const TextStyle(
            color: AetherColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Capsule "pill" for small status chips (lifecycle title, mode label).
class AetherPill extends StatelessWidget {
  final String label;
  final Color? dotColor;
  final Color? background;
  final Color? foreground;

  const AetherPill({
    super.key,
    required this.label,
    this.dotColor,
    this.background,
    this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AetherSpacing.md,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: background ?? AetherColors.bgCanvas,
        borderRadius: BorderRadius.circular(AetherRadii.pill),
        border: Border.all(color: AetherColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: foreground ?? AetherColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
