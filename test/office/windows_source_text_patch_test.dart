import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

const _source =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _frame =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _owner = 'slide-0';
const _table = 'slide-0/shape-7';
const _cell = 'stable-cell-42';

Map<String, dynamic> _proof(String text) => {
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

Map<String, dynamic> _wire({String text = 'A😀B'}) => {
  'kind': 'presentation',
  'sourceSha256': _source,
  'paragraphs': [],
  'tables': [],
  'masters': [],
  'slides': [
    <String, dynamic>{
      'id': _owner,
      'width': 280,
      'height': 157.5,
      'presentationTableCount': 1,
      'presentationTablesTruncated': false,
      'canAddTable': false,
      'shapes': [
        {
          'id': _table,
          'type': 'com.sun.star.drawing.TableShape',
          'text': '',
          'x': 0,
          'y': 0,
          'width': 199.99,
          'height': 70,
        },
      ],
      'presentationTables': [
        {
          'id': _table,
          'ownerId': _owner,
          'tableSha256': null,
          'rowCount': 1,
          'columnCount': 1,
          'totalCellCount': 1,
          'truncated': false,
          'rowHeightsHmm': [7000],
          'columnWidthsHmm': [20000],
          'nativeBoundsHmm': {'x': 0, 'y': 0, 'width': 19999, 'height': 7000},
          'authoredGeometry': {
            'sourcePart': 'ppt/slides/slide1.xml',
            'shapeId': '0009',
            'positionEmu': {'x': 0, 'y': 0},
            'extentEmu': {'width': 7200000, 'height': 2520000},
            'columnWidthsEmu': [7200000],
            'rowHeightsEmu': [2520000],
          },
          'sourceTextPatchAuthority': {
            'kind': 'sourceTextPatch',
            'version': 1,
            'sourceSha256': _source,
            'sourcePart': 'ppt/slides/slide1.xml',
            'shapeId': '0009',
            'frameSha256': _frame,
          },
          'rawStyle': {'unknown': true, 'error': 'native raw unavailable'},
          'capabilities': <String, dynamic>{},
          'cells': [
            {
              'id': _cell,
              'row': 0,
              'column': 0,
              'rowSpan': 1,
              'columnSpan': 1,
              'covered': false,
              'anchorCellId': null,
              'text': 'origin native baseline',
              'textDetails': null,
              'rawStyle': <String, dynamic>{},
              'sourceTextPatch': _proof(text),
            },
          ],
        },
      ],
    },
  ],
};

Map<String, dynamic> _tableWire(Map<String, dynamic> value) =>
    value['slides'][0]['presentationTables'][0] as Map<String, dynamic>;
Map<String, dynamic> _cellWire(Map<String, dynamic> value) =>
    _tableWire(value)['cells'][0] as Map<String, dynamic>;
dynamic _parsed(Map<String, dynamic> value) =>
    WindowsOfficeSnapshot.fromJson(value)
        .slides
        .single
        .presentationTables!
        .single;
dynamic _parsedProof(Map<String, dynamic> value) =>
    _parsed(value).cells.single.sourceTextPatch;

void main() {
  test('source proof is independent of null native SHA and origin native text baseline', () {
    final dynamic table = _parsed(_wire());
    expect(table.tableSha256, isNull);
    expect(table.capabilities.canEditText, isFalse);
    expect(table.sourceTextPatchAuthority.kind, 'sourceTextPatch');
    expect(table.sourceTextPatchAuthority.version, 1);
    expect(table.sourceTextPatchAuthority.shapeId, '0009');
    expect(table.sourceTextPatchAuthority.sourceSha256, _source);
    expect(table.cells.single.text, 'origin native baseline');
    expect(table.cells.single.sourceTextPatch.text, 'A😀B');
    expect(table.cells.single.sourceTextPatch.canReplace, isTrue);
    expect(table.nativeBoundsHmm['width'], 19999);
    expect(table.authoredGeometry['extentEmu']['width'], 7200000);
  });

  test('RAW-only parent truncation does not close a complete separate source proof', () {
    final value = _wire();
    _tableWire(value)['truncated'] = true;
    _cellWire(value)['textDetails'] = {
      'utf16Length': 22,
      'textSha256': 'c' * 64,
      'truncated': true,
      'canReplace': false,
      'canStyle': false,
      'runs': [],
      'protectedRanges': [],
    };
    expect(_parsedProof(value).canReplace, isTrue);
    expect(_parsed(value).capabilities.canEditText, isFalse);
  });

  test('source DTO lists and serialization are detached immutable values', () {
    final value = _wire();
    final dynamic table = _parsed(value),
        proof = table.cells.single.sourceTextPatch;
    _cellWire(value)['sourceTextPatch']['segments'][0]['endUtf16'] = 1;
    _tableWire(value)['sourceTextPatchAuthority']['shapeId'] = '8';
    expect(proof.segments.single.endUtf16, 4);
    expect(table.sourceTextPatchAuthority.shapeId, '0009');
    expect(() => proof.segments.clear(), throwsUnsupportedError);
    expect(() => proof.protectedRanges.clear(), throwsUnsupportedError);
    final dynamic encoded = proof.toJson();
    encoded['segments'][0]['endUtf16'] = 2;
    expect(proof.segments.single.endUtf16, 4);
  });

  test('source allowsRange follows surrogate boundaries and protected closed insertion boundaries', () {
    final value = _wire(text: 'A😀B\nC');
    _cellWire(value)['sourceTextPatch']['segments'] = [
      {'startUtf16': 0, 'endUtf16': 4, 'editable': true},
      {'startUtf16': 4, 'endUtf16': 5, 'editable': false},
      {'startUtf16': 5, 'endUtf16': 6, 'editable': true},
    ];
    _cellWire(value)['sourceTextPatch']['protectedRanges'] = [
      {'startUtf16': 4, 'endUtf16': 5, 'reason': 'paragraphBoundary'},
      {'startUtf16': 1, 'endUtf16': 1, 'reason': 'comment'},
    ];
    final dynamic proof = _parsedProof(value);
    expect(proof.allowsRange(1, 3), isTrue);
    expect(proof.allowsRange(2, 2), isFalse);
    expect(proof.allowsRange(0, 6), isFalse);
    expect(proof.allowsRange(4, 4), isFalse);
    expect(proof.allowsRange(5, 5), isFalse);
    expect(proof.allowsRange(0, 1), isTrue);
  });

  test('paired empty source content can insert while an absent editable interval cannot', () {
    final dynamic proof = _parsedProof(_wire(text: ''));
    expect(proof.allowsRange(0, 0), isTrue);
    final value = _wire(text: '');
    _cellWire(value)['sourceTextPatch']['segments'] = [];
    expect(() => _parsed(value), throwsFormatException);
  });

  test('source authority and proof are optional and never manufacture native text permission', () {
    final value = _wire();
    _tableWire(value).remove('sourceTextPatchAuthority');
    _cellWire(value).remove('sourceTextPatch');
    final dynamic table = _parsed(value);
    expect(table.sourceTextPatchAuthority, isNull);
    expect(table.cells.single.sourceTextPatch, isNull);
    expect(table.capabilities.canEditText, isFalse);
  });

  test('authority version hashes original decimal IDs paths and closed fields are exact', () {
    final corruptions = <void Function(Map<String, dynamic>)>[
      (v) => _tableWire(v)['sourceTextPatchAuthority']['version'] = 2,
      (v) => _tableWire(v)['sourceTextPatchAuthority']['version'] = true,
      (v) => _tableWire(v)['sourceTextPatchAuthority']['kind'] = 'native',
      (v) =>
          _tableWire(v)['sourceTextPatchAuthority']['sourceSha256'] = 'c' * 64,
      (v) =>
          _tableWire(v)['sourceTextPatchAuthority']['frameSha256'] = 'B' * 64,
      (v) => _tableWire(v)['sourceTextPatchAuthority']['sourcePart'] =
          '../slide.xml',
      (v) => _tableWire(v)['sourceTextPatchAuthority']['shapeId'] = 'shape-9',
      (v) => _tableWire(v)['sourceTextPatchAuthority']['extra'] = 1,
      (v) => _tableWire(v)['authoredGeometry']['shapeId'] = '9',
      (v) => _tableWire(v)['authoredGeometry']['sourcePart'] =
          'ppt/slides/slide2.xml',
      (v) => _tableWire(v).remove('authoredGeometry'),
      (v) => _tableWire(v).remove('sourceTextPatchAuthority'),
    ];
    for (final corrupt in corruptions) {
      final value = _wire();
      corrupt(value);
      expect(() => _parsed(value), throwsFormatException);
    }
  });

  test('missing source truncated and partial source permission cannot default to complete', () {
    for (final missing in [
      'canReplace',
      'truncated',
      'text',
      'utf16Length',
      'textSha256',
      'segments',
      'protectedRanges',
    ]) {
      final value = _wire();
      (_cellWire(value)['sourceTextPatch'] as Map).remove(missing);
      expect(() => _parsed(value), throwsFormatException, reason: missing);
    }
    final value = _wire();
    _cellWire(value)['sourceTextPatch']['truncated'] = true;
    expect(() => _parsed(value), throwsFormatException);
  });

  test(
    'source text scalar hash length coverage and closed reasons are validated',
    () {
      final corruptions = <void Function(Map<String, dynamic>)>[
        (p) => p['utf16Length'] = 3,
        (p) => p['utf16Length'] = true,
        (p) => p['textSha256'] = '0' * 64,
        (p) => p['segments'] = [
          {'startUtf16': 1, 'endUtf16': 4, 'editable': true},
        ],
        (p) => p['segments'] = [
          {'startUtf16': 0, 'endUtf16': 2, 'editable': true},
          {'startUtf16': 2, 'endUtf16': 4, 'editable': true},
        ],
        (p) => p['segments'][0]['extra'] = 1,
        (p) => p['protectedRanges'] = [
          {'startUtf16': 0, 'endUtf16': 4, 'reason': 'unknown'},
        ],
        (p) => p['protectedRanges'] = [
          {'startUtf16': 2, 'endUtf16': 3, 'reason': 'field'},
        ],
        (p) => p['text'] = String.fromCharCode(0xd800),
      ];
      for (final corrupt in corruptions) {
        final value = _wire();
        corrupt(_cellWire(value)['sourceTextPatch'] as Map<String, dynamic>);
        expect(() => _parsed(value), throwsFormatException);
      }
    },
  );

  test('source proof and native guards remain separate under incomplete owner or cell topology', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (v) => v['slides'][0]['presentationTablesTruncated'] = true,
      (v) => v['slides'][0]['presentationTableCount'] = 2,
      (v) => v['slides'][0]['presentationTableCount'] = null,
      (v) => v['slides'][0]['shapes'] = [],
      (v) => _tableWire(v)['cells'] = [],
      (v) => _tableWire(v)['truncated'] = true,
    ]) {
      final value = _wire();
      mutate(value);
      if (_tableWire(value)['cells'].isNotEmpty &&
          _tableWire(value)['truncated'] == true) {
        expect(_parsedProof(value).canReplace, isTrue);
      } else {
        expect(() => _parsed(value), throwsFormatException);
      }
    }
  });

  test(
    'master tables and covered cells cannot receive source write permission',
    () {
      final value = _wire();
      final owner = value['slides'][0] as Map<String, dynamic>;
      owner['id'] = 'master-0';
      owner['name'] = 'Master';
      _tableWire(value)['ownerId'] = 'master-0';
      value['masters'] = [owner];
      value['slides'] = [];
      expect(
        () => WindowsOfficeSnapshot.fromJson(value),
        throwsFormatException,
      );
      final covered = _wire();
      _cellWire(covered)['covered'] = true;
      _cellWire(covered)['anchorCellId'] = _cell;
      expect(() => _parsed(covered), throwsFormatException);
    },
  );

  test('source UTF16 and segment protected budgets reject oversized proof before permission', () {
    final textTooLong = _wire(text: 'x' * 131073);
    expect(() => _parsed(textTooLong), throwsFormatException);
    for (final field in ['segments', 'protectedRanges']) {
      final value = _wire();
      _cellWire(value)['sourceTextPatch'][field] = [
        for (var i = 0; i < 4097; i++)
          if (field == 'segments')
            {'startUtf16': 0, 'endUtf16': 0, 'editable': true}
          else
            {'startUtf16': 0, 'endUtf16': 0, 'reason': 'comment'},
      ];
      expect(() => _parsed(value), throwsFormatException);
    }
  });
}
