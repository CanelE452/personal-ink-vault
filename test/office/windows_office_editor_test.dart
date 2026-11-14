import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

Future<WindowsOfficeSnapshot> editorFixture({
  bool presentation = false,
  bool structuredPresentation = false,
  int? duplicableSlide,
}) => WindowsOfficeEngine(
  runner: (_) async => {
    'snapshot': {
      'kind': presentation ? 'presentation' : 'word',
      'sourceSha256': 'a' * 64,
      if (structuredPresentation) 'masters': [],
      'paragraphs': presentation
          ? []
          : [
              {
                'id': 'p0',
                'text': '연구 제목',
                'fontSize': 18,
                'bold': false,
                'color': 0,
              },
            ],
      'tables': presentation
          ? []
          : [
              {
                'id': 't0',
                'cells': {'A1': '항목', 'B1': '내용'},
              },
            ],
      'slides': !presentation
          ? []
          : [
              for (var i = 0; i < 2; i++)
                {
                  'id': 'slide-$i',
                  if (i == duplicableSlide) 'canDuplicate': true,
                  'width': 254,
                  'height': 142.875,
                  'shapes': [
                    {
                      'id': 'slide-$i/shape-0',
                      'type': 'TextShape',
                      'text': '슬라이드 ${i + 1}',
                      'editableText': true,
                      'x': 10,
                      'y': 20,
                      'width': 120,
                      'height': 35,
                      'fontSize': 20,
                      'bold': false,
                      'color': 0,
                    },
                  ],
                },
            ],
    },
  },
).inspect('fixture.docx');

WindowsOfficeSnapshot authoringFixture({
  String shapeKind = 'text',
  String fillStyle = 'none',
  String lineStyle = 'none',
  bool capabilities = true,
  bool multipleShapes = false,
}) => WindowsOfficeSnapshot.fromJson({
  'kind': 'presentation',
  'sourceSha256': 'a' * 64,
  'paragraphs': [],
  'tables': [],
  'slides': [
    {
      'id': 'slide-0',
      'width': 254,
      'height': 142.875,
      'backgroundStyle': 'gradient',
      'backgroundColor': null,
      'shapes': [
        for (var i = 0; i < (multipleShapes ? 2 : 1); i++)
          {
            'id': 'slide-0/shape-$i',
            'type': shapeKind == 'text'
                ? 'com.sun.star.drawing.TextShape'
                : 'com.sun.star.drawing.CustomShape',
            'shapeKind': shapeKind,
            'text': '기존 개체 $i',
            'editableText': true,
            'x': 10 + i * 100,
            'y': 20,
            'width': 90,
            'height': 35,
            'fontSize': 18,
            'bold': false,
            'color': 0,
            'fillStyle': fillStyle,
            'fillColor': null,
            'lineStyle': lineStyle,
            'lineColor': null,
            'lineWidth': .5,
            'canEditFill': capabilities,
            'canEditLine': capabilities,
          },
      ],
    },
  ],
});

