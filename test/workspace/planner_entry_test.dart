import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saber/components/drive/drive_panel.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/planner/planner_platform.dart';
import 'package:saber/data/planner/planner_store.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/library_marks.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/planner/calendar_page.dart';
import 'package:saber/pages/planner/reminder_page.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The planner in the workspace (설계 6·7절): the drawer's 리마인더 and 달력,
/// widget taps, the home-screen widgets fed from the open vault, note links
/// on handwritten pages, the top bar's cloud, and the library marks routed
/// here from Task 4's review.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  late WorkspaceController controller;
  late bool closed;
  late List<MethodCall> calls;
  String? launchTarget;

  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('planner-entry-');
    controller = WorkspaceController(
      await NoteRepository.open(
        Directory(p.join(temp.path, 'vault')),
        createFormatVersion: 2,
      ),
      directoryProvider: () async => Directory(p.join(temp.path, 'support')),
    );
    await controller.refresh();
    closed = false;
    calls = [];
    launchTarget = null;
    messenger.setMockMethodCallHandler(PlannerPlatform.channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'takeLaunchTarget' => launchTarget,
        'scheduleReminders' ||
        'notificationStatus' ||
        'requestNotificationPermission' => {'granted': true, 'exact': true},
        _ => null,
      };
    });
    stows.libraryPanelOpen.value = null;
    stows.libraryGrid.value = true;
    stows.librarySort.value = 'default';
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(PlannerPlatform.channel, null);
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

  /// Runs a vault call in real time while the fake zone is pumped.
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
    DriveConnectionController Function(WorkspaceController)? drive,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: StudyWorkspace(
            controller: controller,
            thumbnailCacheFactory: _NoCovers.new,
            plannerPlatform: PlannerPlatform(),
            createDriveConnection: drive,
          ),
        ),
      ),
    );
    await drain(tester);
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
  Finder card(String id) => key(
    'library-note-${controller.notes.singleWhere((note) => note.id == id).revision.revisionId}',
  );
  int count(String method) =>
      calls.where((call) => call.method == method).length;
  Finder screen(Type page) => find.byType(page, skipOffstage: false);

  /// What a widget tap sends while the app runs.
  Future<void> nativeOpen(WidgetTester tester, String target) async {
    await messenger.handlePlatformMessage(
      PlannerPlatform.channel.name,
      PlannerPlatform.channel.codec.encodeMethodCall(
        MethodCall('open', target),
      ),
      (_) {},
    );
    await drain(tester);
  }

  /// The planner screen's ← back to the workspace.
  Future<void> leave(WidgetTester tester, Type page) async {
    await tester.tap(
      find.descendant(of: find.byType(page), matching: find.byTooltip('뒤로')),
    );
    await until(
      tester,
      () => screen(page).evaluate().isEmpty,
      'The planner screen closes.',
    );
  }

  /// Replaces the vault with a format-1 one holding a handwritten note.
  Future<VaultNote> legacyVault(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        controller.dispose();
        await controller.repository.close();
        controller = WorkspaceController(
          await NoteRepository.open(
            Directory(p.join(temp.path, 'legacy')),
            createFormatVersion: 1,
          ),
          directoryProvider: () async =>
              Directory(p.join(temp.path, 'support')),
        );
        final note = await controller.store.create('기존 필기');
        await controller.refresh();
        return note;
      }))!;

  tabletTest('the reminder and calendar rows open their screens once', (
    tester,
  ) async {
    await mount(tester);
    // Without Drive the top bar keeps the library's crossed-out cloud.
    expect(find.byTooltip('동기화 연결 없음'), findsOneWidget);
    for (final (row, page) in [
      ('library-nav-reminder', ReminderPage),
      ('library-nav-calendar', CalendarPage),
    ]) {
      await tester.tap(key(row));
      await tester.tap(key(row), warnIfMissed: false);
      await until(
        tester,
        () => find.byType(page).evaluate().isNotEmpty,
        '$row opens its screen.',
      );
      await drain(tester);
      expect(screen(page), findsOneWidget, reason: row);
      await leave(tester, page);
      expect(find.byType(LibraryHome), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  for (final (target, page, other) in [
    ('calendar', CalendarPage, ReminderPage),
    ('reminder', ReminderPage, CalendarPage),
  ]) {
    tabletTest(
      'a $target launch target opens the $target after the vault opens',
      (tester) async {
        launchTarget = target;
        await mount(tester);
        await until(
          tester,
          () => find.byType(page).evaluate().isNotEmpty,
          'The widget tap that started the app opens its screen.',
        );
        expect(count('takeLaunchTarget'), 1);
        expect(screen(other), findsNothing);
        await leave(tester, page);
        expect(tester.takeException(), isNull);
      },
    );
  }

  tabletTest('an open request while running opens the reminder screen', (
    tester,
  ) async {
    await mount(tester);
    expect(count('takeLaunchTarget'), 1);
    expect(screen(ReminderPage), findsNothing);
    await nativeOpen(tester, 'reminder');
    await until(
      tester,
      () => find.byType(ReminderPage).evaluate().isNotEmpty,
      'A widget tap opens the reminders.',
    );

    // The same screen stays one; the other one takes its place.
    await nativeOpen(tester, 'reminder');
    expect(screen(ReminderPage), findsOneWidget);
    await nativeOpen(tester, 'calendar');
    await until(
      tester,
      () => find.byType(CalendarPage).evaluate().isNotEmpty,
      'A calendar tap replaces the reminders.',
    );
    await drain(tester);
    expect(screen(ReminderPage), findsNothing);
    expect(screen(CalendarPage), findsOneWidget);
    await leave(tester, CalendarPage);
    expect(find.byType(LibraryHome), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  tabletTest('a format-1 vault asks to upgrade before the planner opens', (
    tester,
  ) async {
    await legacyVault(tester);
    await mount(tester);
    await tester.tap(key('library-nav-reminder'));
    await drain(tester);
    expect(find.text('보관함 형식 업데이트'), findsOneWidget);
    // The gear waits while the workspace is busy.
    expect(
      tester.widget<IconButton>(key('library-settings')).onPressed,
      isNull,
    );

    await tester.tap(find.text('취소'));
    await drain(tester);
    expect(find.text('보관함 형식 업데이트'), findsNothing);
    expect(screen(ReminderPage), findsNothing);
    expect(controller.repository.formatVersion, 1);
    expect(
      tester.widget<IconButton>(key('library-settings')).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  tabletTest('a format-1 vault opens the planner once the upgrade is accepted', (
    tester,
  ) async {
    final paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _SupportPaths(
      p.join(temp.path, 'support'),
    );
    addTearDown(() => PathProviderPlatform.instance = paths);
    final note = await legacyVault(tester);
    await mount(tester);
    await tester.tap(key('library-nav-reminder'));
    await drain(tester);
    await tester.runAsync(() => tester.tap(find.text('형식 2 복사본 만들기')));
    await until(
      tester,
      () => find.byType(ReminderPage).evaluate().isNotEmpty,
      'The reminders open in the upgraded vault.',
    );
    expect(controller.repository.formatVersion, 2);
    expect(controller.notes.map((n) => n.id), contains(note.id));
    await leave(tester, ReminderPage);
    expect(tester.takeException(), isNull);
  });

  tabletTest('a heart on a format-1 vault asks to upgrade it', (tester) async {
    final note = await legacyVault(tester);
    await mount(tester);
    await tester.tap(key('library-favorite-${note.id}'));
    await drain(tester);
    expect(find.text('보관함 형식 업데이트'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await drain(tester);
    expect(find.text('보관함 형식 업데이트'), findsNothing);
    expect(find.text('보관함 형식을 올린 뒤 쓸 수 있습니다.'), findsNothing);
    expect(controller.repository.formatVersion, 1);
    expect(tester.takeException(), isNull);
  });

  tabletTest('opening a vault sends both widget payloads and the alarm list', (
    tester,
  ) async {
    final now = DateTime.now();
    final at = DateTime(now.year, now.month, now.day + 1, 9);
    final day = DateTime(now.year, now.month, 15);
    final month =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}';
    await tester.runAsync(() async {
      final store = PlannerStore(controller.repository);
      await store.writeReminders(
        ReminderNote(
          items: [
            ReminderItem(id: 'pill', text: '약 먹기', at: at, changedAt: 1),
            // A blank task neither shows nor rings.
            const ReminderItem(id: 'blank', text: ' ', order: 1, changedAt: 1),
          ],
        ),
      );
      await store.writeEvents([
        PlannerEvent(id: 'dentist', title: '치과', start: day, end: day),
      ]);
      await store.writeInk({
        month: MonthInk(
          month: month,
          strokes: const [
            InkStroke(
              points: [0.1, 0.1, 0.2, 0.2],
              color: 0xFF202124,
              width: 0.006,
            ),
          ],
        ),
      });
    });
    await mount(tester);
    await until(
      tester,
      () => count('scheduleReminders') > 0,
      'The open vault is sent to the widgets and alarms.',
    );
    Map<String, dynamic> payload(String kind) => jsonDecode(
      (calls
                  .lastWhere(
                    (call) =>
                        call.method == 'updateWidget' &&
                        (call.arguments as Map)['kind'] == kind,
                  )
                  .arguments
              as Map)['payload']
          as String,
    ) as Map<String, dynamic>;
    final reminder = payload('reminder');
    expect(reminder['version'], 1);
    expect(reminder['items'], [
      {
        'id': 'pill',
        'text': '약 먹기',
        'at': at.millisecondsSinceEpoch,
        'done': false,
        'order': 0,
      },
    ]);
    final calendar = payload('calendar');
    expect(calendar['version'], 1);
    expect(
      [for (final event in calendar['events'] as List) (event as Map)['title']],
      ['치과'],
    );
    expect((calendar['months'] as Map).keys, [month]);
    expect(
      calls.lastWhere((call) => call.method == 'scheduleReminders').arguments,
      {
        'items': [
          {'id': 'pill', 'title': '약 먹기', 'at': at.millisecondsSinceEpoch},
        ],
      },
    );

    // A change in the vault is sent again, two seconds after it.
    final sent = count('scheduleReminders');
    await read(tester, () async {
      final store = PlannerStore(controller.repository);
      final note = await store.readReminders();
      await store.writeReminders(
        ReminderNote(
          items: [
            ...note.items,
            ReminderItem(
              id: 'call',
              text: '전화하기',
              at: at.add(const Duration(hours: 1)),
              order: 2,
              changedAt: 2,
            ),
          ],
        ),
      );
    });
    await until(
      tester,
      () => count('scheduleReminders') > sent,
      'A vault change is sent too.',
    );
    final alarms =
        (calls.lastWhere((call) => call.method == 'scheduleReminders').arguments
                as Map)['items']
            as List;
    expect(
      [for (final alarm in alarms) (alarm as Map)['id']],
      ['pill', 'call'],
    );
    expect(tester.takeException(), isNull);
  });

  tabletTest(
    'a reminder added on another device survives a save on this screen',
    (tester) async {
      await mount(tester);
      await tester.tap(key('library-nav-reminder'));
      await until(
        tester,
        () => key('reminder-memo').evaluate().isNotEmpty,
        'The reminder screen opens.',
      );
      // Another device's task reaches the vault through sync.
      await read(
        tester,
        () => PlannerStore(controller.repository).writeReminders(
          const ReminderNote(
            items: [ReminderItem(id: 'phone', text: '택배 받기', changedAt: 1)],
          ),
        ),
      );
      await until(
        tester,
        () => key('reminder-item-phone').evaluate().isNotEmpty,
        'The open screen reads the vault again.',
      );

      // A task added here is saved beside it.
      await tester.tap(key('reminder-add'));
      await tester.pump();
      await tester.enterText(
        find
            .descendant(
              of: key('reminder-page'),
              matching: find.byType(TextField),
            )
            .last,
        '우유 사기',
      );
      // The screen saves five seconds after the last change.
      await tester.pump(const Duration(seconds: 5));
      late ReminderNote note;
      for (var i = 0; i < 20; i++) {
        note = await read(
          tester,
          () => PlannerStore(controller.repository).readReminders(),
        );
        if (note.items.length == 2) break;
        await drain(tester);
      }
      expect({for (final item in note.items) item.text}, {'택배 받기', '우유 사기'});
      await leave(tester, ReminderPage);
      expect(tester.takeException(), isNull);
    },
  );

  tabletTest('a vault change outside the planner sends nothing', (
    tester,
  ) async {
    await mount(tester);
    await until(
      tester,
      () => count('scheduleReminders') == 1,
      'The open vault is sent once.',
    );
    final sent = calls.length;
    // Writing a note changes the vault, not the planner.
    await read(tester, () => controller.store.create('메모'));
    for (var i = 0; i < 14; i++) {
      await drain(tester);
    }
    expect(calls.length, sent);
    expect(tester.takeException(), isNull);
  });

  tabletTest('a vault switch closes the open planner screen', (tester) async {
    await mount(tester);
    await tester.tap(key('library-nav-reminder'));
    await until(
      tester,
      () => key('reminder-memo').evaluate().isNotEmpty,
      'The reminder screen opens.',
    );
    final next = (await tester.runAsync(
      () => NoteRepository.open(
        Directory(p.join(temp.path, 'next')),
        createFormatVersion: 2,
      ),
    ))!;
    await read(tester, () => controller.replaceRepository(next));
    await until(
      tester,
      () => screen(ReminderPage).evaluate().isEmpty,
      'The screen of the vault left behind closes.',
    );
    expect(find.byType(LibraryHome), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  tabletTest('a widget tap on a phone closes the open drawer first', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    await mount(tester);
    await tester.tap(find.byType(DrawerButton));
    await drain(tester);
    expect(find.byType(Drawer), findsOneWidget);
    await nativeOpen(tester, 'reminder');
    await until(
      tester,
      () => find.byType(ReminderPage).evaluate().isNotEmpty,
      'A widget tap opens the reminders.',
    );
    await leave(tester, ReminderPage);
    expect(find.byType(Drawer), findsNothing);
    expect(tester.takeException(), isNull);
  });

  tabletTest('a link to another note opens that note in the workspace', (
    tester,
  ) async {
    final (first, second) = (await tester.runAsync(() async {
      // Made as the pencil makes them: with a first page.
      Future<VaultNote> handwritten(String title) async {
        final note = await controller.createNote(title);
        await controller.closeNote(session: controller.activeSession!);
        return note;
      }

      final first = await handwritten('가 노트');
      final second = await handwritten('나 노트');
      final gone = await handwritten('다 노트');
      await controller.store.setDeleted(gone, true);
      await handwritten('라 노트');
      await controller.refresh();
      return (first, second);
    }))!;
    final third = controller.notes.singleWhere((note) => note.title == '라 노트');
    await mount(tester);
    await tester.tap(card(first.id));
    final editors = find.byType(Editor);
    await until(
      tester,
      () =>
          controller.activeSession?.note.id == first.id &&
          editors.evaluate().isNotEmpty &&
          tester.state<EditorState>(editors).coreInfo.pages.isNotEmpty &&
          !tester.state<EditorState>(editors).coreInfo.readOnly,
      'The first note opens in the editor.',
    );

    // The link dialog's 노트 tab: the vault's notes outside the trash, the
    // open one too, by title.
    final chrome = tester.widget<Editor>(editors).chrome!;
    expect(await read(tester, chrome.listNotes!), [
      (id: first.id, title: '가 노트'),
      (id: second.id, title: '나 노트'),
      (id: third.id, title: '라 노트'),
    ]);

    final editor = tester.state<EditorState>(editors);
    final page = editor.coreInfo.pages.first;
    page.links.add(
      PageLink(
        id: 'to-second',
        // In the middle of the page, which the screen shows.
        rect: Rect.fromCenter(
          center: page.size.center(Offset.zero),
          width: 300,
          height: 120,
        ),
        target: NoteLink(second.id).toString(),
      ),
    );
    editor.currentTool = Pen.currentPen;
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pump();
    await tester.tap(key('page-link-badge-to-second'));
    await until(
      tester,
      () => controller.activeSession?.note.id == second.id,
      'The link opens the other note here.',
    );

    // A link followed while the workspace is still opening another one
    // waits its turn instead of being dropped.
    unawaited(chrome.openLink!(NoteLink(first.id).toString()));
    unawaited(chrome.openLink!(NoteLink(third.id).toString()));
    await until(
      tester,
      () => controller.activeSession?.note.id == third.id,
      'The second link opens after the first.',
    );
    expect(tester.takeException(), isNull);
  });

  tabletTest('the top-bar cloud shows the Drive state', (tester) async {
    late _FakeDrive drive;
    stows.libraryPanelOpen.value = false;
    await mount(
      tester,
      drive: (workspace) =>
          drive = _FakeDrive(workspace, Directory(p.join(temp.path, 'drive'))),
    );
    final cloud = key('library-sync');
    Future<void> shows(IconData icon, String state) async {
      await tester.pump();
      expect(
        find.descendant(of: cloud, matching: find.byIcon(icon)),
        findsOneWidget,
        reason: state,
      );
      expect(tester.widget<IconButton>(cloud).tooltip, state);
    }

    await until(tester, () => drive.ready && !drive.busy, 'Drive starts.');
    await shows(Icons.cloud_off_outlined, 'Drive 미연결');
    drive.show(busy: true);
    await shows(Icons.cloud_sync_outlined, 'Drive 준비 중');
    drive.show(
      busy: false,
      connected: true,
      status: const SyncStatus(SyncPhase.synced),
    );
    await shows(Icons.cloud_done_outlined, 'Drive 반영 완료');
    drive.show(status: const SyncStatus(SyncPhase.syncing));
    await shows(Icons.cloud_sync_outlined, 'Drive 송수신 중');
    drive.show(lease: true);
    await shows(Icons.sync_problem_outlined, '다른 Drive 동기화 작업 대기 중');
    drive.show(lease: false, error: 'Drive operation failed.');
    await shows(Icons.sync_problem_outlined, 'Drive 연결 확인 필요');

    // A tap opens the side panel, where the Drive panel is.
    expect(key('library-panel'), findsNothing);
    await tester.tap(cloud);
    await drain(tester);
    expect(
      find.descendant(
        of: key('library-panel'),
        matching: find.byType(DrivePanel),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  tabletTest('최근 counts 50 live documents', (tester) async {
    final live = (await tester.runAsync(() async {
      final live = <String>[];
      for (var i = 0; i < 50; i++) {
        final note = await controller.store.create('노트 $i');
        controller.navigation.openDocument(note.id, note.title);
        live.add(note.id);
      }
      // Opened last: two documents now in the trash and one gone.
      for (var i = 0; i < 2; i++) {
        final note = await controller.store.create('버린 노트 $i');
        controller.navigation.openDocument(note.id, note.title);
        await controller.store.setDeleted(note, true);
      }
      controller.navigation.openDocument(newId(), '없는 노트');
      controller.navigation.showLibrary(null);
      await controller.refresh();
      return live;
    }))!;
    await mount(tester);
    LibraryCollection shown() =>
        tester.widget<LibraryHome>(find.byType(LibraryHome)).collection;
    await tester.tap(key('library-nav-recent'));
    await until(
      tester,
      () => shown().kind == LibraryCollectionKind.recent,
      '최근 opens.',
    );
    expect(shown().noteIds, live.reversed.toList());
    expect(tester.takeException(), isNull);
  });

  tabletTest('a label edit keeps a label added elsewhere', (tester) async {
    final exam = newId(), homework = newId();
    final note = (await tester.runAsync(() async {
      final note = await controller.store.create('수학');
      await LibraryMarksStore(controller.repository).write(
        LibraryMarks.empty
            .putLabel(
              LibraryLabel(
                id: exam,
                name: '시험',
                color: 0xFFE53935,
                changedAt: 1,
              ),
            )
            .putLabel(
              LibraryLabel(
                id: homework,
                name: '숙제',
                color: 0xFF1E88E5,
                changedAt: 1,
              ),
            )
            .setLabels(note.id, {exam}),
      );
      await controller.refresh();
      return note;
    }))!;
    await mount(tester);
    await until(
      tester,
      () => key('library-label-dots-${note.id}').evaluate().isNotEmpty,
      'The card shows its label.',
    );
    await tester.tap(
      key(
        'library-note-menu-${controller.notes.singleWhere((n) => n.id == note.id).revision.revisionId}',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('라벨 추가'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(key('library-labels-dialog'), findsOneWidget);

    // Another device gives the document the second label meanwhile.
    await read(tester, () async {
      final store = LibraryMarksStore(controller.repository);
      await store.write(
        (await store.read()).setLabels(note.id, {exam, homework}),
      );
    });
    // Here the first one is taken off.
    await tester.tap(key('library-label-check-$exam'));
    await tester.pump();
    await tester.tap(key('library-labels-save'));
    Set<String>? labels;
    for (var i = 0; i < 20; i++) {
      await drain(tester);
      labels = (await read(
        tester,
        () => LibraryMarksStore(controller.repository).read(),
      )).labelsOf[note.id];
      if (labels?.length == 1) break;
    }
    expect(labels, {homework});
    expect(tester.takeException(), isNull);
  });
}

/// The app's support folder in the test's temporary folder.
final class _SupportPaths extends PathProviderPlatform {
  new(this.support);

  final String support;

  @override
  Future<String?> getApplicationSupportPath() async => support;
}

final class _NoCovers extends ThumbnailCache {
  new(super.root);

  @override
  Future<String?> coverKey(NoteRepository repository, VaultNote note) async =>
      null;
}

/// Drive with its states set by the test, as its work would set them.
final class _FakeDrive extends DriveConnectionController {
  new(WorkspaceController workspace, Directory folder)
    : super(
        repository: () => workspace.repository,
        onRepositoryChanged: workspace.replaceRepository,
        onRemoteUpdated: workspace.refresh,
        onResumeReload: workspace.reloadFromDisk,
        directoryProvider: () async => folder,
      );

  var _connected = false;
  var _lease = false;

  @override
  bool get connected => _connected;

  @override
  bool get waitingForLease => _lease;

  void show({
    bool? busy,
    bool? connected,
    bool? lease,
    SyncStatus? status,
    String? error,
  }) {
    if (busy != null) this.busy = busy;
    if (connected != null) _connected = connected;
    if (lease != null) _lease = lease;
    if (status != null) this.status = status;
    if (error != null) this.error = error;
    notifyListeners();
  }
}
