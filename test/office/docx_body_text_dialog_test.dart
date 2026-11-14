import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/docx_body_text.dart';
import 'package:saber/pages/office/docx_body_text_dialog.dart';

const _paragraph = ValueKey('docx-body-text-paragraph');
const _run = ValueKey('docx-body-text-run');
const _input = ValueKey('docx-body-text-input');
const _save = ValueKey('docx-body-text-confirm');
const _cell = ValueKey('docx-table-cell-address');

DocxBodyTextPlan _plan() => DocxBodyTextPlan(
  sourceSha256: 'a' * 64,
  paragraphs: [
    DocxBodyTextParagraph(
      paragraphIndex: 0,
      runs: const [
        DocxBodyTextRun(runIndex: 1, text: ' 시작 😀 & 끝 '),
        DocxBodyTextRun(runIndex: 4, text: '같은 문단'),
      ],
    ),
    DocxBodyTextParagraph(
      paragraphIndex: 4,
      runs: const [DocxBodyTextRun(runIndex: 2, text: '')],
    ),
  ],
);

Future<void> _openDialog(
  WidgetTester tester,
  Future<void> Function(BuildContext) open,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

Future<void> _open(
  WidgetTester tester,
  DocxBodyTextPlan plan,
  void Function(DocxBodyTextDraft?) close,
) => _openDialog(
  tester,
  (context) async => close(await chooseDocxBodyText(context, plan)),
);

Future<void> _select(WidgetTester tester, Key key, String label) async {
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining(label).last);
  await tester.pumpAndSettle();
}

TextEditingController _editor(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(_input)).controller!;

void main() {
  test('requires valid single-line text within the UTF-16 limit', () {
    for (final value in ['', ' 한글 😀 & <> ', '😀' * 1000]) {
      expect(DocxBodyTextEngine.validText(value), isTrue);
    }
    for (final value in [
      '😀' * 1001,
      'a\nb',
      'a\u2028b',
      '\t',
      '\u0000',
      '\ufffe',
      String.fromCharCode(0xd800),
    ]) {
      expect(DocxBodyTextEngine.validText(value), isFalse);
    }
  });

  testWidgets('prefills an exact run and saves a deletion on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 630);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    DocxBodyTextDraft? draft;
    await _open(tester, _plan(), (value) => draft = value);
    expect(find.text('DOCX 본문 글자 수정'), findsOneWidget);
    expect(_editor(tester).text, ' 시작 😀 & 끝 ');
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
    await tester.enterText(find.byKey(_input), '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_save));
    await tester.pumpAndSettle();
    expect(draft, (paragraphIndex: 0, runIndex: 1, text: ''));
    expect(tester.takeException(), isNull);
  });

  testWidgets('requires an explicit discard before changing an edited run', (
    tester,
  ) async {
    DocxBodyTextDraft? draft;
    await _open(tester, _plan(), (value) => draft = value);
    await tester.enterText(find.byKey(_input), '임시 변경');
    await tester.pumpAndSettle();
    await _select(tester, _run, '같은 문단');
    expect(find.text('수정을 버릴까요?'), findsOneWidget);
    await tester.tap(find.text('계속 수정'));
    await tester.pumpAndSettle();
    expect(_editor(tester).text, '임시 변경');
    await _select(tester, _paragraph, '문단 5');
    await tester.tap(find.text('수정 버리기'));
    await tester.pumpAndSettle();
    expect(_editor(tester).text, '');
    await tester.enterText(find.byKey(_input), '새 문구 😀');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_save));
    await tester.pumpAndSettle();
    expect(draft, (paragraphIndex: 4, runIndex: 2, text: '새 문구 😀'));
  });

  testWidgets('can close a document without an editable run', (tester) async {
    var closed = false;
    await _open(
      tester,
      DocxBodyTextPlan(sourceSha256: 'a' * 64, paragraphs: []),
      (draft) {
        expect(draft, isNull);
        closed = true;
      },
    );
    expect(find.byKey(_input), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  testWidgets('edits an empty DOCX table cell by its visible coordinates', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 630);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const emptyCell = (tableIndex: 1, rowIndex: 3, cellIndex: 2);
    final plan = DocxTableCellTextPlan(
      sourceSha256: 'a' * 64,
      cells: [
        DocxTableCellText(
          address: (tableIndex: 0, rowIndex: 0, cellIndex: 1),
          paragraphs: _plan().paragraphs,
        ),
        DocxTableCellText(
          address: emptyCell,
          paragraphs: [
            DocxBodyTextParagraph(
              paragraphIndex: 0,
              runs: const [DocxBodyTextRun(runIndex: 0, text: '')],
            ),
            DocxBodyTextParagraph(
              paragraphIndex: 2,
              runs: const [DocxBodyTextRun(runIndex: 1, text: '기존 문단')],
            ),
          ],
        ),
      ],
    );
    DocxTableCellTextDraft? draft;
    await _openDialog(
      tester,
      (context) async => draft = await chooseDocxTableCellText(context, plan),
    );
    expect(find.text('DOCX 표 셀 글자 수정'), findsOneWidget);
    await tester.enterText(find.byKey(_input), '첫 셀의 초안');
    await tester.pumpAndSettle();
    await _select(tester, _cell, '표 2 · 4행 3열');
    await tester.tap(find.text('계속 수정'));
    await tester.pumpAndSettle();
    expect(_editor(tester).text, '첫 셀의 초안');

    await _select(tester, _cell, '표 2 · 4행 3열');
    await tester.tap(find.text('수정 버리기'));
    await tester.pumpAndSettle();
    expect(_editor(tester).text, '');
    await _select(tester, _paragraph, '문단 3');
    expect(_editor(tester).text, '기존 문단');
    await _select(tester, _paragraph, '문단 1');
    expect(_editor(tester).text, '');
    await tester.enterText(find.byKey(_input), ' 첫 값 😀 & ');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_save));
    await tester.pumpAndSettle();
    expect(draft, (
      address: emptyCell,
      paragraphIndex: 0,
      runIndex: 0,
      text: ' 첫 값 😀 & ',
    ));
    expect(tester.takeException(), isNull);
  });
}
