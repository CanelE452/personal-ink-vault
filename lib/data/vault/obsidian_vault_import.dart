import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/imports/image_note_importer.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/notion_export_csv.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/workspace_bookmarks.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_markdown_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';

export 'package:saber/data/vault/obsidian_vault_source.dart'
    show obsidianVaultZipMaxBytes, starNoteArchiveMaxBytes;

part 'starnote_note_import.dart';

final class ObsidianVaultImportResult {
  const new(
    this.repository,
    this.noteCount,
    this.canvasCount,
    this.attachmentCount,
    this.folderCount,
    this.skippedFiles, {
    this.databaseCount = 0,
    this.bookmarksImported = 0,
    this.bookmarksSkipped = 0,
    this.bookmarksUnreadable = false,
  });

  final NoteRepository repository;
  final int noteCount, canvasCount, attachmentCount, folderCount, skippedFiles;
  final int databaseCount;
  final int bookmarksImported, bookmarksSkipped;
  final bool bookmarksUnreadable;
}

Future<ObsidianVaultImportResult> importObsidianVault({
  required Directory vaultsDirectory,
  Directory? sourceFolder,
  Uint8List? sourceZip,
  required String sourceName,
  InkVaultNative? native,
}) => _importVault(
  vaultsDirectory: vaultsDirectory,
  sourceFolder: sourceFolder,
  sourceZip: sourceZip,
  sourceName: sourceName,
  native: native,
);

Future<ObsidianVaultImportResult> importNotionVault({
  required Directory vaultsDirectory,
  required Uint8List sourceZip,
  required String sourceName,
  InkVaultNative? native,
}) => _importVault(
  vaultsDirectory: vaultsDirectory,
  sourceZip: sourceZip,
  sourceName: sourceName,
  native: native,
  notionExport: true,
);

