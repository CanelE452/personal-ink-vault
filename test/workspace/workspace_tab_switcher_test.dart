import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/workspace_navigation.dart';
import 'package:saber/pages/workspace/workspace_tab_switcher.dart';

const _button = ValueKey('workspace-tab-switcher');
Finder _item(String id) =>
    find.byKey(ValueKey('workspace-tab-switcher-item-$id'));

void main() {
  testWidgets('compact tab switcher stays outside the scrolling strip', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tabs = [
      for (var index = 0; index < 12; index++)
        WorkspaceDocumentTab(
          'note-$index',
          'Long document $index — draft and references',
        ),
    ];
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: 44,
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final tab in tabs)
                            SizedBox(
                              width: 155,
                              child: Text(
                                tab.title,
                                key: ValueKey('strip-${tab.noteId}'),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  WorkspaceTabSwitcher(
                    tabs: tabs,
                    activeNoteId: 'note-0',
                    onSelected: selected.add,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final button = find.byKey(_button);
    expect(find.byTooltip('열린 문서 12개'), findsOneWidget);
    expect(
      find.descendant(of: button, matching: find.text('12')),
      findsOneWidget,
    );
    expect(tester.getRect(button).right, 320);
    expect(tester.getSize(button).height, 44);
    final strip = find.byKey(const ValueKey('strip-note-11'));
    expect(strip.hitTestable(), findsNothing);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckedPopupMenuItem<String>>(_item('note-0')).checked,
      isTrue,
    );
    expect(
      tester.widget<CheckedPopupMenuItem<String>>(_item('note-11')).checked,
      isFalse,
    );
    await tester.ensureVisible(_item('note-11'));
    await tester.pumpAndSettle();
    await tester.tap(_item('note-11'));
    await tester.pumpAndSettle();
    expect(selected, ['note-11']);
    expect(tester.getRect(button).right, 320);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'tab switcher uses IDs for duplicate titles and ignores the active item',
    (tester) async {
      final selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkspaceTabSwitcher(
              tabs: const [
                WorkspaceDocumentTab('first', 'Same title'),
                WorkspaceDocumentTab('second', 'Same title'),
              ],
              activeNoteId: 'first',
              onSelected: selected.add,
            ),
          ),
        ),
      );
      Future<void> openMenu() async {
        await tester.tap(find.byKey(_button));
        await tester.pumpAndSettle();
      }

      await openMenu();
      expect(find.text('Same title'), findsNWidgets(2));
      await tester.tap(_item('first'));
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(_item('first'), findsNothing);

      await openMenu();
      await tester.tap(_item('second'));
      await tester.pumpAndSettle();
      expect(selected, ['second']);
    },
  );

  testWidgets(
    'tab switcher opens with keyboard and Escape returns to the page',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WorkspaceTabSwitcher(
              tabs: const [WorkspaceDocumentTab('first', 'First document')],
              activeNoteId: null,
              onSelected: (_) {},
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_item('first'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(_item('first'), findsNothing);
      expect(find.byKey(_button), findsOneWidget);
    },
  );

  testWidgets('tab switcher hides an empty list and retains a disabled count', (
    tester,
  ) async {
    Future<void> pump(List<WorkspaceDocumentTab> tabs) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceTabSwitcher(
            tabs: tabs,
            activeNoteId: null,
            onSelected: null,
          ),
        ),
      ),
    );
    await pump(const []);
    expect(find.byKey(_button), findsNothing);
    await pump(const [WorkspaceDocumentTab('first', 'First document')]);
    final button = find.byKey(_button);
    expect(find.byTooltip('열린 문서 1개'), findsOneWidget);
    expect(tester.widget<PopupMenuButton<String>>(button).enabled, isFalse);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(_item('first'), findsNothing);
  });
}
