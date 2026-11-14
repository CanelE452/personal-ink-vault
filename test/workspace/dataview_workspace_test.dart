import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/dataview_result.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  final library = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];

  test(
    'a Dataview TASK writes one marker and reloads the current note',
    () async {
      final (directory, controller) = await _taskController();
      addTearDown(() => _closeTaskController(directory, controller));
      const source = '# 한글 🧪\r\n\r\n- [ ]  할 일\r\n';
      final note = await controller.store.createMarkdown(
        '할 일 대시보드',
        Uint8List.fromList(utf8.encode('\uFEFF$source')),
      );
      await controller.openNote(note);
      final revision = (await controller.repository.heads(
        note.markdownEntityId,
      )).single;
      final row = _taskRow(
        note,
        revision.revisionId,
        source.indexOf('[ ]') + 1,
      );

      await controller.setDataviewTask(row, true, isCurrent: () => true);

      final next = (await controller.repository.heads(note.markdownEntityId))
          .single;
      expect(next.parentRevisionIds, [revision.revisionId]);
      final expected = source.replaceFirst('[ ]', '[x]');
      expect(
        await controller.repository.readRevisionFile(next, 'summary.md'),
        utf8.encode('\uFEFF$expected'),
      );
      expect(controller.markdown, expected);
      expect(controller.markdownDirty, isFalse);
      expect(controller.activeSession?.markdownParents, [next.revisionId]);
    },
  );

  test(
    'Dataview TASK rejects an unsaved source and a stale revision',
    () async {
      final (directory, controller) = await _taskController();
      addTearDown(() => _closeTaskController(directory, controller));
      const source = '# 제목\n\n- [ ]  할 일\n';
      final note = await controller.store.createMarkdown(
        '할 일 원본',
        Uint8List.fromList(utf8.encode(source)),
      );
      await controller.openNote(note);
      final original = (await controller.repository.heads(
        note.markdownEntityId,
      )).single;
      final row = _taskRow(
        note,
        original.revisionId,
        source.indexOf('[ ]') + 1,
      );
      controller.editMarkdown('$source\n내 작업본');
      await expectLater(
        controller.setDataviewTask(row, true, isCurrent: () => true),
        throwsStateError,
      );
      expect(controller.markdown, '$source\n내 작업본');
      expect(
        (await controller.repository.heads(note.markdownEntityId))
            .single
            .revisionId,
        original.revisionId,
      );
      await controller.saveMarkdown();
      final saved = (await controller.repository.heads(note.markdownEntityId))
          .single;
      await expectLater(
        controller.setDataviewTask(row, true, isCurrent: () => true),
        throwsStateError,
      );
      expect(
        (await controller.repository.heads(note.markdownEntityId))
            .single
            .revisionId,
        saved.revisionId,
      );
      expect(controller.markdown, '$source\n내 작업본');
    },
  );

  testWidgets(
    'saved Dataview queries follow local revisions and open a note by ID',
    (tester) async {
      final width = ThemeData().platform == TargetPlatform.android
          ? 360.0
          : 1060.0;
      tester.view.physicalSize = Size(width, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final (directory, repository, controller, host, target) = await _io(
        tester,
        () async {
          final directory = await Directory.systemTemp.createTemp(
            'piv-dataview-study-',
          );
          await FileManager.init(
            documentsDirectory: p.join(directory.path, 'documents'),
            shouldWatchRootDirectory: false,
          );
          final repository = await NoteRepository.open(
            Directory(p.join(directory.path, 'vault')),
            createFormatVersion: 2,
          );
          final native = InkVaultNative.open(libraryPath: library!);
          final store = WorkspaceStore(repository, native: native);
          final folder = await LibraryStore(repository).createFolder('연구');
          final other = await LibraryStore(repository).createFolder('연구실');
          Future<VaultNote> note(
            String title,
            String source, {
            String? inFolder,
          }) => store.createMarkdown(
            title,
            Uint8List.fromList(utf8.encode(source)),
            folderId: inFolder,
          );
          final host = await note('검색 대시보드', _dashboard);
          await note('삽입된 조회', _embeddedDashboard);
          await note('포함된 조회 결과', '삽입된 문서에서 나가는 링크의 대상');
          await note('바깥 조회 결과', '[[검색 대시보드]]');
          final target = await note(
            '대상 연구',
            _body('진행', '연구/비전'),
            inFolder: folder.id,
          );
          await note('태그만 일치', _body('완료', '연구'), inFolder: folder.id);
          await note('속성만 일치', _body('진행', '업무'), inFolder: other.id);
          await note('다른 YAML 속성', '---\nstatus: 진행\ncomment: "#연구"\n---\n본문');
          final controller = WorkspaceController(
            repository,
            native: native,
            directoryProvider: () async =>
                Directory(p.join(directory.path, 'support')),
          );
          await controller.refresh();
          await controller.openNote(host);
          return (directory, repository, controller, host, target);
        },
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await _io(tester, () async {
          await controller.flush();
          controller.dispose();
          await repository.close();
          final owned = await directory.resolveSymbolicLinks();
          expect(
            p.dirname(owned),
            await Directory.systemTemp.resolveSymbolicLinks(),
          );
          expect(p.basename(owned), startsWith('piv-dataview-study-'));
          await Directory(owned).delete(recursive: true);
        });
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: StudyWorkspace(controller: controller)),
        ),
      );
      final editor = find.byType(MarkdownEditor);
      Finder text(String value) =>
          find.descendant(of: editor, matching: find.text(value));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(text('대상 연구'), findsOneWidget);
      expect(text('태그만 일치'), findsNothing);
      expect(text('속성만 일치'), findsNothing);
      expect(text('다른 YAML 속성'), findsNothing);
      expect(tester.widget<MarkdownEditor>(editor).source, _dashboard);
      await _wait(
        tester,
        () =>
            text('포함된 조회 결과').evaluate().length == 1 &&
            text('바깥 조회 결과').evaluate().length == 1,
      );

      final checkbox = find.descendant(
        of: editor,
        matching: find.byType(Checkbox),
      );
      expect(text('연구 초안 🧪'), findsOneWidget);
      expect(text('연구'), findsOneWidget);
      expect(tester.widget<Checkbox>(checkbox).value, isFalse);
      await tester.runAsync(() => tester.tap(checkbox));
      await _wait(
        tester,
        () =>
            checkbox.evaluate().length == 1 &&
            tester.widget<Checkbox>(checkbox).value == true,
      );
      await _io(tester, () async {
        final session = await controller.store.open(target);
        expect(
          await session.readMarkdown(),
          _body('진행', '연구/비전').replaceFirst('[ ]', '[x]'),
        );
      });

      await _io(tester, () async {
        final session = await controller.store.open(target);
        await session.saveMarkdown(_body('완료', '연구/비전'));
        await controller.refresh();
      });
      await tester.pumpAndSettle();
      expect(text('대상 연구'), findsNothing);

      await _io(tester, () async {
        final session = await controller.store.open(target);
        await session.saveMarkdown(_body('진행', '연구/비전'));
        await controller.store.rename(target, '이름 바뀐 연구');
        await controller.refresh();
      });
      await tester.pumpAndSettle();
      expect(text('이름 바뀐 연구'), findsOneWidget);
      expect(controller.activeSession!.note.id, host.id);
      await tester.runAsync(() => tester.tap(text('이름 바뀐 연구')));
      await _wait(
        tester,
        () =>
            controller.activeSession?.note.id == target.id &&
            editor.evaluate().length == 1 &&
            tester.widget<MarkdownEditor>(editor).source ==
                _body('진행', '연구/비전'),
      );
      expect(
        tester.widget<MarkdownEditor>(editor).source,
        _body('진행', '연구/비전'),
      );
      expect(tester.takeException(), isNull);
    },
    skip: library == null || !File(library).existsSync(),
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}

