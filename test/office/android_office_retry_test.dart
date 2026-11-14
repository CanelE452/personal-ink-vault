import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_edit_recovery.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/office/office_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';
import 'annotation_store_test.dart' show annotationOfficeFile, annotationPdf;
import 'office_workspace_test.dart' show FixtureOfficeEngine;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late NoteRepository repository;
  late OfficeDocumentStore documents;
  late VaultNote note;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('android-office-retry-');
    await FileManager.init(
      documentsDirectory: '${temp.path}/documents',
      shouldWatchRootDirectory: false,
    );
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    documents = OfficeDocumentStore(repository);
    note = await documents.importDocument(
      title: 'Lecture',
      fileName: 'lecture.docx',
      bytes: annotationOfficeFile('original'),
    );
  });
  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    final elapsed = Stopwatch()..start();
    while (!ready() && elapsed.elapsed < const Duration(seconds: 15)) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
      await tester.pump(const Duration(milliseconds: 15));
    }
    expect(
      ready(),
      isTrue,
      reason:
          'Office repository I/O must finish. Visible text: '
          '${tester.widgetList<Text>(find.byType(Text)).map((text) => text.data).whereType<String>().join(" | ")}',
    );
  }

  Future<void> waitForOperation(
    WidgetTester tester,
    Future<void> Function() operation,
  ) async {
    var completed = false;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      operation().then<void>(
        (_) {
          completed = true;
        },
        onError: (Object error, StackTrace stack) {
          failure = error;
          trace = stack;
          completed = true;
        },
      );
    });
    await waitFor(tester, () => completed);
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  }

  Future<void> withRecoveryWidget(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    try {
      await body();
    } finally {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      Object? error;
      await tester.runAsync(() async {
        repository.close().then(
          (_) => closed = true,
          onError: (Object e) {
            error = e;
            closed = true;
          },
        );
      });
      await waitFor(tester, () => closed);
      if (error != null) throw error!;
    }
  }

  test('a prepared Office edition freezes bytes and retries its published binding after reopen', () async {
    final guarded = _ResponseLossRepository(repository, failBefore: false);
    final store = OfficeDocumentStore(guarded);
    final original = annotationOfficeFile('edited');
    final pdf = annotationPdf('edited');
    final prepared = store.prepareEdited(
      await store.beginEdit(note),
      originalBytes: original,
      pdfBytes: pdf,
      engineVersion: 'fixture',
      pageCount: 1,
    );
    original.fillRange(0, original.length, 0);
    pdf.fillRange(0, pdf.length, 0);
    await expectLater(store.commitPreparedEdition(prepared), throwsStateError);
    final published = await documents.readLatest(note);
    expect(published.originalBytes, annotationOfficeFile('edited'));
    expect(published.pdfBytes, annotationPdf('edited'));
    await repository.close();
    repository = await NoteRepository.open(Directory('${temp.path}/vault'));
    documents = OfficeDocumentStore(repository);
    final retried = await documents.commitPreparedEdition(prepared);
    expect(retried.revision.revisionId, published.revision.revisionId);
    expect(retried.bindingId, published.bindingId);
    expect(retried.originalBytes, annotationOfficeFile('edited'));
    expect(retried.pdfBytes, annotationPdf('edited'));
    expect(await documents.readEditions(note), hasLength(2));
  });

  test('a clone cannot publish a prepared edition or reuse the source edit session', () async {
    final session = await documents.beginEdit(note);
    final prepared = documents.prepareEdited(
      session,
      originalBytes: annotationOfficeFile('private'),
      pdfBytes: annotationPdf('private'),
      engineVersion: 'fixture',
      pageCount: 1,
    );
    final clone = await NoteRepository.open(
      Directory('${temp.path}/clone'),
      vaultId: repository.vaultId,
      deviceId: repository.deviceId,
      createFormatVersion: repository.formatVersion,
    );
    try {
      final foreign = OfficeDocumentStore(clone);
      await expectLater(
        foreign.commitPreparedEdition(prepared),
        throwsFormatException,
      );
      expect(
        () => foreign.prepareEdited(
          session,
          originalBytes: annotationOfficeFile('private'),
          pdfBytes: annotationPdf('private'),
          engineVersion: 'fixture',
          pageCount: 1,
        ),
        throwsFormatException,
      );
      expect(await clone.revisions(), isEmpty);
      expect(await Directory('${clone.root.path}/blobs').list().length, 0);
    } finally {
      await clone.close();
    }
    final edition = await documents.commitPreparedEdition(prepared);
    expect(edition.revision.ownerNoteId, note.id);
  });

  test('a conditional prepared retry reuses its head and rechecks captured permission', () async {
    final guarded = _ResponseLossRepository(repository, failBefore: false);
    final store = OfficeDocumentStore(guarded);
    var allowed = true;
    var checks = 0;
    final prepared = store.prepareEdited(
      await store.beginEdit(note),
      originalBytes: annotationOfficeFile('edited'),
      pdfBytes: annotationPdf('edited'),
      engineVersion: 'fixture',
      pageCount: 1,
      requireCurrentHeads: true,
      beforePublish: () {
        checks++;
        if (!allowed) throw StateError('Editing permission was revoked');
      },
    );
    await expectLater(store.commitPreparedEdition(prepared), throwsStateError);
    final published = await documents.readLatest(note);
    final originalChecks = checks;
    allowed = false;
    await expectLater(store.commitPreparedEdition(prepared), throwsStateError);
    expect(checks, greaterThan(originalChecks));
    allowed = true;
    final retried = await store.commitPreparedEdition(prepared);
    expect(retried.revision.revisionId, published.revision.revisionId);
    expect(retried.bindingId, published.bindingId);
    expect(await documents.readEditions(note), hasLength(2));
  });

  test(
    'a conditional prepared retry does not merge a later remote source head',
    () async {
      final session = await documents.beginEdit(note);
      final guarded = _ResponseLossRepository(repository, failBefore: true);
      final store = OfficeDocumentStore(guarded);
      final prepared = store.prepareEdited(
        session,
        originalBytes: annotationOfficeFile('edited'),
        pdfBytes: annotationPdf('edited'),
        engineVersion: 'fixture',
        pageCount: 1,
        requireCurrentHeads: true,
      );
      await expectLater(
        store.commitPreparedEdition(prepared),
        throwsStateError,
      );
      final remote = await documents.commitEdited(
        session,
        originalBytes: annotationOfficeFile('remote'),
        pdfBytes: annotationPdf('remote'),
        engineVersion: 'remote-fixture',
        pageCount: 1,
      );
      await expectLater(
        store.commitPreparedEdition(prepared),
        throwsStateError,
      );
      expect(
        (await repository.heads(note.sourceEntityId!)).single.revisionId,
        remote.revision.revisionId,
      );
      expect(await documents.readEditions(note), hasLength(2));
    },
  );

  for (final failBefore in [false, true]) {
    testWidgets(
      'Android save retry keeps its exact edition after ${failBefore ? 'pre-publication failure' : 'a lost publication response'}',
      (tester) async {
        final previous = (await tester.runAsync(
          () async => documents.commitEdited(
            await documents.beginEdit(note),
            originalBytes: annotationOfficeFile('previous'),
            pdfBytes: annotationPdf('previous'),
            engineVersion: 'fixture',
            pageCount: 1,
          ),
        ))!;
        final oldInk = (await tester.runAsync(() async {
          final annotations = await OfficeAnnotationStore(repository)
              .open(note, previous);
          return annotations.saveFiles({
            'main.sbn2': Uint8List.fromList([1, 2, 3]),
          });
        }))!;
        final captured = (await tester.runAsync(
          () => documents.beginEdit(note),
        ))!;
        final guarded = _ResponseLossRepository(
          repository,
          failBefore: failBefore,
        );
        var edits = 0;
        late File outputSource;
        late File outputPdf;
        final engine = FixtureOfficeEngine(
          onEdit: (input, id) async {
            edits++;
            expect(await File(input).readAsBytes(), previous.originalBytes);
            final output = Directory('${temp.path}/native/$id');
            await output.create(recursive: true);
            outputSource = File('${output.path}/edited.docx');
            outputPdf = File('${output.path}/preview.pdf');
            final original = annotationOfficeFile('edited');
            final pdf = annotationPdf('edited');
            await outputSource.writeAsBytes(original);
            await outputPdf.writeAsBytes(pdf);
            return AndroidOfficeEditResult(
              status: AndroidOfficeEditStatus.saved,
              engineVersion: 'fixture-engine',
              sessionId: id,
              sourcePath: outputSource.path,
              pdfPath: outputPdf.path,
              sourceSha256: sha256.convert(original).toString(),
              pdfSha256: sha256.convert(pdf).toString(),
              pdfPageCount: 1,
            );
          },
        );
        final key = GlobalKey<OfficeWorkspaceState>();
        final dirty = <bool>[];
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: OfficeWorkspace(
                  key: key,
                  repository: guarded,
                  note: note,
                  engine: engine,
                  onDirtyChanged: dirty.add,
                  onBack: () {},
                ),
              ),
            ),
          ),
        );
        addTearDown(() async {
          final state = key.currentState;
          await tester.pumpWidget(const SizedBox());
          try {
            if (state != null) {
              try {
                await waitForOperation(tester, state.save);
              } on StateError catch (error) {
                if (error.message != 'Synthetic failure before publication' &&
                    error.message !=
                        'Synthetic response lost after publication') {
                  rethrow;
                }
              }
            }
          } finally {
            await waitForOperation(tester, repository.close);
          }
        });
        await waitFor(
          tester,
          () => find
              .byKey(const ValueKey('office-edit-original'))
              .evaluate()
              .isNotEmpty,
        );
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const ValueKey('office-edit-original')));
        });
        await waitFor(tester, () => find.text('저장 재시도').evaluate().isNotEmpty);
        final attempted = guarded.attempted.single;
        expect(dirty.last, isTrue);
        expect(await tester.runAsync(outputSource.exists), isTrue);
        expect(await tester.runAsync(outputPdf.exists), isTrue);
        if (failBefore) {
          expect(guarded.published, isEmpty);
        } else {
          expect(guarded.published.single.revisionId, attempted.revisionId);
        }

        final remote = (await tester.runAsync(
          () => documents.commitEdited(
            captured,
            originalBytes: annotationOfficeFile('remote'),
            pdfBytes: annotationPdf('remote'),
            engineVersion: 'remote-fixture',
            pageCount: 1,
          ),
        ))!;
        await tester.runAsync(() async {
          await tester.tap(find.text('저장 재시도'));
        });
        await waitFor(
          tester,
          () => find.text('원본과 PDF를 저장했습니다.').evaluate().isNotEmpty,
        );
        expect(edits, 1, reason: 'Retry must retain the native editor result');
        expect(guarded.attempted.map((record) => record.revisionId).toSet(), {
          attempted.revisionId,
        }, reason: 'A retry must reuse the prepared publication identity');
        final heads = (await tester.runAsync(
          () => repository.heads(note.sourceEntityId!),
        ))!;
        expect(
          heads.map((record) => record.revisionId),
          unorderedEquals([attempted.revisionId, remote.revision.revisionId]),
          reason: 'Retry preserves the separately published remote branch',
        );
        final saved = (await tester.runAsync(
          () => documents.readLatest(note, revisionId: attempted.revisionId),
        ))!;
        expect(saved.revision.parentRevisionIds, [
          previous.revision.revisionId,
        ]);
        expect(saved.originalBytes, annotationOfficeFile('edited'));
        expect(saved.pdfBytes, annotationPdf('edited'));
        expect(saved.bindingId, isNot(previous.bindingId));
        expect(dirty.last, isFalse);
        expect(
          (await tester.runAsync(() => documents.readEditions(note)))!,
          hasLength(4),
        );
        expect(
          (await tester.runAsync(() => repository.heads(previous.bindingId!)))!
              .single
              .revisionId,
          oldInk.revisionId,
        );
        expect(
          (await tester.runAsync(
            () => repository.readFiles(previous.revision),
          ))!['preview.pdf'],
          previous.pdfBytes,
        );
      },
    );
  }
  for (final width in [320.0, 1000.0]) {
    testWidgets(
      'fresh Office screen restores an exact durable prepared candidate at $width px',
      (tester) => withRecoveryWidget(tester, () async {
        await tester.binding.setSurfaceSize(Size(width, 820));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final staged = (await tester.runAsync(() async {
          final session = await documents.beginEdit(note);
          final id = newId();
          final working = FileManager.getFile(
            '/.working/office/${note.id}/${session.sourceRevision.revisionId}/$id/original.docx',
          );
          await working.parent.create(recursive: true);
          await working.writeAsBytes(session.originalBytes, flush: true);
          final journal = OfficeEditRecoveryStore(repository);
          await journal.start(
            session,
            sessionId: id,
            workingPath: working.path,
          );
          final outputs = Directory('${temp.path}/native/$id');
          await outputs.create(recursive: true);
          final original = annotationOfficeFile('recovered');
          final pdf = annotationPdf('recovered');
          final sourceFile = await File('${outputs.path}/edited.docx')
              .writeAsBytes(original, flush: true);
          final pdfFile = await File('${outputs.path}/preview.pdf')
              .writeAsBytes(pdf, flush: true);
          await journal.recordNativeSaved(
            note,
            id,
            AndroidOfficeEditResult(
              status: AndroidOfficeEditStatus.saved,
              engineVersion: 'fixture-engine',
              sessionId: id,
              inputSourceSha256: sha256
                  .convert(session.originalBytes)
                  .toString(),
              sourcePath: sourceFile.path,
              pdfPath: pdfFile.path,
              sourceSha256: sha256.convert(original).toString(),
              pdfSha256: sha256.convert(pdf).toString(),
              pdfPageCount: 1,
            ),
          );
          final prepared = documents.prepareEdited(
            session,
            originalBytes: original,
            pdfBytes: pdf,
            engineVersion: 'fixture-engine',
            pageCount: 1,
          );
          final entry = await journal.recordPrepared(note, id, prepared);
          await repository.close();
          repository = await NoteRepository.open(
            Directory('${temp.path}/vault'),
          );
          documents = OfficeDocumentStore(repository);
          note = (await WorkspaceStore(repository).list()).single;
          return (
            id,
            entry.preparedRevisionId!,
            entry.bindingId!,
            (await repository.revisions()).length,
          );
        }))!;
        final (id, plannedRevision, bindingId, beforeCount) = staged;
        var backs = 0, edits = 0;
        final engine = FixtureOfficeEngine(
          onEdit: (_, _) async {
            edits++;
            throw StateError(
              'A frozen prepared result must not rerun native editing',
            );
          },
        );
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: OfficeWorkspace(
                  repository: repository,
                  note: note,
                  engine: engine,
                  onBack: () => backs++,
                ),
              ),
            ),
          ),
        );
        await waitFor(
          tester,
          () =>
              find.byKey(ValueKey('office-recovery-$id')).evaluate().isNotEmpty,
        );
        expect(
          (await tester.runAsync(() => repository.revisions()))!.length,
          beforeCount,
        );
        await tester.tap(find.byTooltip('문서 목록으로'));
        await waitFor(tester, () => backs == 1);
        expect(
          (await tester.runAsync(() => repository.revisions()))!.length,
          beforeCount,
        );
        final save = find.byKey(ValueKey('office-recovery-save-$id'));
        await tester.ensureVisible(save);
        await tester.runAsync(() async {
          await tester.tap(save);
        });
        await waitFor(
          tester,
          () =>
              find.byKey(ValueKey('office-recovery-$id')).evaluate().isEmpty &&
              find.text('원본과 PDF를 저장했습니다.').evaluate().isNotEmpty,
        );
        final restored = (await tester.runAsync(
          () => documents.readLatest(note),
        ))!;
        expect(restored.revision.revisionId, plannedRevision);
        expect(restored.bindingId, bindingId);
        expect(restored.originalBytes, annotationOfficeFile('recovered'));
        expect(restored.pdfBytes, annotationPdf('recovered'));
        expect(
          (await tester.runAsync(() => repository.revisions()))!.length,
          beforeCount + 1,
        );
        expect(edits, 0);
        await tester.pumpWidget(const SizedBox());
      }),
    );
  }

  testWidgets(
    'preserving a recovery candidate survives widget and repository recreation without publication',
    (tester) => withRecoveryWidget(tester, () async {
      final id = (await tester.runAsync(() async {
        final session = await documents.beginEdit(note);
        final id = newId();
        final working = FileManager.getFile(
          '/.working/office/${note.id}/${session.sourceRevision.revisionId}/$id/original.docx',
        );
        await working.parent.create(recursive: true);
        await working.writeAsBytes(session.originalBytes, flush: true);
        await OfficeEditRecoveryStore(repository)
            .start(session, sessionId: id, workingPath: working.path);
        return id;
      }))!;
      Future<void> show() => tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: OfficeWorkspace(
                repository: repository,
                note: note,
                engine: FixtureOfficeEngine(),
                onBack: () {},
              ),
            ),
          ),
        ),
      );
      final before = (await tester.runAsync(() => repository.revisions()))!
          .length;
      await show();
      await waitFor(
        tester,
        () => find
            .byKey(ValueKey('office-recovery-preserve-$id'))
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.byKey(ValueKey('office-recovery-preserve-$id')));
      await waitFor(
        tester,
        () => find.byKey(ValueKey('office-recovery-$id')).evaluate().isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await repository.close();
        repository = await NoteRepository.open(Directory('${temp.path}/vault'));
        documents = OfficeDocumentStore(repository);
        note = (await WorkspaceStore(repository).list()).single;
        expect(
          (await OfficeEditRecoveryStore(repository).list(note)).single.stage,
          OfficeEditRecoveryStage.preserved,
        );
        expect((await repository.revisions()).length, before);
      });
      await show();
      await waitFor(
        tester,
        () => find.textContaining('보관한 편집 작업').evaluate().isNotEmpty,
      );
      expect(find.byKey(ValueKey('office-recovery-$id')), findsNothing);
      expect(
        (await tester.runAsync(() => repository.revisions()))!.length,
        before,
      );
      await tester.pumpWidget(const SizedBox());
    }),
  );
}

