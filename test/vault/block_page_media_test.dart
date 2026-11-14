import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';

Uint8List _json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
BlockPageMediaAsset _image() => BlockPageMediaAsset.image(
  name: '사진.png',
  bytes: im.encodePng(im.Image(width: 2, height: 3)),
);
(BlockPageDocument, String) _page(BlockPageMediaAsset asset) {
  final block = BlockPageBlock.create(type: 'image', text: '사진 [caption]');
  return (
    const BlockPageDocument.empty().copyWith(
      blocks: [block],
      media: {block.id: asset.reference},
    ),
    block.id,
  );
}

Map<String, Uint8List> _files(
  BlockPageDocument page,
  BlockPageMediaAsset asset,
) => {'page.json': _json(page.toJson()), asset.reference.path: asset.bytes};

void main() {
  test('v1 unknown image and reserved-looking JSON remain opaque', () {
    final raw = <String, dynamic>{
      'version': 1,
      'blockMedia': {
        'futureSchema': ['keep', 2],
      },
      'future': {'keep': true},
      'blocks': [
        {
          'id': newId(),
          'type': 'image',
          'text': 'Old opaque block',
          'media': {'url': 'https://example.invalid/private'},
        },
      ],
    };
    final page = BlockPageDocument.fromJson(raw);
    expect(page.version, 1);
    expect(page.media, isEmpty);
    expect(page.toJson(), raw);
    expect(page.toMarkdown(), 'Old opaque block');
    expect(page.copyWith().toJson(), raw);
  });

  test(
    'media upgrades to v2 without dropping unknown page or block fields',
    () {
      final asset = _image(), id = newId();
      final page = BlockPageDocument.fromJson({
        'version': 1,
        'future': {'keep': true},
        'blocks': [
          {
            'id': id,
            'type': 'image',
            'text': 'Caption',
            'future': [1, 2],
          },
        ],
      }).copyWith(media: {id: asset.reference});
      expect(page.version, 2);
      expect(page.toJson()['blockMedia'], {id: asset.reference.toJson()});
      expect(page.toJson()['future'], {'keep': true});
      expect((page.toJson()['blocks'] as List).single['future'], [1, 2]);
      expect(BlockPageDocument.fromJson(page.toJson()).toJson(), page.toJson());
      expect(() => page.media[id] = asset.reference, throwsUnsupportedError);
    },
  );

  test(
    'v1 opaque registry collision is rejected with original JSON intact',
    () {
      final asset = _image(), block = BlockPageBlock.create(type: 'image');
      final raw = <String, dynamic>{
        'version': 1,
        'blockMedia': {'opaque': 'must survive'},
        'blocks': [block.toJson()],
      };
      final page = BlockPageDocument.fromJson(raw);
      expect(
        () => page.copyWith(media: {block.id: asset.reference}),
        throwsFormatException,
      );
      expect(page.toJson(), raw);
    },
  );

  test('unregistered per-block media remains opaque even in a v2 document', () {
    final opaque = BlockPageBlock.fromJson({
      'id': newId(),
      'type': 'image',
      'text': 'Opaque',
      'media': {'not': 'a descriptor'},
    });
    final block = BlockPageBlock.create(type: 'image'), asset = _image();
    final page = const BlockPageDocument.empty().copyWith(
      blocks: [opaque, block],
      media: {block.id: asset.reference},
    );
    expect(page.media.keys, [block.id]);
    expect(page.blocks.first.toJson(), opaque.toJson());
    expect(page.toMarkdown(), startsWith('Opaque'));
  });

  test(
    'removal and type changes prune registry while undo and v2 are retained',
    () {
      final asset = _image(), child = BlockPageBlock.create(type: 'image');
      final parent = BlockPageBlock.create(type: 'toggle')
          .copyWith(children: [child]);
      final before = const BlockPageDocument.empty().copyWith(
        blocks: [parent],
        media: {child.id: asset.reference},
      );
      final removed = before.copyWith(blocks: [parent.copyWith(children: [])]);
      expect(removed.media, isEmpty);
      expect(removed.version, 2);
      expect(BlockPageDocument.fromJson(removed.toJson()).version, 2);
      final undone = removed.copyWith(
        blocks: before.blocks,
        media: before.media,
      );
      expect(undone.toJson(), before.toJson());
      expect(
        before
            .copyWith(
              blocks: [
                parent.copyWith(children: [child.copyWith(type: 'paragraph')]),
              ],
            )
            .media,
        isEmpty,
      );
    },
  );

  test('v2 registry must identify existing image or attachment block IDs', () {
    final asset = _image(), block = BlockPageBlock.create(type: 'image');
    final invalid = <Map<String, dynamic>>[
      {
        'version': 2,
        'blocks': [block.toJson()],
        'blockMedia': [],
      },
      {
        'version': 2,
        'blocks': [block.toJson()],
        'blockMedia': {newId(): asset.reference.toJson()},
      },
      {
        'version': 2,
        'blocks': [block.copyWith(type: 'paragraph').toJson()],
        'blockMedia': {block.id: asset.reference.toJson()},
      },
      {
        'version': 2,
        'blocks': [block.toJson()],
        'blockMedia': {'../other': asset.reference.toJson()},
      },
    ];
    for (final raw in invalid) {
      expect(() => BlockPageDocument.fromJson(raw), throwsFormatException);
    }
  });

  test('Markdown uses escaped media labels and hash-bound relative paths', () {
    final asset = _image(),
        image = BlockPageBlock.create(type: 'image', text: '사진 [caption]');
    final block = BlockPageBlock.create(type: 'attachment', text: '');
    final file = BlockPageMediaAsset.attachment(
      name: '강의 [자료].pdf',
      bytes: [37, 80, 68, 70, 45],
      mimeType: 'application/pdf',
    );
    final page = const BlockPageDocument.empty().copyWith(
      blocks: [image, block],
      media: {image.id: asset.reference, block.id: file.reference},
    );
    expect(
      page.toMarkdown(),
      contains('![사진 \\[caption\\]](${asset.reference.path})'),
    );
    expect(
      page.toMarkdown(),
      contains('[강의 \\[자료\\].pdf](${file.reference.path})'),
    );
  });

  test('PNG metadata is decoded and caller and exposed bytes are detached', () {
    final input = Uint8List.fromList(
      im.encodePng(im.Image(width: 2, height: 3)),
    );
    final before = Uint8List.fromList(input);
    final asset = BlockPageMediaAsset.image(name: '태블릿.PNG', bytes: input);
    expect(asset.reference.mimeType, 'image/png');
    expect(asset.reference.width, 2);
    expect(asset.reference.height, 3);
    expect(asset.reference.byteLength, before.length);
    expect(asset.reference.path, 'media/${asset.reference.sha256}.png');
    input.fillRange(0, input.length, 0);
    asset.bytes[0] = 0;
    expect(asset.bytes, before);
  });

  test('JPEG dimensions and media type are decoded from bytes', () {
    final asset = BlockPageMediaAsset.image(
      name: 'camera.jpg',
      bytes: im.encodeJpg(im.Image(width: 4, height: 2)),
    );
    expect(asset.reference.mimeType, 'image/jpeg');
    expect(asset.reference.width, 4);
    expect(asset.reference.height, 2);
    expect(asset.reference.path, endsWith('.jpg'));
  });

  test('attachment label never becomes a filesystem path', () {
    final input = Uint8List.fromList([0, 1, 2, 3]);
    final asset = BlockPageMediaAsset.attachment(
      name: '../한글 자료.PPTX',
      bytes: input,
    );
    expect(asset.reference.name, '../한글 자료.PPTX');
    expect(asset.reference.path, startsWith('media/'));
    expect(asset.reference.path, endsWith('.pptx'));
    expect(asset.reference.path, isNot(contains('..')));
    input[0] = 99;
    expect(asset.bytes, [0, 1, 2, 3]);
  });

  test('descriptor unknown JSON is copied and retained', () {
    final raw = <String, dynamic>{
      ..._image().reference.toJson(),
      'future': {
        'list': [1, 2],
      },
    };
    final ref = BlockPageMedia.fromJson(raw);
    (raw['future'] as Map)['list'].clear();
    final output = ref.toJson();
    expect(output['future'], {
      'list': [1, 2],
    });
    (output['future'] as Map)['list'].clear();
    expect(ref.toJson()['future'], {
      'list': [1, 2],
    });
  });

  test(
    'descriptors reject unsafe paths substituted hashes and malformed fields',
    () {
      final raw = _image().reference.toJson();
      final zero = List.filled(64, '0').join();
      final invalid = <Map<String, dynamic>>[
        {...raw, 'path': '../media/x.png'},
        {...raw, 'path': '/media/x.png'},
        {...raw, 'path': 'media\\x.png'},
        {...raw, 'path': 'media/%2e%2e/x.png'},
        {...raw, 'path': 'media/$zero.png'},
        {...raw, 'path': 'media/${raw['sha256']}.PNG'},
        {...raw, 'sha256': (raw['sha256'] as String).toUpperCase()},
        {...raw, 'byteLength': true},
        {...raw, 'byteLength': -1},
        {...raw, 'byteLength': 64 * 1024 * 1024 + 1},
        {...raw, 'mimeType': 'image/png\r\nx-injected: true'},
        {...raw, 'mimeType': 'not a MIME type'},
        {...raw, 'name': 12},
        {...raw, 'width': 0},
        {...raw, 'height': -1},
        {...raw, 'width': 40000001, 'height': 1},
        {...raw, 'height': null},
      ];
      for (final value in invalid) {
        expect(() => BlockPageMedia.fromJson(value), throwsFormatException);
      }
    },
  );

  test('empty unsupported damaged and oversized photo imports fail', () {
    for (final bytes in [
      <int>[],
      <int>[1, 2, 3],
      <int>[137, 80, 78, 71, 13, 10, 26, 10],
      Uint8List(20 * 1024 * 1024 + 1),
    ]) {
      expect(
        () => BlockPageMediaAsset.image(name: 'image.png', bytes: bytes),
        throwsFormatException,
      );
    }
  });

  test('attachments reject empty payloads and unsafe MIME declarations', () {
    expect(
      () => BlockPageMediaAsset.attachment(name: 'empty.bin', bytes: []),
      throwsFormatException,
    );
    expect(
      () => BlockPageMediaAsset.attachment(
        name: 'x.bin',
        bytes: [1],
        mimeType: 'application/octet-stream\ntext/html',
      ),
      throwsFormatException,
    );
  });

  test(
    'snapshot validates references and detaches every exposed byte buffer',
    () {
      final asset = _image();
      final (page, id) = _page(asset);
      final files = _files(page, asset), expected = asset.bytes;
      final snapshot = BlockPageMediaSnapshot.fromFiles(files);
      files[asset.reference.path]!.fillRange(0, expected.length, 0);
      snapshot.files[asset.reference.path]![0] = 0;
      snapshot.mediaBytes(id)[0] = 0;
      expect(snapshot.mediaBytes(id), expected);
      expect(snapshot.document.toJson(), page.toJson());
      expect(
        () => snapshot.files['foreign.bin'] = Uint8List(1),
        throwsUnsupportedError,
      );
    },
  );

  test('text save keeps binary opaque files and unreferenced media', () {
    final asset = _image();
    final (page, id) = _page(asset);
    final older = BlockPageMediaAsset.attachment(
      name: 'old.txt',
      bytes: [6, 5],
    );
    final previous = {
      ..._files(page, asset),
      'future/data.bin': Uint8List.fromList([9, 8, 7]),
      older.reference.path: older.bytes,
    };
    final edited = page.copyWith(
      blocks: [page.blocks.single.copyWith(text: '수정')],
    );
    final snapshot = BlockPageMediaSnapshot.prepare(
      edited,
      existingFiles: previous,
    );
    expect(snapshot.document.blocks.single.text, '수정');
    expect(snapshot.mediaBytes(id), asset.bytes);
    expect(snapshot.files['future/data.bin'], [9, 8, 7]);
    expect(snapshot.files[older.reference.path], older.bytes);
    expect(
      jsonDecode(utf8.decode(snapshot.files['page.json']!)),
      edited.toJson(),
    );
  });

  test('new image and JSON are prepared together with copied draft bytes', () {
    final asset = _image();
    final (page, id) = _page(asset);
    final pending = asset.bytes, before = asset.bytes;
    final snapshot = BlockPageMediaSnapshot.prepare(
      page,
      existingFiles: {
        'page.json': _json(const BlockPageDocument.empty().toJson()),
        'future.txt': Uint8List.fromList([77]),
      },
      addedFiles: {asset.reference.path: pending},
    );
    pending.fillRange(0, pending.length, 0);
    expect(snapshot.mediaBytes(id), before);
    expect(snapshot.files['future.txt'], [77]);
    expect(snapshot.document.version, 2);
  });

  test('ordinary save cannot downgrade a previous v2 snapshot to v1', () {
    final asset = _image();
    final (page, _) = _page(asset);
    expect(
      () => BlockPageMediaSnapshot.prepare(
        const BlockPageDocument.empty(),
        existingFiles: _files(page, asset),
      ),
      throwsFormatException,
    );
  });

  test('v1 snapshots retain opaque files and do not infer media', () {
    final block = BlockPageBlock.fromJson({
      'id': newId(),
      'type': 'image',
      'text': 'Old extension',
      'media': {'private': 'opaque'},
    });
    final page = const BlockPageDocument.empty().copyWith(blocks: [block]);
    final snapshot = BlockPageMediaSnapshot.prepare(
      page,
      existingFiles: {
        'page.json': _json(page.toJson()),
        'future/private.bin': Uint8List.fromList([1, 4, 9]),
      },
    );
    expect(snapshot.document.version, 1);
    expect(snapshot.document.media, isEmpty);
    expect(snapshot.files['future/private.bin'], [1, 4, 9]);
  });

  test('missing page or media never becomes a successful empty page', () {
    final asset = _image();
    final (page, _) = _page(asset);
    expect(() => BlockPageMediaSnapshot.fromFiles({}), throwsFormatException);
    expect(
      () =>
          BlockPageMediaSnapshot.fromFiles({'page.json': _json(page.toJson())}),
      throwsFormatException,
    );
    expect(() => BlockPageMediaSnapshot.prepare(page), throwsFormatException);
  });

  test('corrupt bytes or false length MIME and dimensions are rejected', () {
    final asset = _image();
    final (page, id) = _page(asset);
    final ref = asset.reference.toJson(), corrupt = asset.bytes;
    corrupt[corrupt.length - 1] ^= 1;
    expect(
      () => BlockPageMediaSnapshot.fromFiles({
        'page.json': _json(page.toJson()),
        asset.reference.path: corrupt,
      }),
      throwsFormatException,
    );
    for (final changed in [
      {...ref, 'byteLength': asset.reference.byteLength + 1},
      {...ref, 'mimeType': 'image/jpeg'},
      {...ref, 'width': 3},
      {...ref, 'height': 4},
    ]) {
      expect(
        () => BlockPageMediaSnapshot.fromFiles({
          ..._files(page, asset),
          'page.json': _json({
            'version': 2,
            'blocks': page.toJson()['blocks'],
            'blockMedia': {id: changed},
          }),
        }),
        throwsFormatException,
      );
    }
  });

  test(
    'added paths must be referenced and collisions must have identical bytes',
    () {
      final asset = _image();
      final (page, _) = _page(asset);
      expect(
        () => BlockPageMediaSnapshot.prepare(
          page,
          addedFiles: {
            'foreign.txt': Uint8List.fromList([1]),
          },
        ),
        throwsFormatException,
      );
      expect(
        () => BlockPageMediaSnapshot.prepare(
          page,
          existingFiles: _files(page, asset),
          addedFiles: {
            asset.reference.path: Uint8List.fromList([3, 2, 1]),
          },
        ),
        throwsFormatException,
      );
      expect(
        BlockPageMediaSnapshot.prepare(
          page,
          existingFiles: _files(page, asset),
          addedFiles: {asset.reference.path: asset.bytes},
        ).document.toJson(),
        page.toJson(),
      );
    },
  );

  test(
    'shared media references cannot disagree about the payload byte length',
    () {
      final asset = _image(), a = BlockPageBlock.create(type: 'image');
      final b = BlockPageBlock.create(type: 'image');
      expect(
        () => BlockPageMediaSnapshot.fromFiles({
          asset.reference.path: asset.bytes,
          'page.json': _json({
            'version': 2,
            'blocks': [a.toJson(), b.toJson()],
            'blockMedia': {
              a.id: asset.reference.toJson(),
              b.id: {
                ...asset.reference.toJson(),
                'byteLength': asset.reference.byteLength + 1,
              },
            },
          }),
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'snapshot byte budget includes opaque and unreferenced existing files',
    () {
      final sharedLarge = Uint8List(64 * 1024 * 1024);
      expect(
        () => BlockPageMediaSnapshot.fromFiles({
          'page.json': _json(const BlockPageDocument.empty().toJson()),
          'opaque-a.bin': sharedLarge,
          'opaque-b.bin': sharedLarge,
        }),
        throwsFormatException,
      );
    },
  );
}
