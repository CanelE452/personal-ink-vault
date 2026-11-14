import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_render.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_page_link.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/note_link.dart';

import '../../integration_test/support/windows_mcp_rpc.dart';
import '../office/annotation_store_test.dart' show annotationOfficeFile;
import '../office/office_original_preview_test.dart' show officePreviewPdf;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  final exe = Platform.environment['INK_VAULT_MCP_TEST_EXE'];
  final explicitPdfium = Platform.environment['PIV_PDF_ANCHOR_TEST_PDFIUM'];
  final bundledPdfium = File('build/windows/x64/runner/Release/pdfium.dll');
  final previousPdfium = Pdfrx.pdfiumModulePath;
  if (explicitPdfium != null) {
    Pdfrx.pdfiumModulePath = File(explicitPdfium).absolute.path;
  } else if (Platform.isWindows && bundledPdfium.existsSync()) {
    Pdfrx.pdfiumModulePath = bundledPdfium.absolute.path;
  }
  tearDownAll(() => Pdfrx.pdfiumModulePath = previousPdfium);
  late Directory temp;
  late NoteRepository repository;
  final context = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => false,
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-page-');
    await FileManager.init(
      documentsDirectory: '${temp.path}/documents',
      shouldWatchRootDirectory: false,
    );
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
  });
  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  test('page rendering rejects malformed selectors and revoked access before reading documents', () async {
    for (final arguments in [
      {'noteId': newId(), 'revisionId': 42},
      {'noteId': newId(), 'pageIndex': -1},
      {'noteId': newId(), 'pageIndex': '1'},
      {'noteId': newId(), 'officePageTarget': null},
      {
        'noteId': newId(),
        'officePageTarget': {'pageId': newId()},
      },
      {
        'noteId': newId(),
        'officePageTarget': {
          ..._officeTargetWire((
            sourceRevisionId: newId(),
            pdfBindingId: newId(),
            pageId: newId(),
          )),
          'unexpected': true,
        },
      },
      for (final selector in [
        {'pageIndex': 0},
        {'revisionId': newId()},
      ])
        {
          'noteId': newId(),
          'officePageTarget': _officeTargetWire((
            sourceRevisionId: newId(),
            pdfBindingId: newId(),
            pageId: newId(),
          )),
          ...selector,
        },
    ]) {
      await expectLater(
        renderVaultMcpPage(repository, arguments, context),
        throwsA(
          isA<VaultMcpException>().having(
            (e) => e.code,
            'code',
            'invalid_arguments',
          ),
        ),
      );
    }
    await expectLater(
      renderVaultMcpPage(repository, {
        'noteId': newId(),
      }, VaultMcpCallContext(isActive: () => false, canWrite: () => true)),
      throwsA(
        isA<VaultMcpException>().having(
          (e) => e.code,
          'code',
          'authorization_revoked',
        ),
      ),
    );
  });

  test(
    'MCP renders the exact historical Office PDF and retained ink UUID',
    () async {
      await pdfrxInitialize(tmpPath: temp.path);
      final fixture = await _seedOfficePage(repository, temp);
      final before = await _revisionIds(repository);
      final result = await renderVaultMcpPage(
        repository,
        fixture.arguments,
        context,
        previewEngine: _ResultPreviewEngine(
          (_) async =>
              fail('An exact Office page must not launch a converter.'),
        ),
      );
      fixture.expectIdentity(result);
      expect(result['annotationRevisionId'], fixture.ink.revisionId);
      expect(result['pageIndex'], 2);
      expect(result['pageCount'], 4);
      final (pixels, width, height) = await _renderPixels(result);
      expect(width, 1200);
      expect(height, 1800);
      final background = 4 * (900 * width + 900);
      expect(
        pixels.getUint8(background + 1),
        greaterThan(pixels.getUint8(background) + 45),
      );
      var blackStrokePixels = 0;
      for (var y = 400; y < 450; y++) {
        for (var x = 250; x < 550; x++) {
          final i = 4 * (y * width + x);
          if (pixels.getUint8(i) < 35 &&
              pixels.getUint8(i + 1) < 35 &&
              pixels.getUint8(i + 2) < 35 &&
              pixels.getUint8(i + 3) == 255) {
            blackStrokePixels++;
          }
        }
      }
      expect(blackStrokePixels, greaterThan(100));

      Future<void> rejects(OfficePageTarget target, String code) => expectLater(
        renderVaultMcpPage(repository, {
          'noteId': fixture.noteId,
          'officePageTarget': _officeTargetWire(target),
        }, context),
        throwsA(isA<VaultMcpException>().having((e) => e.code, 'code', code)),
      );
      final target = fixture.target;
      await rejects((
        sourceRevisionId: target.sourceRevisionId,
        pdfBindingId: fixture.currentBinding,
        pageId: target.pageId,
      ), 'office_source_mismatch');
      await rejects((
        sourceRevisionId: target.sourceRevisionId,
        pdfBindingId: fixture.unannotatedBinding,
        pageId: target.pageId,
      ), 'page_out_of_range');
      await rejects((
        sourceRevisionId: target.sourceRevisionId,
        pdfBindingId: target.pdfBindingId,
        pageId: newId(),
      ), 'page_out_of_range');
      expect(await _revisionIds(repository), before);

      // A concurrent sibling is an ambiguity even if the bytes agree.
      await repository.commit(
        entityId: target.pdfBindingId,
        kind: EntityKind.ink,
        ownerNoteId: fixture.noteId,
        parentRevisionIds: fixture.ink.parentRevisionIds,
        files: await repository.readFiles(fixture.ink),
      );
      expect(await repository.heads(target.pdfBindingId), hasLength(2));
      final conflicted = await _revisionIds(repository);
      await rejects(target, 'revision_conflict');
      expect(await _revisionIds(repository), conflicted);
    },
  );

  test('MCP reads the exact baseline PDF page without creating ink', () async {
    await pdfrxInitialize(tmpPath: temp.path);
    final fixture = await _seedOfficePage(repository, temp);
    final target = (
      sourceRevisionId: fixture.target.sourceRevisionId,
      pdfBindingId: fixture.unannotatedBinding,
      pageId: officePdfBaselinePageId(fixture.unannotatedBinding, 1),
    );
    final before = await _revisionIds(repository);
    final result = await renderVaultMcpPage(repository, {
      'noteId': fixture.noteId,
      'officePageTarget': _officeTargetWire(target),
    }, context);
    expect(result['sourceRevisionId'], target.sourceRevisionId);
    expect(result['pdfBindingId'], target.pdfBindingId);
    expect(result['pageId'], target.pageId);
    expect(result['pageIndex'], 1);
    expect(result['pageCount'], 3);
    expect(result.containsKey('annotationRevisionId'), isFalse);
    expect(
      result['officePageLink'],
      NoteLink.officePage(fixture.noteId, target).toString(),
    );
    final (pixels, width, height) = await _renderPixels(result);
    expect(width, 1200);
    expect(height, 1800);
    final center = 4 * (900 * width + 600);
    expect(
      pixels.getUint8(center),
      greaterThan(pixels.getUint8(center + 1) + 100),
    );

    final trailingBlank = (
      sourceRevisionId: target.sourceRevisionId,
      pdfBindingId: target.pdfBindingId,
      pageId: officePdfBaselinePageId(target.pdfBindingId, -1),
    );
    final blank = await renderVaultMcpPage(repository, {
      'noteId': fixture.noteId,
      'officePageTarget': _officeTargetWire(trailingBlank),
    }, context);
    expect(blank['pageId'], trailingBlank.pageId);
    expect(blank['pageIndex'], 2);
    expect(blank['pageCount'], 3);
    expect(blank.containsKey('annotationRevisionId'), isFalse);
    final (blankPixels, blankWidth, blankHeight) = await _renderPixels(blank);
    expect(blankWidth, 1200);
    expect(blankHeight, greaterThan(1000));
    expect(
      blankPixels.buffer
          .asUint8List(blankPixels.offsetInBytes, blankPixels.lengthInBytes)
          .every((byte) => byte == 255),
      isTrue,
    );
    expect(await repository.heads(target.pdfBindingId), isEmpty);
    expect(await _revisionIds(repository), before);
  });

  test(
    'MCP rejects a different valid PDF embedded under the same Office binding',
    () async {
      final fixture = await _seedOfficePage(repository, temp);
      final files = await repository.readFiles(fixture.ink);
      final boundPdf = await File('${temp.path}/annotated.pdf').readAsBytes();
      final digest = sha256.convert(boundPdf);
      final backgroundAsset = files.entries
          .where(
            (file) =>
                file.key.startsWith('main.sbn2.') &&
                sha256.convert(file.value) == digest,
          )
          .single
          .key;
      final replacement = await officePreviewPdf(
        PdfColors.orange,
        second: PdfColors.red,
      );
      expect(sha256.convert(replacement), isNot(digest));
      final mismatched = await repository.commit(
        entityId: fixture.target.pdfBindingId,
        kind: EntityKind.ink,
        ownerNoteId: fixture.noteId,
        parentRevisionIds: [fixture.ink.revisionId],
        files: {...files, backgroundAsset: replacement},
      );
      expect(
        (await repository.heads(fixture.target.pdfBindingId)).single.revisionId,
        mismatched.revisionId,
      );
      final before = await _revisionIds(repository);
      await expectLater(
        renderVaultMcpPage(repository, fixture.arguments, context),
        throwsA(
          isA<VaultMcpException>().having(
            (e) => e.code,
            'code',
            'office_source_mismatch',
          ),
        ),
      );
      expect(await _revisionIds(repository), before);
    },
  );

  test('Windows Rust stdio renders an exact Office page through the read-only Dart bridge', () async {
    await pdfrxInitialize(tmpPath: temp.path);
    final fixture = await _seedOfficePage(repository, temp);
    final before = await _revisionIds(repository);
    final config = File('${temp.path}/support/bridge.json');
    final bridge = await VaultMcpBridge.start(
      configFile: config,
      handler: (operation, arguments, access) async {
        expect(operation, 'render_page');
        expect(access.writeEnabled, isFalse);
        return renderVaultMcpPage(repository, arguments, access);
      },
    );
    try {
      final client = await WindowsMcpRpc.start(
        File(exe!).absolute.path,
        config.path,
      );
      try {
        expect(await client.tools(), contains('render_page'));
        final result = await client.call('render_page', fixture.arguments);
        expect(result.isError, isFalse, reason: '${result.data}');
        fixture.expectIdentity(result.data);
        expect(result.data['annotationRevisionId'], fixture.ink.revisionId);
        expect(result.data['pageIndex'], 2);
        expect(result.data['pageCount'], 4);
        expect(result.data.containsKey('image'), isFalse);
        final image = result.content
            .where((part) => part['type'] == 'image')
            .single;
        expect(image['mimeType'], 'image/png');
        final (pixels, width, height) = await _renderPixels({'image': image});
        expect((width, height), (1200, 1800));
        final background = 4 * (900 * width + 900);
        expect(
          pixels.getUint8(background + 1),
          greaterThan(pixels.getUint8(background) + 45),
        );
        expect(
          List.generate(
            50,
            (i) => pixels.getUint32(4 * ((400 + i) * width + 400)),
          ),
          contains(0x000000ff),
        );
      } finally {
        await client.close();
      }
    } finally {
      await bridge.stop();
    }
    expect(await _revisionIds(repository), before);
  }, skip: !Platform.isWindows || exe == null);

  test('MCP can see an untouched Office original without creating a canonical edition', () async {
    await pdfrxInitialize(tmpPath: temp.path);
    final pdf = pw.Document()
      ..addPage(pw.Page(build: (_) => pw.Text('Visible original page')));
    final pdfBytes = await pdf.save();
    final output = await File('${temp.path}/preview.pdf')
        .writeAsBytes(pdfBytes);
    final original = utf8.encode('read-only original fixture');
    final note = await OfficeDocumentStore(repository).importDocument(
      title: 'Original',
      fileName: 'paper.docx',
      bytes: original,
    );
    final before = (await repository.revisions()).length;
    var previews = 0;
    final engine = OfficePreviewEngine(
      isWindows: true,
      isAndroid: false,
      windowsEngine: WindowsOfficeEngine(
        runner: (request) async {
          previews++;
          expect(request['mode'], 'inspect');
          expect(request['preview'], isTrue);
          expect(
            await File(request['sourcePath'] as String).readAsBytes(),
            original,
          );
          return {
            'snapshot': {
              'kind': 'word',
              'sourceSha256': sha256.convert(original).toString(),
              'paragraphs': [],
              'tables': [],
              'slides': [],
              'previewPdfPath': output.path,
              'previewPageCount': 1,
            },
          };
        },
      ),
    );
    final result = await renderVaultMcpPage(
      repository,
      {'noteId': note.id},
      context,
      previewEngine: engine,
    );
    expect(result['pageCount'], 1);
    expect(result['image'], containsPair('mimeType', 'image/png'));
    final image = Map<String, dynamic>.from(result['image'] as Map);
    final codec = await ui.instantiateImageCodec(
      base64Decode(image['data'] as String),
    );
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 1200);
    expect(frame.image.height, greaterThan(1000));
    frame.image.dispose();
    codec.dispose();
    expect(previews, 1);
    expect((await repository.revisions()).length, before);
    final stored = await OfficeDocumentStore(repository).readLatest(note);
    expect(stored.originalBytes, original);
    expect(stored.pdfBytes, isNull);
    await expectLater(
      renderVaultMcpPage(
        repository,
        {'noteId': note.id, 'pageIndex': 1},
        context,
        previewEngine: engine,
      ),
      throwsA(
        isA<VaultMcpException>().having(
          (e) => e.code,
          'code',
          'page_out_of_range',
        ),
      ),
    );
  });

  test(
    'Office rendering releases its owned backend PDF after copying a real page',
    () async {
      await pdfrxInitialize(tmpPath: temp.path);
      final pdf = pw.Document()
        ..addPage(pw.Page(build: (_) => pw.Text('Owned backend preview page')));
      final pdfBytes = await pdf.save();
      final original = utf8.encode(
        'original remains unchanged after rendering',
      );
      final documents = OfficeDocumentStore(repository);
      final note = await documents.importDocument(
        title: 'Owned preview',
        fileName: 'paper.docx',
        bytes: original,
      );
      final before = (await repository.revisions()).length;
      final preview = await _createOwnedPreview(
        temp,
        pdfBytes,
        sha256.convert(original).toString(),
      );
      final unrelated = await File('${temp.path}/backend-output/unrelated.pdf')
          .writeAsBytes(pdfBytes);
      String? inputPath;
      final engine = _ResultPreviewEngine((path) async {
        inputPath = path;
        expect(await File(path).readAsBytes(), original);
        return preview;
      });

      final result = await renderVaultMcpPage(
        repository,
        {'noteId': note.id},
        context,
        previewEngine: engine,
      );
      expect(result['pageCount'], 1);
      final image = Map<String, dynamic>.from(result['image'] as Map);
      expect(image['mimeType'], 'image/png');
      final codec = await ui.instantiateImageCodec(
        base64Decode(image['data'] as String),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          expect(frame.image.width, 1200);
          expect(frame.image.height, greaterThan(1000));
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
      expect(preview.disposalCalls, 1);
      expect(File(preview.pdfPath).existsSync(), isFalse);
      expect(await unrelated.readAsBytes(), pdfBytes);
      expect(inputPath, isNotNull);
      expect(File(inputPath!).parent.existsSync(), isFalse);
      expect((await repository.revisions()).length, before);
      expect(
        (await repository.revisions()).where(
          (revision) => revision.blobs.containsKey('edition.json'),
        ),
        isEmpty,
      );
      final stored = await documents.readLatest(note);
      expect(stored.originalBytes, original);
      expect(stored.originalSha256, sha256.convert(original).toString());
      expect(stored.pdfBytes, isNull);
    },
  );

  test('late access revocation releases the owned backend preview and private input', () async {
    final pdf = pw.Document()
      ..addPage(pw.Page(build: (_) => pw.Text('Revoked preview page')));
    final original = utf8.encode('revocation preserves the original');
    final documents = OfficeDocumentStore(repository);
    final note = await documents.importDocument(
      title: 'Revoked preview',
      fileName: 'paper.docx',
      bytes: original,
    );
    final before = (await repository.revisions()).length;
    final preview = await _createOwnedPreview(
      temp,
      await pdf.save(),
      sha256.convert(original).toString(),
    );
    var active = true;
    String? inputPath;
    final engine = _ResultPreviewEngine((path) async {
      inputPath = path;
      expect(await File(path).readAsBytes(), original);
      active = false;
      return preview;
    });
    await expectLater(
      renderVaultMcpPage(
        repository,
        {'noteId': note.id},
        VaultMcpCallContext(isActive: () => active, canWrite: () => false),
        previewEngine: engine,
      ),
      throwsA(
        isA<VaultMcpException>().having(
          (error) => error.code,
          'code',
          'authorization_revoked',
        ),
      ),
    );
    expect(preview.disposalCalls, 1);
    expect(File(preview.pdfPath).existsSync(), isFalse);
    expect(inputPath, isNotNull);
    expect(File(inputPath!).parent.existsSync(), isFalse);
    expect((await repository.revisions()).length, before);
    expect(
      (await repository.revisions()).where(
        (revision) => revision.blobs.containsKey('edition.json'),
      ),
      isEmpty,
    );
    final stored = await documents.readLatest(note);
    expect(stored.originalBytes, original);
    expect(stored.pdfBytes, isNull);
  });

  test(
    'backend disposal failure still cleans the private input directory',
    () async {
      await pdfrxInitialize(tmpPath: temp.path);
      final pdf = pw.Document()
        ..addPage(pw.Page(build: (_) => pw.Text('Disposal failure page')));
      final original = utf8.encode(
        'disposal failure keeps canonical data intact',
      );
      final documents = OfficeDocumentStore(repository);
      final note = await documents.importDocument(
        title: 'Disposal failure',
        fileName: 'paper.docx',
        bytes: original,
      );
      final before = (await repository.revisions()).length;
      final preview = await _createOwnedPreview(
        temp,
        await pdf.save(),
        sha256.convert(original).toString(),
        failDisposal: true,
      );
      String? inputPath;
      await expectLater(
        renderVaultMcpPage(
          repository,
          {'noteId': note.id},
          context,
          previewEngine: _ResultPreviewEngine((path) async {
            inputPath = path;
            expect(await File(path).readAsBytes(), original);
            return preview;
          }),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'owned backend disposal failed',
          ),
        ),
      );
      expect(preview.disposalCalls, 1);
      expect(File(preview.pdfPath).existsSync(), isFalse);
      expect(inputPath, isNotNull);
      expect(File(inputPath!).parent.existsSync(), isFalse);
      expect((await repository.revisions()).length, before);
      expect(
        (await repository.revisions()).where(
          (revision) => revision.blobs.containsKey('edition.json'),
        ),
        isEmpty,
      );
      final stored = await documents.readLatest(note);
      expect(stored.originalBytes, original);
      expect(stored.pdfBytes, isNull);
    },
  );
}

