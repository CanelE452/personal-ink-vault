import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/editor/saving_state.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// Ctrl+Z, Ctrl+Y and Ctrl+Shift+Z are focus shortcuts of the editor: they
/// reach the note on screen, and not while the user types elsewhere.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory directory;
  late WorkspaceController controller;
  late bool closed;

  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    directory = await Directory.systemTemp.createTemp('editor-keyboard-');
    controller = WorkspaceController(
      await NoteRepository.open(directory, createFormatVersion: 2),
    );
    closed = false;
    final hidden = stows.noteTabBarHidden.value;
    stows.noteTabBarHidden.value = false;
    addTearDown(() => stows.noteTabBarHidden.value = hidden);
    // a test that takes the text box would open the next note on it
    final lastTool = stows.lastTool.value;
    stows.lastTool.value = ToolId.fountainPen;
    addTearDown(() => stows.lastTool.value = lastTool);
  });

  tearDown(() async {
    if (!closed) {
      await controller.flush();
      controller.dispose();
      await controller.repository.close().timeout(const Duration(seconds: 20));
    }
    await directory.delete(recursive: true);
  });

  /// Lets the vault's file work run between frames.
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
    expect(done(), isTrue);
  }

  /// Saves the open note's strokes, so the vault can close.
  Future<void> saveOpenNote(WidgetTester tester) async {
    final editors = find.byType(Editor).evaluate();
    if (!controller.dirty || editors.isEmpty) return;
    final editor = (editors.single as StatefulElement).state as EditorState;
    unawaited(editor.saveToFile());
    for (var i = 0; i < 20 && controller.dirty; i++) {
      await drain(tester);
    }
  }

  /// Closes the vault while the test's fake time runs (the editor's last
  /// save starts when the screen goes).
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

  void workspaceTest(
    String name,
    Future<void> Function(WidgetTester) body, {
    TargetPlatform platform = TargetPlatform.android,
    Size size = const Size(1000, 900),
  }) {
    testWidgets(name, (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = platform;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      try {
        await body(tester);
      } finally {
        await saveOpenNote(tester);
        await tester.pumpWidget(const SizedBox());
        await closeWhilePumping(tester);
        debugDefaultTargetPlatformOverride = previous;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      }
    });
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: StudyWorkspace(controller: controller)),
      ),
    );
    await drain(tester, 40);
    expect(tester.takeException(), isNull);
  }

  Future<List<String>> createNotes(
    WidgetTester tester,
    List<String> titles,
  ) async => (await tester.runAsync(() async {
    final ids = <String>[];
    for (final title in titles) {
      await controller.createNote(title);
      ids.add(controller.activeSession!.note.id);
    }
    return ids;
  }))!;

  /// The open note's editor once its page is on screen; not [before].
  Future<EditorState> loadedEditor(
    WidgetTester tester, {
    EditorState? before,
  }) async {
    EditorState? editor() {
      final found = find.byType(Editor).evaluate();
      if (found.isEmpty) return null;
      final state = (found.single as StatefulElement).state as EditorState;
      if (identical(state, before)) return null;
      return state.coreInfo.pages.firstOrNull?.renderBox == null ? null : state;
    }

    await drainUntil(tester, () => editor() != null);
    return editor()!;
  }

  int strokes(EditorState editor) =>
      editor.coreInfo.pages.expand((page) => page.strokes).length;

  /// One pen (or [kind]) stroke across the middle of the note's first page.
  Future<void> drawStroke(
    WidgetTester tester,
    EditorState editor, {
    PointerDeviceKind kind = PointerDeviceKind.stylus,
  }) async {
    final page = editor.coreInfo.pages.first;
    final box = page.renderBox!;
    final center = Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(page.size.bottomRight(Offset.zero)),
    ).intersect(tester.getRect(find.byType(InteractiveCanvasViewer))).center;
    final pen = await tester.createGesture(kind: kind);
    await pen.down(center - const Offset(30, 5));
    await pen.moveTo(center);
    await pen.moveTo(center + const Offset(30, 5));
    await pen.up();
    await tester.pump();
  }

  /// An editor without a host: its title is the file name field. [onSave]
  /// hears each save.
  Future<EditorState> mountAlone(
    WidgetTester tester, {
    VoidCallback? onSave,
  }) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          // The text box (a Quill editor) needs its strings.
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(
            path: '/editor-keys',
            onSaveSnapshot: (_, _) async => onSave?.call(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  Future<void> pressCtrlShiftZ(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  Future<void> pressCtrlZ(WidgetTester tester) =>
      pressCtrl(tester, LogicalKeyboardKey.keyZ);

  workspaceTest('Ctrl+Z still works after switching notes', (tester) async {
    final ids = await createNotes(tester, ['A', 'B']);
    await mount(tester);
    final first = await loadedEditor(tester);
    // B → A → B through the tabs: each new editor starts before the old one
    // is gone.
    await tester.tap(find.byKey(ValueKey('document-tab-${ids.first}')));
    final a = await loadedEditor(tester, before: first);
    expect(controller.activeSession?.note.id, ids.first);
    await tester.tap(find.byKey(ValueKey('document-tab-${ids.last}')));
    final b = await loadedEditor(tester, before: a);
    expect(controller.activeSession?.note.id, ids.last);
    expect(a.mounted, isFalse);

    await drawStroke(tester, b);
    expect(strokes(b), 1);
    await pressCtrlZ(tester);
    expect(strokes(b), 0);
  });

  workspaceTest(
    'Ctrl+Z after a pen stroke and not while typing elsewhere',
    (tester) async {
      await createNotes(tester, ['필기']);
      await mount(tester);
      final editor = await loadedEditor(tester);
      await drawStroke(tester, editor);
      expect(strokes(editor), 1);
      await pressCtrlZ(tester);
      expect(strokes(editor), 0, reason: 'Ctrl+Z after the stroke undoes it');

      await drawStroke(tester, editor);
      expect(strokes(editor), 1);
      // The Markdown beside the note (a wide desktop window) takes the keys.
      await tester.tap(find.byTooltip('원문 편집'));
      await tester.pump();
      final field = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.expands,
      );
      await tester.tap(field);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(
        focused?.findAncestorWidgetOfExactType<TextField>(),
        same(tester.widget<TextField>(field)),
      );
      await pressCtrlZ(tester);
      expect(strokes(editor), 1, reason: 'the keys went to the Markdown');

      // A stroke brings the keys back to the note.
      await drawStroke(tester, editor);
      expect(strokes(editor), 2);
      await pressCtrlZ(tester);
      expect(strokes(editor), 1);
    },
    platform: TargetPlatform.windows,
    size: const Size(1400, 1000),
  );

  workspaceTest(
    'Ctrl+= and the arrow keys move the page, and not while typing elsewhere',
    (tester) async {
      await createNotes(tester, ['필기']);
      await mount(tester);
      final editor = await loadedEditor(tester);
      final transform = tester
          .widget<InteractiveCanvasViewer>(find.byType(InteractiveCanvasViewer))
          .transformationController!;
      Future<void> press(LogicalKeyboardKey key, {bool control = false}) async {
        if (control) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        }
        await tester.sendKeyEvent(key);
        if (control) {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        }
        await tester.pump();
      }

      await drawStroke(tester, editor); // the page has the keys
      final start = transform.value.clone();
      await press(LogicalKeyboardKey.equal, control: true);
      final zoomed = transform.value.getMaxScaleOnAxis();
      expect(zoomed, greaterThan(start.getMaxScaleOnAxis() + .05));
      // zoomed in twice, the page is over 100 wider than the view: the
      // arrows move it across (by one step of 50 each way)
      await press(LogicalKeyboardKey.equal, control: true);
      final x = transform.value.getTranslation().x;
      await press(LogicalKeyboardKey.arrowRight);
      expect(transform.value.getTranslation().x, closeTo(x - 50, 1e-6));
      await press(LogicalKeyboardKey.arrowLeft);
      expect(transform.value.getTranslation().x, closeTo(x, 1e-6));
      await press(LogicalKeyboardKey.minus, control: true);
      await press(LogicalKeyboardKey.minus, control: true);
      expect(
        transform.value.getMaxScaleOnAxis(),
        closeTo(start.getMaxScaleOnAxis(), 1e-6),
      );
      final y = transform.value.getTranslation().y;
      await press(LogicalKeyboardKey.arrowDown);
      expect(transform.value.getTranslation().y, closeTo(y - 50, 1e-6));
      await press(LogicalKeyboardKey.arrowUp);
      expect(transform.value.getTranslation().y, closeTo(y, 1e-6));

      // The Markdown beside the note (a wide desktop window) takes the keys.
      await tester.tap(find.byTooltip('원문 편집'));
      await tester.pump();
      final field = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.expands,
      );
      await tester.tap(field);
      await tester.pump();
      final scale = transform.value.getMaxScaleOnAxis();
      final top = transform.value.getTranslation().y;
      await press(LogicalKeyboardKey.equal, control: true);
      expect(
        transform.value.getMaxScaleOnAxis(),
        closeTo(scale, 1e-9),
        reason: 'Ctrl+= went to the Markdown',
      );
      await press(LogicalKeyboardKey.arrowDown);
      expect(
        transform.value.getTranslation().y,
        closeTo(top, 1e-9),
        reason: 'the arrow went to the Markdown',
      );
    },
    platform: TargetPlatform.windows,
    size: const Size(1400, 1000),
  );

  workspaceTest('the editor takes the focus when it opens in the workspace', (
    tester,
  ) async {
    await createNotes(tester, ['필기']);
    await mount(tester);
    final editor = await loadedEditor(tester);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Editor');
    // So Ctrl+Z works before the page was touched.
    final pages = editor.coreInfo.pages.length;
    await tester.tap(find.byKey(const ValueKey('editor-insert-page')));
    await drain(tester);
    expect(editor.coreInfo.pages, hasLength(pages + 1));
    await pressCtrlZ(tester);
    expect(editor.coreInfo.pages, hasLength(pages));
  });

  workspaceTest('⋯ 「이름 바꾸기」 renames the note in the workspace', (
    tester,
  ) async {
    await createNotes(tester, ['필기']);
    await mount(tester);
    await loadedEditor(tester);
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 바꾸기'));
    // the library's rename: the note is saved first, then its name is asked
    await drainUntil(tester, () => find.text('문서 이름').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField).last, '새 이름');
    await tester.tap(find.text('확인').last);
    await drainUntil(
      tester,
      () => controller.activeSession?.note.title == '새 이름',
    );
  });

  workspaceTest('⋯ holds the workspace\'s rows: 탭 줄 숨기기, 설정, 휴지통으로', (
    tester,
  ) async {
    final ids = await createNotes(tester, ['필기']);
    await mount(tester);
    await loadedEditor(tester);
    Future<void> menuRow(String text) async {
      await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(text));
      await tester.pumpAndSettle();
      await tester.tap(find.text(text));
    }

    // 문서 정보: the vault's note is on the device
    await menuRow('문서 정보');
    await tester.pumpAndSettle();
    expect(find.text('동기화'), findsOneWidget);
    expect(find.text('준비됨'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    await menuRow('탭 줄 숨기기');
    await drain(tester);
    expect(stows.noteTabBarHidden.value, isTrue);
    // hidden, the same row is the way back (Task 17)
    await menuRow('탭 줄 보이기');
    await drain(tester);
    expect(stows.noteTabBarHidden.value, isFalse);

    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    expect(find.text('전체 설정 열기'), findsOneWidget);
    await tester.tapAt(const Offset(5, 880));
    await tester.pumpAndSettle();

    // 휴지통으로: the library's 휴지통; the note's tab goes
    await menuRow('휴지통으로');
    await drainUntil(tester, () => controller.activeSession == null);
    expect(controller.notes.where((note) => note.id == ids.single), isEmpty);
  });

  workspaceTest('휴지통으로 does nothing while the note is 읽기 전용', (tester) async {
    final ids = await createNotes(tester, ['필기']);
    await mount(tester);
    final editor = await loadedEditor(tester);
    final actions = editor.widget.chrome!.actions;
    final context = tester.element(find.byType(Editor));
    expect(actions.run(AppActionIds.readOnly, context), isTrue);
    await drain(tester);
    expect(editor.inkLocked.value, isTrue);

    // the ⋯ menu dims the row (kit_doc_menu_test); the action refuses too
    actions.run(AppActionIds.moveToTrash, context);
    // as long as the unlocked trash below may take
    for (var i = 0; i < 8; i++) {
      await drain(tester);
    }
    expect(controller.activeSession?.note.id, ids.single);
    expect(controller.notes.where((note) => note.id == ids.single), isNotEmpty);

    // unlocked, it goes to the 휴지통 again
    expect(actions.run(AppActionIds.readOnly, context), isTrue);
    await drain(tester);
    expect(actions.run(AppActionIds.moveToTrash, context), isTrue);
    await drainUntil(tester, () => controller.activeSession == null);
    expect(controller.notes.where((note) => note.id == ids.single), isEmpty);
  });

  // Task 19 fix 1: the arrows move the page only while the editor itself
  // has the focus; on a button inside it they move the focus, as usual.
  testWidgets('the arrows move the focus, not the page, on a toolbar button', (
    tester,
  ) async {
    await mountAlone(tester);
    final transform = tester
        .widget<InteractiveCanvasViewer>(find.byType(InteractiveCanvasViewer))
        .transformationController!;
    FocusNode buttonFocus(String key) => Focus.of(
      tester.element(
        find
            .descendant(
              of: find.byKey(ValueKey(key)),
              matching: find.byType(KitIcon),
            )
            .first,
      ),
    );
    final pen = buttonFocus('editor-tool-pen');
    pen.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(pen));
    final before = transform.value.getTranslation();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      isNot(same(pen)),
      reason: 'the focus went on to the next button',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(transform.value.getTranslation().x, closeTo(before.x, 1e-9));
    expect(transform.value.getTranslation().y, closeTo(before.y, 1e-9));

    // in the file name field ← and → move its cursor, not the page (zoomed
    // in twice, so the page could move across)
    final canvas = tester.state<CanvasGestureDetectorState>(
      find.byType(CanvasGestureDetector),
    );
    canvas.zoomIn();
    canvas.zoomIn();
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    final across = transform.value.getTranslation().x;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(transform.value.getTranslation().x, closeTo(across, 1e-9));
  });

  testWidgets('Ctrl+Z in the file name field is the name\'s undo, not the ink\'s', (
    tester,
  ) async {
    final editor = await mountAlone(tester);
    await drawStroke(tester, editor);
    expect(strokes(editor), 1);

    final name = find.byType(TextField);
    await tester.tap(name);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TextField>(),
      same(tester.widget<TextField>(name)),
    );
    await pressCtrlZ(tester);
    expect(strokes(editor), 1, reason: 'the key stays with the name field');

    // A stroke takes the keys back: Ctrl+Z undoes ink again.
    await drawStroke(tester, editor);
    expect(strokes(editor), 2);
    await pressCtrlZ(tester);
    expect(strokes(editor), 1);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('Ctrl+Shift+Z in the text box is its redo, not the ink\'s', (
    tester,
  ) async {
    final editor = await mountAlone(tester);
    await drawStroke(tester, editor);
    await pressCtrlZ(tester);
    expect(strokes(editor), 0);
    expect(editor.history.canRedo, isTrue);

    final actions = tester
        .widget<AppActionScope>(find.byType(AppActionScope))
        .notifier!;
    actions.run(AppActionIds.toolText, tester.element(find.byType(Editor)));
    await tester.pump();
    expect(editor.coreInfo.pages.first.quill.focusNode.hasFocus, isTrue);
    await pressCtrlShiftZ(tester);
    expect(strokes(editor), 0, reason: 'the key stays with the text box');
    editor.cancelAutosaveAndMarkSaved();
  });

  // Final review A-2: 「지금 저장」 has a key.
  testWidgets('Ctrl+S saves now', (tester) async {
    var saves = 0;
    final editor = await mountAlone(tester, onSave: () => saves++);
    await drawStroke(tester, editor);
    expect(editor.savingState.value, SavingState.waitingToSave);
    await pressCtrl(tester, LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(saves, 1, reason: 'saved without waiting for the autosave');
    expect(editor.savingState.value, SavingState.saved);

    // in the file name field the key stays with the field, as Ctrl+Z does
    await drawStroke(tester, editor);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await pressCtrl(tester, LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(saves, 1);
    expect(editor.savingState.value, SavingState.waitingToSave);
    editor.cancelAutosaveAndMarkSaved();
  });

  // Final review A-3 (ledger: keyboard ownership; 13A minor: nothing tested
  // Ctrl+Y redoing ink): leaving the text box for another tool gives the
  // keys back to the page.
  testWidgets('after the text box, the pen button gives Ctrl+Z and Ctrl+Y '
      'back to the ink', (tester) async {
    final editor = await mountAlone(tester);
    final actions = tester
        .widget<AppActionScope>(find.byType(AppActionScope))
        .notifier!;
    actions.run(AppActionIds.toolText, tester.element(find.byType(Editor)));
    await tester.pump();
    expect(editor.coreInfo.pages.first.quill.focusNode.hasFocus, isTrue);

    await tester.tap(find.byKey(const ValueKey('editor-tool-pen')));
    await tester.pump();
    expect(editor.currentTool, isNot(Tool.textEditing));
    expect(editor.coreInfo.pages.first.quill.focusNode.hasFocus, isFalse);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Editor');

    await drawStroke(tester, editor);
    expect(strokes(editor), 1);
    await pressCtrlZ(tester);
    expect(strokes(editor), 0, reason: 'Ctrl+Z undid the stroke');
    await pressCtrl(tester, LogicalKeyboardKey.keyY);
    expect(strokes(editor), 1, reason: 'Ctrl+Y drew it again');
    await pressCtrlZ(tester);
    await pressCtrlShiftZ(tester);
    expect(strokes(editor), 1, reason: 'Ctrl+Shift+Z drew it again');

    // A finger on Android leaves the file name field focused; its stroke
    // still brings the keys back to the page.
    final fingerDrawing = stows.editorFingerDrawing.value;
    stows.editorFingerDrawing.value = true;
    addTearDown(() => stows.editorFingerDrawing.value = fingerDrawing);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('Editor'));
    await drawStroke(tester, editor, kind: PointerDeviceKind.touch);
    expect(strokes(editor), 2);
    await pressCtrlZ(tester);
    expect(strokes(editor), 1, reason: 'Ctrl+Z undid the finger stroke');
    editor.cancelAutosaveAndMarkSaved();
  });

  // Final review B-2: Android's back closes the note window and 「도구 막대
  // 사용자화」 first.
  testWidgets('back closes the note window first, in an editor alone', (
    tester,
  ) async {
    final editor = await mountAlone(tester);
    await tester.tap(find.byKey(const ValueKey('editor-note-sheet')));
    await tester.pumpAndSettle();
    expect(find.text('빠른 노트'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('빠른 노트'), findsNothing);
    expect(find.byType(Editor), findsOneWidget);
    expect(editor.mounted, isTrue);
    editor.cancelAutosaveAndMarkSaved();
  });

  workspaceTest('back closes the editor\'s windows before the note', (
    tester,
  ) async {
    final ids = await createNotes(tester, ['필기']);
    await mount(tester);
    final editor = await loadedEditor(tester);
    await tester.tap(find.byKey(const ValueKey('editor-note-sheet')));
    await tester.pumpAndSettle();
    expect(find.text('빠른 노트'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await drain(tester);
    expect(find.text('빠른 노트'), findsNothing);
    expect(controller.activeSession?.note.id, ids.single);

    editor.widget.chrome!.actions.run(
      AppActionIds.toolbarCustomize,
      tester.element(find.byType(Editor)),
    );
    await tester.pumpAndSettle();
    expect(find.text('도구 막대 사용자화'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await drain(tester);
    expect(find.text('도구 막대 사용자화'), findsNothing);
    expect(controller.activeSession?.note.id, ids.single);
    expect(editor.mounted, isTrue);

    // nothing open: back closes the note
    await tester.binding.handlePopRoute();
    await drainUntil(tester, () => controller.activeSession == null);
  });
}
