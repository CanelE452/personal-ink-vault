import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final libraryPath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');
  late Directory temporary;
  late NoteRepository repository;
  late WorkspaceStore store;
  late InkVaultNative native;
  late WorkspaceController controller;

  Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));

  setUp(() async {
    native = InkVaultNative.open(libraryPath: libraryPath);
    temporary = await Directory.systemTemp.createTemp('ink-mentions-');
    repository = await NoteRepository.open(temporary, createFormatVersion: 2);
    controller = WorkspaceController(repository, native: native);
    store = controller.store;
  });

  tearDown(() async {
    controller.dispose();
    await repository.close();
    await temporary.delete(recursive: true);
  });

  test('links exactly one occurrence in a canonical summary and keeps its bytes', () async {
    final target = await store.createMarkdown(
      'Research',
      bytes('---\nAliases: ["강의", "Lab X"]\n---\n'),
      aliases: ['Obsolete'],
    );
    final source = await store.createWithSource(
      'Lecture',
      fileName: 'Lecture.pdf',
      bytes: bytes('%PDF-1.7\nfixture'),
      documentKind: VaultDocumentKind.pdf,
    );
    const body =
        '---\r\nfield: Research\r\n---\r\n'
        '😀 Lab X, Lab X. 강의와 강의. Obsolete.\r\n'
        '[[Research]] `[Research]` [Research](https://example.com)\r\n';
    await (await store.open(source)).saveMarkdown('\uFEFF$body');
    await controller.openNote(target);
    await controller.refresh();

    final results = await controller.knowledge!.unlinkedMentions(target.id);
    expect(results.truncated, isFalse);
    final mentions = results.mentions;
    expect(mentions.map((mention) => mention.text), ['Lab X', 'Lab X', '강의']);
    expect(mentions.every((mention) => mention.sourceId == source.id), isTrue);
    expect(mentions[1].start, body.lastIndexOf('Lab X'));
    expect(mentions[1].snippet, contains('Lab X'));
    await controller.linkUnlinkedMention(mentions[1], isCurrent: () => true);

    final revision = (await repository.heads(source.markdownEntityId)).single;
    final updated = await repository.readRevisionFile(revision, 'summary.md');
    expect(
      updated,
      bytes(
        '\uFEFF${body.replaceRange(mentions[1].start, mentions[1].end, '[Lab X](${NoteLink.markdown(target.id)})')}',
      ),
    );
    expect(
      (await controller.knowledge!.unlinkedMentions(target.id)).mentions
          .map((mention) => mention.text),
      ['Lab X', '강의'],
    );
  });

  test('saved YAML controls aliases after import and changes', () async {
    final target = await store.createMarkdown(
      'Research',
      bytes('---\naliases: Previous\n---\n'),
      aliases: ['Previous'],
    );
    await store.createMarkdown('Source', bytes('Previous. Current. Research.'));
    final first = await KnowledgeIndex.build(repository, native);
    expect(
      (await first.unlinkedMentions(target.id)).mentions.map((m) => m.text),
      ['Previous', 'Research'],
    );
    final targetSession = await store.open(target);
    await targetSession.saveMarkdown('---\naliases: Current\n---\n');
    final second = await KnowledgeIndex.build(repository, native);
    expect(
      (await second.unlinkedMentions(target.id)).mentions.map((m) => m.text),
      ['Current', 'Research'],
    );
    await targetSession.saveMarkdown('No aliases.');
    final third = await KnowledgeIndex.build(repository, native);
    expect(
      (await third.unlinkedMentions(target.id)).mentions.map((m) => m.text),
      ['Research'],
    );
  });

  test(
    'rejects a result when the target changes or the panel closes',
    () async {
      final target = await store.createMarkdown('Research', bytes(''));
      final source = await store.createMarkdown('Source', bytes('Research.'));
      await controller.openNote(target);
      await controller.refresh();
      final results = await controller.knowledge!.unlinkedMentions(target.id);

      await expectLater(
        controller.linkUnlinkedMention(
          results.mentions.single,
          isCurrent: () => false,
        ),
        throwsStateError,
      );
      final current = await controller.knowledge!.unlinkedMentions(target.id);
      await (await store.open(target)).saveMarkdown('A newer target revision.');
      await expectLater(
        controller.linkUnlinkedMention(
          current.mentions.single,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(await (await store.open(source)).readMarkdown(), 'Research.');
    },
  );

  test('refuses stale source and unsaved target edits', () async {
    final target = await store.createMarkdown('Research', bytes(''));
    final source = await store.create('Handwriting');
    final sourceSession = await store.open(source);
    await sourceSession.saveMarkdown('Research.');
    await controller.openNote(target);
    await controller.refresh();

    final result = await controller.knowledge!.unlinkedMentions(target.id);
    await sourceSession.saveMarkdown('Research. New summary text.');
    await expectLater(
      controller.linkUnlinkedMention(
        result.mentions.single,
        isCurrent: () => true,
      ),
      throwsStateError,
    );
    final current = await controller.knowledge!.unlinkedMentions(target.id);
    controller.editMarkdown('Unpublished target alias.');
    await expectLater(
      controller.linkUnlinkedMention(
        current.mentions.single,
        isCurrent: () => true,
      ),
      throwsStateError,
    );
    expect(await sourceSession.readMarkdown(), 'Research. New summary text.');
  });

  test('scans successive native batches and caps visible results', () async {
    final target = await store.createMarkdown('Research', bytes(''));
    final sources = <String>{};
    for (var i = 0; i < 18; i++) {
      final source = await store.createMarkdown(
        'Source $i',
        bytes('Research.'),
      );
      sources.add(source.id);
    }
    final first = await KnowledgeIndex.build(repository, native);
    final results = await first.unlinkedMentions(target.id);
    expect(results.truncated, isFalse);
    expect(
      results.mentions.map((mention) => mention.sourceId).toSet(),
      sources,
    );

    await store.createMarkdown('Repeated', bytes('Research. ' * 130));
    final second = await KnowledgeIndex.build(repository, native);
    final limited = await second.unlinkedMentions(target.id);
    expect(limited.mentions, hasLength(128));
    expect(limited.truncated, isTrue);
  });
}
