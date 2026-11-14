import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/data/vault/workspace_navigation.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'recent document visits stay in their own vault across switches',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'workspace-vault-recents-',
      );
      final firstRoot = Directory('${root.path}/first');
      final secondRoot = Directory('${root.path}/second');
      final c = WorkspaceController(
        await NoteRepository.open(firstRoot, createFormatVersion: 2),
        directoryProvider: () async => Directory('${root.path}/support'),
      );
      try {
        final first = await c.createNote(
          'First',
          documentKind: VaultDocumentKind.markdown,
        );
        expect(c.recentDocumentIds, [first.id]);
        await c.replaceRepository(
          await NoteRepository.open(secondRoot, createFormatVersion: 2),
        );
        expect(c.recentDocumentIds, isEmpty);
        final second = await c.createNote(
          'Second',
          documentKind: VaultDocumentKind.markdown,
        );
        expect(c.recentDocumentIds, [second.id]);
        await c.replaceRepository(await NoteRepository.open(firstRoot));
        expect(c.activeSession!.note.id, first.id);
        expect(c.recentDocumentIds, [first.id]);
        await c.replaceRepository(await NoteRepository.open(secondRoot));
        expect(c.recentDocumentIds, [second.id]);
      } finally {
        await c.flush();
        c.dispose();
        await c.repository.close();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'invalid linked locations cannot replace the active document or history',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'workspace-invalid-link-',
      );
      final c = WorkspaceController(
        await NoteRepository.open(root, createFormatVersion: 2),
      );
      try {
        final current = await c.createNote(
          'Current',
          documentKind: VaultDocumentKind.markdown,
        );
        final target = await c.store.create(
          'Target',
          documentKind: VaultDocumentKind.markdown,
        );
        final session = c.activeSession;
        final before = c.navigation.toJson();
        for (final anchor in ['', 'bad\nanchor', 'x' * 2049]) {
          await expectLater(
            c.openNote(target, markdownView: true, markdownAnchor: anchor),
            throwsFormatException,
          );
          expect(identical(c.activeSession, session), isTrue);
          expect(c.activeSession!.note.id, current.id);
          expect(c.navigation.toJson(), before);
        }
      } finally {
        await c.flush();
        c.dispose();
        await c.repository.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'remembering an unchanged Markdown view retains its exact anchor',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'workspace-anchor-view-',
      );
      final c = WorkspaceController(
        await NoteRepository.open(root, createFormatVersion: 2),
      );
      try {
        final note = await c.createNote(
          'Anchor',
          documentKind: VaultDocumentKind.markdown,
        );
        c.navigation.openDocument(
          note.id,
          note.title,
          markdown: true,
          markdownAnchor: 'Late%20Heading',
        );
        await c.rememberView(markdown: true);
        expect(c.navigation.current.markdownAnchor, 'Late%20Heading');
        final saved = await WorkspaceNavigation.load(
          File('${root.path}/.workspace/navigation.json'),
        );
        expect(saved.current.markdownAnchor, 'Late%20Heading');
      } finally {
        await c.flush();
        c.dispose();
        await c.repository.close();
        await root.delete(recursive: true);
      }
    },
  );
  test('metadata refresh updates every open document tab title', () async {
    final root = await Directory.systemTemp.createTemp(
      'workspace-rename-tabs-',
    );
    final c = WorkspaceController(
      await NoteRepository.open(root, createFormatVersion: 2),
    );
    try {
      final first = await c.createNote(
        'First',
        documentKind: VaultDocumentKind.markdown,
      );
      final second = await c.createNote(
        'Second',
        documentKind: VaultDocumentKind.markdown,
      );
      await c.store.rename(first, 'Renamed first');
      await c.store.rename(second, 'Renamed second');
      await c.refresh();
      expect(c.navigation.tabs.map((t) => t.title), [
        'Renamed first',
        'Renamed second',
      ]);
      expect(c.activeSession!.note.title, 'Renamed second');
    } finally {
      await c.flush();
      c.dispose();
      await c.repository.close();
      await root.delete(recursive: true);
    }
  });
  test('document tabs and history save content before switching and restore locally', () async {
    final root = await Directory.systemTemp.createTemp('workspace-tabs-');
    var c = WorkspaceController(
      await NoteRepository.open(root, createFormatVersion: 2),
    );
    final folder = await c.createFolder('Research');
    await c.openFolder(folder.id);
    final a = await c.createNote('A', documentKind: VaultDocumentKind.markdown);
    c.editMarkdown('Saved A');
    await c.flush();
    final b = await c.createNote('B', documentKind: VaultDocumentKind.markdown);
    expect(c.navigation.tabs.map((t) => t.noteId), [a.id, b.id]);
    expect(c.recentDocumentIds, [b.id, a.id]);
    await c.closeNote(session: c.activeSession!);
    expect(c.navigation.current.folderId, folder.id);
    await c.backInHistory();
    expect(c.activeSession!.note.id, b.id);
    await c.backInHistory();
    expect(c.activeSession!.note.id, a.id);
    expect(c.recentDocumentIds, [a.id, b.id]);
    expect(c.markdown, 'Saved A');
    await c.forwardInHistory();
    expect(c.activeSession!.note.id, b.id);
    expect(c.recentDocumentIds, [b.id, a.id]);
    await c.closeDocumentTab(b.id);
    expect(c.activeSession!.note.id, a.id);
    expect(c.navigation.tabs.single.noteId, a.id);
    await c.flush();
    c.dispose();
    await c.repository.close();
    c = await WorkspaceController.openLibrary(root);
    expect(c.activeSession!.note.id, a.id);
    expect(c.recentDocumentIds, [a.id, b.id]);
    expect(c.markdown, 'Saved A');
    expect(c.navigation.tabs.single.noteId, a.id);
    await c.flush();
    c.dispose();
    await c.repository.close();
    await root.delete(recursive: true);
  });

  test(
    'tab activation and close replacement restore the saved document view',
    () async {
      final root = await Directory.systemTemp.createTemp('workspace-tab-view-');
      var c = WorkspaceController(
        await NoteRepository.open(root, createFormatVersion: 2),
      );
      try {
        final first = await c.store.create('First');
        await c.openNote(first);
        final page = newId();
        await c.rememberView(markdown: false, pageId: page);
        final second = await c.createNote(
          'Second',
          documentKind: VaultDocumentKind.infinite,
        );
        const view = InfiniteViewport(offset: Offset(-185, 64), scale: 1.5);
        await c.rememberInfiniteView(second.id, view);
        await c.rememberView(markdown: true, markdownAnchor: 'Second heading');
        c.setInkBusy(true);
        await expectLater(c.activateDocumentTab(first.id), throwsStateError);
        expect(c.activeSession!.note.id, second.id);
        expect(c.recentDocumentIds, [second.id, first.id]);
        expect(c.navigation.current.markdownAnchor, 'Second heading');
        c.setInkBusy(false);
        c.editMarkdown('Second contents');
        await c.activateDocumentTab(first.id);
        expect(c.activeSession!.note.id, first.id);
        expect(c.recentDocumentIds, [first.id, second.id]);
        expect(c.navigation.current.pageId, page);
        expect(c.navigation.current.markdown, isFalse);
        await c.flush();
        c.dispose();
        await c.repository.close();
        c = await WorkspaceController.openLibrary(root);
        expect(c.activeSession!.note.id, first.id);
        expect(c.navigation.current.pageId, page);
        await c.activateDocumentTab(second.id);
        expect(c.navigation.current.markdownAnchor, 'Second heading');
        expect(c.navigation.current.markdown, isTrue);
        expect(c.markdown, 'Second contents');
        expect(
          c.navigation.infiniteViewport(second.id)!.toJson(),
          view.toJson(),
        );
        await c.closeDocumentTab(second.id);
        expect(c.activeSession!.note.id, first.id);
        expect(c.navigation.current.pageId, page);
      } finally {
        await c.flush();
        c.dispose();
        await c.repository.close();
        await root.delete(recursive: true);
      }
    },
  );

  test('confirmed background trash prunes tabs and history and persists the active view', () async {
    final root = await Directory.systemTemp.createTemp(
      'workspace-background-trash-',
    );
    var c = WorkspaceController(
      await NoteRepository.open(root, createFormatVersion: 2),
    );
    try {
      final background = await c.createNote(
        'Background',
        documentKind: VaultDocumentKind.markdown,
      );
      await c.rememberView(markdown: true, markdownAnchor: 'Deleted anchor');
      final active = await c.createNote(
        'Active',
        documentKind: VaultDocumentKind.markdown,
      );
      await c.rememberView(markdown: true, markdownAnchor: 'Keep anchor');
      final session = c.activeSession;
      expect(c.navigation.peekBack!.noteId, background.id);
      await c.externalMutation((_) => c.store.setDeleted(background, true));
      expect(identical(c.activeSession, session), isTrue);
      expect(c.navigation.tabs.single.noteId, active.id);
      expect(c.navigation.peekBack!.noteId, isNull);
      expect(c.navigation.current.markdownAnchor, 'Keep anchor');
      final saved = await WorkspaceNavigation.load(
        File('${root.path}/.workspace/navigation.json'),
      );
      expect(saved.tabs.single.noteId, active.id);
      expect(saved.recentDocumentIds, [active.id]);
      expect(saved.peekBack!.noteId, isNull);
      await c.flush();
      c.dispose();
      await c.repository.close();
      c = await WorkspaceController.openLibrary(root);
      expect(c.activeSession!.note.id, active.id);
      expect(c.navigation.current.markdownAnchor, 'Keep anchor');
      expect(c.navigation.tabs.single.noteId, active.id);
    } finally {
      await c.flush();
      c.dispose();
      await c.repository.close();
      await root.delete(recursive: true);
    }
  });
}
