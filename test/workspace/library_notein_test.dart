import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/canvas_background_preview.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/document_facts.dart';
import 'package:saber/data/vault/library_marks.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/library_cards.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/library_menus.dart';
import 'package:sbn/canvas_background_pattern.dart';

/// The library screen laid out like Notein's (사진 1000319963 등, 설계 1–4절).
void main() {
  var sequence = 1;
  String id() =>
      '00000000-0000-4000-8000-${(sequence++).toString().padLeft(12, '0')}';
  RevisionRecord revision(String entity, EntityKind kind) => RevisionRecord(
    vaultId: id(),
    entityId: entity,
    kind: kind,
    revisionId: id(),
    parentRevisionIds: [],
    deviceId: id(),
    blobs: {},
    formatVersion: 2,
  );
  VaultNote note(
    String title, {
    String? folderId,
    VaultDocumentKind kind = VaultDocumentKind.handwriting,
    bool trashed = false,
  }) {
    final entity = id();
    return VaultNote(
      entity,
      title,
      id(),
      id(),
      revision(entity, EntityKind.metadata),
      folderId: folderId,
      documentKind: kind,
      trashed: trashed,
    );
  }

  VaultFolder folder(String title, {String? parentId}) {
    final entity = id();
    return VaultFolder(
      entity,
      title,
      parentId,
      revision(entity, EntityKind.folder),
    );
  }

  LibraryMarks marksOf({
    Set<String> favorites = const {},
    Set<String> pinned = const {},
    List<LibraryLabel> labels = const [],
    Map<String, Set<String>> labelsOf = const {},
    Map<String, ({int color, int changedAt})> covers = const {},
  }) => LibraryMarks(
    favorites: favorites,
    pinned: pinned,
    labels: labels,
    labelsOf: labelsOf,
    covers: covers,
  );

  setUp(() {
    FlavorConfig.setup();
    stows.libraryGrid.value = true;
    stows.librarySort.value = 'default';
  });

  Future<void> mount(
    WidgetTester tester, {
    List<VaultNote> notes = const [],
    List<VaultFolder> folders = const [],
    String? currentFolderId,
    Map<String, DocumentFacts> facts = const {},
    Map<String, ImageProvider> thumbnails = const {},
    LibraryMarks marks = LibraryMarks.empty,
    List<LibraryImportJobView> importJobs = const [],
    LibraryCollection collection = const LibraryCollection.folder(),
    ValueChanged<VaultNote>? onOpenNote,
    ValueChanged<LibraryCreateAction>? onCreate,
    void Function(VaultNote, LibraryNoteAction)? onNoteAction,
    void Function(String)? onToggleFavorite,
    void Function(String)? onTogglePin,
    void Function(String)? onEditLabels,
    void Function(String)? onChangeCover,
    ValueChanged<String>? onCancelImport,
    VoidCallback? onOpenSettings,
    ValueChanged<bool>? onSelectionChanged,
    ValueChanged<String>? onSearchChanged,
    String? searchQuery,
    bool searchPending = false,
    bool showTrash = false,
    bool selecting = false,
    Widget? syncButton,
    ThemeData? theme,
    Size size = const Size(1100, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: LibraryHome(
            leading: IconButton(
              tooltip: '메뉴',
              icon: const Icon(Icons.menu),
              onPressed: () {},
            ),
            notes: notes,
            folders: folders,
            currentFolderId: currentFolderId,
            facts: facts,
            thumbnails: thumbnails,
            marks: marks,
            importJobs: importJobs,
            collection: collection,
            onOpenNote: onOpenNote ?? (_) {},
            onOpenFolder: (_) {},
            onCreate: onCreate ?? (_) {},
            onNoteAction: onNoteAction,
            onToggleFavorite: onToggleFavorite,
            onTogglePin: onTogglePin,
            onEditLabels: onEditLabels,
            onChangeCover: onChangeCover,
            onCancelImport: onCancelImport,
            onOpenSettings: onOpenSettings,
            onSelectionChanged: onSelectionChanged,
            onSearchChanged: onSearchChanged,
            searchQuery: searchQuery,
            searchPending: searchPending,
            showTrash: showTrash,
            selecting: selecting,
            syncButton: syncButton,
          ),
        ),
      ),
    );
  }

  Finder key(String value) => find.byKey(ValueKey(value));

  testWidgets(
    'the top bar has sync, search, settings, select and the view menu',
    (tester) async {
      var settings = 0;
      final searches = <String>[];
      await mount(
        tester,
        notes: [note('필기 수업')],
        onOpenSettings: () => settings++,
        onSelectionChanged: (_) {},
        onSearchChanged: searches.add,
      );
      const icons = [
        'library-sync',
        'library-search-toggle',
        'library-settings',
        'library-select-mode',
        'library-view-menu',
      ];
      final rects = [for (final name in icons) tester.getRect(key(name))];
      // Notein's order from left to right, on one line at the right end.
      for (var i = 1; i < rects.length; i++) {
        expect(
          rects[i].left,
          greaterThan(rects[i - 1].right - 1),
          reason: icons[i],
        );
        expect(
          rects[i].center.dy,
          closeTo(rects[0].center.dy, 1),
          reason: icons[i],
        );
      }
      expect(rects.last.right, greaterThan(1100 - 40));
      expect(
        rects.first.bottom,
        lessThanOrEqualTo(tester.getRect(key('library-filter-tabs')).top),
      );
      expect(
        find.descendant(
          of: key('library-sync'),
          matching: find.byIcon(Icons.cloud_off_outlined),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      await tester.tap(key('library-settings'));
      expect(settings, 1);

      // The search box opens in the top bar itself.
      expect(key('library-search'), findsNothing);
      await tester.tap(key('library-search-toggle'));
      await tester.pump();
      expect(find.byType(LibrarySearchField), findsOneWidget);
      expect(
        tester.getRect(key('library-search')).bottom,
        lessThanOrEqualTo(tester.getRect(key('library-filter-tabs')).top),
      );
      await tester.enterText(key('library-search'), '수업');
      expect(searches, ['수업']);

      // Without a settings callback there is no gear (the side panel keeps
      // that key until the workspace moves it here).
      await tester.pumpWidget(const SizedBox());
      await mount(tester, notes: [note('필기 수업')]);
      expect(key('library-settings'), findsNothing);
      // The workspace's own cloud replaces the plain crossed-out one.
      await mount(
        tester,
        syncButton: const Icon(Icons.cloud_done, key: ValueKey('custom-sync')),
      );
      expect(key('custom-sync'), findsOneWidget);
      expect(key('library-sync'), findsNothing);
    },
  );

  testWidgets('four kind tabs filter pdf and office together and notes apart', (
    tester,
  ) async {
    final lectures = folder('강의 폴더');
    final titles = ['필기 수업', '강의 자료', '발표 원본', '정리 문서', '아이디어 판', '강의 폴더'];
    await mount(
      tester,
      folders: [lectures],
      notes: [
        note('필기 수업'),
        note('강의 자료', kind: VaultDocumentKind.pdf),
        note('발표 원본', kind: VaultDocumentKind.office),
        note('정리 문서', kind: VaultDocumentKind.markdown),
        note('아이디어 판', kind: VaultDocumentKind.infinite),
      ],
    );
    final bar = tester.widget<TabBar>(key('library-filter-tabs'));
    expect(
      [for (final tab in bar.tabs) (tab as Tab).text],
      ['모두', 'PDF', '메모', '폴더'],
    );
    List<String> shown() => [
      for (final title in titles)
        if (find.text(title).evaluate().isNotEmpty) title,
    ];
    expect(shown(), titles);
    await tester.tap(key('library-filter-pdf'));
    await tester.pumpAndSettle();
    expect(shown(), ['강의 자료', '발표 원본']);
    await tester.tap(key('library-filter-notes'));
    await tester.pumpAndSettle();
    expect(shown(), ['필기 수업', '정리 문서', '아이디어 판']);
    await tester.tap(key('library-filter-folders'));
    await tester.pumpAndSettle();
    expect(shown(), ['강의 폴더']);
    await tester.tap(key('library-filter-all'));
    await tester.pumpAndSettle();
    expect(shown(), titles);
  });

  testWidgets('cards follow the document shape', (tester) async {
    final slides = note('슬라이드', kind: VaultDocumentKind.pdf);
    final page = note('세로 노트');
    final board = note('무한 판', kind: VaultDocumentKind.infinite);
    final deck = note('발표', kind: VaultDocumentKind.office);
    await mount(
      tester,
      notes: [slides, page, board, deck],
      facts: {
        slides.id: const DocumentFacts(aspect: 16 / 9, pages: 12),
        deck.id: const DocumentFacts(format: 'pptx'),
      },
    );
    Size cover(VaultNote note) =>
        tester.getSize(key('library-cover-${note.id}'));
    expect(cover(slides).width, greaterThan(cover(slides).height));
    expect(cover(slides).aspectRatio, closeTo(16 / 9, .02));
    expect(cover(page).height, greaterThan(cover(page).width));
    expect(cover(page).aspectRatio, closeTo(.707, .01));
    expect(cover(board).width, closeTo(cover(board).height, .5));
    // A PowerPoint original without a cover picture yet is a 16:9 slide.
    expect(cover(deck).aspectRatio, closeTo(16 / 9, .02));

    // The cover box is 80% of the card's column and 1.33 times as tall: a
    // wide cover fills its width, an upright page its height.
    final column = tester
        .getSize(key('library-note-${page.revision.revisionId}'))
        .width;
    expect(cover(slides).width, closeTo(column * .8, .5));
    expect(cover(page).height, closeTo(column * .8 * 1.33, .5));
    // Each cover sits in the middle of its box, so a row shares one middle
    // line, and the title line with its ⌄ stays under the box whatever the
    // cover's size.
    double middle(VaultNote note) =>
        tester.getCenter(key('library-cover-${note.id}')).dy;
    expect(middle(slides), closeTo(middle(page), .5));
    expect(middle(board), closeTo(middle(page), .5));
    double menuBottom(VaultNote note) => tester
        .getRect(key('library-note-menu-${note.revision.revisionId}'))
        .bottom;
    expect(menuBottom(slides), closeTo(menuBottom(page), .5));
    expect(
      tester
          .getRect(key('library-note-menu-${slides.revision.revisionId}'))
          .top,
      greaterThan(tester.getRect(key('library-cover-${page.id}')).bottom),
    );
  });

  testWidgets('a pptx card shows the PPT mark and a hwp card the 한글 mark', (
    tester,
  ) async {
    final deck = note('발표', kind: VaultDocumentKind.office);
    final letter = note('공문', kind: VaultDocumentKind.office);
    final report = note('보고서', kind: VaultDocumentKind.office);
    final paper = note('논문', kind: VaultDocumentKind.pdf);
    await mount(
      tester,
      notes: [deck, letter, report, paper],
      facts: {
        deck.id: const DocumentFacts(format: 'pptx'),
        letter.id: const DocumentFacts(format: 'hwp'),
        report.id: const DocumentFacts(format: 'docx'),
        paper.id: const DocumentFacts(format: 'pdf'),
      },
    );
    LibraryFormatMark mark(VaultNote note) =>
        tester.widget<LibraryFormatMark>(key('library-format-${note.id}'));
    expect(mark(deck).label, 'PPT');
    expect(mark(deck).color, const Color(0xFFD24726));
    expect(mark(letter).label, '한글');
    expect(mark(letter).color, const Color(0xFF1E8BD8));
    expect(mark(report).label, 'Word');
    expect(mark(report).color, const Color(0xFF2B579A));
    expect(key('library-format-${paper.id}'), findsNothing);

    // The ㄱ band runs from the cover's top-left corner along part of its
    // top and left edges.
    final cover = tester.getRect(key('library-cover-${deck.id}'));
    final band = tester.getRect(key('library-format-${deck.id}'));
    expect((band.topLeft - cover.topLeft).distance, lessThan(.5));
    expect(band.width, closeTo(cover.width * .4, .5));
    expect(band.height, closeTo(cover.height * .3, .5));
    // Without a cover picture the format's name is drawn large on its colour.
    expect(
      find.descendant(
        of: key('library-cover-${deck.id}'),
        matching: find.text('PPT'),
      ),
      findsNWidgets(2),
    );

    // The other formats in the table, including the OpenDocument ones.
    expect(libraryFormatOf('ppt')!.label, 'PPT');
    expect(libraryFormatOf('odp')!.label, 'ODP');
    expect(libraryFormatOf('odp')!.color, const Color(0xFFD24726));
    expect(libraryFormatOf('doc')!.label, 'Word');
    expect(libraryFormatOf('odt')!.label, 'ODT');
    expect(libraryFormatOf('odt')!.color, const Color(0xFF2B579A));
    expect(libraryFormatOf('hwpx')!.label, '한글');
    expect(libraryFormatOf('xlsx')!.label, 'Excel');
    expect(libraryFormatOf('xlsx')!.color, const Color(0xFF217346));
    expect(libraryFormatOf('ods')!.label, 'ODS');
    expect(libraryFormatOf('pdf'), isNull);
    expect(libraryFormatOf(null), isNull);
  });

  testWidgets('the heart toggles a favorite through the callback', (
    tester,
  ) async {
    final page = note('세로 노트');
    final lectures = folder('강의');
    final toggled = <String>[];
    final opened = <VaultNote>[];
    await mount(
      tester,
      notes: [page],
      folders: [lectures],
      onToggleFavorite: toggled.add,
      onOpenNote: opened.add,
    );
    final heart = key('library-favorite-${page.id}');
    expect(
      find.descendant(of: heart, matching: find.byIcon(Icons.favorite_border)),
      findsOneWidget,
    );
    // On the cover's top-right corner.
    final cover = tester.getRect(key('library-cover-${page.id}'));
    final spot = tester.getRect(heart);
    expect((spot.topRight - cover.topRight).distance, lessThan(6));
    await tester.tap(heart);
    expect(toggled, [page.id]);
    expect(opened, isEmpty);
    // 즐겨찾기 lists documents only, so a folder card has no heart.
    expect(key('library-folder-${lectures.id}'), findsOneWidget);
    expect(key('library-favorite-${lectures.id}'), findsNothing);

    await mount(
      tester,
      notes: [page],
      folders: [lectures],
      onToggleFavorite: toggled.add,
      marks: marksOf(favorites: {page.id}),
    );
    expect(
      find.descendant(of: heart, matching: find.byIcon(Icons.favorite)),
      findsOneWidget,
    );
    // Nor in the list.
    stows.libraryGrid.value = false;
    await tester.pump();
    expect(key('library-folder-${lectures.id}'), findsOneWidget);
    expect(heart, findsOneWidget);
    expect(key('library-favorite-${lectures.id}'), findsNothing);
    stows.libraryGrid.value = true;
    await tester.pump();
    // No hearts in the trash.
    await mount(
      tester,
      notes: [note('지운 노트', trashed: true)],
      showTrash: true,
      onToggleFavorite: toggled.add,
    );
    expect(find.byIcon(Icons.favorite_border), findsNothing);
  });

  testWidgets(
    'the v button opens 고정, 이름 바꾸기, 표지 변경, 라벨 추가, 이동, 휴지통으로 이동, 상세 정보',
    (tester) async {
      final course = folder('강의');
      final page = note('세로 노트', folderId: course.id);
      final pins = <String>[], covers = <String>[], labels = <String>[];
      final actions = <LibraryNoteAction>[];
      await mount(
        tester,
        folders: [course],
        currentFolderId: course.id,
        notes: [page],
        facts: {
          page.id: DocumentFacts(
            changed: DateTime(2026, 11, 17, 9, 30),
            created: DateTime(2026, 11, 16, 8, 5),
            pages: 3,
          ),
        },
        onNoteAction: (_, action) => actions.add(action),
        onTogglePin: pins.add,
        onChangeCover: covers.add,
        onEditLabels: labels.add,
      );
      final menu = key('library-note-menu-${page.revision.revisionId}');
      final arrow = tester.widget<Icon>(
        find.descendant(of: menu, matching: find.byType(Icon)),
      );
      expect(arrow.icon, Icons.expand_more);
      expect(arrow.size, 18);
      // The title line under the cover is the button (StarNote's 「내 연구 ⌄」).
      final cover = tester.getRect(key('library-cover-${page.id}'));
      expect(tester.getRect(menu).top, greaterThan(cover.bottom));
      expect(
        find.descendant(of: menu, matching: find.text('세로 노트')),
        findsOneWidget,
      );
      // The card's line under the title: date, then the page count.
      expect(find.text('26/11/17 · 3 페이지'), findsOneWidget);

      await tester.tap(menu);
      await tester.pumpAndSettle();
      const rows = [
        '고정',
        '이름 바꾸기',
        '표지 변경',
        '라벨 추가',
        '이동',
        '휴지통으로 이동',
        '상세 정보',
      ];
      final ys = [for (final row in rows) tester.getCenter(find.text(row)).dy];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: rows[i]);
      }
      expect(key('library-note-preview'), findsNothing);
      expect(
        tester.widget<Text>(find.text('휴지통으로 이동')).style?.color,
        const Color(0xFFE53935),
      );

      Future<void> choose(String row) async {
        await tester.tap(find.text(row));
        await tester.pumpAndSettle();
      }

      await choose('고정');
      expect(pins, [page.id]);
      for (final row in ['이름 바꾸기', '표지 변경', '라벨 추가', '이동', '휴지통으로 이동']) {
        await tester.tap(menu);
        await tester.pumpAndSettle();
        await choose(row);
      }
      expect(actions, [
        LibraryNoteAction.rename,
        LibraryNoteAction.move,
        LibraryNoteAction.trash,
      ]);
      expect(covers, [page.id]);
      expect(labels, [page.id]);

      await tester.tap(menu);
      await tester.pumpAndSettle();
      await choose('상세 정보');
      final details = key('library-details-dialog');
      expect(details, findsOneWidget);
      for (final text in [
        '페이지 노트',
        '26/11/16 08:05',
        '26/11/17 09:30',
        '3 페이지',
        '내 문서 › 강의',
      ]) {
        expect(
          find.descendant(of: details, matching: find.text(text)),
          findsOneWidget,
          reason: text,
        );
      }
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      expect(details, findsNothing);

      // A pinned card offers 고정 해제 and shows a pin on its cover.
      await mount(
        tester,
        folders: [course],
        currentFolderId: course.id,
        notes: [page],
        onTogglePin: pins.add,
        marks: marksOf(pinned: {page.id}),
      );
      final pin = key('library-pin-${page.id}');
      expect(
        tester.widget<Icon>(
          find.descendant(
            of: pin,
            matching: find.byType(Icon),
            matchRoot: true,
          ),
        ),
        isA<Icon>()
            .having((icon) => icon.icon, 'icon', Icons.push_pin)
            .having((icon) => icon.size, 'size', 12),
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(find.text('고정 해제'), findsOneWidget);
      expect(find.text('고정'), findsNothing);
    },
  );

  testWidgets(
    "the plus button opens the add menu in the photo's order and the pencil makes a page note",
    (tester) async {
      final created = <LibraryCreateAction>[];
      await mount(tester, onCreate: created.add);
      final pencil = key('library-new-note');
      final plus = key('library-create-button');
      // A small light pencil (a 40 circle in a 48 touch area) above the big
      // blue +, at the bottom right.
      expect(tester.getSize(pencil), const Size(48, 48));
      expect(
        tester.getSize(
          find.descendant(of: pencil, matching: find.byType(Material)).first,
        ),
        const Size(40, 40),
      );
      expect(tester.getSize(plus), const Size(56, 56));
      expect(tester.getCenter(pencil).dy, lessThan(tester.getCenter(plus).dy));
      expect(tester.getRect(plus).right, greaterThan(1100 - 48));
      expect(tester.getRect(plus).bottom, greaterThan(900 - 48));
      expect(
        tester
            .widget<Material>(
              find.descendant(of: plus, matching: find.byType(Material)).first,
            )
            .color,
        const Color(0xFF3D5AFE),
      );
      await tester.tap(pencil);
      expect(created, [LibraryCreateAction.handwriting]);

      await tester.tap(plus);
      await tester.pumpAndSettle();
      const rows = [
        ('library-add-note', '새 노트…'),
        ('library-add-folder', '새 폴더'),
        ('library-add-pdf', 'PDF 가져오기'),
        ('library-add-importPpt', 'PPT 가져오기'),
        ('library-add-importWord', 'Word 가져오기'),
        ('library-add-importHwp', '한글 가져오기'),
        ('library-add-image', '이미지 가져오기'),
        ('library-add-camera', '사진 촬영'),
        ('library-add-other', '다른 앱에서 가져오기'),
      ];
      final ys = <double>[];
      for (final (name, text) in rows) {
        expect(
          find.descendant(of: key(name), matching: find.text(text)),
          findsOneWidget,
          reason: name,
        );
        ys.add(tester.getCenter(key(name)).dy);
      }
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: rows[i].$1);
      }
      // Above the +, its right edge in line with the button's.
      expect(
        tester.getRect(key('library-add-other')).bottom,
        lessThan(tester.getRect(plus).top),
      );
      // The imports carry their format's colour.
      Color? iconColor(String name) => tester
          .widget<Icon>(
            find.descendant(of: key(name), matching: find.byType(Icon)).first,
          )
          .color;
      expect(iconColor('library-add-importPpt'), const Color(0xFFD24726));
      expect(iconColor('library-add-importWord'), const Color(0xFF2B579A));
      expect(iconColor('library-add-importHwp'), const Color(0xFF1E8BD8));

      await tester.tap(key('library-add-importPpt'));
      await tester.pumpAndSettle();
      expect(created, [
        LibraryCreateAction.handwriting,
        LibraryCreateAction.importPpt,
      ]);

      // 「다른 앱에서 가져오기 ›」 holds Obsidian, Notion and StarNote.
      await tester.tap(plus);
      await tester.pumpAndSettle();
      await tester.tap(key('library-add-other'));
      await tester.pumpAndSettle();
      expect(find.text('Obsidian 보관함'), findsOneWidget);
      expect(find.text('Notion ZIP'), findsOneWidget);
      expect(find.text('StarNote'), findsOneWidget);
      await tester.tap(key('library-import-notion'));
      await tester.pumpAndSettle();
      await tester.tap(plus);
      await tester.pumpAndSettle();
      await tester.tap(key('library-add-other'));
      await tester.pumpAndSettle();
      await tester.tap(key('library-import-obsidian'));
      await tester.pumpAndSettle();
      await tester.tap(plus);
      await tester.pumpAndSettle();
      await tester.tap(key('library-add-other'));
      await tester.pumpAndSettle();
      await tester.tap(key('library-import-starnote'));
      await tester.pumpAndSettle();
      expect(created.skip(2), [
        LibraryCreateAction.notionZip,
        LibraryCreateAction.obsidianVault,
        LibraryCreateAction.starnote,
      ]);

      // Only what the workspace can do is offered.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LibraryHome(
              notes: const [],
              folders: const [],
              currentFolderId: null,
              onOpenNote: (_) {},
              onOpenFolder: (_) {},
              onCreate: created.add,
              availableCreateActions: const {
                LibraryCreateAction.handwriting,
                LibraryCreateAction.pdf,
              },
            ),
          ),
        ),
      );
      await tester.tap(plus);
      await tester.pumpAndSettle();
      expect(key('library-add-note'), findsOneWidget);
      expect(key('library-add-pdf'), findsOneWidget);
      expect(key('library-add-folder'), findsNothing);
      expect(key('library-add-importPpt'), findsNothing);
      expect(key('library-add-other'), findsNothing);
      await tester.tapAt(const Offset(20, 450));
      await tester.pumpAndSettle();

      // Hidden in the trash and while selecting.
      await mount(tester, showTrash: true);
      expect(plus, findsNothing);
      expect(pencil, findsNothing);
      await mount(tester, selecting: true, onSelectionChanged: (_) {});
      expect(plus, findsNothing);
      expect(pencil, findsNothing);
    },
  );

  testWidgets(
    'the new note dialog stores the chosen pattern and creates a page note',
    (tester) async {
      final previous = stows.lastBackgroundPattern.value;
      addTearDown(() => stows.lastBackgroundPattern.value = previous);
      stows.lastBackgroundPattern.value = CanvasBackgroundPattern.lined;
      final created = <LibraryCreateAction>[];
      await mount(tester, onCreate: created.add);
      Future<void> open() async {
        await tester.tap(key('library-create-button'));
        await tester.pumpAndSettle();
        await tester.tap(key('library-add-note'));
        await tester.pumpAndSettle();
      }

      await open();
      final dialog = key('library-new-note-dialog');
      expect(dialog, findsOneWidget);
      // The head: 취소 / 새 노트 / 만들기.
      final head = [
        tester.getCenter(
          find.descendant(of: dialog, matching: find.text('취소')),
        ),
        tester.getCenter(
          find.descendant(of: dialog, matching: find.text('새 노트')),
        ),
        tester.getCenter(
          find.descendant(of: dialog, matching: find.text('만들기')),
        ),
      ];
      expect(head[0].dx, lessThan(head[1].dx));
      expect(head[1].dx, lessThan(head[2].dx));
      // 만들기 is a blue pill and the chosen pattern's border is the same blue,
      // whatever the app's accent colour (Notein's 「페이지 추가」).
      const blue = Color(0xFF3D5AFE);
      expect(
        tester
            .widget<FilledButton>(key('library-new-note-create'))
            .style
            ?.backgroundColor
            ?.resolve(<WidgetState>{}),
        blue,
      );
      expect(
        Theme.of(tester.element(find.byType(CanvasBackgroundPreview).first))
            .colorScheme
            .primary,
        blue,
      );
      // Keyed by the pattern's Dart name (the enum's own `name` is its file
      // name, empty for none).
      const patterns = [
        (CanvasBackgroundPattern.lined, 'lined', '선'),
        (CanvasBackgroundPattern.none, 'none', '공백'),
        (CanvasBackgroundPattern.grid, 'grid', '정사각형'),
        (CanvasBackgroundPattern.cornell, 'cornell', '코넬'),
        (CanvasBackgroundPattern.dots, 'dots', '점'),
        (CanvasBackgroundPattern.collegeLtr, 'collegeLtr', '대학 노트'),
      ];
      bool chosen(String name) => tester
          .widget<CanvasBackgroundPreview>(
            find.descendant(
              of: key('library-pattern-$name'),
              matching: find.byType(CanvasBackgroundPreview),
            ),
          )
          .selected;
      for (final (pattern, name, label) in patterns) {
        expect(
          find.descendant(
            of: key('library-pattern-$name'),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: label,
        );
        expect(chosen(name), pattern == CanvasBackgroundPattern.lined);
      }
      await tester.tap(key('library-pattern-grid'));
      await tester.pump();
      expect(chosen('grid'), isTrue);
      expect(chosen('lined'), isFalse);
      await tester.tap(key('library-new-note-create'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(stows.lastBackgroundPattern.value, CanvasBackgroundPattern.grid);
      expect(created, [LibraryCreateAction.pageNoteWithPattern]);

      // The list below makes its kind at once, without touching the pattern.
      await open();
      const kinds = [
        ('infinite', '무한 노트'),
        ('quickNote', '빠른 메모'),
        ('markdown', 'Markdown'),
        ('canvas', '카드 캔버스'),
        ('page', '블록 페이지'),
        ('database', '데이터베이스'),
        ('dailyNote', '오늘 노트'),
        ('datedNote', '날짜별 노트'),
        ('dailyNoteTemplate', '날짜별 노트 템플릿'),
        ('wordDocument', '새 Word 문서'),
        ('presentation', '새 프레젠테이션'),
        ('hwpx', '새 한글 문서'),
      ];
      for (final (name, text) in kinds) {
        final row = key('library-new-$name');
        await tester.ensureVisible(row);
        expect(
          find.descendant(of: row, matching: find.text(text)),
          findsOneWidget,
        );
      }
      await tester.tap(key('library-new-markdown'));
      await tester.pumpAndSettle();
      expect(created.last, LibraryCreateAction.markdown);
      expect(stows.lastBackgroundPattern.value, CanvasBackgroundPattern.grid);

      // 취소 makes nothing; the dialog opens on the last pattern.
      await open();
      expect(chosen('grid'), isTrue);
      await tester.tap(find.descendant(of: dialog, matching: find.text('취소')));
      await tester.pumpAndSettle();
      expect(created, hasLength(2));
    },
  );

  testWidgets('an import card shows its percent and its × cancels', (
    tester,
  ) async {
    final page = note('세로 노트');
    final cancelled = <String>[];
    await mount(
      tester,
      notes: [page],
      importJobs: const [
        LibraryImportJobView(
          id: 'job-1',
          title: 'INFORMS2026_Temporal-Channel_AIaaS_1103',
          progress: .08,
        ),
        LibraryImportJobView(id: 'job-2', title: '읽는 중.pdf'),
        LibraryImportJobView(
          id: 'job-3',
          title: '깨진.pptx',
          error: '파일을 읽을 수 없습니다.',
        ),
      ],
      onCancelImport: cancelled.add,
    );
    final job = key('library-import-job-1');
    expect(find.descendant(of: job, matching: find.text('8%')), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.descendant(
              of: job,
              matching: find.byType(LinearProgressIndicator),
            ),
          )
          .value,
      .08,
    );
    // First in the folder, before the documents, without a heart or ⌄.
    final document = tester.getRect(
      key('library-note-${page.revision.revisionId}'),
    );
    expect(tester.getRect(job).left, lessThan(document.left));
    expect(
      find.descendant(of: job, matching: find.byIcon(Icons.expand_more)),
      findsNothing,
    );
    expect(
      find.descendant(of: job, matching: find.byIcon(Icons.download)),
      findsOneWidget,
    );
    // Progress not known yet: a moving bar and 가져오는 중.
    final reading = key('library-import-job-2');
    expect(
      find.descendant(of: reading, matching: find.text('가져오는 중')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.descendant(
              of: reading,
              matching: find.byType(LinearProgressIndicator),
            ),
          )
          .value,
      isNull,
    );
    // A failed import says so in red; a tap shows why.
    final failed = key('library-import-job-3');
    final failure = find.descendant(
      of: failed,
      matching: find.text('가져오지 못했습니다'),
    );
    expect(failure, findsOneWidget);
    expect(tester.widget<Text>(failure).style?.color, const Color(0xFFE53935));
    await tester.tap(failure);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('파일을 읽을 수 없습니다.'), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(key('library-import-cancel-job-1'));
    expect(cancelled, ['job-1']);
    await tester.tap(key('library-import-cancel-job-3'));
    expect(cancelled, ['job-1', 'job-3']);
    expect(
      tester
          .widget<Tooltip>(
            find
                .ancestor(
                  of: find.descendant(
                    of: key('library-import-cancel-job-3'),
                    matching: find.byType(Icon),
                  ),
                  matching: find.byType(Tooltip),
                )
                .first,
          )
          .message,
      '닫기',
    );
    // A moving bar never settles: leave the screen before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'phone width shows the top bar, four tabs, two columns and a scrollable add menu without overflow',
    (tester) async {
      final course = folder('아주 긴 이름의 연구 폴더와 그 안의 강의 자료 모음');
      final inner = folder('하위 폴더', parentId: course.id);
      final notes = [
        for (var i = 0; i < 6; i++)
          note('긴 제목의 필기와 문서 그리고 강의 정리 자료 $i', folderId: course.id),
      ];
      final created = <LibraryCreateAction>[];
      Future<void> phone(Size size) => mount(
        tester,
        size: size,
        folders: [course, inner],
        currentFolderId: course.id,
        notes: notes,
        facts: {
          for (final note in notes)
            note.id: DocumentFacts(changed: DateTime(2026, 11, 17), pages: 120),
        },
        onCreate: created.add,
        onOpenSettings: () {},
        onSelectionChanged: (_) {},
        onSearchChanged: (_) {},
        onToggleFavorite: (_) {},
        onNoteAction: (_, _) {},
      );
      await phone(const Size(360, 640));
      expect(tester.takeException(), isNull);
      void onScreen(String name) {
        final box = tester.getRect(key(name));
        expect(
          box.left >= 0 &&
              box.top >= 0 &&
              box.right <= 360 &&
              box.bottom <= 640,
          isTrue,
          reason: '$name at $box',
        );
        expect(key(name).hitTestable(), findsOneWidget, reason: name);
      }

      for (final name in [
        'library-up',
        'library-title',
        'library-sync',
        'library-search-toggle',
        'library-settings',
        'library-select-mode',
        'library-view-menu',
        'library-filter-all',
        'library-filter-pdf',
        'library-filter-notes',
        'library-filter-folders',
        'library-new-note',
        'library-create-button',
      ]) {
        onScreen(name);
      }
      // Two columns: the sub-folder and the first document fill the first
      // row, the next two documents the second.
      final sub = tester.getTopLeft(key('library-folder-${inner.id}'));
      Offset card(int i) => tester.getTopLeft(
        key('library-note-${notes[i].revision.revisionId}'),
      );
      expect(card(0).dy, closeTo(sub.dy, .5));
      expect(card(0).dx, greaterThan(sub.dx));
      expect(card(1).dy, greaterThan(card(0).dy));
      expect(card(1).dx, closeTo(sub.dx, .5));
      expect(card(2).dy, closeTo(card(1).dy, .5));

      // The add menu fits above the + on a phone held upright.
      await tester.tap(key('library-create-button'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final name in [
        'library-add-note',
        'library-add-folder',
        'library-add-pdf',
        'library-add-importPpt',
        'library-add-importWord',
        'library-add-importHwp',
        'library-add-image',
        'library-add-camera',
        'library-add-other',
      ]) {
        onScreen(name);
      }
      await tester.tap(key('library-add-other'));
      await tester.pumpAndSettle();
      onScreen('library-import-starnote');
      await tester.tap(key('library-import-starnote'));
      await tester.pumpAndSettle();
      expect(created, [LibraryCreateAction.starnote]);

      // The new note dialog fits too, and its list scrolls to the end.
      await tester.tap(key('library-create-button'));
      await tester.pumpAndSettle();
      await tester.tap(key('library-add-note'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      onScreen('library-new-note-create');
      onScreen('library-pattern-collegeLtr');
      await tester.ensureVisible(key('library-new-hwpx'));
      await tester.pumpAndSettle();
      await tester.tap(key('library-new-hwpx'));
      await tester.pumpAndSettle();
      expect(created.last, LibraryCreateAction.hwpx);

      // Held sideways the menu is taller than the room above the +, so it
      // scrolls inside and its last row can still be reached.
      await phone(const Size(640, 360));
      expect(tester.takeException(), isNull);
      await tester.tap(key('library-create-button'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(key('library-add-other'));
      await tester.pumpAndSettle();
      await tester.tap(key('library-add-other'));
      await tester.pumpAndSettle();
      await tester.tap(key('library-import-notion'));
      await tester.pumpAndSettle();
      expect(created.last, LibraryCreateAction.notionZip);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('an empty folder shows the Notein empty message', (tester) async {
    final empty = folder('빈 폴더');
    await mount(tester, folders: [empty], currentFolderId: empty.id);
    final message = key('library-empty');
    expect(message, findsOneWidget);
    expect(
      find.descendant(
        of: message,
        matching: find.byIcon(Icons.inventory_2_outlined),
      ),
      findsOneWidget,
    );
    final primary = Theme.of(tester.element(message)).colorScheme.primary;
    for (final text in ['아직 노트가 없습니다', '아래쪽 모서리의 +를 탭하여 노트를 만들거나 문서를 가져오세요.']) {
      final line = find.descendant(of: message, matching: find.text(text));
      expect(line, findsOneWidget);
      expect(tester.widget<Text>(line).style?.color, primary);
    }
    // In the middle of the document area.
    expect(tester.getCenter(message).dx, closeTo(550, 2));
    expect(
      tester.getCenter(message).dy,
      greaterThan(tester.getRect(key('library-filter-tabs')).bottom + 150),
    );

    // The trash, a search and a kind tab keep their own words.
    await mount(tester, showTrash: true);
    expect(message, findsNothing);
    expect(find.text('휴지통이 비어 있습니다.'), findsOneWidget);
    await mount(tester, notes: [note('필기 수업')], searchQuery: '없는 말');
    expect(message, findsNothing);
    expect(find.text('조건에 맞는 문서가 없습니다.'), findsOneWidget);
    await mount(tester, notes: [note('필기 수업')]);
    await tester.tap(key('library-filter-pdf'));
    await tester.pumpAndSettle();
    expect(message, findsNothing);
    expect(find.text('조건에 맞는 문서가 없습니다.'), findsOneWidget);
  });

  testWidgets(
    'the recent and favorite collections show documents from every folder without folder cards',
    (tester) async {
      final lectures = folder('강의');
      final lab = folder('연구');
      final bayes = note('베이즈', folderId: lectures.id);
      final minutes = note('회의록', folderId: lab.id);
      final memo = note('잡기장');
      final gone = note('지운 것', folderId: lab.id, trashed: true);
      String title() => tester.widget<Text>(key('library-title')).data!;
      Iterable<String> shown() => [
        for (final title in ['베이즈', '회의록', '잡기장', '지운 것'])
          if (find.text(title).evaluate().isNotEmpty) title,
      ];
      Future<void> show(LibraryCollection collection, LibraryMarks marks) =>
          mount(
            tester,
            folders: [lectures, lab],
            notes: [bayes, minutes, memo, gone],
            collection: collection,
            marks: marks,
          );

      await show(
        LibraryCollection.recent([minutes.id, bayes.id, gone.id]),
        LibraryMarks.empty,
      );
      expect(title(), '최근');
      expect(shown(), ['베이즈', '회의록']);
      // Most recent first.
      expect(
        tester.getTopLeft(find.text('회의록')).dx,
        lessThan(tester.getTopLeft(find.text('베이즈')).dx),
      );
      expect(key('library-folder-${lectures.id}'), findsNothing);
      expect(key('library-folder-${lab.id}'), findsNothing);
      expect(key('library-up'), findsNothing);

      await show(
        const LibraryCollection.favorites(),
        marksOf(favorites: {bayes.id, memo.id, lectures.id}),
      );
      expect(title(), '즐겨찾기');
      expect(shown(), ['베이즈', '잡기장']);
      expect(key('library-folder-${lectures.id}'), findsNothing);

      const lesson = LibraryLabel(id: 'l1', name: '수업', color: 0xFFE53935);
      await show(
        const LibraryCollection.label('l1', '수업'),
        marksOf(
          labels: [lesson],
          labelsOf: {
            minutes.id: {'l1'},
          },
        ),
      );
      expect(title(), '수업');
      expect(shown(), ['회의록']);
      // A labelled card shows the label's colour under its title.
      final dots = key('library-label-dots-${minutes.id}');
      expect(dots, findsOneWidget);
      expect(
        tester.getCenter(dots).dy,
        greaterThan(tester.getCenter(find.text('회의록')).dy),
      );
    },
  );

  testWidgets('the view menu switches to a list and sorts, and both are kept', (
    tester,
  ) async {
    final second = note('나 노트');
    final first = note('가 노트');
    final third = note('다 노트');
    final labelled = <String>[];
    final facts = {
      second.id: DocumentFacts(
        changed: DateTime(2026, 11, 10),
        created: DateTime(2026, 11, 1),
      ),
      third.id: DocumentFacts(
        changed: DateTime(2026, 11, 15),
        created: DateTime(2026, 10, 1),
      ),
    };
    Future<void> show() => mount(
      tester,
      notes: [second, first, third],
      facts: facts,
      onEditLabels: labelled.add,
      marks: marksOf(
        labels: const [
          LibraryLabel(id: 'l1', name: '수업', color: 0xFFE53935),
          LibraryLabel(id: 'l2', name: '연구', color: 0xFF3949AB),
        ],
      ),
    );
    await show();
    List<String> order() {
      final titles = ['가 노트', '나 노트', '다 노트'];
      final spots = {
        for (final title in titles) title: tester.getTopLeft(find.text(title)),
      };
      return titles..sort((a, b) {
        final dy = spots[a]!.dy.compareTo(spots[b]!.dy);
        return dy != 0 ? dy : spots[a]!.dx.compareTo(spots[b]!.dx);
      });
    }

    expect(order(), ['나 노트', '가 노트', '다 노트']);
    Future<void> openMenu() async {
      await tester.tap(key('library-view-menu'));
      await tester.pumpAndSettle();
    }

    Future<void> sortBy(String name) async {
      await openMenu();
      await tester.tap(key('library-view-sort'));
      await tester.pumpAndSettle();
      await tester.tap(key('library-sort-$name'));
      await tester.pumpAndSettle();
    }

    await openMenu();
    // 격자형 and 목록형 side by side on top, then 정렬 and 라벨 색상.
    final grid = tester.getCenter(key('library-view-grid'));
    final list = tester.getCenter(key('library-view-list'));
    expect(list.dy, closeTo(grid.dy, 1));
    expect(list.dx, greaterThan(grid.dx));
    expect(
      find.descendant(of: key('library-view-grid'), matching: find.text('격자형')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: key('library-view-list'), matching: find.text('목록형')),
      findsOneWidget,
    );
    expect(tester.getCenter(find.text('정렬')).dy, greaterThan(grid.dy));
    expect(
      tester.getCenter(find.text('라벨 색상')).dy,
      greaterThan(tester.getCenter(find.text('정렬')).dy),
    );
    await tester.tapAt(const Offset(20, 450));
    await tester.pumpAndSettle();

    await sortBy('title');
    expect(stows.librarySort.value, 'title');
    expect(order(), ['가 노트', '나 노트', '다 노트']);
    // Latest first; a document without dates goes last.
    await sortBy('changed');
    expect(order(), ['다 노트', '나 노트', '가 노트']);
    await sortBy('created');
    expect(order(), ['나 노트', '다 노트', '가 노트']);

    await openMenu();
    await tester.tap(key('library-view-list'));
    await tester.pumpAndSettle();
    expect(stows.libraryGrid.value, isFalse);
    expect(key('library-list'), findsOneWidget);
    expect(key('library-grid'), findsNothing);

    // A new library screen starts from what was chosen.
    await tester.pumpWidget(const SizedBox());
    await show();
    expect(key('library-list'), findsOneWidget);
    expect(order(), ['나 노트', '다 노트', '가 노트']);
    await sortBy('default');
    expect(order(), ['나 노트', '가 노트', '다 노트']);

    // 라벨 색상 lists the labels and opens the label manager.
    await openMenu();
    await tester.tap(key('library-view-labels'));
    await tester.pumpAndSettle();
    expect(find.text('수업'), findsOneWidget);
    expect(find.text('연구'), findsOneWidget);
    await tester.tap(find.text('연구'));
    await tester.pumpAndSettle();
    expect(labelled, ['']);
  });

  testWidgets('pinned cards come first in their place', (tester) async {
    final first = note('가 노트');
    final second = note('나 노트');
    final third = note('다 노트');
    final alpha = folder('A 폴더');
    final beta = folder('B 폴더');
    await mount(
      tester,
      notes: [first, second, third],
      folders: [alpha, beta],
      marks: marksOf(pinned: {third.id, beta.id}),
    );
    final titles = ['A 폴더', 'B 폴더', '가 노트', '나 노트', '다 노트'];
    final spots = {
      for (final title in titles) title: tester.getTopLeft(find.text(title)),
    };
    final order = [...titles]
      ..sort((a, b) {
        final dy = spots[a]!.dy.compareTo(spots[b]!.dy);
        return dy != 0 ? dy : spots[a]!.dx.compareTo(spots[b]!.dx);
      });
    expect(order, ['B 폴더', '다 노트', 'A 폴더', '가 노트', '나 노트']);
    expect(key('library-pin-${third.id}'), findsOneWidget);
    expect(key('library-pin-${beta.id}'), findsOneWidget);
    expect(key('library-pin-${first.id}'), findsNothing);
  });

  testWidgets('a colour cover shows the title\'s first letter on that colour', (
    tester,
  ) async {
    final page = note('세로 노트');
    await mount(
      tester,
      notes: [page],
      marks: marksOf(covers: {page.id: (color: 0xFF3949AB, changedAt: 1)}),
    );
    final cover = key('library-cover-${page.id}');
    expect(
      find.descendant(of: cover, matching: find.text('세')),
      findsOneWidget,
    );
    final painted = tester.widgetList<DecoratedBox>(
      find.descendant(of: cover, matching: find.byType(DecoratedBox)),
    );
    expect(
      painted.any(
        (box) =>
            box.decoration is BoxDecoration &&
            (box.decoration as BoxDecoration).color == const Color(0xFF3949AB),
      ),
      isTrue,
    );
  });

  testWidgets('the labels dialog checks labels and adds a new one', (
    tester,
  ) async {
    Future<LibraryLabelChoice?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showLibraryLabelsDialog(
              context,
              labels: const [
                LibraryLabel(id: 'l1', name: '수업', color: 0xFFE53935),
                LibraryLabel(id: 'l2', name: '연구', color: 0xFF3949AB),
              ],
              selected: const {'l1'},
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(key('library-labels-dialog'), findsOneWidget);
    bool? checked(String id) =>
        tester.widget<Checkbox>(key('library-label-check-$id')).value;
    expect(checked('l1'), isTrue);
    expect(checked('l2'), isFalse);
    await tester.tap(key('library-label-check-l2'));
    await tester.pump();
    expect(checked('l2'), isTrue);
    await tester.tap(key('library-label-new'));
    await tester.pump();
    await tester.enterText(key('library-label-name'), '시험');
    await tester.tap(key('library-label-color-2'));
    await tester.pump();
    await tester.tap(key('library-label-add'));
    await tester.pump();
    expect(find.text('시험'), findsOneWidget);
    await tester.tap(key('library-labels-save'));
    await tester.pumpAndSettle();
    final choice = (await result)!;
    expect(choice.labels.map((label) => label.name), ['수업', '연구', '시험']);
    final added = choice.labels.last;
    expect(added.color, libraryPalette[2]);
    expect(added.changedAt, greaterThan(0));
    expect(choice.selected, {'l1', 'l2', added.id});

    // 취소 changes nothing.
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(await result, isNull);

    // Without a document the dialog only manages the labels: a colour change
    // marks the label as changed so it wins a merge.
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showLibraryLabelsDialog(
              context,
              labels: const [
                LibraryLabel(id: 'l1', name: '수업', color: 0xFFE53935),
              ],
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(key('library-label-check-l1'), findsNothing);
    await tester.tap(key('library-label-dot-l1'));
    await tester.pump();
    await tester.tap(key('library-label-color-5'));
    await tester.pump();
    await tester.tap(key('library-labels-save'));
    await tester.pumpAndSettle();
    final managed = (await result)!;
    expect(managed.labels.single.color, libraryPalette[5]);
    expect(managed.labels.single.changedAt, greaterThan(0));
  });

  testWidgets('a label in the dialog is renamed, and deleted after asking', (
    tester,
  ) async {
    Future<LibraryLabelChoice?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showLibraryLabelsDialog(
              context,
              labels: const [
                LibraryLabel(
                  id: 'l1',
                  name: '수업',
                  color: 0xFFE53935,
                  changedAt: 1,
                ),
                LibraryLabel(
                  id: 'l2',
                  name: '연구',
                  color: 0xFF3949AB,
                  changedAt: 1,
                ),
              ],
              selected: const {'l1', 'l2'},
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();

    await tester.tap(key('library-label-menu-l1'));
    await tester.pumpAndSettle();
    expect(find.text('이름 바꾸기'), findsOneWidget);
    expect(find.text('삭제'), findsOneWidget);
    await tester.tap(key('library-label-rename-l1'));
    await tester.pumpAndSettle();
    final field = key('library-label-rename-field');
    expect(tester.widget<TextField>(field).controller!.text, '수업');
    await tester.enterText(field, '강의');
    await tester.tap(key('library-label-rename-ok'));
    await tester.pumpAndSettle();
    expect(find.text('강의'), findsOneWidget);
    expect(find.text('수업'), findsNothing);

    // 삭제 asks first; 취소 keeps the label.
    Future<void> askToDelete() async {
      await tester.tap(key('library-label-menu-l2'));
      await tester.pumpAndSettle();
      await tester.tap(key('library-label-delete-l2'));
      await tester.pumpAndSettle();
      expect(find.text('‘연구’ 라벨을 삭제할까요?'), findsOneWidget);
    }

    await askToDelete();
    await tester.tap(key('library-label-delete-cancel'));
    await tester.pumpAndSettle();
    expect(find.text('연구'), findsOneWidget);
    await askToDelete();
    await tester.tap(key('library-label-delete-ok'));
    await tester.pumpAndSettle();
    expect(find.text('연구'), findsNothing);
    expect(key('library-label-check-l2'), findsNothing);

    await tester.tap(key('library-labels-save'));
    await tester.pumpAndSettle();
    final choice = (await result)!;
    expect([for (final label in choice.labels) (label.id, label.name)], [
      ('l1', '강의'),
    ]);
    expect(choice.labels.single.color, 0xFFE53935);
    expect(choice.labels.single.changedAt, greaterThan(1));
    expect(choice.selected, {'l1'});
  });

  testWidgets('the cover dialog offers the first page and eight colours', (
    tester,
  ) async {
    Future<({int? color})?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => result = showLibraryCoverDialog(
              context,
              current: libraryPalette[1],
            ),
            child: const Text('열기'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(key('library-cover-dialog'), findsOneWidget);
    expect(key('library-cover-first'), findsOneWidget);
    for (var i = 0; i < 8; i++) {
      expect(key('library-cover-color-$i'), findsOneWidget);
    }
    expect(libraryPalette, hasLength(8));
    await tester.tap(key('library-cover-color-3'));
    await tester.pumpAndSettle();
    expect((await result)!.color, libraryPalette[3]);
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.tap(key('library-cover-first'));
    await tester.pumpAndSettle();
    final first = (await result)!;
    expect(first.color, isNull);
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  });

  testWidgets(
    "light mode has Notein's white page, grey tab track and white menus; dark mode keeps the theme",
    (tester) async {
      final page = note('세로 노트');
      Future<void> show(ThemeData? theme) => mount(
        tester,
        notes: [page],
        onNoteAction: (_, _) {},
        onEditLabels: (_) {},
        theme: theme,
      );
      Color? pageColour() => tester.widget<Material>(key('library-page')).color;
      BoxDecoration track() =>
          tester
                  .widget<DecoratedBox>(
                    find
                        .ancestor(
                          of: key('library-filter-tabs'),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      Material menuOf(Finder row) => tester.widget<Material>(
        find.ancestor(of: row, matching: find.byType(Material)).first,
      );
      void white(Material menu, String which) {
        expect(menu.color, Colors.white, reason: which);
        expect(menu.surfaceTintColor, Colors.transparent, reason: which);
        expect(
          (menu.shape! as RoundedRectangleBorder).borderRadius,
          BorderRadius.circular(16),
          reason: which,
        );
      }

      await show(null);
      expect(pageColour(), Colors.white);
      expect(track().color, const Color(0xFFEFEFF1));
      // Neutral grey lines, not the theme's tinted ones.
      const line = Color(0xFFE5E5EA);
      expect(tester.widget<Divider>(key('library-top-divider')).color, line);
      final pill =
          tester.widget<TabBar>(key('library-filter-tabs')).indicator!
              as BoxDecoration;
      expect(pill.color, Colors.white);
      expect(pill.boxShadow, isNotEmpty);

      await tester.tap(key('library-create-button'));
      await tester.pumpAndSettle();
      white(menuOf(key('library-add-pdf')), '+ menu');
      expect(
        tester
            .widgetList<PopupMenuDivider>(find.byType(PopupMenuDivider))
            .map((divider) => divider.color),
        everyElement(line),
      );
      await tester.tap(key('library-add-note'));
      await tester.pumpAndSettle();
      // 「페이지 추가」: a light grey sheet with the kinds in a white group.
      expect(
        tester.widget<Dialog>(key('library-new-note-dialog')).backgroundColor,
        const Color(0xFFF2F2F7),
      );
      final group = tester.widget<Material>(key('library-new-kinds'));
      expect(group.color, Colors.white);
      expect(group.borderRadius, BorderRadius.circular(16));
      await tester.tap(key('library-new-note-cancel'));
      await tester.pumpAndSettle();

      await tester.tap(key('library-note-menu-${page.revision.revisionId}'));
      await tester.pumpAndSettle();
      white(menuOf(find.text('이름 바꾸기')), 'card menu');
      expect(
        tester
            .widgetList<PopupMenuDivider>(find.byType(PopupMenuDivider))
            .map((divider) => divider.color),
        everyElement(line),
      );
      await tester.tapAt(const Offset(20, 450));
      await tester.pumpAndSettle();
      await tester.tap(key('library-view-menu'));
      await tester.pumpAndSettle();
      white(menuOf(key('library-view-sort')), 'view menu');
      await tester.tapAt(const Offset(20, 450));
      await tester.pumpAndSettle();

      final dark = ThemeData.dark();
      await show(dark);
      // MaterialApp animates a theme change.
      await tester.pumpAndSettle();
      expect(pageColour(), dark.colorScheme.surface);
      expect(track().color, isNot(const Color(0xFFEFEFF1)));
      await tester.tap(key('library-create-button'));
      await tester.pumpAndSettle();
      expect(menuOf(key('library-add-pdf')).color, isNot(Colors.white));
      await tester.tapAt(const Offset(20, 450));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    '검색 중… stays under the folders and import cards while a search runs',
    (tester) async {
      final course = folder('수업 자료');
      await mount(
        tester,
        folders: [course],
        importJobs: const [
          LibraryImportJobView(id: 'job', title: '수업.pdf', progress: .5),
        ],
        searchQuery: '수업',
        searchPending: true,
        onSearchChanged: (_) {},
      );
      final pending = find.text('검색 중…');
      expect(pending, findsOneWidget);
      expect(key('library-folder-${course.id}'), findsOneWidget);
      expect(
        tester.getTopLeft(pending).dy,
        greaterThan(
          tester.getRect(key('library-folder-${course.id}')).bottom - 1,
        ),
      );
      expect(
        tester.getTopLeft(pending).dy,
        greaterThan(tester.getRect(key('library-import-job')).bottom - 1),
      );
    },
  );

  testWidgets('an import running from 최근, 즐겨찾기 or a label shows its card '
      'there too', (tester) async {
    const job = LibraryImportJobView(id: 'job', title: '수업.pdf', progress: .5);
    for (final collection in const [
      LibraryCollection.recent([]),
      LibraryCollection.favorites(),
      LibraryCollection.label('l1', '수업'),
    ]) {
      await mount(
        tester,
        notes: [note('필기 수업')],
        importJobs: const [job],
        collection: collection,
      );
      expect(
        key('library-import-job'),
        findsOneWidget,
        reason: collection.kind.name,
      );
    }
    // The trash still shows none.
    await mount(tester, importJobs: const [job], showTrash: true);
    expect(key('library-import-job'), findsNothing);
  });

  testWidgets(
    'an empty collection says what is missing, not the first-run hint',
    (tester) async {
      final memo = note('필기 수업');
      for (final (collection, words) in [
        (const LibraryCollection.favorites(), '즐겨찾기한 문서가 없습니다'),
        (const LibraryCollection.recent([]), '최근에 연 문서가 없습니다'),
        (const LibraryCollection.label('l1', '수업'), '이 라벨이 붙은 문서가 없습니다'),
      ]) {
        await mount(tester, notes: [memo], collection: collection);
        expect(find.text(words), findsOneWidget, reason: words);
        expect(key('library-empty'), findsNothing, reason: words);
        expect(find.text('아직 노트가 없습니다'), findsNothing, reason: words);
      }
      // An empty folder keeps Notein's first-run message.
      await mount(tester, notes: [memo], currentFolderId: 'elsewhere');
      expect(key('library-empty'), findsOneWidget);
    },
  );

  testWidgets('small controls have 48 dp touch areas and button roles', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final page = note('세로 노트');
    final toggled = <String>[], cancelled = <String>[];
    final created = <LibraryCreateAction>[];
    await mount(
      tester,
      notes: [page],
      importJobs: const [
        LibraryImportJobView(id: 'job', title: '가져오는 문서.pdf', progress: .5),
      ],
      onToggleFavorite: toggled.add,
      onCancelImport: cancelled.add,
      onCreate: created.add,
      onNoteAction: (_, _) {},
    );
    for (final label in ['즐겨찾기', '가져오기 취소', '새 노트', '추가']) {
      final node = tester.getSemantics(find.bySemanticsLabel(label).first);
      expect(
        node.rect.width >= 48 && node.rect.height >= 48,
        isTrue,
        reason: '$label ${node.rect}',
      );
      expect(node.flagsCollection.isButton, isTrue, reason: label);
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason: label,
      );
    }
    // The ⌄ menu is the whole title line: one button as wide as the card and
    // at least 32 tall. The card itself still says the title.
    final menu = find.bySemanticsLabel('문서 메뉴');
    expect(menu, findsOneWidget);
    final line = tester.getSemantics(menu);
    expect(
      line.rect.width,
      closeTo(
        tester.getSize(key('library-note-${page.revision.revisionId}')).width,
        .5,
      ),
    );
    expect(line.rect.height, greaterThanOrEqualTo(32));
    expect(line.flagsCollection.isButton, isTrue);
    expect(line.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(find.bySemanticsLabel(RegExp('^세로 노트')), findsOneWidget);
    // A touch near the edge of the area, away from the small mark, counts.
    Offset near(String name, Alignment corner) =>
        corner.withinRect(tester.getRect(key(name)).deflate(3));
    await tester.tapAt(
      near('library-favorite-${page.id}', Alignment.bottomLeft),
    );
    expect(toggled, [page.id]);
    await tester.tapAt(near('library-import-cancel-job', Alignment.bottomLeft));
    expect(cancelled, ['job']);
    await tester.tapAt(near('library-new-note', Alignment.topLeft));
    expect(created, [LibraryCreateAction.handwriting]);
    await tester.tapAt(
      near('library-note-menu-${page.revision.revisionId}', Alignment.topLeft),
    );
    await tester.pumpAndSettle();
    expect(find.text('이름 바꾸기'), findsOneWidget);
    await tester.tapAt(const Offset(20, 450));
    await tester.pumpAndSettle();
    semantics.dispose();
  });

  // The user's correction (2026-11-17): the ⌄ goes right after the card's
  // title, as StarNote draws 「내 연구 ⌄」 under a folder's cover.
  testWidgets(
    'the card chevron sits right after the title, centred under the cover',
    (tester) async {
      final research = folder('내 연구');
      final page = note('세로 노트');
      await mount(
        tester,
        folders: [research],
        notes: [page],
        onNoteAction: (_, _) {},
        onTogglePin: (_) {},
      );
      for (final (card, menu, title, cover) in [
        (
          'library-note-${page.revision.revisionId}',
          'library-note-menu-${page.revision.revisionId}',
          '세로 노트',
          'library-cover-${page.id}',
        ),
        (
          'library-folder-${research.id}',
          'library-folder-menu-${research.id}',
          '내 연구',
          'library-cover-${research.id}',
        ),
      ]) {
        final text = tester.getRect(
          find.descendant(of: key(menu), matching: find.text(title)),
        );
        final chevron = tester.getRect(
          find.descendant(
            of: key(menu),
            matching: find.byIcon(Icons.expand_more),
          ),
        );
        final box = tester.getRect(key(cover));
        expect(chevron.left - text.right, inInclusiveRange(0, 6), reason: menu);
        // A one-line title: the ⌄ is centred on that line.
        expect(chevron.center.dy, closeTo(text.center.dy, 3), reason: menu);
        expect(
          (text.left + chevron.right) / 2,
          closeTo(box.center.dx, 2),
          reason: menu,
        );
        expect(text.top, greaterThan(box.bottom), reason: menu);
        // The card has no other ⌄: none is left at the cover's corner.
        expect(
          find.descendant(
            of: key(card),
            matching: find.byIcon(Icons.expand_more),
          ),
          findsOneWidget,
          reason: menu,
        );
      }
    },
  );

  testWidgets(
    'tapping the title line opens the card menu and the cover opens the note',
    (tester) async {
      final page = note('세로 노트');
      final opened = <VaultNote>[];
      await mount(
        tester,
        notes: [page],
        facts: {
          page.id: DocumentFacts(changed: DateTime(2026, 11, 17), pages: 3),
        },
        onNoteAction: (_, _) {},
        onOpenNote: opened.add,
      );
      final menu = key('library-note-menu-${page.revision.revisionId}');
      final line = tester.getRect(menu);
      // The whole line is the target: as wide as the card, at least 32 tall.
      expect(
        line.width,
        closeTo(
          tester.getSize(key('library-note-${page.revision.revisionId}')).width,
          .5,
        ),
      );
      expect(line.height, greaterThanOrEqualTo(32));
      // Even its left end, away from the title, opens the menu under it.
      await tester.tapAt(line.centerLeft + const Offset(3, 0));
      await tester.pumpAndSettle();
      expect(find.text('이름 바꾸기'), findsOneWidget);
      expect(
        tester.getRect(find.text('이름 바꾸기')).top,
        greaterThan(line.bottom - 1),
      );
      expect(opened, isEmpty);
      await tester.tapAt(const Offset(20, 450));
      await tester.pumpAndSettle();
      expect(find.text('이름 바꾸기'), findsNothing);

      // The cover and the date line open the note.
      await tester.tap(key('library-cover-${page.id}'));
      expect(opened, [page]);
      await tester.tap(find.text('26/11/17 · 3 페이지'));
      expect(opened, [page, page]);
      expect(find.text('이름 바꾸기'), findsNothing);
    },
  );

  testWidgets('a long title keeps the chevron visible', (tester) async {
    final long = note('아주 긴 제목의 필기와 문서 그리고 강의 정리 자료와 연구 노트 모음');
    await mount(
      tester,
      notes: [long],
      onNoteAction: (_, _) {},
      size: const Size(360, 800),
    );
    expect(tester.takeException(), isNull);
    final menu = key('library-note-menu-${long.revision.revisionId}');
    final title = find.descendant(of: menu, matching: find.text(long.title));
    final paragraph = tester.renderObject<RenderParagraph>(title);
    expect(paragraph.maxLines, 2);
    expect(paragraph.overflow, TextOverflow.ellipsis);
    expect(paragraph.didExceedMaxLines, isTrue);
    final text = tester.getRect(title);
    final chevron = tester.getRect(
      find.descendant(of: menu, matching: find.byIcon(Icons.expand_more)),
    );
    final cell = tester.getRect(
      key('library-note-${long.revision.revisionId}'),
    );
    expect(chevron.left, greaterThanOrEqualTo(cell.left));
    expect(chevron.right, lessThanOrEqualTo(cell.right));
    expect(chevron.left - text.right, inInclusiveRange(0, 6));
    // Two lines; the ⌄ is centred on the second.
    expect(text.height, greaterThan(chevron.height));
    expect(chevron.center.dy, closeTo(text.bottom - text.height / 4, 3));
  });

  testWidgets('selecting shows the corner checkbox and no chevron', (
    tester,
  ) async {
    final page = note('세로 노트');
    final research = folder('내 연구');
    Future<void> show({required bool selecting}) => mount(
      tester,
      notes: [page],
      folders: [research],
      onNoteAction: (_, _) {},
      onTogglePin: (_) {},
      onSelectionChanged: (_) {},
      selecting: selecting,
    );
    final card = key('library-note-${page.revision.revisionId}');
    // Where the title and the date line sit in the card.
    (double, double) lines() {
      final top = tester.getRect(card).top;
      final title = find.descendant(of: card, matching: find.text('세로 노트'));
      final date = find.descendant(of: card, matching: find.text('페이지 노트'));
      return (tester.getRect(title).top - top, tester.getRect(date).top - top);
    }

    await show(selecting: false);
    final before = lines();

    await show(selecting: true);
    expect(key('library-note-menu-${page.revision.revisionId}'), findsNothing);
    expect(key('library-folder-menu-${research.id}'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsNothing);
    // A plain title, and nothing in the card moves.
    expect(lines().$1, closeTo(before.$1, .5));
    expect(lines().$2, closeTo(before.$2, .5));
    // The check box keeps the cover box's bottom-right corner.
    final checkbox = key('library-select-note-${page.id}');
    expect(checkbox, findsOneWidget);
    final cover = tester.getRect(key('library-cover-${page.id}'));
    expect(
      (tester.getRect(checkbox).bottomRight - cover.bottomRight).distance,
      lessThan(8),
    );
  });

  testWidgets('a card without a menu shows its title without a chevron', (
    tester,
  ) async {
    // A trashed note with nothing to do on it.
    final gone = note('지운 노트', trashed: true);
    await mount(tester, notes: [gone], showTrash: true);
    expect(key('library-note-menu-${gone.revision.revisionId}'), findsNothing);
    expect(find.text('지운 노트'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
    // A folder whose menu would have no rows.
    final research = folder('내 연구');
    await mount(tester, folders: [research]);
    expect(key('library-folder-menu-${research.id}'), findsNothing);
    expect(find.text('내 연구'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  // The user's correction (2026-11-17): a document's cover is its first page
  // as it looks, with the small format mark at the top left; the light
  // format cover is a choice in 표지 변경.
  testWidgets('a chosen format cover wins over the first page', (tester) async {
    final deck = note('발표', kind: VaultDocumentKind.office);
    final memo = note('필기', kind: VaultDocumentKind.handwriting);
    final page = MemoryImage(
      image.encodePng(image.Image(width: 16, height: 9)),
    );
    await mount(
      tester,
      notes: [deck, memo],
      facts: {deck.id: const DocumentFacts(format: 'pptx')},
      thumbnails: {deck.id: page, memo.id: page},
      marks: marksOf(
        covers: {
          deck.id: (color: LibraryMarks.formatCover, changedAt: 1),
          memo.id: (color: LibraryMarks.formatCover, changedAt: 1),
        },
      ),
    );
    final cover = key('library-cover-${deck.id}');
    expect(
      find.descendant(of: cover, matching: find.byType(Image)),
      findsNothing,
    );
    // The format's name, large on its light colour, under the mark's tag.
    expect(
      find.descendant(of: cover, matching: find.text('PPT')),
      findsNWidgets(2),
    );
    expect(
      tester
          .widgetList<ColoredBox>(
            find.descendant(of: cover, matching: find.byType(ColoredBox)),
          )
          .map((box) => box.color),
      contains(libraryPptColor.withValues(alpha: .12)),
    );
    expect(key('library-format-${deck.id}'), findsOneWidget);
    // A document without a format keeps its first page.
    expect(
      find.descendant(
        of: key('library-cover-${memo.id}'),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'the format mark sits on the first-page cover of an office card',
    (tester) async {
      final deck = note('발표', kind: VaultDocumentKind.office);
      final letter = note('공문', kind: VaultDocumentKind.office);
      final slide = MemoryImage(
        image.encodePng(image.Image(width: 16, height: 9)),
      );
      final page = MemoryImage(
        image.encodePng(image.Image(width: 7, height: 10)),
      );
      await mount(
        tester,
        notes: [deck, letter],
        facts: {
          deck.id: const DocumentFacts(format: 'pptx', aspect: 16 / 9),
          letter.id: const DocumentFacts(format: 'hwp', aspect: .707),
        },
        thumbnails: {deck.id: slide, letter.id: page},
      );
      for (final (document, label) in [(deck, 'PPT'), (letter, '한글')]) {
        final cover = key('library-cover-${document.id}');
        final mark = key('library-format-${document.id}');
        // The first page, and only the mark's small tag names the format.
        expect(
          find.descendant(of: cover, matching: find.byType(Image)),
          findsOneWidget,
          reason: label,
        );
        expect(
          find.descendant(of: cover, matching: find.text(label)),
          findsOneWidget,
          reason: label,
        );
        expect(find.descendant(of: cover, matching: mark), findsOneWidget);
        expect(
          (tester.getRect(mark).topLeft - tester.getRect(cover).topLeft)
              .distance,
          lessThan(.5),
          reason: label,
        );
        // Drawn over the page: the picture first in the cover's stack.
        final stack = tester.widget<Stack>(
          find.descendant(of: cover, matching: find.byType(Stack)).first,
        );
        expect(stack.children.first, isA<Image>(), reason: label);
        expect(
          stack.children
              .skip(1)
              .whereType<Positioned>()
              .map((child) => child.child),
          contains(isA<LibraryFormatMark>()),
          reason: label,
        );
      }
    },
  );

  testWidgets('the cover dialog offers 형식 표지 only for office documents', (
    tester,
  ) async {
    Future<({int? color})?>? result;
    Future<void> open({String? format, int? current}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => result = showLibraryCoverDialog(
                context,
                current: current,
                format: format,
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
    }

    // A PowerPoint original: 첫 쪽, then 형식 표지, then the eight colours.
    await open(format: 'pptx');
    final first = tester.getRect(key('library-cover-first'));
    final row = key('library-cover-format');
    expect(tester.getRect(row).top, greaterThanOrEqualTo(first.bottom - 1));
    expect(
      tester.getRect(key('library-cover-color-0')).top,
      greaterThan(tester.getRect(row).bottom - 1),
    );
    expect(
      find.descendant(of: row, matching: find.text('형식 표지')),
      findsOneWidget,
    );
    // Its picture is the format cover itself.
    expect(
      find.descendant(of: row, matching: find.text('PPT')),
      findsOneWidget,
    );
    expect(
      tester.widget<ListTile>(key('library-cover-first')).selected,
      isTrue,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect((await result)!.color, LibraryMarks.formatCover);

    // Once chosen it is the current cover.
    await open(format: 'hwp', current: LibraryMarks.formatCover);
    expect(tester.widget<ListTile>(row).selected, isTrue);
    expect(
      tester.widget<ListTile>(key('library-cover-first')).selected,
      isFalse,
    );
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(await result, isNull);

    // Folders and other documents: the first page and the colours only.
    for (final format in [null, 'pdf']) {
      await open(format: format);
      expect(row, findsNothing, reason: '$format');
      expect(key('library-cover-first'), findsOneWidget);
      expect(key('library-cover-color-7'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
    }
  });
}
