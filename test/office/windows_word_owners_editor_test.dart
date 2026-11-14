import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

import 'windows_office_rich_editor_test.dart'
    show digest, input, mount, textDetails;
import 'windows_word_structure_editor_test.dart'
    show focusParagraph, paragraph, paragraphFields, press, save, value;

Map<String, Object?> ownerParagraph(String id, String ownerId, String text) => {
  'id': id,
  'ownerId': ownerId,
  'text': text,
  'fontSize': 12,
  'bold': false,
  'color': 0,
  'textDetails': textDetails(text),
  'paragraphFormat': {
    'styleName': 'Body',
    'alignment': 'left',
    'listKind': 'none',
    'listLevel': 0,
    'pageBreakBefore': false,
  },
  'structure': {
    'canSplit': true,
    'canDelete': true,
    'canInsertBefore': true,
    'canInsertAfter': true,
    'canJoinNext': true,
  },
};

WindowsOfficeSnapshot ownersFixture({bool missingDetails = false}) => WindowsOfficeSnapshot.fromJson({
  'kind': 'word',
  'sourceSha256': 'a' * 64,
  'bodyOwnerId': 'body',
  'blocks': [
    {'kind': 'paragraph', 'id': 'p0'},
    {'kind': 'table', 'id': 't0'},
  ],
  'paragraphs': [
    {
      ...ownerParagraph('p0', 'body', 'SAME'),
      if (missingDetails) 'textDetails': null,
    },
  ],
  'paragraphStyles': [
    {'name': 'Body', 'displayName': '본문 스타일'},
  ],
  'tables': [
    for (final item in [('t0', 'body', '본문 셀'), ('ht0', 'h0', '머리말 셀')])
      {
        'id': item.$1,
        'ownerId': item.$2,
        'cells': {'A1': item.$3},
        if (!missingDetails) 'cellTextDetails': {'A1': textDetails(item.$3)},
      },
  ],
  'wordOwners': [
    {
      'id': 'h0',
      'kind': 'header',
      'references': [
        {'pageStyleId': 'style0', 'variant': 'default'},
        {'pageStyleId': 'style0', 'variant': 'right'},
      ],
      'blocks': [
        {'kind': 'paragraph', 'id': 'hp0'},
        {'kind': 'table', 'id': 'ht0'},
        {'kind': 'paragraph', 'id': 'hp2'},
      ],
      'paragraphs': [
        ownerParagraph('hp0', 'h0', 'SAME'),
        {
          ...ownerParagraph('hp2', 'h0', 'HEADER END'),
          if (missingDetails) 'textDetails': null,
        },
      ],
      'tableIds': ['ht0'],
    },
    {
      'id': 'h1',
      'kind': 'header',
      'references': [
        {'pageStyleId': 'style0', 'variant': 'left'},
      ],
      'blocks': [
        {'kind': 'paragraph', 'id': 'hp1'},
      ],
      'paragraphs': [ownerParagraph('hp1', 'h1', 'SAME')],
      'tableIds': [],
    },
    {
      'id': 'f0',
      'kind': 'footer',
      'references': [
        {'pageStyleId': 'style1', 'variant': 'first'},
      ],
      'blocks': [
        {'kind': 'paragraph', 'id': 'fp0'},
      ],
      'paragraphs': [ownerParagraph('fp0', 'f0', 'FOOT')],
      'tableIds': [],
    },
  ],
  'pageStyles': [
    {
      'id': 'style0',
      'name': 'ImportedStyle0',
      'displayName': '보고서',
      'regions': {
        'header': {'default': 'h0', 'right': 'h0', 'left': 'h1', 'first': null},
        'footer': {'default': null, 'right': null, 'left': null, 'first': null},
      },
    },
    {
      'id': 'style1',
      'name': 'ImportedStyle1',
      'displayName': '첫 장',
      'regions': {
        'header': {'default': null, 'right': null, 'left': null, 'first': null},
        'footer': {'default': null, 'right': null, 'left': null, 'first': 'f0'},
      },
    },
  ],
  'slides': [],
});

Finder get ownerSelector =>
    find.byKey(const ValueKey('office-word-owner-selector'));
Finder ownerChoice(String id) => find.byKey(ValueKey('office-word-owner-$id'));
Finder cell(String tableId) => find.byKey(ValueKey('office-cell-$tableId-A1'));

Future<void> selectOwner(WidgetTester tester, String id) async {
  await tester.ensureVisible(ownerSelector);
  await tester.tap(ownerSelector);
  await tester.pumpAndSettle();
  await tester.tap(ownerChoice(id).last);
  await tester.pumpAndSettle();
}

