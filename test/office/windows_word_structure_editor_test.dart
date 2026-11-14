import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

import 'windows_office_rich_editor_test.dart'
    show digest, input, mount, textDetails;

WindowsOfficeSnapshot structureFixture({
  bool table = false,
  bool opaque = false,
  bool single = false,
  String secondListKind = 'none',
  bool secondCanSplit = true,
  String firstText = 'ABCD',
  List<Map<String, Object?>> protectedRanges = const [],
}) => WindowsOfficeSnapshot.fromJson({
  'kind': 'word',
  'sourceSha256': 'a' * 64,
  'blocks': [
    {'kind': 'paragraph', 'id': 'p0'},
    if (table) {'kind': 'table', 'id': 't0'},
    if (!single) {'kind': 'paragraph', 'id': 'p1'},
    if (opaque) ...[
      {'kind': 'opaque', 'id': 'o0'},
      {'kind': 'paragraph', 'id': 'p2'},
    ],
  ],
  'paragraphStyles': [
    {'name': 'StudyBody', 'displayName': '본문'},
    {'name': 'StudyHeading', 'displayName': '수업 제목'},
  ],
  'paragraphs': [
    for (final item in [
      ('p0', firstText),
      if (!single) ('p1', 'TAIL'),
      if (opaque) ('p2', 'LAST'),
    ])
      {
        'id': item.$1,
        'text': item.$2,
        'fontSize': 12,
        'bold': false,
        'color': 0,
        'textDetails': textDetails(
          item.$2,
          protectedRanges: item.$1 == 'p0' ? protectedRanges : const [],
        ),
        'paragraphFormat': {
          'styleName': 'StudyBody',
          'alignment': 'left',
          'listKind': item.$1 == 'p1' ? secondListKind : 'none',
          'listLevel': 0,
          'pageBreakBefore': false,
        },
        'structure': {
          'canSplit': item.$1 != 'p1' || secondCanSplit,
          'canDelete':
              !single &&
              item.$1 != (opaque ? 'p2' : 'p1') &&
              (item.$1 != 'p1' || secondCanSplit),
          'canInsertBefore': item.$1 != 'p1' || secondCanSplit,
          'canInsertAfter': item.$1 != 'p1' || secondCanSplit,
          'canJoinNext': item.$1 == 'p0' && !table && !single && secondCanSplit,
        },
      },
  ],
  'tables': [
    if (table)
      {
        'id': 't0',
        'cells': {'A1': '표 내용'},
        'cellTextDetails': {'A1': textDetails('표 내용')},
      },
  ],
  'slides': [],
});

Finder paragraph(String id) => find.byKey(ValueKey('office-paragraph-$id'));

Finder get paragraphFields => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.key is ValueKey<String> &&
      (widget.key as ValueKey<String>).value.startsWith('office-paragraph-'),
);

String newParagraphId(WidgetTester tester, String text) {
  final fields = tester
      .widgetList<TextField>(paragraphFields)
      .where(
        (field) =>
            field.controller!.text == text &&
            !const {
              'office-paragraph-p0',
              'office-paragraph-p1',
              'office-paragraph-p2',
            }.contains((field.key! as ValueKey<String>).value),
      )
      .toList();
  expect(fields, hasLength(1));
  final id = (fields.single.key! as ValueKey<String>).value.substring(
    'office-paragraph-'.length,
  );
  expect(
    id,
    matches(
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    ),
  );
  return id;
}

String value(WidgetTester tester, String id) =>
    tester.widget<TextField>(paragraph(id)).controller!.text;

Future<void> focusParagraph(WidgetTester tester, String id, int offset) async {
  await tester.ensureVisible(paragraph(id));
  await input(
    tester,
    paragraph(id),
    value(tester, id),
    selection: TextSelection.collapsed(offset: offset),
  );
}

