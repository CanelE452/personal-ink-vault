import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/app_external_screen.dart';
import 'package:saber/data/office/office_editor_events.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const events = MethodChannel('test/office_editor_events');
  const engine = MethodChannel('test/office_engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<void> nativeSays(String method, Map<String, Object?> arguments) =>
      messenger.handlePlatformMessage(
        events.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  test('an editor the user left behind no longer counts as a screen over the app', () async {
    final listener = OfficeEditorEvents(events: events, engine: engine);
    final left = <String>[];
    final subscription = listener.editorLeft.listen(left.add);
    addTearDown(subscription.cancel);
    AppExternalScreen.editorInFront('s1');
    AppExternalScreen.editorInFront('s1');
    expect(AppExternalScreen.active, isTrue);
    await nativeSays('editorLeft', {'sessionId': 's1'});
    await pumpEventQueue();
    expect(left, ['s1']);
    expect(AppExternalScreen.active, isFalse);
  });

  test('a late result is announced with its status and the app can move to the back', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(engine, (call) async {
      calls.add(call);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(engine, null));
    final listener = OfficeEditorEvents(events: events, engine: engine);
    final finished = <({String sessionId, String status})>[];
    final subscription = listener.editorFinished.listen(finished.add);
    addTearDown(subscription.cancel);
    AppExternalScreen.editorInFront('s2');
    await nativeSays('editorFinished', {'sessionId': 's2', 'status': 'saved'});
    await pumpEventQueue();
    expect(finished, [(sessionId: 's2', status: 'saved')]);
    expect(AppExternalScreen.active, isFalse);
    await listener.moveAppToBack();
    expect(calls.single.method, 'moveTaskToBack');
  });
}
