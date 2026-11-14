import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

Map<String, dynamic> _jsonCopy(Map<String, Object?> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

void main() {
  late Directory directory;
  final opened = <NoteRepository>[];

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('prepared-recovery-');
  });

  tearDown(() async {
    for (final repository in opened) {
      await repository.close();
    }
    opened.clear();
    final path = await directory.resolveSymbolicLinks();
    expect(
      path,
      startsWith(
        '${await Directory.systemTemp.resolveSymbolicLinks()}${Platform.pathSeparator}prepared-recovery-',
      ),
    );
    await Directory(path).delete(recursive: true);
  });

  Future<NoteRepository> open(
    String name, {
    int format = 2,
    NoteRepository? copy,
  }) async {
    final repository = await NoteRepository.open(
      Directory('${directory.path}/$name'),
      createFormatVersion: format,
      vaultId: copy?.vaultId,
      deviceId: copy?.deviceId,
    );
    opened.add(repository);
    return repository;
  }

  PreparedCommit prepare(
    NoteRepository repository,
    Map<String, Uint8List> files,
  ) => repository.prepareCommit(
    entityId: newId(),
    kind: EntityKind.ink,
    ownerNoteId: newId(),
    files: files,
    parentRevisionIds: [],
  );

  for (final format in [1, 2]) {
    test(
      'format $format descriptor survives reopen with exact revision metadata',
      () async {
        var repository = await open('vault', format: format);
        final entityId = newId(), ownerId = newId();
        final first = await repository.commit(
          entityId: entityId,
          kind: EntityKind.ink,
          ownerNoteId: ownerId,
          files: {'main.sbn2': _bytes('first')},
          parentRevisionIds: [],
        );
        final branch = await repository.commit(
          entityId: entityId,
          kind: EntityKind.ink,
          ownerNoteId: ownerId,
          files: {'main.sbn2': _bytes('branch')},
          parentRevisionIds: [],
        );
        final files = {'main.sbn2': _bytes('private snapshot payload')};
        final original = repository.prepareCommit(
          entityId: entityId,
          kind: EntityKind.ink,
          ownerNoteId: ownerId,
          files: files,
          parentRevisionIds: [branch.revisionId, first.revisionId],
          deleted: true,
          baseRefs: {
            newId(): [newId(), newId()],
          },
        );
        final descriptor = _jsonCopy(original.toRecoveryDescriptor());
        expect(
          descriptor.keys,
          unorderedEquals(['version', 'rootUri', 'record']),
        );
        expect(descriptor['version'], 1);
        expect(
          descriptor['rootUri'],
          repository.root.absolute.uri.normalizePath().toString(),
        );
        expect(descriptor['record'], original.record.toJson());
        expect(
          jsonEncode(descriptor),
          isNot(contains('private snapshot payload')),
        );
        await repository.close();
        repository = await open('vault');
        final resumed = repository.resumePreparedCommit(
          descriptor: descriptor,
          files: files,
        );
        expect(resumed.belongsTo(repository), isTrue);
        expect(resumed.record.toJson(), original.record.toJson());
        expect(resumed.matchesFiles(files), isTrue);
        expect(await repository.revisions(), hasLength(2));
        final result = await repository.commitPreparedIfHeads(
          resumed,
          expectedHeads: {
            entityId: [first.revisionId, branch.revisionId],
          },
          expectedRevisionIds: [first.revisionId, branch.revisionId],
        );
        expect(result.revisionId, original.record.revisionId);
        expect(result.toJson(), original.record.toJson());
        expect(await repository.revisions(), hasLength(3));
      },
    );
  }

  test(
    'descriptor and resumed payloads cannot mutate either prepared snapshot',
    () async {
      final repository = await open('vault');
      final payload = _bytes('snapshot');
      final prepared = prepare(repository, {'main.sbn2': payload});
      final expected = _jsonCopy(prepared.toRecoveryDescriptor());
      final descriptor = prepared.toRecoveryDescriptor();
      final record = descriptor['record'] as Map<String, dynamic>;
      (record['parentRevisionIds'] as List).add(newId());
      (record['blobs'] as Map)['main.sbn2']['length'] = 999;
      (record['baseRefs'] as Map)[newId()] = [newId()];
      descriptor['rootUri'] = 'file:///elsewhere/';
      expect(prepared.toRecoveryDescriptor(), expected);
      final recoveredDescriptor = _jsonCopy(expected);
      final recoveredFiles = {'main.sbn2': _bytes('snapshot')};
      final resumed = repository.resumePreparedCommit(
        descriptor: recoveredDescriptor,
        files: recoveredFiles,
      );
      (recoveredDescriptor['record'] as Map)['deleted'] = true;
      recoveredFiles['main.sbn2']!.fillRange(0, payload.length, 0);
      recoveredFiles['later'] = _bytes('extra');
      expect(resumed.record.toJson(), prepared.record.toJson());
      expect(resumed.matchesFiles({'main.sbn2': _bytes('snapshot')}), isTrue);
      await repository.commitPreparedIfHeads(
        resumed,
        expectedHeads: {prepared.record.entityId: []},
      );
      expect(
        (await repository.readFiles(resumed.record))['main.sbn2'],
        _bytes('snapshot'),
      );
    },
  );

  test('recovered token retains identity after failure before manifest publication', () async {
    var repository = await open('vault');
    final files = {'main.sbn2': _bytes('pending')};
    final prepared = prepare(repository, files);
    final descriptor = _jsonCopy(prepared.toRecoveryDescriptor());
    var checks = 0;
    await expectLater(
      repository.commitPreparedIfHeads(
        prepared,
        expectedHeads: {prepared.record.entityId: []},
        beforePublish: () {
          if (++checks == 2)
            throw StateError('Synthetic before manifest failure');
        },
      ),
      throwsStateError,
    );
    expect(checks, 2);
    expect(await repository.revisions(), isEmpty);
    expect(
      await File(
        '${repository.root.path}/revisions/${prepared.record.revisionId}.json',
      ).exists(),
      isFalse,
    );
    await repository.close();
    repository = await open('vault');
    final resumed = repository.resumePreparedCommit(
      descriptor: descriptor,
      files: files,
    );
    final result = await repository.commitPreparedIfHeads(
      resumed,
      expectedHeads: {prepared.record.entityId: []},
      expectedRevisionIds: [],
    );
    expect(result.revisionId, prepared.record.revisionId);
    expect(await repository.revisions(), hasLength(1));
  });

  test('recovered token reuses disk revision after manifest response loss and reopen', () async {
    var repository = await open('vault');
    final files = {'main.sbn2': _bytes('published')};
    final prepared = prepare(repository, files);
    final descriptor = _jsonCopy(prepared.toRecoveryDescriptor());
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(
        repository.commitPreparedIfHeads(
          prepared,
          expectedHeads: {prepared.record.entityId: []},
          expectedRevisionIds: [],
        ),
        throwsStateError,
      );
    }, _ManifestResponseLoss());
    expect(await repository.revisions(), isEmpty);
    expect(
      await File(
        '${repository.root.path}/revisions/${prepared.record.revisionId}.json',
      ).exists(),
      isTrue,
    );
    await repository.close();
    repository = await open('vault');
    final resumed = repository.resumePreparedCommit(
      descriptor: descriptor,
      files: files,
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      final result = await repository.commitPreparedIfHeads(
        resumed,
        expectedHeads: {prepared.record.entityId: []},
        expectedRevisionIds: [],
      );
      expect(result.revisionId, prepared.record.revisionId);
    }
    expect(await repository.revisions(), hasLength(1));
  });

  test('recovered token still obeys queued head and authorization guards', () async {
    final repository = await open('vault');
    final files = {'main.sbn2': _bytes('planned')};
    final prepared = prepare(repository, files);
    final resumed = repository.resumePreparedCommit(
      descriptor: _jsonCopy(prepared.toRecoveryDescriptor()),
      files: files,
    );
    await expectLater(
      repository.commitPreparedIfHeads(
        resumed,
        expectedHeads: {prepared.record.entityId: []},
        beforePublish: () => throw StateError('Permission revoked'),
      ),
      throwsStateError,
    );
    final remote = repository.commit(
      entityId: prepared.record.entityId,
      kind: EntityKind.ink,
      ownerNoteId: prepared.record.ownerNoteId,
      files: {'main.sbn2': _bytes('remote')},
      parentRevisionIds: [],
    );
    final publishing = repository.commitPreparedIfHeads(
      resumed,
      expectedHeads: {prepared.record.entityId: []},
    );
    final arrival = await remote;
    await expectLater(publishing, throwsStateError);
    expect(
      (await repository.heads(arrival.entityId)).single.revisionId,
      arrival.revisionId,
    );
    expect(
      await File(
        '${repository.root.path}/revisions/${prepared.record.revisionId}.json',
      ).exists(),
      isFalse,
    );
  });

  final invalidDescriptors = <String, void Function(Map<String, dynamic>)>{
    'extra descriptor field': (d) => d['files'] = <String, Object?>{},
    'missing descriptor field': (d) => d.remove('rootUri'),
    'future version': (d) => d['version'] = 2,
    'noninteger version': (d) => d['version'] = 1.0,
    'string version': (d) => d['version'] = '1',
    'foreign root': (d) => d['rootUri'] = 'file:///elsewhere/',
    'foreign vault': (d) => d['record']['vaultId'] = newId(),
    'foreign device': (d) => d['record']['deviceId'] = newId(),
    'foreign format': (d) => d['record']['formatVersion'] = 1,
    'extra record field': (d) => d['record']['unexpected'] = true,
    'missing nullable record field': (d) =>
        (d['record'] as Map).remove('ownerNoteId'),
    'malformed record': (d) => d['record'] = <Object?>[],
    'invalid revision ID': (d) => d['record']['revisionId'] = '../escape',
    'duplicate parent': (d) {
      final parent = newId();
      d['record']['parentRevisionIds'] = [parent, parent];
    },
    'self parent': (d) =>
        d['record']['parentRevisionIds'] = [d['record']['revisionId']],
    'invalid deleted flag': (d) => d['record']['deleted'] = 'false',
    'invalid base references': (d) =>
        d['record']['baseRefs'] = {'invalid': <String>[]},
    'extra blob field': (d) =>
        d['record']['blobs']['main.sbn2']['extra'] = true,
    'missing blob field': (d) =>
        (d['record']['blobs']['main.sbn2'] as Map).remove('length'),
    'invalid blob hash': (d) =>
        d['record']['blobs']['main.sbn2']['hash'] = 'invalid',
    'invalid blob length': (d) =>
        d['record']['blobs']['main.sbn2']['length'] = -1,
    'unsafe logical path': (d) {
      final blobs = d['record']['blobs'] as Map;
      blobs['../main.sbn2'] = blobs.remove('main.sbn2');
    },
  };
  for (final entry in invalidDescriptors.entries) {
    test('recovery rejects ${entry.key} without publishing', () async {
      final repository = await open('vault');
      final files = {'main.sbn2': _bytes('valid')};
      final prepared = prepare(repository, files);
      final descriptor = _jsonCopy(prepared.toRecoveryDescriptor());
      entry.value(descriptor);
      expect(
        () => repository.resumePreparedCommit(
          descriptor: descriptor,
          files: files,
        ),
        throwsFormatException,
      );
      expect(await repository.revisions(), isEmpty);
      expect(await Directory('${repository.root.path}/blobs').list().length, 0);
    });
  }

  for (final mutation in ['missing', 'extra', 'wrong name', 'length', 'hash']) {
    test('recovery rejects $mutation payload entry', () async {
      final repository = await open('vault');
      final prepared = prepare(repository, {'main.sbn2': _bytes('valid')});
      final files = {'main.sbn2': _bytes('valid')};
      switch (mutation) {
        case 'missing':
          files.clear();
        case 'extra':
          files['extra'] = _bytes('valid');
        case 'wrong name':
          files['other'] = files.remove('main.sbn2')!;
        case 'length':
          files['main.sbn2'] = _bytes('shorter?');
        case 'hash':
          files['main.sbn2'] = _bytes('other');
      }
      expect(
        () => repository.resumePreparedCommit(
          descriptor: _jsonCopy(prepared.toRecoveryDescriptor()),
          files: files,
        ),
        throwsFormatException,
      );
    });
  }

  test(
    'same identities in another root cannot consume a recovery descriptor',
    () async {
      final repository = await open('vault');
      final clone = await open('clone', copy: repository);
      final files = {'main.sbn2': _bytes('private')};
      final prepared = prepare(repository, files);
      expect(
        () => clone.resumePreparedCommit(
          descriptor: _jsonCopy(prepared.toRecoveryDescriptor()),
          files: files,
        ),
        throwsFormatException,
      );
      expect(await clone.revisions(), isEmpty);
      expect(await Directory('${clone.root.path}/blobs').list().length, 0);
    },
  );

  test('closed repository cannot resume a descriptor', () async {
    final repository = await open('vault');
    final files = {'main.sbn2': _bytes('valid')};
    final prepared = prepare(repository, files);
    await repository.close();
    expect(
      () => repository.resumePreparedCommit(
        descriptor: _jsonCopy(prepared.toRecoveryDescriptor()),
        files: files,
      ),
      throwsStateError,
    );
  });

  for (final malformed in [false, true]) {
    test(
      'recovered retry preserves and rejects ${malformed ? 'malformed' : 'different'} disk manifest',
      () async {
        final repository = await open('vault');
        final files = {'main.sbn2': _bytes('protected')};
        final prepared = prepare(repository, files);
        final descriptor = _jsonCopy(prepared.toRecoveryDescriptor());
        await repository.commitPreparedIfHeads(
          prepared,
          expectedHeads: {prepared.record.entityId: []},
        );
        final manifest = File(
          '${repository.root.path}/revisions/${prepared.record.revisionId}.json',
        );
        final changed = malformed
            ? '{'
            : jsonEncode({...prepared.record.toJson(), 'deviceId': newId()});
        await manifest.writeAsString(changed);
        final resumed = repository.resumePreparedCommit(
          descriptor: descriptor,
          files: files,
        );
        await expectLater(
          repository.commitPreparedIfHeads(
            resumed,
            expectedHeads: {prepared.record.entityId: []},
          ),
          throwsFormatException,
        );
        expect(await manifest.readAsString(), changed);
      },
    );
  }
}

final class _ManifestResponseLoss extends IOOverrides {
  bool lost = false;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('.tmp') ? _ResponseLossFile(file, this) : file;
  }
}

class _ResponseLossFile implements File {
  _ResponseLossFile(this.inner, this.faults);
  final File inner;
  final _ManifestResponseLoss faults;

  @override
  String get path => inner.path;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => inner.writeAsBytes(bytes, mode: mode, flush: flush);

  @override
  Future<File> rename(String newPath) async {
    final result = await inner.rename(newPath);
    if (!faults.lost && newPath.replaceAll('\\', '/').contains('/revisions/')) {
      faults.lost = true;
      throw StateError('Synthetic manifest response loss');
    }
    return result;
  }

  @override
  Future<bool> exists() => inner.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      inner.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
