import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/save_indicator.dart';
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
  late Directory temp;
  late WorkspaceController controller;
  GoRouter? router;
  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('workspace-navigation-');
    controller = WorkspaceController(await NoteRepository.open(temp));
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    router?.dispose();
    await controller.saveMarkdown();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
  });

  Future<void> drain(WidgetTester tester, [int cycles = 20]) async {
    for (var i = 0; i < cycles; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<EditorState> mount(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
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
    final editor = tester.state<EditorState>(find.byType(Editor));
    expect(editor.coreInfo.filePath, isNotEmpty);
    expect(editor.coreInfo.readOnly, isFalse);
    return editor;
  }

  Future<void> backArrow(WidgetTester tester) async {
    await tester.runAsync(() async {
      tester
          .widget<IconButton>(
            find.descendant(
              of: find.byType(SaveIndicator),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await drain(tester);
  }

  testWidgets(
    'one back action saves ink and Markdown and returns to the list',
    (tester) async {
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      final note = await tester.runAsync(
        () => controller.createNote('Saved by back'),
      );
      final session = controller.activeSession!;
      final editor = await mount(tester);
      await tester.runAsync(() async {
        editor.drawTestStroke();
        controller.editMarkdown('Markdown saved by back');
      });
      await backArrow(tester);
      expect(controller.activeSession, isNull);
      expect(controller.dirty, isFalse);
      final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
      expect(scaffold.isDrawerOpen, isTrue);
      expect(find.byType(Editor), findsNothing);
      await tester.runAsync(() async {
        final saved = await controller.loadInk(session: session);
        expect(saved.pages.first.strokes, isNotEmpty);
        saved.dispose();
        expect(await session.readMarkdown(), 'Markdown saved by back');
        expect((await controller.store.list()).single.id, note!.id);
        controller.setInkDirty(true, session: session);
        expect(controller.dirty, isFalse);
      });
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  for (final dirty in [false, true]) {
    testWidgets(
      'system back closes Drawer first, then ${dirty ? 'saves and closes' : 'closes'} the editor',
      (tester) async {
        addTearDown(() => tester.pumpWidget(const SizedBox()));
        await tester.runAsync(() => controller.createNote('System back'));
        final session = controller.activeSession!;
        final editor = await mount(tester);
        final scaffold = tester.state<ScaffoldState>(
          find.byType(Scaffold).first,
        );
        scaffold.openDrawer();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(tester.binding.handlePopRoute);
        await drain(tester);
        expect(scaffold.isDrawerOpen, isFalse);
        expect(controller.activeSession, same(session));
        if (dirty) {
          await tester.runAsync(() async {
            editor.drawTestStroke();
            controller.editMarkdown('System-back Markdown');
          });
        }
        await tester.runAsync(tester.binding.handlePopRoute);
        await drain(tester);
        expect(controller.activeSession, isNull);
        expect(scaffold.isDrawerOpen, isTrue);
        if (dirty) {
          expect(
            await tester.runAsync(session.readMarkdown),
            'System-back Markdown',
          );
        }
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }

  testWidgets('back waits for an in-flight ink commit before closing', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.runAsync(() => controller.createNote('Pending save'));
    final session = (await tester.runAsync(
      () async => DelayedInkSession(controller.activeSession!),
    ))!;
    controller.activeSession = session;
    final editor = await mount(tester);
    Future<void>? pending;
    addTearDown(() async {
      if (!session.release.isCompleted) session.release.complete();
      await pending;
    });
    await tester.runAsync(() async {
      editor.drawTestStroke();
      pending = editor.saveToFile();
      await session.entered.future;
    });
    await backArrow(tester);
    expect(controller.activeSession, same(session));
    expect(controller.inkBusy, isTrue);
    await tester.runAsync(() async {
      session.release.complete();
      await pending;
    });
    await drain(tester);
    expect(controller.activeSession, isNull);
    final saved = await tester.runAsync(
      () => controller.loadInk(session: session),
    );
    expect(saved!.pages.first.strokes, isNotEmpty);
    saved.dispose();
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'wide back returns to library and home keeps the OS back action',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var exits = 0;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.pop') exits++;
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.runAsync(() => controller.createNote('Wide back'));
      await mount(tester);
      await backArrow(tester);
      expect(controller.activeSession, isNull);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold).first).drawer,
        isNull,
      );
      expect(exits, 0);
      await tester.runAsync(tester.binding.handlePopRoute);
      await drain(tester);
      expect(exits, 1);
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('failed save and busy ink keep the editor open for retry', (
    tester,
  ) async {
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.runAsync(() => controller.createNote('Do not discard'));
    final session = FailingInkSession(controller.activeSession!);
    controller.activeSession = session;
    final editor = await mount(tester);
    await tester.runAsync(() async => editor.drawTestStroke());
    await backArrow(tester);
    expect(controller.activeSession, same(session));
    expect(controller.inkDirty, isTrue);
    expect(find.textContaining('기기 저장 실패'), findsWidgets);
    session.failSave = false;
    await tester.runAsync(editor.saveToFile);
    controller.setInkBusy(true, session: session);
    await backArrow(tester);
    expect(controller.activeSession, same(session));
    expect(controller.inkBusy, isTrue);
    controller.setInkBusy(false, session: session);
    await backArrow(tester);
    expect(controller.activeSession, isNull);
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });
}

class FailingInkSession extends NoteSession {
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
  Future<void> saveInk(Map<String, Uint8List> files) async {
    if (failSave) throw const FileSystemException('Storage unavailable');
    await super.saveInk(files);
  }
}

class DelayedInkSession extends NoteSession {
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
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> saveInk(Map<String, Uint8List> files) async {
    entered.complete();
    await release.future;
    await super.saveInk(files);
  }
}
