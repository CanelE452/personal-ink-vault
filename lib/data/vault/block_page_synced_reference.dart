import 'package:ink_vault_core/ink_vault_core.dart';

final class BlockSyncedReference {
  const new _(this.sourceNoteId, this.sourceBlockId);

  factory create({
    required String sourceNoteId,
    required String sourceBlockId,
  }) {
    validateId(sourceNoteId);
    validateId(sourceBlockId);
    return BlockSyncedReference._(sourceNoteId, sourceBlockId);
  }

  factory fromJson(Map<String, dynamic> json) {
    final noteId = json['sourceNoteId'];
    final blockId = json['sourceBlockId'];
    if (json.length != 3 ||
        json['format'] != format ||
        noteId is! String ||
        blockId is! String) {
      throw const FormatException('Invalid synced block reference');
    }
    return BlockSyncedReference.create(
      sourceNoteId: noteId,
      sourceBlockId: blockId,
    );
  }

  static const format = 'personal-ink-synced-block-1';
  final String sourceNoteId;
  final String sourceBlockId;

  Map<String, dynamic> toJson() => {
    'format': format,
    'sourceNoteId': sourceNoteId,
    'sourceBlockId': sourceBlockId,
  };
}
