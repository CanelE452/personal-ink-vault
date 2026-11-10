import 'dart:convert';
import 'dart:math' as math;

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_inline_text.dart';
import 'package:saber/data/vault/block_page_linked_database.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_synced_reference.dart';
import 'package:saber/data/vault/block_page_table.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_database.dart';

class BlockPageDocument {
  const new empty()
    : _extra = const {},
      version = 1,
      blocks = const [],
      media = const {};
  new _(
    this._extra,
    this.version,
    List<BlockPageBlock> blocks,
    Map<String, BlockPageMedia> media,
  ) : blocks = List.unmodifiable(blocks),
      media = Map.unmodifiable(media) {
    final byId = <String, BlockPageBlock>{};
    var count = 0;
    void visit(BlockPageBlock block, int depth) {
      if (depth > 64 || ++count > 10000 || byId.containsKey(block.id)) {
        throw const FormatException('Invalid block hierarchy');
      }
      if (block.syncedBlock != null && block.children.isNotEmpty) {
        throw const FormatException(
          'A synced block reference cannot own children',
        );
      }
      final inlineData = block._raw['inlineData'];
      if (version >= 3 &&
          block.inlineText == null &&
          inlineData is Map &&
          inlineData['format'] == BlockInlineText.format) {
        throw const FormatException(
          'Legacy opaque inline metadata cannot be reinterpreted',
        );
      }
      byId[block.id] = block;
      for (final child in block.children) {
        visit(child, depth + 1);
      }
    }

    for (final block in blocks) {
      visit(block, 0);
    }
    for (final entry in media.entries) {
      validateId(entry.key);
      final block = byId[entry.key];
      if (block == null ||
          !const {'image', 'attachment'}.contains(block.type) ||
          block.type == 'image' && !entry.value.isImage) {
        throw const FormatException(
          'Page media must identify an image or attachment block',
        );
      }
    }
  }
  factory fromJson(Map<String, dynamic> json) {
    final raw = _copy(json);
    final version = raw.remove('version');
    if (version is! int ||
        !const {1, 2, 3}.contains(version) ||
        raw['blocks'] is! List) {
      throw const FormatException('Unsupported block page');
    }
    final blocks = raw.remove('blocks') as List;
    final media = <String, BlockPageMedia>{};
    if (version >= 2) {
      final registry = raw.containsKey('blockMedia')
          ? raw.remove('blockMedia')
          : <String, dynamic>{};
      for (final entry in _object(registry).entries) {
        media[entry.key] = BlockPageMedia.fromJson(_object(entry.value));
      }
    }
    return BlockPageDocument._(raw, version, [
      for (final block in blocks)
        BlockPageBlock._decode(_object(block), 0, typedInline: version >= 3),
    ], media);
  }
  factory template(String name) {
    final rows = switch (name) {
      'lecture' => [
        ('heading1', '강의 노트'),
        ('paragraph', '강의명 · 날짜'),
        ('heading2', '핵심 개념'),
        ('paragraph', ''),
        ('heading2', '질문'),
        ('todo', '복습할 내용'),
      ],
      'research' => [
        ('heading1', '연구 노트'),
        ('heading2', '연구 질문'),
        ('paragraph', ''),
        ('heading2', '방법과 근거'),
        ('paragraph', ''),
        ('todo', '다음 실험'),
      ],
      'meeting' => [
        ('heading1', '회의록'),
        ('paragraph', '날짜 · 참석자'),
        ('heading2', '안건'),
        ('bullet', ''),
        ('heading2', '결정 사항'),
        ('todo', '후속 작업'),
      ],
      'project' => [
        ('heading1', '프로젝트'),
        ('heading2', '목표'),
        ('paragraph', ''),
        ('heading2', '진행 계획'),
        ('todo', '다음 단계'),
        ('heading2', '관련 자료'),
      ],
      _ => throw const FormatException('Unknown block page template'),
    };
    return const BlockPageDocument.empty().copyWith(
      blocks: [
        for (final (type, text) in rows)
          BlockPageBlock.create(type: type, text: text),
      ],
    );
  }
  final Map<String, dynamic> _extra;
  final int version;
  final List<BlockPageBlock> blocks;
  final Map<String, BlockPageMedia> media;
  BlockPageDocument copyWith({
    List<BlockPageBlock>? blocks,
    Map<String, BlockPageMedia>? media,
    int? minimumVersion,
  }) {
    if (minimumVersion != null && !const {1, 2, 3}.contains(minimumVersion)) {
      throw const FormatException('Unsupported minimum page version');
    }
    final nextBlocks = blocks ?? this.blocks;
    var nextMedia = media ?? this.media;
    if (blocks != null && media == null) {
      final allowed = <String>{};
      void visit(BlockPageBlock block) {
        if (const {'image', 'attachment'}.contains(block.type)) {
          allowed.add(block.id);
        }
        for (final child in block.children) {
          visit(child);
        }
      }

      for (final block in nextBlocks) {
        visit(block);
      }
      nextMedia = {
        for (final entry in this.media.entries)
          if (allowed.contains(entry.key)) entry.key: entry.value,
      };
    }
    bool hasInline(BlockPageBlock block) =>
        block.inlineText != null || block.children.any(hasInline);
    final contentVersion = version == 3 || nextBlocks.any(hasInline)
        ? 3
        : version == 2 || nextMedia.isNotEmpty
        ? 2
        : 1;
    final nextVersion = math.max(contentVersion, minimumVersion ?? 1);
    if (version == 1 && nextVersion >= 2 && _extra.containsKey('blockMedia')) {
      throw const FormatException(
        'The page has opaque data in the reserved media registry',
      );
    }
    return BlockPageDocument._(_extra, nextVersion, nextBlocks, nextMedia);
  }

