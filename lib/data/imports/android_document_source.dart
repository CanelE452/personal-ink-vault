import 'dart:io';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saber/data/app_external_screen.dart';
import 'package:saber/data/office/office_document_store.dart';

typedef AndroidDocumentSelection = ({String id, String name});

enum AndroidDocumentSource {
  starNote('starnote', 'StarNote .note', ['note']),
  office(
    'office',
    'Word·PowerPoint·OpenDocument·한글',
    OfficeDocumentStore.supportedExtensions,
  );

  new(this._prefix, this._label, this._extensions);

  final String _prefix, _label;
  final List<String> _extensions;
  MethodChannel get channel =>
      MethodChannel('personal_ink_vault/${_prefix}_source');

  static final _log = Logger('AndroidDocumentSource');
  static const _uuidPattern = r'[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}';
  static final _uuid = RegExp('^$_uuidPattern\$');

  Future<AndroidDocumentSelection?> choose() async {
    final result = await AppExternalScreen.run(() => _invoke('choose'));
    if (result == null) return null;
    const invalid = FormatException('선택한 문서를 확인하지 못했습니다.');
    if (result is! Map) throw invalid;
    final id = result['id'];
    if (id is! String || !_uuid.hasMatch(id)) {
      throw invalid;
    }
    final name = result['name'];
    final extension = name is String ? p.extension(name).toLowerCase() : '';
    if (result.length != 2 ||
        name is! String ||
        name.contains(RegExp(r'[/\\\x00]')) ||
        extension.isEmpty ||
        !_extensions.contains(extension.substring(1))) {
      await release(id);
      throw FormatException('$_label 파일을 선택하세요.');
    }
    return (id: id, name: name);
  }

  Future<({File file, int bytes})> stage(
    AndroidDocumentSelection selection,
  ) async {
    final (id: id, name: name) = selection;
    final result = await _invoke('stage', {'id': id});
    final path = result is Map ? result['path'] : null;
    final bytes = result is Map ? result['bytes'] : null;
    const invalid = FormatException('문서 임시 파일을 확인하지 못했습니다.');
    final extension = p.extension(name).toLowerCase();
    if (result is! Map ||
        result.length != 2 ||
        path is! String ||
        bytes is! int ||
        bytes <= 0 ||
        path.contains('\u0000') ||
        !p.isAbsolute(path) ||
        p.normalize(path) != path ||
        !RegExp('^$_prefix-${_uuidPattern}_${RegExp.escape(id + extension)}\$')
            .hasMatch(p.basename(path))) {
      throw invalid;
    }
    final cache = await getTemporaryDirectory();
    final directory = p.join(cache.path, '$_prefix-picker');
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
      '$_prefix-picker',
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
      _log.warning('문서 임시 파일을 정리하지 못했습니다 (${error.code}).');
    }
  }

  Future<Object?> _invoke(String method, [Map<String, String>? args]) async {
    try {
      return await channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      throw FormatException('이 앱 버전에서는 $_label 파일을 선택할 수 없습니다.');
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? '문서를 읽지 못했습니다.');
    }
  }
}
