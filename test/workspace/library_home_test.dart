import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
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
          ),
        ),
      ),
    );
  }

  testWidgets(
    'create tile and button dispatch every document kind through the same menu',
    (tester) async {
      final selections = <LibraryCreateAction>[];
      await mount(tester, onCreate: selections.add);
      await tester.tap(find.byKey(const ValueKey('library-create-tile')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('페이지 노트'), findsOneWidget);
      expect(find.text('무한 노트'), findsOneWidget);
      expect(find.text('Office·한글 가져오기'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(PopupMenuItem<LibraryCreateAction>, 'Markdown'),
      );
      await tester.pumpAndSettle();
      expect(selections, [LibraryCreateAction.markdown]);
      await tester.tap(find.byKey(const ValueKey('library-create-button')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('새 폴더'));
      await tester.tap(find.text('새 폴더'));
      await tester.pumpAndSettle();
      expect(selections, [
        LibraryCreateAction.markdown,
        LibraryCreateAction.folder,
      ]);
    },
  );

  testWidgets('the create menu offers quick notes on a single activation', (
    tester,
  ) async {
    final selections = <LibraryCreateAction>[];
    await mount(tester, onCreate: selections.add);
    await tester.tap(find.byKey(const ValueKey('library-create-tile')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
    final quickNote = find.widgetWithText(
      PopupMenuItem<LibraryCreateAction>,
      '빠른 메모',
    );
    expect(quickNote, findsOneWidget);
    await tester.tap(quickNote);
    await tester.pumpAndSettle();
    expect(selections.map((action) => action.name), ['quickNote']);
  });

  testWidgets('double-tapping the create tile dispatches only one quick note', (
    tester,
  ) async {
    final selections = <LibraryCreateAction>[];
    await mount(tester, onCreate: selections.add);
    final tile = find.byKey(const ValueKey('library-create-tile'));
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(selections.map((action) => action.name), ['quickNote']);
    expect(find.byType(PopupMenuItem<LibraryCreateAction>), findsNothing);
  });

  testWidgets('the create tile opens its menu from the keyboard', (
    tester,
  ) async {
    final selections = <LibraryCreateAction>[];
    await mount(tester, onCreate: selections.add);
    final tile = tester.element(
      find.byKey(const ValueKey('library-create-tile')),
    );
    bool tileHasFocus() {
      var hasFocus = false;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
        element,
      ) {
        hasFocus = identical(element, tile);
        return !hasFocus;
      });
      return hasFocus;
    }

    for (var i = 0; i < 25 && !tileHasFocus(); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    expect(tileHasFocus(), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.widgetWithText(PopupMenuItem<LibraryCreateAction>, '빠른 메모'),
      findsOneWidget,
    );
    expect(selections, isEmpty);
  });

  testWidgets('folder cards and breadcrumbs open the selected location', (
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
    await tester.tap(find.byKey(const ValueKey('library-root')));
    expect(locations, [child.id, null]);
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
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        '정리',
      );
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
          find.byKey(const ValueKey('library-create-tile')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('library-layout-toggle')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('library-list')), findsOneWidget);
      },
    );
  }
}
