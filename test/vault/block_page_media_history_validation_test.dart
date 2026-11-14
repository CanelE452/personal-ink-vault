import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List _bytes(BlockPageDocument document) =>
    Uint8List.fromList(utf8.encode(jsonEncode(document.toJson())));

void main() {
  late Directory directory;
  late NoteRepository repository;
  late WorkspaceStore store;
  late VaultNote note;
  late NoteSession session;
  late BlockPageMediaAsset image;
  late BlockPageBlock block;
  late BlockPageDocument mediaPage;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'block-media-history-validation-',
    );
    repository = await NoteRepository.open(directory, createFormatVersion: 2);
    store = WorkspaceStore(repository);
    note = await store.create('Page', documentKind: VaultDocumentKind.page);
    session = await store.open(note);
    image = BlockPageMediaAsset.image(
      name: 'History.png',
      bytes: im.encodePng(im.Image(width: 2, height: 3)),
    );
    block = BlockPageBlock.create(type: 'image', text: 'History image');
    mediaPage = const BlockPageDocument.empty().copyWith(
      blocks: [block],
      media: {block.id: image.reference},
    );
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  Future<RevisionRecord> save(Map<String, Uint8List> files) async {
    await session.saveInk(files);
    return (await repository.heads(note.inkEntityId)).single;
  }

  Map<String, Uint8List> validMediaFiles() => {
    'page.json': _bytes(mediaPage),
    image.reference.path: image.bytes,
  };
  Future<RevisionRecord> current() => save({
    'page.json': _bytes(
      const BlockPageDocument.empty().copyWith(
        blocks: [BlockPageBlock.create(text: 'Current complete page')],
      ),
    ),
  });

  for (final failure in ['missing', 'corrupt', 'dimensions', 'mime']) {
    test(
      'restore rejects canonical revision with $failure media before publication',
      () async {
        final selectedFiles = validMediaFiles();
        if (failure == 'missing') selectedFiles.remove(image.reference.path);
        if (failure == 'corrupt')
          selectedFiles[image.reference.path] = Uint8List.fromList([1, 2, 3]);
        if (failure == 'dimensions' || failure == 'mime') {
          final raw = mediaPage.toJson();
          raw['blockMedia'] = {
            block.id: {
              ...image.reference.toJson(),
              if (failure == 'dimensions') 'width': 3,
              if (failure == 'mime') 'mimeType': 'image/jpeg',
            },
          };
          selectedFiles['page.json'] = Uint8List.fromList(
            utf8.encode(jsonEncode(raw)),
          );
        }
        final chosen = await save(selectedFiles);
        final observed = await current();
        final count = (await repository.revisions()).length;
        await expectLater(
          session.restoreInkRevision(
            chosen,
            expectedHeadRevisionIds: [observed.revisionId],
          ),
          throwsFormatException,
        );
        expect((await repository.revisions()).length, count);
        expect(
          (await repository.heads(note.inkEntityId)).single.revisionId,
          observed.revisionId,
        );
        expect(await repository.readFiles(chosen), selectedFiles);
      },
    );
  }

  test('recovering a guarded prepared restore also validates its selected media bytes', () async {
    final invalid = {
      'page.json': _bytes(mediaPage),
      image.reference.path: Uint8List.fromList([0, 9, 8]),
    };
    final chosen = await save(invalid);
    final observed = await current();
    final heads = await session.captureInkRevisionRestoreHeads(observed);
    final prepared = repository.prepareCommit(
      entityId: note.inkEntityId,
      ownerNoteId: note.id,
      kind: EntityKind.ink,
      parentRevisionIds: [observed.revisionId],
      files: invalid,
      baseRefs: chosen.baseRefs,
    );
    final count = (await repository.revisions()).length;
    await expectLater(
      session.resumeInkRevisionRestore({
        'version': 1,
        'selectedRevisionId': chosen.revisionId,
        'expectedHeads': heads,
        'prepared': prepared.toRecoveryDescriptor(),
      }),
      throwsFormatException,
    );
    expect((await repository.revisions()).length, count);
    expect(
      (await repository.heads(note.inkEntityId)).single.revisionId,
      observed.revisionId,
    );
  });

  test(
    'foreign history ownership is rejected before reading its payload',
    () async {
      final observed = await current();
      final foreignNote = await store.create(
        'Other page',
        documentKind: VaultDocumentKind.page,
      );
      final foreignSession = await store.open(foreignNote);
      await foreignSession.saveInk(validMediaFiles());
      final foreign = (await repository.heads(foreignNote.inkEntityId)).single;
      final tracking = _HistoryReadLog(repository);
      session.repository = tracking;
      await expectLater(
        session.restoreInkRevision(
          foreign,
          expectedHeadRevisionIds: [observed.revisionId],
        ),
        throwsFormatException,
      );
      expect(tracking.readIds, isNot(contains(foreign.revisionId)));
      expect(tracking.preparedCount, 0);
      expect(
        (await repository.heads(note.inkEntityId)).single.revisionId,
        observed.revisionId,
      );
    },
  );

  test(
    'forged selected blob map is rejected before any selected payload read',
    () async {
      final chosen = await save(validMediaFiles());
      final observed = await current();
      final forged = RevisionRecord.fromJson({
        ...chosen.toJson(),
        'blobs': {
          'page.json': {'hash': List.filled(64, 'a').join(), 'length': 2},
        },
      });
      final tracking = _HistoryReadLog(repository);
      session.repository = tracking;
      await expectLater(
        session.restoreInkRevision(
          forged,
          expectedHeadRevisionIds: [observed.revisionId],
        ),
        throwsFormatException,
      );
      expect(tracking.readIds, isNot(contains(chosen.revisionId)));
      expect(tracking.preparedCount, 0);
    },
  );

  test(
    'valid whole media restoration keeps source files and separate Markdown',
    () async {
      final files = {
        ...validMediaFiles(),
        'future/opaque.bin': Uint8List.fromList([1, 255, 0]),
      };
      final chosen = await save(files);
      final observed = await current();
      await session.saveMarkdown('Keep separate summary');
      await session.restoreInkRevision(
        chosen,
        expectedHeadRevisionIds: [observed.revisionId],
      );
      final restored = (await repository.heads(note.inkEntityId)).single;
      expect(restored.parentRevisionIds, [observed.revisionId]);
      expect(restored.revisionId, isNot(chosen.revisionId));
      expect(await repository.readFiles(restored), files);
      expect(await repository.readFiles(chosen), files);
      expect(
        BlockPageMediaSnapshot.fromFiles(await repository.readFiles(restored))
            .mediaBytes(block.id),
        image.bytes,
      );
      expect(await session.readMarkdown(), 'Keep separate summary');
    },
  );

  test('explicit restoration of v1 before media remains allowed without reinterpreting opaque data', () async {
    final opaque = BlockPageDocument.fromJson({
      'version': 1,
      'blockMedia': {'opaque': 'old registry extension'},
      'blocks': [
        {
          'id': newId(),
          'type': 'image',
          'text': 'Old opaque image',
          'media': {'future': true},
        },
      ],
    });
    final oldFiles = {
      'page.json': _bytes(opaque),
      'old/unknown.bin': Uint8List.fromList([7, 6, 5]),
    };
    final chosen = await save(oldFiles);
    final observed = await save(validMediaFiles());
    await session.restoreInkRevision(
      chosen,
      expectedHeadRevisionIds: [observed.revisionId],
    );
    final restored = (await repository.heads(note.inkEntityId)).single;
    final snapshot = BlockPageMediaSnapshot.fromFiles(
      await repository.readFiles(restored),
    );
    expect(snapshot.document.version, 1);
    expect(snapshot.document.toJson(), opaque.toJson());
    expect(snapshot.document.media, isEmpty);
    expect(snapshot.files['old/unknown.bin'], [7, 6, 5]);
  });
}

class _HistoryReadLog implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  final readIds = <String>[];
  var preparedCount = 0;
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
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) {
    readIds.add(record.revisionId);
    return inner.readFiles(record);
  }

  @override
  PreparedCommit prepareCommit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) {
    preparedCount++;
    return inner.prepareCommit(
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
