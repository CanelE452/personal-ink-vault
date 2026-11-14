import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/obsidian_canvas_json.dart';

const _markdownId = '11111111-1111-4111-8111-111111111111';
const _pdfId = '22222222-2222-4222-8222-222222222222';

Map<String, Object?> _node(String id, String type) => {
  'id': id,
  'type': type,
  'x': -3.6,
  'y': 2.4,
  'width': 180.5,
  'height': 0.4,
};

void main() {
  test('exports standard fields, order, and linked vault paths', () {
    final input = <String, dynamic>{
      'privateRoot': 'hidden',
      'nodes': [
        {..._node('text', 'text'), 'text': '# 원문', 'color': '6', 'plugin': 42},
        {
          ..._node('note', 'file'),
          'inkVaultNoteId': _markdownId,
          'inkVaultTitle': 'private display label',
          'file': 'Old Path.md',
          'subpath': '#제목',
        },
        {..._node('pdf', 'file'), 'file': _pdfId, 'subpath': '#page=2'},
        {
          ..._node('group', 'group'),
          'label': '연구',
          'color': '#AB12cd',
          'background': 'assets/back.png',
          'backgroundStyle': 'repeat',
        },
        {..._node('url', 'link'), 'url': 'https://example.invalid/'},
      ],
      'edges': [
        {
          'id': 'edge',
          'fromNode': 'pdf',
          'fromSide': 'bottom',
          'fromEnd': 'arrow',
          'toNode': 'note',
          'toSide': 'left',
          'toEnd': 'none',
          'color': '4',
          'label': '연결',
          'plugin': 8,
        },
      ],
    };
    final document = CardCanvasDocument.fromJson(input);
    final warnings = <String>[];
    final exported = encodeObsidianCanvas(
      document,
      filePathFor: (id) => const {
        _markdownId: 'Notes/Café%20-제목.md',
        _pdfId: 'Assets/강의.pdf',
      }[id],
      imagePathFor: (path) =>
          path == 'assets/back.png' ? 'Assets/배경.png' : null,
      onWarning: (id, _) => warnings.add(id),
    );
    final decoded = jsonDecode(utf8.decode(exported)) as Map<String, dynamic>;
    expect(decoded.keys, ['nodes', 'edges']);
    final nodes = (decoded['nodes'] as List).cast<Map<String, dynamic>>();
    expect(nodes.map((node) => node['id']), [
      'text',
      'note',
      'pdf',
      'group',
      'url',
    ]);
    expect(nodes[0], {
      'id': 'text',
      'type': 'text',
      'x': -4,
      'y': 2,
      'width': 181,
      'height': 1,
      'color': '6',
      'text': '# 원문',
    });
    expect(nodes[1]['file'], 'Notes/Café%20-제목.md');
    expect(nodes[1]['subpath'], '#제목');
    expect(nodes[1].keys, isNot(contains('inkVaultNoteId')));
    expect(nodes[1].keys, isNot(contains('inkVaultTitle')));
    expect(nodes[2]['file'], 'Assets/강의.pdf');
    expect(nodes[2]['subpath'], '#page=2');
    expect(nodes[3]['label'], '연구');
    expect(nodes[3]['background'], 'Assets/배경.png');
    expect(nodes[3]['backgroundStyle'], 'repeat');
    expect(nodes[3]['color'], '#AB12cd');
    expect(nodes[4]['url'], 'https://example.invalid/');
    expect(decoded['edges'], [
      {
        'id': 'edge',
        'fromNode': 'pdf',
        'fromSide': 'bottom',
        'fromEnd': 'arrow',
        'toNode': 'note',
        'toSide': 'left',
        'toEnd': 'none',
        'color': '4',
        'label': '연결',
      },
    ]);
    expect(warnings, isEmpty);
    expect(document.toJson(), input);
  });

  test('warns about unavailable targets without exporting private paths', () {
    final document = CardCanvasDocument.fromJson({
      'nodes': [
        {
          ..._node('unbound', 'file'),
          'file': '../../private.md',
          'inkVaultNoteId': null,
        },
        {..._node('outside', 'file'), 'file': _markdownId},
        {..._node('unsafe', 'link'), 'url': 'file:///C:/private.txt'},
        {..._node('future', 'private-plugin'), 'opaque': 'private payload'},
        {
          ..._node('group', 'group'),
          'background': 'No Image.png',
          'backgroundStyle': 'ratio',
        },
        {
          ..._node('text', 'text'),
          'text': '[local](inkvault://note/$_markdownId)',
        },
        {
          ..._node('image', 'file'),
          'file': _pdfId,
          'subpath': '#no-image-subpath',
        },
      ],
      'edges': [
        {
          'id': 'preserved',
          'fromNode': 'unbound',
          'toNode': 'future',
          'fromSide': 'outside',
          'fromEnd': 'wrong',
          'toSide': 4,
          'toEnd': 2,
          'color': 'invalid',
          'label': 12,
        },
        {'id': 'dangling', 'fromNode': 'unbound', 'toNode': 'missing'},
      ],
    });
    final warnings = <(String, String)>[];
    final encoded = utf8.decode(
      encodeObsidianCanvas(
        document,
        filePathFor: (id) =>
            id == _markdownId ? '../unpacked.md' : 'Assets/image.webp',
        imagePathFor: (_) => null,
        onWarning: (id, message) => warnings.add((id, message)),
      ),
    );
    final decoded = jsonDecode(encoded) as Map<String, dynamic>;
    final nodes = (decoded['nodes'] as List).cast<Map<String, dynamic>>();
    expect(nodes.take(4).map((node) => node['type']), List.filled(4, 'text'));
    expect(
      nodes.take(4).every((node) => (node['text'] as String).isNotEmpty),
      isTrue,
    );
    expect(nodes[4].keys, isNot(contains('background')));
    expect(nodes[4].keys, isNot(contains('backgroundStyle')));
    expect(nodes[5]['text'], '[local](inkvault://note/$_markdownId)');
    expect(nodes[6].keys, isNot(contains('subpath')));
    expect(decoded['edges'], [
      {'id': 'preserved', 'fromNode': 'unbound', 'toNode': 'future'},
    ]);
    expect(
      warnings.map((value) => value.$1),
      containsAll([
        'unbound',
        'outside',
        'unsafe',
        'future',
        'group',
        'text',
        'image',
      ]),
    );
    expect(warnings.any((value) => value.$2.contains('dangling')), isTrue);
    for (final private in [
      '../../private.md',
      '../unpacked.md',
      'file:///C:/private.txt',
      'private payload',
    ]) {
      expect(encoded, isNot(contains(private)));
    }
  });

  test('rejects geometry outside the supported Canvas range', () {
    final document = CardCanvasDocument.fromJson({
      'nodes': [
        {..._node('node', 'text'), 'x': 1000000001, 'text': 'sample'},
      ],
    });
    expect(
      () => encodeObsidianCanvas(
        document,
        filePathFor: (_) => null,
        imagePathFor: (_) => null,
        onWarning: (_, _) {},
      ),
      throwsFormatException,
    );
  });
}
