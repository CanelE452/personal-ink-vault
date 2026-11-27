import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bson/bson.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kPrimaryButton, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/audio/note_recorder.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/quick_note.dart';
import 'package:saber/data/editor/saving_state.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/editor/editor_chrome.dart';
import 'package:saber/pages/editor/editor_side_host.dart';
import 'package:sbn/tool_id.dart';

import '../audio/fake_audio_backends.dart';
import '../utils/paint_counts.dart';
import '../utils/test_mock_channel_handlers.dart';

/// The vault's attachments, whose quick note cannot be read while
/// [failReads] is above 0 (each failed read takes one off).
class _Store extends NoteSideStore {
  new(super.repository);

  var failReads = 0;

  @override
  Future<List<NoteSideRecord>> list(String noteId, NoteSideKind kind) async {
    if (kind == NoteSideKind.quickNote && failReads > 0) {
      failReads--;
      throw const FileSystemException('the quick note cannot be read');
    }
    return super.list(noteId, kind);
  }
}

/// The quick note window over the editor's page (supplement Task 13, 12th
/// draft `#extras12`: `.r1note`, `noteHtml`, `.r1npill`, the phone sheet),
/// and what task 5 left for the screen: the pen kind it writes with, one
/// pointer at a time, and the unsaved and read-only marks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  StrokeOptionsExtension.setDefaults();

  setUp(() async {
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    await FileManager.init();
    final saved = (
      stows.lastTool.value,
      stows.lastPenFamily.value,
      stows.editorToolbarTools.value,
      stows.pageToolbarLayout.value,
      stows.editorFingerDrawing.value,
      stows.quickNoteWindow.value,
      stows.quickNoteSheet.value,
    );
    stows.lastTool.value = ToolId.fountainPen;
    stows.lastPenFamily.value = ToolId.fountainPen;
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    stows.editorFingerDrawing.value = false;
    stows.quickNoteWindow.value = const [];
    stows.quickNoteSheet.value = 0.6;
    // no recorder: the toolbar holds no record button
    EditorAudioHost.debugAndroid = false;
    // only closing, folding and the editor going save
    EditorQuickNoteHost.debugSaveDelay = const Duration(hours: 1);
    addTearDown(() {
      stows.lastTool.value = saved.$1;
      stows.lastPenFamily.value = saved.$2;
      stows.editorToolbarTools.value = saved.$3;
      stows.pageToolbarLayout.value = saved.$4;
      stows.editorFingerDrawing.value = saved.$5;
      stows.quickNoteWindow.value = saved.$6;
      stows.quickNoteSheet.value = saved.$7;
      EditorAudioHost.debugAndroid = null;
      EditorQuickNoteHost.debugSaveDelay = null;
    });
  });

  /// Lets the vault's file work run outside the fake time, then builds a
  /// frame in it.
  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() done,
    String what,
  ) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await drain(tester);
    }
    expect(done(), isTrue, reason: what);
  }

  late _Store store;
  late NoteRepository repository;
  late String noteId;
  late Directory recordings;

  /// A vault of [format] with one note; [seed] commits to it first.
  Future<NoteSideBinding> openVault(
    WidgetTester tester,
    int format,
    Future<void> Function(NoteRepository repository, String noteId)? seed,
  ) async {
    final made = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('piv-quick-window-');
      final repository = await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: format,
      );
      final id = (await WorkspaceStore(repository).create('Quick')).id;
      await seed?.call(repository, id);
      return (repository, id, temp, _Store(repository));
    });
    // closed from the fake time: the editor's vault work waits in its queue
    addTearDown(() async {
      var closed = false;
      unawaited(
        made!.$1
            .close()
            .timeout(const Duration(seconds: 10))
            .whenComplete(() => closed = true),
      );
      await until(tester, () => closed, 'the vault closes');
      await tester.runAsync(() => made.$3.delete(recursive: true));
    });
    store = made!.$4;
    repository = made.$1;
    noteId = made.$2;
    recordings = Directory('${made.$3.path}/recordings');
    return (store: made.$4, noteId: made.$2);
  }

  /// The app [open] built, built again at another size.
  late Widget Function(Size size) app;

  /// The editor records on Android with a fake microphone.
  void useRecorder() {
    EditorAudioHost.debugAndroid = true;
    EditorAudioHost.debugNewRecorder = (notes, beforeStart) => NoteRecorder(
      recordings: notes,
      backend: FakeRecorderBackend(),
      directory: () async => recordings,
      clock: () => Duration.zero,
      now: () => DateTime(2026, 11, 27, 15, 20),
      keepScreenOn: (_) async {},
      beforeStart: beforeStart,
    );
    addTearDown(() => EditorAudioHost.debugNewRecorder = null);
  }

  /// The editor on a note at [path] of [size], in a vault of [format] (none
  /// when null).
  Future<EditorState> open(
    WidgetTester tester,
    String path, {
    Size size = const Size(1000, 1400),
    int? format = 2,
    Future<void> Function(NoteRepository repository, String noteId)? seed,
    String? pdfPath,
  }) async {
    final binding = format == null
        ? null
        : await openVault(tester, format, seed);
    final chrome = EditorChromeController()..noteSide = () => binding;
    addTearDown(chrome.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = EditorCoreInfo(filePath: path)..pages.add(EditorPage());
    app = (size) => MediaQuery(
      data: MediaQueryData(size: size),
      child: TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(
            path: path,
            pdfPath: pdfPath,
            loadSnapshot: () async => core,
            onSaveSnapshot: (_, _) async {},
            chrome: chrome,
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(size));
    // a PDF being brought in turns a spinner: it never settles
    pdfPath == null ? await tester.pumpAndSettle() : await tester.pump();
    final editor = tester.state<EditorState>(find.byType(Editor));
    if (format == 2) {
      await until(
        tester,
        () => !editor.side.audio.loading,
        'the note side is read',
      );
    } else {
      for (var i = 0; i < 5; i++) {
        await drain(tester);
      }
    }
    await tester.pump();
    return editor;
  }

  Future<void> close(WidgetTester tester, EditorState editor) async {
    editor.cancelAutosaveAndMarkSaved();
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await drain(tester);
    }
  }

  final noteButton = find.byKey(const ValueKey('editor-note-sheet'));
  final layer = find.byType(EditorQuickNoteLayer);
  final window = find.byKey(const ValueKey('quick-note-window'));
  final undo = find.byKey(const ValueKey('quick-note-undo'));
  final fold = find.byKey(const ValueKey('quick-note-fold'));
  final shut = find.byKey(const ValueKey('quick-note-close'));
  final handle = find.byKey(const ValueKey('quick-note-resize'));
  final grab = find.byKey(const ValueKey('quick-note-grab'));
  final sizeBadge = find.byKey(const ValueKey('quick-note-size'));
  final paper = find.byKey(const ValueKey('quick-note-page'));
  final pill = find.byKey(const ValueKey('quick-note-pill'));
  final unsaved = find.byKey(const ValueKey('quick-note-unsaved'));
  final readOnly = find.byKey(const ValueKey('quick-note-read-only'));
  final head = find.descendant(of: window, matching: find.text('빠른 노트'));

  /// Opens the quick note with 노트 창 (with its action unless [tap]) and
  /// waits for it to be read and to rise.
  Future<QuickNote> openQuick(
    WidgetTester tester,
    EditorState editor, {
    bool tap = true,
  }) async {
    if (tap) {
      await tester.tap(noteButton);
    } else {
      editor.actions.run(
        AppActionIds.quickNote,
        tester.element(find.byType(Editor)),
      );
    }
    await tester.pump();
    await until(
      tester,
      () => editor.side.quickNote.note.value != null,
      'the quick note is read',
    );
    await tester.pump(KitMotion.quickNoteRise);
    return editor.side.quickNote.note.value!;
  }

  /// A touch (a finger unless [kind]) from [from] by [by], in two steps.
  Future<void> dragBy(
    WidgetTester tester,
    Offset from,
    Offset by, {
    PointerDeviceKind kind = PointerDeviceKind.touch,
  }) async {
    final gesture = await tester.startGesture(from, kind: kind);
    await gesture.moveBy(by / 2);
    await tester.pump();
    await gesture.moveBy(by / 2);
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  /// [x], [y] on the quick note's page as the window shows it.
  Offset paperAt(WidgetTester tester, double x, double y) =>
      tester.getRect(paper).topLeft + Offset(x, y);

  /// A pen line from [x], [y] on the paper, [length] to the right.
  Future<void> write(
    WidgetTester tester,
    double x,
    double y, {
    double length = 120,
    PointerDeviceKind kind = PointerDeviceKind.stylus,
    int buttons = kPrimaryButton,
  }) async {
    final gesture = await tester.startGesture(
      paperAt(tester, x, y),
      kind: kind,
      buttons: buttons,
    );
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(Offset(length / 4, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();
  }

  /// Page units per pixel of the window's paper.
  double unit(WidgetTester tester, QuickNote quick) =>
      quick.page.size.width / tester.getRect(paper).width;

  testWidgets('노트 창 shows where the vault keeps attachments (format 2) '
      'only; the window starts 16 from the page area\'s top right', (
    tester,
  ) async {
    var editor = await open(tester, '/qn-shown');
    expect(noteButton, findsOneWidget);
    expect(editor.actions.lookup(AppActionIds.quickNote)?.label, '노트 창');
    expect(window, findsNothing);
    await openQuick(tester, editor);
    final area = tester.getRect(layer);
    expect(
      tester.getRect(window),
      Rect.fromLTWH(area.right - 360 - 16, area.top + 16, 360, 460),
    );
    // back closes it before the note
    expect(editor.closeOpenWindow(), isTrue);
    await tester.pump();
    expect(window, findsNothing);
    await close(tester, editor);

    for (final (path, format) in [('/qn-alone', null), ('/qn-format-1', 1)]) {
      editor = await open(tester, path, format: format);
      expect(noteButton, findsNothing, reason: path);
      expect(editor.actions.lookup(AppActionIds.quickNote), isNull);
      expect(editor.side.quickNote.available.value, isFalse);
      expect(window, findsNothing);
      await close(tester, editor);
    }
  });

  // Final fix wave minor 5: as 쪽 즐겨찾기 shows its state and waits for the note.
  testWidgets('노트 창 is checked while the window is open, off until the note '
      'is ready', (tester) async {
    final editor = await open(tester, '/qn-checked');
    AppAction action() => editor.actions.lookup(AppActionIds.quickNote)!;
    expect(action().enabled, isTrue);
    expect(action().checked, isFalse);
    await openQuick(tester, editor, tap: false);
    expect(action().checked, isTrue);
    await tester.tap(shut);
    await tester.pump();
    expect(action().checked, isFalse);
    await close(tester, editor);

    // a PDF brought in when the note opens that never got in: the note is
    // never ready
    final waiting = await open(
      tester,
      '/qn-not-ready',
      pdfPath: '/qn-not-ready/missing.pdf',
    );
    await until(tester, () => !waiting.coreInfo.readOnly, 'the note is read');
    expect(waiting.actions.lookup(AppActionIds.quickNote)?.enabled, isFalse);
    await close(tester, waiting);
  });

  testWidgets('dragging the head moves the window, inside the page area', (
    tester,
  ) async {
    final editor = await open(tester, '/qn-move');
    await openQuick(tester, editor);
    final area = tester.getRect(layer);
    final start = tester.getRect(window);
    await dragBy(tester, tester.getCenter(head), const Offset(-100, 60));
    expect(tester.getRect(window), start.shift(const Offset(-100, 60)));
    // it stays in while it is dragged, and where it is let go
    final gesture = await tester.startGesture(tester.getCenter(head));
    await gesture.moveBy(const Offset(-3000, -3000));
    await tester.pump();
    expect(tester.getRect(window).topLeft, area.topLeft);
    await gesture.moveBy(const Offset(6000, 6000));
    await tester.pump();
    expect(tester.getRect(window).bottomRight, area.bottomRight);
    await gesture.up();
    await tester.pump();
    expect(tester.getRect(window).bottomRight, area.bottomRight);
    await dragBy(tester, tester.getCenter(head), const Offset(-3000, -3000));
    expect(tester.getRect(window).topLeft, area.topLeft);
    expect(tester.getRect(window).size, start.size);
    await close(tester, editor);
  });

  testWidgets('the corner handle sizes it from 260 x 220 to the page area '
      'less 24; the page inside is as wide as the window and scrolls', (
    tester,
  ) async {
    final editor = await open(tester, '/qn-size');
    final quick = await openQuick(tester, editor);
    final area = tester.getRect(layer);
    final page = quick.page.size;
    expect(tester.getRect(paper).width, 360);
    // it grows no further than the page area's right edge: room first
    await dragBy(tester, tester.getCenter(handle), const Offset(60, 0));
    expect(tester.getRect(window).right, area.right);
    expect(tester.getRect(window).size, const Size(376, 460));
    await dragBy(tester, tester.getCenter(head), const Offset(-300, 0));
    final start = tester.getRect(window);

    // the size shows while it is sized
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(30, 30));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 30));
    await tester.pump();
    expect(find.text('436 × 520'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(sizeBadge, findsNothing);
    expect(tester.getRect(window), start.topLeft & const Size(436, 520));
    expect(stows.quickNoteWindow.value, [
      for (final value in [start.left - area.left, start.top - area.top])
        '$value',
      '436.0',
      '520.0',
    ]);
    // the page grows with the width
    expect(tester.getRect(paper).width, 436);
    expect(
      tester.getRect(paper).height,
      closeTo(page.height * 436 / page.width, 0.01),
    );

    await dragBy(tester, tester.getCenter(handle), const Offset(-3000, -3000));
    expect(tester.getRect(window).size, const Size(260, 220));
    await dragBy(tester, tester.getCenter(head), const Offset(-3000, -3000));
    await dragBy(tester, tester.getCenter(handle), const Offset(3000, 3000));
    expect(
      tester.getRect(window),
      area.topLeft & Size(area.width - 24, area.height - 24),
    );

    // a finger (not writing) scrolls the page up and down
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('quick-note-scroll')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(scroll.maxScrollExtent, greaterThan(0));
    await dragBy(tester, paperAt(tester, 300, 400), const Offset(0, -200));
    expect(scroll.pixels, greaterThan(0));
    expect(quick.page.strokes, isEmpty);
    await close(tester, editor);
  });

  testWidgets('strokes go into the quick note only', (tester) async {
    final editor = await open(tester, '/qn-ink');
    final quick = await openQuick(tester, editor);
    final document = editor.coreInfo.pages.first;
    await write(tester, 40, 30);
    expect(quick.page.strokes, hasLength(1));
    expect(document.strokes, isEmpty);
    final stroke = quick.page.strokes.single;
    expect(stroke.toolId, ToolId.fountainPen);
    // in the quick note's page units
    expect(stroke.points.first.x, closeTo(40 * unit(tester, quick), 2));
    expect(stroke.points.first.y, closeTo(30 * unit(tester, quick), 2));

    // a finger writes only where the editor lets fingers write
    await write(tester, 40, 90, kind: PointerDeviceKind.touch);
    expect(quick.page.strokes, hasLength(1));
    stows.editorFingerDrawing.value = true;
    await tester.pump();
    await write(tester, 40, 90, kind: PointerDeviceKind.touch);
    expect(quick.page.strokes, hasLength(2));
    // in gesture mode nothing writes
    stows.editorGestureMode.value = true;
    await tester.pump();
    await write(tester, 40, 150);
    stows.editorGestureMode.value = false;
    await tester.pump();
    expect(quick.page.strokes, hasLength(2));
    expect(document.strokes, isEmpty);
    expect(editor.savingState.value, SavingState.saved);
    await close(tester, editor);
  });

  testWidgets('실행 취소 takes back the quick note\'s strokes', (tester) async {
    final semantics = tester.ensureSemantics();
    final editor = await open(tester, '/qn-undo');
    final quick = await openQuick(tester, editor);
    // off while there is nothing to take back, and said to be off
    expect(tester.widget(undo), isA<Opacity>());
    expect(
      tester.getSemantics(undo),
      isSemantics(
        label: '실행 취소',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    await write(tester, 40, 30);
    await write(tester, 40, 90);
    expect(tester.widget(undo), isA<InkWell>());
    await tester.tap(undo);
    await tester.pump();
    expect(quick.page.strokes, hasLength(1));
    // the last one went
    expect(
      quick.page.strokes.single.points.first.y,
      closeTo(30 * unit(tester, quick), 2),
    );
    await tester.tap(undo);
    await tester.pump();
    expect(quick.page.strokes, isEmpty);
    expect(tester.widget(undo), isA<Opacity>());
    expect(editor.coreInfo.pages.first.strokes, isEmpty);
    await close(tester, editor);
    semantics.dispose();
  });

  testWidgets('접기 folds it into its pill and saves; the pill opens it again; '
      '닫기 saves', (tester) async {
    final editor = await open(tester, '/qn-fold');
    final quick = await openQuick(tester, editor);
    await write(tester, 40, 30);
    expect(quick.hasUnsavedChanges, isTrue);
    final shown = tester.getRect(window);

    await tester.tap(fold);
    await tester.pump();
    expect(window, findsNothing);
    expect(pill, findsOneWidget);
    expect(tester.getSemantics(pill).label, '빠른 노트 펼치기');
    // at the head's right end
    expect(tester.getRect(pill).right, shown.right);
    expect(tester.getRect(pill).top, shown.top);
    await until(tester, () => !quick.hasUnsavedChanges, 'folding saves');
    // the pill moves
    final at = tester.getRect(pill);
    await dragBy(tester, tester.getCenter(pill), const Offset(-200, 100));
    expect(tester.getRect(pill), at.shift(const Offset(-200, 100)));

    await tester.tap(pill);
    await tester.pump();
    expect(pill, findsNothing);
    expect(tester.getRect(window), shown);
    await write(tester, 40, 90);
    expect(quick.hasUnsavedChanges, isTrue);

    await tester.tap(shut);
    await tester.pump();
    expect(window, findsNothing);
    expect(pill, findsNothing);
    expect(editor.side.quickNote.open.value, isFalse);
    await until(tester, () => !quick.hasUnsavedChanges, 'closing saves');
    final saved = await tester.runAsync(() async {
      final again = await QuickNote.open(store, noteId);
      final count = again.page.strokes.length;
      again.dispose();
      return count;
    });
    expect(saved, 2);
    await close(tester, editor);
  });

  testWidgets('on a phone it is a sheet that rests at 40, 60 or 90%, kept', (
    tester,
  ) async {
    const phone = Size(360, 740);
    var editor = await open(tester, '/qn-phone', size: phone);
    final quick = await openQuick(tester, editor, tap: false);
    final area = tester.getRect(layer);
    double share() => tester.getRect(window).height / area.height;
    expect(tester.getRect(window).bottom, area.bottom);
    expect(tester.getRect(window).width, area.width);
    expect(share(), closeTo(0.6, 1e-6));
    // no grip to move it and no handle to size it
    expect(handle, findsNothing);

    Future<void> pull(double by) =>
        dragBy(tester, tester.getCenter(grab), Offset(0, by * area.height));
    final page =
        editor.coreInfo.pages.first.innerCanvasKey.currentContext!
                .findRenderObject()!
            as RenderRepaintBoundary;
    final pageBefore = paintCounts(page);
    await pull(-0.25);
    // pulling the sheet paints no page
    expectNotPainted(page, pageBefore);
    expect(share(), closeTo(0.9, 1e-6));
    expect(stows.quickNoteSheet.value, 0.9);
    await pull(0.45);
    expect(share(), closeTo(0.4, 1e-6));
    await pull(-0.15);
    expect(share(), closeTo(0.6, 1e-6));
    // while it is pulled it goes no further than 94%
    final gesture = await tester.startGesture(tester.getCenter(grab));
    await gesture.moveBy(const Offset(0, -3000));
    await tester.pump();
    expect(share(), closeTo(0.94, 1e-6));
    await gesture.up();
    await tester.pump();
    expect(share(), closeTo(0.9, 1e-6));
    await pull(0.48);
    expect(share(), closeTo(0.4, 1e-6));

    // where there is no room the page scrolls
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('quick-note-scroll')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(scroll.maxScrollExtent, greaterThan(0));
    await write(tester, 40, 30);
    expect(quick.page.strokes, hasLength(1));

    // folded: the pill in the middle, 16 over the foot
    await tester.tap(fold);
    await tester.pump();
    expect(tester.getRect(pill).center.dx, closeTo(area.center.dx, 0.01));
    expect(tester.getRect(pill).bottom, area.bottom - 16);
    await close(tester, editor);

    // the sheet comes back at the height it was left
    editor = await open(tester, '/qn-phone-again', size: phone);
    await openQuick(tester, editor, tap: false);
    expect(share(), closeTo(0.4, 1e-6));
    await close(tester, editor);
  });

  testWidgets('the window comes back where it was left, at its size', (
    tester,
  ) async {
    var editor = await open(tester, '/qn-kept');
    await openQuick(tester, editor);
    await dragBy(tester, tester.getCenter(head), const Offset(-300, 200));
    await dragBy(tester, tester.getCenter(handle), const Offset(80, 40));
    final kept = tester.getRect(window);
    expect(kept.size, const Size(440, 500));
    expect(stows.quickNoteWindow.value, hasLength(4));
    await close(tester, editor);

    editor = await open(tester, '/qn-kept-again');
    await openQuick(tester, editor);
    expect(tester.getRect(window), kept);
    await close(tester, editor);
  });

  testWidgets('moving, sizing and writing in it paint no page and no '
      'toolbar', (tester) async {
    final editor = await open(tester, '/qn-paint');
    final quick = await openQuick(tester, editor);
    await write(tester, 40, 30);
    await tester.pump();

    RenderRepaintBoundary boundary(Finder of) =>
        tester.renderObject<RenderRepaintBoundary>(
          find.descendant(of: of, matching: find.byType(RepaintBoundary)).first,
        );
    final page =
        editor.coreInfo.pages.first.innerCanvasKey.currentContext!
                .findRenderObject()!
            as RenderRepaintBoundary;
    final toolbar = boundary(find.byType(KitEditorToolbar));
    final drawn = tester.renderObject<RenderRepaintBoundary>(
      find.ancestor(of: paper, matching: find.byType(RepaintBoundary)).first,
    );
    final pageBefore = paintCounts(page);
    final toolbarBefore = paintCounts(toolbar);
    final drawnBefore = drawn.debugAsymmetricPaintCount;
    // the editor builds nothing again: the same layer and toolbar widgets
    final layerBuilt = tester.widget(layer);
    final toolbarBuilt = tester.widget(find.byType(KitEditorToolbar));

    await dragBy(tester, tester.getCenter(head), const Offset(-120, 80));
    await write(tester, 40, 90);
    await dragBy(tester, tester.getCenter(handle), const Offset(40, 40));
    await write(tester, 40, 150);

    expect(quick.page.strokes, hasLength(3));
    expect(drawn.debugAsymmetricPaintCount, greaterThan(drawnBefore));
    expectNotPainted(page, pageBefore);
    expectNotPainted(toolbar, toolbarBefore);
    expect(identical(tester.widget(layer), layerBuilt), isTrue);
    expect(
      identical(tester.widget(find.byType(KitEditorToolbar)), toolbarBuilt),
      isTrue,
    );
    expect(editor.coreInfo.pages.first.strokes, isEmpty);
    await close(tester, editor);
  });

  testWidgets('it rises in KitMotion.quickNoteRise (160 ms)', (tester) async {
    expect(KitMotion.quickNoteRise, const Duration(milliseconds: 160));
    final editor = await open(tester, '/qn-rise');
    await tester.tap(noteButton);
    await tester.pump();
    double opacity() => tester
        .widget<FadeTransition>(
          find.descendant(of: layer, matching: find.byType(FadeTransition)),
        )
        .opacity
        .value;
    expect(opacity(), 0);
    await tester.pump(const Duration(milliseconds: 80));
    expect(opacity(), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 80));
    expect(opacity(), 1);
    await until(
      tester,
      () => editor.side.quickNote.note.value != null,
      'the quick note is read',
    );
    await close(tester, editor);
  });

  testWidgets('with the lasso, the text box, the laser or the shape pen in '
      'hand it writes with the last pen kind; the eraser rubs out whole '
      'strokes', (tester) async {
    final editor = await open(tester, '/qn-pens');
    final quick = await openQuick(tester, editor);
    final context = tester.element(find.byType(Editor));
    // the stroke the next line writes (a highlighter goes under the pens)
    Future<ToolId> writes(double y) async {
      final before = [...quick.page.strokes];
      await write(tester, 40, y);
      return quick.page.strokes.where((s) => !before.contains(s)).single.toolId;
    }

    // the pen in hand
    expect(await writes(30), ToolId.fountainPen);
    editor.actions.run(AppActionIds.toolHighlighter, context);
    await tester.pump();
    expect(await writes(70), ToolId.highlighter);

    var y = 70.0;
    for (final id in [
      AppActionIds.toolLasso,
      AppActionIds.toolText,
      AppActionIds.toolLaser,
      AppActionIds.toolShapes,
    ]) {
      editor.actions.run(id, context);
      await tester.pump();
      y += 40;
      expect(await writes(y), ToolId.highlighter, reason: id);
    }
    expect(quick.page.strokes, hasLength(6));

    // the eraser at the pen stroke's start takes all of it
    editor.actions.run(AppActionIds.toolEraser, context);
    await tester.pump();
    final pen = quick.page.strokes.singleWhere(
      (stroke) => stroke.toolId == ToolId.fountainPen,
    );
    await write(tester, 40, 30, length: 4);
    expect(quick.page.strokes, hasLength(5));
    expect(quick.page.strokes, isNot(contains(pen)));
    for (final stroke in quick.page.strokes) {
      expect(stroke.points.length, greaterThan(2));
    }
    expect(editor.coreInfo.pages.first.strokes, isEmpty);
    await close(tester, editor);
  });

  testWidgets('one pointer writes at a time; a cancelled touch ends its '
      'stroke', (tester) async {
    final editor = await open(tester, '/qn-pointer');
    final quick = await openQuick(tester, editor);
    final a = await tester.startGesture(
      paperAt(tester, 40, 30),
      kind: PointerDeviceKind.stylus,
    );
    final b = await tester.startGesture(
      paperAt(tester, 40, 150),
      kind: PointerDeviceKind.stylus,
    );
    await a.moveBy(const Offset(60, 0));
    await b.moveBy(const Offset(60, 0));
    await tester.pump();
    await b.up();
    await tester.pump();
    expect(quick.page.strokes, isEmpty, reason: 'the second pen wrote');
    expect(quick.currentStroke.value, isNotNull);
    await a.up();
    await tester.pump();
    expect(quick.page.strokes, hasLength(1));
    expect(
      quick.page.strokes.single.points.first.y,
      closeTo(30 * unit(tester, quick), 2),
    );

    final c = await tester.startGesture(
      paperAt(tester, 40, 100),
      kind: PointerDeviceKind.stylus,
    );
    await c.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(quick.currentStroke.value, isNotNull);
    await c.cancel();
    await tester.pump();
    expect(quick.currentStroke.value, isNull);
    expect(quick.page.strokes, hasLength(2));
    // and the next pen writes again
    await write(tester, 40, 170);
    expect(quick.page.strokes, hasLength(3));
    await close(tester, editor);
  });

  testWidgets('the head says ink is not saved yet; a read-only quick note '
      'says so and takes no ink', (tester) async {
    var editor = await open(tester, '/qn-marks');
    var quick = await openQuick(tester, editor);
    expect(unsaved, findsNothing);
    await write(tester, 40, 30);
    expect(unsaved, findsOneWidget);
    expect(readOnly, findsNothing);
    unawaited(editor.side.quickNote.flush());
    await until(tester, () => !quick.hasUnsavedChanges, 'it saves');
    await tester.pump();
    expect(unsaved, findsNothing);
    await close(tester, editor);

    // a quick note written by a newer app
    editor = await open(
      tester,
      '/qn-read-only',
      seed: (repository, noteId) async => repository.commit(
        entityId: newId(),
        kind: EntityKind.attachment,
        ownerNoteId: noteId,
        files: _newerQuickNote(),
        parentRevisionIds: [],
      ),
    );
    quick = await openQuick(tester, editor);
    expect(quick.readOnly, isTrue);
    expect(readOnly, findsOneWidget);
    expect(unsaved, findsNothing);
    expect(quick.page.strokes, hasLength(1));
    await write(tester, 40, 90);
    expect(quick.page.strokes, hasLength(1));
    expect(quick.currentStroke.value, isNull);
    expect(tester.widget(undo), isA<Opacity>());
    await close(tester, editor);
  });
  // Fix round 1 (task 13 review).

  testWidgets('closing the editor saves what was written in the quick note', (
    tester,
  ) async {
    final editor = await open(tester, '/qn-editor-closes');
    await openQuick(tester, editor);
    await write(tester, 40, 30);
    await write(tester, 40, 90);
    // the editor goes (the note closes or another opens) with the window open
    await close(tester, editor);
    // read back from the fake time, behind the save in the vault's queue
    int? saved;
    unawaited(
      QuickNote.open(store, noteId).then((again) {
        saved = again.page.strokes.length;
        again.dispose();
      }),
    );
    await until(tester, () => saved != null, 'it is read back');
    expect(saved, 2);
  });

  testWidgets('turning read-only while it saves shows both marks, and the '
      'ink kept in memory says it is not saved', (tester) async {
    final semantics = tester.ensureSemantics();
    final editor = await open(tester, '/qn-turns-read-only');
    final quick = await openQuick(tester, editor);
    await write(tester, 40, 30);
    expect(find.bySemanticsLabel('저장 안 됨'), findsOneWidget);
    unawaited(editor.side.quickNote.flush());
    await until(tester, () => !quick.hasUnsavedChanges, 'it saves');
    final seen = (await tester.runAsync(
      () => store.list(noteId, NoteSideKind.quickNote),
    ))!.single;

    await write(tester, 40, 90);
    // a newer app writes the quick note while this one saves
    var arrivals = 0;
    store.beforeCommit = () async {
      if (arrivals++ > 0) return;
      await repository.commit(
        entityId: seen.entityId,
        kind: EntityKind.attachment,
        ownerNoteId: noteId,
        files: _newerQuickNote(),
        parentRevisionIds: [seen.revisionId],
      );
    };
    addTearDown(() => store.beforeCommit = null);
    unawaited(editor.side.quickNote.flush());
    await until(tester, () => quick.readOnly, 'it turns read-only');
    await tester.pump();
    expect(quick.hasUnsavedChanges, isTrue);
    expect(readOnly, findsOneWidget);
    expect(unsaved, findsOneWidget);
    const lost = '읽기 전용이라 이 필기는 저장되지 않습니다';
    expect(find.bySemanticsLabel('읽기 전용'), findsOneWidget);
    expect(find.bySemanticsLabel(lost), findsOneWidget);
    expect(find.byTooltip(lost), findsOneWidget);
    await close(tester, editor);
    semantics.dispose();
  });

  testWidgets('a quick note that cannot be read says so; 다시 시도 reads it '
      'again', (tester) async {
    final editor = await open(tester, '/qn-read-fails');
    store.failReads = 1;
    await tester.tap(noteButton);
    await tester.pump();
    const failed = '빠른 노트를 읽지 못했습니다.';
    await until(
      tester,
      () => find.text(failed).evaluate().isNotEmpty,
      'the failed read is said',
    );
    expect(editor.side.quickNote.note.value, isNull);
    // on a box of the paper's colour: no ruling through the line and 다시 시도
    final box = find.byKey(const ValueKey('quick-note-failed'));
    expect(tester.widget<ColoredBox>(box).color, KitTokens.quickNotePaper);
    final behind = tester.getRect(box);
    for (final text in [find.text(failed), find.text('다시 시도')]) {
      expect(behind.expandToInclude(tester.getRect(text)), behind);
    }
    await tester.tap(find.text('다시 시도'));
    await tester.pump();
    await until(
      tester,
      () => editor.side.quickNote.note.value != null,
      'it is read again',
    );
    await tester.pump();
    expect(find.text(failed), findsNothing);
    await write(tester, 40, 30);
    expect(editor.side.quickNote.note.value!.page.strokes, hasLength(1));
    await close(tester, editor);
  });

  final recordPill = find.byKey(const ValueKey('kit-record-pill'));

  testWidgets('while it records, the window and its pill stay under the '
      'record pill where they would meet it', (tester) async {
    useRecorder();
    final editor = await open(tester, '/qn-recording');
    await openQuick(tester, editor);
    final area = tester.getRect(layer);
    // the record pill's inset (10) and height (44), and 8 under it
    final under = area.top + 62;
    expect(tester.getRect(window).top, area.top + 16);

    // it starts recording with the window under the record pill: down at once
    await tester.tap(find.byKey(const ValueKey('editor-record')));
    await until(tester, () => recordPill.evaluate().isNotEmpty, 'it records');
    await until(
      tester,
      () => tester.getRect(window).top == under,
      'the window goes under the record pill',
    );
    expect(
      tester.getRect(window).top,
      greaterThan(tester.getRect(recordPill).bottom),
    );
    expect(tester.getRect(window).right, area.right - 16);
    // kept there (it does not come back up after)
    expect(editor.side.quickNote.place.value!.top, under - area.top);
    await dragBy(tester, tester.getCenter(head), const Offset(0, -300));
    expect(tester.getRect(window).top, under);

    // folded, its pill too
    await tester.tap(fold);
    await tester.pump();
    await dragBy(tester, tester.getCenter(pill), const Offset(0, -300));
    expect(tester.getRect(pill).top, under);
    // clear of the record pill it goes up to the top
    await dragBy(tester, tester.getCenter(pill), const Offset(-600, -300));
    expect(tester.getRect(pill).top, area.top);
    await tester.tap(pill);
    await tester.pump();

    // stopping leaves the window where it went
    await tester.tap(find.byKey(const ValueKey('kit-record-stop')));
    await until(
      tester,
      () => editor.side.audio.rows.length == 1,
      'the recording is saved',
    );
    await tester.pump();
    expect(recordPill, findsNothing);
    expect(tester.getRect(window).top, under);
    await close(tester, editor);
  });

  testWidgets('opened while it records the window starts under the record '
      'pill; clear of it, it keeps its place', (tester) async {
    useRecorder();
    final editor = await open(tester, '/qn-recording-clear');
    final area = tester.getRect(layer);
    final under = area.top + 62;
    await tester.tap(find.byKey(const ValueKey('editor-record')));
    await until(tester, () => recordPill.evaluate().isNotEmpty, 'it records');
    await openQuick(tester, editor);
    await tester.pump();
    expect(tester.getRect(window).top, under);
    await dragBy(tester, tester.getCenter(head), const Offset(-500, -300));
    final clear = tester.getRect(window);
    expect(clear.top, area.top);
    expect(clear.right, lessThan(tester.getRect(recordPill).left));

    // recording again with the window clear of the record pill moves nothing
    await tester.tap(find.byKey(const ValueKey('kit-record-stop')));
    await until(
      tester,
      () => editor.side.audio.rows.length == 1,
      'the recording is saved',
    );
    await tester.tap(find.byKey(const ValueKey('editor-record')));
    await until(tester, () => recordPill.evaluate().isNotEmpty, 'it records');
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(window), clear);
    await tester.tap(find.byKey(const ValueKey('kit-record-stop')));
    await until(
      tester,
      () => editor.side.audio.rows.length == 2,
      'the recording is saved',
    );
    await close(tester, editor);
  });

  testWidgets('the ⋯ 읽기 전용 lock leaves the quick note writable', (
    tester,
  ) async {
    final editor = await open(tester, '/qn-lock');
    final quick = await openQuick(tester, editor);
    editor.actions.run(
      AppActionIds.readOnly,
      tester.element(find.byType(Editor)),
    );
    await tester.pump();
    expect(editor.inkLocked.value, isTrue);
    await write(tester, 40, 30);
    expect(quick.page.strokes, hasLength(1));
    expect(readOnly, findsNothing);
    await close(tester, editor);
  });

  testWidgets('a point added paints the line being drawn only, over the '
      'strokes already there', (tester) async {
    final editor = await open(tester, '/qn-live-line');
    final quick = await openQuick(tester, editor);
    await write(tester, 40, 30);
    final outer = tester.renderObject<RenderRepaintBoundary>(
      find.ancestor(of: paper, matching: find.byType(RepaintBoundary)).first,
    );
    final pen = await tester.startGesture(
      paperAt(tester, 40, 90),
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveBy(const Offset(10, 0));
    await tester.pump();
    final before = paintCounts(outer);
    for (var i = 0; i < 4; i++) {
      await pen.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    expect(quick.currentStroke.value!.points.length, greaterThan(4));
    expectNotPainted(outer, before);
    // and not alone either (its top layer, the fitting, is kept when it
    // paints again, so the layers alone cannot tell)
    expect(paintCounts(outer).alone, before.alone);
    // the line being drawn lies over the strokes already there
    final stack = tester.widget<Stack>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('quick-note-live')),
            matching: find.byType(Stack),
          )
          .first,
    );
    final keys = [for (final child in stack.children) child.key];
    expect(
      keys.indexOf(const ValueKey('quick-note-live')),
      greaterThan(keys.indexOf(const ValueKey('quick-note-strokes'))),
    );
    await pen.up();
    await tester.pump();
    expect(quick.page.strokes, hasLength(2));
    await close(tester, editor);
  });

  testWidgets('the pen\'s eraser end and its button rub out', (tester) async {
    final editor = await open(tester, '/qn-pen-eraser');
    final quick = await openQuick(tester, editor);
    await write(tester, 40, 30);
    await write(
      tester,
      40,
      30,
      length: 4,
      kind: PointerDeviceKind.invertedStylus,
    );
    expect(quick.page.strokes, isEmpty, reason: 'the eraser end');
    await write(tester, 40, 30);
    await write(tester, 40, 30, length: 4, buttons: kSecondaryButton);
    expect(quick.page.strokes, isEmpty, reason: 'the pen\'s button');
    await close(tester, editor);
  });

  testWidgets('a palm does not scroll the page while the pen is down', (
    tester,
  ) async {
    final editor = await open(tester, '/qn-palm');
    final quick = await openQuick(tester, editor);
    // read each time: a change of the devices that scroll makes a new one
    ScrollPosition scroll() => tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('quick-note-scroll')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    expect(scroll().maxScrollExtent, greaterThan(0));
    final pen = await tester.startGesture(
      paperAt(tester, 40, 30),
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveBy(const Offset(20, 0));
    await tester.pump();
    await dragBy(tester, paperAt(tester, 200, 300), const Offset(0, -150));
    expect(scroll().pixels, 0);
    await pen.up();
    await tester.pump();
    expect(quick.page.strokes, hasLength(1));
    // the pen up, a finger scrolls again
    await dragBy(tester, paperAt(tester, 200, 300), const Offset(0, -150));
    expect(scroll().pixels, greaterThan(0));
    await close(tester, editor);
  });

  for (final (kept, stop) in [(0.1, 0.4), (0.99, 0.9), (0.7, 0.6)]) {
    testWidgets('a kept sheet height of $kept comes back at ${stop * 100}%', (
      tester,
    ) async {
      stows.quickNoteSheet.value = kept;
      const phone = Size(360, 740);
      final editor = await open(tester, '/qn-sheet-kept', size: phone);
      await openQuick(tester, editor, tap: false);
      final area = tester.getRect(layer);
      expect(tester.getRect(window).height / area.height, closeTo(stop, 1e-6));
      await close(tester, editor);
    });
  }

  testWidgets('the folded pill stays in the page area', (tester) async {
    final editor = await open(tester, '/qn-pill-in');
    await openQuick(tester, editor);
    final area = tester.getRect(layer);
    await tester.tap(fold);
    await tester.pump();
    await dragBy(tester, tester.getCenter(pill), const Offset(-3000, -3000));
    expect(tester.getRect(pill).topLeft, area.topLeft);
    await dragBy(tester, tester.getCenter(pill), const Offset(3000, 3000));
    expect(tester.getRect(pill).bottomRight, area.bottomRight);
    await close(tester, editor);
  });

  testWidgets('a window left at the foot stays in a page area that turned '
      'smaller', (tester) async {
    final editor = await open(tester, '/qn-turned');
    await openQuick(tester, editor);
    await dragBy(tester, tester.getCenter(head), const Offset(3000, 3000));
    const turned = Size(1400, 1000);
    tester.view.physicalSize = turned;
    await tester.pumpWidget(app(turned));
    await tester.pump();
    final area = tester.getRect(layer);
    final shown = tester.getRect(window);
    expect(shown.size, const Size(360, 460));
    expect(area.expandToInclude(shown), area);
    expect(shown.bottom, area.bottom);
    await close(tester, editor);
  });
  // Fix round 2 (task 13 review).

  final record = find.byKey(const ValueKey('editor-record'));
  final stop = find.byKey(const ValueKey('kit-record-stop'));

  /// Starts recording and waits for the record pill and the frames after it.
  Future<void> startRecording(WidgetTester tester) async {
    await tester.tap(record);
    await until(tester, () => recordPill.evaluate().isNotEmpty, 'it records');
    await tester.pump();
    await tester.pump();
  }

  /// Stops recording and waits for the [count]th recording to be saved.
  Future<void> stopRecording(
    WidgetTester tester,
    EditorState editor, [
    int count = 1,
  ]) async {
    await tester.tap(stop);
    await until(
      tester,
      () => editor.side.audio.rows.length == count,
      'the recording is saved',
    );
  }

  testWidgets('recording with the window shut leaves where it was left', (
    tester,
  ) async {
    useRecorder();
    final editor = await open(tester, '/qn-recording-shut');
    final area = tester.getRect(layer);
    await startRecording(tester);
    expect(stows.quickNoteWindow.value, isEmpty);
    await stopRecording(tester, editor);
    await openQuick(tester, editor);
    expect(tester.getRect(window).top, area.top + 16);
    expect(editor.side.quickNote.place.value, isNull);
    expect(stows.quickNoteWindow.value, isEmpty);
    await close(tester, editor);
  });

  testWidgets('opened while it records it stays under the record pill after', (
    tester,
  ) async {
    useRecorder();
    final editor = await open(tester, '/qn-recording-opened');
    final area = tester.getRect(layer);
    await startRecording(tester);
    await openQuick(tester, editor);
    expect(tester.getRect(window).top, area.top + 62);
    await stopRecording(tester, editor);
    await tester.pump();
    expect(recordPill, findsNothing);
    expect(tester.getRect(window).top, area.top + 62);
    await close(tester, editor);
  });

  testWidgets('while it records, a page area turned narrower moves a window '
      'it now meets under the record pill', (tester) async {
    useRecorder();
    final editor = await open(tester, '/qn-recording-narrower');
    await openQuick(tester, editor);
    await dragBy(tester, tester.getCenter(head), const Offset(-500, -300));
    await startRecording(tester);
    expect(tester.getRect(window).top, tester.getRect(layer).top);

    const narrower = Size(640, 1400);
    tester.view.physicalSize = narrower;
    await tester.pumpWidget(app(narrower));
    await tester.pump();
    await tester.pump();
    final area = tester.getRect(layer);
    final shown = tester.getRect(window);
    // the record pill moved left over the window's span
    expect(tester.getRect(recordPill).left, lessThan(shown.right));
    expect(shown.top, area.top + 62);
    await stopRecording(tester, editor);
    await close(tester, editor);
  });

  testWidgets('while it records, sizing a window left of the record pill '
      'stops at it', (tester) async {
    useRecorder();
    final editor = await open(tester, '/qn-recording-size');
    await openQuick(tester, editor);
    await dragBy(tester, tester.getCenter(head), const Offset(-500, -300));
    await startRecording(tester);
    final from = tester.getRect(window);
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(300, 0));
    await tester.pump();
    final pillLeft = tester.getRect(recordPill).left;
    expect(tester.getRect(window).right, pillLeft);
    await gesture.up();
    await tester.pump();
    final sized = tester.getRect(window);
    expect(sized.top, from.top);
    expect(sized.right, pillLeft);
    await stopRecording(tester, editor);
    await close(tester, editor);
  });

  testWidgets('while it records on a short tablet the window is made lower to '
      'stay under the record pill', (tester) async {
    useRecorder();
    final editor = await open(
      tester,
      '/qn-recording-short',
      size: const Size(1000, 560),
    );
    await openQuick(tester, editor);
    final area = tester.getRect(layer);
    // no room under the record pill for it as it is
    expect(area.height - 62, lessThan(tester.getRect(window).height));
    await startRecording(tester);
    final shown = tester.getRect(window);
    expect(shown.top, area.top + 62);
    expect(shown.height, area.height - 62);
    expect(shown.bottom, area.bottom);
    expect(tester.getRect(recordPill).bottom, lessThan(shown.top));
    await stopRecording(tester, editor);
    await close(tester, editor);
  });

  testWidgets('kept values read late move the window and the sheet there', (
    tester,
  ) async {
    final keptWindow = stows.quickNoteWindow;
    final keptSheet = stows.quickNoteSheet;
    final wasLoaded = (keptWindow.loaded, keptSheet.loaded);
    addTearDown(() {
      keptWindow.loaded = wasLoaded.$1;
      keptSheet.loaded = wasLoaded.$2;
    });
    keptWindow.loaded = false;
    keptSheet.loaded = false;
    // the device's settings, read once the gate opens
    final gate = Completer<void>();
    unawaited(
      // ignore: invalid_use_of_visible_for_overriding_member
      keptWindow.readMutex.protect(() async {
        await gate.future;
        keptWindow.value = const ['120', '200', '400', '500'];
        keptWindow.loaded = true;
      }),
    );
    unawaited(
      // ignore: invalid_use_of_visible_for_overriding_member
      keptSheet.readMutex.protect(() async {
        await gate.future;
        keptSheet.value = 0.1;
        keptSheet.loaded = true;
      }),
    );
    final editor = await open(tester, '/qn-read-late');
    await openQuick(tester, editor);
    final area = tester.getRect(layer);
    expect(
      tester.getRect(window),
      Rect.fromLTWH(area.right - 16 - 360, area.top + 16, 360, 460),
    );
    expect(editor.side.quickNote.sheet.value, 0.6);

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(
      tester.getRect(window),
      Rect.fromLTWH(area.left + 120, area.top + 200, 400, 500),
    );
    expect(editor.side.quickNote.sheet.value, 0.4);
    await close(tester, editor);
  });
}

/// A quick note attachment with one stroke, marked as written by an app of
/// a newer note version.
Map<String, Uint8List> _newerQuickNote() {
  final core = EditorCoreInfo(filePath: '/remote')..pages.add(EditorPage());
  final page = core.pages.single;
  final stroke = Pen.fountainPen().createStroke(page, 0)
    ..addPoint(const Offset(10, 10))
    ..addPoint(const Offset(100, 10));
  stroke.options.isComplete = true;
  page.insertStroke(stroke);
  final (json, _) = core.toJson();
  core.dispose();
  json['v'] = EditorCoreInfo.newestSbnVersion + 1;
  return {
    NoteSideKind.quickNote.markerFile: Uint8List.fromList(
      utf8.encode(jsonEncode({'schemaVersion': 1})),
    ),
    'quick-note.sbn2': BsonCodec.serialize(json).byteList,
  };
}
