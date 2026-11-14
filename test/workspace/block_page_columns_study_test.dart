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
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  test('Rust indexes text and backlinks from both columns without touching the summary', () async {
    final root = await Directory.systemTemp.createTemp('columns-study-');
    final repository = await NoteRepository.open(root, createFormatVersion: 2);
    addTearDown(() async {
      await repository.close();
      await _deleteFixture(root);
    });
    final library =
        Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
        p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');
    final native = InkVaultNative.open(libraryPath: library);
    final store = WorkspaceStore(repository, native: native);
    final target = await store.create(
      'Reference target',
      documentKind: VaultDocumentKind.markdown,
    );
    final page = await store.create(
      'Columns for search',
      documentKind: VaultDocumentKind.page,
    );
    final session = await store.open(page);
    await session.saveMarkdown('My separate Markdown summary');
    final group = BlockPageBlock.createColumns();
    final body = const BlockPageDocument.empty().copyWith(
      blocks: [
        group.copyWith(
          children: [
            group.children.first.copyWith(
              children: [
                BlockPageBlock.create(
                  type: 'heading2',
                  text: 'First column evidence',
                ),
              ],
            ),
            group.children.last.copyWith(
              children: [
                BlockPageBlock.create(
                  text: 'Second column evidence [[Reference target]] #column/test',
                ),
              ],
            ),
          ],
        ),
      ],
    );
    await session.saveInk({
      'page.json': Uint8List.fromList(utf8.encode(jsonEncode(body.toJson()))),
    });
    final index = await KnowledgeIndex.build(repository, native);
    expect(index.search('First column evidence').map((note) => note.id), [
      page.id,
    ]);
    expect(index.search('Second column evidence').map((note) => note.id), [
      page.id,
    ]);
    expect(index.backlinks(target.id).map((note) => note.id), [page.id]);
    expect(await session.readMarkdown(), 'My separate Markdown summary');
  });

  testWidgets(
    'Study creates, saves and reopens a two-column page',
    (tester) async {
      final phone = defaultTargetPlatform == TargetPlatform.android;
      tester.view.physicalSize = Size(phone ? 400 : 1600, 1050);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final fixture = await _io(tester, () async {
        final root = await Directory.systemTemp.createTemp('columns-study-');
        await FileManager.init(
          documentsDirectory: p.join(root.path, 'documents'),
          shouldWatchRootDirectory: false,
        );
        final repo = await NoteRepository.open(
          Directory(p.join(root.path, 'vault')),
          createFormatVersion: 2,
        );
        final controller = WorkspaceController(
          repo,
          directoryProvider: () async =>
              Directory(p.join(root.path, 'support')),
        );
        final note = await controller.createNote(
          'Columns workspace',
          documentKind: VaultDocumentKind.page,
        );
        return (root: root, repo: repo, controller: controller, note: note);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await _io(tester, () async {
          fixture.controller.dispose();
          await fixture.repo.close();
          await _deleteFixture(fixture.root);
        });
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: StudyWorkspace(controller: fixture.controller),
          ),
        ),
      );
      final page = find.byType(BlockPageEditor);
      await _wait(tester, () => page.evaluate().length == 1);
      expect(tester.widget<BlockPageEditor>(page).enableColumns, isTrue);
      final add = find.descendant(of: page, matching: find.byTooltip('블록 추가'));
      await tester.tap(add);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      await tester.tap(find.text('2단'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 240));
      BlockPageDocument current() =>
          tester.state<BlockPageEditorState>(page).document;
      BlockPageBlock layout() =>
          current().blocks.singleWhere((block) => block.isColumnLayout);
      final group = layout();
      final ids = [for (final column in group.children) column.id];
      final paneLeft = find.byKey(ValueKey('column-pane-${ids.first}'));
      final paneRight = find.byKey(ValueKey('column-pane-${ids.last}'));
      if (phone) {
        expect(
          tester.getTopLeft(paneRight).dy,
          greaterThan(tester.getTopLeft(paneLeft).dy),
        );
      } else {
        expect(
          tester.getTopLeft(paneRight).dx,
          greaterThan(tester.getTopLeft(paneLeft).dx),
        );
      }
      for (var i = 0; i < ids.length; i++) {
        final addParagraph = find.byKey(ValueKey('column-add-${ids[i]}'));
        await tester.ensureVisible(addParagraph);
        await tester.tap(addParagraph);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
        final block = layout().children[i].children.single;
        await tester.enterText(
          find.byKey(ValueKey('block-text-${block.id}')),
          'Pane ${i + 1} body',
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 240));
      }
      final save = find
          .descendant(of: page, matching: find.byTooltip('저장'))
          .first;
      await tester.tap(save);
      await _wait(
        tester,
        () =>
            !fixture.controller.dirty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      final saved = await _io(tester, () async {
        final head = (await fixture.repo.heads(fixture.note.inkEntityId))
            .single;
        final bytes = await fixture.repo.readRevisionFile(head, 'page.json');
        return _decodeDocument(bytes);
      });
      expect(saved.blocks.single.id, group.id);
      expect(saved.blocks.single.children.map((column) => column.id), ids);
      expect(saved.toMarkdown(), contains('Pane 1 body\n\nPane 2 body'));

      await tester.tap(
        find.descendant(of: page, matching: find.byTooltip('문서 목록으로')),
      );
      await _wait(tester, () => page.evaluate().isEmpty);
      await _io(tester, () => fixture.controller.openNote(fixture.note));
      await _wait(tester, () => page.evaluate().length == 1);
      expect(layout().children.map((column) => column.id), ids);
      expect(layout().children.map((column) => column.children.single.text), [
        'Pane 1 body',
        'Pane 2 body',
      ]);
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 50)),
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}

BlockPageDocument _decodeDocument(List<int> bytes) =>
    BlockPageDocument.fromJson(jsonObject(jsonDecode(utf8.decode(bytes))));

Future<void> _wait(WidgetTester tester, bool Function() done) async {
  final timer = Stopwatch()..start();
  while (!done()) {
    if (timer.elapsed > const Duration(seconds: 15))
      fail('Study did not reach the expected state');
    await tester.pump(const Duration(milliseconds: 16));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump();
}

Future<T> _io<T>(WidgetTester tester, Future<T> Function() action) async {
  var done = false;
  T? value;
  (Object, StackTrace)? failure;
  await tester.runAsync(() async {
    unawaited(
      action()
          .timeout(const Duration(seconds: 12))
          .then<void>(
            (result) {
              value = result;
              done = true;
            },
            onError: (Object error, StackTrace stack) {
              failure = (error, stack);
              done = true;
            },
          ),
    );
  });
  await _wait(tester, () => done);
  if (failure case final error?) Error.throwWithStackTrace(error.$1, error.$2);
  return value as T;
}

Future<void> _deleteFixture(Directory directory) async {
  final owned = await directory.resolveSymbolicLinks();
  expect(p.dirname(owned), await Directory.systemTemp.resolveSymbolicLinks());
  expect(p.basename(owned), startsWith('columns-study-'));
  await Directory(owned).delete(recursive: true);
}
