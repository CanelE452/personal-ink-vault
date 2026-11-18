import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/library_marks.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/planner/calendar_page.dart';
import 'package:saber/pages/workspace/library_cards.dart';
import 'package:saber/pages/workspace/library_menus.dart';
import 'package:saber/pages/workspace/study_workspace.dart';
import 'package:sbn/canvas_background_pattern.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The workspace around the Notein library (설계 1.9·2·13절): the drawer,
/// the marks and facts on the cards, and the per-format Office imports.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late WorkspaceController controller;
  late bool closed;

  Future<WorkspaceController> openVault() async {
    final value = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    await value.refresh();
    return value;
  }

  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('library-drawer-');
    controller = await openVault();
    closed = false;
    stows.libraryPanelOpen.value = null;
    stows.libraryGrid.value = true;
    stows.librarySort.value = 'default';
  });

  tearDown(() async {
    if (!closed) {
      await controller.flush();
      controller.dispose();
      await controller.repository.close();
    }
    stows.libraryPanelOpen.value = null;
    for (var attempt = 0; ; attempt++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on PathAccessException {
        if (!Platform.isWindows || attempt == 19) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
    }
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() ready,
    String reason,
  ) async {
    for (var i = 0; i < 40 && !ready(); i++) {
      await drain(tester);
    }
    expect(ready(), isTrue, reason: reason);
  }

  Future<T> read<T>(WidgetTester tester, Future<T> Function() operation) async {
    var done = false;
    T? value;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      unawaited(
        operation().then(
          (result) {
            value = result;
            done = true;
          },
          onError: (Object error, StackTrace stack) {
            failure = error;
            trace = stack;
            done = true;
          },
        ),
      );
    });
    await until(tester, () => done, 'The read must finish.');
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return value as T;
  }

  Future<void> closeWhilePumping(WidgetTester tester) async {
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        () async {
          await controller.flush();
          controller.dispose();
          await controller.repository.close();
        }().whenComplete(() => done = true),
      );
    });
    for (var i = 0; i < 80 && !done; i++) {
      await drain(tester);
    }
    closed = done;
  }

  Future<void> mount(
    WidgetTester tester, {
    ThumbnailCache Function(Directory) covers = _NoCovers.new,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: StudyWorkspace(
            controller: controller,
            thumbnailCacheFactory: covers,
          ),
        ),
      ),
    );
    await drain(tester);
  }

  /// Closes the app and opens the same vault again.
  Future<void> restart(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await closeWhilePumping(tester);
    expect(closed, isTrue);
    controller = (await tester.runAsync(openVault))!;
    closed = false;
    await mount(tester);
  }

  /// An Android tablet held sideways: the side panel is open beside the
  /// documents.
  void tabletTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (!closed) await closeWhilePumping(tester);
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Finder key(String value) => find.byKey(ValueKey(value));
  VaultNote listed(String id) =>
      controller.notes.singleWhere((note) => note.id == id);
  Finder card(String id) =>
      key('library-note-${listed(id).revision.revisionId}');
  String? title(WidgetTester tester) => key('library-title')
      .evaluate()
      .map((element) => (element.widget as Text).data)
      .firstOrNull;

  /// Taps a drawer row and waits for the library it leads to.
  Future<void> navigate(
    WidgetTester tester,
    String row,
    bool Function() shown,
  ) async {
    await tester.tap(key(row));
    await until(tester, shown, 'The library shows what $row leads to.');
  }

  Future<void> openMenu(WidgetTester tester, String noteId, String row) async {
    await tester.tap(
      key('library-note-menu-${listed(noteId).revision.revisionId}'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(row));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<VaultNote> markdown(String title, {String? folderId}) =>
      controller.store.create(
        title,
        folderId: folderId,
        documentKind: VaultDocumentKind.markdown,
      );

  tabletTest('the drawer browse tab lists 모두 최근 즐겨찾기 리마인더 달력 휴지통', (
    tester,
  ) async {
    final (folder, note) = (await tester.runAsync(() async {
      final folder = await controller.library.createFolder('수업');
      final note = await markdown('지난 강의', folderId: folder.id);
      // Opened once, so it is one of the recent documents.
      await controller.openNote(note);
      await controller.closeNote(session: controller.activeSession!);
      await controller.openFolder(null);
      await controller.refresh();
      return (folder, note);
    }))!;
    await mount(tester);
    final panel = key('library-panel');
    expect(panel, findsOneWidget);
    for (final tab in ['browse', 'folders', 'labels']) {
      expect(
        find.descendant(of: panel, matching: key('library-drawer-$tab')),
        findsOneWidget,
      );
    }
    // The gear and the search box are the top bar's alone now.
    expect(key('library-settings'), findsOneWidget);
    expect(
      find.descendant(of: panel, matching: key('library-settings')),
      findsNothing,
    );
    expect(key('library-search'), findsNothing);

    double? previous;
    for (final (id, label) in [
      ('all', '모두'),
      ('recent', '최근'),
      ('favorites', '즐겨찾기'),
      ('reminder', '리마인더'),
      ('calendar', '달력'),
      ('trash', '휴지통'),
    ]) {
      final row = find.descendant(of: panel, matching: key('library-nav-$id'));
      expect(row, findsOneWidget, reason: id);
      expect(
        find.descendant(of: row, matching: find.text(label)),
        findsOneWidget,
      );
      final top = tester.getTopLeft(row).dy;
      if (previous != null) expect(top, greaterThan(previous));
      previous = top;
    }
    // The bar's other rows follow, below a divider.
    final bookmarks = find.descendant(
      of: panel,
      matching: key('workspace-bookmarks'),
    );
    expect(bookmarks, findsOneWidget);
    expect(tester.getTopLeft(bookmarks).dy, greaterThan(previous!));
    expect(
      find.descendant(of: panel, matching: key('workspace-quick-switch')),
      findsOneWidget,
    );

    // 최근 lists the opened document from its folder; 모두 returns to the top.
    await navigate(tester, 'library-nav-recent', () => title(tester) == '최근');
    expect(card(note.id), findsOneWidget);
    await navigate(
      tester,
      'library-nav-all',
      () => key('library-folder-${folder.id}').evaluate().isNotEmpty,
    );
    expect(title(tester), isNull);
    expect(card(note.id), findsNothing);

    // 달력 opens its screen over the library, and ← comes back
    // (planner_entry_test.dart has the rest).
    await tester.tap(key('library-nav-calendar'));
    await until(
      tester,
      () => find.byType(CalendarPage).evaluate().isNotEmpty,
      '달력 opens its screen.',
    );
    await tester.tap(
      find.descendant(
        of: find.byType(CalendarPage),
        matching: find.byTooltip('뒤로'),
      ),
    );
    await until(
      tester,
      () => find.byType(CalendarPage, skipOffstage: false).evaluate().isEmpty,
      '← returns to the library.',
    );

    // 폴더: a new folder row over the folder tree; 라벨: a new label row.
    await tester.tap(key('library-drawer-folders'));
    await tester.pump();
    expect(key('library-nav-all'), findsNothing);
    expect(key('library-drawer-new-folder'), findsOneWidget);
    expect(key('sidebar-folder-${folder.id}'), findsOneWidget);
    await tester.tap(key('library-drawer-labels'));
    await tester.pump();
    expect(key('library-drawer-new-label'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  tabletTest(
    'favoriting a card persists in the vault and the favorites view shows it from another folder',
    (tester) async {
      final (folder, note) = (await tester.runAsync(() async {
        final folder = await controller.library.createFolder('수업');
        final note = await markdown('강의 노트', folderId: folder.id);
        await controller.refresh();
        return (folder, note);
      }))!;
      await mount(tester);
      final heart = key('library-favorite-${note.id}');
      await tester.tap(key('library-folder-${folder.id}'));
      await until(
        tester,
        () => heart.evaluate().isNotEmpty,
        'The folder opens with its card.',
      );
      await tester.tap(heart);
      await until(
        tester,
        () => find
            .descendant(of: heart, matching: find.byIcon(Icons.favorite))
            .evaluate()
            .isNotEmpty,
        'The heart fills once the mark is saved.',
      );
      final stored = await read(
        tester,
        () => LibraryMarksStore(controller.repository).read(),
      );
      expect(stored.favorites, {note.id});

      // 즐겨찾기 shows it at the top of the library, without its folder.
      await navigate(
        tester,
        'library-nav-all',
        () => key('library-folder-${folder.id}').evaluate().isNotEmpty,
      );
      expect(card(note.id), findsNothing);
      await navigate(
        tester,
        'library-nav-favorites',
        () => title(tester) == '즐겨찾기',
      );
      expect(card(note.id), findsOneWidget);
      expect(key('library-folder-${folder.id}'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  tabletTest(
    'a label renamed and another deleted in the labels dialog change the vault',
    (tester) async {
      final note = (await tester.runAsync(() async {
        final note = await markdown('수학');
        await LibraryMarksStore(controller.repository).write(
          LibraryMarks.empty
              .putLabel(
                const LibraryLabel(
                  id: 'l1',
                  name: '수업',
                  color: 0xFFE53935,
                  changedAt: 1,
                ),
              )
              .putLabel(
                const LibraryLabel(
                  id: 'l2',
                  name: '연구',
                  color: 0xFF3949AB,
                  changedAt: 1,
                ),
              )
              .setLabels(note.id, {'l1', 'l2'}),
        );
        await controller.refresh();
        return note;
      }))!;
      await mount(tester);
      await until(
        tester,
        () => key('library-label-dots-${note.id}').evaluate().isNotEmpty,
        'The card shows its labels.',
      );
      Future<void> animate() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      final before = DateTime.now().microsecondsSinceEpoch;
      await openMenu(tester, note.id, '라벨 추가');
      expect(key('library-labels-dialog'), findsOneWidget);
      await tester.tap(key('library-label-menu-l1'));
      await animate();
      await tester.tap(key('library-label-rename-l1'));
      await animate();
      await tester.enterText(key('library-label-rename-field'), '시험');
      await tester.tap(key('library-label-rename-ok'));
      await animate();
      await tester.tap(key('library-label-menu-l2'));
      await animate();
      await tester.tap(key('library-label-delete-l2'));
      await animate();
      await tester.tap(key('library-label-delete-ok'));
      await animate();
      await tester.tap(key('library-labels-save'));

      var stored = LibraryMarks.empty;
      for (var i = 0; i < 20; i++) {
        await drain(tester);
        stored = await read(
          tester,
          () => LibraryMarksStore(controller.repository).read(),
        );
        if (stored.labels.length == 1) break;
      }
      expect([for (final label in stored.labels) (label.id, label.name)], [
        ('l1', '시험'),
      ]);
      expect(stored.labels.single.changedAt, greaterThanOrEqualTo(before));
      expect(stored.labelsOf, {
        note.id: {'l1'},
      });
      expect(tester.takeException(), isNull);
    },
  );

  tabletTest('pinning puts the card first and survives a restart', (
    tester,
  ) async {
    final ids = (await tester.runAsync(() async {
      final first = await markdown('가 노트');
      final second = await markdown('나 노트');
      await controller.refresh();
      return [first.id, second.id];
    }))!;
    await mount(tester);
    double left(String id) => tester.getTopLeft(card(id)).dx;
    final later = left(ids.first) < left(ids.last) ? ids.last : ids.first;
    final earlier = ids.firstWhere((id) => id != later);

    await openMenu(tester, later, '고정');
    await until(
      tester,
      () => key('library-pin-$later').evaluate().isNotEmpty,
      'The pin shows once the mark is saved.',
    );
    expect(left(later), lessThan(left(earlier)));

    // 표지 변경 gives the same card a colour cover.
    await openMenu(tester, later, '표지 변경');
    expect(key('library-cover-dialog'), findsOneWidget);
    await tester.tap(key('library-cover-color-3'));
    int? coverColour() =>
        tester.widget<LibraryCover>(key('library-cover-$later')).color;
    await until(
      tester,
      () => coverColour() == libraryPalette[3],
      'The colour cover shows once it is saved.',
    );

    await restart(tester);
    await until(
      tester,
      () => key('library-pin-$later').evaluate().isNotEmpty,
      'The pin is read back from the vault.',
    );
    expect(left(later), lessThan(left(earlier)));
    expect(coverColour(), libraryPalette[3]);
    expect(tester.takeException(), isNull);
  });

  tabletTest(
    'a label assigned in the dialog shows on the card and filters in the labels tab',
    (tester) async {
      final (math, english) = (await tester.runAsync(() async {
        final math = await markdown('수학');
        final english = await markdown('영어');
        await controller.refresh();
        return (math, english);
      }))!;
      await mount(tester);
      final before = DateTime.now().microsecondsSinceEpoch;
      await openMenu(tester, math.id, '라벨 추가');
      expect(key('library-labels-dialog'), findsOneWidget);
      await tester.tap(key('library-label-new'));
      await tester.pump();
      await tester.enterText(key('library-label-name'), '시험');
      await tester.tap(key('library-label-color-2'));
      await tester.pump();
      await tester.tap(key('library-label-add'));
      await tester.pump();
      await tester.tap(key('library-labels-save'));
      await until(
        tester,
        () => key('library-label-dots-${math.id}').evaluate().isNotEmpty,
        'The label colour shows on the card once it is saved.',
      );
      expect(key('library-label-dots-${english.id}'), findsNothing);
      final stored = await read(
        tester,
        () => LibraryMarksStore(controller.repository).read(),
      );
      final label = stored.labels.single;
      expect(label.name, '시험');
      expect(label.color, libraryPalette[2]);
      expect(label.changedAt, greaterThanOrEqualTo(before));
      expect(stored.labelsOf, {
        math.id: {label.id},
      });

      // The 라벨 tab lists it; choosing it shows only its documents.
      await tester.tap(key('library-drawer-labels'));
      await tester.pump();
      await navigate(
        tester,
        'library-drawer-label-${label.id}',
        () => title(tester) == '시험',
      );
      expect(card(math.id), findsOneWidget);
      expect(card(english.id), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  tabletTest('PPT 가져오기 asks the picker for presentation types only', (
    tester,
  ) async {
    const channel = MethodChannel('personal_ink_vault/office_source');
    const id = '00000000-0000-4000-8000-000000000031';
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    Map<String, Object?>? chosen;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'choose' => chosen,
        'release' => null,
        _ => fail('Unexpected ${call.method}'),
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await mount(tester);
    Future<void> importPpt() async {
      await tester.tap(key('library-create-button'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(key('library-add-importPpt'));
      await drain(tester);
    }

    // The picker offers presentations only; cancelling it changes nothing.
    await importPpt();
    expect(calls.map((call) => call.method), ['choose']);
    expect(calls.single.arguments, {
      'mimeTypes': [
        'application/vnd.ms-powerpoint',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        'application/vnd.oasis.opendocument.presentation',
      ],
    });
    expect(controller.activeSession, isNull);

    // A document of another format is refused and let go without reading it.
    calls.clear();
    chosen = {'id': id, 'name': '보고서.docx'};
    await importPpt();
    expect(calls.map((call) => call.method), ['choose', 'release']);
    expect(calls.last.arguments, {'id': id});
    expect(find.text('PPT 파일을 고르세요.'), findsOneWidget);
    expect(key('office-import-mode'), findsNothing);
    expect(controller.activeSession, isNull);
    expect(tester.takeException(), isNull);
  });

  tabletTest(
    'the pencil and 만들기 make a page note at once with the last page pattern',
    (tester) async {
      final pattern = stows.lastBackgroundPattern.value;
      addTearDown(() => stows.lastBackgroundPattern.value = pattern);
      stows.lastBackgroundPattern.value = CanvasBackgroundPattern.grid;
      await mount(tester);

      await tester.tap(key('library-new-note'));
      await until(
        tester,
        () => controller.activeSession != null,
        'The pencil makes and opens a page note.',
      );
      expect(find.text('문서 이름'), findsNothing);
      final first = controller.activeSession!;
      expect(first.note.title, '새 노트');
      expect(first.note.documentKind, VaultDocumentKind.handwriting);
      final firstInk = await read(
        tester,
        () => controller.loadInk(session: first),
      );
      expect(firstInk.backgroundPattern, CanvasBackgroundPattern.grid);
      firstInk.dispose();

      // The editor saves in real time, as in navigation_test's back.
      final back = key('workspace-back-to-library');
      await until(
        tester,
        () =>
            back.evaluate().isNotEmpty &&
            tester.widget<IconButton>(back).onPressed != null,
        'The note is open and its back button ready.',
      );
      await tester.runAsync(() async {
        tester.widget<IconButton>(back).onPressed!();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await until(
        tester,
        () => controller.activeSession == null,
        'Back returns to the library.',
      );

      // 「새 노트」's 만들기 uses the pattern chosen there.
      await tester.tap(key('library-create-button'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(key('library-add-note'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(key('library-pattern-dots'));
      await tester.pump();
      await tester.tap(key('library-new-note-create'));
      await until(
        tester,
        () =>
            controller.activeSession != null &&
            controller.activeSession!.note.id != first.note.id,
        '만들기 makes and opens a page note.',
      );
      expect(find.text('문서 이름'), findsNothing);
      final second = controller.activeSession!;
      expect(second.note.title, '새 노트');
      expect(stows.lastBackgroundPattern.value, CanvasBackgroundPattern.dots);
      final secondInk = await read(
        tester,
        () => controller.loadInk(session: second),
      );
      expect(secondInk.backgroundPattern, CanvasBackgroundPattern.dots);
      secondInk.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  tabletTest('a card shows the saved date and the page count of its cover', (
    tester,
  ) async {
    final note = (await tester.runAsync(() async {
      final note = await markdown('세 쪽 노트');
      await controller.refresh();
      return note;
    }))!;
    await mount(tester, covers: _FactCovers.new);
    final expected = '${libraryDate(DateTime.now())} · 3 페이지';
    await until(
      tester,
      () => find
          .descendant(of: card(note.id), matching: find.text(expected))
          .evaluate()
          .isNotEmpty,
      'The date comes from the vault and the pages from the cover.',
    );
    expect(tester.takeException(), isNull);
  });
}

final class _NoCovers extends ThumbnailCache {
  new(super.root);

  @override
  Future<String?> coverKey(NoteRepository repository, VaultNote note) async =>
      null;
}

/// A cover with its facts sidecar: three pages, 3:4.
final class _FactCovers extends ThumbnailCache {
  new(super.root);

  @override
  Future<String?> coverKey(NoteRepository repository, VaultNote note) async =>
      'facts-${note.id}';

  @override
  Future<File?> getOrCreate(NoteRepository repository, VaultNote note) async {
    await root.create(recursive: true);
    final png = File('${root.path}/${note.id}.png');
    await png.writeAsBytes(image.encodePng(image.Image(width: 3, height: 4)));
    await File(
      '${png.path}.facts.json',
    ).writeAsString(jsonEncode({'pages': 3, 'aspect': 0.75}));
    return png;
  }
}
