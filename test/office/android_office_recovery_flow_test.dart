import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_edit_recovery.dart';
import 'package:saber/data/office/office_view_state.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/office/office_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';
import 'annotation_store_test.dart' show annotationOfficeFile, annotationPdf;
import 'office_workspace_test.dart' show FixtureOfficeEngine;

typedef _Started = ({
  String id,
  String inputHash,
  String workingPath,
  String sourceRevisionId,
});

Future<void> _tick(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await _tick(tester);
  }
  expect(ready(), isTrue, reason: reason);
}

Future<T> _readWhilePumping<T>(
  WidgetTester tester,
  Future<T> Function() operation,
) async {
  var done = false;
  T? value;
  Object? failure;
  StackTrace? trace;
  await tester.runAsync(() async {
    operation().then(
      (result) {
        value = result;
        done = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        done = true;
      },
    );
  });
  await _until(
    tester,
    () => done,
    'The repository operation must finish while the application queue is pumped',
  );
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return value as T;
}

Future<void> _withFixture(
  WidgetTester tester,
  Future<void> Function(_Fixture fixture) body, {
  String fileName = 'lecture.docx',
  Uint8List? sourceBytes,
}) async {
  final fixture = await _readWhilePumping(
    tester,
    () => _Fixture.create(fileName: fileName, sourceBytes: sourceBytes),
  );
  try {
    await body(fixture);
  } finally {
    try {
      await tester.pumpWidget(const SizedBox());
    } finally {
      await _readWhilePumping(tester, fixture.close);
    }
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Fixture fixture,
  _RecoveryEngine engine,
) => tester.pumpWidget(
  TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: OfficeWorkspace(
          key: const ValueKey('office-recovery-flow'),
          repository: fixture.repository,
          note: fixture.note,
          engine: engine,
          onBack: () {},
        ),
      ),
    ),
  ),
);

Future<void> _waitCandidate(WidgetTester tester, String id) => _until(
  tester,
  () => find.byKey(ValueKey('office-recovery-$id')).evaluate().isNotEmpty,
  'The durable recovery candidate must be discovered',
);

Future<void> _tapResume(
  WidgetTester tester,
  String id, {
  bool save = false,
}) async {
  final button = find.byKey(
    ValueKey('office-recovery-${save ? 'save' : 'resume'}-$id'),
  );
  await _until(
    tester,
    () =>
        button.evaluate().isNotEmpty &&
        tester.widget<FilledButton>(button).onPressed != null,
    'The recovery candidate must be ready for explicit continuation',
  );
  await tester.ensureVisible(button);
  await tester.runAsync(() async {
    await tester.tap(button);
  });
}

