import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

const _caps = <String>[
  'canEditText',
  'canEditTextStyle',
  'canEditAppearance',
  'canInsertRows',
  'canDeleteRows',
  'canInsertColumns',
  'canDeleteColumns',
  'canMerge',
  'canSplit',
  'canDeleteTable',
];

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

Map<String, dynamic> _details(
  String text, {
  List<Map<String, dynamic>>? runs,
}) => {
  'utf16Length': text.length,
  'textSha256': sha256.convert(utf8.encode(text)).toString(),
  'truncated': false,
  'canReplace': false,
  'canStyle': false,
  'runs': runs ?? <Map<String, dynamic>>[],
  'protectedRanges': <Map<String, dynamic>>[],
};

Map<String, dynamic> _rawStyle() => _copy({
  'CharFontName': {
    'present': true,
    'nativeType': 'string',
    'attributes': 0,
    'state': {
      'enumType': 'com.sun.star.beans.PropertyState',
      'value': 'DEFAULT_VALUE',
    },
    'value': 'Authored nonempty font',
  },
  'LeftBorder': {
    'present': true,
    'nativeType': 'com.sun.star.table.BorderLine',
    'attributes': 0,
    'state': {
      'enumType': 'com.sun.star.beans.PropertyState',
      'value': 'DIRECT_VALUE',
    },
    'value': {
      'enumType': 'com.sun.star.table.BorderLine2',
      'value': {
        'structType': 'struct',
        'fields': {
          'Color': -1,
          'InnerLineWidth': 0,
          'OuterLineWidth': 17,
          'LineDistance': 0,
          'LineStyle': 0,
          'LineWidth': 17,
        },
      },
    },
  },
  'LeftBorder2': {'present': false},
  'VerticalJustify': {'present': false},
  'IsProtected': {'present': false},
  '_paragraphs': [
    {
      'rawStyle': {
        'ParaAdjust': {
          'present': true,
          'nativeType': 'short',
          'attributes': 0,
          'state': {
            'enumType': 'com.sun.star.beans.PropertyState',
            'value': 'DEFAULT_VALUE',
          },
          'value': 0,
        },
      },
      'portions': [
        {
          'text': 'same',
          'rawStyle': {
            'CharFontName': {
              'present': true,
              'nativeType': 'string',
              'attributes': 0,
              'state': {
                'enumType': 'com.sun.star.beans.PropertyState',
                'value': 'DIRECT_VALUE',
              },
              'value': 'Actual run font',
            },
          },
        },
      ],
    },
  ],
});

Map<String, dynamic> _cell(
  String id,
  int row,
  int column, {
  String? text = 'same',
}) => {
  'id': id,
  'row': row,
  'column': column,
  'rowSpan': 1,
  'columnSpan': 1,
  'covered': false,
  'anchorCellId': null,
  'text': text,
  'textDetails': text == null ? null : _details(text),
  'rawStyle': <String, dynamic>{},
};

Map<String, dynamic> _table(
  String owner,
  String id, {
  int rows = 2,
  int columns = 2,
}) => _copy({
  'id': id,
  'ownerId': owner,
  'tableSha256': sha256.convert(utf8.encode('source-bound:$id')).toString(),
  'rowCount': rows,
  'columnCount': columns,
  'totalCellCount': rows * columns,
  'truncated': false,
  'rowHeightsHmm': List<int>.filled(rows, 3500),
  'columnWidthsHmm': List<int>.filled(columns, 11000),
  'nativeBoundsHmm': {'x': 1500, 'y': 3000, 'width': 21999, 'height': 7000},
  'authoredGeometry': null,
  'rawStyle': {
    'Name': {
      'present': true,
      'nativeType': 'string',
      'attributes': 0,
      'state': {
        'enumType': 'com.sun.star.beans.PropertyState',
        'value': 'DIRECT_VALUE',
      },
      'value': 'Same table name',
    },
  },
  'capabilities': {for (final key in _caps) key: false},
  'cells': [
    for (var row = 0; row < rows; row++)
      for (var column = 0; column < columns; column++)
        _cell('$id/cell-ref-${row * columns + column + 42}', row, column),
  ],
});

Map<String, dynamic> _shape(String owner, String id) => {
  'id': id,
  'type': 'com.sun.star.drawing.TableShape',
  'text': '',
  'editableText': false,
  'ownerKind': owner.startsWith('master-') ? 'master' : 'slide',
  'ownerId': owner,
  'canEditGeometry': false,
  'canDelete': false,
  'canEditTextStyle': false,
  'x': 15,
  'y': 30,
  'width': 219.99,
  'height': 70,
};

Map<String, dynamic> _owner(
  String id,
  List<Map<String, dynamic>>? tables, {
  int? count,
  bool truncated = false,
  String? reason,
}) => {
  'id': id,
  if (id.startsWith('master-')) 'name': 'Actual master',
  'width': 280,
  'height': 157.5,
  'shapes': [
    for (final table in tables ?? <Map<String, dynamic>>[])
      _shape(id, table['id'] as String),
  ],
  'presentationTables': tables,
  'presentationTableCount': count ?? tables?.length,
  'presentationTablesTruncated': truncated,
  'presentationTablesUnknownReason': reason,
  'canAddTable': false,
};

Map<String, dynamic> _snapshot(
  String hash, {
  List<Map<String, dynamic>>? slides,
  List<Map<String, dynamic>>? masters,
}) => {
  'kind': 'presentation',
  'sourceSha256': hash,
  'paragraphs': <Map<String, dynamic>>[],
  'tables': <Map<String, dynamic>>[],
  'slides': slides ?? [_owner('slide-0', [])],
  'masters': masters ?? <Map<String, dynamic>>[],
};

List<Map> _presentationTables(Map office) => [
  for (final dynamic owner in [
    ...office['slides'] as List,
    ...office['masters'] as List,
  ])
    if (owner['presentationTables'] is List)
      for (final dynamic table in owner['presentationTables']) table as Map,
];

