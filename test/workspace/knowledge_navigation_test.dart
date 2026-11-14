import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

class _FailingMarkdownSession extends NoteSession {
  new(NoteSession source)
    : super(
        source.repository,
        source.note,
        source.inkHeads,
        source.markdownHeads,
      ) {
    inkParents = List.of(source.inkParents);
    markdownParents = List.of(source.markdownParents);
  }

  var failSave = true;

  @override
  Future<void> saveMarkdown(
    String text, {
    Map<String, List<String>>? expectedHeads,
    void Function()? requireWrite,
  }) async {
    if (failSave)
      throw const FileSystemException('Markdown storage unavailable');
    await super.saveMarkdown(
      text,
      expectedHeads: expectedHeads,
      requireWrite: requireWrite,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late WorkspaceController controller;
  GoRouter? router;
  const ioTimeout = Duration(seconds: 8);
  final libraryPath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');

  Future<void> initialize(WidgetTester tester) async {
    await tester.runAsync(() async {
      debugPrint('knowledge navigation: initialize');
      await FileManager.init(shouldWatchRootDirectory: false)
          .timeout(ioTimeout);
      temp = await Directory.systemTemp
          .createTemp('knowledge-navigation-')
          .timeout(ioTimeout);
      controller = WorkspaceController(
        await NoteRepository.open(
          temp,
          createFormatVersion: 2,
        ).timeout(ioTimeout),
        native: InkVaultNative.open(libraryPath: libraryPath),
      );
      debugPrint('knowledge navigation: initialized');
    });
    addTearDown(
      () => tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        router?.dispose();
        router = null;
        final session = controller.activeSession;
        if (session is _FailingMarkdownSession) session.failSave = false;
        debugPrint('knowledge navigation: cleanup flush');
        try {
          await controller.flush().timeout(ioTimeout);
        } finally {
          controller.dispose();
          await controller.repository.close().timeout(ioTimeout);
        }
        final resolved = await temp.resolveSymbolicLinks().timeout(ioTimeout);
        expect(
          resolved,
          startsWith(
            '${await Directory.systemTemp.resolveSymbolicLinks()}${Platform.pathSeparator}knowledge-navigation-',
          ),
        );
        await Directory(resolved).delete(recursive: true).timeout(ioTimeout);
        debugPrint('knowledge navigation: cleanup complete');
      }),
    );
  }

