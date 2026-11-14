import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_editor.dart';
import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory directory;
  late WorkspaceController controller;
  GoRouter? router;
  final open = find.byKey(const ValueKey('workspace-quick-switch'));
  final query = find.byKey(const ValueKey('workspace-quick-switch-query'));
  Finder result(VaultNote note) =>
      find.byKey(ValueKey('workspace-quick-switch-result-${note.id}'));

  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    directory = await Directory.systemTemp.createTemp(
      'quick-switch-workspace-',
    );
    controller = WorkspaceController(
      await NoteRepository.open(directory, createFormatVersion: 2),
    );
  });

  tearDown(() async {
    router?.dispose();
    router = null;
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await directory.delete(recursive: true);
  });

  Future<void> drain(WidgetTester tester, [int cycles = 12]) async {
    await tester.runAsync(() async {
      for (var i = 0; i < cycles; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    });
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> mount(WidgetTester tester) async {
    router = GoRouter(
      initialLocation: '/workspace',
      routes: [
        GoRoute(
          path: '/workspace',
          builder: (_, _) => StudyWorkspace(controller: controller),
        ),
        GoRoute(path: '/home/:subpage', redirect: (_, _) => '/workspace'),
      ],
    );
    await tester.pumpWidget(
      TranslationProvider(child: MaterialApp.router(routerConfig: router)),
    );
    await drain(tester, 40);
    expect(tester.takeException(), isNull);
  }

  void platformTest(
    String name,
    TargetPlatform platform,
    Future<void> Function(WidgetTester) body,
  ) {
    testWidgets(name, (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = platform;
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = previous;
      }
    });
  }

  Future<void> openPicker(WidgetTester tester) async {
    expect(open, findsOneWidget);
    await tester.runAsync(() => tester.tap(open));
    await drain(tester);
    expect(query, findsOneWidget);
  }

  platformTest(
    'Android quick switch searches outside the current folder and saves the outgoing ink and Markdown',
    TargetPlatform.android,
    (tester) async {
      final (first, second) = (await tester.runAsync(() async {
        final lecture = await controller.library.createFolder('강의');
        final research = await controller.library.createFolder('연구');
        final first = await controller.store.create(
          '그래프',
          folderId: lecture.id,
          documentKind: VaultDocumentKind.markdown,
        );
        final second = await controller.store.create(
          '그래프',
          folderId: research.id,
          documentKind: VaultDocumentKind.markdown,
        );
        await controller.createNote('필기 초안');
        return (first, second);
      }))!;
      final outgoing = controller.activeSession!;
      await mount(tester);
      final editor = tester.state<EditorState>(find.byType(Editor));
      expect(
        editor.coreInfo.filePath,
        isNotEmpty,
        reason: tester
            .widgetList<Text>(find.textContaining('필기를 열 수 없습니다'))
            .map((widget) => widget.data)
            .join('\n'),
      );
      await tester.runAsync(() async {
        editor.drawTestStroke();
        controller.editMarkdown('전환 전 Markdown');
      });
      await openPicker(tester);
      await tester.enterText(query, '그래프');
      await tester.pump();
      expect(result(first), findsOneWidget);
      expect(result(second), findsOneWidget);
      expect(
        find.descendant(
          of: result(second),
          matching: find.textContaining('연구'),
        ),
        findsOneWidget,
      );
      await tester.tap(result(second));
      await drain(tester, 60);
      expect(
        controller.activeSession?.note.id,
        second.id,
        reason: tester
            .widgetList<Text>(find.textContaining(RegExp('실패|Bad state|오류')))
            .map((widget) => widget.data)
            .join('\n'),
      );
      expect(controller.navigation.current.markdown, isTrue);
      await tester.runAsync(() async {
        final ink = await controller.loadInk(session: outgoing);
        expect(ink.pages.first.strokes, isNotEmpty);
        ink.dispose();
        expect(await outgoing.readMarkdown(), '전환 전 Markdown');
      });
    },
  );

  platformTest(
    'Windows Ctrl+O reuses the remembered view of an open document tab',
    TargetPlatform.windows,
    (tester) async {
      final target = (await tester.runAsync(() async {
        final target = await controller.store.create(
          '탭 대상',
          documentKind: VaultDocumentKind.page,
        );
        await controller.openNote(
          target,
          markdownView: true,
          markdownAnchor: 'part',
        );
        await controller.createNote(
          '현재 문서',
          documentKind: VaultDocumentKind.markdown,
        );
        return target;
      }))!;
      await mount(tester);
      await tester.runAsync(() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      });
      await drain(tester);
      expect(query, findsOneWidget);
      await tester.enterText(query, '탭 대상');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await drain(tester);
      expect(controller.activeSession?.note.id, target.id);
      expect(controller.navigation.current.markdown, isTrue);
      expect(controller.navigation.current.markdownAnchor, 'part');
    },
  );

  platformTest(
    'quick switch rejects a result trashed while the picker is open',
    TargetPlatform.android,
    (tester) async {
      final target = (await tester.runAsync(() async {
        final target = await controller.store.create(
          '사라질 문서',
          documentKind: VaultDocumentKind.markdown,
        );
        await controller.createNote(
          '현재 문서',
          documentKind: VaultDocumentKind.markdown,
        );
        return target;
      }))!;
      final outgoing = controller.activeSession!;
      await mount(tester);
      await openPicker(tester);
      await tester.enterText(query, '사라질 문서');
      await tester.pump();
      expect(result(target), findsOneWidget);
      await tester.runAsync(() => controller.store.setDeleted(target, true));
      await tester.tap(result(target));
      await drain(tester, 60);
      expect(query, findsNothing);
      expect(controller.activeSession, same(outgoing));
      expect(find.textContaining('최신 문서를 다시 검색'), findsOneWidget);
    },
  );
}
