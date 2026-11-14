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
import 'package:saber/data/office/docx_table_structure.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';
import 'package:xml/xml.dart';

import '../../integration_test/support/windows_mcp_rpc.dart';

const _tempPrefix = 'piv-docx-table-mcp-';
const _table = DocxTableStructureTable(
  tableIndex: 3,
  rowCount: 2,
  columnCount: 3,
  preview: '연구 자료',
);
const _single = DocxTableStructureTable(
  tableIndex: 17,
  rowCount: 1,
  columnCount: 1,
  preview: '',
);
const _full = DocxTableStructureTable(
  tableIndex: 21,
  rowCount: 16,
  columnCount: 32,
  preview: '512 cells',
);
final _pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nfixture\n%%EOF\n'));

Uint8List _docx(String marker) => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
      ..addFile(
        ArchiveFile.string('word/document.xml', '<document>$marker</document>'),
      ),
  ),
);

String _sha(List<int> bytes) => sha256.convert(bytes).toString();

Matcher _error(String code) =>
    isA<VaultMcpException>().having((error) => error.code, 'code', code);

Map<String, Object?> _read(
  String noteId, [
  Map<String, Object?> query = const {},
]) => {'noteId': noteId, 'docxTableStructure': query};

Map<String, Object?> _operation(
  OfficeEdition source, {
  int tableIndex = 3,
  DocxTableStructureAction action = DocxTableStructureAction.insertColumn,
  int index = 2,
  int? anchorIndex = 1,
  String? sourceHash,
}) => {
  'op': 'docxTableStructureEdit',
  'expectedSourceSha256': sourceHash ?? source.originalSha256,
  'tableIndex': tableIndex,
  'action': action.name,
  'index': index,
  'anchorIndex': ?anchorIndex,
};

Map<String, Object?> _edit(
  String noteId,
  OfficeEdition source, {
  List<Map<String, Object?>>? operations,
}) => {
  'noteId': noteId,
  'expectedRevisionId': source.revision.revisionId,
  'requestId': newId(),
  'operations': operations ?? [_operation(source)],
};

class _StubStructure extends DocxTableStructureEngine {
  new(this.original, this.edited);

  final Uint8List original;
  final Uint8List edited;
  final paths = <String>[];
  final edits = <(int, DocxTableStructureAction, int, int?)>[];
  Future<void> Function()? afterInspect;

  @override
  Future<DocxTableStructurePlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    paths.add(sourcePath);
    expect(sourceSha256, _sha(original));
    expect(await File(sourcePath).readAsBytes(), original);
    await afterInspect?.call();
    return DocxTableStructurePlan(
      sourceSha256: sourceSha256,
      tables: const [_table, _single, _full],
    );
  }

  @override
  Future<DocxTableStructureOutput> edit({
    required String sourcePath,
    required DocxTableStructurePlan plan,
    required String outputPath,
    required int tableIndex,
    required DocxTableStructureAction action,
    required int index,
    int? anchorIndex,
  }) async {
    expect(await File(sourcePath).readAsBytes(), original);
    expect(File(outputPath).existsSync(), isFalse);
    expect(p.equals(p.dirname(sourcePath), p.dirname(outputPath)), isTrue);
    final table = plan.tables.singleWhere(
      (item) => item.tableIndex == tableIndex,
    );
    expect(
      table.allowsPosition(action, index, anchorIndex: anchorIndex),
      isTrue,
    );
    edits.add((tableIndex, action, index, anchorIndex));
    paths.add(outputPath);
    await File(outputPath).writeAsBytes(edited, flush: true);
    return DocxTableStructureOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: _sha(edited),
      tableIndex: tableIndex,
      rowCount: table.rowCount + action.rowDelta,
      columnCount: table.columnCount + action.columnDelta,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('DOCX table MCP service', _serviceRoundTrips);
  _realWindowsRoundTrip();
}

