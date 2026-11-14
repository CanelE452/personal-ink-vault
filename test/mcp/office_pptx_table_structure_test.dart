import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/pptx_shape_text.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';
import 'package:xml/xml.dart';

import '../../integration_test/support/windows_mcp_rpc.dart';

const _tempPrefix = 'piv-pptx-table-mcp-';
const _pptxSha =
    'dc9bf8f671717ca2f1280e6181e940a027c518de54bd663f10492f6a9595b6c0';
const _pdfSha =
    'cb5fa20630118e3112721587fb9d18683ef5906d938bf127e8e6b8148ff0c4e3';
const _inkSha =
    'ac8da508357ae1b1d26342769d4691ab76a56e41f77d47da7954e1f4e63db300';
const _targetPart = 'ppt/slides/slide3.xml';
const _drawing = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _presentation =
    'http://schemas.openxmlformats.org/presentationml/2006/main';

Map<String, Object?> _read(String noteId, Map<String, Object?> query) => {
  'noteId': noteId,
  'pptxTableStructure': query,
};

Map<String, Object?> _edit(
  String noteId,
  OfficeEdition source, {
  int slideIndex = 2,
  int shapeId = 32,
  PptxTableStructureAction action = PptxTableStructureAction.insertRowBefore,
  int index = 1,
  String? sourceSha256,
}) => {
  'noteId': noteId,
  'expectedRevisionId': source.revision.revisionId,
  'requestId': newId(),
  'operations': [
    {
      'op': 'presentationTableStructureEdit',
      'expectedSourceSha256': sourceSha256 ?? source.originalSha256,
      'slideIndex': slideIndex,
      'shapeId': shapeId,
      'action': action.name,
      'index': index,
    },
  ],
};

Matcher _error(String code) =>
    isA<VaultMcpException>().having((e) => e.code, 'code', code);

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

Uint8List _stubPptx(String marker) => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
      ..addFile(
        ArchiveFile.string('ppt/presentation.xml', '<ppt>$marker</ppt>'),
      ),
  ),
);

final _stubPdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nfixture\n%%EOF\n'));

class _StubStructure extends PptxTableStructureEngine {
  new(this.original, this.edited);

  final Uint8List original;
  final Uint8List edited;
  final paths = <String>[];
  var writes = 0;
  Future<void> Function()? afterInspectSlide;

