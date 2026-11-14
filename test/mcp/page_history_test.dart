import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));
Matcher _error(String code) =>
    isA<VaultMcpException>().having((e) => e.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late NoteRepository repo;
  late WorkspaceController controller;
  late VaultMcpService service;
  late VaultFolder ancestor;
  late VaultNote note;
  late RevisionRecord before, after;
  late Map<String, Uint8List> original;
  late String block;
  var preparations = 0;
  var writable = true;
  final readOnly = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => false,
  );
  late VaultMcpCallContext context;

  Map<String, Object?> body(String text) => {
    'version': 1,
    'futurePage': [1, 2],
    'blocks': [
      {
        'id': block,
        'type': 'paragraph',
        'text': text,
        'future': {'keep': true},
      },
    ],
  };
  Future<Map<String, dynamic>> call(
    String op,
    Map<String, dynamic> args, {
    VaultMcpCallContext? access,
  }) async =>
      jsonObject(await service.call(op, args, context: access ?? context));
  Future<Map<String, dynamic>> compare([
    Map<String, dynamic> extra = const {},
  ]) => call('compare_page_revision', {
    'noteId': note.id,
    'revisionId': before.revisionId,
    'expectedRevisionId': after.revisionId,
    ...extra,
  }, access: readOnly);
  Map<String, dynamic> restoreArgs(Map<String, dynamic> comparison) => {
    'noteId': note.id,
    'revisionId': before.revisionId,
    'expectedRevisionId': after.revisionId,
    'expectedHeads': comparison['expectedHeads'],
    'requestId': newId(),
  };
  File receipt(Map<String, dynamic> args) => File(
    '${repo.root.path}/.workspace/mcp/requests/${args['requestId']}.json',
  );
  Future<void> reopen() async {
    controller.dispose();
    await repo.close();
    repo = await NoteRepository.open(Directory('${temp.path}/vault'));
    controller = WorkspaceController(repo, directoryProvider: () async => temp);
    service = VaultMcpService(controller);
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-page-history-');
    repo = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    controller = WorkspaceController(repo, directoryProvider: () async => temp);
    preparations = 0;
    writable = true;
    context = VaultMcpCallContext(
      isActive: () => true,
      canWrite: () => writable,
    );
    service = VaultMcpService(
      controller,
      prepareMutation: () async {
        preparations++;
      },
    );
    ancestor = await LibraryStore(repo).createFolder('Research');
    note = await controller.store.create(
      'Page',
      documentKind: VaultDocumentKind.page,
      folderId: ancestor.id,
    );
    block = newId();
    original = {
      'page.json': _bytes(jsonEncode(body('Before'))),
      'assets/source.bin': Uint8List.fromList([1, 0, 255]),
    };
    before = await repo.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: original,
      parentRevisionIds: [],
      baseRefs: {
        newId(): [newId()],
      },
    );
    final session = await controller.store.open(note);
    await session.saveInk({'page.json': _bytes(jsonEncode(body('After')))});
    after = (await repo.heads(note.inkEntityId)).single;
    await session.saveMarkdown('Independent summary');
  });
  tearDown(() async {
    controller.dispose();
    await repo.close();
    await temp.delete(recursive: true);
  });

  test('saved-only comparison returns exact body metadata and ancestor guards without flushing UI', () async {
    controller.inkDirty = true;
    final count = (await repo.revisions()).length;
    final diff = await compare();
    expect(diff['beforeRevisionId'], before.revisionId);
    expect(diff['afterRevisionId'], after.revisionId);
    expect(diff['expectedHeads'], {
      note.inkEntityId: [after.revisionId],
      note.id: [note.revision.revisionId],
      ancestor.id: [ancestor.revision.revisionId],
    });
    expect(diff['totalChanges'], 1);
    final change = jsonObject((diff['changes'] as List).single);
    expect(change['blockId'], block);
    expect(change['kinds'], ['content']);
    expect(change['before']['text'], 'Before');
    expect(change['after']['text'], 'After');
    expect(change['before'], isNot(contains('children')));
    expect(diff['pageMetadataChanged'], false);
    expect(diff['nextOffset'], isNull);
    expect(preparations, 0);
    expect(controller.inkDirty, true);
    expect((await repo.revisions()).length, count);
    controller.inkDirty = false;
  });

  test(
    'body history pagination preserves the legacy omitted-argument response',
    () async {
      final legacy = await call('list_revisions', {'noteId': note.id});
      expect(
        legacy.keys,
        unorderedEquals(['noteId', 'revisions', 'total', 'truncated']),
      );
      expect(
        (legacy['revisions'] as List).map((r) => r['kind']),
        containsAll(['metadata', 'ink', 'markdown']),
      );
      final all = await call('list_revisions', {
        'noteId': note.id,
        'target': 'body',
        'limit': 100,
      });
      final first = await call('list_revisions', {
        'noteId': note.id,
        'target': 'body',
        'limit': 1,
      });
      final second = await call('list_revisions', {
        'noteId': note.id,
        'target': 'body',
        'offset': 1,
        'limit': 1,
      });
      expect(all['total'], 2);
      expect(first['revisions'], [(all['revisions'] as List).first]);
      expect(second['revisions'], [(all['revisions'] as List).last]);
      expect(first['nextOffset'], 1);
      expect(second['nextOffset'], isNull);
      for (final invalid in [
        {'limit': null},
        {'limit': 0},
        {'limit': 101},
        {'offset': -1},
        {'target': 'metadata'},
      ]) {
        await expectLater(
          call('list_revisions', {'noteId': note.id, ...invalid}),
          throwsA(_error('invalid_arguments')),
        );
      }
    },
  );

  test('restore copies complete selected files and baseRefs once, keeps summary and retries after reopen', () async {
    final args = restoreArgs(await compare());
    final count = (await repo.revisions()).length;
    final result = await call('restore_page_revision', args);
    final head = (await repo.heads(note.inkEntityId)).single;
    expect(result['revisionId'], head.revisionId);
    expect(result['restoredFromRevisionId'], before.revisionId);
    expect(head.parentRevisionIds, [after.revisionId]);
    expect(head.baseRefs, before.baseRefs);
    expect(await repo.readFiles(head), original);
    expect(await repo.readFiles(before), original);
    expect(
      await (await controller.store.open(note)).readMarkdown(),
      'Independent summary',
    );
    expect((await repo.revisions()).length, count + 1);
    expect(preparations, 1);
    await reopen();
    expect(await call('restore_page_revision', args), result);
    expect((await repo.revisions()).length, count + 1);
    await expectLater(
      call('restore_page_revision', {...args, 'revisionId': after.revisionId}),
      throwsA(_error('request_id_reused')),
    );
    await expectLater(
      call('document_action', {
        'noteId': note.id,
        'action': 'restore',
        'expectedRevisionId': note.revision.revisionId,
        'requestId': args['requestId'],
      }),
      throwsA(_error('request_id_reused')),
    );
  });

  for (final race in ['body', 'metadata', 'ancestor', 'dirtySave']) {
    test('restore rejects $race changes since comparison', () async {
      final args = restoreArgs(await compare());
      Future<void> change() async {
        if (race == 'body' || race == 'dirtySave') {
          final session = await controller.store.open(note);
          await session.saveInk({
            'page.json': _bytes(jsonEncode(body('Newer'))),
          });
        } else if (race == 'metadata') {
          await controller.store.rename(note, 'Renamed');
        } else {
          await LibraryStore(repo).renameFolder(ancestor, 'Renamed');
        }
      }

      if (race == 'dirtySave') {
        service = VaultMcpService(controller, prepareMutation: change);
      } else {
        await change();
      }
      final count = (await repo.revisions()).length;
      await expectLater(
        call('restore_page_revision', args),
        throwsA(_error('revision_conflict')),
      );
      expect(
        (await repo.heads(note.inkEntityId)).single.revisionId,
        isNot(before.revisionId),
      );
      expect(
        (await repo.revisions()).length,
        count + (race == 'dirtySave' ? 1 : 0),
      );
    });
  }

  test('read-only, foreign revision, missing guard and oversized page requests do not publish', () async {
    final args = restoreArgs(await compare());
    await expectLater(
      call('restore_page_revision', args, access: readOnly),
      throwsA(_error('read_only')),
    );
    await expectLater(
      compare({'revisionId': note.revision.revisionId}),
      throwsA(_error('revision_not_owned')),
    );
    final guards = jsonObject(jsonDecode(jsonEncode(args['expectedHeads'])))
      ..remove(ancestor.id);
    await expectLater(
      call('restore_page_revision', {...args, 'expectedHeads': guards}),
      throwsA(_error('invalid_arguments')),
    );
    await expectLater(
      compare({'extra': true}),
      throwsA(_error('invalid_arguments')),
    );
    final session = await controller.store.open(note);
    await session.saveInk({
      'page.json': _bytes(jsonEncode(body('x' * (1024 * 1024)))),
    });
    after = (await repo.heads(note.inkEntityId)).single;
    await expectLater(compare(), throwsA(_error('content_too_large')));
  });

  test('diff pagination computes all changes and explicitly omits large per-block payloads', () async {
    final session = await controller.store.open(note);
    final ids = [for (var i = 0; i < 104; i++) newId()];
    final data = {
      'version': 1,
      'blocks': [
        for (var i = 0; i < ids.length; i++)
          {
            'id': ids[i],
            'type': 'paragraph',
            'text': i == 0 ? 'x' * 300000 : 'item $i',
          },
      ],
    };
    await session.saveInk({'page.json': _bytes(jsonEncode(data))});
    after = (await repo.heads(note.inkEntityId)).single;
    final first = await compare({'limit': 2});
    expect(first['totalChanges'], 105);
    expect((first['changes'] as List).length, 2);
    expect(first['nextOffset'], 2);
    expect((first['changes'] as List).first['payloadOmitted'], true);
    expect(utf8.encode(jsonEncode(first)).length, lessThan(300000));
    final last = await compare({'offset': 104, 'limit': 2});
    expect((last['changes'] as List).length, 1);
    expect(last['nextOffset'], isNull);
    expect(last['totalChanges'], first['totalChanges']);
  });

  test(
    'final rename permission revocation leaves a resumable exact plan',
    () async {
      final args = restoreArgs(await compare());
      var revokedAtRename = false;
      final guarded = VaultMcpCallContext(
        isActive: () => true,
        canWrite: () {
          final pending = Directory('${repo.root.path}/revisions')
              .listSync()
              .any((f) => f.path.endsWith('.tmp'));
          if (pending) {
            revokedAtRename = true;
            return false;
          }
          return writable;
        },
      );
      await expectLater(
        call('restore_page_revision', args, access: guarded),
        throwsA(_error('read_only')),
      );
      expect(revokedAtRename, true);
      final saved = jsonObject(jsonDecode(await receipt(args).readAsString()));
      expect(saved['version'], 2);
      expect(saved['state'], 'prepared');
      final id = saved['plan']['prepared']['record']['revisionId'];
      expect(
        (await repo.heads(note.inkEntityId)).single.revisionId,
        after.revisionId,
      );
      await reopen();
      expect((await call('restore_page_revision', args))['revisionId'], id);
    },
  );

  for (final failure in ['publicationResponse', 'completedReceipt']) {
    test(
      '$failure loss after publication resumes same revision after later descendants',
      () async {
        final args = restoreArgs(await compare());
        var failed = false;
        final faults = _JournalIo(
          (path, contents) =>
              !failed &&
              (failure == 'publicationResponse'
                  ? path.contains('/revisions/') && path.endsWith('.tmp')
                  : path.endsWith('.pending') &&
                        contents?['state'] == 'completed'),
          afterRename: failure == 'publicationResponse',
          onFailure: () => failed = true,
        );
        await IOOverrides.runWithIOOverrides(() async {
          await expectLater(
            call('restore_page_revision', args),
            throwsA(isA<VaultMcpException>()),
          );
        }, faults);
        expect(failed, true);
        final saved = jsonObject(
          jsonDecode(await receipt(args).readAsString()),
        );
        expect(saved['state'], 'prepared');
        final planned = saved['plan']['prepared']['record']['revisionId'];
        await reopen();
        expect((await repo.heads(note.inkEntityId)).single.revisionId, planned);
        final session = await controller.store.open(
          (await controller.store.list()).single,
        );
        await session.saveInk({
          'page.json': _bytes(jsonEncode(body('Later descendant'))),
        });
        final descendant = session.inkParents.single;
        await LibraryStore(repo).renameFolder(ancestor, 'Later folder');
        final count = (await repo.revisions()).length;
        final result = await call('restore_page_revision', args);
        expect(result['revisionId'], planned);
        expect(
          (await repo.heads(note.inkEntityId)).single.revisionId,
          descendant,
        );
        expect((await repo.revisions()).length, count);
        expect(await call('restore_page_revision', args), result);
      },
    );
  }

  test('a started restore receipt has no published plan and can resume after restart', () async {
    final args = restoreArgs(await compare());
    service = VaultMcpService(
      controller,
      prepareMutation: () async =>
          throw StateError('Interrupted before planning'),
    );
    await expectLater(
      call('restore_page_revision', args),
      throwsA(_error('revision_conflict')),
    );
    final saved = jsonObject(jsonDecode(await receipt(args).readAsString()));
    expect(saved['state'], 'started');
    expect(saved.containsKey('plan'), false);
    expect(
      (await repo.heads(note.inkEntityId)).single.revisionId,
      after.revisionId,
    );
    await reopen();
    final result = await call('restore_page_revision', args);
    expect(
      (await repo.heads(note.inkEntityId)).single.revisionId,
      result['revisionId'],
    );
  });

  for (final damage in ['missing', 'malformed', 'different']) {
    test(
      'completed MCP acknowledgement verifies the actual $damage manifest',
      () async {
        final args = restoreArgs(await compare());
        final result = await call('restore_page_revision', args);
        final manifest = File(
          '${repo.root.path}/revisions/${result['revisionId']}.json',
        );
        if (damage == 'missing') {
          await manifest.delete();
        } else if (damage == 'malformed') {
          await manifest.writeAsString('{');
        } else {
          final changed = jsonObject(jsonDecode(await manifest.readAsString()))
            ..['deviceId'] = newId();
          await manifest.writeAsString(jsonEncode(changed));
        }
        final damaged = manifest.existsSync()
            ? await manifest.readAsBytes()
            : null;
        await expectLater(
          call('restore_page_revision', args),
          throwsA(isA<VaultMcpException>()),
        );
        expect(
          manifest.existsSync() ? await manifest.readAsBytes() : null,
          damaged,
        );
      },
    );
  }
}

