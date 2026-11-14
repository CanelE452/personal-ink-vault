import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/obsidian_canvas_export_source.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List _text(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  final nativeLibrary = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  late Directory temp;
  late NoteRepository repository;
  late WorkspaceStore workspace;
  late InkVaultNative native;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('canvas-export-source-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    workspace = WorkspaceStore(repository);
    native = InkVaultNative.open(libraryPath: nativeLibrary);
  });
  tearDown(() async {
    await repository.close();
    final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
    final owned = await temp.resolveSymbolicLinks();
    expect(p.dirname(owned), temporaryRoot);
    expect(p.basename(owned), startsWith('canvas-export-source-'));
    await Directory(owned).delete(recursive: true);
  });

  group('Canvas export reader', () {
    test('pins editable boards and byte-exact linked originals', () async {
      final folder = await LibraryStore(repository).createFolder('수업');
      final board = await workspace.createWithSource(
        'Renamed board',
        fileName: 'Original.canvas',
        bytes: _text('{"nodes":[],"edges":[]}'),
        documentKind: VaultDocumentKind.canvas,
        folderId: folder.id,
        fromObsidian: true,
      );
      final editedBoard = _text('{"nodes":[],"edges":[],"edited":true}');
      await (await workspace.open(board))
          .saveInk({'board.canvas': editedBoard});
      final markdown = _text('\ufeff# 원문\r\n');
      final note = await workspace.createMarkdown(
        '강의 노트',
        markdown,
        folderId: folder.id,
      );
      final pdf = _text('%PDF-1.7\nsynthetic original\n%%EOF\n');
      final pdfNote = await workspace.createWithSource(
        'PDF display title',
        fileName: 'Slides.pdf',
        bytes: pdf,
        documentKind: VaultDocumentKind.pdf,
        folderId: folder.id,
      );
      final office = OfficeDocumentStore(repository);
      final slides = await office.importDocument(
        title: 'Presentation display title',
        fileName: 'Slides.pptx',
        bytes: OfficeTemplates.create(
          OfficeTemplateKind.presentation,
          title: 'Initial edition',
        ).bytes,
        folderId: folder.id,
      );
      final editedSlides = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'Edited edition',
      ).bytes;
      final saved = await office.commitEdited(
        await office.beginEdit(slides),
        originalBytes: editedSlides,
        pdfBytes: pdf,
        engineVersion: 'test engine',
        pageCount: 1,
      );
      final page = await workspace.create(
        'Workspace-only page',
        documentKind: VaultDocumentKind.page,
      );
      final unsafeTitle = await workspace.createMarkdown(
        'Name/Folder\\Leaf',
        markdown,
      );

      final reader = await ObsidianCanvasExportReader.capture(
        repository,
        native: native,
      );
      final results = [
        (board, '수업/Original.canvas', editedBoard),
        (note, '수업/강의 노트.md', markdown),
        (pdfNote, '수업/Slides.pdf', pdf),
        (slides, '수업/Slides.pptx', editedSlides),
        (unsafeTitle, 'Name_Folder_Leaf.md', markdown),
      ];
      for (final (target, path, bytes) in results) {
        final file = await reader.read(target.id, maxBytes: bytes.length);
        expect(file, isNotNull);
        expect(file!.preferredPath, path);
        expect(file.noteId, target.id);
        expect(file.title, target.title);
        expect(file.kind, target.documentKind);
        expect(file.metadataRevisionId, target.revision.revisionId);
        expect(file.bytes, bytes);
        expect(() => file.bytes[0] = 0, throwsUnsupportedError);
        expect(
          await reader.read(target.id, maxBytes: bytes.length - 1),
          isNull,
        );
      }
      final exportedOffice = await reader.read(
        slides.id,
        maxBytes: editedSlides.length,
      );
      expect(exportedOffice!.bodyRevisionId, saved.revision.revisionId);
      expect(await reader.read(page.id, maxBytes: 1000), isNull);
      await reader.ensureCurrent();
    });

    test('matches only exact normalized imported images and rejects stale snapshots', () async {
      final folder = await LibraryStore(repository).createFolder('Cafe\u0301');
      Future<VaultNote> image(String title, {required bool imported}) =>
          workspace.createWithSource(
            title,
            fileName: 'Study%20image.PNG',
            bytes: Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]),
            documentKind: VaultDocumentKind.image,
            folderId: folder.id,
            fromObsidian: imported,
          );
      final first = await image('Renamed imported image', imported: true);
      await image('Native image', imported: false);

      final reader = await ObsidianCanvasExportReader.capture(
        repository,
        native: native,
      );
      expect(reader.resolveImage('CAFÉ/Study%20Image.png'), first.id);
      expect(reader.resolveImage('Study%20Image.png'), isNull);
      expect(reader.resolveImage('CAFÉ/Study Image.png'), isNull);
      expect(reader.resolveImage('../CAFÉ/Study%20Image.png'), isNull);
      expect(reader.resolveImage('CAFÉ\\Study%20Image.png'), isNull);

      await image('Competing imported image', imported: true);
      await expectLater(reader.ensureCurrent(), throwsStateError);
      final current = await ObsidianCanvasExportReader.capture(
        repository,
        native: native,
      );
      expect(current.resolveImage('CAFÉ/Study%20Image.png'), isNull);
    });

    test('caps Markdown and Canvas bodies at the reimport limit', () async {
      const limit = 8 * 1024 * 1024;
      final body = Uint8List(limit + 1);
      final note = await workspace.createMarkdown('Large note', body);
      final board = await workspace.create(
        'Large canvas',
        documentKind: VaultDocumentKind.canvas,
      );
      await (await workspace.open(board)).saveInk({'board.canvas': body});
      final reader = await ObsidianCanvasExportReader.capture(
        repository,
        native: native,
      );
      expect(await reader.read(note.id, maxBytes: body.length), isNull);
      expect(await reader.read(board.id, maxBytes: body.length), isNull);
    });
  }, skip: nativeLibrary == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false);
}
