import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

const _chunkSize = 1024 * 1024;

void main() {
  late Directory temp;
  late NoteRepository source;
  final opened = <NoteRepository>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ink-streaming-clone-');
    source = await NoteRepository.open(Directory('${temp.path}/source'));
    opened.add(source);
  });
  tearDown(() async {
    for (final repository in opened) {
      await repository.close();
    }
    opened.clear();
    final resolved = await temp.resolveSymbolicLinks();
    expect(
      resolved,
      startsWith(
        '${await Directory.systemTemp.resolveSymbolicLinks()}${Platform.pathSeparator}ink-streaming-clone-',
      ),
    );
    await Directory(resolved).delete(recursive: true);
  });

  Future<RevisionRecord> smallPayload({int length = 32}) => source.commit(
    entityId: newId(),
    kind: EntityKind.ink,
    files: {
      'source.pdf': Uint8List.fromList(List.generate(length, (i) => i % 256)),
    },
    parentRevisionIds: [],
  );

  Future<void> expectNoNewEntries(Set<String> before) async {
    expect(await _entryNames(temp), before);
  }

  test('a vault beyond portable JSON size streams each unique blob once into a verified v2 clone', () async {
    final sourceRoot = source.root;
    final vaultId = source.vaultId, deviceId = source.deviceId;
    await source.close();
    final hash = await _writeLargeBlob(sourceRoot, 100);
    final entityId = newId(), ownerId = newId();
    final revision = RevisionRecord(
      vaultId: vaultId,
      entityId: entityId,
      kind: EntityKind.ink,
      revisionId: newId(),
      parentRevisionIds: [],
      deviceId: deviceId,
      ownerNoteId: ownerId,
      blobs: {
        'assets/source.pdf': BlobRef(hash: hash, length: 100 * _chunkSize),
      },
    );
    final opaque = Uint8List.fromList([0, 255, 128, 13, 10, 1]);
    final opaqueHash = sha256.convert(opaque).toString();
    await File('${sourceRoot.path}/blobs/$opaqueHash').writeAsBytes(opaque);
    final withOpaque = RevisionRecord.fromJson({
      ...revision.toJson(),
      'blobs': <String, dynamic>{
        ...Map<String, dynamic>.from(revision.toJson()['blobs'] as Map),
        'future/opaque.bin': BlobRef(
          hash: opaqueHash,
          length: opaque.length,
        ).toJson(),
      },
    });
    final manifest = {
      ...withOpaque.toJson(),
      'futureManifest': {
        'preserved': true,
        'opaque': ['연구', 7],
      },
    };
    await File('${sourceRoot.path}/revisions/${revision.revisionId}.json')
        .writeAsString(jsonEncode(manifest));
    source = await NoteRepository.open(sourceRoot);
    opened.add(source);
    await expectLater(
      BackupService.exportSnapshot(source),
      throwsFormatException,
    );
    final sourceConfig = await File('${sourceRoot.path}/vault.json')
        .readAsString();
    final destination = Directory('${temp.path}/cloned');
    final guard = _CloneIo(sourceRoot.path);
    final clone = await IOOverrides.runWithIOOverrides(
      () => BackupService.cloneToEmpty(
        source,
        destination,
        targetFormatVersion: 2,
      ),
      guard,
    );
    opened.add(clone);

    expect(clone.vaultId, isNot(vaultId));
    expect(clone.deviceId, isNot(deviceId));
    expect(clone.formatVersion, 2);
    expect(source.vaultId, vaultId);
    expect(source.formatVersion, 1);
    expect(
      await File('${sourceRoot.path}/vault.json').readAsString(),
      sourceConfig,
    );
    final copied = (await clone.revisions()).single;
    expect(copied.toJson(), {...withOpaque.toJson(), 'vaultId': clone.vaultId});
    expect(
      (await clone.heads(entityId)).single.revisionId,
      revision.revisionId,
    );
    expect(guard.sourceReads[hash], 1);
    expect(guard.sourceReads[opaqueHash], 1);
    expect(guard.maxRead, lessThanOrEqualTo(_chunkSize));
    expect(guard.maxWrite, lessThanOrEqualTo(_chunkSize));
    expect(guard.maxRead, greaterThan(0));
    final copiedBlob = File('${clone.root.path}/blobs/$hash');
    expect(await copiedBlob.length(), 100 * _chunkSize);
    expect(await _hashFile(copiedBlob), hash);
    expect(await _hashFile(File('${sourceRoot.path}/blobs/$hash')), hash);
    expect(
      await File('${clone.root.path}/blobs/$opaqueHash').readAsBytes(),
      opaque,
    );
    final clonedManifest = jsonDecode(
      await File('${clone.root.path}/revisions/${revision.revisionId}.json')
          .readAsString(),
    ) as Map;
    expect(clonedManifest['futureManifest'], manifest['futureManifest']);
    await clone.close();
    final reopened = await NoteRepository.open(destination);
    opened.add(reopened);
    expect(reopened.integrityIssues, isEmpty);
    expect(reopened.pendingRevisionCount, 0);
    expect((await reopened.revisions()).single.revisionId, revision.revisionId);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test(
    'all branches tombstones bases owners and opaque bytes survive the clone',
    () async {
      final entityId = newId(), ownerId = newId();
      final original = await source.commit(
        entityId: entityId,
        kind: EntityKind.ink,
        ownerNoteId: ownerId,
        files: {
          'main.sbn2': Uint8List.fromList([1, 2, 255]),
          'future/unknown.json': Uint8List.fromList(
            utf8.encode('{"future":{"field":"원본"}}'),
          ),
        },
        parentRevisionIds: [],
      );
      for (final deleted in [false, true]) {
        await source.commit(
          entityId: entityId,
          kind: EntityKind.ink,
          ownerNoteId: ownerId,
          files: {
            'main.sbn2': Uint8List.fromList([deleted ? 9 : 8]),
          },
          parentRevisionIds: [original.revisionId],
          deleted: deleted,
          baseRefs: {
            entityId: [original.revisionId],
          },
        );
      }
      final before = await source.revisions();
      final clone = await BackupService.cloneToEmpty(
        source,
        Directory('${temp.path}/graph-clone'),
        targetFormatVersion: 2,
      );
      opened.add(clone);
      expect(await clone.heads(entityId), hasLength(2));
      expect(await source.heads(entityId), hasLength(2));
      final after = await clone.revisions();
      expect(after, hasLength(before.length));
      for (final old in before) {
        final copied = after.singleWhere(
          (record) => record.revisionId == old.revisionId,
        );
        expect(copied.toJson(), {...old.toJson(), 'vaultId': clone.vaultId});
        expect(await clone.readFiles(copied), await source.readFiles(old));
      }
    },
  );

  test('a deep complete revision chain is cloned without recursive ancestry traversal', () async {
    final root = source.root,
        vaultId = source.vaultId,
        deviceId = source.deviceId;
    await source.close();
    final entityId = newId();
    const count = 6000;
    var parents = <String>[];
    for (var index = 0; index < count; index++) {
      final record = RevisionRecord(
        vaultId: vaultId,
        entityId: entityId,
        kind: EntityKind.ink,
        revisionId:
            '90000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
        parentRevisionIds: parents,
        deviceId: deviceId,
        blobs: {},
      );
      await File('${root.path}/revisions/${record.revisionId}.json')
          .writeAsString(jsonEncode(record.toJson()));
      parents = [record.revisionId];
    }
    source = await NoteRepository.open(root);
    opened.add(source);
    final clone = await BackupService.cloneToEmpty(
      source,
      Directory('${temp.path}/deep-clone'),
      targetFormatVersion: 2,
    );
    opened.add(clone);
    expect(await clone.revisions(), hasLength(count));
    expect((await clone.heads(entityId)).single.revisionId, parents.single);
    expect(clone.integrityIssues, isEmpty);
    expect(clone.pendingRevisionCount, 0);
    expect(await source.revisions(), hasLength(count));
  }, timeout: const Timeout(Duration(minutes: 3)));

  for (final truncated in [false, true]) {
    test(
      '${truncated ? 'truncated' : 'corrupt'} source bytes cannot publish a clone or remove unrelated data',
      () async {
        final record = await smallPayload();
        final blob = File(
          '${source.root.path}/blobs/${record.blobs.values.single.hash}',
        );
        final replacement = Uint8List.fromList(
          List.filled(truncated ? 3 : 32, 127),
        );
        await blob.writeAsBytes(replacement);
        final unrelated = Directory('${temp.path}/destination.clone-unrelated');
        await unrelated.create();
        final marker = File('${unrelated.path}/keep');
        await marker.writeAsString('untouched');
        final before = await _entryNames(temp);
        final destination = Directory('${temp.path}/destination');
        await expectLater(
          BackupService.cloneToEmpty(
            source,
            destination,
            targetFormatVersion: 2,
          ),
          throwsFormatException,
        );
        expect(await destination.exists(), isFalse);
        await expectNoNewEntries(before);
        expect(await marker.readAsString(), 'untouched');
        expect(await blob.readAsBytes(), replacement);
        expect(await File('${source.root.path}/vault.json').exists(), isTrue);
      },
    );
  }

  test(
    'a streaming IO failure cleans only its own staging directory',
    () async {
      final record = await smallPayload(length: 3 * _chunkSize);
      final sourceHash = record.blobs.values.single.hash;
      final unrelated = Directory('${temp.path}/destination.clone-unrelated');
      await unrelated.create();
      final marker = File('${unrelated.path}/keep');
      await marker.writeAsString('untouched');
      final before = await _entryNames(temp);
      final destination = Directory('${temp.path}/destination');
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => BackupService.cloneToEmpty(
            source,
            destination,
            targetFormatVersion: 2,
          ),
          _CloneIo(source.root.path, failAfterSourceBytes: _chunkSize),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(await destination.exists(), isFalse);
      await expectNoNewEntries(before);
      expect(await marker.readAsString(), 'untouched');
      expect(
        await _hashFile(File('${source.root.path}/blobs/$sourceHash')),
        sourceHash,
      );
      expect(
        (await source.heads(record.entityId)).single.revisionId,
        record.revisionId,
      );
    },
  );

  test('nonempty destinations and overlapping source paths are rejected without writes', () async {
    final record = await smallPayload();
    final existing = Directory('${temp.path}/existing');
    await existing.create();
    final marker = File('${existing.path}/keep');
    await marker.writeAsString('untouched');
    for (final destination in [
      existing,
      source.root,
      temp,
      Directory('${source.root.path}/inside'),
      Directory('${source.root.path}/../source/normalized-inside'),
    ]) {
      final before = await _entryNames(temp);
      await expectLater(
        BackupService.cloneToEmpty(source, destination, targetFormatVersion: 2),
        throwsA(anyOf(isA<FormatException>(), isA<FileSystemException>())),
      );
      await expectNoNewEntries(before);
    }
    expect(await marker.readAsString(), 'untouched');
    expect(await Directory('${source.root.path}/inside').exists(), isFalse);
    expect(
      await Directory('${source.root.path}/normalized-inside').exists(),
      isFalse,
    );
    expect(await source.readFiles(record), isNotEmpty);
  });

  test(
    'copy failure survives close and owned staging cleanup failures',
    () async {
      final record = await smallPayload(length: 3 * _chunkSize);
      final guard = _CloneIo(
        source.root.path,
        failAfterSourceBytes: _chunkSize,
        failOnClose: true,
        failOnStagingCleanup: true,
      );
      final destination = Directory('${temp.path}/double-failure');
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => BackupService.cloneToEmpty(
            source,
            destination,
            targetFormatVersion: 2,
          ),
          guard,
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'original error',
            'Synthetic streaming read failure',
          ),
        ),
      );
      expect(guard.closeAttempts, 2);
      expect(guard.failedCleanupPaths, hasLength(1));
      expect(await destination.exists(), false);
      expect(await Directory(guard.failedCleanupPaths.single).exists(), true);
      expect(await source.readFiles(record), isNotEmpty);
    },
  );

  test(
    'the first close failure is kept while both file handles are closed',
    () async {
      await smallPayload();
      final guard = _CloneIo(source.root.path, failOnClose: true);
      final destination = Directory('${temp.path}/close-failure');
      await expectLater(
        IOOverrides.runWithIOOverrides(
          () => BackupService.cloneToEmpty(
            source,
            destination,
            targetFormatVersion: 2,
          ),
          guard,
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.message,
            'first close error',
            'Synthetic destination close failure',
          ),
        ),
      );
      expect(guard.closeAttempts, 2);
      expect(await destination.exists(), false);
      expect(
        (await _entryNames(temp))
            .any((name) => name.startsWith('close-failure.clone-')),
        false,
      );
    },
  );

  test('blocked parents and unsupported target formats leave source and destinations intact', () async {
    final record = await smallPayload();
    final blocker = File('${temp.path}/blocked');
    await blocker.writeAsString('keep');
    final before = await _entryNames(temp);
    await expectLater(
      BackupService.cloneToEmpty(
        source,
        Directory('${blocker.path}/clone'),
        targetFormatVersion: 2,
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await blocker.readAsString(), 'keep');
    for (final version in [0, 3]) {
      await expectLater(
        BackupService.cloneToEmpty(
          source,
          Directory('${temp.path}/unsupported-$version'),
          targetFormatVersion: version,
        ),
        throwsFormatException,
      );
    }
    await expectNoNewEntries(before);
    expect(
      (await source.heads(record.entityId)).single.revisionId,
      record.revisionId,
    );
  });
}

