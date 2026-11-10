import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final class AndroidStarNoteSource {
  const new();

  static const channel = MethodChannel('personal_ink_vault/starnote_source');
  static final _log = Logger('AndroidStarNoteSource');
  static final _uuid = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');

  Future<({String id, String name})?> choose() async {
    final result = await _invoke('choose');
    if (result == null) return null;
    const invalid = FormatException('선택한 StarNote 파일을 확인하지 못했습니다.');
    if (result is! Map) throw invalid;
    final id = result['id'];
    if (id is! String || !_uuid.hasMatch(id)) {
      throw invalid;
    }
    final name = result['name'];
    if (result.length != 2 ||
        name is! String ||
        name.contains(RegExp(r'[/\\\x00]')) ||
        p.extension(name).toLowerCase() != '.note') {
      await release(id);
      throw const FormatException('StarNote .note 파일을 선택하세요.');
    }
    return (id: id, name: name);
  }

  Future<({File file, int bytes})> stage(String id) async {
    final result = await _invoke('stage', {'id': id});
    final path = result is Map ? result['path'] : null;
    final bytes = result is Map ? result['bytes'] : null;
    const invalid = FormatException('StarNote 임시 파일을 확인하지 못했습니다.');
    if (result is! Map ||
        result.length != 2 ||
        path is! String ||
        bytes is! int ||
        bytes <= 0 ||
        path.contains('\u0000') ||
        !p.isAbsolute(path) ||
        p.normalize(path) != path ||
        !p.basename(path).endsWith('_$id.note')) {
      throw invalid;
    }
    final cache = await getTemporaryDirectory();
    final directory = p.join(cache.path, 'starnote-picker');
    if (!p.equals(p.dirname(path), directory) ||
        FileSystemEntity.typeSync(directory, followLinks: false) !=
            FileSystemEntityType.directory ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw invalid;
    }
    final file = File(path);
    final canonicalDirectory = p.join(
      await cache.resolveSymbolicLinks(),
      'starnote-picker',
    );
    if (!p.equals(
      p.dirname(await file.resolveSymbolicLinks()),
      canonicalDirectory,
    )) {
      throw invalid;
    }
    return (file: file, bytes: bytes);
  }

  Future<void> release(String id) async {
    try {
      await channel.invokeMethod<void>('release', {'id': id});
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      _log.warning('StarNote 임시 파일을 정리하지 못했습니다 (${error.code}).');
    }
  }

  Future<Object?> _invoke(String method, [Map<String, String>? args]) async {
    try {
      return await channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      throw const FormatException('이 앱 버전에서는 StarNote 파일을 선택할 수 없습니다.');
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? 'StarNote 파일을 읽지 못했습니다.');
    }
  }
}