Future<void> _waitSaved(WidgetTester tester, String id) => _until(
  tester,
  () =>
      find.byKey(ValueKey('office-recovery-$id')).evaluate().isEmpty &&
      find.text('원본과 PDF를 저장했습니다.').evaluate().isNotEmpty,
  'Publication, recovery completion, and the success notice must all finish',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();

  for (final prepared in [false, true]) {
    testWidgets(
      'a historical ${prepared ? 'prepared' : 'native-saved'} legacy mismatch retains the original and recovery',
      (tester) async {
        final format = prepared ? 'ppt' : 'doc';
        final original = _legacyPayload('original');
        final edited = _legacyPayload('wrong family');
        const message = '문서 확장자와 실제 형식이 일치하지 않습니다.';
        await _withFixture(
          tester,
          (fixture) async {
            final started = await _readWhilePumping(
              tester,
              fixture.startCandidate,
            );
            final saved = await _readWhilePumping(
              tester,
              () => fixture.savedOutput(
                started,
                'changed',
                originalBytes: edited,
              ),
            );
            await _readWhilePumping(
              tester,
              () => fixture.journal.recordNativeSaved(
                fixture.note,
                started.id,
                saved,
              ),
            );
            final recovered = await _readWhilePumping(
              tester,
              () => fixture.journal.read(fixture.note, started.id),
            );
            if (prepared) {
              final draft = fixture.documents.prepareEdited(
                recovered.session,
                originalBytes: edited,
                pdfBytes: annotationPdf('changed'),
                engineVersion: saved.engineVersion,
                pageCount: 1,
              );
              await _readWhilePumping(
                tester,
                () => fixture.journal.recordPrepared(
                  fixture.note,
                  started.id,
                  draft,
                ),
              );
            }
            final before = await _readWhilePumping(
              tester,
              fixture.repository.revisions,
            );
            final engine = _RecoveryEngine(
              onValidateLegacy: (path, expectedFormat, hash) async {
                expect(path, recovered.nativeResult!.sourcePath);
                expect(expectedFormat, format);
                expect(hash, saved.sourceSha256);
                throw PlatformException(
                  code: 'office_format_mismatch',
                  message: message,
                );
              },
            );
            await _mount(tester, fixture, engine);
            await _waitCandidate(tester, started.id);
            await _tapResume(tester, started.id, save: true);
            await _until(
              tester,
              () =>
                  find.textContaining(message).evaluate().isNotEmpty ||
                  find.text('원본과 PDF를 저장했습니다.').evaluate().isNotEmpty,
              'The recovery attempt must finish with an error or publication',
            );
            expect(engine.validateLegacyCalls, 1);
            expect(find.textContaining(message), findsOneWidget);
            expect(
              find.byKey(ValueKey('office-recovery-${started.id}')),
              findsOneWidget,
            );
            final revisions = await _readWhilePumping(
              tester,
              fixture.repository.revisions,
            );
            expect(
              revisions.map((revision) => revision.revisionId),
              before.map((revision) => revision.revisionId),
            );
            final kept = await _readWhilePumping(
              tester,
              () => File(recovered.nativeResult!.sourcePath!).readAsBytes(),
            );
            expect(kept, edited);
            expect(
              engine.recoverCalls + engine.resumeCalls + engine.editCalls,
              0,
            );
          },
          fileName: 'lecture.$format',
          sourceBytes: original,
        );
      },
    );
  }
  setupMockPrinting();
  setupMockWindowManager();

  for (final samePdf in [true, false]) {
    testWidgets(
      samePdf
          ? 'identical Android original and PDF retain the exact annotated edition after restart'
          : 'the same Android original with a different PDF publishes a new edition',
      (tester) async {
        await _withFixture(tester, (fixture) async {
          final pdf = annotationPdf('existing-pdf');
          final outputPdf = samePdf ? pdf : annotationPdf('changed-pdf');
          final ink = Uint8List.fromList([1, 2, 3]);
          final (
            edition,
            variant,
            annotation,
            before,
          ) = await _readWhilePumping(tester, () async {
            final edition = await fixture.documents.readLatest(fixture.note);
            final variant = await fixture.documents.commitDerivedPdf(
              await fixture.documents.beginEdit(fixture.note),
              pdfBytes: pdf,
              pageCount: 1,
            );
            final session = await OfficeAnnotationStore(fixture.repository)
                .open(fixture.note, edition, preview: variant);
            final annotation = await session.saveFiles({'main.sbn2': ink});
            final before = await fixture.repository.revisions();
            return (edition, variant, annotation, before);
          });
          final engine = _RecoveryEngine(
            onEdit: (path, id) async {
              final bytes = await File(path).readAsBytes();
              expect(bytes, edition.originalBytes);
              return fixture.savedOutput(
                (
                  id: id,
                  inputHash: edition.originalSha256,
                  workingPath: path,
                  sourceRevisionId: edition.revision.revisionId,
                ),
                'android-edit-return',
                originalBytes: bytes,
                pdfBytes: outputPdf,
              );
            },
          );
          await _mount(tester, fixture, engine);
          final edit = find.byKey(const ValueKey('office-edit-original'));
          bool editReady() =>
              edit.evaluate().length == 1 &&
              tester.widget<FilledButton>(edit).onPressed != null;
          await _until(
            tester,
            editReady,
            'The Android edit action must be ready',
          );
          await tester.ensureVisible(edit);
          await tester.runAsync(() => tester.tap(edit));
          await _until(
            tester,
            () => engine.editCalls == 1 && editReady(),
            'The Android editor result must finish processing',
          );
          final current = await _readWhilePumping(
            tester,
            () => fixture.documents.readLatest(fixture.note),
          );
          if (samePdf) {
            expect(
              current.revision.revisionId,
              edition.revision.revisionId,
              reason: 'Identical output must not publish another source head',
            );
          } else {
            expect(current.revision.parentRevisionIds, [
              edition.revision.revisionId,
            ]);
            expect(current.originalBytes, edition.originalBytes);
            expect(current.pdfBytes, outputPdf);
            expect(current.bindingId, isNot(variant.bindingId));
          }
          final receipt = (await _readWhilePumping(
            tester,
            () => fixture.journal.list(fixture.note),
          )).single;
          expect(receipt.stage.name, samePdf ? 'unchanged' : 'completed');
          expect(receipt.canResume, isFalse);
          expect(engine.recoverCalls, 0);
          expect(engine.resumeCalls, 0);

          await tester.pumpWidget(const SizedBox());
          await _readWhilePumping(tester, fixture.restart);
          await _mount(tester, fixture, engine);
          await _until(
            tester,
            editReady,
            'The Office document must reopen cold',
          );
          final persisted = await _readWhilePumping(tester, () async {
            final latest = await fixture.documents.readLatest(fixture.note);
            final sourceHeads = await fixture.repository.heads(
              fixture.note.sourceEntityId!,
            );
            final history = await fixture.documents.readLatest(
              fixture.note,
              revisionId: edition.revision.revisionId,
            );
            final storedPdf = (await fixture.documents.readPdfVariants(
              fixture.note,
              history,
            )).single;
            final reopenedInk = await OfficeAnnotationStore(fixture.repository)
                .open(fixture.note, history, preview: storedPdf);
            return (
              latest: latest,
              sourceHeads: sourceHeads,
              variant: storedPdf,
              pdf: await fixture.documents.readPdfVariantBytes(
                fixture.note,
                history,
                storedPdf,
              ),
              ink: reopenedInk,
              inkBytes: await fixture.repository.readRevisionFile(
                reopenedInk.revision!,
                'main.sbn2',
              ),
              revisions: await fixture.repository.revisions(),
              receipt: (await fixture.journal.list(fixture.note)).single,
            );
          });
          expect(
            persisted.latest.revision.revisionId,
            current.revision.revisionId,
          );
          expect(persisted.sourceHeads.map((head) => head.revisionId), [
            current.revision.revisionId,
          ]);
          expect(persisted.variant.bindingId, variant.bindingId);
          expect(
            persisted.variant.revision.revisionId,
            variant.revision.revisionId,
          );
          expect(persisted.pdf, pdf);
          expect(persisted.ink.parentRevisionIds, [annotation.revisionId]);
          expect(persisted.inkBytes, ink);
          expect(
            persisted.revisions,
            hasLength(before.length + (samePdf ? 0 : 1)),
          );
          expect(persisted.receipt.stage.name, receipt.stage.name);
          expect(persisted.receipt.canResume, isFalse);
          expect(
            find.byKey(ValueKey('office-recovery-${receipt.sessionId}')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        });
      },
    );
  }

  testWidgets(
    'a lost Dart callback recovers the native saved pair without reopening the editor',
    (tester) async {
      await _withFixture(tester, (fixture) async {
        final started = await _readWhilePumping(tester, fixture.startCandidate);
        final saved = await _readWhilePumping(
          tester,
          () => fixture.savedOutput(started, 'callback-lost'),
        );
        final original = (await _readWhilePumping(
          tester,
          () => fixture.repository.heads(fixture.note.sourceEntityId!),
        )).single;
        await _readWhilePumping(tester, fixture.restart);
        final count = (await _readWhilePumping(
          tester,
          fixture.repository.revisions,
        )).length;
        final engine = _RecoveryEngine(
          onRecover: (id, hash) async {
            expect(id, started.id);
            expect(hash, started.inputHash);
            return AndroidOfficeRecoveryResult(
              status: AndroidOfficeRecoveryStatus.saved,
              sessionId: id,
              inputSourceSha256: hash,
              engineVersion: 'fixture-engine',
              savedResult: saved,
            );
          },
        );
        await _mount(tester, fixture, engine);
        await _waitCandidate(tester, started.id);
        expect(
          (await _readWhilePumping(
            tester,
            fixture.repository.revisions,
          )).length,
          count,
        );
        await _tapResume(tester, started.id);
        await _waitSaved(tester, started.id);
        final edition = await _readWhilePumping(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        expect(edition.revision.revisionId, isNot(original.revisionId));
        expect(edition.revision.parentRevisionIds, [original.revisionId]);
        expect(edition.originalBytes, annotationOfficeFile('callback-lost'));
        expect(edition.pdfBytes, annotationPdf('callback-lost'));
        expect(edition.bindingId, isNotNull);
        expect(
          (await _readWhilePumping(
            tester,
            fixture.repository.revisions,
          )).length,
          count + 1,
        );
        expect(engine.recoverCalls, 1);
        expect(engine.resumeCalls, 0);
        expect(engine.editCalls, 0);
        expect(
          (await _readWhilePumping(
            tester,
            () => fixture.repository.readFiles(original),
          ))['lecture.docx'],
          annotationOfficeFile('original'),
        );
        expect(
          (await _readWhilePumping(
            tester,
            () => fixture.journal.list(fixture.note),
          )).single.stage,
          OfficeEditRecoveryStage.completed,
        );
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'a native edit reopens the newly saved edition instead of the remembered PDF',
    (tester) async {
      await _withFixture(tester, (fixture) async {
        final (source, previousPdf, previousInk) = await _readWhilePumping(
          tester,
          () async {
            final source = await fixture.documents.readLatest(fixture.note);
            final previousPdf = await fixture.documents.commitDerivedPdf(
              await fixture.documents.beginEdit(fixture.note),
              pdfBytes: annotationPdf('previous PDF'),
              pageCount: 1,
            );
            final annotations = await OfficeAnnotationStore(fixture.repository)
                .open(fixture.note, source, preview: previousPdf);
            final previousInk = await annotations.saveFiles({
              'main.sbn2': Uint8List.fromList([1, 2, 3]),
            });
            await OfficeViewStore(fixture.repository, fixture.note.id).save(
              OfficeViewState(
                vaultId: fixture.repository.vaultId,
                noteId: fixture.note.id,
                sourceRevisionId: source.revision.revisionId,
                bindingId: previousPdf.bindingId,
                pdfMode: false,
                pageId: newId(),
              ),
            );
            return (source, previousPdf, previousInk);
          },
        );
        final engine = _RecoveryEngine(
          onEdit: (path, id) => fixture.savedOutput((
            id: id,
            inputHash: source.originalSha256,
            workingPath: path,
            sourceRevisionId: source.revision.revisionId,
          ), 'new native edition'),
        );
        final edit = find.byKey(const ValueKey('office-edit-original'));
        final selector = find.byKey(const ValueKey('office-edition-selector'));
        bool editReady() =>
            edit.evaluate().length == 1 &&
            tester.widget<FilledButton>(edit).onPressed != null;
        String? selectedEdition() =>
            tester.widget<DropdownButton<String>>(selector).value;
        await _mount(tester, fixture, engine);
        await _until(tester, editReady, 'The original must be editable');
        expect(selectedEdition(), source.revision.revisionId);
        await tester.ensureVisible(edit);
        await tester.runAsync(() => tester.tap(edit));
        await _until(
          tester,
          () =>
              editReady() &&
              find.text('원본과 PDF를 저장했습니다.').evaluate().isNotEmpty,
          'The native edit must finish saving',
        );
        final saved = await _readWhilePumping(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        expect(saved.revision.revisionId, isNot(source.revision.revisionId));
        expect(saved.bindingId, isNot(previousPdf.bindingId));
        expect(selectedEdition(), saved.revision.revisionId);

        // A cold reopen cannot rely on save() or the user's back action.
        await tester.pumpWidget(const SizedBox());
        await _readWhilePumping(tester, fixture.restart);
        await _mount(tester, fixture, engine);
        await _until(tester, editReady, 'The saved original must reopen');
        expect(selectedEdition(), saved.revision.revisionId);
        final view = await _readWhilePumping(
          tester,
          OfficeViewStore(fixture.repository, fixture.note.id).load,
        );
        expect(view?.sourceRevisionId, saved.revision.revisionId);
        expect(view?.bindingId, saved.bindingId);
        expect(view?.pdfMode, isFalse);
        expect(view?.pageId, isNull);
        expect(
          (await _readWhilePumping(
            tester,
            () => fixture.repository.heads(previousPdf.bindingId),
          )).single.revisionId,
          previousInk.revisionId,
        );
        expect(engine.editCalls, 1);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'a changed native working copy resumes with the original input binding and reopens its saved edition',
    (tester) async {
      await _withFixture(tester, (fixture) async {
        final started = await _readWhilePumping(tester, fixture.startCandidate);
        final working = await _readWhilePumping(tester, () async {
          final file = File(
            '${fixture.directory.path}/native/${started.id}/working.docx',
          );
          await file.parent.create(recursive: true);
          await file.writeAsBytes(
            annotationOfficeFile('autosaved-working'),
            flush: true,
          );
          return (
            path: file.path,
            hash: sha256.convert(await file.readAsBytes()).toString(),
          );
        });
        expect(working.hash, isNot(started.inputHash));
        final saved = await _readWhilePumping(
          tester,
          () => fixture.savedOutput(started, 'resumed-working'),
        );
        await _readWhilePumping(tester, fixture.restart);
        final engine = _RecoveryEngine(
          onRecover: (id, hash) async {
            expect(id, started.id);
            expect(hash, started.inputHash);
            return AndroidOfficeRecoveryResult(
              status: AndroidOfficeRecoveryStatus.working,
              sessionId: id,
              inputSourceSha256: hash,
              engineVersion: 'fixture-engine',
              workingPath: working.path,
              workingSha256: working.hash,
            );
          },
          onResume: (id, hash) async {
            expect(id, started.id);
            expect(
              hash,
              started.inputHash,
              reason: 'The changed working SHA must never replace the original input identity',
            );
            return saved;
          },
        );
        await _mount(tester, fixture, engine);
        await _waitCandidate(tester, started.id);
        await _tapResume(tester, started.id);
        await _waitSaved(tester, started.id);
        final edition = await _readWhilePumping(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        expect(edition.revision.parentRevisionIds, [started.sourceRevisionId]);
        expect(edition.originalBytes, annotationOfficeFile('resumed-working'));
        expect(edition.pdfBytes, annotationPdf('resumed-working'));
        expect(engine.recoverCalls, 1);
        expect(engine.resumeCalls, 1);
        expect(engine.editCalls, 0);
        await tester.pumpWidget(const SizedBox());
        await _readWhilePumping(tester, fixture.restart);
        await _mount(tester, fixture, engine);
        await _until(
          tester,
          () => find
              .byKey(const ValueKey('office-edit-original'))
              .evaluate()
              .isNotEmpty,
          'The saved document must reopen in a fresh widget',
        );
        final reopened = await _readWhilePumping(
          tester,
          () => fixture.documents.readLatest(fixture.note),
        );
        expect(reopened.revision.revisionId, edition.revision.revisionId);
        expect(reopened.bindingId, edition.bindingId);
        expect(reopened.originalBytes, edition.originalBytes);
        expect(reopened.pdfBytes, edition.pdfBytes);
        expect(
          find.byKey(ValueKey('office-recovery-${started.id}')),
          findsNothing,
        );
        expect(engine.recoverCalls, 1);
        expect(engine.resumeCalls, 1);
        expect(engine.editCalls, 0);
        expect(tester.takeException(), isNull);
      });
    },
  );

  testWidgets(
    'a late native result after same-note metadata repoint is retained only for the captured source',
    (tester) async {
      final result = Completer<AndroidOfficeEditResult>();
      try {
        await _withFixture(tester, (fixture) async {
          final oldSource = fixture.note.sourceEntityId!;
          final original = (await _readWhilePumping(
            tester,
            () => fixture.repository.heads(oldSource),
          )).single;
          final launched = Completer<_Started>();
          final engine = _RecoveryEngine(
            onEdit: (path, id) async {
              final inputHash = sha256
                  .convert(await File(path).readAsBytes())
                  .toString();
              launched.complete((
                id: id,
                inputHash: inputHash,
                workingPath: path,
                sourceRevisionId: original.revisionId,
              ));
              return result.future;
            },
          );
          await _mount(tester, fixture, engine);
          final edit = find.byKey(const ValueKey('office-edit-original'));
          await _until(
            tester,
            () =>
                edit.evaluate().isNotEmpty &&
                tester.widget<FilledButton>(edit).onPressed != null,
            'The original edit action must be ready',
          );
          await tester.ensureVisible(edit);
          await tester.runAsync(() async {
            await tester.tap(edit);
          });
          final started = await _readWhilePumping(
            tester,
            () => launched.future,
          );
          final replacement = await _readWhilePumping(tester, () async {
            final sourceId = newId();
            final source = await fixture.repository.commit(
              entityId: sourceId,
              kind: EntityKind.attachment,
              ownerNoteId: fixture.note.id,
              files: {
                'lecture.docx': annotationOfficeFile('new-current-source'),
              },
              parentRevisionIds: [],
            );
            final metadata = jsonObject(
              jsonDecode(
                utf8.decode(
                  (await fixture.repository.readFiles(
                    fixture.note.revision,
                  ))['note.json']!,
                ),
              ),
            );
            await fixture.repository.commit(
              entityId: fixture.note.id,
              kind: EntityKind.metadata,
              files: {
                'note.json': _jsonBytes({
                  ...metadata,
                  'sourceEntityId': sourceId,
                }),
              },
              parentRevisionIds: [fixture.note.revision.revisionId],
            );
            fixture.note = (await WorkspaceStore(
              fixture.repository,
            ).list()).single;
            return source;
          });
          final count = (await _readWhilePumping(
            tester,
            fixture.repository.revisions,
          )).length;
          await _mount(tester, fixture, engine);
          await _waitCandidate(tester, started.id);
          final saved = await _readWhilePumping(
            tester,
            () => fixture.savedOutput(started, 'late-old-source'),
          );
          result.complete(saved);
          final preserve = find.byKey(
            ValueKey('office-recovery-preserve-${started.id}'),
          );
          await _until(
            tester,
            () =>
                preserve.evaluate().isNotEmpty &&
                tester.widget<TextButton>(preserve).onPressed != null,
            'The late result must finish retention without publishing into the changed document',
          );
          final candidate = (await _readWhilePumping(
            tester,
            () => fixture.journal.list(fixture.note),
          )).single;
          expect(candidate.stage, OfficeEditRecoveryStage.nativeSaved);
          expect(candidate.canResume, isFalse);
          expect(candidate.sourceRevisionId, original.revisionId);
          expect(
            await _readWhilePumping(
              tester,
              () => File(candidate.sourcePath!).readAsBytes(),
            ),
            annotationOfficeFile('late-old-source'),
          );
          expect(
            await _readWhilePumping(
              tester,
              () => File(candidate.pdfPath!).readAsBytes(),
            ),
            annotationPdf('late-old-source'),
          );
          expect(
            (await _readWhilePumping(
              tester,
              () => fixture.repository.heads(replacement.entityId),
            )).single.revisionId,
            replacement.revisionId,
          );
          expect(
            (await _readWhilePumping(
              tester,
              () => fixture.repository.heads(oldSource),
            )).single.revisionId,
            original.revisionId,
          );
          expect(
            (await _readWhilePumping(
              tester,
              () => fixture.repository.readFiles(original),
            ))['lecture.docx'],
            annotationOfficeFile('original'),
          );
          expect(
            (await _readWhilePumping(
              tester,
              fixture.repository.revisions,
            )).length,
            count,
          );
          expect(find.text('원본과 PDF를 저장했습니다.'), findsNothing);
          final resume = find.byKey(
            ValueKey('office-recovery-resume-${started.id}'),
          );
          final blocked = resume.evaluate().isNotEmpty
              ? resume
              : find.byKey(ValueKey('office-recovery-save-${started.id}'));
          expect(blocked, findsOneWidget);
          expect(tester.widget<FilledButton>(blocked).onPressed, isNull);
          await tester.ensureVisible(preserve);
          await tester.runAsync(() async {
            await tester.tap(preserve);
          });
          await _until(
            tester,
            () =>
                find
                    .byKey(ValueKey('office-recovery-${started.id}'))
                    .evaluate()
                    .isEmpty &&
                find.textContaining('편집 파일을 보관했습니다.').evaluate().isNotEmpty,
            'The disconnected edit must remain preservable',
          );
          final retained = (await _readWhilePumping(
            tester,
            () => fixture.journal.list(fixture.note),
          )).single;
          expect(retained.stage, OfficeEditRecoveryStage.preserved);
          expect(retained.resumableStage, OfficeEditRecoveryStage.nativeSaved);
          expect(retained.canResume, isFalse);
          expect(File(saved.sourcePath!).existsSync(), isTrue);
          expect(File(saved.pdfPath!).existsSync(), isTrue);
          expect(
            (await _readWhilePumping(
              tester,
              fixture.repository.revisions,
            )).length,
            count,
          );
          expect(engine.editCalls, 1);
          expect(engine.recoverCalls, 0);
          expect(engine.resumeCalls, 0);
          expect(tester.takeException(), isNull);
        });
      } finally {
        if (!result.isCompleted)
          result.complete(
            const AndroidOfficeEditResult(
              status: AndroidOfficeEditStatus.cancelled,
              engineVersion: 'fixture-engine',
            ),
          );
      }
    },
  );
}

Uint8List _jsonBytes(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

Uint8List _legacyPayload(String label) => Uint8List.fromList([
  0xd0,
  0xcf,
  0x11,
  0xe0,
  0xa1,
  0xb1,
  0x1a,
  0xe1,
  ...utf8.encode(label),
]);

class _Fixture {
  new(this.directory, this.repository, this.note);
  final Directory directory;
  NoteRepository repository;
  VaultNote note;
  OfficeDocumentStore get documents => OfficeDocumentStore(repository);
  OfficeEditRecoveryStore get journal => OfficeEditRecoveryStore(repository);

  static Future<_Fixture> create({
    required String fileName,
    Uint8List? sourceBytes,
  }) async {
    final directory = await Directory.systemTemp.createTemp(
      'android-office-recovery-flow-',
    );
    NoteRepository? opened;
    try {
      await FileManager.init(
        documentsDirectory: '${directory.path}/documents',
        shouldWatchRootDirectory: false,
      );
      final repository = await NoteRepository.open(
        Directory('${directory.path}/vault'),
        createFormatVersion: 2,
      );
      opened = repository;
      final note = await OfficeDocumentStore(repository).importDocument(
        title: 'Lecture',
        fileName: fileName,
        bytes: sourceBytes ?? annotationOfficeFile('original'),
      );
      return _Fixture(directory, repository, note);
    } catch (_) {
      await opened?.close();
      await directory.delete(recursive: true);
      rethrow;
    }
  }

  Future<_Started> startCandidate() async {
    final captured = await documents.beginEdit(note);
    final id = newId();
    final extension = p.extension(captured.originalFileName).toLowerCase();
    final working = FileManager.getFile(
      '/.working/office/${note.id}/${captured.sourceRevision.revisionId}/$id/original$extension',
    );
    await working.parent.create(recursive: true);
    await working.writeAsBytes(captured.originalBytes, flush: true);
    await journal.start(captured, sessionId: id, workingPath: working.path);
    return (
      id: id,
      inputHash: sha256.convert(captured.originalBytes).toString(),
      workingPath: working.path,
      sourceRevisionId: captured.sourceRevision.revisionId,
    );
  }

  Future<AndroidOfficeEditResult> savedOutput(
    _Started started,
    String label, {
    Uint8List? originalBytes,
    Uint8List? pdfBytes,
  }) async {
    final outputs = Directory('${directory.path}/native/${started.id}');
    await outputs.create(recursive: true);
    final original = originalBytes ?? annotationOfficeFile(label);
    final pdf = pdfBytes ?? annotationPdf(label);
    final source = await File(
      '${outputs.path}/edited${p.extension(started.workingPath)}',
    ).writeAsBytes(original, flush: true);
    final preview = await File('${outputs.path}/preview.pdf')
        .writeAsBytes(pdf, flush: true);
    return AndroidOfficeEditResult(
      status: AndroidOfficeEditStatus.saved,
      sessionId: started.id,
      inputSourceSha256: started.inputHash,
      engineVersion: 'fixture-engine',
      sourcePath: source.path,
      pdfPath: preview.path,
      sourceSha256: sha256.convert(original).toString(),
      pdfSha256: sha256.convert(pdf).toString(),
      pdfPageCount: 1,
    );
  }

  Future<void> restart() async {
    final root = repository.root;
    final id = note.id;
    await repository.close();
    repository = await NoteRepository.open(root);
    note = (await WorkspaceStore(
      repository,
    ).list()).singleWhere((n) => n.id == id);
  }

  Future<void> close() async {
    try {
      await repository.close();
    } finally {
      await directory.delete(recursive: true);
    }
  }
}

class _RecoveryEngine extends FixtureOfficeEngine {
  new({super.onEdit, this.onRecover, this.onResume, this.onValidateLegacy});
  final Future<AndroidOfficeRecoveryResult> Function(String, String)? onRecover;
  final Future<AndroidOfficeEditResult> Function(String, String)? onResume;
  final Future<void> Function(String, String, String)? onValidateLegacy;
  var editCalls = 0, recoverCalls = 0, resumeCalls = 0, validateLegacyCalls = 0;

  @override
  Future<void> validateLegacySource({
    required String sourcePath,
    required String format,
    required String sourceSha256,
  }) {
    validateLegacyCalls++;
    return onValidateLegacy!(sourcePath, format, sourceSha256);
  }

  @override
  Future<AndroidOfficeEditResult> edit({
    required String sourcePath,
    required String sessionId,
  }) {
    editCalls++;
    if (onEdit == null) throw StateError('Recovery must not launch a new edit');
    return super.edit(sourcePath: sourcePath, sessionId: sessionId);
  }

  @override
  Future<AndroidOfficeRecoveryResult> recoverSession({
    required String sessionId,
    required String inputSourceSha256,
  }) {
    recoverCalls++;
    if (onRecover == null) throw StateError('Unexpected native recovery');
    return onRecover!(sessionId, inputSourceSha256);
  }

  @override
  Future<AndroidOfficeEditResult> resumeSession({
    required String sessionId,
    required String inputSourceSha256,
  }) {
    resumeCalls++;
    if (onResume == null) throw StateError('Unexpected native resume');
    return onResume!(sessionId, inputSourceSha256);
  }
}
