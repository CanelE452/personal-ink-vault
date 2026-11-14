// Service/publication boundaries with actual repository bytes; native execution is separate.
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

import '../office/windows_presentation_structure_preview_test.dart';
import '../office/windows_presentation_structure_test.dart';

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);

void _setHash(Map<String, dynamic> snapshot, String hash) {
  snapshot['sourceSha256'] = hash;
  for (final slide in snapshot['slides'] as List) {
    slide['sourceStructureAuthority']['sourceSha256'] = hash;
    for (final table in slide['presentationTables'] as List) {
      table['sourceTextPatchAuthority']['sourceSha256'] = hash;
    }
  }
}

Uint8List _pptx(String text) => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
      ..addFile(
        ArchiveFile.string(
          'ppt/presentation.xml',
          '<presentation>$text</presentation>',
        ),
      ),
  ),
);

Map<String, dynamic> _operation(
  String hash, {
  String id = 'new-table-service',
}) => {
  'op': 'presentationSourceTableAdd',
  'authorityVersion': 1,
  'id': id,
  'ownerId': 'slide-0',
  'expectedSourceSha256': hash,
  'sourcePart': 'ppt/slides/slide1.xml',
  'expectedSourcePartSha256': sourceStructurePartHash,
  'expectedShapeIdInventorySha256': sourceStructureInventoryHash,
  'xMm': 0.29,
  'yMm': -0.29,
  'columnWidthsMm': <num>[30, 40.01],
  'rowHeightsMm': <num>[12, 12],
};

Matcher _error(String code) => throwsA(
  isA<VaultMcpException>().having((error) => error.code, 'code', code),
);

