import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/pages/workspace/workspace_quick_switcher.dart';

const _query = ValueKey('workspace-quick-switch-query');
const _open = ValueKey('test-open-quick-switcher');
Finder _result(String id) =>
    find.byKey(ValueKey('workspace-quick-switch-result-$id'));

Future<List<String?>> _mount(
  WidgetTester tester,
  List<WorkspaceQuickSwitchEntry> entries, {
  List<String> recent = const [],
  String? activeId,
}) async {
  final picked = <String?>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: _open,
            onPressed: () async => picked.add(
              await showWorkspaceQuickSwitcher(
                context,
                entries: entries,
                recentIds: recent,
                activeId: activeId,
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_open));
  await tester.pumpAndSettle();
  return picked;
}

void main() {
  testWidgets('empty query shows current available documents in recent order', (
    tester,
  ) async {
    final picked = await _mount(
      tester,
      const [
        WorkspaceQuickSwitchEntry(id: 'a', title: 'Alpha', path: 'Notes/Alpha'),
        WorkspaceQuickSwitchEntry(id: 'b', title: 'Beta', path: 'Notes/Beta'),
        WorkspaceQuickSwitchEntry(id: 'c', title: 'Gamma', path: 'Notes/Gamma'),
      ],
      recent: ['missing', 'b', 'a', 'b'],
      activeId: 'a',
    );
    expect(find.text('최근 문서'), findsOneWidget);
    expect(_result('b'), findsOneWidget);
    expect(_result('a'), findsOneWidget);
    expect(_result('c'), findsNothing);
    expect(
      tester.getTopLeft(_result('b')).dy,
      lessThan(tester.getTopLeft(_result('a')).dy),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(picked, [null]);
  });

  testWidgets('exact, prefix, substring and fuzzy matches prefer title ties', (
    tester,
  ) async {
    await _mount(tester, const [
      WorkspaceQuickSwitchEntry(
        id: 'path',
        title: 'Facts',
        path: 'Topic/Facts',
      ),
      WorkspaceQuickSwitchEntry(
        id: 'substring',
        title: 'My Topic',
        path: 'My Topic',
      ),
      WorkspaceQuickSwitchEntry(
        id: 'folder-substring',
        title: 'Outline',
        path: 'Other/Topic/Outline',
      ),
      WorkspaceQuickSwitchEntry(
        id: 'prefix',
        title: 'Topic notes',
        path: 'Topic notes',
      ),
      WorkspaceQuickSwitchEntry(id: 'fuzzy', title: 'To pic', path: 'To pic'),
      WorkspaceQuickSwitchEntry(
        id: 'exact',
        title: 'Topic',
        path: 'Folder/Topic',
      ),
    ]);
    await tester.enterText(find.byKey(_query), ' TOPIC ');
    await tester.pumpAndSettle();
    expect(find.text('검색 결과'), findsOneWidget);
    final offsets = [
      for (final id in [
        'exact',
        'prefix',
        'path',
        'substring',
        'folder-substring',
        'fuzzy',
      ])
        tester.getTopLeft(_result(id)).dy,
    ];
    expect(offsets, orderedEquals([...offsets]..sort()));
  });

  testWidgets('compact dialog opens the keyboard-selected result with Enter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final picked = await _mount(tester, const [
      WorkspaceQuickSwitchEntry(id: 'a', title: 'Study', path: 'Class A/Study'),
      WorkspaceQuickSwitchEntry(id: 'b', title: 'Study', path: 'Class B/Study'),
      WorkspaceQuickSwitchEntry(id: 'c', title: 'Study', path: 'Class C/Study'),
    ]);
    await tester.enterText(find.byKey(_query), 'study');
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(_result('a')).selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(_result('b')).selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(_result('b')).selected, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, ['b']);
    expect(find.byKey(_query), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard wrap reveals the selected row', (tester) async {
    tester.view.physicalSize = const Size(320, 420);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(tester, [
      for (var index = 0; index < 20; index++)
        WorkspaceQuickSwitchEntry(
          id: '$index',
          title: 'Document ${'$index'.padLeft(2, '0')}',
          path: 'Notes',
        ),
    ]);
    await tester.enterText(find.byKey(_query), 'doc');
    await tester.pumpAndSettle();
    expect(_result('19').hitTestable(), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(_result('19')).selected, isTrue);
    expect(_result('19').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(tester.widget<ListTile>(_result('0')).selected, isTrue);
    expect(_result('0').hitTestable(), findsOneWidget);
  });

  testWidgets('path label disambiguates equal titles and opens by touch', (
    tester,
  ) async {
    final picked = await _mount(tester, const [
      WorkspaceQuickSwitchEntry(id: 'a', title: '수업', path: '지난 학기/수업'),
      WorkspaceQuickSwitchEntry(id: 'b', title: '수업', path: '이번 학기/수업'),
    ]);
    expect(find.text('최근 문서가 없습니다.'), findsOneWidget);
    await tester.enterText(find.byKey(_query), '이번');
    await tester.pumpAndSettle();
    expect(_result('a'), findsNothing);
    expect(find.text('이번 학기/수업'), findsOneWidget);
    await tester.tap(_result('b'));
    await tester.pumpAndSettle();
    expect(picked, ['b']);
  });

  testWidgets('search results are bounded and clear when there is no match', (
    tester,
  ) async {
    final picked = await _mount(tester, [
      for (var index = 0; index < 70; index++)
        WorkspaceQuickSwitchEntry(
          id: '$index',
          title: 'Document ${'$index'.padLeft(2, '0')}',
          path: 'Notes',
        ),
    ]);
    await tester.enterText(find.byKey(_query), 'doc');
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNWidgets(50));
    await tester.enterText(find.byKey(_query), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('일치하는 문서가 없습니다.'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(picked, isEmpty);
  });
}
