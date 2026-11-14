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
  final layoutHash = sha256.convert(utf8.encode('layout fixture')).toString();
  Map<String, Object?> paragraph(String id, String ownerId) => {
    'id': id,
    'ownerId': ownerId,
    'text': 'SAME',
    'textDetails': {
      'utf16Length': 4,
      'textSha256': sha256.convert(utf8.encode('SAME')).toString(),
      'canReplace': true,
      'canStyle': true,
      'truncated': false,
      'runs': [],
      'protectedRanges': [],
    },
  };
  Map<String, Object?> owner(
    String id,
    String kind, {
    String styleId = 'ps0',
  }) => {
    'id': id,
    'kind': kind,
    'references': [
      {'pageStyleId': styleId, 'variant': 'default'},
      {'pageStyleId': styleId, 'variant': 'right'},
    ],
    'blocks': [
      {'kind': 'paragraph', 'id': '$id/p0'},
    ],
    'paragraphs': [paragraph('$id/p0', id)],
    'tableIds': kind == 'header' ? ['HeaderTable'] : [],
  };
  Map<String, Object?> pageStyle(String id) => {
    'id': id,
    'name': 'Standard',
    'displayName': '기본',
    'inUse': false,
    'width': 210.0,
    'height': 297.0,
    'leftMargin': 0.0,
    'rightMargin': 18.0,
    'topMargin': 20.0,
    'bottomMargin': 20.0,
    'landscape': false,
    'headerIsOn': true,
    'footerIsOn': true,
    'headerIsShared': false,
    'footerIsShared': true,
    'firstIsShared': true,
    'pageLayout': 'all',
    'layoutSha256': layoutHash,
    'regions': {
      'header': {'default': 'h0', 'left': null, 'right': 'h0', 'first': 'h0'},
      'footer': {'default': 'f0', 'left': 'f0', 'right': 'f0', 'first': 'f0'},
    },
  };
  Map<String, Object?> snapshot() => {
    'kind': 'word',
    'sourceSha256': first.originalSha256,
    'bodyOwnerId': 'body',
    'blocks': [
      {'kind': 'paragraph', 'id': 'paragraph-0'},
    ],
    'paragraphs': [paragraph('paragraph-0', 'body')],
    'tables': [
      {
        'id': 'HeaderTable',
        'ownerId': 'h0',
        'cells': {'A1': '헤더 표'},
      },
    ],
    'slides': [],
    'wordOwners': [owner('h0', 'header'), owner('f0', 'footer')],
    'pageStyles': [pageStyle('ps0')],
  };
  Future<Map> read(Map<String, Object?> data) async {
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async => {'snapshot': data},
      ),
    );
    return (await service.call('read_document', {
          'noteId': note.id,
        }, context: context) as Map)['office']
        as Map;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-word-layout-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    note = await OfficeDocumentStore(controller.repository).importDocument(
      title: 'Word owner fixture',
      fileName: 'source.docx',
      bytes: Uint8List.fromList(
        ZipEncoder().encode(
          Archive()
            ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
            ..addFile(ArchiveFile.string('word/document.xml', '<document/>')),
        ),
      ),
    );
    first = await OfficeDocumentStore(controller.repository).readLatest(note);
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
  });

  test(
    'MCP reads distinct Word owners without merging identical text',
    () async {
      final office = await read(snapshot());
      expect(office.containsKey('wordOwners'), true);
      expect(office['bodyOwnerId'], 'body');
      expect(office['paragraphs'].single['ownerId'], 'body');
      expect(office['paragraphs'].length, 1);
      expect(office['tables'].single['ownerId'], 'h0');
      final owners = office['wordOwners'] as List;
      expect(owners.map((value) => value['id']), ['h0', 'f0']);
      expect(owners.map((value) => value['paragraphs'].single['text']), [
        'SAME',
        'SAME',
      ]);
      expect(owners.first['paragraphs'].single['ownerId'], 'h0');
      expect(owners.first['references'].length, 2);
      expect(owners.first['tableIds'], ['HeaderTable']);
      final style = (office['pageStyles'] as List).single as Map;
      expect(style['leftMargin'], 0);
      expect(style['landscape'], false);
      expect(style['headerIsShared'], false);
      expect(style['inUse'], false);
      expect(style['layoutSha256'], layoutHash);
      expect(style['regions']['header']['left'], isNull);
    },
  );

  test(
    'MCP bounds Word owner and page style lists with original totals',
    () async {
      final data = snapshot();
      data['wordOwners'] = [
        for (var i = 0; i < 50; i++) owner('h$i', 'header'),
      ];
      data['pageStyles'] = [for (var i = 0; i < 50; i++) pageStyle('ps$i')];
      final office = await read(data);
      expect(office.containsKey('wordOwners'), true);
      expect((office['wordOwners'] as List).length, lessThanOrEqualTo(32));
      expect((office['pageStyles'] as List).length, lessThanOrEqualTo(32));
      expect(office['totalWordOwners'], 50);
      expect(office['totalPageStyles'], 50);
      expect(office['truncated'], true);
      expect(jsonEncode(office).length, lessThan(180000));
    },
  );

  test(
    'MCP retains an empty paragraph font run without claiming truncation',
    () async {
      final data = snapshot();
      data['paragraphs'] = [
        {
          'id': 'paragraph-0',
          'ownerId': 'body',
          'text': '',
          'textDetails': {
            'utf16Length': 0,
            'textSha256': sha256.convert(const <int>[]).toString(),
            'canReplace': true,
            'canStyle': true,
            'truncated': false,
            'runs': [
              {
                'startUtf16': 0,
                'endUtf16': 0,
                'fontSize': 14.0,
                'bold': false,
                'color': 0,
              },
            ],
            'protectedRanges': [],
          },
        },
      ];
      final office = await read(data);
      final details = office['paragraphs'].single['textDetails'] as Map;
      expect(details['runs'], hasLength(1));
      expect((details['runs'] as List).single['fontSize'], 14);
      expect(details['truncated'], false);
      expect(office['truncated'], false);
    },
  );

  test(
    'MCP applies identity limits to global tables and their owner references',
    () async {
      final data = snapshot();
      final oversized = 'table' * 20000;
      data['tables'] = [
        {
          'id': oversized,
          'ownerId': 'h0',
          'cells': {'A1': 'hidden'},
        },
        ...(data['tables'] as List),
      ];
      final office = await read(data);
      expect((office['tables'] as List).map((table) => table['id']), [
        'HeaderTable',
      ]);
      expect(office['totalTables'], 2);
      expect(office['truncated'], true);
      expect(jsonEncode(office).length, lessThan(20000));
    },
  );

  test(
    'MCP omits oversized Word identities instead of shortening them',
    () async {
      final oversized = 'x' * 100000;
      final data = snapshot();
      data['wordOwners'] = [owner(oversized, 'header'), owner('h0', 'header')];
      data['pageStyles'] = [pageStyle(oversized), pageStyle('ps0')];
      final office = await read(data);
      expect(office.containsKey('wordOwners'), true);
      expect((office['wordOwners'] as List).map((value) => value['id']), [
        'h0',
      ]);
      expect((office['pageStyles'] as List).map((value) => value['id']), [
        'ps0',
      ]);
      expect(office['totalWordOwners'], 2);
      expect(office['totalPageStyles'], 2);
      expect(office['truncated'], true);
      expect(jsonEncode(office).length, lessThan(20000));
    },
  );
}
