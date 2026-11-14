import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  Future<void> drain(WidgetTester tester, [int count = 8]) async {
    for (var i = 0; i < count; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
  }

  Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 80 && !ready(); i++) await drain(tester, 1);
    expect(ready(), isTrue);
  }

  Future<(Directory, _PublicationBarrier, WorkspaceController)> initialize(
    WidgetTester tester,
  ) async {
    late Directory temp;
    late _PublicationBarrier repository;
    late WorkspaceController controller;
    await tester.runAsync(() async {
      await FileManager.init(shouldWatchRootDirectory: false);
      temp = await Directory.systemTemp.createTemp('path-change-ui-');
      repository = _PublicationBarrier(
        await NoteRepository.open(temp, createFormatVersion: 2),
      );
      controller = WorkspaceController(
        repository,
        native: InkVaultNative.open(libraryPath: _nativePath),
        directoryProvider: () async => temp,
      );
    });
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() async {
      repository.releaseIfBlocked();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await controller.flush().timeout(const Duration(seconds: 8));
        controller.dispose();
        await repository.close();
        final actual = await temp.resolveSymbolicLinks();
        final parent = await Directory.systemTemp.resolveSymbolicLinks();
        expect(
          actual,
          startsWith('$parent${Platform.pathSeparator}path-change-ui-'),
        );
        await Directory(actual).delete(recursive: true);
      });
    });
    return (temp, repository, controller);
  }

  Future<void> mount(
    WidgetTester tester,
    WorkspaceController controller,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: StudyWorkspace(controller: controller)),
      ),
    );
    await drain(tester);
  }

  testWidgets(
    'the real note move menu protects the workspace while linked source publication is pending',
    (tester) async {
      try {
        final (_, repository, controller) = await initialize(tester);
        late VaultNote target, source;
        late String destination;
        await tester.runAsync(() async {
          final course = await controller.library.createFolder('Course');
          destination = (await controller.library.createFolder('Other')).id;
          target = await controller.store.create(
            'B',
            folderId: course.id,
            documentKind: VaultDocumentKind.markdown,
          );
          source = await controller.store.create(
            'Reader',
            documentKind: VaultDocumentKind.markdown,
          );
          await (await controller.store.open(source))
              .saveMarkdown('[read](Course/B.md)');
          await controller.openFolder(course.id);
          await controller.refresh();
        });
        await mount(tester, controller);
        repository.block(source.markdownEntityId);
        await tester.runAsync(
          () => tester.tap(
            find.byKey(
              ValueKey('library-note-menu-${target.revision.revisionId}'),
            ),
          ),
        );
        await drain(tester);
        await tester.runAsync(() => tester.tap(find.text('이동').last));
        await waitFor(
          tester,
          () => find.byType(SimpleDialog).evaluate().isNotEmpty,
        );
        await tester.runAsync(
          () => tester.tap(
            find.descendant(
              of: find.byType(SimpleDialog),
              matching: find.text('Other'),
            ),
          ),
        );
        await waitFor(tester, () => repository.entered.isCompleted);
        await tester.pump();
        final protected = controller.externalBusy;
        repository.releaseIfBlocked();
        await waitFor(
          tester,
          () => controller.notes.any(
            (n) => n.id == target.id && n.folderId == destination,
          ),
        );
        await drain(tester);

        expect(protected, isTrue);
        final text = await tester.runAsync(
          () async => (await controller.store.open(source)).readMarkdown(),
        );
        expect(text, '[read](inkvault://note/${target.id}?view=markdown)');
        final heads = await tester.runAsync(
          () => repository.heads(source.markdownEntityId),
        );
        expect(heads, hasLength(1));
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
    skip: !File(_nativePath).existsSync(),
  );

  testWidgets(
    'folder rename blocks old relative buffer input until normalized heads are loaded',
    (tester) async {
      try {
        final (_, repository, controller) = await initialize(tester);
        late VaultNote target, source;
        late String folderId;
        await tester.runAsync(() async {
          final course = await controller.library.createFolder('Course');
          folderId = course.id;
          target = await controller.store.create(
            'B',
            folderId: course.id,
            documentKind: VaultDocumentKind.markdown,
          );
          source = await controller.store.create(
            'Reader',
            documentKind: VaultDocumentKind.markdown,
          );
          await (await controller.store.open(source))
              .saveMarkdown('[read](Course/B.md)');
          await controller.openNote(source);
          await controller.refresh();
        });
        await mount(tester, controller);
        await tester.tap(find.byTooltip('원문 편집'));
        await tester.pump();
        final input = find.descendant(
          of: find.byType(MarkdownEditor),
          matching: find.byType(TextField),
        );
        expect(input, findsOneWidget);
        repository.block(source.markdownEntityId);
        final folderTile = find
            .ancestor(of: find.text('Course'), matching: find.byType(ListTile))
            .first;
        await tester.runAsync(
          () => tester.tap(
            find.descendant(
              of: folderTile,
              matching: find.byType(PopupMenuButton<LibraryFolderAction>),
            ),
          ),
        );
        await drain(tester);
        await tester.runAsync(() => tester.tap(find.text('이름 변경').last));
        await waitFor(
          tester,
          () => find.byType(AlertDialog).evaluate().isNotEmpty,
        );
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          'Changed',
        );
        await tester.runAsync(() => tester.tap(find.text('확인').last));
        await waitFor(tester, () => repository.entered.isCompleted);
        await tester.pump();
        await tester.tap(input, warnIfMissed: false);
        await tester.pump();
        if (tester.testTextInput.hasAnyClients)
          tester.testTextInput.enterText(
            '[read](Course/B.md) typed during rename',
          );
        await tester.pump();
        final typedDuringChange = controller.markdownDirty;
        repository.releaseIfBlocked();
        await waitFor(
          tester,
          () => controller.folders.any(
            (f) => f.id == folderId && f.title == 'Changed',
          ),
        );
        await drain(tester);
        await tester.runAsync(controller.flush);
        final heads = await tester.runAsync(
          () => repository.heads(source.markdownEntityId),
        );

        expect(typedDuringChange, isFalse);
        expect(
          heads,
          hasLength(1),
          reason:
              'A late old-path buffer must not publish a second source branch',
        );
        final files = await tester.runAsync(
          () => repository.readFiles(heads!.single),
        );
        expect(
          utf8.decode(files!['summary.md']!),
          '[read](inkvault://note/${target.id}?view=markdown)',
        );
        expect(controller.remoteConflict, isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    },
    skip: !File(_nativePath).existsSync(),
  );
}

final _nativePath =
    Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
    p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');

class _PublicationBarrier implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  String? entity;
  final entered = Completer<void>(), release = Completer<void>();
  void block(String id) => entity = id;
  void releaseIfBlocked() {
    if (!release.isCompleted) release.complete();
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
  int get pendingRevisionCount => inner.pendingRevisionCount;
  @override
  List<String> get integrityIssues => inner.integrityIssues;
  @override
  Stream<void> get changes => inner.changes;
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) =>
      inner.readFiles(record);
  @override
  Future<Uint8List> readBlob(String hash) => inner.readBlob(hash);
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
  Future<RevisionRecord> commit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) => inner.commit(
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
      inner.commitPrepared(prepared);
  @override
  Future<RevisionRecord> commitPreparedIfHeads(
    PreparedCommit prepared, {
    required Map<String, List<String>> expectedHeads,
    List<String>? expectedRevisionIds,
    void Function()? beforePublish,
    bool allowHistoricalParents = false,
  }) async {
    if (entity == prepared.record.entityId) {
      entity = null;
      entered.complete();
      await release.future;
    }
    return inner.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      expectedRevisionIds: expectedRevisionIds,
      beforePublish: beforePublish,
      allowHistoricalParents: allowHistoricalParents,
    );
  }

  @override
  Future<RevisionRecord> confirmPublishedCommit(PreparedCommit prepared) =>
      inner.confirmPublishedCommit(prepared);
  @override
  Future<void> close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
