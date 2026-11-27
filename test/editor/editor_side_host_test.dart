import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/canvas_preview.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_pages.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/theming/adaptive_alert_dialog.dart';
import 'package:saber/components/toolbar/editor_bottom_sheet.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/audio/recording_entry.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/page_clipboard.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/note_page_marks.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/editor/editor_chrome.dart';
import 'package:saber/pages/editor/editor_side_host.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/read_only_reason.dart';
import 'package:sbn/tool_id.dart';

import '../utils/paint_counts.dart';
import '../utils/test_mock_channel_handlers.dart';

/// The editor's left panel and its favourites (supplement Task 9).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  /// The favourites of every page marks attachment of [noteId], merged.
  Future<List<String>> storedFavorites(
    NoteSideStore store,
    String noteId,
  ) async {
    final all = <NotePageMarks>[];
    for (final record in await store.list(noteId, NoteSideKind.pageMarks)) {
      for (final head in record.heads) {
        final files = await store.repository.readFiles(head);
        all.add(NotePageMarks.decode(files['page-marks.json']!));
      }
    }
    return NotePageMarks.merge(all).favorites;
  }

  /// The live outline rows (page id, title) of every page marks attachment
  /// of [noteId], merged.
  Future<List<(String, String)>> storedOutline(
    NoteSideStore store,
    String noteId,
  ) async {
    final all = <NotePageMarks>[];
    for (final record in await store.list(noteId, NoteSideKind.pageMarks)) {
      for (final head in record.heads) {
        final files = await store.repository.readFiles(head);
        all.add(NotePageMarks.decode(files['page-marks.json']!));
      }
    }
    return [
      for (final row in NotePageMarks.merge(all).liveOutline)
        (row.pageId, row.title),
    ];
  }

  Map<String, Uint8List> marksFile(NotePageMarks marks) => {
    'page-marks.json': marks.encode(),
  };

  group('the host keeps favourites in the note attachment', () {
    late Directory temp;
    late NoteRepository repository;
    late NoteSideStore store;
    late String noteId;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('piv-side-host-');
      repository = await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      );
      store = NoteSideStore(repository);
      await FileManager.init(
        documentsDirectory: '${temp.path}/working',
        shouldWatchRootDirectory: false,
      );
      noteId = (await WorkspaceStore(repository).create('Side')).id;
    });
    tearDown(() async {
      await repository.close().timeout(const Duration(seconds: 30));
      await temp.delete(recursive: true);
    });

    EditorSideHost host({
      NoteSideBinding? binding,
      bool noBinding = false,
      List<Object>? errors,
      List<bool>? saves,
      Future<bool> Function()? noteWritable,
    }) {
      final h = EditorSideHost(
        binding: () =>
            noBinding ? null : binding ?? (store: store, noteId: noteId),
        saveNote: (force) async => saves?.add(force),
        pages: () => const [],
        pageOnScreen: () => 0,
        pageMoves: const AlwaysStoppedAnimation(0),
        onChanged: () {},
        onError: (error) => errors?.add(error),
        noteWritable: noteWritable,
      );
      addTearDown(h.dispose);
      return h;
    }

    test('adding and removing a favourite writes the attachment', () async {
      final side = host();
      await side.load();
      expect(side.favoritesAvailable, isTrue);
      await side.setFavorite('page-a', true);
      expect(side.isFavorite('page-a'), isTrue);
      final first = await store.list(noteId, NoteSideKind.pageMarks);
      expect(first, hasLength(1));
      expect(await storedFavorites(store, noteId), ['page-a']);

      await side.setFavorite('page-a', false);
      expect(side.isFavorite('page-a'), isFalse);
      final second = await store.list(noteId, NoteSideKind.pageMarks);
      expect(second.single.entityId, first.single.entityId);
      expect(second.single.revisionId, isNot(first.single.revisionId));
      expect(await storedFavorites(store, noteId), isEmpty);

      // read again by another editor of the same note
      final again = host();
      await again.load();
      expect(again.isFavorite('page-a'), isFalse);
    });

    test(
      'two attachments (offline firsts) merge; writes go to the first only',
      () async {
        final at = DateTime.utc(2026, 11, 1);
        // two devices each wrote the note's first page marks offline
        await store.write(
          noteId,
          NoteSideKind.pageMarks,
          marksFile(NotePageMarks()..addFavorite('page-a', at: at)),
        );
        await store.write(
          noteId,
          NoteSideKind.pageMarks,
          marksFile(
            NotePageMarks()
              ..addFavorite('page-a', at: at)
              ..addFavorite('page-b', at: at),
          ),
        );
        final before = await store.list(noteId, NoteSideKind.pageMarks);
        expect(before, hasLength(2));

        final side = host();
        await side.load();
        expect(side.isFavorite('page-a'), isTrue);
        expect(side.isFavorite('page-b'), isTrue);

        await side.setFavorite('page-a', false);
        final after = await store.list(noteId, NoteSideKind.pageMarks);
        // neither is marked deleted; the one with the smaller id took the write
        expect(
          [for (final r in after) r.entityId],
          [for (final r in before) r.entityId],
        );
        expect(after.first.revisionId, isNot(before.first.revisionId));
        expect(after.first.heads.single.parentRevisionIds, [
          before.first.revisionId,
        ]);
        expect(after.last.revisionId, before.last.revisionId);

        final again = host();
        await again.load();
        expect(again.isFavorite('page-a'), isFalse, reason: 'still removed');
        expect(again.isFavorite('page-b'), isTrue);
      },
    );

    test(
      'a head that arrives meanwhile is merged and the write tried again',
      () async {
        final at = DateTime.utc(2026, 11, 1);
        final first = await store.write(
          noteId,
          NoteSideKind.pageMarks,
          marksFile(NotePageMarks()..addFavorite('page-a', at: at)),
        );
        final side = host();
        await side.load();
        var arrivals = 0;
        store.beforeCommit = () async {
          if (arrivals++ > 0) return;
          // another device's edit arrives between the read and the commit
          await repository.commit(
            entityId: first.entityId,
            kind: EntityKind.attachment,
            ownerNoteId: noteId,
            files: marksFile(
              NotePageMarks()
                ..addFavorite('page-a', at: at)
                ..addFavorite('page-c', at: at),
            ),
            parentRevisionIds: [first.revisionId],
          );
        };
        final errors = <Object>[];
        final retried = host(errors: errors);
        await retried.load();
        await retried.setFavorite('page-b', true);
        expect(arrivals, 2, reason: 'committed on the second try');
        expect(errors, isEmpty);
        expect(
          await storedFavorites(store, noteId),
          unorderedEquals(['page-a', 'page-b', 'page-c']),
        );
        expect(
          (await store.list(noteId, NoteSideKind.pageMarks)).single.heads,
          hasLength(1),
        );
      },
    );

    test('a write that fails twice says so and keeps the favourite', () async {
      final first = await store.write(
        noteId,
        NoteSideKind.pageMarks,
        marksFile(NotePageMarks()),
      );
      var tries = 0;
      store.beforeCommit = () async {
        tries++;
        // a new head every time, so every commit misses
        final heads = await repository.heads(first.entityId);
        await repository.commit(
          entityId: first.entityId,
          kind: EntityKind.attachment,
          ownerNoteId: noteId,
          files: marksFile(NotePageMarks()),
          parentRevisionIds: [for (final h in heads) h.revisionId],
        );
      };
      final errors = <Object>[];
      final side = host(errors: errors);
      await side.load();
      await side.setFavorite('page-a', true);
      expect(tries, 2);
      expect(errors, hasLength(1));
      expect(side.isFavorite('page-a'), isTrue, reason: 'kept in memory');
      expect(await storedFavorites(store, noteId), isEmpty);

      // the next write carries it
      store.beforeCommit = null;
      await side.setFavorite('page-b', true);
      expect(
        await storedFavorites(store, noteId),
        unorderedEquals(['page-a', 'page-b']),
      );
    });

    test('the note is saved once before the first write', () async {
      final saves = <bool>[];
      final side = host(saves: saves);
      await side.load();
      expect(saves, isEmpty);
      await side.setFavorite('page-a', true);
      await side.setFavorite('page-b', true);
      // forced the first time (its pages may never have been saved), then
      // only what waits to be saved
      expect(saves, [true, false]);
    });

    test('a write still lands after the editor is gone, quietly', () async {
      final errors = <Object>[];
      final side = EditorSideHost(
        binding: () => (store: store, noteId: noteId),
        saveNote: (_) async {},
        pages: () => const [],
        pageOnScreen: () => 0,
        pageMoves: const AlwaysStoppedAnimation(0),
        onChanged: () {},
        onError: errors.add,
      );
      await side.load();
      final written = side.setFavorite('page-a', true);
      side.dispose();
      await written;
      expect(errors, isEmpty);
      expect(await storedFavorites(store, noteId), ['page-a']);
    });

    test(
      'an attachment with an unreadable head is left; a new one keeps it',
      () async {
        final at = DateTime.utc(2026, 11, 1);
        final first = await store.write(
          noteId,
          NoteSideKind.pageMarks,
          marksFile(NotePageMarks()..addFavorite('page-a', at: at)),
        );
        // another device's head of the same attachment that this app cannot
        // read (a newer schema). (A head whose file is missing stops every
        // guarded write of the vault until it is repaired, so it is not this.)
        await repository.commit(
          entityId: first.entityId,
          kind: EntityKind.attachment,
          ownerNoteId: noteId,
          files: {
            'page-marks.json': Uint8List.fromList(
              utf8.encode('{"schemaVersion": 2, "favorites": ["page-z"]}'),
            ),
          },
          parentRevisionIds: [first.revisionId],
        );
        final sibling = await repository.commit(
          entityId: first.entityId,
          kind: EntityKind.attachment,
          ownerNoteId: noteId,
          files: marksFile(
            NotePageMarks()
              ..addFavorite('page-a', at: at)
              ..addFavorite('page-y', at: at),
          ),
          parentRevisionIds: [first.revisionId],
        );
        final listed = await store.list(noteId, NoteSideKind.pageMarks);
        expect(listed.single.heads.single.revisionId, sibling.revisionId);

        final errors = <Object>[];
        final side = host(errors: errors);
        await side.load();
        expect(side.isFavorite('page-a'), isTrue);
        await side.setFavorite('page-b', true);
        expect(errors, isEmpty);

        final again = host();
        await again.load();
        expect(again.isFavorite('page-b'), isTrue, reason: 'saved');
        expect(again.isFavorite('page-a'), isTrue);
        expect(again.isFavorite('page-y'), isTrue);
        // the damaged attachment is left as it is, a new one holds the write
        final after = await store.list(noteId, NoteSideKind.pageMarks);
        expect(after, hasLength(2));
        expect(
          after.firstWhere((r) => r.entityId == first.entityId).revisionId,
          sibling.revisionId,
        );
        // and the next write goes to the new one, not to a third
        await again.setFavorite('page-c', true);
        expect(await store.list(noteId, NoteSideKind.pageMarks), hasLength(2));
        expect(
          await storedFavorites(store, noteId),
          containsAll(['page-a', 'page-b', 'page-c', 'page-y']),
        );
      },
    );

    test(
      'a head that arrives between the list and the check is read again',
      () async {
        final at = DateTime.utc(2026, 11, 1);
        final first = await store.write(
          noteId,
          NoteSideKind.pageMarks,
          marksFile(NotePageMarks()..addFavorite('page-a', at: at)),
        );
        final racing = _RacingStore(repository);
        final side = host(binding: (store: racing, noteId: noteId));
        await side.load();
        // another device's first head of the same attachment, just after the
        // host listed it
        racing.afterList = () => repository.commit(
          entityId: first.entityId,
          kind: EntityKind.attachment,
          ownerNoteId: noteId,
          files: marksFile(NotePageMarks()..addFavorite('page-c', at: at)),
          parentRevisionIds: const [],
        );
        await side.setFavorite('page-b', true);
        final after = await store.list(noteId, NoteSideKind.pageMarks);
        expect(
          after.single.entityId,
          first.entityId,
          reason: 'written to it, no new attachment',
        );
        expect(after.single.heads, hasLength(1), reason: 'the split joined');
        expect(
          await storedFavorites(store, noteId),
          unorderedEquals(['page-a', 'page-b', 'page-c']),
        );
      },
    );

    // Final fix wave minor 1: as when the panel closes.
    test('names being changed when the note closes are kept', () async {
      final page = EditorPage();
      addTearDown(page.dispose);
      final entry = await NoteRecordings(store).add(
        noteId,
        audio: Uint8List.fromList([1, 2, 3]),
        duration: const Duration(seconds: 3),
        createdAt: DateTime.utc(2026, 11, 1),
      );
      final side = EditorSideHost(
        binding: () => (store: store, noteId: noteId),
        saveNote: (_) async {},
        pages: () => [page],
        pageOnScreen: () => 0,
        pageMoves: const AlwaysStoppedAnimation(0),
        onChanged: () {},
        onError: (_) {},
      );
      await side.load();
      await side.addOutline(0);
      side.renameDraft(side.renaming.value!, '그림 설명');
      side.audio.renaming.value = entry.entityId;
      side.audio.renameDraft(entry.entityId, '강의 1');
      side.dispose();
      await side.idle;
      expect(await storedOutline(store, noteId), [(page.pageId, '그림 설명')]);
      expect((await NoteRecordings(store).list(noteId)).single.name, '강의 1');
    });

    // Two devices wrote beside the note offline (final fix wave 1): the
    // host joins each split once on load, so apps that do not join them
    // (232, Windows 226) see no conflict either.
    group('a split attachment is joined on load', () {
      Future<void> branch(NoteSideRecord base, Map<String, Uint8List> files) =>
          repository.commit(
            entityId: base.entityId,
            kind: EntityKind.attachment,
            ownerNoteId: noteId,
            files: files,
            parentRevisionIds: [base.revisionId],
          );

      Uint8List text(String value) => Uint8List.fromList(utf8.encode(value));

      Future<NoteSideRecord> splitMarks() async {
        final at = DateTime.utc(2026, 11, 1);
        final base = await store.write(
          noteId,
          NoteSideKind.pageMarks,
          marksFile(NotePageMarks()),
        );
        for (final page in ['page-a', 'page-b']) {
          await branch(
            base,
            marksFile(NotePageMarks()..addFavorite(page, at: at)),
          );
        }
        return base;
      }

      Future<NoteSideRecord> splitQuickNote() async {
        final page = EditorCoreInfo(filePath: '/quick-note')
          ..pages.add(EditorPage());
        final (sbn, _) = page.saveToBinary(currentPageIndex: null);
        page.dispose();
        final files = {
          'quick-note.json': text('{"schemaVersion": 1}'),
          'quick-note.sbn2': sbn,
        };
        final base = await store.write(noteId, NoteSideKind.quickNote, files);
        await branch(base, files);
        await branch(base, files);
        return base;
      }

      Future<RecordingEntry> recording() => NoteRecordings(store).add(
        noteId,
        audio: Uint8List.fromList([1, 2, 3]),
        duration: const Duration(seconds: 3),
        createdAt: DateTime.utc(2026, 11, 1),
      );

      /// A recording renamed on one device and deleted on the other.
      Future<NoteSideRecord> splitRecording() async {
        final entry = await recording();
        await branch(entry.record, {
          'recording.json': text('{"schemaVersion": 1, "name": "Renamed"}'),
          'audio.m4a': Uint8List.fromList([1, 2, 3]),
        });
        await branch(entry.record, {
          'recording.json': text('{"schemaVersion": 1, "deleted": true}'),
        });
        return entry.record;
      }

      Future<Map<dynamic, dynamic>> marker(RevisionRecord head) async =>
          jsonDecode(
            utf8.decode(
              await repository.readRevisionFile(head, 'recording.json'),
            ),
          ) as Map;

      test('favourites: one head with both, the note not saved', () async {
        final base = await splitMarks();
        final saves = <bool>[];
        final errors = <Object>[];
        final side = host(saves: saves, errors: errors);
        await side.load();
        expect(await repository.heads(base.entityId), hasLength(1));
        expect(
          await storedFavorites(store, noteId),
          unorderedEquals(['page-a', 'page-b']),
        );
        expect(side.favorites, unorderedEquals(['page-a', 'page-b']));
        expect(saves, isEmpty);
        expect(errors, isEmpty);
      });

      test('the quick note: one head, its window still shut', () async {
        final base = await splitQuickNote();
        final side = host();
        await side.load();
        expect(await repository.heads(base.entityId), hasLength(1));
        expect(side.quickNote.open.value, isFalse);
      });

      test('a recording deleted on one device and renamed on the other '
          'stays deleted, in one head', () async {
        final base = await splitRecording();
        final side = host();
        await side.load();
        final heads = await repository.heads(base.entityId);
        expect(heads, hasLength(1));
        expect((await marker(heads.single))['deleted'], isTrue);
        expect(side.audio.rows, isEmpty);
      });

      test('a recording renamed on two devices keeps one name', () async {
        final entry = await recording();
        for (final name in ['A', 'B']) {
          await branch(entry.record, {
            'recording.json': text('{"schemaVersion": 1, "name": "$name"}'),
            'audio.m4a': Uint8List.fromList([1, 2, 3]),
          });
        }
        // every device keeps the head with the smallest revision id
        final listed = (await store.list(
          noteId,
          NoteSideKind.recording,
        )).single;
        final name = (await marker(
          listed.heads.singleWhere((h) => h.revisionId == listed.revisionId),
        ))['name'];
        final side = host();
        await side.load();
        final heads = await repository.heads(entry.entityId);
        expect(heads, hasLength(1));
        expect((await marker(heads.single))['name'], name);
        expect(await repository.readRevisionFile(heads.single, 'audio.m4a'), [
          1,
          2,
          3,
        ]);
        expect(side.audio.rows.single.title, name);
      });

      test('a read-only note is not written to', () async {
        final splits = [
          await splitMarks(),
          await splitQuickNote(),
          await splitRecording(),
        ];
        final side = host(noteWritable: () async => false);
        await side.load();
        for (final split in splits) {
          expect(await repository.heads(split.entityId), hasLength(2));
        }
      });

      // Opening the note goes on when the quick notes cannot be listed: the
      // failure is only logged, as for the other two (final fix 2, Minor 1).
      test('a quick note list that fails is only logged', () async {
        final base = await splitMarks();
        final failing = _QuickNoteListFails(repository);
        final errors = <Object>[];
        final side = host(
          binding: (store: failing, noteId: noteId),
          errors: errors,
        );
        await side.load();
        expect(failing.tries, 1);
        expect(await repository.heads(base.entityId), hasLength(1));
        expect(errors, isEmpty);
      });
    });

    test('no vault, or a format 1 vault: no favourites', () async {
      final none = host(noBinding: true);
      await none.load();
      expect(none.favoritesAvailable, isFalse);

      final old = await NoteRepository.open(Directory('${temp.path}/old'));
      try {
        final oldSide = host(
          binding: (store: NoteSideStore(old), noteId: noteId),
        );
        await oldSide.load();
        expect(oldSide.favoritesAvailable, isFalse);
        expect(await old.revisions(), isEmpty);
      } finally {
        await old.close().timeout(const Duration(seconds: 30));
      }
    });
  });

  group('the editor', () {
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
      );
      stows.lastTool.value = ToolId.fountainPen;
      stows.lastPenFamily.value = ToolId.fountainPen;
      stows.editorToolbarTools.value = const [];
      stows.pageToolbarLayout.value = const [];
      stows.editorGestureMode.value = false;
      addTearDown(() {
        stows.lastTool.value = saved.$1;
        stows.lastPenFamily.value = saved.$2;
        stows.editorToolbarTools.value = saved.$3;
        stows.pageToolbarLayout.value = saved.$4;
      });
    });

    /// Lets the vault's file work run between frames.
    Future<void> drain(WidgetTester tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 12; i++) {
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
      });
      await tester.pump(const Duration(milliseconds: 350));
    }

    /// Runs [work] (the vault's file work) while frames go on: awaiting the
    /// vault inside `runAsync` stalls once the fake time has used it.
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

    Future<EditorState> mountEditor(
      WidgetTester tester, {
      Size size = const Size(1000, 1400),
      String path = '/editor-side',
      EditorChromeController? chrome,
      Future<EditorCoreInfo> Function()? load,
      Future<void> Function(EditorCoreInfo, int)? save,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: TranslationProvider(
            child: MaterialApp(
              localizationsDelegates: const [
                FlutterQuillLocalizations.delegate,
              ],
              home: Editor(
                path: path,
                loadSnapshot: load,
                onSaveSnapshot: save ?? (_, _) async {},
                chrome: chrome,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.state<EditorState>(find.byType(Editor));
    }

    /// A vault of [format] with one note, opened outside the fake time.
    Future<(NoteRepository, String, Directory)> openVault(
      WidgetTester tester, {
      int format = 2,
    }) async {
      final made = await tester.runAsync(() async {
        final temp = await Directory.systemTemp.createTemp('piv-side-ed-');
        final repository = await NoteRepository.open(
          Directory('${temp.path}/vault'),
          createFormatVersion: format,
        );
        final id = format >= 2
            ? (await WorkspaceStore(repository).create('Side')).id
            : newId();
        return (repository, id, temp);
      });
      addTearDown(
        () => settle(tester, () async {
          await made!.$1.close().timeout(const Duration(seconds: 10));
          await made.$3.delete(recursive: true);
        }),
      );
      return made!;
    }

    final panel = find.byKey(const ValueKey('kit-side-panel'));
    Finder tab(KitSideTab t) => find.byKey(ValueKey('kit-side-tab-${t.name}'));

    testWidgets(
      'a new note is saved before its first favourite: same page id',
      (tester) async {
        final (repository, noteId, _) = await openVault(tester);
        final store = NoteSideStore(repository);
        final chrome = EditorChromeController()
          ..noteSide = () => (store: store, noteId: noteId);
        addTearDown(chrome.dispose);
        final saves = <Uint8List>[];
        final editor = await mountEditor(
          tester,
          chrome: chrome,
          // never saved: its page gets a new id every time it is read
          load: () async =>
              EditorCoreInfo(filePath: '/editor-side')..pages.add(EditorPage()),
          save: (core, page) async =>
              saves.add(core.saveToBinary(currentPageIndex: page).$1),
        );
        await drain(tester);
        final pageId = editor.coreInfo.pages.first.pageId;
        expect(saves, isEmpty);
        expect(
          chrome.actions.lookup(AppActionIds.pageBookmark)!.checked,
          isFalse,
        );

        chrome.actions.run(
          AppActionIds.pageBookmark,
          tester.element(find.byType(Editor)),
        );
        var stored = <String>[];
        for (var i = 0; i < 20 && stored.isEmpty; i++) {
          await drain(tester);
          stored = await settle(tester, () => storedFavorites(store, noteId));
        }
        expect(stored, [pageId]);
        expect(saves, hasLength(1), reason: 'saved before the write');
        final reopened = (await tester.runAsync(
          () => EditorCoreInfo.loadFromFileContents(
            bsonBytes: saves.single,
            path: '/editor-side',
            onlyFirstPage: false,
          ),
        ))!;
        expect(reopened.pages.first.pageId, pageId);
        expect(
          chrome.actions.lookup(AppActionIds.pageBookmark)!.checked,
          isTrue,
        );

        // the favourite shows on the page in the pages tab and in its own tab
        chrome.actions.run(
          AppActionIds.pageList,
          tester.element(find.byType(Editor)),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('kit-side-page-0-ribbon')),
          findsOneWidget,
        );
        await tester.tap(tab(KitSideTab.favorites));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('kit-side-page-0')), findsOneWidget);

        // taking it off again needs no second save
        chrome.actions.run(
          AppActionIds.pageBookmark,
          tester.element(find.byType(Editor)),
        );
        for (var i = 0; i < 20 && stored.isNotEmpty; i++) {
          await drain(tester);
          stored = await settle(tester, () => storedFavorites(store, noteId));
        }
        expect(stored, isEmpty);
        expect(saves, hasLength(1));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('kit-side-page-0')), findsNothing);
        expect(find.text(keepWordsOf(KitSideTab.favorites)), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await drain(tester);
      },
    );

    testWidgets('without a vault or in a format 1 vault the favourites hide', (
      tester,
    ) async {
      for (final format in [0, 1, 2]) {
        EditorChromeController? chrome;
        if (format > 0) {
          final (repository, noteId, _) = await openVault(
            tester,
            format: format,
          );
          final store = NoteSideStore(repository);
          chrome = EditorChromeController()
            ..noteSide = () => (store: store, noteId: noteId);
          addTearDown(chrome.dispose);
        }
        final editor = await mountEditor(tester, chrome: chrome);
        await drain(tester);
        final shown = format == 2;
        expect(
          editor.actions.has(AppActionIds.pageBookmark),
          shown,
          reason: 'format $format',
        );
        // the user's own outline is a page mark too
        expect(
          editor.actions.has(AppActionIds.outlineAdd),
          shown,
          reason: 'format $format',
        );
        editor.actions.run(
          AppActionIds.pageList,
          tester.element(find.byType(Editor)),
        );
        await tester.pumpAndSettle();
        expect(panel, findsOneWidget);
        expect(
          tab(KitSideTab.favorites),
          shown ? findsOneWidget : findsNothing,
          reason: 'format $format',
        );
        expect(tab(KitSideTab.pages), findsOneWidget);
        // not a PDF: without its own outline there is nothing to show
        expect(
          tab(KitSideTab.outline),
          shown ? findsOneWidget : findsNothing,
          reason: 'format $format',
        );
        // recordings are note attachments too (design: no vault, no audio)
        expect(
          tab(KitSideTab.audio),
          shown ? findsOneWidget : findsNothing,
          reason: 'format $format',
        );
        await tester.pumpWidget(const SizedBox());
        await drain(tester);
      }
    });

    testWidgets('on a phone a page press goes there and closes the panel', (
      tester,
    ) async {
      for (final phone in [true, false]) {
        final editor = await mountEditor(
          tester,
          size: phone ? const Size(360, 700) : const Size(1000, 1400),
          path: '/editor-side-phone',
        );
        editor.createPage(2);
        // ignore: invalid_use_of_protected_member
        editor.setState(() {});
        await tester.pumpAndSettle();
        expect(editor.coreInfo.pages.length, greaterThanOrEqualTo(3));
        // a page that is not the one on screen
        final target = editor.currentPageIndex == 2 ? 0 : 2;

        await tester.tap(find.byKey(const ValueKey('editor-page-list')));
        await tester.pumpAndSettle();
        expect(panel, findsOneWidget);
        expect(
          tester.getSize(panel).width,
          phone ? 360 : 272,
          reason: phone ? 'phone' : 'tablet',
        );
        await tester.tap(find.byKey(ValueKey('kit-side-page-$target')));
        await tester.pumpAndSettle();
        expect(editor.currentPageIndex, target);
        expect(panel, phone ? findsNothing : findsOneWidget);
        editor.cancelAutosaveAndMarkSaved();
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('opening and closing the panel does not repaint the page', (
      tester,
    ) async {
      final (repository, noteId, _) = await openVault(tester);
      final store = NoteSideStore(repository);
      final chrome = EditorChromeController()
        ..noteSide = () => (store: store, noteId: noteId);
      addTearDown(chrome.dispose);
      final editor = await mountEditor(
        tester,
        path: '/editor-side-paint',
        chrome: chrome,
      );
      await drain(tester);
      final page =
          editor.coreInfo.pages.first.innerCanvasKey.currentContext!
                  .findRenderObject()!
              as RenderRepaintBoundary;
      final before = paintCounts(page);
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      await tester.tap(tab(KitSideTab.outline));
      await tester.pumpAndSettle();
      expect(find.text(keepWordsOf(KitSideTab.outline)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expectNotPainted(page, before);
      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    });

    /// The editor with [count] pages (empty, as a new note's), the left panel
    /// open on its pages tab. Each test gives its own [path].
    Future<EditorState> mountPanel(
      WidgetTester tester, {
      required String path,
      int count = 3,
      Size size = const Size(1000, 1400),
      EditorChromeController? chrome,
      Future<EditorCoreInfo> Function()? load,
    }) async {
      final editor = await mountEditor(
        tester,
        size: size,
        path: path,
        chrome: chrome,
        load: load,
      );
      await drain(tester);
      if (load == null) {
        editor.createPage(count - 1);
        // ignore: invalid_use_of_protected_member
        editor.setState(() {});
      }
      await tester.pumpAndSettle();
      // a note keeps an empty page at its end besides
      expect(editor.coreInfo.pages.length, greaterThanOrEqualTo(count));
      if (editor.coreInfo.readOnly) {
        // the toolbar is folded away on a read-only note
        editor.side.panelOpen.value = true;
      } else {
        await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      }
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      return editor;
    }

    void strokeOn(EditorState editor, int i) {
      final page = editor.coreInfo.pages[i];
      page.insertStroke(
        Stroke(
          color: const Color(0xFF1E88E5),
          pressureEnabled: false,
          options: StrokeOptions(size: 10),
          pageIndex: i,
          page: page,
          toolId: ToolId.ballpointPen,
        )..addPoints([for (var x = 0.0; x < 5; x++) Offset(100 + x, 300)]),
      );
    }

    List<String> ids(EditorState editor) => [
      for (final page in editor.coreInfo.pages) page.pageId,
    ];

    Finder dots(int i) => find.byKey(ValueKey('kit-side-page-$i-menu'));
    Finder menuItem(String label) =>
        find.byKey(ValueKey('kit-page-menu-$label'));

    Future<void> pickFromMenu(WidgetTester tester, int i, String label) async {
      await tester.tap(dots(i));
      await tester.pumpAndSettle();
      await tester.tap(menuItem(label));
      await tester.pumpAndSettle();
    }

    /// [i]'s thumbnail held past the long-press time, taken over thumbnail
    /// [to] and let go.
    Future<void> dragThumb(WidgetTester tester, int i, int to) async {
      final picture = find.byKey(ValueKey('kit-side-page-$i-picture'));
      final gesture = await tester.startGesture(tester.getCenter(picture));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(
        tester.getCenter(find.byKey(ValueKey('kit-side-page-$to-picture'))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    /// A page of another note with one stroke, as the page clipboard holds it.
    Future<PageClip> otherNotesClip(WidgetTester tester) async {
      final other = EditorCoreInfo(filePath: '/page-menu-other')
        ..pages.add(EditorPage());
      final page = other.pages.first;
      page.insertStroke(
        Stroke(
          color: const Color(0xFFE53935),
          pressureEnabled: false,
          options: StrokeOptions(size: 10),
          pageIndex: 0,
          page: page,
          toolId: ToolId.ballpointPen,
        )..addPoints([for (var x = 0.0; x < 5; x++) Offset(50 + x, 60)]),
      );
      return (await tester.runAsync(
        () => clipPage(
          page,
          notePattern: other.backgroundPattern,
          assetCache: other.assetCache,
        ),
      ))!;
    }

    Future<void> endTest(WidgetTester tester, EditorState editor) async {
      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    }

    setUp(() => PageClipboard.current.value = null);
    tearDown(() => PageClipboard.current.value = null);

    testWidgets(
      'dots → 붙여넣기 after copying from another note puts the page after '
      'that thumbnail',
      (tester) async {
        final editor = await mountPanel(tester, path: '/page-menu-paste');
        PageClipboard.current.value = await otherNotesClip(tester);
        final before = ids(editor);

        await pickFromMenu(tester, 0, '붙여넣기');

        expect(editor.coreInfo.pages, hasLength(before.length + 1));
        expect(editor.coreInfo.pages[1].strokes, hasLength(1));
        expect(editor.coreInfo.pages[1].pageId, isNot(before[1]));
        expect(
          [ids(editor)[0], ...ids(editor).skip(2)],
          before,
          reason: 'the others keep their order around it',
        );
        expect(find.text('쪽을 붙여넣었습니다'), findsOneWidget);
        // pasting after the last thumbnail goes to the end
        final last = editor.coreInfo.pages.length - 1;
        await pickFromMenu(tester, last, '붙여넣기');
        expect(editor.coreInfo.pages, hasLength(before.length + 2));
        expect(editor.coreInfo.pages[last + 1].strokes, hasLength(1));
        await endTest(tester, editor);
      },
    );

    testWidgets('dots → 쪽 비우기 asks for confirmation first', (tester) async {
      final editor = await mountPanel(tester, path: '/page-menu-clear');
      strokeOn(editor, 0);
      expect(editor.coreInfo.pages[0].strokes, hasLength(1));

      await pickFromMenu(tester, 0, '쪽 비우기');
      final confirm = find.byKey(const ValueKey('eraser-clear-page-confirm'));
      expect(confirm, findsOneWidget);
      expect(editor.coreInfo.pages[0].strokes, hasLength(1));

      await tester.tap(find.byKey(const ValueKey('eraser-clear-page-cancel')));
      await tester.pumpAndSettle();
      expect(editor.coreInfo.pages[0].strokes, hasLength(1), reason: 'cancel');

      await pickFromMenu(tester, 0, '쪽 비우기');
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(editor.coreInfo.pages[0].strokes, isEmpty);
      await endTest(tester, editor);
    });

    testWidgets('dots → 쪽 삭제 shows 쪽을 삭제했습니다 with 되돌리기, which restores the '
        'page', (tester) async {
      final editor = await mountPanel(tester, path: '/page-menu-delete');
      strokeOn(editor, 1);
      final before = ids(editor);

      await pickFromMenu(tester, 1, '쪽 삭제');

      expect(
        find.byKey(const ValueKey('eraser-clear-page-confirm')),
        findsNothing,
        reason: 'no confirm window',
      );
      expect(ids(editor), [...before]..removeAt(1));
      final notice = editor.side.notice.notice;
      expect(notice?.text, '쪽을 삭제했습니다');
      expect(notice?.action, '되돌리기');
      expect(find.text('쪽을 삭제했습니다'), findsOneWidget);

      await tester.tap(find.text('되돌리기'));
      await tester.pumpAndSettle();
      expect(ids(editor), before);
      expect(editor.coreInfo.pages[1].strokes, hasLength(1));
      await endTest(tester, editor);
    });

    testWidgets('deleting or cutting a filled last page shows its notice with '
        '되돌리기', (tester) async {
      final editor = await mountPanel(tester, path: '/page-menu-last-page');
      PageClipboard.current.value = await otherNotesClip(tester);
      // pasted after the spare empty page, the pasted page is the last one
      await pickFromMenu(tester, editor.coreInfo.pages.length - 1, '붙여넣기');
      final last = editor.coreInfo.pages.length - 1;
      final pasted = editor.coreInfo.pages[last];
      expect(pasted.strokes, hasLength(1));
      final before = ids(editor);

      await pickFromMenu(tester, last, '쪽 삭제');
      expect(editor.coreInfo.pages, isNot(contains(pasted)));
      expect(editor.side.notice.notice?.text, '쪽을 삭제했습니다');
      expect(editor.side.notice.notice?.action, '되돌리기');
      await tester.tap(find.text('되돌리기'));
      await tester.pumpAndSettle();
      expect(ids(editor).take(before.length), before);

      await pickFromMenu(tester, last, '잘라내기');
      await drain(tester);
      expect(editor.coreInfo.pages, isNot(contains(pasted)));
      expect(editor.side.notice.notice?.text, '쪽을 잘라냈습니다');
      expect(editor.side.notice.notice?.action, '되돌리기');
      await tester.tap(find.text('되돌리기'));
      await tester.pumpAndSettle();
      expect(editor.coreInfo.pages[last], same(pasted));
      await endTest(tester, editor);
    });

    testWidgets('a cut whose page went while it was being copied says the '
        'page was copied', (tester) async {
      final editor = await mountPanel(tester, path: '/page-menu-cut-gone');
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('piv-cut-gone-'),
      ))!;
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File('${temp.path}/photo.png')
        ..writeAsBytesSync(_onePixelPng);
      final page = editor.coreInfo.pages[1];
      strokeOn(editor, 1);
      // the copy reads this picture's file, which takes real time
      page.images.add(
        PngEditorImage(
          id: editor.coreInfo.nextImageId++,
          assetCache: editor.coreInfo.assetCache,
          extension: '.png',
          imageProvider: FileImage(file),
          pageIndex: 1,
          pageSize: page.size,
          onMoveImage: null,
          onDeleteImage: null,
          onMiscChange: null,
          newImage: false,
          dstRect: const Rect.fromLTWH(10, 20, 30, 40),
        ),
      );

      await pickFromMenu(tester, 1, '잘라내기');
      expect(PageClipboard.current.value, isNull, reason: 'still copying');
      editor.deletePageAt(1);
      final after = ids(editor);
      await drain(tester);

      expect(PageClipboard.current.value, isNotNull);
      expect(ids(editor), after, reason: 'nothing else was taken out');
      expect(editor.side.notice.notice?.text, '쪽을 복사했습니다');
      expect(editor.side.notice.notice?.onAction, isNull);
      await endTest(tester, editor);
      // the picture lets its image go 5 s after it leaves the screen
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('a cut overtaken by a later copy keeps its page', (
      tester,
    ) async {
      final editor = await mountPanel(tester, path: '/page-menu-cut-overtaken');
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('piv-cut-overtaken-'),
      ))!;
      addTearDown(() => temp.deleteSync(recursive: true));
      final file = File('${temp.path}/photo.png')
        ..writeAsBytesSync(_onePixelPng);
      final page = editor.coreInfo.pages[1];
      strokeOn(editor, 0);
      // the copy reads this picture's file, which takes real time
      page.images.add(
        PngEditorImage(
          id: editor.coreInfo.nextImageId++,
          assetCache: editor.coreInfo.assetCache,
          extension: '.png',
          imageProvider: FileImage(file),
          pageIndex: 1,
          pageSize: page.size,
          onMoveImage: null,
          onDeleteImage: null,
          onMiscChange: null,
          newImage: false,
          dstRect: const Rect.fromLTWH(10, 20, 30, 40),
        ),
      );
      final before = ids(editor);

      await pickFromMenu(tester, 1, '잘라내기');
      await pickFromMenu(tester, 0, '복사');
      final copied = PageClipboard.current.value;
      expect(copied, isNotNull, reason: 'page 1 has no file to wait for');
      final told = editor.side.notice.notice;
      expect(told?.text, '쪽을 복사했습니다');
      await drain(tester);

      expect(PageClipboard.current.value, same(copied));
      expect(ids(editor), before, reason: 'its copy was not kept');
      expect(editor.side.notice.notice, same(told), reason: 'the cut is quiet');
      await endTest(tester, editor);
      // the picture lets its image go 5 s after it leaves the screen
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('copy, cut and paste show their messages', (tester) async {
      final editor = await mountPanel(tester, path: '/page-menu-messages');
      strokeOn(editor, 1);
      final before = ids(editor);

      await tester.tap(dots(1));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('복사'));
      await tester.pumpAndSettle();
      await drain(tester);
      expect(editor.side.notice.notice?.text, '쪽을 복사했습니다');
      expect(editor.side.notice.notice?.onAction, isNull);
      expect(PageClipboard.current.value, isNotNull);
      expect(ids(editor), before, reason: 'copying leaves the note as it is');

      await pickFromMenu(tester, 1, '잘라내기');
      await drain(tester);
      expect(editor.side.notice.notice?.text, '쪽을 잘라냈습니다');
      expect(editor.side.notice.notice?.action, '되돌리기');
      expect(ids(editor), [...before]..removeAt(1));
      // one step brings it back; the copy is kept for pasting
      await tester.tap(find.text('되돌리기'));
      await tester.pumpAndSettle();
      expect(ids(editor), before);
      expect(PageClipboard.current.value, isNotNull);

      await pickFromMenu(tester, 0, '붙여넣기');
      expect(editor.side.notice.notice?.text, '쪽을 붙여넣었습니다');
      expect(editor.side.notice.notice?.onAction, isNull);
      expect(editor.coreInfo.pages, hasLength(before.length + 1));
      await endTest(tester, editor);
    });

    testWidgets('dragging a favourite keeps it favourite by page id', (
      tester,
    ) async {
      final (repository, noteId, _) = await openVault(tester);
      final store = NoteSideStore(repository);
      final chrome = EditorChromeController()
        ..noteSide = () => (store: store, noteId: noteId);
      addTearDown(chrome.dispose);
      final editor = await mountPanel(
        tester,
        path: '/page-menu-favourite',
        chrome: chrome,
        load: () async =>
            EditorCoreInfo(filePath: '/page-menu-favourite')
              ..pages.addAll([EditorPage(), EditorPage(), EditorPage()]),
      );
      await drain(tester);
      final before = ids(editor);

      await tester.tap(
        find.byKey(const ValueKey('kit-side-page-0-favorite-button')),
      );
      await tester.pumpAndSettle();
      var stored = <String>[];
      for (var i = 0; i < 20 && stored.isEmpty; i++) {
        await drain(tester);
        stored = await settle(tester, () => storedFavorites(store, noteId));
      }
      expect(stored, [before[0]]);

      await dragThumb(tester, 0, 2);

      expect(ids(editor), [before[1], before[2], before[0], ...before.skip(3)]);
      expect(editor.side.favorites, [before[0]]);
      bool filled(int i) => find
          .descendant(
            of: find.byKey(ValueKey('kit-side-page-$i-ribbon')),
            matching: find.byType(ColoredBox),
          )
          .evaluate()
          .isNotEmpty;
      expect(
        [for (var i = 0; i < before.length; i++) filled(i)],
        [false, false, true, ...List.filled(before.length - 3, false)],
      );
      for (var i = 0; i < 20; i++) {
        await drain(tester);
      }
      expect(await settle(tester, () => storedFavorites(store, noteId)), [
        before[0],
      ]);

      // the favourites tab: the ribbon and the dots, no dragging
      KitSidePages pages() =>
          tester.widget<KitSidePages>(find.byType(KitSidePages));
      expect(pages().onMove, isNotNull);
      await tester.tap(tab(KitSideTab.favorites));
      await tester.pumpAndSettle();
      expect(pages().onMove, isNull);
      expect(pages().onFavorite, isNotNull);
      expect(pages().onMenu, isNotNull);
      expect(pages().showRibbon, isTrue);
      expect(find.byType(LongPressDraggable<int>), findsNothing);
      // the page number in the menu is the note's, not its place in the tab
      await tester.tap(dots(2));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('앞에 쪽 추가'));
      await tester.pumpAndSettle();
      expect(editor.coreInfo.pages, hasLength(before.length + 1));
      expect(editor.coreInfo.pages[2].pageId, isNot(before[0]));
      expect(editor.coreInfo.pages[3].pageId, before[0]);
      await endTest(tester, editor);
    });

    testWidgets('a long press no longer opens the old page manager', (
      tester,
    ) async {
      final editor = await mountPanel(tester, path: '/page-menu-long-press');
      for (final locked in [false, true]) {
        editor.inkLocked.value = locked;
        await tester.pump();
        final thumb = find.byKey(const ValueKey('kit-side-page-1'));
        final gesture = await tester.startGesture(tester.getCenter(thumb));
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        expect(find.byType(AdaptiveAlertDialog), findsNothing);
        expect(find.text('쪽 관리'), findsNothing);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(AdaptiveAlertDialog), findsNothing);
      }
      await endTest(tester, editor);
    });

    for (final readOnly in [false, true])
      testWidgets(
        readOnly
            ? 'read-only note: no drag, menu shows copy only, ribbon not '
                  'tappable'
            : 'locked note: no drag, menu shows copy only, ribbon not tappable',
        (tester) async {
          final (repository, noteId, _) = await openVault(tester);
          final store = NoteSideStore(repository);
          final chrome = EditorChromeController()
            ..noteSide = () => (store: store, noteId: noteId);
          addTearDown(chrome.dispose);
          final editor = await mountPanel(
            tester,
            path: '/page-menu-locked-$readOnly',
            chrome: chrome,
            load: () async => EditorCoreInfo(
              filePath: '/page-menu-locked-$readOnly',
              readOnlyReason: readOnly ? ReadOnlyReason.versionTooNew : null,
            )..pages.addAll([EditorPage(), EditorPage(), EditorPage()]),
          );
          await drain(tester);
          KitSidePages pages() =>
              tester.widget<KitSidePages>(find.byType(KitSidePages));
          if (!readOnly) {
            expect(pages().onMove, isNotNull, reason: 'a note that may change');
            expect(
              find.byKey(const ValueKey('kit-side-page-0-favorite-button')),
              findsOneWidget,
            );
            editor.inkLocked.value = true;
          }
          await tester.pump();
          await tester.pumpAndSettle();
          final before = ids(editor);
          expect(pages().onMove, isNull);
          await dragThumb(tester, 0, 2);
          expect(ids(editor), before, reason: 'nothing dragged');

          // the ribbon is drawn but is not a button
          expect(
            find.byKey(const ValueKey('kit-side-page-0-ribbon')),
            findsOneWidget,
          );
          expect(pages().onFavorite, isNull);
          expect(
            find.byKey(const ValueKey('kit-side-page-0-favorite-button')),
            findsNothing,
          );
          await tester.tapAt(
            tester
                    .getRect(
                      find.byKey(const ValueKey('kit-side-page-0-picture')),
                    )
                    .topRight +
                const Offset(-10, 10),
          );
          await tester.pumpAndSettle();
          expect(editor.side.favorites, isEmpty);

          // the menu: only 복사 does anything
          await tester.tap(dots(1));
          await tester.pumpAndSettle();
          for (final label in [
            '앞에 쪽 추가',
            '뒤에 쪽 추가',
            '복제',
            '잘라내기',
            '붙여넣기',
            '쪽 비우기',
            '쪽 삭제',
          ]) {
            await tester.tap(menuItem(label));
            await tester.pumpAndSettle();
            expect(menuItem(label), findsOneWidget, reason: '$label is off');
          }
          expect(ids(editor), before);
          await tester.tap(menuItem('복사'));
          await tester.pumpAndSettle();
          await drain(tester);
          expect(menuItem('복사'), findsNothing);
          expect(PageClipboard.current.value, isNotNull);
          expect(editor.side.notice.notice?.text, '쪽을 복사했습니다');
          expect(ids(editor), before);
          await endTest(tester, editor);
        },
      );

    testWidgets(
      'read-only note: a tap on a thumbnail still goes to that page',
      (tester) async {
        final editor = await mountPanel(
          tester,
          path: '/page-menu-read-only-tap',
          load: () async => EditorCoreInfo(
            filePath: '/page-menu-read-only-tap',
            readOnlyReason: ReadOnlyReason.versionTooNew,
          )..pages.addAll([EditorPage(), EditorPage(), EditorPage()]),
        );
        final before = ids(editor);
        expect(editor.currentPageIndex, 0);

        await tester.tap(find.byKey(const ValueKey('kit-side-page-2')));
        await tester.pumpAndSettle();

        expect(editor.currentPageIndex, 2);
        expect(ids(editor), before, reason: 'going there changes no page');
        await endTest(tester, editor);
      },
    );

    testWidgets('no ribbon outline when favourites are unavailable', (
      tester,
    ) async {
      final editor = await mountPanel(tester, path: '/page-menu-no-vault');
      expect(editor.side.favoritesAvailable, isFalse);
      final pages = tester.widget<KitSidePages>(find.byType(KitSidePages));
      expect(pages.showRibbon, isFalse);
      expect(pages.onFavorite, isNull);
      for (var i = 0; i < 3; i++) {
        expect(
          find.byKey(ValueKey('kit-side-page-$i-ribbon')),
          findsNothing,
          reason: 'page $i',
        );
      }
      // the dots and the drag are there all the same
      expect(dots(0), findsOneWidget);
      expect(pages.onMove, isNotNull);
      await endTest(tester, editor);
    });

    testWidgets(
      'dragging, dropping and opening the menu do not repaint the page canvas',
      (tester) async {
        final editor = await mountPanel(tester, path: '/page-menu-paint');
        final page =
            editor.coreInfo.pages.first.innerCanvasKey.currentContext!
                    .findRenderObject()!
                as RenderRepaintBoundary;
        final before = paintCounts(page);
        final pageIds = ids(editor);

        // a page lifted, taken over another and let go outside the grid
        final picture = find.byKey(const ValueKey('kit-side-page-0-picture'));
        final gesture = await tester.startGesture(tester.getCenter(picture));
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
        await gesture.moveTo(
          tester.getCenter(
            find.byKey(const ValueKey('kit-side-page-2-picture')),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.moveTo(const Offset(700, 400));
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(ids(editor), pageIds, reason: 'nothing was dropped on a page');
        expectNotPainted(page, before);

        // the menu opened and closed again
        await tester.tap(dots(1));
        await tester.pumpAndSettle();
        expect(menuItem('복사'), findsOneWidget);
        await tester.tapAt(const Offset(700, 400));
        await tester.pumpAndSettle();
        expect(menuItem('복사'), findsNothing);
        expectNotPainted(page, before);

        // a real drop reorders the note, which paints its pages again (the
        // editor builds with the new order), so only the order is checked
        final beforeIds = ids(editor);
        await dragThumb(tester, 1, 2);
        expect(ids(editor), [
          beforeIds[0],
          beforeIds[2],
          beforeIds[1],
          ...beforeIds.skip(3),
        ]);
        await endTest(tester, editor);
      },
    );

    testWidgets('a drop reorders the note at once, before any frame', (
      tester,
    ) async {
      final editor = await mountPanel(tester, path: '/page-menu-sync');
      final before = ids(editor);
      final picture = find.byKey(const ValueKey('kit-side-page-0-picture'));
      final gesture = await tester.startGesture(tester.getCenter(picture));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('kit-side-page-2-picture'))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(ids(editor), before, reason: 'only hovering');

      // the lift is dispatched as the call is made, so look before awaiting
      // it (an await would run a waiting microtask first)
      final lifted = gesture.up();
      expectSync(ids(editor), [
        before[1],
        before[2],
        before[0],
        ...before.skip(3),
      ]);
      await lifted;
      await tester.pumpAndSettle();
      await endTest(tester, editor);
    });

    testWidgets('a page that cannot be copied says nothing and is logged', (
      tester,
    ) async {
      final editor = await mountPanel(tester, path: '/page-menu-copy-fails');
      final broken = _BrokenPage();
      editor.coreInfo.pages[1] = broken;
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pumpAndSettle();
      final records = <LogRecord>[];
      final listen = Logger.root.onRecord.listen(records.add);
      addTearDown(listen.cancel);

      await tester.tap(dots(1));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('복사'));
      await tester.pumpAndSettle();
      await drain(tester);

      expect(PageClipboard.current.value, isNull);
      expect(editor.side.notice.notice, isNull);
      expect(find.text('쪽을 복사했습니다'), findsNothing);
      expect(
        records.where(
          (r) => r.level >= Level.WARNING && r.message.contains('page 1'),
        ),
        isNotEmpty,
      );
      // cutting it fails the same way and leaves the page where it is
      await pickFromMenu(tester, 1, '잘라내기');
      await drain(tester);
      expect(editor.coreInfo.pages[1], same(broken));
      expect(editor.side.notice.notice, isNull);
      await endTest(tester, editor);
    });

    testWidgets('insert and duplicate go to the new page', (tester) async {
      final editor = await mountPanel(
        tester,
        path: '/page-menu-scroll',
        count: 4,
      );
      expect(editor.currentPageIndex, 0);

      await pickFromMenu(tester, 1, '뒤에 쪽 추가');
      expect(editor.currentPageIndex, 2, reason: 'after page 1');

      await pickFromMenu(tester, 3, '앞에 쪽 추가');
      expect(editor.currentPageIndex, 3, reason: 'before page 3');

      await pickFromMenu(tester, 0, '복제');
      expect(editor.currentPageIndex, 1, reason: 'a copy after page 0');
      await endTest(tester, editor);
    });

    testWidgets('쪽 비우기 is off on a page with nothing on it', (tester) async {
      final editor = await mountPanel(tester, path: '/page-menu-clear-empty');
      strokeOn(editor, 1);
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pumpAndSettle();

      await tester.tap(dots(0));
      await tester.pumpAndSettle();
      await tester.tap(menuItem('쪽 비우기'));
      await tester.pumpAndSettle();
      expect(menuItem('쪽 비우기'), findsOneWidget, reason: 'page 0 is empty');
      expect(
        find.byKey(const ValueKey('eraser-clear-page-confirm')),
        findsNothing,
      );
      await tester.tapAt(const Offset(900, 20));
      await tester.pumpAndSettle();

      await pickFromMenu(tester, 1, '쪽 비우기');
      expect(
        find.byKey(const ValueKey('eraser-clear-page-confirm')),
        findsOneWidget,
        reason: 'page 1 has a stroke',
      );
      await tester.tap(find.byKey(const ValueKey('eraser-clear-page-cancel')));
      await tester.pumpAndSettle();
      await endTest(tester, editor);
    });

    testWidgets('a stroke begun keeps the pictures; saved, they draw again', (
      tester,
    ) async {
      final editor = await mountEditor(tester, path: '/editor-side-stroke');
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      CanvasPreview first() => tester.widget<CanvasPreview>(
        find.descendant(of: panel, matching: find.byType(CanvasPreview)).first,
      );
      // a first stroke, so the next one adds no page (a page count drawn
      // again would hide what is checked here)
      final ink = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await ink.down(const Offset(600, 200));
      await ink.moveTo(const Offset(650, 210));
      await ink.moveTo(const Offset(700, 220));
      await ink.up();
      await tester.pumpAndSettle();
      final pages = editor.coreInfo.pages.length;
      final before = first();
      final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await pen.down(const Offset(600, 300));
      await pen.moveTo(const Offset(650, 310));
      await tester.pump();
      await pen.moveTo(const Offset(700, 320));
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pump();
      expect(first(), same(before), reason: 'nothing saved yet');

      await pen.up();
      await tester.pumpAndSettle();
      expect(editor.coreInfo.pages.first.strokes, hasLength(2));
      expect(editor.coreInfo.pages, hasLength(pages));
      expect(first(), isNot(same(before)), reason: 'the stroke saved');
      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('「개요에 추가」 names the page on screen in the outline tab', (
      tester,
    ) async {
      final (repository, noteId, _) = await openVault(tester);
      final store = NoteSideStore(repository);
      final chrome = EditorChromeController()
        ..noteSide = () => (store: store, noteId: noteId);
      addTearDown(chrome.dispose);
      final editor = await mountEditor(
        tester,
        chrome: chrome,
        path: '/editor-side-outline',
        load: () async =>
            EditorCoreInfo(filePath: '/editor-side-outline')
              ..pages.addAll([EditorPage(), EditorPage(), EditorPage()]),
      );
      await drain(tester);
      final pageId = editor.coreInfo.pages[1].pageId;
      editor.revealPageId(pageId);
      await tester.pump(const Duration(milliseconds: 400));
      expect(editor.currentPageIndex, 1);
      expect(chrome.actions.lookup(AppActionIds.outlineAdd)!.label, '개요에 추가');

      chrome.actions.run(
        AppActionIds.outlineAdd,
        tester.element(find.byType(Editor)),
      );
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(panel, findsOneWidget);
      final rename = find.byKey(const ValueKey('kit-outline-rename'));
      expect(rename, findsOneWidget);
      expect(tester.widget<TextField>(rename).controller!.text, '쪽 2');
      await tester.enterText(rename, '그림 설명');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      var rows = <(String, String)>[];
      for (var i = 0; i < 20 && !rows.contains((pageId, '그림 설명')); i++) {
        await drain(tester);
        rows = await settle(tester, () => storedOutline(store, noteId));
      }
      expect(rows, [(pageId, '그림 설명')]);
      expect(find.text('그림 설명'), findsOneWidget);

      // removed, the undo notice stands over the page area and brings it back
      await tester.tap(find.byKey(const ValueKey('kit-outline-more')));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.text('지우기'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('그림 설명'), findsNothing);
      expect(find.text('지웠습니다 · 그림 설명'), findsOneWidget);
      await tester.tap(find.text('실행 취소'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('그림 설명'), findsOneWidget);
      // the vault closes after the writes the undo queued
      await settle(tester, () => editor.side.idle);
      rows = await settle(tester, () => storedOutline(store, noteId));
      expect(rows, [(pageId, '그림 설명')]);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);

      // a note that may not change takes none
      final locked = await mountEditor(
        tester,
        chrome: chrome,
        path: '/editor-side-outline-locked',
        load: () async => EditorCoreInfo(
          filePath: '/editor-side-outline-locked',
          readOnlyReason: ReadOnlyReason.versionTooNew,
        )..pages.add(EditorPage()),
      );
      await drain(tester);
      expect(locked.coreInfo.readOnly, isTrue);
      expect(chrome.actions.has(AppActionIds.outlineAdd), isFalse);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    });

    testWidgets('a split attachment is joined on open, not in a locked note', (
      tester,
    ) async {
      final (repository, noteId, _) = await openVault(tester);
      final store = NoteSideStore(repository);
      final chrome = EditorChromeController()
        ..noteSide = () => (store: store, noteId: noteId);
      addTearDown(chrome.dispose);
      final at = DateTime.utc(2026, 11, 1);
      final base = await settle(tester, () async {
        final base = await store.write(
          noteId,
          NoteSideKind.pageMarks,
          marksFile(NotePageMarks()),
        );
        for (final page in ['page-a', 'page-b']) {
          await repository.commit(
            entityId: base.entityId,
            kind: EntityKind.attachment,
            ownerNoteId: noteId,
            files: marksFile(NotePageMarks()..addFavorite(page, at: at)),
            parentRevisionIds: [base.revisionId],
          );
        }
        return base;
      });
      Future<int> heads() async =>
          (await settle(tester, () => repository.heads(base.entityId))).length;

      // a note that may not change is not written to
      final locked = await mountEditor(
        tester,
        chrome: chrome,
        path: '/editor-side-join-locked',
        load: () async => EditorCoreInfo(
          filePath: '/editor-side-join-locked',
          readOnlyReason: ReadOnlyReason.versionTooNew,
        )..pages.add(EditorPage()),
      );
      for (var i = 0; i < 20 && !locked.side.isFavorite('page-b'); i++) {
        await drain(tester);
      }
      expect(locked.side.isFavorite('page-b'), isTrue);
      // as long as a join takes in a note that may change (below)
      for (var i = 0; i < 5; i++) {
        await drain(tester);
      }
      await settle(tester, () => locked.side.idle);
      expect(locked.coreInfo.readOnly, isTrue);
      expect(await heads(), 2);
      await tester.pumpWidget(const SizedBox());
      await drain(tester);

      final editor = await mountEditor(
        tester,
        chrome: chrome,
        path: '/editor-side-join',
      );
      var count = 2;
      for (var i = 0; i < 20 && count == 2; i++) {
        await drain(tester);
        count = await heads();
      }
      expect(count, 1);
      await settle(tester, () => editor.side.idle);
      expect(
        await settle(tester, () => storedFavorites(store, noteId)),
        unorderedEquals(['page-a', 'page-b']),
      );
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    });

    testWidgets('back closes the panel first, and the note stays', (
      tester,
    ) async {
      final editor = await mountEditor(
        tester,
        size: const Size(360, 700),
        path: '/editor-side-back',
      );
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(find.byType(Editor), findsOneWidget);

      // a host's back asks the editor the same
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      expect(editor.closeOpenWindow(), isTrue);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(editor.closeOpenWindow(), isFalse);
      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the editor building again does not build the pages again', (
      tester,
    ) async {
      final editor = await mountEditor(tester, path: '/editor-side-thumbs');
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      CanvasPreview first() => tester.widget<CanvasPreview>(
        find.descendant(of: panel, matching: find.byType(CanvasPreview)).first,
      );
      final before = first();
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pump();
      expect(first(), same(before), reason: 'the same picture, not built');

      // a stroke on the page is drawn there too
      final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
      await pen.down(const Offset(600, 300));
      await pen.moveTo(const Offset(650, 310));
      await pen.moveTo(const Offset(700, 320));
      await pen.up();
      await tester.pumpAndSettle();
      expect(editor.coreInfo.pages.first.strokes, hasLength(1));
      expect(first(), isNot(same(before)));
      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a picture moved or the paper changed draws the pages again', (
      tester,
    ) async {
      final editor = await mountEditor(tester, path: '/editor-side-edits');
      final page = editor.coreInfo.pages.first;
      final photo = PngEditorImage(
        id: editor.coreInfo.nextImageId++,
        assetCache: editor.coreInfo.assetCache,
        extension: '.png',
        imageProvider: MemoryImage(_onePixelPng),
        pageIndex: 0,
        pageSize: page.size,
        onMoveImage: null,
        onDeleteImage: null,
        onMiscChange: null,
        newImage: false,
        dstRect: const Rect.fromLTWH(150, 260, 200, 80),
      );
      page.images.add(photo);
      editor.autosaveAfterDelay();
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      CanvasPreview first() => tester.widget<CanvasPreview>(
        find.descendant(of: panel, matching: find.byType(CanvasPreview)).first,
      );

      // moved as the picture's own drag moves it
      var before = first();
      photo.dstRect = photo.dstRect.shift(const Offset(40, 0));
      editor.onMoveImage(photo, const Rect.fromLTRB(40, 0, 40, 0));
      await tester.pump();
      expect(first(), isNot(same(before)), reason: 'moved');

      // the paper's pattern from the bottom sheet
      before = first();
      final sheet = editor.bottomSheet(
        tester.element(find.byType(Editor)),
      ) as EditorBottomSheet;
      sheet.setBackgroundPattern(
        CanvasBackgroundPattern.values.firstWhere(
          (pattern) => pattern != editor.coreInfo.backgroundPattern,
        ),
      );
      await tester.pump();
      expect(first(), isNot(same(before)), reason: 'the paper');

      // and nothing changed: the same picture
      before = first();
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pump();
      expect(first(), same(before));
      editor.cancelAutosaveAndMarkSaved();
      // a picture lets its image go 5 s after it leaves the screen
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('writes waiting when the editor closes still land', (
      tester,
    ) async {
      final (repository, noteId, _) = await openVault(tester);
      final store = NoteSideStore(repository);
      final chrome = EditorChromeController()
        ..noteSide = () => (store: store, noteId: noteId);
      addTearDown(chrome.dispose);
      final gate = Completer<void>();
      var saves = 0;
      final editor = await mountEditor(
        tester,
        chrome: chrome,
        path: '/editor-side-gone',
        load: () async =>
            EditorCoreInfo(filePath: '/editor-side-gone')
              ..pages.addAll([EditorPage(), EditorPage(), EditorPage()]),
        save: (_, _) async {
          saves++;
          await gate.future;
        },
      );
      await drain(tester);
      final ids = [
        for (final i in [0, 2]) editor.coreInfo.pages[i].pageId,
      ];
      final context = tester.element(find.byType(Editor));
      // the first write waits in the note's save
      chrome.actions.run(AppActionIds.pageBookmark, context);
      await tester.pump();
      expect(saves, 1);
      editor.revealPageId(ids.last);
      await tester.pump(const Duration(milliseconds: 400));
      expect(editor.currentPageIndex, 2);
      // the second waits behind it
      chrome.actions.run(AppActionIds.pageBookmark, context);
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      gate.complete();
      var stored = <String>[];
      for (var i = 0; i < 20 && stored.length < 2; i++) {
        await drain(tester);
        stored = await settle(tester, () => storedFavorites(store, noteId));
      }
      expect(stored, unorderedEquals(ids));
      expect(saves, 1, reason: 'the closed editor does not save again');
      expect(tester.takeException(), isNull);
    });
  });
}

/// The empty line of [tab] as it is set (a word joiner between letters).
String keepWordsOf(KitSideTab tab) => keepWords(tab.empty!);

/// A store whose next [list] lets [afterList] run before it answers: what
/// another device writes just after the vault was read.
class _RacingStore extends NoteSideStore {
  new(super.repository);

  Future<Object?> Function()? afterList;

  @override
  Future<List<NoteSideRecord>> list(String noteId, NoteSideKind kind) async {
    final records = await super.list(noteId, kind);
    final hook = afterList;
    afterList = null;
    await hook?.call();
    return records;
  }
}

/// A store that cannot list the quick notes (the disk fails as it is read).
class _QuickNoteListFails extends NoteSideStore {
  new(super.repository);

  var tries = 0;

  @override
  Future<List<NoteSideRecord>> list(String noteId, NoteSideKind kind) {
    if (kind != NoteSideKind.quickNote) return super.list(noteId, kind);
    tries++;
    throw const FileSystemException('read failed');
  }
}

final _onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
]);

/// A page whose copy cannot be made.
class _BrokenPage extends EditorPage {
  new();

  @override
  Map<String, dynamic> toJson(
    OrderedAssetCache assets, {
    required CanvasBackgroundPattern notePattern,
  }) => throw StateError('this page cannot be copied');
}
