import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';

class OfficeViewState {
  final String vaultId;
  final String noteId;
  final String sourceRevisionId;
  final String? bindingId;
  final bool pdfMode;
  final String? pageId;

  const new({
    required this.vaultId,
    required this.noteId,
    required this.sourceRevisionId,
    required this.bindingId,
    required this.pdfMode,
    required this.pageId,
  });

  factory fromJson(Map<String, dynamic> json) {
    String id(String key) {
      final value = json[key];
      if (value is! String)
        throw const FormatException('Invalid Office view ID');
      validateId(value);
      return value;
    }

    String? optionalId(String key) => json[key] == null ? null : id(key);

    if (json['version'] != 1 || json['pdfMode'] is! bool) {
      throw const FormatException('Unsupported Office view');
    }
    final binding = optionalId('bindingId');
    if (json['pdfMode'] == true && binding == null) {
      throw const FormatException('Missing Office PDF binding');
    }
    return OfficeViewState(
      vaultId: id('vaultId'),
      noteId: id('noteId'),
      sourceRevisionId: id('sourceRevisionId'),
      bindingId: binding,
      pdfMode: json['pdfMode'] as bool,
      pageId: optionalId('pageId'),
    );
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'vaultId': vaultId,
    'noteId': noteId,
    'sourceRevisionId': sourceRevisionId,
    'bindingId': bindingId,
    'pdfMode': pdfMode,
    'pageId': pageId,
  };
}

class OfficeViewStore {
  new(NoteRepository repository, this.noteId)
    : vaultId = repository.vaultId,
      _root = repository.root {
    validateId(noteId);
    validateId(vaultId);
  }

  final String vaultId;
  final String noteId;
  final Directory _root;
  Future<void> _tail = Future.value();
  static const _maxBytes = 16 * 1024;

  File get _file => File('${_root.path}/.workspace/office-views/$noteId.json');

  Future<OfficeViewState?> load() async {
    final kind = FileSystemEntity.typeSync(_file.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) return null;
    if (kind != FileSystemEntityType.file) {
      throw const FormatException('Invalid Office view file');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final part in _file.openRead(0, _maxBytes + 1)) {
      bytes.add(part);
    }
    if (bytes.length > _maxBytes) {
      throw const FormatException('Office view file is too large');
    }
    final state = OfficeViewState.fromJson(
      jsonObject(jsonDecode(utf8.decode(bytes.takeBytes()))),
    );
    _validateOwner(state);
    return state;
  }

  Future<void> save(OfficeViewState state) {
    _validateOwner(OfficeViewState.fromJson(jsonObject(state.toJson())));
    final bytes = utf8.encode(jsonEncode(state.toJson()));
    final next = _tail.then((_) async {
      final file = _file;
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.${newId()}.pending');
      try {
        await pending.writeAsBytes(bytes, flush: true);
        for (var wait = 10; ; wait *= 2) {
          try {
            await pending.rename(file.path);
            break;
          } on FileSystemException catch (error) {
            final code = error.osError?.errorCode;
            if (!Platform.isWindows ||
                wait > 160 ||
                (code != 5 && code != 32 && code != 33)) {
              rethrow;
            }
            await Future<void>.delayed(Duration(milliseconds: wait));
          }
        }
      } finally {
        if (pending.existsSync()) await pending.delete();
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _validateOwner(OfficeViewState state) {
    if (state.vaultId != vaultId || state.noteId != noteId) {
      throw const FormatException('Foreign Office view');
    }
  }
}