Future<void> press(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.text('저장하고 닫기'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Word body shows paragraph table and opaque blocks in original order',
    (tester) async {
      await mount(
        tester,
        structureFixture(table: true, opaque: true),
        commit: (_) async {},
      );
      tester.view.physicalSize = const Size(1280, 1600);
      await tester.pump();
      final table = find.byKey(const ValueKey('office-cell-t0-A1'));
      final opaque = find.byKey(const ValueKey('office-word-opaque-o0'));
      expect(opaque, findsOneWidget);
      expect(
        tester.getTopLeft(paragraph('p0')).dy,
        lessThan(tester.getTopLeft(table).dy),
      );
      expect(
        tester.getTopLeft(table).dy,
        lessThan(tester.getTopLeft(paragraph('p1')).dy),
      );
      expect(
        tester.getTopLeft(paragraph('p1')).dy,
        lessThan(tester.getTopLeft(opaque).dy),
      );
      expect(
        tester.getTopLeft(opaque).dy,
        lessThan(tester.getTopLeft(paragraph('p2')).dy),
      );
    },
  );

  testWidgets(
    'text split and edits to both paragraph aliases keep chronological hashes',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(table: true),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(tester, paragraph('p0'), 'AXCD');
      await focusParagraph(tester, 'p0', 2);
      await press(tester, 'office-word-split');
      final rightId = newParagraphId(tester, 'CD');
      expect(value(tester, 'p0'), 'AX');
      expect(
        tester
            .widget<TextField>(paragraph(rightId))
            .controller!
            .selection
            .baseOffset,
        0,
      );
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: paragraph(rightId),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.focusNode.hasFocus, isTrue);
      await input(tester, paragraph(rightId), 'CD!');
      await input(tester, paragraph('p0'), 'AZ');
      await save(tester);
      expect(saved, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 1,
          'endUtf16': 2,
          'expectedTextSha256': digest('ABCD'),
          'text': 'X',
        },
        {
          'op': 'paragraphSplit',
          'id': 'p0',
          'newId': rightId,
          'offsetUtf16': 2,
          'expectedTextSha256': digest('AXCD'),
        },
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': rightId,
          'startUtf16': 2,
          'endUtf16': 2,
          'expectedTextSha256': digest('CD'),
          'text': '!',
        },
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 1,
          'endUtf16': 2,
          'expectedTextSha256': digest('AX'),
          'text': 'Z',
        },
      ]);
    },
  );

  testWidgets('confirmed keyboard newline creates one structural split', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await mount(
      tester,
      structureFixture(),
      commit: (operations) async {
        saved = [for (final operation in operations) operation.toJson()];
      },
    );
    await input(
      tester,
      paragraph('p0'),
      'AB\nCD',
      selection: const TextSelection.collapsed(offset: 3),
    );
    final rightId = newParagraphId(tester, 'CD');
    expect(value(tester, 'p0'), 'AB');
    await save(tester);
    expect(saved, [
      {
        'op': 'paragraphSplit',
        'id': 'p0',
        'newId': rightId,
        'offsetUtf16': 2,
        'expectedTextSha256': digest('ABCD'),
      },
    ]);
  });

  testWidgets(
    'composition is preserved before split and committed once when confirmed',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(
        tester,
        paragraph('p0'),
        'AB한CD',
        selection: const TextSelection.collapsed(offset: 3),
        composing: const TextRange(start: 2, end: 3),
      );
      await press(tester, 'office-word-split');
      expect(value(tester, 'p0'), 'AB한CD');
      expect(paragraphFields, findsNWidgets(2));
      expect(
        tester.widget<TextField>(paragraph('p0')).controller!.value.composing,
        const TextRange(start: 2, end: 3),
      );
      await input(
        tester,
        paragraph('p0'),
        'AB한CD',
        selection: const TextSelection.collapsed(offset: 3),
      );
      await press(tester, 'office-word-split');
      final rightId = newParagraphId(tester, 'CD');
      await save(tester);
      expect(saved, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 2,
          'endUtf16': 2,
          'expectedTextSha256': digest('ABCD'),
          'text': '한',
        },
        {
          'op': 'paragraphSplit',
          'id': 'p0',
          'newId': rightId,
          'offsetUtf16': 3,
          'expectedTextSha256': digest('AB한CD'),
        },
      ]);
    },
  );

  testWidgets(
    'split selection undo and redo restore text caret and the same alias',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(
        tester,
        paragraph('p0'),
        'ABCD',
        selection: const TextSelection(baseOffset: 1, extentOffset: 3),
      );
      await press(tester, 'office-word-split');
      final rightId = newParagraphId(tester, 'D');
      expect(value(tester, 'p0'), 'A');
      await press(tester, 'office-word-undo');
      expect(value(tester, 'p0'), 'ABCD');
      expect(paragraph(rightId), findsNothing);
      expect(
        tester.widget<TextField>(paragraph('p0')).controller!.selection,
        const TextSelection(baseOffset: 1, extentOffset: 3),
      );
      await press(tester, 'office-word-redo');
      expect(newParagraphId(tester, 'D'), rightId);
      await save(tester);
      expect(saved, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 1,
          'endUtf16': 3,
          'expectedTextSha256': digest('ABCD'),
          'text': '',
        },
        {
          'op': 'paragraphSplit',
          'id': 'p0',
          'newId': rightId,
          'offsetUtf16': 1,
          'expectedTextSha256': digest('AD'),
        },
      ]);
    },
  );

  testWidgets(
    'joining adjacent paragraphs keeps the left ID and subsequent text hash',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await focusParagraph(tester, 'p0', 4);
      await press(tester, 'office-word-join');
      expect(value(tester, 'p0'), 'ABCDTAIL');
      expect(paragraph('p1'), findsNothing);
      expect(
        tester
            .widget<TextField>(paragraph('p0'))
            .controller!
            .selection
            .baseOffset,
        4,
      );
      await input(tester, paragraph('p0'), 'ABCDTAIL!');
      await save(tester);
      expect(saved, [
        {
          'op': 'paragraphJoin',
          'id': 'p0',
          'nextId': 'p1',
          'expectedTextSha256': digest('ABCD'),
          'expectedNextTextSha256': digest('TAIL'),
        },
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 8,
          'endUtf16': 8,
          'expectedTextSha256': digest('ABCDTAIL'),
          'text': '!',
        },
      ]);
    },
  );

  testWidgets(
    'undo of hardware backspace join restores the right input owner and hash',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await focusParagraph(tester, 'p1', 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(value(tester, 'p0'), 'ABCDTAIL');
      expect(paragraph('p1'), findsNothing);
      await press(tester, 'office-word-undo');
      expect(value(tester, 'p0'), 'ABCD');
      expect(value(tester, 'p1'), 'TAIL');
      final field = tester.widget<TextField>(paragraph('p1'));
      expect(
        field.controller!.selection,
        const TextSelection.collapsed(offset: 0),
      );
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: paragraph('p1'),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.focusNode.hasFocus, isTrue);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'XTAIL',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();
      expect(value(tester, 'p0'), 'ABCD');
      expect(value(tester, 'p1'), 'XTAIL');
      await save(tester);
      expect(saved, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p1',
          'startUtf16': 0,
          'endUtf16': 0,
          'expectedTextSha256': digest('TAIL'),
          'text': 'X',
        },
      ]);
    },
  );

  testWidgets(
    'paragraph join and hardware backspace cannot cross an intervening table',
    (tester) async {
      var commits = 0;
      await mount(
        tester,
        structureFixture(table: true),
        commit: (_) async {
          commits++;
        },
      );
      await focusParagraph(tester, 'p0', 4);
      await press(tester, 'office-word-join');
      await focusParagraph(tester, 'p1', 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(value(tester, 'p0'), 'ABCD');
      expect(value(tester, 'p1'), 'TAIL');
      expect(find.byKey(const ValueKey('office-cell-t0-A1')), findsOneWidget);
      await save(tester);
      expect(commits, 0);
    },
  );

  testWidgets(
    'protected field boundary split is rejected without changing either paragraph',
    (tester) async {
      var commits = 0;
      await mount(
        tester,
        structureFixture(
          firstText: 'A1B',
          protectedRanges: [
            {'startUtf16': 1, 'endUtf16': 2, 'type': 'TextField'},
          ],
        ),
        commit: (_) async {
          commits++;
        },
      );
      await focusParagraph(tester, 'p0', 1);
      await press(tester, 'office-word-split');
      expect(value(tester, 'p0'), 'A1B');
      expect(value(tester, 'p1'), 'TAIL');
      expect(paragraphFields, findsNWidgets(2));
      await save(tester);
      expect(commits, 0);
    },
  );

  testWidgets(
    'unsaved paragraph insertion deletion and another insertion never reuse an alias',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await focusParagraph(tester, 'p0', 4);
      await press(tester, 'office-word-insert-after');
      final removedId = newParagraphId(tester, '');
      await press(tester, 'office-word-delete');
      expect(paragraph(removedId), findsNothing);
      await focusParagraph(tester, 'p0', 4);
      await press(tester, 'office-word-insert-after');
      final finalId = newParagraphId(tester, '');
      expect(finalId, isNot(removedId));
      await save(tester);
      expect(saved, [
        {
          'op': 'paragraphInsert',
          'id': finalId,
          'referenceId': 'p0',
          'position': 'after',
          'expectedTextSha256': digest('ABCD'),
          'text': '',
        },
      ]);
    },
  );

  testWidgets(
    'insert before a paragraph preserves the preceding table position',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(table: true),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await focusParagraph(tester, 'p1', 0);
      await press(tester, 'office-word-insert-before');
      final id = newParagraphId(tester, '');
      final table = find.byKey(const ValueKey('office-cell-t0-A1'));
      expect(
        tester.getTopLeft(table).dy,
        lessThan(tester.getTopLeft(paragraph(id)).dy),
      );
      expect(
        tester.getTopLeft(paragraph(id)).dy,
        lessThan(tester.getTopLeft(paragraph('p1')).dy),
      );
      await save(tester);
      expect(saved, [
        {
          'op': 'paragraphInsert',
          'id': id,
          'referenceId': 'p1',
          'position': 'before',
          'expectedTextSha256': digest('TAIL'),
          'text': '',
        },
      ]);
    },
  );

  testWidgets(
    'a newly inserted final paragraph keeps the native mandatory body boundary',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await focusParagraph(tester, 'p1', 4);
      await press(tester, 'office-word-insert-after');
      final id = newParagraphId(tester, '');
      await press(tester, 'office-word-delete');
      expect(paragraph(id), findsOneWidget);
      expect(value(tester, 'p1'), 'TAIL');
      await save(tester);
      expect(saved, [
        {
          'op': 'paragraphInsert',
          'id': id,
          'referenceId': 'p1',
          'position': 'after',
          'expectedTextSha256': digest('TAIL'),
          'text': '',
        },
      ]);
    },
  );

  testWidgets(
    'new paragraph join cannot bypass the original right structural capability',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(secondCanSplit: false),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await focusParagraph(tester, 'p0', 4);
      await press(tester, 'office-word-insert-after');
      final id = newParagraphId(tester, '');
      await press(tester, 'office-word-join');
      expect(paragraph('p1'), findsOneWidget);
      expect(value(tester, 'p1'), 'TAIL');
      expect(paragraph(id), findsOneWidget);
      await save(tester);
      expect(saved, [
        {
          'op': 'paragraphInsert',
          'id': id,
          'referenceId': 'p0',
          'position': 'after',
          'expectedTextSha256': digest('ABCD'),
          'text': '',
        },
      ]);
    },
  );

  testWidgets(
    'join undo and redo restore both original paragraphs and one join operation',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await focusParagraph(tester, 'p0', 4);
      await press(tester, 'office-word-join');
      await press(tester, 'office-word-undo');
      expect(value(tester, 'p0'), 'ABCD');
      expect(value(tester, 'p1'), 'TAIL');
      await press(tester, 'office-word-redo');
      expect(value(tester, 'p0'), 'ABCDTAIL');
      expect(paragraph('p1'), findsNothing);
      await save(tester);
      expect(saved, [
        {
          'op': 'paragraphJoin',
          'id': 'p0',
          'nextId': 'p1',
          'expectedTextSha256': digest('ABCD'),
          'expectedNextTextSha256': digest('TAIL'),
        },
      ]);
    },
  );

  testWidgets('the required last paragraph cannot be deleted', (tester) async {
    var commits = 0;
    await mount(
      tester,
      structureFixture(single: true),
      commit: (_) async {
        commits++;
      },
    );
    await focusParagraph(tester, 'p0', 4);
    await press(tester, 'office-word-delete');
    expect(value(tester, 'p0'), 'ABCD');
    expect(paragraphFields, findsOneWidget);
    await save(tester);
    expect(commits, 0);
  });

  testWidgets(
    'active paragraph format uses source styles and only requested paragraph properties',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await focusParagraph(tester, 'p1', 2);
      expect(find.byKey(const ValueKey('office-word-style')), findsOneWidget);
      await press(tester, 'office-word-style');
      await tester.tap(find.text('수업 제목').last);
      await tester.pumpAndSettle();
      await press(tester, 'office-word-alignment-center');
      await press(tester, 'office-word-list-bullet');
      await press(tester, 'office-word-list-level');
      await press(tester, 'office-word-list-level-2');
      await press(tester, 'office-word-page-break');
      await save(tester);
      expect(saved, isNotEmpty);
      const properties = {
        'styleName',
        'alignment',
        'listKind',
        'listLevel',
        'pageBreakBefore',
      };
      final finalFormat = <String, Object?>{};
      for (final operation in saved!) {
        expect(operation['op'], 'paragraphFormat');
        expect(operation['id'], 'p1');
        expect(operation['expectedTextSha256'], digest('TAIL'));
        expect(
          operation.keys.toSet().difference({
            'op',
            'id',
            'expectedTextSha256',
            ...properties,
          }),
          isEmpty,
        );
        for (final entry in operation.entries) {
          if (properties.contains(entry.key))
            finalFormat[entry.key] = entry.value;
        }
      }
      expect(finalFormat, {
        'styleName': 'StudyHeading',
        'alignment': 'center',
        'listKind': 'bullet',
        'listLevel': 2,
        'pageBreakBefore': true,
      });
      expect(value(tester, 'p0'), 'ABCD');
    },
  );

  testWidgets(
    'alignment change preserves unsupported existing list formatting',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        structureFixture(secondListKind: 'other'),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await focusParagraph(tester, 'p1', 2);
      await press(tester, 'office-word-alignment-center');
      await save(tester);
      expect(saved, [
        {
          'op': 'paragraphFormat',
          'id': 'p1',
          'expectedTextSha256': digest('TAIL'),
          'alignment': 'center',
        },
      ]);
    },
  );

  testWidgets(
    'failed structural save retains text aliases and the exact retry payload',
    (tester) async {
      final attempts = <List<Map<String, Object?>>>[];
      var closed = false;
      await mount(
        tester,
        structureFixture(),
        commit: (operations) async {
          attempts.add([
            for (final operation in operations) operation.toJson(),
          ]);
          if (attempts.length == 1)
            throw StateError('Synthetic structure save failure');
        },
        back: () => closed = true,
      );
      await focusParagraph(tester, 'p0', 2);
      await press(tester, 'office-word-split');
      final rightId = newParagraphId(tester, 'CD');
      await input(tester, paragraph(rightId), 'CD!');
      await save(tester);
      expect(closed, isFalse);
      expect(value(tester, 'p0'), 'AB');
      expect(value(tester, rightId), 'CD!');
      await tester.tap(find.text('저장 재시도'));
      await tester.pumpAndSettle();
      expect(attempts, hasLength(2));
      expect(attempts[1], attempts[0]);
      expect(attempts[0][0]['newId'], rightId);
      expect(attempts[0][1]['id'], rightId);
      expect(closed, isTrue);
    },
  );

  testWidgets(
    'legacy snapshot without structure keeps the original two text operations',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        WindowsOfficeSnapshot.fromJson({
          'kind': 'word',
          'sourceSha256': 'a' * 64,
          'paragraphs': [
            {
              'id': 'p0',
              'text': '기존',
              'fontSize': 12,
              'bold': false,
              'color': 0,
            },
          ],
          'tables': [
            {
              'id': 't0',
              'cells': {'A1': '셀'},
            },
          ],
          'slides': [],
        }),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      expect(find.byKey(const ValueKey('office-word-split')), findsNothing);
      await input(tester, paragraph('p0'), '본문 변경');
      await input(
        tester,
        find.byKey(const ValueKey('office-cell-t0-A1')),
        '셀 변경',
      );
      await save(tester);
      expect(saved, [
        {'op': 'paragraphText', 'id': 'p0', 'text': '본문 변경'},
        {'op': 'tableCellText', 'tableId': 't0', 'cell': 'A1', 'text': '셀 변경'},
      ]);
    },
  );
}
