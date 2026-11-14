import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pdf;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/obsidian_vault_import.dart';
import 'package:saber/data/vault/workspace_bookmarks.dart';
import 'package:saber/data/vault/workspace_markdown_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  final nativeLibrary = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  late Directory temporary;
  late Directory vaults;
  late Directory source;
  late InkVaultNative native;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('piv-obsidian-');
    vaults = Directory(p.join(temporary.path, 'vaults'));
    source = await Directory(p.join(temporary.path, '연구 노트')).create();
    if (nativeLibrary != null) {
      native = InkVaultNative.open(libraryPath: nativeLibrary);
    }
  });

  tearDown(() async {
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final owned = await temporary.resolveSymbolicLinks();
    expect(p.dirname(owned), root);
    expect(p.basename(owned), startsWith('piv-obsidian-'));
    await Directory(owned).delete(recursive: true);
  });

  Future<File> sourceFile(List<String> path, List<int> bytes) async {
    final file = File(p.joinAll([source.path, ...path]));
    await file.parent.create(recursive: true);
    return file.writeAsBytes(bytes);
  }

  Future<ObsidianVaultImportResult> runImport() => importObsidianVault(
    vaultsDirectory: vaults,
    sourceFolder: source,
    sourceName: p.basename(source.path),
    native: native,
  );

  test('publishes the template folder as an imported ID and skips invalid settings', () async {
    await sourceFile([
      'Course',
      'Templates',
      'Lesson.md',
    ], utf8.encode('# {{title}}'));
    final settingsFile = await sourceFile([
      '.obsidian',
      'templates.json',
    ], utf8.encode('{"folder":"Course/Templates","dateFormat":"DD.MM.YYYY"}'));
    final imported = await runImport();
    addTearDown(imported.repository.close);
    final store = WorkspaceMarkdownTemplateStore(imported.repository);
    final settings = await store.settings();
    final folders = await store.folders();
    expect(
      settings.folderId,
      folders.singleWhere((f) => f.label == 'Course/Templates').id,
    );
    expect(settings.dateFormat, 'DD.MM.YYYY');
    expect(settings.timeFormat, 'HH:mm');
    final choice = (await store.templates(settings.folderId!)).single;
    expect(await store.readTemplate(settings.folderId!, choice), '# {{title}}');

    await settingsFile.writeAsString('{"folder":"Course/Missing"}');
    final withoutSettings = await runImport();
    addTearDown(withoutSettings.repository.close);
    final skipped = WorkspaceMarkdownTemplateStore(withoutSettings.repository);
    expect((await skipped.settings()).revisionIds, isEmpty);
    expect(
      (await WorkspaceStore(withoutSettings.repository).list()).single.title,
      'Lesson',
    );
  }, skip: nativeLibrary == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false);

  test(
    'published Obsidian vault reopens grouped bookmarks by imported IDs',
    () async {
      final pdfDocument = pdf.Document()
        ..addPage(pdf.Page(build: (_) => pdf.SizedBox()))
        ..addPage(pdf.Page(build: (_) => pdf.SizedBox()));
      final archive = Archive();
      void file(String path, List<int> content) =>
          archive.addFile(ArchiveFile.bytes('Wrapped/$path', content));
      file('Course/Lesson%.MD', utf8.encode('## Heading 100%\n\nText ^AbC\n'));
      file(
        'Other/Lesson%.md',
        utf8.encode('# Another file with the same name'),
      );
      file('Course/Slides.pdf', await pdfDocument.save());
      file(
        '.obsidian/bookmarks.json',
        utf8.encode('''
{"items":[{"type":"group","title":"Study","items":[
  {"type":"file","path":"Course/Lesson%.MD","subpath":"#Heading 100%","title":"Heading"},
  {"type":"group","title":"Reading","items":[
    {"type":"file","path":"Course/Slides.pdf","subpath":"#page=2","title":"Page 2"},
    {"type":"file","path":"Course/Lesson%.MD","subpath":"#^AbC","title":"Block"}
  ]},
  {"type":"file","path":"Course/Lesson%.MD","title":"Whole note"}
]},
{"type":"folder","path":"Course","title":"Folder"},
{"type":"url","url":"https://example.org/reference","title":"Website"},
{"type":"search","query":"\\"literature review\\"","title":"Search"},
{"type":"graph","options":{}},
{"type":"file","path":"Lesson%.md"},
{"type":"file","path":"Course/\\ud800.md"},
{"type":"search","query":"tag:#research -draft","title":"Filtered search"},
{"type":"search","query":"unknown:research"},
{"type":"url","url":"javascript:alert(1)"},
{"type":"file","path":"Course/Slides.pdf","subpath":"#page=0"}
]}
'''),
      );
      final imported = await importObsidianVault(
        vaultsDirectory: vaults,
        sourceZip: Uint8List.fromList(ZipEncoder().encode(archive)),
        sourceName: 'Wrapped',
        native: native,
      );
      addTearDown(imported.repository.close);
      expect(imported.noteCount, 2);
      expect(imported.attachmentCount, 1);
      expect(imported.skippedFiles, 0);
      expect(imported.bookmarksImported, 10);
      expect(imported.bookmarksSkipped, 6);
      expect(imported.bookmarksUnreadable, isFalse);
      final path = imported.repository.root;
      await imported.repository.close();
      final reopened = await NoteRepository.open(path);
      addTearDown(reopened.close);
      final items = await WorkspaceBookmarkStore(reopened).list();
      expect(items, hasLength(10));
      final byTitle = {for (final item in items) item.spec.title: item};
      final folder = (await LibraryStore(
        reopened,
      ).listFolders()).singleWhere((folder) => folder.title == 'Course');
      final notes = await WorkspaceStore(reopened).list();
      final lesson = notes.singleWhere(
        (note) => note.title == 'Lesson%' && note.folderId == folder.id,
      );
      final slides = notes.singleWhere((note) => note.title == 'Slides.pdf');
      expect(byTitle['Reading']!.spec.groupId, byTitle['Study']!.id);
      expect(byTitle['Heading']!.spec.groupId, byTitle['Study']!.id);
      expect(byTitle['Block']!.spec.groupId, byTitle['Reading']!.id);
      expect(
        byTitle['Heading']!.spec.order,
        lessThan(byTitle['Reading']!.spec.order!),
      );
      expect(
        NoteLink.parse(byTitle['Heading']!.spec.target!)!.noteId,
        lesson.id,
      );
      expect(
        NoteLink.parse(byTitle['Heading']!.spec.target!)!.markdownAnchor,
        'Heading 100%',
      );
      expect(
        NoteLink.parse(byTitle['Block']!.spec.target!)!.markdownAnchor,
        '^AbC',
      );
      expect(
        NoteLink.parse(byTitle['Whole note']!.spec.target!)!.isMarkdown,
        isTrue,
      );
      expect(
        NoteLink.parse(byTitle['Page 2']!.spec.target!)!.noteId,
        slides.id,
      );
      expect(byTitle['Page 2']!.spec.pdfPageNumber, 2);
      expect(byTitle['Folder']!.spec.target, folder.id);
      expect(byTitle['Website']!.spec.target, 'https://example.org/reference');
      expect(byTitle['Search']!.spec.target, '"literature review"');
      expect(byTitle['Search']!.spec.literalSearch, isFalse);
      expect(byTitle['Search']!.spec.expressionSearch, isTrue);
      expect(byTitle['Filtered search']!.spec.target, 'tag:#research -draft');
      expect(byTitle['Filtered search']!.spec.expressionSearch, isTrue);
      expect(byTitle['Filtered search']!.spec.literalSearch, isFalse);
      expect(reopened.integrityIssues, isEmpty);
    },
    skip: nativeLibrary == null
        ? 'Set INK_VAULT_NATIVE_LIBRARY to a fresh common engine'
        : false,
  );

  test(
    'malformed bookmark metadata leaves ordinary documents intact',
    () async {
      await sourceFile(['Read.md'], utf8.encode('# Read'));
      await sourceFile([
        '.obsidian',
        'bookmarks.json',
      ], utf8.encode('{"items":['));
      final imported = await runImport();
      addTearDown(imported.repository.close);
      expect(imported.bookmarksUnreadable, isTrue);
      expect(imported.bookmarksImported, 0);
      expect(imported.skippedFiles, 0);
      expect(
        (await WorkspaceStore(imported.repository).list()).single.title,
        'Read',
      );
      expect(await WorkspaceBookmarkStore(imported.repository).list(), isEmpty);
    },
    skip: nativeLibrary == null
        ? 'Set INK_VAULT_NATIVE_LIBRARY to a fresh common engine'
        : false,
  );

  test(
    'published vault reopens with byte-exact Markdown and Rust path links',
    () async {
      final body = Uint8List.fromList([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode(
          '# 원본\r\n\r\n[[수업/정리#작업 항목]]\r\n'
          '[상대](../정리.md#작업%20항목)\r\n'
          '[루트](/수업/정리.md#작업%20항목)\r\n'
          '[[강의 요약]]\r\n',
        ),
      ]);
      final original = await sourceFile(['수업', '주차', '원본.md'], body);
      await sourceFile([
        '수업',
        '정리.md',
      ], utf8.encode('---\naliases: [강의 요약]\n---\n\n## 작업 항목\n고유 본문\n'));
      await sourceFile(['기타', '정리.md'], utf8.encode('# 별도 노트\n'));
      await sourceFile(['.obsidian', 'private.md'], utf8.encode('# 제외'));
      await sourceFile(['수업', 'slides.bin'], [0x50, 0x4b]);

      final old = await NoteRepository.open(
        Directory(p.join(vaults.path, 'offline')),
        createFormatVersion: 2,
      );
      addTearDown(old.close);
      final existing = await WorkspaceStore(old).create('이전 보관함');
      final oldRevisions = (await old.revisions())
          .map((r) => r.toJson())
          .toList();

      final imported = await runImport();
      addTearDown(imported.repository.close);
      expect(imported.noteCount, 3);
      expect(imported.folderCount, 3);
      expect(imported.skippedFiles, 1);
      expect(imported.repository.vaultId, isNot(old.vaultId));
      expect(p.dirname(imported.repository.root.path), vaults.path);
      expect(
        p.basename(imported.repository.root.path),
        startsWith('obsidian-'),
      );
      final root = imported.repository.root;
      await imported.repository.close();

      final reopened = await NoteRepository.open(root);
      addTearDown(reopened.close);
      expect(reopened.pendingRevisionCount, 0);
      expect(reopened.integrityIssues, isEmpty);
      final folders = await LibraryStore(reopened).listFolders();
      final course = folders.singleWhere((folder) => folder.title == '수업');
      final week = folders.singleWhere((folder) => folder.title == '주차');
      expect(course.parentId, isNull);
      expect(week.parentId, course.id);
      final notes = await WorkspaceStore(reopened).list();
      final importedSource = notes.singleWhere((note) => note.title == '원본');
      final target = notes.singleWhere((note) => note.folderId == course.id);
      expect(importedSource.folderId, week.id);
      expect(importedSource.documentKind, VaultDocumentKind.markdown);
      final markdown = (await reopened.heads(importedSource.markdownEntityId))
          .single;
      expect(markdown.parentRevisionIds, isEmpty);
      expect((await reopened.readFiles(markdown))['summary.md'], body);
      expect(await original.readAsBytes(), body);

      final index = await KnowledgeIndex.build(reopened, native);
      final wiki = index.resolveWikiLink(
        '수업/정리#작업 항목',
        fromNoteId: importedSource.id,
      );
      expect(wiki?.noteId, target.id);
      expect(wiki?.anchor, '작업 항목');
      for (final href in ['../정리.md#작업%20항목', '/수업/정리.md#작업%20항목']) {
        final link = index.resolveMarkdownLink(
          href,
          fromNoteId: importedSource.id,
        );
        expect(link?.noteId, target.id);
        expect(link?.anchor, '작업 항목');
      }
      expect(
        index.resolveWikiLink('강의 요약', fromNoteId: importedSource.id)?.noteId,
        target.id,
      );
      expect(index.backlinks(target.id).map((note) => note.id), [
        importedSource.id,
      ]);
      expect((await WorkspaceStore(old).list()).single.id, existing.id);
      expect((await old.revisions()).map((r) => r.toJson()), oldRevisions);
    },
    skip: nativeLibrary == null
        ? 'Set INK_VAULT_NATIVE_LIBRARY to a fresh common engine'
        : false,
  );

  test(
    'reopened vault preserves originals and resolves typed attachment paths',
    () async {
      await FileManager.init(
        documentsDirectory: p.join(temporary.path, 'working'),
        shouldWatchRootDirectory: false,
      );
      final document = pdf.Document()
        ..addPage(pdf.Page(build: (_) => pdf.SizedBox()));
      final originalPdf = await document.save();
      final originalPpt = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'Attachment',
      ).bytes;
      final originalDoc = OfficeTemplates.create(
        OfficeTemplateKind.document,
        title: 'Attachment',
      ).bytes;
      final originalHwp = OfficeTemplates.create(
        OfficeTemplateKind.hwpx,
        title: 'Attachment',
      ).bytes;
      final originalPng = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQKNj3H4QZYAwATRAJNQkgY7wAAAAASUVORK5CYII=',
      );
      final originals = {
        '강의 자료.pdf': (VaultDocumentKind.pdf, originalPdf),
        'Deck.PPTX': (VaultDocumentKind.office, originalPpt),
        'Draft.docx': (VaultDocumentKind.office, originalDoc),
        '연구.hwpx': (VaultDocumentKind.office, originalHwp),
        'Plot.png': (VaultDocumentKind.image, originalPng),
      };
      for (final entry in originals.entries) {
        await sourceFile(['자료', entry.key], entry.value.$2);
      }
      final body = utf8.encode(
        '[[자료/Deck.PPTX]]\n'
        '[PDF](../자료/강의%20자료.pdf#page=1)\n'
        '![[Plot.png]]\n'
        '[Markdown](../자료/Deck.PPTX.md)',
      );
      await sourceFile(['노트', 'Start.md'], body);
      await sourceFile(['자료', 'Deck.PPTX.md'], utf8.encode('Same base name'));

      final imported = await runImport();
      addTearDown(imported.repository.close);
      expect(imported.noteCount, 2);
      expect(imported.attachmentCount, 5);
      expect(imported.skippedFiles, 0);
      final path = imported.repository.root;
      await imported.repository.close();
      final reopened = await NoteRepository.open(path);
      addTearDown(reopened.close);
      final notes = await WorkspaceStore(reopened).list();
      final start = notes.singleWhere((note) => note.title == 'Start');
      final md = (await reopened.heads(start.markdownEntityId)).single;
      expect(await reopened.readRevisionFile(md, 'summary.md'), body);
      final attachmentIds = <String, String>{};
      for (final entry in originals.entries) {
        final (kind, bytes) = entry.value;
        final note = notes.singleWhere(
          (note) => note.title == entry.key && note.documentKind == kind,
        );
        final head = (await reopened.heads(note.sourceEntityId!)).single;
        expect(head.ownerNoteId, note.id);
        expect(await reopened.readRevisionFile(head, entry.key), bytes);
        expect(
          await File(p.join(source.path, '자료', entry.key)).readAsBytes(),
          bytes,
        );
        attachmentIds[entry.key] = note.id;
        if (kind == VaultDocumentKind.image) {
          final ink = (await reopened.heads(note.inkEntityId)).single;
          expect(ink.blobs.keys, contains('main.sbn2'));
        }
        if (kind == VaultDocumentKind.office) {
          final edition = await OfficeDocumentStore(reopened).readLatest(note);
          expect(edition.originalFileName, entry.key);
        }
      }

      final index = await KnowledgeIndex.build(reopened, native);
      final deck = index.resolveWikiLink('자료/deck.pptx', fromNoteId: start.id);
      expect(deck?.noteId, attachmentIds['Deck.PPTX']);
      expect(deck?.attachmentName, 'Deck.PPTX');
      final pdfLink = index.resolveMarkdownLink(
        '../자료/강의%20자료.pdf#page=1',
        fromNoteId: start.id,
      );
      expect(pdfLink?.noteId, attachmentIds['강의 자료.pdf']);
      expect(pdfLink?.anchor, 'page=1');
      expect(pdfLink?.attachmentName, '강의 자료.pdf');
      expect(
        index.backlinks(attachmentIds['Plot.png']!).map((note) => note.id),
        [start.id],
      );
      final summary = index.resolveMarkdownLink(
        '../자료/Deck.PPTX.md',
        fromNoteId: start.id,
      );
      final markdown = notes.singleWhere(
        (note) =>
            note.title == 'Deck.PPTX' &&
            note.documentKind == VaultDocumentKind.markdown,
      );
      expect(summary?.noteId, markdown.id);
      expect(summary?.attachmentName, isNull);

      final image = notes.singleWhere(
        (note) => note.id == attachmentIds['Plot.png'],
      );
      await WorkspaceStore(reopened, native: native).rename(image, '논문 그림');
      final renamed = (await WorkspaceStore(
        reopened,
      ).list()).singleWhere((note) => note.id == image.id);
      expect(renamed.title, '논문 그림');
      expect(renamed.obsidianAttachmentName, 'Plot.png');
      expect(
        (await reopened.heads(start.markdownEntityId)).single.revisionId,
        md.revisionId,
      );
      final after = await KnowledgeIndex.build(reopened, native);
      expect(
        after.resolveWikiLink('Plot.png', fromNoteId: start.id)?.noteId,
        image.id,
      );
    },
    skip: nativeLibrary == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false,
  );

  test('Canvas imports editable boards with stable file links and untouched originals', () async {
    Map<String, Object?> node(
      String id,
      String type,
      Map<String, Object?> data,
    ) => {
      'id': id,
      'type': type,
      'x': -80,
      'y': 125,
      'width': 240,
      'height': 160,
      ...data,
    };
    List<int> board(
      List<Map<String, Object?>> nodes, [
      List<Object> edges = const [],
    ]) => utf8.encode(
      jsonEncode({
        'nodes': nodes,
        'edges': edges,
        'futureField': {'kept': true},
      }),
    );
    final plan = board(
      [
        node('group', 'group', {
          'label': '논문',
          'background': 'cover.png',
          'text': {'future': true},
        }),
        node('intro', 'file', {'file': 'Notes/Intro.md', 'subpath': '#주제'}),
        node('cycle', 'file', {'file': 'Boards/Second.canvas'}),
        node('missing', 'file', {
          'file': '../Notes/Intro.md',
          'inkVaultNoteId': newId(),
        }),
        node('literal', 'file', {'file': 'Notes/Paper%20One.md'}),
        node('text', 'text', {'text': '원래 내용'}),
      ],
      [
        {
          'id': 'edge',
          'fromNode': 'intro',
          'toNode': 'cycle',
          'fromSide': 'right',
          'toEnd': 'none',
          'label': '다음',
        },
      ],
    );
    await sourceFile(['Boards', 'Plan.canvas'], plan);
    await sourceFile(
      ['Boards', 'Second.canvas'],
      board([
        node('back', 'file', {'file': 'Boards/Plan.canvas'}),
      ]),
    );
    await sourceFile(['Boards', 'Plan.canvas.md'], utf8.encode('Namesake'));
    await sourceFile(['Notes', 'Paper%20One.md'], utf8.encode('Literal'));
    await sourceFile(['Notes', 'Paper One.md'], utf8.encode('Space'));
    await sourceFile([
      'Notes',
      'Intro.md',
    ], utf8.encode('## 주제\n[[Boards/Plan.canvas]]'));

    final result = await runImport();
    await result.repository.close();
    final repository = await NoteRepository.open(result.repository.root);
    addTearDown(repository.close);
    final store = WorkspaceStore(repository);
    final notes = await store.list();
    final boards = notes
        .where((note) => note.documentKind == VaultDocumentKind.canvas)
        .toList();
    expect(boards, hasLength(2));
    final first = boards.singleWhere((note) => note.title == 'Plan.canvas');
    final second = boards.singleWhere((note) => note.title == 'Second.canvas');
    final intro = notes.singleWhere((note) => note.title == 'Intro');
    final literal = notes.singleWhere((note) => note.title == 'Paper%20One');
    final namesake = notes.singleWhere(
      (note) =>
          note.title == 'Plan.canvas' &&
          note.documentKind == VaultDocumentKind.markdown,
    );
    final head = (await repository.heads(first.sourceEntityId!)).single;
    expect(head.ownerNoteId, first.id);
    expect(await repository.readRevisionFile(head, 'Plan.canvas'), plan);
    expect(
      await File(p.join(source.path, 'Boards', 'Plan.canvas')).readAsBytes(),
      plan,
    );

    Future<CardCanvasDocument> readBoard(VaultNote note) async {
      final ink = (await repository.heads(note.inkEntityId)).single;
      expect(ink.ownerNoteId, note.id);
      return CardCanvasDocument.fromJson(
        jsonDecode(
          utf8.decode(await repository.readRevisionFile(ink, 'board.canvas')),
        ) as Map<String, dynamic>,
      );
    }

    final editable = await readBoard(first);
    expect(editable.nodes.map((node) => node.id), [
      'group',
      'intro',
      'cycle',
      'missing',
      'literal',
      'text',
    ]);
    expect(editable.nodes[0].toJson()['background'], 'cover.png');
    expect(editable.nodes[0].text, isNull);
    expect(editable.nodes[0].toJson()['text'], {'future': true});
    expect(
      editable.nodes[1].toJson(),
      containsPair('inkVaultNoteId', intro.id),
    );
    expect(editable.nodes[1].toJson()['file'], 'Notes/Intro.md');
    expect(editable.nodes[1].toJson()['subpath'], '#주제');
    expect(
      editable.nodes[2].toJson(),
      containsPair('inkVaultNoteId', second.id),
    );
    expect(editable.nodes[3].toJson(), containsPair('inkVaultNoteId', null));
    expect(
      editable.nodes[4].toJson(),
      containsPair('inkVaultNoteId', literal.id),
    );
    expect(
      (await readBoard(second)).nodes.single.toJson()['inkVaultNoteId'],
      first.id,
    );
    expect(editable.edges.single.toJson()['label'], '다음');
    expect(editable.toJson()['futureField'], {'kept': true});

    final index = await KnowledgeIndex.build(repository, native);
    expect(
      index.resolveWikiLink('Boards/Plan.canvas', fromNoteId: intro.id)?.noteId,
      first.id,
    );
    expect(
      index
          .resolveMarkdownLink('../Boards/Plan.canvas.md', fromNoteId: intro.id)
          ?.noteId,
      namesake.id,
    );
    expect(
      index.backlinks(first.id).map((note) => note.id),
      unorderedEquals([intro.id, second.id]),
    );
    expect(index.backlinks(intro.id).map((note) => note.id), [first.id]);
    final session = await store.open(first);
    final edited = editable.copyWith(
      nodes: [
        ...editable.nodes.take(5),
        editable.nodes.last.copyWith(text: '편집한 내용'),
      ],
    );
    await session.saveInk({
      'board.canvas': Uint8List.fromList(
        utf8.encode(jsonEncode(edited.toJson())),
      ),
    });
    expect((await readBoard(first)).nodes.last.text, '편집한 내용');
    expect(await repository.readRevisionFile(head, 'Plan.canvas'), plan);
  }, skip: nativeLibrary == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false);

  test(
    'invalid Canvas prevents publication even with a valid Markdown note',
    () async {
      await sourceFile(['Valid.md'], utf8.encode('# Valid'));
      await sourceFile([
        'Bad.canvas',
      ], utf8.encode('{"nodes":[{"id":"broken"}],"edges":[]}'));
      await expectLater(runImport(), throwsFormatException);
      if (vaults.existsSync()) {
        final visible = await vaults
            .list()
            .where((item) => p.basename(item.path) != '.imports')
            .toList();
        expect(visible, isEmpty);
        final staging = Directory(p.join(vaults.path, '.imports'));
        if (staging.existsSync())
          expect(await staging.list().toList(), isEmpty);
      }
    },
    skip: nativeLibrary == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false,
  );

  test(
    'Canvas path stays unavailable until its editable body arrives',
    () async {
      final repository = await NoteRepository.open(
        vaults,
        createFormatVersion: 2,
      );
      addTearDown(repository.close);
      final store = WorkspaceStore(repository);
      final canvas = await store.createWithSource(
        'Board.canvas',
        fileName: 'Board.canvas',
        bytes: Uint8List.fromList(utf8.encode('{"nodes":[],"edges":[]}')),
        documentKind: VaultDocumentKind.canvas,
        fromObsidian: true,
      );
      final namesake = await store.createMarkdown('Board.canvas', Uint8List(0));
      final before = await KnowledgeIndex.build(repository, native);
      expect(before.resolveWikiLink('Board.canvas'), isNull);
      expect(before.resolveWikiLink('Board.canvas.md')?.noteId, namesake.id);

      final session = await store.open(canvas);
      await session.saveInk({
        'board.canvas': Uint8List.fromList(
          utf8.encode('{"nodes":[],"edges":[]}'),
        ),
      });
      final after = await KnowledgeIndex.build(repository, native);
      expect(after.resolveWikiLink('Board.canvas')?.noteId, canvas.id);
      expect(after.resolveWikiLink('Board.canvas.md')?.noteId, namesake.id);
    },
    skip: nativeLibrary == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false,
  );

  test(
    'an imported attachment folder cannot change to an unsafe path',
    () async {
      final document = pdf.Document()
        ..addPage(pdf.Page(build: (_) => pdf.SizedBox()));
      await sourceFile(['Assets', 'Original.pdf'], await document.save());
      await sourceFile(['Plain.md'], utf8.encode('No links'));
      final result = await runImport();
      addTearDown(result.repository.close);
      final library = LibraryStore(result.repository, native: native);
      final folder = (await library.listFolders()).single;
      final before = await result.repository.revisions();
      await expectLater(
        library.renameFolder(folder, 'Assets?'),
        throwsFormatException,
      );
      expect((await library.listFolders()).single.title, 'Assets');
      expect(
        (await result.repository.revisions()).map((r) => r.revisionId),
        unorderedEquals(before.map((r) => r.revisionId)),
      );
      final index = await KnowledgeIndex.build(result.repository, native);
      expect(
        index.resolveWikiLink('Assets/Original.pdf')?.attachmentName,
        'Original.pdf',
      );
    },
    skip: nativeLibrary == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false,
  );

  test(
    'an unavailable attachment cannot point to a Markdown namesake',
    () async {
      final document = pdf.Document()
        ..addPage(pdf.Page(build: (_) => pdf.SizedBox()));
      final bytes = await document.save();
      await sourceFile(['Assets', 'Original.pdf'], bytes);
      await sourceFile(['Assets', 'Other.pdf'], bytes);
      await sourceFile(['Assets', 'Original.pdf.md'], utf8.encode('Namesake'));
      await sourceFile(['Start.md'], utf8.encode('[[Assets/Original.pdf]]'));
      final imported = await runImport();
      final repo = imported.repository;
      addTearDown(repo.close);
      final notes = await WorkspaceStore(repo).list();
      final original = notes.singleWhere(
        (note) =>
            note.documentKind == VaultDocumentKind.pdf &&
            note.title == 'Original.pdf',
      );
      final other = notes.singleWhere((note) => note.title == 'Other.pdf');
      final summary = notes.singleWhere(
        (note) =>
            note.documentKind == VaultDocumentKind.markdown &&
            note.title == 'Original.pdf',
      );
      final start = notes.singleWhere((note) => note.title == 'Start');
      await repo.commit(
        entityId: original.id,
        kind: EntityKind.metadata,
        parentRevisionIds: [original.revision.revisionId],
        files: {
          'note.json': Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                ...original.json,
                'sourceEntityId': other.sourceEntityId,
              }),
            ),
          ),
        },
      );

      final index = await KnowledgeIndex.build(repo, native);
      expect(
        index.resolveWikiLink('Assets/Original.pdf', fromNoteId: start.id),
        isNull,
      );
      expect(
        index.resolveMarkdownLink('Assets/Original.pdf', fromNoteId: start.id),
        isNull,
      );
      expect(
        index
            .resolveMarkdownLink('Assets/Original.pdf.md', fromNoteId: start.id)
            ?.noteId,
        summary.id,
      );
    },
    skip: nativeLibrary == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false,
  );

  test(
    'failed image validation cannot publish a partial imported vault',
    () async {
      await sourceFile(['Start.md'], utf8.encode('# Retain source'));
      final invalid = await sourceFile(
        ['Broken.png'],
        [0x89, 0x50, 0x4e, 0x47],
      );
      await expectLater(runImport(), throwsFormatException);
      expect(await invalid.readAsBytes(), [0x89, 0x50, 0x4e, 0x47]);
      expect(
        await vaults
            .list()
            .where((entry) => p.basename(entry.path) != '.imports')
            .toList(),
        isEmpty,
      );
      expect(
        await Directory(p.join(vaults.path, '.imports')).list().toList(),
        isEmpty,
      );
    },
    skip: nativeLibrary == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false,
  );

  test(
    'invalid source publishes no selectable vault and a retry succeeds',
    () async {
      final broken = await sourceFile(['깨짐.md'], [0xff]);
      await expectLater(runImport(), throwsFormatException);
      if (vaults.existsSync()) {
        expect(
          await vaults
              .list()
              .where((entry) => p.basename(entry.path).startsWith('obsidian-'))
              .toList(),
          isEmpty,
        );
      }
      await broken.writeAsString('# 고침');
      final [first, second] = await Future.wait([runImport(), runImport()]);
      addTearDown(first.repository.close);
      addTearDown(second.repository.close);
      expect(first.repository.vaultId, isNot(second.repository.vaultId));
      expect(first.repository.root.path, isNot(second.repository.root.path));
      expect(
        (await WorkspaceStore(second.repository).list()).single.title,
        '깨짐',
      );
      expect(await broken.readAsString(), '# 고침');
    },
    skip: nativeLibrary == null
        ? 'Set INK_VAULT_NATIVE_LIBRARY to a fresh common engine'
        : false,
  );

  test(
    'ZIP restores marked vault contents at the logical root',
    () async {
      final archive = Archive()
        ..addFile(
          ArchiveFile.bytes('Study Vault/.obsidian/app.json', [0x7b, 0x7d]),
        )
        ..addFile(
          ArchiveFile.bytes(
            'Study Vault/Start.md',
            utf8.encode('[[강의/Target]]'),
          ),
        )
        ..addFile(
          ArchiveFile.bytes(
            'Study Vault/강의/Target.md',
            utf8.encode('### Target'),
          ),
        );
      final systemZip = Platform.environment['PIV_OBSIDIAN_SYSTEM_ZIP_FIXTURE'];
      for (final bytes in [
        Uint8List.fromList(ZipEncoder().encode(archive)),
        if (systemZip != null) await File(systemZip).readAsBytes(),
      ]) {
        final imported = await importObsidianVault(
          vaultsDirectory: vaults,
          sourceZip: bytes,
          sourceName: 'Study Vault',
          native: native,
        );
        addTearDown(imported.repository.close);
        expect(imported.folderCount, 1);
        expect(imported.noteCount, 2);
        final folder = (await LibraryStore(
          imported.repository,
        ).listFolders()).single;
        expect(folder.title, '강의');
        expect(folder.parentId, isNull);
        final notes = await WorkspaceStore(imported.repository).list();
        final start = notes.singleWhere((note) => note.title == 'Start');
        final target = notes.singleWhere((note) => note.title == 'Target');
        expect(start.folderId, isNull);
        final index = await KnowledgeIndex.build(imported.repository, native);
        expect(
          index.resolveWikiLink('강의/Target', fromNoteId: start.id)?.noteId,
          target.id,
        );
      }
    },
    skip: nativeLibrary == null
        ? 'Set INK_VAULT_NATIVE_LIBRARY to a fresh common engine'
        : false,
  );

  test(
    'NFC-equivalent ZIP paths are rejected before publication',
    () async {
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('CAFÉ.md', [0x41]))
        ..addFile(ArchiveFile.bytes('Cafe\u0301.md', [0x42]));
      await expectLater(
        importObsidianVault(
          vaultsDirectory: vaults,
          sourceZip: Uint8List.fromList(ZipEncoder().encode(archive)),
          sourceName: 'Conflicting names',
          native: native,
        ),
        throwsFormatException,
      );
      expect(vaults.existsSync(), isFalse);
    },
    skip: nativeLibrary == null
        ? 'Set INK_VAULT_NATIVE_LIBRARY to a fresh common engine'
        : false,
  );

  final junctionSource = Platform.environment['PIV_OBSIDIAN_JUNCTION_SOURCE'];
  if (nativeLibrary != null && junctionSource != null) {
    test('Windows vault traversal rejects a real directory junction', () async {
      await expectLater(
        importObsidianVault(
          vaultsDirectory: vaults,
          sourceFolder: Directory(junctionSource),
          sourceName: 'Junction fixture',
          native: native,
        ),
        throwsFormatException,
      );
      expect(vaults.existsSync(), isFalse);
    });
  }
}
