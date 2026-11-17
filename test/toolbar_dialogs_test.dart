import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/toolbar/shortcut_bar_editor.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
import 'package:saber/components/toolbar/toolbar_custom_dialog.dart';
import 'package:saber/components/toolbar/toolbar_layout.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';

/// StarNote's two customise dialogs (popup_shape_toolbar_custom and
/// popup_shortcut_bar_custom): changes wait for 완료, 닫기 drops them.
void main() {
  setUp(FlavorConfig.setup);

  Future<void> open(WidgetTester tester, void Function(BuildContext) show) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => show(context), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void keepStows() {
    final toolbar = stows.pageToolbarLayout.value;
    final shortcuts = stows.noteShortcutLayout.value;
    addTearDown(() {
      stows.pageToolbarLayout.value = toolbar;
      stows.noteShortcutLayout.value = shortcuts;
    });
  }

  Future<void> openToolbar(WidgetTester tester) => open(
    tester,
    (context) => showToolbarCustomDialog(
      context,
      items: pageToolbarItems,
      layout: stows.pageToolbarLayout,
    ),
  );

  Future<void> openShortcuts(WidgetTester tester) => open(
    tester,
    (context) => showShortcutBarEditor(context, layout: stows.noteShortcutLayout),
  );

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('hiding a tool and applying saves it; closing discards', (tester) async {
    keepStows();
    stows.pageToolbarLayout.value = const [];
    await openToolbar(tester);
    expect(find.text('사용자 지정 도구 모음'), findsOneWidget);
    expect(find.text('개인 선호에 따라 도구 모음 사용자 지정'), findsOneWidget);
    expect(find.text('표시된 도구'), findsOneWidget);
    expect(find.text('숨겨진 도구'), findsOneWidget);
    await tapKey(tester, 'toolbar-custom-eye-pen');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('toolbar-custom-hidden-list')),
        matching: find.text('펜'),
      ),
      findsOneWidget,
    );
    await tapKey(tester, 'toolbar-custom-apply');
    expect(stows.pageToolbarLayout.value, contains('!pen'));
    expect(find.byKey(const ValueKey('toolbar-custom-dialog')), findsNothing);

    await openToolbar(tester);
    await tapKey(tester, 'toolbar-custom-eye-highlighter');
    await tapKey(tester, 'toolbar-custom-close');
    expect(stows.pageToolbarLayout.value, contains('!pen'));
    expect(stows.pageToolbarLayout.value, isNot(contains('!highlighter')));
  });

  testWidgets('restore default settings saves the default layout', (tester) async {
    keepStows();
    stows.pageToolbarLayout.value = const ['!pen', 'laser'];
    await openToolbar(tester);
    await tapKey(tester, 'toolbar-custom-reset');
    await tapKey(tester, 'toolbar-custom-apply');
    expect(
      ToolbarLayout.decode(pageToolbarItems, stows.pageToolbarLayout.value).shownIds,
      ToolbarLayout.decode(pageToolbarItems, const []).shownIds,
    );
  });

  testWidgets('an 11th shortcut is refused with the limit message', (tester) async {
    keepStows();
    stows.noteShortcutLayout.value = const [];
    await openShortcuts(tester);
    expect(find.text('사용자 지정 바로가기 막대'), findsOneWidget);
    expect(
      find.text("'문서 개요'와 '기타 설정' 외에 최대 10개의 바로가기를 추가해 바로가기 막대를 사용자 지정할 수 있습니다"),
      findsOneWidget,
    );
    expect(find.text('바로가기 막대 왼쪽'), findsOneWidget);
    expect(find.text('바로가기 막대 오른쪽'), findsOneWidget);
    await tapKey(tester, 'shortcut-editor-eye-quickSwitch');
    expect(find.text('바로가기 수가 한도에 도달했습니다'), findsOneWidget);
    await tapKey(tester, 'shortcut-editor-apply');
    final saved = ShortcutLayout.decode(noteShortcutItems, stows.noteShortcutLayout.value);
    expect(saved.barCount, maxBarShortcuts);
    expect(saved.more, contains('quickSwitch'));
  });

  testWidgets('hiding a bar shortcut moves it to more; apply saves', (tester) async {
    keepStows();
    stows.noteShortcutLayout.value = const [];
    await openShortcuts(tester);
    await tapKey(tester, 'shortcut-editor-eye-fullscreen');
    // With room again, a shortcut from 더 많은 기능 joins the bar's left part.
    await tapKey(tester, 'shortcut-editor-eye-quickSwitch');
    await tapKey(tester, 'shortcut-editor-apply');
    final saved = ShortcutLayout.decode(noteShortcutItems, stows.noteShortcutLayout.value);
    expect(saved.more, contains('fullscreen'));
    expect(saved.left.last, 'quickSwitch');
  });

  testWidgets('dragging a shortcut below the right title moves it to the right part', (
    tester,
  ) async {
    keepStows();
    stows.noteShortcutLayout.value = const [];
    await openShortcuts(tester);
    final handle = find.descendant(
      of: find.byKey(const ValueKey('shortcut-editor-row-prev')),
      matching: find.byIcon(Icons.drag_handle),
    );
    final target = tester.getCenter(
      find.byKey(const ValueKey('shortcut-editor-row-fullscreen')),
    );
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    final start = tester.getCenter(handle);
    for (var step = 1; step <= 10; step++) {
      await gesture.moveTo(Offset.lerp(start, target + const Offset(0, 20), step / 10)!);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    await tapKey(tester, 'shortcut-editor-apply');
    final saved = ShortcutLayout.decode(noteShortcutItems, stows.noteShortcutLayout.value);
    expect(saved.right, contains('prev'));
    expect(saved.left, isNot(contains('prev')));
  });

  testWidgets('the fixed items are listed but cannot be hidden', (tester) async {
    keepStows();
    await openShortcuts(tester);
    expect(find.text('문서 개요'), findsOneWidget);
    expect(find.text('기타 설정'), findsOneWidget);
    expect(find.byKey(const ValueKey('shortcut-editor-eye-overview')), findsNothing);
    expect(find.byKey(const ValueKey('shortcut-editor-eye-otherSettings')), findsNothing);
    await tapKey(tester, 'shortcut-editor-close');
    expect(find.byKey(const ValueKey('shortcut-editor-dialog')), findsNothing);
  });
}
