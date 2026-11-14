import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_edit_recovery.dart';
import 'package:saber/data/vault/workspace_store.dart';

import 'annotation_store_test.dart' show annotationOfficeFile, annotationPdf;

void main() {
  late Directory temporary;
  late NoteRepository repository;
  late OfficeDocumentStore documents;
  late OfficeEditRecoveryStore recovery;
  late VaultNote note;
  late OfficeEditSession session;
  late String sessionId;
  late File working;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('office-edit-recovery-');
    await FileManager.init(
      documentsDirectory: '${temporary.path}/documents',
      shouldWatchRootDirectory: false,
    );
    repository = await NoteRepository.open(
      Directory('${temporary.path}/vault'),
      createFormatVersion: 2,
    );
    documents = OfficeDocumentStore(repository);
    recovery = OfficeEditRecoveryStore(repository);
    note = await documents.importDocument(
      title: 'Lecture',
      fileName: 'lecture.docx',
      bytes: annotationOfficeFile('original'),
    );
    session = await documents.beginEdit(note);
    sessionId = newId();
    working = FileManager.getFile(
      '/.working/office/${note.id}/${session.sourceRevision.revisionId}/$sessionId/original.docx',
    );
    await working.parent.create(recursive: true);
    await working.writeAsBytes(session.originalBytes, flush: true);
  });

  tearDown(() async {
    await repository.close();
    final path = await temporary.resolveSymbolicLinks();
    expect(
      path,
      startsWith(
        '${await Directory.systemTemp.resolveSymbolicLinks()}${Platform.pathSeparator}office-edit-recovery-',
      ),
    );
    await Directory(path).delete(recursive: true);
  });

  File receipt() => File(
    '${repository.root.path}/.workspace/office-recovery/${note.id}/$sessionId/receipt.json',
  );

  Future<OfficeEditRecoveryEntry> start() =>
      recovery.start(session, sessionId: sessionId, workingPath: working.path);

  Future<void> reopen() async {
    final root = repository.root;
    final noteId = note.id;
    await repository.close();
    repository = await NoteRepository.open(root);
    documents = OfficeDocumentStore(repository);
    recovery = OfficeEditRecoveryStore(repository);
    note = (await WorkspaceStore(repository).list(includeDeleted: true))
        .singleWhere((value) => value.id == noteId);
  }

  Future<AndroidOfficeEditResult> nativeResult({
    String label = 'edited',
  }) async {
    // The native editor owns a private folder outside the vault root.
    final directory = Directory('${temporary.path}/native/$sessionId');
    await directory.create(recursive: true);
    final original = annotationOfficeFile(label);
    final pdf = annotationPdf(label);
    final source = File('${directory.path}/edited.docx');
    final preview = File('${directory.path}/preview.pdf');
    await source.writeAsBytes(original, flush: true);
    await preview.writeAsBytes(pdf, flush: true);
    return AndroidOfficeEditResult(
      status: AndroidOfficeEditStatus.saved,
      engineVersion: 'fixture-engine',
      sessionId: sessionId,
      inputSourceSha256: sha256.convert(session.originalBytes).toString(),
      sourcePath: source.path,
      pdfPath: preview.path,
      sourceSha256: sha256.convert(original).toString(),
      pdfSha256: sha256.convert(pdf).toString(),
      pdfPageCount: 1,
    );
  }

  Future<OfficePreparedEdition> prepared({String label = 'edited'}) async {
    final restored = await recovery.read(note, sessionId);
    return documents.prepareEdited(
      restored.session,
      originalBytes: annotationOfficeFile(label),
      pdfBytes: annotationPdf(label),
      engineVersion: 'fixture-engine',
      pageCount: 1,
    );
  }

  test(
    'a fresh journal discovers the exact started session without publishing',
    () async {
      final count = (await repository.revisions()).length;
      final originalDescriptor = session.toRecoveryDescriptor();
      final originalWorking = working.path;
      final originalSourceRevision = session.sourceRevision.revisionId;
      final entry = await start();
      expect(entry.sessionId, sessionId);
      expect(entry.noteId, note.id);
      expect(entry.sourceRevisionId, originalSourceRevision);
      expect(entry.workingPath, originalWorking);
      expect(entry.stage, OfficeEditRecoveryStage.started);
      expect(entry.resumableStage, OfficeEditRecoveryStage.started);
      expect(receipt().existsSync(), isTrue);
      await reopen();
      final entries = await recovery.list(note);
      expect(entries, hasLength(1));
      expect(entries.single.stage, OfficeEditRecoveryStage.started);
      final restored = await recovery.read(note, sessionId);
      expect(restored.session.toRecoveryDescriptor(), originalDescriptor);
      expect(restored.nativeResult, isNull);
      expect(restored.preparedEdition, isNull);
      expect(
        await File(originalWorking).readAsBytes(),
        annotationOfficeFile('original'),
      );
      expect((await repository.revisions()).length, count);
    },
  );

  test('starting the same captured session is idempotent and never resets progress', () async {
    await start();
    await recovery.recordNativeSaved(note, sessionId, await nativeResult());
    final repeated = await start();
    expect(repeated.stage, OfficeEditRecoveryStage.nativeSaved);
    expect(await recovery.list(note), hasLength(1));
    final before = await receipt().readAsBytes();
    await expectLater(
      recovery.start(
        session,
        sessionId: sessionId,
        workingPath: '${working.path}.other',
      ),
      throwsA(isA<Exception>()),
    );
    expect(await receipt().readAsBytes(), before);
  });

  test(
    'native saved bytes survive removal of native output and old Dart state',
    () async {
      final count = (await repository.revisions()).length;
      await start();
      final result = await nativeResult();
      final saved = await recovery.recordNativeSaved(note, sessionId, result);
      expect(saved.stage, OfficeEditRecoveryStage.nativeSaved);
      expect(saved.sourcePath, isNot(result.sourcePath));
      expect(saved.pdfPath, isNot(result.pdfPath));
      await File(result.sourcePath!).delete();
      await File(result.pdfPath!).delete();
      await reopen();
      final restored = await recovery.read(note, sessionId);
      final recoveredResult = restored.nativeResult!;
      expect(recoveredResult.sessionId, sessionId);
      expect(recoveredResult.inputSourceSha256, result.inputSourceSha256);
      expect(
        await File(recoveredResult.sourcePath!).readAsBytes(),
        annotationOfficeFile('edited'),
      );
      expect(
        await File(recoveredResult.pdfPath!).readAsBytes(),
        annotationPdf('edited'),
      );
      expect(restored.preparedEdition, isNull);
      expect((await repository.revisions()).length, count);
      expect(working.existsSync(), isTrue);
    },
  );

  for (final alreadyPublished in [false, true]) {
    test(
      'prepared state recovers exact revision and binding ${alreadyPublished ? 'after lost publication response' : 'before publication'}',
      () async {
        await start();
        await recovery.recordNativeSaved(note, sessionId, await nativeResult());
        final token = await prepared();
        final captured = await recovery.recordPrepared(note, sessionId, token);
        final revisionId = captured.preparedRevisionId!;
        final bindingId = captured.bindingId!;
        final sourceRevisionId = session.sourceRevision.revisionId;
        if (alreadyPublished) {
          final published = await documents.commitPreparedEdition(token);
          expect(published.revision.revisionId, revisionId);
          expect(published.bindingId, bindingId);
        }
        await reopen();
        final before = (await repository.revisions()).length;
        final restored = await recovery.read(note, sessionId);
        expect(restored.entry.stage, OfficeEditRecoveryStage.prepared);
        expect(restored.preparedEdition, isNotNull);
        final edition = await documents.commitPreparedEdition(
          restored.preparedEdition!,
        );
        expect(edition.revision.revisionId, revisionId);
        expect(edition.bindingId, bindingId);
        expect(edition.revision.parentRevisionIds, [sourceRevisionId]);
        expect(edition.originalBytes, annotationOfficeFile('edited'));
        expect(edition.pdfBytes, annotationPdf('edited'));
        final complete = await recovery.complete(note, sessionId, edition);
        expect(complete.stage, OfficeEditRecoveryStage.completed);
        expect(
          (await repository.revisions()).length,
          before + (alreadyPublished ? 0 : 1),
        );
        await reopen();
        final completed = (await recovery.list(note)).single;
        expect(completed.stage, OfficeEditRecoveryStage.completed);
        expect(completed.preparedRevisionId, revisionId);
        expect(completed.bindingId, bindingId);
      },
    );
  }

  test('recovered Android branch publication retains captured parents and remote branch', () async {
    await start();
    await recovery.recordNativeSaved(note, sessionId, await nativeResult());
    final captured = await recovery.recordPrepared(
      note,
      sessionId,
      await prepared(),
    );
    final originalParent = session.sourceRevision.revisionId;
    final remote = await documents.commitEdited(
      session,
      originalBytes: annotationOfficeFile('remote'),
      pdfBytes: annotationPdf('remote'),
      engineVersion: 'remote-engine',
      pageCount: 1,
    );
    await reopen();
    final restored = await recovery.read(note, sessionId);
    final edition = await documents.commitPreparedEdition(
      restored.preparedEdition!,
    );
    expect(edition.revision.revisionId, captured.preparedRevisionId);
    expect(edition.revision.parentRevisionIds, [originalParent]);
    expect(
      (await repository.heads(note.sourceEntityId!)).map((r) => r.revisionId),
      unorderedEquals([
        remote.revision.revisionId,
        captured.preparedRevisionId,
      ]),
    );
    await recovery.complete(note, sessionId, edition);
    expect(
      (await recovery.list(note)).single.stage,
      OfficeEditRecoveryStage.completed,
    );
  });

  for (final preparedFirst in [false, true]) {
    test(
      'preserved ${preparedFirst ? 'prepared' : 'nativeSaved'} state stays discoverable with exportable bytes and no publication',
      () async {
        await start();
        await recovery.recordNativeSaved(note, sessionId, await nativeResult());
        if (preparedFirst) {
          await recovery.recordPrepared(note, sessionId, await prepared());
        }
        final count = (await repository.revisions()).length;
        final preserved = await recovery.preserve(note, sessionId);
        expect(preserved.stage, OfficeEditRecoveryStage.preserved);
        expect(
          preserved.resumableStage,
          preparedFirst
              ? OfficeEditRecoveryStage.prepared
              : OfficeEditRecoveryStage.nativeSaved,
        );
        await reopen();
        final candidate = (await recovery.list(note)).single;
        expect(candidate.stage, OfficeEditRecoveryStage.preserved);
        expect(
          await File(candidate.sourcePath!).readAsBytes(),
          annotationOfficeFile('edited'),
        );
        expect(
          await File(candidate.pdfPath!).readAsBytes(),
          annotationPdf('edited'),
        );
        final restored = await recovery.read(note, sessionId);
        expect(restored.preparedEdition != null, preparedFirst);
        expect((await repository.revisions()).length, count);
        expect(working.existsSync(), isTrue);
      },
    );
  }

  test(
    'a late native result preserves the user choice across a fresh restart',
    () async {
      await start();
      final retained = await recovery.preserve(note, sessionId);
      expect(retained.stage, OfficeEditRecoveryStage.preserved);
      expect(retained.resumableStage, OfficeEditRecoveryStage.started);
      final count = (await repository.revisions()).length;
      final result = await nativeResult();
      final saved = await recovery.recordNativeSaved(note, sessionId, result);
      expect(saved.stage, OfficeEditRecoveryStage.preserved);
      expect(saved.resumableStage, OfficeEditRecoveryStage.nativeSaved);
      final sourcePath = saved.sourcePath!;
      final pdfPath = saved.pdfPath!;
      final sourceBytes = await File(sourcePath).readAsBytes();
      final pdfBytes = await File(pdfPath).readAsBytes();
      expect(sourceBytes, annotationOfficeFile('edited'));
      expect(pdfBytes, annotationPdf('edited'));
      await reopen();
      final candidate = (await recovery.list(note)).single;
      expect(candidate.stage, OfficeEditRecoveryStage.preserved);
      expect(candidate.resumableStage, OfficeEditRecoveryStage.nativeSaved);
      expect(candidate.sourcePath, sourcePath);
      expect(candidate.pdfPath, pdfPath);
      final resumed = await recovery.read(note, sessionId);
      expect(resumed.entry.stage, OfficeEditRecoveryStage.preserved);
      expect(resumed.nativeResult!.sourceSha256, result.sourceSha256);
      expect(resumed.nativeResult!.pdfSha256, result.pdfSha256);
      expect(resumed.preparedEdition, isNull);
      expect(await File(sourcePath).readAsBytes(), sourceBytes);
      expect(await File(pdfPath).readAsBytes(), pdfBytes);
      expect(File(result.sourcePath!).existsSync(), isTrue);
      expect(File(result.pdfPath!).existsSync(), isTrue);
      expect(await working.readAsBytes(), annotationOfficeFile('original'));
      expect((await repository.revisions()).length, count);
    },
  );

  final invalidNative =
      <String, Map<String, Object?> Function(AndroidOfficeEditResult)>{
        'wrong session': (_) => {'sessionId': newId()},
        'missing input binding': (_) => {'inputSourceSha256': null},
        'foreign input binding': (_) => {'inputSourceSha256': '0' * 64},
        'bad original hash': (_) => {'sourceSha256': '0' * 64},
        'bad PDF hash': (_) => {'pdfSha256': '0' * 64},
        'missing engine identity': (_) => {'engineVersion': ''},
        'invalid page count': (_) => {'pdfPageCount': 0},
        'same output paths': (r) => {'pdfPath': r.sourcePath},
        'input used as output': (_) => {'sourcePath': working.path},
        'relative output': (_) => {'sourcePath': 'edited.docx'},
        'wrong original basename': (r) => {
          'sourcePath': '${File(r.sourcePath!).parent.path}/other.docx',
        },
        'wrong PDF basename': (r) => {
          'pdfPath': '${File(r.pdfPath!).parent.path}/other.pdf',
        },
        'different output parents': (_) => {
          'pdfPath': '${temporary.path}/other/preview.pdf',
        },
      };
  for (final entry in invalidNative.entries) {
    test(
      'native snapshot rejects ${entry.key} and keeps started record',
      () async {
        await start();
        final result = await nativeResult();
        final fields = <String, Object?>{
          'sessionId': result.sessionId,
          'inputSourceSha256': result.inputSourceSha256,
          'sourcePath': result.sourcePath,
          'pdfPath': result.pdfPath,
          'sourceSha256': result.sourceSha256,
          'pdfSha256': result.pdfSha256,
          'engineVersion': result.engineVersion,
          'pdfPageCount': result.pdfPageCount,
          ...entry.value(result),
        };
        final invalid = AndroidOfficeEditResult(
          status: AndroidOfficeEditStatus.saved,
          sessionId: fields['sessionId'] as String?,
          inputSourceSha256: fields['inputSourceSha256'] as String?,
          sourcePath: fields['sourcePath'] as String?,
          pdfPath: fields['pdfPath'] as String?,
          sourceSha256: fields['sourceSha256'] as String?,
          pdfSha256: fields['pdfSha256'] as String?,
          engineVersion: fields['engineVersion'] as String,
          pdfPageCount: fields['pdfPageCount'] as int?,
        );
        await expectLater(
          recovery.recordNativeSaved(note, sessionId, invalid),
          throwsFormatException,
        );
        expect(
          (await recovery.list(note)).single.stage,
          OfficeEditRecoveryStage.started,
        );
        expect(File(result.sourcePath!).existsSync(), isTrue);
        expect(File(result.pdfPath!).existsSync(), isTrue);
      },
    );
  }

  test('a different prepared payload cannot replace the native snapshot or captured identity', () async {
    await start();
    await recovery.recordNativeSaved(note, sessionId, await nativeResult());
    await expectLater(
      recovery.recordPrepared(
        note,
        sessionId,
        await prepared(label: 'different'),
      ),
      throwsFormatException,
    );
    final first = await prepared();
    final entry = await recovery.recordPrepared(note, sessionId, first);
    await expectLater(
      recovery.recordPrepared(note, sessionId, await prepared()),
      throwsFormatException,
    );
    expect(
      (await recovery.list(note)).single.preparedRevisionId,
      entry.preparedRevisionId,
    );
  });

  test('Android recovery cannot persist a conditional policy or prepare before native validation', () async {
    await start();
    final token = await prepared();
    await expectLater(
      recovery.recordPrepared(note, sessionId, token),
      throwsStateError,
    );
    await recovery.recordNativeSaved(note, sessionId, await nativeResult());
    final conditional = documents.prepareEdited(
      session,
      originalBytes: annotationOfficeFile('edited'),
      pdfBytes: annotationPdf('edited'),
      engineVersion: 'fixture-engine',
      pageCount: 1,
      requireCurrentHeads: true,
    );
    await expectLater(
      recovery.recordPrepared(note, sessionId, conditional),
      throwsFormatException,
    );
    expect(
      (await recovery.list(note)).single.stage,
      OfficeEditRecoveryStage.nativeSaved,
    );
  });

  test(
    'oversized native output is rejected before snapshot receipt promotion',
    () async {
      await start();
      final result = await nativeResult();
      final file = await File(result.sourcePath!).open(mode: FileMode.write);
      try {
        await file.truncate(128 * 1024 * 1024 + 1);
      } finally {
        await file.close();
      }
      await expectLater(
        recovery.recordNativeSaved(note, sessionId, result),
        throwsFormatException,
      );
      expect(
        (await recovery.list(note)).single.stage,
        OfficeEditRecoveryStage.started,
      );
    },
  );

  test(
    'completion requires exact actual publication and rejects damaged manifest',
    () async {
      await start();
      await recovery.recordNativeSaved(note, sessionId, await nativeResult());
      final token = await prepared();
      final entry = await recovery.recordPrepared(note, sessionId, token);
      final unrelated = await documents.readLatest(note);
      await expectLater(
        recovery.complete(note, sessionId, unrelated),
        throwsFormatException,
      );
      expect(
        (await recovery.list(note)).single.stage,
        OfficeEditRecoveryStage.prepared,
      );
      final edition = await documents.commitPreparedEdition(token);
      final manifest = File(
        '${repository.root.path}/revisions/${entry.preparedRevisionId}.json',
      );
      final original = await manifest.readAsBytes();
      await manifest.writeAsString('{', flush: true);
      await expectLater(
        recovery.complete(note, sessionId, edition),
        throwsFormatException,
      );
      expect(
        (await recovery.list(note)).single.stage,
        OfficeEditRecoveryStage.prepared,
      );
      expect(await manifest.readAsString(), '{');
      await manifest.writeAsBytes(original, flush: true);
      expect(
        (await recovery.complete(note, sessionId, edition)).stage,
        OfficeEditRecoveryStage.completed,
      );
    },
  );

  test('missing or corrupt journal payload blocks resumption without changing the vault', () async {
    await start();
    final native = await recovery.recordNativeSaved(
      note,
      sessionId,
      await nativeResult(),
    );
    final count = (await repository.revisions()).length;
    await File(native.sourcePath!).writeAsString('corrupt', flush: true);
    await expectLater(recovery.read(note, sessionId), throwsFormatException);
    expect((await repository.revisions()).length, count);
    expect(
      (await documents.readLatest(note)).originalBytes,
      annotationOfficeFile('original'),
    );
  });

  test('receipt version or captured root tampering cannot be resumed', () async {
    await start();
    final file = receipt();
    final original = await file.readAsString();
    final changed = jsonObject(jsonDecode(original));
    changed['version'] = 2;
    await file.writeAsString(jsonEncode(changed), flush: true);
    await expectLater(recovery.read(note, sessionId), throwsFormatException);
    await file.writeAsString(original, flush: true);
    final clone = await NoteRepository.open(
      Directory('${temporary.path}/clone'),
      vaultId: repository.vaultId,
      deviceId: repository.deviceId,
      createFormatVersion: 2,
    );
    try {
      final foreignReceipt = File(
        '${clone.root.path}/.workspace/office-recovery/${note.id}/$sessionId/receipt.json',
      );
      await foreignReceipt.parent.create(recursive: true);
      await foreignReceipt.writeAsString(original, flush: true);
      await expectLater(
        OfficeEditRecoveryStore(clone).read(note, sessionId),
        throwsFormatException,
      );
    } finally {
      await clone.close();
    }
  });

  test('another note cannot read or overwrite this recovery session', () async {
    await start();
    final other = await documents.importDocument(
      title: 'Other',
      fileName: 'other.docx',
      bytes: annotationOfficeFile('other'),
    );
    expect(await recovery.list(other), isEmpty);
    await expectLater(
      recovery.read(other, sessionId),
      throwsA(isA<Exception>()),
    );
    expect((await recovery.list(note)).single.sessionId, sessionId);
  });

  test('failed receipt promotion leaves a complete started record and allows exact retry', () async {
    await start();
    final result = await nativeResult();
    final original = await receipt().readAsBytes();
    final fault = _ReceiptRenameFault(receipt().path);
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(
        recovery.recordNativeSaved(note, sessionId, result),
        throwsStateError,
      );
    }, fault);
    expect(fault.intercepted, isTrue);
    expect(await receipt().readAsBytes(), original);
    recovery = OfficeEditRecoveryStore(repository);
    expect(
      (await recovery.list(note)).single.stage,
      OfficeEditRecoveryStage.started,
    );
    final saved = await recovery.recordNativeSaved(note, sessionId, result);
    expect(saved.stage, OfficeEditRecoveryStage.nativeSaved);
    expect(File(result.sourcePath!).existsSync(), isTrue);
    expect(working.existsSync(), isTrue);
  });

  test('orphan prepared metadata cannot block a new plan after receipt promotion failure and restart', () async {
    await start();
    await recovery.recordNativeSaved(note, sessionId, await nativeResult());
    final first = await prepared();
    final firstDescriptor = jsonObject(first.toRecoveryDescriptor());
    final firstId = jsonObject(
      jsonObject(firstDescriptor['prepared'])['record'],
    )['revisionId'];
    final originalReceipt = await receipt().readAsBytes();
    final count = (await repository.revisions()).length;
    final fault = _ReceiptRenameFault(receipt().path);
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(
        recovery.recordPrepared(note, sessionId, first),
        throwsStateError,
      );
    }, fault);
    expect(fault.intercepted, isTrue);
    expect(await receipt().readAsBytes(), originalReceipt);
    final orphanMetadata = <String, List<int>>{};
    await for (final file in receipt().parent.list(
      recursive: true,
      followLinks: false,
    )) {
      if (file is File && p.basename(file.path) == 'edition.json') {
        orphanMetadata[file.path] = await file.readAsBytes();
      }
    }
    expect(orphanMetadata, hasLength(1));
    await reopen();
    final interrupted = await recovery.read(note, sessionId);
    expect(interrupted.entry.stage, OfficeEditRecoveryStage.nativeSaved);
    expect(interrupted.preparedEdition, isNull);
    final next = await prepared();
    final descriptor = jsonObject(next.toRecoveryDescriptor());
    final nextId = jsonObject(
      jsonObject(descriptor['prepared'])['record'],
    )['revisionId'];
    expect(nextId, isNot(firstId));
    final entry = await recovery.recordPrepared(note, sessionId, next);
    expect(entry.preparedRevisionId, nextId);
    expect(entry.stage, OfficeEditRecoveryStage.prepared);
    expect((await repository.revisions()).length, count);
    for (final orphan in orphanMetadata.entries) {
      expect(await File(orphan.key).readAsBytes(), orphan.value);
    }
    expect(
      await File(entry.sourcePath!).readAsBytes(),
      annotationOfficeFile('edited'),
    );
    expect(await File(entry.pdfPath!).readAsBytes(), annotationPdf('edited'));
    expect(await working.readAsBytes(), annotationOfficeFile('original'));
    await reopen();
    final resumed = await recovery.read(note, sessionId);
    expect(resumed.entry.preparedRevisionId, nextId);
    final edition = await documents.commitPreparedEdition(
      resumed.preparedEdition!,
    );
    expect(edition.revision.revisionId, nextId);
    expect(edition.bindingId, entry.bindingId);
    await recovery.complete(note, sessionId, edition);
  });

  test('prepared receipt rename response loss recovers its first immutable plan after restart', () async {
    await start();
    await recovery.recordNativeSaved(note, sessionId, await nativeResult());
    final first = await prepared();
    final descriptor = jsonObject(first.toRecoveryDescriptor());
    final firstId = jsonObject(
      jsonObject(descriptor['prepared'])['record'],
    )['revisionId'];
    final firstBinding = jsonObject(
      jsonDecode(utf8.decode(first.copyRecoveryFiles()['edition.json']!)),
    )['bindingId'];
    final count = (await repository.revisions()).length;
    final fault = _ReceiptRenameFault(receipt().path, afterRename: true);
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(
        recovery.recordPrepared(note, sessionId, first),
        throwsStateError,
      );
    }, fault);
    expect(fault.intercepted, isTrue);
    await reopen();
    final resumed = await recovery.read(note, sessionId);
    expect(resumed.entry.stage, OfficeEditRecoveryStage.prepared);
    expect(resumed.entry.preparedRevisionId, firstId);
    expect(resumed.entry.bindingId, firstBinding);
    expect((await repository.revisions()).length, count);
    final edition = await documents.commitPreparedEdition(
      resumed.preparedEdition!,
    );
    expect(edition.revision.revisionId, firstId);
    expect(edition.bindingId, firstBinding);
    await recovery.complete(note, sessionId, edition);
  });

  test('late native results remain discoverable after actual metadata source repoint without exposing a writable session', () async {
    await start();
    final capturedNote = note;
    final oldSourceId = session.sourceEntityId;
    final result = await nativeResult();
    final replacementId = newId();
    final replacement = await repository.commit(
      entityId: replacementId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {'lecture.docx': annotationOfficeFile('replacement')},
      parentRevisionIds: [],
    );
    await repository.commit(
      entityId: note.id,
      kind: EntityKind.metadata,
      files: {
        'note.json': Uint8List.fromList(
          utf8.encode(
            jsonEncode({...note.json, 'sourceEntityId': replacementId}),
          ),
        ),
      },
      parentRevisionIds: [note.revision.revisionId],
    );
    final count = (await repository.revisions()).length;
    final retained = await recovery.recordNativeSaved(
      capturedNote,
      sessionId,
      result,
    );
    expect(retained.stage, OfficeEditRecoveryStage.nativeSaved);
    expect(
      await File(retained.sourcePath!).readAsBytes(),
      annotationOfficeFile('edited'),
    );
    expect(
      await File(retained.pdfPath!).readAsBytes(),
      annotationPdf('edited'),
    );
    await reopen();
    expect(note.sourceEntityId, replacementId);
    final entries = await recovery.list(note);
    expect(entries, hasLength(1));
    expect(entries.single.sessionId, sessionId);
    expect(entries.single.canResume, isFalse);
    expect(
      await File(entries.single.sourcePath!).readAsBytes(),
      annotationOfficeFile('edited'),
    );
    expect(
      await File(entries.single.pdfPath!).readAsBytes(),
      annotationPdf('edited'),
    );
    await expectLater(recovery.read(note, sessionId), throwsFormatException);
    final preserved = await recovery.preserve(note, sessionId);
    expect(preserved.stage, OfficeEditRecoveryStage.preserved);
    await reopen();
    expect(
      (await recovery.list(note)).single.stage,
      OfficeEditRecoveryStage.preserved,
    );
    expect(
      (await documents.readLatest(note)).revision.revisionId,
      replacement.revisionId,
    );
    expect(
      (await repository.heads(oldSourceId)).single.revisionId,
      session.sourceRevision.revisionId,
    );
    expect((await repository.revisions()).length, count);
    expect(await working.readAsBytes(), annotationOfficeFile('original'));
  });

  for (final field in ['engineVersion', 'pageCount']) {
    test(
      'prepared metadata cannot replace native $field while reusing identical source and PDF bytes',
      () async {
        await start();
        await recovery.recordNativeSaved(note, sessionId, await nativeResult());
        final restored = await recovery.read(note, sessionId);
        final token = documents.prepareEdited(
          restored.session,
          originalBytes: annotationOfficeFile('edited'),
          pdfBytes: annotationPdf('edited'),
          engineVersion: field == 'engineVersion'
              ? 'different-engine'
              : 'fixture-engine',
          pageCount: field == 'pageCount' ? 2 : 1,
        );
        final count = (await repository.revisions()).length;
        await expectLater(
          recovery.recordPrepared(note, sessionId, token),
          throwsFormatException,
        );
        expect(
          (await recovery.list(note)).single.stage,
          OfficeEditRecoveryStage.nativeSaved,
        );
        expect((await repository.revisions()).length, count);
      },
    );
  }
}

final class _ReceiptRenameFault extends IOOverrides {
  new(this.receiptPath, {this.afterRename = false});
  final String receiptPath;
  final bool afterRename;
  var intercepted = false;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('.pending') || path.endsWith('.tmp')
        ? _ReceiptFaultFile(file, this)
        : file;
  }
}

class _ReceiptFaultFile implements File {
  new(this.inner, this.fault);
  final File inner;
  final _ReceiptRenameFault fault;

  @override
  String get path => inner.path;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => inner.writeAsBytes(bytes, mode: mode, flush: flush);

  @override
  Future<File> rename(String target) async {
    if (!fault.intercepted &&
        p.equals(p.normalize(target), p.normalize(fault.receiptPath))) {
      fault.intercepted = true;
      if (fault.afterRename) await inner.rename(target);
      throw StateError('Synthetic receipt promotion failure');
    }
    return inner.rename(target);
  }

  @override
  Future<bool> exists() async => inner.existsSync();

  @override
  bool existsSync() => inner.existsSync();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      inner.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
