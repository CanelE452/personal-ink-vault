import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/obsidian_canvas_export.dart';
import 'package:saber/data/vault/obsidian_canvas_export_source.dart';
import 'package:saber/data/vault/obsidian_canvas_json.dart';
import 'package:saber/data/vault/obsidian_vault_export_links.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/workspace_store.dart';

const _maxEntries = 10000;
const _maxContents = 96 * 1024 * 1024;
const _maxMarkdown = 8 * 1024 * 1024;
const _maxAttachment = 64 * 1024 * 1024;
const _maxWarnings = 200;
const _maxPathLength = 180;
const obsidianVaultExportReportPath = '.ink-vault-export/report.json';

final class ObsidianVaultExport {
  new _(this.files, this.folders, this.warnings, this._reader);

  final Map<String, Uint8List> files;
  final List<String> folders;
  final List<String> warnings;
  final ObsidianCanvasExportReader _reader;

  Future<void> ensureCurrent() =>
      _reader.ensureCurrent(action: 'Obsidian 보관함 내보내기');
}

Future<ObsidianVaultExport> buildObsidianVaultExport({
  required NoteRepository repository,
  required InkVaultNative native,
}) async {
  final reader = await ObsidianCanvasExportReader.capture(
    repository,
    native: native,
  );
  final catalog = reader.catalog;
  if (catalog.folders.length + catalog.notes.length > _maxEntries) {
    _tooManyEntries();
  }

  final allocator = _VaultPaths(native);
  final folderPaths = <String, String>{};
  final omissions = <Map<String, String>>[];
  final warnings = <String>[];
  var hiddenWarningCount = 0;
  void warn(String message) {
    if (warnings.length < _maxWarnings) {
      warnings.add(message);
    } else {
      hiddenWarningCount++;
    }
  }

  void omit(String kind, String title, String reason) {
    final name = _clip(title, 240);
    omissions.add({'kind': kind, 'title': name, 'reason': reason});
    warn('$name · $reason');
  }

  final candidates = <String, VaultFolder>{};
  final children = <String?, List<String>>{};
  final sortedFolders = catalog.folders.keys.toList()..sort();
  for (final id in sortedFolders) {
    final branches = catalog.folders[id]!;
    final folder = branches.singleOrNull;
    final head = catalog.heads[id]?.singleOrNull;
    if (folder == null || folder.deletionConflict) {
      omit('folder', branches.first.title, '폴더에 미해결 판본이 있습니다.');
      continue;
    }
    if (folder.trashed) continue;
    if (head?.kind != EntityKind.folder ||
        head?.revisionId != folder.revision.revisionId) {
      omit('folder', folder.title, '저장된 폴더 정보를 확인할 수 없습니다.');
      continue;
    }
    candidates[id] = folder;
    (children[folder.parentId] ??= []).add(id);
  }
  final pending = Queue<String>.of(children[null] ?? const []);
  while (pending.isNotEmpty) {
    final id = pending.removeFirst();
    final folder = candidates.remove(id)!;
    final parent = folder.parentId == null ? '' : folderPaths[folder.parentId]!;
    final path = parent.split('/').length < 64
        ? allocator.allocate(parent, folder.title)
        : null;
    if (path == null) {
      omit('folder', folder.title, '호환되는 내보내기 경로가 없습니다.');
      continue;
    }
    folderPaths[id] = path;
    if (path.split('/').last != folder.title) {
      warn('${_clip(folder.title, 240)} · 폴더 이름을 "$path"로 조정했습니다.');
    }
    pending.addAll(children[id] ?? const []);
  }
  for (final folder in candidates.values) {
    omit('folder', folder.title, '저장된 상위 폴더 경로를 확인할 수 없습니다.');
  }
  final folders = folderPaths.values.toList()..sort();

  final primaryPaths = <String, String>{};
  final markdownPaths = <String, String>{};
  final files = <String, Uint8List>{};
  final boards = <String, CardCanvasDocument>{};
  final markdown = <String, (String, Uint8List)>{};
  final summaries = <String, (String, String)>{};
  var sourceBytes = 0;
  void retain(Uint8List bytes) {
    sourceBytes += bytes.length;
    if (sourceBytes > _maxContents) _tooLarge();
  }

  bool collectMarkdown(VaultNote note, Uint8List bytes) {
    try {
      markdown[note.id] = (utf8.decode(bytes), bytes);
    } on FormatException {
      omit('markdown', note.title, '저장된 Markdown을 UTF-8로 읽을 수 없습니다.');
      return false;
    }
    retain(bytes);
    return true;
  }

  final sortedNotes = catalog.notes.keys.toList()..sort();
  for (final id in sortedNotes) {
    final branches = catalog.notes[id]!;
    final note = branches.singleOrNull;
    if (note == null || note.deletionConflict) {
      omit('document', branches.first.title, '문서에 미해결 판본이 있습니다.');
      continue;
    }
    if (note.trashed) continue;
    final metadata = catalog.heads[id]?.singleOrNull;
    if (metadata?.kind != EntityKind.metadata ||
        metadata?.revisionId != note.revision.revisionId ||
        metadata!.deleted) {
      omit('document', note.title, '저장된 문서 정보를 확인할 수 없습니다.');
      continue;
    }
    final parent = note.folderId == null ? '' : folderPaths[note.folderId];
    if (parent == null) {
      omit(note.documentKind.name, note.title, '저장된 폴더 경로를 확인할 수 없습니다.');
      continue;
    }

    final kind = note.documentKind;
    final hasPortableBody = switch (kind) {
      VaultDocumentKind.markdown ||
      VaultDocumentKind.canvas ||
      VaultDocumentKind.pdf ||
      VaultDocumentKind.image ||
      VaultDocumentKind.office => true,
      _ => false,
    };
    if (hasPortableBody) {
      final source = await reader.read(id, maxBytes: _maxAttachment);
      if (source == null) {
        omit(kind.name, note.title, '원본을 읽을 수 없거나 판본 또는 크기 한도를 확인하세요.');
      } else {
        final leaf = source.preferredPath.split('/').last;
        final extension = leaf.substring(leaf.lastIndexOf('.'));
        if (kind == VaultDocumentKind.canvas) {
          try {
            boards[id] = decodeObsidianExportCanvas(source.bytes);
          } on FormatException {
            omit('canvas', note.title, 'Canvas 본문이 손상되었거나 변환 한도를 초과했습니다.');
          }
        }
        final canExport = switch (kind) {
          VaultDocumentKind.markdown => collectMarkdown(note, source.bytes),
          VaultDocumentKind.canvas => boards.containsKey(id),
          _ => true,
        };
        if (canExport) {
          final path = allocator.allocate(
            parent,
            leaf.substring(0, leaf.length - extension.length),
            extension: extension,
          );
          if (path == null) {
            omit(kind.name, note.title, '호환되는 내보내기 경로가 없습니다.');
            markdown.remove(id);
            boards.remove(id);
          } else {
            primaryPaths[id] = path;
            if (path.split('/').last != leaf) {
              warn('${_clip(note.title, 240)} · 파일 이름을 "$path"로 조정했습니다.');
            }
            if (kind == VaultDocumentKind.markdown) {
              markdownPaths[id] = path;
            } else {
              retain(source.bytes);
              if (kind != VaultDocumentKind.canvas) files[path] = source.bytes;
            }
          }
        }
      }
    } else {
      omit(kind.name, note.title, '앱 전용 문서 본문은 Obsidian 형식으로 내보낼 수 없습니다.');
    }
    if (kind == VaultDocumentKind.markdown) continue;

    final summary = await reader.readSummary(note, maxBytes: _maxMarkdown);
    if (summary == null) {
      omit('markdown', note.title, '저장된 Markdown 요약의 판본 또는 크기를 확인하세요.');
    } else if (summary.bytes.isNotEmpty &&
        collectMarkdown(note, summary.bytes)) {
      final primary = primaryPaths[id]?.split('/').last;
      final stem = primary == null
          ? note.title
          : primary.substring(0, primary.lastIndexOf('.'));
      summaries[id] = (parent, stem);
    }
  }

  // Allocate ordinary filenames before summaries to keep existing notes stable.
  for (final entry in summaries.entries) {
    final (parent, stem) = entry.value;
    final path = allocator.allocate(parent, stem, extension: '.md');
    if (path == null) {
      omit(
        'markdown',
        catalog.notes[entry.key]!.single.title,
        '요약을 저장할 호환 경로가 없습니다.',
      );
      markdown.remove(entry.key);
      continue;
    }
    if (path.split('/').last != '$stem.md') {
      warn('${_clip(stem, 240)} · Markdown 요약을 "$path"로 저장했습니다.');
    }
    markdownPaths[entry.key] = path;
    primaryPaths.putIfAbsent(entry.key, () => path);
  }

  final rewritten = portableObsidianMarkdown(
    native: native,
    catalog: catalog,
    pathsById: primaryPaths,
    markdownPathsById: markdownPaths,
    markdownById: {
      for (final entry in markdown.entries) entry.key: entry.value.$1,
    },
    warnings: warnings,
  );
  for (final entry in markdown.entries) {
    final (original, bytes) = entry.value;
    final text = rewritten[entry.key] ?? original;
    final hasBom =
        bytes.length >= 3 &&
        bytes[0] == 0xef &&
        bytes[1] == 0xbb &&
        bytes[2] == 0xbf;
    final exported = text == original
        ? bytes
        : utf8.encode(hasBom ? '\ufeff$text' : text);
    if (exported.length > _maxMarkdown) {
      throw const FormatException('변환한 Markdown은 파일당 8 MiB까지 내보낼 수 있습니다.');
    }
    files[markdownPaths[entry.key]!] = exported;
  }

  final imageIds = <String, String?>{};
  for (final entry in boards.entries) {
    final path = primaryPaths[entry.key]!;
    files[path] = encodeObsidianCanvas(
      entry.value,
      filePathFor: (id) => primaryPaths[id],
      imagePathFor: (raw) =>
          primaryPaths[imageIds.putIfAbsent(
            raw,
            () => reader.resolveImage(raw),
          )],
      onWarning: (nodeId, message) =>
          warn('$path (${_clip(nodeId, 80)}) ${_clip(message, 240)}'),
    );
  }

  if (hiddenWarningCount > 0 || warnings.length > _maxWarnings) {
    final remaining =
        hiddenWarningCount +
        (warnings.length > _maxWarnings ? warnings.length - _maxWarnings : 0);
    if (warnings.length > _maxWarnings)
      warnings.removeRange(_maxWarnings, warnings.length);
    warnings.add('그 밖에 $remaining개의 변환 안내가 있습니다.');
  }
  final fileCount = files.length;
  files[obsidianVaultExportReportPath] = utf8.encode(
    '${const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'format': 'Obsidian vault ZIP',
      'documents': fileCount,
      'folders': folders.length,
      'scope': ['Markdown, JSON Canvas and supported original attachments.', 'PDF and Office entries contain the stored original. Ink strokes, app-only document bodies, trash and revision history stay in Personal Ink Vault.', 'Obsidian configuration and plugins are not included.'],
      'omissions': omissions,
      'warnings': warnings,
    })}\n',
  );
  _checkSize(files, folders);
  await reader.ensureCurrent(action: 'Obsidian 보관함 내보내기');
  return ObsidianVaultExport._(
    Map.unmodifiable({
      for (final entry in files.entries)
        entry.key: entry.value.asUnmodifiableView(),
    }),
    List.unmodifiable(folders),
    List.unmodifiable(warnings),
    reader,
  );
}

