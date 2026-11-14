import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'template-only image and attachment survive cold reopen and row creation',
    () async {
      await _withDatabase((controller, note, initial) async {
        final session = controller.activeSession!;
        final fixture = _rowMedia(initial);
        final source = fixture.database.rows.single;
        final templateId = newId();
        final templateOnly = fixture.database
            .captureRowTemplate(
              rowId: source.id,
              templateId: templateId,
              name: 'Media template',
            )
            .removeRow(source.id);
        final assets = {
          fixture.image.reference.path: fixture.image.bytes,
          fixture.attachment.reference.path: fixture.attachment.bytes,
        };
        await controller.saveDatabase(
          templateOnly,
          session: session,
          mediaFiles: assets,
        );
        final saved = (await controller.repository.heads(note.inkEntityId))
            .single;
        final savedFiles = await controller.repository.readFiles(saved);

        await controller.closeNote(session: session);
        await controller.replaceRepository(
          await NoteRepository.open(controller.repository.root),
        );
        await controller.openNote(
          (await controller.store.list()).singleWhere(
            (entry) => entry.id == note.id,
          ),
        );
        final reopenedSession = controller.activeSession!;
        final reopened = await controller.loadDatabase(
          session: reopenedSession,
        );
        expect(reopened.rows, isEmpty);
        expect(reopened.rowTemplates.single.id, templateId);
        expect(reopened.toJson(), templateOnly.toJson());
        final newRow = reopened.instantiateRowTemplate(
          templateId: templateId,
          rowId: newId(),
        );
        final originalBody = BlockPageDocument.fromJson(source.body);
        final newBody = BlockPageDocument.fromJson(newRow.body);
        expect(
          newBody.media.keys.toSet().intersection(
            originalBody.media.keys.toSet(),
          ),
          isEmpty,
        );
        await controller.saveDatabase(
          reopened.addRow(newRow),
          session: reopenedSession,
        );
        for (final asset in [fixture.image, fixture.attachment]) {
          expect(
            await controller.readDatabaseRowMedia(
              newRow.id,
              asset.reference,
              session: reopenedSession,
            ),
            asset.bytes,
          );
        }
        expect(await controller.repository.readFiles(saved), savedFiles);
      });
    },
  );

  test('registered DB row PNG and attachment survive metadata save and cold reopen', () async {
    await _withDatabase((controller, note, initial) async {
      final session = controller.activeSession!;
      final fixture = _rowMedia(initial);
      final originalFiles = fixture.files;
      await session.saveInk(originalFiles);
      controller.editMarkdown('DB와 별도의 정리 한글😀');
      await controller.flush();
      final original = (await controller.repository.heads(note.inkEntityId))
          .single;
      final markdown = (await controller.repository.heads(
        note.markdownEntityId,
      )).single;
      final markdownFiles = await controller.repository.readFiles(markdown);

      final loaded = await controller.loadDatabase(session: session);
      expect(loaded.toJson(), fixture.database.toJson());
      final changed = loaded.renameProperty(
        loaded.properties.single.id,
        '수정한 속성 이름',
      );
      await controller.saveDatabase(changed, session: session);
      final saved = (await controller.repository.heads(note.inkEntityId))
          .single;
      expect(saved.revisionId, isNot(original.revisionId));
      expect(saved.parentRevisionIds, [original.revisionId]);
      final savedFiles = await controller.repository.readFiles(saved);
      expect(_database(savedFiles).toJson(), changed.toJson());
      for (final path in originalFiles.keys.where(
        (path) => path != 'database.json',
      )) {
        expect(savedFiles[path], originalFiles[path], reason: path);
      }
      fixture.image.reference.verifyBytes(
        savedFiles[fixture.image.reference.path]!,
      );
      fixture.attachment.reference.verifyBytes(
        savedFiles[fixture.attachment.reference.path]!,
      );
      expect(await controller.repository.readFiles(original), originalFiles);
      expect(
        (await controller.repository.heads(note.markdownEntityId))
            .single
            .revisionId,
        markdown.revisionId,
      );
      expect(await controller.repository.readFiles(markdown), markdownFiles);

      await controller.closeNote(session: session);
      final reopenedRepository = await NoteRepository.open(
        controller.repository.root,
      );
      await controller.replaceRepository(reopenedRepository);
      await controller.openNote(
        (await controller.store.list()).singleWhere(
          (entry) => entry.id == note.id,
        ),
      );
      final reopened = await controller.loadDatabase(
        session: controller.activeSession!,
      );
      expect(reopened.toJson(), changed.toJson());
      final reopenedHead = (await controller.repository.heads(note.inkEntityId))
          .single;
      expect(reopenedHead.revisionId, saved.revisionId);
      expect(await controller.repository.readFiles(reopenedHead), savedFiles);
      expect(controller.markdown, 'DB와 별도의 정리 한글😀');
      expect(
        (await controller.repository.heads(note.markdownEntityId))
            .single
            .revisionId,
        markdown.revisionId,
      );
      expect(await controller.repository.readFiles(original), originalFiles);
    });
  });

  test(
    'ordinary v1 DB metadata save preserves opaque row JSON and snapshot files',
    () async {
      await _withDatabase((controller, note, initial) async {
        final session = controller.activeSession!;
        final body = {
          'version': 1,
          'blocks': [
            {
              'id': newId(),
              'type': 'image',
              'text': 'opaque vendor image',
              'media': {
                'vendor': 'uninterpreted',
                'path': 'not-an-app-media-path',
              },
            },
          ],
          'blockMedia': {
            'vendorRegistry': [1, true, 'keep'],
          },
          'futureBody': {'keep': true},
        };
        final database = initial.addRow(DatabaseRow.create(body: body));
        final files = <String, Uint8List>{
          'database.json': _databaseBytes(database),
          'future/original.bin': Uint8List.fromList([0, 255, 3, 7]),
          'media/unregistered-old.bin': Uint8List.fromList([9, 0, 12]),
        };
        await session.saveInk(files);
        final original = (await controller.repository.heads(note.inkEntityId))
            .single;
        final loaded = await controller.loadDatabase(session: session);
        expect(loaded.rows.single.body, body);
        final changed = loaded.renameProperty(
          loaded.properties.single.id,
          'Metadata edit',
        );
        await controller.saveDatabase(changed, session: session);
        final saved = (await controller.repository.heads(note.inkEntityId))
            .single;
        final after = await controller.repository.readFiles(saved);
        expect(after['future/original.bin'], files['future/original.bin']);
        expect(
          after['media/unregistered-old.bin'],
          files['media/unregistered-old.bin'],
        );
        expect(_database(after).rows.single.body, body);
        expect(await controller.repository.readFiles(original), files);
      });
    },
  );

  for (final failure in ['missing attachment', 'corrupt PNG']) {
    test(
      'DB row media $failure is rejected without publishing a new revision',
      () async {
        await _withDatabase((controller, note, initial) async {
          final session = controller.activeSession!;
          final fixture = _rowMedia(initial);
          final files = fixture.files;
          if (failure == 'missing attachment') {
            files.remove(fixture.attachment.reference.path);
          } else {
            files[fixture.image.reference.path] = Uint8List.fromList(
              fixture.image.bytes,
            )..[0] ^= 1;
          }
          await session.saveInk(files);
          final before = (await controller.repository.heads(note.inkEntityId))
              .single;
          final revisionsBefore = (await controller.repository.revisions())
              .map((record) => record.revisionId)
              .toSet();
          await expectLater(
            controller.loadDatabase(session: session),
            throwsFormatException,
          );
          final candidate = fixture.database.renameProperty(
            initial.properties.single.id,
            'Rejected edit',
          );
          await expectLater(
            controller.saveDatabase(candidate, session: session),
            throwsFormatException,
          );
          expect(
            (await controller.repository.heads(note.inkEntityId))
                .single
                .revisionId,
            before.revisionId,
          );
          expect(
            (await controller.repository.revisions())
                .map((record) => record.revisionId)
                .toSet(),
            revisionsBefore,
          );
          expect(await controller.repository.readFiles(before), files);
        });
      },
    );
  }
  test('controller adds DB row media defensively and retains deleted assets for undo', () async {
    await _withDatabase((controller, _, initial) async {
      final session = controller.activeSession!, fixture = _rowMedia(initial);
      final rowId = fixture.database.rows.single.id;
      final body = BlockPageDocument.fromJson(
        fixture.database.rows.single.body,
      );
      final imageId = body.blocks.first.id;
      final inputImage = fixture.image.bytes,
          inputAttachment = fixture.attachment.bytes;
      final saving = controller.saveDatabase(
        fixture.database,
        session: session,
        mediaFiles: {
          fixture.image.reference.path: inputImage,
          fixture.attachment.reference.path: inputAttachment,
        },
      );
      inputImage.fillRange(0, inputImage.length, 0);
      inputAttachment.fillRange(0, inputAttachment.length, 0);
      await saving;
      expect(
        (await controller.loadDatabaseSnapshot(session: session))
            .mediaBytes(rowId, imageId),
        fixture.image.bytes,
      );
      final exposed = await controller.readDatabaseRowMedia(
        rowId,
        fixture.image.reference,
        session: session,
      );
      exposed[0] ^= 1;
      expect(
        await controller.readDatabaseRowMedia(
          rowId,
          fixture.image.reference,
          session: session,
        ),
        fixture.image.bytes,
      );
      final removed = fixture.database.updateRow(
        fixture.database.rows.single.copyWith(
          body: body.copyWith(blocks: [body.blocks.last]).toJson(),
        ),
      );
      await controller.saveDatabase(removed, session: session);
      expect(
        await controller.readDatabaseRowMedia(
          rowId,
          fixture.image.reference,
          session: session,
        ),
        fixture.image.bytes,
      );
      final loaded = await controller.loadDatabase(session: session);
      expect(BlockPageDocument.fromJson(loaded.rows.single.body).version, 2);
      await controller.saveDatabase(loaded.archiveRow(rowId), session: session);
      await expectLater(
        controller.readDatabaseRowMedia(
          rowId,
          fixture.image.reference,
          session: session,
        ),
        throwsStateError,
      );
      await controller.saveDatabase(loaded.removeRow(rowId), session: session);
      await expectLater(
        controller.readDatabaseRowMedia(
          rowId,
          fixture.image.reference,
          session: session,
        ),
        throwsStateError,
      );
    });
  });

  for (final operation in ['load', 'read', 'save']) {
    for (final mutation in ['selected', 'session', 'repository']) {
      test(
        'DB media $operation rejects $mutation mutation after bytes arrive',
        () async {
          await _withDatabase((controller, _, initial) async {
            final session = controller.activeSession!,
                old = controller.activeSession!.inkParents.single;
            final fixture = _rowMedia(initial);
            await session.saveInk(fixture.files);
            await controller.refresh();
            final selected = List<String>.of(session.inkParents);
            final proxy = _DatabaseRepository(controller.repository);
            controller.repository = proxy;
            session.repository = proxy;
            final replacementDirectory = mutation == 'repository'
                ? await Directory.systemTemp.createTemp('database-media-other-')
                : null;
            final replacement = replacementDirectory == null
                ? null
                : await NoteRepository.open(
                    replacementDirectory,
                    createFormatVersion: 2,
                  );
            final changed = Completer<void>();
            proxy.afterRead = () => Timer.run(() {
              if (mutation == 'selected') {
                session.inkParents = [old];
              } else if (mutation == 'session') {
                controller.activeSession = null;
              } else {
                controller.repository = replacement!;
              }
              changed.complete();
            });
            final pending = switch (operation) {
              'load' =>
                controller
                    .loadDatabaseSnapshot(session: session)
                    .then<void>((_) {}),
              'read' =>
                controller
                    .readDatabaseRowMedia(
                      fixture.database.rows.single.id,
                      fixture.image.reference,
                      session: session,
                    )
                    .then<void>((_) {}),
              _ => controller.saveDatabase(fixture.database, session: session),
            };
            try {
              await expectLater(pending, throwsStateError);
              await changed.future.timeout(const Duration(seconds: 5));
              expect(
                (await proxy.inner.heads(session.note.inkEntityId))
                    .single
                    .revisionId,
                selected.single,
              );
            } finally {
              await changed.future.timeout(const Duration(seconds: 5));
              controller.repository = proxy;
              controller.activeSession = session;
              session.repository = proxy;
              session.inkParents = selected;
              await replacement?.close();
              await replacementDirectory?.delete(recursive: true);
            }
          });
        },
      );
    }
  }

  test(
    'DB late media read and old-session save reject after closing the note',
    () async {
      await _withDatabase((controller, _, initial) async {
        final session = controller.activeSession!, fixture = _rowMedia(initial);
        await session.saveInk(fixture.files);
        await controller.refresh();
        final proxy = _DatabaseRepository(controller.repository);
        controller.repository = proxy;
        session.repository = proxy;
        proxy.pauseEntity = session.note.inkEntityId;
        final reading = controller.readDatabaseRowMedia(
          fixture.database.rows.single.id,
          fixture.image.reference,
          session: session,
        );
        await proxy.readEntered.future.timeout(const Duration(seconds: 5));
        await controller.closeNote(session: session);
        proxy.releaseRead.complete();
        await expectLater(reading, throwsStateError);
        await expectLater(
          controller.saveDatabase(fixture.database, session: session),
          throwsStateError,
        );
        await expectLater(
          controller.loadDatabaseSnapshot(session: session),
          throwsStateError,
        );
      });
    },
  );

  for (final failBefore in [true, false]) {
    test(
      'DB media retry preserves exact prepared revision failBefore=$failBefore',
      () async {
        await _withDatabase((controller, note, initial) async {
          final session = controller.activeSession!,
              fixture = _rowMedia(initial);
          await controller.refresh();
          final proxy = _DatabaseRepository(controller.repository)
            ..failBefore = failBefore;
          controller.repository = proxy;
          session.repository = proxy;
          final before = (await proxy.inner.heads(note.inkEntityId)).single;
          final beforeFiles = await proxy.inner.readFiles(before);
          proxy.failNextInk = true;
          await expectLater(
            controller.saveDatabase(
              fixture.database,
              session: session,
              mediaFiles: {
                fixture.image.reference.path: fixture.image.bytes,
                fixture.attachment.reference.path: fixture.attachment.bytes,
              },
            ),
            throwsStateError,
          );
          final attempted = proxy.attemptedIds.single;
          await controller.saveDatabase(
            fixture.database,
            session: session,
            mediaFiles: {
              fixture.image.reference.path: fixture.image.bytes,
              fixture.attachment.reference.path: fixture.attachment.bytes,
            },
          );
          final after = (await proxy.inner.heads(note.inkEntityId)).single;
          expect(after.revisionId, attempted);
          expect(proxy.attemptedIds.toSet(), {attempted});
          expect(await proxy.inner.readFiles(before), beforeFiles);
          final row = fixture.database.rows.single;
          expect(
            (await controller.loadDatabaseSnapshot(session: session))
                .mediaBytes(
                  row.id,
                  BlockPageDocument.fromJson(row.body).blocks.first.id,
                ),
            fixture.image.bytes,
          );
        });
      },
    );
  }

  test(
    'DB media save keeps a remote writer as an independent branch',
    () async {
      await _withDatabase((controller, note, initial) async {
        final session = controller.activeSession!, fixture = _rowMedia(initial);
        final selected = List<String>.of(session.inkParents);
        await controller.refresh();
        final proxy = _DatabaseRepository(controller.repository);
        controller.repository = proxy;
        session.repository = proxy;
        RevisionRecord? remote;
        proxy.beforeInkPublish = () async {
          proxy.beforeInkPublish = null;
          remote = await proxy.inner.commit(
            entityId: note.inkEntityId,
            kind: EntityKind.ink,
            ownerNoteId: note.id,
            files: {
              'database.json': _databaseBytes(
                initial.renameProperty(
                  initial.properties.single.id,
                  'Remote writer',
                ),
              ),
            },
            parentRevisionIds: selected,
          );
        };
        await controller.saveDatabase(
          fixture.database,
          session: session,
          mediaFiles: {
            fixture.image.reference.path: fixture.image.bytes,
            fixture.attachment.reference.path: fixture.attachment.bytes,
          },
        );
        final heads = await proxy.inner.heads(note.inkEntityId);
        expect(heads, hasLength(2));
        expect(
          heads.map((head) => head.revisionId),
          contains(remote!.revisionId),
        );
        final local = heads.singleWhere(
          (head) => head.revisionId != remote!.revisionId,
        );
        expect(
          (await proxy.inner.readFiles(local))[fixture.image.reference.path],
          fixture.image.bytes,
        );
        expect(
          _database(await proxy.inner.readFiles(remote!))
              .properties
              .single
              .name,
          'Remote writer',
        );
      });
    },
  );

  test('DB identity and ordinary row media downgrade cannot replace the saved snapshot', () async {
    await _withDatabase((controller, note, initial) async {
      final session = controller.activeSession!, fixture = _rowMedia(initial);
      await session.saveInk(fixture.files);
      final before = (await controller.repository.heads(note.inkEntityId))
          .single;
      await expectLater(
        controller.saveDatabase(WorkspaceDatabase.empty(), session: session),
        throwsFormatException,
      );
      final downgraded = fixture.database.updateRow(
        fixture.database.rows.single.copyWith(
          body: const BlockPageDocument.empty().toJson(),
        ),
      );
      await expectLater(
        controller.saveDatabase(downgraded, session: session),
        throwsFormatException,
      );
      expect(
        (await controller.repository.heads(note.inkEntityId)).single.revisionId,
        before.revisionId,
      );
      expect(await controller.repository.readFiles(before), fixture.files);
    });
  });
}

