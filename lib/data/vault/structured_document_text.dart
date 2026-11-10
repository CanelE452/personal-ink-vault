import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_inline_text.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/workspace_database.dart';

String structuredDocumentText(String kind, Map<String, Uint8List> files) {
  if (kind == 'page') {
    final json = _body(files, 'page.json');
    return json == null ? '' : BlockPageDocument.fromJson(json).toSearchText();
  }
  if (kind == 'canvas') {
    final json = _body(files, 'board.canvas');
    if (json == null) return '';
    return CardCanvasDocument.fromJson(json).nodes
        .map((node) {
          if (node.type == 'text') return node.text ?? '';
          if (node.linkedNoteId == null) return '';
          final label = node.label
              ?.replaceAll(RegExp(r'[\r\n\t]+'), ' ')
              .trim();
          return label == null ? '' : BlockInlineText.plain(label).toMarkdown();
        })
        .join('\n\n');
  }
  if (kind == 'database') {
    final json = _body(files, 'database.json');
    if (json == null) return '';
    final db = WorkspaceDatabase.fromJson(json);
    return db.rows
        .where((row) => !row.archived)
        .map(
          (row) => [
            for (final property in db.properties)
              if (row.values[property.id] != null)
                '${property.name}: ${row.values[property.id]}',
            BlockPageDocument.fromJson(row.body).toSearchText(),
          ].join('\n'),
        )
        .join('\n\n');
  }
  return '';
}

String structuredDocumentLinkText(String kind, Map<String, Uint8List> files) {
  final name = switch (kind) {
    'page' => 'page.json',
    'canvas' => 'board.canvas',
    'database' => 'database.json',
    _ => null,
  };
  final json = name == null ? null : _body(files, name);
  if (json == null) return '';
  if (kind == 'page')
    return BlockPageDocument.fromJson(json).toLinkProjection();
  if (kind == 'canvas') {
    return CardCanvasDocument.fromJson(json).nodes
        .map((node) => node.linkedNoteId)
        .whereType<String>()
        .map((id) => '[[$id]]')
        .join('\n');
  }
  return WorkspaceDatabase.fromJson(json).rows
      .where((row) => !row.archived)
      .map((row) => BlockPageDocument.fromJson(row.body).toLinkProjection())
      .where((projection) => projection.isNotEmpty)
      .join('\n');
}

Map<String, dynamic>? _body(Map<String, Uint8List> files, String name) {
  final bytes = files[name];
  return bytes == null ? null : jsonObject(jsonDecode(utf8.decode(bytes)));
}
