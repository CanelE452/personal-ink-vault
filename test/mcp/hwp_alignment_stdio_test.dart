import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable =
      Platform.environment['INK_VAULT_MCP_TEST_EXE'] ??
      p.absolute('build/native/windows/ink_vault_mcp.exe');
  final library = Platform.environment['PIV_HWP_ALIGNMENT_TEST_DLL'];
  final fixtures = Platform.environment['PIV_HWP_ALIGNMENT_TEST_FIXTURES'];
  final hwp5RowFixture = Platform.environment['PIV_HWP5_ROW_FIXTURE'];
  final fonts = p.absolute('build/native/fonts');

  for (final (extension, starterOperation) in [
    ('hwp', null),
    ('hwpx', null),
    ('hwpx', 'paragraphInsert'),
    ('hwp', 'paragraphInsert'),
    ('hwpx', 'tableInsert'),
    ('hwpx', 'populatedTableInsert'),
    ('hwpx', 'tableStructure'),
    ('hwp', 'hwp5TableRows'),
  ]) {
    final hwp5Paragraph =
        extension == 'hwp' && starterOperation == 'paragraphInsert';
    final needsHwp5Fixture =
        hwp5Paragraph || starterOperation == 'hwp5TableRows';
    final fixture = switch (starterOperation) {
      _ when needsHwp5Fixture && hwp5RowFixture != null => File(hwp5RowFixture),
      null when fixtures != null => File(
        p.join(fixtures, 'synthetic-original.$extension'),
      ),
      _ => null,
    };
    final unavailable =
        !Platform.isWindows ||
        library == null ||
        !File(library).existsSync() ||
        ((starterOperation == null || needsHwp5Fixture) &&
            (fixture == null || !fixture.existsSync())) ||
        !File(executable).existsSync() ||
        !File(p.join(fonts, 'NotoSansCJKkr-Regular.otf')).existsSync();
    test(
      switch (starterOperation) {
        'paragraphInsert' when hwp5Paragraph => 'actual Rust stdio inserts a paragraph in a real HWP5 original and replays across restart',
        'paragraphInsert' => 'actual Rust stdio inserts an HWPX starter paragraph and replays across restart',
        'tableInsert' => 'actual Rust stdio inserts an HWPX starter table and replays across restart',
        'populatedTableInsert' => 'actual Rust stdio inserts populated HWPX cells and replays across restart',
        'tableStructure' => 'actual Rust stdio changes an existing HWPX table and edits a new cell',
        'hwp5TableRows' =>
          'actual Rust stdio adds and removes a row in a real HWP5 original',
        _ =>
          'actual Rust stdio $extension alignment preserves originals and guards retry across restart',
      },
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'piv-hwp-alignment-stdio-',
        );
        final temporaryParent = await Directory.systemTemp
            .resolveSymbolicLinks();
        try {
          await IOOverrides.runZoned(
            () => _workflow(
              extension: extension,
              starterOperation: starterOperation,
              fixture: fixture,
              executable: executable,
              library: library!,
              fonts: fonts,
              temporary: temporary,
            ),
            getSystemTempDirectory: () => temporary,
          );
        } finally {
          if (temporary.existsSync()) {
            final owned = await temporary.resolveSymbolicLinks();
            expect(p.isWithin(temporaryParent, owned), isTrue);
            expect(p.basename(owned), startsWith('piv-hwp-alignment-stdio-'));
            await Directory(owned).delete(recursive: true);
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: unavailable
          ? 'Set the HWP DLL and use the built Rust MCP executable and fonts; alignment also needs the synthetic fixtures'
          : false,
    );
  }
}

