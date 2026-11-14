import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

const _tableId = 'slide-0/shape-7';
const _anchorId = '$_tableId/cell-42';
const _coveredId = '$_tableId/cell-8';
const _capabilityKeys = <String>[
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

Map<String, dynamic> _textDetails(String text) => {
  'utf16Length': text.length,
  'textSha256': sha256.convert(utf8.encode(text)).toString(),
  'truncated': false,
  'canReplace': false,
  'canStyle': false,
  'runs': [
    {'startUtf16': 0, 'endUtf16': 1, 'bold': false, 'fontFamily': 'Original'},
    {
      'startUtf16': 1,
      'endUtf16': 3,
      'bold': true,
      'italic': true,
      'underline': false,
      'fontSize': 24,
      'color': 0x123456,
      'fontFamily': 'Emoji font',
    },
  ],
  'protectedRanges': [
    {'startUtf16': 5, 'endUtf16': 5, 'type': 'TextField'},
  ],
};

Map<String, dynamic> _rawStyle() => {
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
  'UnobservedProperty': {
    'present': true,
    'nativeType': 'any',
    'attributes': 16,
    'unknown': true,
    'error': {'type': 'RuntimeException', 'message': 'not observed'},
  },
};

Map<String, dynamic> _cell(
  String id,
  int row,
  int column, {
  int rowSpan = 1,
  int columnSpan = 1,
  bool covered = false,
  String? anchorCellId,
  String? text = '',
}) => {
  'id': id,
  'row': row,
  'column': column,
  'rowSpan': rowSpan,
  'columnSpan': columnSpan,
  'covered': covered,
  'anchorCellId': anchorCellId,
  'text': text,
  'textDetails': null,
  'rawStyle': <String, dynamic>{},
};

Map<String, dynamic> _authoredGeometry() => {
  'sourcePart': 'ppt/slides/slide1.xml',
  'shapeId': '8',
  'positionEmu': {'x': 540000, 'y': 1080000},
  'extentEmu': {'width': 7920001, 'height': 2520000},
  'columnWidthsEmu': [3960000, 3960000],
  'rowHeightsEmu': [1260000, 1260000],
};

Map<String, dynamic> _table() {
  const text = 'A😀é\n  ';
  return {
    'id': _tableId,
    'ownerId': 'slide-0',
    'tableSha256': 'b' * 64,
    'rowCount': 2,
    'columnCount': 2,
    'totalCellCount': 4,
    'truncated': false,
    'rowHeightsHmm': [3500, 3500],
    'columnWidthsHmm': [11000, 11000],
    'nativeBoundsHmm': {'x': 1500, 'y': 3000, 'width': 21999, 'height': 7000},
    'authoredGeometry': null,
    'rawStyle': {
      'UseFirstRowStyle': {
        'present': true,
        'nativeType': 'boolean',
        'attributes': 0,
        'state': {
          'enumType': 'com.sun.star.beans.PropertyState',
          'value': 'DIRECT_VALUE',
        },
        'value': true,
      },
    },
    'capabilities': {for (final key in _capabilityKeys) key: false},
    'cells': [
      {
        ..._cell(_anchorId, 0, 0, columnSpan: 2, text: text),
        'textDetails': _textDetails(text),
        'rawStyle': _rawStyle(),
      },
      _cell(_coveredId, 0, 1, covered: true, anchorCellId: _anchorId),
      _cell('$_tableId/cell-19', 1, 0, text: 'same'),
      _cell('$_tableId/cell-2', 1, 1, text: 'same'),
    ],
  };
}

Map<String, dynamic> _slide() => {
  'id': 'slide-0',
  'width': 280,
  'height': 157.5,
  'shapes': [
    {
      'id': _tableId,
      'type': 'com.sun.star.drawing.TableShape',
      'text': '',
      'editableText': false,
      'canEditTextStyle': false,
      'canEditGeometry': false,
      'canDelete': false,
      'x': 15,
      'y': 30,
      'width': 219.99,
      'height': 70,
    },
  ],
};

Map<String, dynamic> _snapshot(Map<String, dynamic> slide) => {
  'kind': 'presentation',
  'sourceSha256': 'a' * 64,
  'paragraphs': [],
  'tables': [],
  'slides': [slide],
};

Map<String, dynamic> _catalogSlide(Map<String, dynamic> table) => {
  ..._slide(),
  'presentationTables': [table],
  'presentationTableCount': 1,
  'presentationTablesTruncated': false,
  'canAddTable': false,
};

dynamic _readSlide(Map<String, dynamic> slide) =>
    WindowsOfficeSnapshot.fromJson(_snapshot(slide)).slides.single;

dynamic _readTable(Map<String, dynamic> table) =>
    _readSlide(_catalogSlide(table)).presentationTables.single;

List<bool> _capabilities(dynamic capabilities) => [
  capabilities.canEditText as bool,
  capabilities.canEditTextStyle as bool,
  capabilities.canEditAppearance as bool,
  capabilities.canInsertRows as bool,
  capabilities.canDeleteRows as bool,
  capabilities.canInsertColumns as bool,
  capabilities.canDeleteColumns as bool,
  capabilities.canMerge as bool,
  capabilities.canSplit as bool,
  capabilities.canDeleteTable as bool,
];

void main() {
  test('Word tables retain their existing cell map and text details', () {
    final snapshot = WindowsOfficeSnapshot.fromJson({
      'kind': 'word',
      'sourceSha256': 'a' * 64,
      'paragraphs': [],
      'tables': [
        {
          'id': 'WordTable1',
          'ownerId': 'body',
          'cells': {'A1': 'word cell'},
          'cellTextDetails': {'A1': _textDetails('word cell')},
        },
      ],
      'slides': [],
    });
    expect(snapshot.tables.single.id, 'WordTable1');
    expect(snapshot.tables.single.ownerId, 'body');
    expect(snapshot.tables.single.cells, {'A1': 'word cell'});
    expect(snapshot.tables.single.cellTextDetails['A1']!.utf16Length, 9);
  });

  test(
    'missing and null presentation catalogs remain unknown and cannot add',
    () {
      for (final wire in [
        _slide(),
        {..._slide(), 'presentationTables': null},
      ]) {
        final dynamic slide = _readSlide(wire);
        expect(slide.presentationTables, isNull);
        expect(slide.presentationTableCount, isNull);
        expect(slide.presentationTablesTruncated, isFalse);
        expect(slide.canAddTable, isFalse);
      }
    },
  );

  test(
    'an observed empty catalog is distinct from unknown and defaults closed',
    () {
      final dynamic slide = _readSlide({
        ..._slide(),
        'presentationTables': [],
        'presentationTableCount': 0,
      });
      expect(slide.presentationTables, isEmpty);
      expect(slide.presentationTableCount, 0);
      expect(slide.presentationTablesTruncated, isFalse);
      expect(slide.canAddTable, isFalse);
      expect(() => slide.presentationTables.clear(), throwsUnsupportedError);
    },
  );

  test(
    'actual shape and opaque cell identities survive duplicate cell text',
    () {
      final dynamic slide = _readSlide(_catalogSlide(_table()));
      final dynamic table = slide.presentationTables.single;
      expect(table.id, slide.shapes.single.id);
      expect(table.ownerId, 'slide-0');
      expect(table.tableSha256, 'b' * 64);
      expect(
        [table.rowCount, table.columnCount, table.totalCellCount],
        [2, 2, 4],
      );
      expect(table.rowHeightsHmm, [3500, 3500]);
      expect(table.columnWidthsHmm, [11000, 11000]);
      expect(table.truncated, isFalse);
      expect([table.cells[2].text, table.cells[3].text], ['same', 'same']);
      expect(
        [table.cells[2].id, table.cells[3].id],
        ['$_tableId/cell-19', '$_tableId/cell-2'],
      );
      expect(_capabilities(table.capabilities), everyElement(isFalse));
    },
  );

  test(
    'merged anchor and covered cell retain independent spans and raw text',
    () {
      final dynamic table = _readTable(_table());
      final dynamic anchor = table.cells[0];
      final dynamic covered = table.cells[1];
      expect(
        [anchor.row, anchor.column, anchor.rowSpan, anchor.columnSpan],
        [0, 0, 1, 2],
      );
      expect(anchor.covered, isFalse);
      expect(anchor.anchorCellId, isNull);
      expect(
        [covered.row, covered.column, covered.rowSpan, covered.columnSpan],
        [0, 1, 1, 1],
      );
      expect(covered.covered, isTrue);
      expect(covered.anchorCellId, _anchorId);
      expect(anchor.text, 'A😀é\n  ');
      expect(anchor.textDetails.utf16Length, 'A😀é\n  '.length);
      expect(
        anchor.textDetails.textSha256,
        sha256.convert(utf8.encode(anchor.text as String)).toString(),
      );
      expect(anchor.textDetails.runs[1].endUtf16, 3);
      expect(anchor.textDetails.runs[1].fontFamily, 'Emoji font');
      expect(anchor.textDetails.protectedRanges.single.startUtf16, 5);
      expect(anchor.textDetails.protectedRanges.single.endUtf16, 5);
    },
  );

  test(
    'unknown cell text stays null while an observed empty string stays empty',
    () {
      final wire = _table();
      wire['cells'][2]['text'] = null;
      final dynamic table = _readTable(wire);
      expect(table.cells[1].text, '');
      expect(table.cells[1].textDetails, isNull);
      expect(table.cells[2].text, isNull);
      expect(table.cells[2].textDetails, isNull);
    },
  );

  test(
    'raw property presence, declared type, actual value and state are lossless',
    () {
      final wire = _table();
      final raw = wire['cells'][0]['rawStyle'];
      final dynamic table = _readTable(wire);
      final dynamic style = table.cells[0].rawStyle;
      expect(style, raw);
      expect(style['CharFontName']['state']['value'], 'DEFAULT_VALUE');
      expect(style['CharFontName']['value'], 'Authored nonempty font');
      expect(
        style['LeftBorder']['nativeType'],
        'com.sun.star.table.BorderLine',
      );
      expect(
        style['LeftBorder']['value']['enumType'],
        'com.sun.star.table.BorderLine2',
      );
      expect(style['LeftBorder']['value']['value']['fields']['LineWidth'], 17);
      expect(style['LeftBorder2'], {'present': false});
      expect(style['VerticalJustify'], {'present': false});
      expect(style['IsProtected'], {'present': false});
      expect(style['UnobservedProperty']['unknown'], isTrue);
      expect(style['UnobservedProperty']['error']['type'], 'RuntimeException');
      expect(table.rawStyle['UseFirstRowStyle']['value'], isTrue);
    },
  );

  test(
    'catalog collections and nested raw state are detached and immutable',
    () {
      final wire = _table();
      final dynamic table = _readTable(wire);
      wire['rowHeightsHmm'][0] = 1;
      wire['cells'][0]['rawStyle']['CharFontName']['state']['value'] =
          'DIRECT_VALUE';
      wire['rawStyle']['UseFirstRowStyle']['value'] = false;
      expect(table.rowHeightsHmm, [3500, 3500]);
      expect(
        table.cells[0].rawStyle['CharFontName']['state']['value'],
        'DEFAULT_VALUE',
      );
      expect(table.rawStyle['UseFirstRowStyle']['value'], isTrue);
      expect(() => table.cells.removeAt(0), throwsUnsupportedError);
      expect(() => table.rowHeightsHmm[0] = 1, throwsUnsupportedError);
      expect(() => table.columnWidthsHmm.add(1), throwsUnsupportedError);
      expect(() => table.rawStyle['new'] = null, throwsUnsupportedError);
      expect(
        () => table.cells[0].rawStyle['CharFontName']['state']['value'] =
            'DIRECT_VALUE',
        throwsUnsupportedError,
      );
    },
  );

  test('native bounds never manufacture unknown authored source geometry', () {
    final dynamic table = _readTable(_table());
    expect(table.authoredGeometry, isNull);
    expect(table.nativeBoundsHmm, {
      'x': 1500,
      'y': 3000,
      'width': 21999,
      'height': 7000,
    });
    expect(
      table.columnWidthsHmm.fold<int>(
        0,
        (int sum, dynamic width) => sum + (width as int),
      ),
      22000,
    );
    expect(_capabilities(table.capabilities), everyElement(isFalse));
  });

  test(
    'authored EMU integers and grid mismatch stay separate from native bounds',
    () {
      final wire = _table()..['authoredGeometry'] = _authoredGeometry();
      final dynamic table = _readTable(wire);
      expect(table.authoredGeometry, _authoredGeometry());
      expect(table.authoredGeometry['extentEmu']['width'], 7920001);
      expect(table.authoredGeometry['columnWidthsEmu'], [3960000, 3960000]);
      expect(table.nativeBoundsHmm['width'], 21999);
      expect(_capabilities(table.capabilities), everyElement(isFalse));
      wire['authoredGeometry']['extentEmu']['width'] = 1;
      expect(table.authoredGeometry['extentEmu']['width'], 7920001);
      expect(
        () => table.authoredGeometry['columnWidthsEmu'][0] = 1,
        throwsUnsupportedError,
      );
      expect(
        () => table.nativeBoundsHmm['width'] = 22000,
        throwsUnsupportedError,
      );
    },
  );

  test('partial inventory retains a covered cell without guessing an absent anchor', () {
    final tableWire = _table()
      ..['truncated'] = true
      ..['cells'] = [
        _cell(_coveredId, 0, 1, covered: true, anchorCellId: _anchorId),
      ];
    final dynamic slide = _readSlide({
      ..._catalogSlide(tableWire),
      'presentationTableCount': 7,
      'presentationTablesTruncated': true,
    });
    expect(slide.presentationTableCount, 7);
    expect(slide.presentationTablesTruncated, isTrue);
    final dynamic table = slide.presentationTables.single;
    expect(table.truncated, isTrue);
    expect(table.totalCellCount, 4);
    expect(table.cells.single.id, _coveredId);
    expect(table.cells.single.anchorCellId, _anchorId);
    expect(_capabilities(table.capabilities), everyElement(isFalse));
    expect(slide.canAddTable, isFalse);
  });

  test('omitted new table capabilities and optional counts default closed', () {
    final wire = _table()
      ..remove('capabilities')
      ..remove('truncated')
      ..remove('totalCellCount');
    final dynamic table = _readTable(wire);
    expect(_capabilities(table.capabilities), everyElement(isFalse));
    expect(table.truncated, isFalse);
    expect(table.totalCellCount, 4);
  });

  test('identical content does not collapse distinct actual tables', () {
    const secondId = 'slide-0/shape-11';
    final second = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(_table()).replaceAll(_tableId, secondId)) as Map,
    );
    second['tableSha256'] = 'c' * 64;
    final slideWire =
        Map<String, dynamic>.from(
            jsonDecode(jsonEncode(_catalogSlide(_table()))) as Map,
          )
          ..['presentationTables'] = [_table(), second]
          ..['presentationTableCount'] = 2;
    slideWire['shapes'].add({
      ...Map<String, dynamic>.from(slideWire['shapes'][0] as Map),
      'id': secondId,
    });
    final dynamic slide = _readSlide(slideWire);
    expect(
      [for (final dynamic table in slide.presentationTables) table.id],
      [_tableId, secondId],
    );
    expect(
      [for (final dynamic table in slide.presentationTables) table.tableSha256],
      ['b' * 64, 'c' * 64],
    );
    expect(slide.presentationTables[1].cells.first.id, '$secondId/cell-42');
  });

  test('logical coordinates are parsed independently of cell list order', () {
    final wire = _table();
    wire['cells'] = [
      wire['cells'][3],
      wire['cells'][1],
      wire['cells'][0],
      wire['cells'][2],
    ];
    final dynamic table = _readTable(wire);
    expect(
      [for (final dynamic cell in table.cells) cell.id],
      ['$_tableId/cell-2', _coveredId, _anchorId, '$_tableId/cell-19'],
    );
    expect([table.cells[0].row, table.cells[0].column], [1, 1]);
    expect(table.cells[1].anchorCellId, _anchorId);
  });

  test('known boolean capability values survive a complete future payload', () {
    final wire = _table()
      ..['authoredGeometry'] = {
        ..._authoredGeometry(),
        'extentEmu': {'width': 7920000, 'height': 2520000},
      }
      ..['nativeBoundsHmm'] = {
        'x': 1500,
        'y': 3000,
        'width': 22000,
        'height': 7000,
      }
      ..['capabilities'] = {for (final key in _capabilityKeys) key: true};
    expect(_capabilities(_readTable(wire).capabilities), everyElement(isTrue));
    final dynamic emptySlide = _readSlide({
      ..._slide(),
      'presentationTables': [],
      'presentationTableCount': 0,
      'canAddTable': true,
    });
    expect(emptySlide.canAddTable, isTrue);
  });

  test(
    'capability objects reject unknown names instead of accepting typos',
    () {
      final wire = _table()
        ..['capabilities'] = {'canEditText': false, 'canEditCellText': true};
      expect(() => _readTable(wire), throwsFormatException);
    },
  );

  for (final value in <Object?>['true', 1, null, <String, bool>{}]) {
    test('capability values require booleans: $value', () {
      final wire = _table()..['capabilities'] = {'canMerge': value};
      expect(() => _readTable(wire), throwsFormatException);
    });
  }

  for (final value in <Object?>['true', 1, null]) {
    test('canAddTable requires a boolean when present: $value', () {
      final slide = _catalogSlide(_table())..['canAddTable'] = value;
      expect(() => _readSlide(slide), throwsFormatException);
    });
  }

  test('partial table capabilities cannot claim mutation authority', () {
    final wire = _table()
      ..['truncated'] = true
      ..['capabilities'] = {'canEditText': true};
    expect(() => _readTable(wire), throwsFormatException);
  });

  test('a partial slide cannot expose table mutation or create authority', () {
    for (final enableCreate in [false, true]) {
      final table = _table();
      if (!enableCreate) table['capabilities']['canMerge'] = true;
      final slide = _catalogSlide(table)
        ..['presentationTablesTruncated'] = true
        ..['canAddTable'] = enableCreate;
      expect(() => _readSlide(slide), throwsFormatException);
    }
  });

  test('an unknown catalog cannot claim create authority', () {
    final slide = _slide()..['canAddTable'] = true;
    expect(() => _readSlide(slide), throwsFormatException);
  });

  final invalidTables = <String, void Function(Map<String, dynamic>)>{
    'zero row count': (wire) => wire['rowCount'] = 0,
    'fractional column count': (wire) => wire['columnCount'] = 2.5,
    'incorrect total logical cell count': (wire) => wire['totalCellCount'] = 3,
    'row heights do not describe every row': (wire) =>
        wire['rowHeightsHmm'] = [3500],
    'column widths do not describe every column': (wire) =>
        wire['columnWidthsHmm'] = [11000],
    'cell outside row bounds': (wire) => wire['cells'][3]['row'] = 2,
    'zero anchor span': (wire) => wire['cells'][0]['columnSpan'] = 0,
    'anchor span outside column bounds': (wire) =>
        wire['cells'][0]['columnSpan'] = 3,
    'duplicate actual cell ID': (wire) =>
        wire['cells'][3]['id'] = wire['cells'][2]['id'],
    'duplicate logical coordinate': (wire) => wire['cells'][3]['column'] = 0,
    'missing logical cell in complete catalog': (wire) =>
        wire['cells'].removeLast(),
    'covered cell has no anchor ID': (wire) =>
        wire['cells'][1]['anchorCellId'] = null,
    'covered cell refers to an absent anchor': (wire) =>
        wire['cells'][1]['anchorCellId'] = 'absent-cell',
    'covered cell refers outside its anchor span': (wire) =>
        wire['cells'][1]['anchorCellId'] = wire['cells'][2]['id'],
    'overlapping anchor partition': (wire) {
      wire['cells'][1]['covered'] = false;
      wire['cells'][1]['anchorCellId'] = null;
    },
  };
  for (final invalid in invalidTables.entries) {
    test('complete topology rejects ${invalid.key}', () {
      final wire = _table();
      invalid.value(wire);
      expect(() => _readTable(wire), throwsFormatException);
    });
  }

  test('partial grids still reject duplicate identities, coordinates and out-of-bounds cells', () {
    for (final key in [
      'duplicate actual cell ID',
      'duplicate logical coordinate',
      'cell outside row bounds',
    ]) {
      final wire = _table()..['truncated'] = true;
      invalidTables[key]!(wire);
      expect(() => _readTable(wire), throwsFormatException);
    }
  });

  test('a slide rejects duplicate table IDs and a table belonging to another owner', () {
    final duplicate = _catalogSlide(_table())
      ..['presentationTables'] = [_table(), _table()]
      ..['presentationTableCount'] = 2;
    expect(() => _readSlide(duplicate), throwsFormatException);
    final wrongOwner = _table()..['ownerId'] = 'slide-1';
    expect(() => _readTable(wrongOwner), throwsFormatException);
  });

  test(
    'catalog counts and truncation flags require exact nonnegative types',
    () {
      for (final value in <Object?>[-1, 1.5, '1']) {
        final slide = _catalogSlide(_table())
          ..['presentationTableCount'] = value;
        expect(() => _readSlide(slide), throwsFormatException);
      }
      final mismatch = _catalogSlide(_table())..['presentationTableCount'] = 2;
      expect(() => _readSlide(mismatch), throwsFormatException);
      final invalidSlideFlag = _catalogSlide(_table())
        ..['presentationTablesTruncated'] = 'false';
      expect(() => _readSlide(invalidSlideFlag), throwsFormatException);
      final invalidTableFlag = _table()..['truncated'] = 'false';
      expect(() => _readTable(invalidTableFlag), throwsFormatException);
    },
  );

  for (final part in [
    '../ppt/slides/slide1.xml',
    'ppt/../slides/slide1.xml',
    '/ppt/slides/slide1.xml',
    'C:/ppt/slides/slide1.xml',
    r'ppt\slides\slide1.xml',
  ]) {
    test('authored package part rejects unsafe path $part', () {
      final geometry = _authoredGeometry()..['sourcePart'] = part;
      final wire = _table()..['authoredGeometry'] = geometry;
      expect(() => _readTable(wire), throwsFormatException);
    });
  }

  final invalidGeometries = <String, void Function(Map<String, dynamic>)>{
    'fractional EMU': (geometry) => geometry['extentEmu']['width'] = 7920001.5,
    'zero extent': (geometry) => geometry['extentEmu']['height'] = 0,
    'nonpositive authored column': (geometry) =>
        geometry['columnWidthsEmu'][0] = 0,
    'missing row dimension': (geometry) =>
        geometry['rowHeightsEmu'] = [1260000],
    'unknown authored field': (geometry) => geometry['widthHmm'] = 22000,
    'unknown position field': (geometry) => geometry['positionEmu']['z'] = 0,
  };
  for (final invalid in invalidGeometries.entries) {
    test('authored geometry rejects ${invalid.key}', () {
      final geometry = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(_authoredGeometry())) as Map,
      );
      invalid.value(geometry);
      final wire = _table()..['authoredGeometry'] = geometry;
      expect(() => _readTable(wire), throwsFormatException);
    });
  }

  test(
    'a raw unknown keeps a full read catalog with a nullable fingerprint',
    () {
      final wire = _table()..['tableSha256'] = null;
      final dynamic slide = _readSlide({
        ..._catalogSlide(wire),
        'presentationTablesUnknownReason': 'raw_state_unavailable',
      });
      final dynamic table = slide.presentationTables.single;
      expect(table.tableSha256, isNull);
      expect(table.truncated, isFalse);
      expect(table.cells, hasLength(4));
      expect(table.cells[0].rawStyle['UnobservedProperty']['unknown'], isTrue);
      expect(slide.presentationTablesUnknownReason, 'raw_state_unavailable');
      expect(_capabilities(table.capabilities), everyElement(isFalse));
    },
  );

  test('a nullable fingerprint cannot claim any write capability', () {
    final wire = _table()
      ..['tableSha256'] = null
      ..['capabilities'] = {'canEditText': true};
    expect(() => _readTable(wire), throwsFormatException);
  });

  test('an unknown catalog keeps its observed count and short reason code', () {
    final dynamic slide = _readSlide({
      ..._slide(),
      'presentationTables': null,
      'presentationTableCount': 2,
      'presentationTablesUnknownReason': 'model_unavailable',
    });
    expect(slide.presentationTables, isNull);
    expect(slide.presentationTableCount, 2);
    expect(slide.presentationTablesUnknownReason, 'model_unavailable');
    expect(slide.canAddTable, isFalse);
  });

  test(
    'unknown native row dimensions stay null in a complete read catalog',
    () {
      final wire = _table()
        ..['tableSha256'] = null
        ..['rowHeightsHmm'] = [null, 3500]
        ..['columnWidthsHmm'] = [11000, null];
      final dynamic table = _readTable(wire);
      expect(table.rowHeightsHmm, [null, 3500]);
      expect(table.columnWidthsHmm, [11000, null]);
      expect(table.cells, hasLength(4));
      expect(table.truncated, isFalse);
      expect(_capabilities(table.capabilities), everyElement(isFalse));
    },
  );

  test('unknown authored geometry cannot claim table mutation authority', () {
    final wire = _table()..['capabilities'] = {'canEditText': true};
    expect(() => _readTable(wire), throwsFormatException);
  });

  test(
    'authored frame and grid mismatch cannot claim table mutation authority',
    () {
      final wire = _table()
        ..['authoredGeometry'] = _authoredGeometry()
        ..['capabilities'] = {'canMerge': true};
      expect(() => _readTable(wire), throwsFormatException);
    },
  );

  for (final tall in [true, false]) {
    test(
      'partial ${tall ? 'row' : 'column'} dimensions retain an exact 100-item prefix and original counts',
      () {
        final prefix = List<int?>.generate(
          100,
          (index) => index == 37 ? null : 3500 + index,
        );
        final wire = _table()
          ..['tableSha256'] = null
          ..['truncated'] = true
          ..['totalCellCount'] = 400000;
        if (tall) {
          wire['rowCount'] = 200000;
          wire['rowHeightsHmm'] = prefix;
        } else {
          wire['columnCount'] = 200000;
          wire['columnWidthsHmm'] = prefix;
        }
        final dynamic table = _readTable(wire);
        expect(table.totalCellCount, 400000);
        expect(table.rowCount, tall ? 200000 : 2);
        expect(table.columnCount, tall ? 2 : 200000);
        expect(tall ? table.rowHeightsHmm : table.columnWidthsHmm, prefix);
        expect(
          tall ? table.columnWidthsHmm : table.rowHeightsHmm,
          tall ? [11000, 11000] : [3500, 3500],
        );
        expect(table.cells, hasLength(4));
        expect(table.truncated, isTrue);
        expect(_capabilities(table.capabilities), everyElement(isFalse));
        expect(
          () =>
              (tall ? table.rowHeightsHmm : table.columnWidthsHmm).removeAt(0),
          throwsUnsupportedError,
        );
      },
    );
  }

  for (final rows in [true, false]) {
    test(
      'partial ${rows ? 'row' : 'column'} dimension vectors reject 101 observations',
      () {
        final wire = _table()
          ..['tableSha256'] = null
          ..['truncated'] = true
          ..['totalCellCount'] = 202;
        if (rows) {
          wire['rowCount'] = 101;
          wire['rowHeightsHmm'] = List<int?>.filled(101, 3500);
        } else {
          wire['columnCount'] = 101;
          wire['columnWidthsHmm'] = List<int?>.filled(101, 11000);
        }
        expect(() => _readTable(wire), throwsFormatException);
      },
    );
  }

  test('partial dimension prefixes cannot exceed their original row or column counts', () {
    for (final rows in [true, false]) {
      final wire = _table()
        ..['tableSha256'] = null
        ..['truncated'] = true;
      wire[rows ? 'rowHeightsHmm' : 'columnWidthsHmm'] = [3500, 3500, 3500];
      expect(() => _readTable(wire), throwsFormatException);
    }
  });

  test('every partial dimension-prefix mutation capability remains closed', () {
    for (final capability in _capabilityKeys) {
      final wire = _table()
        ..['rowCount'] = 200000
        ..['totalCellCount'] = 400000
        ..['truncated'] = true
        ..['rowHeightsHmm'] = List<int?>.filled(100, 3500)
        ..['capabilities'] = {capability: true};
      expect(() => _readTable(wire), throwsFormatException, reason: capability);
    }
  });

  test(
    'partial dimension vectors retain every index in their bounded prefix',
    () {
      for (final rows in [true, false]) {
        final wire = _table()
          ..['tableSha256'] = null
          ..['truncated'] = true
          ..['totalCellCount'] = 400000;
        wire[rows ? 'rowCount' : 'columnCount'] = 200000;
        wire[rows ? 'rowHeightsHmm' : 'columnWidthsHmm'] = List<int?>.filled(
          99,
          null,
        );
        expect(() => _readTable(wire), throwsFormatException);
      }
    },
  );
}
