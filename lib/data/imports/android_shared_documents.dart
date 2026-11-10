import 'dart:async';

import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/imports/shared_document_queue.dart';
import 'package:saber/data/office/office_document_store.dart';

final class AndroidSharedDocuments {
  new({
    required this._inbox,
    required this._onQueued,
    this._channel = const MethodChannel('personal_ink_vault/document_import'),
  });

  final SharedDocumentInbox _inbox;
  final void Function() _onQueued;
  final MethodChannel _channel;
  final _known = <String>{};
  Future<void>? _reading;
  var _refreshRequested = false;
  var _disposed = false;

  static final _log = Logger('AndroidSharedDocuments');
  static final _id = RegExp(r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$');

  void start() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'documentsChanged') throw MissingPluginException();
      unawaited(refresh());
    });
    unawaited(refresh());
  }

  Future<void> refresh() {
    if (_disposed) return Future<void>.value();
    _refreshRequested = true;
    return _reading ??= _readPending().whenComplete(() {
      _reading = null;
      if (_refreshRequested && !_disposed) unawaited(refresh());
    });
  }

  Future<void> _readPending() async {
    while (_refreshRequested && !_disposed) {
      _refreshRequested = false;
      try {
        final records = await _channel.invokeListMethod<Object?>('takePending');
        if (_disposed || records == null) continue;
        final live = <String>{};
        var added = false;
        for (final record in records) {
          if (record is! Map) continue;
          final recovered = record['recovered'] == true;
          if (record.length != (recovered ? 3 : 2)) continue;
          final id = record['id'], path = record['path'];
          if (id is! String ||
              !_id.hasMatch(id) ||
              path is! String ||
              !_validPath(path))
            continue;
          live.add(id);
          if (_known.add(id) &&
              _inbox.enqueue(
                path,
                onRelease: () => _release(id),
                sharedRequestId: id,
                recovered: recovered,
              )) {
            added = true;
          }
        }
        _known.removeWhere((id) => !live.contains(id));
        if (added) _onQueued();
      } on MissingPluginException {
        return;
      } on PlatformException catch (error) {
        _log.warning('공유 문서 목록을 가져오지 못했습니다 (${error.code}).');
      }
    }
  }

  bool _validPath(String path) {
    if (!p.posix.isAbsolute(path) ||
        p.posix.normalize(path) != path ||
        path.contains('\u0000'))
      return false;
    final extension = p.posix.extension(path).toLowerCase();
    return extension == '.pdf' ||
        extension.isNotEmpty &&
            OfficeDocumentStore.supportedExtensions.contains(
              extension.substring(1),
            );
  }

  Future<void> _release(String id) async {
    try {
      await _channel.invokeMethod<void>('release', {'id': id});
    } on MissingPluginException {
      return;
    } on PlatformException catch (error) {
      _log.warning('공유 문서 임시 파일을 정리하지 못했습니다 (${error.code}).');
    }
  }

  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
  }
}