int _nodes(Object? value) =>
    1 +
    (value is Map
        ? value.entries.fold<int>(
            0,
            (total, entry) => total + 1 + _nodes(entry.value),
          )
        : value is List
        ? value.fold<int>(0, (total, child) => total + _nodes(child))
        : 0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late WorkspaceController controller;
  late VaultNote note;
  late OfficeEdition first;
  var writable = true;
  final readContext = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => false,
  );
  late VaultMcpCallContext writeContext;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-source-structure-');
    controller = WorkspaceController(
      await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      ),
      directoryProvider: () async => temp,
    );
    note = await OfficeDocumentStore(controller.repository).importDocument(
      title: 'Source table creation',
      fileName: 'source.pptx',
      bytes: _pptx('immutable original'),
    );
    first = await OfficeDocumentStore(controller.repository).readLatest(note);
    writable = true;
    writeContext = VaultMcpCallContext(
      isActive: () => true,
      canWrite: () => writable,
    );
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
  });

  Map<String, dynamic> args(List<Map<String, dynamic>> operations) => {
    'noteId': note.id,
    'expectedRevisionId': first.revision.revisionId,
    'requestId': newId(),
    'operations': operations,
  };

  Future<Map> read(Map<String, dynamic> snapshot) async {
    var calls = 0;
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          calls++;
          expect(request['mode'], 'inspect');
          expect(
            sha256
                .convert(
                  await File(request['sourcePath'] as String).readAsBytes(),
                )
                .toString(),
            first.originalSha256,
          );
          return {'snapshot': snapshot};
        },
      ),
    );
    final result = await service.call('read_document', {
      'noteId': note.id,
    }, context: readContext) as Map;
    expect(calls, 1);
    return result['office'] as Map;
  }

  Map<String, dynamic> emptySnapshot() {
    final value = sourceStructureSnapshotWire();
    _setHash(value, first.originalSha256);
    return value;
  }

  Map<String, dynamic> oneTable() {
    final value = structureCandidateSnapshot();
    _setHash(value, first.originalSha256);
    return value;
  }

  test('read_document publishes closed source creation authority on a known table-free owner', () async {
    final snapshot = emptySnapshot();
    final office = await read(snapshot);
    final owner = office['slides'][0] as Map;
    expect(
      owner['sourceStructureAuthority'],
      snapshot['slides'][0]['sourceStructureAuthority'],
    );
    expect(owner['sourceStructureAuthority']['canAddTable'], true);
    expect(owner['canAddTable'], false);
    expect(owner['presentationTableCount'], 0);
    expect(owner['presentationTables'], isEmpty);
    expect((owner['sourceStructureAuthority'] as Map).length, 8);
  });

  test(
    'native RAW loss and null table SHA alone do not close source creation',
    () async {
      final snapshot = oneTable();
      final table = snapshot['slides'][0]['presentationTables'][0];
      table['truncated'] = true;
      table['tableSha256'] = null;
      table['rawStyle'] = {'unknown': true, 'error': 'read_budget_exhausted'};
      final office = await read(snapshot);
      final owner = office['slides'][0] as Map;
      expect(owner['sourceStructureAuthority'], isNotNull);
      expect(owner['sourceStructureAuthority']['canAddTable'], true);
      expect(owner['canAddTable'], false);
      expect(owner['presentationTables'][0]['tableSha256'], isNull);
      expect(
        (owner['presentationTables'][0]['capabilities'] as Map).values.every(
          (value) => value == false,
        ),
        true,
      );
      expect(
        owner['presentationTables'][0]['cells'][0]['sourceTextPatch'],
        isNotNull,
      );
    },
  );

  test('read_document preserves unknown native text and complete known-empty source proof', () async {
    final snapshot = oneTable();
    final table = snapshot['slides'][0]['presentationTables'][0];
    final cell = table['cells'][0];
    table['truncated'] = true;
    table['tableSha256'] = null;
    table['rawStyle'] = {'unknown': true, 'error': 'read_budget_exhausted'};
    cell['text'] = null;
    cell['textDetails'] = null;
    cell['rawStyle'] = {'unknown': true, 'error': 'read_budget_exhausted'};
    final expectedProof = _copy(
      Map<String, dynamic>.from(cell['sourceTextPatch'] as Map),
    );

    final office = await read(snapshot);
    final published = jsonDecode(jsonEncode(office)) as Map;
    final owner = published['slides'][0] as Map;
    final publishedTable = owner['presentationTables'][0] as Map;
    final publishedCell = publishedTable['cells'][0] as Map;
    expect(publishedCell.containsKey('text'), true);
    expect(publishedCell['text'], isNull);
    expect(publishedCell['textDetails'], isNull);
    expect(publishedCell['truncated'], true);
    expect(publishedTable['tableSha256'], isNull);
    expect(publishedTable['truncated'], true);
    expect(
      (publishedTable['capabilities'] as Map).values.every(
        (value) => value == false,
      ),
      true,
    );
    expect(publishedCell['sourceTextPatch'], expectedProof);
    expect(publishedCell['sourceTextPatch']['text'], '');
    expect(publishedCell['sourceTextPatch']['utf16Length'], 0);
    expect(
      publishedCell['sourceTextPatch']['textSha256'],
      sha256.convert(const <int>[]).toString(),
    );
    expect(publishedCell['sourceTextPatch']['truncated'], false);
    expect(publishedCell['sourceTextPatch']['canReplace'], true);
    expect(
      publishedTable['sourceTextPatchAuthority'],
      table['sourceTextPatchAuthority'],
    );
    expect(owner['sourceStructureAuthority']['canAddTable'], true);
    expect(owner['canAddTable'], false);
  });

  test('hidden actual table shapes close creation without inventing a zero-table owner', () async {
    final snapshot = oneTable();
    final owner = snapshot['slides'][0] as Map;
    final tableShape = _copy(
      Map<String, dynamic>.from(owner['shapes'][0] as Map),
    );
    owner['shapes'] = [
      for (var index = 0; index < 100; index++)
        {
          ...tableShape,
          'id': 'slide-0/plain-$index',
          'type': 'com.sun.star.drawing.RectangleShape',
        },
      tableShape,
    ];
    owner['sourceStructureAuthority']['shapeIdCount'] = 102;
    final office = await read(snapshot);
    final published = office['slides'][0] as Map;
    final authority = published['sourceStructureAuthority'] as Map?;
    expect(authority?['canAddTable'] ?? false, false);
    expect(published['presentationTableCount'], 1);
    expect(published['presentationTables'], hasLength(1));
    expect(published['shapes'], hasLength(100));
    expect(office['truncated'], true);
  });

  test(
    'omitted regular owners close source creation on the visible remainder',
    () async {
      final snapshot = emptySnapshot();
      snapshot['slides'] = [
        for (var index = 0; index < 51; index++)
          {
            ..._copy(Map<String, dynamic>.from(snapshot['slides'][0] as Map)),
            'id': 'slide-$index',
            'sourceStructureAuthority': {
              ...sourceStructureAuthorityWire(),
              'sourceSha256': first.originalSha256,
              'sourcePart': 'ppt/slides/slide$index.xml',
            },
          },
      ];
      final office = await read(snapshot);
      expect(office['slides'], hasLength(50));
      expect(office['truncated'], true);
      for (final owner in (office['slides'] as List).cast<Map>()) {
        expect(
          (owner['sourceStructureAuthority'] as Map?)?['canAddTable'] ?? false,
          false,
        );
      }
    },
  );

  test(
    'a separate 64KiB structure budget never emits partial writable guard maps',
    () async {
      final snapshot = emptySnapshot();
      final original = Map<String, dynamic>.from(snapshot['slides'][0] as Map);
      snapshot['slides'] = [
        for (var index = 0; index < 50; index++)
          {
            ..._copy(original),
            'id': 'slide-$index',
            'sourceStructureAuthority': {
              ...sourceStructureAuthorityWire(),
              'sourceSha256': first.originalSha256,
              'sourcePart': 'ppt/slides/${'😀' * 480}$index.xml',
            },
          },
      ];
      final office = await read(snapshot);
      final values = [
        for (final owner in (office['slides'] as List).cast<Map>())
          owner['sourceStructureAuthority'],
      ];
      expect(values.whereType<Map>(), isNotEmpty);
      expect(
        values
            .whereType<Map>()
            .where((value) => value['canAddTable'] == true)
            .length,
        lessThan(50),
      );
      expect(
        values.fold<int>(
          0,
          (total, value) => total + utf8.encode(jsonEncode(value)).length,
        ),
        lessThanOrEqualTo(64 * 1024),
      );
      expect(
        values.fold<int>(0, (total, value) => total + _nodes(value)),
        lessThanOrEqualTo(4096),
      );
      for (final value in values.whereType<Map>()) {
        expect(value.keys.toSet(), sourceStructureAuthorityWire().keys.toSet());
        expect(value['sourceSha256'], first.originalSha256);
      }
      expect(office['truncated'], true);
    },
  );

  test('missing published cell source proof closes structural authority independently of RAW', () async {
    final snapshot = oneTable();
    final table = snapshot['slides'][0]['presentationTables'][0] as Map;
    final originalCell = Map<String, dynamic>.from(table['cells'][0] as Map);
    table['rowCount'] = 2;
    table['totalCellCount'] = 2;
    table['rowHeightsHmm'] = [1200, 1200];
    table['authoredGeometry']['rowHeightsEmu'] = [432000, 432000];
    table['authoredGeometry']['extentEmu']['height'] = 864000;
    table['nativeBoundsHmm']['height'] = 2400;
    table['cells'] = [
      for (var row = 0; row < 2; row++)
        {
          ..._copy(originalCell),
          'id': 'slide-0/shape-0/cell-$row',
          'row': row,
          'text': 'k' * 4096,
          'sourceTextPatch': {
            'canReplace': true,
            'truncated': false,
            'text': 'k' * 4096,
            'utf16Length': 4096,
            'textSha256': sha256.convert(utf8.encode('k' * 4096)).toString(),
            'segments': [
              for (var index = 0; index < 4096; index++)
                {'startUtf16': index, 'endUtf16': index + 1, 'editable': true},
            ],
            'protectedRanges': <Map<String, dynamic>>[],
          },
        },
    ];
    final office = await read(snapshot);
    final owner = office['slides'][0] as Map;
    final cells = (owner['presentationTables'][0]['cells'] as List).cast<Map>();
    expect(cells.any((cell) => cell['sourceTextPatch'] == null), true);
    expect(
      (owner['sourceStructureAuthority'] as Map?)?['canAddTable'] ?? false,
      false,
    );
    expect(owner['presentationTableCount'], 1);
    expect(cells, hasLength(2));
  });

  test('regular source authority is never attached to master owners', () async {
    final snapshot = emptySnapshot();
    snapshot['masters'] = [
      {
        'id': 'master-0',
        'name': 'Master',
        'width': 280,
        'height': 157.5,
        'shapes': [],
        'presentationTables': [],
        'presentationTableCount': 0,
        'presentationTablesTruncated': false,
        'presentationTablesUnknownReason': null,
        'canAddTable': false,
      },
    ];
    final office = await read(snapshot);
    expect(office['slides'][0]['sourceStructureAuthority'], isNotNull);
    expect(
      (office['masters'][0] as Map).containsKey('sourceStructureAuthority'),
      false,
    );
  });

  test('closed source add reaches apply with every guard and numeric representation intact', () async {
    final calls = <Map<String, Object?>>[];
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          calls.add(Map<String, Object?>.from(request));
          throw const WindowsOfficeException(
            'controlled_source_add',
            'typed source add reached',
          );
        },
      ),
    );
    final operation = _operation(first.originalSha256)..['xMm'] = 0;
    await expectLater(
      service.call('office_edit', args([operation]), context: writeContext),
      _error('controlled_source_add'),
    );
    expect(calls, hasLength(1));
    expect(calls.single['operations'], [operation]);
    final forwarded = (calls.single['operations'] as List).single as Map;
    expect(forwarded['xMm'], isA<int>());
    expect(forwarded['yMm'], -0.29);
    expect((forwarded['columnWidthsMm'] as List).first, isA<int>());
    expect((forwarded['columnWidthsMm'] as List)[1], isA<double>());
    expect(calls.single['expectedSourceSha256'], first.originalSha256);
    expect(
      (await OfficeDocumentStore(controller.repository).readLatest(note))
          .revision
          .revisionId,
      first.revision.revisionId,
    );
  });

  test('malformed source add fields fail closed before the engine', () async {
    var calls = 0;
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (_) async {
          calls++;
          throw StateError('must not enter');
        },
      ),
    );
    final mutations = <Map<String, dynamic>>[
      {'extra': true},
      {'authorityVersion': 2},
      {'authorityVersion': true},
      {'id': 'slide-0/shape-0'},
      {'ownerId': ''},
      {'expectedSourcePartSha256': 'B' * 64},
      {'expectedShapeIdInventorySha256': 'bad'},
      {'sourcePart': '../slide.xml'},
      {'xMm': true},
      {'yMm': 0.001},
      {
        'columnWidthsMm': [30, true],
      },
      {'rowHeightsMm': []},
      {
        'columnWidthsMm': [500, 500.01],
      },
    ];
    final invalid = [
      for (final mutation in mutations)
        {..._operation(first.originalSha256), ...mutation},
    ];
    for (final key in _operation(first.originalSha256).keys) {
      invalid.add(_operation(first.originalSha256)..remove(key));
    }
    for (final operation in invalid) {
      await expectLater(
        service.call('office_edit', args([operation]), context: writeContext),
        _error('invalid_arguments'),
      );
    }
    expect(calls, 0);
  });

  test(
    'mixed duplicate and oversized creation batches stop before the engine',
    () async {
      var calls = 0;
      final service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (_) async {
            calls++;
            throw StateError('must not enter');
          },
        ),
      );
      final operation = _operation(first.originalSha256);
      for (final operations in <List<Map<String, dynamic>>>[
        [operation, operation],
        [
          operation,
          {'op': 'slideMove', 'id': 'slide-0', 'index': 0},
        ],
        [
          for (var index = 0; index < 101; index++)
            _operation(first.originalSha256, id: 'new-table-$index'),
        ],
      ]) {
        await expectLater(
          service.call('office_edit', args(operations), context: writeContext),
          _error('invalid_arguments'),
        );
      }
      expect(calls, 0);
    },
  );

  test('captured edition SHA mismatch is reported by the service before native execution', () async {
    var calls = 0;
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (_) async {
          calls++;
          throw StateError('must not enter');
        },
      ),
    );
    await expectLater(
      service.call(
        'office_edit',
        args([_operation('0' * 64)]),
        context: writeContext,
      ),
      _error('office_source_mismatch'),
    );
    expect(calls, 0);
    expect(
      (await OfficeDocumentStore(controller.repository).readLatest(note))
          .revision
          .revisionId,
      first.revision.revisionId,
    );
  });

  test('source create uses normal immutable edition publication and identical request replay', () async {
    var calls = 0;
    final edited = _pptx('source-created table edition');
    final candidateHash = sha256.convert(edited).toString();
    final pdf = Uint8List.fromList(
      utf8.encode('%PDF-1.7\nsource structure fixture\n%%EOF\n'),
    );
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          calls++;
          expect(request['mode'], 'apply');
          expect(
            await File(request['sourcePath'] as String).readAsBytes(),
            first.originalBytes,
          );
          final output = await File('${temp.path}/edited.pptx')
              .writeAsBytes(edited);
          final preview = await File('${temp.path}/preview.pdf')
              .writeAsBytes(pdf);
          final snapshot = structureCandidateSnapshot();
          _setHash(snapshot, candidateHash);
          return {
            'status': 'saved',
            'sessionId': request['sessionId'],
            'sourcePath': output.path,
            'pdfPath': preview.path,
            'sourceSha256': candidateHash,
            'pdfSha256': sha256.convert(pdf).toString(),
            'pdfPageCount': 1,
            'engineVersion': 'controlled source structure service fixture',
            'snapshot': snapshot,
          };
        },
      ),
    );
    final request = args([_operation(first.originalSha256)]);
    final result = await service.call(
      'office_edit',
      request,
      context: writeContext,
    ) as Map;
    final replay = await service.call(
      'office_edit',
      request,
      context: writeContext,
    ) as Map;
    expect(replay, result);
    expect(calls, 1);
    final latest = await OfficeDocumentStore(controller.repository)
        .readLatest(note);
    expect(latest.originalSha256, candidateHash);
    expect(latest.revision.revisionId, isNot(first.revision.revisionId));
    final original = await OfficeDocumentStore(controller.repository)
        .readLatest(note, revisionId: first.revision.revisionId);
    expect(original.originalBytes, first.originalBytes);
    expect(original.originalSha256, first.originalSha256);
  });

  test('permission revocation after candidate creation prevents publication of an edition', () async {
    final edited = _pptx('never published');
    final candidateHash = sha256.convert(edited).toString();
    final pdf = Uint8List.fromList(
      utf8.encode('%PDF-1.7\nnot published\n%%EOF\n'),
    );
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          final output = await File('${temp.path}/unpublished.pptx')
              .writeAsBytes(edited);
          final preview = await File('${temp.path}/unpublished.pdf')
              .writeAsBytes(pdf);
          final snapshot = structureCandidateSnapshot();
          _setHash(snapshot, candidateHash);
          writable = false;
          return {
            'status': 'saved',
            'sessionId': request['sessionId'],
            'sourcePath': output.path,
            'pdfPath': preview.path,
            'sourceSha256': candidateHash,
            'pdfSha256': sha256.convert(pdf).toString(),
            'pdfPageCount': 1,
            'engineVersion': 'controlled permission fixture',
            'snapshot': snapshot,
          };
        },
      ),
    );
    await expectLater(
      service.call(
        'office_edit',
        args([_operation(first.originalSha256)]),
        context: writeContext,
      ),
      _error('read_only'),
    );
    expect(
      (await OfficeDocumentStore(controller.repository).readLatest(note))
          .revision
          .revisionId,
      first.revision.revisionId,
    );
  });
}
