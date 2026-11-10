import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/obsidian_canvas_export_source.dart';
import 'package:saber/data/vault/obsidian_canvas_json.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/portable_document_export.dart';
import 'package:saber/data/vault/workspace_store.dart';

const _maxDocuments = 1000;
const _maxContents = 96 * 1024 * 1024;
const _maxAttachment = 64 * 1024 * 1024;
const _maxBoard = 8 * 1024 * 1024;
const _reportPath = 'export-report.json';
const _readmePath = '읽어주세요.txt';

final class ObsidianCanvasExport {
  new(this.bundle, this._reader);

  final PortableExportBundle bundle;
  final ObsidianCanvasExportReader _reader;

  Future<void> ensureCurrent() => _reader.ensureCurrent();
}

Future<ObsidianCanvasExport> buildObsidianCanvasExport({
  required NoteRepository repository,
  required InkVaultNative native,
  required String noteId,
  required String metadataRevisionId,
  required String bodyRevisionId,
}) async {
  validateId(noteId);
  validateId(metadataRevisionId);
  validateId(bodyRevisionId);
  final reader = await ObsidianCanvasExportReader.capture(
    repository,
    native: native,
  );
  final root = await reader.read(noteId, maxBytes: _maxBoard);
  if (root == null ||
      root.kind != VaultDocumentKind.canvas ||
      root.metadataRevisionId != metadataRevisionId ||
      root.bodyRevisionId != bodyRevisionId) {
    throw StateError('현재 저장된 단일 Canvas 판본을 선택한 뒤 내보내세요.');
  }

  final documents = <String, ObsidianCanvasExportFile>{noteId: root};
  final boards = <String, CardCanvasDocument>{
    noteId: decodeObsidianExportCanvas(root.bytes),
  };
  final requested = <String>{noteId};
  final pending = Queue<String>()..add(noteId);
  final imageIds = <String, String?>{};
  String? resolveImage(String path) =>
      imageIds.putIfAbsent(path, () => reader.resolveImage(path));
  var bytesRead = root.bytes.length;

  while (pending.isNotEmpty) {
    final board = boards[pending.removeFirst()]!;
    for (final node in board.nodes) {
      final background = node.type == 'group'
          ? node.toJson()['background']
          : null;
      final target = background is String
          ? resolveImage(background)
          : node.linkedNoteId;
      if (target == null ||
          requested.length >= _maxDocuments ||
          !requested.add(target))
        continue;
      final remaining = math.min(_maxAttachment, _maxContents - bytesRead);
      if (remaining <= 0) break;
      final dependency = await reader.read(target, maxBytes: remaining);
      if (dependency == null) continue;
      if (dependency.kind == VaultDocumentKind.canvas) {
        try {
          boards[target] = decodeObsidianExportCanvas(dependency.bytes);
        } on FormatException {
          continue;
        }
        pending.add(target);
      }
      documents[target] = dependency;
      bytesRead += dependency.bytes.length;
    }
  }

  final allocator = _CanvasPaths(native, noteId);
  final paths = <String, String>{};
  final warnings = <String>[];
  var omittedWarnings = 0;
  void warn(String message) {
    if (warnings.length < 200) {
      warnings.add(message);
    } else {
      omittedWarnings++;
    }
  }

  for (final file in documents.values) {
    final path = allocator.assign(file);
    paths[file.noteId] = path;
    if (path != file.preferredPath) {
      warn('경로 충돌 또는 호환되지 않는 파일 이름 때문에 $path 에 저장했습니다.');
    }
  }
  final files = <String, Uint8List>{};
  for (final file in documents.values) {
    final path = paths[file.noteId]!;
    final board = boards[file.noteId];
    if (board == null) {
      files[path] = file.bytes;
      continue;
    }
    final encoded = encodeObsidianCanvas(
      board,
      filePathFor: (target) => paths[target],
      imagePathFor: (raw) => paths[resolveImage(raw)],
      onWarning: (id, message) => warn(
        '$path (${String.fromCharCodes(id.runes.take(80))}) ${String.fromCharCodes(message.runes.take(240))}',
      ),
    );
    if (encoded.length > _maxBoard) {
      throw const FormatException('내보낸 Canvas는 파일당 8 MiB까지 지원합니다.');
    }
    files[path] = encoded;
  }
  if (omittedWarnings > 0) warnings.add('그 밖에 $omittedWarnings개의 변환 안내가 있습니다.');
  final entrypoint = paths[noteId]!;
  final report = {
    'schemaVersion': 1,
    'format': 'JSON Canvas 1.0',
    'entrypoint': entrypoint,
    'scope': 'File cards, linked Canvas boards, and group background images.',
    'notes': [
      'Extract this ZIP and open its root as an Obsidian vault.',
      'Open entrypoint to edit the board.',
      'Markdown and card text remain as saved. Their own links may point outside this bundle.',
      'PDF entries contain the saved source files. Open Personal Ink Vault to see its ink strokes.',
      'Unavailable cards are represented as text.',
    ],
    'files': [
      for (final file in documents.values)
        {'path': paths[file.noteId], 'revisionId': file.bodyRevisionId},
    ],
    'warnings': warnings,
  };
  files[_reportPath] = Uint8List.fromList(
    utf8.encode(const JsonEncoder.withIndent('  ').convert(report)),
  );
  files[_readmePath] = utf8.encode(
    'Obsidian Canvas 내보내기\n\n'
    '압축을 새 폴더에 풀고 그 폴더를 Obsidian 보관함으로 여세요.\n'
    '"$entrypoint" 파일을 열면 시작 보드가 표시됩니다.\n'
    '"$_reportPath" 파일에서 변환 안내와 파일 목록을 확인하세요.\n'
    'PDF는 저장된 원본을 포함합니다. 별도 필기는 Personal Ink Vault에서 확인하세요.\n',
  );
  final total = files.values.fold<int>(0, (sum, bytes) => sum + bytes.length);
  if (total > _maxContents)
    throw const FormatException('Canvas 내보내기는 최대 96 MiB입니다.');
  await reader.ensureCurrent();
  return ObsidianCanvasExport(
    PortableExportBundle(
      files: files,
      entrypoint: entrypoint,
      warnings: warnings,
    ),
    reader,
  );
}

