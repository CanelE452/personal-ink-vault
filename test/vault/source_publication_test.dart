import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/imports/image_note_importer.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory directory;
  late NoteRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('source-publication-');
    repository = await NoteRepository.open(directory, createFormatVersion: 2);
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });
  final starter = OfficeTemplates.create(
    OfficeTemplateKind.document,
    title: 'Original',
  );

  for (final name in [
    '../original.pdf',
    'dir/original.pdf',
    r'C:\original.pdf',
    'CON.pdf',
    'bad?.pdf',
    'trailing.',
  ]) {
    test(
      'source publication rejects unsafe filename $name before writing revisions',
      () async {
        await expectLater(
          WorkspaceStore(repository).createWithSource(
            'PDF',
            fileName: name,
            bytes: Uint8List.fromList([1]),
            documentKind: VaultDocumentKind.pdf,
          ),
          throwsFormatException,
        );
        expect(await repository.revisions(), isEmpty);
      },
    );
  }

  test('source publication validates empty bytes unsupported type and missing destination before commits', () async {
    for (final (bytes, kind, folder) in [
      (Uint8List(0), VaultDocumentKind.pdf, null),
      (Uint8List.fromList([1]), VaultDocumentKind.markdown, null),
      (Uint8List.fromList([1]), VaultDocumentKind.pdf, newId()),
    ]) {
      await expectLater(
        WorkspaceStore(repository).createWithSource(
          'Invalid',
          fileName: 'original.pdf',
          bytes: bytes,
          documentKind: kind,
          folderId: folder,
        ),
        throwsA(anything),
      );
      expect(await repository.revisions(), isEmpty);
    }
  });

  test('source publication captures caller bytes before asynchronous destination checks', () async {
    final incoming = Uint8List.fromList(starter.bytes);
    final creating = WorkspaceStore(repository).createWithSource(
      'Captured',
      fileName: starter.fileName,
      bytes: incoming,
      documentKind: VaultDocumentKind.office,
    );
    incoming.fillRange(0, incoming.length, 0);
    final note = await creating;
    expect(
      (await OfficeDocumentStore(repository).readLatest(note)).originalBytes,
      starter.bytes,
    );
  });

  test('a staged shared document replays across restart without creating another note', () async {
    final id = newId();
    Future<VaultNote> share(Uint8List bytes) => OfficeDocumentStore(repository)
        .importDocument(
          title: '공유 원본',
          fileName: starter.fileName,
          bytes: bytes,
          sharedRequestId: id,
        );
    final published = await share(starter.bytes);
    expect(published.id, id);
    final first = (await repository.revisions())
        .map((record) => record.revisionId)
        .toSet();
    await repository.close();
    repository = await NoteRepository.open(directory);
    final replayed = await share(starter.bytes);
    expect(replayed.sourceEntityId, published.sourceEntityId);
    expect(replayed.revision.revisionId, published.revision.revisionId);
    final altered = Uint8List.fromList(starter.bytes);
    altered[10] ^= 1;
    await expectLater(share(altered), throwsStateError);
    expect(
      (await repository.revisions()).map((record) => record.revisionId).toSet(),
      first,
    );
    expect(await WorkspaceStore(repository).list(), hasLength(1));
  });

  test(
    'two attempts for one native request publish only one metadata head',
    () async {
      final id = newId();
      final results = await Future.wait([
        for (var attempt = 0; attempt < 2; attempt++)
          WorkspaceStore(repository).createWithSource(
            '공유 PDF',
            fileName: 'original.pdf',
            bytes: Uint8List.fromList('%PDF-1.7'.codeUnits),
            documentKind: VaultDocumentKind.pdf,
            sharedRequestId: id,
          ),
      ]);
      expect(results.map((note) => note.id).toSet(), {id});
      expect(
        (await repository.heads(id)).single.revisionId,
        results.first.revision.revisionId,
      );
      expect(await WorkspaceStore(repository).list(), hasLength(1));
    },
  );

  for (final kind in [
    EntityKind.attachment,
    EntityKind.markdown,
    EntityKind.metadata,
  ]) {
    test(
      'failed Office $kind publication never exposes a source-less note after reopening',
      () async {
        final old = await WorkspaceStore(repository).create('Saved');
        final guarded = _PublicationRepository(repository, failBefore: kind);
        await expectLater(
          OfficeDocumentStore(guarded).importDocument(
            title: 'Incoming',
            fileName: starter.fileName,
            bytes: starter.bytes,
          ),
          throwsStateError,
        );
        expect((await WorkspaceStore(repository).list()).map((n) => n.id), [
          old.id,
        ]);
        await repository.close();
        repository = await NoteRepository.open(directory);
        expect((await WorkspaceStore(repository).list()).map((n) => n.id), [
          old.id,
        ]);
      },
    );
  }

  test('first visible Office metadata already references the exact committed original', () async {
    final observed = _PublicationRepository(repository);
    final note = await OfficeDocumentStore(observed).importDocument(
      title: 'Incoming',
      fileName: starter.fileName,
      bytes: starter.bytes,
    );
    expect(observed.order, [
      EntityKind.attachment,
      EntityKind.markdown,
      EntityKind.metadata,
    ]);
    expect(note.sourceEntityId, isNotNull);
    final metadata = (await repository.heads(note.id)).single;
    expect(metadata.parentRevisionIds, isEmpty);
    final source = (await repository.heads(note.sourceEntityId!)).single;
    expect(source.ownerNoteId, note.id);
    expect(
      (await repository.readFiles(source))[starter.fileName],
      starter.bytes,
    );
    expect(observed.publishedSources, [note.sourceEntityId]);
  });

  test('lost response after metadata publication leaves a complete original instead of a ghost', () async {
    final observed = _PublicationRepository(
      repository,
      failAfterMetadata: true,
    );
    await expectLater(
      OfficeDocumentStore(observed).importDocument(
        title: 'Incoming',
        fileName: starter.fileName,
        bytes: starter.bytes,
      ),
      throwsStateError,
    );
    await repository.close();
    repository = await NoteRepository.open(directory);
    final note = (await WorkspaceStore(repository).list()).single;
    expect(note.sourceEntityId, isNotNull);
    expect(
      (await OfficeDocumentStore(repository).readLatest(note)).originalBytes,
      starter.bytes,
    );
  });

  for (final kind in [
    EntityKind.attachment,
    EntityKind.markdown,
    EntityKind.metadata,
  ]) {
    testWidgets(
      'failed image $kind publication leaves no partial visible document',
      (tester) async {
        await tester.runAsync(() async {
          final picture = ui.PictureRecorder();
          ui.Canvas(picture)
              .drawColor(const ui.Color(0xffff0000), ui.BlendMode.src);
          final drawing = picture.endRecording();
          final image = await drawing.toImage(4, 4);
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          drawing.dispose();
          final guarded = _PublicationRepository(repository, failBefore: kind);
          await expectLater(
            ImageNoteImporter(guarded).import(
              title: 'Incoming image',
              fileName: 'original.png',
              bytes: png!.buffer.asUint8List(),
            ),
            throwsStateError,
          );
          expect(await WorkspaceStore(repository).list(), isEmpty);
        });
      },
    );
  }
}

class _PublicationRepository implements NoteRepository {
  new(this.inner, {this.failBefore, this.failAfterMetadata = false});
  final NoteRepository inner;
  final EntityKind? failBefore;
  final bool failAfterMetadata;
  final order = <EntityKind>[];
  final publishedSources = <Object?>[];
  @override
  int get formatVersion => inner.formatVersion;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  Directory get root => inner.root;
  @override
  Stream<void> get changes => inner.changes;
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
  Future<RevisionRecord> commitPrepared(PreparedCommit prepared) =>
      inner.commitPrepared(prepared);
  @override
  Future<RevisionRecord> commit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) async {
    order.add(kind);
    if (kind == failBefore)
      throw StateError('Synthetic failure before $kind publication');
    final result = await inner.commit(
      entityId: entityId,
      kind: kind,
      files: files,
      parentRevisionIds: parentRevisionIds,
      ownerNoteId: ownerNoteId,
      deleted: deleted,
      baseRefs: baseRefs,
    );
    if (kind == EntityKind.metadata) {
      final json = jsonDecode(utf8.decode(files['note.json']!)) as Map;
      publishedSources.add(json['sourceEntityId']);
      if (failAfterMetadata)
        throw StateError('Synthetic lost metadata response');
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
