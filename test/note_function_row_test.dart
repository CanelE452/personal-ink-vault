import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/toolbar/note_function_row.dart';
import 'package:saber/components/toolbar/other_settings_panel.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';

/// StarNote's function row (layout_function_tool): back, the shortcut bar's
/// left and right parts (each scrolling), the fixed 문서 개요 and 기타 설정,
/// then ⋯ "더 많은 기능".
void main() {
  final log = <String>[];
  setUp(log.clear);

  List<NoteShortcut> shortcuts({Set<String> without = const {}}) => [
    for (final item in noteShortcutItems)
      if (!without.contains(item.id))
        NoteShortcut(
          id: item.id,
          label: item.label,
          icon: Icon(item.icon),
          buttonKey: ValueKey('sc-${item.id}'),
          onPressed: () => log.add(item.id),
          menuBuilder: item.id == 'documentExport'
              ? (_) => [
                  PopupMenuItem<void>(
                    onTap: () => log.add('markdown'),
                    child: const Text('Markdown'),
                  ),
                ]
              : null,
        ),
  ];

  final fixed = [
    NoteShortcut(
      id: 'overview',
      label: '문서 개요',
      icon: const Icon(Icons.grid_view),
      buttonKey: const ValueKey('note-overview'),
      onPressed: () => log.add('overview'),
    ),
    NoteShortcut(
      id: 'otherSettings',
      label: '기타 설정',
      icon: const Icon(Icons.tune),
      buttonKey: const ValueKey('note-other-settings'),
      onPressed: () => log.add('otherSettings'),
    ),
  ];

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1200, 800),
    Set<String> without = const {},
    List<String> stored = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              NoteFunctionRow(
                back: IconButton(
                  key: const ValueKey('back'),
                  onPressed: () => log.add('back'),
                  icon: const Icon(Icons.arrow_back),
                ),
                shortcuts: shortcuts(without: without),
                fixed: fixed,
                layout: ShortcutLayout.decode(noteShortcutItems, stored),
                onCustomize: () => log.add('customize'),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inPart(String part, String key) => find.descendant(
    of: find.byKey(ValueKey(part)),
    matching: find.byKey(ValueKey(key)),
  );

  testWidgets(
    'the bar shows left and right shortcuts, fixed items at the end and the rest under 더 많은 기능',
    (tester) async {
      await mount(tester);
      expect(find.byKey(const ValueKey('note-function-row')), findsOneWidget);
      expect(inPart('note-function-left', 'sc-insertPage'), findsOneWidget);
      expect(inPart('note-function-left', 'sc-prev'), findsOneWidget);
      expect(inPart('note-function-right', 'sc-viewToggle'), findsOneWidget);
      // The fixed pair sits after the right part's scroll, so it never scrolls away.
      expect(inPart('note-function-row', 'note-other-settings'), findsOneWidget);
      expect(inPart('note-function-right', 'note-other-settings'), findsNothing);
      expect(
        tester.getCenter(find.byKey(const ValueKey('note-other-settings'))).dx,
        greaterThan(tester.getCenter(find.byKey(const ValueKey('sc-fullscreen'))).dx),
      );
      expect(find.byKey(const ValueKey('sc-export')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('workspace-more-actions')));
      await tester.pumpAndSettle();
      expect(find.text('사용자 지정 바로가기 막대'), findsOneWidget);
      await tester.tap(find.text('파일 내보내기'));
      await tester.pumpAndSettle();
      expect(log, ['export']);

      await tester.tap(find.byKey(const ValueKey('sc-insertPage')));
      await tester.tap(find.byKey(const ValueKey('note-overview')));
      expect(log, ['export', 'insertPage', 'overview']);
    },
  );

  testWidgets('a shortcut missing from this document is not shown anywhere', (
    tester,
  ) async {
    await mount(tester, without: {'pdfSearch', 'pdfRemake'});
    expect(find.byKey(const ValueKey('sc-pdfSearch')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('workspace-more-actions')));
    await tester.pumpAndSettle();
    expect(find.text('PDF 본문 검색'), findsNothing);
    expect(find.text('새 엔진으로 PDF 다시 만들기'), findsNothing);
  });

  testWidgets('at phone width the row does not overflow', (tester) async {
    await mount(tester, size: const Size(360, 640));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('workspace-more-actions')), findsOneWidget);
  });

  testWidgets('at phone width 문서 개요 and 기타 설정 stay in view at the right end', (
    tester,
  ) async {
    await mount(tester, size: const Size(360, 640));
    for (final key in const ['note-overview', 'note-other-settings']) {
      final button = find.byKey(ValueKey(key));
      expect(button.hitTestable(), findsOneWidget, reason: key);
      expect(tester.getRect(button).right, lessThanOrEqualTo(360));
    }
    await tester.tap(find.byKey(const ValueKey('note-other-settings')));
    expect(log, ['otherSettings']);
  });

  testWidgets('a menu shortcut opens its menu from the bar and from 더 많은 기능', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('sc-documentExport')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    expect(log, ['markdown']);

    await mount(tester, stored: const ['!documentExport']);
    await tester.tap(find.byKey(const ValueKey('workspace-more-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('문서 내보내기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Markdown'));
    await tester.pumpAndSettle();
    expect(log, ['markdown', 'markdown']);
  });

  testWidgets('더 많은 기능 opens the shortcut bar editor', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('workspace-more-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shortcut-bar-customize')));
    await tester.pumpAndSettle();
    expect(log, ['customize']);
  });

  testWidgets('toolbar position row selects a side', (tester) async {
    final chosen = <AxisDirection>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ToolbarPositionRow(
            alignment: AxisDirection.up,
            onChanged: chosen.add,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('toolbar-position-left')));
    expect(chosen, [AxisDirection.left]);
    expect(find.text('도구 모음'), findsOneWidget);
  });
}