CardCanvasDocument decodeObsidianExportCanvas(Uint8List bytes) {
  final json = jsonObject(jsonDecode(utf8.decode(bytes)));
  final nodes = json['nodes'] ?? const [];
  final edges = json['edges'] ?? const [];
  if (nodes is! List ||
      edges is! List ||
      nodes.length > 2000 ||
      edges.length > 5000) {
    throw const FormatException('Canvas는 카드 2,000개와 연결선 5,000개까지 내보낼 수 있습니다.');
  }
  final board = CardCanvasDocument.fromJson(json);
  for (final node in board.nodes) {
    if ([
      node.x,
      node.y,
      node.width,
      node.height,
    ].any((value) => value.abs() > 1e9)) {
      throw const FormatException('Canvas 좌표가 내보내기 한도를 초과했습니다.');
    }
  }
  return board;
}

final class _CanvasPaths {
  new(this.native, String rootId) : fallback = '_ink-vault-assets-$rootId';

  final InkVaultNative native;
  final String fallback;
  final _keys = <String, String>{};
  final _files = <String>{};
  final _folders = <String, String>{};

  String assign(ObsidianCanvasExportFile file) {
    final candidate = file.preferredPath;
    final parts = candidate.split('/');
    if (candidate.length <= 180 &&
        parts.length <= 65 &&
        parts.every(_portableSegment) &&
        _claim(parts, allowFallback: false)) {
      return candidate;
    }
    validateId(file.noteId);
    final leaf = parts.last;
    final suffix = RegExp(r'\.[A-Za-z0-9]{1,8}$').firstMatch(leaf)?.group(0);
    if (suffix == null)
      throw const FormatException('Missing Canvas export file extension');
    final name = leaf.length <= 75 && _portableSegment(leaf)
        ? leaf
        : 'document$suffix';
    final safe = [fallback, file.noteId, name];
    if (!_claim(safe, allowFallback: true))
      throw StateError('Canvas export path collision');
    return safe.join('/');
  }

  bool _portableSegment(String value) =>
      !value.startsWith('.') && isObsidianPathSegment(value);

  bool _claim(List<String> parts, {required bool allowFallback}) {
    final missing = {
      for (final value in [...parts, fallback, _reportPath, _readmePath])
        if (!_keys.containsKey(value)) value,
    }.toList();
    if (missing.isNotEmpty) {
      final keys = native.invoke({
        'op': 'normalize_workspace_segments',
        'segments': missing,
      })['segments'];
      if (keys is! List || keys.length != missing.length)
        throw StateError('Invalid Canvas path keys');
      for (var i = 0; i < missing.length; i++) {
        final key = keys[i];
        if (key is! String || key.isEmpty || key.contains('/'))
          throw StateError('Invalid Canvas path key');
        _keys[missing[i]] = key;
      }
    }
    if (!allowFallback && _keys[parts.first] == _keys[fallback]) return false;
    final keys = parts.map((part) => _keys[part]!).toList();
    final file = keys.join('/');
    if (keys.first == _keys[_reportPath] ||
        keys.first == _keys[_readmePath] ||
        _files.contains(file) ||
        _folders.containsKey(file))
      return false;
    final folders = <String, String>{};
    for (var i = 1; i < keys.length; i++) {
      final key = keys.take(i).join('/');
      final path = parts.take(i).join('/');
      final existing = _folders[key];
      if (_files.contains(key) || existing != null && existing != path)
        return false;
      if (existing == null) folders[key] = path;
    }
    // Keep room for generated fallback folders and files under the import cap.
    if (!allowFallback && _folders.length + folders.length > 7000) return false;
    _folders.addAll(folders);
    _files.add(file);
    return true;
  }
}
