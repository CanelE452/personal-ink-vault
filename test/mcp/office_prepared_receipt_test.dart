import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

Uint8List _docx(String text) => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
      ..addFile(
        ArchiveFile.string('word/document.xml', '<document>$text</document>'),
      ),
  ),
);
Matcher _error(String code) =>
    isA<VaultMcpException>().having((error) => error.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late NoteRepository repo;
  late WorkspaceController controller;
  late VaultMcpService service;
  late VaultNote note;
  late OfficeEdition first;
  late Uint8List edited, pdf;
  var nativeCalls = 0;
  var nativeFails = false;
  var writable = true;
  var active = true;
  late VaultMcpCallContext context;

  VaultMcpService makeService() => VaultMcpService(
    controller,
    officeEngine: WindowsOfficeEngine(
      runner: (request) async {
        nativeCalls++;
        expect(request['mode'], 'apply');
        expect(
          await File(request['sourcePath'] as String).readAsBytes(),
          first.originalBytes,
        );
        if (nativeFails)
          throw const WindowsOfficeException(
            'native_interrupted',
            'Interrupted before native completion',
          );
        final output = await File('${temp.path}/native-edited.docx')
            .writeAsBytes(edited, flush: true);
        final preview = await File('${temp.path}/native-preview.pdf')
            .writeAsBytes(pdf, flush: true);
        return {
          'status': 'saved',
          'sessionId': request['sessionId'],
          'sourcePath': output.path,
          'pdfPath': preview.path,
          'sourceSha256': sha256.convert(edited).toString(),
          'pdfSha256': sha256.convert(pdf).toString(),
          'pdfPageCount': 1,
          'engineVersion': 'durable-office-fixture',
          'snapshot': {
            'kind': 'word',
            'sourceSha256': sha256.convert(edited).toString(),
            'paragraphs': [],
            'tables': [],
            'slides': [],
          },
        };
      },
    ),
  );
  Map<String, dynamic> arguments() => {
    'noteId': note.id,
    'expectedRevisionId': first.revision.revisionId,
    'requestId': newId(),
    'operations': [
      {'op': 'paragraphText', 'id': 'p1', 'text': 'Prepared native edition'},
    ],
  };
  Future<Map<String, dynamic>> call(
    Map<String, dynamic> args, {
    VaultMcpCallContext? access,
  }) async => jsonObject(
    await service.call('office_edit', args, context: access ?? context),
  );
  File receipt(Map<String, dynamic> args) => File(
    '${repo.root.path}/.workspace/mcp/requests/${args['requestId']}.json',
  );
  File recoveryFile(Map<String, dynamic> args, String name) => File(
    '${repo.root.path}/.workspace/mcp/requests/${args['requestId']}/files/$name',
  );
  Future<Map<String, dynamic>> savedReceipt(Map<String, dynamic> args) async =>
      jsonObject(jsonDecode(await receipt(args).readAsString()));
  String plannedId(Map<String, dynamic> saved) =>
      saved['plan']['prepared']['record']['revisionId'] as String;
  Future<void> restart() async {
    await controller.flush();
    controller.dispose();
    await repo.close();
    repo = await NoteRepository.open(Directory('${temp.path}/vault'));
    controller = WorkspaceController(repo, directoryProvider: () async => temp);
    service = makeService();
  }

  Future<Map<String, dynamic>> interruptAfterDurablePreparation(
    Map<String, dynamic> args,
  ) async {
    final fault = _OfficeReceiptIo(
      (target, body) =>
          target.endsWith('/${args['requestId']}.json') &&
          body?['state'] == 'prepared',
      afterRename: true,
    );
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(call(args), throwsA(isA<VaultMcpException>()));
    }, fault);
    expect(fault.fired, true);
    final saved = await savedReceipt(args);
    expect(saved['version'], 2);
    expect(saved['state'], 'prepared');
    expect(
      (await repo.heads(note.sourceEntityId!)).single.revisionId,
      first.revision.revisionId,
    );
    return saved;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-office-prepared-');
    repo = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    controller = WorkspaceController(repo, directoryProvider: () async => temp);
    nativeCalls = 0;
    nativeFails = false;
    writable = true;
    active = true;
    context = VaultMcpCallContext(
      isActive: () => active,
      canWrite: () => writable,
    );
    note = await OfficeDocumentStore(repo).importDocument(
      title: 'Office',
      fileName: 'source.docx',
      bytes: _docx('immutable original'),
    );
    first = await OfficeDocumentStore(repo).readLatest(note);
    edited = _docx('Prepared native edition');
    pdf = Uint8List.fromList(utf8.encode('%PDF-1.7\nfixture\n%%EOF\n'));
    service = makeService();
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await repo.close();
    await temp.delete(recursive: true);
  });

  test('Office preparation durably records all exact files before publication and resumes after a full restart', () async {
    final args = arguments();
    final saved = await interruptAfterDurablePreparation(args);
    expect(nativeCalls, 1);
    expect(saved['rootUri'], repo.root.absolute.uri.normalizePath().toString());
    expect(saved['vaultId'], repo.vaultId);
    expect(saved['deviceId'], repo.deviceId);
    expect(saved['formatVersion'], repo.formatVersion);
    expect(saved['noteId'], note.id);
    expect(saved['noteRevisionId'], note.revision.revisionId);
    expect(saved['sourceEntityId'], note.sourceEntityId);
    expect(saved['sourceRevisionId'], first.revision.revisionId);
    expect(saved['sourceSha256'], first.originalSha256);
    expect(saved['plan']['requireCurrentHeads'], true);
    final id = plannedId(saved);
    final original = await recoveryFile(args, 'source.docx').readAsBytes();
    final preview = await recoveryFile(args, 'preview.pdf').readAsBytes();
    final metadata = await recoveryFile(args, 'edition.json').readAsBytes();
    expect(original, edited);
    expect(preview, pdf);
    final binding = jsonObject(jsonDecode(utf8.decode(metadata)))['bindingId'];
    expect(saved['plan']['prepared']['record']['parentRevisionIds'], [
      first.revision.revisionId,
    ]);
    final privateFiles = Directory(
      '${repo.root.path}/.workspace/mcp/requests/${args['requestId']}/files',
    ).listSync().whereType<File>().map((file) => file.uri.pathSegments.last).toSet();
    expect(privateFiles, {'source.docx', 'preview.pdf', 'edition.json'});
    await restart();
    final result = await call(args);
    expect(result['revisionId'], id);
    expect(result['bindingId'], binding);
    expect(result['sourceEntityId'], note.sourceEntityId);
    expect(nativeCalls, 1);
    final edition = await OfficeDocumentStore(repo).readLatest(note);
    expect(edition.originalBytes, edited);
    expect(edition.pdfBytes, pdf);
    expect(await recoveryFile(args, 'source.docx').readAsBytes(), original);
    expect(await recoveryFile(args, 'preview.pdf').readAsBytes(), preview);
    expect(await recoveryFile(args, 'edition.json').readAsBytes(), metadata);
    expect(
      (await OfficeDocumentStore(
        repo,
      ).readLatest(note, revisionId: first.revision.revisionId)).originalBytes,
      first.originalBytes,
    );
  });

  for (final loss in ['manifestResponse', 'completedReceipt']) {
    test(
      '$loss loss acknowledges the same Office edition after restart and a later body descendant',
      () async {
        final args = arguments();
        final fault = _OfficeReceiptIo((target, body) {
          if (body == null) return false;
          if (loss == 'manifestResponse') {
            return target.contains('/revisions/') &&
                body['entityId'] == note.sourceEntityId &&
                body['ownerNoteId'] == note.id;
          }
          return target.endsWith('/${args['requestId']}.json') &&
              body['state'] == 'completed';
        }, afterRename: loss == 'manifestResponse');
        await IOOverrides.runWithIOOverrides(() async {
          await expectLater(call(args), throwsA(isA<VaultMcpException>()));
        }, fault);
        expect(fault.fired, true);
        final saved = await savedReceipt(args);
        expect(saved['state'], 'prepared');
        final id = plannedId(saved);
        await restart();
        expect((await repo.heads(note.sourceEntityId!)).single.revisionId, id);
        final published = await OfficeDocumentStore(repo)
            .readLatest(note, revisionId: id);
        final session = await OfficeDocumentStore(repo)
            .beginEdit(note, revisionId: id);
        final later = await OfficeDocumentStore(repo).commitEdited(
          session,
          originalBytes: _docx('Later descendant'),
          pdfBytes: pdf,
          engineVersion: 'later',
          pageCount: 1,
        );
        final count = (await repo.revisions()).length;
        final result = await call(args);
        expect(result['revisionId'], id);
        expect(result['bindingId'], published.bindingId);
        expect(
          (await repo.heads(note.sourceEntityId!)).single.revisionId,
          later.revision.revisionId,
        );
        expect((await repo.revisions()).length, count);
        expect(nativeCalls, 1);
        expect(await call(args), result);
      },
    );
  }

  test('an unindexed published manifest is rejoined without native reexecution or a sibling', () async {
    final args = arguments();
    final fault = _OfficeReceiptIo(
      (target, body) =>
          target.contains('/revisions/') &&
          body?['entityId'] == note.sourceEntityId,
      afterRename: true,
    );
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(call(args), throwsA(isA<VaultMcpException>()));
    }, fault);
    expect(fault.fired, true);
    final id = plannedId(await savedReceipt(args));
    final manifest = File('${repo.root.path}/revisions/$id.json');
    final publishedBytes = await manifest.readAsBytes();
    final result = await call(args);
    expect(result['revisionId'], id);
    expect((await repo.heads(note.sourceEntityId!)).single.revisionId, id);
    expect(
      (await repo.revisions())
          .where(
            (record) =>
                record.entityId == note.sourceEntityId &&
                record.revisionId != first.revision.revisionId,
          )
          .map((record) => record.revisionId),
      [id],
    );
    expect(await manifest.readAsBytes(), publishedBytes);
    expect(nativeCalls, 1);
  });

  for (final damage in [
    'bytes',
    'missingFile',
    'planDigest',
    'rootUri',
    'vaultId',
    'deviceId',
    'formatVersion',
  ]) {
    test(
      'damaged durable Office recovery $damage is rejected without rerunning native or changing source',
      () async {
        final args = arguments();
        final saved = await interruptAfterDurablePreparation(args);
        if (damage == 'bytes') {
          await recoveryFile(
            args,
            'source.docx',
          ).writeAsBytes(_docx('tampered recovery'));
        } else if (damage == 'missingFile') {
          await recoveryFile(args, 'preview.pdf').delete();
        } else {
          saved[damage] = switch (damage) {
            'formatVersion' => 999,
            'rootUri' => Directory(
              '${temp.path}/other-vault',
            ).absolute.uri.toString(),
            'planDigest' => '0' * 64,
            _ => newId(),
          };
          await receipt(args).writeAsString(jsonEncode(saved));
        }
        final damagedReceipt = await receipt(args).readAsBytes();
        await restart();
        await expectLater(call(args), throwsA(isA<VaultMcpException>()));
        expect(nativeCalls, 1);
        expect(
          (await repo.heads(note.sourceEntityId!)).single.revisionId,
          first.revision.revisionId,
        );
        expect(await receipt(args).readAsBytes(), damagedReceipt);
        expect(
          (await repo.revisions()).any(
            (record) => record.revisionId == plannedId(saved),
          ),
          false,
        );
      },
    );
  }

  for (final revoke in ['permission', 'context']) {
    test(
      'final manifest rename $revoke revocation leaves an exact resumable Office plan',
      () async {
        final args = arguments();
        var atFinalRename = false;
        bool beforeRename() {
          if (Directory('${repo.root.path}/revisions')
              .listSync()
              .any((file) => file.path.endsWith('.tmp'))) {
            atFinalRename = true;
            if (revoke == 'permission') writable = false;
            if (revoke == 'context') active = false;
          }
          return true;
        }

        final guarded = VaultMcpCallContext(
          isActive: () {
            beforeRename();
            return active;
          },
          canWrite: () {
            beforeRename();
            return writable;
          },
        );
        await expectLater(
          call(args, access: guarded),
          throwsA(
            _error(
              revoke == 'permission' ? 'read_only' : 'authorization_revoked',
            ),
          ),
        );
        expect(atFinalRename, true);
        final saved = await savedReceipt(args);
        expect(saved['state'], 'prepared');
        final id = plannedId(saved);
        expect(
          (await repo.heads(note.sourceEntityId!)).single.revisionId,
          first.revision.revisionId,
        );
        active = true;
        writable = true;
        await restart();
        expect((await call(args))['revisionId'], id);
        expect(nativeCalls, 1);
      },
    );
  }

  for (final race in ['sourceHead', 'noteMetadata']) {
    test(
      'a $race race after durable preparation cannot publish or rebase the Office plan',
      () async {
        final args = arguments();
        String? winner;
        final fault = _OfficeReceiptIo(
          (target, body) =>
              target.endsWith('/${args['requestId']}.json') &&
              body?['state'] == 'prepared',
          afterRename: true,
          throwFailure: false,
          onMatch: () async {
            if (race == 'sourceHead') {
              winner = (await repo.commit(
                entityId: note.sourceEntityId!,
                kind: EntityKind.attachment,
                ownerNoteId: note.id,
                files: {'source.docx': _docx('Remote source')},
                parentRevisionIds: [first.revision.revisionId],
              )).revisionId;
            } else {
              await controller.store.rename(
                note,
                'Metadata changed after native completion',
              );
            }
          },
        );
        await IOOverrides.runWithIOOverrides(() async {
          await expectLater(call(args), throwsA(_error('revision_conflict')));
        }, fault);
        expect(fault.fired, true);
        final saved = await savedReceipt(args);
        expect(saved['state'], 'prepared');
        final id = plannedId(saved);
        final count = (await repo.revisions()).length;
        await restart();
        await expectLater(call(args), throwsA(_error('revision_conflict')));
        expect(nativeCalls, 1);
        expect(
          (await repo.revisions()).any((record) => record.revisionId == id),
          false,
        );
        expect((await repo.revisions()).length, count);
        expect(
          (await repo.heads(note.sourceEntityId!)).single.revisionId,
          winner ?? first.revision.revisionId,
        );
      },
    );
  }

  test('native interruption leaves a started request unknown rather than rerunning the editor', () async {
    final args = arguments();
    nativeFails = true;
    await expectLater(call(args), throwsA(_error('native_interrupted')));
    expect((await savedReceipt(args))['state'], 'started');
    nativeFails = false;
    await restart();
    await expectLater(call(args), throwsA(_error('operation_state_unknown')));
    expect(nativeCalls, 1);
    expect(
      (await repo.heads(note.sourceEntityId!)).single.revisionId,
      first.revision.revisionId,
    );
  });

  for (final damage in ['missing', 'malformed', 'different']) {
    test(
      'completed Office acknowledgement rejects the actual $damage published manifest without repairing it',
      () async {
        final args = arguments();
        final result = await call(args);
        final manifest = File(
          '${repo.root.path}/revisions/${result['revisionId']}.json',
        );
        if (damage == 'missing') {
          await manifest.delete();
        } else if (damage == 'malformed') {
          await manifest.writeAsString('{');
        } else {
          final record = jsonObject(jsonDecode(await manifest.readAsString()))
            ..['deviceId'] = newId();
          await manifest.writeAsString(jsonEncode(record));
        }
        final damaged = manifest.existsSync()
            ? await manifest.readAsBytes()
            : null;
        await expectLater(call(args), throwsA(isA<VaultMcpException>()));
        expect(
          manifest.existsSync() ? await manifest.readAsBytes() : null,
          damaged,
        );
        expect(nativeCalls, 1);
      },
    );
  }

  for (final savedStage in ['prepared', 'completed']) {
    test(
      '$savedStage Office acknowledgement rejects a linked revisions parent containing the exact published files',
      () async {
        final args = arguments();
        if (savedStage == 'prepared') {
          final fault = _OfficeReceiptIo(
            (target, body) =>
                target.endsWith('/${args['requestId']}.json') &&
                body?['state'] == 'completed',
            afterRename: false,
          );
          await IOOverrides.runWithIOOverrides(() async {
            await expectLater(call(args), throwsA(isA<VaultMcpException>()));
          }, fault);
          expect(fault.fired, true);
        } else {
          await call(args);
        }
        final saved = await savedReceipt(args);
        expect(saved['state'], savedStage);
        final revisionId = plannedId(saved);
        final canonical = Directory('${repo.root.path}/revisions');
        final retained = Directory('${temp.path}/retained-revisions');
        final outside = await Directory('${temp.path}/outside-revisions')
            .create();
        final actualBytes = <String, Uint8List>{};
        await for (final entry in canonical.list(followLinks: false)) {
          expect(entry, isA<File>());
          final name = entry.uri.pathSegments.last;
          actualBytes[name] = await File(entry.path).readAsBytes();
          await File(entry.path).copy('${outside.path}/$name');
        }
        expect(actualBytes.containsKey('$revisionId.json'), true);
        final ownedRoot = await temp.resolveSymbolicLinks();
        final ownedVault = p.join(ownedRoot, 'vault');
        expect(await canonical.parent.resolveSymbolicLinks(), ownedVault);
        expect(await canonical.parent.parent.resolveSymbolicLinks(), ownedRoot);
        expect(await retained.parent.resolveSymbolicLinks(), ownedRoot);
        expect(await outside.parent.resolveSymbolicLinks(), ownedRoot);
        expect(
          FileSystemEntity.typeSync(canonical.path, followLinks: false),
          FileSystemEntityType.directory,
        );
        expect(
          await canonical.resolveSymbolicLinks(),
          p.join(ownedVault, 'revisions'),
        );
        expect(
          await outside.resolveSymbolicLinks(),
          p.join(ownedRoot, 'outside-revisions'),
        );
        expect(
          FileSystemEntity.typeSync(retained.path, followLinks: false),
          FileSystemEntityType.notFound,
        );
        await canonical.rename(retained.path);
        try {
          await Link(canonical.path).create(outside.path);
          expect(
            FileSystemEntity.typeSync(canonical.path, followLinks: false),
            FileSystemEntityType.link,
          );
          await expectLater(
            call(args),
            throwsA(_error('operation_state_unknown')),
          );
          final remaining = outside.listSync(followLinks: false);
          expect(remaining.length, actualBytes.length);
          for (final entry in remaining) {
            expect(entry, isA<File>());
            expect(
              await File(entry.path).readAsBytes(),
              actualBytes[entry.uri.pathSegments.last],
            );
          }
          expect(nativeCalls, 1);
        } finally {
          if (FileSystemEntity.typeSync(canonical.path, followLinks: false) ==
              FileSystemEntityType.link) {
            await Link(canonical.path).delete();
          }
          if (FileSystemEntity.typeSync(canonical.path, followLinks: false) ==
                  FileSystemEntityType.notFound &&
              retained.existsSync()) {
            expect(
              FileSystemEntity.typeSync(retained.path, followLinks: false),
              FileSystemEntityType.directory,
            );
            expect(await retained.parent.resolveSymbolicLinks(), ownedRoot);
            expect(
              await retained.resolveSymbolicLinks(),
              p.join(ownedRoot, 'retained-revisions'),
            );
            expect(await canonical.parent.resolveSymbolicLinks(), ownedVault);
            await retained.rename(canonical.path);
          }
        }
      },
    );
  }

  for (final damage in ['missingManifest', 'changedResult']) {
    test(
      'a version-only downgrade of an Office v2 receipt cannot bypass $damage validation',
      () async {
        final args = arguments();
        final result = await call(args);
        final saved = await savedReceipt(args);
        final manifest = File(
          '${repo.root.path}/revisions/${result['revisionId']}.json',
        );
        final publishedBytes = await manifest.readAsBytes();
        saved['version'] = 1;
        if (damage == 'missingManifest') {
          await manifest.delete();
        } else {
          saved['result'] = {
            ...jsonObject(saved['result']),
            'bindingId': newId(),
          };
        }
        await receipt(args).writeAsString(jsonEncode(saved));
        await expectLater(
          call(args),
          throwsA(
            isA<VaultMcpException>().having(
              (error) => error.code,
              'code',
              'operation_state_unknown',
            ),
          ),
        );
        expect(
          manifest.existsSync() ? await manifest.readAsBytes() : null,
          damage == 'missingManifest' ? null : publishedBytes,
        );
        expect(nativeCalls, 1);
      },
    );
  }

  for (final includeStartedAt in [false, true]) {
    test(
      'completed legacy version1 Office receipts retain results without sourceEntityId (startedAt: $includeStartedAt)',
      () async {
        final args = arguments();
        final result = await call(args);
        final old = await savedReceipt(args);
        final legacyResult = {...result}..remove('sourceEntityId');
        await receipt(args).writeAsString(
          jsonEncode({
            'version': 1,
            'requestId': args['requestId'],
            'digest': old['digest'],
            'state': 'completed',
            'result': legacyResult,
            if (includeStartedAt) 'startedAt': '2026-11-04T12:00:00.000Z',
          }),
        );
        await restart();
        expect(await call(args), legacyResult);
        expect(nativeCalls, 1);
      },
    );
  }
}

