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
  final fonts = p.absolute('build/native/fonts');
  for (final extension in ['hwp', 'hwpx']) {
    final fixture = fixtures == null
        ? null
        : File(p.join(fixtures, 'synthetic-original.$extension'));
    final missing = [
      if (!Platform.isWindows) 'Windows is required for this actual DLL test',
      if (library == null)
        'PIV_HWP_ALIGNMENT_TEST_DLL is not set'
      else if (!File(library).existsSync())
        'The explicit HWP DLL does not exist',
      if (fixtures == null)
        'PIV_HWP_ALIGNMENT_TEST_FIXTURES is not set'
      else if (!fixture!.existsSync())
        'The synthetic-original.$extension fixture does not exist',
      if (!File(executable).existsSync())
        'The actual Rust MCP SDK is not built',
      if (!File(p.join(fonts, 'NotoSansCJKkr-Regular.otf')).existsSync())
        'The HWP rendering font is not prepared',
    ];
    test(
      'actual Rust stdio $extension character edits preserve ranges and receipts across restart',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'piv-hwp-character-stdio-',
        );
        final parent = await Directory.systemTemp.resolveSymbolicLinks();
        try {
          await IOOverrides.runZoned(
            () => _workflow(
              extension: extension,
              fixture: fixture!,
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
            expect(p.isWithin(parent, owned), isTrue);
            expect(p.basename(owned), startsWith('piv-hwp-character-stdio-'));
            await Directory(owned).delete(recursive: true);
          }
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: missing.isEmpty ? false : missing.join('; '),
    );
  }
}