String splitId(WidgetTester tester, String text) {
  final field = tester
      .widgetList<TextField>(paragraphFields)
      .singleWhere((field) => field.controller!.text == text);
  final id = (field.key! as ValueKey<String>).value.substring(
    'office-paragraph-'.length,
  );
  expect({
    'p0',
    'hp0',
    'hp1',
    'hp2',
    'fp0',
    't0',
    'ht0',
    'body',
    'h0',
    'h1',
    'f0',
    'style0',
    'style1',
  }, isNot(contains(id)));
  return id;
}

Map<String, Object?> append(String id, String before, String suffix) => {
  'op': 'textReplace',
  'targetKind': 'paragraph',
  'id': id,
  'startUtf16': before.length,
  'endUtf16': before.length,
  'expectedTextSha256': digest(before),
  'text': suffix,
};

void main() {
  testWidgets('equal-text owners stay distinct and edits retain chronology', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await mount(
      tester,
      ownersFixture(),
      commit: (operations) async {
        saved = [for (final operation in operations) operation.toJson()];
      },
    );
    expect(ownerSelector, findsOneWidget);
    expect(paragraph('p0'), findsOneWidget);
    expect(paragraph('hp0'), findsNothing);
    await tester.tap(ownerSelector);
    await tester.pumpAndSettle();
    expect(ownerChoice('h0'), findsOneWidget);
    expect(ownerChoice('h1'), findsOneWidget);
    final sharedLabel = tester
        .widgetList<Text>(
          find.descendant(of: ownerChoice('h0'), matching: find.byType(Text)),
        )
        .map((text) => text.data ?? '')
        .join(' ');
    expect(sharedLabel, contains('보고서'));
    expect(sharedLabel, contains('기본'));
    expect(sharedLabel, contains('오른쪽'));
    await tester.tap(ownerChoice('h0'));
    await tester.pumpAndSettle();
    await input(tester, paragraph('hp0'), 'SAME A');
    await selectOwner(tester, 'h1');
    expect(value(tester, 'hp1'), 'SAME');
    expect(paragraph('hp0'), findsNothing);
    await input(tester, paragraph('hp1'), 'SAME B');
    await selectOwner(tester, 'h0');
    expect(value(tester, 'hp0'), 'SAME A');
    await input(tester, paragraph('hp0'), 'SAME A!');
    await selectOwner(tester, 'body');
    await input(tester, paragraph('p0'), 'SAME BODY');
    await selectOwner(tester, 'f0');
    await input(tester, paragraph('fp0'), 'FOOT!');
    await save(tester);
    expect(saved, [
      append('hp0', 'SAME', ' A'),
      append('hp1', 'SAME', ' B'),
      append('hp0', 'SAME A', '!'),
      append('p0', 'SAME', ' BODY'),
      append('fp0', 'FOOT', '!'),
    ]);
  });

  testWidgets('owner block order and table editing exclude other scopes', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await mount(
      tester,
      ownersFixture(),
      commit: (operations) async {
        saved = [for (final operation in operations) operation.toJson()];
      },
    );
    expect(cell('t0'), findsOneWidget);
    expect(cell('ht0'), findsNothing);
    await selectOwner(tester, 'h0');
    expect(cell('t0'), findsNothing);
    expect(cell('ht0'), findsOneWidget);
    expect(paragraph('p0'), findsNothing);
    expect(
      tester.getTopLeft(paragraph('hp0')).dy,
      lessThan(tester.getTopLeft(cell('ht0')).dy),
    );
    expect(
      tester.getTopLeft(cell('ht0')).dy,
      lessThan(tester.getTopLeft(paragraph('hp2')).dy),
    );
    await input(tester, cell('ht0'), '머리말 셀!');
    await selectOwner(tester, 'f0');
    expect(cell('ht0'), findsNothing);
    expect(cell('t0'), findsNothing);
    expect(paragraphFields, findsOneWidget);
    await selectOwner(tester, 'body');
    expect(tester.widget<TextField>(cell('t0')).controller!.text, '본문 셀');
    await save(tester);
    expect(saved, [
      {
        'op': 'textReplace',
        'targetKind': 'cell',
        'id': 'ht0',
        'cell': 'A1',
        'startUtf16': '머리말 셀'.length,
        'endUtf16': '머리말 셀'.length,
        'expectedTextSha256': digest('머리말 셀'),
        'text': '!',
      },
    ]);
  });

  testWidgets(
    'global undo reveals affected owner and preserves local structure',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        ownersFixture(),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await selectOwner(tester, 'h1');
      await focusParagraph(tester, 'hp1', 2);
      await press(tester, 'office-word-split');
      final id = splitId(tester, 'ME');
      expect(value(tester, 'hp1'), 'SA');
      await selectOwner(tester, 'body');
      await input(tester, paragraph('p0'), 'SAME!');
      await press(tester, 'office-word-undo');
      expect(value(tester, 'p0'), 'SAME');
      await press(tester, 'office-word-undo');
      expect(paragraph('p0'), findsNothing);
      expect(value(tester, 'hp1'), 'SAME');
      expect(paragraph(id), findsNothing);
      await press(tester, 'office-word-redo');
      expect(value(tester, 'hp1'), 'SA');
      expect(value(tester, id), 'ME');
      await focusParagraph(tester, 'hp1', 2);
      await press(tester, 'office-word-join');
      expect(value(tester, 'hp1'), 'SAME');
      expect(paragraph(id), findsNothing);
      await selectOwner(tester, 'body');
      expect(value(tester, 'p0'), 'SAME');
      expect(cell('t0'), findsOneWidget);
      await save(tester);
      expect(saved, [
        {
          'op': 'paragraphSplit',
          'id': 'hp1',
          'newId': id,
          'offsetUtf16': 2,
          'expectedTextSha256': digest('SAME'),
        },
        {
          'op': 'paragraphJoin',
          'id': 'hp1',
          'nextId': id,
          'expectedTextSha256': digest('SA'),
          'expectedNextTextSha256': digest('ME'),
        },
      ]);
    },
  );

  testWidgets('body guard and owner boundaries disable invalid structure', (
    tester,
  ) async {
    var commits = 0;
    await mount(
      tester,
      ownersFixture(),
      commit: (_) async {
        commits++;
      },
    );
    await focusParagraph(tester, 'p0', 4);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('office-word-delete')))
          .onPressed,
      isNull,
    );
    await press(tester, 'office-word-delete');
    expect(value(tester, 'p0'), 'SAME');
    for (final item in [('h1', 'hp1', 'SAME'), ('f0', 'fp0', 'FOOT')]) {
      await selectOwner(tester, item.$1);
      await focusParagraph(tester, item.$2, 0);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('office-word-join')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const ValueKey('office-word-page-break')),
            )
            .onSelected,
        isNull,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pumpAndSettle();
      expect(value(tester, item.$2), item.$3);
      expect(paragraphFields, findsOneWidget);
    }
    await save(tester);
    expect(commits, 0);
  });

  testWidgets('owner history preserves missing paragraph and cell capabilities', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await mount(
      tester,
      ownersFixture(missingDetails: true),
      commit: (operations) async {
        saved = [for (final operation in operations) operation.toJson()];
      },
    );
    expect(tester.widget<TextField>(paragraph('p0')).readOnly, isTrue);
    expect(tester.widget<TextField>(cell('t0')).readOnly, isTrue);
    await selectOwner(tester, 'h0');
    expect(tester.widget<TextField>(paragraph('hp0')).readOnly, isFalse);
    expect(tester.widget<TextField>(paragraph('hp2')).readOnly, isTrue);
    expect(tester.widget<TextField>(cell('ht0')).readOnly, isTrue);
    await input(tester, paragraph('hp0'), 'SAME!');
    await selectOwner(tester, 'body');
    await press(tester, 'office-word-undo');
    expect(value(tester, 'hp0'), 'SAME');
    expect(tester.widget<TextField>(paragraph('hp2')).readOnly, isTrue);
    expect(tester.widget<TextField>(cell('ht0')).readOnly, isTrue);
    await selectOwner(tester, 'body');
    expect(tester.widget<TextField>(paragraph('p0')).readOnly, isTrue);
    expect(tester.widget<TextField>(cell('t0')).readOnly, isTrue);
    await press(tester, 'office-word-redo');
    expect(value(tester, 'hp0'), 'SAME!');
    expect(tester.widget<TextField>(paragraph('hp2')).readOnly, isTrue);
    expect(tester.widget<TextField>(cell('ht0')).readOnly, isTrue);
    await selectOwner(tester, 'body');
    expect(value(tester, 'p0'), 'SAME');
    expect(tester.widget<TextField>(cell('t0')).controller!.text, '본문 셀');
    expect(tester.widget<TextField>(paragraph('p0')).readOnly, isTrue);
    expect(tester.widget<TextField>(cell('t0')).readOnly, isTrue);
    await save(tester);
    expect(saved, [append('hp0', 'SAME', '!')]);
  });

  testWidgets('legacy snapshot without owners keeps original text editing', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await mount(
      tester,
      WindowsOfficeSnapshot.fromJson({
        'kind': 'word',
        'sourceSha256': 'a' * 64,
        'paragraphs': [
          {'id': 'p0', 'text': '본문', 'fontSize': 12, 'bold': false, 'color': 0},
        ],
        'tables': [],
        'slides': [],
      }),
      commit: (operations) async {
        saved = [for (final operation in operations) operation.toJson()];
      },
    );
    expect(ownerSelector, findsNothing);
    await input(tester, paragraph('p0'), '본문 수정');
    await save(tester);
    expect(saved, [
      {'op': 'paragraphText', 'id': 'p0', 'text': '본문 수정'},
    ]);
  });
}
