import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

import 'windows_presentation_structure_test.dart'
    show
        sourceStructureAuthorityWire,
        sourceStructureSnapshotWire,
        sourceStructureHash,
        sourceStructurePartHash,
        sourceStructureInventoryHash;

typedef _Preview = Future<WindowsOfficeDraftPreview> Function(
  List<WindowsOfficeOperation>,
  Map<String, WindowsOfficeImageAsset>,
);
const _candidateHash =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const _frameHash =
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _owner = 'slide-0';
const _originalShape = 'slide-0/original-shape';
Finder _key(String value) => find.byKey(ValueKey(value));

Map<String, dynamic> _base({bool authority = true, bool canAdd = true}) {
  final result = sourceStructureSnapshotWire(authority: authority);
  final slide = result['slides'][0] as Map<String, dynamic>;
  if (authority) {
    slide['sourceStructureAuthority'] = sourceStructureAuthorityWire(
      canAdd: canAdd,
    );
  }
  slide['shapes'] = [
    {
      'id': _originalShape,
      'ownerId': _owner,
      'ownerKind': 'slide',
      'type': 'com.sun.star.drawing.TextShape',
      'shapeKind': 'text',
      'text': 'Original',
      'editableText': true,
      'canEditTextStyle': true,
      'canEditGeometry': true,
      'canDelete': true,
      'x': 15,
      'y': 15,
      'width': 90,
      'height': 20,
    },
  ];
  return result;
}

Object? _ordered(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _ordered(value[key])};
  }
  if (value is List) return [for (final child in value) _ordered(child)];
  return value;
}

List<Map<String, Object?>> _json(List<WindowsOfficeOperation> operations) => [
  for (final operation in operations) operation.toJson(),
];
String _operationsDigest(List<WindowsOfficeOperation> operations) => sha256
    .convert(utf8.encode(jsonEncode(_ordered(_json(operations)))))
    .toString();

Map<String, dynamic> _candidate(List<WindowsOfficeOperation> operations) {
  final result = _base()..['sourceSha256'] = _candidateHash;
  final slide = result['slides'][0] as Map<String, dynamic>;
  slide['sourceStructureAuthority'] = {
    ...sourceStructureAuthorityWire(),
    'sourceSha256': _candidateHash,
    'partSha256': '8' * 64,
    'shapeIdInventorySha256': '9' * 64,
    'shapeIdCount': 1 + operations.length,
  };
  slide['presentationTableCount'] = operations.length;
  final tables = <Map<String, dynamic>>[];
  final shapes = slide['shapes'] as List;
  for (var index = 0; index < operations.length; index++) {
    final op = operations[index].toJson();
    final id = 'slide-0/shape-${index + 1}';
    final widths = (op['columnWidthsMm'] as List).cast<num>();
    final heights = (op['rowHeightsMm'] as List).cast<num>();
    final x = op['xMm'] as num, y = op['yMm'] as num;
    final width = widths.fold<num>(0, (a, b) => a + b);
    final height = heights.fold<num>(0, (a, b) => a + b);
    shapes.add({
      'id': id,
      'ownerId': _owner,
      'ownerKind': 'slide',
      'type': 'com.sun.star.drawing.TableShape',
      'text': '',
      'editableText': false,
      'canEditTextStyle': false,
      'canEditGeometry': false,
      'canDelete': false,
      'x': x,
      'y': y,
      'width': width - .01,
      'height': height,
    });
    tables.add({
      'id': id,
      'ownerId': _owner,
      'tableSha256': null,
      'rowCount': heights.length,
      'columnCount': widths.length,
      'totalCellCount': heights.length * widths.length,
      'truncated': false,
      'rowHeightsHmm': [for (final value in heights) (value * 100).round()],
      'columnWidthsHmm': [for (final value in widths) (value * 100).round()],
      'nativeBoundsHmm': {
        'x': (x * 100).round(),
        'y': (y * 100).round(),
        'width': (width * 100).round() - 1,
        'height': (height * 100).round(),
      },
      'authoredGeometry': {
        'sourcePart': 'ppt/slides/slide1.xml',
        'shapeId': '${index + 2}',
        'positionEmu': {'x': (x * 36000).round(), 'y': (y * 36000).round()},
        'extentEmu': {
          'width': (width * 36000).round(),
          'height': (height * 36000).round(),
        },
        'columnWidthsEmu': [
          for (final value in widths) (value * 36000).round(),
        ],
        'rowHeightsEmu': [for (final value in heights) (value * 36000).round()],
      },
      'sourceTextPatchAuthority': {
        'kind': 'sourceTextPatch',
        'version': 1,
        'sourceSha256': _candidateHash,
        'sourcePart': 'ppt/slides/slide1.xml',
        'shapeId': '${index + 2}',
        'frameSha256': _frameHash,
      },
      'rawStyle': <String, dynamic>{},
      'capabilities': <String, dynamic>{},
      'cells': [
        for (var row = 0; row < heights.length; row++)
          for (var column = 0; column < widths.length; column++)
            {
              'id': '$id/cell-${row * widths.length + column}',
              'row': row,
              'column': column,
              'rowSpan': 1,
              'columnSpan': 1,
              'covered': false,
              'anchorCellId': null,
              'text': '',
              'textDetails': null,
              'rawStyle': <String, dynamic>{},
              'sourceTextPatch': {
                'canReplace': true,
                'truncated': false,
                'text': '',
                'utf16Length': 0,
                'textSha256': sha256.convert(const <int>[]).toString(),
                'segments': [
                  {'startUtf16': 0, 'endUtf16': 0, 'editable': true},
                ],
                'protectedRanges': <Map<String, dynamic>>[],
              },
            },
      ],
    });
  }
  slide['presentationTables'] = tables;
  return result;
}