  BlockPageDocument duplicateBlock(String blockId) {
    final nextMedia = {...media};
    BlockPageBlock duplicate(BlockPageBlock block) {
      final id = newId();
      if (media[block.id] case final reference?) nextMedia[id] = reference;
      return block._withIdentityAndChildren(
        id,
        block.children.map(duplicate).toList(),
      );
    }

    List<BlockPageBlock>? insert(List<BlockPageBlock> siblings) {
      for (var index = 0; index < siblings.length; index++) {
        final block = siblings[index];
        if (block.id == blockId) {
          final ids = block._duplicableIds();
          if (ids == null ||
              ids.any((id) {
                final descriptor = media[id];
                return descriptor != null &&
                    _opaqueRefersToBlock(descriptor.toJson(), const {
                      'path',
                      'name',
                      'mimeType',
                      'byteLength',
                      'sha256',
                      'width',
                      'height',
                    }, ids);
              })) {
            throw const FormatException('Cannot safely duplicate this block');
          }
          return [
            ...siblings.take(index + 1),
            duplicate(block),
            ...siblings.skip(index + 1),
          ];
        }
        if (block.children.isEmpty) continue;
        final children = insert(block.children);
        if (children != null) {
          return [
            ...siblings.take(index),
            block._withIdentityAndChildren(block.id, children),
            ...siblings.skip(index + 1),
          ];
        }
      }
      return null;
    }

    final next = insert(blocks);
    if (next == null) throw const FormatException('Unknown block');
    return BlockPageDocument._(_extra, version, next, nextMedia);
  }

