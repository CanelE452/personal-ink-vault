import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/pptx_slide_reorder.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';
import 'package:xml/xml.dart';

import '../../integration_test/support/windows_mcp_rpc.dart';

const _prefix = 'piv-pptx-section-stdio-';
const _sourceSha =
    '640696b580c54023a923c466d4f33aad9736a32744dc354ead4143b974ea3288';
const _pdfSha =
    'f88821a90d6786f19501ee8d7583e34bc2d045a4b72b262dc5be494f02e6cc17';
const _inkSha =
    'ac8da508357ae1b1d26342769d4691ab76a56e41f77d47da7954e1f4e63db300';
const _presentation = 'ppt/presentation.xml';
const _sectionNamespace =
    'http://schemas.microsoft.com/office/powerpoint/2010/main';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final fixture = env['PIV_PPTX_SECTION_FIXTURE'];
  final executable = env['INK_VAULT_MCP_TEST_EXE'];
  final runtime = env['PIV_PPTX_SECTION_RUNTIME'];
  final originalPdfPath = env['PIV_PPTX_SECTION_PDF'];
  final pdfium = env['PIV_PDF_ANCHOR_TEST_PDFIUM'];
  final native = env['INK_VAULT_NATIVE_LIBRARY'];
  test(
    'PPTX section authority reads current source before calling Rust stdio',
    () async {
      final original = await File(fixture!).readAsBytes();
      expect(sha256.convert(original).toString(), _sourceSha);
      final root = await Directory.systemTemp.createTemp(_prefix);
      final repository = await NoteRepository.open(
        Directory(p.join(root.path, 'vault')),
        createFormatVersion: 2,
      );
      final controller = WorkspaceController(
        repository,
        directoryProvider: () async => Directory(p.join(root.path, 'support')),
      );
      addTearDown(() async {
        try {
          await controller.flush();
        } finally {
          controller.dispose();
          await repository.close();
          await _removeOwned(root);
        }
      });

      final store = OfficeDocumentStore(repository);
      final note = await store.importDocument(
        title: 'Synthetic sectioned presentation',
        fileName: 'original.pptx',
        bytes: original,
      );
      final edition = await store.readLatest(note);
      final service = VaultMcpService(
        controller,
        pptxSlideReorder: PptxSlideReorderEngine(
          libraryPath: p.absolute(native!),
        ),
      );
      final authority = await service.call(
        'read_document',
        {'noteId': note.id, 'pptxSlideOrder': true},
        context: VaultMcpCallContext(
          isActive: () => true,
          canWrite: () => false,
        ),
      );
      expect(authority, containsPair('sourceSha256', _sourceSha));
      expect(
        authority,
        containsPair('sourceRevisionId', edition.revision.revisionId),
      );
      final slides = (authority as Map)['slides'] as List;
      expect(slides.map((slide) => slide['sectionGroup']), [0, 0, 1]);
    },
    skip: !Platform.isWindows || fixture == null || native == null
        ? 'Set PIV_PPTX_SECTION_FIXTURE and INK_VAULT_NATIVE_LIBRARY'
        : false,
  );

  test(
    'actual Rust stdio saves a section-only PPTX move and replays after restart',
    () async {
      final original = await File(fixture!).readAsBytes();
      final originalPdf = await File(originalPdfPath!).readAsBytes();
      final originalInk = await File(
        p.join('test', 'sbn_examples', 'v19_shape_strokes.sbn2'),
      ).readAsBytes();
      expect(sha256.convert(original).toString(), _sourceSha);
      expect(sha256.convert(originalPdf).toString(), _pdfSha);
      expect(sha256.convert(originalInk).toString(), _inkSha);
      final engine = _InspectableWindowsOfficeEngine(
        runtimePath: p.absolute(runtime!),
        helperDirectory: p.absolute('windows', 'office_engine'),
      );
      expect(await engine.available, isTrue);
      final root = await Directory.systemTemp.createTemp(_prefix);
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
            pptxSlideReorder: PptxSlideReorderEngine(
              libraryPath: p.absolute(native!),
            ),
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
          await _removeOwned(root);
        }
      });

      await start();
      final repo = controller!.repository;
      final store = OfficeDocumentStore(repo);
      final note = await store.importDocument(
        title: 'Synthetic sectioned presentation',
        fileName: 'original.pptx',
        bytes: original,
      );
      final before = await store.commitEdited(
        await store.beginEdit(note),
        originalBytes: original,
        pdfBytes: originalPdf,
        engineVersion: 'Impress reference fixture',
        pageCount: 3,
      );
      final annotation = await OfficeAnnotationStore(repo).open(note, before);
      final inkRevision = await annotation.saveFiles({
        'main.sbn2': originalInk,
      });
      final read = {'noteId': note.id, 'pptxSlideOrder': true};
      final authority = await client!.call('read_document', read);
      expect(authority.isError, isFalse, reason: '${authority.data}');
      expect(authority.data['sourceRevisionId'], before.revision.revisionId);
      expect(authority.data['sourceSha256'], _sourceSha);
      expect(authority.data['slideCount'], 3);
      final slides = authority.data['slides'] as List;
      expect(slides.map((slide) => slide['index']), [0, 1, 2]);
      expect(slides.map((slide) => slide['sectionGroup']), [0, 0, 1]);

      final invalidRead = await client!.call('read_document', {
        ...read,
        'revisionId': null,
      });
      expect(invalidRead.isError, isTrue);
      expect(invalidRead.data['code'], 'invalid_arguments');

      Map<String, Object?> edit({
        int source = 1,
        int target = 2,
        String sourceSha = _sourceSha,
      }) => {
        'noteId': note.id,
        'expectedRevisionId': before.revision.revisionId,
        'requestId': newId(),
        'operations': [
          {
            'op': 'pptxSlideSectionMove',
            'sourceIndex': source,
            'targetIndex': target,
            'after': false,
            'expectedSourceSha256': sourceSha,
          },
        ],
      };

      final request = edit();
      final denied = await client!.call('office_edit', request);
      expect(denied.isError, isTrue);
      expect(denied.data['code'], 'read_only');
      await access!.allowEdits(true);
      final wrongHash = await client!.call(
        'office_edit',
        edit(sourceSha: 'a' * 64),
      );
      expect(wrongHash.isError, isTrue);
      expect(wrongHash.data['code'], 'office_source_mismatch');
      final sameGroup = await client!.call(
        'office_edit',
        edit(source: 0, target: 1),
      );
      expect(sameGroup.isError, isTrue);
      expect(sameGroup.data['code'], 'invalid_arguments');
      expect(
        (await store.readLatest(note)).revision.revisionId,
        before.revision.revisionId,
      );

      final saved = await client!.call('office_edit', request);
      expect(saved.isError, isFalse, reason: '${saved.data}');
      expect(saved.data['pageCount'], 3);
      final after = await store.readLatest(note);
      expect(after.revision.parentRevisionIds, [before.revision.revisionId]);
      expect(after.originalSha256, saved.data['sourceSha256']);
      expect(after.pdfSha256, saved.data['pdfSha256']);
      expect(after.bindingId, isNot(before.bindingId));
      _expectSectionOnly(original, after.originalBytes);

      Pdfrx.pdfiumModulePath = p.absolute(pdfium!);
      await pdfrxInitialize(tmpPath: root.path);
      final pdf = await PdfDocument.openData(after.pdfBytes!);
      try {
        expect(pdf.pages, hasLength(3));
        for (var index = 0; index < 3; index++) {
          expect(
            (await pdf.pages[index].loadText())!.fullText,
            contains('DIRECT_SLIDE_$index'),
          );
        }
      } finally {
        await pdf.dispose();
      }

      await stop();
      await start();
      final reopenedRepo = controller!.repository;
      final reopened = OfficeDocumentStore(reopenedRepo);
      final savedAuthority = await client!.call('read_document', read);
      expect(savedAuthority.isError, isFalse, reason: '${savedAuthority.data}');
      expect(
        savedAuthority.data['sourceRevisionId'],
        after.revision.revisionId,
      );
      expect(
        (savedAuthority.data['slides'] as List).map(
          (slide) => slide['sectionGroup'],
        ),
        [0, 1, 1],
      );
      final previous = await reopened.readLatest(
        note,
        revisionId: before.revision.revisionId,
      );
      expect(previous.originalBytes, original);
      expect(previous.pdfBytes, originalPdf);
      expect(
        (await reopenedRepo.readFiles(inkRevision))['main.sbn2'],
        originalInk,
      );
      expect(await reopenedRepo.heads(after.bindingId!), isEmpty);

      await access!.allowEdits(true);
      final replay = await client!.call('office_edit', request);
      expect(replay.isError, isFalse, reason: '${replay.data}');
      expect(replay.data, saved.data);
      final stale = await client!.call('office_edit', edit());
      expect(stale.isError, isTrue);
      expect(stale.data['code'], 'revision_conflict');
      expect(
        (await reopenedRepo.revisions()).where(
          (row) => row.entityId == note.sourceEntityId,
        ),
        hasLength(3),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip:
        !Platform.isWindows ||
        fixture == null ||
        executable == null ||
        runtime == null ||
        originalPdfPath == null ||
        pdfium == null ||
        native == null,
  );
}