WindowsOfficeDraftPreview _preview(
  List<WindowsOfficeOperation> operations, {
  void Function(Map<String, dynamic>)? mutate,
  bool legacy = false,
}) {
  final receipt = <String, dynamic>{
    'kind': 'presentationSourceStructure',
    'version': 1,
    'baseSourceSha256': sourceStructureHash,
    'candidateSourceSha256': _candidateHash,
    'operationsSha256': _operationsDigest(operations),
    'additions': [
      for (var index = 0; index < operations.length; index++)
        <String, dynamic>{
          'alias': operations[index].toJson()['id'],
          'ownerId': _owner,
          'tableId': 'slide-0/shape-${index + 1}',
          'sourcePart': 'ppt/slides/slide1.xml',
          'shapeId': '${index + 2}',
          'frameSha256': _frameHash,
        },
    ],
    'snapshot': _candidate(operations),
  };
  mutate?.call(receipt);
  final typed = WindowsOfficeStructuralPreview.fromJson(receipt);
  return WindowsOfficeDraftPreview(
    snapshot: typed.snapshot,
    pdfPath: 'C:/private-preview/structure.pdf',
    signature: _operationsDigest(operations),
    baseSourceSha256: sourceStructureHash,
    structuralPreview: legacy ? null : typed,
  );
}

