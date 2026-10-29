import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  late Directory temp;
  late WorkspaceController c;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('workspace-controller-');
    c = WorkspaceController(await NoteRepository.open(temp));
  });
  tearDown(() async {
    await c.repository.close();
    c.dispose();
    await temp.delete(recursive: true);
  });
  test('remote arrival preserves dirty text and session parents', () async {
    final note = await c.store.create('Test');
    await c.openNote(note);
    final base = c.activeSession!.markdownParents.single;
    c.editMarkdown('unsaved local');
    await c.repository.commit(
      entityId: note.markdownEntityId,
      kind: EntityKind.markdown,
      ownerNoteId: note.id,
      files: {'summary.md': Uint8List.fromList('remote'.codeUnits)},
      parentRevisionIds: [base],
    );
    await c.refresh();
    expect(c.markdown, 'unsaved local');
    expect(c.activeSession!.markdownParents, [base]);
    expect(c.remoteConflict, isTrue);
    await c.saveMarkdown();
    expect(await c.repository.heads(note.markdownEntityId), hasLength(2));
  });
  test(
    'disk reopen receives background writes and preserves dirty base',
    () async {
      final note = await c.store.create('Test');
      await c.openNote(note);
      final base = c.activeSession!.markdownParents.single;
      c.editMarkdown('foreground');
      final worker = await NoteRepository.open(temp);
      await worker.commit(
        entityId: note.markdownEntityId,
        kind: EntityKind.markdown,
        ownerNoteId: note.id,
        files: {'summary.md': Uint8List.fromList('background'.codeUnits)},
        parentRevisionIds: [base],
      );
      await worker.close();
      await c.reloadFromDisk();
      expect(c.markdown, 'foreground');
      expect(c.activeSession!.markdownParents, [base]);
      expect(c.remoteConflict, isTrue);
      await c.saveMarkdown();
      expect(await c.repository.heads(note.markdownEntityId), hasLength(2));
    },
  );
  test(
    'typing while remote markdown read waits preserves text and base',
    () async {
      final note = await c.store.create('Read race');
      await c.openNote(note);
      final original = c.activeSession!;
      final base = original.markdownParents.single;
      final delayed = DelayedSession(original)..delayRead = true;
      c.activeSession = delayed;
      await c.repository.commit(
        entityId: note.markdownEntityId,
        kind: EntityKind.markdown,
        ownerNoteId: note.id,
        files: {'summary.md': Uint8List.fromList('remote'.codeUnits)},
        parentRevisionIds: [base],
      );
      final refresh = c.refresh();
      await delayed.entered.future;
      c.editMarkdown('typed during read');
      delayed.release.complete();
      await refresh;
      expect(c.markdown, 'typed during read');
      expect(delayed.markdownParents, [base]);
    },
  );
  test(
    'save and reload drain an outstanding local commit before indexing',
    () async {
      final note = await c.store.create('Reload race');
      await c.openNote(note);
      final delayed = DelayedSession(c.activeSession!)..delaySave = true;
      c.activeSession = delayed;
      c.editMarkdown('durable before reload');
      final save = c.saveMarkdown();
      await delayed.entered.future;
      final reload = c.reloadFromDisk();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      delayed.release.complete();
      await Future.wait([save, reload]);
      expect(await c.activeSession!.readMarkdown(), 'durable before reload');
      c.editMarkdown('next write');
      await c.saveMarkdown();
      expect(await c.activeSession!.readMarkdown(), 'next write');
      expect(await c.repository.heads(note.markdownEntityId), hasLength(1));
    },
  );
  test('debounce persists typed markdown without pressing save', () async {
    final note = await c.store.create('Autosave');
    await c.openNote(note);
    c.editMarkdown('automatically durable');
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(await c.activeSession!.readMarkdown(), 'automatically durable');
    expect(c.markdownDirty, isFalse);
  });
  test(
    'overlapping manual saves preserve newer input without branching',
    () async {
      final note = await c.store.create('Save race');
      await c.openNote(note);
      final delayed = DelayedSession(c.activeSession!)..delaySave = true;
      c.activeSession = delayed;
      c.editMarkdown('first');
      final first = c.saveMarkdown();
      await delayed.entered.future;
      c.editMarkdown('second');
      final second = c.saveMarkdown();
      delayed.release.complete();
      await Future.wait([first, second]);
      expect(await delayed.readMarkdown(), 'second');
      expect(await c.repository.heads(note.markdownEntityId), hasLength(1));
      expect(c.markdownDirty, isFalse);
    },
  );
  test('capture drains before disk reload and the reopened index contains its revision', () async {
    final note = await c.store.create('Capture');
    await c.openNote(note);
    final file = File('${temp.path}/source.pdf');
    await file.writeAsBytes([37, 80, 68, 70, 42]);
    final delayed = DelayedFile(file);
    final core = EditorCoreInfo(filePath: '/capture');
    core.pages.add(
      EditorPage(
        backgroundImage: PdfEditorImage(
          id: 0,
          pdfBytes: null,
          pdfFile: delayed,
          pdfPage: 0,
          pageIndex: 0,
          pageSize: const Size(100, 200),
          naturalSize: const Size(100, 200),
          assetCache: core.assetCache,
          onMoveImage: null,
          onDeleteImage: null,
          onMiscChange: null,
        ),
      ),
    );
    final save = c.saveInk(core, 0);
    await delayed.entered.future;
    var reloaded = false;
    final reload = c.reloadFromDisk().then((_) => reloaded = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(reloaded, isFalse);
    delayed.release.complete();
    await Future.wait([save, reload]);
    final heads = await c.repository.heads(note.inkEntityId);
    expect(heads, hasLength(1));
    expect((await c.repository.readFiles(heads.single))['main.sbn2.0'], [
      37,
      80,
      68,
      70,
      42,
    ]);
    core.dispose();
  });
  test(
    'a completed ink save during remote read cannot roll the ink base back',
    () async {
      final note = await c.store.create('Read and ink');
      await c.openNote(note);
      final core = EditorCoreInfo(filePath: '/new-ink')
        ..pages.add(EditorPage());
      await c.saveInk(core, 0);
      final delayed = DelayedSession(c.activeSession!)..delayRead = true;
      c.activeSession = delayed;
      final worker = await NoteRepository.open(temp);
      final oldInk = (await worker.heads(note.inkEntityId)).single;
      await worker.commit(
        entityId: note.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: note.id,
        files: await worker.readFiles(oldInk),
        parentRevisionIds: [oldInk.revisionId],
      );
      await worker.commit(
        entityId: note.markdownEntityId,
        kind: EntityKind.markdown,
        ownerNoteId: note.id,
        files: {'summary.md': Uint8List.fromList('remote'.codeUnits)},
        parentRevisionIds: delayed.markdownParents,
      );
      await worker.close();
      final refresh = c.reloadFromDisk();
      await delayed.entered.future;
      c.setInkDirty(true);
      await c.saveInk(core, 0);
      final saved = List.of(delayed.inkParents);
      c.setInkDirty(false);
      delayed.release.complete();
      await refresh;
      expect(delayed.inkParents, saved);
      core.dispose();
    },
  );
}

class DelayedSession extends NoteSession {
  new(NoteSession source)
    : super(
        source.repository,
        source.note,
        source.inkHeads,
        source.markdownHeads,
      ) {
    inkParents = List.of(source.inkParents);
    markdownParents = List.of(source.markdownParents);
  }
  final entered = Completer<void>();
  final release = Completer<void>();
  var delayRead = false, delaySave = false;
  @override
  Future<String> readMarkdown({List<String>? parents}) async {
    final value = await super.readMarkdown(parents: parents);
    if (delayRead) {
      delayRead = false;
      entered.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<void> saveMarkdown(String text) async {
    if (delaySave) {
      delaySave = false;
      entered.complete();
      await release.future;
    }
    await super.saveMarkdown(text);
  }
}

class DelayedFile implements File {
  new(this.delegate);
  final File delegate;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  String get path => delegate.path;
  @override
  Future<Uint8List> readAsBytes() async {
    entered.complete();
    await release.future;
    return delegate.readAsBytes();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