Future<ObsidianVaultImportResult> _importVault({
  required Directory vaultsDirectory,
  Directory? sourceFolder,
  Uint8List? sourceZip,
  required String sourceName,
  InkVaultNative? native,
  bool notionExport = false,
}) async {
  if ((sourceFolder == null) == (sourceZip == null)) {
    throw ArgumentError('Choose one Obsidian folder or ZIP file');
  }
  final engine = native ?? InkVaultNative.open();
  List<String> normalizeSegments(List<String> segments) =>
      (engine.invoke({
                'op': 'normalize_workspace_segments',
                'segments': segments,
              })['segments']
              as List)
          .cast<String>();

  final source = sourceFolder != null
      ? await readObsidianVaultFolder(
          sourceFolder,
          normalizeSegments: normalizeSegments,
        )
      : await readObsidianVaultZip(
          sourceZip!,
          normalizeSegments: normalizeSegments,
          notionExport: notionExport,
        );
  final databases = notionExport
      ? _notionDatabases(source.attachments)
      : const <_NotionDatabase>[];
  final canvases = <(ObsidianAttachmentFile, VaultNote)>[];
  var bookmarks = (
    imported: 0,
    skipped: 0,
    unreadable: source.bookmarksUnreadable,
  );

  Future<void> write(NoteRepository repository) async {
    final library = LibraryStore(repository);
    final workspace = WorkspaceStore(repository);
    final importedPaths = <(List<String>, VaultNote)>[];
    final hasCanvases = source.attachments.any(
      (file) => file.documentKind == 'canvas',
    );
    final bookmarkBytes = source.bookmarkBytes;
    final needsSourcePaths = hasCanvases || bookmarkBytes != null;
    final folderIds = <String, String>{};
    String? inFolder(List<String> path) =>
        path.isEmpty ? null : folderIds[path.join('/')]!;
    for (final path in source.folders) {
      final folder = await library.createFolder(
        path.last,
        parentId: path.length == 1
            ? null
            : folderIds[path.take(path.length - 1).join('/')]!,
      );
      folderIds[path.join('/')] = folder.id;
    }
    if (source.templateSettings case final settings?) {
      final folderId = folderIds[settings.folderPath.join('/')];
      if (folderId != null) {
        final templates = WorkspaceMarkdownTemplateStore(repository);
        final prior = await templates.settings();
        await templates.saveSettings(
          prior,
          folderId: folderId,
          dateFormat: settings.dateFormat ?? prior.dateFormat,
          timeFormat: settings.timeFormat ?? prior.timeFormat,
        );
      }
    }
    final notionPages = <(String, String), List<VaultNote>>{};
    for (final note in source.notes) {
      final title = notionExport ? _notionDisplayTitle(note.title) : note.title;
      final created = await workspace.createMarkdown(
        title,
        note.markdown,
        folderId: inFolder(note.folders),
        aliases: note.aliases,
        notionExportNames: notionExport ? ['${note.title}.md'] : const [],
      );
      if (notionExport) {
        (notionPages[(note.folders.join('/'), title)] ??= []).add(created);
      }
      if (needsSourcePaths) {
        importedPaths.add(([...note.folders, '${note.title}.md'], created));
      }
    }
    final images = ImageNoteImporter(repository);
    final office = OfficeDocumentStore(repository);
    for (final attachment in source.attachments) {
      if (attachment.documentKind == 'notion-csv') continue;
      final name = attachment.fileName;
      final folderId = inFolder(attachment.folders);
      final created = await switch (attachment.documentKind) {
        'pdf' || 'canvas' => workspace.createWithSource(
          name,
          fileName: name,
          bytes: attachment.bytes,
          folderId: folderId,
          documentKind: attachment.documentKind == 'canvas'
              ? VaultDocumentKind.canvas
              : VaultDocumentKind.pdf,
          fromObsidian: true,
        ),
        'office' => office.importDocument(
          title: name,
          fileName: name,
          bytes: attachment.bytes,
          folderId: folderId,
          fromObsidian: true,
        ),
        'image' => images.import(
          title: name,
          fileName: name,
          bytes: attachment.bytes,
          folderId: folderId,
          fromObsidian: true,
        ),
        _ => throw StateError('Unsupported Obsidian attachment kind'),
      };
      if (needsSourcePaths)
        importedPaths.add(([...attachment.folders, name], created));
      if (attachment.documentKind == 'canvas')
        canvases.add((attachment, created));
    }
    for (final database in databases) {
      await _saveNotionDatabase(
        database,
        workspace,
        inFolder(database.file.folders),
        notionPages,
      );
    }
    if (needsSourcePaths) {
      final sourceKeys = _importPathKeys([
        for (final (path, _) in importedPaths) path,
        if (bookmarkBytes != null) ...source.folders,
      ], normalizeSegments);
      final targets = {
        for (final (path, note) in importedPaths)
          _importPathKey(path, sourceKeys): note,
      };
      // Assign all IDs before resolving links, including cycles between boards.
      if (canvases.isNotEmpty) {
        final noteIds = targets.map((path, note) => MapEntry(path, note.id));
        for (final (attachment, note) in canvases) {
          final editable = _editableCanvas(
            attachment,
            noteIds,
            normalizeSegments,
          );
          final session = await workspace.open(note);
          await session.saveInk({'board.canvas': editable});
        }
      }
      if (bookmarkBytes != null) {
        bookmarks = await _importBookmarks(
          bookmarkBytes,
          WorkspaceBookmarkStore(repository),
          targets,
          {
            for (final path in source.folders)
              _importPathKey(path, sourceKeys): folderIds[path.join('/')]!,
          },
          normalizeSegments,
          engine,
        );
      }
    }
  }

  final published = await _publishImportedVault(
    vaultsDirectory: vaultsDirectory,
    kind: notionExport ? 'notion' : 'obsidian',
    sourceName: sourceName,
    write: write,
  );
  return ObsidianVaultImportResult(
    await NoteRepository.open(published),
    source.notes.length,
    canvases.length,
    source.attachments
            .where((file) => file.documentKind != 'notion-csv')
            .length -
        canvases.length,
    source.folders.length,
    source.skippedFiles,
    databaseCount: databases.length,
    bookmarksImported: bookmarks.imported,
    bookmarksSkipped: bookmarks.skipped,
    bookmarksUnreadable: bookmarks.unreadable,
  );
}

