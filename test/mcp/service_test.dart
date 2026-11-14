import 'dart:async';
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
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late WorkspaceController controller;
  late VaultMcpService service;
  final context = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => true,
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-service-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    service = VaultMcpService(controller);
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
  });
  Future<Map<String, dynamic>> call(
    String operation,
    Map<String, dynamic> arguments,
  ) async => Map<String, dynamic>.from(
    await service.call(operation, arguments, context: context) as Map,
  );

  test('MCP search finds block, canvas and database row text while preserving scope and pagination', () async {
    final folder = await controller.library.createFolder('연구');
    final database = WorkspaceDatabase.empty();
    final title = database.properties.single.id;
    final body = const BlockPageDocument.empty()
        .copyWith(
          blocks: [BlockPageBlock.create(type: 'paragraph', text: '본문 검색표식')],
        )
        .toJson();
    final fixtures = <(String, Map<String, dynamic>)>[
      ('page', body),
      (
        'canvas',
        const CardCanvasDocument.empty()
            .copyWith(
              nodes: [CardCanvasNode.text(id: 'card-search', text: '검색표식 캔버스')],
            )
            .toJson(),
      ),
      (
        'database',
        database
            .addRow(
              DatabaseRow.fromJson({
                ...DatabaseRow.create(values: {title: '검색표식 셀'}).toJson(),
                'body': body,
              }),
            )
            .toJson(),
      ),
    ];
    final ids = <String>[];
    for (final (kind, contents) in fixtures) {
      ids.add(
        (await call('create_document', {
              'title': kind,
              'kind': kind,
              'body': contents,
              'folderId': folder.id,
              'requestId': newId(),
            }))['noteId']
            as String,
      );
    }
    final rootOnly = await call('create_document', {
      'title': '루트',
      'kind': 'page',
      'body': body,
      'requestId': newId(),
    });
    final all = await call('list_documents', {
      'query': '검색표식',
      'folderId': folder.id,
    });
    expect(all['total'], 3);
    expect(
      (all['documents'] as List).map((item) => item['noteId']),
      unorderedEquals(ids),
    );
    final page = await call('list_documents', {
      'query': '검색표식',
      'folderId': folder.id,
      'offset': 1,
      'limit': 1,
    });
    expect(page['total'], 3);
    expect(page['documents'], [(all['documents'] as List)[1]]);
    expect(
      (await call('list_documents', {
        'query': '검색표식',
        'folderId': null,
      }))['documents'].map((item) => item['noteId']),
      [rootOnly['noteId']],
    );
    expect((await call('list_documents', {'query': '검색표식 셀'}))['total'], 1);
    expect((await call('list_documents', {'query': '본문 검색표식'}))['total'], 3);
    await call('document_action', {
      'noteId': ids.first,
      'action': 'trash',
      'expectedRevisionId': (all['documents'] as List).firstWhere(
        (item) => item['noteId'] == ids.first,
      )['metadataRevisionId'],
      'requestId': newId(),
    });
    expect(
      (await call('list_documents', {
        'query': '검색표식',
        'folderId': folder.id,
      }))['total'],
      2,
    );
    expect(
      (await call('list_documents', {
        'query': '검색표식',
        'folderId': folder.id,
        'includeDeleted': true,
      }))['total'],
      3,
    );
  });

  test('read-only MCP status exposes the current automation pass without creating revisions', () async {
    final runner = controller.createAutomationCoordinator(
      actionRuntime: DatabaseActionRuntime(
        deviceId: controller.repository.deviceId,
        invoke: (_) => throw StateError('No database requires an engine call'),
      ),
    );
    final pass = await runner.runOnce(
      capturedAtUtcMs: DateTime.utc(2026, 10, 30).millisecondsSinceEpoch,
    );
    final result = await service.call(
      'vault_status',
      {},
      context: VaultMcpCallContext(isActive: () => true, canWrite: () => false),
    ) as Map;
    expect(result['automation'], pass.toJson());
    expect(result['writeEnabled'], false);
    expect(await controller.repository.revisions(), isEmpty);
  });

  for (final (kind, extension, part) in [
    ('word', '.docx', 'word/document.xml'),
    ('presentation', '.pptx', 'ppt/slides/slide1.xml'),
    ('hwpx', '.hwpx', 'Contents/section0.xml'),
  ]) {
    test(
      'MCP creates a real $kind original and retry after service recreation reuses it',
      () async {
        final args = <String, dynamic>{
          'title': '연구 & 발표',
          'kind': kind,
          'requestId': newId(),
        };
        final created = await call('create_document', args);
        final note = (await WorkspaceStore(
          controller.repository,
        ).list()).single;
        expect(created['noteId'], note.id);
        expect(created['kind'], 'office');
        final edition = await OfficeDocumentStore(controller.repository)
            .readLatest(note);
        expect(edition.originalFileName, endsWith(extension));
        expect(
          ZipDecoder().decodeBytes(edition.originalBytes).findFile(part),
          isNotNull,
        );
        expect(created['sourceRevisionId'], edition.revision.revisionId);
        final before = (await controller.repository.revisions()).length;
        service = VaultMcpService(controller);
        expect(await call('create_document', args), created);
        expect(
          (await WorkspaceStore(controller.repository).list()),
          hasLength(1),
        );
        expect((await controller.repository.revisions()).length, before);
      },
    );

    test(
      'MCP $kind rejects a silently discarded body before publishing anything',
      () async {
        await expectLater(
          call('create_document', {
            'title': 'Invalid',
            'kind': kind,
            'body': 'Keep my content',
            'requestId': newId(),
          }),
          throwsA(
            isA<VaultMcpException>().having(
              (error) => error.code,
              'code',
              'invalid_arguments',
            ),
          ),
        );
        expect(await controller.repository.revisions(), isEmpty);
      },
    );
  }

  test(
    'MCP creates a valid empty database without a hand-written body',
    () async {
      final created = await call('create_document', {
        'title': 'Tasks',
        'kind': 'database',
        'requestId': newId(),
      });
      final read = await call('read_document', {'noteId': created['noteId']});
      final database = WorkspaceDatabase.fromJson(
        Map<String, dynamic>.from(read['body']['content'] as Map),
      );
      expect(database.properties.single.type, 'title');
      expect(database.views.single.type, 'table');
      expect(database.rows, isEmpty);
    },
  );

  test(
    'MCP preserves the database identity used by other documents relations',
    () async {
      final created = await call('create_document', {
        'title': 'Tasks',
        'kind': 'database',
        'requestId': newId(),
      });
      final read = await call('read_document', {'noteId': created['noteId']});
      final body = Map<String, dynamic>.from(read['body']['content'] as Map);
      final revision = read['body']['revisionId'];
      await expectLater(
        call('update_document', {
          'noteId': created['noteId'],
          'target': 'body',
          'content': {...body, 'id': newId()},
          'expectedRevisionId': revision,
          'requestId': newId(),
        }),
        throwsA(
          isA<VaultMcpException>().having(
            (e) => e.code,
            'code',
            'identity_changed',
          ),
        ),
      );
      final unchanged = await call('read_document', {
        'noteId': created['noteId'],
      });
      expect(unchanged['body']['content'], body);
      expect(unchanged['body']['revisionId'], revision);
    },
  );

  test('MCP reads and updates the same board.canvas body used by the visible workspace', () async {
    final note = await controller.createNote(
      '보드',
      documentKind: VaultDocumentKind.canvas,
    );
    await controller.flush();
    final read = await call('read_document', {'noteId': note.id});
    expect(read['body']['content'], {'nodes': [], 'edges': []});
    await call('update_document', {
      'noteId': note.id,
      'target': 'body',
      'content': {
        'nodes': [
          {
            'id': 'card-1',
            'type': 'text',
            'x': 0,
            'y': 0,
            'width': 280,
            'height': 180,
            'text': 'MCP 카드',
          },
        ],
        'edges': [],
      },
      'expectedRevisionId': read['body']['revisionId'],
      'requestId': newId(),
    });
    final loaded = await controller.loadCardCanvas(
      session: controller.activeSession!,
    );
    expect(loaded.nodes.single.text, 'MCP 카드');
    final head = (await controller.repository.heads(note.inkEntityId)).single;
    expect(head.blobs.keys, ['board.canvas']);
  });

  test(
    'MCP PPT authoring reads appearance and publishes typed object edits once',
    () async {
      Uint8List presentation(String content) => Uint8List.fromList(
        ZipEncoder().encode(
          Archive()
            ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
            ..addFile(ArchiveFile.string('ppt/presentation.xml', content)),
        ),
      );
      final original = presentation('original');
      final edited = presentation('edited');
      final pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nfixture\n%%EOF\n'));
      final store = OfficeDocumentStore(controller.repository);
      final note = await store.importDocument(
        title: 'LLM 도형 편집',
        fileName: 'source.pptx',
        bytes: original,
      );
      final first = await store.readLatest(note);
      final operations = [
        {
          'op': 'shapeAdd',
          'id': 'llm-line',
          'slideId': 'slide-0',
          'shapeKind': 'line',
          'x': 10.0,
          'y': 20.0,
          'width': 60.0,
          'height': 0.0,
          'text': '',
        },
        for (final kind in ['roundedRectangle', 'rightArrow'])
          {
            'op': 'shapeAdd',
            'id': 'llm-$kind',
            'slideId': 'slide-0',
            'shapeKind': kind,
            'x': 30.0,
            'y': 36.0,
            'width': 55.0,
            'height': 18.0,
            'text': '도형 글자',
          },
        {
          'op': 'shapeAppearance',
          'id': 'llm-line',
          'lineStyle': 'solid',
          'lineColor': 0x112233,
          'lineWidth': .5,
        },
        {'op': 'shapeDelete', 'id': 'slide-0/shape-0'},
        {
          'op': 'slideBackground',
          'id': 'slide-0',
          'fillStyle': 'solid',
          'fillColor': 0xf0e0d0,
        },
      ];
      Map<String, dynamic> snapshot(String hash) => {
        'kind': 'presentation',
        'sourceSha256': hash,
        'paragraphs': [],
        'tables': [],
        'slides': [
          {
            'id': 'slide-0',
            'width': 280,
            'height': 157.5,
            'backgroundStyle': 'solid',
            'backgroundColor': 0xf0e0d0,
            'shapes': [
              {
                'id': 'slide-0/shape-0',
                'type': 'LineShape',
                'shapeKind': 'line',
                'text': '',
                'editableText': false,
                'x': 10,
                'y': 20,
                'width': 60,
                'height': 0,
                'canEditFill': false,
                'canEditLine': true,
                'fillStyle': null,
                'fillColor': null,
                'lineStyle': 'solid',
                'lineColor': 0x112233,
                'lineWidth': .5,
              },
              for (final (index, kind) in [
                'roundedRectangle',
                'rightArrow',
              ].indexed)
                {
                  'id': 'slide-0/shape-${index + 1}',
                  'type': 'com.sun.star.drawing.CustomShape',
                  'shapeKind': kind,
                  'text': '도형 글자',
                  'editableText': true,
                  'x': 30,
                  'y': 36,
                  'width': 55,
                  'height': 18,
                  'canEditFill': true,
                  'canEditLine': true,
                },
            ],
          },
        ],
      };
      var edits = 0;
      service = VaultMcpService(
        controller,
        officeEngine: WindowsOfficeEngine(
          runner: (request) async {
            final hash = sha256
                .convert(
                  await File(request['sourcePath'] as String).readAsBytes(),
                )
                .toString();
            if (request['mode'] == 'inspect')
              return {'snapshot': snapshot(hash)};
            edits++;
            expect(request['operations'], operations);
            return {
              'status': 'saved',
              'sessionId': request['sessionId'],
              'sourcePath': (await File(
                '${temp.path}/edited.pptx',
              ).writeAsBytes(edited)).path,
              'pdfPath': (await File(
                '${temp.path}/preview.pdf',
              ).writeAsBytes(pdf)).path,
              'sourceSha256': sha256.convert(edited).toString(),
              'pdfSha256': sha256.convert(pdf).toString(),
              'pdfPageCount': 1,
              'engineVersion': 'synthetic-contract',
              'snapshot': snapshot(sha256.convert(edited).toString()),
            };
          },
        ),
      );
      final read = await call('read_document', {'noteId': note.id});
      final slide = read['office']['slides'].single;
      expect(slide['backgroundStyle'], 'solid');
      expect(slide['backgroundColor'], 0xf0e0d0);
      final shape = slide['shapes'].first;
      expect(shape['shapeKind'], 'line');
      expect(
        (slide['shapes'] as List).skip(1).map((item) => item['shapeKind']),
        ['roundedRectangle', 'rightArrow'],
      );
      expect(shape['canEditFill'], false);
      expect(shape['canEditLine'], true);
      expect(shape['lineColor'], 0x112233);
      expect(shape['lineWidth'], .5);
      final args = {
        'noteId': note.id,
        'expectedRevisionId': first.revision.revisionId,
        'operations': operations,
        'requestId': newId(),
      };
      final result = await call('office_edit', args);
      expect(await call('office_edit', args), result);
      expect(edits, 1);
      expect((await store.readLatest(note)).originalBytes, edited);
      expect(
        (await store.readLatest(
          note,
          revisionId: first.revision.revisionId,
        )).originalBytes,
        original,
      );
      await expectLater(
        call('office_edit', {...args, 'requestId': newId()}),
        throwsA(
          isA<VaultMcpException>().having(
            (e) => e.code,
            'code',
            'revision_conflict',
          ),
        ),
      );
      expect(edits, 1);
    },
  );

  test('MCP Office read exposes stored PDF bindings without changing the original edit target', () async {
    final documents = OfficeDocumentStore(controller.repository);
    final note = await documents.importDocument(
      title: 'Office variants',
      fileName: 'original.docx',
      bytes: Uint8List.fromList([1, 2, 3]),
    );
    final captured = await documents.beginEdit(note);
    final variant = await documents.commitDerivedPdf(
      captured,
      pdfBytes: Uint8List.fromList(utf8.encode('%PDF-1.7\nvariant\n%%EOF\n')),
      pageCount: 1,
    );
    service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async => {
          'snapshot': {
            'kind': 'word',
            'sourceSha256': sha256.convert(captured.originalBytes).toString(),
            'paragraphs': [],
            'tables': [],
            'slides': [],
          },
        },
      ),
    );
    final office =
        (await call('read_document', {'noteId': note.id}))['office'] as Map;
    expect(office['sourceRevisionId'], captured.sourceRevision.revisionId);
    expect(office['pdfVariantCount'], 1);
    expect(office['pdfVariants'], [
      {
        'revisionId': variant.revision.revisionId,
        'bindingId': variant.bindingId,
        'pdfSha256': variant.pdfSha256,
      },
    ]);
  });

  test('Office typed operations bind the physical edited original and PDF while preserving the old edition', () async {
    Uint8List docx(String text) => Uint8List.fromList(
      ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
          ..addFile(
            ArchiveFile.string(
              'word/document.xml',
              '<document>$text</document>',
            ),
          ),
      ),
    );
    final original = docx('before'), edited = docx('after');
    final pdf = Uint8List.fromList(
      utf8.encode('%PDF-1.7\nMCP contract fixture\n%%EOF\n'),
    );
    final store = OfficeDocumentStore(controller.repository);
    final note = await store.importDocument(
      title: '문서',
      fileName: 'source.docx',
      bytes: original,
    );
    final first = await store.readLatest(note);
    var edits = 0;
    Map<String, dynamic> snapshot(String hash) => {
      'kind': 'word',
      'sourceSha256': hash,
      'paragraphs': [
        {'id': 'paragraph-0', 'text': 'before'},
      ],
      'tables': [],
      'slides': [],
    };
    service = VaultMcpService(
      controller,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          final source = File(request['sourcePath'] as String);
          final hash = sha256.convert(await source.readAsBytes()).toString();
          if (request['mode'] == 'inspect') return {'snapshot': snapshot(hash)};
          edits++;
          expect(
            request['expectedSourceSha256'],
            sha256.convert(original).toString(),
          );
          expect(request['operations'], [
            {'op': 'paragraphText', 'id': 'paragraph-0', 'text': 'after'},
          ]);
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
            'engineVersion': 'mcp-contract',
            'snapshot': snapshot(sha256.convert(edited).toString()),
          };
        },
      ),
    );
    final read = await call('read_document', {'noteId': note.id});
    expect(read['office']['paragraphs'].single['text'], 'before');
    final result = await call('office_edit', {
      'noteId': note.id,
      'expectedRevisionId': first.revision.revisionId,
      'operations': [
        {'op': 'paragraphText', 'id': 'paragraph-0', 'text': 'after'},
      ],
      'requestId': newId(),
    });
    expect(result['bindingId'], isNotNull);
    expect(result['sourceSha256'], sha256.convert(edited).toString());
    final latest = await store.readLatest(note);
    expect(latest.originalBytes, edited);
    expect(latest.pdfBytes, pdf);
    expect(
      (await store.readLatest(
        note,
        revisionId: first.revision.revisionId,
      )).originalBytes,
      original,
    );
    await expectLater(
      call('office_edit', {
        'noteId': note.id,
        'expectedRevisionId': latest.revision.revisionId,
        'operations': [
          {'op': 'runMacro', 'command': 'ignored'},
        ],
        'requestId': newId(),
      }),
      throwsA(
        isA<VaultMcpException>().having(
          (e) => e.code,
          'code',
          'unsupported_operation',
        ),
      ),
    );
    expect(edits, 1);
  });

  test(
    'write authorization is rechecked after saving the visible editor',
    () async {
      var allowed = true;
      service = VaultMcpService(
        controller,
        prepareMutation: () async {
          allowed = false;
        },
      );
      await expectLater(
        service.call(
          'create_document',
          {'kind': 'markdown', 'title': '금지', 'requestId': newId()},
          context: VaultMcpCallContext(
            isActive: () => true,
            canWrite: () => allowed,
          ),
        ),
        throwsA(
          isA<VaultMcpException>().having((e) => e.code, 'code', 'read_only'),
        ),
      );
      expect(await controller.store.list(), isEmpty);
    },
  );

  test('a service cannot follow a repository replacement even when revision IDs were cloned', () async {
    final created = await call('create_document', {
      'kind': 'markdown',
      'title': '원본',
      'requestId': newId(),
    });
    final original = controller.repository;
    final restored = await BackupService.restoreToEmpty(
      await BackupService.exportSnapshot(original),
      Directory('${temp.path}/restored'),
      targetFormatVersion: 2,
    );
    controller.repository = restored;
    try {
      await expectLater(
        call('vault_status', {}),
        throwsA(
          isA<VaultMcpException>().having(
            (e) => e.code,
            'code',
            'vault_changed',
          ),
        ),
      );
      await expectLater(
        call('document_action', {
          'noteId': created['noteId'],
          'action': 'trash',
          'expectedRevisionId': created['metadataRevisionId'],
          'requestId': newId(),
        }),
        throwsA(
          isA<VaultMcpException>().having(
            (e) => e.code,
            'code',
            'vault_changed',
          ),
        ),
      );
      expect((await controller.store.list()).single.trashed, isFalse);
    } finally {
      await original.close();
    }
  });

  test('create read and revision-conditional Markdown update use actual repository content', () async {
    final created = await call('create_document', {
      'kind': 'markdown',
      'title': 'MCP 노트',
      'body': '# 처음',
      'requestId': newId(),
    });
    final id = created['noteId'] as String;
    final read = await call('read_document', {'noteId': id});
    expect(read['markdown']['content'], '# 처음');
    final updated = await call('update_document', {
      'noteId': id,
      'target': 'markdown',
      'content': '# 변경',
      'expectedRevisionId': read['markdown']['revisionId'],
      'requestId': newId(),
    });
    expect(updated['revisionId'], isNot(read['markdown']['revisionId']));
    expect(
      (await call('read_document', {'noteId': id}))['markdown']['content'],
      '# 변경',
    );
    await expectLater(
      call('update_document', {
        'noteId': id,
        'target': 'markdown',
        'content': '오래된 쓰기',
        'expectedRevisionId': read['markdown']['revisionId'],
        'requestId': newId(),
      }),
      throwsA(
        isA<VaultMcpException>().having(
          (e) => e.code,
          'code',
          'revision_conflict',
        ),
      ),
    );
  });

  test('request journal shares retries rejects changed arguments and survives service restart', () async {
    final requestId = newId();
    final args = {
      'kind': 'markdown',
      'title': '한 번만',
      'body': '내용',
      'requestId': requestId,
    };
    final first = await call('create_document', args);
    service = VaultMcpService(controller);
    expect(await call('create_document', args), first);
    expect((await controller.store.list()).length, 1);
    await expectLater(
      call('create_document', {...args, 'title': '다른 내용'}),
      throwsA(
        isA<VaultMcpException>().having(
          (e) => e.code,
          'code',
          'request_id_reused',
        ),
      ),
    );
    final file = File('${temp.path}/.workspace/mcp/requests/$requestId.json');
    final record =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    await file.writeAsString(jsonEncode({...record, 'state': 'started'}));
    service = VaultMcpService(controller);
    await expectLater(
      call('create_document', args),
      throwsA(
        isA<VaultMcpException>().having(
          (e) => e.code,
          'code',
          'operation_state_unknown',
        ),
      ),
    );
    expect((await controller.store.list()).length, 1);
  });

  test('an in-flight duplicate shares one write and prepares the visible editor first', () async {
    final entered = Completer<void>(), release = Completer<void>();
    var preparations = 0;
    service = VaultMcpService(
      controller,
      prepareMutation: () async {
        preparations++;
        entered.complete();
        await release.future;
      },
    );
    final args = {'kind': 'markdown', 'title': '동시', 'requestId': newId()};
    final a = call('create_document', args);
    try {
      await Future.any([entered.future, a.then<void>((_) {})])
          .timeout(const Duration(seconds: 5));
      final b = call('create_document', args);
      release.complete();
      expect(await b, await a);
    } finally {
      if (!release.isCompleted) release.complete();
    }
    expect(preparations, 1);
    expect((await controller.store.list()).length, 1);
  });

  test('read-only callers cannot mutate and read_revision cannot cross note ownership', () async {
    final a = await call('create_document', {
      'kind': 'markdown',
      'title': 'A',
      'requestId': newId(),
    });
    final b = await call('create_document', {
      'kind': 'markdown',
      'title': 'B',
      'requestId': newId(),
    });
    final bRead = await call('read_document', {'noteId': b['noteId']});
    await expectLater(
      service.call(
        'create_document',
        {'kind': 'markdown', 'title': '거부', 'requestId': newId()},
        context: VaultMcpCallContext(
          isActive: () => true,
          canWrite: () => false,
        ),
      ),
      throwsA(
        isA<VaultMcpException>().having((e) => e.code, 'code', 'read_only'),
      ),
    );
    await expectLater(
      call('read_revision', {
        'noteId': a['noteId'],
        'revisionId': bRead['markdown']['revisionId'],
      }),
      throwsA(
        isA<VaultMcpException>().having(
          (e) => e.code,
          'code',
          'revision_not_owned',
        ),
      ),
    );
    await expectLater(
      call('read_document', {'noteId': '../../private'}),
      throwsA(isA<VaultMcpException>()),
    );
  });

  test('typed bodies are validated before writing and unknown operations cannot execute', () async {
    final created = await call('create_document', {
      'kind': 'infinite',
      'title': '캔버스',
      'requestId': newId(),
    });
    final read = await call('read_document', {'noteId': created['noteId']});
    expect(read['body']['content'], {'version': 1, 'strokes': []});
    await expectLater(
      call('update_document', {
        'noteId': created['noteId'],
        'target': 'body',
        'content': {'version': 99},
        'expectedRevisionId': read['body']['revisionId'],
        'requestId': newId(),
      }),
      throwsA(
        isA<VaultMcpException>().having(
          (e) => e.code,
          'code',
          'invalid_arguments',
        ),
      ),
    );
    await expectLater(
      call('run_shell', {'cmd': 'anything'}),
      throwsA(
        isA<VaultMcpException>().having(
          (e) => e.code,
          'code',
          'unknown_operation',
        ),
      ),
    );
    expect(
      (await call('read_document', {
        'noteId': created['noteId'],
      }))['body']['revisionId'],
      read['body']['revisionId'],
    );
  });

  test('metadata actions honor expected heads and open happens outside the writer gate', () async {
    final created = await call('create_document', {
      'kind': 'markdown',
      'title': '원제목',
      'requestId': newId(),
    });
    var read = await call('read_document', {'noteId': created['noteId']});
    await call('document_action', {
      'noteId': created['noteId'],
      'action': 'rename',
      'title': '새제목',
      'expectedRevisionId': read['metadataRevisionId'],
      'requestId': newId(),
    });
    read = await call('read_document', {'noteId': created['noteId']});
    expect(read['title'], '새제목');
    String? opened;
    service = VaultMcpService(
      controller,
      onOpenNote: (id) async {
        opened = id;
        final note = (await controller.store.list()).singleWhere(
          (n) => n.id == id,
        );
        await controller.openNote(note);
      },
    );
    await call('document_action', {
      'noteId': created['noteId'],
      'action': 'open',
      'requestId': newId(),
    });
    expect(opened, created['noteId']);
    expect(controller.activeSession!.note.id, created['noteId']);
  });
}