class _OfficePageFixture {
  const new({
    required this.noteId,
    required this.target,
    required this.ink,
    required this.unannotatedBinding,
    required this.currentBinding,
  });

  final String noteId;
  final OfficePageTarget target;
  final RevisionRecord ink;
  final String unannotatedBinding;
  final String currentBinding;

  Map<String, dynamic> get arguments => {
    'noteId': noteId,
    'officePageTarget': _officeTargetWire(target),
  };

  void expectIdentity(Map<String, Object?> result) {
    expect(result['noteId'], noteId);
    expect(result['revisionId'], target.sourceRevisionId);
    expect(result['sourceRevisionId'], target.sourceRevisionId);
    expect(result['pdfBindingId'], target.pdfBindingId);
    expect(result['pageId'], target.pageId);
    expect(
      result['officePageLink'],
      NoteLink.officePage(noteId, target).toString(),
    );
  }
}

Map<String, String> _officeTargetWire(OfficePageTarget target) => {
  'sourceRevisionId': target.sourceRevisionId,
  'pdfBindingId': target.pdfBindingId,
  'pageId': target.pageId,
};

Future<Set<String>> _revisionIds(NoteRepository repository) async => {
  for (final revision in await repository.revisions()) revision.revisionId,
};

Future<_OfficePageFixture> _seedOfficePage(
  NoteRepository repository,
  Directory temp,
) async {
  final documents = OfficeDocumentStore(repository);
  final note = await documents.importDocument(
    title: 'Saved Office PDF pages',
    fileName: 'lecture.docx',
    bytes: annotationOfficeFile('Historical source'),
  );
  final historical = await documents.readLatest(note);
  final edit = await documents.beginEdit(note);
  final unannotated = await documents.commitDerivedPdf(
    edit,
    pdfBytes: await officePreviewPdf(PdfColors.orange, second: PdfColors.red),
    pageCount: 2,
  );
  final pdf = await officePreviewPdf(PdfColors.blue, second: PdfColors.green);
  final annotated = await documents.commitDerivedPdf(
    edit,
    pdfBytes: pdf,
    pageCount: 2,
  );
  final annotation = await OfficeAnnotationStore(repository)
      .open(note, historical, preview: annotated);
  final pdfFile = await File('${temp.path}/annotated.pdf').writeAsBytes(pdf);
  final core = EditorCoreInfo(filePath: annotation.workingPath)
    ..nextImageId = 2;
  const size = ui.Size(200, 300);
  EditorPage pdfPage(int index) => EditorPage(
    size: size,
    backgroundImage: PdfEditorImage(
      id: index,
      assetCache: core.assetCache,
      pdfBytes: null,
      pdfFile: pdfFile,
      pdfPage: index,
      pageIndex: index,
      pageSize: size,
      naturalSize: size,
      onMoveImage: null,
      onDeleteImage: null,
      onMiscChange: null,
    ),
  );
  final linked = pdfPage(1);
  try {
    core.pages.addAll([pdfPage(0), linked]);
    final pen = Pen.ballpointPen()..color = const ui.Color(0xff000000);
    pen.onDragStart(const ui.Offset(25, 70), linked, 1, null);
    for (var x = 40; x <= 115; x += 15) {
      pen.onDragUpdate(ui.Offset(x.toDouble(), 70), null);
    }
    linked.insertStroke(pen.onDragEnd()!);
    await annotation.saveSnapshot(core, 0);
    core.pages.insert(1, EditorPage(size: size));
    linked.updatePageIndex(2);
    await annotation.saveSnapshot(core, 0);
  } finally {
    core.dispose();
  }
  final current = await documents.commitEdited(
    edit,
    originalBytes: annotationOfficeFile('New source'),
    pdfBytes: await officePreviewPdf(PdfColors.purple),
    pageCount: 1,
    engineVersion: 'office-link-render-fixture',
  );
  return _OfficePageFixture(
    noteId: note.id,
    target: (
      sourceRevisionId: historical.revision.revisionId,
      pdfBindingId: annotated.bindingId,
      pageId: linked.pageId,
    ),
    ink: annotation.revision!,
    unannotatedBinding: unannotated.bindingId,
    currentBinding: current.bindingId!,
  );
}