  BlockPageDocument moveBlockToColumn({
    required String blockId,
    required String? columnId,
  }) {
    BlockPageBlock? source;
    BlockPageBlock? originGroup;
    BlockPageBlock? originColumn;
    BlockPageBlock? destinationGroup;
    for (final root in blocks) {
      if (root.id == blockId) source = root;
      if (!root.isColumnLayout) continue;
      for (final column in root.children) {
        if (column.id == columnId) destinationGroup = root;
        for (final child in column.children) {
          if (child.id != blockId) continue;
          source = child;
          originGroup = root;
          originColumn = column;
          break;
        }
      }
    }
    final moved = source;
    if (moved == null ||
        moved._isColumnStructure ||
        originColumn?.id == columnId ||
        columnId != null && destinationGroup == null) {
      return this;
    }
    bool fitsInColumn(BlockPageBlock block, int depth) =>
        depth <= 64 &&
        block.children.every((child) => fitsInColumn(child, depth + 1));
    if (originColumn == null && !fitsInColumn(moved, 2)) return this;

    final nextBlocks = <BlockPageBlock>[];
    for (final root in blocks) {
      if (root.id == blockId) continue;
      if (root != originGroup && root != destinationGroup) {
        nextBlocks.add(root);
        continue;
      }
      nextBlocks.add(
        root.copyWith(
          children: [
            for (final column in root.children)
              if (column == originColumn || column.id == columnId)
                column.copyWith(
                  children: [
                    for (final child in column.children)
                      if (child.id != blockId) child,
                    if (column.id == columnId) moved,
                  ],
                )
              else
                column,
          ],
        ),
      );
      if (columnId == null && root == originGroup) nextBlocks.add(moved);
    }
    return copyWith(blocks: nextBlocks);
  }