void main() {
  late WindowsOfficeSnapshot word;
  late WindowsOfficeSnapshot slides;
  setUp(() async {
    word = await editorFixture();
    slides = await editorFixture(presentation: true);
  });

  Future<GlobalKey<WindowsOfficeEditorState>> mount(
    WidgetTester tester, {
    WindowsOfficeSnapshot? snapshot,
    required Future<void> Function(List<WindowsOfficeOperation>) commit,
    required FutureOr<void> Function() back,
    ValueChanged<bool>? dirty,
    bool allowFormatting = true,
  }) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey<WindowsOfficeEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsOfficeEditor(
          key: key,
          snapshot: snapshot ?? word,
          onCommit: commit,
          onBack: back,
          onDirtyChanged: dirty,
          allowFormatting: allowFormatting,
        ),
      ),
    );
    return key;
  }

  testWidgets(
    'paragraph text style and table drafts become minimal real operations',
    (tester) async {
      List<Map<String, Object?>>? saved;
      var closed = false;
      final dirty = <bool>[];
      await mount(
        tester,
        commit: (ops) async {
          saved = [for (final op in ops) op.toJson()];
        },
        back: () {
          closed = true;
        },
        dirty: dirty.add,
      );
      await tester.enterText(
        find.byKey(const ValueKey('office-paragraph-p0')),
        '수정 1',
      );
      await tester.enterText(
        find.byKey(const ValueKey('office-paragraph-p0')),
        '수정 2',
      );
      await tester.tap(find.byKey(const ValueKey('office-bold-p0')));
      await tester.enterText(
        find.byKey(const ValueKey('office-cell-t0-A1')),
        '시험',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(
        saved,
        unorderedEquals([
          {'op': 'paragraphText', 'id': 'p0', 'text': '수정 2'},
          {'op': 'paragraphStyle', 'id': 'p0', 'bold': true},
          {'op': 'tableCellText', 'tableId': 't0', 'cell': 'A1', 'text': '시험'},
        ]),
      );
      expect(closed, true);
      expect(dirty, [true, false]);
      expect(find.text('p0'), findsNothing);
    },
  );

  testWidgets('failed commit keeps draft open and retry saves the same edits', (
    tester,
  ) async {
    var calls = 0;
    var closed = false;
    await mount(
      tester,
      commit: (_) async {
        if (++calls == 1) throw StateError('디스크 저장 실패');
      },
      back: () {
        closed = true;
      },
    );
    await tester.enterText(
      find.byKey(const ValueKey('office-paragraph-p0')),
      '지켜야 할 내용',
    );
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(closed, false);
    expect(find.textContaining('저장하지 못했습니다'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('office-paragraph-p0')))
          .controller!
          .text,
      '지켜야 할 내용',
    );
    await tester.tap(find.text('저장 재시도'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(closed, true);
  });

  testWidgets('public save shares pending commit and awaits successful close', (
    tester,
  ) async {
    final pending = Completer<void>();
    final closed = Completer<void>();
    var commits = 0;
    final key = await mount(
      tester,
      commit: (_) {
        commits++;
        return pending.future;
      },
      back: () => closed.future,
    );
    await tester.enterText(
      find.byKey(const ValueKey('office-paragraph-p0')),
      '저장 중',
    );
    final first = key.currentState!.save();
    final second = key.currentState!.save();
    expect(identical(first, second), true);
    var done = false;
    first.then((_) {
      done = true;
    });
    pending.complete();
    await tester.pump();
    expect(done, false);
    expect(commits, 1);
    closed.complete();
    await tester.pump();
    expect(done, true);
  });

  testWidgets('unchanged back closes without creating a document edition', (
    tester,
  ) async {
    var commits = 0;
    var closed = false;
    await mount(
      tester,
      commit: (_) async {
        commits++;
      },
      back: () {
        closed = true;
      },
    );
    await tester.tap(find.byTooltip('문서로 돌아가기'));
    await tester.pumpAndSettle();
    expect(commits, 0);
    expect(closed, true);
  });

  testWidgets(
    'text-only original editing hides unsupported formatting and commits only text',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        allowFormatting: false,
        commit: (ops) async {
          saved = [for (final op in ops) op.toJson()];
        },
        back: () {},
      );
      expect(find.byTooltip('굵게'), findsNothing);
      expect(find.text('글자 크기(pt)'), findsNothing);
      expect(find.byTooltip('글자 색'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('office-paragraph-p0')),
        '한글 문단 수정',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        {'op': 'paragraphText', 'id': 'p0', 'text': '한글 문단 수정'},
      ]);
    },
  );

  testWidgets('slide object geometry stays in mm and text style stays in pt', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await mount(
      tester,
      snapshot: slides,
      commit: (ops) async {
        saved = [for (final op in ops) op.toJson()];
      },
      back: () {},
    );
    await tester.tap(
      find.byKey(const ValueKey('office-shape-slide-0/shape-0')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('office-shape-text')),
      '새 발표',
    );
    await tester.enterText(find.byKey(const ValueKey('office-shape-x')), '32');
    await tester.enterText(
      find.byKey(const ValueKey('office-shape-width')),
      '150',
    );
    await tester.enterText(
      find.byKey(const ValueKey('office-shape-font')),
      '28',
    );
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(
      saved,
      unorderedEquals([
        {'op': 'shapeText', 'id': 'slide-0/shape-0', 'text': '새 발표'},
        {
          'op': 'shapeGeometry',
          'id': 'slide-0/shape-0',
          'x': 32.0,
          'y': 20.0,
          'width': 150.0,
          'height': 35.0,
        },
        {'op': 'shapeStyle', 'id': 'slide-0/shape-0', 'fontSize': 28.0},
      ]),
    );
  });

  testWidgets('slide add delete and ordering keep original object identities', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await mount(
      tester,
      snapshot: slides,
      commit: (ops) async {
        saved = [for (final op in ops) op.toJson()];
      },
      back: () {},
    );
    await tester.tap(find.byKey(const ValueKey('office-slide-slide-1')));
    await tester.pump();
    await tester.tap(find.byTooltip('슬라이드 위로'));
    await tester.pump();
    await tester.tap(find.byTooltip('슬라이드 추가'));
    await tester.pump();
    await tester.tap(find.byTooltip('슬라이드 삭제'));
    await tester.pump();
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(saved, [
      {'op': 'slideMove', 'id': 'slide-1', 'index': 0},
    ]);
  });

  for (final structured in [false, true]) {
    testWidgets('slide moves keep the selected identity ($structured)', (
      tester,
    ) async {
      final requests = <List<Map<String, Object?>>>[];
      await mount(
        tester,
        snapshot: await editorFixture(
          presentation: true,
          structuredPresentation: structured,
        ),
        commit: (ops) async {
          requests.add([for (final op in ops) op.toJson()]);
          if (requests.length == 1) throw StateError('retry slide move');
        },
        back: () {},
      );
      await tester.tap(find.byTooltip('슬라이드 아래로'));
      await tester.pump();
      await tester.tap(find.byTooltip('슬라이드 위로'));
      await tester.pump();
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.text('저장하고 닫기'));
        await tester.pumpAndSettle();
      }
      expect(requests, hasLength(2));
      expect(requests.first, [
        {'op': 'slideMove', 'id': 'slide-0', 'index': 1},
        {'op': 'slideMove', 'id': 'slide-0', 'index': 0},
      ]);
      expect(requests.last, requests.first);
    });

    testWidgets(
      'slide moves replay around additions and deletions ($structured)',
      (tester) async {
        List<Map<String, Object?>>? saved;
        await mount(
          tester,
          snapshot: await editorFixture(
            presentation: true,
            structuredPresentation: structured,
          ),
          commit: (ops) async {
            saved = [for (final op in ops) op.toJson()];
          },
          back: () {},
        );
        await tester.tap(find.byTooltip('슬라이드 추가'));
        await tester.pump();
        await tester.tap(find.byTooltip('슬라이드 아래로'));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('office-slide-slide-0')));
        await tester.pump();
        await tester.tap(find.byTooltip('슬라이드 아래로'));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('office-slide-slide-1')));
        await tester.pump();
        await tester.tap(find.byTooltip('슬라이드 삭제'));
        await tester.pump();
        await tester.tap(find.text('저장하고 닫기'));
        await tester.pumpAndSettle();
        final operations = saved!
            .where(
              (operation) => const {
                'slideAdd',
                'slideMove',
                'slideDelete',
              }.contains(operation['op']),
            )
            .toList();
        final inserted = operations.first['id'];
        expect(operations, [
          {'op': 'slideAdd', 'id': inserted, 'index': 1, 'text': ''},
          {'op': 'slideMove', 'id': inserted, 'index': 2},
          {'op': 'slideMove', 'id': 'slide-0', 'index': 1},
          {'op': 'slideDelete', 'id': 'slide-1'},
        ]);
      },
    );
  }

  testWidgets('PPTX duplication is isolated, cancellable and retryable', (
    tester,
  ) async {
    final requests = <List<Map<String, Object?>>>[];
    final dirty = <bool>[];
    var closed = 0;
    await mount(
      tester,
      snapshot: await editorFixture(
        presentation: true,
        structuredPresentation: true,
        duplicableSlide: 1,
      ),
      commit: (ops) async {
        requests.add([for (final op in ops) op.toJson()]);
        if (requests.length == 1) throw StateError('시험용 저장 실패');
      },
      back: () => closed++,
      dirty: dirty.add,
    );
    final duplicate = find.byTooltip('슬라이드 복제');
    expect(duplicate, findsNothing);
    await tester.tap(find.byKey(const ValueKey('office-slide-slide-1')));
    await tester.pumpAndSettle();
    await tester.tap(duplicate);
    await tester.pumpAndSettle();
    expect(find.text('저장하면 선택한 슬라이드 바로 뒤에 복제본이 추가됩니다.'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == '슬라이드 추가',
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('슬라이드 복제 취소'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    expect(dirty, [true, false]);

    await tester.tap(duplicate);
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(closed, 0);
    expect(find.text('저장 재시도'), findsOneWidget);
    expect(find.byTooltip('슬라이드 복제 취소'), findsOneWidget);
    await tester.tap(find.text('저장 재시도'));
    await tester.pumpAndSettle();
    expect(requests, [
      [
        {'op': 'slideDuplicate', 'id': 'slide-1'},
      ],
      [
        {'op': 'slideDuplicate', 'id': 'slide-1'},
      ],
    ]);
    expect(closed, 1);
    expect(dirty, [true, false, true, false]);
  });

  testWidgets('PPTX duplication preserves existing dirty edits', (
    tester,
  ) async {
    final requests = <List<Map<String, Object?>>>[];
    await mount(
      tester,
      snapshot: await editorFixture(presentation: true, duplicableSlide: 0),
      commit: (ops) async => requests.add([for (final op in ops) op.toJson()]),
      back: () {},
    );
    await tester.tap(
      find.byKey(const ValueKey('office-shape-slide-0/shape-0')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('office-shape-text')),
      '저장할 발표 내용',
    );
    await tester.tap(find.byTooltip('슬라이드 복제'));
    await tester.pump();
    expect(find.text('기존 편집을 저장한 뒤 슬라이드를 복제하세요.'), findsOneWidget);
    expect(find.byTooltip('슬라이드 복제 취소'), findsNothing);
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(requests, [
      [
        {'op': 'shapeText', 'id': 'slide-0/shape-0', 'text': '저장할 발표 내용'},
      ],
    ]);
  });

  Future<void> choose(WidgetTester tester, String button, String item) async {
    await tester.ensureVisible(find.byKey(ValueKey(button)));
    await tester.tap(find.byKey(ValueKey(button)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey(item)).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'PPT authoring inserts six object kinds including presets with stable batch identities',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        snapshot: authoringFixture(),
        commit: (ops) async {
          saved = [for (final op in ops) op.toJson()];
        },
        back: () {},
      );
      for (final kind in [
        'text',
        'rectangle',
        'roundedRectangle',
        'ellipse',
        'rightArrow',
        'line',
      ]) {
        await choose(tester, 'office-insert-shape', 'office-insert-$kind');
        if (kind != 'line') {
          await tester.enterText(
            find.byKey(const ValueKey('office-shape-text')),
            '새 $kind',
          );
        }
      }
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      final added = saved!.where((op) => op['op'] == 'shapeAdd').toList();
      expect(added.map((op) => op['shapeKind']), [
        'text',
        'rectangle',
        'roundedRectangle',
        'ellipse',
        'rightArrow',
        'line',
      ]);
      expect(added.map((op) => op['id']).toSet(), hasLength(6));
      expect(added.every((op) => op['slideId'] == 'slide-0'), isTrue);
      expect(added.every((op) => op['id'] != 'slide-0/shape-0'), isTrue);
      expect(added.take(5).map((op) => op['text']), [
        '새 text',
        '새 rectangle',
        '새 roundedRectangle',
        '새 ellipse',
        '새 rightArrow',
      ]);
      expect(added.last['height'], 0);
      expect(added.last['width'] as double, greaterThan(0));
    },
  );

  for (final kind in ['roundedRectangle', 'rightArrow']) {
    testWidgets('PPT preset $kind renders and edits an imported shape', (
      tester,
    ) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        snapshot: authoringFixture(shapeKind: kind),
        commit: (ops) async {
          saved = [for (final op in ops) op.toJson()];
        },
        back: () {},
      );
      final shape = find.byKey(const ValueKey('office-shape-slide-0/shape-0'));
      await tester.tap(shape);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        '이어 편집한 도형',
      );
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-x')),
        '24',
      );
      await choose(
        tester,
        'office-shape-fill-style',
        'office-shape-fill-solid',
      );
      await choose(
        tester,
        'office-shape-fill-color',
        'office-shape-fill-color-11740702',
      );
      await choose(
        tester,
        'office-shape-line-style',
        'office-shape-line-solid',
      );
      await choose(
        tester,
        'office-shape-line-color',
        'office-shape-line-color-2381735',
      );
      final preview = find.descendant(
        of: shape,
        matching: find.byType(CustomPaint),
      );
      const fill = Color(0xffb3261e);
      const outline = Color(0xff2457a7);
      if (kind == 'roundedRectangle') {
        expect(
          preview,
          paints
            ..rrect(color: fill, style: PaintingStyle.fill)
            ..rrect(color: outline, style: PaintingStyle.stroke),
        );
      } else {
        final size = tester.getSize(preview);
        final inside = [size.center(Offset.zero)];
        final outside = [Offset(size.width * .05, size.height * .05)];
        expect(
          preview,
          paints
            ..path(
              color: fill,
              style: PaintingStyle.fill,
              includes: inside,
              excludes: outside,
            )
            ..path(
              color: outline,
              style: PaintingStyle.stroke,
              includes: inside,
              excludes: outside,
            ),
        );
      }
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(
        saved,
        unorderedEquals([
          {'op': 'shapeText', 'id': 'slide-0/shape-0', 'text': '이어 편집한 도형'},
          {
            'op': 'shapeGeometry',
            'id': 'slide-0/shape-0',
            'x': 24.0,
            'y': 20.0,
            'width': 90.0,
            'height': 35.0,
          },
          {
            'op': 'shapeAppearance',
            'id': 'slide-0/shape-0',
            'fillStyle': 'solid',
            'fillColor': 0xb3261e,
            'lineStyle': 'solid',
            'lineColor': 0x2457a7,
          },
        ]),
      );
    });
  }

  testWidgets(
    'PPT authoring deletes an unsaved object without publishing an orphan operation',
    (tester) async {
      var commits = 0;
      final dirty = <bool>[];
      await mount(
        tester,
        snapshot: authoringFixture(),
        commit: (_) async {
          commits++;
        },
        back: () {},
        dirty: dirty.add,
      );
      await choose(tester, 'office-insert-shape', 'office-insert-ellipse');
      await tester.tap(find.byKey(const ValueKey('office-delete-shape')));
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(commits, 0);
      expect(dirty, [true, false]);
    },
  );

  testWidgets(
    'PPT authoring deletes an original object without renumbering later edits',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        snapshot: authoringFixture(multipleShapes: true),
        commit: (ops) async {
          saved = [for (final op in ops) op.toJson()];
        },
        back: () {},
      );
      await tester.tap(
        find.byKey(const ValueKey('office-shape-slide-0/shape-0')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('office-delete-shape')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('office-shape-slide-0/shape-1')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        '두 번째 개체 유지',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(
        saved,
        unorderedEquals([
          {'op': 'shapeDelete', 'id': 'slide-0/shape-0'},
          {'op': 'shapeText', 'id': 'slide-0/shape-1', 'text': '두 번째 개체 유지'},
        ]),
      );
    },
  );

  testWidgets('PPT authoring creates a slide before adding an object to it', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await mount(
      tester,
      snapshot: authoringFixture(),
      commit: (ops) async {
        saved = [for (final op in ops) op.toJson()];
      },
      back: () {},
    );
    await tester.tap(find.byTooltip('슬라이드 추가'));
    await tester.pump();
    await choose(tester, 'office-insert-shape', 'office-insert-rectangle');
    await tester.enterText(
      find.byKey(const ValueKey('office-shape-text')),
      '새 슬라이드의 사각형',
    );
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    final slide = saved!.singleWhere((op) => op['op'] == 'slideAdd');
    final shape = saved!.singleWhere((op) => op['op'] == 'shapeAdd');
    expect(shape['slideId'], slide['id']);
    expect(saved!.indexOf(slide), lessThan(saved!.indexOf(shape)));
    expect(shape['text'], '새 슬라이드의 사각형');
  });

  testWidgets(
    'PPT authoring deletes the implicit title before adding a stable new-slide object',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        snapshot: authoringFixture(),
        commit: (ops) async {
          saved = [for (final op in ops) op.toJson()];
        },
        back: () {},
      );
      await tester.tap(find.byTooltip('슬라이드 추가'));
      await tester.pump();
      final implicitTitle = find.byWidgetPredicate((widget) {
        final key = widget.key;
        return widget is GestureDetector &&
            key is ValueKey<String> &&
            key.value.startsWith('office-shape-') &&
            key.value.endsWith('/shape-0');
      });
      expect(implicitTitle, findsOneWidget);
      await tester.tap(implicitTitle);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('office-delete-shape')));
      await tester.pump();
      await choose(tester, 'office-insert-shape', 'office-insert-rectangle');
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        '제목 대신 새 개체',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      final slide = saved!.singleWhere((op) => op['op'] == 'slideAdd');
      final deleted = saved!.singleWhere((op) => op['op'] == 'shapeDelete');
      final added = saved!.singleWhere((op) => op['op'] == 'shapeAdd');
      expect(saved, [slide, deleted, added]);
      expect(slide['text'], '');
      expect(deleted['id'], '${slide['id']}/shape-0');
      expect(added['slideId'], slide['id']);
      expect(added['id'], isNot(deleted['id']));
      expect(added['shapeKind'], 'rectangle');
      expect(added['text'], '제목 대신 새 개체');
    },
  );

  testWidgets(
    'PPT authoring changes explicit fill outline and slide background only',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        snapshot: authoringFixture(),
        commit: (ops) async {
          saved = [for (final op in ops) op.toJson()];
        },
        back: () {},
      );
      await tester.tap(
        find.byKey(const ValueKey('office-shape-slide-0/shape-0')),
      );
      await tester.pump();
      await choose(
        tester,
        'office-shape-fill-style',
        'office-shape-fill-solid',
      );
      await choose(
        tester,
        'office-shape-fill-color',
        'office-shape-fill-color-11740702',
      );
      await choose(
        tester,
        'office-shape-line-style',
        'office-shape-line-solid',
      );
      await choose(
        tester,
        'office-shape-line-color',
        'office-shape-line-color-2381735',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('office-shape-line-width')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-line-width')),
        '.8',
      );
      await choose(
        tester,
        'office-slide-background-style',
        'office-slide-background-solid',
      );
      await choose(
        tester,
        'office-slide-background-color',
        'office-slide-background-color-16777215',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(
        saved,
        unorderedEquals([
          {
            'op': 'shapeAppearance',
            'id': 'slide-0/shape-0',
            'fillStyle': 'solid',
            'fillColor': 0xb3261e,
            'lineStyle': 'solid',
            'lineColor': 0x2457a7,
            'lineWidth': .8,
          },
          {
            'op': 'slideBackground',
            'id': 'slide-0',
            'fillStyle': 'solid',
            'fillColor': 0xffffff,
          },
        ]),
      );
    },
  );

  testWidgets(
    'PPT authoring preserves unsupported appearance while editing text',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        snapshot: authoringFixture(fillStyle: 'gradient', lineStyle: 'dash'),
        commit: (ops) async {
          saved = [for (final op in ops) op.toJson()];
        },
        back: () {},
      );
      await tester.tap(
        find.byKey(const ValueKey('office-shape-slide-0/shape-0')),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        '서식은 그대로',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        {'op': 'shapeText', 'id': 'slide-0/shape-0', 'text': '서식은 그대로'},
      ]);
    },
  );

  testWidgets(
    'PPT authoring respects object capability and text-only editor limits',
    (tester) async {
      await mount(
        tester,
        snapshot: authoringFixture(capabilities: false),
        allowFormatting: false,
        commit: (_) async {},
        back: () {},
      );
      await tester.tap(
        find.byKey(const ValueKey('office-shape-slide-0/shape-0')),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('office-insert-shape')), findsNothing);
      expect(find.byKey(const ValueKey('office-delete-shape')), findsNothing);
      expect(
        find.byKey(const ValueKey('office-shape-fill-style')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('office-shape-line-style')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('office-slide-background-style')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'PPT authoring hides appearance controls for unsupported native objects',
    (tester) async {
      await mount(
        tester,
        snapshot: authoringFixture(capabilities: false),
        commit: (_) async {},
        back: () {},
      );
      await tester.tap(
        find.byKey(const ValueKey('office-shape-slide-0/shape-0')),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('office-insert-shape')), findsOneWidget);
      expect(find.byKey(const ValueKey('office-shape-text')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('office-shape-fill-style')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('office-shape-line-style')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'PPT authoring retains temporary identity and horizontal line on narrow retry',
    (tester) async {
      final attempts = <List<Map<String, Object?>>>[];
      var closed = false;
      await mount(
        tester,
        snapshot: authoringFixture(),
        commit: (ops) async {
          attempts.add([for (final op in ops) op.toJson()]);
          if (attempts.length == 1) throw StateError('Synthetic write failure');
        },
        back: () {
          closed = true;
        },
      );
      tester.view.physicalSize = const Size(320, 960);
      await tester.pump();
      await choose(tester, 'office-insert-shape', 'office-insert-line');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      expect(find.textContaining('저장하지 못했습니다'), findsOneWidget);
      await tester.tap(find.text('저장 재시도'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(attempts, hasLength(2));
      expect(attempts[1], attempts[0]);
      final line = attempts.first.singleWhere((op) => op['op'] == 'shapeAdd');
      expect(line['shapeKind'], 'line');
      expect(line['height'], 0);
      expect(tester.takeException(), isNull);
    },
  );
}