final class _OfficeReceiptIo extends IOOverrides {
  new(
    this.select, {
    required this.afterRename,
    this.throwFailure = true,
    this.onMatch,
  });
  final bool Function(String target, Map<String, dynamic>? body) select;
  final bool afterRename;
  final bool throwFailure;
  final Future<void> Function()? onMatch;
  var fired = false;
  @override
  File createFile(String path) =>
      _OfficeReceiptFile(super.createFile(path), this);
}

class _OfficeReceiptFile implements File {
  new(this.inner, this.fault);
  final File inner;
  final _OfficeReceiptIo fault;
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
  int lengthSync() => inner.lengthSync();
  @override
  Future<int> length() => inner.length();
  @override
  FileStat statSync() => inner.statSync();
  @override
  Future<FileStat> stat() async => inner.statSync();
  @override
  DateTime lastModifiedSync() => inner.lastModifiedSync();
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      inner.openRead(start, end);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      inner.open(mode: mode);
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      inner.openSync(mode: mode);
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      inner.create(recursive: recursive, exclusive: exclusive);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      inner.readAsString(encoding: encoding);
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      inner.readAsStringSync(encoding: encoding);
  @override
  Future<Uint8List> readAsBytes() => inner.readAsBytes();
  @override
  Uint8List readAsBytesSync() => inner.readAsBytesSync();
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
    final target = newPath.replaceAll('\\', '/');
    Map<String, dynamic>? body;
    if (target.endsWith('.json')) {
      try {
        final parsed = jsonDecode(await inner.readAsString());
        if (parsed is Map) body = jsonObject(parsed);
      } on FormatException {
        body = null;
      }
    }
    final selected = !fault.fired && fault.select(target, body);
    if (selected) fault.fired = true;
    if (selected && !fault.afterRename) {
      await fault.onMatch?.call();
      if (fault.throwFailure)
        throw FileSystemException(
          'Injected Office durable rename failure',
          path,
        );
    }
    final result = await inner.rename(newPath);
    if (selected && fault.afterRename) {
      await fault.onMatch?.call();
      if (fault.throwFailure)
        throw FileSystemException(
          'Injected Office response loss after actual rename',
          path,
        );
    }
    return result;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      inner.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
