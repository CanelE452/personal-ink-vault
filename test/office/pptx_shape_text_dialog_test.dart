import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/pptx_shape_text.dart';
import 'package:saber/pages/office/pptx_shape_text_dialog.dart';

const _slide = ValueKey('pptx-shape-text-slide');
const _shape = ValueKey('pptx-shape-text-shape');
const _firstRun = ValueKey('pptx-shape-text-run-0-0');
const _secondRun = ValueKey('pptx-shape-text-run-1-2');
const _confirm = ValueKey('pptx-shape-text-confirm');
const _cancel = ValueKey('pptx-shape-text-cancel');

PptxShapeTextShape _sample(int id, String name) => PptxShapeTextShape(
  shapeId: id,
  name: name,
  runs: const [
    PptxShapeTextRun(paragraphIndex: 0, runIndex: 0, text: '기존 제목'),
    PptxShapeTextRun(paragraphIndex: 1, runIndex: 2, text: '기존 설명'),
  ],
);

Future<void> _open(
  WidgetTester tester,
  Future<List<PptxShapeTextShape>> Function(int) loadSlide,
  void Function(PptxShapeTextDraft?) onClose, {
  bool formatOnly = false,
  bool alignmentOnly = false,
}) async {
  final plan = PptxShapeTextPlan(
    sourceSha256: 'a' * 64,
    slides: const [
      PptxShapeTextSlide(index: 0, hidden: false),
      PptxShapeTextSlide(index: 1, hidden: false),
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              onClose(
                await choosePptxShapeText(
                  context,
                  plan,
                  loadSlide,
                  formatOnly: formatOnly,
                  alignmentOnly: alignmentOnly,
                ),
              );
            },
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, Key key, String label) async {
  await tester.tap(find.byKey(key));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(label).last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('aligns one whole PPTX paragraph without selecting a text run', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final shape = PptxShapeTextShape(
      shapeId: 7,
      name: '제목 상자',
      runs: const [],
      paragraphs: const [
        PptxShapeTextParagraph(
          index: 0,
          text: '기존 제목',
          alignment: PptxParagraphAlignment.inherited,
        ),
        PptxShapeTextParagraph(
          index: 2,
          text: '다음 문단',
          alignment: PptxParagraphAlignment.center,
        ),
      ],
    );
    PptxShapeTextDraft? draft;
    await _open(
      tester,
      (_) async => [shape],
      (value) => draft = value,
      alignmentOnly: true,
    );
    await _choose(tester, _slide, '슬라이드 1');
    await _choose(tester, _shape, '제목 상자');
    await _choose(
      tester,
      const ValueKey('pptx-shape-paragraph'),
      '문단 1 · 기존 제목',
    );
    final confirm = find.byKey(const ValueKey('pptx-shape-align-confirm'));
    expect(find.text('현재 정렬 · 상속'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    const alignment = ValueKey('pptx-shape-paragraph-alignment');
    await tester.ensureVisible(find.byKey(alignment));
    await _choose(tester, alignment, '상속');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    await _choose(tester, alignment, '오른쪽');
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(draft?.shape, same(shape));
    expect(draft?.alignment?.paragraphIndex, 0);
    expect(draft?.alignment?.value, PptxParagraphAlignment.right);
    expect(draft?.changes, isEmpty);
    expect(draft?.format, isNull);
    expect(tester.takeException(), isNull);
  });

  test('validates UTF-16 length, XML characters, and single-line text', () {
    expect(PptxShapeTextEngine.validText(''), isTrue);
    expect(PptxShapeTextEngine.validText('한글 😀 & <> '), isTrue);
    expect(PptxShapeTextEngine.validText('😀' * 1000), isTrue);
    expect(PptxShapeTextEngine.validText('😀' * 1001), isFalse);
    for (final invalid in [
      '\n',
      '\r',
      '\u0000',
      '\u2028',
      '\ufffe',
      String.fromCharCode(0xd800),
    ]) {
      expect(PptxShapeTextEngine.validText(invalid), isFalse);
    }
  });

  testWidgets('edits two existing runs and clears text on a narrow phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final shape = _sample(6, '본문 상자');
    PptxShapeTextDraft? draft;
    final loaded = <int>[];
    await _open(tester, (index) async {
      loaded.add(index);
      return [shape];
    }, (value) => draft = value);
    expect(loaded, isEmpty);
    await _choose(tester, _slide, '슬라이드 1');
    expect(loaded, [0]);
    await _choose(tester, _shape, '본문 상자');
    expect(tester.widget<FilledButton>(find.byKey(_confirm)).onPressed, isNull);
    expect(find.text('기존 제목'), findsOneWidget);
    await tester.enterText(find.byKey(_firstRun), '새 제목 😀 &');
    final secondRun = find.byKey(_secondRun);
    await tester.ensureVisible(secondRun);
    await tester.enterText(secondRun, '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(draft?.slideIndex, 0);
    expect(draft?.shape, same(shape));
    expect(
      draft?.changes.map(
        (change) => (change.paragraphIndex, change.runIndex, change.text),
      ),
      [(0, 0, '새 제목 😀 &'), (1, 2, '')],
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('ignores a late slide read after selection changes', (
    tester,
  ) async {
    final first = Completer<List<PptxShapeTextShape>>();
    final second = Completer<List<PptxShapeTextShape>>();
    var closed = false;
    await _open(tester, (index) => index == 0 ? first.future : second.future, (
      value,
    ) {
      expect(value, isNull);
      closed = true;
    });
    await _choose(tester, _slide, '슬라이드 1');
    await _choose(tester, _slide, '슬라이드 2');
    second.complete([_sample(8, '현재 도형')]);
    await tester.pumpAndSettle();
    first.complete([_sample(9, '오래된 도형')]);
    await tester.pumpAndSettle();
    await _choose(tester, _shape, '현재 도형');
    expect(find.text('오래된 도형'), findsNothing);
    await tester.tap(find.byKey(_cancel));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('font controls keep and validate the selected run on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final shape = PptxShapeTextShape(
      shapeId: 6,
      name: '본문 상자',
      runs: const [
        PptxShapeTextRun(paragraphIndex: 0, runIndex: 0, text: 'A🧑‍🔬Z'),
        PptxShapeTextRun(paragraphIndex: 1, runIndex: 2, text: '기존 설명'),
      ],
    );
    PptxShapeTextDraft? draft;
    await _open(
      tester,
      (_) async => [shape],
      (value) => draft = value,
      formatOnly: true,
    );
    await _choose(tester, _slide, '슬라이드 1');
    await _choose(tester, _shape, '본문 상자');
    final first = find.byKey(const ValueKey('pptx-shape-format-run-0-0'));
    final second = find.byKey(const ValueKey('pptx-shape-format-run-1-2'));
    final fontSize = find.byKey(const ValueKey('pptx-shape-format-font-size'));
    final fontColor = find.byKey(
      const ValueKey('pptx-shape-format-font-color'),
    );
    final confirm = find.byKey(const ValueKey('pptx-shape-format-confirm'));
    bool canSave() => tester.widget<FilledButton>(confirm).onPressed != null;

    Future<void> select(
      Finder field,
      int start,
      int end, {
      double scrollDelta = 50,
    }) async {
      if (field.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          field,
          scrollDelta,
          scrollable: find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        );
      }
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      expect(field.hitTestable(), findsOneWidget);
      await tester.tap(field);
      tester.widget<TextField>(field).controller!.selection = TextSelection(
        baseOffset: start,
        extentOffset: end,
      );
      await tester.pumpAndSettle();
    }

    Future<void> enter(Finder field, String text) async {
      await tester.ensureVisible(field);
      await tester.enterText(field, text);
      await tester.pumpAndSettle();
    }

    expect(fontSize, findsNothing);
    expect(fontColor, findsNothing);
    await select(first, 1, 2);
    expect(fontSize, findsNothing);
    await select(first, 1, 6);
    expect(find.text('선택한 글자  🧑‍🔬'), findsOneWidget);
    expect(fontSize, findsOneWidget);
    expect(fontColor, findsOneWidget);
    expect(canSave(), isFalse);

    await enter(fontSize, '0.99');
    expect(canSave(), isFalse);
    await enter(fontSize, '4000');
    expect(canSave(), isTrue);
    await enter(fontSize, '4000.01');
    expect(canSave(), isFalse);
    await enter(fontColor, '#ff0000');
    expect(canSave(), isFalse);
    await enter(fontSize, '12.375');
    expect(canSave(), isFalse);
    await enter(fontSize, '12.35');
    expect(canSave(), isTrue);
    await enter(fontColor, '#FFGG00');
    expect(canSave(), isFalse);
    await enter(fontColor, '#1a2b3c');
    expect(canSave(), isTrue);

    await select(second, 0, 2);
    expect(tester.widget<TextField>(fontSize).controller!.text, isEmpty);
    expect(tester.widget<TextField>(fontColor).controller!.text, isEmpty);
    expect(canSave(), isFalse);
    await select(first, 1, 6, scrollDelta: -50);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await enter(fontSize, '12.35');
    final palette = find.byTooltip('기본 글자 색상');
    await tester.ensureVisible(palette);
    await tester.pumpAndSettle();
    await tester.tap(palette);
    await tester.pumpAndSettle();
    await tester.tap(find.text('파랑'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(fontColor).controller!.text, '1565C0');
    await enter(fontColor, '  #1a2b3c  ');
    tester.view.resetViewInsets();
    await tester.pumpAndSettle();
    const bold = ValueKey('pptx-shape-format-bold');
    await tester.ensureVisible(find.byKey(bold));
    await _choose(tester, bold, '굵게 적용');
    expect(canSave(), isTrue);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(draft?.shape, same(shape));
    expect((draft?.format?.start, draft?.format?.end), (1, 6));
    expect(draft?.format?.fontSize, 1235);
    expect(draft?.format?.fontColor, '1A2B3C');
    expect(draft?.format?.bold, isTrue);
    expect(tester.takeException(), isNull);
  });
}
