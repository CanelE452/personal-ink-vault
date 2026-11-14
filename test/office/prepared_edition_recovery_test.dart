import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

import 'office_document_store_test.dart' show officeFile, syntheticPdf;

Map<String, dynamic> _jsonCopy(Map<String, Object?> json) =>
    jsonObject(jsonDecode(jsonEncode(json)));

Map<String, Uint8List> _copyFiles(Map<String, Uint8List> files) => {
  for (final entry in files.entries) entry.key: Uint8List.fromList(entry.value),
};

Uint8List _jsonBytes(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

RevisionRecord _planned(Map<String, dynamic> descriptor) =>
    RevisionRecord.fromJson(
      jsonObject(jsonObject(descriptor['prepared'])['record']),
    );

void main() {
  late Directory directory;
  late NoteRepository repository;
  late OfficeDocumentStore documents;
  late VaultNote note;
  late OfficeEdition base;
  late RevisionRecord oldInk;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('office-recovery-');
    repository = await NoteRepository.open(
      Directory('${directory.path}/vault'),
      createFormatVersion: 2,
    );
    documents = OfficeDocumentStore(repository);
    note = await documents.importDocument(
      title: 'Lecture',
      fileName: 'lecture.docx',
      bytes: officeFile('imported'),
    );
    base = await documents.commitEdited(
      await documents.beginEdit(note),
      originalBytes: officeFile('base'),
      pdfBytes: syntheticPdf('base'),
      engineVersion: 'fixture-base',
      pageCount: 1,
    );
    final annotations = await OfficeAnnotationStore(repository)
        .open(note, base);
    oldInk = await annotations.saveFiles({
      'main.sbn2': Uint8List.fromList([1, 2, 3]),
    });
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  Future<OfficePreparedEdition> prepare({
    bool conditional = false,
    void Function()? beforePublish,
  }) async => documents.prepareEdited(
    await documents.beginEdit(note),
    originalBytes: officeFile('edited'),
    pdfBytes: syntheticPdf('edited'),
    engineVersion: 'fixture-edited',
    pageCount: 2,
    requireCurrentHeads: conditional,
    beforePublish: beforePublish,
  );

  Future<void> persist(OfficePreparedEdition prepared) async {
    final staged = Directory('${directory.path}/staged');
    await staged.create();
    for (final entry in prepared.copyRecoveryFiles().entries) {
      await File('${staged.path}/${entry.key}')
          .writeAsBytes(entry.value, flush: true);
    }
    await File(
      '${staged.path}/plan.json',
    ).writeAsString(jsonEncode(prepared.toRecoveryDescriptor()), flush: true);
  }

  Future<({Map<String, dynamic> descriptor, Map<String, Uint8List> files})>
  load() async {
    final staged = Directory('${directory.path}/staged');
    final descriptor = jsonObject(
      jsonDecode(await File('${staged.path}/plan.json').readAsString()),
    );
    final files = <String, Uint8List>{};
    await for (final file in staged.list()) {
      if (file is File && !file.path.endsWith('plan.json'))
        files[file.uri.pathSegments.last] = await file.readAsBytes();
    }
    return (descriptor: descriptor, files: files);
  }

  Future<void> restart() async {
    await repository.close();
    repository = await NoteRepository.open(
      Directory('${directory.path}/vault'),
    );
    documents = OfficeDocumentStore(repository);
    note = (await WorkspaceStore(repository).list(includeDeleted: true))
        .singleWhere((n) => n.id == note.id);
  }

  test('prepared exports are detached copies of exact three files and publication identity', () async {
    final prepared = await prepare();
    final descriptor = _jsonCopy(prepared.toRecoveryDescriptor());
    final files = prepared.copyRecoveryFiles();
    expect(
      descriptor.keys,
      unorderedEquals([
        'version',
        'noteRevisionId',
        'sourceRevisionId',
        'requireCurrentHeads',
        'prepared',
      ]),
    );
    expect(descriptor['version'], 1);
    expect(descriptor['noteRevisionId'], note.revision.revisionId);
    expect(descriptor['sourceRevisionId'], base.revision.revisionId);
    expect(descriptor['requireCurrentHeads'], isFalse);
    expect(
      files.keys,
      unorderedEquals(['lecture.docx', 'preview.pdf', 'edition.json']),
    );
    final planned = _planned(descriptor);
    final metadata = jsonObject(
      jsonDecode(utf8.decode(files['edition.json']!)),
    );
    expect(metadata['bindingId'], isA<String>());
    expect(
      metadata['originalSha256'],
      sha256.convert(files['lecture.docx']!).toString(),
    );
    expect(
      metadata['pdfSha256'],
      sha256.convert(files['preview.pdf']!).toString(),
    );
    for (final bytes in files.values) {
      bytes.fillRange(0, bytes.length, 0);
    }
    jsonObject(jsonObject(descriptor['prepared'])['record'])['deviceId'] =
        newId();
    files.clear();
    final result = await documents.commitPreparedEdition(prepared);
    expect(result.revision.revisionId, planned.revisionId);
    expect(result.bindingId, metadata['bindingId']);
    expect(result.originalBytes, officeFile('edited'));
    expect(result.pdfBytes, syntheticPdf('edited'));
    expect(prepared.copyRecoveryFiles().keys, hasLength(3));
  });

  test('fresh store reconstructs an unpublished plan from disk without the old token', () async {
    Future<void> createAndForget() async {
      await persist(await prepare());
    }

    await createAndForget();
    final count = (await repository.revisions()).length;
    await restart();
    final stored = await load();
    final planned = _planned(stored.descriptor);
    final binding = jsonObject(
      jsonDecode(utf8.decode(stored.files['edition.json']!)),
    )['bindingId'];
    final resumed = await documents.resumePreparedEdition(
      note,
      descriptor: stored.descriptor,
      files: stored.files,
    );
    stored.files['lecture.docx']!.fillRange(
      0,
      stored.files['lecture.docx']!.length,
      0,
    );
    stored.files.clear();
    jsonObject(
      jsonObject(stored.descriptor['prepared'])['record'],
    )['deviceId'] = newId();
    final edition = await documents.commitPreparedEdition(resumed);
    expect(edition.revision.toJson(), planned.toJson());
    expect(edition.revision.parentRevisionIds, [base.revision.revisionId]);
    expect(edition.bindingId, binding);
    expect(edition.originalBytes, officeFile('edited'));
    expect(edition.pdfBytes, syntheticPdf('edited'));
    expect((await repository.revisions()).length, count + 1);
    expect(
      (await repository.heads(base.bindingId!)).single.revisionId,
      oldInk.revisionId,
    );
    expect(
      (await documents.readLatest(
        note,
        revisionId: base.revision.revisionId,
      )).pdfBytes,
      base.pdfBytes,
    );
  });

  for (final conditional in [false, true]) {
    test(
      'published ${conditional ? 'conditional' : 'branching'} plan survives response loss, restart and later branches',
      () async {
        Future<void> publishAndForget() async {
          final guarded = _LostResponseRepository(repository);
          final writer = OfficeDocumentStore(guarded);
          final prepared = writer.prepareEdited(
            await writer.beginEdit(note),
            originalBytes: officeFile('edited'),
            pdfBytes: syntheticPdf('edited'),
            engineVersion: 'fixture-edited',
            pageCount: 2,
            requireCurrentHeads: conditional,
          );
          await persist(prepared);
          await expectLater(
            writer.commitPreparedEdition(prepared),
            throwsStateError,
          );
        }

        await publishAndForget();
        await restart();
        final stored = await load();
        final planned = _planned(stored.descriptor);
        final descendant = await documents.commitEdited(
          await documents.beginEdit(note),
          originalBytes: officeFile('descendant'),
          pdfBytes: syntheticPdf('descendant'),
          engineVersion: 'fixture',
          pageCount: 1,
        );
        final remote = await documents.commitEdited(
          await documents.beginEdit(note, revisionId: base.revision.revisionId),
          originalBytes: officeFile('remote'),
          pdfBytes: syntheticPdf('remote'),
          engineVersion: 'fixture',
          pageCount: 1,
        );
        final count = (await repository.revisions()).length;
        final resumed = await documents.resumePreparedEdition(
          note,
          descriptor: stored.descriptor,
          files: stored.files,
        );
        final edition = await documents.commitPreparedEdition(resumed);
        expect(edition.revision.revisionId, planned.revisionId);
        expect(
          edition.bindingId,
          jsonObject(
            jsonDecode(utf8.decode(stored.files['edition.json']!)),
          )['bindingId'],
        );
        expect(edition.originalBytes, officeFile('edited'));
        expect(edition.pdfBytes, syntheticPdf('edited'));
        expect((await repository.revisions()).length, count);
        expect(
          (await repository.heads(note.sourceEntityId!))
              .map((r) => r.revisionId),
          unorderedEquals([
            descendant.revision.revisionId,
            remote.revision.revisionId,
          ]),
        );
        expect(
          (await repository.heads(base.bindingId!)).single.revisionId,
          oldInk.revisionId,
        );
      },
    );
  }

  for (final conditional in [false, true]) {
    test(
      'unpublished recovery preserves ${conditional ? 'conditional rejection' : 'Android captured branch'} policy',
      () async {
        await persist(await prepare(conditional: conditional));
        final remote = await documents.commitEdited(
          await documents.beginEdit(note),
          originalBytes: officeFile('remote'),
          pdfBytes: syntheticPdf('remote'),
          engineVersion: 'fixture',
          pageCount: 1,
        );
        await restart();
        final stored = await load();
        final planned = _planned(stored.descriptor);
        final resumed = await documents.resumePreparedEdition(
          note,
          descriptor: stored.descriptor,
          files: stored.files,
        );
        if (conditional) {
          await expectLater(
            documents.commitPreparedEdition(resumed),
            throwsStateError,
          );
          expect(
            (await repository.heads(note.sourceEntityId!)).single.revisionId,
            remote.revision.revisionId,
          );
        } else {
          final edition = await documents.commitPreparedEdition(resumed);
          expect(edition.revision.revisionId, planned.revisionId);
          expect(edition.revision.parentRevisionIds, [
            base.revision.revisionId,
          ]);
          expect(
            (await repository.heads(note.sourceEntityId!))
                .map((r) => r.revisionId),
            unorderedEquals([planned.revisionId, remote.revision.revisionId]),
          );
        }
      },
    );
  }

  test('fresh callback replaces old process closure and protects final manifest rename', () async {
    var oldChecks = 0;
    await persist(
      await prepare(
        beforePublish: () {
          oldChecks++;
        },
      ),
    );
    await restart();
    final stored = await load();
    final planned = _planned(stored.descriptor);
    var revokeAtRename = true, renameChecked = false;
    final resumed = await documents.resumePreparedEdition(
      note,
      descriptor: stored.descriptor,
      files: stored.files,
      beforePublish: () {
        final pending = Directory('${repository.root.path}/revisions')
            .listSync()
            .any(
              (f) =>
                  f.path.contains('${planned.revisionId}.json.') &&
                  f.path.endsWith('.tmp'),
            );
        if (pending) {
          renameChecked = true;
          if (revokeAtRename)
            throw StateError('New process permission revoked');
        }
      },
    );
    expect(resumed.toRecoveryDescriptor()['requireCurrentHeads'], isTrue);
    await expectLater(
      documents.commitPreparedEdition(resumed),
      throwsStateError,
    );
    expect(renameChecked, isTrue);
    expect(oldChecks, 0);
    expect(
      File('${repository.root.path}/revisions/${planned.revisionId}.json')
          .existsSync(),
      isFalse,
    );
    revokeAtRename = false;
    expect(
      (await documents.commitPreparedEdition(resumed)).revision.revisionId,
      planned.revisionId,
    );
  });

  test('injecting a callback into a branching descriptor forces current-head protection', () async {
    await persist(await prepare());
    await documents.commitEdited(
      await documents.beginEdit(note),
      originalBytes: officeFile('remote'),
      pdfBytes: syntheticPdf('remote'),
      engineVersion: 'fixture',
      pageCount: 1,
    );
    final stored = await load();
    final resumed = await documents.resumePreparedEdition(
      note,
      descriptor: stored.descriptor,
      files: stored.files,
      beforePublish: () {},
    );
    expect(resumed.toRecoveryDescriptor()['requireCurrentHeads'], isTrue);
    await expectLater(
      documents.commitPreparedEdition(resumed),
      throwsStateError,
    );
  });

  test('strict prepared envelope rejects schema, policy, identity and parent damage', () async {
    final prepared = await prepare();
    final descriptor = _jsonCopy(prepared.toRecoveryDescriptor());
    final files = prepared.copyRecoveryFiles();
    final other = await documents.importDocument(
      title: 'Other',
      fileName: 'other.docx',
      bytes: officeFile('other'),
    );
    final otherSource = (await repository.heads(other.sourceEntityId!)).single;
    final mutations = <void Function(Map<String, dynamic>)>[
      (j) => j['unknown'] = true,
      (j) => j.remove('requireCurrentHeads'),
      (j) => j['requireCurrentHeads'] = 'false',
      (j) => j['version'] = 2,
      (j) => j['noteRevisionId'] = other.revision.revisionId,
      (j) => j['sourceRevisionId'] = otherSource.revisionId,
      (j) => j['sourceRevisionId'] = base.revision.parentRevisionIds.single,
      (j) => jsonObject(j['prepared'])['rootUri'] = Directory(
        '${directory.path}/different',
      ).absolute.uri.normalizePath().toString(),
      (j) => jsonObject(jsonObject(j['prepared'])['record'])['ownerNoteId'] =
          other.id,
      (j) =>
          jsonObject(jsonObject(j['prepared'])['record'])['parentRevisionIds'] =
              [otherSource.revisionId],
      (j) => jsonObject(jsonObject(j['prepared'])['record'])['kind'] = 'ink',
      (j) => jsonObject(jsonObject(j['prepared'])['record'])['deleted'] = true,
      (j) =>
          jsonObject(jsonObject(j['prepared'])['record'])['deviceId'] = newId(),
    ];
    final count = (await repository.revisions()).length;
    for (final mutate in mutations) {
      final damaged = _jsonCopy(descriptor);
      mutate(damaged);
      await expectLater(
        documents.resumePreparedEdition(
          note,
          descriptor: damaged,
          files: _copyFiles(files),
        ),
        throwsFormatException,
      );
    }
    expect((await repository.revisions()).length, count);
    final clone = await NoteRepository.open(
      Directory('${directory.path}/clone'),
      vaultId: repository.vaultId,
      deviceId: repository.deviceId,
      createFormatVersion: 2,
    );
    try {
      await expectLater(
        OfficeDocumentStore(clone)
            .resumePreparedEdition(note, descriptor: descriptor, files: files),
        throwsFormatException,
      );
      expect(await clone.revisions(), isEmpty);
      expect(await Directory('${clone.root.path}/blobs').list().length, 0);
    } finally {
      await clone.close();
    }
  });

  test('current metadata repointed to a different source cannot resume the historical plan', () async {
    final prepared = await prepare();
    final capturedSession = await documents.beginEdit(note);
    final other = await documents.importDocument(
      title: 'Other',
      fileName: 'other.docx',
      bytes: officeFile('other'),
    );
    final metadata = jsonObject(
      jsonDecode(
        utf8.decode((await repository.readFiles(note.revision))['note.json']!),
      ),
    );
    await repository.commit(
      entityId: note.id,
      kind: EntityKind.metadata,
      files: {
        'note.json': _jsonBytes({
          ...metadata,
          'sourceEntityId': other.sourceEntityId,
        }),
      },
      parentRevisionIds: [note.revision.revisionId],
    );
    final current = (await WorkspaceStore(
      repository,
    ).list()).singleWhere((n) => n.id == note.id);
    await expectLater(
      documents.resumePreparedEdition(
        current,
        descriptor: _jsonCopy(prepared.toRecoveryDescriptor()),
        files: prepared.copyRecoveryFiles(),
      ),
      throwsFormatException,
    );
    await expectLater(
      documents.resumePreparedEdition(
        note,
        descriptor: _jsonCopy(prepared.toRecoveryDescriptor()),
        files: prepared.copyRecoveryFiles(),
      ),
      throwsFormatException,
    );
    await expectLater(
      documents.resumeEditSession(
        note,
        descriptor: _jsonCopy(capturedSession.toRecoveryDescriptor()),
      ),
      throwsFormatException,
    );
    final forgedCurrent = VaultNote(
      note.id,
      note.title,
      note.inkEntityId,
      note.markdownEntityId,
      current.revision,
      documentKind: VaultDocumentKind.office,
      sourceEntityId: note.sourceEntityId,
    );
    await expectLater(
      documents.resumePreparedEdition(
        forgedCurrent,
        descriptor: _jsonCopy(prepared.toRecoveryDescriptor()),
        files: prepared.copyRecoveryFiles(),
      ),
      throwsFormatException,
    );
  });

  test(
    'missing, extra and tampered staged payloads reject before publication',
    () async {
      final prepared = await prepare();
      final descriptor = _jsonCopy(prepared.toRecoveryDescriptor());
      final original = prepared.copyRecoveryFiles();
      for (final name in ['lecture.docx', 'preview.pdf', 'edition.json']) {
        final missing = _copyFiles(original)..remove(name);
        await expectLater(
          documents.resumePreparedEdition(
            note,
            descriptor: descriptor,
            files: missing,
          ),
          throwsFormatException,
        );
        final changed = _copyFiles(original);
        changed[name]![0] ^= 1;
        await expectLater(
          documents.resumePreparedEdition(
            note,
            descriptor: descriptor,
            files: changed,
          ),
          throwsFormatException,
        );
      }
      await expectLater(
        documents.resumePreparedEdition(
          note,
          descriptor: descriptor,
          files: {
            ...original,
            'extra.bin': Uint8List.fromList([1]),
          },
        ),
        throwsFormatException,
      );
    },
  );

  test('matching core hashes do not bypass Office binding, package and PDF validation', () async {
    final prepared = await prepare();
    final originalDescriptor = _jsonCopy(prepared.toRecoveryDescriptor());
    final originalFiles = prepared.copyRecoveryFiles();
    final mutations =
        <void Function(Map<String, Uint8List>, Map<String, dynamic>)>[
          (files, metadata) => metadata['bindingId'] = 'not-a-uuid',
          (files, metadata) => metadata['sourceEntityId'] = newId(),
          (files, metadata) => metadata['originalSha256'] = '0' * 64,
          (files, metadata) => metadata['pdfSha256'] = '0' * 64,
          (files, metadata) => metadata['pageCount'] = 0,
          (files, metadata) => metadata['engineVersion'] = ' ',
          (files, metadata) {
            files['lecture.docx'] = Uint8List.fromList([1, 2, 3]);
            metadata['originalSha256'] = sha256
                .convert(files['lecture.docx']!)
                .toString();
          },
          (files, metadata) {
            files['preview.pdf'] = Uint8List.fromList(
              utf8.encode('%PDF-1.7\nmissing end'),
            );
            metadata['pdfSha256'] = sha256
                .convert(files['preview.pdf']!)
                .toString();
          },
          (files, metadata) => files['extra.bin'] = Uint8List.fromList([1]),
        ];
    for (final mutate in mutations) {
      final files = _copyFiles(originalFiles);
      final metadata = jsonObject(
        jsonDecode(utf8.decode(files['edition.json']!)),
      );
      mutate(files, metadata);
      files['edition.json'] = _jsonBytes(metadata);
      final token = repository.prepareCommit(
        entityId: note.sourceEntityId!,
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: files,
        parentRevisionIds: [base.revision.revisionId],
      );
      final descriptor = _jsonCopy(originalDescriptor)
        ..['prepared'] = token.toRecoveryDescriptor();
      await expectLater(
        documents.resumePreparedEdition(
          note,
          descriptor: descriptor,
          files: files,
        ),
        throwsFormatException,
      );
    }
  });

  for (final damage in ['malformed', 'different', 'missing', 'payload']) {
    test(
      'already published recovery refuses $damage actual immutable edition without repair',
      () async {
        final prepared = await prepare();
        await persist(prepared);
        final published = await documents.commitPreparedEdition(prepared);
        final target = damage == 'payload'
            ? File('${repository.root.path}/blobs/${published.pdfSha256}')
            : File(
                '${repository.root.path}/revisions/${published.revision.revisionId}.json',
              );
        if (damage == 'missing') {
          await target.delete();
        } else if (damage == 'different') {
          final actual = published.revision.toJson()..['deviceId'] = newId();
          await target.writeAsString(jsonEncode(actual), flush: true);
        } else {
          await target.writeAsString('{', flush: true);
        }
        final damaged = damage == 'missing' ? null : await target.readAsBytes();
        final manifestCount = await Directory(
          '${repository.root.path}/revisions',
        ).list().length;
        final stored = await load();
        Future<OfficeEdition> retry() async {
          final resumed = await documents.resumePreparedEdition(
            note,
            descriptor: stored.descriptor,
            files: stored.files,
          );
          return documents.commitPreparedEdition(resumed);
        }

        await expectLater(
          retry(),
          throwsA(anyOf(isA<FormatException>(), isA<FileSystemException>())),
        );
        if (damage == 'missing') {
          expect(target.existsSync(), isFalse);
        } else {
          expect(await target.readAsBytes(), damaged);
        }
        expect(
          await Directory('${repository.root.path}/revisions').list().length,
          manifestCount,
        );
        expect(
          (await repository.readFiles(base.revision))['preview.pdf'],
          base.pdfBytes,
        );
      },
    );
  }

  test('edit-session descriptor resumes captured source before a prepared token exists', () async {
    final captured = await documents.beginEdit(note);
    final descriptor = _jsonCopy(captured.toRecoveryDescriptor());
    expect(
      descriptor.keys,
      unorderedEquals([
        'version',
        'rootUri',
        'vaultId',
        'deviceId',
        'formatVersion',
        'noteId',
        'noteRevisionId',
        'sourceEntityId',
        'sourceRevisionId',
        'parentRevisionIds',
        'originalFileName',
        'originalSha256',
      ]),
    );
    final exported = _jsonCopy(captured.toRecoveryDescriptor());
    (exported['parentRevisionIds'] as List).clear();
    expect(captured.parentRevisionIds, [base.revision.revisionId]);
    await documents.commitEdited(
      await documents.beginEdit(note),
      originalBytes: officeFile('remote'),
      pdfBytes: syntheticPdf('remote'),
      engineVersion: 'fixture',
      pageCount: 1,
    );
    final metadata = jsonObject(
      jsonDecode(
        utf8.decode((await repository.readFiles(note.revision))['note.json']!),
      ),
    );
    await repository.commit(
      entityId: note.id,
      kind: EntityKind.metadata,
      files: {
        'note.json': _jsonBytes({...metadata, 'title': 'Renamed'}),
      },
      parentRevisionIds: [note.revision.revisionId],
    );
    await restart();
    final resumed = await documents.resumeEditSession(
      note,
      descriptor: descriptor,
    );
    expect(resumed.sourceRevision.revisionId, base.revision.revisionId);
    expect(resumed.parentRevisionIds, [base.revision.revisionId]);
    expect(resumed.originalBytes, officeFile('base'));
    expect(resumed.originalFileName, 'lecture.docx');
    expect(
      resumed.toRecoveryDescriptor()['noteRevisionId'],
      descriptor['noteRevisionId'],
    );
    final prepared = documents.prepareEdited(
      resumed,
      originalBytes: officeFile('recovered'),
      pdfBytes: syntheticPdf('recovered'),
      engineVersion: 'fixture',
      pageCount: 1,
    );
    final result = await documents.commitPreparedEdition(prepared);
    expect(result.revision.parentRevisionIds, [base.revision.revisionId]);
    expect(await repository.heads(note.sourceEntityId!), hasLength(2));
  });

  test('edit-session resume rejects damaged scope, history, filename and original binding', () async {
    final captured = await documents.beginEdit(note);
    final descriptor = _jsonCopy(captured.toRecoveryDescriptor());
    final mutations = <void Function(Map<String, dynamic>)>[
      (j) => j['extra'] = true,
      (j) => j.remove('noteRevisionId'),
      (j) =>
          j['rootUri'] = Directory('${directory.path}/foreign').absolute.uri
              .normalizePath()
              .toString(),
      (j) => j['vaultId'] = newId(),
      (j) => j['deviceId'] = newId(),
      (j) => j['formatVersion'] = 1,
      (j) => j['noteId'] = newId(),
      (j) => j['sourceEntityId'] = newId(),
      (j) => j['sourceRevisionId'] = base.revision.parentRevisionIds.single,
      (j) => j['parentRevisionIds'] = [],
      (j) => j['originalFileName'] = '../lecture.docx',
      (j) => j['originalSha256'] = '0' * 64,
    ];
    final count = (await repository.revisions()).length;
    for (final mutate in mutations) {
      final damaged = _jsonCopy(descriptor);
      mutate(damaged);
      await expectLater(
        documents.resumeEditSession(note, descriptor: damaged),
        throwsFormatException,
      );
    }
    expect((await repository.revisions()).length, count);
  });
  test('disk-only published edition retry rejoins the repository index without rewriting its manifest', () async {
    final prepared = await prepare(conditional: true);
    final descriptor = _jsonCopy(prepared.toRecoveryDescriptor());
    final files = prepared.copyRecoveryFiles();
    final planned = _planned(descriptor);
    final fault = _ManifestRenameLoss(planned.revisionId);
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(
        documents.commitPreparedEdition(prepared),
        throwsStateError,
      );
      expect(fault.lostResponse, isTrue);
      expect(
        (await repository.revisions()).any(
          (r) => r.revisionId == planned.revisionId,
        ),
        isFalse,
      );
      final manifest = File(
        '${repository.root.path}/revisions/${planned.revisionId}.json',
      );
      expect(manifest.existsSync(), isTrue);
      final bytes = await manifest.readAsBytes();
      final remote = await documents.commitEdited(
        await documents.beginEdit(note),
        originalBytes: officeFile('remote-after-rename'),
        pdfBytes: syntheticPdf('remote-after-rename'),
        engineVersion: 'fixture',
        pageCount: 1,
      );
      final resumed = await documents.resumePreparedEdition(
        note,
        descriptor: descriptor,
        files: files,
      );
      final edition = await documents.commitPreparedEdition(resumed);
      expect(edition.revision.revisionId, planned.revisionId);
      expect(
        (await repository.revisions()).where(
          (r) => r.revisionId == planned.revisionId,
        ),
        hasLength(1),
      );
      expect(
        (await repository.heads(note.sourceEntityId!)).map((r) => r.revisionId),
        unorderedEquals([planned.revisionId, remote.revision.revisionId]),
      );
      expect(
        (await documents.readLatest(
          note,
          revisionId: planned.revisionId,
        )).bindingId,
        edition.bindingId,
      );
      expect(await manifest.readAsBytes(), bytes);
      expect(
        fault.manifestRenames,
        1,
        reason: 'Acknowledgement must register the exact disk record without writing it again',
      );
      expect(
        (await repository.readFiles(base.revision))['preview.pdf'],
        base.pdfBytes,
      );
    }, fault);
  });
}

