// Localized relative time formatter — replaces HomeViewModel's
// hardcoded zh-only `relativeTimeString`. Lives in i18n/ instead of
// each widget so any view (Vault, Me, capture history…) can reuse the
// exact same buckets.

import '../l10n/app_localizations.dart';

String formatRelativeTime(AppL10n l, DateTime createdAt) {
  final diff = DateTime.now().difference(createdAt);
  if (diff.inMinutes < 1) return l.relativeJustNow;
  if (diff.inMinutes < 60) return l.relativeMinutesAgo(diff.inMinutes);
  if (diff.inHours < 24) return l.relativeHoursAgo(diff.inHours);
  if (diff.inDays < 7) return l.relativeDaysAgo(diff.inDays);
  if (diff.inDays < 30) return l.relativeWeeksAgo((diff.inDays / 7).floor());
  return l.relativeMonthsAgo((diff.inDays / 30).floor());
}
