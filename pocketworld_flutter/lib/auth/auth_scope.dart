// InheritedWidget that exposes CurrentUser to descendants without any
// prop-drilling. Used by MePage (sign-out button), ScanRecord cloud
// queries (scope by userID), etc.

import 'package:flutter/widgets.dart';

import 'current_user.dart';

class AuthScope extends InheritedNotifier<CurrentUser> {
  const AuthScope({
    super.key,
    required CurrentUser currentUser,
    required super.child,
  }) : super(notifier: currentUser);

  static CurrentUser of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AuthScope>();
    assert(scope != null, 'AuthScope missing from widget tree');
    return scope!.notifier!;
  }

  /// Non-dependency variant for imperative callers (gesture handlers,
  /// method-channel callbacks). Doesn't subscribe this widget to rebuilds.
  static CurrentUser read(BuildContext context) {
    final scope =
        context.getInheritedWidgetOfExactType<AuthScope>();
    assert(scope != null, 'AuthScope missing from widget tree');
    return scope!.notifier!;
  }
}
