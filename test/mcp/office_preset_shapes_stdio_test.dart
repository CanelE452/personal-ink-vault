import 'dart:convert';
import 'dart:io';

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
import 'package:xml/xml.dart';

import '../../integration_test/support/windows_mcp_rpc.dart';

const _fixtureSha =
    '4cee0278fb6e36ee271491a206de1a5d6a27fb8d23731410614f380ce9fed1bf';
const _tempPrefix = 'piv-pptx-presets-stdio-';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final executable = env['INK_VAULT_MCP_TEST_EXE'];
  final runtime = env['PIV_PPTX_PRESETS_RUNTIME'];
  final fixture = env['PIV_PPTX_PRESETS_FIXTURE'];
  final pdfium = env['PIV_PDF_ANCHOR_TEST_PDFIUM'];

  test(
    'actual MCP edits an imported Android preset and creates both native shapes',
    () async {
      final fixtureFile = File(fixture!);
      final original = await fixtureFile.readAsBytes();
      expect(sha256.convert(original).toString(), _fixtureSha);
      final engine = WindowsOfficeEngine(
        runtimePath: p.absolute(runtime!),
        helperDirectory: p.absolute(
          env['PIV_PPTX_PRESETS_HELPERS'] ?? p.join('windows', 'office_engine'),
        ),
      );
      expect(await engine.available, isTrue);
      final root = await Directory.systemTemp.createTemp(_tempPrefix);
      final support = Directory(p.join(root.path, 'support'));
      final previousPdfium = Pdfrx.pdfiumModulePath;
      WorkspaceController? controller;
      McpAccessController? access;
      WindowsMcpRpc? client;
      addTearDown(() async {
        try {
          await client?.close();
          await access?.stop();
          access?.dispose();
          final current = controller;
          if (current != null) {
            current.dispose();
            await current.repository.close();
          }
        } finally {
          Pdfrx.pdfiumModulePath = previousPdfium;
          final owned = await root.resolveSymbolicLinks();
          expect(
            p.dirname(owned),
            await Directory.systemTemp.resolveSymbolicLinks(),
          );
          expect(p.basename(owned), startsWith(_tempPrefix));
          await Directory(owned).delete(recursive: true);
        }
      });
      final repository = await NoteRepository.open(
        Directory(p.join(root.path, 'vault')),
        createFormatVersion: 2,
      );
      final current = controller = WorkspaceController(
        repository,
        directoryProvider: () async => support,
      );
      final bridge = access = McpAccessController(
        () => VaultMcpService(current, officeEngine: engine),
        executable: p.absolute(executable!),
        supportDirectory: () async => support,
      );
      await bridge.start();
      final servers = bridge.clientConfiguration['mcpServers'] as Map;
      final config = servers['personal-ink-vault'] as Map;
      final arguments = config['args'] as List;
      expect(arguments.first, '--bridge-file');
      final rpc = client = await WindowsMcpRpc.start(
        config['command'] as String,
        arguments.last as String,
        replyTimeout: const Duration(seconds: 90),
      );

      final store = OfficeDocumentStore(repository);
      final note = await store.importDocument(
        title: 'Android preset round trip',
        fileName: 'android.pptx',
        bytes: original,
      );
      final before = await store.readLatest(note);
      final initial = await rpc.call('read_document', {'noteId': note.id});
      expect(initial.isError, isFalse, reason: '${initial.data}');
      final initialOffice = initial.data['office'] as Map;
      expect(initialOffice['available'], isTrue, reason: '$initialOffice');
      expect(initialOffice['sourceRevisionId'], before.revision.revisionId);
      final slides = initialOffice['slides'] as List;
      final target = slides[1] as Map;
      final imported = (target['shapes'] as List).whereType<Map>().singleWhere(
        (shape) => shape['shapeKind'] == 'roundedRectangle',
      );
      expect(imported['editableText'], isTrue);
      expect(imported['canEditGeometry'], isTrue);
      final id = imported['id'];
      final request = <String, Object?>{
        'noteId': note.id,
        'expectedRevisionId': before.revision.revisionId,
        'requestId': newId(),
        'operations': [
          {'op': 'shapeText', 'id': id, 'text': 'KEEPBOX'},
          {
            'op': 'shapeGeometry',
            'id': id,
            'x': 14.0,
            'y': 20.0,
            'width': 55.0,
            'height': 24.0,
          },
          {
            'op': 'shapeAppearance',
            'id': id,
            'fillStyle': 'solid',
            'fillColor': 0x335577,
          },
          for (final (kind, label, x) in [
            ('roundedRectangle', 'NEWBOX', 95.0),
            ('rightArrow', 'NEXTARROW', 166.0),
          ])
            {
              'op': 'shapeAdd',
              'id': 'llm-$kind',
              'slideId': target['id'],
              'shapeKind': kind,
              'x': x,
              'y': 20.0,
              'width': 60.0,
              'height': 24.0,
              'text': label,
            },
        ],
      };
      final denied = await rpc.call('office_edit', request);
      expect(denied.isError, isTrue);
      expect(denied.data['code'], 'read_only');
      await bridge.allowEdits(true);
      final saved = await rpc.call('office_edit', request);
      expect(saved.isError, isFalse, reason: '${saved.data}');
      expect(saved.data['pageCount'], 3);
      final stored = await store.readLatest(note);
      expect(stored.revision.parentRevisionIds, [before.revision.revisionId]);
      expect(stored.originalSha256, saved.data['sourceSha256']);
      expect(stored.pdfSha256, saved.data['pdfSha256']);
      expect(
        (await store.readLatest(
          note,
          revisionId: before.revision.revisionId,
        )).originalBytes,
        original,
      );
      final reopened = await rpc.call('read_document', {'noteId': note.id});
      expect(reopened.isError, isFalse, reason: '${reopened.data}');
      final afterOffice = reopened.data['office'] as Map;
      expect(afterOffice['sourceRevisionId'], stored.revision.revisionId);
      final shapes = (afterOffice['slides'] as List)[1]['shapes'] as List;
      final byLabel = {
        for (final shape in shapes.whereType<Map>()) shape['text']: shape,
      };
      expect(byLabel['KEEPBOX']?['shapeKind'], 'roundedRectangle');
      expect(byLabel['KEEPBOX']?['x'], closeTo(14, .02));
      expect(byLabel['KEEPBOX']?['width'], closeTo(55, .02));
      expect(byLabel['KEEPBOX']?['fillColor'], 0x335577);
      expect(byLabel['NEWBOX']?['shapeKind'], 'roundedRectangle');
      expect(byLabel['NEXTARROW']?['shapeKind'], 'rightArrow');
      expect(
        _presets(stored.originalBytes),
        containsPair('KEEPBOX', 'roundRect'),
      );
      expect(
        _presets(stored.originalBytes),
        containsPair('NEWBOX', 'roundRect'),
      );
      expect(
        _presets(stored.originalBytes),
        containsPair('NEXTARROW', 'rightArrow'),
      );

      Pdfrx.pdfiumModulePath = p.absolute(pdfium!);
      await pdfrxInitialize(tmpPath: root.path);
      final preview = await PdfDocument.openData(stored.pdfBytes!);
      try {
        expect(preview.pages, hasLength(3));
        final rendered = (await preview.pages[1].loadText())!.fullText;
        for (final label in ['KEEPBOX', 'NEWBOX', 'NEXTARROW']) {
          expect(rendered, contains(label));
        }
      } finally {
        await preview.dispose();
      }
      final replay = await rpc.call('office_edit', request);
      expect(replay.isError, isFalse);
      expect(replay.data, saved.data);
      expect(
        sha256.convert(await fixtureFile.readAsBytes()).toString(),
        _fixtureSha,
      );
    },
    timeout: const Timeout(Duration(minutes: 4)),
    skip:
        !Platform.isWindows ||
        executable == null ||
        runtime == null ||
        fixture == null ||
        pdfium == null,
  );
}

Map<String, String> _presets(List<int> bytes) {
  const presentation =
      'http://schemas.openxmlformats.org/presentationml/2006/main';
  const drawing = 'http://schemas.openxmlformats.org/drawingml/2006/main';
  final deck = ZipDecoder().decodeBytes(bytes);
  final result = <String, String>{};
  for (final slide in deck.files.where(
    (file) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(file.name),
  )) {
    final xml = XmlDocument.parse(utf8.decode(slide.content));
    for (final shape in xml.findAllElements('sp', namespace: presentation)) {
      final preset = shape
          .findAllElements('prstGeom', namespace: drawing)
          .firstOrNull;
      final kind = preset?.getAttribute('prst');
      if (kind == null) continue;
      final label = shape
          .findAllElements('t', namespace: drawing)
          .map((node) => node.innerText)
          .join();
      if (label.isNotEmpty) result[label] = kind;
    }
  }
  return result;
}