class _ResponseLossRepository implements NoteRepository {
  new(this.inner, {required this.failBefore});
  final NoteRepository inner;
  final bool failBefore;
  var failed = false;
  final attempted = <RevisionRecord>[];
  final published = <RevisionRecord>[];

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
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) =>
      inner.readFiles(record);
  @override
  Future<Uint8List> readRevisionFile(RevisionRecord record, String name) =>
      inner.readRevisionFile(record, name);
  @override
  PreparedCommit resumePreparedCommit({
    required Map<String, dynamic> descriptor,
    required Map<String, Uint8List> files,
  }) => inner.resumePreparedCommit(descriptor: descriptor, files: files);
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
  Future<RevisionRecord> commitPrepared(PreparedCommit prepared) =>
      _commit(prepared, () => inner.commitPrepared(prepared));

  @override
  Future<RevisionRecord> commitPreparedIfHeads(
    PreparedCommit prepared, {
    required Map<String, List<String>> expectedHeads,
    List<String>? expectedRevisionIds,
    void Function()? beforePublish,
    bool allowHistoricalParents = false,
  }) => _commit(
    prepared,
    () => inner.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      expectedRevisionIds: expectedRevisionIds,
      beforePublish: beforePublish,
      allowHistoricalParents: allowHistoricalParents,
    ),
  );

  Future<RevisionRecord> _commit(
    PreparedCommit prepared,
    Future<RevisionRecord> Function() publish,
  ) async {
    attempted.add(prepared.record);
    if (!failed && failBefore) {
      failed = true;
      throw StateError('Synthetic failure before publication');
    }
    final record = await publish();
    if (!failed) {
      failed = true;
      published.add(record);
      throw StateError('Synthetic response lost after publication');
    }
    return record;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
