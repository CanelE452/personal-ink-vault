import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pdf;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/obsidian_vault_export.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  final nativePath = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  test('exports portable links to same-name notes, PDF pages and a PDF summary', () async {
    final temporary = await Directory.systemTemp.createTemp('piv-links-out-');
    addTearDown(() async {
      final owned = await temporary.resolveSymbolicLinks();
      expect(
        p.dirname(owned),
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      expect(p.basename(owned), startsWith('piv-links-out-'));
      await Directory(owned).delete(recursive: true);
    });
    final native = InkVaultNative.open(libraryPath: nativePath);
    final repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'vault')),
      createFormatVersion: 2,
    );
    addTearDown(repository.close);
    final store = WorkspaceStore(repository, native: native);
    final library = LibraryStore(repository);
    final a = await library.createFolder('Study A');
    final b = await library.createFolder('Study B');
    final assets = await library.createFolder('Assets');
    await store.createMarkdown(
      'Result',
      Uint8List.fromList(utf8.encode('# First\nStudy A\n')),
      folderId: a.id,
    );
    await store.createMarkdown(
      'Result',
      Uint8List.fromList(utf8.encode('# Details\nStudy B\n')),
      folderId: b.id,
    );
    final handout = pdf.Document()
      ..addPage(pdf.Page(build: (_) => pdf.Text('First page')))
      ..addPage(pdf.Page(build: (_) => pdf.Text('Second page')));
    final paper = await store.createWithSource(
      'Article',
      fileName: 'Article.pdf',
      bytes: await handout.save(),
      documentKind: VaultDocumentKind.pdf,
      fromObsidian: true,
      folderId: assets.id,
    );
    final paperSession = await store.open(paper);
    await paperSession.saveMarkdown('# Summary\nWindows summary\n');
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQKNj3H4QZYAwATRAJNQkgY7wAAAAASUVORK5CYII=',
    );
    await store.createWithSource(
      'Figure',
      fileName: 'Figure.png',
      bytes: png,
      documentKind: VaultDocumentKind.image,
      fromObsidian: true,
      folderId: assets.id,
    );
    await store.createMarkdown(
      'Index',
      Uint8List.fromList(
        utf8.encode(
          '---\n'
          'related: ["[[${paper.id}#Summary|Study summary]]"] # keep this comment\n'
          '---\n\n'
          '# Links\n\n'
          '[[Result#First|A note]]\n\n'
          '[B note](<../Study%20B/Result.md#Details>)\n\n'
          '[Paper summary](inkvault://note/${paper.id}?view=markdown#Summary)\n\n'
          '[[/Assets/Article.pdf#page=2|Paper page 2]]\n\n'
          '![[/Assets/Figure.png]]\n',
        ),
      ),
      folderId: a.id,
    );
    final output = await buildObsidianVaultExport(
      repository: repository,
      native: native,
    );
    const host = 'Study A/Index.md';
    expect(
      utf8.decode(output.files[host]!),
      contains(
        'related: ["[[/Assets/Article#Summary|Study summary]]"] # keep this comment',
      ),
    );
    expect(
      utf8.decode(output.files[host]!),
      contains('[[/Study A/Result#First|A note]]'),
    );
    expect(
      utf8.decode(output.files[host]!),
      contains('[B note](<../Study%20B/Result.md#Details>)'),
    );
    expect(
      utf8.decode(output.files[host]!),
      contains('[Paper summary](../Assets/Article.md#Summary)'),
    );
    expect(
      utf8.decode(output.files[host]!),
      contains('[[/Assets/Article.pdf#page=2|Paper page 2]]'),
    );
    expect(
      utf8.decode(output.files['Assets/Article.md']!),
      contains('Windows summary'),
    );
    expect(output.files['Assets/Figure.png'], png);
    final exportDirectory = Platform.environment['PIV_OBSIDIAN_GUI_FIXTURE'];
    if (exportDirectory != null) {
      final target = Directory(exportDirectory);
      expect(target.existsSync(), isTrue);
      final archive = File(p.join(target.path, 'vault.zip'));
      final expectation = File(p.join(target.path, 'expectation.json'));
      await archive.create(exclusive: true);
      await archive.writeAsBytes(
        encodeObsidianVaultZip(files: output.files, folders: output.folders),
      );
      await expectation.create(exclusive: true);
      await expectation.writeAsString(
        jsonEncode({
          'host': host,
          'links': [
            {'label': 'A note', 'path': 'Study A/Result.md'},
            {'label': 'B note', 'path': 'Study B/Result.md'},
            {'label': 'Paper summary', 'path': 'Assets/Article.md'},
            {'label': 'Paper page 2', 'path': 'Assets/Article.pdf', 'page': 2},
          ],
          'image': {'path': 'Assets/Figure.png'},
          'propertyLinks': [
            {
              'key': 'related.0',
              'path': 'Assets/Article.md',
              'anchor': '#Summary',
            },
          ],
        }),
      );
    }
  }, skip: nativePath == null);
}