Uint8List encodeObsidianVaultZip({
  required Map<String, Uint8List> files,
  required List<String> folders,
}) {
  _checkSize(files, folders);
  final archive = Archive();
  try {
    for (final folder in folders.toList()..sort()) {
      _validateArchivePath(folder, directory: true);
      archive.addFile(ArchiveFile.directory(folder));
    }
    for (final path in files.keys.toList()..sort()) {
      _validateArchivePath(path, directory: false);
      archive.addFile(ArchiveFile.bytes(path, files[path]!));
    }
    final bytes = ZipEncoder().encodeBytes(archive);
    if (bytes.length > obsidianVaultZipMaxBytes) _tooLarge();
    return bytes;
  } finally {
    archive.clearSync();
  }
}

void _validateArchivePath(String path, {required bool directory}) {
  if (!directory && path == obsidianVaultExportReportPath) return;
  final parts = path.split('/');
  if (path.length > _maxPathLength ||
      parts.length > (directory ? 64 : 65) ||
      parts.any(
        (part) => part.startsWith('.') || !isObsidianPathSegment(part),
      )) {
    throw const FormatException('Obsidian ZIP에 호환되지 않는 경로가 있습니다.');
  }
}

void _checkSize(Map<String, Uint8List> files, List<String> folders) {
  if (files.length + folders.length > _maxEntries) _tooManyEntries();
  final total = files.values.fold<int>(0, (sum, bytes) => sum + bytes.length);
  if (total > _maxContents) _tooLarge();
}

