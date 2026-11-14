import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

import '../../integration_test/support/windows_mcp_rpc.dart';

const _fixtureSha =
    'f4e0190053ab3411c39cdd481cb05014d212a94f03a17fc5196a32bf78312456';
const _tempPrefix = 'piv-pptx-duplicate-stdio-';
const _markers = ['DIRECT_SLIDE_0', 'DIRECT_SLIDE_1', 'DIRECT_SLIDE_2'];
const _expectedOrder = ['DIRECT_SLIDE_0', ..._markers];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable = Platform.environment['INK_VAULT_MCP_TEST_EXE'];
  final runtime = Platform.environment['PIV_PPTX_DUPLICATE_RUNTIME'];
  final fixture = Platform.environment['PIV_PPTX_DUPLICATE_FIXTURE'];
  final pdfium = Platform.environment['PIV_PDF_ANCHOR_TEST_PDFIUM'];

  test(
    'actual Rust stdio duplicates a saved PPTX, reopens it, and replays once',
    () async {
      final fixtureFile = File(fixture!);
      final original = await fixtureFile.readAsBytes();
      expect(sha256.convert(original).toString(), _fixtureSha);
      final engine = WindowsOfficeEngine(
        runtimePath: p.absolute(runtime!),
        helperDirectory: p.absolute('windows', 'office_engine'),
      );
      expect(await engine.available, isTrue);

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
        final previous = controller;
        controller = null;
        if (previous != null) {
          try {
            await previous.flush();
          } finally {
            previous.dispose();
            await previous.repository.close();
          }
        }
      }

      Future<void> start() async {
        final repo = await NoteRepository.open(vault, createFormatVersion: 2);
        final current = WorkspaceController(
          repo,
          directoryProvider: () async => support,
        );
        controller = current;
        final bridge = McpAccessController(
          () => VaultMcpService(current, officeEngine: engine),
          executable: p.absolute(executable!),
          supportDirectory: () async => support,
        );
        access = bridge;
        await bridge.start();
        final servers = bridge.clientConfiguration['mcpServers'] as Map;
        final config = servers['personal-ink-vault'] as Map;
        final arguments = config['args'] as List;
        expect(arguments.first, '--bridge-file');
        client = await WindowsMcpRpc.start(
          config['command'] as String,
          arguments.last as String,
        );
      }

      addTearDown(() async {
        try {
          await stop();
        } finally {
          Pdfrx.pdfiumModulePath = previousPdfium;
          final owned = await root.resolveSymbolicLinks();
          final system = await Directory.systemTemp.resolveSymbolicLinks();
          expect(p.equals(p.dirname(owned), system), isTrue);
          expect(p.basename(owned), startsWith(_tempPrefix));
          await Directory(owned).delete(recursive: true);
        }
      });

      await start();
      final store = OfficeDocumentStore(controller!.repository);
      final note = await store.importDocument(
        title: 'Synthetic PPTX',
        fileName: 'source.pptx',
        bytes: original,
      );
      final before = await store.readLatest(note);
      final initial = await client!.call('read_document', {'noteId': note.id});
      expect(initial.isError, isFalse, reason: '${initial.data}');
      final office = initial.data['office'] as Map;
      expect(office['available'], isTrue, reason: '$office');
      final slides = office['slides'] as List;
      expect(office['sourceRevisionId'], before.revision.revisionId);
      expect(_slideOrder(slides), _markers);
      expect(slides.first, containsPair('canDuplicate', true));
      final request = <String, Object?>{
        'noteId': note.id,
        'expectedRevisionId': office['sourceRevisionId'],
        'requestId': newId(),
        'operations': [
          {'op': 'slideDuplicate', 'id': slides.first['id']},
        ],
      };

      final denied = await client!.call('office_edit', request);
      expect(denied.isError, isTrue);
      expect(denied.data['code'], 'read_only');
      expect(
        (await store.readLatest(note)).revision.revisionId,
        before.revision.revisionId,
      );
      await access!.allowEdits(true);
      final saved = await client!.call('office_edit', request);
      expect(saved.isError, isFalse, reason: '${saved.data}');
      expect(saved.data['pageCount'], 4);

      await stop();
      await start();
      final reopenedStore = OfficeDocumentStore(controller!.repository);
      final reopened = await reopenedStore.readLatest(note);
      expect(reopened.revision.revisionId, saved.data['revisionId']);
      expect(reopened.revision.parentRevisionIds, [before.revision.revisionId]);
      expect(reopened.originalSha256, saved.data['sourceSha256']);
      expect(reopened.pdfSha256, saved.data['pdfSha256']);
      expect(
        sha256.convert(reopened.originalBytes).toString(),
        reopened.originalSha256,
      );
      expect(sha256.convert(reopened.pdfBytes!).toString(), reopened.pdfSha256);
      final prior = await reopenedStore.readLatest(
        note,
        revisionId: before.revision.revisionId,
      );
      expect(prior.originalBytes, original);
      _expectExactCopy(original, reopened.originalBytes);

      final read = await client!.call('read_document', {'noteId': note.id});
      expect(read.isError, isFalse, reason: '${read.data}');
      final savedOffice = read.data['office'] as Map;
      expect(savedOffice['available'], isTrue, reason: '$savedOffice');
      expect(savedOffice['sourceRevisionId'], reopened.revision.revisionId);
      expect(_slideOrder(savedOffice['slides'] as List), _expectedOrder);

      Pdfrx.pdfiumModulePath = p.absolute(pdfium!);
      await pdfrxInitialize(tmpPath: root.path);
      final preview = await PdfDocument.openData(reopened.pdfBytes!);
      try {
        expect(preview.pages, hasLength(4));
        for (var index = 0; index < _expectedOrder.length; index++) {
          final pageText = (await preview.pages[index].loadText())!.fullText;
          expect(pageText, contains(_expectedOrder[index]));
        }
      } finally {
        await preview.dispose();
      }

      await access!.allowEdits(true);
      final replay = await client!.call('office_edit', request);
      expect(replay.isError, isFalse, reason: '${replay.data}');
      expect(replay.data, saved.data);
      final stale = await client!.call('office_edit', {
        ...request,
        'requestId': newId(),
      });
      expect(stale.isError, isTrue);
      expect(stale.data['code'], 'revision_conflict');
      final sourceHistory = (await controller!.repository.revisions())
          .where((revision) => revision.entityId == note.sourceEntityId)
          .map((revision) => revision.revisionId);
      expect(
        sourceHistory,
        unorderedEquals([
          before.revision.revisionId,
          reopened.revision.revisionId,
        ]),
      );
      expect(
        sha256.convert(await fixtureFile.readAsBytes()).toString(),
        _fixtureSha,
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip:
        !Platform.isWindows ||
            executable == null ||
            runtime == null ||
            fixture == null ||
            pdfium == null
        ? 'Set INK_VAULT_MCP_TEST_EXE, PIV_PPTX_DUPLICATE_RUNTIME, '
              'PIV_PPTX_DUPLICATE_FIXTURE, and PIV_PDF_ANCHOR_TEST_PDFIUM'
        : false,
  );
}

