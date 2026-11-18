import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

typedef NotificationStatus = ({bool granted, bool exact});

/// Android side of the planner: home-screen widgets, reminder notifications
/// and the screen a widget tap should open. A missing plugin (Windows, tests)
/// is ignored and gives "nothing granted".
class PlannerPlatform {
  static const channel = MethodChannel('personal_ink_vault/planner');

  final _opens = StreamController<String>.broadcast();
  var _listening = false;

  Stream<String> get openRequests {
    if (!_listening) {
      _listening = true;
      channel.setMethodCallHandler((call) async {
        final target = call.arguments;
        if (call.method == 'open' && target is String) _opens.add(target);
        return null;
      });
    }
    return _opens.stream;
  }

  Future<void> updateWidget(String kind, String payload) async {
    try {
      await channel.invokeMethod<void>('updateWidget', {
        'kind': kind,
        'payload': payload,
      });
    } on MissingPluginException {
      // No widgets on this platform.
    }
  }

  /// The alarm list last scheduled through this platform, by any screen, as
  /// JSON; null before the first.
  String? get lastAlarms => _lastAlarms;
  String? _lastAlarms;

  Future<NotificationStatus> scheduleReminders(
    List<Map<String, Object>> items,
  ) async {
    final status = await _status('scheduleReminders', {'items': items});
    _lastAlarms = jsonEncode(items);
    return status;
  }

  Future<NotificationStatus> notificationStatus() =>
      _status('notificationStatus');

  Future<NotificationStatus> requestNotificationPermission() =>
      _status('requestNotificationPermission');

  Future<String?> takeLaunchTarget() async {
    try {
      return await channel.invokeMethod<String>('takeLaunchTarget');
    } on MissingPluginException {
      return null;
    }
  }

  Future<NotificationStatus> _status(String method, [Object? arguments]) async {
    try {
      final result = await channel.invokeMethod<Map<Object?, Object?>>(
        method,
        arguments,
      );
      return (
        granted: result?['granted'] == true,
        exact: result?['exact'] == true,
      );
    } on MissingPluginException {
      return (granted: false, exact: false);
    }
  }
}