  @override
  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    paths.add(sourcePath);
    expect(sourceSha256, _sha(original));
    expect(await File(sourcePath).readAsBytes(), original);
    return PptxShapeTextPlan(
      sourceSha256: sourceSha256,
      slides: const [PptxShapeTextSlide(index: 0, hidden: true, title: 'Plan')],
    );
  }

  @override
  Future<List<PptxTableStructureTable>> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    expect(await File(sourcePath).readAsBytes(), original);
    expect(plan.sourceSha256, _sha(original));
    expect(slideIndex, 0);
    await afterInspectSlide?.call();
    return [
      for (final id in [41, 0xffffffff])
        PptxTableStructureTable(
          shapeId: id,
          name: 'Table $id',
          rows: 2,
          columns: 2,
          rowInsertGaps: [0, 2],
          columnInsertGaps: [1],
          rowDelete: [1],
          columnDelete: [0],
        ),
    ];
  }

  @override
  Future<PptxTableStructureOutput> edit({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxTableStructureTable table,
    required PptxTableStructureAction action,
    required int index,
  }) async {
    expect(await File(sourcePath).readAsBytes(), original);
    expect(File(outputPath).existsSync(), isFalse);
    expect(p.equals(p.dirname(sourcePath), p.dirname(outputPath)), isTrue);
    expect(table.shapeId, 41);
    expect(table.allows(action, index), isTrue);
    writes++;
    await File(outputPath).writeAsBytes(edited, flush: true);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: _sha(edited),
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      shapeId: table.shapeId,
      action: action,
      index: index,
      rows: table.rows + action.rowDelta,
      columns: table.columns + action.columnDelta,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PPTX table MCP service', () {
    late Directory temp;
    late NoteRepository repo;
    late WorkspaceController controller;
    late OfficeDocumentStore store;
    late OfficeEdition original;
    late _StubStructure tables;
    late VaultMcpService service;
    late VaultMcpCallContext context;
    late String noteId;
    late int previewCalls;
    late int previewPages;
    late bool writable;
    late bool revokeDuringPreview;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp(_tempPrefix);
      repo = await NoteRepository.open(
        Directory(p.join(temp.path, 'vault')),
        createFormatVersion: 2,
      );
      controller = WorkspaceController(
        repo,
        directoryProvider: () async => temp,
      );
      store = OfficeDocumentStore(repo);
      final note = await store.importDocument(
        title: 'Fixture PPTX',
        fileName: 'table.pptx',
        bytes: _stubPptx('before'),
      );
      noteId = note.id;
      original = await store.readLatest(note);
      tables = _StubStructure(original.originalBytes, _stubPptx('after'));
      previewCalls = 0;
      previewPages = 1;
      writable = true;
      revokeDuringPreview = false;
      context = VaultMcpCallContext(
        isActive: () => true,
        canWrite: () => writable,
      );
      service = VaultMcpService(
        controller,
        pptxTableStructure: tables,
        officeEngine: WindowsOfficeEngine(
          runner: (request) async {
            previewCalls++;
            expect(request['mode'], 'inspect');
            expect(request['preview'], isTrue);
            final source = File(request['sourcePath'] as String);
            expect(await source.readAsBytes(), tables.edited);
            final pdf = await File(p.join(temp.path, 'fixture.pdf'))
                .writeAsBytes(_stubPdf);
            if (revokeDuringPreview) writable = false;
            return {
              'snapshot': {
                'kind': 'presentation',
                'sourceSha256': _sha(tables.edited),
                'paragraphs': [],
                'tables': [],
                'slides': [],
                'previewPdfPath': pdf.path,
                'previewPageCount': previewPages,
              },
            };
          },
        ),
      );
    });

    tearDown(() async {
      try {
        await controller.flush();
      } finally {
        controller.dispose();
        await repo.close();
        await _deleteOwnedTemp(temp);
      }
    });

    Future<Object?> call(String tool, Map<String, Object?> args) =>
        service.call(tool, args, context: context);

    Future<void> expectUnchanged() async {
      expect(
        (await repo.heads(original.revision.entityId)).single.revisionId,
        original.revision.revisionId,
      );
      for (final path in tables.paths) {
        expect(File(path).existsSync(), isFalse);
      }
    }

    test(
      'read-only discovery pages exact numeric targets and allowed positions',
      () async {
        writable = false;
        final slides = jsonObject(
          await call('read_document', _read(noteId, {})),
        );
        expect(slides, {
          'noteId': noteId,
          'sourceRevisionId': original.revision.revisionId,
          'sourceSha256': original.originalSha256,
          'slideCount': 1,
          'slides': [
            {'index': 0, 'hidden': true, 'title': 'Plan'},
          ],
        });
        final first = jsonObject(
          await call(
            'read_document',
            _read(noteId, {'slideIndex': 0, 'tableLimit': 1}),
          ),
        );
        expect(first['tableOffset'], 0);
        expect(first['tableLimit'], 1);
        expect(first['nextTableOffset'], 1);
        expect(first['tables'], [
          {
            'shapeId': 41,
            'name': 'Table 41',
            'rows': 2,
            'columns': 2,
            'positions': {
              'insertRowBefore': [0],
              'insertRowAfter': [1],
              'insertColumnBefore': [1],
              'insertColumnAfter': [0],
              'deleteRow': [1],
              'deleteColumn': [0],
            },
          },
        ]);
        final last = jsonObject(
          await call(
            'read_document',
            _read(noteId, {'slideIndex': 0, 'tableOffset': 1}),
          ),
        );
        expect(last['tableLimit'], 16);
        expect(last['nextTableOffset'], isNull);
        expect((last['tables'] as List).single['shapeId'], 0xffffffff);
        await expectLater(
          call('read_document', {
            ..._read(noteId, {}),
            'revisionId': original.revision.revisionId,
          }),
          throwsA(_error('invalid_arguments')),
        );
        for (final query in <Map<String, Object?>>[
          {'tableLimit': 1},
          {'slideIndex': 0, 'tableLimit': 33},
          {'slideIndex': 0, 'tableOffset': 401},
          {'slideIndex': 256},
          {'slideIndex': 0, 'sourcePath': 'not-a-target'},
        ]) {
          await expectLater(
            call('read_document', _read(noteId, query)),
            throwsA(_error('invalid_arguments')),
          );
        }
        expect(tables.writes, 0);
        expect(previewCalls, 0);
        await expectUnchanged();
      },
    );

    test(
      'source hash, exact allowed index and permission guard the native editor',
      () async {
        final valid = _edit(
          noteId,
          original,
          slideIndex: 0,
          shapeId: 41,
          index: 0,
        );
        writable = false;
        await expectLater(
          call('office_edit', valid),
          throwsA(_error('read_only')),
        );
        writable = true;
        await expectLater(
          call(
            'office_edit',
            _edit(
              noteId,
              original,
              slideIndex: 0,
              shapeId: 41,
              index: 0,
              sourceSha256: '0' * 64,
            ),
          ),
          throwsA(_error('office_source_mismatch')),
        );
        await expectLater(
          call(
            'office_edit',
            _edit(noteId, original, slideIndex: 0, shapeId: 42, index: 0),
          ),
          throwsA(_error('invalid_arguments')),
        );
        await expectLater(
          call(
            'office_edit',
            _edit(noteId, original, slideIndex: 0, shapeId: 41, index: 1),
          ),
          throwsA(_error('invalid_arguments')),
        );
        expect(tables.writes, 0);
        expect(previewCalls, 0);
        await expectUnchanged();
      },
    );

    test(
      'bad page count and revoked write access leave the original head intact',
      () async {
        Map<String, Object?> valid() =>
            _edit(noteId, original, slideIndex: 0, shapeId: 41, index: 0);
        previewPages = 2;
        await expectLater(
          call('office_edit', valid()),
          throwsA(_error('office_payload_mismatch')),
        );
        await expectUnchanged();
        previewPages = 1;
        revokeDuringPreview = true;
        await expectLater(
          call('office_edit', valid()),
          throwsA(_error('read_only')),
        );
        expect(tables.writes, 2);
        expect(previewCalls, 2);
        await expectUnchanged();
      },
    );

    test('publishes the native candidate and PDF once per request', () async {
      final request = _edit(
        noteId,
        original,
        slideIndex: 0,
        shapeId: 41,
        index: 0,
      );
      final result = jsonObject(await call('office_edit', request));
      expect(result['sourceSha256'], _sha(tables.edited));
      expect(result['pdfSha256'], _sha(_stubPdf));
      expect(result['pageCount'], 1);
      expect(await call('office_edit', request), result);
      final revisions = (await repo.revisions())
          .where((r) => r.entityId == original.revision.entityId)
          .toList();
      expect(revisions, hasLength(2));
      final published = revisions.singleWhere(
        (r) => r.revisionId == result['revisionId'],
      );
      expect(published.parentRevisionIds, [original.revision.revisionId]);
      final files = await repo.readFiles(published);
      expect(files['table.pptx'], tables.edited);
      expect(files['preview.pdf'], _stubPdf);
      expect(tables.writes, 1);
      expect(previewCalls, 1);
    });

    test(
      'discards discovered positions if the source changes during inspection',
      () async {
        tables.afterInspectSlide = () async {
          await repo.commit(
            entityId: original.revision.entityId,
            kind: EntityKind.attachment,
            ownerNoteId: noteId,
            files: {'table.pptx': tables.edited},
            parentRevisionIds: [original.revision.revisionId],
          );
        };
        await expectLater(
          call('read_document', _read(noteId, {'slideIndex': 0})),
          throwsA(_error('revision_conflict')),
        );
        expect(tables.paths, hasLength(1));
        expect(File(tables.paths.single).existsSync(), isFalse);
        expect(tables.writes, 0);
        expect(previewCalls, 0);
      },
    );
  });

  _realWindowsRoundTrip();
}

