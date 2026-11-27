import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:bson/bson.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/ink_ui/audio/record_pill.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/quick_note.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/editor/editor_side_host.dart';

import '../utils/screen_capture.dart';
import '../utils/test_mock_channel_handlers.dart';

/// Writes screenshots of the quick note window (supplement Task 13) to
/// build/screen-review/supp-t13/app-supp-t13-*.png with the app's fonts at
/// device pixel ratio 2, as the 12th draft's device (`#extras12`): the
/// toolbar (46) over the page area (586 x 734 on the tablet, 360 x 600 on
/// the phone), a few lines written in the quick note. The window open
/// (`note`), being sized to 420 x 520 at 120, 40 (`noteresize`), folded
/// (`notefold`), with ink not saved yet, read-only, both, unread, under the
/// record pill while it records, the phone sheet at 40, 60 and 90% and
/// folded on the phone (task 13 fix 1). Runs only with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/supp-t13');
const _paper = Color(0xfffbf8ef); // `--paper`

Future<void> _write(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  debugDisableShadows = false;
  try {
    void mark(RenderObject o) {
      o.markNeedsPaint();
      o.visitChildren(mark);
    }

    mark(boundary.currentContext!.findRenderObject()!);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final object =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await object.toImage(pixelRatio: 2);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/app-supp-t13-$name.png')
          .writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
  }
  expect(tester.takeException(), isNull);
}

/// The 12th draft's scribbles (`NOTE0`) in window pixels at 360 wide: three
/// lines and an arrow.
const _lines = [(18.0, 40.0, 150.0), (18.0, 66.0, 210.0), (18.0, 92.0, 120.0)];

void _scribble(QuickNote quick) {
  final unit = quick.page.size.width / KitTokens.quickNoteWidth;
  final pen = Pen.fountainPen();
  for (final (x, y, length) in _lines) {
    quick.penDown(Offset(x, y) * unit, pen, null);
    for (var i = 1; i <= 12; i++) {
      final dx = length * i / 12;
      quick.penMove(Offset(x + dx, y + (i.isEven ? -2 : 2)) * unit, null);
    }
    quick.penUp();
  }
  for (final arrow in [
    [const Offset(24, 128), const Offset(64, 128)],
    [const Offset(60, 120), const Offset(68, 128), const Offset(60, 136)],
  ]) {
    quick.penDown(arrow.first * unit, pen, null);
    for (final point in arrow.skip(1)) {
      quick.penMove(point * unit, null);
    }
    quick.penUp();
  }
}

/// A quick note attachment marked as written by an app of a newer note
/// version, with the scribbles on it.
Future<Map<String, Uint8List>> _newer(QuickNote written) async {
  final (json, _) = written.core.toJson();
  json['v'] = EditorCoreInfo.newestSbnVersion + 1;
  return {
    NoteSideKind.quickNote.markerFile: Uint8List.fromList(
      utf8.encode(jsonEncode({'schemaVersion': 1})),
    ),
    'quick-note.sbn2': BsonCodec.serialize(json).byteList,
  };
}