class _LostResponseRepository implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
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
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) =>
      inner.readFiles(record);
  @override
  Future<Uint8List> readRevisionFile(RevisionRecord record, String name) =>
      inner.readRevisionFile(record, name);
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
    await inner.commitPrepared(prepared);
    throw StateError('Published response lost');
  }

  @override
  Future<RevisionRecord> commitPreparedIfHeads(
    PreparedCommit prepared, {
    required Map<String, List<String>> expectedHeads,
    List<String>? expectedRevisionIds,
    void Function()? beforePublish,
    bool allowHistoricalParents = false,
  }) async {
    await inner.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      expectedRevisionIds: expectedRevisionIds,
      beforePublish: beforePublish,
      allowHistoricalParents: allowHistoricalParents,
    );
    throw StateError('Published response lost');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ManifestRenameLoss extends IOOverrides {
  new(this.revisionId);
  final String revisionId;
  var lostResponse = false;
  var manifestRenames = 0;
  @override
  File createFile(String path) {
    final inner = super.createFile(path);
    return path.endsWith('.tmp') ? _ManifestFaultFile(inner, this) : inner;
  }
}

class _ManifestFaultFile implements File {
  new(this.inner, this.fault);
  final File inner;
  final _ManifestRenameLoss fault;
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
    if (newPath.replaceAll(r'\', '/').endsWith('/${fault.revisionId}.json')) {
      fault.manifestRenames++;
      if (!fault.lostResponse) {
        fault.lostResponse = true;
        throw StateError(
          'Actual manifest rename succeeded but its response was lost',
        );
      }
    }
    return result;
  }

  @override
  Future<bool> exists() => Future.value(inner.existsSync());
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      inner.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