WorkspaceDatabase _database(Map<String, Uint8List> files) =>
    WorkspaceDatabase.fromJson(
      jsonObject(jsonDecode(utf8.decode(files['database.json']!))),
    );
Uint8List _databaseBytes(WorkspaceDatabase database) =>
    Uint8List.fromList(utf8.encode(jsonEncode(database.toJson())));

({
  WorkspaceDatabase database,
  BlockPageMediaAsset image,
  BlockPageMediaAsset attachment,
  Map<String, Uint8List> files,
})
_rowMedia(WorkspaceDatabase initial) {
  final image = BlockPageMediaAsset.image(
    name: 'DB 그림.png',
    bytes: im.encodePng(
      im.Image(width: 3, height: 2)..setPixelRgba(1, 1, 255, 40, 70, 255),
    ),
  );
  final attachment = BlockPageMediaAsset.attachment(
    name: '강의.pptx',
    bytes: [80, 75, 3, 4, 0, 255, 9],
    mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  );
  final picture = BlockPageBlock.create(type: 'image', text: 'DB 그림 설명');
  final file = BlockPageBlock.create(type: 'attachment', text: 'DB 첨부 설명');
  final body = const BlockPageDocument.empty().copyWith(
    blocks: [picture, file],
    media: {picture.id: image.reference, file.id: attachment.reference},
  );
  final database = initial.addRow(
    DatabaseRow.create(
      values: {initial.properties.single.id: '미디어 행'},
      body: body.toJson(),
    ),
  );
  return (
    database: database,
    image: image,
    attachment: attachment,
    files: {
      'database.json': _databaseBytes(database),
      image.reference.path: image.bytes,
      attachment.reference.path: attachment.bytes,
      'future/opaque.bin': Uint8List.fromList([0, 255, 42]),
    },
  );
}

