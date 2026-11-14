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
  var allowed = true;
  final context = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => allowed,
  );
  Uint8List docx(String text) => Uint8List.fromList(
    ZipEncoder().encode(
      Archive()
        ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
        ..addFile(
          ArchiveFile.string('word/document.xml', '<document>$text</document>'),
        ),
    ),
  );
  final hash = sha256.convert(utf8.encode('AB')).toString();
  Map<String, Object?> snapshot(String sourceHash) => {
    'kind': 'word',
    'sourceSha256': sourceHash,
    'tables': [
      {
        'id': 'Table1',
        'cells': {'A1': 'Cell'},
      },
    ],
    'slides': [],
    'paragraphs': [
      {
        'id': 'paragraph-0',
        'text': 'AB',
        'paragraphFormat': {
          'styleName': 'Heading 1',
          'alignment': 'center',
          'listKind': 'number',
          'listLevel': 1,
          'pageBreakBefore': true,
        },
        'structure': {
          'canSplit': true,
          'canDelete': false,
          'canInsertBefore': true,
          'canInsertAfter': true,
          'canJoinNext': false,
        },
      },
    ],
    'blocks': [
      {'kind': 'paragraph', 'id': 'paragraph-0'},
      {'kind': 'table', 'id': 'Table1'},
      {'kind': 'opaque', 'id': 'opaque-0'},
    ],
    'paragraphStyles': [
      {'name': 'Heading 1', 'displayName': '제목 1'},
    ],
  };
  final operations = <Map<String, Object?>>[
    {
      'op': 'paragraphSplit',
      'id': 'paragraph-0',
      'newId': 'ai-split',
      'offsetUtf16': 1,
      'expectedTextSha256': hash,
    },
    {
      'op': 'paragraphInsert',
      'id': 'ai-insert',
      'referenceId': 'ai-split',
      'position': 'after',
      'expectedTextSha256': hash,
      'text': 'new',
    },
    {
      'op': 'paragraphJoin',
      'id': 'paragraph-0',
      'nextId': 'ai-split',
      'expectedTextSha256': hash,
      'expectedNextTextSha256': hash,
    },
    {'op': 'paragraphDelete', 'id': 'ai-insert', 'expectedTextSha256': hash},
    {
      'op': 'paragraphFormat',
      'id': 'paragraph-0',
      'expectedTextSha256': hash,
      'styleName': 'Heading 1',
      'alignment': 'center',
      'listKind': 'number',
      'listLevel': 1,
      'pageBreakBefore': true,
    },
  ];
  setUp(() async {
    allowed = true;
    temp = await Directory.systemTemp.createTemp('mcp-word-structure-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    note = await OfficeDocumentStore(controller.repository).importDocument(
      title: 'Word',
      fileName: 'source.docx',
      bytes: docx('original'),
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
    'MCP exposes native body order and actual paragraph format capabilities',
    () async {
      final service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (request) async => {
            'snapshot': snapshot(first.originalSha256),
          },
        ),
      );
      final response = Map<String, dynamic>.from(
        await service.call('read_document', {
          'noteId': note.id,
        }, context: context) as Map,
      );
      final office = response['office'] as Map;
      expect(office['blocks'], snapshot(first.originalSha256)['blocks']);
      expect(
        office['paragraphStyles'],
        snapshot(first.originalSha256)['paragraphStyles'],
      );
      expect(
        office['paragraphs'].single['paragraphFormat'],
        (snapshot('')['paragraphs'] as List).single['paragraphFormat'],
      );
      expect(office['paragraphs'].single['structure']['canJoinNext'], false);
      expect(office['totalBlocks'], 3);
    },
  );
  test(
    'MCP structural operations keep exact timeline and one canonical retry',
    () async {
      var writes = 0;
      final edited = docx('edited');
      final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nfixture\n%%EOF\n'));
      final service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (request) async {
            writes++;
            expect(request['operations'], operations);
            final output = await File('${temp.path}/edited.docx')
                .writeAsBytes(edited);
            final preview = await File('${temp.path}/preview.pdf')
                .writeAsBytes(pdf);
            return {
              'status': 'saved',
              'sessionId': request['sessionId'],
              'sourcePath': output.path,
              'pdfPath': preview.path,
              'sourceSha256': sha256.convert(edited).toString(),
              'pdfSha256': sha256.convert(pdf).toString(),
              'pdfPageCount': 1,
              'engineVersion': 'synthetic-word-contract',
              'snapshot': snapshot(sha256.convert(edited).toString()),
            };
          },
        ),
      );
      final args = {
        'noteId': note.id,
        'expectedRevisionId': first.revision.revisionId,
        'requestId': newId(),
        'operations': operations,
      };
      final saved = await service.call('office_edit', args, context: context);
      expect(await service.call('office_edit', args, context: context), saved);
      expect(writes, 1);
      expect(
        (await OfficeDocumentStore(controller.repository).readLatest(note))
            .originalBytes,
        edited,
      );
      expect(
        (await OfficeDocumentStore(controller.repository).readLatest(
          note,
          revisionId: first.revision.revisionId,
        )).originalBytes,
        first.originalBytes,
      );
      allowed = false;
      await expectLater(
        service.call('office_edit', {
          ...args,
          'requestId': newId(),
        }, context: context),
        throwsA(
          isA<VaultMcpException>().having((e) => e.code, 'code', 'read_only'),
        ),
      );
      expect(writes, 1);
    },
  );

  test(
    'MCP bounds paragraph metadata without inventing shortened identities',
    () async {
      final huge = 'x' * 100000;
      final data = snapshot(first.originalSha256);
      data['paragraphStyles'] = [
        {'name': huge, 'displayName': 'oversized name'},
        {'name': 'normal', 'displayName': huge},
        {'name': 'valid', 'displayName': 'Valid'},
      ];
      data['blocks'] = [
        {'kind': 'paragraph', 'id': 'paragraph-0'},
        {'kind': 'table', 'id': huge},
        {'kind': 'opaque', 'id': 'after-hidden'},
      ];
      ((data['paragraphs'] as List).single as Map)['paragraphFormat'] = {
        'styleName': huge,
        'alignment': huge,
        'listKind': huge,
        'listLevel': 0,
        'pageBreakBefore': false,
      };
      final service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (request) async => {'snapshot': data},
        ),
      );
      final result = Map<String, dynamic>.from(
        await service.call('read_document', {
          'noteId': note.id,
        }, context: context) as Map,
      );
      final office = result['office'] as Map;
      expect(office['truncated'], true);
      expect(office['paragraphStyles'], [
        {'name': 'valid', 'displayName': 'Valid'},
      ]);
      expect(office['blocks'], [
        {'kind': 'paragraph', 'id': 'paragraph-0'},
      ]);
      expect(office['totalBlocks'], 3);
      expect(office['totalParagraphStyles'], 3);
      expect(
        office['paragraphs'].single['paragraphFormat']['styleName'],
        isNull,
      );
      expect(jsonEncode(office).length, lessThan(12000));
    },
  );
  test('MCP rejects malformed structural arguments before invoking document engine', () async {
    var calls = 0;
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          calls++;
          throw StateError('must not run');
        },
      ),
    );
    for (final invalid in [
      {...operations[0], 'offsetUtf16': -1},
      {...operations[0], 'expectedTextSha256': 'bad'},
      {...operations[1], 'position': 'inside'},
      {...operations[1], 'text': 'a\nb'},
      {...operations[4], 'alignment': 'diagonal'},
      {...operations[4], 'listKind': 'script'},
      {...operations[4], 'listLevel': 9},
      {...operations[4], 'pageBreakBefore': 'yes'},
      {...operations[3], 'path': 'outside'},
      {
        'op': 'paragraphFormat',
        'id': 'paragraph-0',
        'expectedTextSha256': hash,
        'alignment': null,
      },
    ]) {
      await expectLater(
        service.call('office_edit', {
          'noteId': note.id,
          'expectedRevisionId': first.revision.revisionId,
          'requestId': newId(),
          'operations': [invalid],
        }, context: context),
        throwsA(
          isA<VaultMcpException>().having(
            (e) => e.code,
            'code',
            'invalid_arguments',
          ),
        ),
      );
    }
    expect(calls, 0);
  });
}
