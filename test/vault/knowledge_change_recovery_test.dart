import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/knowledge_rename.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory temp;
  late NoteRepository repository;
  late WorkspaceStore store;
  late LibraryStore library;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('knowledge-recovery-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    store = WorkspaceStore(repository);
    library = LibraryStore(repository);
  });
  tearDown(() async {
    await repository.close();
    final actual = await temp.resolveSymbolicLinks();
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    expect(
      actual,
      startsWith('$parent${Platform.pathSeparator}knowledge-recovery-'),
    );
    await Directory(actual).delete(recursive: true);
  });

  Future<(VaultNote, PreparedKnowledgeChange)> completed() async {
    final destination = await library.createFolder('Other');
    final note = await store.create('A');
    late PreparedKnowledgeChange plan;
    await store.moveNote(
      note,
      destination.id,
      onPrepared: (value) async {
        plan = value;
      },
    );
    return (note, plan);
  }

  Map<String, dynamic> descriptor(PreparedKnowledgeChange plan) =>
      jsonObject(jsonDecode(jsonEncode(plan.toRecoveryDescriptor())));

  File manifest(String id) => File(p.join(temp.path, 'revisions', '$id.json'));

  Future<(VaultNote, PreparedKnowledgeChange)> pendingDeletion() async {
    final note = await store.createWithSource(
      'A',
      fileName: 'original.pdf',
      bytes: Uint8List.fromList([37, 80, 68, 70, 0, 255]),
      documentKind: VaultDocumentKind.pdf,
    );
    await repository.commit(
      entityId: note.markdownEntityId,
      kind: EntityKind.markdown,
      ownerNoteId: note.id,
      files: {'summary.md': Uint8List.fromList(utf8.encode('Second branch'))},
      parentRevisionIds: [],
    );
    late PreparedKnowledgeChange plan;
    await expectLater(
      store.setDeleted(
        note,
        true,
        onPrepared: (value) async {
          plan = value;
          throw StateError('Stop before deletion publication');
        },
      ),
      throwsStateError,
    );
    expect(plan.record.baseRefs.keys, hasLength(2));
    expect(plan.record.baseRefs[note.markdownEntityId], hasLength(2));
    return (note, plan);
  }

  test(
    'recovers both versions of a rename with YAML-only references',
    () async {
      final native = InkVaultNative.open(libraryPath: _nativePath);
      final writer = WorkspaceStore(repository, native: native);
      final target = await writer.createMarkdown('Old', Uint8List(0));
      const original = '---\nref: "[[Old]]"\n---\n';
      final source = await writer.createMarkdown(
        'Source',
        Uint8List.fromList(utf8.encode(original)),
      );
      late PreparedKnowledgeChange pending;
      await expectLater(
        writer.rename(
          target,
          'New',
          onPrepared: (plan) async {
            pending = plan;
            throw StateError('Stop before publishing');
          },
        ),
        throwsStateError,
      );
      final json = descriptor(pending);
      final files = pending.copyRecoveryFiles();
      expect(json['version'], 2);
      expect(files, hasLength(2));
      await repository.close();
      repository = await NoteRepository.open(temp);

      final legacy = await resumePreparedKnowledgeChange(
        repository,
        descriptor: {
          ...json,
          'version': 1,
          'steps': [(json['steps'] as List).last],
        },
        files: [files.last],
        invoke: native.invoke,
      );
      expect(legacy.toRecoveryDescriptor()['version'], 1);
      final current = await resumePreparedKnowledgeChange(
        repository,
        descriptor: json,
        files: files,
        invoke: native.invoke,
      );
      await current.publish(repository);
      final head = (await repository.heads(source.markdownEntityId)).single;
      final updated = (await repository.readFiles(head))['summary.md']!;
      expect(
        utf8.decode(updated),
        original.replaceFirst('[[Old]]', '[[${target.id}|Old]]'),
      );
    },
    skip: File(_nativePath).existsSync()
        ? false
        : 'Set INK_VAULT_NATIVE_LIBRARY to the installed common-engine library.',
  );

  test('deletion recovery ignores base reference map insertion order after restart', () async {
    final (note, plan) = await pendingDeletion();
    final json = descriptor(plan);
    final files = plan.copyRecoveryFiles();
    final steps = json['steps'] as List;
    final lastStep = jsonObject(steps.last);
    final record = jsonObject(lastStep['record']);
    final originalKeys = plan.record.baseRefs.keys.toList();
    record['baseRefs'] = {
      for (final key in originalKeys.reversed)
        key: List.of(plan.record.baseRefs[key]!),
    };
    lastStep['record'] = record;
    steps[steps.length - 1] = lastStep;
    final reordered = repository.resumePreparedCommit(
      descriptor: lastStep,
      files: files.last,
    );
    expect(reordered.record.toJson(), plan.record.toJson());
    expect(
      reordered.record.baseRefs.keys,
      orderedEquals(originalKeys.reversed),
    );
    expect(
      jsonEncode(reordered.record.baseRefs),
      isNot(jsonEncode(plan.record.baseRefs)),
    );
    final originalIds = (await repository.revisions())
        .map((record) => record.revisionId)
        .toSet();
    final root = repository.root;
    await repository.close();
    repository = await NoteRepository.open(root);
    store = WorkspaceStore(repository);
    library = LibraryStore(repository);
    expect(
      (await repository.revisions()).map((record) => record.revisionId).toSet(),
      originalIds,
    );

    final recovered = await resumePreparedKnowledgeChange(
      repository,
      descriptor: json,
      files: files,
    );
    expect(recovered.record.toJson(), plan.record.toJson());
    await recovered.publish(repository);
    final tombstone = (await repository.heads(note.id)).single;
    expect(tombstone.toJson(), plan.record.toJson());
    expect(tombstone.deleted, isTrue);
    expect(
      await repository.readFiles(tombstone),
      await repository.readFiles(note.revision),
    );
    for (final entry in plan.record.baseRefs.entries) {
      expect(
        (await repository.heads(entry.key)).map((head) => head.revisionId),
        unorderedEquals(entry.value),
      );
    }
  });

  for (final mutation in [
    'child identity',
    'head identity',
    'child bundle',
    'head order',
  ]) {
    test('deletion recovery still rejects changed $mutation', () async {
      final (note, plan) = await pendingDeletion();
      final json = descriptor(plan);
      final steps = json['steps'] as List;
      final lastStep = jsonObject(steps.last);
      final record = jsonObject(lastStep['record']);
      final bases = {
        for (final entry in plan.record.baseRefs.entries)
          entry.key: List.of(entry.value),
      };
      if (mutation == 'child identity') {
        final previous = bases.remove(note.sourceEntityId!)!;
        bases[newId()] = previous;
      } else if (mutation == 'head identity') {
        bases[note.sourceEntityId!] = [bases[note.markdownEntityId]!.first];
      } else if (mutation == 'child bundle') {
        bases.remove(note.sourceEntityId!);
      } else {
        bases[note.markdownEntityId] = bases[note.markdownEntityId]!.reversed
            .toList();
      }
      record['baseRefs'] = bases;
      lastStep['record'] = record;
      steps[steps.length - 1] = lastStep;
      final originalIds = (await repository.revisions())
          .map((record) => record.revisionId)
          .toSet();

      await expectLater(
        resumePreparedKnowledgeChange(
          repository,
          descriptor: json,
          files: plan.copyRecoveryFiles(),
        ),
        throwsFormatException,
      );
      expect(
        (await repository.revisions())
            .map((record) => record.revisionId)
            .toSet(),
        originalIds,
      );
      expect((await repository.heads(note.id)).single.deleted, isFalse);
    });
  }

  test('a completed recovered plan rechecks a subsequently missing final manifest before acknowledgement', () async {
    final (_, original) = await completed();
    final recovered = await resumePreparedKnowledgeChange(
      repository,
      descriptor: descriptor(original),
      files: original.copyRecoveryFiles(),
    );
    await manifest(original.record.revisionId).delete();

    await expectLater(
      recovered.publish(repository),
      throwsA(anyOf(isA<FormatException>(), isA<FileSystemException>())),
    );
  });

  test(
    'publishing an already completed plan rechecks its exact manifest fields',
    () async {
      final (_, plan) = await completed();
      final file = manifest(plan.record.revisionId);
      final json = jsonObject(jsonDecode(await file.readAsString()));
      await file.writeAsString(
        jsonEncode({...json, 'future': 'not part of the prepared record'}),
      );

      await expectLater(plan.publish(repository), throwsFormatException);
    },
  );

  test(
    'recovery rejects unknown fields added to an original source manifest',
    () async {
      final (note, plan) = await completed();
      final file = manifest(note.revision.revisionId);
      final json = jsonObject(jsonDecode(await file.readAsString()));
      await file.writeAsString(
        jsonEncode({...json, 'future': 'changed original envelope'}),
      );

      await expectLater(
        resumePreparedKnowledgeChange(
          repository,
          descriptor: descriptor(plan),
          files: plan.copyRecoveryFiles(),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'a floating point recovery version cannot claim the integer schema',
    () async {
      final (_, plan) = await completed();
      final json = descriptor(plan)..['version'] = 1.0;

      await expectLater(
        resumePreparedKnowledgeChange(
          repository,
          descriptor: json,
          files: plan.copyRecoveryFiles(),
        ),
        throwsFormatException,
      );
    },
  );

  test('recovery refuses an oversized source manifest before accepting normalized known fields', () async {
    final (note, plan) = await completed();
    final file = manifest(note.revision.revisionId);
    final json = jsonObject(jsonDecode(await file.readAsString()));
    await file.writeAsString(
      jsonEncode({...json, 'future': 'x' * (1024 * 1024 + 1)}),
    );

    await expectLater(
      resumePreparedKnowledgeChange(
        repository,
        descriptor: descriptor(plan),
        files: plan.copyRecoveryFiles(),
      ),
      throwsFormatException,
    );
  });

  test('completed recovery acknowledges the original record while preserving a later valid descendant', () async {
    final (note, plan) = await completed();
    final current = (await store.list()).singleWhere((n) => n.id == note.id);
    await store.rename(current, 'Later');
    final head = (await repository.heads(note.id)).single;
    final before = (await repository.revisions())
        .map((r) => r.revisionId)
        .toSet();

    final recovered = await resumePreparedKnowledgeChange(
      repository,
      descriptor: descriptor(plan),
      files: plan.copyRecoveryFiles(),
    );
    await recovered.publish(repository);

    expect(recovered.record.revisionId, plan.record.revisionId);
    expect(
      (await repository.heads(note.id)).single.revisionId,
      head.revisionId,
    );
    expect(
      (await repository.revisions()).map((r) => r.revisionId).toSet(),
      before,
    );
  });

  test('a stale rejected recovery releases the in-memory plan for a different fresh action', () async {
    final destination = await library.createFolder('Other');
    final original = await store.create('A');
    late PreparedKnowledgeChange pending;
    await expectLater(
      store.moveNote(
        original,
        destination.id,
        onPrepared: (plan) async {
          pending = plan;
          throw StateError('Receipt failed before publication');
        },
      ),
      throwsStateError,
    );
    final remote = await store.create('Remote arrival');
    await expectLater(
      resumePreparedKnowledgeChange(
        repository,
        descriptor: descriptor(pending),
        files: pending.copyRecoveryFiles(),
      ),
      throwsStateError,
    );

    await expectLater(store.rename(remote, 'Fresh action'), completes);

    expect(
      (await store.list()).singleWhere((n) => n.id == original.id).folderId,
      isNull,
    );
    expect(
      (await store.list()).singleWhere((n) => n.id == remote.id).title,
      'Fresh action',
    );
    expect(
      (await repository.revisions()).map((r) => r.revisionId),
      isNot(contains(pending.record.revisionId)),
    );
  });

  test(
    'recovery refuses a published metadata step after a missing body step',
    () async {
      final native = InkVaultNative.open(libraryPath: _nativePath);
      store = WorkspaceStore(repository, native: native);
      final destination = await library.createFolder('Other');
      final target = await store.create('A');
      final source = await store.create('Reader');
      await (await store.open(source)).saveMarkdown('[A](A.md)');
      late PreparedKnowledgeChange plan;
      await expectLater(
        store.moveNote(
          target,
          destination.id,
          onPrepared: (value) async {
            plan = value;
            throw StateError('Stop before the first publication');
          },
        ),
        throwsStateError,
      );
      final json = descriptor(plan);
      final steps = json['steps'] as List;
      expect(steps, hasLength(2));
      final files = plan.copyRecoveryFiles();
      await repository.commitPrepared(
        repository.resumePreparedCommit(
          descriptor: jsonObject(steps.last),
          files: files.last,
        ),
      );

      await expectLater(
        resumePreparedKnowledgeChange(
          repository,
          descriptor: json,
          files: files,
          invoke: native.invoke,
        ),
        throwsFormatException,
      );
    },
    skip: File(_nativePath).existsSync() ? false : 'Set INK_VAULT_NATIVE_LIBRARY to the installed common-engine library.',
  );
}

final _nativePath =
    Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
    p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');
