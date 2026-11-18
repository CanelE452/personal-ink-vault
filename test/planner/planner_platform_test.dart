import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/planner/planner_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void mock(String channel, Future<Object?>? Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(MethodChannel(channel), handler);
    addTearDown(
      () => messenger.setMockMethodCallHandler(MethodChannel(channel), null),
    );
  }

  const channelName = 'personal_ink_vault/planner';

  test('channel name matches the native side', () {
    expect(PlannerPlatform.channel.name, channelName);
  });

  test('updateWidget sends kind and payload', () async {
    MethodCall? seen;
    mock(channelName, (call) async {
      seen = call;
      return null;
    });
    await PlannerPlatform().updateWidget('calendar', '{"version":1}');
    expect(seen!.method, 'updateWidget');
    expect(seen!.arguments, {'kind': 'calendar', 'payload': '{"version":1}'});
  });

  test('scheduleReminders sends items and parses the status', () async {
    MethodCall? seen;
    mock(channelName, (call) async {
      seen = call;
      return {'granted': true, 'exact': false};
    });
    final status = await PlannerPlatform().scheduleReminders([
      {'id': 'a', 'title': 't', 'at': 5},
    ]);
    expect(seen!.method, 'scheduleReminders');
    expect(seen!.arguments, {
      'items': [
        {'id': 'a', 'title': 't', 'at': 5},
      ],
    });
    expect(status.granted, isTrue);
    expect(status.exact, isFalse);
  });

  test('status and permission calls parse the map', () async {
    mock(channelName, (call) async => {'granted': true, 'exact': true});
    final platform = PlannerPlatform();
    expect((await platform.notificationStatus()).exact, isTrue);
    expect((await platform.requestNotificationPermission()).granted, isTrue);
  });

  test('takeLaunchTarget returns the string or null', () async {
    mock(channelName, (call) async => 'reminder');
    expect(await PlannerPlatform().takeLaunchTarget(), 'reminder');
  });

  test('a missing plugin gives quiet defaults', () async {
    final platform = PlannerPlatform();
    await platform.updateWidget('reminder', '{}');
    final status = await platform.scheduleReminders(const []);
    expect(status.granted, isFalse);
    expect(status.exact, isFalse);
    expect((await platform.notificationStatus()).granted, isFalse);
    expect((await platform.requestNotificationPermission()).granted, isFalse);
    expect(await platform.takeLaunchTarget(), isNull);
  });

  test('native open calls arrive on openRequests', () async {
    final platform = PlannerPlatform();
    final first = platform.openRequests.first;
    await messenger.handlePlatformMessage(
      channelName,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('open', 'calendar'),
      ),
      (_) {},
    );
    expect(await first, 'calendar');
  });
}