Future<Directory> _publishImportedVault({
  required Directory vaultsDirectory,
  required String kind,
  required String sourceName,
  required Future<void> Function(NoteRepository) write,
  void Function()? requireCurrent,
}) async {
  requireCurrent?.call();
  await vaultsDirectory.create(recursive: true);
  final vaultsRoot = await vaultsDirectory.resolveSymbolicLinks();
  final stagingParent = Directory(p.join(vaultsRoot, '.imports'));
  await stagingParent.create();
  if (FileSystemEntity.typeSync(stagingParent.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.equals(
        await stagingParent.resolveSymbolicLinks(),
        stagingParent.path,
      )) {
    throw const FileSystemException('Invalid vault import staging directory');
  }
  final label = String.fromCharCodes(sourceName.runes.take(32))
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .trim();
  final destination = p.join(
    vaultsRoot,
    '$kind-${label.isEmpty ? '' : '$label-'}${newId()}',
  );
  requireCurrent?.call();
  final staging = await stagingParent.createTemp('$kind-');
  NoteRepository? writing;
  try {
    final repository = writing = await NoteRepository.open(
      staging,
      createFormatVersion: 2,
    );
    await write(repository);
    if (repository.pendingRevisionCount != 0 ||
        repository.integrityIssues.isNotEmpty) {
      throw const FormatException('가져온 보관함의 저장 상태를 확인할 수 없습니다.');
    }
    await repository.close();
    if (!p.isWithin(stagingParent.path, staging.path) ||
        !p.equals(await staging.resolveSymbolicLinks(), staging.path) ||
        !p.isWithin(vaultsRoot, destination) ||
        FileSystemEntity.typeSync(destination, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw const FileSystemException('Invalid vault import destination');
    }
    requireCurrent?.call();
    // A same-volume rename publishes only a complete vault to the menu.
    return await staging.rename(destination);
  } finally {
    await writing?.close();
    if (p.isWithin(stagingParent.path, staging.path) &&
        FileSystemEntity.typeSync(staging.path, followLinks: false) ==
            FileSystemEntityType.directory &&
        p.equals(await staging.resolveSymbolicLinks(), staging.path)) {
      await staging.delete(recursive: true);
    }
  }
}

final _notionIdSuffix = RegExp(
  r' (?:[0-9a-f]{32}|[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})$',
  caseSensitive: false,
);

bool _isNotionAllCsv(String name) =>
    name.toLowerCase().endsWith('_all.csv') &&
    _notionIdSuffix.hasMatch(name.substring(0, name.length - 8));

String _notionDisplayTitle(String stem) {
  final match = _notionIdSuffix.firstMatch(stem);
  final title = match == null ? stem : stem.substring(0, match.start);
  return isObsidianPathSegment(title) ? title : stem;
}

typedef _NotionDatabase = ({ObsidianAttachmentFile file, List<String> names});

List<_NotionDatabase> _notionDatabases(
  List<ObsidianAttachmentFile> attachments,
) {
  final selected = <String, _NotionDatabase>{};
  for (final file in attachments) {
    if (file.documentKind != 'notion-csv') continue;
    final name = file.fileName;
    final allRows = _isNotionAllCsv(name);
    final baseName = allRows
        ? '${name.substring(0, name.length - 8)}.csv'
        : name;
    final key = [...file.folders, baseName].join('/');
    final prior = selected[key];
    selected[key] = (
      file: allRows || prior == null ? file : prior.file,
      names: [...?prior?.names, name],
    );
  }
  return selected.values.toList();
}

Future<void> _saveNotionDatabase(
  _NotionDatabase source,
  WorkspaceStore workspace,
  String? folderId,
  Map<(String, String), List<VaultNote>> pages,
) async {
  final name = source.file.fileName;
  final stem = name.substring(0, name.length - (_isNotionAllCsv(name) ? 8 : 4));
  final csv = parseNotionCsv(source.file.bytes);
  final properties = [
    for (final (index, header) in csv.headers.indexed)
      DatabaseProperty.create(
        name: header.trim().isEmpty ? '열 ${index + 1}' : header,
        type: index == 0 ? 'title' : 'text',
      ),
  ];
  final matches = <String, int>{};
  for (final row in csv.rows) {
    final title = row.first.trim();
    matches.update(title, (count) => count + 1, ifAbsent: () => 1);
  }
  final scope = [...source.file.folders, stem].join('/');
  final rows = <DatabaseRow>[];
  for (final row in csv.rows) {
    final title = row.first.trim();
    final page = title.isNotEmpty && matches[title] == 1
        ? pages[(scope, title)]?.singleOrNull
        : null;
    rows.add(
      DatabaseRow.create(
        values: {
          for (final (index, value) in row.indexed) properties[index].id: value,
        },
        body: page == null
            ? null
            : {
                'version': 1,
                'blocks': [
                  BlockPageBlock.create(
                    type: 'documentLink',
                    text: page.title,
                    noteId: page.id,
                  ).toJson(),
                ],
              },
      ),
    );
  }
  final note = await workspace.createNotionDatabase(
    _notionDisplayTitle(stem),
    folderId: folderId,
    notionExportNames: source.names,
  );
  final database = WorkspaceDatabase.empty(id: note.id)
      .copyWith(properties: properties, rows: rows);
  final session = await workspace.open(note);
  await session.saveInk(DatabaseMediaSnapshot.prepare(database).files);
}

Map<String, String> _importPathKeys(
  Iterable<List<String>> paths,
  List<String> Function(List<String>) normalizeSegments,
) {
  final segments = paths.expand((path) => path).toSet().toList();
  final keys = <String, String>{};
  const batchSize = 10000;
  for (var start = 0; start < segments.length; start += batchSize) {
    final batch = segments.skip(start).take(batchSize).toList();
    final normalized = normalizeSegments(batch);
    if (normalized.length != batch.length) {
      throw StateError('Invalid import path normalization result');
    }
    for (var i = 0; i < batch.length; i++) {
      final key = normalized[i];
      if (key.isEmpty || key.contains('/')) {
        throw StateError('Invalid normalized import path segment');
      }
      keys[batch[i]] = key;
    }
  }
  return keys;
}

String _importPathKey(List<String> path, Map<String, String> keys) =>
    path.map((segment) => keys[segment]!).join('/');

const _maxBookmarkItems = 512;
const _maxBookmarkGroupDepth = 16;
final _bookmarkInvalidCharacters = RegExp(
  r'[\x00-\x1f\x7f-\x9f\ud800-\udfff]',
  unicode: true,
);
final _bookmarkPage = RegExp(r'^#page=([0-9]{1,10})$');
final _bookmarkSearchOperators = RegExp(r'[\s:"\\/*?(){}\[\]|]');

typedef _BookmarkReport = ({int imported, int skipped, bool unreadable});

Future<_BookmarkReport> _importBookmarks(
  Uint8List bytes,
  WorkspaceBookmarkStore store,
  Map<String, VaultNote> notes,
  Map<String, String> folders,
  List<String> Function(List<String>) normalizeSegments,
  InkVaultNative native,
) async {
  final List<Object?> items;
  try {
    final text = utf8.decode(bytes);
    if (!_boundedBookmarkJson(text)) {
      return (imported: 0, skipped: 0, unreadable: true);
    }
    final document = jsonDecode(text);
    if (document is! Map<String, Object?> ||
        document['items'] is! List<Object?>) {
      return (imported: 0, skipped: 0, unreadable: true);
    }
    items = document['items']! as List<Object?>;
  } on FormatException {
    return (imported: 0, skipped: 0, unreadable: true);
  }

  String? pathKey(Object? value) {
    final text = _bookmarkText(value, 4096);
    if (text == null) return null;
    final path = text.split('/');
    if (path.length > 65 ||
        path.any(
          (part) => part.startsWith('.') || !isObsidianPathSegment(part),
        )) {
      return null;
    }
    return normalizeSegments(path).join('/');
  }

  var visited = 0;
  var imported = 0;
  var skipped = 0;
  Future<void> visit(List<Object?> children, String? groupId, int depth) async {
    for (var i = 0; i < children.length; i++) {
      if (visited >= _maxBookmarkItems) {
        skipped += children.length - i;
        return;
      }
      final order = visited++;
      final child = children[i];
      if (child is! Map<String, Object?>) {
        skipped++;
        continue;
      }
      final title = _bookmarkText(child['title'], 256)?.trim();
      final label = title == null || title.isEmpty ? null : title;
      final type = child['type'];
      if (type == 'group') {
        final nested = child['items'];
        if (nested is! List<Object?> || depth >= _maxBookmarkGroupDepth) {
          skipped++;
          continue;
        }
        if (label == null) {
          skipped++;
          await visit(nested, groupId, depth + 1);
          continue;
        }
        final group = await store.add(
          WorkspaceBookmarkSpec(
            kind: WorkspaceBookmarkKind.group,
            title: label,
            groupId: groupId,
            order: order,
          ),
        );
        imported++;
        await visit(nested, group.id, depth + 1);
        continue;
      }

      final WorkspaceBookmarkKind kind;
      final String? target;
      int? page;
      var expressionSearch = false;
      switch (type) {
        case 'file':
          kind = WorkspaceBookmarkKind.note;
          final note = notes[pathKey(child['path'])];
          final link = note == null
              ? null
              : _bookmarkNoteLink(note, child['subpath']);
          target = link?.$1;
          page = link?.$2;
        case 'folder':
          kind = WorkspaceBookmarkKind.folder;
          target = folders[pathKey(child['path'])];
        case 'search':
          kind = WorkspaceBookmarkKind.search;
          final search = _bookmarkSearch(native, child['query']);
          target = search?.query;
          expressionSearch = search?.expression ?? false;
        case 'url':
          kind = WorkspaceBookmarkKind.url;
          final url = _bookmarkText(child['url'], 16384);
          target = url != null && url == url.trim() && isSafeExternalLink(url)
              ? url
              : null;
        default:
          skipped++;
          continue;
      }
      if (target == null) {
        skipped++;
        continue;
      }
      await store.add(
        WorkspaceBookmarkSpec(
          kind: kind,
          title: label,
          groupId: groupId,
          target: target,
          pdfPageNumber: page,
          literalSearch:
              kind == WorkspaceBookmarkKind.search && !expressionSearch,
          expressionSearch: expressionSearch,
          order: order,
        ),
      );
      imported++;
    }
  }

  await visit(items, null, 0);
  return (imported: imported, skipped: skipped, unreadable: false);
}

String? _bookmarkText(Object? value, int limit) =>
    value is String &&
        value.length <= limit &&
        !_bookmarkInvalidCharacters.hasMatch(value)
    ? value
    : null;

({String query, bool expression})? _bookmarkSearch(
  InkVaultNative native,
  Object? value,
) {
  final query = _bookmarkText(value, 2048)?.trim();
  if (query == null || query.isEmpty) return null;
  try {
    final response = native.invoke({
      'op': 'validate_search_expression',
      'query': query,
    });
    return response['valid'] == true ? (query: query, expression: true) : null;
  } on InkVaultNativeException catch (error) {
    if (error.code == 'invalid_search_expression') return null;
    if (error.code != 'unknown_operation') rethrow;
  }
  final literal = _legacyBookmarkQuery(query);
  return literal == null ? null : (query: literal, expression: false);
}

String? _legacyBookmarkQuery(String query) {
  if (query.length >= 3 && query.startsWith('"') && query.endsWith('"')) {
    final phrase = query.substring(1, query.length - 1);
    return phrase.isNotEmpty &&
            phrase == phrase.trim() &&
            !phrase.contains('"') &&
            !phrase.contains('\\')
        ? phrase
        : null;
  }
  if (_bookmarkSearchOperators.hasMatch(query) ||
      query.startsWith('-') ||
      const {'AND', 'OR', 'NOT'}.contains(query)) {
    return null;
  }
  return query;
}

(String, int?)? _bookmarkNoteLink(VaultNote note, Object? rawSubpath) {
  final markdown = note.documentKind == VaultDocumentKind.markdown;
  if (rawSubpath == null || rawSubpath == '' || rawSubpath == '#') {
    return (
      (markdown ? NoteLink.markdown(note.id) : NoteLink(note.id)).toString(),
      null,
    );
  }
  final subpath = _bookmarkText(rawSubpath, 2049);
  if (subpath == null || !subpath.startsWith('#')) return null;
  if (markdown) {
    final anchor = subpath.substring(1);
    if (anchor.trim().isEmpty || anchor == '^') return null;
    final link = NoteLink.markdown(note.id, anchor).toString();
    return link.length <= 16384 && NoteLink.parse(link)?.toString() == link
        ? (link, null)
        : null;
  }
  if (note.documentKind == VaultDocumentKind.pdf) {
    final match = _bookmarkPage.firstMatch(subpath);
    final page = match == null ? null : int.tryParse(match.group(1)!);
    if (page != null && page > 0 && page <= 0x7fffffff) {
      return (NoteLink(note.id).toString(), page);
    }
  }
  return null;
}

bool _boundedBookmarkJson(String text) {
  // Bound depth before decoding optional data, including ignored graph options.
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (final character in text.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character == 0x5c) {
        escaped = true;
      } else if (character == 0x22) {
        inString = false;
      }
    } else if (character == 0x22) {
      inString = true;
    } else if (character == 0x7b || character == 0x5b) {
      if (++depth > 48) return false;
    } else if (character == 0x7d || character == 0x5d) {
      if (--depth < 0) return false;
    }
  }
  return depth == 0 && !inString;
}