Future<Set<String>> _entryNames(Directory directory) async => {
  await for (final entry in directory.list(followLinks: false))
    entry.uri.pathSegments.where((part) => part.isNotEmpty).last,
};

Future<String> _hashFile(File file) async =>
    (await sha256.bind(file.openRead()).single).toString();

Future<String> _writeLargeBlob(Directory root, int megabytes) async {
  final pending = File('${root.path}/blobs/seed-pending');
  final output = await pending.open(mode: FileMode.write);
  final sink = _DigestSink();
  final digest = sha256.startChunkedConversion(sink);
  final chunk = Uint8List(_chunkSize)..fillRange(0, _chunkSize, 97);
  try {
    for (var index = 0; index < megabytes; index++) {
      chunk[0] = index % 256;
      await output.writeFrom(chunk);
      digest.add(chunk);
    }
    await output.flush();
  } finally {
    await output.close();
    digest.close();
  }
  final hash = sink.value!.toString();
  await pending.rename('${root.path}/blobs/$hash');
  return hash;
}

final class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

final class _CloneIo extends IOOverrides {
  _CloneIo(
    this.sourceRoot, {
    this.failAfterSourceBytes,
    this.failOnClose = false,
    this.failOnStagingCleanup = false,
  });
  final String sourceRoot;
  final int? failAfterSourceBytes;
  final bool failOnClose;
  final bool failOnStagingCleanup;
  final failedCleanupPaths = <String>[];
  var closeAttempts = 0;
  final sourceReads = <String, int>{};
  var maxRead = 0, maxWrite = 0, sourceBytes = 0;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    final normalized = path.replaceAll('\\', '/');
    if (!RegExp(r'/blobs/[a-f0-9]{64}$').hasMatch(normalized)) return file;
    final isSource = normalized.startsWith(
      '${sourceRoot.replaceAll('\\', '/')}/blobs/',
    );
    return _GuardedFile(file, this, isSource);
  }

  @override
  Directory createDirectory(String path) {
    final directory = super.createDirectory(path);
    if (!failOnStagingCleanup || !RegExp(r'\.clone-[a-f0-9-]+$').hasMatch(path))
      return directory;
    return _CleanupFailureDirectory(directory, this);
  }

  void opened(File file, bool source) {
    if (source) {
      final hash = file.uri.pathSegments.last;
      sourceReads.update(hash, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  void read(int count, bool source) {
    if (count > _chunkSize)
      throw StateError('Clone requested a whole-blob buffer');
    if (count > maxRead) maxRead = count;
    if (source) {
      if (failAfterSourceBytes != null &&
          sourceBytes >= failAfterSourceBytes!) {
        throw const FileSystemException('Synthetic streaming read failure');
      }
      sourceBytes += count;
    }
  }

  void write(int count) {
    if (count > _chunkSize)
      throw StateError('Clone requested a whole-blob write');
    if (count > maxWrite) maxWrite = count;
  }
}

final class _GuardedFile implements File {
  _GuardedFile(this.file, this.guard, this.source);
  final File file;
  final _CloneIo guard;
  final bool source;
  @override
  String get path => file.path;
  @override
  Uri get uri => file.uri;
  @override
  Directory get parent => file.parent;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<int> length() => file.length();
  @override
  Future<FileStat> stat() => file.stat();
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    if (mode == FileMode.read) guard.opened(file, source);
    return _GuardedRandomFile(await file.open(mode: mode), guard, source);
  }

  @override
  Stream<List<int>> openRead([int? start, int? end]) {
    guard.opened(file, source);
    return file.openRead(start, end).map((chunk) {
      guard.read(chunk.length, source);
      return chunk;
    });
  }

  @override
  Future<Uint8List> readAsBytes() =>
      Future.error(StateError('Clone must stream blob bytes'));
  @override
  Uint8List readAsBytesSync() =>
      throw StateError('Clone must stream blob bytes');
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      file.delete(recursive: recursive);
  @override
  Future<File> rename(String path) => file.rename(path);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _GuardedRandomFile implements RandomAccessFile {
  _GuardedRandomFile(this.file, this.guard, this.source);
  final RandomAccessFile file;
  final _CloneIo guard;
  final bool source;
  @override
  String get path => file.path;
  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) {
    guard.read((end ?? buffer.length) - start, source);
    return file.readInto(buffer, start, end);
  }

  @override
  Future<Uint8List> read(int bytes) {
    guard.read(bytes, source);
    return file.read(bytes);
  }

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    guard.write((end ?? buffer.length) - start);
    await file.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await file.flush();
    return this;
  }

  @override
  Future<void> close() async {
    await file.close();
    guard.closeAttempts++;
    if (guard.failOnClose)
      throw FileSystemException(
        'Synthetic ${source ? 'source' : 'destination'} close failure',
      );
  }

  @override
  Future<int> length() => file.length();
  @override
  Future<int> position() => file.position();
  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await file.setPosition(position);
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CleanupFailureDirectory implements Directory {
  _CleanupFailureDirectory(this.directory, this.guard);
  final Directory directory;
  final _CloneIo guard;
  @override
  String get path => directory.path;
  @override
  Uri get uri => directory.uri;
  @override
  Directory get absolute => directory.absolute;
  @override
  Directory get parent => directory.parent;
  @override
  Future<Directory> create({bool recursive = false}) =>
      directory.create(recursive: recursive);
  @override
  Future<String> resolveSymbolicLinks() => directory.resolveSymbolicLinks();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    guard.failedCleanupPaths.add(path);
    throw const FileSystemException('Synthetic owned staging cleanup failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
