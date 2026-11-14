import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

import 'windows_presentation_structure_test.dart';

const _candidate =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const _frame =
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _operations =
    'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';

Map<String, dynamic> structureCandidateSnapshot() {
  final result = sourceStructureSnapshotWire();
  result['sourceSha256'] = _candidate;
  final slide = result['slides'][0] as Map<String, dynamic>;
  slide['sourceStructureAuthority'] = {
    ...sourceStructureAuthorityWire(),
    'sourceSha256': _candidate,
    'shapeIdCount': 2,
  };
  slide['presentationTableCount'] = 1;
  slide['shapes'] = [
    {
      'id': 'slide-0/shape-0',
      'ownerId': 'slide-0',
      'type': 'com.sun.star.drawing.TableShape',
      'text': '',
      'x': 0,
      'y': 0,
      'width': 29.99,
      'height': 12,
    },
  ];
  slide['presentationTables'] = [
    {
      'id': 'slide-0/shape-0',
      'ownerId': 'slide-0',
      'tableSha256': null,
      'rowCount': 1,
      'columnCount': 1,
      'totalCellCount': 1,
      'truncated': false,
      'rowHeightsHmm': [1200],
      'columnWidthsHmm': [3000],
      'nativeBoundsHmm': {'x': 0, 'y': 0, 'width': 2999, 'height': 1200},
      'authoredGeometry': {
        'sourcePart': 'ppt/slides/slide1.xml',
        'shapeId': '2',
        'positionEmu': {'x': 0, 'y': 0},
        'extentEmu': {'width': 1080000, 'height': 432000},
        'columnWidthsEmu': [1080000],
        'rowHeightsEmu': [432000],
      },
      'sourceTextPatchAuthority': {
        'kind': 'sourceTextPatch',
        'version': 1,
        'sourceSha256': _candidate,
        'sourcePart': 'ppt/slides/slide1.xml',
        'shapeId': '2',
        'frameSha256': _frame,
      },
      'rawStyle': <String, dynamic>{},
      'capabilities': <String, dynamic>{},
      'cells': [
        {
          'id': 'slide-0/shape-0/cell-0',
          'row': 0,
          'column': 0,
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
    },
  ];
  return result;
}

Map<String, dynamic> structuralPreviewWire() => {
  'kind': 'presentationSourceStructure',
  'version': 1,
  'baseSourceSha256': sourceStructureHash,
  'candidateSourceSha256': _candidate,
  'operationsSha256': _operations,
  'additions': [
    <String, dynamic>{
      'alias': 'new-table-fixture',
      'ownerId': 'slide-0',
      'tableId': 'slide-0/shape-0',
      'sourcePart': 'ppt/slides/slide1.xml',
      'shapeId': '2',
      'frameSha256': _frame,
    },
  ],
  'snapshot': structureCandidateSnapshot(),
};

Map<String, dynamic> structuralResultWire() => {
  'sessionId': 'fixture-session',
  'sourcePath': r'C:\private\edited.pptx',
  'pdfPath': r'C:\private\preview.pdf',
  'sourceSha256': _candidate,
  'pdfSha256': '0' * 64,
  'pdfPageCount': 1,
  'engineVersion': 'LibreOffice26.8.2.2',
  'snapshot': structureCandidateSnapshot(),
  'structuralPreview': structuralPreviewWire(),
};

dynamic _parsedPreview(Map<String, dynamic> result) {
  final dynamic parsed = WindowsOfficeEditResult.fromJson(result);
  try {
    return parsed.structuralPreview;
  } on NoSuchMethodError {
    return null;
  }
}

void main() {
  test(
    'structural preview keeps base and verified candidate revisions separate',
    () {
      final dynamic preview = _parsedPreview(structuralResultWire());
      expect(
        preview,
        isNotNull,
        reason: 'New candidate structure must not be discarded or use legacy draftSnapshot',
      );
      expect(preview.kind, 'presentationSourceStructure');
      expect(preview.version, 1);
      expect(preview.baseSourceSha256, sourceStructureHash);
      expect(preview.candidateSourceSha256, _candidate);
      expect(preview.operationsSha256, _operations);
      expect(preview.snapshot.sourceSha256, _candidate);
      expect(preview.additions.single.alias, 'new-table-fixture');
      expect(preview.additions.single.tableId, 'slide-0/shape-0');
      expect(() => preview.additions.clear(), throwsUnsupportedError);
      expect(
        WindowsOfficeEditResult.fromJson(structuralResultWire()).draftSnapshot,
        isNull,
      );
    },
  );

  test(
    'structural preview schema revision and operation digest are closed',
    () {
      final mutations = <void Function(Map<String, dynamic>)>[
        (p) => p['extra'] = 1,
        (p) => p['kind'] = 'sourceTextPatch',
        (p) => p['version'] = 2,
        (p) => p['version'] = true,
        (p) => p['baseSourceSha256'] = 'bad',
        (p) => p['candidateSourceSha256'] = sourceStructureHash,
        (p) => p['operationsSha256'] = 'F' * 64,
      ];
      for (final mutate in mutations) {
        final result = structuralResultWire();
        mutate(result['structuralPreview'] as Map<String, dynamic>);
        expect(
          () => WindowsOfficeEditResult.fromJson(result),
          throwsFormatException,
        );
      }
      for (final key in structuralPreviewWire().keys) {
        final result = structuralResultWire();
        (result['structuralPreview'] as Map).remove(key);
        expect(
          () => WindowsOfficeEditResult.fromJson(result),
          throwsFormatException,
          reason: key,
        );
      }
    },
  );

  test(
    'new table aliases are unique and bound to actual candidate source frames',
    () {
      final mutations = <void Function(Map<String, dynamic>)>[
        (p) => p['additions'] = [],
        (p) => p['additions'] = [p['additions'][0], p['additions'][0]],
        (p) => p['additions'][0]['alias'] = 'slide-0/shape-0',
        (p) => p['additions'][0]['extra'] = true,
        (p) => p['additions'][0]['ownerId'] = 'master-0',
        (p) => p['additions'][0]['tableId'] = 'slide-0/shape-99',
        (p) => p['additions'][0]['sourcePart'] = 'ppt/slides/slide2.xml',
        (p) => p['additions'][0]['shapeId'] = '3',
        (p) => p['additions'][0]['frameSha256'] = 'a' * 64,
      ];
      for (final mutate in mutations) {
        final result = structuralResultWire();
        mutate(result['structuralPreview'] as Map<String, dynamic>);
        expect(
          () => WindowsOfficeEditResult.fromJson(result),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'the structural snapshot and saved candidate snapshot must be identical',
    () {
      final result = structuralResultWire();
      result['structuralPreview']['snapshot']['slides'][0]['width'] = 300;
      expect(
        () => WindowsOfficeEditResult.fromJson(result),
        throwsFormatException,
      );
      final wrongHash = structuralResultWire()
        ..['sourceSha256'] = sourceStructureHash;
      expect(
        () => WindowsOfficeEditResult.fromJson(wrongHash),
        throwsFormatException,
      );
    },
  );

  test('structural and legacy draft payloads cannot be conflated', () {
    final result = structuralResultWire();
    result['draftSnapshot'] = sourceStructureSnapshotWire();
    expect(
      () => WindowsOfficeEditResult.fromJson(result),
      throwsFormatException,
    );
    final legacy = structuralResultWire()..remove('structuralPreview');
    expect(_parsedPreview(legacy), isNull);
  });

  test(
    'parsing the preview detaches caller-owned addition and snapshot JSON',
    () {
      final result = structuralResultWire();
      final dynamic preview = _parsedPreview(result);
      expect(preview, isNotNull);
      result['structuralPreview']['additions'][0]['frameSha256'] = 'a' * 64;
      result['structuralPreview']['snapshot']['slides'][0]['width'] = 300;
      expect(preview.additions.single.frameSha256, _frame);
      expect(preview.snapshot.slides.single.width, 280);
      expect(jsonEncode(structuralResultWire()), isNotEmpty);
    },
  );
}
