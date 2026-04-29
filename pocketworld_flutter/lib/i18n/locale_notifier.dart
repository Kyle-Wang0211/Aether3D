// LocaleNotifier — single source of truth for the user's chosen UI
// language (system / zh / en). Persisted via AetherPrefs so the choice
// survives app restarts.
//
// Wiring:
//   • main.dart instantiates one LocaleNotifier, restores from prefs,
//     and exposes it through LocaleScope (InheritedNotifier).
//   • MaterialApp listens via locale: scope.locale; rebuilds the whole
//     widget tree when locale changes.
//   • MePage's "语言 / Language" row pushes a dialog that calls
//     scope.notifier.set(...). All AppL10n.of(context) calls then return
//     translations from the new locale on next build.

import 'package:flutter/widgets.dart';

import '../aether_prefs.dart';

/// Persisted under this key in AetherPrefs (NSUserDefaults). Value is
/// a BCP-47 language tag ("zh", "en") or empty string for "follow
/// system".
const String kLocaleOverridePrefKey = 'pw.locale.override.v1';

class LocaleNotifier extends ChangeNotifier {
  // Per user direction (2026-04-28): no "follow system" mode. The app
  // always renders in either zh or en. First launch infers from OS
  // locale (zh-* → zh, anything else → en) and persists the choice;
  // afterwards the Me-page language dialog is the only source of
  // changes.
  Locale _override = _initialLocaleFromSystem();

  Locale get override => _override;

  /// Forced locale for MaterialApp.locale.
  Locale get locale => _override;

  bool get isChinese => _override.languageCode == 'zh';

  static Locale _initialLocaleFromSystem() {
    final sys = WidgetsBinding.instance.platformDispatcher.locale;
    return sys.languageCode == 'zh' ? const Locale('zh') : const Locale('en');
  }

  Future<void> bootstrap() async {
    try {
      final prefs = await AetherPrefs.getInstance();
      final raw = await prefs.getString(kLocaleOverridePrefKey) ?? '';
      final parsed = _parseLocaleTag(raw);
      if (parsed != null) {
        _override = parsed;
        notifyListeners();
      }
    } catch (_) {
      // Best effort — _override stays at the system-derived default.
    }
  }

  Future<void> set(Locale locale) async {
    if (_override == locale) return;
    _override = locale;
    notifyListeners();
    try {
      final prefs = await AetherPrefs.getInstance();
      await prefs.setString(kLocaleOverridePrefKey, locale.languageCode);
    } catch (_) {
      // Persist failure is non-fatal — runtime override stays in effect.
    }
  }

  static Locale? _parseLocaleTag(String tag) {
    final t = tag.trim();
    if (t.isEmpty) return null;
    if (t == 'zh') return const Locale('zh');
    if (t == 'en') return const Locale('en');
    return null;
  }
}

/// InheritedNotifier exposing the LocaleNotifier to the widget tree.
/// Widgets that want to read the current locale (or imperatively switch
/// it) reach for [LocaleScope.of].
class LocaleScope extends InheritedNotifier<LocaleNotifier> {
  const LocaleScope({
    super.key,
    required LocaleNotifier notifier,
    required super.child,
  }) : super(notifier: notifier);

  static LocaleNotifier of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LocaleScope>();
    final notifier = scope?.notifier;
    if (notifier == null) {
      throw StateError('LocaleScope missing from widget tree');
    }
    return notifier;
  }

  /// Imperative variant — doesn't subscribe the caller to rebuilds.
  static LocaleNotifier read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<LocaleScope>();
    final notifier = scope?.notifier;
    if (notifier == null) {
      throw StateError('LocaleScope missing from widget tree');
    }
    return notifier;
  }
}