DataviewRow _taskRow(VaultNote note, String revisionId, int offset) =>
    DataviewRow(
      noteId: note.id,
      title: note.title,
      values: const [],
      task: DataviewTask(
        text: '할 일',
        line: 3,
        status: ' ',
        statusOffset: offset,
        revisionId: revisionId,
      ),
    );

Future<(Directory, WorkspaceController)> _taskController() async {
  final root = await Directory.systemTemp.createTemp('piv-dataview-task-');
  final repository = await NoteRepository.open(
    Directory(p.join(root.path, 'vault')),
    createFormatVersion: 2,
  );
  return (
    root,
    WorkspaceController(
      repository,
      directoryProvider: () async => Directory(p.join(root.path, 'support')),
    ),
  );
}

Future<void> _closeTaskController(
  Directory directory,
  WorkspaceController controller,
) async {
  await controller.flush();
  controller.dispose();
  await controller.repository.close();
  final owned = await directory.resolveSymbolicLinks();
  expect(p.dirname(owned), await Directory.systemTemp.resolveSymbolicLinks());
  expect(p.basename(owned), startsWith('piv-dataview-task-'));
  await Directory(owned).delete(recursive: true);
}

const _dashboard = '''
# 저장한 검색

```dataview
TABLE status AS "상태"
FROM #연구
WHERE (status = "진행" OR status = "대기") AND !archived
SORT status ASC, file.name DESC
```

```dataview
TASK
FROM #연구/비전
GROUP BY file.folder
```

```dataview
LIST FROM [[]]
```

![[삽입된 조회]]
''';

const _embeddedDashboard = '''
[[포함된 조회 결과|이 문서에서 나가는 링크]]

```dataview
LIST FROM outgoing([[]])
```
''';

String _body(String status, String tag) =>
    '---\nstatus: $status\ntags: [$tag]\n---\n연구 본문\n\n- [ ]  연구 초안 🧪';

Future<void> _wait(WidgetTester tester, bool Function() done) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 4)),
    );
    if (watch.elapsed > const Duration(seconds: 12))
      fail('Workspace test did not settle');
  }
  await tester.pump();
}

Future<T> _io<T>(WidgetTester tester, Future<T> Function() action) async {
  var done = false;
  T? result;
  (Object, StackTrace)? error;
  await tester.runAsync(() async {
    unawaited(
      action()
          .timeout(const Duration(seconds: 10))
          .then<void>(
            (value) {
              result = value;
              done = true;
            },
            onError: (Object failure, StackTrace trace) {
              error = (failure, trace);
              done = true;
            },
          ),
    );
  });
  await _wait(tester, () => done);
  final failure = error;
  if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
  return result as T;
}
