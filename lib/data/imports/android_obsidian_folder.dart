import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final class AndroidObsidianFolder {
  const new();

  static const _channel = MethodChannel('personal_ink_vault/obsidian_folder');
  static final _log = Logger('AndroidObsidianFolder');
  static final _uuid = RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$');

  Future<({String id, String name, Directory directory})?> pick() async {
    final Object? selected;
    try {
      selected = await _channel.invokeMethod<Object?>('pickFolder');
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? 'Obsidian 보관함 폴더를 읽지 못했습니다.');
    }
    if (selected == null) return null;
    const invalid = FormatException('선택한 Obsidian 보관함 폴더를 확인하지 못했습니다.');
    final id = selected is Map ? selected['id'] : null;
    if (id is! String || !_uuid.hasMatch(id)) throw invalid;
    try {
      final name = (selected as Map)['name'];
      if (name is! String || name.trim().isEmpty) throw invalid;
      final cache = await getTemporaryDirectory();
      final path = p.join(
        await cache.resolveSymbolicLinks(),
        'obsidian-picker',
        id,
      );
      final directory = Directory(path);
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.directory ||
          !p.equals(path, await directory.resolveSymbolicLinks())) {
        throw invalid;
      }
      return (id: id, name: name, directory: directory);
    } catch (_) {
      await release(id);
      rethrow;
    }
  }

  Future<void> release(String id) async {
    try {
      await _channel.invokeMethod<void>('release', {'id': id});
    } on PlatformException catch (error) {
      _log.warning('Obsidian 임시 폴더를 정리하지 못했습니다 (${error.code}).');
    } on MissingPluginException {
      return;
    }
  }
}
