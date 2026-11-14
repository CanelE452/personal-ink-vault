import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  late Directory directory;
  late NoteRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('revision-file-');
    repository = await NoteRepository.open(directory, createFormatVersion: 2);
  });

  tearDown(() async {
    await repository.close();
    final path = await directory.resolveSymbolicLinks();
    expect(
      path,
      startsWith(
        '${await Directory.systemTemp.resolveSymbolicLinks()}${Platform.pathSeparator}revision-file-',
      ),
    );
    await Directory(path).delete(recursive: true);
  });

  Future<RevisionRecord> seed({Map<String, Uint8List>? files}) =>
      repository.commit(
        entityId: newId(),
        kind: EntityKind.ink,
        ownerNoteId: newId(),
        files: files ?? {'page.json': _bytes('snapshot')},
        parentRevisionIds: [],
      );

  test('selected read touches only its blob despite a large corrupt attachment', () async {
    final record = await seed(
      files: {
        'page.json': _bytes('snapshot'),
        'attachments/large.bin': Uint8List(4 * 1024 * 1024)
          ..fillRange(0, 4 * 1024 * 1024, 7),
      },
    );
    final pagePath =
        '${repository.root.path}/blobs/${record.blobs['page.json']!.hash}';
    final attachmentPath =
        '${repository.root.path}/blobs/${record.blobs['attachments/large.bin']!.hash}';
    await File(attachmentPath).writeAsString('corrupt');
    final counter = _ReadCounter();
    await IOOverrides.runWithIOOverrides(() async {
      expect(
        await repository.readRevisionFile(record, 'page.json'),
        _bytes('snapshot'),
      );
    }, counter);
    expect(counter.reads, {pagePath: 1});
    expect(counter.opened, isEmpty);
    await expectLater(repository.readFiles(record), throwsFormatException);
    expect(await repository.revisions(), isEmpty);
    expect(repository.pendingRevisionCount, 1);
    expect(repository.integrityIssues, hasLength(1));
    expect(
      await repository.readRevisionFile(record, 'page.json'),
      _bytes('snapshot'),
    );
  });

  test(
    'selected payload is independently verified after a successful cached read',
    () async {
      final record = await seed();
      final hash = record.blobs['page.json']!.hash;
      expect(
        await repository.readRevisionFile(record, 'page.json'),
        _bytes('snapshot'),
      );
      await File('${repository.root.path}/blobs/$hash')
          .writeAsString('tampered');
      await expectLater(
        repository.readRevisionFile(record, 'page.json'),
        throwsFormatException,
      );
      expect(await repository.revisions(), isEmpty);
      expect(repository.pendingRevisionCount, 1);
      expect(repository.integrityIssues, hasLength(1));
      await repository.importRevision(
        record,
        blobsByHash: {hash: _bytes('snapshot')},
      );
      expect(
        await repository.readRevisionFile(record, 'page.json'),
        _bytes('snapshot'),
      );
      expect(repository.integrityIssues, isEmpty);
    },
  );

  test('missing selected payload invalidates cached active state', () async {
    final record = await seed();
    await File(
      '${repository.root.path}/blobs/${record.blobs['page.json']!.hash}',
    ).delete();
    await expectLater(
      repository.readRevisionFile(record, 'page.json'),
      throwsA(isA<FileSystemException>()),
    );
    expect(await repository.revisions(), isEmpty);
    expect(repository.pendingRevisionCount, 1);
    expect(repository.integrityIssues, hasLength(1));
  });

  test(
    'unknown filename and foreign vault reject before any payload IO',
    () async {
      final record = await seed();
      final foreign = RevisionRecord.fromJson({
        ...record.toJson(),
        'vaultId': newId(),
      });
      final counter = _ReadCounter();
      await IOOverrides.runWithIOOverrides(() async {
        await expectLater(
          repository.readRevisionFile(record, 'unknown'),
          throwsFormatException,
        );
        await expectLater(
          repository.readRevisionFile(record, '../page.json'),
          throwsFormatException,
        );
        await expectLater(
          repository.readRevisionFile(foreign, 'page.json'),
          throwsFormatException,
        );
      }, counter);
      expect(counter.reads, isEmpty);
      expect(counter.opened, isEmpty);
      expect(await repository.revisions(), hasLength(1));
      expect(repository.integrityIssues, isEmpty);
    },
  );

  test('selected read checks record length without invalidating another valid record', () async {
    final record = await seed();
    final ref = record.blobs['page.json']!;
    final wrong = RevisionRecord.fromJson({
      ...record.toJson(),
      'blobs': {
        'page.json': {'hash': ref.hash, 'length': ref.length + 1},
      },
    });
    await expectLater(
      repository.readRevisionFile(wrong, 'page.json'),
      throwsFormatException,
    );
    expect(
      await repository.readRevisionFile(record, 'page.json'),
      _bytes('snapshot'),
    );
    expect(await repository.revisions(), hasLength(1));
    expect(repository.integrityIssues, isEmpty);
  });

  test('selected read preserves readFiles ownership semantics for an unimported record', () async {
    final record = await seed();
    final unimported = RevisionRecord.fromJson({
      ...record.toJson(),
      'revisionId': newId(),
      'deviceId': newId(),
    });
    expect(
      (await repository.readFiles(unimported))['page.json'],
      _bytes('snapshot'),
    );
    expect(
      await repository.readRevisionFile(unimported, 'page.json'),
      _bytes('snapshot'),
    );
    expect(await repository.revisions(), hasLength(1));
  });

  test(
    'read results are separate payloads and close rejects selected reads',
    () async {
      final record = await seed();
      final first = await repository.readRevisionFile(record, 'page.json');
      first.fillRange(0, first.length, 0);
      expect(
        await repository.readRevisionFile(record, 'page.json'),
        _bytes('snapshot'),
      );
      await repository.close();
      await expectLater(
        repository.readRevisionFile(record, 'page.json'),
        throwsStateError,
      );
    },
  );
}

final class _ReadCounter extends IOOverrides {
  final reads = <String, int>{};
  final opened = <String>[];

  @override
  File createFile(String path) => _CountingFile(super.createFile(path), this);
}

class _CountingFile implements File {
  _CountingFile(this.inner, this.counter);
  final File inner;
  final _ReadCounter counter;

  @override
  String get path => inner.path;

  @override
  Future<Uint8List> readAsBytes() {
    counter.reads.update(path, (count) => count + 1, ifAbsent: () => 1);
    return inner.readAsBytes();
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) {
    counter.opened.add(path);
    return inner.open(mode: mode);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
