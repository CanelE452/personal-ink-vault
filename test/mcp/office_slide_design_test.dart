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
  Uint8List pptx(String text) => Uint8List.fromList(
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
  Map<String, Object?> shape(String owner) => {
    'id': '$owner/shape-0',
    'type': 'com.sun.star.drawing.TextShape',
    'shapeKind': 'text',
    'text': 'A',
    'editableText': true,
    'ownerKind': owner.startsWith('master-') ? 'master' : 'slide',
    'ownerId': owner,
    'presentationObject': false,
    'emptyPresentationObject': false,
    'canEditGeometry': true,
    'canDelete': true,
    'canEditTextStyle': true,
    'x': 10,
    'y': 10,
    'width': 80,
    'height': 20,
  };
  Map<String, Object?> snapshot(String hash) => {
    'kind': 'presentation',
    'sourceSha256': hash,
    'paragraphs': [],
    'tables': [],
    'layoutOptions': [
      {'code': 0, 'label': 'Title'},
      {'code': 20, 'label': 'Blank'},
    ],
    'masters': [
      {
        'id': 'master-0',
        'name': 'Common design',
        'width': 280,
        'height': 157.5,
        'backgroundStyle': 'solid',
        'backgroundColor': 0xfff6e0,
        'shapes': [shape('master-0')],
      },
    ],
    'slides': [
      {
        'id': 'slide-0',
        'width': 280,
        'height': 157.5,
        'masterId': 'master-0',
        'layoutCode': 0,
        'designSha256': 'b' * 64,
        'visible': false,
        'showMasterObjects': false,
        'shapes': [shape('slide-0')],
      },
    ],
  };
  final operations = <Map<String, Object?>>[
    {'op': 'shapeText', 'id': 'master-0/shape-0', 'text': 'Brand'},
    {
      'op': 'slideDesign',
      'id': 'slide-0',
      'changeId': 'design-1',
      'expectedDesignSha256': 'b' * 64,
      'masterId': 'master-0',
      'layoutCode': 0,
    },
    {
      'op': 'slideDisplay',
      'id': 'slide-0',
      'visible': false,
      'showMasterObjects': false,
    },
  ];
  setUp(() async {
    allowed = true;
    temp = await Directory.systemTemp.createTemp('mcp-slide-design-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    note = await OfficeDocumentStore(controller.repository).importDocument(
      title: 'Slides',
      fileName: 'source.pptx',
      bytes: pptx('original'),
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
    'MCP reads actual common-design owners and preserves zero and false',
    () async {
      final service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (_) async => {'snapshot': snapshot(first.originalSha256)},
        ),
      );
      final response = await service.call('read_document', {
        'noteId': note.id,
      }, context: context) as Map;
      final office = response['office'] as Map;
      expect(office['masters'], isA<List>());
      expect((office['masters'] as List).single['id'], 'master-0');
      expect(
        (office['masters'] as List).single['shapes'].single['ownerKind'],
        'master',
      );
      expect(office['slides'].single['masterId'], 'master-0');
      expect(office['slides'].single['layoutCode'], 0);
      expect(office['slides'].single['visible'], false);
      expect(office['slides'].single['showMasterObjects'], false);
      expect(office['layoutOptions'], snapshot('')['layoutOptions']);
      expect(office['totalMasters'], 1);
    },
  );
  test(
    'MCP design edits use the same ordered canonical write and retry',
    () async {
      var writes = 0;
      final edited = pptx('edited');
      final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nfixture\n%%EOF\n'));
      final service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (request) async {
            writes++;
            expect(request['operations'], operations);
            final output = await File('${temp.path}/edited.pptx')
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
              'engineVersion': 'synthetic-slide-contract',
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
    'MCP bounds common-design metadata without shortening identities',
    () async {
      final data = snapshot(first.originalSha256);
      final huge = 'x' * 100000;
      data['masters'] = List.generate(
        30,
        (index) => {
          'id': index == 1 ? huge : 'master-$index',
          'name': index == 0 ? huge : 'Common $index',
          'width': 280,
          'height': 157.5,
          'shapes': [shape('master-$index')],
        },
      );
      final service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (_) async => {'snapshot': data},
        ),
      );
      final response = await service.call('read_document', {
        'noteId': note.id,
      }, context: context) as Map;
      final office = response['office'] as Map;
      final masters = office['masters'] as List;
      expect(office['totalMasters'], 30);
      expect(office['truncated'], true);
      expect(masters.length, 19);
      expect(masters.first['id'], 'master-0');
      expect(masters.first['name'], null);
      expect(
        masters.any(
          (dynamic master) =>
              master['id'] == huge || master['id'] == huge.substring(0, 256),
        ),
        false,
      );
      expect(jsonEncode(office).length, lessThan(40000));
    },
  );
  test(
    'MCP rejects unsafe or empty design arguments before the native engine',
    () async {
      var calls = 0;
      final service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (_) async {
            calls++;
            throw StateError('must not run');
          },
        ),
      );
      for (final invalid in [
        {...operations[1], 'expectedDesignSha256': 'bad'},
        {...operations[1], 'layoutCode': 2},
        {...operations[1], 'layoutCode': false},
        {...operations[1], 'changeId': 'x' * 129},
        {...operations[1], 'path': 'outside'},
        {
          'op': 'slideDesign',
          'id': 'slide-0',
          'changeId': 'design-1',
          'expectedDesignSha256': 'b' * 64,
          'masterId': null,
        },
        {'op': 'slideDisplay', 'id': 'slide-0'},
        {'op': 'slideDisplay', 'id': 'slide-0', 'visible': null},
        {'op': 'slideDisplay', 'id': 'slide-0', 'visible': 'false'},
        {'op': 'slideDisplay', 'id': 'slide-0', 'showMasterBackground': false},
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
    },
  );
}
