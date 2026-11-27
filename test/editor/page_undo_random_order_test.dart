import 'dart:math';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/page_clipboard.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// Page steps (put in before or after, move, delete, copy and paste) mixed
/// with strokes drawn and erased, undo and redo, in orders picked by fixed
/// seeds. The tidying of empty pages at the note's end, which no undo step
/// records, must not shift the steps that find pages by their places.
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
      try {
        final length = 20 + random.nextInt(21);
        for (var n = 0; n < length; n++) {
          final at = random.nextInt(pages.length);
          switch (random.nextInt(11)) {
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
                ),
              );
            case 7:
              // as the eraser does: tidy, then record
              if (pages[at].strokes.isEmpty) continue;
              final stroke =
                  pages[at].strokes[random.nextInt(pages[at].strokes.length)];
              steps.add('erase $at');
              pages[at].strokes.remove(stroke);
              editor.removeExcessPages();
              editor.history.recordChange(
                EditorHistoryItem(
                  type: EditorHistoryItemType.erase,
                  pageIndex: at,
                  strokes: [stroke],
                  images: const [],
                ),
              );
            case 8:
              steps.add('undo');
              editor.undo();
            case 9:
              steps.add('redo');
              editor.redo();
            case _:
              steps.add('clear $at');
              editor.clearPage(at);
          }
          if (wrongIndex() case final wrong?) throw StateError(wrong);
        }

        final end = content();
        var undone = 0;
        while (editor.history.canUndo) {
          editor.undo();
          undone++;
          if (wrongIndex() case final wrong?) throw StateError('undo: $wrong');
        }
        if (!_same(content(), start)) {
          throw StateError('undone ${content()}, at the start $start');
        }
        for (var i = 0; i < undone; i++) {
          editor.redo();
          if (wrongIndex() case final wrong?) throw StateError('redo: $wrong');
        }
        if (!_same(content(), end)) {
          throw StateError('redone ${content()}, before undoing $end');
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
