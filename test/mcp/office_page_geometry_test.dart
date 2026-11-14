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
  Map<String, Object?> snapshot(String hash, {bool? capability = true}) => {
    'kind': 'word',
    'sourceSha256': hash,
    'bodyOwnerId': 'body',
    'paragraphs': [
      {'id': 'paragraph-0', 'ownerId': 'body', 'text': 'BODY'},
    ],
    'blocks': [
      {'kind': 'paragraph', 'id': 'paragraph-0'},
    ],
    'tables': [],
    'slides': [],
    'wordOwners': [],
    'pageStyles': [
      {
        'id': 'page-0',
        'name': 'ImportedPage',
        'displayName': '보고서',
        'inUse': true,
        'canEditGeometry': ?capability,
        'width': 210.01,
        'height': 297,
        'landscape': false,
        'leftMargin': 0,
        'rightMargin': 17.99,
        'topMargin': 20,
        'bottomMargin': 21.01,
        'layoutSha256': 'b' * 64,
        'regions': {'header': {}, 'footer': {}},
      },
    ],
  };
  Map<String, Object?> geometry() => {
    'op': 'pageGeometry',
    'id': 'page-0',
    'expectedLayoutSha256': 'b' * 64,
    'width': 297.0,
    'height': 210.01,
    'landscape': true,
    'leftMargin': 25.4,
    'rightMargin': 18.0,
  };
  Map<String, Object?> arguments(List<Map<String, Object?>> operations) => {
    'noteId': note.id,
    'expectedRevisionId': first.revision.revisionId,
    'requestId': newId(),
    'operations': operations,
  };
  setUp(() async {
    allowed = true;
    temp = await Directory.systemTemp.createTemp('mcp-page-geometry-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    note = await OfficeDocumentStore(controller.repository).importDocument(
      title: 'Page geometry contract',
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
  for (final capability in <bool?>[true, false, null]) {
    test(
      'MCP preserves explicit page geometry capability $capability',
      () async {
        final service = VaultMcpService(
          controller,
          officeEngine: WindowsOfficeEngine(
            runner: (_) async => {
              'snapshot': snapshot(
                first.originalSha256,
                capability: capability,
              ),
            },
          ),
        );
        final response = await service.call('read_document', {
          'noteId': note.id,
        }, context: context) as Map;
        final page = response['office']['pageStyles'].single as Map;
        expect(page.containsKey('canEditGeometry'), true);
        expect(page['canEditGeometry'], capability);
        expect(page['leftMargin'], 0);
        expect(page['landscape'], false);
        expect(page['layoutSha256'], 'b' * 64);
      },
    );
  }
  test('MCP page geometry preserves order source binding one revision and exact retry', () async {
    var calls = 0;
    final operations = <Map<String, Object?>>[
      {'op': 'paragraphText', 'id': 'paragraph-0', 'text': 'EDITED'},
      geometry(),
    ];
    final edited = docx('edited');
    final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nfixture\n%%EOF\n'));
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          calls++;
          expect(request['expectedSourceSha256'], first.originalSha256);
          expect(request['operations'], operations);
          final original = await File('${temp.path}/edited.docx')
              .writeAsBytes(edited);
          final preview = await File('${temp.path}/preview.pdf')
              .writeAsBytes(pdf);
          final hash = sha256.convert(edited).toString();
          return {
            'status': 'saved',
            'sessionId': request['sessionId'],
            'sourcePath': original.path,
            'pdfPath': preview.path,
            'sourceSha256': hash,
            'pdfSha256': sha256.convert(pdf).toString(),
            'pdfPageCount': 2,
            'engineVersion': 'synthetic-page-geometry-contract',
            'snapshot': snapshot(hash),
          };
        },
      ),
    );
    final args = arguments(operations);
    final saved = await service.call('office_edit', args, context: context);
    expect(await service.call('office_edit', args, context: context), saved);
    expect(calls, 1);
    final store = OfficeDocumentStore(controller.repository);
    final latest = await store.readLatest(note);
    expect(latest.originalBytes, edited);
    expect(latest.pdfBytes, pdf);
    expect(
      (await store.readLatest(
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
    expect(calls, 1);
  });
  test(
    'MCP rejects malformed geometry before calling the document engine',
    () async {
      var calls = 0;
      final service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (_) async {
            calls++;
            throw StateError('Malformed geometry reached the document engine');
          },
        ),
      );
      final base = geometry();
      final invalid = <Map<String, Object?>>[
        {...base, 'expectedLayoutSha256': 'not-a-hash'},
        {...base, 'id': 'x' * 257},
        {...base, 'width': true},
        {...base, 'width': null},
        {...base, 'width': 0},
        {...base, 'width': -1},
        {...base, 'width': 1000.01},
        {...base, 'landscape': false},
        {...base, 'width': 210.01},
        {...base, 'leftMargin': -1},
        {...base, 'leftMargin': 1.001},
        {...base, 'leftMargin': double.nan},
        {...base, 'leftMargin': double.infinity},
        {...base, 'leftMargin': 250, 'rightMargin': 250},
        {...base, 'headerIsOn': false},
        {...base, 'headerIsShared': true},
        {...base, 'firstIsShared': false},
        {...base, 'pageLayout': 'ALL'},
        {
          'op': 'pageGeometry',
          'id': 'page-0',
          'expectedLayoutSha256': 'b' * 64,
        },
        {
          'op': 'pageGeometry',
          'id': 'page-0',
          'expectedLayoutSha256': 'b' * 64,
          'landscape': true,
        },
        {
          'op': 'pageGeometry',
          'id': 'page-0',
          'expectedLayoutSha256': 'b' * 64,
          'width': null,
          'leftMargin': 0,
        },
      ];
      for (final operation in invalid) {
        await expectLater(
          service.call('office_edit', arguments([operation]), context: context),
          throwsA(
            isA<VaultMcpException>().having(
              (e) => e.code,
              'code',
              'invalid_arguments',
            ),
          ),
          reason: 'Malformed geometry: ${operation.keys.join(',')}',
        );
      }
      expect(calls, 0);
      expect(
        (await OfficeDocumentStore(controller.repository).readLatest(note))
            .revision
            .revisionId,
        first.revision.revisionId,
      );
    },
  );
}
