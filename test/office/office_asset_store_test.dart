import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/office/office_asset_store.dart';

void main() {
  late Directory temp;
  late NoteRepository repository;
  late OfficeAssetStore store;
  late String assetId;
  late String noteId;
  late String sourceRevisionId;
  late Uint8List png;

  Future<void> allowWrite() async {}

  Matcher assetError(String code) =>
      isA<OfficeAssetException>().having((error) => error.code, 'code', code);

  Future<Map<String, Object?>> begin({
    String? id,
    Uint8List? bytes,
    String mimeType = 'image/png',
    String? digest,
    int? byteLength,
    Future<void> Function()? requireWrite,
  }) {
    final content = bytes ?? png;
    return store.begin(
      assetId: id ?? assetId,
      noteId: noteId,
      sourceRevisionId: sourceRevisionId,
      mimeType: mimeType,
      sha256: digest ?? sha256.convert(content).toString(),
      byteLength: byteLength ?? content.length,
      requireWrite: requireWrite ?? allowWrite,
    );
  }

  Future<Map<String, Object?>> append(
    List<int> bytes, {
    int offset = 0,
    Future<void> Function()? requireWrite,
  }) => store.append(
    assetId: assetId,
    noteId: noteId,
    sourceRevisionId: sourceRevisionId,
    offset: offset,
    base64Data: base64Encode(bytes),
    requireWrite: requireWrite ?? allowWrite,
  );

  Future<Map<String, Object?>> status() => store.status(
    assetId: assetId,
    noteId: noteId,
    sourceRevisionId: sourceRevisionId,
  );

  Future<Map<String, Object?>> seal({Future<void> Function()? requireWrite}) =>
      store.seal(
        assetId: assetId,
        noteId: noteId,
        sourceRevisionId: sourceRevisionId,
        requireWrite: requireWrite ?? allowWrite,
      );

  Future<void> upload() async {
    await begin();
    await append(png);
    await seal();
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('office-assets-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    store = OfficeAssetStore(repository);
    assetId = newId();
    noteId = newId();
    sourceRevisionId = newId();
    final image = im.Image(width: 3, height: 2);
    image.setPixelRgba(0, 0, 210, 30, 50, 255);
    png = im.encodePng(image);
  });

  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  test(
    'begin retries and repository reopen preserve the same upload',
    () async {
      final first = await begin();
      expect(first['assetId'], assetId);
      expect(first['state'], 'uploading');
      expect(first['receivedBytes'], 0);
      await append(png.sublist(0, 11));
      final retried = await begin();
      expect(retried['receivedBytes'], 11);
      await repository.close();
      repository = await NoteRepository.open(temp);
      store = OfficeAssetStore(repository);
      final resumed = await status();
      expect(resumed['noteId'], noteId);
      expect(resumed['sourceRevisionId'], sourceRevisionId);
      expect(resumed['receivedBytes'], 11);
      await append(png.sublist(11), offset: 11);
      expect((await seal())['state'], 'sealed');
    },
  );

  test(
    'a lost append response can be retried only with identical bytes',
    () async {
      await begin();
      final chunk = png.sublist(0, 11);
      await append(chunk);
      expect((await append(chunk))['receivedBytes'], 11);
      final altered = Uint8List.fromList(chunk)..[3] ^= 1;
      await expectLater(append(altered), throwsA(assetError('asset_conflict')));
      await expectLater(
        append(png.sublist(11), offset: 12),
        throwsA(assetError('asset_offset_mismatch')),
      );
      await expectLater(
        append(png.sublist(4, 15), offset: 4),
        throwsA(assetError('asset_offset_mismatch')),
      );
      expect((await status())['receivedBytes'], 11);
    },
  );

  test(
    'an append committed before its manifest is recovered after restart',
    () async {
      await begin();
      final manifestFile = File(
        '${temp.path}/.workspace/office-assets/$assetId/manifest.json',
      );
      final previousManifest = await manifestFile.readAsBytes();
      await append(png.sublist(0, 11));
      await manifestFile.writeAsBytes(previousManifest, flush: true);
      store = OfficeAssetStore(repository);
      expect((await status())['receivedBytes'], 11);
      expect((await append(png.sublist(0, 11)))['receivedBytes'], 11);
      await append(png.sublist(11), offset: 11);
      expect((await seal())['state'], 'sealed');
    },
  );

  test(
    'sealing verifies the payload and exposes immutable decoded bytes',
    () async {
      await upload();
      final result = await seal();
      expect(result['mimeType'], 'image/png');
      expect(result['sha256'], sha256.convert(png).toString());
      expect((result['width'], result['height']), (3, 2));
      final image = await store.readSealed(
        assetId: assetId,
        noteId: noteId,
        sourceRevisionId: sourceRevisionId,
      );
      final returned = image.bytes;
      returned[0] = 0;
      expect(image.bytes, orderedEquals(png));
      expect((await begin())['state'], 'sealed');
      await expectLater(append(png), throwsA(assetError('asset_conflict')));
    },
  );

  test('JPEG upload retains its actual type and dimensions', () async {
    final jpeg = im.encodeJpg(im.Image(width: 4, height: 3));
    await begin(bytes: jpeg, mimeType: 'image/jpeg');
    await append(jpeg);
    final result = await seal();
    expect(result['mimeType'], 'image/jpeg');
    expect((result['width'], result['height']), (4, 3));
  });

  test(
    'incomplete or hash-mismatched uploads remain available for recovery',
    () async {
      await begin(digest: '0' * 64);
      await append(png.sublist(0, 11));
      await expectLater(seal(), throwsA(assetError('asset_integrity_failed')));
      expect((await status())['receivedBytes'], 11);
      await append(png.sublist(11), offset: 11);
      await expectLater(seal(), throwsA(assetError('asset_integrity_failed')));
      expect((await status())['state'], 'uploading');
      expect(
        await File('${temp.path}/.workspace/office-assets/$assetId/data')
            .readAsBytes(),
        orderedEquals(png),
      );
    },
  );

  test(
    'matching hashes cannot seal corrupt images or a false MIME type',
    () async {
      final corrupt = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
      await begin(bytes: corrupt);
      await append(corrupt);
      await expectLater(seal(), throwsA(assetError('asset_integrity_failed')));
      assetId = newId();
      await begin(mimeType: 'image/jpeg');
      await append(png);
      await expectLater(seal(), throwsA(assetError('asset_integrity_failed')));
    },
  );

  test('read requires a sealed asset and rechecks on-disk integrity', () async {
    await begin();
    await expectLater(
      store.readSealed(
        assetId: assetId,
        noteId: noteId,
        sourceRevisionId: sourceRevisionId,
      ),
      throwsA(assetError('asset_not_sealed')),
    );
    await append(png);
    await seal();
    final data = File('${temp.path}/.workspace/office-assets/$assetId/data');
    final altered = Uint8List.fromList(png)..[png.length - 1] ^= 1;
    await data.writeAsBytes(altered, flush: true);
    await expectLater(
      store.readSealed(
        assetId: assetId,
        noteId: noteId,
        sourceRevisionId: sourceRevisionId,
      ),
      throwsA(assetError('asset_integrity_failed')),
    );
    expect(data.existsSync(), true);
  });

  test(
    'begin rejects invalid identities sizes hashes and MIME types',
    () async {
      for (final invalidId in [
        '../escape',
        '',
        'https://example.com/image.png',
      ]) {
        await expectLater(
          begin(id: invalidId),
          throwsA(assetError('invalid_argument')),
        );
      }
      for (final length in [-1, 0, 20 * 1024 * 1024 + 1]) {
        await expectLater(
          begin(byteLength: length),
          throwsA(assetError('invalid_argument')),
        );
      }
      await expectLater(
        begin(digest: 'not-a-hash'),
        throwsA(assetError('invalid_argument')),
      );
      await expectLater(
        begin(mimeType: 'image/svg+xml'),
        throwsA(assetError('invalid_argument')),
      );
      await begin();
      await expectLater(
        begin(byteLength: png.length + 1),
        throwsA(assetError('asset_conflict')),
      );
    },
  );

  test(
    'append enforces 128 KiB chunks and the declared total length',
    () async {
      await begin(byteLength: 128 * 1024 + 1);
      await expectLater(
        append(Uint8List(128 * 1024 + 1)),
        throwsA(assetError('invalid_argument')),
      );
      expect(
        (await append(Uint8List(128 * 1024)))['receivedBytes'],
        128 * 1024,
      );
      await expectLater(
        append([1, 2], offset: 128 * 1024),
        throwsA(assetError('invalid_argument')),
      );
      expect((await status())['receivedBytes'], 128 * 1024);
    },
  );

  test('reserved bytes share an 80 MiB quota across store instances', () async {
    final ids = List.generate(4, (_) => newId());
    for (final id in ids) {
      await begin(id: id, byteLength: 20 * 1024 * 1024);
    }
    store = OfficeAssetStore(repository);
    await expectLater(
      begin(byteLength: 1),
      throwsA(assetError('asset_quota_exceeded')),
    );
    await store.discard(
      assetId: ids.first,
      noteId: noteId,
      sourceRevisionId: sourceRevisionId,
      requireWrite: allowWrite,
    );
    expect((await begin())['state'], 'uploading');
  });

  test(
    '32 unfinished or sealed assets reserve slots until explicit discard',
    () async {
      final ids = List.generate(32, (_) => newId());
      for (final id in ids) {
        await begin(id: id, byteLength: 1);
      }
      await expectLater(begin(), throwsA(assetError('asset_quota_exceeded')));
      await store.discard(
        assetId: ids.first,
        noteId: noteId,
        sourceRevisionId: sourceRevisionId,
        requireWrite: allowWrite,
      );
      await begin();
      await append(png);
      await seal();
      assetId = newId();
      await expectLater(begin(), throwsA(assetError('asset_quota_exceeded')));
    },
  );

  test('all operations reject a foreign note or source revision without deleting bytes', () async {
    await upload();
    for (final binding in [(newId(), sourceRevisionId), (noteId, newId())]) {
      final wrongNote = binding.$1;
      final wrongSource = binding.$2;
      for (final operation in <Future<Object?> Function()>[
        () => store.begin(
          assetId: assetId,
          noteId: wrongNote,
          sourceRevisionId: wrongSource,
          mimeType: 'image/png',
          sha256: sha256.convert(png).toString(),
          byteLength: png.length,
          requireWrite: allowWrite,
        ),
        () => store.status(
          assetId: assetId,
          noteId: wrongNote,
          sourceRevisionId: wrongSource,
        ),
        () => store.append(
          assetId: assetId,
          noteId: wrongNote,
          sourceRevisionId: wrongSource,
          offset: 0,
          base64Data: base64Encode(png),
          requireWrite: allowWrite,
        ),
        () => store.seal(
          assetId: assetId,
          noteId: wrongNote,
          sourceRevisionId: wrongSource,
          requireWrite: allowWrite,
        ),
        () => store.readSealed(
          assetId: assetId,
          noteId: wrongNote,
          sourceRevisionId: wrongSource,
        ),
        () => store.discard(
          assetId: assetId,
          noteId: wrongNote,
          sourceRevisionId: wrongSource,
          requireWrite: allowWrite,
        ),
      ]) {
        await expectLater(
          operation(),
          throwsA(assetError('asset_binding_mismatch')),
        );
      }
    }
    expect((await status())['state'], 'sealed');
  });

  test(
    'a copied manifest from another vault is not owned by this repository',
    () async {
      await upload();
      final file = File(
        '${temp.path}/.workspace/office-assets/$assetId/manifest.json',
      );
      final manifest =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      manifest['vaultId'] = newId();
      await file.writeAsString(jsonEncode(manifest), flush: true);
      await expectLater(
        status(),
        throwsA(assetError('asset_binding_mismatch')),
      );
      await expectLater(
        store.discard(
          assetId: assetId,
          noteId: noteId,
          sourceRevisionId: sourceRevisionId,
          requireWrite: allowWrite,
        ),
        throwsA(assetError('asset_binding_mismatch')),
      );
      expect(
        File('${temp.path}/.workspace/office-assets/$assetId/data')
            .existsSync(),
        true,
      );
    },
  );

  test(
    'permission is checked again before begin publishes its manifest',
    () async {
      final revoked = StateError('permission revoked');
      var checks = 0;
      await expectLater(
        begin(
          requireWrite: () async {
            if (++checks > 1) throw revoked;
          },
        ),
        throwsA(same(revoked)),
      );
      await expectLater(status(), throwsA(assetError('asset_not_found')));
    },
  );

  test(
    'permission revoked before append or seal cannot publish new state',
    () async {
      await begin();
      final revoked = StateError('permission revoked');
      var checks = 0;
      await expectLater(
        append(
          png,
          requireWrite: () async {
            if (++checks > 1) throw revoked;
          },
        ),
        throwsA(same(revoked)),
      );
      expect((await status())['receivedBytes'], 0);
      await append(png);
      checks = 0;
      await expectLater(
        seal(
          requireWrite: () async {
            if (++checks > 2) throw revoked;
          },
        ),
        throwsA(same(revoked)),
      );
      expect((await status())['state'], 'uploading');
    },
  );

  test(
    'permission revoked before discard preserves the sealed upload',
    () async {
      await upload();
      final revoked = StateError('permission revoked');
      var checks = 0;
      await expectLater(
        store.discard(
          assetId: assetId,
          noteId: noteId,
          sourceRevisionId: sourceRevisionId,
          requireWrite: () async {
            if (++checks > 1) throw revoked;
          },
        ),
        throwsA(same(revoked)),
      );
      expect((await status())['state'], 'sealed');
    },
  );

  test(
    'store instances serialize writes against one repository instance',
    () async {
      await begin();
      final second = OfficeAssetStore(repository);
      final entered = Completer<void>();
      final release = Completer<void>();
      var blocked = false;
      final firstAppend = append(
        png.sublist(0, 11),
        requireWrite: () async {
          if (!blocked) {
            blocked = true;
            entered.complete();
            await release.future;
          }
        },
      );
      await entered.future;
      final secondAppend = second.append(
        assetId: assetId,
        noteId: noteId,
        sourceRevisionId: sourceRevisionId,
        offset: 11,
        base64Data: base64Encode(png.sublist(11)),
        requireWrite: allowWrite,
      );
      release.complete();
      await Future.wait([firstAppend, secondAppend]);
      expect((await seal())['state'], 'sealed');
    },
  );

  test(
    'discard preserves unowned directories and succeeds for owned uploads',
    () async {
      final unowned = Directory(
        '${temp.path}/.workspace/office-assets/$assetId',
      );
      await unowned.create(recursive: true);
      final sentinel = File('${unowned.path}/keep.txt');
      await sentinel.writeAsString('unowned');
      await expectLater(
        store.discard(
          assetId: assetId,
          noteId: noteId,
          sourceRevisionId: sourceRevisionId,
          requireWrite: allowWrite,
        ),
        throwsA(assetError('asset_not_found')),
      );
      expect(await sentinel.readAsString(), 'unowned');
      assetId = newId();
      await upload();
      await store.discard(
        assetId: assetId,
        noteId: noteId,
        sourceRevisionId: sourceRevisionId,
        requireWrite: allowWrite,
      );
      await expectLater(status(), throwsA(assetError('asset_not_found')));
    },
  );

  test(
    'an owned upload can still be discarded after its data is truncated',
    () async {
      await upload();
      await File('${temp.path}/.workspace/office-assets/$assetId/data')
          .writeAsBytes([1, 2, 3], flush: true);
      await expectLater(
        status(),
        throwsA(assetError('asset_integrity_failed')),
      );
      await store.discard(
        assetId: assetId,
        noteId: noteId,
        sourceRevisionId: sourceRevisionId,
        requireWrite: allowWrite,
      );
      await expectLater(status(), throwsA(assetError('asset_not_found')));
    },
  );

  for (final component in [
    '.workspace',
    'office-assets',
    'asset',
    'data',
    'manifest.json',
  ]) {
    test(
      'a linked $component staging component is rejected without touching its target',
      () async {
        final outside = await Directory.systemTemp.createTemp(
          'office-assets-outside-',
        );
        addTearDown(() => outside.delete(recursive: true));
        final sentinel = File('${outside.path}/keep.txt');
        await sentinel.writeAsString('untouched');
        String linkPath;
        String targetPath = outside.path;
        if (component == '.workspace') {
          linkPath = '${temp.path}/.workspace';
        } else if (component == 'office-assets') {
          await Directory('${temp.path}/.workspace').create();
          linkPath = '${temp.path}/.workspace/office-assets';
        } else {
          await begin();
          final folder = '${temp.path}/.workspace/office-assets/$assetId';
          if (component == 'asset') {
            await Directory(folder).delete(recursive: true);
            linkPath = folder;
          } else {
            linkPath = '$folder/$component';
            await File(linkPath).delete();
            final target = File('${outside.path}/target');
            await target.writeAsString('untouched');
            targetPath = target.path;
          }
        }
        final link = Link(linkPath);
        try {
          await link.create(targetPath);
        } on FileSystemException {
          markTestSkipped('This host cannot create filesystem links');
          return;
        }
        addTearDown(() async {
          if (FileSystemEntity.typeSync(link.path, followLinks: false) ==
              FileSystemEntityType.link) {
            await link.delete();
          }
        });
        if (component == '.workspace' || component == 'office-assets') {
          await expectLater(begin(), throwsA(assetError('asset_unsafe_path')));
        } else {
          await expectLater(status(), throwsA(assetError('asset_unsafe_path')));
          await expectLater(
            store.discard(
              assetId: assetId,
              noteId: noteId,
              sourceRevisionId: sourceRevisionId,
              requireWrite: allowWrite,
            ),
            throwsA(assetError('asset_unsafe_path')),
          );
        }
        expect(await sentinel.readAsString(), 'untouched');
        if (component == 'data' || component == 'manifest.json') {
          expect(await File(targetPath).readAsString(), 'untouched');
        }
      },
    );
  }
}
