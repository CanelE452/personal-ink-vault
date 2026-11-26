import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_panel_common.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';

/// A window's context under the app's navigator.
Future<BuildContext> _window(WidgetTester tester) async {
  late BuildContext window;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          window = context;
          return const SizedBox();
        },
      ),
    ),
  );
  return window;
}

void main() {
  testWidgets('there is no eyedropper without the action', (tester) async {
    final window = await _window(tester);
    expect(colourRowEyedropper(null, window, close: () {}), isNull);
    final empty = AppActionRegistry();
    addTearDown(empty.dispose);
    expect(colourRowEyedropper(empty, window, close: () {}), isNull);
  });

  testWidgets('it closes the window, then runs on the next frame if the '
      'overlay is still there', (tester) async {
    final calls = <String>[];
    final acts = AppActionRegistry();
    addTearDown(acts.dispose);
    acts.publish(Object(), [
      AppAction(
        id: AppActionIds.eyedropper,
        label: '스포이트',
        icon: KitIconName.eyedrop,
        run: (context) => calls.add('run, mounted ${context.mounted}'),
      ),
    ]);
    final window = await _window(tester);
    final press = colourRowEyedropper(
      acts,
      window,
      close: () => calls.add('close'),
    )!;
    press();
    // closed at once, the action not yet
    expect(calls, ['close']);
    await tester.pump();
    expect(calls, ['close', 'run, mounted true']);
    // the overlay gone before the frame after: nothing runs
    press();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls, ['close', 'run, mounted true', 'close']);
  });
}