void _serviceRoundTrips() {
  late Directory temp;
  late NoteRepository repo;
  late WorkspaceController controller;
  late OfficeDocumentStore store;
  late VaultNote note;
  late OfficeEdition original;
  late _StubStructure tables;
  late VaultMcpService service;
  late VaultMcpCallContext context;
  late int previewCalls;
  late bool writable;
  Future<void> Function()? afterRender;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(_tempPrefix);
    repo = await NoteRepository.open(
      Directory(p.join(temp.path, 'vault')),
      createFormatVersion: 2,
    );
    controller = WorkspaceController(repo, directoryProvider: () async => temp);
    store = OfficeDocumentStore(repo);
    note = await store.importDocument(
      title: 'Fixture DOCX',
      fileName: 'table.docx',
      bytes: _docx('before'),
    );
    original = await store.readLatest(note);
    tables = _StubStructure(original.originalBytes, _docx('after'));
    previewCalls = 0;
    writable = true;
    afterRender = null;
    context = VaultMcpCallContext(
      isActive: () => true,
      canWrite: () => writable,
    );
    service = VaultMcpService(
      controller,
      docxTableStructure: tables,
      officeEngine: WindowsOfficeEngine(
        runner: (request) async {
          previewCalls++;
          expect(request['mode'], 'inspect');
          expect(request['preview'], isTrue);
          final source = File(request['sourcePath'] as String);
          expect(await source.readAsBytes(), tables.edited);
          final pdf = await File(p.join(source.parent.path, 'fixture.pdf'))
              .writeAsBytes(_pdf, flush: true);
          tables.paths.add(pdf.path);
          await afterRender?.call();
          return {
            'snapshot': {
              'kind': 'word',
              'sourceSha256': _sha(tables.edited),
              'paragraphs': [],
              'tables': [],
              'slides': [],
              'previewPdfPath': pdf.path,
              'previewPageCount': 1,
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

  Future<Map<String, dynamic>> call(
    String tool,
    Map<String, Object?> args,
  ) async => jsonObject(await service.call(tool, args, context: context));

  Future<void> expectHead(String revisionId) async {
    expect(
      (await repo.heads(original.revision.entityId)).single.revisionId,
      revisionId,
    );
    for (final path in tables.paths) {
      expect(
        FileSystemEntity.typeSync(path, followLinks: false),
        FileSystemEntityType.notFound,
      );
    }
  }

  Future<String> replaceSource() async {
    final rival = await repo.commit(
      entityId: original.revision.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {'table.docx': _docx('concurrent change')},
      parentRevisionIds: [original.revision.revisionId],
    );
    return rival.revisionId;
  }

  test(
    'read-only DOCX discovery pages stable table indexes and limits',
    () async {
      writable = false;
      final page = await call(
        'read_document',
        _read(note.id, {'tableLimit': 1}),
      );
      expect(page['sourceRevisionId'], original.revision.revisionId);
      expect(page['sourceSha256'], original.originalSha256);
      expect(page['tableTotal'], 3);
      expect(page['tableOffset'], 0);
      expect(page['tableLimit'], 1);
      expect(page['nextTableOffset'], 1);
      final first = (page['tables'] as List).single as Map;
      expect(first, containsPair('tableIndex', 3));
      expect(first, containsPair('rowCount', 2));
      expect(first, containsPair('columnCount', 3));
      expect(first, containsPair('preview', '연구 자료'));
      expect(
        first['supportedActions'],
        unorderedEquals(
          DocxTableStructureAction.values.map((action) => action.name),
        ),
      );

      final last = await call(
        'read_document',
        _read(note.id, {'tableOffset': 1}),
      );
      expect(last['tableOffset'], 1);
      expect(last['tableLimit'], 16);
      expect(last['nextTableOffset'], isNull);
      final rest = (last['tables'] as List).cast<Map>();
      expect(rest.map((table) => table['tableIndex']), [17, 21]);
      expect(
        rest.first['supportedActions'],
        unorderedEquals(['insertRow', 'insertColumn']),
      );
      expect(
        rest.last['supportedActions'],
        unorderedEquals(['deleteRow', 'deleteColumn']),
      );

      for (final query in <Map<String, Object?>>[
        {'tableLimit': 0},
        {'tableLimit': 33},
        {'tableOffset': -1},
        {'sourcePath': 'outside.docx'},
      ]) {
        await expectLater(
          call('read_document', _read(note.id, query)),
          throwsA(_error('invalid_arguments')),
        );
      }
      await expectLater(
        call('read_document', {
          ..._read(note.id),
          'revisionId': original.revision.revisionId,
        }),
        throwsA(_error('invalid_arguments')),
      );
      expect(tables.edits, isEmpty);
      expect(previewCalls, 0);
      await expectHead(original.revision.revisionId);
    },
  );

  test(
    'permission, exact source, and one eligible operation guard the editor',
    () async {
      writable = false;
      await expectLater(
        call('office_edit', _edit(note.id, original)),
        throwsA(_error('read_only')),
      );
      expect(tables.paths, isEmpty);
      writable = true;
      await expectLater(
        call(
          'office_edit',
          _edit(
            note.id,
            original,
            operations: [_operation(original, sourceHash: '0' * 64)],
          ),
        ),
        throwsA(_error('office_source_mismatch')),
      );
      final valid = _operation(original);
      for (final ops in [
        [valid, valid],
        [_operation(original, anchorIndex: null)],
        [_operation(original, anchorIndex: 0)],
        [_operation(original, tableIndex: 0)],
        [
          _operation(
            original,
            action: DocxTableStructureAction.deleteRow,
            index: 0,
          ),
        ],
        [
          _operation(
            original,
            tableIndex: 17,
            action: DocxTableStructureAction.deleteRow,
            index: 0,
            anchorIndex: null,
          ),
        ],
      ]) {
        await expectLater(
          call('office_edit', _edit(note.id, original, operations: ops)),
          throwsA(_error('invalid_arguments')),
        );
      }
      expect(tables.edits, isEmpty);
      expect(previewCalls, 0);
      await expectHead(original.revision.revisionId);
    },
  );

  test('the same request saves exact DOCX and PDF bytes once', () async {
    final request = _edit(note.id, original);
    final saved = await call('office_edit', request);
    expect(saved['sourceSha256'], _sha(tables.edited));
    expect(saved['pdfSha256'], _sha(_pdf));
    expect(saved['pageCount'], 1);
    expect(await call('office_edit', request), saved);
    await expectLater(
      call('office_edit', {
        ...request,
        'operations': [_operation(original, index: 1)],
      }),
      throwsA(_error('request_id_reused')),
    );
    await expectLater(
      call('office_edit', _edit(note.id, original)),
      throwsA(_error('revision_conflict')),
    );
    final current = await store.readLatest(note);
    expect(current.revision.parentRevisionIds, [original.revision.revisionId]);
    expect(current.originalBytes, tables.edited);
    expect(current.pdfBytes, _pdf);
    final previous = await store.readLatest(
      note,
      revisionId: original.revision.revisionId,
    );
    expect(previous.originalBytes, original.originalBytes);
    expect(previous.pdfBytes, isNull);
    expect(tables.edits, [(3, DocxTableStructureAction.insertColumn, 2, 1)]);
    expect(previewCalls, 1);
    await expectHead(current.revision.revisionId);
  });

  test(
    'revocation during rendering discards the candidate before publication',
    () async {
      afterRender = () async {
        writable = false;
      };
      final request = _edit(note.id, original);
      await expectLater(
        call('office_edit', request),
        throwsA(_error('read_only')),
      );
      expect(tables.edits, hasLength(1));
      expect(previewCalls, 1);
      await expectHead(original.revision.revisionId);
      expect(
        Directory(
          p.join(
            repo.root.path,
            '.workspace',
            'mcp',
            'requests',
            request['requestId'] as String,
            'files',
          ),
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'a concurrent source change during rendering wins over the draft',
    () async {
      late String current;
      afterRender = () async {
        current = await replaceSource();
      };
      await expectLater(
        call('office_edit', _edit(note.id, original)),
        throwsA(_error('revision_conflict')),
      );
      expect(tables.edits, hasLength(1));
      expect(previewCalls, 1);
      await expectHead(current);
    },
  );

  test(
    'read drops tables when their original changes during inspection',
    () async {
      late String current;
      tables.afterInspect = () async {
        current = await replaceSource();
      };
      await expectLater(
        call('read_document', _read(note.id)),
        throwsA(_error('revision_conflict')),
      );
      expect(tables.edits, isEmpty);
      expect(previewCalls, 0);
      await expectHead(current);
    },
  );
}

void _realWindowsRoundTrip() {
  final env = Platform.environment;
  final executable = env['INK_VAULT_MCP_TEST_EXE'];
  final runtime = env['PIV_DOCX_TABLE_STRUCTURE_RUNTIME'];
  final fixture = env['PIV_DOCX_TABLE_STRUCTURE_FIXTURE'];
  final library = env['PIV_DOCX_TABLE_STRUCTURE_LIBRARY'];
  final pdfium = env['PIV_PDF_ANCHOR_TEST_PDFIUM'];

  test(
    'real Windows MCP edits the Writer DOCX and replays after a full restart',
    () async {
      final sourceFile = File(fixture!);
      final pdfFile = File(p.setExtension(fixture, '.pdf'));
      final source = await sourceFile.readAsBytes();
      final sourcePdf = await pdfFile.readAsBytes();
      expect(
        _sha(source),
        '697ca7cbff6502e4f1057b760afec8b2a6d3142e10159771e74a0d300ea1ace3',
      );
      expect(
        _sha(sourcePdf),
        '91053c390262b080354126b2230adbd588154fac3ea1ffab65d6fd89592b3345',
      );
      final engine = WindowsOfficeEngine(
        runtimePath: p.absolute(runtime!),
        helperDirectory: p.absolute(
          env['PIV_DOCX_TABLE_STRUCTURE_HELPERS'] ?? p.dirname(runtime),
        ),
      );
      expect(await engine.available, isTrue);
      final native = DocxTableStructureEngine(
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
            docxTableStructure: native,
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
        title: 'Writer table',
        fileName: 'table.docx',
        bytes: source,
      );
      final before = await store.commitEdited(
        await store.beginEdit(note),
        originalBytes: source,
        pdfBytes: sourcePdf,
        engineVersion: 'A150 Writer fixture',
        pageCount: 1,
      );
      final page = await client!.call(
        'read_document',
        _read(note.id, {'tableLimit': 1}),
      );
      expect(page.isError, isFalse, reason: '${page.data}');
      expect(page.data['sourceRevisionId'], before.revision.revisionId);
      expect(page.data['sourceSha256'], before.originalSha256);
      expect(page.data['tableTotal'], 2);
      expect(page.data['nextTableOffset'], 1);
      expect(
        (page.data['tables'] as List).single,
        containsPair('tableIndex', 0),
      );

      final request = _edit(
        note.id,
        before,
        operations: [_operation(before, tableIndex: 0)],
      );
      final denied = await client!.call('office_edit', request);
      expect(denied.isError, isTrue);
      expect(denied.data['code'], 'read_only');
      await access!.allowEdits(true);
      final saved = await client!.call('office_edit', request);
      expect(saved.isError, isFalse, reason: '${saved.data}');
      final edited = await store.readLatest(note);
      expect(edited.revision.parentRevisionIds, [before.revision.revisionId]);
      expect(edited.originalSha256, saved.data['sourceSha256']);
      expect(edited.pdfSha256, saved.data['pdfSha256']);
      expect(edited.bindingId, isNot(before.bindingId));
      expect(edited.pageCount, 1);

      const part = 'word/document.xml';
      final originalMembers = _members(source),
          editedMembers = _members(edited.originalBytes);
      expect(editedMembers.keys.toSet(), originalMembers.keys.toSet());
      for (final name in originalMembers.keys.where((name) => name != part)) {
        expect(editedMembers[name], originalMembers[name], reason: name);
      }
      final originalTables = _wordTables(originalMembers[part]!);
      final editedTables = _wordTables(editedMembers[part]!);
      expect(editedTables.first, [
        for (final row in originalTables.first) [...row.take(2), '', row.last],
      ]);
      expect(editedTables.last, originalTables.last);

      Pdfrx.pdfiumModulePath = p.absolute(pdfium!);
      await pdfrxInitialize(tmpPath: root.path);
      final rendered = await PdfDocument.openData(edited.pdfBytes!);
      try {
        expect(rendered.pages, hasLength(1));
        final text = (await rendered.pages.single.loadText())!.fullText;
        for (final marker in [
          'A150_A1',
          'A150_B2',
          'A150_KEEP_B2',
          'A150_BODY_AFTER',
        ]) {
          expect(text, contains(marker));
        }
      } finally {
        await rendered.dispose();
      }

      await stop();
      await start();
      await access!.allowEdits(true);
      final replay = await client!.call('office_edit', request);
      expect(replay.isError, isFalse, reason: '${replay.data}');
      expect(replay.data, saved.data);
      final reopened = OfficeDocumentStore(controller!.repository);
      expect(
        (await reopened.readLatest(note)).revision.revisionId,
        edited.revision.revisionId,
      );
      final previous = await reopened.readLatest(
        note,
        revisionId: before.revision.revisionId,
      );
      expect(previous.originalBytes, source);
      expect(previous.pdfBytes, sourcePdf);
      expect(await sourceFile.readAsBytes(), source);
      expect(await pdfFile.readAsBytes(), sourcePdf);
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip:
        !Platform.isWindows ||
        executable == null ||
        runtime == null ||
        fixture == null ||
        library == null ||
        pdfium == null,
  );
}

Map<String, Uint8List> _members(List<int> bytes) {
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

List<List<List<String>>> _wordTables(List<int> xml) {
  const word = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
  final root = XmlDocument.parse(utf8.decode(xml)).rootElement;
  final body = root.findElements('body', namespace: word).single;
  return [
    for (final table in body.findElements('tbl', namespace: word))
      [
        for (final row in table.findElements('tr', namespace: word))
          [
            for (final cell in row.findElements('tc', namespace: word))
              cell
                  .findAllElements('t', namespace: word)
                  .map((text) => text.innerText)
                  .join(),
          ],
      ],
  ];
}

Future<void> _deleteOwnedTemp(Directory root) async {
  final owned = await root.resolveSymbolicLinks();
  final system = await Directory.systemTemp.resolveSymbolicLinks();
  expect(p.equals(p.dirname(owned), system), isTrue);
  expect(p.basename(owned), startsWith(_tempPrefix));
  await Directory(owned).delete(recursive: true);
}
