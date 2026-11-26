import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/infinite_canvas.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The infinite note's function row (Task 18 fix 1): its ⋯ holds 손가락
/// 필기 (the editor's setting) and 확대 비율, which its own toolbar has no
/// room for (right zone 원점으로 · 저장, no ⋯).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory directory;
  late WorkspaceController controller;
  late bool closed;
  GoRouter? router;

  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    directory = await Directory.systemTemp.createTemp('infinite-row-');
    controller = WorkspaceController(
      await NoteRepository.open(directory, createFormatVersion: 2),
    );
    closed = false;
    final hidden = stows.noteTabBarHidden.value;
    final shortcuts = stows.noteShortcutLayout.value;
    final finger = stows.editorFingerDrawing.value;
    stows.noteTabBarHidden.value = false;
    stows.noteShortcutLayout.value = const [];
    stows.editorFingerDrawing.value = false;
    stows.editorGestureMode.value = false;
    addTearDown(() {
      stows.noteTabBarHidden.value = hidden;
      stows.noteShortcutLayout.value = shortcuts;
      stows.editorFingerDrawing.value = finger;
    });
  });

  tearDown(() async {
    router?.dispose();
    router = null;
    if (!closed) {
      await controller.flush();
      controller.dispose();
      await controller.repository.close().timeout(const Duration(seconds: 20));
    }
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

  Future<void> drainUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 20 && !done(); i++) {
      await drain(tester);
    }
  }

  /// Closes the vault while the test's fake time runs.
  Future<void> closeWhilePumping(WidgetTester tester) async {
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        () async {
          await controller.flush();
          controller.dispose();
          await controller.repository.close().timeout(
            const Duration(seconds: 20),
          );
        }().whenComplete(() => done = true),
      );
    });
    for (var i = 0; i < 80 && !done; i++) {
      await drain(tester);
    }
    closed = done;
  }

  /// The workspace with an infinite note open, on an Android tablet.
  Future<InfiniteCanvasState> mountInfinite(WidgetTester tester) async {
    await tester.runAsync(
      () => controller.createNote(
        '무한 노트',
        documentKind: VaultDocumentKind.infinite,
      ),
    );
    const size = Size(1280, 800);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    await drainUntil(
      tester,
      () => find.byType(InfiniteCanvas).evaluate().isNotEmpty,
    );
    expect(tester.takeException(), isNull);
    return tester.state<InfiniteCanvasState>(find.byType(InfiniteCanvas));
  }

  void androidTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await closeWhilePumping(tester);
        debugDefaultTargetPlatformOverride = previous;
      }
    });
  }

  Finder key(String name) => find.byKey(ValueKey(name));

  /// Whether the switch of the ⋯ row [rowKey] shows on.
  bool switchOn(WidgetTester tester, String rowKey) => tester
      .widget<KitSwitch>(
        find.descendant(of: key(rowKey), matching: find.byType(KitSwitch)),
      )
      .value;

  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(key('workspace-more-actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  androidTest('the row ⋯ turns finger writing on for the infinite note', (
    tester,
  ) async {
    final canvas = await mountInfinite(tester);
    // in ⋯, not on the row's bar
    expect(
      find.descendant(
        of: key('note-function-row'),
        matching: find.byTooltip('손가락 필기'),
      ),
      findsNothing,
    );
    await openMore(tester);
    expect(key('note-more-finger'), findsOneWidget);
    expect(switchOn(tester, 'note-more-finger'), isFalse);
    // the switch turns as it is pressed, the window open
    await tester.tap(key('note-more-finger'));
    await tester.pump();
    expect(stows.editorFingerDrawing.value, isTrue);
    expect(switchOn(tester, 'note-more-finger'), isTrue);
    await tester.tap(key('note-more-finger'));
    await tester.pump();
    expect(stows.editorFingerDrawing.value, isFalse);
    expect(switchOn(tester, 'note-more-finger'), isFalse);
    await tester.tap(key('note-more-finger'));
    await tester.pump();
    expect(switchOn(tester, 'note-more-finger'), isTrue);
    await tester.tapAt(const Offset(640, 780));
    await drain(tester);
    final surface = find.byKey(const ValueKey('infinite-surface'));
    final page = tester.getTopLeft(surface);
    final finger = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 4,
    );
    await finger.down(page + const Offset(300, 300));
    await finger.moveTo(page + const Offset(360, 330));
    await finger.up();
    await tester.pump();
    expect(canvas.document.strokes, hasLength(1));
    // off again: a finger moves the view
    await openMore(tester);
    await tester.tap(key('note-more-finger'));
    await tester.pump();
    expect(stows.editorFingerDrawing.value, isFalse);
    await tester.tapAt(const Offset(640, 780));
    await drain(tester);
    final view = canvas.viewport.offset;
    await finger.down(page + const Offset(300, 300));
    await finger.moveTo(page + const Offset(360, 330));
    await finger.up();
    await tester.pump();
    expect(canvas.document.strokes, hasLength(1));
    expect(canvas.viewport.offset, view + const Offset(60, 30));
    // saved before the vault closes (a save awaited inside runAsync would
    // wait on the test's clock)
    unawaited(canvas.save());
    await drainUntil(tester, () => !controller.dirty);
    expect(controller.dirty, isFalse);
  });

  androidTest('확대 비율 in the row ⋯ zooms the infinite note', (tester) async {
    final canvas = await mountInfinite(tester);
    await openMore(tester);
    await tester.tap(key('note-more-zoom'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(key('note-more-zoom-2.0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(canvas.viewport.scale, closeTo(2, 1e-9));
    // the list shows the scale it has
    await openMore(tester);
    await tester.tap(key('note-more-zoom'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('200%'), findsWidgets);
    await tester.tapAt(const Offset(640, 780));
    await drain(tester);
  });

  androidTest('keys reach the infinite note opened in the workspace', (
    tester,
  ) async {
    final canvas = await mountInfinite(tester);
    final actions = tester
        .widget<KitEditorToolbar>(find.byType(KitEditorToolbar))
        .actions;
    Future<void> ctrl(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump();
    }

    // before any touch on the page: the note took the keys from the
    // workspace
    await ctrl(LogicalKeyboardKey.keyE);
    expect(actions.lookup(AppActionIds.toolEraser)!.checked, isTrue);
    await ctrl(LogicalKeyboardKey.keyE);
    await tester.tap(find.byKey(const ValueKey('editor-tool-pen')));
    await tester.pump();
    final page = tester.getTopLeft(
      find.byKey(const ValueKey('infinite-surface')),
    );
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(page + const Offset(300, 300));
    await pen.moveTo(page + const Offset(360, 330));
    await pen.up();
    await tester.pump();
    expect(canvas.document.strokes, hasLength(1));
    await ctrl(LogicalKeyboardKey.keyZ);
    expect(canvas.document.strokes, isEmpty);
    unawaited(canvas.save());
    await drainUntil(tester, () => !controller.dirty);
  });

  androidTest('확대 잠금 sits under the scales in the row ⋯', (tester) async {
    await mountInfinite(tester);
    final lock = stows.lastZoomLock.value;
    addTearDown(() => stows.lastZoomLock.value = lock);
    stows.lastZoomLock.value = false;
    await openMore(tester);
    await tester.tap(key('note-more-zoom'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.getTopLeft(key('note-more-zoom-lock')).dy,
      greaterThan(tester.getTopLeft(key('note-more-zoom-3.0')).dy),
    );
    await tester.tap(key('note-more-zoom-lock'));
    await tester.pump();
    // a submenu is built again the frame after its menu (KitMenu)
    await tester.pump();
    expect(stows.lastZoomLock.value, isTrue);
    expect(switchOn(tester, 'note-more-zoom-lock'), isTrue);
    await tester.tapAt(const Offset(640, 780));
    await drain(tester);
  });
}