Future<void> _workflow({
  required String extension,
  required String? starterOperation,
  required File? fixture,
  required String executable,
  required String library,
  required String fonts,
  required Directory temporary,
}) async {
  const starterTitle = '한글 제목 😀';
  final starter = fixture == null
      ? OfficeTemplates.create(OfficeTemplateKind.hwpx, title: starterTitle)
      : null;
  final input = starter?.bytes ?? await fixture!.readAsBytes();
  final inputHash = sha256.convert(input).toString();
  final hwp5Paragraph =
      extension == 'hwp' && starterOperation == 'paragraphInsert';
  if (hwp5Paragraph) {
    expect(
      inputHash,
      '4ff3c231d835f37ceaa08ccd41f7db66d74d65a5a03c0791f6f683cc9fde0d39',
    );
  }
  final fileName = starter?.fileName ?? 'source.$extension';
  final executableHash = await _hash(File(executable));
  final libraryHash = await _hash(File(library));
  final vault = Directory(p.join(temporary.path, 'vault'));
  WorkspaceController? controller = WorkspaceController(
    await NoteRepository.open(vault, createFormatVersion: 2),
    directoryProvider: () async => Directory(p.join(temporary.path, 'support')),
  );
  McpAccessController? access;
  _Client? client;
  final exits = <int>[];

  Future<void> start() async {
    final currentController = controller!;
    access = McpAccessController(
      () => VaultMcpService(
        currentController,
        prepareMutation: currentController.flush,
        hwpEngine: HwpStructuredOfficeEngine(
          libraryPath: library,
          fontDirectory: fonts,
        ),
      ),
      executable: executable,
      supportDirectory: () async =>
          Directory(p.join(temporary.path, 'support')),
    );
    await access!.start();
    final config =
        (access!.clientConfiguration['mcpServers'] as Map)['personal-ink-vault']
            as Map;
    client = _Client(
      await Process.start(
        executable,
        List<String>.from(config['args'] as List),
      ),
    );
    final initialized = await client!.request('initialize', {
      'protocolVersion': '2025-11-25',
      'capabilities': <String, Object?>{},
      'clientInfo': {
        'name': 'piv-hwp-native-edit-regression',
        'version': '1.0',
      },
    });
    expect(initialized['error'], isNull);
    client!.process.stdin.writeln(
      jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
    );
  }

  Future<void> stop() async {
    final closing = client;
    client = null;
    if (closing != null) exits.add(await closing.close());
    await access?.stop();
    access?.dispose();
    access = null;
  }

  Future<void> reopen() async {
    await stop();
    final previous = controller!;
    controller = null;
    try {
      await previous.flush();
    } finally {
      previous.dispose();
      await previous.repository.close();
    }
    controller = WorkspaceController(
      await NoteRepository.open(vault),
      directoryProvider: () async =>
          Directory(p.join(temporary.path, 'support')),
    );
    await start();
  }

  Future<Map<String, dynamic>> read(
    String noteId, {
    String? revisionId,
  }) async => client!.data(
    await client!.tool('read_document', {
      'noteId': noteId,
      'revisionId': ?revisionId,
    }),
  );

  Future<Set<String>> revisions() async =>
      (await controller!.repository.revisions())
          .map((revision) => revision.revisionId)
          .toSet();

  Map<String, dynamic> office(Map<String, dynamic> document) =>
      Map<String, dynamic>.from(document['office'] as Map);

  Map<String, dynamic> paragraph(Map<String, dynamic> document, String id) =>
      Map<String, dynamic>.from(
        (office(document)['paragraphs'] as List).singleWhere(
          (value) => value['id'] == id,
        ) as Map,
      );

  Map<String, Object?> request(
    String noteId,
    Map<String, dynamic> document,
    String id,
    String alignment, {
    String? textHash,
  }) => {
    'noteId': noteId,
    'expectedRevisionId': office(document)['sourceRevisionId'],
    'requestId': newId(),
    'operations': [
      {
        'op': 'paragraphFormat',
        'id': id,
        'expectedTextSha256':
            textHash ?? paragraph(document, id)['textDetails']['textSha256'],
        'alignment': alignment,
      },
    ],
  };

  try {
    expect(
      await HwpStructuredOfficeEngine(
        libraryPath: library,
        fontDirectory: fonts,
      ).available,
      isTrue,
    );
    final store = OfficeDocumentStore(controller!.repository);
    final note = await store.importDocument(
      title: starter != null ? starterTitle : '원본 정렬 $extension',
      fileName: fileName,
      bytes: input,
    );
    final summary = await WorkspaceStore(controller!.repository).open(note);
    const markdown = '# 별도 Markdown\n\nHWP 원문 정렬과 독립적인 정리 😀\n';
    await summary.saveMarkdown(markdown);
    final originalEdition = await store.readLatest(note);
    expect(originalEdition.originalBytes, input);
    expect(originalEdition.originalSha256, inputHash);

    await start();
    var current = await read(note.id);
    final initialOffice = office(current);
    expect(
      initialOffice['available'],
      isTrue,
      reason: jsonEncode(initialOffice),
    );
    expect(initialOffice['kind'], 'word');
    expect(initialOffice['sourceSha256'], inputHash);
    expect(
      initialOffice['sourceRevisionId'],
      originalEdition.revision.revisionId,
    );
    if (starterOperation == 'hwp5TableRows') {
      await access!.allowEdits(true);
      Map<String, dynamic> targetTable(Map<String, dynamic> source) =>
          (source['tables'] as List).cast<Map<String, dynamic>>().singleWhere(
            (table) => table['id'] == 's0:p2:t0',
          );
      final initialTable = targetTable(initialOffice);
      final originalId = originalEdition.revision.revisionId;
      final add = {
        'noteId': note.id,
        'expectedRevisionId': originalId,
        'requestId': newId(),
        'operations': [
          {
            'op': 'tableStructure',
            'id': initialTable['id'],
            'action': 'insertRow',
            'index': 1,
          },
        ],
      };
      final added = client!.data(await client!.tool('office_edit', add));
      final addedId = added['revisionId'] as String;
      expect(addedId, isNot(originalId));
      expect(client!.data(await client!.tool('office_edit', add)), added);
      expect(initialTable['structure'], {
        'rows': 3,
        'columns': 2,
        'canInsertRow': true,
        'canDeleteRow': true,
        'canInsertColumn': false,
        'canDeleteColumn': false,
      });
      final newTable = targetTable(office(await read(note.id)));
      expect(newTable['structure']['rows'], 4);
      expect(newTable['cells']['1,0'], '');
      expect(newTable['cells']['1,1'], '');
      final addedEdition = await store.readLatest(note);
      expect(addedEdition.pdfBytes, isNotEmpty);
      expect(addedEdition.revision.parentRevisionIds, [originalId]);
      final removed = client!.data(
        await client!.tool('office_edit', {
          'noteId': note.id,
          'expectedRevisionId': addedId,
          'requestId': newId(),
          'operations': [
            {
              'op': 'tableStructure',
              'id': initialTable['id'],
              'action': 'deleteRow',
              'index': 1,
            },
          ],
        }),
      );
      expect(removed['revisionId'], isNot(addedId));
      final finalTable = targetTable(office(await read(note.id)));
      expect(finalTable['cells'], initialTable['cells']);
      expect(
        (await store.readLatest(note, revisionId: originalId)).originalBytes,
        input,
      );
      await stop();
      expect(exits, [0]);
      return;
    }
    if (starter != null || hwp5Paragraph) {
      final changesTable = starterOperation == 'tableStructure';
      final populatedTable =
          starterOperation == 'populatedTableInsert' || changesTable;
      final insertTable = populatedTable || starterOperation == 'tableInsert';
      final initialParagraphs = (initialOffice['paragraphs'] as List)
          .cast<Map>();
      final anchor = hwp5Paragraph
          ? paragraph(current, 's0:p1')
          : initialParagraphs.single;
      final anchorId = anchor['id'] as String;
      final anchorIndex = initialParagraphs.indexWhere(
        (value) => value['id'] == anchorId,
      );
      expect(anchorIndex, greaterThanOrEqualTo(0));
      final anchorText = hwp5Paragraph ? '연안 안전정보 서비스 제안요청서' : starterTitle;
      expect(anchor['text'], anchorText);
      expect(anchor['structure']['canInsertAfter'], isTrue);
      if (insertTable) {
        expect(initialOffice['supportsHwpTableInsert'], isTrue);
        expect(anchor['tableInsertAnchor'], isTrue);
      }
      final anchorDigest = sha256.convert(utf8.encode(anchorText)).toString();
      expect(anchor['textDetails']['textSha256'], anchorDigest);

      final originalId = originalEdition.revision.revisionId;
      final before = await read(note.id, revisionId: originalId);
      final originalRecord = before['revision'] as Map;
      expect(originalRecord['revisionId'], originalId);
      expect(originalRecord['files'][fileName], {
        'sha256': inputHash,
        'length': input.length,
      });
      final body = hwp5Paragraph ? '제목 아래 HWP5 본문' : '제목 아래 본문 😀 <A&B>';
      final cells = populatedTable
          ? [
              ['  제목 & <값>  ', ''],
              ['둘째 행', '끝'],
            ]
          : List.generate(2, (_) => ['', '']);
      final operation = {
        'op': insertTable ? 'tableInsert' : starterOperation,
        'id': insertTable ? 'starter-table-draft' : 'starter-body-draft',
        'referenceId': anchorId,
        'position': 'after',
        'expectedTextSha256': anchorDigest,
        if (insertTable) 'rows': 2,
        if (insertTable) 'columns': 2,
        if (populatedTable) 'cells': cells,
        if (!insertTable) 'text': body,
      };
      final args = {
        'noteId': note.id,
        'expectedRevisionId': originalId,
        'requestId': newId(),
        'operations': [operation],
      };
      await access!.allowEdits(true);
      final saved = client!.data(await client!.tool('office_edit', args));
      final committed = await revisions();
      final savedId = saved['revisionId'] as String;
      expect(savedId, isNot(originalId));
      expect(saved['sourceSha256'], isNot(inputHash));
      expect(saved['pageCount'], greaterThan(0));
      expect(saved['pdfSha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(client!.data(await client!.tool('office_edit', args)), saved);
      expect(await revisions(), committed);

      await reopen();
      final reopened = await read(note.id);
      expect(office(reopened)['sourceRevisionId'], savedId);
      expect(office(reopened)['sourceSha256'], saved['sourceSha256']);
      expect(reopened['markdown'], current['markdown']);
      final paragraphs = (office(reopened)['paragraphs'] as List).cast<Map>();
      final expectedParagraphs = initialParagraphs
          .map((value) => value['text'])
          .toList();
      if (!insertTable) expectedParagraphs.insert(anchorIndex + 1, body);
      expect(
        paragraphs.map((paragraph) => paragraph['text']),
        expectedParagraphs,
      );
      expect(paragraphs[anchorIndex]['id'], anchorId);
      if (insertTable) {
        final table = (office(reopened)['tables'] as List).single as Map;
        expect(table['id'], 's0:p1:t0');
        expect(table['cells'], {
          for (var row = 0; row < cells.length; row++)
            for (var column = 0; column < cells[row].length; column++)
              '$row,$column': cells[row][column],
        });
      } else {
        final inserted = paragraphs[anchorIndex + 1];
        expect(inserted['id'], isNot(anchorId));
        expect(inserted['structure']['canInsertAfter'], isTrue);
        if (hwp5Paragraph) {
          expect(inserted['id'], 's0:p2');
          expect(inserted['paragraphFormat'], anchor['paragraphFormat']);
          Map firstTable(Map<String, dynamic> value, String id) =>
              (value['tables'] as List).cast<Map>().singleWhere(
                (table) => table['id'] == id,
              );
          expect(
            firstTable(office(reopened), 's0:p3:t0')['cells'],
            firstTable(initialOffice, 's0:p2:t0')['cells'],
          );
        }
      }
      expect(await read(note.id, revisionId: originalId), before);

      final reopenedStore = OfficeDocumentStore(controller!.repository);
      final editedEdition = await reopenedStore.readLatest(note);
      expect(editedEdition.revision.parentRevisionIds, [originalId]);
      expect(p.extension(editedEdition.originalFileName), '.$extension');
      expect(editedEdition.pdfSha256, saved['pdfSha256']);
      expect(editedEdition.pdfBytes!.take(5), '%PDF-'.codeUnits);
      expect(
        (await reopenedStore.readLatest(
          note,
          revisionId: originalId,
        )).originalBytes,
        input,
      );
      await access!.allowEdits(true);
      expect(client!.data(await client!.tool('office_edit', args)), saved);
      expect(await revisions(), committed);
      if (populatedTable) {
        final reused = await client!.tool('office_edit', {
          ...args,
          'operations': [
            {
              ...operation,
              'cells': [
                ['바뀐 값', ''],
                cells[1],
              ],
            },
          ],
        });
        expect(reused['isError'], isTrue);
        expect(client!.payload(reused)['code'], 'request_id_reused');
        expect(await revisions(), committed);
      }
      if (insertTable) {
        var editRevision = savedId;
        if (changesTable) {
          final snapshot = (office(reopened)['tables'] as List).single as Map;
          expect(snapshot['structure'], {
            'rows': 2,
            'columns': 2,
            'canInsertRow': true,
            'canDeleteRow': true,
            'canInsertColumn': true,
            'canDeleteColumn': true,
          });
          final previousRead = await read(note.id, revisionId: savedId);
          final previousEdition = await reopenedStore.readLatest(
            note,
            revisionId: savedId,
          );
          final resize = {
            'noteId': note.id,
            'expectedRevisionId': savedId,
            'requestId': newId(),
            'operations': [
              {
                'op': 'tableStructure',
                'id': snapshot['id'],
                'action': 'insertRow',
                'index': 1,
              },
            ],
          };
          final resized = client!.data(
            await client!.tool('office_edit', resize),
          );
          editRevision = resized['revisionId'] as String;
          expect(editRevision, isNot(savedId));
          expect(
            client!.data(await client!.tool('office_edit', resize)),
            resized,
          );
          final resizedTable =
              (office(await read(note.id))['tables'] as List).single as Map;
          expect(resizedTable['structure']['rows'], 3);
          expect(resizedTable['cells'], {
            '0,0': cells[0][0],
            '0,1': cells[0][1],
            '1,0': '',
            '1,1': '',
            '2,0': cells[1][0],
            '2,1': cells[1][1],
          });
          expect(
            (await reopenedStore.readLatest(note)).revision.parentRevisionIds,
            [savedId],
          );
          expect(await read(note.id, revisionId: savedId), previousRead);
          final preserved = await reopenedStore.readLatest(
            note,
            revisionId: savedId,
          );
          expect(preserved.originalBytes, previousEdition.originalBytes);
          expect(preserved.pdfBytes, previousEdition.pdfBytes);
        }
        final changed = client!.data(
          await client!.tool('office_edit', {
            'noteId': note.id,
            'expectedRevisionId': editRevision,
            'requestId': newId(),
            'operations': [
              {
                'op': 'tableCellText',
                'tableId': 's0:p1:t0',
                'cell': '1,1',
                'text': '다시 편집한 셀',
              },
            ],
          }),
        );
        expect(changed['revisionId'], isNot(editRevision));
        final updated = office(await read(note.id));
        final table = (updated['tables'] as List).single as Map;
        expect(table['cells']['1,1'], '다시 편집한 셀');
        expect(table['cells']['0,0'], cells[0][0]);
        expect(await read(note.id, revisionId: originalId), before);
      }
      await stop();
      expect(exits, [0, 0]);
      expect(await _hash(File(executable)), executableHash);
      expect(await _hash(File(library)), libraryHash);
      if (hwp5Paragraph) expect(await _hash(fixture!), inputHash);
      return;
    }

    final originalParagraph = Map<String, dynamic>.from(
      (initialOffice['paragraphs'] as List).singleWhere(
        (value) => (value['text'] as String).contains('ORIGINAL_PARAGRAPH'),
      ) as Map,
    );
    final id = originalParagraph['id'] as String;
    final originalText = originalParagraph['text'] as String;
    expect(
      originalParagraph['textDetails']['textSha256'],
      sha256.convert(utf8.encode(originalText)).toString(),
    );
    expect(originalParagraph['paragraphFormat'], isA<Map>());
    expect(originalParagraph['paragraphFormat']['alignment'], isA<String>());
    final unrelatedParagraphs = (initialOffice['paragraphs'] as List)
        .where((value) => value['id'] != id)
        .toList();
    final originalTables = initialOffice['tables'];
    final markdownBefore = current['markdown'];
    final initialRevisions = await revisions();

    final center = request(note.id, current, id, 'center');
    expect((await client!.tool('office_edit', center))['isError'], isTrue);
    expect(await revisions(), initialRevisions);
    expect(
      office(await read(note.id))['sourceRevisionId'],
      originalEdition.revision.revisionId,
    );
    await access!.allowEdits(true);

    final wrongDigest = request(
      note.id,
      current,
      id,
      'center',
      textHash: '0' * 64,
    );
    expect((await client!.tool('office_edit', wrongDigest))['isError'], isTrue);
    expect(await revisions(), initialRevisions);
    final wrongSource = await client!.tool('office_edit', {
      ...center,
      'requestId': newId(),
      'expectedRevisionId': note.revision.revisionId,
    });
    expect(wrongSource['isError'], isTrue);
    expect(client!.payload(wrongSource)['code'], 'revision_conflict');
    expect(await revisions(), initialRevisions);

    Map<String, dynamic>? firstResult;
    Map<String, Object?>? lastRequest;
    Map<String, dynamic>? lastResult;
    for (final alignment in ['center', 'right', 'justify', 'left']) {
      final args = alignment == 'center'
          ? center
          : request(note.id, current, id, alignment);
      final previousRevision = office(current)['sourceRevisionId'];
      final saved = client!.data(await client!.tool('office_edit', args));
      final committed = await revisions();
      expect(saved['revisionId'], isNot(previousRevision));
      expect(saved['sourceEntityId'], note.sourceEntityId);
      expect(saved['pageCount'], greaterThan(0));
      expect(saved['pdfSha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(client!.data(await client!.tool('office_edit', args)), saved);
      expect(await revisions(), committed);
      firstResult ??= saved;
      lastRequest = args;
      lastResult = saved;
      current = await read(note.id);
      expect(office(current)['sourceRevisionId'], saved['revisionId']);
      expect(office(current)['sourceSha256'], saved['sourceSha256']);
      final changed = paragraph(current, id);
      expect(changed['text'], originalText);
      expect(
        changed['textDetails']['textSha256'],
        originalParagraph['textDetails']['textSha256'],
      );
      expect(changed['paragraphFormat']['alignment'], alignment);
      expect(
        (office(current)['paragraphs'] as List)
            .where((value) => value['id'] != id)
            .toList(),
        unrelatedParagraphs,
      );
      expect(office(current)['tables'], originalTables);
      expect(current['markdown'], markdownBefore);
      final edition = await store.readLatest(note);
      expect(p.extension(edition.originalFileName), '.$extension');
      expect(edition.originalSha256, saved['sourceSha256']);
      expect(edition.pdfSha256, saved['pdfSha256']);
      expect(edition.pdfBytes, isNotNull);
      expect(edition.pdfBytes!.take(5), '%PDF-'.codeUnits);
      expect(
        edition.originalBytes.take(extension == 'hwp' ? 8 : 4),
        extension == 'hwp'
            ? [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1]
            : [0x50, 0x4b, 0x03, 0x04],
      );
      expect(
        (await store.readLatest(
          note,
          revisionId: originalEdition.revision.revisionId,
        )).originalBytes,
        input,
      );
      expect(await fixture!.readAsBytes(), input);
    }

    final finalRevisions = await revisions();
    final stale = await client!.tool('office_edit', {
      ...center,
      'requestId': newId(),
    });
    expect(stale['isError'], isTrue);
    expect(client!.payload(stale)['code'], 'revision_conflict');
    final reused = await client!.tool('office_edit', {
      ...lastRequest!,
      'operations': [
        {
          'op': 'paragraphFormat',
          'id': id,
          'expectedTextSha256': originalParagraph['textDetails']['textSha256'],
          'alignment': 'center',
        },
      ],
    });
    expect(reused['isError'], isTrue);
    expect(client!.payload(reused)['code'], 'request_id_reused');
    await access!.allowEdits(false);
    expect(
      (await client!.tool(
        'office_edit',
        request(note.id, current, id, 'center'),
      ))['isError'],
      isTrue,
    );
    expect(await revisions(), finalRevisions);

    await reopen();
    final reopened = await read(note.id);
    expect(office(reopened)['sourceRevisionId'], lastResult!['revisionId']);
    expect(paragraph(reopened, id)['paragraphFormat']['alignment'], 'left');
    expect(reopened['markdown'], markdownBefore);
    expect(await revisions(), finalRevisions);
    await access!.allowEdits(true);
    expect(
      client!.data(await client!.tool('office_edit', center)),
      firstResult,
    );
    expect(
      client!.data(await client!.tool('office_edit', lastRequest)),
      lastResult,
    );
    expect(await revisions(), finalRevisions);
    final reopenedStore = OfficeDocumentStore(controller!.repository);
    expect(
      (await reopenedStore.readLatest(note)).originalSha256,
      lastResult['sourceSha256'],
    );
    expect(
      (await reopenedStore.readLatest(
        note,
        revisionId: originalEdition.revision.revisionId,
      )).originalBytes,
      input,
    );
    final reopenedSummary = await WorkspaceStore(controller!.repository)
        .open(note);
    expect(await reopenedSummary.readMarkdown(), markdown);
    expect(await fixture!.readAsBytes(), input);
    await stop();
    expect(exits, [0, 0]);
    expect(await _hash(File(executable)), executableHash);
    expect(await _hash(File(library)), libraryHash);
    expect(await _hash(fixture), inputHash);
  } finally {
    await stop();
    final remaining = controller;
    if (remaining != null) {
      await remaining.flush();
      remaining.dispose();
      await remaining.repository.close();
    }
  }
}

Future<String> _hash(File file) async =>
    sha256.convert(await file.readAsBytes()).toString();

class _Client {
  new(this.process) {
    subscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final message = Map<String, dynamic>.from(jsonDecode(line) as Map);
          if (message['id'] is int)
            pending.remove(message['id'])?.complete(message);
        });
    errors = process.stderr.drain<void>();
  }
  final Process process;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  late final StreamSubscription<String> subscription;
  late final Future<void> errors;
  var sequence = 0;

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> args,
  ) {
    final id = ++sequence;
    final result = Completer<Map<String, dynamic>>();
    pending[id] = result;
    process.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': args,
      }),
    );
    return result.future.timeout(const Duration(seconds: 40));
  }

  Future<Map<String, dynamic>> tool(
    String name,
    Map<String, Object?> args,
  ) async {
    final response = await request('tools/call', {
      'name': name,
      'arguments': args,
    });
    expect(response['error'], isNull, reason: jsonEncode(response));
    return Map<String, dynamic>.from(response['result'] as Map);
  }

  Map<String, dynamic> payload(Map<String, dynamic> result) =>
      Map<String, dynamic>.from(
        result['structuredContent'] as Map? ??
            jsonDecode(result['content'][0]['text'] as String) as Map,
      );

  Map<String, dynamic> data(Map<String, dynamic> result) {
    expect(result['isError'], isNot(true), reason: jsonEncode(result));
    return payload(result);
  }

  Future<int> close() async {
    await process.stdin.close();
    try {
      final exit = await process.exitCode.timeout(const Duration(seconds: 10));
      await subscription.cancel();
      await errors;
      return exit;
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      await subscription.cancel();
      await errors;
      rethrow;
    }
  }
}
