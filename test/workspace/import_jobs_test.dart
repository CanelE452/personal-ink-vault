import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/import_jobs.dart';

/// The list of imports behind the library's import cards (설계 4절): reading
/// fills the bar to 85 %, storing holds it there, and a finished import leaves
/// the list.
void main() {
  final bytes = Uint8List.fromList([1, 2, 3, 4]);

  VaultNote note(String title) {
    final id = newId();
    return VaultNote(
      id,
      title,
      newId(),
      newId(),
      RevisionRecord(
        vaultId: newId(),
        entityId: id,
        kind: EntityKind.metadata,
        revisionId: newId(),
        parentRevisionIds: const [],
        deviceId: newId(),
        blobs: const {},
      ),
    );
  }

  test(
    'progress goes from reading to writing and the job disappears when done',
    () async {
      // The job catches what trash throws, so trashing is recorded and checked instead.
      final trashed = <VaultNote>[];
      final jobs = ImportJobs(trash: (value) async => trashed.add(value));
      var notified = 0;
      jobs.addListener(() => notified++);
      final reading = Completer<void>();
      final storing = Completer<VaultNote>();
      late void Function(double) report;
      Uint8List? stored;
      VaultNote? finished;
      final id = jobs.start(
        title: '강의 자료',
        folderId: 'folder',
        read: (progress, cancelled) async {
          report = progress;
          await reading.future;
          return bytes;
        },
        write: (value) {
          stored = value;
          return storing.future;
        },
        done: (value) => finished = value,
      );
      // Until the file tells its size, the bar does not know how far it is.
      final started = jobs.jobs.single;
      expect(
        (started.id, started.title, started.folderId, started.progress),
        (id, '강의 자료', 'folder', null),
      );
      expect(started.writing, isFalse);
      expect(started.error, isNull);

      // Reading fills the bar up to 85 %.
      report(0.5);
      expect(jobs.jobs.single.progress, closeTo(0.425, 1e-9));
      report(1);
      expect(jobs.jobs.single.progress, closeTo(0.85, 1e-9));
      expect(jobs.jobs.single.writing, isFalse);
      expect(stored, isNull);

      // Storing holds it at 85 %.
      reading.complete();
      await pumpEventQueue();
      expect(stored, same(bytes));
      expect(jobs.jobs.single.writing, isTrue);
      expect(jobs.jobs.single.progress, closeTo(0.85, 1e-9));
      expect(finished, isNull);

      // Once stored, the import leaves the list and says which document it made.
      final created = note('강의 자료');
      storing.complete(created);
      await pumpEventQueue();
      expect(jobs.jobs, isEmpty);
      expect(finished, same(created));
      expect(notified, greaterThanOrEqualTo(5));
      expect(trashed, isEmpty);
    },
  );

  test('cancel before writing never calls write', () async {
    final trashed = <VaultNote>[];
    final jobs = ImportJobs(trash: (value) async => trashed.add(value));
    var writes = 0;
    final reading = Completer<void>();
    late bool Function() stopReading;
    final id = jobs.start(
      title: '읽는 중',
      folderId: null,
      read: (progress, cancelled) async {
        stopReading = cancelled;
        await reading.future;
        return bytes;
      },
      write: (_) async {
        writes++;
        return note('읽는 중');
      },
      done: (_) => fail('A cancelled import is not done.'),
    );
    expect(stopReading(), isFalse);
    jobs.cancel(id);
    // The card goes at once, and the read is told to stop.
    expect(jobs.jobs, isEmpty);
    expect(stopReading(), isTrue);
    reading.complete();
    await pumpEventQueue();
    expect(writes, 0);

    // Imports are stored one at a time; one cancelled while it waits for its
    // turn is not stored either.
    final storing = Completer<VaultNote>();
    jobs.start(
      title: '먼저',
      folderId: null,
      read: (_, _) async => bytes,
      write: (_) {
        writes++;
        return storing.future;
      },
    );
    final waiting = jobs.start(
      title: '다음',
      folderId: null,
      read: (_, _) async => bytes,
      write: (_) async {
        writes++;
        return note('다음');
      },
      done: (_) => fail('A cancelled import is not done.'),
    );
    await pumpEventQueue();
    expect(writes, 1);
    expect(
      [for (final job in jobs.jobs) (job.title, job.writing)],
      [('먼저', true), ('다음', false)],
    );
    jobs.cancel(waiting);
    storing.complete(note('먼저'));
    await pumpEventQueue();
    expect(writes, 1);
    expect(jobs.jobs, isEmpty);
    expect(trashed, isEmpty);
  });

  test('cancel while writing trashes the note afterwards', () async {
    final trashed = <VaultNote>[];
    final jobs = ImportJobs(trash: (value) async => trashed.add(value));
    final storing = Completer<VaultNote>();
    final id = jobs.start(
      title: '저장 중',
      folderId: null,
      read: (_, _) async => bytes,
      write: (_) => storing.future,
      done: (_) => fail('A cancelled import is not done.'),
    );
    await pumpEventQueue();
    expect(jobs.jobs.single.writing, isTrue);
    jobs.cancel(id);
    expect(jobs.jobs, isEmpty);
    // What is being stored cannot be taken back half way: it goes to the
    // trash once it is stored.
    expect(trashed, isEmpty);
    final created = note('저장 중');
    storing.complete(created);
    await pumpEventQueue();
    expect(trashed, hasLength(1));
    expect(trashed.single, same(created));
  });

  test('a failing read leaves a dismissable error card', () async {
    final trashed = <VaultNote>[];
    final jobs = ImportJobs(trash: (value) async => trashed.add(value));
    var writes = 0;
    final id = jobs.start(
      title: '깨진 파일',
      folderId: 'folder',
      read: (_, _) async =>
          throw const FormatException('선택한 문서의 파일 크기를 확인하지 못했습니다.'),
      write: (_) async {
        writes++;
        return note('깨진 파일');
      },
      done: (_) => fail('A failed import is not done.'),
    );
    await pumpEventQueue();
    final failed = jobs.jobs.single;
    expect(failed.id, id);
    expect(failed.error, '선택한 문서의 파일 크기를 확인하지 못했습니다.');
    expect(failed.writing, isFalse);
    expect(writes, 0);

    // Closing a card is for failed imports; one still running stays.
    final running = Completer<void>();
    final other = jobs.start(
      title: '읽는 중',
      folderId: null,
      read: (_, _) async {
        await running.future;
        return bytes;
      },
      write: (_) async => note('읽는 중'),
    );
    jobs.dismiss(other);
    expect([for (final job in jobs.jobs) job.id], [id, other]);
    jobs.dismiss(id);
    expect([for (final job in jobs.jobs) job.id], [other]);
    // Another vault or a closed screen leaves nothing behind.
    jobs.cancelAll();
    expect(jobs.jobs, isEmpty);
    running.complete();
    await pumpEventQueue();
    expect(jobs.jobs, isEmpty);
    expect(trashed, isEmpty);
  });

  test('closing the screen while an import is stored keeps the document; one '
      'still reading is cancelled', () async {
    final trashed = <VaultNote>[];
    final jobs = ImportJobs(trash: (value) async => trashed.add(value));
    final storing = Completer<VaultNote>();
    var stored = false;
    jobs.start(
      title: '저장 중',
      folderId: null,
      read: (_, _) async => bytes,
      write: (_) => storing.future.whenComplete(() => stored = true),
      done: (_) => fail('A closed screen is not told.'),
    );
    final reading = Completer<void>();
    var writes = 0;
    jobs.start(
      title: '읽는 중',
      folderId: null,
      read: (_, _) async {
        await reading.future;
        return bytes;
      },
      write: (_) async {
        writes++;
        return note('읽는 중');
      },
      done: (_) => fail('A cancelled import is not done.'),
    );
    await pumpEventQueue();
    expect(
      [for (final job in jobs.jobs) (job.title, job.writing)],
      [('저장 중', true), ('읽는 중', false)],
    );

    // The screen closes, as the workspace's dispose does it.
    jobs
      ..cancelAll()
      ..dispose();
    storing.complete(note('저장 중'));
    reading.complete();
    await pumpEventQueue();
    // As with a vault switch, what was being stored stays in the vault.
    expect(stored, isTrue);
    expect(trashed, isEmpty);
    expect(writes, 0);
  });

  test('the finished message takes the particle the title ends with', () {
    // A final consonant takes 을, none takes 를.
    expect(importDoneMessage('칠판'), '‘칠판’을 가져왔습니다');
    expect(importDoneMessage('느린 자료'), '‘느린 자료’를 가져왔습니다');
    // A title that does not end in a Hangul syllable gets a sentence without one.
    expect(importDoneMessage('Lecture'), '‘Lecture’ 가져오기를 마쳤습니다');
    expect(importDoneMessage('자료 (2)'), '‘자료 (2)’ 가져오기를 마쳤습니다');
  });
}
