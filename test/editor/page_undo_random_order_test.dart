import 'dart:math';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/ink_swap.dart';
import 'package:saber/data/editor/page_clipboard.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// Page steps (put in before or after, move, delete, copy and paste) mixed
/// with strokes drawn, erased, split and brought to the front, undo and
/// redo, in orders picked by fixed seeds. The tidying of empty pages at the
/// note's end, which no undo step records, must not shift the steps that
/// find pages by their places, and undoing puts every stroke back at its
/// place on its own page.
void main() {
  const seeds = 200;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
    PageClipboard.current.value = null;
  });
  tearDown(() => PageClipboard.current.value = null);

  testWidgets('undo all, then redo all, in $seeds random orders', (
    tester,
  ) async {
    const size = Size(1200, 1600);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: size),
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(
              path: '/page-undo-random-order',
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.state<EditorState>(find.byType(Editor));
    final pages = editor.coreInfo.pages;
    var key = 0;

    /// A stroke whose first x is its own number.
    Stroke strokeFor(int i) => Stroke(
      color: const Color(0xFF1E88E5),
      pressureEnabled: false,
      options: StrokeOptions(size: 10),
      pageIndex: i,
      page: pages[i],
      toolId: ToolId.ballpointPen,
    )..addPoints([for (var x = 0; x < 3; x++) Offset(1000.0 + key++, 300)]);

    /// Each page's strokes by their numbers, the empty pages at the end
    /// left out (how many there are follows the tidying).
    List<List<double>> content() {
      final all = [
        for (final page in pages)
          [for (final s in page.strokes) s.points.first.x]..sort(),
      ];
      while (all.isNotEmpty && all.last.isEmpty) {
        all.removeLast();
      }
      return all;
    }

    /// Each page's strokes (the objects, in order), the empty pages at the
    /// end left out.
    List<List<Stroke>> objects() {
      final all = [for (final page in pages) List.of(page.strokes)];
      while (all.isNotEmpty && all.last.isEmpty) {
        all.removeLast();
      }
      return all;
    }

    List<String> contentIds() => [
      for (final page in pages)
        if (page.strokes.isNotEmpty) page.pageId,
    ];

    /// What [swap] did to page [at], recorded as one undo step.
    void replaced(int at, InkSwap swap) =>
        editor.pageList.recordReplace([(page: pages[at], swap: swap)]);

    String? wrongIndex() {
      for (var i = 0; i < pages.length; i++) {
        for (final s in pages[i].strokes) {
          if (s.pageIndex != i) {
            return 'a stroke on page $i says ${s.pageIndex}';
          }
        }
      }
      return null;
    }

    final failures = <String>[];
    for (var seed = 0; seed < seeds; seed++) {
      final random = Random(seed);
      final steps = <String>[];
      // a fresh note: 2 to 5 pages, some empty, then the spare empty page
      editor.history = EditorHistory();
      pages.clear();
      final count = 2 + random.nextInt(4);
      editor.createPage(count - 1);
      for (var i = 0; i < count; i++) {
        if (random.nextInt(3) > 0) pages[i].insertStroke(strokeFor(i));
      }
      final start = content();
      final startObjects = objects();
      final startIds = contentIds();
      try {
        final length = 20 + random.nextInt(21);
        for (var n = 0; n < length; n++) {
          final at = random.nextInt(pages.length);
          switch (random.nextInt(14)) {
            case 0:
              steps.add('before $at');
              editor.insertPageBefore(at);
            case 1:
              steps.add('after $at');
              editor.insertPageAfter(at);
            case 2:
              final to = random.nextInt(pages.length);
              steps.add('move $at $to');
              editor.movePage(at, to);
            case 3:
              steps.add('delete $at');
              editor.deletePageAt(at);
            case 4:
              steps.add('copy $at');
              await editor.copyPage(at);
              final after = random.nextInt(pages.length);
              steps.add('paste $after');
              editor.pastePageAfter(after);
            case 5 || 6:
              // as the pen does: an empty page after the last one drawn on
              steps.add('draw $at');
              editor.createPage(at);
              final stroke = strokeFor(at);
              pages[at].insertStroke(stroke);
              editor.history.recordChange(
                EditorHistoryItem(
                  type: EditorHistoryItemType.draw,
                  pageIndex: at,
                  strokes: [stroke],
                  images: const [],
                  page: pages[at],
                ),
              );
            case 7:
              // as the eraser does: take it off, then record (and tidy)
              if (pages[at].strokes.isEmpty) continue;
              final k = random.nextInt(pages[at].strokes.length);
              steps.add('erase $at');
              final stroke = pages[at].strokes.removeAt(k);
              replaced(at, InkSwap(removedStrokes: [(k, stroke)]));
            case 8:
              steps.add('undo');
              editor.undo();
            case 9:
              steps.add('redo');
              editor.redo();
            case 10:
              // as the partial eraser will: one stroke becomes two pieces
              if (pages[at].strokes.isEmpty) continue;
              final k = random.nextInt(pages[at].strokes.length);
              steps.add('split $at $k');
              final stroke = pages[at].strokes.removeAt(k);
              final (one, two) = (strokeFor(at), strokeFor(at));
              pages[at].strokes.insertAll(k, [one, two]);
              replaced(
                at,
                InkSwap(
                  removedStrokes: [(k, stroke)],
                  addedStrokes: [(k, one), (k + 1, two)],
                ),
              );
            case 11:
              // as the eraser with some kinds on: some or all strokes go
              final strokes = pages[at].strokes;
              final gone = [
                for (final (i, s) in strokes.indexed)
                  if (random.nextBool()) (i, s),
              ];
              if (gone.isEmpty) continue;
              steps.add('erase-kinds $at ${gone.length}');
              for (final (_, s) in gone) {
                strokes.remove(s);
              }
              replaced(at, InkSwap(removedStrokes: gone));
            case 12:
              // bring a stroke to the front
              final strokes = pages[at].strokes;
              if (strokes.length < 2) continue;
              final k = random.nextInt(strokes.length);
              steps.add('front $at $k');
              final stroke = strokes.removeAt(k);
              strokes.add(stroke);
              replaced(
                at,
                InkSwap(
                  removedStrokes: [(k, stroke)],
                  addedStrokes: [(strokes.length - 1, stroke)],
                ),
              );
            case _:
              steps.add('clear $at');
              editor.clearPage(at);
          }
          if (wrongIndex() case final wrong?) throw StateError(wrong);
        }

        final end = content();
        final endObjects = objects();
        var undone = 0;
        while (editor.history.canUndo) {
          editor.undo();
          undone++;
          if (wrongIndex() case final wrong?) throw StateError('undo: $wrong');
        }
        if (!_same(content(), start)) {
          throw StateError('undone ${content()}, at the start $start');
        }
        if (!_sameObjects(objects(), startObjects)) {
          throw StateError('undone, a stroke is not back at its place');
        }
        if (!listEquals(contentIds(), startIds)) {
          throw StateError(
            'undone, page ids ${contentIds()}, at the start '
            '$startIds',
          );
        }
        for (var i = 0; i < undone; i++) {
          editor.redo();
          if (wrongIndex() case final wrong?) throw StateError('redo: $wrong');
        }
        if (!_same(content(), end)) {
          throw StateError('redone ${content()}, before undoing $end');
        }
        if (!_sameObjects(objects(), endObjects)) {
          throw StateError('redone, a stroke is not back at its place');
        }
        await tester.pump();
      } catch (error) {
        failures.add('seed $seed [${steps.join(', ')}]: $error');
        if (failures.length >= 3) break;
      }
    }
    editor.cancelAutosaveAndMarkSaved();
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  });
}

bool _same(List<List<double>> a, List<List<double>> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) listEquals(a[i], b[i])].every((x) => x);

/// The same stroke objects in the same order on each page.
bool _sameObjects(List<List<Stroke>> a, List<List<Stroke>> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].length != b[i].length) return false;
    for (var j = 0; j < a[i].length; j++) {
      if (!identical(a[i][j], b[i][j])) return false;
    }
  }
  return true;
}
