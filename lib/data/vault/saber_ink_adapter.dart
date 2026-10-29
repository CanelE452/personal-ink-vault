import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/file_manager/file_manager.dart';

class SaberInkAdapter {
  static Future<Map<String, Uint8List>> capture(
    EditorCoreInfo core,
    int pageIndex,
  ) async {
    core.assetCache.allowRemovingAssets = false;
    try {
      final (body, assets) = core.saveToBinary(currentPageIndex: pageIndex);
      final files = <String, Uint8List>{'main.sbn2': body};
      for (var i = 0; i < assets.length; i++) {
        files['main.sbn2.$i'] = Uint8List.fromList(await assets.getBytes(i));
      }
      return files;
    } finally {
      core.assetCache.allowRemovingAssets = true;
    }
  }

  static Future<EditorCoreInfo> load(
    NoteRepository repository,
    RevisionRecord revision,
  ) async {
    final files = await repository.readFiles(revision);
    final body = files['main.sbn2'];
    if (body == null) throw const FormatException('필기 본문이 없습니다. 복구가 필요합니다.');
    final path = '/.working/${revision.entityId}/${revision.revisionId}/main';
    // A revision gets its own materialization directory; an open editor's
    // attachment paths are never overwritten by an incoming remote revision.
    for (final entry in files.entries) {
      if (!RegExp(r'^main\.sbn2(?:\.\d+)?$').hasMatch(entry.key)) {
        throw const FormatException('지원하지 않는 필기 자산 경로');
      }
      final file = FileManager.getFile('$path${entry.key.substring(4)}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.value, flush: true);
    }
    final core = await EditorCoreInfo.loadFromFileContents(
      bsonBytes: body,
      path: path,
      onlyFirstPage: false,
    );
    if (core.readOnlyReason != null)
      throw const FormatException('필기 snapshot을 안전하게 열 수 없습니다.');
    return core;
  }
}
