import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/imports/image_note_importer.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  late Directory temp;
  late NoteRepository repository;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ink-image-import-');
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    await FileManager.init(
      documentsDirectory: '${temp.path}/working',
      shouldWatchRootDirectory: false,
    );
  });
  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  testWidgets(
    'actual PNG imports into a natural-size background and reopens with exact original and pixels',
    (tester) async {
      await tester.runAsync(() async {
        final png = await _redPng();
        final supplied = Uint8List.fromList(png);
        final folder = await LibraryStore(repository).createFolder('Photos');
        final note = await ImageNoteImporter(repository).import(
          title: '사진',
          fileName: '사진.png',
          bytes: supplied,
          folderId: folder.id,
        );
        supplied.fillRange(0, supplied.length, 0);
        expect(note.documentKind, VaultDocumentKind.image);
        expect(note.folderId, folder.id);
        final source = (await repository.heads(note.sourceEntityId!)).single;
        expect(source.kind, EntityKind.attachment);
        expect((await repository.readFiles(source))['사진.png'], png);
        await repository.close();
        repository = await NoteRepository.open(Directory('${temp.path}/vault'));
        final reopened = (await WorkspaceStore(repository).list()).single;
        expect(reopened.sourceEntityId, note.sourceEntityId);
        final ink = (await repository.heads(reopened.inkEntityId)).single;
        final core = await SaberInkAdapter.load(repository, ink);
        try {
          expect(
            core.pages.where((page) => page.backgroundImage != null),
            hasLength(1),
          );
          final page = core.pages.first;
          expect(page.size, const ui.Size(8, 4));
          final background = page.backgroundImage! as PngEditorImage;
          expect(background.naturalSize, const ui.Size(8, 4));
          expect(background.srcRect, const ui.Rect.fromLTWH(0, 0, 8, 4));
          final provider = background.imageProvider;
          final stored = provider is MemoryImage
              ? provider.bytes
              : await (provider as FileImage).file.readAsBytes();
          expect(stored, png);
          final codec = await ui.instantiateImageCodec(stored);
          try {
            final image = (await codec.getNextFrame()).image;
            try {
              expect((image.width, image.height), (8, 4));
              final rgba = (await image.toByteData())!.buffer.asUint8List();
              expect(rgba.take(4), [255, 0, 0, 255]);
            } finally {
              image.dispose();
            }
          } finally {
            codec.dispose();
          }
        } finally {
          core.dispose();
        }
      });
    },
  );

  testWidgets(
    'invalid signatures unsafe names and mismatched extensions do not create canonical records',
    (tester) async {
      await tester.runAsync(() async {
        final png = await _redPng();
        for (final filename in [
          '../photo.png',
          'bad\\photo.png',
          'bad:photo.png',
          'CON.png',
          'photo.jpg',
        ]) {
          await expectLater(
            ImageNoteImporter(repository)
                .import(title: 'Bad', fileName: filename, bytes: png),
            throwsFormatException,
          );
        }
        await expectLater(
          ImageNoteImporter(repository).import(
            title: 'Bad',
            fileName: 'photo.png',
            bytes: Uint8List.fromList([1, 2, 3]),
          ),
          throwsFormatException,
        );
        expect(await repository.revisions(), isEmpty);
      });
    },
  );

  testWidgets(
    'JPEG EXIF orientation and lossless WebP preserve original bytes and decoded page size',
    (tester) async {
      await tester.runAsync(() async {
        for (final fixture in [
          ('photo.jpg', base64Decode(_jpegExif6), const ui.Size(4, 8)),
          ('photo.webp', base64Decode(_webp), const ui.Size(8, 4)),
        ]) {
          final note = await ImageNoteImporter(
            repository,
          ).import(title: fixture.$1, fileName: fixture.$1, bytes: fixture.$2);
          final original = (await repository.heads(note.sourceEntityId!))
              .single;
          expect(
            (await repository.readFiles(original))[fixture.$1],
            fixture.$2,
          );
          final ink = (await repository.heads(note.inkEntityId)).single;
          final restored = await SaberInkAdapter.load(repository, ink);
          try {
            expect(restored.pages.first.size, fixture.$3);
            expect(
              restored.pages.first.backgroundImage!.naturalSize,
              fixture.$3,
            );
          } finally {
            restored.dispose();
          }
        }
      });
    },
  );

  testWidgets(
    'oversize dimensions and source byte limit are rejected before canonical writes',
    (tester) async {
      await tester.runAsync(() async {
        final png = await _redPng();
        final huge = Uint8List.fromList(png);
        ByteData.sublistView(huge).setUint32(16, 10000);
        ByteData.sublistView(huge).setUint32(20, 10000);
        await expectLater(
          ImageNoteImporter(repository)
              .import(title: 'Large', fileName: 'large.png', bytes: huge),
          throwsFormatException,
        );
        await expectLater(
          ImageNoteImporter(repository).import(
            title: 'Large',
            fileName: 'large.png',
            bytes: Uint8List(64 * 1024 * 1024 + 1),
          ),
          throwsFormatException,
        );
        expect(await repository.revisions(), isEmpty);
      });
    },
  );

  testWidgets(
    'ink save failure retains the exact canonical original and reports incomplete import',
    (tester) async {
      await tester.runAsync(() async {
        final png = await _redPng();
        ImageNoteImportException? failure;
        try {
          await ImageNoteImporter(_FailInkWrites(repository))
              .import(title: 'Recover', fileName: 'original.png', bytes: png);
        } on ImageNoteImportException catch (error) {
          failure = error;
        }
        expect(failure, isNotNull);
        final note = failure!.note;
        final source = (await repository.heads(note.sourceEntityId!)).single;
        expect((await repository.readFiles(source))['original.png'], png);
        expect(await repository.heads(note.inkEntityId), isEmpty);
        expect((await WorkspaceStore(repository).list()).single.id, note.id);
      });
    },
  );
}

// Original synthetic solid-red 8x4 images; the JPEG has EXIF orientation 6.
const _jpegExif6 =
    '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYAAAAAAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAAEAAgDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD8X6KKK/ynP+/g/9k=';
const _webp = 'UklGRhwAAABXRUJQVlA4TA8AAAAvB8AAAAcQ/Y/+ByKi/wEA';

Future<Uint8List> _redPng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(8, 4);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      return Uint8List.fromList(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

class _FailInkWrites implements NoteRepository {
  const new(this.inner);
  final NoteRepository inner;
  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord revision) =>
      inner.readFiles(revision);
  @override
  PreparedCommit prepareCommit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) => inner.prepareCommit(
    entityId: entityId,
    kind: kind,
    files: files,
    parentRevisionIds: parentRevisionIds,
    ownerNoteId: ownerNoteId,
    deleted: deleted,
    baseRefs: baseRefs,
  );
  @override
  Future<RevisionRecord> commitPrepared(PreparedCommit prepared) {
    if (prepared.record.kind == EntityKind.ink)
      return Future.error(StateError('Synthetic ink write failure'));
    return inner.commitPrepared(prepared);
  }

  @override
  Future<RevisionRecord> commit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) {
    if (kind == EntityKind.ink)
      return Future.error(StateError('Synthetic ink write failure'));
    return inner.commit(
      entityId: entityId,
      kind: kind,
      files: files,
      parentRevisionIds: parentRevisionIds,
      ownerNoteId: ownerNoteId,
      deleted: deleted,
      baseRefs: baseRefs,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
