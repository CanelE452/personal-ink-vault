import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/linked_database_session.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('linked source opens without replacing the page or relaxing ordinary DB guards', () async {
    await _withFixture((f) async {
      final ownerHead = f.owner.inkParents.single;
      final LinkedDatabaseSession link = await f.controller.openLinkedDatabase(
        f.source.id,
        owner: f.owner,
      );
      expect(f.controller.activeSession, same(f.owner));
      expect(link.owner, same(f.owner));
      expect(link.target.note.id, f.source.id);
      expect(link.target.repository, same(f.repository));
      expect(link.database.toJson(), f.initial.toJson());
      expect(link.revisionId, link.target.inkParents.single);
      expect(link.isClosed, isFalse);
      expect(f.owner.inkParents, [ownerHead]);
      await expectLater(
        f.controller.loadDatabase(session: link.target),
        throwsStateError,
      );
      await expectLater(
        f.controller.saveDatabase(link.database, session: link.target),
        throwsStateError,
      );
    });
  });

  test('row edits publish only the original database and preserve views, opaque files and old revisions', () async {
    await _withFixture((f) async {
      final pageHead = (await f.repository.heads(f.page.id)).single;
      final pageBody = (await f.repository.heads(f.page.inkEntityId)).single;
      final original = (await f.repository.heads(f.source.inkEntityId)).single;
      final originalFiles = await f.repository.readFiles(original);
      final markdown = (await f.repository.heads(f.source.markdownEntityId))
          .single;
      final link = await f.controller.openLinkedDatabase(
        f.source.id,
        owner: f.owner,
      );
      final changed = link.database.setCell(f.row.id, f.titleId, '연구 자료 수정 😀');
      await f.controller.saveLinkedDatabase(link, changed);
      final saved = (await f.repository.heads(f.source.inkEntityId)).single;
      final savedFiles = await f.repository.readFiles(saved);
      expect(saved.parentRevisionIds, [original.revisionId]);
      expect(saved.revisionId, link.revisionId);
      expect(link.database.toJson(), changed.toJson());
      expect(_database(savedFiles).toJson(), changed.toJson());
      expect(
        savedFiles['future/original.bin'],
        originalFiles['future/original.bin'],
      );
      expect(await f.repository.readFiles(original), originalFiles);
      expect(
        (await f.repository.heads(f.page.id)).single.revisionId,
        pageHead.revisionId,
      );
      expect(
        (await f.repository.heads(f.page.inkEntityId)).single.revisionId,
        pageBody.revisionId,
      );
      expect(
        (await f.repository.heads(f.source.markdownEntityId)).single.revisionId,
        markdown.revisionId,
      );
      expect(
        link.database.views.map((view) => view.toJson()),
        f.initial.views.map((view) => view.toJson()),
      );
      expect(f.controller.activeSession, same(f.owner));
    });
  });

  test(
    'a linked view definition cannot overwrite the source database views',
    () async {
      await _withFixture((f) async {
        final link = await f.controller.openLinkedDatabase(
          f.source.id,
          owner: f.owner,
        );
        final before = await _revisionIds(f.repository);
        final localView = link.database.views.single.copyWith(
          name: '이 페이지에만 보이는 보기',
        );
        await expectLater(
          f.controller.saveLinkedDatabase(
            link,
            link.database.copyWith(views: [localView]),
          ),
          throwsFormatException,
        );
        expect(await _revisionIds(f.repository), before);
        expect(link.database.views.single.name, f.initial.views.single.name);
      });
    },
  );

  test('Rust-style map key reordering preserves equivalent source views during row save', () async {
    await _withFixture((f) async {
      final view = DatabaseView.fromJson({
        ...f.initial.views.single.toJson(),
        'futureView': {
          'second': [
            2,
            1,
            {'tail': 7, 'head': 3},
          ],
          'first': {'z': true, 'a': false},
        },
      });
      await _externalBody(f, f.initial.copyWith(views: [view]));
      final link = await f.controller.openLinkedDatabase(
        f.source.id,
        owner: f.owner,
      );
      Object? reorder(Object? value) {
        if (value is Map) {
          return <String, dynamic>{
            for (final entry in value.entries.toList().reversed)
              entry.key as String: reorder(entry.value),
          };
        }
        if (value is List) return [for (final item in value) reorder(item)];
        return value;
      }

      final candidate = WorkspaceDatabase.fromJson(
        reorder(link.database.toJson()) as Map<String, dynamic>,
      ).setCell(f.row.id, f.titleId, 'Rust에서 계산한 행 수정');
      expect(
        jsonEncode(candidate.views.map((item) => item.toJson()).toList()),
        isNot(
          jsonEncode(link.database.views.map((item) => item.toJson()).toList()),
        ),
      );
      await f.controller.saveLinkedDatabase(link, candidate);
      final files = await f.repository.readFiles(
        (await f.repository.heads(f.source.inkEntityId)).single,
      );
      final saved = _database(files);
      expect(saved.rows.first.values[f.titleId], 'Rust에서 계산한 행 수정');
      expect(saved.views.map((item) => item.toJson()), [view.toJson()]);
      expect(
        saved.toJson()['futureDatabase'],
        f.initial.toJson()['futureDatabase'],
      );
    });
  });

  for (final change in [
    'database identity',
    'view array order',
    'unknown nested array order',
  ]) {
    test('source view equality still rejects $change', () async {
      await _withFixture((f) async {
        final source = f.initial.copyWith(
          views: [
            DatabaseView.fromJson({
              ...f.initial.views.single.toJson(),
              'futureView': {
                'ordered': [1, 2],
              },
            }),
            DatabaseView.create(name: '별도 원본 보기', type: 'list'),
          ],
        );
        await _externalBody(f, source);
        final link = await f.controller.openLinkedDatabase(
          f.source.id,
          owner: f.owner,
        );
        final raw = link.database.toJson();
        if (change == 'database identity') {
          raw['id'] = newId();
        } else if (change == 'view array order') {
          raw['views'] = (raw['views'] as List).reversed.toList();
        } else {
          final first = (raw['views'] as List).first as Map;
          (first['futureView'] as Map)['ordered'] = [2, 1];
        }
        final before = await _revisionIds(f.repository);
        await expectLater(
          f.controller.saveLinkedDatabase(
            link,
            WorkspaceDatabase.fromJson(raw),
          ),
          throwsFormatException,
        );
        expect(await _revisionIds(f.repository), before);
        expect(link.database.toJson(), source.toJson());
      });
    });
  }

  test('two pages share the same source rows and a renamed source keeps its fixed identity', () async {
    await _withFixture((f) async {
      final first = await f.controller.openLinkedDatabase(
        f.source.id,
        owner: f.owner,
      );
      await f.controller.saveLinkedDatabase(
        first,
        first.database.setCell(f.row.id, f.titleId, '두 페이지가 함께 보는 행'),
      );
      first.close();
      await f.controller.closeNote(session: f.owner);
      await f.controller.openNote(f.otherPage);
      final secondOwner = f.controller.activeSession!;
      await _metadataRevision(f, title: '이름을 바꾼 자료 DB');
      final second = await f.controller.openLinkedDatabase(
        f.source.id,
        owner: secondOwner,
      );
      expect(second.target.note.id, f.source.id);
      expect(second.target.note.title, '이름을 바꾼 자료 DB');
      expect(second.database.rows.first.values[f.titleId], '두 페이지가 함께 보는 행');
      await f.controller.saveLinkedDatabase(
        second,
        second.database.setCell(f.row.id, f.titleId, '다른 페이지에서 다시 수정'),
      );
      await f.controller.closeNote(session: secondOwner);
      await f.controller.openNote(f.page);
      final reopened = await f.controller.openLinkedDatabase(
        f.source.id,
        owner: f.controller.activeSession!,
      );
      expect(reopened.database.rows.first.values[f.titleId], '다른 페이지에서 다시 수정');
      expect(reopened.database.id, f.initial.id);
    });
  });

  for (final unavailable in [
    'missing',
    'wrong kind',
    'deleted',
    'metadata conflict',
    'body conflict',
    'deleted body',
  ]) {
    test(
      'opening a $unavailable linked source is rejected without publication',
      () async {
        await _withFixture((f) async {
          var sourceId = f.source.id;
          if (unavailable == 'missing') {
            sourceId = newId();
          } else if (unavailable == 'wrong kind') {
            sourceId = f.otherPage.id;
          } else if (unavailable == 'deleted') {
            await _metadataRevision(f, deleted: true);
          } else if (unavailable == 'metadata conflict') {
            final original = (await f.repository.heads(f.source.id)).single;
            await _metadataRevision(f, title: '첫 분기');
            await f.inner.commit(
              entityId: f.source.id,
              kind: EntityKind.metadata,
              files: await f.inner.readFiles(original),
              parentRevisionIds: [original.revisionId],
            );
          } else if (unavailable == 'body conflict') {
            final original = (await f.repository.heads(f.source.inkEntityId))
                .single;
            await _externalBody(
              f,
              f.initial.setCell(f.row.id, f.titleId, '첫 본문 분기'),
            );
            await f.inner.commit(
              entityId: f.source.inkEntityId,
              kind: EntityKind.ink,
              ownerNoteId: f.source.id,
              files: await f.inner.readFiles(original),
              parentRevisionIds: [original.revisionId],
            );
          } else {
            final original = (await f.repository.heads(f.source.inkEntityId))
                .single;
            await f.inner.commit(
              entityId: f.source.inkEntityId,
              kind: EntityKind.ink,
              ownerNoteId: f.source.id,
              files: await f.inner.readFiles(original),
              parentRevisionIds: [original.revisionId],
              deleted: true,
            );
          }
          final before = await _revisionIds(f.repository);
          await expectLater(
            f.controller.openLinkedDatabase(sourceId, owner: f.owner),
            throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
          );
          expect(await _revisionIds(f.repository), before);
          expect(f.controller.activeSession, same(f.owner));
        });
      },
    );
  }

  for (final changed in ['body', 'metadata']) {
    test(
      'a stale source $changed cannot be silently replaced by a linked save',
      () async {
        await _withFixture((f) async {
          final link = await f.controller.openLinkedDatabase(
            f.source.id,
            owner: f.owner,
          );
          final candidate = link.database.setCell(
            f.row.id,
            f.titleId,
            '낡은 화면의 입력',
          );
          if (changed == 'body') {
            await _externalBody(
              f,
              f.initial.setCell(f.row.id, f.titleId, '다른 작성자의 입력'),
            );
          } else {
            await _metadataRevision(f, title: '다른 작성자가 이름 변경');
          }
          final before = await _revisionIds(f.repository);
          await expectLater(
            f.controller.saveLinkedDatabase(link, candidate),
            throwsStateError,
          );
          expect(await _revisionIds(f.repository), before);
          expect(link.database.toJson(), f.initial.toJson());
        });
      },
    );
  }

  for (final transition in [
    'link closed',
    'owner closed',
    'repository switched',
    'controller disposed',
  ]) {
    test('$transition invalidates linked callbacks', () async {
      await _withFixture((f) async {
        final link = await f.controller.openLinkedDatabase(
          f.source.id,
          owner: f.owner,
        );
        final before = await _revisionIds(f.inner);
        if (transition == 'link closed') {
          link.close();
          link.close();
          expect(link.isClosed, isTrue);
        } else if (transition == 'owner closed') {
          await f.controller.closeNote(session: f.owner);
        } else if (transition == 'repository switched') {
          final next = await NoteRepository.open(
            Directory(p.join(f.directory.path, 'next')),
            createFormatVersion: 2,
          );
          f.extraRepositories.add(next);
          await f.controller.replaceRepository(next);
        } else {
          f.controller.dispose();
          f.controllerDisposed = true;
        }
        await expectLater(
          f.controller.saveLinkedDatabase(
            link,
            link.database.setCell(f.row.id, f.titleId, '늦은 입력'),
          ),
          throwsStateError,
        );
        if (transition == 'controller disposed' ||
            transition == 'repository switched') {
          await f.inner.close();
          final reopened = await NoteRepository.open(f.inner.root);
          try {
            expect(await _revisionIds(reopened), before);
          } finally {
            await reopened.close();
          }
        } else {
          expect(await _revisionIds(f.inner), before);
        }
      });
    });
  }

  test('a source read finishing after its owner closes cannot create a live linked session', () async {
    await _withFixture((f) async {
      f.repository.pauseEntity = f.source.inkEntityId;
      final pending = f.controller.openLinkedDatabase(
        f.source.id,
        owner: f.owner,
      );
      await f.repository.readEntered.future.timeout(const Duration(seconds: 5));
      await f.controller.closeNote(session: f.owner);
      f.repository.releaseRead.complete();
      await expectLater(pending, throwsStateError);
      expect(f.controller.activeSession, isNull);
    });
  });

  test('registered row media remains source-owned and cannot be read through another row', () async {
    await _withFixture((f) async {
      final asset = BlockPageMediaAsset.attachment(
        name: '강의 자료.pptx',
        bytes: [80, 75, 3, 4, 0, 255, 7],
        mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      );
      final block = BlockPageBlock.create(type: 'attachment', text: '자료 설명');
      final body = const BlockPageDocument.empty().copyWith(
        blocks: [block],
        media: {block.id: asset.reference},
      );
      final database = f.initial.updateRow(f.row.copyWith(body: body.toJson()));
      await _externalBody(
        f,
        database,
        added: {asset.reference.path: asset.bytes},
      );
      final link = await f.controller.openLinkedDatabase(
        f.source.id,
        owner: f.owner,
      );
      expect(
        await f.controller.readLinkedDatabaseRowMedia(
          link,
          f.row.id,
          asset.reference,
        ),
        asset.bytes,
      );
      await expectLater(
        f.controller.readLinkedDatabaseRowMedia(
          link,
          f.otherRow.id,
          asset.reference,
        ),
        throwsFormatException,
      );
      final changed = link.database.setCell(f.row.id, f.titleId, '설명을 유지한 자료');
      await f.controller.saveLinkedDatabase(link, changed);
      final files = await f.repository.readFiles(
        (await f.repository.heads(f.source.inkEntityId)).single,
      );
      expect(files[asset.reference.path], asset.bytes);
      expect(files['future/original.bin'], [0, 255, 42]);
      expect(
        BlockPageDocument.fromJson(link.database.rows.first.body)
            .media[block.id]!
            .toJson(),
        asset.reference.toJson(),
      );
      link.close();
      await expectLater(
        f.controller.readLinkedDatabaseRowMedia(
          link,
          f.row.id,
          asset.reference,
        ),
        throwsStateError,
      );
    });
  });

  for (final failure in ['before publication', 'lost publication response']) {
    test(
      'linked save retry after $failure reuses exactly one prepared source revision',
      () async {
        await _withFixture((f) async {
          final link = await f.controller.openLinkedDatabase(
            f.source.id,
            owner: f.owner,
          );
          final original = link.revisionId;
          final candidate = link.database.setCell(
            f.row.id,
            f.titleId,
            '재시도할 입력',
          );
          f.repository.failNext = true;
          f.repository.failBefore = failure == 'before publication';
          await expectLater(
            f.controller.saveLinkedDatabase(link, candidate),
            throwsStateError,
          );
          expect(link.revisionId, original);
          expect(link.database.toJson(), f.initial.toJson());
          await f.controller.saveLinkedDatabase(link, candidate);
          final head = (await f.repository.heads(f.source.inkEntityId)).single;
          expect(link.revisionId, head.revisionId);
          expect(head.parentRevisionIds, [original]);
          expect(link.database.toJson(), candidate.toJson());
          expect(f.repository.attemptedIds.toSet(), {head.revisionId});
          final descendants = (await f.repository.revisions()).where(
            (record) =>
                record.entityId == f.source.inkEntityId &&
                record.parentRevisionIds.contains(original),
          );
          expect(descendants.length, 1);
        });
      },
    );
  }

  test('closing a link at the conditional publication boundary rejects its pending write', () async {
    await _withFixture((f) async {
      final link = await f.controller.openLinkedDatabase(
        f.source.id,
        owner: f.owner,
      );
      final before = await _revisionIds(f.repository);
      f.repository.beforeConditional = () async => link.close();
      await expectLater(
        f.controller.saveLinkedDatabase(
          link,
          link.database.setCell(f.row.id, f.titleId, '닫힌 링크의 입력'),
        ),
        throwsStateError,
      );
      expect(await _revisionIds(f.repository), before);
    });
  });

  for (final failure in ['before publication', 'lost publication response']) {
    test(
      'newer input after $failure first acknowledges the pending source revision',
      () async {
        await _withFixture((f) async {
          final link = await f.controller.openLinkedDatabase(
            f.source.id,
            owner: f.owner,
          );
          final original = link.revisionId;
          final first = link.database.setCell(f.row.id, f.titleId, '먼저 보낸 입력');
          f.repository.failNext = true;
          f.repository.failBefore = failure == 'before publication';
          await expectLater(
            f.controller.saveLinkedDatabase(link, first),
            throwsStateError,
          );
          final newer = first.setCell(f.row.id, f.titleId, '실패 뒤에 더 작성한 입력');
          await f.controller.saveLinkedDatabase(link, newer);
          final source = (await f.repository.heads(f.source.inkEntityId))
              .single;
          final history = (await f.repository.revisions())
              .where((record) => record.entityId == f.source.inkEntityId)
              .toList();
          final firstPublished = history.singleWhere(
            (record) => record.parentRevisionIds.contains(original),
          );
          expect(source.parentRevisionIds, [firstPublished.revisionId]);
          expect(
            _database(await f.repository.readFiles(firstPublished))
                .rows
                .first
                .values[f.titleId],
            '먼저 보낸 입력',
          );
          expect(
            _database(await f.repository.readFiles(source))
                .rows
                .first
                .values[f.titleId],
            '실패 뒤에 더 작성한 입력',
          );
          expect(link.database.toJson(), newer.toJson());
          expect(link.revisionId, source.revisionId);
          expect(f.repository.attemptedIds.toSet().length, 2);
        });
      },
    );
  }

  test('a remote descendant after a lost response cannot be acknowledged as the old linked selection', () async {
    await _withFixture((f) async {
      final link = await f.controller.openLinkedDatabase(
        f.source.id,
        owner: f.owner,
      );
      final original = link.revisionId;
      final first = link.database.setCell(f.row.id, f.titleId, '응답을 잃은 입력');
      f.repository.failNext = true;
      await expectLater(
        f.controller.saveLinkedDatabase(link, first),
        throwsStateError,
      );
      await _externalBody(
        f,
        first.setCell(f.row.id, f.titleId, '그 뒤의 다른 작성자 입력'),
      );
      final before = await _revisionIds(f.repository);
      await expectLater(
        f.controller.saveLinkedDatabase(link, first),
        throwsStateError,
      );
      expect(await _revisionIds(f.repository), before);
      expect(link.revisionId, original);
      expect(link.database.toJson(), f.initial.toJson());
    });
  });
}