final class _JournalIo extends IOOverrides {
  new(this.shouldFail, {required this.afterRename, required this.onFailure});
  final bool Function(String, Map<String, dynamic>?) shouldFail;
  final bool afterRename;
  final void Function() onFailure;
  @override
  File createFile(String path) => _JournalFile(super.createFile(path), this);
}

class _JournalFile implements File {
  new(this.inner, this.faults);
  final File inner;
  final _JournalIo faults;
  @override
  String get path => inner.path;
  @override
  Uri get uri => inner.uri;
  @override
  File get absolute => inner.absolute;
  @override
  Directory get parent => inner.parent;
  @override
  bool existsSync() => inner.existsSync();
  @override
  Future<bool> exists() async => inner.existsSync();
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      inner.create(recursive: recursive, exclusive: exclusive);
  @override
  Future<int> length() => inner.length();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      inner.readAsString(encoding: encoding);
  @override
  Future<Uint8List> readAsBytes() => inner.readAsBytes();
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => inner.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => inner.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  Future<File> rename(String newPath) async {
    Map<String, dynamic>? contents;
    if (path.endsWith('.pending'))
      contents = jsonObject(jsonDecode(await inner.readAsString()));
    final fail = faults.shouldFail(path.replaceAll('\\', '/'), contents);
    if (fail && !faults.afterRename) {
      faults.onFailure();
      throw FileSystemException('Injected receipt rename failure', path);
    }
    final result = await inner.rename(newPath);
    if (fail) {
      faults.onFailure();
      throw FileSystemException('Injected published response loss', path);
    }
    return result;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      inner.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