Future<void> _withDatabase(
  Future<void> Function(WorkspaceController, VaultNote, WorkspaceDatabase)
  action,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'database-media-integration-',
  );
  final controller = WorkspaceController(
    await NoteRepository.open(
      Directory(p.join(directory.path, 'vault')),
      createFormatVersion: 2,
    ),
    directoryProvider: () async => Directory(p.join(directory.path, 'support')),
  );
  try {
    final note = await controller.createNote(
      'DB media',
      documentKind: VaultDocumentKind.database,
    );
    final initial = await controller.loadDatabase(
      session: controller.activeSession!,
    );
    await action(controller, note, initial);
    await controller.flush();
  } finally {
    controller.dispose();
    await controller.repository.close();
    await directory.delete(recursive: true);
  }
}

class _DatabaseRepository implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  String? pauseEntity;
  final readEntered = Completer<void>(), releaseRead = Completer<void>();
  void Function()? afterRead;
  Future<void> Function()? beforeInkPublish;
  var failNextInk = false, failBefore = false;
  final attemptedIds = <String>[];
  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  Stream<void> get changes => inner.changes;
  @override
  List<String> get integrityIssues => inner.integrityIssues;
  @override
  int get pendingRevisionCount => inner.pendingRevisionCount;
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<Uint8List> readBlob(String hash) => inner.readBlob(hash);
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) async {
    if (record.entityId == pauseEntity) {
      pauseEntity = null;
      readEntered.complete();
      await releaseRead.future;
    }
    final files = await inner.readFiles(record);
    final callback = afterRead;
    afterRead = null;
    callback?.call();
    return files;
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
  Future<RevisionRecord> commitPrepared(PreparedCommit prepared) async {
    if (prepared.record.kind == EntityKind.ink) {
      attemptedIds.add(prepared.record.revisionId);
      await beforeInkPublish?.call();
      if (failNextInk && failBefore) {
        failNextInk = false;
        throw StateError('Synthetic DB failure before publication');
      }
    }
    final result = await inner.commitPrepared(prepared);
    if (prepared.record.kind == EntityKind.ink && failNextInk) {
      failNextInk = false;
      throw StateError('Synthetic DB lost publication response');
    }
    return result;
  }

  @override
  Future<void> close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