Never _tooManyEntries() =>
    throw const FormatException('Obsidian 내보내기는 최대 10,000개 항목을 지원합니다.');

Never _tooLarge() =>
    throw const FormatException('Obsidian 내보내기는 압축 전 96 MiB까지 지원합니다.');

String _clip(String value, int maximum) {
  if (maximum == 0) return '';
  if (value.length <= maximum) return value;
  final codeUnit = value.codeUnitAt(maximum - 1);
  final end = codeUnit >= 0xd800 && codeUnit <= 0xdbff ? maximum - 1 : maximum;
  return value.substring(0, end);
}

final class _VaultPaths {
  new(this.native);

  final InkVaultNative native;
  final _taken = <String, Set<String>>{};
  final _nextSerial = <(String, String, String), int>{};
  final _keys = <String, String>{};
  static final _unsafe = RegExp(r'[<>:"/\\|?*#\[\]^\x00-\x1f\x7f-\x9f]|%{2,}');
  static final _leadingDots = RegExp(r'^\.+');
  static final _trailing = RegExp(r'[.\s]+$');

  String? allocate(String parent, String label, {String extension = ''}) {
    final prefix = parent.isEmpty ? '' : '$parent/';
    final maximum = _maxPathLength - prefix.length - extension.length;
    if (maximum < 1) return null;
    final used = _taken.putIfAbsent(parent, () => {});
    var stem = label
        .trim()
        .replaceAll(_unsafe, '_')
        .replaceFirst(_leadingDots, '_')
        .replaceFirst(_trailing, '');
    if (stem.isEmpty) stem = '_';
    final serialKey = (parent, stem, extension);
    for (
      var serial = _nextSerial[serialKey] ?? 1;
      serial <= _maxEntries;
      serial++
    ) {
      final suffix = serial == 1 ? '' : '-$serial';
      final remaining = maximum - suffix.length;
      if (remaining < 1) return null;
      var base = _clip(stem, remaining).replaceFirst(_trailing, '');
      if (!isObsidianPathSegment(base) ||
          (parent.isEmpty &&
              extension.isEmpty &&
              base.toLowerCase() == '__macosx')) {
        base = '_${_clip(base, remaining - 1)}';
      }
      final candidate = '$base$suffix$extension';
      final key = _keys.putIfAbsent(
        candidate,
        () => normalizeObsidianExportSegments(native, [candidate]).single,
      );
      if (used.add(key)) {
        _nextSerial[serialKey] = serial + 1;
        return '$prefix$candidate';
      }
    }
    return null;
  }
}
