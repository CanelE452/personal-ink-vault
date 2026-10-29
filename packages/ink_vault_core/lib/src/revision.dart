import 'dart:math';

enum EntityKind { metadata, ink, markdown }

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
final _hash = RegExp(r'^[0-9a-f]{64}$');

String newId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

void validateId(String value) {
  if (!_uuid.hasMatch(value)) throw const FormatException('Invalid UUID');
}

void validateHash(String value) {
  if (!_hash.hasMatch(value)) throw const FormatException('Invalid SHA-256');
}

void validateLogicalPath(String value) {
  if (value.isEmpty ||
      value.contains(RegExp(r'[\\:\x00-\x1f]')) ||
      value.split('/').any((p) => p.isEmpty || p == '.' || p == '..')) {
    throw const FormatException('Unsafe logical file path');
  }
}

Map<String, dynamic> jsonObject(Object? value) {
  if (value is! Map<String, dynamic>)
    throw const FormatException('Expected JSON object');
  return value;
}

String _string(Object? value) {
  if (value is! String) throw const FormatException('Expected string');
  return value;
}

List<String> _strings(Object? value) {
  if (value is! List) throw const FormatException('Expected string list');
  return value.map(_string).toList();
}

class BlobRef {
  final String hash;
  final int length;

  BlobRef({required this.hash, required this.length}) {
    validateHash(hash);
    if (length < 0) throw const FormatException('Invalid blob length');
  }

  Map<String, dynamic> toJson() => {'hash': hash, 'length': length};

  factory BlobRef.fromJson(Map<String, dynamic> json) {
    if (json['length'] is! int)
      throw const FormatException('Invalid blob length');
    return BlobRef(hash: _string(json['hash']), length: json['length'] as int);
  }
}

class RevisionRecord {
  final String vaultId;
  final String entityId;
  final EntityKind kind;
  final String revisionId;
  final List<String> parentRevisionIds;
  final String deviceId;
  final Map<String, BlobRef> blobs;
  final String? ownerNoteId;
  final bool deleted;
  final Map<String, List<String>> baseRefs;
  final int formatVersion;

  RevisionRecord({
    required this.vaultId,
    required this.entityId,
    required this.kind,
    required this.revisionId,
    required List<String> parentRevisionIds,
    required this.deviceId,
    required Map<String, BlobRef> blobs,
    this.ownerNoteId,
    this.deleted = false,
    Map<String, List<String>> baseRefs = const {},
    this.formatVersion = 1,
  }) : parentRevisionIds = List.unmodifiable(parentRevisionIds),
       blobs = Map.unmodifiable(blobs),
       baseRefs = Map.unmodifiable(
         baseRefs.map(
           (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
         ),
       ) {
    for (final id in [
      vaultId,
      entityId,
      revisionId,
      deviceId,
      if (ownerNoteId != null) ownerNoteId!,
    ]) {
      validateId(id);
    }
    if (formatVersion != 1)
      throw const FormatException('Unsupported revision format');
    if (this.parentRevisionIds.toSet().length !=
            this.parentRevisionIds.length ||
        this.parentRevisionIds.contains(revisionId)) {
      throw const FormatException('Duplicate or self parent');
    }
    for (final id in this.parentRevisionIds) {
      validateId(id);
    }
    for (final name in this.blobs.keys) {
      validateLogicalPath(name);
    }
    for (final entry in this.baseRefs.entries) {
      validateId(entry.key);
      if (entry.value.toSet().length != entry.value.length)
        throw const FormatException('Duplicate base reference');
      for (final id in entry.value) {
        validateId(id);
      }
    }
    if (kind == EntityKind.metadata && ownerNoteId != null) {
      throw const FormatException('Metadata cannot belong to another note');
    }
  }

  Map<String, dynamic> toJson() => {
    'vaultId': vaultId,
    'entityId': entityId,
    'kind': kind.name,
    'revisionId': revisionId,
    'parentRevisionIds': [...parentRevisionIds]..sort(),
    'deviceId': deviceId,
    'formatVersion': formatVersion,
    'deleted': deleted,
    'ownerNoteId': ownerNoteId,
    'blobs': {
      for (final key in blobs.keys.toList()..sort()) key: blobs[key]!.toJson(),
    },
    'baseRefs': {
      for (final key in baseRefs.keys.toList()..sort())
        key: [...baseRefs[key]!]..sort(),
    },
  };

  factory RevisionRecord.fromJson(Map<String, dynamic> json) {
    final kindName = _string(json['kind']);
    final kinds = EntityKind.values.where((k) => k.name == kindName);
    if (kinds.isEmpty ||
        json['formatVersion'] != 1 ||
        json['deleted'] is! bool ||
        json['ownerNoteId'] != null && json['ownerNoteId'] is! String) {
      throw const FormatException('Invalid revision schema');
    }
    final blobs = jsonObject(json['blobs']);
    final bases = jsonObject(json['baseRefs']);
    return RevisionRecord(
      vaultId: _string(json['vaultId']),
      entityId: _string(json['entityId']),
      kind: kinds.single,
      revisionId: _string(json['revisionId']),
      parentRevisionIds: _strings(json['parentRevisionIds']),
      deviceId: _string(json['deviceId']),
      ownerNoteId: json['ownerNoteId'] as String?,
      deleted: json['deleted'] as bool,
      blobs: blobs.map(
        (key, value) => MapEntry(key, BlobRef.fromJson(jsonObject(value))),
      ),
      baseRefs: bases.map((key, value) => MapEntry(key, _strings(value))),
      formatVersion: json['formatVersion'] as int,
    );
  }
}