Future<(ByteData, int, int)> _renderPixels(Map<String, Object?> result) async {
  final image = result['image'] as Map;
  expect(image['mimeType'], 'image/png');
  final bytes = base64Decode(image['data'] as String);
  expect(bytes.take(8), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      final pixels = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      return (pixels!, frame.image.width, frame.image.height);
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

Future<_OwnedPreviewResult> _createOwnedPreview(
  Directory temp,
  List<int> pdfBytes,
  String sourceSha256, {
  bool failDisposal = false,
}) async {
  final backend = await Directory('${temp.path}/backend-output').create();
  final output = await File('${backend.path}/owned-preview.pdf')
      .writeAsBytes(pdfBytes, flush: true);
  return _OwnedPreviewResult(
    output,
    pdfSha256: sha256.convert(pdfBytes).toString(),
    sourceSha256: sourceSha256,
    failDisposal: failDisposal,
  );
}

class _OwnedPreviewResult extends OfficePreviewResult {
  new(
    this._ownedPdf, {
    required super.pdfSha256,
    required super.sourceSha256,
    this.failDisposal = false,
  }) : super(
         pdfPath: _ownedPdf.path,
         pageCount: 1,
         engineVersion: 'owned-render-preview-fixture',
       );
  final File _ownedPdf;
  final bool failDisposal;
  var disposalCalls = 0;
  var _disposed = false;

  @override
  Future<void> dispose() async {
    disposalCalls++;
    if (_disposed) return;
    _disposed = true;
    if (_ownedPdf.existsSync()) await _ownedPdf.delete();
    if (failDisposal) throw StateError('owned backend disposal failed');
  }
}

class _ResultPreviewEngine extends OfficePreviewEngine {
  new(this.run);
  final Future<OfficePreviewResult?> Function(String) run;

  @override
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) {
    expect(sessionId, isNotEmpty);
    return run(sourcePath);
  }
}