WorkspaceDatabase _database(Map<String, Uint8List> files) =>
    WorkspaceDatabase.fromJson(
      jsonObject(jsonDecode(utf8.decode(files['database.json']!))),
    );

Uint8List _encoded(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

Future<Set<String>> _revisionIds(NoteRepository repository) async =>
    (await repository.revisions()).map((record) => record.revisionId).toSet();

Future<void> _externalBody(
  _Fixture f,
  WorkspaceDatabase database, {
  Map<String, Uint8List> added = const {},
}) async {
  final head = (await f.inner.heads(f.source.inkEntityId)).single;
  await f.inner.commit(
    entityId: f.source.inkEntityId,
    kind: EntityKind.ink,
    ownerNoteId: f.source.id,
    files: {
      ...await f.inner.readFiles(head),
      ...added,
      'database.json': _encoded(database.toJson()),
    },
    parentRevisionIds: [head.revisionId],
  );
}

Future<void> _metadataRevision(
  _Fixture f, {
  String? title,
  bool deleted = false,
}) async {
  final head = (await f.inner.heads(f.source.id)).single;
  final files = await f.inner.readFiles(head);
  final metadata = jsonObject(jsonDecode(utf8.decode(files['note.json']!)));
  if (title != null) metadata['title'] = title;
  await f.inner.commit(
    entityId: f.source.id,
    kind: EntityKind.metadata,
    files: {...files, 'note.json': _encoded(metadata)},
    parentRevisionIds: [head.revisionId],
    deleted: deleted,
    baseRefs: {
      f.source.inkEntityId: (await f.inner.heads(f.source.inkEntityId))
          .map((r) => r.revisionId)
          .toList(),
      f.source.markdownEntityId: (await f.inner.heads(
        f.source.markdownEntityId,
      )).map((r) => r.revisionId).toList(),
    },
  );
}

class _Fixture {
  new(
    this.directory,
    this.inner,
    this.repository,
    this.controller,
    this.source,
    this.page,
    this.otherPage,
    this.owner,
    this.initial,
    this.row,
    this.otherRow,
  );
  final Directory directory;
  final NoteRepository inner;
  final _LinkedRepository repository;
  final WorkspaceController controller;
  final VaultNote source, page, otherPage;
  final NoteSession owner;
  final WorkspaceDatabase initial;
  final DatabaseRow row, otherRow;
  final extraRepositories = <NoteRepository>[];
  var controllerDisposed = false;
  String get titleId => initial.properties.single.id;
}

Future<void> _withFixture(Future<void> Function(_Fixture) action) async {
  final directory = await Directory.systemTemp.createTemp(
    'linked-database-session-',
  );
  final inner = await NoteRepository.open(
    Directory(p.join(directory.path, 'vault')),
    createFormatVersion: 2,
  );
  final controller = WorkspaceController(
    inner,
    directoryProvider: () async => Directory(p.join(directory.path, 'support')),
  );
  _Fixture? fixture;
  try {
    final source = await controller.createNote(
      '공유 자료 DB',
      documentKind: VaultDocumentKind.database,
    );
    final empty = await controller.loadDatabase(
      session: controller.activeSession!,
    );
    final row = DatabaseRow.create(
      values: {empty.properties.single.id: '원래 자료'},
    );
    final otherRow = DatabaseRow.create(
      values: {empty.properties.single.id: '다른 자료'},
    );
    final initial = WorkspaceDatabase.fromJson({
      ...empty.addRow(row).addRow(otherRow).toJson(),
      'futureDatabase': {'preserve': true},
    });
    await controller.activeSession!.saveInk({
      'database.json': _encoded(initial.toJson()),
      'future/original.bin': Uint8List.fromList([0, 255, 42]),
    });
    final page = await controller.createNote(
      '연구 페이지',
      documentKind: VaultDocumentKind.page,
    );
    final otherPage = await controller.createNote(
      '강의 페이지',
      documentKind: VaultDocumentKind.page,
    );
    await controller.openNote(page);
    final owner = controller.activeSession!;
    final repository = _LinkedRepository(inner, source.inkEntityId);
    controller.repository = repository;
    owner.repository = repository;
    fixture = _Fixture(
      directory,
      inner,
      repository,
      controller,
      source,
      page,
      otherPage,
      owner,
      initial,
      row,
      otherRow,
    );
    await action(fixture);
  } finally {
    if (fixture?.controllerDisposed != true) controller.dispose();
    for (final repository in fixture?.extraRepositories ?? <NoteRepository>[]) {
      await repository.close();
    }
    await inner.close();
    await directory.delete(recursive: true);
  }
}

class _LinkedRepository implements NoteRepository {
  new(this.inner, this.sourceEntityId);
  final NoteRepository inner;
  final String sourceEntityId;
  String? pauseEntity;
  final readEntered = Completer<void>(), releaseRead = Completer<void>();
  var failNext = false, failBefore = false;
  Future<void> Function()? beforeConditional;
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
  Future<RevisionRecord> commitPreparedIfHeads(
    PreparedCommit prepared, {
    required Map<String, List<String>> expectedHeads,
    List<String>? expectedRevisionIds,
    void Function()? beforePublish,
    bool allowHistoricalParents = false,
  }) async {
    if (prepared.record.entityId == sourceEntityId) {
      attemptedIds.add(prepared.record.revisionId);
      final callback = beforeConditional;
      beforeConditional = null;
      await callback?.call();
      if (failNext && failBefore) {
        failNext = false;
        throw StateError('Synthetic linked save failure before publication');
      }
    }
    final result = await inner.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      expectedRevisionIds: expectedRevisionIds,
      beforePublish: beforePublish,
      allowHistoricalParents: allowHistoricalParents,
    );
    if (prepared.record.entityId == sourceEntityId && failNext) {
      failNext = false;
      throw StateError('Synthetic linked save lost publication response');
    }
    return result;
  }

  @override
  Future<void> close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
