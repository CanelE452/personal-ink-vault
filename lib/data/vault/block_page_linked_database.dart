import 'dart:convert';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_database.dart';

class BlockLinkedDatabase {
  new _(this.noteId, this.view, this._extra);

  factory create({required String noteId, required DatabaseView view}) =>
      BlockLinkedDatabase.fromJson({
        'format': format,
        'noteId': noteId,
        'view': view.toJson(),
      });

  factory fromJson(Map<String, dynamic> json) {
    final raw = _linkedCopy(json);
    if (raw.remove('format') != format) {
      throw const FormatException('Unsupported linked database format');
    }
    final noteId = raw.remove('noteId');
    final view = raw.remove('view');
    if (noteId is! String || view is! Map) {
      throw const FormatException('Invalid linked database reference');
    }
    validateId(noteId);
    return BlockLinkedDatabase._(
      noteId,
      DatabaseView.fromJson(Map<String, dynamic>.from(view)),
      raw,
    );
  }

  static const format = 'personal-ink-linked-database-1';
  final String noteId;
  final DatabaseView view;
  final Map<String, dynamic> _extra;

  BlockLinkedDatabase copyWith({DatabaseView? view}) =>
      BlockLinkedDatabase.fromJson({
        ...toJson(),
        if (view != null) 'view': view.toJson(),
      });

  Map<String, dynamic> toJson() => {
    ..._linkedCopy(_extra),
    'format': format,
    'noteId': noteId,
    'view': view.toJson(),
  };
}

Map<String, dynamic> _linkedCopy(Map<String, dynamic> raw) {
  try {
    return Map<String, dynamic>.from(jsonDecode(jsonEncode(raw)) as Map);
  } on Object {
    throw const FormatException('Expected JSON linked database data');
  }
}
