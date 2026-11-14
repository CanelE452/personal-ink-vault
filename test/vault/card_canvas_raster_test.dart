import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/card_canvas_raster.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory temp;
  late NoteRepository repository;
  late WorkspaceStore store;
  late InkVaultNative native;
  final png = Uint8List.fromList(
    image.encodePng(image.Image(width: 7, height: 3)),
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('piv-canvas-raster-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    store = WorkspaceStore(repository);
    native = InkVaultNative.open(
      libraryPath: Platform.environment['INK_VAULT_NATIVE_LIBRARY'],
    );
  });

  tearDown(() async {
    await repository.close();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final owned = await temp.resolveSymbolicLinks();
    expect(p.dirname(owned), root);
    expect(p.basename(owned), startsWith('piv-canvas-raster-'));
    await Directory(owned).delete(recursive: true);
  });

  CardCanvasNode group(String path) => CardCanvasNode.fromJson({
    'id': 'group',
    'type': 'group',
    'x': 0,
    'y': 0,
    'width': 100,
    'height': 100,
    'background': path,
  });

  test(
    'loads exact imported group paths and stable image file cards',
    () async {
      final media = await LibraryStore(repository).createFolder('Cafe\u0301');
      final imageNote = await store.createWithSource(
        'Cover label',
        fileName: 'Cover%20.png',
        bytes: png,
        documentKind: VaultDocumentKind.image,
        folderId: media.id,
        fromObsidian: true,
      );
      final note = await store.createMarkdown(
        'Regular note',
        Uint8List.fromList([65]),
      );
      final reader = CardCanvasRasterReader(
        repository,
        native: native,
        isCurrent: () => true,
      );
      final file = CardCanvasNode.note(
        id: 'file',
        noteId: imageNote.id,
        title: 'Image',
      );
      for (final node in [group('CAFÉ/cover%20.PNG'), file]) {
        final raster = await reader.read(node);
        expect(raster, isNotNull);
        expect((raster!.width, raster.height), (7, 3));
        expect(raster.bytes, png);
        expect(() => raster.bytes[0] = 0, throwsUnsupportedError);
      }
      for (final path in [
        'Cover%20.png',
        '../Café/Cover%20.png',
        'https://example.test/Cover.png',
        'Café/Cover .png',
      ]) {
        expect(await reader.read(group(path)), isNull);
      }
      expect(
        await reader.read(
          CardCanvasNode.note(id: 'text', noteId: note.id, title: 'Regular'),
        ),
        isNull,
      );
      expect(
        await reader.read(
          CardCanvasNode.fromJson({...file.toJson(), 'subpath': '#heading'}),
        ),
        isNull,
      );
    },
  );

  test('rejects corrupt, ambiguous and stale Canvas image sources', () async {
    Future<VaultNote> add(String filename, Uint8List bytes) =>
        store.createWithSource(
          filename,
          fileName: filename,
          bytes: bytes,
          documentKind: VaultDocumentKind.image,
          fromObsidian: true,
        );
    await add('Broken.png', Uint8List.fromList([0, 1, 2]));
    await add('Cover.png', png);
    await add('cover.PNG', png);
    var active = true;
    final reader = CardCanvasRasterReader(
      repository,
      native: native,
      isCurrent: () => active,
    );
    expect(await reader.read(group('Broken.png')), isNull);
    expect(await reader.read(group('Cover.png')), isNull);
    final good = await add('Unique.png', png);
    expect(
      await reader.read(group('Unique.png')),
      isNull,
      reason: 'prior catalog is stale',
    );
    final current = CardCanvasRasterReader(
      repository,
      native: native,
      isCurrent: () => active,
    );
    expect(await current.read(group('Unique.png')), isNotNull);
    await store.rename(good, 'New title');
    expect(await current.read(group('Unique.png')), isNull);
    active = false;
    expect(await current.read(group('Unique.png')), isNull);
  });
}
