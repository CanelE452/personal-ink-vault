import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/ink_ui/side_panel/outline_tab.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/pdf_outline.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/note_page_marks.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/editor/editor_chrome.dart';
import 'package:saber/pages/editor/editor_side_host.dart';
import 'package:sbn/read_only_reason.dart';

/// The left panel's outline tab (supplement Task 10, 12th draft `#extras12`):
/// the PDF's outline and the user's own, kept in the note's page marks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  /// A note of five pages p0..p4: the first four from one PDF, the last
  /// blank (or none from a PDF with [pdf] false).
  EditorCoreInfo note({bool pdf = true}) {
    final core = EditorCoreInfo(filePath: '/outline-tab');
    for (var i = 0; i < 5; i++) {
      core.pages.add(
        EditorPage(
          pageId: 'p$i',
          backgroundImage: !pdf || i == 4
              ? null
              : PdfEditorImage(
                  id: i,
                  assetCache: core.assetCache,
                  pdfBytes: null,
                  pdfFile: File('/outline-tab/a.pdf'),
                  pdfPage: i,
                  pageIndex: i,
                  pageSize: const Size(100, 140),
                  naturalSize: const Size(100, 140),
                  onMoveImage: null,
                  onDeleteImage: null,
                  onMiscChange: null,
                ),
        ),
      );
    }
    return core;
  }

  PdfOutlineRow line(String title, int depth, int page) => PdfOutlineRow(
    title: title,
    depth: depth,
    pageId: 'p$page',
    pageIndex: page,
    renamed: false,
  );

  // the draft's outline (`OUT0`), counted from 0
  final pdfOutline = [
    line('1. 들어가며', 0, 0),
    line('2. 방법', 0, 1),
    line('2.1 자료 모으기', 1, 2),
    line('2.2 실험 순서', 1, 2),
    line('3. 결과', 0, 3),
  ];

  /// Lets the vault's file work run between frames.
  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    });
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Runs [work] (the vault's file work) while frames go on.
  Future<T> settle<T>(WidgetTester tester, Future<T> Function() work) async {
    late T value;
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        work().then((v) {
          value = v;
          done = true;
        }),
      );
    });
    for (var i = 0; i < 40 && !done; i++) {
      await drain(tester);
    }
    expect(done, isTrue, reason: 'the vault work finished');
    return value;
  }

  /// A format 2 vault with one note whose page marks hold [marks].
  Future<NoteSideBinding> openVault(
    WidgetTester tester, {
    NotePageMarks? marks,
  }) async {
    final made = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('piv-outline-');
      final repository = await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      );
      final id = (await WorkspaceStore(repository).create('Outline')).id;
      final store = NoteSideStore(repository);
      if (marks != null) {
        await store.write(id, NoteSideKind.pageMarks, {
          NoteSideKind.pageMarks.markerFile: marks.encode(),
        });
      }
      return (repository, id, temp, store);
    });
    addTearDown(
      () => settle(tester, () async {
        await made!.$1.close().timeout(const Duration(seconds: 10));
        await made.$3.delete(recursive: true);
      }),
    );
    return (store: made!.$4, noteId: made.$2);
  }

  /// The marks of every head of the note's page marks, merged, once every
  /// write [host] has started is done.
  Future<NotePageMarks> stored(
    WidgetTester tester,
    EditorSideHost host,
    NoteSideBinding binding,
  ) async {
    await settle(tester, () => host.idle);
    return settle(tester, () async {
      final all = <NotePageMarks>[];
      for (final record in await binding.store.list(
        binding.noteId,
        NoteSideKind.pageMarks,
      )) {
        for (final head in record.heads) {
          final files = await binding.store.repository.readFiles(head);
          all.add(
            NotePageMarks.decode(files[NoteSideKind.pageMarks.markerFile]!),
          );
        }
      }
      return NotePageMarks.merge(all);
    });
  }

  /// The user's own outline as the draft starts (`OUT0`): 「다시 볼 식」 on
  /// page 2 made after 「질문 모음」 on page 5, 「두 번째」 on page 2 made last,
  /// and one on a page the note no longer has.
  NotePageMarks userOutline() {
    final marks = NotePageMarks();
    marks.addOutline('p4', '질문 모음', at: DateTime.utc(2026, 11, 1));
    marks.addOutline('p1', '다시 볼 식', at: DateTime.utc(2026, 11, 2));
    marks.addOutline('p1', '두 번째', at: DateTime.utc(2026, 11, 3));
    marks.addOutline('p-gone', '지운 쪽', at: DateTime.utc(2026, 11, 4));
    return marks;
  }

  /// The left panel on its outline tab over a page area of [size], with
  /// the undo notice over it, as the editor lays them.
  Future<({EditorSideHost host, EditorCoreInfo core, List<int> went})> mount(
    WidgetTester tester, {
    NoteSideBinding? binding,
    EditorCoreInfo? core,
    List<PdfOutlineRow>? outline,
    Future<List<PdfOutlineRow>> Function()? read,
    Size size = const Size(586, 734),
    int shown = 0,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = core ?? note();
    final went = <int>[];
    var onScreen = shown;
    final host = EditorSideHost(
      binding: () => binding,
      saveNote: (_) async {},
      pages: () => c.pages,
      pageOnScreen: () => onScreen,
      pageMoves: const AlwaysStoppedAnimation(0),
      onChanged: () {},
      onError: (error) => fail('$error'),
      readOutline: (_, edits) async {
        expect(edits, isEmpty, reason: 'the host applies the edits itself');
        return read != null ? read() : outline ?? pdfOutline;
      },
    );
    addTearDown(host.dispose);
    await settle(tester, host.load);
    host.tab.value = KitSideTab.outline;
    host.togglePanel();
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          home: Material(
            child: Stack(
              children: [
                Positioned.fill(
                  child: EditorSidePanelLayer(
                    host: host,
                    coreInfo: c,
                    goTo: (i) {
                      went.add(i);
                      onScreen = i;
                    },
                    managePage: (_) {},
                  ),
                ),
                Positioned.fill(child: KitUndoNotice(controller: host.notice)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (host: host, core: c, went: went);
  }

  Finder row(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('kit-outline-row-'),
    ),
  );
  Finder more(String title) => find.descendant(
    of: row(title),
    matching: find.byKey(const ValueKey('kit-outline-more')),
  );
  double top(WidgetTester tester, String title) =>
      tester.getTopLeft(row(title)).dy;
  bool lit(WidgetTester tester, String title) =>
      tester.widget<Text>(find.text(title)).style?.fontWeight ==
      FontWeight.w600;
  final rename = find.byKey(const ValueKey('kit-outline-rename'));
  final notice = find.byKey(const ValueKey('kit-undo-notice'));

  testWidgets('「PDF 목차 · 자동」 and the user\'s own outline show apart', (
    tester,
  ) async {
    final binding = await openVault(tester, marks: userOutline());
    await mount(tester, binding: binding);
    expect(find.text('PDF 목차'), findsOneWidget);
    expect(find.text('자동'), findsOneWidget);
    expect(find.text('내가 더한 개요'), findsOneWidget);
    // the PDF's lines in the PDF's order, the lines under one set in 16
    final pdf = [for (final l in pdfOutline) l.title];
    for (final (i, title) in pdf.indexed.skip(1)) {
      expect(
        top(tester, title),
        greaterThan(top(tester, pdf[i - 1])),
        reason: title,
      );
    }
    expect(
      tester.getTopLeft(find.text('2.1 자료 모으기')).dx -
          tester.getTopLeft(find.text('2. 방법')).dx,
      KitTokens.sideRowIndent,
    );
    expect(tester.getSize(row('2. 방법')).height, KitTokens.sideRowHeight);
    expect(KitTokens.sideRowHeight, 44);
    // the user's below them, by page, then as they were made
    expect(
      tester.getTopLeft(find.text('내가 더한 개요')).dy,
      greaterThan(top(tester, '3. 결과')),
    );
    expect(top(tester, '다시 볼 식'), lessThan(top(tester, '두 번째')));
    expect(top(tester, '두 번째'), lessThan(top(tester, '질문 모음')));
    // each with its page's number
    expect(
      find.descendant(of: row('질문 모음'), matching: find.text('5')),
      findsOneWidget,
    );
    expect(
      find.text(keepWords('쪽 ⋯ 메뉴의 「개요에 추가」로 지금 쪽을 더합니다. 줄을 누르면 그 쪽으로 갑니다.')),
      findsOneWidget,
    );
    final title = tester.widget<Text>(find.text('2. 방법'));
    expect(title.style?.fontSize, KitTokens.sideRowFontSize);
    expect(KitTokens.sideRowFontSize, 13.5);
    // the ⋯ button 36, pressed anywhere in its 44
    final button = tester.getRect(more('2. 방법'));
    expect(button.size, const Size.square(KitTokens.sideRowMenuHit));
    expect(KitTokens.sideRowMenuHit, 44);
    expect(KitTokens.sideRowMenuButton, 36);
  });

  testWidgets('the row of the page on screen is lit: the nearest before it', (
    tester,
  ) async {
    final binding = await openVault(tester, marks: userOutline());
    final (:host, core: _, went: _) = await mount(
      tester,
      binding: binding,
      shown: 2,
    );
    // page 3 holds two of the PDF's lines: the last of them only
    expect(lit(tester, '2.2 실험 순서'), isTrue);
    expect(lit(tester, '2.1 자료 모으기'), isFalse);
    expect(lit(tester, '2. 방법'), isFalse);
    // the user's own: none on page 3, the last made on page 2
    expect(lit(tester, '두 번째'), isTrue);
    expect(lit(tester, '다시 볼 식'), isFalse);
    expect(find.byKey(const ValueKey('kit-outline-current')), findsNWidgets(2));
    final lights = tester.widget<DecoratedBox>(
      find
          .descendant(of: row('2.2 실험 순서'), matching: find.byType(DecoratedBox))
          .first,
    );
    expect(
      (lights.decoration as BoxDecoration).color,
      KitTokens.sideRowCurrentBg,
    );

    host.shownPage.value = 4;
    await tester.pump();
    expect(lit(tester, '3. 결과'), isTrue);
    expect(lit(tester, '2.2 실험 순서'), isFalse);
    expect(lit(tester, '질문 모음'), isTrue);

    // before any of the user's: none of them lit
    host.shownPage.value = 0;
    await tester.pump();
    expect(lit(tester, '1. 들어가며'), isTrue);
    expect(find.byKey(const ValueKey('kit-outline-current')), findsOneWidget);
  });

  testWidgets('a row is renamed and removed; the undo notice brings it back', (
    tester,
  ) async {
    final binding = await openVault(tester, marks: userOutline());
    final (:host, core: _, went: _) = await mount(tester, binding: binding);

    await tester.tap(more('다시 볼 식'));
    await tester.pumpAndSettle();
    expect(find.text('지우기'), findsOneWidget);
    await tester.tap(find.text('이름 바꾸기'));
    await tester.pumpAndSettle();
    expect(rename, findsOneWidget);
    expect(tester.widget<TextField>(rename).controller!.text, '다시 볼 식');
    await tester.enterText(rename, '식 모음');
    await tester.tap(find.text('완료'));
    await tester.pumpAndSettle();
    expect(rename, findsNothing);
    expect(find.text('식 모음'), findsOneWidget);
    var marks = await stored(tester, host, binding);
    expect([for (final r in marks.liveOutline) r.title], contains('식 모음'));
    final renamedAt = marks.outline
        .singleWhere((r) => r.title == '식 모음')
        .updatedAt;

    await tester.tap(more('식 모음'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('식 모음'), findsNothing);
    expect(notice, findsOneWidget);
    expect(find.text('지웠습니다 · 식 모음'), findsOneWidget);
    await tester.tap(find.text(KitTokens.undoNoticeAction));
    await tester.pumpAndSettle();
    expect(find.text('식 모음'), findsOneWidget);
    expect(notice, findsNothing);
    // removed, then brought back: both written, the last one later
    marks = await stored(tester, host, binding);
    final kept = marks.outline.singleWhere((r) => r.title == '식 모음');
    expect(kept.updatedAt.isAfter(renamedAt), isTrue);
    expect(kept.deleted, isFalse, reason: 'undone, and stored so');
    expect(kept.pageId, 'p1');
  });

  testWidgets('a PDF line is renamed and hidden, the lines under it too', (
    tester,
  ) async {
    final binding = await openVault(tester);
    final (:host, core: _, went: _) = await mount(tester, binding: binding);

    await tester.tap(more('2. 방법'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 바꾸기'));
    await tester.pumpAndSettle();
    await tester.enterText(rename, '2. 방법론');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('2. 방법'), findsNothing);
    expect(find.text('2. 방법론'), findsOneWidget);

    await tester.tap(more('2. 방법론'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pumpAndSettle();
    // the line and the two under it
    for (final title in ['2. 방법론', '2.1 자료 모으기', '2.2 실험 순서']) {
      expect(find.text(title), findsNothing, reason: title);
    }
    expect(find.text('1. 들어가며'), findsOneWidget);
    expect(find.text('3. 결과'), findsOneWidget);
    expect(find.text('지웠습니다 · 2. 방법론'), findsOneWidget);
    var marks = await stored(tester, host, binding);
    var edit = marks.pdfOutlineEdits.single;
    expect(
      (edit.pageId, edit.depth, edit.originalTitle, edit.title, edit.hidden),
      ('p1', 0, '2. 방법', '2. 방법론', true),
    );

    await tester.tap(find.text(KitTokens.undoNoticeAction));
    await tester.pumpAndSettle();
    for (final title in ['2. 방법론', '2.1 자료 모으기', '2.2 실험 순서']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    marks = await stored(tester, host, binding);
    edit = marks.pdfOutlineEdits.single;
    expect((edit.title, edit.hidden), ('2. 방법론', false));
  });

  testWidgets('a row press goes to its page; a phone closes the panel', (
    tester,
  ) async {
    for (final phone in [false, true]) {
      final binding = await openVault(tester, marks: userOutline());
      final (:host, core: _, :went) = await mount(
        tester,
        binding: binding,
        size: phone ? const Size(360, 600) : const Size(586, 734),
      );
      await tester.tap(find.text('3. 결과'));
      await tester.pumpAndSettle();
      expect(went, [3]);
      expect(host.shownPage.value, 3);
      expect(host.panelOpen.value, !phone, reason: phone ? 'phone' : 'tablet');
      if (!phone) {
        await tester.tap(find.text('질문 모음'));
        await tester.pumpAndSettle();
        expect(went, [3, 4]);
        expect(lit(tester, '질문 모음'), isTrue);
      }
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a row whose page is gone does not show', (tester) async {
    final binding = await openVault(tester, marks: userOutline());
    final (host: _, :core, went: _) = await mount(
      tester,
      binding: binding,
      outline: [...pdfOutline, line('부록', 0, 9)],
    );
    expect(find.text('지운 쪽'), findsNothing);
    expect(find.text('부록'), findsNothing);
    expect(find.text('질문 모음'), findsOneWidget);

    // the page of 「3. 결과」 deleted from the note, the panel shown again
    core.pages.removeAt(3);
    await tester.pumpWidget(const SizedBox());
    await mount(tester, binding: binding, core: core);
    expect(find.text('3. 결과'), findsNothing);
    expect(find.text('2.2 실험 순서'), findsOneWidget);
    // the user's on page 5 now stands on page 4
    expect(
      find.descendant(of: row('질문 모음'), matching: find.text('4')),
      findsOneWidget,
    );
  });

  testWidgets('without a vault the PDF outline shows, read only', (
    tester,
  ) async {
    final (host: _, core: _, :went) = await mount(tester);
    expect(find.text('PDF 목차'), findsOneWidget);
    expect(find.text('2. 방법'), findsOneWidget);
    expect(find.byKey(const ValueKey('kit-outline-more')), findsNothing);
    expect(find.text('내가 더한 개요'), findsNothing);
    // a press still goes there
    await tester.tap(find.text('2. 방법'));
    await tester.pumpAndSettle();
    expect(went, [1]);
    expect(rename, findsNothing);
  });

  testWidgets('the outline tab: none for a note with nothing to show', (
    tester,
  ) async {
    Finder tab(KitSideTab t) => find.byKey(ValueKey('kit-side-tab-${t.name}'));
    // no vault, not a PDF: nothing could show there
    await mount(tester, core: note(pdf: false));
    expect(tab(KitSideTab.outline), findsNothing);
    expect(tab(KitSideTab.pages), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    // no vault, a PDF: its outline
    await mount(tester);
    expect(tab(KitSideTab.outline), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    // a format 2 vault, not a PDF: the tab with its empty line
    final binding = await openVault(tester);
    await mount(tester, binding: binding, core: note(pdf: false));
    expect(tab(KitSideTab.outline), findsOneWidget);
    expect(find.text(keepWords(KitSideTab.outline.empty!)), findsOneWidget);
  });

  testWidgets('「개요에 추가」 adds the page on screen, its name open to change', (
    tester,
  ) async {
    final binding = await openVault(tester);
    final (:host, core: _, went: _) = await mount(
      tester,
      binding: binding,
      shown: 2,
    );
    host.panelOpen.value = false;
    // another tab (the pages tab would draw the PDF this note has none of)
    host.tab.value = KitSideTab.favorites;
    await tester.pumpAndSettle();

    unawaited(host.addOutline(2));
    await tester.pumpAndSettle();
    expect(host.panelOpen.value, isTrue);
    expect(host.tab.value, KitSideTab.outline);
    expect(rename, findsOneWidget);
    final field = tester.widget<TextField>(rename);
    expect(field.controller!.text, '쪽 3');
    // all of it chosen, so typing takes its place
    expect(
      field.controller!.selection,
      const TextSelection(baseOffset: 0, extentOffset: 3),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.enterText(rename, '실험 그림');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('실험 그림'), findsOneWidget);
    final marks = await stored(tester, host, binding);
    expect(
      [for (final r in marks.liveOutline) (r.pageId, r.title)],
      [('p2', '실험 그림')],
    );
  });

  testWidgets('a PDF brought into the open note shows its outline', (
    tester,
  ) async {
    final binding = await openVault(tester);
    final (:host, :core, went: _) = await mount(
      tester,
      binding: binding,
      core: note(pdf: false),
    );
    expect(find.text('PDF 목차'), findsNothing);
    // the note's sheet 「PDF」 adds the PDF's pages to the same note
    core.pages.add(
      EditorPage(
        pageId: 'p5',
        backgroundImage: PdfEditorImage(
          id: 5,
          assetCache: core.assetCache,
          pdfBytes: null,
          pdfFile: File('/outline-tab/b.pdf'),
          pdfPage: 0,
          pageIndex: 5,
          pageSize: const Size(100, 140),
          naturalSize: const Size(100, 140),
          onMoveImage: null,
          onDeleteImage: null,
          onMiscChange: null,
        ),
      ),
    );
    host.shownPage.value = 1;
    await tester.pumpAndSettle();
    expect(find.text('PDF 목차'), findsOneWidget);
    expect(find.text('2. 방법'), findsOneWidget);
  });

  /// The ⋯ menu of 「2.2 실험 순서」, the line of the page on screen.
  Future<Finder> openMenu(WidgetTester tester) async {
    final binding = await openVault(tester, marks: userOutline());
    await mount(tester, binding: binding, shown: 2);
    await tester.tap(more('2.2 실험 순서'));
    await tester.pumpAndSettle();
    return find.ancestor(
      of: find.text('이름 바꾸기'),
      matching: find.byWidgetPredicate(
        (w) => w is SizedBox && w.width == KitTokens.sideMenuWidth,
      ),
    );
  }

  testWidgets('the ⋯ menu is 88 high: its line inside the second row', (
    tester,
  ) async {
    final menu = await openMenu(tester);
    // `.it+.it{border-top:1px}` inside the second row's 44
    expect(
      tester.getSize(menu),
      const Size(KitTokens.sideMenuWidth, 2 * KitTokens.sideMenuRow),
    );
    expect(KitTokens.sideMenuRow * 2, 88);
  });

  testWidgets('the ⋯ menu line runs across it, #eceef2', (tester) async {
    final menu = await openMenu(tester);
    final lines = find.descendant(
      of: menu,
      matching: find.byWidgetPredicate(
        (w) =>
            (w is ColoredBox && w.color == KitTokens.menuLine) ||
            (w is DecoratedBox &&
                w.decoration is BoxDecoration &&
                ((w.decoration as BoxDecoration).border as Border?)
                        ?.top
                        .color ==
                    KitTokens.menuLine),
      ),
    );
    expect(lines, findsOneWidget);
    expect(KitTokens.menuLine, const Color(0xffeceef2));
    expect(tester.getSize(lines).width, KitTokens.sideMenuWidth);
    expect(
      tester.getTopLeft(lines).dy - tester.getTopLeft(menu).dy,
      KitTokens.sideMenuRow,
    );
  });

  testWidgets('the row whose menu is open is grey, lit or not', (tester) async {
    await openMenu(tester);
    // `.r1row.mopen` comes after `.r1row.cur`: the open row is grey, and
    // keeps its bar and its weight
    final shade = tester.widget<DecoratedBox>(
      find
          .descendant(of: row('2.2 실험 순서'), matching: find.byType(DecoratedBox))
          .first,
    );
    expect(
      (shade.decoration as BoxDecoration).color,
      KitTokens.sideRowMenuOpenBg,
    );
    expect(KitTokens.sideRowMenuOpenBg, const Color(0xfff1f3f6));
    expect(
      find.descendant(
        of: row('2.2 실험 순서'),
        matching: find.byKey(const ValueKey('kit-outline-current')),
      ),
      findsOneWidget,
    );
    expect(lit(tester, '2.2 실험 순서'), isTrue);
  });

  testWidgets('a name being changed is kept when the panel closes', (
    tester,
  ) async {
    final binding = await openVault(tester, marks: userOutline());
    final (:host, core: _, went: _) = await mount(tester, binding: binding);
    await tester.tap(more('다시 볼 식'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 바꾸기'));
    await tester.pumpAndSettle();
    await tester.enterText(rename, '식 정리');
    await tester.pump();
    // back closes the panel (the editor's closeOpenWindow)
    host.panelOpen.value = false;
    await tester.pumpAndSettle();
    expect(host.renaming.value, isNull);
    final marks = await stored(tester, host, binding);
    expect([for (final r in marks.liveOutline) r.title], contains('식 정리'));
    host.togglePanel();
    await tester.pumpAndSettle();
    expect(rename, findsNothing);
    expect(find.text('식 정리'), findsOneWidget);
  });

  testWidgets('Escape leaves the old name; the field reads 「개요 이름」', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final binding = await openVault(tester, marks: userOutline());
    final (:host, core: _, went: _) = await mount(tester, binding: binding);
    await tester.tap(more('다시 볼 식'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 바꾸기'));
    await tester.pumpAndSettle();
    await tester.enterText(rename, '버릴 이름');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(rename, findsNothing);
    expect(find.text('다시 볼 식'), findsOneWidget);
    expect(find.text('버릴 이름'), findsNothing);
    // and closing the panel then keeps the old name
    host.panelOpen.value = false;
    await tester.pumpAndSettle();
    final marks = await stored(tester, host, binding);
    final titles = [for (final r in marks.liveOutline) r.title];
    expect(titles, contains('다시 볼 식'));
    expect(titles, isNot(contains('버릴 이름')));
    host.togglePanel();
    await tester.pumpAndSettle();
    await tester.tap(more('다시 볼 식'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 바꾸기'));
    await tester.pumpAndSettle();
    // the field alone, apart from 「완료」
    final field = tester.getSemantics(rename);
    expect(field.label, '개요 이름');
    expect(field.flagsCollection.isTextField, isTrue);
    expect(find.bySemanticsLabel('완료'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('an empty outline that cannot change says so; none while read', (
    tester,
  ) async {
    const none = '이 노트에는 개요가 없습니다.';
    final empty = find.text(keepWords(KitSideTab.outline.empty!));
    // no vault, a PDF without an outline
    await mount(tester, outline: const []);
    expect(find.text(keepWords(none)), findsOneWidget);
    expect(empty, findsNothing);
    await tester.pumpWidget(const SizedBox());

    // a format 2 vault, a note that may not change
    final binding = await openVault(tester);
    await mount(
      tester,
      binding: binding,
      core: note(pdf: false)..readOnlyReason = ReadOnlyReason.versionTooNew,
    );
    expect(find.text(keepWords(none)), findsOneWidget);
    expect(empty, findsNothing);
    await tester.pumpWidget(const SizedBox());

    // while the PDF's outline is read: no line at all
    final reading = Completer<List<PdfOutlineRow>>();
    await mount(tester, read: () => reading.future);
    expect(find.text(keepWords(none)), findsNothing);
    expect(empty, findsNothing);
    expect(find.text('PDF 목차'), findsNothing);
    reading.complete(const []);
    await tester.pumpAndSettle();
    expect(find.text(keepWords(none)), findsOneWidget);
  });

  testWidgets('drawn again as it was, the outline is not made again', (
    tester,
  ) async {
    final binding = await openVault(tester, marks: userOutline());
    final (:host, :core, went: _) = await mount(tester, binding: binding);
    final first = host.outlineOf(core);
    final again = host.outlineOf(core);
    expect(identical(first.pdf, again.pdf), isTrue);
    expect(identical(first.mine, again.mine), isTrue);
    // the page on screen moved: lit anew
    host.shownPage.value = 2;
    final moved = host.outlineOf(core);
    expect(identical(first.mine, moved.mine), isFalse);
    // a line added: made anew
    unawaited(host.addOutline(3));
    final added = host.outlineOf(core);
    expect(identical(moved.mine, added.mine), isFalse);
    expect(added.mine, hasLength(moved.mine.length + 1));
    await tester.pumpAndSettle();
    await stored(tester, host, binding);
    // the lines are built as they scroll in
    final list = tester.widget<ListView>(
      find.descendant(
        of: find.byType(KitSideOutline),
        matching: find.byType(ListView),
      ),
    );
    expect(list.childrenDelegate, isA<SliverChildBuilderDelegate>());
  });
}
