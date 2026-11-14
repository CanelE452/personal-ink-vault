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
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/obsidian_canvas_export.dart';
import 'package:saber/data/vault/obsidian_vault_import.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  final nativePath = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  final skip = nativePath == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false;
  late Directory temp;
  late NoteRepository repo;
  late WorkspaceStore store;
  late InkVaultNative native;

  Uint8List jsonBytes(Object value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));
  Map<String, dynamic> decode(Uint8List bytes) =>
      jsonObject(jsonDecode(utf8.decode(bytes)));
  Map<String, Object?> node(
    String id,
    String type,
    Map<String, Object?> fields,
  ) => {
    'id': id,
    'type': type,
    'x': -20,
    'y': 10,
    'width': 240,
    'height': 120,
    ...fields,
  };
  Future<RevisionRecord> saveBoard(
    VaultNote note,
    List<Map<String, Object?>> nodes, {
    List<Object> edges = const [],
  }) async {
    final session = await store.open(note);
    await session.saveInk({
      'board.canvas': jsonBytes({'nodes': nodes, 'edges': edges}),
    });
    return (await repo.heads(note.inkEntityId)).single;
  }

  Future<ObsidianCanvasExport> export(VaultNote root, RevisionRecord body) =>
      buildObsidianCanvasExport(
        repository: repo,
        native: native,
        noteId: root.id,
        metadataRevisionId: root.revision.revisionId,
        bodyRevisionId: body.revisionId,
      );

  setUp(() async {
    native = InkVaultNative.open(libraryPath: nativePath);
    temp = await Directory.systemTemp.createTemp('piv-canvas-out-');
    repo = await NoteRepository.open(
      Directory(p.join(temp.path, 'original')),
      createFormatVersion: 2,
    );
    store = WorkspaceStore(repo, native: native);
    await FileManager.init(
      documentsDirectory: p.join(temp.path, 'working'),
      shouldWatchRootDirectory: false,
    );
  });

  tearDown(() async {
    await repo.close();
    final owned = await temp.resolveSymbolicLinks();
    expect(p.dirname(owned), await Directory.systemTemp.resolveSymbolicLinks());
    expect(p.basename(owned), startsWith('piv-canvas-out-'));
    await Directory(owned).delete(recursive: true);
  });

  test(
    'exports an edited Canvas and its document graph as an importable ZIP',
    () async {
      final library = LibraryStore(repo);
      final boards = await library.createFolder('Boards');
      final media = await library.createFolder('Media');
      final original = jsonBytes({'nodes': [], 'edges': []});
      final first = await store.createWithSource(
        'Plan.canvas',
        fileName: 'Plan.canvas',
        bytes: original,
        folderId: boards.id,
        documentKind: VaultDocumentKind.canvas,
        fromObsidian: true,
      );
      final second = await store.create(
        'Second',
        folderId: boards.id,
        documentKind: VaultDocumentKind.canvas,
      );
      final intro = Uint8List.fromList(utf8.encode('## 실험 자료\r\n본문\r\n'));
      final markdown = await store.createMarkdown('Reading renamed', intro);
      final same = await store.createMarkdown(
        'READING RENAMED',
        Uint8List.fromList(utf8.encode('Different note')),
      );
      await store.createMarkdown(
        'Unrelated private note',
        Uint8List.fromList(utf8.encode('private')),
      );
      final handout = pdf.Document()
        ..addPage(pdf.Page(build: (_) => pdf.SizedBox()));
      final pdfBytes = await handout.save();
      final pdfNote = await store.createWithSource(
        'Handout',
        fileName: 'Handout.pdf',
        bytes: pdfBytes,
        folderId: media.id,
        documentKind: VaultDocumentKind.pdf,
        fromObsidian: true,
      );
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQKNj3H4QZYAwATRAJNQkgY7wAAAAASUVORK5CYII=',
      );
      await store.createWithSource(
        'Cover.PNG',
        fileName: 'Cover.PNG',
        bytes: png,
        folderId: media.id,
        documentKind: VaultDocumentKind.image,
        fromObsidian: true,
      );
      final presentation = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'New edition',
      ).bytes;
      final office = OfficeDocumentStore(repo);
      final ppt = await office.importDocument(
        title: 'Deck',
        fileName: 'Deck.pptx',
        bytes: OfficeTemplates.create(
          OfficeTemplateKind.presentation,
          title: 'Old edition',
        ).bytes,
        folderId: media.id,
      );
      await office.commitEdited(
        await office.beginEdit(ppt),
        originalBytes: presentation,
        pdfBytes: pdfBytes,
        engineVersion: 'test',
        pageCount: 1,
      );

      final firstBody = await saveBoard(
        first,
        [
          node('group', 'group', {
            'label': '자료',
            'background': 'Media/cover.png',
            'backgroundStyle': 'ratio',
          }),
          node('md', 'file', {
            'file': 'Old folder/Old name.md',
            'inkVaultNoteId': markdown.id,
            'subpath': '#실험 자료',
          }),
          node('same', 'file', {'file': same.id}),
          node('pdf', 'file', {'file': pdfNote.id, 'subpath': '#page=1'}),
          node('ppt', 'file', {'file': ppt.id}),
          node('child', 'file', {'file': second.id}),
          node('external', 'file', {
            'file': 'C:/personal/private.txt',
            'inkVaultNoteId': null,
          }),
          node('draft', 'text', {'text': '편집한 본문'}),
        ],
        edges: [
          {
            'id': 'arrow',
            'fromNode': 'draft',
            'toNode': 'md',
            'label': '읽기',
            'toEnd': 'none',
          },
        ],
      );
      await saveBoard(second, [
        node('back', 'file', {'file': first.id}),
      ]);
      final result = await export(first, firstBody);
      final bundle = result.bundle;
      final files = bundle.files;
      final board = decode(files[bundle.entrypoint]!);
      Map<String, dynamic> card(String id) => jsonObject(
        (board['nodes'] as List).singleWhere((value) => value['id'] == id),
      );
      expect(bundle.entrypoint, 'Boards/Plan.canvas');
      expect(card('group')['backgroundStyle'], 'ratio');
      expect(files[card('group')['background']], png);
      expect(card('md')['subpath'], '#실험 자료');
      expect(card('md')['file'], 'Reading renamed.md');
      expect(files[card('md')['file']], intro);
      expect(card('same')['file'], isNot(card('md')['file']));
      expect(utf8.decode(files[card('same')['file']]!), 'Different note');
      expect(card('pdf')['subpath'], '#page=1');
      expect(files[card('pdf')['file']], pdfBytes);
      expect(files[card('ppt')['file']], presentation);
      final child = decode(files[card('child')['file']]!);
      expect((child['nodes'] as List).single['file'], bundle.entrypoint);
      expect(card('external')['type'], 'text');
      expect(card('draft')['text'], '편집한 본문');
      expect((board['edges'] as List).single['label'], '읽기');
      expect(
        utf8.decode(files[bundle.entrypoint]!),
        isNot(contains('inkVaultNoteId')),
      );
      expect(
        utf8.decode(files[bundle.entrypoint]!),
        isNot(contains('C:/personal')),
      );
      expect(files.keys, isNot(contains('Unrelated private note.md')));
      expect(
        files.keys.where((name) => name.endsWith('.canvas')),
        hasLength(2),
      );
      expect(bundle.warnings, isNotEmpty);

      final zipped = bundle.toZip();
      final archive = ZipDecoder().decodeBytes(zipped, verify: true);
      addTearDown(archive.clearSync);
      expect(archive.map((file) => file.name), unorderedEquals(files.keys));
      final imported = await importObsidianVault(
        vaultsDirectory: Directory(p.join(temp.path, 'out')),
        sourceZip: zipped,
        sourceName: 'portable',
        native: native,
      );
      addTearDown(imported.repository.close);
      expect(imported.canvasCount, 2);
      expect(imported.noteCount, 2);
      expect(imported.attachmentCount, 3);
      final importedNotes = await WorkspaceStore(imported.repository).list();
      final root = importedNotes.singleWhere(
        (note) => note.title == 'Plan.canvas',
      );
      final head = (await imported.repository.heads(root.inkEntityId)).single;
      final reloaded = decode(
        await imported.repository.readRevisionFile(head, 'board.canvas'),
      );
      final importedMd = (reloaded['nodes'] as List).singleWhere(
        (node) => node['id'] == 'md',
      );
      expect(
        importedMd['inkVaultNoteId'],
        importedNotes.singleWhere((note) => note.title == 'Reading renamed').id,
      );
      final source = (await repo.heads(first.sourceEntityId!)).single;
      expect(await repo.readRevisionFile(source, 'Plan.canvas'), original);
      await result.ensureCurrent();
      await saveBoard(first, [
        node('new', 'text', {'text': 'later'}),
      ]);
      await expectLater(result.ensureCurrent(), throwsStateError);
    },
    skip: skip,
  );
}
