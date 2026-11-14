import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/database_media_worker.dart';
import 'package:saber/data/vault/workspace_database.dart';

Uint8List _encode(WorkspaceDatabase database) =>
    Uint8List.fromList(utf8.encode(jsonEncode(database.toJson())));

BlockPageDocument _body(
  String blockId,
  BlockPageMedia reference, {
  String text = 'Caption',
  String type = 'attachment',
}) => const BlockPageDocument.empty().copyWith(
  blocks: [
    BlockPageBlock.fromJson({
      'id': blockId,
      'type': type,
      'text': text,
      'futureBlock': {
        'keep': [1, 2],
      },
    }),
  ],
  media: {blockId: reference},
);

void main() {
  late WorkspaceDatabase database;
  late DatabaseRow first;
  late DatabaseRow second;
  late BlockPageMediaAsset image;
  late BlockPageMediaAsset attachment;
  late String blockId;

  Map<String, Uint8List> files([WorkspaceDatabase? value]) => {
    'database.json': _encode(value ?? database),
    image.reference.path: image.bytes,
    attachment.reference.path: attachment.bytes,
    'future/opaque.bin': Uint8List.fromList([0, 255, 7]),
    // A DB snapshot must preserve this opaque file, not interpret it as a page.
    'page.json': Uint8List.fromList([255, 0, 253]),
  };
  WorkspaceDatabase changeCaption(String caption) {
    final body = BlockPageDocument.fromJson(first.body);
    return database.updateRow(
      first.copyWith(
        body: body
            .copyWith(blocks: [body.blocks.single.copyWith(text: caption)])
            .toJson(),
      ),
    );
  }

  setUp(() {
    image = BlockPageMediaAsset.image(
      name: '도표.png',
      bytes: im.encodePng(im.Image(width: 2, height: 3)),
    );
    attachment = BlockPageMediaAsset.attachment(
      name: '자료.txt',
      bytes: utf8.encode('한글 binary 😀'),
    );
    blockId = newId();
    first = DatabaseRow.fromJson({
      ...DatabaseRow.create().toJson(),
      'body': _body(blockId, image.reference, type: 'image').toJson(),
      'futureRow': {
        'keep': [3],
      },
    });
    // Block UUIDs are unique within a row page, not across all DB rows.
    second = DatabaseRow.create(
      body: _body(blockId, attachment.reference, text: 'Second row').toJson(),
    );
    database = WorkspaceDatabase.fromJson({
      ...WorkspaceDatabase.empty().addRow(first).addRow(second).toJson(),
      'futureDatabase': {
        'keep': [4, 5],
      },
    });
  });

  test('two row pages bind the same block UUID to their own binary files', () {
    final original = files();
    final snapshot = DatabaseMediaSnapshot.fromFiles(original);
    expect(snapshot.database.toJson(), database.toJson());
    expect(snapshot.mediaBytes(first.id, blockId), image.bytes);
    expect(snapshot.mediaBytes(second.id, blockId), attachment.bytes);
    expect(snapshot.files, original);
    expect(snapshot.files['page.json'], [255, 0, 253]);
  });

  test('prepare accepts added bytes registered by either row and preserves a full snapshot', () {
    final snapshot = DatabaseMediaSnapshot.prepare(
      database,
      addedFiles: {
        image.reference.path: image.bytes,
        attachment.reference.path: attachment.bytes,
      },
    );
    expect(snapshot.database.toJson(), database.toJson());
    expect(
      snapshot.files.keys,
      unorderedEquals([
        'database.json',
        image.reference.path,
        attachment.reference.path,
      ]),
    );
    expect(snapshot.mediaBytes(first.id, blockId), image.bytes);
    expect(snapshot.mediaBytes(second.id, blockId), attachment.bytes);
  });

  test(
    'caption-only saves retain other raw row maps and opaque unused files',
    () {
      final original = files();
      final changed = changeCaption('Changed 한글😀');
      final snapshot = DatabaseMediaSnapshot.prepare(
        changed,
        existingFiles: original,
      );
      expect(
        snapshot.database.rows.first.body['blocks'][0]['text'],
        'Changed 한글😀',
      );
      expect(snapshot.database.rows.last.toJson(), second.toJson());
      expect(
        snapshot.database.toJson()['futureDatabase'],
        database.toJson()['futureDatabase'],
      );
      for (final entry in original.entries) {
        if (entry.key != 'database.json')
          expect(snapshot.files[entry.key], entry.value);
      }
      expect(
        DatabaseMediaSnapshot.fromFiles(snapshot.files).database.toJson(),
        changed.toJson(),
      );
    },
  );

  test(
    'shared image paths allow independent row labels and one immutable payload',
    () {
      final renamed = BlockPageMedia.fromJson({
        ...image.reference.toJson(),
        'name': '다른 행의 이름.png',
        'futureDescriptor': {'keep': true},
      });
      final shared = database.updateRow(
        second.copyWith(body: _body(blockId, renamed).toJson()),
      );
      final snapshot = DatabaseMediaSnapshot.prepare(
        shared,
        addedFiles: {image.reference.path: image.bytes},
      );
      expect(snapshot.mediaBytes(first.id, blockId), image.bytes);
      expect(snapshot.mediaBytes(second.id, blockId), image.bytes);
      expect(snapshot.files, {
        'database.json': _encode(shared),
        image.reference.path: image.bytes,
      });
      expect(snapshot.database.rows.last.body, shared.rows.last.body);
    },
  );

  for (final field in ['mimeType', 'width', 'height']) {
    test('shared paths reject inconsistent cross-row $field descriptors', () {
      final changed = image.reference.toJson();
      changed[field] = field == 'mimeType'
          ? 'image/jpeg'
          : (changed[field] as int) + 1;
      final other = BlockPageMedia.fromJson(changed);
      final shared = database.updateRow(
        second.copyWith(body: _body(blockId, other).toJson()),
      );
      expect(
        () => DatabaseMediaSnapshot.prepare(
          shared,
          addedFiles: {image.reference.path: image.bytes},
        ),
        throwsFormatException,
      );
    });
  }

  test(
    'one shared path cannot disagree between image and non-image MIME metadata',
    () {
      final changed = image.reference.toJson()
        ..['mimeType'] = 'application/octet-stream'
        ..remove('width')
        ..remove('height');
      final other = BlockPageMedia.fromJson(changed);
      final shared = database.updateRow(
        second.copyWith(body: _body(blockId, other).toJson()),
      );
      expect(
        () => DatabaseMediaSnapshot.prepare(
          shared,
          addedFiles: {image.reference.path: image.bytes},
        ),
        throwsFormatException,
      );
    },
  );

  for (final failure in ['missing', 'hash', 'length']) {
    test(
      '$failure binary integrity failure is rejected by decoding and preparation',
      () {
        final damaged = files();
        if (failure == 'missing') {
          damaged.remove(image.reference.path);
        } else if (failure == 'hash') {
          damaged[image.reference.path]![0] ^= 1;
        } else {
          damaged[image.reference.path] = Uint8List.fromList([1]);
        }
        expect(
          () => DatabaseMediaSnapshot.fromFiles(damaged),
          throwsFormatException,
        );
        expect(
          () => DatabaseMediaSnapshot.prepare(database, existingFiles: damaged),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'archived row media is validated and readable as part of the same snapshot',
    () {
      final archived = database.archiveRow(first.id);
      final original = files(archived);
      final snapshot = DatabaseMediaSnapshot.fromFiles(original);
      expect(snapshot.mediaBytes(first.id, blockId), image.bytes);
      original.remove(image.reference.path);
      expect(
        () => DatabaseMediaSnapshot.fromFiles(original),
        throwsFormatException,
      );
    },
  );

  test('new bytes require a reference and cannot overwrite an existing logical path', () {
    final extra = BlockPageMediaAsset.attachment(
      name: 'extra.bin',
      bytes: [4, 5],
    );
    expect(
      () => DatabaseMediaSnapshot.prepare(
        database,
        existingFiles: files(),
        addedFiles: {extra.reference.path: extra.bytes},
      ),
      throwsFormatException,
    );
    final changed = image.bytes..[0] ^= 1;
    expect(
      () => DatabaseMediaSnapshot.prepare(
        database,
        existingFiles: files(),
        addedFiles: {image.reference.path: changed},
      ),
      throwsFormatException,
    );
  });

  test('database identity is stable across an ordinary save', () {
    final other = WorkspaceDatabase.fromJson({
      ...database.toJson(),
      'id': newId(),
    });
    expect(
      () => DatabaseMediaSnapshot.prepare(other, existingFiles: files()),
      throwsFormatException,
    );
  });

  test('same-row v2 downgrade is rejected while reorder and deletion keep identities intact', () {
    final downgraded = database.updateRow(
      first.copyWith(body: {'version': 1, 'blocks': []}),
    );
    expect(
      () => DatabaseMediaSnapshot.prepare(downgraded, existingFiles: files()),
      throwsFormatException,
    );
    final reordered = database.copyWith(rows: [second, first]);
    expect(
      DatabaseMediaSnapshot.prepare(
        reordered,
        existingFiles: files(),
      ).database.toJson(),
      reordered.toJson(),
    );
    final replaced = database.removeRow(first.id).addRow(DatabaseRow.create());
    expect(
      DatabaseMediaSnapshot.prepare(
        replaced,
        existingFiles: files(),
      ).database.toJson(),
      replaced.toJson(),
    );
  });

  test('a row v1 opaque blockMedia map stays raw and cannot be reinterpreted by upgrade', () {
    final opaqueBody = <String, dynamic>{
      'version': 1,
      'blocks': [
        {
          'id': newId(),
          'type': 'futureBlock',
          'opaque': {
            'keep': [1, 2],
          },
        },
      ],
      'blockMedia': {'opaque': 'old reserved extension'},
      'futureBody': {
        'keep': [8],
      },
    };
    final opaqueRow = first.copyWith(body: opaqueBody);
    final previous = database.updateRow(opaqueRow);
    final original = files(previous);
    final changed = previous.setCell(
      second.id,
      previous.properties.single.id,
      'Only a cell edit',
    );
    final snapshot = DatabaseMediaSnapshot.prepare(
      changed,
      existingFiles: original,
    );
    expect(snapshot.database.rows.first.body, opaqueBody);
    expect(snapshot.files['page.json'], [255, 0, 253]);
    expect(snapshot.files[image.reference.path], image.bytes);
    expect(
      () => DatabaseMediaSnapshot.prepare(database, existingFiles: original),
      throwsFormatException,
    );
  });

  test('removed row and removed block payloads remain immutable for history and undo', () {
    final original = files();
    final removed = DatabaseMediaSnapshot.prepare(
      database.removeRow(first.id),
      existingFiles: original,
    );
    expect(removed.files[image.reference.path], image.bytes);
    expect(() => removed.mediaBytes(first.id, blockId), throwsFormatException);
    final body = BlockPageDocument.fromJson(first.body).copyWith(blocks: []);
    final withoutBlock = database.updateRow(
      first.copyWith(body: body.toJson()),
    );
    final current = DatabaseMediaSnapshot.prepare(
      withoutBlock,
      existingFiles: original,
    );
    expect(current.files[image.reference.path], image.bytes);
    expect(() => current.mediaBytes(first.id, blockId), throwsFormatException);
    expect(
      DatabaseMediaSnapshot.fromFiles(original).mediaBytes(first.id, blockId),
      image.bytes,
    );
  });

  test('file paths and database.json are validated without reinterpreting opaque page.json', () {
    for (final path in [
      '../outside.bin',
      '/outside.bin',
      'media/../outside.bin',
    ]) {
      expect(
        () => DatabaseMediaSnapshot.fromFiles({...files(), path: Uint8List(1)}),
        throwsFormatException,
      );
    }
    expect(() => DatabaseMediaSnapshot.fromFiles({}), throwsFormatException);
    expect(
      () => DatabaseMediaSnapshot.fromFiles({
        'database.json': Uint8List.fromList(utf8.encode('[]')),
      }),
      throwsFormatException,
    );
  });

  test(
    'one 128 MiB budget covers the complete database including opaque files',
    () {
      final sharedBuffer = Uint8List(1024 * 1024);
      final oversized = <String, Uint8List>{
        ...files(),
        for (var i = 0; i < 129; i++) 'opaque/$i.bin': sharedBuffer,
      };
      // Logical size is >128 MiB; only one 1 MiB test buffer is allocated.
      expect(
        () => DatabaseMediaSnapshot.fromFiles(oversized),
        throwsFormatException,
      );
      expect(
        () => DatabaseMediaSnapshot.prepare(database, existingFiles: oversized),
        throwsFormatException,
      );
    },
  );

  test('adding a referenced row asset cannot bypass the shared existing-file budget', () {
    final sharedBuffer = Uint8List(1024 * 1024);
    final existing = <String, Uint8List>{
      ...files(),
      for (var i = 0; i < 126; i++) 'opaque/$i.bin': sharedBuffer,
    };
    final extra = BlockPageMediaAsset.attachment(
      name: 'extra.bin',
      bytes: Uint8List(2 * 1024 * 1024),
    );
    final candidate = database.addRow(
      DatabaseRow.create(body: _body(newId(), extra.reference).toJson()),
    );
    expect(
      () => DatabaseMediaSnapshot.prepare(
        candidate,
        existingFiles: existing,
        addedFiles: {extra.reference.path: extra.bytes},
      ),
      throwsFormatException,
    );
  });

  test('input maps, returned files, raw JSON and mediaBytes cannot mutate the owned snapshot', () {
    final original = files();
    final expectedImage = image.bytes;
    final snapshot = DatabaseMediaSnapshot.fromFiles(original);
    original[image.reference.path]![0] ^= 1;
    original.clear();
    final exposed = snapshot.files;
    exposed[image.reference.path]![0] ^= 1;
    final payload = snapshot.mediaBytes(first.id, blockId)..[0] ^= 1;
    expect(payload, isNot(expectedImage));
    expect(snapshot.mediaBytes(first.id, blockId), expectedImage);
    expect(snapshot.files[image.reference.path], expectedImage);
    final raw = snapshot.database.toJson();
    (raw['futureDatabase'] as Map)['keep'].clear();
    expect(snapshot.database.toJson()['futureDatabase'], {
      'keep': [4, 5],
    });
    final added = {
      image.reference.path: image.bytes,
      attachment.reference.path: attachment.bytes,
    };
    final prepared = DatabaseMediaSnapshot.prepare(database, addedFiles: added);
    added[image.reference.path]![0] ^= 1;
    added.clear();
    expect(prepared.mediaBytes(first.id, blockId), expectedImage);
  });

  test(
    'selectors reject invalid IDs and rows or blocks without registration',
    () {
      final snapshot = DatabaseMediaSnapshot.fromFiles(files());
      for (final ids in [
        ('../row', blockId),
        (first.id, '../block'),
        (newId(), blockId),
        (first.id, newId()),
      ]) {
        expect(
          () => snapshot.mediaBytes(ids.$1, ids.$2),
          throwsFormatException,
        );
      }
    },
  );

  test('worker decoding and preparation retain both row registrations and every existing file', () async {
    final original = files();
    final decoded = await decodeDatabaseMediaInWorker(original);
    expect(decoded.database.toJson(), database.toJson());
    expect(decoded.mediaBytes(first.id, blockId), image.bytes);
    expect(decoded.mediaBytes(second.id, blockId), attachment.bytes);
    final changed = changeCaption('Worker caption');
    final prepared = await prepareDatabaseMediaInWorker(
      changed,
      existingFiles: decoded.files,
      addedFiles: const {},
    );
    expect(prepared.database.toJson(), changed.toJson());
    for (final entry in original.entries) {
      if (entry.key != 'database.json')
        expect(prepared.files[entry.key], entry.value);
    }
  });

  test('worker failures do not return a partial snapshot', () async {
    final damaged = files()..remove(attachment.reference.path);
    await expectLater(
      decodeDatabaseMediaInWorker(damaged),
      throwsFormatException,
    );
    await expectLater(
      prepareDatabaseMediaInWorker(
        database,
        existingFiles: damaged,
        addedFiles: const {},
      ),
      throwsFormatException,
    );
  });
}
