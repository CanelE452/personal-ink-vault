part of 'workspace_database.dart';

final class DatabaseRowTemplate {
  new _(Map<String, dynamic> raw) : _raw = _freezeMap(raw);

  factory fromJson(Map<String, dynamic> json) {
    final raw = _copyMap(json);
    validateId(_id(raw['id']));
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty || name.trim().length > 120) {
      throw const FormatException('Invalid database row template name');
    }
    raw['name'] = name.trim();
    final values = _object(raw['values']);
    final types = _object(raw['propertyTypes']);
    if (values.length != types.length) {
      throw const FormatException('Invalid template property types');
    }
    for (final id in values.keys) {
      _id(id);
      final type = types[id];
      if (type is! String ||
          !databasePropertyTypes.contains(type) ||
          type == 'formula' ||
          type == 'rollup') {
        throw const FormatException('Invalid template property type');
      }
      DatabaseProperty.create(
        id: id,
        name: name,
        type: type,
      ).validateValue(values[id]);
    }
    BlockPageDocument.fromJson(_object(raw['body']));
    return DatabaseRowTemplate._(raw);
  }

  final Map<String, dynamic> _raw;
  String get id => _raw['id'] as String;
  String get name => _raw['name'] as String;
  Map<String, Object?> get values => _raw['values'] as Map<String, dynamic>;
  Map<String, dynamic> get body => _raw['body'] as Map<String, dynamic>;
  Map<String, dynamic> get _propertyTypes =>
      _raw['propertyTypes'] as Map<String, dynamic>;
  Map<String, dynamic> toJson() => _copyMap(_raw);
}

bool _editableTemplateField(DatabaseProperty property) =>
    databasePropertyTypes.contains(property.type) && !property.isComputed;

final _blockIdPattern = RegExp(
  r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
  caseSensitive: false,
);

Map<String, dynamic> _copyTemplateBody(
  Map<String, dynamic> raw, {
  String? rowId,
}) {
  final page = BlockPageDocument.fromJson(raw);
  final blockIds = <String, String>{};
  void collect(BlockPageBlock block) {
    blockIds[block.id] = rowId == null
        ? block.id
        : _rowTemplateBlockId(rowId, block.id);
    for (final child in block.children) {
      collect(child);
    }
  }

  for (final block in page.blocks) {
    collect(block);
  }

  bool hasLocalReference(Object? value) => switch (value) {
    final String text =>
      _blockIdPattern
          .allMatches(text)
          .any((match) => blockIds.containsKey(match.group(0)!.toLowerCase())),
    final List list => list.any(hasLocalReference),
    final Map map => map.entries.any(
      (entry) => hasLocalReference(entry.key) || hasLocalReference(entry.value),
    ),
    _ => false,
  };
  void checkReferences(Map<String, dynamic> value, Set<String> ownedKeys) {
    if (value.entries.any(
      (entry) =>
          !ownedKeys.contains(entry.key) &&
          (hasLocalReference(entry.key) || hasLocalReference(entry.value)),
    )) {
      throw const FormatException(
        'A template cannot copy ambiguous references to its own blocks',
      );
    }
  }

  void rewrite(Map<String, dynamic> block) {
    checkReferences(block, const {'id', 'children'});
    final id = block['id'] as String;
    block['id'] = blockIds[id]!;
    final children = block['children'] as List?;
    if (children != null) {
      for (final child in children) {
        rewrite(child as Map<String, dynamic>);
      }
    }
  }

  final body = _copyMap(raw);
  checkReferences(body, {'blocks', if (page.version >= 2) 'blockMedia'});
  for (final block in body['blocks'] as List) {
    rewrite(block as Map<String, dynamic>);
  }
  final registry = body['blockMedia'];
  if (page.version >= 2 && registry is Map) {
    body['blockMedia'] = {
      for (final entry in registry.entries) blockIds[entry.key]!: entry.value,
    };
  }
  return body;
}

String _rowTemplateBlockId(String rowId, String blockId) {
  final bytes = sha256
      .convert(utf8.encode('personal-ink-row-template/$rowId/$blockId'))
      .bytes
      .take(16)
      .toList();
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
