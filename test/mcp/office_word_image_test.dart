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
  late VaultNote note;
  late OfficeEdition first;
  final context = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => true,
  );
  Map<String, Object?> snapshot() => {
    'kind': 'word',
    'sourceSha256': first.originalSha256,
    'paragraphs': <Object?>[],
    'tables': <Object?>[],
    'slides': <Object?>[],
  };
  Future<Map> read(Map<String, Object?> data) async {
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async => {'snapshot': data},
      ),
    );
    final response = await service.call('read_document', {
      'noteId': note.id,
    }, context: context) as Map;
    return response['office'] as Map;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-word-images-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    note = await OfficeDocumentStore(controller.repository).importDocument(
      title: 'Word',
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

  test('MCP keeps unknown Word images distinct from known none', () async {
    final legacy = await read(snapshot());
    expect(legacy.containsKey('wordImages'), false);
    expect(legacy.containsKey('totalWordImages'), false);
    final empty = await read({...snapshot(), 'wordImages': <Object?>[]});
    expect(empty['wordImages'], isEmpty);
    expect(empty['totalWordImages'], 0);
    expect(empty['truncated'], false);
  });

  test(
    'MCP exposes exact Word image locators and explicit capabilities',
    () async {
      final office = await read({
        ...snapshot(),
        'wordImages': [
          {
            'id': 'source-image-1',
            'ownerId': 'body-1',
            'paragraphId': 'paragraph-4',
            'anchorType': 'AT_PARAGRAPH',
            'width': 30,
            'height': 20.5,
            'nativeGraphicSha256': 'b' * 64,
            'image': {'mimeType': 'image/png', 'canReplace': true},
          },
          {
            'id': 'source-image-2',
            'ownerId': 'header-1',
            'tableId': 'Table1',
            'cell': 'B2',
            'image': {'mimeType': 'image/jpeg'},
          },
        ],
      });
      final images = office['wordImages'] as List;
      expect(images[0]['id'], 'source-image-1');
      expect(images[0]['ownerId'], 'body-1');
      expect(images[0]['paragraphId'], 'paragraph-4');
      expect(images[0]['anchorType'], 'AT_PARAGRAPH');
      expect(images[0]['width'], 30.0);
      expect(images[0]['height'], 20.5);
      expect(images[0]['nativeGraphicSha256'], 'b' * 64);
      expect(images[0]['image']['canReplace'], true);
      expect(images[0].containsKey('offsetUtf16'), false);
      expect(images[1]['tableId'], 'Table1');
      expect(images[1]['cell'], 'B2');
      expect(images[1]['ownerId'], 'header-1');
      expect(images[1]['image']['canReplace'], false);
      expect(office['totalWordImages'], 2);
      expect(office['truncated'], false);
    },
  );

  test(
    'MCP omits incomplete or oversized Word image identities intact',
    () async {
      final office = await read({
        ...snapshot(),
        'wordImages': [
          {'id': 'missing-locator'},
          {'id': 'table-without-cell', 'tableId': 'Table1'},
          {'id': 'x' * 257, 'paragraphId': 'p1'},
          {'id': 'long-paragraph', 'paragraphId': 'p' * 257},
          {'id': 'long-cell', 'tableId': 'Table1', 'cell': 'A' * 257},
          {'id': 'exact-native-id', 'paragraphId': 'p1'},
        ],
      });
      final images = office['wordImages'] as List;
      expect(images.length, 1);
      expect(images.single['id'], 'exact-native-id');
      expect(images.single['paragraphId'], 'p1');
      expect(office['totalWordImages'], 6);
      expect(office['truncated'], true);
    },
  );

  test(
    'MCP bounds Word image detail metadata without inventing capability',
    () async {
      final office = await read({
        ...snapshot(),
        'wordImages': [
          {
            'id': 'image-1',
            'paragraphId': 'p1',
            'nativeGraphicSha256': 'h' * 65,
            'image': {
              'mimeType': 'm' * 129,
              'thumbnailMimeType': 't' * 129,
              'thumbnailSha256': 'h' * 65,
            },
          },
        ],
      });
      final image = (office['wordImages'] as List).single as Map;
      expect(image['id'], 'image-1');
      expect(image['paragraphId'], 'p1');
      expect(image['nativeGraphicSha256'], isNull);
      expect(image['image']['mimeType'], isNull);
      expect(image['image']['thumbnailMimeType'], isNull);
      expect(image['image']['thumbnailSha256'], isNull);
      expect(image['image']['canReplace'], false);
      expect(office['truncated'], true);
    },
  );

  test('MCP Word images share the existing 64KiB metadata budget', () async {
    final office = await read({
      ...snapshot(),
      'paragraphs': [
        for (var i = 0; i < 100; i++)
          {
            'id': '${i.toString().padLeft(4, '0')}${'p' * 252}',
            'ownerId': 'o' * 256,
            'text': '',
            'paragraphFormat': {'styleName': 's' * 128},
          },
      ],
      'wordImages': [
        for (var i = 0; i < 4; i++)
          {
            'id': '${i.toString().padLeft(4, '0')}${'i' * 252}',
            'ownerId': 'o' * 256,
            'paragraphId': 'p' * 256,
          },
      ],
    });
    final images = office['wordImages'] as List;
    expect(images.length, 2);
    var metadataBytes = 0;
    for (final paragraph in office['paragraphs'] as List) {
      for (final value in [
        paragraph['id'],
        paragraph['ownerId'],
        paragraph['paragraphFormat']['styleName'],
      ]) {
        metadataBytes += utf8.encode(value as String).length;
      }
    }
    for (final image in images) {
      for (final value in [
        image['id'],
        image['ownerId'],
        image['paragraphId'],
      ]) {
        metadataBytes += utf8.encode(value as String).length;
      }
    }
    expect(metadataBytes, 64 * 1024);
    expect(office['totalWordImages'], 4);
    expect(office['truncated'], true);
  });

  test(
    'MCP Word images share thumbnail budget with slide and master images',
    () async {
      Map<String, Object?> image() => {
        'mimeType': 'image/png',
        'canReplace': true,
        'thumbnailMimeType': 'image/png',
        'thumbnailBase64': 'A' * (256 * 1024),
      };
      Map<String, Object?> shape(int id) => {
        'id': 'shape-$id',
        'type': 'GraphicObjectShape',
        'text': '',
        'x': 0,
        'y': 0,
        'width': 20,
        'height': 20,
        'image': image(),
      };
      final office = await read({
        ...snapshot(),
        'slides': [
          {
            'id': 'slide-1',
            'width': 200,
            'height': 100,
            'shapes': [shape(1), shape(2)],
          },
        ],
        'masters': [
          {
            'id': 'master-1',
            'name': 'Master',
            'width': 200,
            'height': 100,
            'shapes': [shape(3)],
          },
        ],
        'wordImages': [
          {'id': 'image-1', 'paragraphId': 'p1', 'image': image()},
          {'id': 'image-2', 'paragraphId': 'p2', 'image': image()},
        ],
      });
      final images = office['wordImages'] as List;
      expect(images[0]['image']['thumbnailBase64'], hasLength(256 * 1024));
      expect(images[0]['image']['thumbnailTruncated'], false);
      expect(images[1]['image'].containsKey('thumbnailBase64'), false);
      expect(images[1]['image']['thumbnailTruncated'], true);
      expect(images[1]['image']['canReplace'], true);
      expect(office['totalWordImages'], 2);
      expect(office['truncated'], true);
    },
  );

  test('MCP Word image list keeps original total when capped', () async {
    final office = await read({
      ...snapshot(),
      'wordImages': [
        for (var i = 0; i < 101; i++) {'id': 'image-$i', 'paragraphId': 'p1'},
      ],
    });
    expect(office['wordImages'], hasLength(100));
    expect(office['totalWordImages'], 101);
    expect(office['truncated'], true);
  });

  test(
    'MCP keeps unknown Word image targets distinct from verified none',
    () async {
      final unknown = await read(snapshot());
      expect(unknown.containsKey('wordImageTargets'), false);
      expect(unknown.containsKey('totalWordImageTargets'), false);
      final explicitNull = await read({
        ...snapshot(),
        'wordImageTargets': null,
      });
      expect(explicitNull.containsKey('wordImageTargets'), false);
      final empty = await read({
        ...snapshot(),
        'wordImageTargets': <Object?>[],
      });
      expect(empty['wordImageTargets'], isEmpty);
      expect(empty['totalWordImageTargets'], 0);
    },
  );

  test('MCP exposes complete native targets and explicit inline image capabilities', () async {
    final office = await read({
      ...snapshot(),
      'bodyOwnerId': 'body',
      'paragraphs': [_wordParagraph('p1')],
      'wordImageTargets': [_wordTarget('p1')],
      'wordImages': [_movableWordImage('p1')],
    });
    final target = (office['wordImageTargets'] as List).single as Map;
    expect(target['ownerId'], 'body');
    expect(target['paragraphId'], 'p1');
    expect(target['canAdd'], true);
    expect(target['canMoveHere'], true);
    expect(office['totalWordImageTargets'], 1);
    final image = (office['wordImages'] as List).single as Map;
    expect(image['offsetUtf16'], 1);
    expect(image['canMove'], true);
    expect(image['canDelete'], true);
    expect(office['truncated'], false);
  });

  test('MCP preserves valid native caret style runs and complete Word image targets', () async {
    const source = 'A😀éB';
    final runs = <Map<String, Object?>>[
      {
        'startUtf16': 0,
        'endUtf16': source.length,
        'fontSize': 10,
        'color': null,
        'fontFamily': '맑은 고딕',
      },
      for (final offset in [0, 3, source.length])
        {
          'startUtf16': offset,
          'endUtf16': offset,
          'fontSize': 12,
          'italic': true,
          'color': null,
          'fontFamily': '맑은 고딕',
        },
    ];
    final office = await read({
      ...snapshot(),
      'bodyOwnerId': 'body',
      'paragraphs': [_wordParagraph('p1', text: source, runs: runs)],
      'wordImageTargets': [_wordTarget('p1')],
      'wordImages': [_movableWordImage('p1')],
    });
    final paragraph = (office['paragraphs'] as List).single as Map;
    final details = paragraph['textDetails'] as Map;
    expect(paragraph['text'], source);
    expect(
      details['textSha256'],
      sha256.convert(utf8.encode(source)).toString(),
    );
    expect(details['utf16Length'], source.length);
    expect(details['visibleUtf16Length'], source.length);
    expect(details['totalRuns'], runs.length);
    expect(details['runs'], hasLength(runs.length));
    final retained = details['runs'] as List;
    for (var i = 0; i < runs.length; i++) {
      expect(retained[i]['startUtf16'], runs[i]['startUtf16']);
      expect(retained[i]['endUtf16'], runs[i]['endUtf16']);
      expect(retained[i]['fontSize'], runs[i]['fontSize']);
      expect(retained[i]['fontFamily'], runs[i]['fontFamily']);
      expect((retained[i] as Map).containsKey('color'), true);
      expect(retained[i]['color'], isNull);
    }
    expect(retained.skip(1).every((run) => run['italic'] == true), true);
    expect(details['canReplace'], true);
    expect(details['canStyle'], true);
    expect(details['totalProtectedRanges'], 0);
    expect(details['protectedRanges'], isEmpty);
    expect(details['truncated'], false);
    final target = (office['wordImageTargets'] as List).single as Map;
    expect(target['canAdd'], true);
    expect(target['canMoveHere'], true);
    final image = (office['wordImages'] as List).single as Map;
    expect(image['canMove'], true);
    expect(image['canDelete'], true);
    expect(office['truncated'], false);
  });

  for (final caret in [-1, 2, 7]) {
    test(
      'MCP rejects invalid native caret run at UTF16 offset $caret without advertising image edits',
      () async {
        const source = 'A😀éB';
        final office = await read({
          ...snapshot(),
          'bodyOwnerId': 'body',
          'paragraphs': [
            _wordParagraph(
              'p1',
              text: source,
              runs: [
                {'startUtf16': 0, 'endUtf16': source.length, 'color': null},
                {
                  'startUtf16': caret,
                  'endUtf16': caret,
                  'italic': true,
                  'color': null,
                },
              ],
            ),
          ],
          'wordImageTargets': [_wordTarget('p1')],
          'wordImages': [_movableWordImage('p1')],
        });
        final paragraph = (office['paragraphs'] as List).single as Map;
        final details = paragraph['textDetails'] as Map;
        expect(paragraph['text'], source);
        expect(
          details['textSha256'],
          sha256.convert(utf8.encode(source)).toString(),
        );
        expect(details['totalRuns'], 2);
        expect(details['runs'], hasLength(1));
        expect((details['runs'] as List).single['startUtf16'], 0);
        expect((details['runs'] as List).single['endUtf16'], source.length);
        expect(details['truncated'], true);
        final target = (office['wordImageTargets'] as List).single as Map;
        expect(target['canAdd'], false);
        expect(target['canMoveHere'], false);
        final image = (office['wordImages'] as List).single as Map;
        expect(image['canMove'], false);
        expect(image['canDelete'], false);
        expect(office['truncated'], true);
      },
    );
  }

  test('MCP retains the native caret run total while enforcing the existing run cap', () async {
    const source = 'A😀éB';
    final office = await read({
      ...snapshot(),
      'bodyOwnerId': 'body',
      'paragraphs': [
        _wordParagraph(
          'p1',
          text: source,
          runs: [
            {'startUtf16': 0, 'endUtf16': source.length, 'color': null},
            for (var i = 0; i < 256; i++)
              {
                'startUtf16': 3,
                'endUtf16': 3,
                'fontSize': 10 + i % 3,
                'color': null,
              },
          ],
        ),
      ],
      'wordImageTargets': [_wordTarget('p1')],
      'wordImages': [_movableWordImage('p1')],
    });
    final details = (office['paragraphs'] as List).single['textDetails'] as Map;
    expect(details['totalRuns'], 257);
    expect(details['runs'], hasLength(256));
    expect(details['truncated'], true);
    final target = (office['wordImageTargets'] as List).single as Map;
    expect(target['canAdd'], false);
    expect(target['canMoveHere'], false);
    final image = (office['wordImages'] as List).single as Map;
    expect(image['canMove'], false);
    expect(image['canDelete'], false);
    expect(office['truncated'], true);
  });

  for (final unavailable in [
    'missing',
    'textTruncated',
    'nativeTruncated',
    'capped',
    'ownerMismatch',
  ]) {
    test(
      'MCP never advertises Word image editing for a $unavailable paragraph',
      () async {
        final paragraphs = switch (unavailable) {
          'missing' => <Object?>[],
          'textTruncated' => [_wordParagraph('p1', text: 'x' * 4097)],
          'nativeTruncated' => [_wordParagraph('p1', truncated: true)],
          'capped' => [
            for (var i = 0; i < 100; i++) _wordParagraph('other-$i'),
            _wordParagraph('p1'),
          ],
          'ownerMismatch' => [_wordParagraph('p1', owner: 'other-body')],
          _ => throw StateError('Unknown fixture'),
        };
        final office = await read({
          ...snapshot(),
          'bodyOwnerId': 'body',
          'paragraphs': paragraphs,
          'wordImageTargets': [_wordTarget('p1')],
          'wordImages': [_movableWordImage('p1')],
        });
        final targets = office['wordImageTargets'] as List;
        expect(
          targets.every(
            (row) => row['canAdd'] != true && row['canMoveHere'] != true,
          ),
          true,
        );
        final image = (office['wordImages'] as List).single as Map;
        expect(image['canMove'], false);
        expect(image['canDelete'], false);
      },
    );
  }

  for (final invalidOffset in [-1, 2, 7, null]) {
    test(
      'MCP disables inline image operations for invalid UTF16 offset $invalidOffset',
      () async {
        final office = await read({
          ...snapshot(),
          'bodyOwnerId': 'body',
          'paragraphs': [_wordParagraph('p1')],
          'wordImageTargets': [_wordTarget('p1')],
          'wordImages': [
            {..._movableWordImage('p1'), 'offsetUtf16': invalidOffset},
          ],
        });
        final image = (office['wordImages'] as List).single as Map;
        expect(image['canMove'], false);
        expect(image['canDelete'], false);
      },
    );
  }

  test(
    'MCP caps target rows at 100 and preserves the original count',
    () async {
      final office = await read({
        ...snapshot(),
        'bodyOwnerId': 'body',
        'paragraphs': [for (var i = 0; i < 101; i++) _wordParagraph('p$i')],
        'wordImageTargets': [for (var i = 0; i < 101; i++) _wordTarget('p$i')],
      });
      expect(office['wordImageTargets'], hasLength(100));
      expect(office['totalWordImageTargets'], 101);
      expect(office['truncated'], true);
    },
  );

  test(
    'Word target locators share the 64KiB paragraph metadata budget',
    () async {
      String id(int i) => '${i.toString().padLeft(4, '0')}${'p' * 252}';
      final office = await read({
        ...snapshot(),
        'bodyOwnerId': 'o' * 256,
        'paragraphs': [
          for (var i = 0; i < 100; i++)
            {
              ..._wordParagraph(id(i), owner: 'o' * 256, text: ''),
              'paragraphFormat': {'styleName': 's' * 128},
            },
        ],
        'wordImageTargets': [
          for (var i = 0; i < 4; i++) _wordTarget(id(i), owner: 'o' * 256),
        ],
      });
      final targets = office['wordImageTargets'] as List;
      var bytes = 0;
      for (final paragraph in office['paragraphs'] as List) {
        for (final value in [
          paragraph['id'],
          paragraph['ownerId'],
          paragraph['paragraphFormat']['styleName'],
        ]) {
          if (value is String) bytes += utf8.encode(value).length;
        }
      }
      for (final target in targets) {
        for (final value in [target['ownerId'], target['paragraphId']]) {
          if (value is String) bytes += utf8.encode(value).length;
        }
      }
      if (office['bodyOwnerId'] case final String owner)
        bytes += utf8.encode(owner).length;
      expect(bytes, lessThanOrEqualTo(64 * 1024));
      expect(targets.length, lessThan(4));
      expect(office['totalWordImageTargets'], 4);
      expect(office['truncated'], true);
    },
  );

  test('MCP passes closed Word add move delete operations and their sealed asset to the writer', () async {
    final png = Uint8List.fromList(im.encodePng(im.Image(width: 4, height: 3)));
    final assetId = newId();
    var nativeCalls = 0;
    final edited = _wordDocx('edited with inline image');
    final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nfixture\n%%EOF\n'));
    final operations = [
      {
        'op': 'wordImageAdd',
        'id': 'new-photo',
        'ownerId': 'body',
        'paragraphId': 'p1',
        'offsetUtf16': 1,
        'expectedTextSha256': 'a' * 64,
        'assetId': assetId,
        'width': 25.4,
        'height': 19.05,
      },
      {
        'op': 'wordImageMove',
        'id': 'new-photo',
        'ownerId': 'body',
        'paragraphId': 'p2',
        'offsetUtf16': 3,
        'expectedTextSha256': 'b' * 64,
      },
      {'op': 'wordImageDelete', 'id': 'new-photo'},
    ];
    final service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          nativeCalls++;
          expect(request['operations'], operations);
          final assets = request['imageAssets'] as List;
          expect(assets.single['id'], assetId);
          expect(assets.single['sha256'], sha256.convert(png).toString());
          final output = await File('${temp.path}/word-edited.docx')
              .writeAsBytes(edited);
          final preview = await File('${temp.path}/word-preview.pdf')
              .writeAsBytes(pdf);
          return {
            'status': 'saved',
            'sessionId': request['sessionId'],
            'sourcePath': output.path,
            'pdfPath': preview.path,
            'sourceSha256': sha256.convert(edited).toString(),
            'pdfSha256': sha256.convert(pdf).toString(),
            'pdfPageCount': 1,
            'engineVersion': 'word-mutation-fixture',
            'snapshot': {
              'kind': 'word',
              'sourceSha256': sha256.convert(edited).toString(),
              'paragraphs': [],
              'tables': [],
              'slides': [],
            },
          };
        },
      ),
    );
    Future<void> upload(String action, Map<String, dynamic> fields) async {
      await service.call('office_asset', {
        'action': action,
        'noteId': note.id,
        'expectedRevisionId': first.revision.revisionId,
        'requestId': action == 'begin' ? assetId : newId(),
        if (action != 'begin') 'assetId': assetId,
        ...fields,
      }, context: context);
    }

    await upload('begin', {
      'mimeType': 'image/png',
      'byteLength': png.length,
      'sha256': sha256.convert(png).toString(),
    });
    await upload('append', {'offset': 0, 'base64Data': base64Encode(png)});
    await upload('seal', {});
    final args = {
      'noteId': note.id,
      'expectedRevisionId': first.revision.revisionId,
      'requestId': newId(),
      'operations': operations,
    };
    final result =
        await service.call('office_edit', args, context: context) as Map;
    expect(await service.call('office_edit', args, context: context), result);
    expect(nativeCalls, 1);
    final current = await OfficeDocumentStore(controller.repository)
        .readLatest(note);
    expect(current.originalBytes, edited);
    expect(current.pdfBytes, pdf);
    expect(
      (await OfficeDocumentStore(
        controller.repository,
      ).readLatest(note, revisionId: first.revision.revisionId)).originalBytes,
      first.originalBytes,
    );
  });

  final move = <String, Object?>{
    'op': 'wordImageMove',
    'id': 'photo',
    'ownerId': 'body',
    'paragraphId': 'p1',
    'offsetUtf16': 1,
    'expectedTextSha256': 'a' * 64,
  };
  for (final malformed in [
    {...move, 'path': '/arbitrary'},
    {...move, 'url': 'https://example.test/image.png'},
    {...move, 'offsetUtf16': -1},
    {...move, 'offsetUtf16': true},
    {...move, 'offsetUtf16': 1.5},
    {...move, 'expectedTextSha256': 'g' * 64},
    {...move, 'ownerId': 'x' * 257},
    {
      'op': 'wordImageMove',
      'id': 'photo',
      'paragraphId': 'p1',
      'offsetUtf16': 1,
      'expectedTextSha256': 'a' * 64,
    },
    {'op': 'wordImageDelete', 'id': 'photo', 'paragraphId': 'p1'},
    for (final width in [0, -1, 1000.01, 1.001])
      {
        ...move,
        'op': 'wordImageAdd',
        'assetId': '00000000-0000-4000-8000-000000000001',
        'width': width,
        'height': 20,
      },
  ]) {
    test(
      'MCP rejects malformed closed Word operation ${jsonEncode(malformed)} before native execution',
      () async {
        var calls = 0;
        final service = VaultMcpService(
          controller,
          officeEngine: WindowsOfficeEngine(
            runner: (_) async {
              calls++;
              throw StateError('Malformed operations must not reach native');
            },
          ),
        );
        await expectLater(
          service.call('office_edit', {
            'noteId': note.id,
            'expectedRevisionId': first.revision.revisionId,
            'requestId': newId(),
            'operations': [malformed],
          }, context: context),
          throwsA(
            isA<VaultMcpException>().having(
              (error) => error.code,
              'code',
              'invalid_arguments',
            ),
          ),
        );
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
}

Map<String, Object?> _wordParagraph(
  String id, {
  String owner = 'body',
  String text = 'A😀éB',
  bool truncated = false,
  List<Map<String, Object?>> runs = const [],
}) => {
  'id': id,
  'ownerId': owner,
  'text': text,
  'textDetails': {
    'utf16Length': text.length,
    'textSha256': sha256.convert(utf8.encode(text)).toString(),
    'truncated': truncated,
    'canReplace': true,
    'canStyle': true,
    'runs': runs,
    'protectedRanges': [],
  },
};
Map<String, Object?> _wordTarget(String id, {String owner = 'body'}) => {
  'ownerId': owner,
  'paragraphId': id,
  'canAdd': true,
  'canMoveHere': true,
};
Map<String, Object?> _movableWordImage(String paragraph) => {
  'id': 'photo',
  'ownerId': 'body',
  'paragraphId': paragraph,
  'anchorType': 'AS_CHARACTER',
  'offsetUtf16': 1,
  'canMove': true,
  'canDelete': true,
  'nativeGraphicSha256': 'a' * 64,
  'width': 25.4,
  'height': 19.05,
  'image': {'mimeType': 'image/png', 'canReplace': true},
};
Uint8List _wordDocx(String text) => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
      ..addFile(
        ArchiveFile.string('word/document.xml', '<document>$text</document>'),
      ),
  ),
);
