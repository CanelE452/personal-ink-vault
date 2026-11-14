import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
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
  late VaultMcpService service;
  late VaultNote note;
  late OfficeEdition first;
  late Uint8List png;
  var writesAllowed = true;
  final context = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => writesAllowed,
  );

  Uint8List ppt(String text) => Uint8List.fromList(
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

  Future<Map<String, dynamic>> call(
    String operation,
    Map<String, dynamic> args,
  ) async => Map<String, dynamic>.from(
    await service.call(operation, args, context: context) as Map,
  );
  Future<Map<String, dynamic>> asset(
    String action,
    String id, {
    Map<String, dynamic> fields = const {},
  }) => call('office_asset', {
    'action': action,
    'noteId': note.id,
    'expectedRevisionId': first.revision.revisionId,
    'requestId': action == 'begin' ? id : newId(),
    if (action != 'begin') 'assetId': id,
    ...fields,
  });

  setUp(() async {
    writesAllowed = true;
    temp = await Directory.systemTemp.createTemp('mcp-office-rich-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    service = VaultMcpService(controller);
    note = await OfficeDocumentStore(controller.repository).importDocument(
      title: '슬라이드',
      fileName: 'source.pptx',
      bytes: ppt('original'),
    );
    first = await OfficeDocumentStore(controller.repository).readLatest(note);
    png = Uint8List.fromList(im.encodePng(im.Image(width: 4, height: 3)));
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
  });

  test(
    'MCP stages chunked images and retries without modifying canonical source',
    () async {
      final id = newId();
      final start = await asset(
        'begin',
        id,
        fields: {
          'mimeType': 'image/png',
          'byteLength': png.length,
          'sha256': sha256.convert(png).toString(),
        },
      );
      expect(start['assetId'], id);
      expect(start['receivedBytes'], 0);
      final fields = {'offset': 0, 'base64Data': base64Encode(png)};
      final sent = await asset('append', id, fields: fields);
      final retry = await asset('append', id, fields: fields);
      expect(retry, sent);
      expect((await asset('seal', id))['state'], 'sealed');
      expect((await asset('status', id))['receivedBytes'], png.length);
      expect(
        (await OfficeDocumentStore(controller.repository).readLatest(note))
            .revision
            .revisionId,
        first.revision.revisionId,
      );
      writesAllowed = false;
      await expectLater(
        asset('discard', id),
        throwsA(
          isA<VaultMcpException>().having((e) => e.code, 'code', 'read_only'),
        ),
      );
      writesAllowed = true;
      await asset('discard', id);
      await expectLater(
        asset('status', id),
        throwsA(
          isA<VaultMcpException>().having(
            (e) => e.code,
            'code',
            'asset_not_found',
          ),
        ),
      );
    },
  );

  test('MCP passes sealed owned asset and selected text edits through the app writer', () async {
    final id = newId();
    await asset(
      'begin',
      id,
      fields: {
        'mimeType': 'image/png',
        'byteLength': png.length,
        'sha256': sha256.convert(png).toString(),
      },
    );
    await asset(
      'append',
      id,
      fields: {'offset': 0, 'base64Data': base64Encode(png)},
    );
    await asset('seal', id);
    var writes = 0;
    final edited = ppt('new embedded image');
    final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nfixture\n%%EOF\n'));
    service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          writes++;
          expect(request['operations'], [
            {
              'op': 'textStyle',
              'targetKind': 'shape',
              'id': 'slide-0/shape-0',
              'startUtf16': 1,
              'endUtf16': 3,
              'expectedTextSha256': 'a' * 64,
              'italic': true,
            },
            {
              'op': 'imageAdd',
              'id': 'ai-image',
              'slideId': 'slide-0',
              'assetId': id,
              'x': 10.0,
              'y': 20.0,
              'width': 30.0,
              'height': 40.0,
            },
          ]);
          final assets = request['imageAssets'] as List;
          expect(assets.single['id'], id);
          expect(assets.single['sha256'], sha256.convert(png).toString());
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
            'engineVersion': 'rich-contract',
            'snapshot': {
              'kind': 'presentation',
              'sourceSha256': sha256.convert(edited).toString(),
              'paragraphs': [],
              'tables': [],
              'slides': [],
            },
          };
        },
      ),
    );
    final args = {
      'noteId': note.id,
      'expectedRevisionId': first.revision.revisionId,
      'requestId': newId(),
      'operations': [
        {
          'op': 'textStyle',
          'targetKind': 'shape',
          'id': 'slide-0/shape-0',
          'startUtf16': 1,
          'endUtf16': 3,
          'expectedTextSha256': 'a' * 64,
          'italic': true,
        },
        {
          'op': 'imageAdd',
          'id': 'ai-image',
          'slideId': 'slide-0',
          'assetId': id,
          'x': 10,
          'y': 20,
          'width': 30,
          'height': 40,
        },
      ],
    };
    final result = await call('office_edit', args);
    expect(await call('office_edit', args), result);
    expect(writes, 1);
    final latest = await OfficeDocumentStore(controller.repository)
        .readLatest(note);
    expect(latest.originalBytes, edited);
    expect(
      (await OfficeDocumentStore(
        controller.repository,
      ).readLatest(note, revisionId: first.revision.revisionId)).originalBytes,
      first.originalBytes,
    );
  });

  test(
    'MCP snapshot distinguishes visible UTF16 prefix from full text and hash',
    () async {
      final fullText = '${'x' * 4095}😀${'z' * 5000}';
      final hash = sha256.convert(utf8.encode(fullText)).toString();
      service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (request) async {
            return {
              'snapshot': {
                'kind': 'word',
                'sourceSha256': first.originalSha256,
                'paragraphs': [
                  {
                    'id': 'paragraph-0',
                    'text': fullText,
                    'textDetails': {
                      'utf16Length': fullText.length,
                      'textSha256': hash,
                      'canReplace': true,
                      'canStyle': true,
                      'runs': [
                        {
                          'startUtf16': 0,
                          'endUtf16': fullText.length,
                          'bold': true,
                        },
                      ],
                      'protectedRanges': [],
                    },
                  },
                ],
                'tables': [],
                'slides': [],
              },
            };
          },
        ),
      );
      final response = await call('read_document', {'noteId': note.id});
      final paragraph = response['office']['paragraphs'].single;
      expect(paragraph['text'], 'x' * 4095);
      expect(paragraph['textDetails']['textSha256'], hash);
      expect(paragraph['textDetails']['utf16Length'], fullText.length);
      expect(paragraph['textDetails']['visibleUtf16Length'], 4095);
      expect(paragraph['textDetails']['truncated'], true);
      expect(paragraph['textDetails']['runs'].single['endUtf16'], 4095);
      expect(response['office']['truncated'], true);
    },
  );
}