List<Object?> _rawPositions(Map office) => [
  for (final table in _presentationTables(office)) ...[
    table['rawStyle'],
    for (final dynamic cell in table['cells'] as List) cell['rawStyle'],
  ],
];

bool _hasBudgetUnknown(Object? value) {
  if (value is Map) {
    if (value['unknown'] == true &&
        value['error'] == 'mcp_read_budget_exhausted')
      return true;
    return value.values.any(_hasBudgetUnknown);
  }
  return value is List && value.any(_hasBudgetUnknown);
}

int _nodes(Object? value) =>
    1 +
    (value is Map
        ? value.values.fold<int>(0, (sum, item) => sum + _nodes(item))
        : value is List
        ? value.fold<int>(0, (sum, item) => sum + _nodes(item))
        : 0);

void _expectClosed(Map table) =>
    expect(table['capabilities'], {for (final key in _caps) key: false});

Map<String, dynamic> _sourceProof(String text) => {
  'canReplace': true,
  'truncated': false,
  'text': text,
  'utf16Length': text.length,
  'textSha256': sha256.convert(utf8.encode(text)).toString(),
  'segments': [
    {'startUtf16': 0, 'endUtf16': text.length, 'editable': true},
  ],
  'protectedRanges': <Map<String, dynamic>>[],
};

Map<String, dynamic> _sourceTable(String hash, {String text = 'same'}) {
  final table = _table('slide-0', 'slide-0/shape-7', rows: 1, columns: 1);
  table['tableSha256'] = null;
  table['authoredGeometry'] = {
    'sourcePart': 'ppt/slides/slide1.xml',
    'shapeId': '0009',
    'positionEmu': {'x': 0, 'y': 0},
    'extentEmu': {'width': 7200000, 'height': 2520000},
    'columnWidthsEmu': [7200000],
    'rowHeightsEmu': [2520000],
  };
  table['sourceTextPatchAuthority'] = {
    'kind': 'sourceTextPatch',
    'version': 1,
    'sourceSha256': hash,
    'sourcePart': 'ppt/slides/slide1.xml',
    'shapeId': '0009',
    'frameSha256': 'b' * 64,
  };
  table['cells'][0]['sourceTextPatch'] = _sourceProof(text);
  return table;
}

Map<String, dynamic> _sourceOperation(String hash) => {
  'op': 'presentationCellTextPatch',
  'authorityVersion': 1,
  'ownerId': 'slide-0',
  'tableId': 'slide-0/shape-7',
  'cellId': 'slide-0/shape-7/cell-ref-42',
  'expectedSourceSha256': hash,
  'sourcePart': 'ppt/slides/slide1.xml',
  'shapeId': '0009',
  'expectedSourceFrameSha256': 'b' * 64,
  'expectedTextSha256': sha256.convert(utf8.encode('same')).toString(),
  'startUtf16': 0,
  'endUtf16': 4,
  'text': '',
};

int _sourceNodes(Object? value) =>
    1 +
    (value is Map
        ? value.entries.fold<int>(
            0,
            (sum, entry) => sum + 1 + _sourceNodes(entry.value),
          )
        : value is List
        ? value.fold<int>(0, (sum, item) => sum + _sourceNodes(item))
        : 0);

