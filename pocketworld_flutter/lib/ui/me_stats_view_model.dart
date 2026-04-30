// MeStatsViewModel — backs the trailing values on the Me settings page
// (notifications + privacy). One-shot Supabase fetch on load(), with a
// notifyListeners() so the page rebuilds when the values arrive.
//
// Sources:
//   • notificationsEnabled → public.notification_settings.push_enabled
//     for the signed-in uid. Null when the row hasn't been created yet
//     (UI shows "未配置 / Not configured").
//   • isPrivate            → public.profiles.is_private. Null on RLS or
//     network failure.

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

class MeStatsViewModel extends ChangeNotifier {
  bool _disposed = false;

  bool? _notificationsEnabled;
  bool? _isPrivate;

  bool? get notificationsEnabled => _notificationsEnabled;
  bool? get isPrivate => _isPrivate;

  Future<void> load() => _loadRemote();

  Future<void> _loadRemote() async {
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentSession?.user.id;
      if (uid == null) return;
      // profiles.is_private — auto_init_user_profile trigger guarantees a
      // row exists, but maybeSingle() returning null is still tolerated
      // (e.g. RLS denies the read in tests).
      final profile = await client
          .from('profiles')
          .select('is_private')
          .eq('id', uid)
          .maybeSingle();
      if (_disposed) return;
      if (profile != null && profile['is_private'] is bool) {
        _isPrivate = profile['is_private'] as bool;
      }
      // notification_settings — the row is created lazily the first time
      // the user touches notification preferences, so a null here means
      // "未配置 / Not configured" rather than an error.
      final settings = await client
          .from('notification_settings')
          .select('push_enabled')
          .eq('user_id', uid)
          .maybeSingle();
      if (_disposed) return;
      if (settings != null && settings['push_enabled'] is bool) {
        _notificationsEnabled = settings['push_enabled'] as bool;
      }
      notifyListeners();
    } catch (e, s) {
      debugPrint('[MeStats] remote load failed: $e\n$s');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
