import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

const _original = '왼쪽🙂 기존 오른쪽';
const _template = '{{title}} / {{date}} / {{time}} |';
const _changedWhileChoosing = '템플릿을 고르는 동안 바뀐 내용';

Uint8List _markdown(String value) => Uint8List.fromList(utf8.encode(value));

Future<T> _whilePumping<T>(
  WidgetTester tester,
  Future<T> Function() action,
) async {
  final complete = Completer<T>();
  await tester.runAsync(() async {
    unawaited(
      action().then(complete.complete, onError: complete.completeError),
    );
  });
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  while (!complete.isCompleted && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  if (!complete.isCompleted) throw TimeoutException('Workspace IO');
  return complete.future;
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 25));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(finder, findsOneWidget);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _waitFor(tester, finder);
  await tester.runAsync(() => tester.tap(finder));
  await tester.pump(const Duration(milliseconds: 250));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  for (final (platform, changeWhileChoosing) in [
    (TargetPlatform.android, false),
    (TargetPlatform.windows, false),
    (TargetPlatform.android, true),
  ]) {
    testWidgets(
      changeWhileChoosing
          ? 'android leaves an updated draft alone after the picker opens'
          : '${platform.name} inserts the selected nested template and saves one Markdown draft',
      (tester) async {
        late Directory root;
        late NoteRepository repository;
        late WorkspaceController workspace;
        late VaultNote target;
        late VaultNote flat;
        late VaultNote nested;
        await _whilePumping(tester, () async {
          await FileManager.init(shouldWatchRootDirectory: false);
          root = await Directory.systemTemp.createTemp('piv-template-ui-');
          repository = await NoteRepository.open(root, createFormatVersion: 2);
          workspace = WorkspaceController(repository);
          final library = LibraryStore(repository);
          final folder = await library.createFolder('템플릿 모음');
          final subfolder = await library.createFolder(
            '하위',
            parentId: folder.id,
          );
          final store = workspace.store;
          flat = await store.createMarkdown(
            '회의',
            _markdown('다른 템플릿'),
            folderId: folder.id,
          );
          nested = await store.createMarkdown(
            '회의',
            _markdown(_template),
            folderId: subfolder.id,
          );
          target = await store.createMarkdown('현재 노트', _markdown(_original));
          await workspace.openNote(target);
        });
        addTearDown(() async {
          await tester.runAsync(() async {
            workspace.dispose();
            await repository.close();
            await root.delete(recursive: true);
          });
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        tester.view.physicalSize = platform == TargetPlatform.android
            ? const Size(420, 880)
            : const Size(1100, 900);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(home: StudyWorkspace(controller: workspace)),
          ),
        );

        await _tap(tester, find.byTooltip('원문 편집'));
        final field = find.byType(TextField);
        final controller = tester.widget<TextField>(field).controller!;
        final start = _original.indexOf('기존');
        controller.selection = TextSelection(
          baseOffset: start,
          extentOffset: start + '기존'.length,
        );
        if (platform == TargetPlatform.windows) {
          await _tap(tester, find.byTooltip('미리보기'));
        }
        await _tap(tester, find.byKey(const ValueKey('markdown-templates')));
        await _tap(tester, find.text('폴더 설정'));
        await _tap(
          tester,
          find.byKey(const ValueKey('markdown-template-folder')),
        );
        await _tap(tester, find.text('템플릿 모음').hitTestable());
        await tester.enterText(
          find.byKey(const ValueKey('markdown-template-date-format')),
          'YYYY',
        );
        await tester.enterText(
          find.byKey(const ValueKey('markdown-template-time-format')),
          '[고정]',
        );
        await _tap(
          tester,
          find.byKey(const ValueKey('markdown-template-save-settings')),
        );
        await _waitFor(
          tester,
          find.byKey(ValueKey('markdown-template-${flat.id}')),
        );
        if (changeWhileChoosing) {
          await tester.runAsync(
            () async => workspace.editMarkdown(
              _changedWhileChoosing,
              session: workspace.activeSession,
            ),
          );
          await tester.pump();
        }
        await _tap(
          tester,
          find.byKey(ValueKey('markdown-template-${nested.id}')),
        );
        final inserted = '현재 노트 / ${DateTime.now().year} / 고정 |';
        final expected = changeWhileChoosing
            ? _changedWhileChoosing
            : '왼쪽🙂 $inserted 오른쪽';
        await _waitFor(tester, find.text(expected));
        expect(workspace.markdown, expected);
        expect(controller.text, expected);
        if (!changeWhileChoosing) {
          expect(
            controller.selection,
            TextSelection.collapsed(offset: start + inserted.length),
          );
        }
        await _whilePumping(tester, workspace.saveMarkdown);
        expect(
          await _whilePumping(
            tester,
            () async => (await workspace.store.open(target)).readMarkdown(),
          ),
          expected,
        );
        expect(
          (await _whilePumping(
            tester,
            repository.revisions,
          )).where((revision) => revision.entityId == target.markdownEntityId),
          hasLength(2),
        );
        expect(
          await _whilePumping(
            tester,
            () async => (await workspace.store.open(nested)).readMarkdown(),
          ),
          _template,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
      variant: TargetPlatformVariant({platform}),
    );
  }
}