Future<GlobalKey<WindowsOfficeEditorState>> _mount(
  WidgetTester tester, {
  WindowsOfficeSnapshot? snapshot,
  _Preview? preview,
  Future<void> Function(List<WindowsOfficeOperation>)? commit,
  bool allowFormatting = true,
  double width = 1400,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<WindowsOfficeEditorState>();
  await tester.pumpWidget(
    MaterialApp(
      home: WindowsOfficeEditor(
        key: key,
        snapshot: snapshot ?? WindowsOfficeSnapshot.fromJson(_base()),
        onPreview: preview ?? (operations, _) async => _preview(operations),
        onCommit: commit ?? (_) async {},
        onBack: () {},
        allowFormatting: allowFormatting,
      ),
    ),
  );
  return key;
}

Future<void> _open(WidgetTester tester) async {
  final button = _key('office-ppt-add-table');
  expect(button, findsOneWidget);
  await tester.ensureVisible(button);
  expect(tester.widget<ButtonStyleButton>(button).onPressed, isNotNull);
  await tester.tap(button);
  await tester.pump();
  final rows = _key('office-ppt-table-rows');
  expect(rows, findsOneWidget);
  final route = ModalRoute.of(tester.element(rows))!;
  for (
    var frame = 0;
    frame < 4 && route.animation?.isCompleted != true;
    frame++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(route.isCurrent, isTrue);
  expect(route.animation?.isCompleted, isTrue);
  expect(_key('office-ppt-add-table-confirm'), findsOneWidget);
  expect(find.text('표 추가'), findsWidgets);
}

Future<void> _create(WidgetTester tester) async {
  await _open(tester);
  final rows = _key('office-ppt-table-rows');
  final route = ModalRoute.of(tester.element(rows))!;
  await tester.ensureVisible(_key('office-ppt-add-table-confirm'));
  await tester.tap(_key('office-ppt-add-table-confirm'));
  await tester.pump();
  for (var frame = 0; frame < 5 && rows.evaluate().isNotEmpty; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(rows, findsNothing);
  expect(route.isCurrent, isFalse);
  expect(route.animation == null || route.animation!.isDismissed, isTrue);
  await tester.pump();
}

Future<void> _press(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pump();
}

void _expectSourceOperation(Map<String, Object?> operation) {
  expect(operation.keys, hasLength(12));
  expect(operation['op'], 'presentationSourceTableAdd');
  expect(operation['authorityVersion'], 1);
  expect(operation['id'], matches(RegExp(r'^new-table-[A-Za-z0-9_-]{1,64}$')));
  expect(operation['ownerId'], _owner);
  expect(operation['expectedSourceSha256'], sourceStructureHash);
  expect(operation['sourcePart'], 'ppt/slides/slide1.xml');
  expect(operation['expectedSourcePartSha256'], sourceStructurePartHash);
  expect(
    operation['expectedShapeIdInventorySha256'],
    sourceStructureInventoryHash,
  );
}

void main() {
  testWidgets(
    'table-free source owner creates guarded default 2 by 3 table and saves the same journal',
    (tester) async {
      final previews = <List<Map<String, Object?>>>[];
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        preview: (operations, assets) async {
          expect(assets, isEmpty);
          previews.add(_json(operations));
          return _preview(operations);
        },
        commit: (operations) async => saved = _json(operations),
      );
      await _create(tester);
      expect(previews, hasLength(1));
      final operation = previews.single.single;
      _expectSourceOperation(operation);
      expect(operation['rowHeightsMm'], [12, 12]);
      expect(operation['columnWidthsMm'], [30, 30, 30]);
      expect(operation['xMm'], 15);
      expect(operation['yMm'], 120);
      expect(_key('office-ppt-table-slide-0/shape-1'), findsOneWidget);
      expect(find.text('표를 저장하면 셀을 편집할 수 있습니다'), findsWidgets);
      expect(saved, isNull);
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, previews.single);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('add dialog uses chosen counts mm dimensions and position', (
    tester,
  ) async {
    List<Map<String, Object?>>? actual;
    await _mount(
      tester,
      preview: (operations, _) async {
        actual = _json(operations);
        return _preview(operations);
      },
    );
    await _open(tester);
    for (final entry in {
      'rows': '3',
      'columns': '2',
      'row-height': '10.25',
      'column-width': '24.5',
      'x': '20.75',
      'y': '80',
    }.entries) {
      final field = _key('office-ppt-table-${entry.key}');
      await tester.ensureVisible(field);
      await tester.enterText(field, entry.value);
    }
    await _press(tester, 'office-ppt-add-table-confirm');
    await tester.pump();
    _expectSourceOperation(actual!.single);
    expect(actual!.single['columnWidthsMm'], [24.5, 24.5]);
    expect(actual!.single['rowHeightsMm'], [10.25, 10.25, 10.25]);
    expect(actual!.single['xMm'], 20.75);
    expect(actual!.single['yMm'], 80);
  });

  for (final settings in [
    (authority: false, canAdd: true, allowFormatting: true),
    (authority: true, canAdd: false, allowFormatting: true),
    (authority: true, canAdd: true, allowFormatting: false),
  ]) {
    testWidgets(
      'creation is closed for permission $settings even if legacy flag is true',
      (tester) async {
        final wire = _base(
          authority: settings.authority,
          canAdd: settings.canAdd,
        );
        wire['slides'][0]['canAddTable'] = true;
        var calls = 0;
        await _mount(
          tester,
          snapshot: WindowsOfficeSnapshot.fromJson(wire),
          allowFormatting: settings.allowFormatting,
          preview: (operations, _) async {
            calls++;
            return _preview(operations);
          },
        );
        final button = _key('office-ppt-add-table');
        if (button.evaluate().isNotEmpty) {
          expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
        }
        expect(calls, 0);
      },
    );
  }

  testWidgets(
    'multiple adds retain original source guards and undo redo do not reuse aliases',
    (tester) async {
      final previews = <List<Map<String, Object?>>>[];
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        preview: (operations, _) async {
          previews.add(_json(operations));
          return _preview(operations);
        },
        commit: (operations) async => saved = _json(operations),
      );
      await _create(tester);
      await _create(tester);
      expect(previews.map((ops) => ops.length), [1, 2]);
      for (final operation in previews.last) {
        _expectSourceOperation(operation);
      }
      final abandonedId = previews.last.last['id'];
      await _press(tester, 'office-ppt-undo');
      expect(_key('office-ppt-table-slide-0/shape-2'), findsNothing);
      await _press(tester, 'office-ppt-redo');
      expect(_key('office-ppt-table-slide-0/shape-2'), findsOneWidget);
      await _press(tester, 'office-ppt-undo');
      await _create(tester);
      expect(previews.last, hasLength(2));
      expect(previews.last.last['id'], isNot(abandonedId));
      expect(previews.last.first, previews.first.single);
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, previews.last);
    },
  );

  testWidgets(
    'structural preview keeps cells and unrelated shape edits closed until save reload',
    (tester) async {
      await _mount(tester);
      await _create(tester);
      await _press(tester, 'office-ppt-table-slide-0/shape-1');
      await _press(tester, 'office-ppt-cell-slide-0/shape-1/cell-0');
      expect(
        tester.widget<TextField>(_key('office-ppt-cell-text')).readOnly,
        isTrue,
      );
      final insert = _key('office-insert-shape');
      expect(tester.widget<PopupMenuButton<String>>(insert).enabled, isFalse);
      await _press(tester, 'office-shape-$_originalShape');
      expect(
        tester.widget<TextField>(_key('office-shape-text')).readOnly,
        isTrue,
      );
    },
  );

  testWidgets('unrelated dirty shape journal prevents adding a source table', (
    tester,
  ) async {
    var previews = 0;
    await _mount(
      tester,
      preview: (operations, _) async {
        previews++;
        return _preview(operations);
      },
    );
    await _press(tester, 'office-shape-$_originalShape');
    await tester.enterText(_key('office-shape-text'), 'Changed');
    await tester.pump();
    expect(
      tester.widget<ButtonStyleButton>(_key('office-ppt-add-table')).onPressed,
      isNull,
    );
    expect(previews, 0);
  });

  for (final corruption in [
    'base',
    'digest',
    'alias',
    'geometry',
    'foreign-shape',
    'legacy',
  ]) {
    testWidgets(
      'fabricated $corruption preview cannot replace the structure or clear the journal',
      (tester) async {
        var calls = 0, writes = 0;
        List<Map<String, Object?>>? requested;
        final key = await _mount(
          tester,
          preview: (operations, _) async {
            calls++;
            requested ??= _json(operations);
            expect(_json(operations), requested);
            if (calls > 1) return _preview(operations);
            return _preview(
              operations,
              legacy: corruption == 'legacy',
              mutate: (receipt) {
                if (corruption == 'base')
                  receipt['baseSourceSha256'] = '7' * 64;
                if (corruption == 'digest')
                  receipt['operationsSha256'] = '7' * 64;
                if (corruption == 'alias')
                  receipt['additions'][0]['alias'] = 'new-table-foreign';
                if (corruption == 'geometry')
                  receipt['snapshot']['slides'][0]['presentationTables'][0]['authoredGeometry']['positionEmu']['x'] +=
                      36000;
                if (corruption == 'foreign-shape')
                  receipt['snapshot']['slides'][0]['shapes'][0]['x'] = 16;
              },
            );
          },
          commit: (_) async {
            writes++;
          },
        );
        await _create(tester);
        expect(_key('office-ppt-table-slide-0/shape-1'), findsNothing);
        expect(_key('office-ppt-retry-preview'), findsOneWidget);
        await expectLater(key.currentState!.save(), throwsFormatException);
        await tester.pump();
        expect(writes, 0);
        await _press(tester, 'office-ppt-retry-preview');
        await tester.pump();
        expect(calls, 2);
        expect(_key('office-ppt-table-slide-0/shape-1'), findsOneWidget);
        await tester.tap(find.text('저장하고 닫기'));
        await tester.pump();
        expect(writes, 1);
      },
    );
  }

  testWidgets(
    'failed source preview retains the pending operation for retry without writes',
    (tester) async {
      var calls = 0, writes = 0;
      List<Map<String, Object?>>? first;
      await _mount(
        tester,
        preview: (operations, _) async {
          calls++;
          first ??= _json(operations);
          expect(_json(operations), first);
          if (calls == 1) throw StateError('preview failed');
          return _preview(operations);
        },
        commit: (_) async {
          writes++;
        },
      );
      await _create(tester);
      expect(_key('office-ppt-retry-preview'), findsOneWidget);
      expect(writes, 0);
      await _press(tester, 'office-ppt-retry-preview');
      await tester.pump();
      expect(_key('office-ppt-table-slide-0/shape-1'), findsOneWidget);
      expect(writes, 0);
    },
  );

  testWidgets(
    'late structure preview cannot restore a replaced source session',
    (tester) async {
      final pending = Completer<WindowsOfficeDraftPreview>();
      late List<WindowsOfficeOperation> requested;
      final key = await _mount(
        tester,
        preview: (operations, _) {
          requested = operations;
          return pending.future;
        },
      );
      await _create(tester);
      final replacement = _base(authority: false);
      replacement['sourceSha256'] = '6' * 64;
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsOfficeEditor(
            key: key,
            snapshot: WindowsOfficeSnapshot.fromJson(replacement),
            onCommit: (_) async {},
            onBack: () {},
          ),
        ),
      );
      pending.complete(_preview(requested));
      await tester.pump();
      await tester.pump();
      expect(_key('office-ppt-table-slide-0/shape-1'), findsNothing);
      expect(find.text('표를 저장하면 셀을 편집할 수 있습니다'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final values in [
    {'rows': '11', 'columns': '10'},
    {'column-width': '0'},
    {'row-height': '12.001'},
    {'x': 'NaN'},
    {'x': '1000.01'},
  ]) {
    testWidgets(
      'invalid table form $values stays open and never calls preview',
      (tester) async {
        var calls = 0;
        await _mount(
          tester,
          preview: (operations, _) async {
            calls++;
            return _preview(operations);
          },
        );
        await _open(tester);
        for (final entry in values.entries) {
          await tester.enterText(
            _key('office-ppt-table-${entry.key}'),
            entry.value,
          );
        }
        await _press(tester, 'office-ppt-add-table-confirm');
        expect(_key('office-ppt-table-rows'), findsOneWidget);
        expect(calls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    '320px dialog scrolls above keyboard and composing input cannot submit; back closes only dialog',
    (tester) async {
      var calls = 0;
      await _mount(
        tester,
        width: 320,
        preview: (operations, _) async {
          calls++;
          return _preview(operations);
        },
      );
      await _open(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      addTearDown(tester.view.resetViewInsets);
      final rows = _key('office-ppt-table-rows');
      await tester.ensureVisible(rows);
      await tester.tap(rows);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '2',
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange(start: 0, end: 1),
        ),
      );
      await tester.pump();
      await tester.ensureVisible(_key('office-ppt-add-table-confirm'));
      expect(
        tester
            .widget<ButtonStyleButton>(_key('office-ppt-add-table-confirm'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(rows, findsNothing);
      expect(_key('office-ppt-add-table'), findsOneWidget);
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
