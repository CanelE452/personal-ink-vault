import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/pptx_shape_geometry.dart';
import 'package:saber/pages/office/pptx_shape_geometry_dialog.dart';

Finder _key(String suffix) =>
    find.byKey(ValueKey('pptx-shape-geometry-$suffix'));

PptxShapeGeometryShape _shape(
  int id, {
  bool locked = false,
  bool movable = true,
}) => PptxShapeGeometryShape(
  shapeId: id,
  name: '도형 $id',
  kind: 'shape',
  aspectRatioLocked: locked,
  canMove: movable,
  canResize: true,
  geometry: const PptxShapeGeometry(
    xEmu: -123457,
    yEmu: 901,
    widthEmu: 36001,
    heightEmu: 72003,
  ),
);

Future<void> _open(
  WidgetTester tester,
  Future<List<PptxShapeGeometryShape>> Function(int) load,
  void Function(PptxShapeGeometryDraft?) closed,
) async {
  final plan = PptxShapeGeometryPlan(
    sourceSha256: 'a' * 64,
    slides: const [
      PptxShapeGeometrySlide(index: 0, hidden: false),
      PptxShapeGeometrySlide(index: 1, hidden: false),
    ],
  );
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              closed(await choosePptxShapeGeometry(context, plan, load));
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

Future<void> _choose(WidgetTester tester, String picker, int value) async {
  await tester.tap(_key(picker));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(_key('$picker-$value').last);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

bool _canSave(WidgetTester tester) =>
    tester.widget<FilledButton>(_key('save')).onPressed != null;

Future<void> _edit(WidgetTester tester, String field, String value) async {
  await tester.ensureVisible(_key(field));
  await tester.enterText(_key(field), value);
  await tester.pump();
}

void main() {
  testWidgets(
    'changes one size and preserves exact other EMU on a narrow phone',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final shape = _shape(7);
      PptxShapeGeometryDraft? draft;
      await _open(tester, (_) async => [shape], (value) => draft = value);
      expect(_key('dialog'), findsOneWidget);
      await _choose(tester, 'slide', 0);
      await _choose(tester, 'shape', 7);
      expect(_canSave(tester), isFalse);
      await _edit(tester, 'width', '0');
      expect(_canSave(tester), isFalse);
      await _edit(tester, 'width', '1e2');
      expect(_canSave(tester), isFalse);
      await _edit(tester, 'width', '2,25');
      expect(_canSave(tester), isTrue);
      await tester.tap(_key('save'));
      await tester.pumpAndSettle();
      expect(draft?.slideIndex, 0);
      expect(draft?.shape, same(shape));
      expect(
        draft?.geometry,
        const PptxShapeGeometry(
          xEmu: -123457,
          yEmu: 901,
          widthEmu: 81000,
          heightEmu: 72003,
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keeps locked position and rounds the dependent extent to EMU', (
    tester,
  ) async {
    final shape = _shape(3, locked: true, movable: false);
    PptxShapeGeometryDraft? draft;
    await _open(tester, (_) async => [shape], (value) => draft = value);
    await _choose(tester, 'slide', 0);
    await _choose(tester, 'shape', 3);
    expect(tester.widget<TextFormField>(_key('x')).enabled, isFalse);
    await _edit(tester, 'width', '2');
    final dependent = tester.widget<TextFormField>(_key('height')).controller!;
    expect(dependent.text, '4.000056');
    await tester.enterText(_key('width'), '3');
    await tester.tap(_key('save'));
    await tester.pumpAndSettle();
    expect(draft?.geometry.widthEmu, 108000);
    expect(draft?.geometry.heightEmu, 216003);
    expect(draft?.geometry.xEmu, shape.geometry.xEmu);
  });

  testWidgets('ignores late slide responses and protects edits on back', (
    tester,
  ) async {
    final first = Completer<List<PptxShapeGeometryShape>>();
    final current = Completer<List<PptxShapeGeometryShape>>();
    var closed = false;
    await _open(tester, (index) => index == 0 ? first.future : current.future, (
      draft,
    ) {
      expect(draft, isNull);
      closed = true;
    });
    await _choose(tester, 'slide', 0);
    await _choose(tester, 'slide', 1);
    current.complete([_shape(8)]);
    await tester.pumpAndSettle();
    first.complete([_shape(9)]);
    await tester.pumpAndSettle();
    await _choose(tester, 'shape', 8);
    expect(find.text('도형 9'), findsNothing);
    await tester.enterText(_key('x'), '-10.125');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('계속 편집'));
    await tester.pumpAndSettle();
    expect(_canSave(tester), isTrue);
    await tester.tap(_key('cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('변경 버리기'));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });
}