void _realWindowsRoundTrip() {
  final env = Platform.environment;
  final executable = env['INK_VAULT_MCP_TEST_EXE'];
  final runtime = env['PIV_PPTX_TABLE_STRUCTURE_RUNTIME'];
  final fixture = env['PIV_PPTX_TABLE_STRUCTURE_FIXTURE'];
  final library = env['PIV_PPTX_TABLE_STRUCTURE_LIBRARY'];
  final pdfium = env['PIV_PDF_ANCHOR_TEST_PDFIUM'];

  test(
    'actual Windows MCP publishes all six PPTX table actions and replays after restart',
    () async {
      final fixtureFile = File(fixture!);
      final pdfFile = File(p.setExtension(fixture, '.pdf'));
      final original = await fixtureFile.readAsBytes();
      final originalPdf = await pdfFile.readAsBytes();
      final ink = await File(
        p.join('test', 'sbn_examples', 'v19_shape_strokes.sbn2'),
      ).readAsBytes();
      expect(_sha(original), _pptxSha);
      expect(_sha(originalPdf), _pdfSha);
      expect(_sha(ink), _inkSha);
      final engine = WindowsOfficeEngine(
        runtimePath: p.absolute(runtime!),
        helperDirectory: p.absolute(
          env['PIV_PPTX_TABLE_STRUCTURE_HELPERS'] ?? p.dirname(runtime),
        ),
      );
      expect(await engine.available, isTrue);
      final native = PptxTableStructureEngine(
        libraryPath: p.absolute(library!),
      );
      final root = await Directory.systemTemp.createTemp(_tempPrefix);
      final vault = Directory(p.join(root.path, 'vault'));
      final support = Directory(p.join(root.path, 'support'));
      final previousPdfium = Pdfrx.pdfiumModulePath;
      WorkspaceController? controller;
      McpAccessController? access;
      WindowsMcpRpc? client;

      Future<void> stop() async {
        await client?.close();
        client = null;
        await access?.stop();
        access?.dispose();
        access = null;
        final current = controller;
        controller = null;
        if (current != null) {
          try {
            await current.flush();
          } finally {
            current.dispose();
            await current.repository.close();
          }
        }
      }

      Future<void> start() async {
        final repo = await NoteRepository.open(vault, createFormatVersion: 2);
        final current = controller = WorkspaceController(
          repo,
          directoryProvider: () async => support,
        );
        final bridge = access = McpAccessController(
          () => VaultMcpService(
            current,
            officeEngine: engine,
            pptxTableStructure: native,
          ),
          executable: p.absolute(executable!),
          supportDirectory: () async => support,
        );
        await bridge.start();
        final servers = bridge.clientConfiguration['mcpServers'] as Map;
        final config = servers['personal-ink-vault'] as Map;
        final arguments = config['args'] as List;
        expect(arguments.first, '--bridge-file');
        client = await WindowsMcpRpc.start(
          config['command'] as String,
          arguments.last as String,
          replyTimeout: const Duration(seconds: 90),
        );
      }

      addTearDown(() async {
        try {
          await stop();
        } finally {
          Pdfrx.pdfiumModulePath = previousPdfium;
          await _deleteOwnedTemp(root);
        }
      });

      await start();
      final repo = controller!.repository;
      final store = OfficeDocumentStore(repo);
      final note = await store.importDocument(
        title: 'Hidden table round trip',
        fileName: 'table.pptx',
        bytes: original,
      );
      final before = await store.commitEdited(
        await store.beginEdit(note),
        originalBytes: original,
        pdfBytes: originalPdf,
        engineVersion: 'A138 fixture',
        pageCount: 3,
      );
      final annotation = await OfficeAnnotationStore(repo).open(note, before);
      final inkRevision = await annotation.saveFiles({'main.sbn2': ink});
      final slides = await client!.call('read_document', _read(note.id, {}));
      expect(slides.isError, isFalse, reason: '${slides.data}');
      expect(slides.data['sourceRevisionId'], before.revision.revisionId);
      expect(slides.data['sourceSha256'], _pptxSha);
      expect(slides.data['slideCount'], 3);
      expect(slides.data['slides'], contains(containsPair('hidden', true)));

      const actions = [
        (PptxTableStructureAction.insertRowBefore, 1),
        (PptxTableStructureAction.deleteColumn, 2),
        (PptxTableStructureAction.insertColumnBefore, 1),
        (PptxTableStructureAction.insertRowAfter, 1),
        (PptxTableStructureAction.deleteRow, 1),
        (PptxTableStructureAction.insertColumnAfter, 1),
      ];
      Pdfrx.pdfiumModulePath = p.absolute(pdfium!);
      await pdfrxInitialize(tmpPath: root.path);
      final baselineText = await _pdfText(originalPdf);
      final originalMembers = _members(original);
      final originalCells = _tableMatrix(originalMembers[_targetPart]!);
      expect(originalCells, hasLength(3));
      expect(originalCells.every((row) => row.length == 4), isTrue);
      final expected = originalCells
          .map((row) => List<String>.of(row))
          .toList();
      var current = before;
      late Map<String, Object?> lastRequest;
      late Map<String, dynamic> lastSaved;
      for (final (number, (action, index)) in actions.indexed) {
        final page = await client!.call(
          'read_document',
          _read(note.id, {'slideIndex': 2, 'tableLimit': 1}),
        );
        expect(page.isError, isFalse, reason: '${page.data}');
        expect(page.data['sourceRevisionId'], current.revision.revisionId);
        expect(page.data['sourceSha256'], current.originalSha256);
        final table = (page.data['tables'] as List).single as Map;
        expect(table, containsPair('shapeId', 32));
        expect(table, containsPair('name', 'Table 2'));
        expect(table, containsPair('rows', expected.length));
        expect(table, containsPair('columns', expected.first.length));
        expect((table['positions'] as Map)[action.name], contains(index));
        lastRequest = _edit(note.id, current, action: action, index: index);
        if (number == 0) {
          final denied = await client!.call('office_edit', lastRequest);
          expect(denied.isError, isTrue);
          expect(denied.data['code'], 'read_only');
          await access!.allowEdits(true);
        }
        final saved = await client!.call('office_edit', lastRequest);
        expect(saved.isError, isFalse, reason: '${action.name}: ${saved.data}');
        lastSaved = saved.data;
        final edited = await store.readLatest(note);
        expect(edited.revision.parentRevisionIds, [
          current.revision.revisionId,
        ]);
        expect(edited.originalSha256, saved.data['sourceSha256']);
        expect(edited.pdfSha256, saved.data['pdfSha256']);
        expect(edited.bindingId, isNot(current.bindingId));
        expect(edited.pageCount, 3);
        final members = _members(edited.originalBytes);
        expect(members.keys.toSet(), originalMembers.keys.toSet());
        for (final part in originalMembers.keys.where(
          (key) => key != _targetPart,
        )) {
          expect(members[part], originalMembers[part], reason: part);
        }
        _apply(expected, action, index);
        expect(
          _tableMatrix(members[_targetPart]!),
          expected,
          reason: action.name,
        );
        final rendered = await _pdfText(edited.pdfBytes!);
        expect(rendered.take(2), baselineText.take(2));
        expect(
          _labels(rendered[2]),
          _labels(expected.expand((row) => row).join(' ')),
        );
        current = edited;
        if (number == 0) {
          final stale = await client!.call(
            'office_edit',
            _edit(note.id, before),
          );
          expect(stale.isError, isTrue);
          expect(stale.data['code'], 'revision_conflict');
        }
      }

      await stop();
      await start();
      await access!.allowEdits(true);
      final reopenedRepo = controller!.repository;
      final reopened = OfficeDocumentStore(reopenedRepo);
      final replay = await client!.call('office_edit', lastRequest);
      expect(replay.isError, isFalse, reason: '${replay.data}');
      expect(replay.data, lastSaved);
      expect(
        (await reopened.readLatest(note)).revision.revisionId,
        current.revision.revisionId,
      );
      expect(
        (await reopenedRepo.revisions()).where(
          (r) => r.entityId == note.sourceEntityId,
        ),
        hasLength(actions.length + 2),
      );
      final previous = await reopened.readLatest(
        note,
        revisionId: before.revision.revisionId,
      );
      expect(previous.originalBytes, original);
      expect(previous.pdfBytes, originalPdf);
      expect((await reopenedRepo.readFiles(inkRevision))['main.sbn2'], ink);
      expect(_sha(await fixtureFile.readAsBytes()), _pptxSha);
      expect(_sha(await pdfFile.readAsBytes()), _pdfSha);
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip:
        !Platform.isWindows ||
        executable == null ||
        runtime == null ||
        fixture == null ||
        library == null ||
        pdfium == null,
  );
}

Future<void> _deleteOwnedTemp(Directory root) async {
  final owned = await root.resolveSymbolicLinks();
  final system = await Directory.systemTemp.resolveSymbolicLinks();
  expect(p.equals(p.dirname(owned), system), isTrue);
  expect(p.basename(owned), startsWith(_tempPrefix));
  await Directory(owned).delete(recursive: true);
}

Map<String, List<int>> _members(List<int> bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  try {
    return {
      for (final member in archive.files)
        if (member.isFile) member.name: Uint8List.fromList(member.content),
    };
  } finally {
    archive.clearSync();
  }
}

List<List<String>> _tableMatrix(List<int> slide) {
  final document = XmlDocument.parse(utf8.decode(slide));
  expect(document.rootElement.getAttribute('show'), '0');
  final frame = document
      .findAllElements('graphicFrame', namespace: _presentation)
      .single;
  expect(
    frame
        .findAllElements('cNvPr', namespace: _presentation)
        .single
        .getAttribute('id'),
    '32',
  );
  final table = frame.findAllElements('tbl', namespace: _drawing).single;
  final columns = table.findAllElements('gridCol', namespace: _drawing).length;
  final rows = [
    for (final row in table.findElements('tr', namespace: _drawing))
      [
        for (final cell in row.findElements('tc', namespace: _drawing))
          cell
              .findAllElements('t', namespace: _drawing)
              .map((text) => text.innerText)
              .join(),
      ],
  ];
  expect(rows.every((row) => row.length == columns), isTrue);
  return rows;
}

void _apply(
  List<List<String>> rows,
  PptxTableStructureAction action,
  int index,
) {
  final target = index + (action.isAfter ? 1 : 0);
  if (action.isRow) {
    if (action.isDelete) {
      rows.removeAt(target);
    } else {
      rows.insert(target, List.filled(rows.first.length, '', growable: true));
    }
  } else {
    for (final row in rows) {
      if (action.isDelete) {
        row.removeAt(target);
      } else {
        row.insert(target, '');
      }
    }
  }
}

Set<String> _labels(String text) =>
    RegExp(r'R[1-3]C[1-4]').allMatches(text).map((match) => match[0]!).toSet();

Future<List<String>> _pdfText(Uint8List bytes) async {
  final document = await PdfDocument.openData(bytes);
  try {
    expect(document.pages, hasLength(3));
    return [
      for (final page in document.pages) (await page.loadText())!.fullText,
    ];
  } finally {
    await document.dispose();
  }
}
