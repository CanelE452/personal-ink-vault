import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/canvas_preview.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/toolbar/editor_bottom_sheet.dart';
import 'package:saber/components/toolbar/editor_page_manager.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/audio/recording_entry.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
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

    testWidgets('a long press on a page opens the page manager on it', (
      tester,
    ) async {
      final editor = await mountEditor(
        tester,
        size: const Size(360, 700),
        path: '/editor-side-manage',
      );
      editor.createPage(29);
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pumpAndSettle();
      final count = editor.coreInfo.pages.length;
      expect(count, greaterThanOrEqualTo(30));
      const held = 27;
      final heldId = editor.coreInfo.pages[held].pageId;

      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      final thumb = find.byKey(const ValueKey('kit-side-page-$held'));
      await tester.scrollUntilVisible(
        thumb,
        300,
        scrollable: find
            .descendant(of: panel, matching: find.byType(Scrollable))
            .first,
      );
      await tester.ensureVisible(thumb);
      await tester.pumpAndSettle();
      await tester.longPress(thumb);
      await tester.pumpAndSettle();
      expect(find.byType(EditorPageManager), findsOneWidget);
      // the window opens on that page's row, marked as the page
      final row = find.text('${held + 1} / $count');
      expect(row.hitTestable(), findsOneWidget);
      expect(tester.widget<Text>(row).style?.color, KitTokens.sideThumbOnInk);
      expect(
        tester.widget<Text>(find.text('$held / $count')).style?.color,
        isNot(KitTokens.sideThumbOnInk),
      );
      // a long press is not a page press: the phone's panel stays
      expect(panel, findsOneWidget);

      // deleted from that row: that page is gone
      await tester.tap(
        find.descendant(
          of: find.ancestor(of: row, matching: find.byType(InkWell)).first,
          matching: find.byTooltip(t.editor.menu.deletePage),
        ),
      );
      await tester.pumpAndSettle();
      expect(editor.coreInfo.pages, hasLength(count - 1));
      expect([
        for (final page in editor.coreInfo.pages) page.pageId,
      ], isNot(contains(heldId)));
      Navigator.of(tester.element(find.byType(EditorPageManager))).pop();
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets("the page manager's mark stays on its page after a delete", (
      tester,
    ) async {
      final editor = await mountEditor(tester, path: '/editor-side-mark');
      editor.createPage(2);
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pumpAndSettle();
      final count = editor.coreInfo.pages.length;
      expect(count, greaterThanOrEqualTo(3));
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('kit-side-page-1')));
      await tester.pumpAndSettle();
      Color? ink(String text) =>
          tester.widget<Text>(find.text(text)).style?.color;
      expect(ink('2 / $count'), KitTokens.sideThumbOnInk);

      // the page before it deleted inside the window: the mark moves with it
      await tester.tap(
        find.descendant(
          of: find
              .ancestor(
                of: find.text('1 / $count'),
                matching: find.byType(InkWell),
              )
              .first,
          matching: find.byTooltip(t.editor.menu.deletePage),
        ),
      );
      await tester.pumpAndSettle();
      expect(editor.coreInfo.pages, hasLength(count - 1));
      expect(ink('1 / ${count - 1}'), KitTokens.sideThumbOnInk);
      expect(ink('2 / ${count - 1}'), isNot(KitTokens.sideThumbOnInk));
      Navigator.of(tester.element(find.byType(EditorPageManager))).pop();
      await tester.pumpAndSettle();
      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
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
