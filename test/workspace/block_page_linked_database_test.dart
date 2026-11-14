import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_linked_database.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_database.dart';

const linkedDatabaseFormat = 'personal-ink-linked-database-1';

Map<String, dynamic> linkedPage({int version = 1}) => {
  'version': version,
  if (version >= 2) 'blockMedia': <String, dynamic>{},
  'futurePage': {'keep': true},
  'blocks': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': newId(),
      'type': 'linkedDatabase',
      'text': '연구 할 일',
      'futureBlock': {
        'keep': [1, 2],
      },
      'linkedDatabaseData': <String, dynamic>{
        'format': linkedDatabaseFormat,
        'noteId': newId(),
        'view': DatabaseView.create(name: '진행 중', type: 'board').toJson(),
        'futureLink': {
          'keep': ['source'],
        },
      },
    },
  ],
};

Map<String, dynamic> linkedBlockOf(Map<String, dynamic> page) =>
    (page['blocks'] as List).single as Map<String, dynamic>;

Map<String, dynamic> linkedDataOf(Map<String, dynamic> page) =>
    linkedBlockOf(page)['linkedDatabaseData'] as Map<String, dynamic>;

Map<String, dynamic> copyJson(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

void main() {
  test('factory creates an independently configured source reference', () {
    final sourceId = newId();
    final sourceView = DatabaseView.fromJson({
      ...DatabaseView.create(name: '원본 보기', type: 'board').toJson(),
      'futureView': {'keep': true},
    });
    final block = BlockPageBlock.createLinkedDatabase(
      noteId: sourceId,
      view: sourceView,
      text: '강의 할 일',
    );
    expect(block.type, 'linkedDatabase');
    expect(block.noteId, sourceId);
    expect(block.linkedDatabase!.noteId, sourceId);
    expect(block.linkedDatabase!.view.toJson(), sourceView.toJson());
    final configured = block.copyWith(
      linkedDatabase: block.linkedDatabase!.copyWith(
        view: sourceView.copyWith(name: '이 페이지의 보기', type: 'table'),
      ),
    );
    expect(configured.id, block.id);
    expect(configured.text, block.text);
    expect(configured.linkedDatabase!.noteId, sourceId);
    expect(configured.linkedDatabase!.view.type, 'table');
    expect(configured.linkedDatabase!.view.toJson()['futureView'], {
      'keep': true,
    });
    expect(sourceView.type, 'board');
    expect(sourceView.name, '원본 보기');
    expect(
      BlockPageBlock.fromJson(copyJson(configured.toJson())).toJson(),
      configured.toJson(),
    );
  });

  test('typed reference copies preserve extensions and detached view data', () {
    final raw = linkedDataOf(linkedPage());
    final expected = copyJson(raw);
    final reference = BlockLinkedDatabase.fromJson(raw);
    final changed = reference.copyWith(
      view: reference.view.copyWith(name: '기간별', type: 'timeline'),
    );
    (expected['view'] as Map)['name'] = '기간별';
    (expected['view'] as Map)['type'] = 'timeline';
    expect(changed.toJson(), expected);
    expect(changed.noteId, reference.noteId);
    (raw['futureLink'] as Map)['keep'] = ['changed original'];
    final output = changed.toJson();
    (output['futureLink'] as Map)['keep'] = ['changed returned data'];
    expect(changed.toJson(), expected);
    expect(reference.view.name, '진행 중');
  });

  test(
    'opaque references cannot be replaced by a current typed configuration',
    () {
      for (final opaque in [
        {'noteId': 'legacy title'},
        {'format': 'future-linked-database-9', 'view': 'future'},
        ['future sequence'],
      ]) {
        final raw = linkedBlockOf(linkedPage());
        raw['linkedDatabaseData'] = opaque;
        final block = BlockPageBlock.fromJson(raw);
        expect(block.linkedDatabase, isNull);
        expect(
          () => block.copyWith(
            linkedDatabase: BlockLinkedDatabase.create(
              noteId: newId(),
              view: DatabaseView.create(),
            ),
          ),
          throwsFormatException,
        );
        expect(block.toJson(), raw);
      }
    },
  );

  test(
    'type conversion retains source metadata children and block identity',
    () {
      final child = BlockPageBlock.create(text: '관련 설명');
      final block = BlockPageBlock.createLinkedDatabase(
        noteId: newId(),
        view: DatabaseView.create(),
        text: '원본 DB',
      ).copyWith(children: [child]);
      final paragraph = block.copyWith(type: 'paragraph', text: '문단으로 보기');
      expect(paragraph.linkedDatabase, isNull);
      expect(
        paragraph.toJson()['linkedDatabaseData'],
        block.toJson()['linkedDatabaseData'],
      );
      final reloaded = BlockPageBlock.fromJson(copyJson(paragraph.toJson()));
      final restored = reloaded.copyWith(type: 'linkedDatabase');
      expect(restored.id, block.id);
      expect(restored.children.single.id, child.id);
      expect(restored.text, '문단으로 보기');
      expect(restored.linkedDatabase!.toJson(), block.linkedDatabase!.toJson());
    },
  );

  test(
    'direct reference decoding rejects unsupported formats and invalid sources',
    () {
      final raw = linkedDataOf(linkedPage());
      expect(
        () => BlockLinkedDatabase.fromJson({...raw, 'format': 'future-format'}),
        throwsFormatException,
      );
      expect(
        () => BlockLinkedDatabase.create(
          noteId: 'path/to/note',
          view: DatabaseView.create(),
        ),
        throwsFormatException,
      );
      expect(
        () => BlockLinkedDatabase.fromJson({...raw, 'view': 'table'}),
        throwsFormatException,
      );
    },
  );

  test(
    'future view definitions remain opaque within a valid linked reference',
    () {
      final raw = linkedDataOf(linkedPage());
      (raw['view'] as Map)['type'] = 'future-spatial-view';
      (raw['view'] as Map)['futureConfig'] = {
        'retain': [1, 2, 3],
      };
      final reference = BlockLinkedDatabase.fromJson(raw);
      expect(reference.view.type, 'future-spatial-view');
      expect(reference.toJson(), raw);
    },
  );

  test('known linked database marker rejects missing source or view', () {
    for (final field in ['noteId', 'view']) {
      final page = linkedPage();
      linkedDataOf(page).remove(field);
      expect(
        () => BlockPageDocument.fromJson(page),
        throwsFormatException,
        reason: 'Missing $field must not publish an editable DB reference',
      );
    }
  });

  test('known linked database marker requires a stable source note UUID', () {
    for (final id in [null, 7, '', '../notes', '연구 할 일', '${newId()}/view']) {
      final page = linkedPage();
      linkedDataOf(page)['noteId'] = id;
      expect(
        () => BlockPageDocument.fromJson(page),
        throwsFormatException,
        reason: 'The source must be a note ID, not a title or path: $id',
      );
    }
  });

  test('known linked database marker validates the embedded view shape', () {
    for (final value in [null, [], 'table', 1]) {
      final page = linkedPage();
      linkedDataOf(page)['view'] = value;
      expect(() => BlockPageDocument.fromJson(page), throwsFormatException);
    }
    for (final entry in <String, Object?>{
      'id': '../view',
      'name': '',
      'type': '',
      'filter': [],
      'sorts': 'title',
      'groupBy': 42,
      'visibleProperties': ['not-a-property-id'],
      'config': [],
    }.entries) {
      final page = linkedPage();
      (linkedDataOf(page)['view'] as Map)[entry.key] = entry.value;
      expect(
        () => BlockPageDocument.fromJson(page),
        throwsFormatException,
        reason: 'Invalid known view field: ${entry.key}',
      );
    }
  });

  test('a known linked source cannot contradict a retained noteId field', () {
    final page = linkedPage();
    linkedBlockOf(page)['noteId'] = newId();
    expect(() => BlockPageDocument.fromJson(page), throwsFormatException);
  });

  test('nested linked database references receive the same validation', () {
    final page = linkedPage();
    linkedDataOf(page)['noteId'] = 'wrong source';
    final child = linkedBlockOf(page);
    page['blocks'] = [
      {
        'id': newId(),
        'type': 'toggle',
        'text': '연구',
        'children': [child],
      },
    ];
    expect(() => BlockPageDocument.fromJson(page), throwsFormatException);
  });

  test('known linked block Markdown references the source stable ID', () {
    final raw = linkedPage();
    final sourceId = linkedDataOf(raw)['noteId'] as String;
    final page = BlockPageDocument.fromJson(raw);
    expect(page.toMarkdown(), contains('[연구 할 일](${NoteLink(sourceId)})'));
    expect(page.toMarkdown(), isNot(contains(linkedDatabaseFormat)));
  });

  test('linked caption escaping cannot split or replace the source URI', () {
    final raw = linkedPage();
    final sourceId = linkedDataOf(raw)['noteId'] as String;
    linkedBlockOf(raw)['text'] = '연구 [할 일]\\\n다음';
    final markdown = BlockPageDocument.fromJson(raw).toMarkdown();
    expect(markdown, contains(r'\[할 일\]'));
    expect(markdown, contains('](${NoteLink(sourceId)})'));
    expect(markdown.split('\n'), hasLength(1));
  });

  test('empty captions retain a readable linked database source link', () {
    final raw = linkedPage();
    linkedBlockOf(raw)['text'] = '';
    final sourceId = linkedDataOf(raw)['noteId'] as String;
    final markdown = BlockPageDocument.fromJson(raw).toMarkdown();
    expect(markdown, contains('[연결된 DB](${NoteLink(sourceId)})'));
  });

  test('link projection keeps the source even when the caption is a fence', () {
    final raw = linkedPage();
    final sourceId = linkedDataOf(raw)['noteId'] as String;
    linkedBlockOf(raw)['text'] = '```\n숨겨진 캡션';
    final page = BlockPageDocument.fromJson(raw);
    expect(page.toLinkProjection(), contains('(${NoteLink(sourceId)})'));
    expect(page.toSearchText(), contains('(${NoteLink(sourceId)})'));
  });

  test(
    'known metadata and view extensions survive unrelated edits and reload',
    () {
      final raw = linkedPage();
      final expected = copyJson(raw);
      final view = linkedDataOf(raw)['view'] as Map;
      view['futureView'] = {'color': 'teal'};
      (linkedDataOf(expected)['view'] as Map)['futureView'] = {'color': 'teal'};
      final page = BlockPageDocument.fromJson(raw);
      (linkedDataOf(raw)['futureLink'] as Map)['keep'] = ['mutated input'];
      final changed = page.copyWith(
        blocks: [
          page.blocks.single,
          BlockPageBlock.create(text: '별도 문단'),
        ],
      );
      final encoded = changed.toJson();
      expect((encoded['blocks'] as List).first, linkedBlockOf(expected));
      expect(encoded['futurePage'], expected['futurePage']);
      expect(BlockPageDocument.fromJson(copyJson(encoded)).toJson(), encoded);
      final detached = changed.toJson();
      ((((detached['blocks'] as List).first as Map)['linkedDatabaseData']
              as Map)['futureLink']
          as Map)['keep'] = [
        'mutated output',
      ];
      expect(
        (changed.toJson()['blocks'] as List).first,
        linkedBlockOf(expected),
      );
    },
  );

  test('opaque legacy and future link metadata is preserved without interpretation', () {
    for (final value in [
      {
        'noteId': 'legacy title',
        'foreign': [1, 2],
      },
      {'format': 'future-linked-database-9', 'view': 'not our schema'},
      ['future sequence'],
    ]) {
      final raw = linkedPage();
      linkedBlockOf(raw)['linkedDatabaseData'] = value;
      final originalBlock = copyJson(linkedBlockOf(raw));
      final page = BlockPageDocument.fromJson(raw);
      final changed = page.copyWith(
        blocks: [
          page.blocks.single,
          BlockPageBlock.create(text: '다른 문단'),
        ],
      );
      expect((changed.toJson()['blocks'] as List).first, originalBlock);
      expect(changed.toMarkdown(), contains('연구 할 일'));
      expect(changed.toMarkdown(), isNot(contains('inkvault://')));
    }
  });

  test('metadata on another block type remains opaque during conversion', () {
    final raw = linkedPage();
    linkedBlockOf(raw)['type'] = 'paragraph';
    linkedDataOf(raw)['noteId'] = 'retained old extension';
    final page = BlockPageDocument.fromJson(raw);
    expect(page.toJson(), raw);
    expect(page.toMarkdown(), '연구 할 일');
  });

  test('linked references preserve existing page version floors', () {
    for (final version in [1, 2, 3]) {
      final raw = linkedPage(version: version);
      final page = BlockPageDocument.fromJson(raw);
      final changed = page.copyWith(
        blocks: [page.blocks.single.copyWith(text: '이름만 변경')],
      );
      expect(changed.version, version);
      expect(
        BlockPageDocument.fromJson(copyJson(changed.toJson())).version,
        version,
      );
      expect(
        linkedDataOf(changed.toJson())['noteId'],
        linkedDataOf(raw)['noteId'],
      );
    }
  });
}