Uint8List _editableCanvas(
  ObsidianAttachmentFile attachment,
  Map<String, String> targets,
  List<String> Function(List<String>) normalizeSegments,
) {
  try {
    final json = jsonDecode(utf8.decode(attachment.bytes));
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Canvas must be an object');
    }
    final nodes = json['nodes'] ?? const [];
    final edges = json['edges'] ?? const [];
    if (nodes is! List ||
        edges is! List ||
        nodes.length > 2000 ||
        edges.length > 5000) {
      throw const FormatException('Invalid or oversized Canvas arrays');
    }
    _checkCanvasDepth(json, 0);
    final paths = <int, List<String>>{};
    for (var i = 0; i < nodes.length; i++) {
      final node = nodes[i];
      if (node is! Map<String, dynamic>) {
        throw const FormatException('Invalid Canvas node');
      }
      for (final key in const ['x', 'y', 'width', 'height']) {
        final value = node[key];
        if (value is! num || !value.isFinite || value.abs() > 1e9) {
          throw const FormatException('Canvas coordinate exceeds limits');
        }
      }
      // These fields belong to the current vault, never to the source file.
      node.remove('inkVaultTitle');
      node.remove('inkVaultNoteId');
      if (node['type'] != 'file') continue;
      node['inkVaultNoteId'] = null;
      final file = node['file'];
      if (file is! String || file.length > 4096) continue;
      final parts = file.split('/');
      if (parts.length <= 65 && parts.every(isObsidianPathSegment)) {
        paths[i] = parts;
      }
    }
    final keys = _importPathKeys(paths.values, normalizeSegments);
    for (final entry in paths.entries) {
      (nodes[entry.key] as Map<String, dynamic>)['inkVaultNoteId'] =
          targets[_importPathKey(entry.value, keys)];
    }
    final document = CardCanvasDocument.fromJson(json);
    return Uint8List.fromList(utf8.encode(jsonEncode(document.toJson())));
  } on FormatException {
    throw FormatException('Canvas 파일을 가져올 수 없습니다 (${attachment.fileName}).');
  }
}

void _checkCanvasDepth(Object? value, int depth) {
  if (depth > 64) throw const FormatException('Canvas exceeds nesting limits');
  if (value is num && !value.isFinite) {
    throw const FormatException('Canvas contains a non-finite number');
  }
  if (value is Map<String, dynamic>) {
    for (final child in value.values) {
      _checkCanvasDepth(child, depth + 1);
    }
  } else if (value is List) {
    for (final child in value) {
      _checkCanvasDepth(child, depth + 1);
    }
  }
}