Future<void> _workflow({
  required String extension,
  required File fixture,
  required String executable,
  required String library,
  required String fonts,
  required Directory temporary,
}) async {
  final input = await fixture.readAsBytes();
  final inputHash = sha256.convert(input).toString();
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
    access = McpAccessController(
      () => VaultMcpService(
        controller!,
        prepareMutation: controller.flush,
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
      'clientInfo': {'name': 'piv-hwp-character-regression', 'version': '1.0'},
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

  Future<Map<String, dynamic>> read(String id) async =>
      client!.data(await client!.tool('read_document', {'noteId': id}));
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

  try {
    final engine = HwpOfficeEngine(libraryPath: library, fontDirectory: fonts);
    expect(await engine.available, isTrue);
    final store = OfficeDocumentStore(controller.repository);
    final note = await store.importDocument(
      title: '원본 선택 글자 $extension',
      fileName: 'source.$extension',
      bytes: input,
    );
    final summary = await WorkspaceStore(controller.repository).open(note);
    const markdown = '# 별도 Markdown\n\n원문 글자 서식과 독립적인 정리 😀\n';
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
    final originalParagraph = Map<String, dynamic>.from(
      (initialOffice['paragraphs'] as List).singleWhere(
        (value) => (value['text'] as String).contains('ORIGINAL_PARAGRAPH'),
      ) as Map,
    );
    final id = originalParagraph['id'] as String;
    final text = originalParagraph['text'] as String;
    final originalStyles = _styles(originalParagraph);
    expect(originalParagraph['textDetails']['canReplace'], isTrue);
    expect(originalParagraph['textDetails']['canStyle'], isTrue);
    expect(originalParagraph['textDetails']['truncated'], isFalse);
    final unchangedParagraphs = (initialOffice['paragraphs'] as List)
        .where((value) => value['id'] != id)
        .toList();
    final unchangedTables = initialOffice['tables'] as List;
    expect(unchangedTables, isNotEmpty);
    expect(unchangedTables.first['cells'] as Map, isNotEmpty);
    final markdownBefore = current['markdown'];
    final initialRevisions = await revisions();
    final startUtf16 = text.indexOf('ORIGINAL_PARAGRAPH');
    final endUtf16 = startUtf16 + 'ORIGINAL'.length;
    const firstStyle = {
      'bold': true,
      'italic': true,
      'underline': true,
      'fontSize': 18.0,
      'color': 0x2457a7,
    };
    final styled = [
      for (var index = 0; index < text.length; index++)
        if (index >= startUtf16 && index < endUtf16)
          {...originalStyles[index], ...firstStyle}
        else
          originalStyles[index],
    ];
    expect(styled, isNot(originalStyles));

    Map<String, Object?> request(
      Map<String, dynamic> document,
      List<Map<String, Object?>> operations,
    ) => {
      'noteId': note.id,
      'expectedRevisionId': office(document)['sourceRevisionId'],
      'requestId': newId(),
      'operations': operations,
    };

    Map<String, Object?> style(
      String value,
      int start,
      int end,
      Map<String, Object?> format,
    ) => {
      'op': 'textStyle',
      'targetKind': 'paragraph',
      'id': id,
      'startUtf16': start,
      'endUtf16': end,
      'expectedTextSha256': _digest(value),
      ...format,
    };

    void verifyRead(
      Map<String, dynamic> document,
      String expectedText,
      List<Map<String, Object?>> expectedStyles,
    ) {
      final target = paragraph(document, id);
      expect(target['text'], expectedText);
      expect(_styles(target), expectedStyles);
      expect(
        (office(document)['paragraphs'] as List)
            .where((value) => value['id'] != id)
            .toList(),
        unchangedParagraphs,
      );
      expect(office(document)['tables'], unchangedTables);
      expect(document['markdown'], markdownBefore);
      expect(target['paragraphFormat'], originalParagraph['paragraphFormat']);
    }

    Future<List<int>> verifySaved(
      Map<String, dynamic> saved,
      String expectedText,
      List<Map<String, Object?>> expectedStyles,
      String name,
    ) async {
      expect(saved['sourceEntityId'], note.sourceEntityId);
      expect(saved['pageCount'], greaterThan(0));
      final edition = await OfficeDocumentStore(controller!.repository)
          .readLatest(note, revisionId: saved['revisionId'] as String);
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
      final original = await OfficeDocumentStore(controller!.repository)
          .readLatest(note, revisionId: originalEdition.revision.revisionId);
      expect(original.originalBytes, input);
      final path = File(p.join(temporary.path, '$name.$extension'));
      expect(path.existsSync(), isFalse);
      await path.writeAsBytes(edition.originalBytes);
      final direct = await engine.inspect(path.path);
      final snapshot = direct['snapshot'] as Map;
      expect(snapshot['sourceSha256'], edition.originalSha256);
      final target = Map<String, dynamic>.from(
        (snapshot['paragraphs'] as List).singleWhere(
          (value) => value['id'] == id,
        ) as Map,
      );
      expect(target['text'], expectedText);
      expect(_styles(target), expectedStyles);
      expect(await _hash(path), edition.originalSha256);
      expect(await fixture.readAsBytes(), input);
      return edition.originalBytes;
    }

    final firstRequest = request(current, [
      style(text, startUtf16, endUtf16, firstStyle),
    ]);
    expect(
      (await client!.tool('office_edit', firstRequest))['isError'],
      isTrue,
    );
    expect(await revisions(), initialRevisions);
    await access!.allowEdits(true);
    final wrongDigest = request(current, [
      {
        ...style(text, startUtf16, endUtf16, firstStyle),
        'expectedTextSha256': '0' * 64,
      },
    ]);
    expect((await client!.tool('office_edit', wrongDigest))['isError'], isTrue);
    expect(await revisions(), initialRevisions);

    final first = client!.data(await client!.tool('office_edit', firstRequest));
    final firstRevisions = await revisions();
    expect(first['revisionId'], isNot(originalEdition.revision.revisionId));
    expect(
      client!.data(await client!.tool('office_edit', firstRequest)),
      first,
    );
    expect(await revisions(), firstRevisions);
    current = await read(note.id);
    verifyRead(current, text, styled);
    expect(office(current)['sourceRevisionId'], first['revisionId']);
    final firstBytes = await verifySaved(first, text, styled, 'first-readback');

    const inserted = '한😀e\u0301 ';
    final nextText = inserted + text;
    const clearStyle = {'italic': false, 'underline': false};
    const secondStyle = {
      'bold': false,
      ...clearStyle,
      'fontSize': 22.0,
      'color': 0xb3261e,
    };
    final replacement = <String, Object?>{
      'op': 'textReplace',
      'targetKind': 'paragraph',
      'id': id,
      'startUtf16': 0,
      'endUtf16': 0,
      'expectedTextSha256': _digest(text),
      'text': inserted,
    };
    final nextStyles = <Map<String, Object?>>[
      for (var index = 0; index < inserted.length; index++) {...secondStyle},
      for (var index = 0; index < styled.length; index++)
        if (index >= startUtf16 && index < endUtf16)
          {...styled[index], ...clearStyle}
        else
          styled[index],
    ];
    final invalidSequential = request(current, [
      replacement,
      style(text, 0, inserted.length, secondStyle),
    ]);
    expect(
      (await client!.tool('office_edit', invalidSequential))['isError'],
      isTrue,
    );
    expect(await revisions(), firstRevisions);
    final afterInvalid = await read(note.id);
    expect(office(afterInvalid)['sourceRevisionId'], first['revisionId']);
    verifyRead(afterInvalid, text, styled);

    final secondRequest = request(current, [
      replacement,
      style(nextText, 0, inserted.length, secondStyle),
      style(
        nextText,
        inserted.length + startUtf16,
        inserted.length + endUtf16,
        clearStyle,
      ),
    ]);
    final second = client!.data(
      await client!.tool('office_edit', secondRequest),
    );
    final finalRevisions = await revisions();
    expect(second['revisionId'], isNot(first['revisionId']));
    expect(
      client!.data(await client!.tool('office_edit', secondRequest)),
      second,
    );
    expect(await revisions(), finalRevisions);
    current = await read(note.id);
    verifyRead(current, nextText, nextStyles);
    expect(office(current)['sourceRevisionId'], second['revisionId']);
    final secondBytes = await verifySaved(
      second,
      nextText,
      nextStyles,
      'second-readback',
    );
    final stale = await client!.tool('office_edit', {
      ...firstRequest,
      'requestId': newId(),
    });
    expect(stale['isError'], isTrue);
    expect(client!.payload(stale)['code'], 'revision_conflict');
    final reused = await client!.tool('office_edit', {
      ...secondRequest,
      'operations': [
        style(nextText, 0, inserted.length, {'bold': true}),
      ],
    });
    expect(reused['isError'], isTrue);
    expect(client!.payload(reused)['code'], 'request_id_reused');
    expect(await revisions(), finalRevisions);

    await stop();
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    controller = WorkspaceController(
      await NoteRepository.open(vault),
      directoryProvider: () async =>
          Directory(p.join(temporary.path, 'support')),
    );
    await start();
    final reopened = await read(note.id);
    verifyRead(reopened, nextText, nextStyles);
    expect(office(reopened)['sourceRevisionId'], second['revisionId']);
    await access!.allowEdits(true);
    expect(
      client!.data(await client!.tool('office_edit', firstRequest)),
      first,
    );
    expect(
      client!.data(await client!.tool('office_edit', secondRequest)),
      second,
    );
    expect(await revisions(), finalRevisions);
    expect(
      (await OfficeDocumentStore(controller.repository).readLatest(note))
          .originalBytes,
      secondBytes,
    );
    expect(
      (await OfficeDocumentStore(controller.repository).readLatest(
        note,
        revisionId: first['revisionId'] as String,
      )).originalBytes,
      firstBytes,
    );
    final reopenedSummary = await WorkspaceStore(controller.repository)
        .open(note);
    expect(await reopenedSummary.readMarkdown(), markdown);
    await access!.allowEdits(false);
    expect(
      (await client!.tool(
        'office_edit',
        request(reopened, [
          style(nextText, 0, inserted.length, {'bold': true}),
        ]),
      ))['isError'],
      isTrue,
    );
    expect(await revisions(), finalRevisions);
    await stop();
    expect(exits, [0, 0]);
    expect(await _hash(File(executable)), executableHash);
    expect(await _hash(File(library)), libraryHash);
    expect(await _hash(fixture), inputHash);
  } finally {
    await stop();
    if (controller != null) {
      await controller.flush();
      controller.dispose();
      await controller.repository.close();
    }
  }
}

List<Map<String, Object?>> _styles(Map<String, dynamic> paragraph) {
  final text = paragraph['text'] as String;
  final details = paragraph['textDetails'] as Map;
  expect(details['textSha256'], _digest(text));
  expect(details['utf16Length'], text.length);
  expect(details['canStyle'], isTrue);
  expect(details['canReplace'], isTrue);
  expect(details['truncated'], isFalse);
  final styles = <Map<String, Object?>>[];
  for (final run in details['runs'] as List) {
    final start = run['startUtf16'] as int;
    final end = run['endUtf16'] as int;
    expect(start, styles.length);
    expect(end, greaterThan(start));
    expect(end, lessThanOrEqualTo(text.length));
    expect(run['bold'], isA<bool>());
    expect(run['italic'], isA<bool>());
    expect(run['underline'], isA<bool>());
    expect(run['fontSize'], isA<num>());
    expect(run['color'], isA<int>());
    for (var index = start; index < end; index++) {
      styles.add({
        'bold': run['bold'],
        'italic': run['italic'],
        'underline': run['underline'],
        'fontSize': run['fontSize'],
        'color': run['color'],
      });
    }
  }
  expect(styles, hasLength(text.length));
  return styles;
}

String _digest(String text) => sha256.convert(utf8.encode(text)).toString();
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
    final response = Completer<Map<String, dynamic>>();
    pending[id] = response;
    process.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': args,
      }),
    );
    return response.future.timeout(const Duration(seconds: 40));
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