void main() {
  FlavorConfig.setup();
  StrokeOptionsExtension.setDefaults();

  setUp(() async {
    setupMockPathProvider();
    await FileManager.init();
  });

  /// A quick note in a new format 2 vault, the scribbles written; saved
  /// unless [unsaved]; [readOnly] as a newer app left it; with [bothMarks],
  /// turned read-only by a newer app while it saved a line more.
  Future<QuickNote> quickNote(
    WidgetTester tester, {
    bool unsaved = false,
    bool readOnly = false,
    bool bothMarks = false,
  }) async {
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('piv-quick-capture-'),
    ))!;
    final repository = (await tester.runAsync(
      () => NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      ),
    ))!;
    addTearDown(
      () => tester.runAsync(() async {
        await repository.close().timeout(const Duration(seconds: 10));
        await temp.delete(recursive: true);
      }),
    );
    final quick = await tester.runAsync(() async {
      final store = NoteSideStore(repository);
      final id = (await WorkspaceStore(repository).create('Quick')).id;
      Future<QuickNote> open() =>
          QuickNote.open(store, id, saveDelay: const Duration(hours: 1));
      if (readOnly) {
        final written = await open();
        _scribble(written);
        await repository.commit(
          entityId: newId(),
          kind: EntityKind.attachment,
          ownerNoteId: id,
          files: await _newer(written),
          parentRevisionIds: [],
        );
        written.dispose();
        return open();
      }
      final quick = await open();
      _scribble(quick);
      if (!unsaved) await quick.flush();
      if (bothMarks) {
        final seen = (await store.list(id, NoteSideKind.quickNote)).single;
        final newer = await _newer(quick);
        final unit = quick.page.size.width / KitTokens.quickNoteWidth;
        quick.penDown(const Offset(18, 150) * unit, Pen.fountainPen(), null);
        quick.penMove(const Offset(118, 152) * unit, null);
        quick.penUp();
        store.beforeCommit = () async {
          store.beforeCommit = null;
          await repository.commit(
            entityId: seen.entityId,
            kind: EntityKind.attachment,
            ownerNoteId: id,
            files: newer,
            parentRevisionIds: [seen.revisionId],
          );
        };
        await quick.flush();
      }
      return quick;
    });
    return quick!;
  }

  /// The toolbar over the page area of [size], the quick note [quick] open
  /// over it ([folded] into its pill; none read when null, its read failed
  /// with [readFailed]); the window was left at [place], the phone sheet at
  /// [sheet]; while [recording], under the record pill.
  Future<GlobalKey> mount(
    WidgetTester tester, {
    required Size size,
    required QuickNote? quick,
    bool folded = false,
    Rect? place,
    double sheet = 0.6,
    bool readFailed = false,
    bool recording = false,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    stows.quickNoteWindow.value = [
      if (place != null)
        for (final value in [place.left, place.top, place.width, place.height])
          '$value',
    ];
    stows.quickNoteSheet.value = sheet;
    final screen = Size(size.width, KitTokens.toolbarHeight + size.height);
    tester.view.physicalSize = screen * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final actions = AppActionRegistry();
    addTearDown(actions.dispose);
    final floatingBar = ValueNotifier(false);
    addTearDown(floatingBar.dispose);
    final open = ValueNotifier(true);
    final host = EditorQuickNoteHost(open: open)
      ..available.value = true
      ..note.value = quick
      ..readFailed.value = readFailed;
    // folded as 접기 folds it, without its save (made in the fake time, it
    // would hold up the save below)
    if (folded) host.folded.value = true;
    // saved first, so that disposing the host saves nothing
    addTearDown(() async {
      host.dispose();
      open.dispose();
    });
    if (quick != null) addTearDown(() => tester.runAsync(quick.flush));
    final recordState = ValueNotifier(
      recording ? KitRecording.on : KitRecording.off,
    );
    addTearDown(recordState.dispose);
    final elapsed = ValueNotifier(const Duration(minutes: 2, seconds: 14));
    addTearDown(elapsed.dispose);
    final recordPill = GlobalKey();
    AppAction action(String id, KitIconName icon, {bool? checked}) =>
        AppAction(id: id, label: id, icon: icon, checked: checked, run: (_) {});
    actions.publish(Object(), [
      action(AppActionIds.pageList, KitIconName.sidebar, checked: false),
      for (final id in AppActionIds.tools)
        action(id, KitIconName.pen, checked: id == AppActionIds.toolPen),
      action(AppActionIds.pickPhoto, KitIconName.image),
      action(AppActionIds.insertPageMenu, KitIconName.pageAdd),
      action(AppActionIds.fullscreen, KitIconName.expand, checked: false),
    ]);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MediaQuery(
          data: MediaQueryData(size: screen, devicePixelRatio: 2),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: captureLatin,
              fontFamilyFallback: const [captureKorean],
            ),
            home: Material(
              color: _paper,
              child: Column(
                children: [
                  KitEditorToolbar(
                    actions: actions,
                    title: '강의노트 3주차',
                    floatingBarOpen: floatingBar,
                    noteSheetOpen: open,
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: EditorQuickNoteLayer(
                            host: host,
                            pen: Pen.fountainPen,
                            erasing: () => false,
                            recording: recordState,
                            recordPill: recordPill,
                          ),
                        ),
                        if (recording)
                          Positioned.fill(
                            child: KitRecordPill(
                              boxKey: recordPill,
                              paused: false,
                              elapsed: elapsed,
                              onPauseResume: () {},
                              onStop: () {},
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    return boundary;
  }

  const tablet = Size(586, 734);
  const phone = Size(360, 600);

  group('quick note captures', skip: !_capture, () {
    testWidgets('open', (tester) async {
      final quick = await quickNote(tester);
      final boundary = await mount(tester, size: tablet, quick: quick);
      expect(
        tester.getRect(find.byKey(const ValueKey('quick-note-window'))),
        const Rect.fromLTWH(586 - 360 - 16.0, 46 + 16.0, 360, 460),
      );
      await _write(tester, boundary, 'open');
    });
    testWidgets('resize', (tester) async {
      final quick = await quickNote(tester);
      final boundary = await mount(
        tester,
        size: tablet,
        quick: quick,
        place: const Rect.fromLTWH(120, 40, 360, 460),
      );
      // held while it is sized: the size shows
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('quick-note-resize'))),
      );
      await gesture.moveBy(const Offset(30, 30));
      await tester.pump();
      await gesture.moveBy(const Offset(30, 30));
      await tester.pump();
      expect(find.text('420 × 520'), findsOneWidget);
      await _write(tester, boundary, 'resize');
      await gesture.up();
      await tester.pump();
    });
    testWidgets('folded', (tester) async {
      final quick = await quickNote(tester);
      final boundary = await mount(
        tester,
        size: tablet,
        quick: quick,
        folded: true,
      );
      expect(find.byKey(const ValueKey('quick-note-pill')), findsOneWidget);
      await _write(tester, boundary, 'folded');
    });
    testWidgets('unsaved', (tester) async {
      final quick = await quickNote(tester, unsaved: true);
      final boundary = await mount(tester, size: tablet, quick: quick);
      expect(find.byKey(const ValueKey('quick-note-unsaved')), findsOneWidget);
      await _write(tester, boundary, 'unsaved');
    });
    testWidgets('read-only', (tester) async {
      final quick = await quickNote(tester, readOnly: true);
      final boundary = await mount(tester, size: tablet, quick: quick);
      expect(
        find.byKey(const ValueKey('quick-note-read-only')),
        findsOneWidget,
      );
      await _write(tester, boundary, 'read-only');
    });
    testWidgets('read-only-unsaved', (tester) async {
      final quick = await quickNote(tester, bothMarks: true);
      expect(quick.readOnly, isTrue);
      expect(quick.hasUnsavedChanges, isTrue);
      final boundary = await mount(tester, size: tablet, quick: quick);
      expect(
        find.byKey(const ValueKey('quick-note-read-only')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('quick-note-unsaved')), findsOneWidget);
      await _write(tester, boundary, 'read-only-unsaved');
    });
    testWidgets('read-failed', (tester) async {
      final boundary = await mount(
        tester,
        size: tablet,
        quick: null,
        readFailed: true,
      );
      expect(find.text('빠른 노트를 읽지 못했습니다.'), findsOneWidget);
      expect(find.text('다시 시도'), findsOneWidget);
      await _write(tester, boundary, 'read-failed');
    });
    testWidgets('recording', (tester) async {
      final quick = await quickNote(tester);
      final boundary = await mount(
        tester,
        size: tablet,
        quick: quick,
        recording: true,
      );
      expect(
        tester.getRect(find.byKey(const ValueKey('quick-note-window'))).top,
        46 +
            KitTokens.recPillInset +
            KitTokens.recPillHeight +
            KitTokens.quickNoteUnderRecPill,
      );
      await _write(tester, boundary, 'recording');
    });
    testWidgets('phone folded', (tester) async {
      final quick = await quickNote(tester);
      final boundary = await mount(
        tester,
        size: phone,
        quick: quick,
        folded: true,
      );
      expect(find.byKey(const ValueKey('quick-note-pill')), findsOneWidget);
      await _write(tester, boundary, 'phone-folded');
    });
    for (final share in KitTokens.noteSheetFractions) {
      final percent = (share * 100).round();
      testWidgets('phone sheet at $percent%', (tester) async {
        final quick = await quickNote(tester);
        final boundary = await mount(
          tester,
          size: phone,
          quick: quick,
          sheet: share,
        );
        await _write(tester, boundary, 'phone-$percent');
      });
    }
  });
}
