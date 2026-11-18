import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/library_home.dart';

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
    bool conflict = false,
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
      deletionConflict: conflict,
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

  // The layout and the sort are kept in stows; each test starts from the
  // defaults.
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
    ValueChanged<VaultNote>? onOpenNote,
    ValueChanged<String?>? onOpenFolder,
    ValueChanged<LibraryCreateAction>? onCreate,
    void Function(VaultNote, LibraryNoteAction)? onNoteAction,
    bool showTrash = false,
    double width = 1100,
    String? searchQuery,
    ValueChanged<String>? onSearchChanged,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibraryHome(
            notes: notes,
            folders: folders,
            currentFolderId: currentFolderId,
            onOpenNote: onOpenNote ?? (_) {},
            onOpenFolder: onOpenFolder ?? (_) {},
            onCreate: onCreate ?? (_) {},
            onNoteAction: onNoteAction,
            showTrash: showTrash,
            searchQuery: searchQuery,
            onSearchChanged: onSearchChanged,
          ),
        ),
      ),
    );
  }

  testWidgets(
    'the + menu and the new note dialog dispatch every document kind',
    (tester) async {
      final selections = <LibraryCreateAction>[];
      await mount(tester, onCreate: selections.add);
      await tester.tap(find.byKey(const ValueKey('library-create-button')));
      await tester.pumpAndSettle();
      expect(find.text('PDF 가져오기'), findsOneWidget);
      expect(find.text('한글 가져오기'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('library-add-note')));
      await tester.pumpAndSettle();
      expect(find.text('무한 노트'), findsOneWidget);
      await tester.tap(find.text('Markdown'));
      await tester.pumpAndSettle();
      expect(selections, [LibraryCreateAction.markdown]);
      await tester.tap(find.byKey(const ValueKey('library-create-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('새 폴더'));
      await tester.pumpAndSettle();
      expect(selections, [
        LibraryCreateAction.markdown,
        LibraryCreateAction.folder,
      ]);
    },
  );

  testWidgets('the new note dialog offers quick notes in one tap', (
    tester,
  ) async {
    final selections = <LibraryCreateAction>[];
    await mount(tester, onCreate: selections.add);
    await tester.tap(find.byKey(const ValueKey('library-create-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('library-add-note')));
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
    final quickNote = find.byKey(const ValueKey('library-new-quickNote'));
    expect(
      find.descendant(of: quickNote, matching: find.text('빠른 메모')),
      findsOneWidget,
    );
    await tester.tap(quickNote);
    await tester.pumpAndSettle();
    expect(selections.map((action) => action.name), ['quickNote']);
  });

  testWidgets('double-tapping the pencil makes only one page note', (
    tester,
  ) async {
    final selections = <LibraryCreateAction>[];
    await mount(tester, onCreate: selections.add);
    final pencil = find.byKey(const ValueKey('library-new-note'));
    await tester.tap(pencil);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(pencil);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(selections.map((action) => action.name), ['handwriting']);
    expect(find.byKey(const ValueKey('library-new-note-dialog')), findsNothing);
    // A tap a moment later makes the next one.
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(pencil);
    expect(selections.map((action) => action.name), [
      'handwriting',
      'handwriting',
    ]);
  });

  testWidgets('the + button opens its menu from the keyboard', (tester) async {
    final selections = <LibraryCreateAction>[];
    await mount(tester, onCreate: selections.add);
    final plus = tester.element(
      find.byKey(const ValueKey('library-create-button')),
    );
    bool plusHasFocus() {
      var hasFocus = false;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
        element,
      ) {
        hasFocus = identical(element, plus);
        return !hasFocus;
      });
      return hasFocus;
    }

    for (var i = 0; i < 25 && !plusHasFocus(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(plusHasFocus(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-add-note')), findsOneWidget);
    expect(selections, isEmpty);
  });

  testWidgets("folder cards open a folder and the title's ‹ goes up one", (
    tester,
  ) async {
    final parent = folder('대학');
    final child = folder('연구', parentId: parent.id);
    final locations = <String?>[];
    await mount(
      tester,
      folders: [parent, child],
      currentFolderId: parent.id,
      onOpenFolder: locations.add,
    );
    await tester.tap(find.byKey(ValueKey('library-folder-${child.id}')));
    expect(locations, [child.id]);
    await tester.tap(find.byKey(const ValueKey('library-up')));
    expect(locations, [child.id, null]);
    await mount(
      tester,
      folders: [parent, child],
      currentFolderId: child.id,
      onOpenFolder: locations.add,
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('library-title'))).data,
      '연구',
    );
    await tester.tap(find.byKey(const ValueKey('library-up')));
    expect(locations, [child.id, null, parent.id]);
  });

  testWidgets(
    'home shows only current-folder documents and opens a whole card',
    (tester) async {
      final current = folder('강의');
      final inside = note('베이즈 네트워크', folderId: current.id);
      final outside = note('다른 노트');
      final opened = <VaultNote>[];
      await mount(
        tester,
        folders: [current],
        notes: [inside, outside],
        currentFolderId: current.id,
        onOpenNote: opened.add,
      );
      expect(find.text('다른 노트'), findsNothing);
      expect(find.text(inside.id), findsNothing);
      await tester.tap(
        find.byKey(ValueKey('library-note-${inside.revision.revisionId}')),
      );
      expect(opened, [inside]);
    },
  );

  testWidgets(
    'type filters and search narrow documents without deleting folder state',
    (tester) async {
      final ink = note('필기 수업');
      final pdf = note('강의 자료', kind: VaultDocumentKind.pdf);
      final md = note('정리 문서', kind: VaultDocumentKind.markdown);
      await mount(tester, notes: [ink, pdf, md]);
      await tester.tap(find.byKey(const ValueKey('library-filter-pdf')));
      await tester.pumpAndSettle();
      expect(find.text('강의 자료'), findsOneWidget);
      expect(find.text('필기 수업'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('library-filter-all')));
      // The search box is in the side bar; the library takes its query.
      await mount(tester, notes: [ink, pdf, md], searchQuery: '정리');
      await tester.pumpAndSettle();
      expect(find.text('정리 문서'), findsOneWidget);
      expect(find.text('강의 자료'), findsNothing);
    },
  );

  testWidgets(
    'trash state shows restoration and preserves conflict indicators',
    (tester) async {
      final deleted = note('휴지통 문서', trashed: true, conflict: true);
      final actions = <LibraryNoteAction>[];
      await mount(
        tester,
        notes: [deleted],
        showTrash: true,
        onNoteAction: (_, action) => actions.add(action),
      );
      expect(find.text('변경 충돌'), findsOneWidget);
      await tester.tap(
        find.byKey(
          ValueKey('library-note-menu-${deleted.revision.revisionId}'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('복원'));
      await tester.pumpAndSettle();
      expect(actions, [LibraryNoteAction.restore]);
    },
  );

  for (final width in [320.0, 600.0, 1400.0]) {
    testWidgets(
      'library fits ${width.toInt()}px with long titles and list layout',
      (tester) async {
        await mount(
          tester,
          notes: [note('긴 제목의 필기와 문서 그리고 강의 정리 자료')],
          folders: [folder('긴 이름의 연구 폴더')],
          width: width,
        );
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('library-create-button')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('library-view-menu')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('library-view-list')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('library-list')), findsOneWidget);
      },
    );
  }

  testWidgets('swiping the document area moves to the next kind tab', (
    tester,
  ) async {
    final ink = note('필기 수업');
    final pdf = note('강의 자료', kind: VaultDocumentKind.pdf);
    await mount(tester, notes: [ink, pdf]);
    expect(find.text('필기 수업'), findsOneWidget);
    await tester.fling(find.byType(TabBarView), const Offset(-600, 0), 2000);
    await tester.pumpAndSettle();
    expect(find.text('강의 자료'), findsOneWidget);
    expect(find.text('필기 수업'), findsNothing);
    final tabs = tester.widget<TabBar>(
      find.byKey(const ValueKey('library-filter-tabs')),
    );
    expect(tabs.controller!.index, 1);
  });

  testWidgets(
    'the header starts with ‹ and the current folder, with no search box over it',
    (tester) async {
      final lectures = folder('강의');
      await mount(
        tester,
        folders: [lectures],
        notes: [note('필기 수업', folderId: lectures.id)],
        currentFolderId: lectures.id,
      );
      final title = find.byKey(const ValueKey('library-title'));
      expect(tester.widget<Text>(title).data, '강의');
      expect(find.byKey(const ValueKey('library-search')), findsNothing);
      // As in Notein, ‹ and the folder name start the header on the left and
      // the view menu ends it on the right.
      final up = tester.getRect(find.byKey(const ValueKey('library-up')));
      final text = tester.getRect(title);
      expect(up.left, lessThan(60));
      expect(text.left, greaterThan(up.right - 1));
      final view = tester.getRect(
        find.byKey(const ValueKey('library-view-menu')),
      );
      expect(view.right, greaterThan(1100 - 40));
      expect((view.center.dy - text.center.dy).abs(), lessThan(4));
      // The + is no longer in the header: it waits at the bottom right.
      expect(
        tester
            .getCenter(find.byKey(const ValueKey('library-create-button')))
            .dy,
        greaterThan(800),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('library-filter-tabs'))).dy,
        greaterThan(text.bottom),
      );
    },
  );

  testWidgets('the root has no title and the trash is titled, without a ‹', (
    tester,
  ) async {
    await mount(tester, notes: [note('필기 수업')]);
    expect(find.byKey(const ValueKey('library-title')), findsNothing);
    expect(find.byKey(const ValueKey('library-up')), findsNothing);
    await mount(tester, showTrash: true);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('library-title'))).data,
      '휴지통',
    );
    expect(find.byKey(const ValueKey('library-up')), findsNothing);
  });

  testWidgets('a search in the trash shows in its title too', (tester) async {
    final searches = <String>[];
    await mount(
      tester,
      showTrash: true,
      searchQuery: '초안',
      onSearchChanged: searches.add,
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('library-title'))).data,
      "휴지통 '초안' 검색 결과",
    );
    await tester.tap(find.byKey(const ValueKey('library-search-clear')));
    expect(searches, ['']);
  });

  testWidgets('while searching the title says so and its × clears it', (
    tester,
  ) async {
    final searches = <String>[];
    await mount(
      tester,
      notes: [note('정리 문서')],
      searchQuery: '정리',
      onSearchChanged: searches.add,
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('library-title'))).data,
      "'정리' 검색 결과",
    );
    await tester.tap(find.byKey(const ValueKey('library-search-clear')));
    expect(searches, ['']);
  });

  testWidgets(
    "an Office card's menu previews it or makes a PDF; other cards' do not",
    (tester) async {
      final office = note('강의 원본', kind: VaultDocumentKind.office);
      final ink = note('필기 수업');
      final actions = <(VaultNote, LibraryNoteAction)>[];
      await mount(
        tester,
        notes: [office, ink],
        onNoteAction: (note, action) => actions.add((note, action)),
      );
      await tester.tap(
        find.byKey(ValueKey('library-note-menu-${office.revision.revisionId}')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-note-preview')), findsOneWidget);
      await tester.tap(find.text('PDF로 바꾸기'));
      await tester.pumpAndSettle();
      expect(actions, [(office, LibraryNoteAction.pdf)]);
      await tester.tap(
        find.byKey(ValueKey('library-note-menu-${ink.revision.revisionId}')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-note-preview')), findsNothing);
      expect(find.text('이름 바꾸기'), findsOneWidget);
    },
  );

  testWidgets('cards are six across on an upright tablet, nine lying flat and two on a phone', (
    tester,
  ) async {
    final notes = [for (var i = 0; i < 12; i++) note('노트 $i')];
    Future<int> columns(double width) async {
      await mount(tester, notes: notes, width: width);
      await tester.pump();
      final top = tester
          .getTopLeft(
            find.byKey(
              ValueKey('library-note-${notes.first.revision.revisionId}'),
            ),
          )
          .dy;
      return notes.where((note) {
        final card = find.byKey(
          ValueKey('library-note-${note.revision.revisionId}'),
        );
        return card.evaluate().isNotEmpty &&
            (tester.getTopLeft(card).dy - top).abs() < 8;
      }).length;
    }

    // The Galaxy Tab S9+ at density 340: 824 x 1318 dp. A column is at
    // least 128 wide, and a phone always gets two.
    expect(await columns(824), 6);
    expect(await columns(1318), 9);
    expect(await columns(412), 2);
  });

  testWidgets('folders are stacked covers in the grid with their document counts', (
    tester,
  ) async {
    final outer = folder('랩');
    final inner = folder('통합세미나', parentId: outer.id);
    final loose = note('메모장');
    await mount(
      tester,
      folders: [outer, inner],
      notes: [
        note('회의', folderId: outer.id),
        note('발표', folderId: inner.id),
        note('지운 것', folderId: outer.id, trashed: true),
        loose,
      ],
    );
    expect(find.text('2 메모'), findsOneWidget);
    // A wide 4:3 cover, in a card as big as a document's.
    final cover = tester.getSize(
      find.byKey(ValueKey('library-cover-${outer.id}')),
    );
    expect(cover.aspectRatio, closeTo(4 / 3, .01));
    expect(
      tester.getSize(find.byKey(ValueKey('library-folder-${outer.id}'))),
      tester.getSize(
        find.byKey(ValueKey('library-note-${loose.revision.revisionId}')),
      ),
    );
  });
}