Future<void> _removeOwned(Directory root) async {
  final owned = await root.resolveSymbolicLinks();
  final temp = await Directory.systemTemp.resolveSymbolicLinks();
  expect(p.equals(p.dirname(owned), temp), isTrue);
  expect(p.basename(owned), startsWith(_prefix));
  await Directory(owned).delete(recursive: true);
}

class _InspectableWindowsOfficeEngine extends WindowsOfficeEngine {
  _InspectableWindowsOfficeEngine({super.runtimePath, super.helperDirectory});

  @override
  Future<WindowsOfficeSnapshot> inspect(
    String sourcePath, {
    bool preview = false,
  }) async {
    try {
      return await super.inspect(sourcePath, preview: preview);
    } on WindowsOfficeException catch (error) {
      printOnFailure('Office preview ${error.code}: ${error.safeDiagnostics}');
      rethrow;
    }
  }
}

void _expectSectionOnly(Uint8List before, Uint8List after) {
  Map<String, List<int>> files(Uint8List bytes) => {
    for (final member in ZipDecoder().decodeBytes(bytes, verify: true).files)
      if (member.isFile) member.name: member.content,
  };
  final original = files(before);
  final edited = files(after);
  expect(edited.keys.toSet(), original.keys.toSet());
  expect(
    original.keys.where((name) => !listEquals(original[name], edited[name])),
    [_presentation],
  );
  final originalXml = utf8.decode(original[_presentation]!);
  final editedXml = utf8.decode(edited[_presentation]!);
  final listing = RegExp(r'<p:sldIdLst>.*?</p:sldIdLst>', dotAll: true);
  expect(
    listing.firstMatch(editedXml)!.group(0),
    listing.firstMatch(originalXml)!.group(0),
  );
  final doc = XmlDocument.parse(editedXml);
  final sections = doc.findAllElements('section', namespace: _sectionNamespace);
  expect(
    sections.map(
      (section) => section
          .findAllElements('sldId', namespace: _sectionNamespace)
          .map((slide) => slide.getAttribute('id'))
          .toList(),
    ),
    [
      ['256'],
      ['257', '258'],
    ],
  );
}
