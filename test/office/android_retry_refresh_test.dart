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
    final resolved = await temp.resolveSymbolicLinks();
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    expect(
      resolved,
      startsWith('$parent${Platform.pathSeparator}android-office-retry-'),
    );
    await Directory(resolved).delete(recursive: true);
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

  for (final failRetry in [false, true]) {
    testWidgets(
      'Android retry ${failRetry ? 'failure' : 'success'} defers refresh and preserves the frozen edition',
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
        final guarded = _RetryBarrierRepository(repository, failBefore: true);
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
          guarded.releaseRetryBarrier();
          await tester.pumpWidget(const SizedBox());
          try {
            if (state != null) {
              try {
                await waitForOperation(tester, state.save);
              } on StateError catch (error) {
                if (error.message != 'Synthetic failure before publication' &&
                    error.message !=
                        'Synthetic retry pre-publication failure') {
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
        expect(guarded.published, isEmpty);

        guarded.armRetryBarrier(failAgain: failRetry);
        var readsDuringRetry = -1;
        var remoteVisibleAfterFailure = true;
        late OfficeEdition remote;
        try {
          await tester.runAsync(() async {
            await tester.tap(find.text('저장 재시도'));
          });
          await waitFor(tester, () => guarded.retryHolding);
          remote = (await tester.runAsync(
            () => documents.commitEdited(
              captured,
              originalBytes: annotationOfficeFile('remote'),
              pdfBytes: annotationPdf('remote'),
              engineVersion: 'remote-fixture',
              pageCount: 1,
            ),
          ))!;
          // Deliver the external event, then expire its actual debounce timer.
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          for (var i = 0; i < 8; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 15)),
            );
            await tester.pump(const Duration(milliseconds: 15));
          }
          readsDuringRetry = guarded.readsWhileRetryHeld;
        } finally {
          guarded.releaseRetryBarrier();
        }
        if (failRetry) {
          await waitFor(
            tester,
            () => find
                .textContaining('Synthetic retry pre-publication failure')
                .evaluate()
                .isNotEmpty,
          );
          remoteVisibleAfterFailure = false;
          for (var i = 0; i < 160; i++) {
            final selector = tester.widget<DropdownButton<String>>(
              find.byKey(const ValueKey('office-edition-selector')),
            );
            if (selector.items!.any(
              (item) => item.value == remote.revision.revisionId,
            )) {
              remoteVisibleAfterFailure = true;
              break;
            }
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 15)),
            );
            await tester.pump(const Duration(milliseconds: 15));
          }
          expect(dirty.last, isTrue);
          expect(guarded.published, isEmpty);
          expect(
            (await tester.runAsync(
              () => repository.heads(note.sourceEntityId!),
            ))!.single.revisionId,
            remote.revision.revisionId,
          );
          await tester.runAsync(() async {
            await tester.tap(find.text('저장 재시도'));
          });
        }
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
        expect(guarded.retryEntered, isTrue);
        expect(
          remoteVisibleAfterFailure,
          isTrue,
          reason: 'A deferred external edition must become visible even when retry publication fails',
        );
        expect(
          readsDuringRetry,
          0,
          reason: 'The held retry has no remaining own reads; background refresh must wait for its finalizer',
        );
      },
    );
  }
}

class _RetryBarrierRepository implements NoteRepository {
  new(this.inner, {required this.failBefore});
  final NoteRepository inner;
  final bool failBefore;
  var failed = false;
  final attempted = <RevisionRecord>[];
  final published = <RevisionRecord>[];
  Completer<void>? _retryRelease;
  var _gateTaken = false;
  var _failAgain = false;
  var retryEntered = false;
  var retryHolding = false;
  var readsWhileRetryHeld = 0;

  void armRetryBarrier({required bool failAgain}) {
    _retryRelease = Zone.root.run(() => Completer<void>());
    _failAgain = failAgain;
  }

  void releaseRetryBarrier() {
    final release = _retryRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

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
  Future<List<RevisionRecord>> heads(String id) {
    if (retryHolding) readsWhileRetryHeld++;
    return inner.heads(id);
  }

  @override
  Future<List<RevisionRecord>> revisions() {
    if (retryHolding) readsWhileRetryHeld++;
    return inner.revisions();
  }

  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) {
    if (retryHolding) readsWhileRetryHeld++;
    return inner.readFiles(record);
  }

  @override
  Future<Uint8List> readRevisionFile(RevisionRecord record, String name) {
    if (retryHolding) readsWhileRetryHeld++;
    return inner.readRevisionFile(record, name);
  }

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
    final gate = _retryRelease;
    if (gate != null && !_gateTaken) {
      _gateTaken = true;
      retryEntered = true;
      retryHolding = true;
      try {
        await gate.future;
      } finally {
        retryHolding = false;
      }
      if (_failAgain) {
        _failAgain = false;
        throw StateError('Synthetic retry pre-publication failure');
      }
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
