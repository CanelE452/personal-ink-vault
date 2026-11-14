import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/vault/obsidian_vault_import.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pdfium = File(
    Platform.environment['PIV_PDF_ANCHOR_TEST_PDFIUM'] ??
        p.join('build', 'windows', 'x64', 'runner', 'Release', 'pdfium.dll'),
  ).absolute;
  const firstId = '94e409ae-fa39-4501-9b9a-e827ad490ddd';
  const secondId = 'cc16db1a-5da4-4ef1-865a-cd7979458249';
  late Directory temporary;
  late Directory vaults;
  late NoteRepository prior;
  late WorkspaceStore priorStore;

  group('StarNote PDF storage with PDFium', () {
    late String? previousPdfiumPath;
    setUpAll(() async {
      previousPdfiumPath = Pdfrx.pdfiumModulePath;
      Pdfrx.pdfiumModulePath = pdfium.path;
      await pdfrxInitialize(tmpPath: Directory.systemTemp.path);
    });
    tearDownAll(() => Pdfrx.pdfiumModulePath = previousPdfiumPath);

    setUp(() async {
      temporary = await Directory.systemTemp.createTemp('piv-starnote-');
      addTearDown(() async {
        final root = await Directory.systemTemp.resolveSymbolicLinks();
        final owned = await temporary.resolveSymbolicLinks();
        expect(p.dirname(owned), root);
        expect(p.basename(owned), startsWith('piv-starnote-'));
        await Directory(owned).delete(recursive: true);
      });
      vaults = Directory(p.join(temporary.path, 'vaults'));
      prior = await NoteRepository.open(
        Directory(p.join(vaults.path, 'prior')),
        createFormatVersion: 2,
      );
      addTearDown(prior.close);
      priorStore = WorkspaceStore(prior);
      await priorStore.createMarkdown(
        '기존 노트',
        Uint8List.fromList(utf8.encode('unchanged')),
      );
    });

    List<String> visibleVaults() => vaults
        .listSync(followLinks: false)
        .whereType<Directory>()
        .map((dir) => p.basename(dir.path))
        .where((name) => name != '.imports')
        .toList();

    test(
      'publishes a separate vault with the original PDFs as PDF notes',
      () async {
        final first = await _pdf('First source');
        final second = await _pdf('Second source');
        final archive = _collection(
          _note(firstId, '첫 번째.pdf', first),
          _note(secondId, '두 번째.pdf', second),
        );
        final originalArchive = Uint8List.fromList(archive);
        final result = await importStarNoteVault(
          archive: archive,
          vaultsDirectory: vaults,
        );
        expect(result.documents, 2);
        expect(
          p.equals(
            p.dirname(result.directory.path),
            await vaults.resolveSymbolicLinks(),
          ),
          isTrue,
        );
        expect(
          visibleVaults(),
          unorderedEquals(['prior', p.basename(result.directory.path)]),
        );
        expect(archive, orderedEquals(originalArchive));
        final reopened = await NoteRepository.open(result.directory);
        addTearDown(reopened.close);
        expect(reopened.vaultId, isNot(prior.vaultId));
        expect(reopened.integrityIssues, isEmpty);
        expect(reopened.pendingRevisionCount, 0);
        final notes = await WorkspaceStore(reopened).list();
        expect(notes.map((n) => n.title), unorderedEquals(['첫 번째', '두 번째']));
        for (final note in notes) {
          expect(note.documentKind, VaultDocumentKind.pdf);
          final source = (await reopened.heads(note.sourceEntityId!)).single;
          expect(source.ownerNoteId, note.id);
          expect(source.kind, EntityKind.attachment);
          expect(
            (await reopened.readFiles(source))['${note.title}.pdf'],
            orderedEquals(note.title == '첫 번째' ? first : second),
          );
        }
        expect((await priorStore.list()).single.title, '기존 노트');
      },
    );

    test('a later unreadable PDF leaves the previous vault intact', () async {
      final archive = _collection(
        _note(firstId, '첫 번째.pdf', await _pdf('Readable')),
        _note(secondId, '두 번째.pdf', utf8.encode('%PDF-1.7\ninvalid\n%%EOF\n')),
      );
      expect(readStarNotePdfSource(archive), hasLength(2));
      await expectLater(
        importStarNoteVault(archive: archive, vaultsDirectory: vaults),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('두 번째.pdf'),
          ),
        ),
      );
      expect(visibleVaults(), ['prior']);
      expect(Directory(p.join(vaults.path, '.imports')).existsSync(), isFalse);
      expect((await priorStore.list()).single.title, '기존 노트');
    });

    test('cleans staging if the active vault changes before publish', () async {
      final staging = Directory(p.join(vaults.path, '.imports'));
      final stale = StateError('active vault changed');
      var stagedRevisionCount = 0;
      final archive = _note(firstId, '단일.pdf', await _pdf('Only source'));
      await expectLater(
        importStarNoteVault(
          archive: archive,
          vaultsDirectory: vaults,
          requireCurrent: () {
            if (!staging.existsSync()) return;
            final contents = staging.listSync(
              recursive: true,
              followLinks: false,
            );
            stagedRevisionCount = contents
                .whereType<File>()
                .where(
                  (file) =>
                      p.basename(p.dirname(file.path)) == 'revisions' &&
                      p.extension(file.path) == '.json',
                )
                .length;
            if (stagedRevisionCount != 0) throw stale;
          },
        ),
        throwsA(same(stale)),
      );
      expect(stagedRevisionCount, 3);
      expect(staging.listSync(), isEmpty);
      expect(visibleVaults(), ['prior']);
      expect((await priorStore.list()).single.title, '기존 노트');
    });
  }, skip: !pdfium.existsSync() ? 'Set PIV_PDF_ANCHOR_TEST_PDFIUM' : false);
}

Future<Uint8List> _pdf(String text) =>
    (pw.Document()..addPage(pw.Page(build: (_) => pw.Text(text)))).save();

Uint8List _note(String id, String name, List<int> pdf) => _zip({
  '$id/resource/content/$name': pdf,
  '$id/note/pb/note_info': [8, 1],
});

Uint8List _collection(Uint8List first, Uint8List second) => _zip({
  '첫 번째.note': first,
  '두 번째.note': second,
  'extraInfo': utf8.encode('{"version":2}'),
});

Uint8List _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