List<String> _slideOrder(List<dynamic> slides) => [
  for (final slide in slides)
    (slide['shapes'] as List)
        .map((shape) => shape['text'])
        .whereType<String>()
        .singleWhere(_markers.contains),
];

void _expectExactCopy(Uint8List before, Uint8List after) {
  Map<String, Uint8List> parts(Uint8List bytes) => {
    for (final entry in ZipDecoder().decodeBytes(bytes, verify: true).files)
      if (entry.isFile) entry.name: entry.content,
  };
  final original = parts(before), copied = parts(after);
  const updatedIndexes = {
    '[Content_Types].xml',
    'ppt/_rels/presentation.xml.rels',
    'ppt/presentation.xml',
  };
  for (final entry in original.entries) {
    expect(copied, contains(entry.key));
    if (!updatedIndexes.contains(entry.key)) {
      expect(copied[entry.key], entry.value, reason: entry.key);
    }
  }
  final added = copied.keys.toSet().difference(original.keys.toSet());
  expect(added, hasLength(4));
  for (final part in [
    'ppt/slides/slide1.xml',
    'ppt/notesSlides/notesSlide1.xml',
  ]) {
    final base = part.replaceFirst(RegExp(r'1\.xml$'), '');
    final clone = added.singleWhere((name) => name.startsWith(base));
    expect(copied[clone], original[part], reason: clone);
  }
}
