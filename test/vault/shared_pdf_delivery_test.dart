import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late _RecordingImportController controller;
  var fixtureClosed = false;
  var widgetOwnsCleanup = false;

  setUp(() async {
    fixtureClosed = false;
    widgetOwnsCleanup = false;
    StudyWorkspace.pendingDocumentImport.value = null;
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('shared-pdf-delivery-');
    controller = _RecordingImportController(
      await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      ),
      directoryProvider: () async => Directory('${temp.path}/support'),
    );
  });
  Future<void> closeFixture() async {
    if (fixtureClosed) return;
    StudyWorkspace.pendingDocumentImport.value = null;
    final release = controller.release;
    if (release != null && !release.isCompleted) release.complete();
    await controller.settle();
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
    fixtureClosed = true;
  }

  tearDown(() async {
    if (!widgetOwnsCleanup) await closeFixture();
  });

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() ready,
    String message,
  ) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    }
    expect(ready(), isTrue, reason: message);
  }

  Future<void> mount(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: StudyWorkspace(controller: controller)),
      ),
    );
    await tester.pump();
  }

  void changeLifecycle(WidgetTester tester, AppLifecycleState target) {
    final previous = tester.binding.lifecycleState;
    if (previous == target) return;
    if (previous == null) {
      tester.binding.handleAppLifecycleStateChanged(target);
      return;
    }
    const states = AppLifecycleState.values;
    final start = states.indexOf(previous), end = states.indexOf(target);
    if (target == AppLifecycleState.detached) {
      for (var i = start + 1; i < states.length; i++) {
        tester.binding.handleAppLifecycleStateChanged(states[i]);
      }
      tester.binding.handleAppLifecycleStateChanged(target);
      return;
    }
    final step = start < end ? 1 : -1;
    for (var i = start + step; i != end + step; i += step) {
      tester.binding.handleAppLifecycleStateChanged(states[i]);
    }
  }

  void sharedWidgetTest(
    String description,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(description, (tester) async {
      widgetOwnsCleanup = true;
      final platform = debugDefaultTargetPlatformOverride;
      final lifecycle = tester.binding.lifecycleState;
      try {
        await body(tester);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox());
          var finished = false;
          Object? cleanupError;
          StackTrace? cleanupStack;
          await tester.runAsync(() async {
            unawaited(
              closeFixture().then<void>(
                (_) => finished = true,
                onError: (Object error, StackTrace stack) {
                  cleanupError = error;
                  cleanupStack = stack;
                  finished = true;
                },
              ),
            );
          });
          await pumpUntil(
            tester,
            () => finished,
            'The fixture must drain, flush, close its repository and delete its temporary files.',
          );
          if (cleanupError != null)
            Error.throwWithStackTrace(cleanupError!, cleanupStack!);
          expect(fixtureClosed, isTrue);
          expect(
            StudyWorkspace.pendingDocumentImport.processing,
            isFalse,
            reason: 'The disposed workspace must finish its own import lease.',
          );
        } finally {
          changeLifecycle(tester, lifecycle ?? AppLifecycleState.resumed);
          debugDefaultTargetPlatformOverride = platform;
        }
      }
    });
  }

  Future<File> source(WidgetTester tester, String name) async =>
      (await tester.runAsync(
        () => File('${temp.path}/$name.pdf').writeAsBytes(
          Uint8List.fromList('%PDF-shared-$name-original'.codeUnits),
        ),
      ))!;

  for (final (extension, kind) in [
    ('PPTX', OfficeTemplateKind.presentation),
    ('DOCX', OfficeTemplateKind.document),
  ]) {
    sharedWidgetTest(
      'a shared $extension opens for Office editing with unrelated pending revisions',
      (tester) async {
        final starter = OfficeTemplates.create(kind, title: '공유 문서');
        final repository = controller.repository;
        final unrelated = RevisionRecord(
          vaultId: repository.vaultId,
          revisionId: newId(),
          entityId: newId(),
          kind: EntityKind.ink,
          ownerNoteId: newId(),
          deviceId: newId(),
          parentRevisionIds: [newId()],
          blobs: {},
          formatVersion: 2,
        );
        final file = (await tester.runAsync(() async {
          await repository.importRevision(unrelated, blobsByHash: {});
          expect(repository.pendingRevisionCount, 1);
          return File('${temp.path}/${starter.fileName}')
              .writeAsBytes(starter.bytes);
        }))!;
        final requestId = newId();
        final inbox = StudyWorkspace.pendingDocumentImport;
        var released = false;
        inbox.enqueue(
          file.path,
          sharedRequestId: requestId,
          onRelease: () async {
            await file.delete();
            released = true;
          },
        );
        await mount(tester);
        await pumpUntil(
          tester,
          () => find.text('Office 편집용').hitTestable().evaluate().isNotEmpty,
          'The shared Office file must offer the first-open choice.',
        );
        await tester.runAsync(() => tester.tap(find.text('Office 편집용')));
        await pumpUntil(
          tester,
          () => inbox.pending.isEmpty || inbox.pending.first.failure != null,
          'The shared source must finish importing.',
        );
        expect(inbox.pending.firstOrNull?.failure, isNull);
        final note = (await tester.runAsync(controller.store.list))!.single;
        expect(note.id, requestId);
        expect(note.documentKind, VaultDocumentKind.office);
        expect(controller.activeSession?.note.id, note.id);
        final opened = (await tester.runAsync(
          () => OfficeDocumentStore(repository).readLatest(note),
        ))!;
        expect(opened.originalFileName, starter.fileName);
        expect(opened.originalBytes, starter.bytes);
        expect(repository.pendingRevisionCount, 1);
        await pumpUntil(
          tester,
          () => released,
          'The staged file is released after import.',
        );
        expect(await tester.runAsync(file.exists), isFalse);
      },
    );
  }

  sharedWidgetTest(
    'shared PDF arrivals during another import retain their order and exact originals',
    (tester) async {
      final a = await source(tester, 'first');
      final b = await source(tester, 'second');
      final c = await source(tester, 'third');
      final release = Completer<void>();
      controller.release = release;
      await mount(tester);
      await tester.runAsync(() async {
        StudyWorkspace.pendingDocumentImport.value = a.path;
      });
      await pumpUntil(
        tester,
        () => controller.started.length == 1,
        'The first import must be running before the next two arrive.',
      );
      await tester.runAsync(() async {
        StudyWorkspace.pendingDocumentImport.value = b.path;
        StudyWorkspace.pendingDocumentImport.value = c.path;
        release.complete();
        controller.release = null;
      });
      await pumpUntil(
        tester,
        () => controller.completed.length == 3,
        'The completed first request must not discard later requests.',
      );
      expect(controller.started, ['first.pdf', 'second.pdf', 'third.pdf']);
      expect(controller.completed, controller.started);
      expect(StudyWorkspace.pendingDocumentImport.value, isNull);
      await tester.runAsync(() async {
        final notes = await controller.store.list();
        expect(notes, hasLength(3));
        for (final note in notes) {
          final original = File('${temp.path}/${note.title}.pdf');
          final revision = (await controller.repository.heads(
            note.sourceEntityId!,
          )).single;
          final saved = await controller.repository.readFiles(revision);
          expect(saved.values.single, await original.readAsBytes());
        }
      });
    },
  );

  sharedWidgetTest('shared PDF resumes when an unrelated busy dialog closes', (
    tester,
  ) async {
    final pdf = await source(tester, 'after-dialog');
    await mount(tester);
    await tester.tap(find.byTooltip('노트 링크 열기'));
    await pumpUntil(
      tester,
      () => find.text('inkvault 링크 열기').evaluate().isNotEmpty,
      'The unrelated link dialog must be open before the PDF arrives.',
    );
    expect(find.text('inkvault 링크 열기'), findsOneWidget);
    await tester.runAsync(() async {
      StudyWorkspace.pendingDocumentImport.value = pdf.path;
    });
    await tester.pump();
    expect(controller.started, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, '취소'));
    await pumpUntil(
      tester,
      () => controller.completed.length == 1,
      'A queued external PDF must resume after the active dialog ends.',
    );
    expect(controller.completed, ['after-dialog.pdf']);
    expect(StudyWorkspace.pendingDocumentImport.value, isNull);
    expect(await tester.runAsync(pdf.exists), isTrue);
  });

  sharedWidgetTest(
    'shared PDFs received before the workspace mounts are all delivered',
    (tester) async {
      final a = await source(tester, 'before-first');
      final b = await source(tester, 'before-second');
      await tester.runAsync(() async {
        StudyWorkspace.pendingDocumentImport.value = a.path;
        StudyWorkspace.pendingDocumentImport.value = b.path;
      });
      await mount(tester);
      await pumpUntil(
        tester,
        () => controller.completed.length == 2,
        'The shared-file batch must survive until the workspace is mounted.',
      );
      expect(controller.completed, ['before-first.pdf', 'before-second.pdf']);
    },
  );

  sharedWidgetTest(
    'a shared request waits for an independently opened popup route',
    (tester) async {
      final pdf = await source(tester, 'after-popup');
      await mount(tester);
      await tester.tap(find.byTooltip('다른 AI 연결 · MCP'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        StudyWorkspace.pendingDocumentImport.value = pdf.path;
      });
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.started, isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '닫기'));
      await pumpUntil(
        tester,
        () => controller.completed.length == 1,
        'A route becoming current again must resume its shared request.',
      );
      expect(controller.completed, ['after-popup.pdf']);
    },
  );

  sharedWidgetTest('a failed shared request is held until its explicit retry', (
    tester,
  ) async {
    final pdf = await source(tester, 'retry');
    controller.failNext = true;
    await mount(tester);
    await tester.runAsync(() async {
      StudyWorkspace.pendingDocumentImport.value = pdf.path;
    });
    await pumpUntil(
      tester,
      () => find.text('다시 시도').evaluate().isNotEmpty,
      'A failed external import must remain available to retry.',
    );
    expect(controller.started, ['retry.pdf']);
    expect(controller.completed, isEmpty);
    final request = StudyWorkspace.pendingDocumentImport.pending.single.id;
    await tester.runAsync(controller.refresh);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.started, ['retry.pdf']);
    expect(StudyWorkspace.pendingDocumentImport.pending.single.id, request);
    await tester.tap(find.widgetWithText(TextButton, '다시 시도'));
    await pumpUntil(
      tester,
      () => controller.completed.length == 1,
      'The retry must finish the held request.',
    );
    expect(controller.started, ['retry.pdf', 'retry.pdf']);
    expect(StudyWorkspace.pendingDocumentImport.value, isNull);
    expect(await tester.runAsync(pdf.exists), isTrue);
    expect(await tester.runAsync(controller.store.list), hasLength(1));
  });

  sharedWidgetTest(
    'a new workspace cannot double claim a previous in-flight request',
    (tester) async {
      final a = await source(tester, 'old-state');
      final b = await source(tester, 'new-state');
      final release = Completer<void>();
      controller.release = release;
      await mount(tester);
      await tester.runAsync(() async {
        StudyWorkspace.pendingDocumentImport.value = a.path;
      });
      await pumpUntil(
        tester,
        () => controller.started.length == 1,
        'The first state must own the active import.',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        StudyWorkspace.pendingDocumentImport.value = b.path;
      });
      await mount(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(controller.started, ['old-state.pdf']);
      await tester.runAsync(() async {
        controller.release = null;
        release.complete();
      });
      await pumpUntil(
        tester,
        () => controller.completed.length == 2,
        'The old completion must release only its own request, then allow the next.',
      );
      expect(controller.started, ['old-state.pdf', 'new-state.pdf']);
      expect(StudyWorkspace.pendingDocumentImport.value, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  sharedWidgetTest(
    'a queued request needs explicit consent for another vault',
    (tester) async {
      final pdf = await source(tester, 'old-vault');
      await mount(tester);
      await tester.tap(find.byTooltip('노트 링크 열기'));
      await pumpUntil(
        tester,
        () => find.text('inkvault 링크 열기').evaluate().isNotEmpty,
        'The link dialog must be open before switching the destination vault.',
      );
      await tester.runAsync(() async {
        StudyWorkspace.pendingDocumentImport.value = pdf.path;
        final next = await NoteRepository.open(
          Directory('${temp.path}/selected-vault'),
          createFormatVersion: 2,
        );
        await controller.replaceRepository(next);
      });
      await tester.tap(find.widgetWithText(TextButton, '취소'));
      await pumpUntil(
        tester,
        () => find.text('현재 저장소에 가져오기').evaluate().isNotEmpty,
        'Changing the vault must not silently retarget a queued PDF.',
      );
      expect(controller.started, isEmpty);
      expect(await tester.runAsync(controller.store.list), isEmpty);
      await tester.tap(find.widgetWithText(TextButton, '현재 저장소에 가져오기'));
      await pumpUntil(
        tester,
        () => controller.completed.length == 1,
        'An explicit destination choice must resume this request.',
      );
      expect(controller.completed, ['old-vault.pdf']);
      expect(await tester.runAsync(pdf.exists), isTrue);
    },
  );

  sharedWidgetTest(
    'shared imports wait while paused and resume in the foreground',
    (tester) async {
      final pdf = await source(tester, 'resumed');
      await mount(tester);
      await tester.runAsync(() async {
        changeLifecycle(tester, AppLifecycleState.resumed);
        changeLifecycle(tester, AppLifecycleState.paused);
        StudyWorkspace.pendingDocumentImport.value = pdf.path;
      });
      await tester.pump(const Duration(seconds: 1));
      expect(controller.started, isEmpty);
      await tester.runAsync(() async {
        changeLifecycle(tester, AppLifecycleState.resumed);
      });
      await pumpUntil(
        tester,
        () => controller.completed.length == 1,
        'A queued PDF must resume after returning to the foreground.',
      );
      expect(controller.completed, ['resumed.pdf']);
    },
  );

  for (final withSource in [false, true]) {
    test(
      '${withSource ? 'PDF source' : 'new ink'} creation cannot write into a replacement repository',
      () async {
        final old = await NoteRepository.open(
          Directory('${temp.path}/scope-old-$withSource'),
          createFormatVersion: 2,
        );
        final next = await NoteRepository.open(
          Directory('${temp.path}/scope-next-$withSource'),
          createFormatVersion: 2,
        );
        final c = _DelayedCreationController(old);
        Object? failure;
        var succeeded = false;
        final pending =
            (withSource
                    ? c.importPdf(
                        'Scoped PDF',
                        fileName: 'source.pdf',
                        bytes: Uint8List.fromList(
                          '%PDF-scoped-original'.codeUnits,
                        ),
                      )
                    : c.createNote('Scoped ink'))
                .then<void>(
                  (_) {
                    succeeded = true;
                  },
                  onError: (Object error) {
                    failure = error;
                  },
                );
        try {
          await c.delayedStore.entered.future;
          c.repository = next;
          c.delayedStore.release.complete();
          await pending;
          expect(succeeded, isFalse);
          expect(failure, isStateError);
          expect(await next.revisions(), isEmpty);
          expect(await WorkspaceStore(old).list(), hasLength(1));
        } finally {
          if (!c.delayedStore.release.isCompleted)
            c.delayedStore.release.complete();
          await pending;
          c.dispose();
          await old.close();
          await next.close();
        }
      },
    );
  }
}

class _RecordingImportController extends WorkspaceController {
  new(super.repository, {super.directoryProvider});
  final started = <String>[];
  final completed = <String>[];
  final _imports = <Future<void>>[];
  Completer<void>? release;
  var failNext = false;

  @override
  Future<VaultNote> importPdf(
    String title, {
    required String fileName,
    required Uint8List bytes,
  }) {
    final pending = _import(title, fileName, bytes);
    _imports.add(
      pending.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return pending;
  }

  Future<VaultNote> _import(
    String title,
    String fileName,
    Uint8List bytes,
  ) async {
    started.add(fileName);
    final waiting = release;
    if (waiting != null) await waiting.future;
    if (failNext) {
      failNext = false;
      throw const FileSystemException('Synthetic import failure');
    }
    final note = await store.createWithSource(
      title,
      fileName: fileName,
      bytes: bytes,
      documentKind: VaultDocumentKind.pdf,
    );
    completed.add(fileName);
    return note;
  }

  Future<void> settle() async {
    while (_imports.isNotEmpty) {
      final pending = _imports.first;
      await pending;
      _imports.remove(pending);
    }
  }
}

class _DelayedCreationController extends WorkspaceController {
  new(super.repository);
  late final delayedStore = _DelayedCreationStore(repository);
  @override
  WorkspaceStore get store => identical(repository, delayedStore.repository)
      ? delayedStore
      : super.store;
}

class _DelayedCreationStore extends WorkspaceStore {
  new(super.repository);
  final entered = Completer<void>();
  final release = Completer<void>();

  Future<VaultNote> _wait(VaultNote note) async {
    entered.complete();
    await release.future;
    return note;
  }

  @override
  Future<VaultNote> create(
    String title, {
    String? folderId,
    VaultDocumentKind documentKind = VaultDocumentKind.handwriting,
  }) async => _wait(
    await super.create(title, folderId: folderId, documentKind: documentKind),
  );

  @override
  Future<VaultNote> createWithSource(
    String title, {
    required String fileName,
    required Uint8List bytes,
    required VaultDocumentKind documentKind,
    String? folderId,
    bool fromObsidian = false,
    String? sharedRequestId,
    SharedOfficeOriginal? sharedOfficeOriginal,
  }) async => _wait(
    await super.createWithSource(
      title,
      fileName: fileName,
      bytes: bytes,
      documentKind: documentKind,
      folderId: folderId,
      fromObsidian: fromObsidian,
      sharedRequestId: sharedRequestId,
      sharedOfficeOriginal: sharedOfficeOriginal,
    ),
  );
}