Map<String, dynamic> _boundedInspectDiagnostics() {
  Map<String, dynamic> summary(String type) => {
    'type': type,
    'frames': [
      for (var index = 0; index < 16; index++)
        <String, dynamic>{
          'file': 'office_presentation_tables.py',
          'function': '읽기_검증',
          'line': index + 1,
        },
    ],
    'framesTruncated': true,
  };
  return {
    ...summary('RuntimeError'),
    'causes': [summary('ValueError'), summary('LookupError')],
    'causesTruncated': true,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late WorkspaceController controller;
  late VaultNote note;
  late OfficeEdition first;
  final context = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => false,
  );
  Uint8List original(String kind) => Uint8List.fromList(
    ZipEncoder().encode(
      Archive()
        ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
        ..addFile(
          ArchiveFile.string(
            kind == 'word' ? 'word/document.xml' : 'ppt/presentation.xml',
            '<document>immutable original</document>',
          ),
        ),
    ),
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-presentation-tables-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    note = await OfficeDocumentStore(controller.repository).importDocument(
      title: 'Actual table owners',
      fileName: 'source.pptx',
      bytes: original('presentation'),
    );
    first = await OfficeDocumentStore(controller.repository).readLatest(note);
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
  });
  Future<Map> read(Map<String, dynamic> data, {VaultNote? target}) async {
    var calls = 0;
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          calls++;
          expect(request['mode'], 'inspect');
          expect(request.containsKey('operations'), isFalse);
          expect(
            sha256
                .convert(
                  await File(request['sourcePath'] as String).readAsBytes(),
                )
                .toString(),
            data['sourceSha256'],
          );
          return {'snapshot': data};
        },
      ),
    );
    final result = await service.call('read_document', {
      'noteId': (target ?? note).id,
    }, context: context) as Map;
    expect(calls, 1);
    return result;
  }

  Future<Map> readInspectFailure(Map<String, dynamic>? diagnostics) async {
    const secret = 'private-exception-message-and-local-secret';
    var calls = 0;
    String? ownedSource;
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          calls++;
          expect(request['mode'], 'inspect');
          expect(request.containsKey('operations'), isFalse);
          ownedSource = request['sourcePath'] as String;
          throw WindowsOfficeException(
            'office_operation_failed',
            secret,
            diagnostics: diagnostics,
          );
        },
      ),
    );
    final result = await service.call('read_document', {
      'noteId': note.id,
    }, context: context) as Map;
    expect(calls, 1);
    expect(File(ownedSource!).parent.existsSync(), isFalse);
    final office = result['office'] as Map;
    expect(office['available'], false);
    expect(office['reason'], 'office_operation_failed');
    expect(jsonEncode(office), isNot(contains(secret)));
    expect(
      (await OfficeDocumentStore(controller.repository).readLatest(note))
          .revision
          .revisionId,
      first.revision.revisionId,
    );
    return office;
  }

  test(
    'read_document distinguishes unknown, observed zero and partial owners',
    () async {
      final office =
          (await read(
                _snapshot(
                  first.originalSha256,
                  slides: [
                    _owner(
                      'slide-0',
                      null,
                      count: 4,
                      reason: 'model_unavailable',
                    ),
                    _owner('slide-1', []),
                    _owner(
                      'slide-2',
                      [],
                      count: 3,
                      truncated: true,
                      reason: 'raw_state_unavailable',
                    ),
                    _owner('slide-3', null),
                  ],
                  masters: [
                    _owner(
                      'master-0',
                      null,
                      count: 2,
                      reason: 'topology_unavailable',
                    ),
                    _owner('master-1', []),
                  ],
                ),
              ))['office']
              as Map;
      final slides = office['slides'] as List,
          masters = office['masters'] as List;
      for (final dynamic owner in [...slides, ...masters]) {
        expect(owner.containsKey('presentationTables'), isTrue);
        expect(owner['canAddTable'], isFalse);
      }
      expect(slides[0]['presentationTables'], isNull);
      expect(slides[0]['presentationTableCount'], 4);
      expect(slides[0]['presentationTablesUnknownReason'], 'model_unavailable');
      expect(slides[1]['presentationTables'], isEmpty);
      expect(slides[1]['presentationTableCount'], 0);
      expect(slides[1]['presentationTablesTruncated'], isFalse);
      expect(slides[2]['presentationTables'], isEmpty);
      expect(slides[2]['presentationTableCount'], 3);
      expect(slides[2]['presentationTablesTruncated'], isTrue);
      expect(slides[3]['presentationTables'], isNull);
      expect(slides[3]['presentationTableCount'], isNull);
      expect(slides[3]['presentationTablesUnknownReason'], isNull);
      expect(masters[0]['presentationTables'], isNull);
      expect(masters[0]['presentationTableCount'], 2);
      expect(
        masters[0]['presentationTablesUnknownReason'],
        'topology_unavailable',
      );
      expect(masters[1]['presentationTables'], isEmpty);
      expect(masters[1]['presentationTableCount'], 0);
    },
  );

  test('read_document preserves actual table and cell identities, spans, raw states and geometry', () async {
    final table = _table('slide-0', 'slide-0/shape-7');
    final other = _table('slide-0', 'slide-0/shape-11');
    final master = _table('master-0', 'master-0/shape-3');
    table['cells'][0]['columnSpan'] = 2;
    table['cells'][1]['covered'] = true;
    table['cells'][1]['anchorCellId'] = table['cells'][0]['id'];
    table['cells'][0]['rawStyle'] = _rawStyle();
    table['authoredGeometry'] = _copy({
      'sourcePart': 'ppt/slides/slide1.xml',
      'shapeId': '8',
      'positionEmu': {'x': 540000, 'y': 1080000},
      'extentEmu': {'width': 7920001, 'height': 2520000},
      'columnWidthsEmu': [3960000, 3960000],
      'rowHeightsEmu': [1260000, 1260000],
    });
    final office =
        (await read(
              _snapshot(
                first.originalSha256,
                slides: [
                  _owner('slide-0', [table, other]),
                ],
                masters: [
                  _owner('master-0', [master]),
                ],
              ),
            ))['office']
            as Map;
    final tables = office['slides'][0]['presentationTables'] as List;
    expect(tables, hasLength(2));
    expect(
      [for (final dynamic item in tables) item['id']],
      ['slide-0/shape-7', 'slide-0/shape-11'],
    );
    expect(tables[0]['ownerId'], 'slide-0');
    expect(tables[0]['rawStyle'], table['rawStyle']);
    expect(tables[1]['rawStyle']['Name']['value'], 'Same table name');
    expect(tables[0]['tableSha256'], table['tableSha256']);
    expect(tables[0]['truncated'], isFalse);
    expect(
      [
        tables[0]['rowCount'],
        tables[0]['columnCount'],
        tables[0]['totalCellCount'],
      ],
      [2, 2, 4],
    );
    expect(tables[0]['rowHeightsHmm'], [3500, 3500]);
    expect(tables[0]['columnWidthsHmm'], [11000, 11000]);
    expect(tables[0]['nativeBoundsHmm'], table['nativeBoundsHmm']);
    expect(tables[0]['authoredGeometry'], table['authoredGeometry']);
    expect(tables[1]['authoredGeometry'], isNull);
    final cells = tables[0]['cells'] as List;
    expect(cells[0]['id'], 'slide-0/shape-7/cell-ref-42');
    expect(
      [
        cells[0]['row'],
        cells[0]['column'],
        cells[0]['rowSpan'],
        cells[0]['columnSpan'],
      ],
      [0, 0, 1, 2],
    );
    expect(cells[0]['covered'], isFalse);
    expect(cells[0]['anchorCellId'], isNull);
    expect(cells[1]['covered'], isTrue);
    expect(cells[1]['anchorCellId'], cells[0]['id']);
    expect(cells[0]['rawStyle'], _rawStyle());
    expect(cells[0]['truncated'], isFalse);
    expect(
      cells[0]['rawStyle']['CharFontName']['state']['value'],
      'DEFAULT_VALUE',
    );
    expect(
      cells[0]['rawStyle']['CharFontName']['value'],
      'Authored nonempty font',
    );
    expect(
      cells[0]['rawStyle']['LeftBorder']['value']['enumType'],
      'com.sun.star.table.BorderLine2',
    );
    final masterOut = office['masters'][0]['presentationTables'][0] as Map;
    expect(masterOut['id'], 'master-0/shape-3');
    expect(masterOut['ownerId'], 'master-0');
    expect(masterOut['cells'][0]['id'], 'master-0/shape-3/cell-ref-42');
    for (final item in _presentationTables(office)) _expectClosed(item);
  });

  test(
    'unknown cell text and raw state stay distinct from verified empty text',
    () async {
      final table = _table('slide-0', 'slide-0/shape-7', rows: 1);
      table['tableSha256'] = null;
      table['cells'][0]['text'] = null;
      table['cells'][0]['textDetails'] = null;
      table['cells'][0]['rawStyle'] = {
        '_text': {'unknown': true, 'error': 'cell_text_unavailable'},
      };
      table['cells'][1]['text'] = '';
      table['cells'][1]['textDetails'] = _details('');
      final office =
          (await read(
                _snapshot(
                  first.originalSha256,
                  slides: [
                    _owner('slide-0', [table], reason: 'raw_state_unavailable'),
                  ],
                ),
              ))['office']
              as Map;
      final output = office['slides'][0]['presentationTables'][0] as Map;
      final cells = output['cells'] as List;
      expect(cells[0]['text'], isNull);
      expect(cells[0]['textDetails'], isNull);
      expect(cells[0]['rawStyle'], table['cells'][0]['rawStyle']);
      expect(cells[0]['truncated'], isTrue);
      expect(cells[1]['text'], '');
      expect(cells[1]['textDetails']['utf16Length'], 0);
      expect(cells[1]['textDetails']['truncated'], isFalse);
      expect(cells[1]['truncated'], isFalse);
      expect(output['tableSha256'], isNull);
      expect(output['truncated'], isTrue);
      expect(
        office['slides'][0]['presentationTablesUnknownReason'],
        'raw_state_unavailable',
      );
      _expectClosed(output);
    },
  );

  test(
    'one shared twenty-table budget includes slide and master owners',
    () async {
      final slideTables = [
        for (var i = 0; i < 12; i++)
          _table('slide-0', 'slide-0/shape-$i', rows: 1, columns: 1),
      ];
      final masterTables = [
        for (var i = 0; i < 12; i++)
          _table('master-0', 'master-0/shape-$i', rows: 1, columns: 1),
      ];
      final office =
          (await read(
                _snapshot(
                  first.originalSha256,
                  slides: [_owner('slide-0', slideTables)],
                  masters: [_owner('master-0', masterTables)],
                ),
              ))['office']
              as Map;
      expect(_presentationTables(office), hasLength(20));
      expect(office['slides'][0]['presentationTableCount'], 12);
      expect(office['masters'][0]['presentationTableCount'], 12);
      expect(
        office['slides'][0]['presentationTablesTruncated'] == true ||
            office['masters'][0]['presentationTablesTruncated'] == true,
        isTrue,
      );
      expect(office['truncated'], isTrue);
      for (final item in _presentationTables(office)) _expectClosed(item);
    },
  );

  test('a partial source owner and a 101-cell table retain totals without inventing coordinates', () async {
    final table = _table('slide-0', 'slide-0/shape-7', rows: 1, columns: 101);
    final office =
        (await read(
              _snapshot(
                first.originalSha256,
                slides: [
                  _owner('slide-0', [table], count: 4, truncated: true),
                ],
              ),
            ))['office']
            as Map;
    final owner = office['slides'][0] as Map,
        output = owner['presentationTables'][0] as Map;
    expect(owner['presentationTableCount'], 4);
    expect(owner['presentationTablesTruncated'], isTrue);
    expect(output['totalCellCount'], 101);
    expect(output['columnCount'], 101);
    expect(output['cells'], hasLength(100));
    expect(
      (output['cells'] as List).map((dynamic cell) => cell['id']).toSet(),
      hasLength(100),
    );
    expect(output['cells'][99]['column'], 99);
    expect(output['truncated'], isTrue);
    expect(output['tableSha256'], isNull);
    expect(office['truncated'], isTrue);
    _expectClosed(output);
  });

  test('cell text prefixes do not split a surrogate pair or claim a complete table hash', () async {
    final text = 'A' * 4095 + '😀é한글';
    final table = _table('slide-0', 'slide-0/shape-7', rows: 1, columns: 1);
    table['cells'][0]['text'] = text;
    table['cells'][0]['textDetails'] = _details(
      text,
      runs: [
        {'startUtf16': 0, 'endUtf16': 4095, 'bold': false},
        {'startUtf16': 4095, 'endUtf16': 4097, 'bold': true},
      ],
    );
    final office =
        (await read(
              _snapshot(
                first.originalSha256,
                slides: [
                  _owner('slide-0', [table]),
                ],
              ),
            ))['office']
            as Map;
    final output = office['slides'][0]['presentationTables'][0] as Map,
        cell = output['cells'][0] as Map;
    expect(cell['text'], 'A' * 4095);
    expect(cell['textDetails']['visibleUtf16Length'], 4095);
    expect(cell['textDetails']['utf16Length'], text.length);
    expect(
      cell['textDetails']['textSha256'],
      sha256.convert(utf8.encode(text)).toString(),
    );
    expect(cell['textDetails']['totalRuns'], 2);
    expect(cell['textDetails']['truncated'], isTrue);
    expect(cell['truncated'], isTrue);
    expect(output['truncated'], isTrue);
    expect(output['tableSha256'], isNull);
    _expectClosed(output);
  });

  test(
    'presentation cells share the existing total text and run budgets',
    () async {
      final textTable = _table(
        'slide-0',
        'slide-0/shape-7',
        rows: 1,
        columns: 80,
      );
      for (final dynamic cell in textTable['cells']) {
        cell['text'] = 'x' * 4096;
        cell['textDetails'] = _details(cell['text'] as String);
      }
      final textOffice =
          (await read(
                _snapshot(
                  first.originalSha256,
                  slides: [
                    _owner('slide-0', [textTable]),
                  ],
                ),
              ))['office']
              as Map;
      final textCells =
          textOffice['slides'][0]['presentationTables'][0]['cells'] as List;
      expect(
        textCells.fold<int>(
          0,
          (sum, dynamic cell) => sum + (cell['text'] as String).length,
        ),
        lessThanOrEqualTo(256 * 1024),
      );
      expect(textCells.first['text'], 'x' * 4096);
      expect(
        textCells.any((dynamic cell) => cell['truncated'] == true),
        isTrue,
      );
      final runTable = _table(
        'slide-0',
        'slide-0/shape-7',
        rows: 1,
        columns: 20,
      );
      for (final dynamic cell in runTable['cells']) {
        cell['text'] = 'x' * 256;
        cell['textDetails'] = _details(
          cell['text'] as String,
          runs: [
            for (var i = 0; i < 256; i++)
              {'startUtf16': i, 'endUtf16': i + 1, 'bold': i.isEven},
          ],
        );
      }
      final runOffice =
          (await read(
                _snapshot(
                  first.originalSha256,
                  slides: [
                    _owner('slide-0', [runTable]),
                  ],
                ),
              ))['office']
              as Map;
      final runCells =
          runOffice['slides'][0]['presentationTables'][0]['cells'] as List;
      expect(
        runCells.fold<int>(
          0,
          (sum, dynamic cell) =>
              sum + (cell['textDetails']['runs'] as List).length,
        ),
        lessThanOrEqualTo(4096),
      );
      expect(runCells.first['textDetails']['runs'], hasLength(256));
      expect(
        runCells.any(
          (dynamic cell) =>
              cell['textDetails']['truncated'] == true &&
              cell['truncated'] == true,
        ),
        isTrue,
      );
      expect(runOffice['truncated'], isTrue);
    },
  );

  test('raw byte budget charges repeated values at every table and cell output position', () async {
    final shared = <String, dynamic>{'payload': 'same 😀 한글 ' * 9000};
    final a = _table('slide-0', 'slide-0/shape-7', rows: 1, columns: 1);
    final b = _table('master-0', 'master-0/shape-3', rows: 1, columns: 1);
    for (final table in [a, b]) {
      table['rawStyle'] = shared;
      table['cells'][0]['rawStyle'] = shared;
    }
    final office =
        (await read(
              _snapshot(
                first.originalSha256,
                slides: [
                  _owner('slide-0', [a]),
                ],
                masters: [
                  _owner('master-0', [b]),
                ],
              ),
            ))['office']
            as Map;
    final raw = _rawPositions(office);
    expect(raw, hasLength(4));
    expect(
      raw.where(
        (value) => value is Map && value['payload'] == shared['payload'],
      ),
      hasLength(1),
    );
    expect(raw.any(_hasBudgetUnknown), isTrue);
    expect(
      raw.fold<int>(
        0,
        (sum, value) => sum + utf8.encode(jsonEncode(value)).length,
      ),
      lessThanOrEqualTo(256 * 1024),
    );
    for (final table in _presentationTables(office)) {
      expect(table['truncated'], isTrue);
      expect(table['tableSha256'], isNull);
      _expectClosed(table);
      for (final dynamic cell in table['cells']) {
        if (_hasBudgetUnknown(cell['rawStyle']))
          expect(cell['truncated'], isTrue);
      }
    }
    expect(office['truncated'], isTrue);
  });

  test('raw node budget charges repeated primitive nodes without identity deduplication', () async {
    final table = _table('slide-0', 'slide-0/shape-7', rows: 1, columns: 1);
    table['cells'][0]['rawStyle'] = {
      'repeatedZeroNodes': List<int>.filled(40000, 0),
    };
    final office =
        (await read(
              _snapshot(
                first.originalSha256,
                slides: [
                  _owner('slide-0', [table]),
                ],
              ),
            ))['office']
            as Map;
    final output = office['slides'][0]['presentationTables'][0] as Map,
        raw = _rawPositions(office);
    expect(raw.any(_hasBudgetUnknown), isTrue);
    expect(
      raw.fold<int>(0, (sum, value) => sum + _nodes(value)),
      lessThanOrEqualTo(32768),
    );
    expect(output['cells'][0]['truncated'], isTrue);
    expect(output['truncated'], isTrue);
    expect(output['tableSha256'], isNull);
    _expectClosed(output);
  });

  test('legacy Word tables keep their global address map and source revision binding', () async {
    final word = await OfficeDocumentStore(controller.repository)
        .importDocument(
          title: 'Word',
          fileName: 'source.docx',
          bytes: original('word'),
        );
    final edition = await OfficeDocumentStore(controller.repository)
        .readLatest(word);
    final office =
        (await read({
              'kind': 'word',
              'sourceSha256': edition.originalSha256,
              'paragraphs': [],
              'slides': [],
              'masters': [],
              'tables': [
                {
                  'id': 'WordTable1',
                  'ownerId': 'body',
                  'cells': {'A1': 'same'},
                  'cellTextDetails': {'A1': _details('same')},
                },
              ],
            }, target: word))['office']
            as Map;
    expect(office['tables'], hasLength(1));
    expect(office['tables'][0]['id'], 'WordTable1');
    expect(office['tables'][0]['cells'], {'A1': 'same'});
    expect(office['tables'][0]['cellTextDetails']['A1']['utf16Length'], 4);
    expect(office['sourceRevisionId'], edition.revision.revisionId);
    expect(office['sourceSha256'], edition.originalSha256);
    expect(office['slides'], isEmpty);
  });

  test('read_document table snapshot is bound to immutable original bytes and its edition', () async {
    final office =
        (await read(
              _snapshot(
                first.originalSha256,
                slides: [
                  _owner('slide-0', [_table('slide-0', 'slide-0/shape-7')]),
                ],
              ),
            ))['office']
            as Map;
    expect(office['sourceRevisionId'], first.revision.revisionId);
    expect(office['sourceSha256'], first.originalSha256);
    expect(office['slides'][0]['presentationTables'][0]['ownerId'], 'slide-0');
    expect(
      (await OfficeDocumentStore(controller.repository).readLatest(note))
          .originalBytes,
      first.originalBytes,
    );
    final mismatched = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (_) async => {
          'snapshot': _snapshot(
            '0' * 64,
            slides: [
              _owner('slide-0', [_table('slide-0', 'slide-0/shape-7')]),
            ],
          ),
        },
      ),
    );
    await expectLater(
      mismatched.call('read_document', {'noteId': note.id}, context: context),
      throwsA(
        isA<VaultMcpException>().having(
          (e) => e.code,
          'code',
          'office_source_mismatch',
        ),
      ),
    );
  });

  for (final kind in ['fontFamily', 'protectedType', 'textHash']) {
    test(
      'PPT bounded metadata closes a cell after oversized $kind loss',
      () async {
        final table = _table('slide-0', 'slide-0/shape-7', rows: 1, columns: 1);
        final details = _details('same');
        if (kind == 'fontFamily') {
          details['runs'] = [
            <String, dynamic>{
              'startUtf16': 0,
              'endUtf16': 4,
              'fontFamily': 'f' * 100000,
            },
          ];
        } else if (kind == 'protectedType') {
          details['protectedRanges'] = [
            <String, dynamic>{
              'startUtf16': 0,
              'endUtf16': 0,
              'type': 'p' * 100000,
            },
          ];
        } else {
          details['textSha256'] = 'h' * 100000;
        }
        table['cells'][0]['textDetails'] = details;
        final office =
            (await read(
                  _snapshot(
                    first.originalSha256,
                    slides: [
                      _owner('slide-0', [table]),
                    ],
                  ),
                ))['office']
                as Map;
        final output = office['slides'][0]['presentationTables'][0] as Map;
        expect(utf8.encode(jsonEncode(office)).length, lessThan(30000));
        expect(output['cells'][0]['text'], 'same');
        expect(output['cells'][0]['truncated'], isTrue);
        expect(output['truncated'], isTrue);
        expect(output['tableSha256'], isNull);
        _expectClosed(output);
      },
    );
  }

  test(
    'raw byte measurement includes JSON escaping at every output position',
    () async {
      final shared = <String, dynamic>{
        'escaped': String.fromCharCodes([34, 92, 10]) * 22000,
      };
      final table = _table('slide-0', 'slide-0/shape-7', rows: 1, columns: 1);
      table['rawStyle'] = shared;
      table['cells'][0]['rawStyle'] = shared;
      final office =
          (await read(
                _snapshot(
                  first.originalSha256,
                  slides: [
                    _owner('slide-0', [table]),
                  ],
                ),
              ))['office']
              as Map;
      final raw = _rawPositions(office);
      expect(
        raw.where(
          (value) => value is Map && value['escaped'] == shared['escaped'],
        ),
        hasLength(1),
      );
      expect(raw.any(_hasBudgetUnknown), isTrue);
      expect(
        raw.fold<int>(
          0,
          (sum, value) => sum + utf8.encode(jsonEncode(value)).length,
        ),
        lessThanOrEqualTo(256 * 1024),
      );
    },
  );

  test('oversized PPT reasons and cell identities are omitted without creating prefix IDs', () async {
    final table = _table('slide-0', 'slide-0/shape-7', rows: 1, columns: 1);
    final hugeId = 'cell-actual-' * 10000;
    table['cells'][0]['id'] = hugeId;
    final office =
        (await read(
              _snapshot(
                first.originalSha256,
                slides: [
                  _owner('slide-0', [table], reason: 'reason-' * 20000),
                ],
              ),
            ))['office']
            as Map;
    final owner = office['slides'][0] as Map,
        output = owner['presentationTables'][0] as Map;
    expect(owner['presentationTablesUnknownReason'], isNull);
    expect(owner['presentationTablesTruncated'], isTrue);
    expect(output['cells'], isEmpty);
    expect(output['truncated'], isTrue);
    expect(output['tableSha256'], isNull);
    expect(jsonEncode(office).contains(hugeId.substring(0, 256)), isFalse);
    expect(utf8.encode(jsonEncode(office)).length, lessThan(30000));
    _expectClosed(output);
  });

  test(
    'PPT authored source metadata shares the existing UTF8 metadata budget',
    () async {
      final tables = <Map<String, dynamic>>[];
      final geometry = _copy({
        'sourcePart': '한' * 1024,
        'shapeId': 's' * 256,
        'positionEmu': {'x': 0, 'y': 0},
        'extentEmu': {'width': 1, 'height': 1},
        'columnWidthsEmu': [1],
        'rowHeightsEmu': [1],
      });
      for (var i = 0; i < 20; i++) {
        final table = _table(
          'slide-0',
          'slide-0/shape-$i',
          rows: 1,
          columns: 1,
        );
        table['authoredGeometry'] = geometry;
        tables.add(table);
      }
      final office =
          (await read(
                _snapshot(
                  first.originalSha256,
                  slides: [_owner('slide-0', tables)],
                ),
              ))['office']
              as Map;
      final output = office['slides'][0]['presentationTables'] as List;
      expect(output.first['authoredGeometry'], geometry);
      expect(
        output.any(
          (dynamic table) =>
              table['authoredGeometry'] == null &&
              table['truncated'] == true &&
              table['tableSha256'] == null,
        ),
        isTrue,
      );
      expect(office['truncated'], isTrue);
      for (final dynamic table in output) _expectClosed(table as Map);
    },
  );
  test(
    'source read proof survives null native SHA and separate RAW output loss',
    () async {
      final table = _sourceTable(first.originalSha256);
      table['rawStyle'] = {
        'escaped': String.fromCharCodes([34, 92, 10]) * 50000,
      };
      table['cells'][0]['rawStyle'] = table['rawStyle'];
      final office =
          (await read(
                _snapshot(
                  first.originalSha256,
                  slides: [
                    _owner('slide-0', [table]),
                  ],
                ),
              ))['office']
              as Map;
      final output = office['slides'][0]['presentationTables'][0] as Map;
      expect(output['tableSha256'], isNull);
      _expectClosed(output);
      expect(output['truncated'], isTrue);
      expect(
        output['sourceTextPatchAuthority'],
        table['sourceTextPatchAuthority'],
      );
      expect(
        output['cells'][0]['sourceTextPatch'],
        table['cells'][0]['sourceTextPatch'],
      );
      expect(output['cells'][0]['sourceTextPatch']['canReplace'], isTrue);
      expect(office['sourceRevisionId'], first.revision.revisionId);
    },
  );

  test('source output has a distinct exact escaped JSON byte budget', () async {
    final table = _sourceTable(first.originalSha256);
    table['columnCount'] = table['totalCellCount'] = 8;
    table['columnWidthsHmm'] = List<int>.filled(8, 1000);
    table['authoredGeometry']['columnWidthsEmu'] = List<int>.filled(8, 360000);
    table['authoredGeometry']['extentEmu']['width'] = 2880000;
    final shared = _sourceProof(String.fromCharCodes([92, 10, 34]) * 40000);
    table['cells'] = [
      for (var column = 0; column < 8; column++)
        {
          ..._cell('slide-0/shape-7/cell-$column', 0, column),
          'sourceTextPatch': shared,
        },
    ];
    final office =
        (await read(
              _snapshot(
                first.originalSha256,
                slides: [
                  _owner('slide-0', [table]),
                ],
              ),
            ))['office']
            as Map;
    final output = office['slides'][0]['presentationTables'][0] as Map;
    final proofs = [
      for (final dynamic cell in output['cells']) cell['sourceTextPatch'],
    ];
    expect(proofs.whereType<Map>(), isNotEmpty);
    expect(proofs.any((value) => value == null), isTrue);
    final values = [
      output['sourceTextPatchAuthority'],
      ...proofs.whereType<Map>(),
    ];
    expect(
      values
          .where((value) => value != null)
          .fold<int>(
            0,
            (sum, value) => sum + utf8.encode(jsonEncode(value)).length,
          ),
      lessThanOrEqualTo(1024 * 1024),
    );
    _expectClosed(output);
  });

  test(
    'source output counts repeated protected nodes at each position',
    () async {
      final table = _sourceTable(first.originalSha256);
      table['columnCount'] = table['totalCellCount'] = 2;
      table['columnWidthsHmm'] = [1000, 1000];
      table['authoredGeometry']['columnWidthsEmu'] = [3600000, 3600000];
      final shared = _sourceProof('same');
      shared['protectedRanges'] = [
        for (var i = 0; i < 4096; i++)
          {'startUtf16': 0, 'endUtf16': 0, 'reason': 'comment'},
      ];
      table['cells'] = [
        for (var column = 0; column < 2; column++)
          {
            ..._cell('slide-0/shape-7/cell-$column', 0, column),
            'sourceTextPatch': shared,
          },
      ];
      final office =
          (await read(
                _snapshot(
                  first.originalSha256,
                  slides: [
                    _owner('slide-0', [table]),
                  ],
                ),
              ))['office']
              as Map;
      final output = office['slides'][0]['presentationTables'][0] as Map;
      final proofs = [
        for (final dynamic cell in output['cells']) cell['sourceTextPatch'],
      ];
      expect(proofs.whereType<Map>(), hasLength(1));
      expect(
        proofs.whereType<Map>().fold<int>(
          _sourceNodes(output['sourceTextPatchAuthority']),
          (sum, value) => sum + _sourceNodes(value),
        ),
        lessThanOrEqualTo(32768),
      );
    },
  );

  test('closed source operation forwards every scalar guard and permits empty replacement', () async {
    final calls = <Map<String, Object?>>[];
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          calls.add(Map<String, Object?>.from(request));
          throw const WindowsOfficeException(
            'controlled_source_apply',
            'source apply reached',
          );
        },
      ),
    );
    final operation = _sourceOperation(first.originalSha256);
    await expectLater(
      service.call(
        'office_edit',
        {
          'noteId': note.id,
          'expectedRevisionId': first.revision.revisionId,
          'requestId': newId(),
          'operations': [operation],
        },
        context: VaultMcpCallContext(
          isActive: () => true,
          canWrite: () => true,
        ),
      ),
      throwsA(
        isA<VaultMcpException>().having(
          (error) => error.code,
          'code',
          'controlled_source_apply',
        ),
      ),
    );
    expect(calls, hasLength(1));
    expect(calls.single['operations'], [operation]);
    expect(calls.single['expectedSourceSha256'], first.originalSha256);
    expect(
      (await OfficeDocumentStore(controller.repository).readLatest(note))
          .revision
          .revisionId,
      first.revision.revisionId,
    );
  });

  test('source operation malformed stale and over-budget requests stop before engine', () async {
    final calls = <Map<String, Object?>>[];
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          calls.add(Map<String, Object?>.from(request));
          throw StateError('must not enter');
        },
      ),
    );
    final variants = <Map<String, dynamic>>[
      {'extra': 1},
      {'authorityVersion': 2},
      {'authorityVersion': true},
      {'expectedSourceSha256': '0' * 64},
      {'expectedSourceFrameSha256': 'B' * 64},
      {'sourcePart': '../slide.xml'},
      {'shapeId': 'shape-9'},
      {'startUtf16': true},
      {'startUtf16': 5},
      {'endUtf16': 131073},
      {'text': '\u0000'},
      {'text': String.fromCharCode(0xd800)},
    ];
    for (var i = 0; i < variants.length; i++) {
      await expectLater(
        service.call(
          'office_edit',
          {
            'noteId': note.id,
            'expectedRevisionId': first.revision.revisionId,
            'requestId': newId(),
            'operations': [
              {..._sourceOperation(first.originalSha256), ...variants[i]},
            ],
          },
          context: VaultMcpCallContext(
            isActive: () => true,
            canWrite: () => true,
          ),
        ),
        throwsA(
          isA<VaultMcpException>().having(
            (error) => error.code,
            'code',
            variants[i].containsKey('expectedSourceSha256')
                ? 'office_source_mismatch'
                : 'invalid_arguments',
          ),
        ),
      );
    }
    await expectLater(
      service.call(
        'office_edit',
        {
          'noteId': note.id,
          'expectedRevisionId': first.revision.revisionId,
          'requestId': newId(),
          'operations': List.generate(
            101,
            (_) => _sourceOperation(first.originalSha256),
          ),
        },
        context: VaultMcpCallContext(
          isActive: () => true,
          canWrite: () => true,
        ),
      ),
      throwsA(
        isA<VaultMcpException>().having(
          (error) => error.code,
          'code',
          'invalid_arguments',
        ),
      ),
    );
    expect(calls, isEmpty);
    expect(
      (await OfficeDocumentStore(controller.repository).readLatest(note))
          .revision
          .revisionId,
      first.revision.revisionId,
    );
  });

  test('source proof closes when its actual table shape is omitted from the public inventory', () async {
    for (final prefixCount in [99, 100]) {
      final table = _sourceTable(first.originalSha256);
      final owner = _owner('slide-0', [table]);
      owner['shapes'] = [
        for (var index = 0; index < prefixCount; index++)
          {
            ..._shape('slide-0', 'slide-0/plain-$index'),
            'type': 'com.sun.star.drawing.RectangleShape',
          },
        _shape('slide-0', table['id'] as String),
      ];
      final office =
          (await read(
                _snapshot(first.originalSha256, slides: [owner]),
              ))['office']
              as Map;
      final publishedOwner = office['slides'][0] as Map;
      final publishedShapes = (publishedOwner['shapes'] as List).cast<Map>();
      final publishedTable = publishedOwner['presentationTables'][0] as Map;
      final visible = publishedShapes.any(
        (shape) => shape['id'] == table['id'],
      );
      expect(visible, prefixCount == 99);
      final writable = (publishedTable['cells'] as List).cast<Map>().any(
        (cell) => (cell['sourceTextPatch'] as Map?)?['canReplace'] == true,
      );
      expect(
        writable,
        visible,
        reason:
            'A hidden target cannot retain a public source write capability',
      );
      if (!visible) expect(office['truncated'], true);
      _expectClosed(publishedTable);
    }
  });

  test('visible source target keeps authority when only unrelated trailing shapes are omitted', () async {
    final table = _sourceTable(first.originalSha256);
    final owner = _owner('slide-0', [table]);
    owner['shapes'] = [
      _shape('slide-0', table['id'] as String),
      for (var index = 0; index < 100; index++)
        {
          ..._shape('slide-0', 'slide-0/unrelated-$index'),
          'type': 'com.sun.star.drawing.RectangleShape',
        },
    ];
    final office =
        (await read(_snapshot(first.originalSha256, slides: [owner])))['office']
            as Map;
    final publishedOwner = office['slides'][0] as Map;
    final shapes = (publishedOwner['shapes'] as List).cast<Map>();
    final publishedTable = publishedOwner['presentationTables'][0] as Map;
    expect(shapes, hasLength(100));
    expect(
      shapes.where(
        (shape) =>
            shape['id'] == table['id'] &&
            shape['type'] == 'com.sun.star.drawing.TableShape',
      ),
      hasLength(1),
    );
    expect(office['truncated'], true);
    expect(
      publishedTable['sourceTextPatchAuthority'],
      table['sourceTextPatchAuthority'],
    );
    expect(publishedTable['cells'][0]['sourceTextPatch']['canReplace'], true);
    _expectClosed(publishedTable);
  });
  test('inspect failure exposes only validated bounded worker diagnostic frames and causes', () async {
    final diagnostics = _boundedInspectDiagnostics();
    expect(
      utf8.encode(jsonEncode(diagnostics)).length,
      lessThanOrEqualTo(16 * 1024),
    );
    final office = await readInspectFailure(diagnostics);
    expect(office, {
      'available': false,
      'reason': 'office_operation_failed',
      'diagnostics': diagnostics,
    });
    expect(office['diagnostics']['frames'], hasLength(16));
    expect(office['diagnostics']['causes'], hasLength(2));
    expect(office['diagnostics']['framesTruncated'], true);
    expect(office['diagnostics']['causesTruncated'], true);
    diagnostics['frames'][0]['line'] = 999;
    expect(office['diagnostics']['frames'][0]['line'], 1);
    expect(
      () => office['diagnostics']['frames'].clear(),
      throwsUnsupportedError,
    );
  });

  test('inspect failure excludes the entire malformed secret message locals or extra diagnostic payload', () async {
    const secret = 'must-never-appear-in-public-office';
    final invalid = <Map<String, dynamic>>[];
    invalid.add(_boundedInspectDiagnostics()..['message'] = secret);
    final locals = _boundedInspectDiagnostics();
    locals['frames'][0]['locals'] = {'credential': secret};
    invalid.add(locals);
    final path = _boundedInspectDiagnostics();
    path['frames'][0]['file'] = 'C:/private/$secret.py';
    invalid.add(path);
    final cause = _boundedInspectDiagnostics();
    cause['causes'][0]['message'] = secret;
    invalid.add(cause);
    final tooMany = _boundedInspectDiagnostics();
    tooMany['frames'].add({
      'file': 'worker.py',
      'function': 'extra',
      'line': 17,
    });
    invalid.add(tooMany);
    final wrongType = _boundedInspectDiagnostics();
    wrongType['framesTruncated'] = 'false';
    invalid.add(wrongType);
    for (final diagnostics in invalid) {
      final office = await readInspectFailure(diagnostics);
      expect(office, {'available': false, 'reason': 'office_operation_failed'});
      expect(office.containsKey('diagnostics'), false);
      expect(jsonEncode(office), isNot(contains(secret)));
    }
  });

  test('inspect failure without diagnostics retains the exact legacy unavailable response', () async {
    final office = await readInspectFailure(null);
    expect(office, {'available': false, 'reason': 'office_operation_failed'});
    expect(office.containsKey('diagnostics'), false);
  });
}