  Future<void> drain(WidgetTester tester, [int cycles = 25]) async {
    for (var i = 0; i < cycles; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    }
    await tester.pump(const Duration(milliseconds: 200));
    for (var frame = 0; frame < 25; frame++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      final views = tester.widgetList<SingleChildScrollView>(
        find.descendant(
          of: find.byType(MarkdownPreview),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      if (views.every(
        (view) =>
            view.controller == null ||
            !view.controller!.hasClients ||
            !view.controller!.position.isScrollingNotifier.value,
      ))
        return;
    }
    fail('Markdown scrolling did not become idle before the next interaction');
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
    await drain(tester);
    expect(find.byType(MarkdownPreview), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  Finder rendered(String text) => find.byWidgetPredicate(
    (widget) =>
        widget is SelectableText &&
        (widget.data ?? widget.textSpan?.toPlainText()) == text,
  );

  void expectVisible(WidgetTester tester, String text) {
    final target = rendered(text);
    expect(target, findsOneWidget);
    final viewport = tester.getRect(find.byType(MarkdownPreview));
    final rect = tester.getRect(target);
    expect(rect.top, greaterThanOrEqualTo(viewport.top));
    expect(rect.bottom, lessThanOrEqualTo(viewport.bottom));
    expect(
      find.byKey(const ValueKey('markdown-anchor-unavailable')),
      findsNothing,
    );
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await drain(tester);
    expect(tester.takeException(), isNull);
  }

  Future<void> tapLink(WidgetTester tester, String label) async {
    final text = rendered(label);
    final editable = find.descendant(
      of: text,
      matching: find.byType(EditableText),
    );
    expect(editable, findsOneWidget);
    final render = tester.state<EditableTextState>(editable).renderEditable;
    final boxes = render.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: 1),
    );
    expect(boxes, isNotEmpty);
    final point = render.localToGlobal(boxes.first.toRect().center);
    expect(
      tester.getRect(find.byType(MarkdownPreview)).contains(point),
      isTrue,
    );
    await tester.runAsync(() async {
      debugPrint('knowledge navigation: tap $label');
      await tester.tapAt(point);
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await drain(tester);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'actual links and history reveal headings and blocks through StudyWorkspace',
    (tester) async {
      await initialize(tester);
      late VaultNote source, target;
      await tester.runAsync(() async {
        target = await controller.store.create(
          'Target',
          documentKind: VaultDocumentKind.markdown,
        );
        await (await controller.store.open(target)).saveMarkdown(
          [
            for (var i = 0; i < 55; i++) 'leading paragraph $i\n',
            '## Deep heading',
            '',
            '[open block](#^focus)',
            '',
            for (var i = 0; i < 55; i++) 'middle paragraph $i\n',
            'Block destination ^focus',
            '',
            for (var i = 0; i < 12; i++) 'ending paragraph $i\n',
          ].join('\n'),
        );
        source = await controller.store.create(
          'Source',
          documentKind: VaultDocumentKind.markdown,
        );
        await (await controller.store.open(source))
            .saveMarkdown('[[Target#Deep heading|open heading]]');
        await controller.openNote(source);
      });
      await mount(tester);
      await tapLink(tester, 'open heading');
      expect(controller.activeSession!.note.id, target.id);
      expect(controller.navigation.current.markdown, isTrue);
      expect(controller.navigation.current.markdownAnchor, 'Deep heading');
      expectVisible(tester, 'Deep heading');
      await tapLink(tester, 'open block');
      expect(controller.navigation.current.markdownAnchor, '^focus');
      expectVisible(tester, 'Block destination');

      await tap(tester, find.byTooltip('이전 위치'));
      expect(controller.navigation.current.markdownAnchor, 'Deep heading');
      expectVisible(tester, 'Deep heading');
      await tap(tester, find.byTooltip('이전 위치'));
      expect(controller.activeSession!.note.id, source.id);
      expect(controller.navigation.current.markdown, isTrue);
      expect(controller.navigation.current.markdownAnchor, isNull);
      await tap(tester, find.byTooltip('다음 위치'));
      expect(controller.activeSession!.note.id, target.id);
      expectVisible(tester, 'Deep heading');
      await tap(tester, find.byTooltip('다음 위치'));
      expect(controller.navigation.current.markdownAnchor, '^focus');
      expectVisible(tester, 'Block destination');
    },
  );

  testWidgets(
    'unlinked mentions link one saved occurrence and open its Markdown source',
    (tester) async {
      await initialize(tester);
      late VaultNote target, source;
      const first = '첫 번째 별칭 문서 확인';
      const second = '두 번째 별칭 문서 확인';
      await tester.runAsync(() async {
        target = await controller.store.create(
          '연결 대상',
          documentKind: VaultDocumentKind.markdown,
        );
        await (await controller.store.open(target))
            .saveMarkdown('---\naliases: [별칭 문서]\n---\n# 대상 본문');
        source = await controller.store.create('출발 요약');
        await (await controller.store.open(source))
            .saveMarkdown('$first\n\n$second\n');
        await controller.openNote(target);
      });
      await mount(tester);
      await tap(tester, find.byTooltip('문서 연결 · 태그 · 그래프'));
      expect(find.text('미연결 언급'), findsOneWidget);
      expect(find.text('이 문서를 가리키는 링크가 없습니다.'), findsOneWidget);
      expect(find.widgetWithText(TextButton, '링크로 연결'), findsNWidgets(2));

      await tap(
        tester,
        find.descendant(
          of: find.widgetWithText(ListTile, first),
          matching: find.widgetWithText(TextButton, '링크로 연결'),
        ),
      );
      expect(controller.activeSession!.note.id, target.id);
      expect(find.text('미연결 언급'), findsOneWidget);
      expect(find.text('이 문서를 가리키는 링크가 없습니다.'), findsNothing);
      expect(find.widgetWithText(TextButton, '링크로 연결'), findsOneWidget);
      await tester.runAsync(() async {
        final written = await (await controller.store.open(source))
            .readMarkdown();
        expect(
          written,
          '첫 번째 [별칭 문서](${NoteLink.markdown(target.id)}) 확인\n\n$second\n',
        );
      });

      await tap(tester, find.widgetWithText(ListTile, second));
      expect(find.text('미연결 언급'), findsNothing);
      expect(controller.activeSession!.note.id, source.id);
      expect(controller.navigation.current.markdown, isTrue);
    },
  );

  testWidgets(
    'same document anchor clicks reuse the session and reposition every request',
    (tester) async {
      await initialize(tester);
      await tester.runAsync(() async {
        final note = await controller.store.create(
          'Self',
          documentKind: VaultDocumentKind.markdown,
        );
        await (await controller.store.open(note)).saveMarkdown(
          [
            '[jump](#Deep%20heading)',
            '',
            for (var i = 0; i < 65; i++) 'paragraph $i\n',
            '# Deep heading',
            '',
            for (var i = 0; i < 12; i++) 'ending paragraph $i\n',
          ].join('\n'),
        );
        await controller.openNote(note);
      });
      await mount(tester);
      final session = controller.activeSession;
      await tapLink(tester, 'jump');
      expectVisible(tester, 'Deep heading');
      expect(controller.activeSession, same(session));
      final historyLength = controller.navigation.backLength;
      final scroll = tester.widget<SingleChildScrollView>(
        find
            .descendant(
              of: find.byType(MarkdownPreview),
              matching: find.byType(SingleChildScrollView),
            )
            .first,
      );
      scroll.controller!.jumpTo(0);
      await tester.pump();
      expect(tester.getTopLeft(rendered('Deep heading')).dy, greaterThan(760));
      await tapLink(tester, 'jump');
      expectVisible(tester, 'Deep heading');
      expect(controller.activeSession, same(session));
      expect(controller.navigation.backLength, historyLength);
      expect(controller.navigation.current.markdownAnchor, 'Deep heading');
    },
  );

  testWidgets(
    'failed dirty Markdown save keeps the current document and history during link clicks',
    (tester) async {
      await initialize(tester);
      debugPrint('failed save navigation: prepare documents');
      late VaultNote source;
      await tester.runAsync(() async {
        final target = await controller.store.create(
          'Target',
          documentKind: VaultDocumentKind.markdown,
        );
        await (await controller.store.open(target))
            .saveMarkdown('# Destination');
        source = await controller.store.create(
          'Source',
          documentKind: VaultDocumentKind.markdown,
        );
        await (await controller.store.open(source))
            .saveMarkdown('[[Target#Destination|open target]]');
        await controller.openNote(source).timeout(ioTimeout);
        debugPrint('failed save navigation: documents prepared');
      });
      debugPrint('failed save navigation: mount');
      await mount(tester);
      late _FailingMarkdownSession failing;
      const edited = '[[Target#Destination|open target]]\n\nUnsaved text';
      await tester.runAsync(() async {
        failing = _FailingMarkdownSession(controller.activeSession!);
        controller.activeSession = failing;
        controller.editMarkdown(edited, session: failing);
      });
      debugPrint('failed save navigation: rebuild edited preview');
      await tester.pump();
      debugPrint('failed save navigation: preview rebuilt');
      final navigationBefore = jsonEncode(controller.navigation.toJson());
      await tapLink(tester, 'open target');
      expect(controller.activeSession, same(failing));
      expect(controller.activeSession!.note.id, source.id);
      expect(controller.markdown, edited);
      expect(controller.markdownDirty, isTrue);
      expect(jsonEncode(controller.navigation.toJson()), navigationBefore);
      expect(
        tester.widget<MarkdownEditor>(find.byType(MarkdownEditor)).source,
        edited,
      );
      expect(find.textContaining('Markdown storage unavailable'), findsWidgets);
      failing.failSave = false;
      late Future<void> saved;
      await tester.runAsync(() async {
        debugPrint('failed save navigation: retry save');
        saved = controller.saveMarkdown();
      });
      await drain(tester);
      await tester.runAsync(() async {
        await saved.timeout(ioTimeout);
        expect(await failing.readMarkdown(), edited);
        expect(controller.markdownDirty, isFalse);
        debugPrint('failed save navigation: retry saved');
      });
    },
  );
}