  BlockPageDocument unwrapColumns(String groupId) {
    final index = blocks.indexWhere(
      (block) => block.id == groupId && block.isColumnLayout,
    );
    if (index < 0) return this;
    return copyWith(
      blocks: [
        ...blocks.take(index),
        for (final column in blocks[index].children) ...column.children,
        ...blocks.skip(index + 1),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    ..._copy(_extra),
    'version': version,
    'blocks': [for (final block in blocks) block.toJson()],
    if (version >= 2)
      'blockMedia': {
        for (final entry in media.entries) entry.key: entry.value.toJson(),
      },
  };
  String toMarkdown({bool includeInlineFormatting = true}) {
    final lines = <String>[];
    Iterable<BlockPageBlock?> rootProjection() sync* {
      for (final block in blocks) {
        if (!block.isColumnLayout) {
          yield block;
          continue;
        }
        for (final column in block.children) {
          yield null;
          yield* column.children;
        }
        yield null;
      }
    }

    void append(Iterable<BlockPageBlock?> blocks, int depth) {
      var number = 0;
      var crossedColumnBoundary = false;
      String? previousList;
      for (final block in blocks) {
        if (block == null) {
          number = 0;
          crossedColumnBoundary = true;
          continue;
        }
        final list = switch (block.type) {
          'numbered' => 'ordered',
          'bullet' || 'todo' => 'unordered',
          _ => null,
        };
        number = block.type == 'numbered' ? number + 1 : 0;
        final text =
            includeInlineFormatting &&
                const {
                  'paragraph',
                  'heading1',
                  'heading2',
                  'heading3',
                  'todo',
                  'bullet',
                  'numbered',
                  'quote',
                  'callout',
                  'toggle',
                  'table',
                  'image',
                  'attachment',
                }.contains(block.type)
            ? block.inlineText?.toMarkdown() ?? block.text
            : block.text;
        final prefix = '  ' * depth;
        final registered = media[block.id];
        final content = registered != null
            ? _mediaMarkdown(
                block,
                registered,
                inlineText: includeInlineFormatting ? block.inlineText : null,
              )
            : switch (block.type) {
                'table' when block.table != null => [
                  if (text.isNotEmpty) text,
                  block.table!.toMarkdown(),
                ].join('\n\n'),
                'heading1' => '# $text',
                'heading2' => '## $text',
                'heading3' => '### $text',
                'todo' => '- [${block.checked ? 'x' : ' '}] $text',
                'bullet' => '- $text',
                'numbered' => '$number. $text',
                'quote' => text.split('\n').map((line) => '> $line').join('\n'),
                'callout' =>
                  text.split('\n').map((line) => '> 💡 $line').join('\n'),
                'toggle' => '▸ $text',
                'code' => _code(text),
                'equation' => '\$\$\n$text\n\$\$',
                'divider' => '---',
                'documentLink' when block.noteId != null =>
                  '[${text.replaceAll('[', r'\[').replaceAll(']', r'\]')}](${NoteLink(block.noteId!)})',
                'linkedDatabase' when block.linkedDatabase != null =>
                  _linkedDatabaseMarkdown(block),
                'syncedBlock' when block.syncedBlock != null =>
                  _syncedBlockMarkdown(block),
                _ => text,
              };
        final visible = content.trim().isNotEmpty;
        if (visible || block.children.isNotEmpty) {
          // Blank lines alone do not separate adjacent lists in CommonMark.
          if (crossedColumnBoundary &&
              previousList != null &&
              (list == previousList || !visible)) {
            lines.addAll(['<!-- -->', '']);
          }
          crossedColumnBoundary = false;
          previousList = list;
        }
        lines.add(content.split('\n').map((line) => '$prefix$line').join('\n'));
        if (block.children.isNotEmpty) append(block.children, depth + 1);
        lines.add('');
      }
    }

    append(rootProjection(), 0);
    return lines.join('\n').trimRight();
  }

  String toSearchText() {
    final projection = toLinkProjection();
    return [
      toMarkdown(includeInlineFormatting: false),
      if (projection.isNotEmpty) projection,
    ].join('\n\n');
  }

  String toLinkProjection() {
    final links = <String>{};
    void visit(BlockPageBlock block) {
      final syncedBlock = block.syncedBlock;
      if (syncedBlock != null) {
        links.add('[synced-block](inkwiki:${syncedBlock.sourceNoteId})');
      }
      final linkedDatabase = block.linkedDatabase;
      if (linkedDatabase != null) {
        links.add('[linked-database](${NoteLink(linkedDatabase.noteId)})');
      }
      for (final run in block.inlineText?.runs ?? <BlockInlineRun>[]) {
        final link = run.link;
        final parsed = link == null ? null : NoteLink.parse(link);
        if (parsed != null) {
          final destination = NoteLink.markdown(
            parsed.noteId,
            parsed.markdownAnchor,
          );
          links.add('[inline-document]($destination)');
        }
      }
      for (final child in block.children) {
        visit(child);
      }
    }

    for (final block in blocks) {
      visit(block);
    }
    return links.join('\n');
  }
}

class BlockPageBlock {
  new _(
    this._raw,
    List<BlockPageBlock> children,
    this.table,
    this.linkedDatabase,
    this.syncedBlock,
    this.inlineText,
    this._typedInline,
  ) : children = List.unmodifiable(children);
  factory create({
    String type = 'paragraph',
    String text = '',
    String? noteId,
  }) => BlockPageBlock.fromJson({
    'id': newId(),
    'type': type,
    'text': text,
    'noteId': ?noteId,
  });
  factory createColumns() => BlockPageBlock.fromJson({
    'id': newId(),
    'type': 'columnList',
    'columnLayout': 1,
    'children': [
      for (var index = 0; index < 2; index++)
        {'id': newId(), 'type': 'column', 'columnLayout': 1},
    ],
  });
  factory createTable({int rows = 2, int columns = 2, String text = ''}) =>
      BlockPageBlock.fromJson({
        'id': newId(),
        'type': 'table',
        'text': text,
        'tableData': BlockPageTable.create(
          rows: rows,
          columns: columns,
        ).toJson(),
      });
  factory createLinkedDatabase({
    required String noteId,
    required DatabaseView view,
    String text = '',
  }) => BlockPageBlock.fromJson({
    'id': newId(),
    'type': 'linkedDatabase',
    'text': text,
    'linkedDatabaseData': BlockLinkedDatabase.create(
      noteId: noteId,
      view: view,
    ).toJson(),
  });
  factory createSyncedBlock({
    required BlockSyncedReference reference,
    String text = '',
  }) => BlockPageBlock.fromJson({
    'id': newId(),
    'type': 'syncedBlock',
    'text': text,
    'syncedBlockData': reference.toJson(),
  });
  factory fromJson(Map<String, dynamic> json) =>
      BlockPageBlock._decode(json, 0);
  factory _decode(
    Map<String, dynamic> json,
    int depth, {
    bool typedInline = false,
  }) {
    if (depth > 64) throw const FormatException('Block nesting is too deep');
    final raw = _copy(json);
    final id = raw['id'], type = raw['type'];
    if (id is! String ||
        type is! String ||
        type.isEmpty ||
        raw['text'] != null && raw['text'] is! String ||
        raw['checked'] != null && raw['checked'] is! bool ||
        raw['collapsed'] != null && raw['collapsed'] is! bool) {
      throw const FormatException('Invalid block data');
    }
    validateId(id);
    final noteId = raw['noteId'];
    if (noteId != null) {
      if (noteId is! String) throw const FormatException('Invalid linked note');
      validateId(noteId);
    }
    final tableData = raw['tableData'];
    final table =
        type == 'table' &&
            tableData is Map &&
            tableData['format'] == BlockPageTable.format
        ? BlockPageTable.fromJson(_object(tableData))
        : null;
    final linkedDatabaseData = raw['linkedDatabaseData'];
    final linkedDatabase =
        type == 'linkedDatabase' &&
            linkedDatabaseData is Map &&
            linkedDatabaseData['format'] == BlockLinkedDatabase.format
        ? BlockLinkedDatabase.fromJson(_object(linkedDatabaseData))
        : null;
    if (linkedDatabase != null &&
        noteId != null &&
        noteId != linkedDatabase.noteId) {
      throw const FormatException('Linked database source identities disagree');
    }
    final syncedData = raw['syncedBlockData'];
    final syncedBlock =
        type == 'syncedBlock' &&
            syncedData is Map &&
            syncedData['format'] == BlockSyncedReference.format
        ? BlockSyncedReference.fromJson(_object(syncedData))
        : null;
    if (syncedBlock != null &&
        noteId != null &&
        noteId != syncedBlock.sourceNoteId) {
      throw const FormatException('Synced block source identities disagree');
    }
    final inlineData = raw['inlineData'];
    final inlineText =
        typedInline &&
            inlineData is Map &&
            inlineData['format'] == BlockInlineText.format
        ? BlockInlineText.fromJson(
            _object(inlineData),
            text: raw['text'] as String? ?? '',
          )
        : null;
    final children = raw.remove('children');
    if (children != null && children is! List)
      throw const FormatException('Invalid block children');
    return BlockPageBlock._(
      raw,
      [
        if (children is List)
          for (final child in children)
            BlockPageBlock._decode(
              _object(child),
              depth + 1,
              typedInline: typedInline,
            ),
      ],
      table,
      linkedDatabase,
      syncedBlock,
      inlineText,
      typedInline,
    );
  }
  final Map<String, dynamic> _raw;
  final BlockPageTable? table;
  final BlockLinkedDatabase? linkedDatabase;
  final BlockSyncedReference? syncedBlock;
  final BlockInlineText? inlineText;
  final bool _typedInline;
  String get id => _raw['id'] as String;
  String get type => _raw['type'] as String;
  String get text => _raw['text'] as String? ?? '';
  String? get noteId =>
      linkedDatabase?.noteId ??
      syncedBlock?.sourceNoteId ??
      _raw['noteId'] as String?;
  bool get checked => _raw['checked'] == true;
  bool get collapsed => _raw['collapsed'] == true;
  bool get _isColumnStructure => type == 'columnList' || type == 'column';
  bool _isColumnWrapper(String wrapperType) =>
      type == wrapperType &&
      identical(_raw['columnLayout'], 1) &&
      text.isEmpty &&
      _raw.keys.every(const {'id', 'type', 'text', 'columnLayout'}.contains);
  bool get isColumnLayout =>
      _isColumnWrapper('columnList') &&
      children.length == 2 &&
      children.every(
        (column) =>
            column._isColumnWrapper('column') &&
            column.children.every((block) => !block._isColumnStructure),
      );
  final List<BlockPageBlock> children;

  bool get canDuplicate => _duplicableIds() != null;

  Set<String>? _duplicableIds() {
    final members = <BlockPageBlock>[];
    bool collect(BlockPageBlock block, {required bool columnWrapper}) {
      final supported = switch (block.type) {
        'columnList' => block.isColumnLayout,
        'column' => columnWrapper,
        'table' => block.table != null,
        'paragraph' ||
        'heading1' ||
        'heading2' ||
        'heading3' ||
        'todo' ||
        'bullet' ||
        'numbered' ||
        'quote' ||
        'callout' ||
        'toggle' ||
        'code' ||
        'equation' ||
        'divider' ||
        'documentLink' ||
        'image' ||
        'attachment' => true,
        _ => false,
      };
      if (!supported) return false;
      members.add(block);
      return block.children.every(
        (child) => collect(child, columnWrapper: block.type == 'columnList'),
      );
    }

    if (!collect(this, columnWrapper: false)) return null;
    final ids = {for (final block in members) block.id};
    return members.any((block) => block._refersToCopiedBlock(ids)) ? null : ids;
  }

  bool _refersToCopiedBlock(Set<String> ids) {
    if (_opaqueRefersToBlock(_raw, {
      'id',
      'type',
      'text',
      'noteId',
      'checked',
      'collapsed',
      if (inlineText != null) 'inlineData',
      if (table != null) 'tableData',
    }, ids)) {
      return true;
    }
    if (inlineText != null) {
      final inline = _raw['inlineData'] as Map;
      if (_opaqueRefersToBlock(inline, const {
            'format',
            'textSha256',
            'runs',
          }, ids) ||
          (inline['runs'] as List).any(
            (run) => _opaqueRefersToBlock(run as Map, const {
              'start',
              'end',
              'marks',
              'link',
            }, ids),
          )) {
        return true;
      }
    }
    if (table != null) {
      final tableData = _raw['tableData'] as Map;
      return _opaqueRefersToBlock(tableData, const {
            'format',
            'columns',
            'rows',
            'headerRow',
            'headerColumn',
          }, ids) ||
          (tableData['rows'] as List).cast<Map>().any(
            (row) =>
                _opaqueRefersToBlock(row, const {'id', 'cells'}, ids) ||
                (row['cells'] as List).any(
                  (cell) => _opaqueRefersToBlock(cell as Map, const {
                    'id',
                    'text',
                  }, ids),
                ),
          );
    }
    return false;
  }

  BlockPageBlock _withIdentityAndChildren(
    String id,
    List<BlockPageBlock> children,
  ) => BlockPageBlock._(
    id == this.id ? _raw : {..._raw, 'id': id},
    children,
    table,
    linkedDatabase,
    syncedBlock,
    inlineText,
    _typedInline,
  );

  BlockPageBlock copyWith({
    String? type,
    String? text,
    String? noteId,
    bool? checked,
    bool? collapsed,
    List<BlockPageBlock>? children,
    BlockPageTable? table,
    BlockLinkedDatabase? linkedDatabase,
    BlockInlineText? inlineText,
  }) {
    if (linkedDatabase != null &&
        this.linkedDatabase == null &&
        _raw.containsKey('linkedDatabaseData')) {
      throw const FormatException(
        'Opaque linked database metadata cannot be overwritten',
      );
    }
    if (inlineText != null &&
        this.inlineText == null &&
        _raw.containsKey('inlineData')) {
      throw const FormatException(
        'Opaque inline metadata cannot be overwritten',
      );
    }
    final nextText = text ?? this.text;
    if (inlineText != null && inlineText.text != nextText) {
      throw const FormatException('Inline text must match the block text');
    }
    final nextInline = inlineText ?? this.inlineText?.replaceText(nextText);
    final encoded = {
      ...toJson(),
      'type': ?type,
      'text': ?text,
      'noteId': ?noteId,
      'checked': ?checked,
      'collapsed': ?collapsed,
      if (table != null) 'tableData': table.toJson(),
      if (linkedDatabase != null) 'linkedDatabaseData': linkedDatabase.toJson(),
      if (nextInline != null) 'inlineData': nextInline.toJson(),
      if (children != null)
        'children': [for (final child in children) child.toJson()],
    };
    encoded.remove('children');
    final decoded = BlockPageBlock._decode(
      encoded,
      0,
      typedInline: _typedInline || nextInline != null,
    );
    // Existing children retain their own version context during an edit.
    return BlockPageBlock._(
      decoded._raw,
      children ?? this.children,
      decoded.table,
      decoded.linkedDatabase,
      decoded.syncedBlock,
      decoded.inlineText,
      decoded._typedInline,
    );
  }

  Map<String, dynamic> toJson() => {
    ..._copy(_raw),
    if (linkedDatabase != null) 'linkedDatabaseData': linkedDatabase!.toJson(),
    if (inlineText != null) 'inlineData': inlineText!.toJson(),
    if (children.isNotEmpty)
      'children': [for (final child in children) child.toJson()],
  };
}

final _blockIdInMetadata = RegExp(
  r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
  caseSensitive: false,
);

bool _opaqueRefersToBlock(Map fields, Set<String> known, Set<String> ids) {
  bool refers(Object? value) => switch (value) {
    final String text =>
      _blockIdInMetadata
          .allMatches(text)
          .any((match) => ids.contains(match[0]!.toLowerCase())),
    final List list => list.any(refers),
    final Map map => map.entries.any(
      (entry) => refers(entry.key) || refers(entry.value),
    ),
    _ => false,
  };
  return fields.entries.any(
    (entry) =>
        !known.contains(entry.key) &&
        (refers(entry.key) || refers(entry.value)),
  );
}

String _syncedBlockMarkdown(BlockPageBlock block) {
  final label = (block.text.isEmpty ? '동기화 블록 원본' : block.text)
      .replaceAll('\\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]')
      .replaceAll('\r', ' ')
      .replaceAll('\n', ' ');
  return '[$label](inkwiki:${block.syncedBlock!.sourceNoteId})';
}

String _linkedDatabaseMarkdown(BlockPageBlock block) {
  final label = (block.text.isEmpty ? '연결된 DB' : block.text)
      .replaceAll('\\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]')
      .replaceAll('\r', ' ')
      .replaceAll('\n', ' ');
  return '[$label](${NoteLink(block.linkedDatabase!.noteId)})';
}

Map<String, dynamic> _object(Object? raw) {
  if (raw is! Map) throw const FormatException('Expected block object');
  return Map<String, dynamic>.from(raw);
}

Map<String, dynamic> _copy(Map<String, dynamic> raw) {
  try {
    return _object(jsonDecode(jsonEncode(raw)));
  } on Object {
    throw const FormatException('Expected JSON block data');
  }
}

String _code(String text) {
  final runs = RegExp(r'`+').allMatches(text).map((match) => match[0]!.length);
  final fence = '`' * math.max(3, runs.fold(0, math.max) + 1);
  return '$fence\n$text\n$fence';
}

String _mediaMarkdown(
  BlockPageBlock block,
  BlockPageMedia media, {
  BlockInlineText? inlineText,
}) {
  final label = block.type == 'attachment' || block.text.isEmpty
      ? media.name
      : block.text;
  final escaped = label
      .replaceAll('\\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll(']', r'\]')
      .replaceAll('\r', ' ')
      .replaceAll('\n', ' ');
  final link = '${block.type == 'image' ? '!' : ''}[$escaped](${media.path})';
  if (inlineText != null && block.text.isNotEmpty) {
    final asset =
        '${block.type == 'image' ? '!' : ''}[${media.name.replaceAll('[', r'\[').replaceAll(']', r'\]')}](${media.path})';
    return '$asset\n\n${inlineText.toMarkdown()}';
  }
  return block.type == 'attachment' &&
          block.text.isNotEmpty &&
          block.text != media.name
      ? '$link\n\n${block.text}'
      : link;
}
