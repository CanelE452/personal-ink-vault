import 'dart:convert';
import 'dart:io';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/office/office_image_asset.dart';

class OfficeAssetException implements Exception {
  const new(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class OfficeAssetStore {
  new(this.repository) : _queue = _queues[repository] ??= _OfficeAssetQueue();

  final NoteRepository repository;
  final _OfficeAssetQueue _queue;
  static final _queues = Expando<_OfficeAssetQueue>();
  static const _maxChunkBytes = 128 * 1024;
  static const _maxAssets = 32;

  String get _workspace => '${repository.root.path}/.workspace';
  String get _root => '$_workspace/office-assets';
  String _folder(String assetId) => '$_root/$assetId';
  File _manifest(String assetId) => File('${_folder(assetId)}/manifest.json');
  File _data(String assetId) => File('${_folder(assetId)}/data');

  Future<Map<String, Object?>> begin({
    required String assetId,
    required String noteId,
    required String sourceRevisionId,
    required String mimeType,
    required String sha256,
    required int byteLength,
    required Future<void> Function() requireWrite,
  }) => _queue.run(() async {
    await requireWrite();
    _validateBinding(assetId, noteId, sourceRevisionId);
    _validateMetadata(mimeType, sha256, byteLength);
    await _safePaths(assetId);
    if (_manifest(assetId).existsSync()) {
      final current = await _load(assetId, noteId, sourceRevisionId);
      if (current.metadata['mimeType'] != mimeType ||
          current.metadata['sha256'] != sha256 ||
          current.metadata['byteLength'] != byteLength) {
        throw const OfficeAssetException(
          'asset_conflict',
          'The upload ID already describes another image',
        );
      }
      return current.status;
    }
    if (Directory(_folder(assetId)).existsSync()) {
      throw const OfficeAssetException(
        'asset_conflict',
        'The upload directory has no owned manifest',
      );
    }
    await _checkQuota(byteLength);
    for (final path in [_workspace, _root, _folder(assetId)]) {
      if (!Directory(path).existsSync()) {
        await _beforeWrite(assetId, requireWrite);
        await Directory(path).create();
      }
    }
    await _beforeWrite(assetId, requireWrite);
    await _data(assetId).writeAsBytes(const [], flush: true);
    final metadata = <String, Object?>{
      'schemaVersion': 1,
      'vaultId': repository.vaultId,
      'assetId': assetId,
      'noteId': noteId,
      'sourceRevisionId': sourceRevisionId,
      'mimeType': mimeType,
      'sha256': sha256,
      'byteLength': byteLength,
      'receivedBytes': 0,
      'state': 'uploading',
    };
    await _publish(assetId, metadata, requireWrite);
    return _OfficeStagedAsset(metadata, 0).status;
  });

  Future<Map<String, Object?>> append({
    required String assetId,
    required String noteId,
    required String sourceRevisionId,
    required int offset,
    required String base64Data,
    required Future<void> Function() requireWrite,
  }) => _queue.run(() async {
    await requireWrite();
    final current = await _load(assetId, noteId, sourceRevisionId);
    if (current.metadata['state'] != 'uploading') {
      throw const OfficeAssetException('asset_conflict', 'The image is sealed');
    }
    if (offset < 0 || base64Data.length > ((_maxChunkBytes + 2) ~/ 3) * 4) {
      throw const OfficeAssetException(
        'invalid_argument',
        'Invalid image chunk',
      );
    }
    List<int> bytes;
    try {
      bytes = base64Decode(base64Data);
    } on FormatException {
      throw const OfficeAssetException(
        'invalid_argument',
        'Invalid base64 chunk',
      );
    }
    if (bytes.isEmpty || bytes.length > _maxChunkBytes) {
      throw const OfficeAssetException(
        'invalid_argument',
        'Invalid image chunk',
      );
    }
    if (offset > current.receivedBytes ||
        offset < current.receivedBytes &&
            offset + bytes.length > current.receivedBytes) {
      throw const OfficeAssetException(
        'asset_offset_mismatch',
        'Resume from the received byte offset',
      );
    }
    if (offset < current.receivedBytes) {
      final file = await _data(assetId).open();
      try {
        await file.setPosition(offset);
        final saved = await file.read(bytes.length);
        var sameBytes = saved.length == bytes.length;
        for (var index = 0; sameBytes && index < bytes.length; index++) {
          sameBytes = saved[index] == bytes[index];
        }
        if (!sameBytes) {
          throw const OfficeAssetException(
            'asset_conflict',
            'The retried chunk differs from the stored bytes',
          );
        }
      } finally {
        await file.close();
      }
      return current.status;
    }
    final received = current.receivedBytes + bytes.length;
    if (received > (current.metadata['byteLength'] as int)) {
      throw const OfficeAssetException(
        'invalid_argument',
        'The chunk exceeds the declared image length',
      );
    }
    await _beforeWrite(assetId, requireWrite);
    await _data(assetId)
        .writeAsBytes(bytes, mode: FileMode.append, flush: true);
    final metadata = {...current.metadata, 'receivedBytes': received};
    await _publish(assetId, metadata, requireWrite);
    return _OfficeStagedAsset(metadata, received).status;
  });

  Future<Map<String, Object?>> seal({
    required String assetId,
    required String noteId,
    required String sourceRevisionId,
    required Future<void> Function() requireWrite,
  }) => _queue.run(() async {
    await requireWrite();
    final current = await _load(assetId, noteId, sourceRevisionId);
    final image = await _verifiedImage(assetId, current);
    if (current.metadata['state'] == 'sealed') return current.status;
    final metadata = <String, Object?>{
      ...current.metadata,
      'receivedBytes': current.receivedBytes,
      'state': 'sealed',
      'width': image.width,
      'height': image.height,
    };
    await _publish(assetId, metadata, requireWrite);
    return _OfficeStagedAsset(metadata, current.receivedBytes).status;
  });

  Future<Map<String, Object?>> status({
    required String assetId,
    required String noteId,
    required String sourceRevisionId,
  }) => _queue.run(() async {
    return (await _load(assetId, noteId, sourceRevisionId)).status;
  });

  Future<WindowsOfficeImageAsset> readSealed({
    required String assetId,
    required String noteId,
    required String sourceRevisionId,
  }) => _queue.run(() async {
    final current = await _load(assetId, noteId, sourceRevisionId);
    if (current.metadata['state'] != 'sealed') {
      throw const OfficeAssetException(
        'asset_not_sealed',
        'Finish and seal the image upload first',
      );
    }
    return _verifiedImage(assetId, current);
  });

  Future<Map<String, Object?>> discard({
    required String assetId,
    required String noteId,
    required String sourceRevisionId,
    required Future<void> Function() requireWrite,
  }) => _queue.run(() async {
    await requireWrite();
    await _load(assetId, noteId, sourceRevisionId, allowDamagedData: true);
    final files = <File>[];
    await for (final entry in Directory(
      _folder(assetId),
    ).list(followLinks: false)) {
      final name = entry.uri.pathSegments.last;
      if (FileSystemEntity.typeSync(entry.path, followLinks: false) !=
              FileSystemEntityType.file ||
          name != 'data' && name != 'manifest.json' && !_pendingName(name)) {
        throw const OfficeAssetException(
          'asset_unsafe_path',
          'The upload directory contains an unowned entry',
        );
      }
      files.add(File(entry.path));
    }
    files.sort(
      (a, b) => (a.uri.pathSegments.last == 'manifest.json' ? 1 : 0).compareTo(
        b.uri.pathSegments.last == 'manifest.json' ? 1 : 0,
      ),
    );
    for (final file in files) {
      await _beforeWrite(assetId, requireWrite);
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const OfficeAssetException(
          'asset_unsafe_path',
          'Unsafe upload file',
        );
      }
      await file.delete();
    }
    await _beforeWrite(assetId, requireWrite);
    await Directory(_folder(assetId)).delete();
    return {'assetId': assetId, 'state': 'discarded'};
  });

  void _validateBinding(
    String assetId,
    String noteId,
    String sourceRevisionId,
  ) {
    try {
      validateId(assetId);
      validateId(noteId);
      validateId(sourceRevisionId);
    } on FormatException {
      throw const OfficeAssetException(
        'invalid_argument',
        'Invalid upload identity',
      );
    }
  }

  void _validateMetadata(String mimeType, String digest, int length) {
    try {
      validateHash(digest);
    } on FormatException {
      throw const OfficeAssetException(
        'invalid_argument',
        'Invalid image SHA-256',
      );
    }
    if (mimeType != 'image/png' && mimeType != 'image/jpeg' ||
        length < 1 ||
        length > WindowsOfficeImageAsset.maxBytes) {
      throw const OfficeAssetException(
        'invalid_argument',
        'Only PNG/JPEG images of at most 20 MiB are supported',
      );
    }
  }

  Future<void> _safePaths(String assetId) async {
    for (final path in [
      repository.root.path,
      _workspace,
      _root,
      _folder(assetId),
    ]) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw const OfficeAssetException(
          'asset_unsafe_path',
          'Unsafe upload directory',
        );
      }
    }
    for (final path in [_data(assetId).path, _manifest(assetId).path]) {
      final type = FileSystemEntity.typeSync(path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw const OfficeAssetException(
          'asset_unsafe_path',
          'Unsafe upload file',
        );
      }
    }
  }

  Future<void> _beforeWrite(
    String assetId,
    Future<void> Function() requireWrite,
  ) async {
    await requireWrite();
    await _safePaths(assetId);
  }

  Future<_OfficeStagedAsset> _load(
    String assetId,
    String noteId,
    String sourceRevisionId, {
    bool allowDamagedData = false,
  }) async {
    _validateBinding(assetId, noteId, sourceRevisionId);
    await _safePaths(assetId);
    final file = _manifest(assetId);
    if (!file.existsSync()) {
      throw const OfficeAssetException(
        'asset_not_found',
        'Image upload not found',
      );
    }
    Map<String, Object?> metadata;
    try {
      if (file.lengthSync() > 16 * 1024) throw const FormatException();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      metadata = Map<String, Object?>.from(decoded);
      if (metadata['vaultId'] != repository.vaultId ||
          metadata['assetId'] != assetId ||
          metadata['noteId'] != noteId ||
          metadata['sourceRevisionId'] != sourceRevisionId) {
        throw const OfficeAssetException(
          'asset_binding_mismatch',
          'The image belongs to another document or vault',
        );
      }
      if (metadata['schemaVersion'] != 1 ||
          metadata['mimeType'] is! String ||
          metadata['sha256'] is! String ||
          metadata['byteLength'] is! int ||
          metadata['receivedBytes'] is! int ||
          metadata['state'] != 'uploading' && metadata['state'] != 'sealed') {
        throw const FormatException();
      }
      _validateMetadata(
        metadata['mimeType'] as String,
        metadata['sha256'] as String,
        metadata['byteLength'] as int,
      );
      final declared = metadata['byteLength'] as int;
      final recorded = metadata['receivedBytes'] as int;
      final data = _data(assetId);
      final received = data.existsSync() ? data.lengthSync() : 0;
      if (recorded < 0 ||
          recorded > declared ||
          metadata['state'] == 'sealed' &&
              (recorded != declared ||
                  metadata['width'] is! int ||
                  metadata['height'] is! int) ||
          !allowDamagedData &&
              (recorded > received ||
                  received > declared ||
                  metadata['state'] == 'sealed' && received != declared)) {
        throw const FormatException();
      }
      return _OfficeStagedAsset(metadata, received);
    } on FormatException {
      throw const OfficeAssetException(
        'asset_integrity_failed',
        'Invalid upload manifest or data',
      );
    } on OfficeAssetException catch (error) {
      if (error.code == 'invalid_argument') {
        throw const OfficeAssetException(
          'asset_integrity_failed',
          'Invalid upload manifest',
        );
      }
      rethrow;
    }
  }

  Future<WindowsOfficeImageAsset> _verifiedImage(
    String assetId,
    _OfficeStagedAsset current,
  ) async {
    if (current.receivedBytes != current.metadata['byteLength']) {
      throw const OfficeAssetException(
        'asset_integrity_failed',
        'The image upload is incomplete',
      );
    }
    try {
      final image = WindowsOfficeImageAsset.fromBytes(
        await _data(assetId).readAsBytes(),
      );
      if (image.sha256 != current.metadata['sha256'] ||
          image.mimeType != current.metadata['mimeType'] ||
          current.metadata['state'] == 'sealed' &&
              (image.width != current.metadata['width'] ||
                  image.height != current.metadata['height'])) {
        throw const FormatException();
      }
      return image;
    } on FormatException {
      throw const OfficeAssetException(
        'asset_integrity_failed',
        'The image bytes or identity do not match',
      );
    }
  }

  Future<void> _checkQuota(int requestedBytes) async {
    if (!Directory(_root).existsSync()) return;
    var count = 0;
    var reserved = 0;
    await for (final entry in Directory(_root).list(followLinks: false)) {
      final id = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      try {
        validateId(id);
      } on FormatException {
        continue;
      }
      await _safePaths(id);
      final file = _manifest(id);
      if (!file.existsSync()) continue;
      if (file.lengthSync() > 16 * 1024) {
        throw const OfficeAssetException(
          'asset_integrity_failed',
          'Invalid upload manifest',
        );
      }
      Object? decoded;
      try {
        decoded = jsonDecode(await file.readAsString());
      } on FormatException {
        throw const OfficeAssetException(
          'asset_integrity_failed',
          'Invalid upload manifest',
        );
      }
      if (decoded is! Map<String, dynamic> ||
          decoded['noteId'] is! String ||
          decoded['sourceRevisionId'] is! String) {
        throw const OfficeAssetException(
          'asset_integrity_failed',
          'Invalid upload manifest',
        );
      }
      final owned = await _load(
        id,
        decoded['noteId'] as String,
        decoded['sourceRevisionId'] as String,
        allowDamagedData: true,
      );
      count++;
      reserved += owned.metadata['byteLength'] as int;
    }
    if (count >= _maxAssets ||
        reserved + requestedBytes > WindowsOfficeImageAsset.maxBatchBytes) {
      throw const OfficeAssetException(
        'asset_quota_exceeded',
        'Discard an image upload to free staging space',
      );
    }
  }

  bool _pendingName(String name) {
    if (!name.endsWith('.pending')) return false;
    try {
      validateId(name.substring(0, name.length - '.pending'.length));
      return true;
    } on FormatException {
      return false;
    }
  }

  Future<void> _publish(
    String assetId,
    Map<String, Object?> metadata,
    Future<void> Function() requireWrite,
  ) async {
    final pending = File('${_folder(assetId)}/${newId()}.pending');
    await _beforeWrite(assetId, requireWrite);
    if (FileSystemEntity.typeSync(pending.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const OfficeAssetException(
        'asset_unsafe_path',
        'Unsafe pending upload manifest',
      );
    }
    await pending.writeAsString(jsonEncode(metadata), flush: true);
    await _beforeWrite(assetId, requireWrite);
    if (FileSystemEntity.typeSync(pending.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const OfficeAssetException(
        'asset_unsafe_path',
        'Unsafe pending upload manifest',
      );
    }
    await pending.rename(_manifest(assetId).path);
  }
}

class _OfficeStagedAsset {
  const new(this.metadata, this.receivedBytes);
  final Map<String, Object?> metadata;
  final int receivedBytes;

  Map<String, Object?> get status => {
    'assetId': metadata['assetId'],
    'noteId': metadata['noteId'],
    'sourceRevisionId': metadata['sourceRevisionId'],
    'mimeType': metadata['mimeType'],
    'sha256': metadata['sha256'],
    'byteLength': metadata['byteLength'],
    'receivedBytes': receivedBytes,
    'state': metadata['state'],
    if (metadata['state'] == 'sealed') 'width': metadata['width'],
    if (metadata['state'] == 'sealed') 'height': metadata['height'],
  };
}

class _OfficeAssetQueue {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }
}
