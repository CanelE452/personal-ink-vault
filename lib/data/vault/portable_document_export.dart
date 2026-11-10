import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_inline_text.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/database_query.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_database.dart';

enum PortableExportFormat { markdown, html, csv, pdf }

class PortableExportSource {
  new page({
    required this.noteId,
    required this.title,
    required this.bodyRevisionId,
    required List<String> metadataRevisionIds,
    required BlockPageMediaSnapshot snapshot,
  }) : metadataRevisionIds = List.unmodifiable(metadataRevisionIds),
       page = snapshot,
       database = null,
       values = const {},
       relatedRevisionIds = const {},
       evaluatedAtUtc = null;

  new database({
    required this.noteId,
    required this.title,
    required this.bodyRevisionId,
    required List<String> metadataRevisionIds,
    required DatabaseMediaSnapshot snapshot,
    Map<String, Map<String, DatabaseValue>> values = const {},
    Map<String, String> relatedRevisionIds = const {},
    DateTime? evaluatedAtUtc,
  }) : metadataRevisionIds = List.unmodifiable(metadataRevisionIds),
       page = null,
       database = snapshot,
       relatedRevisionIds = Map.unmodifiable(relatedRevisionIds),
       evaluatedAtUtc = evaluatedAtUtc?.toUtc(),
       values = Map.unmodifiable({
         for (final row in values.entries)
           row.key: Map<String, DatabaseValue>.unmodifiable({
             for (final value in row.value.entries)
               value.key: DatabaseValue(
                 _freezeJson(value.value.value),
                 error: value.value.error == null
                     ? null
                     : DatabaseCalculationError(
                         value.value.error!.code,
                         value.value.error!.message,
                         List.unmodifiable(value.value.error!.path),
                       ),
               ),
           }),
       });

  final String noteId, title, bodyRevisionId;
  final List<String> metadataRevisionIds;
  final BlockPageMediaSnapshot? page;
  final DatabaseMediaSnapshot? database;
  final Map<String, Map<String, DatabaseValue>> values;
  final Map<String, String> relatedRevisionIds;
  final DateTime? evaluatedAtUtc;
}

class PortableExportBundle {
  new({
    required Map<String, Uint8List> files,
    required this.entrypoint,
    required List<String> warnings,
  }) : _files = _copyFiles(files),
       warnings = List.unmodifiable(warnings) {
    if (!_files.containsKey(entrypoint)) {
      throw const FormatException('Export entrypoint is missing');
    }
    final names = <String>{};
    for (final path in _files.keys) {
      validateLogicalPath(path);
      if (!names.add(path.toLowerCase())) {
        throw const FormatException(
          'Export paths collide on a case-insensitive filesystem',
        );
      }
    }
  }
  final Map<String, Uint8List> _files;
  Map<String, Uint8List> get files => _copyFiles(_files);
  final String entrypoint;
  final List<String> warnings;

  Uint8List toZip() {
    final archive = Archive();
    try {
      final names = _files.keys.toList()..sort();
      for (final name in names) {
        final bytes = _files[name]!;
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    } finally {
      archive.clearSync();
    }
  }
}

PortableExportBundle buildPortableDocumentExport(
  PortableExportSource source,
  PortableExportFormat format, {
  Uint8List? pdfBytes,
  List<String> pdfWarnings = const [],
}) {
  validateId(source.noteId);
  if (source.bodyRevisionId.isEmpty || source.metadataRevisionIds.isEmpty) {
    throw const FormatException('Export requires a saved document edition');
  }
  if (format == PortableExportFormat.csv && source.database == null) {
    throw const FormatException('CSV export requires a database');
  }
  if (format == PortableExportFormat.pdf &&
      (pdfBytes == null || pdfBytes.isEmpty)) {
    throw const FormatException('PDF export requires a rendered PDF');
  }
  return _Export(source, format).build(pdfBytes, pdfWarnings);
}

class _Export {
  new(this.source, this.format);
  final PortableExportSource source;
  final PortableExportFormat format;
  final files = <String, Uint8List>{};
  final warnings = <String>{};

  String get extension => switch (format) {
    PortableExportFormat.markdown => 'md',
    PortableExportFormat.html => 'html',
    PortableExportFormat.csv => 'csv',
    PortableExportFormat.pdf => 'pdf',
  };
  String get entrypoint =>
      '${_basename(source.title)}--${source.noteId}.$extension';

  PortableExportBundle build(Uint8List? pdfBytes, List<String> pdfWarnings) {
    final original = source.page?.files ?? source.database!.files;
    final sourcePaths = _sourcePaths(original);
    for (final entry in sourcePaths.entries) {
      files[entry.value] = original[entry.key]!;
    }
    if (source.page case final snapshot?) {
      _addMedia(snapshot.document, original);
      _pageWarnings(snapshot.document);
      final content = format == PortableExportFormat.html
          ? _htmlDocument(source.title, _htmlPage(snapshot.document))
          : '# ${_markdownText(source.title)}\n\n${_markdownPage(snapshot.document)}';
      if (format != PortableExportFormat.pdf) _text(entrypoint, content);
    } else {
      _database(source.database!.database, original);
    }
    if (format == PortableExportFormat.pdf) {
      files[entrypoint] = Uint8List.fromList(pdfBytes!);
      warnings.addAll(pdfWarnings);
    }
    final report = {
      'schemaVersion': 1,
      'noteId': source.noteId,
      'title': source.title,
      'bodyRevisionId': source.bodyRevisionId,
      'metadataRevisionIds': source.metadataRevisionIds,
      'kind': source.page == null ? 'database' : 'page',
      'format': format.name,
      'entrypoint': entrypoint,
      'scope': 'One saved document edition; not a complete vault backup',
      'sourceFiles': [
        for (final entry in sourcePaths.entries)
          {
            'originalPath': entry.key,
            'exportedPath': entry.value,
            'path': entry.value,
            'bytes': original[entry.key]!.length,
            'sha256': crypto.sha256.convert(original[entry.key]!).toString(),
          },
      ],
      if (source.database != null)
        'computedValues': {
          for (final row in source.values.entries)
            row.key: {
              for (final cell in row.value.entries)
                cell.key: cell.value.toJson(),
            },
        },
      if (source.database != null) ...{
        'relatedRevisionIds': source.relatedRevisionIds,
        'evaluatedAtUtc': source.evaluatedAtUtc?.toIso8601String(),
        'archivedRowsIncluded': true,
      },
      'warnings': warnings.toList(),
      'sourcePreservation': 'Exact saved snapshot files are included under source/. Presentation formats do not preserve interactive editor behavior.',
    };
    _text(
      'export-report.json',
      const JsonEncoder.withIndent('  ').convert(report),
    );
    _text(
      '읽어주세요.txt',
      '문서 내보내기\n\n'
          '1. 이 압축 파일을 폴더에 풀어 주세요.\n'
          '2. "$entrypoint" 파일을 열면 내보낸 문서를 볼 수 있습니다.\n'
          '${source.database != null ? '3. 각 행의 본문은 rows 폴더에 있습니다. 보관된 행도 포함합니다.\n' : ''}'
          '그림과 첨부 파일은 media 폴더에 있습니다. 문서와 함께 보관해 주세요.\n'
          '저장된 원본 파일은 source 폴더에 있으며 내용은 바꾸지 않았습니다.\n'
          '다른 기기에서 사용할 수 없는 원본 파일 이름은 안전한 이름으로 바꾸고, '
          '원래 이름과 새 위치를 export-report.json에 기록했습니다.\n'
          'export-report.json에는 내보낸 판본, 원본 파일 목록, 계산 값과 보존되지 않는 동작도 기록되어 있습니다.\n'
          '링크 대상 문서와 외부 데이터베이스는 이 묶음에 포함되지 않을 수 있습니다.\n'
          '이 묶음은 선택한 문서 한 판본이며 전체 저장소 백업은 아닙니다.\n',
    );
    return PortableExportBundle(
      files: files,
      entrypoint: entrypoint,
      warnings: warnings.toList(),
    );
  }

  Map<String, String> _sourcePaths(Map<String, Uint8List> original) {
    final names = original.keys.toList()..sort();
    final protected = <String>{
      if (source.page != null) 'page.json',
      if (source.database != null) 'database.json',
      if (source.page != null)
        for (final media in source.page!.document.media.values) media.path,
      if (source.database case final snapshot?)
        for (final row in snapshot.database.rows)
          for (final media in BlockPageDocument.fromJson(row.body).media.values)
            media.path,
    };
    final remapped = {
      for (final name in names)
        if (!_portablePath(name)) name,
    };
    final byName = <String, List<String>>{};
    for (final name in names) {
      byName.putIfAbsent(name.toLowerCase(), () => []).add(name);
    }
    void conflict(String first, String second) {
      if (!protected.contains(first)) remapped.add(first);
      if (!protected.contains(second)) remapped.add(second);
    }

    for (final group in byName.values) {
      if (group.length > 1) {
        for (var index = 1; index < group.length; index++) {
          conflict(group.first, group[index]);
        }
      }
    }
    for (final name in names) {
      final parts = name.toLowerCase().split('/');
      for (var index = 1; index < parts.length; index++) {
        for (final ancestor
            in byName[parts.take(index).join('/')] ?? const <String>[]) {
          conflict(name, ancestor);
        }
      }
    }
    if (remapped.isNotEmpty) remapped.addAll(byName['opaque'] ?? const []);
    final paths = <String, String>{};
    final occupied = <String>{};
    for (final name in names.where((name) => !remapped.contains(name))) {
      paths[name] = 'source/$name';
      occupied.add('source/${name.toLowerCase()}');
    }
    bool collides(String path) {
      final lower = path.toLowerCase();
      return occupied.any(
        (existing) =>
            existing == lower ||
            existing.startsWith('$lower/') ||
            lower.startsWith('$existing/'),
      );
    }

    for (final name in names.where(remapped.contains)) {
      final hash = crypto.sha256.convert(utf8.encode(name)).toString();
      var path = 'source/opaque/$hash.bin';
      var suffix = 0;
      while (collides(path)) {
        path = 'source/opaque/$hash-${++suffix}.bin';
      }
      paths[name] = path;
      occupied.add(path.toLowerCase());
      warnings.add(
        'source-path-remapped: ${jsonEncode(name)} -> $path; original bytes are unchanged',
      );
    }
    return {for (final name in names) name: paths[name]!};
  }

  void _text(String path, String value) {
    files[path] = Uint8List.fromList(utf8.encode(value));
  }

  void _addMedia(BlockPageDocument page, Map<String, Uint8List> original) {
    for (final media in page.media.values) {
      files[media.path] = original[media.path]!;
    }
  }

  void _pageWarnings(BlockPageDocument page) {
    final extra = page.toJson().keys.where(
      (key) => !const {'version', 'blocks', 'blockMedia'}.contains(key),
    );
    if (extra.isNotEmpty)
      warnings.add(
        'opaque-page-fields: ${extra.join(', ')} remain in source JSON',
      );
    void visit(BlockPageBlock block, {bool allowColumns = false}) {
      if (allowColumns && block.isColumnLayout) {
        if (format == PortableExportFormat.markdown) {
          warnings.add('markdown.columns_flattened:${block.id}');
        }
        for (final column in block.children) {
          for (final child in column.children) {
            visit(child);
          }
        }
        return;
      }
      if (!_knownBlocks.contains(block.type)) {
        warnings.add(
          'unknown-block: ${block.id} (${block.type}); text is exported and complete data remains in source JSON',
        );
      }
      final extra = block.toJson().keys.where(
        (key) => !{
          'id',
          'type',
          'text',
          'noteId',
          'checked',
          'collapsed',
          'children',
          'tableData',
          if (block.linkedDatabase != null) 'linkedDatabaseData',
          if (block.inlineText != null) 'inlineData',
        }.contains(key),
      );
      if (extra.isNotEmpty)
        warnings.add(
          'opaque-block-fields: ${block.id}: ${extra.join(', ')} remain in source JSON',
        );
      if (block.type == 'table' && block.table == null) {
        warnings.add(
          'unknown-table: ${block.id}; complete table data remains in source JSON',
        );
      }
      if (block.type == 'linkedDatabase') {
        final linked = block.linkedDatabase;
        warnings.add(
          linked == null
              ? 'unknown-linked-database: ${block.id}; complete data remains in source JSON'
              : 'linked-database-reference: ${block.id}: ${linked.noteId}; the source database and live view are outside this export',
        );
      }
      if (block.inlineText?.runs.isNotEmpty == true &&
          !_inlineBlockTypes.contains(block.type)) {
        warnings.add(
          'dormant-inline: ${block.id} (${block.type}); formatting remains in source JSON',
        );
      }
      if (block.type == 'table' &&
          block.table?.headerColumn == true &&
          format == PortableExportFormat.markdown) {
        warnings.add(
          'table-header-column: ${block.id}; Markdown has no row-header semantics',
        );
      }
      if (const {'image', 'attachment'}.contains(block.type) &&
          !page.media.containsKey(block.id)) {
        warnings.add(
          'unregistered-media: ${block.id}; no binary was supplied for this block',
        );
      }
      if (block.type == 'documentLink' &&
          block.noteId != null &&
          block.noteId != source.noteId) {
        warnings.add(
          'external-document: ${block.noteId}; target is outside this export',
        );
      }
      final inline = _inlineBlockTypes.contains(block.type)
          ? block.inlineText
          : null;
      for (final segment in inline?.segments ?? const []) {
        final link = segment.link;
        if (link == null) continue;
        final note = NoteLink.parse(link);
        if (note == null) continue;
        if (note.noteId != source.noteId) {
          warnings.add(
            'external-document: ${note.noteId}; inline target is outside this export',
          );
        } else if (note.pageId != null || note.markdownAnchor != null) {
          warnings.add(
            'unresolved-document-location: $link; the original target remains in the export',
          );
        }
      }
      for (final child in block.children) {
        visit(child);
      }
    }

    for (final block in page.blocks) {
      visit(block, allowColumns: true);
    }
  }

  String _inlineDestination(String destination, String prefix) {
    final note = NoteLink.parse(destination);
    return note != null &&
            note.noteId == source.noteId &&
            note.pageId == null &&
            note.markdownAnchor == null
        ? _relativeHref('$prefix$entrypoint')
        : destination;
  }

  String _markdownPage(BlockPageDocument page, {String prefix = ''}) {
    final output = <String>[];
    Iterable<BlockPageBlock?> rootProjection() sync* {
      for (final block in page.blocks) {
        if (!block.isColumnLayout) {
          yield block;
          continue;
        }
        for (final column in block.children) {
          yield null;
          yield* column.children;
        }
        yield null;
      }
    }

    void append(Iterable<BlockPageBlock?> blocks, int depth) {
      var number = 0;
      var crossedColumnBoundary = false;
      String? previousList;
      for (final block in blocks) {
        if (block == null) {
          number = 0;
          crossedColumnBoundary = true;
          continue;
        }
        final list = switch (block.type) {
          'numbered' => 'ordered',
          'bullet' || 'todo' => 'unordered',
          _ => null,
        };
        number = block.type == 'numbered' ? number + 1 : 0;
        final media = page.media[block.id];
        final inline = _inlineBlockTypes.contains(block.type)
            ? block.inlineText
            : null;
        final text =
            inline?.toMarkdown(
              linkDestination: (value) => _inlineDestination(value, prefix),
            ) ??
            (block.inlineText != null
                ? BlockInlineText.plain(block.text).toMarkdown()
                : _markdownText(block.text));
        String content;
        if (media != null) {
          final label = block.type == 'attachment' || block.text.isEmpty
              ? media.name
              : block.text;
          content =
              '${block.type == 'image' ? '!' : ''}[${_markdownLabel(label)}](${_relativeHref('$prefix${media.path}')})';
          if (block.text.isNotEmpty &&
              (block.inlineText != null ||
                  block.type == 'attachment' && block.text != media.name)) {
            content += '\n\n$text';
          }
        } else {
          content = switch (block.type) {
            'heading1' => '# $text',
            'heading2' => '## $text',
            'heading3' => '### $text',
            'todo' => '- [${block.checked ? 'x' : ' '}] $text',
            'bullet' => '- $text',
            'numbered' => '$number. $text',
            'quote' => text.split('\n').map((line) => '> $line').join('\n'),
            'callout' =>
              text.split('\n').map((line) => '> 💡 $line').join('\n'),
            'toggle' => '▸ $text',
            'code' => _code(block.text),
            'equation' => '\$\$\n${_markdownText(block.text)}\n\$\$',
            'divider' => '---',
            'documentLink' when block.noteId != null =>
              '[${BlockInlineText.plain(block.text.replaceAll('\r', ' ').replaceAll('\n', ' ')).toMarkdown()}](${block.noteId == source.noteId ? _relativeHref('$prefix$entrypoint') : NoteLink(block.noteId!).toString()})',
            'linkedDatabase' when block.linkedDatabase != null =>
              '[${BlockInlineText.plain((block.text.isEmpty ? '연결된 데이터베이스' : block.text).replaceAll('\r', ' ').replaceAll('\n', ' ')).toMarkdown()}](${block.linkedDatabase!.noteId == source.noteId ? _relativeHref('$prefix$entrypoint') : NoteLink(block.linkedDatabase!.noteId).toString()})',
            'table' when block.table != null => [
              if (text.isNotEmpty) text,
              block.table!.toMarkdown(),
            ].join('\n\n'),
            _ => text,
          };
        }
        final visible = content.trim().isNotEmpty;
        if (visible || block.children.isNotEmpty) {
          // Blank lines alone do not separate adjacent lists in CommonMark.
          if (crossedColumnBoundary &&
              previousList != null &&
              (list == previousList || !visible)) {
            output.addAll(['<!-- -->', '']);
          }
          crossedColumnBoundary = false;
          previousList = list;
        }
        final indent = '  ' * depth;
        output.add(
          content.split('\n').map((line) => '$indent$line').join('\n'),
        );
        if (block.children.isNotEmpty) append(block.children, depth + 1);
        output.add('');
      }
    }

    append(rootProjection(), 0);
    return output.join('\n').trimRight();
  }

  String _htmlPage(BlockPageDocument page, {String prefix = ''}) {
    String blocks(List<BlockPageBlock> children, {bool allowColumns = false}) {
      final output = StringBuffer();
      String? list;
      void finishList() {
        if (list != null) output.write('</$list>');
        list = null;
      }

      for (final block in children) {
        if (allowColumns && block.isColumnLayout) {
          finishList();
          output.write('<section class="page-columns">');
          for (final column in block.children) {
            output.write(
              '<div class="page-column">${blocks(column.children)}</div>',
            );
          }
          output.write('</section>');
          continue;
        }
        final tag = switch (block.type) {
          'bullet' => 'ul',
          'numbered' => 'ol',
          _ => null,
        };
        if (tag != list) {
          finishList();
          list = tag;
          if (tag != null) output.write('<$tag>');
        }
        final inline = _inlineBlockTypes.contains(block.type)
            ? block.inlineText
            : null;
        final text =
            inline?.toHtml(
              linkDestination: (value) => _inlineDestination(value, prefix),
            ) ??
            _htmlText(block.text).replaceAll('\n', '<br>');
        final nested = blocks(block.children);
        final media = page.media[block.id];
        if (media != null) {
          final label = _htmlText(block.text.isEmpty ? media.name : block.text);
          final path = _htmlText(_relativeHref('$prefix${media.path}'));
          output.write(
            block.type == 'image'
                ? '<figure><img src="$path" alt="$label"><figcaption>${block.text.isEmpty ? label : text}</figcaption>$nested</figure>'
                : '<p><a href="$path" download>${_htmlText(media.name)}</a>${block.text.isEmpty ? '' : '<br>$text'}</p>$nested',
          );
          continue;
        }
        switch (block.type) {
          case 'heading1':
            output.write('<h1>$text</h1>$nested');
          case 'heading2':
            output.write('<h2>$text</h2>$nested');
          case 'heading3':
            output.write('<h3>$text</h3>$nested');
          case 'bullet':
          case 'numbered':
            output.write('<li>$text$nested</li>');
          case 'todo':
            output.write('<p>${block.checked ? '☑' : '☐'} $text</p>$nested');
          case 'quote':
            output.write('<blockquote>$text$nested</blockquote>');
          case 'callout':
            output.write('<aside>💡 $text$nested</aside>');
          case 'toggle':
            output.write(
              '<details open><summary>$text</summary>$nested</details>',
            );
          case 'code':
            output.write(
              '<pre><code>${_htmlText(block.text)}</code></pre>$nested',
            );
          case 'equation':
            output.write(
              '<pre class="equation">${_htmlText(block.text)}</pre>$nested',
            );
          case 'divider':
            output.write('<hr>$nested');
          case 'documentLink' when block.noteId != null:
            final path = block.noteId == source.noteId
                ? _relativeHref('$prefix$entrypoint')
                : NoteLink(block.noteId!).toString();
            output.write(
              '<p><a href="${_htmlText(path)}">$text</a></p>$nested',
            );
          case 'linkedDatabase' when block.linkedDatabase != null:
            final linked = block.linkedDatabase!;
            final linkedPath = linked.noteId == source.noteId
                ? _relativeHref('$prefix$entrypoint')
                : NoteLink(linked.noteId).toString();
            output.write(
              '<p><a href="${_htmlText(linkedPath)}">${text.isEmpty ? '연결된 데이터베이스' : text}</a></p>$nested',
            );
          case 'table' when block.table != null:
            if (text.isNotEmpty) output.write('<p>$text</p>');
            output.write('<table>');
            final table = block.table!;
            for (var row = 0; row < table.rows.length; row++) {
              output.write('<tr>');
              for (var column = 0; column < table.columnCount; column++) {
                final heading =
                    table.headerRow && row == 0 ||
                    table.headerColumn && column == 0;
                final tag = heading ? 'th' : 'td';
                final scope = heading
                    ? ' scope="${table.headerRow && row == 0 ? 'col' : 'row'}"'
                    : '';
                output.write(
                  '<$tag$scope>${_htmlText(table.rows[row].cells[column].text).replaceAll('\n', '<br>')}</$tag>',
                );
              }
              output.write('</tr>');
            }
            output.write('</table>$nested');
          default:
            output.write('<p>$text</p>$nested');
        }
      }
      finishList();
      return output.toString();
    }

    return blocks(page.blocks, allowColumns: true);
  }

  void _database(WorkspaceDatabase database, Map<String, Uint8List> original) {
    warnings.add(
      'database-settings: views, filters, forms and automations remain in source/database.json and are not interactive in the export',
    );
    if (database.properties.any((property) => property.isComputed)) {
      warnings.add(
        'computed-static-snapshot: computed cells contain captured values, not live formulas; definitions remain in source JSON, and the report identifies supplied calculation input editions without exporting those related documents',
      );
    }
    final html = format == PortableExportFormat.html;
    final rowExtension = html ? 'html' : 'md';
    final rows = <List<String>>[];
    final headers = [
      '_row_id',
      '_archived',
      '_row_page',
      ...database.properties.map((property) => property.name),
    ];
    for (final row in database.rows) {
      final page = BlockPageDocument.fromJson(row.body);
      _addMedia(page, original);
      _pageWarnings(page);
      final path = 'rows/${row.id}.$rowExtension';
      final title = _rowTitle(database, row);
      final cells = [
        for (final property in database.properties)
          _cell(database, row, property),
      ];
      rows.add([row.id, row.archived.toString(), path, ...cells]);
      final properties = [
        for (var index = 0; index < database.properties.length; index++)
          (database.properties[index].name, cells[index]),
      ];
      if (html) {
        final metadata = properties
            .map(
              (property) =>
                  '<dt>${_htmlText(property.$1)}</dt><dd>${_htmlText(property.$2)}</dd>',
            )
            .join();
        _text(
          path,
          _htmlDocument(
            title,
            '<p><a href="${_htmlText(_relativeHref('../$entrypoint'))}">${_htmlText(source.title)}</a></p><p>${row.archived ? '보관된 행' : '행'} · ${row.id}</p><dl>$metadata</dl>${_htmlPage(page, prefix: '../')}',
          ),
        );
      } else {
        final metadata = properties
            .map(
              (property) =>
                  '- ${_markdownText(property.$1)}: ${_markdownText(property.$2)}',
            )
            .join('\n');
        _text(
          path,
          '# ${_markdownText(title)}\n\n${row.archived ? '보관된 행' : '행'} · ${row.id}\n\n$metadata\n\n${_markdownPage(page, prefix: '../')}',
        );
      }
    }
    if (format == PortableExportFormat.csv) {
      final output = [
        headers,
        ...rows,
      ].map((row) => row.map(_csvCell).join(',')).join('\r\n');
      _text(entrypoint, '\ufeff$output\r\n');
    } else if (html) {
      final head = headers.map((cell) => '<th>${_htmlText(cell)}</th>').join();
      final body = rows
          .map(
            (row) =>
                '<tr>${row.asMap().entries.map((cell) => cell.key == 2 ? '<td><a href="${_htmlText(_relativeHref(cell.value))}">행 본문</a></td>' : '<td>${_htmlText(cell.value)}</td>').join()}</tr>',
          )
          .join();
      _text(
        entrypoint,
        _htmlDocument(
          source.title,
          '<table><thead><tr>$head</tr></thead><tbody>$body</tbody></table>',
        ),
      );
    } else if (format == PortableExportFormat.markdown) {
      String line(List<String> row) =>
          '| ${row.map(_markdownCell).join(' | ')} |';
      final output = [
        '# ${_markdownText(source.title)}',
        '',
        line(headers),
        line(List.filled(headers.length, '---')),
        for (final row in rows)
          line([
            row[0],
            row[1],
            '[행 본문](${_relativeHref(row[2])})',
            ...row.skip(3),
          ]),
      ];
      _text(entrypoint, output.join('\n'));
    }
  }

  String _cell(
    WorkspaceDatabase database,
    DatabaseRow row,
    DatabaseProperty property,
  ) {
    Object? value = row.values[property.id];
    if (property.isComputed) {
      final computed = source.values[row.id]?[property.id];
      if (computed == null) {
        warnings.add(
          'computed-value-missing: ${row.id}/${property.id}; no calculated value was supplied',
        );
        return '#ERROR computed_value_missing';
      }
      if (computed.error case final error?) {
        warnings.add(
          'computed-error: ${row.id}/${property.id}: ${error.code} ${error.message}',
        );
        return '#ERROR ${error.code}: ${error.message}';
      }
      value = computed.value;
    }
    if (!databasePropertyTypes.contains(property.type)) {
      warnings.add(
        'unknown-property: ${property.id} (${property.type}); raw JSON is preserved',
      );
    }
    if (property.type == 'relation' && value != null) {
      for (final ref in value is List ? value : [value]) {
        if (ref is Map &&
            (ref['databaseId'] != database.id ||
                !database.rows.any((row) => row.id == ref['rowId']))) {
          warnings.add(
            'external-relation: ${ref['databaseId']}/${ref['rowId']}; target is outside this export',
          );
        }
      }
      warnings.add(
        'relation-rendering: ${property.id}; fixed database/row identifiers are exported as static JSON',
      );
    }
    if (property.type == 'files' && value is List && value.isNotEmpty) {
      warnings.add(
        'external-files-property: ${property.id}; filename/URL metadata is preserved, remote URLs were not downloaded',
      );
    }
    return switch (value) {
      null => '',
      final String value => value,
      final num value => value.toString(),
      final bool value => value.toString(),
      _ => jsonEncode(value),
    };
  }

  String _csvCell(String value) {
    var escaped = value;
    final numeric = RegExp(r'^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$')
        .hasMatch(value);
    if (!numeric && RegExp(r'^[\x00-\x20]*[=+\-@]').hasMatch(value) ||
        value.startsWith('\t') ||
        value.startsWith('\r') ||
        value.startsWith('\n')) {
      escaped = "'$value";
      warnings.add(
        'spreadsheet-formula-escaped: leading apostrophes protect spreadsheet cells; exact values remain in source JSON',
      );
    }
    return '"${escaped.replaceAll('"', '""')}"';
  }
}

const _knownBlocks = {
  'paragraph',
  'heading1',
  'heading2',
  'heading3',
  'todo',
  'bullet',
  'numbered',
  'quote',
  'callout',
  'toggle',
  'code',
  'equation',
  'divider',
  'documentLink',
  'linkedDatabase',
  'table',
  'image',
  'attachment',
};

const _inlineBlockTypes = {
  'paragraph',
  'heading1',
  'heading2',
  'heading3',
  'todo',
  'bullet',
  'numbered',
  'quote',
  'callout',
  'toggle',
  'table',
  'image',
  'attachment',
};

String _rowTitle(WorkspaceDatabase database, DatabaseRow row) {
  for (final property in database.properties) {
    final value = row.values[property.id];
    if (property.type == 'title' && value is String && value.isNotEmpty)
      return value;
  }
  return row.id;
}

String _basename(String value) {
  var safe = value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  safe = safe.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  safe = String.fromCharCodes(safe.runes.take(80));
  return safe.isEmpty ? 'document' : safe;
}

String _htmlText(String value) =>
    const HtmlEscape(HtmlEscapeMode.attribute).convert(value);
String _htmlDocument(String title, String body) =>
    '<!doctype html>\n<html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src \'self\'; style-src \'unsafe-inline\'; base-uri \'none\'; form-action \'none\'"><title>${_htmlText(title)}</title><style>body{max-width:70rem;margin:2rem auto;padding:0 1rem;font-family:system-ui,sans-serif;line-height:1.6;overflow-wrap:anywhere}img{max-width:100%;height:auto}table{border-collapse:collapse;max-width:100%;display:block;overflow:auto}th,td{border:1px solid #aaa;padding:.4rem;text-align:left;vertical-align:top}pre{white-space:pre-wrap}blockquote,aside{border-left:3px solid #aaa;padding-left:1rem}dt{font-weight:bold}dd{margin-bottom:.5rem}.page-columns{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:1rem}.page-column{min-width:0}@media(max-width:40rem){.page-columns{grid-template-columns:minmax(0,1fr)}}</style></head><body><h1>${_htmlText(title)}</h1>$body</body></html>';

String _markdownText(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
String _markdownLabel(String value) =>
    _markdownText(value)
        .replaceAll('\\', r'\\')
        .replaceAll('[', r'\[')
        .replaceAll(']', r'\]')
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ');
String _markdownCell(String value) =>
    _markdownText(value)
        .replaceAll('\\', r'\\')
        .replaceAll('|', r'\|')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\n', '<br>');
String _relativeHref(String path) => path
    .split('/')
    .map(
      (segment) =>
          Uri.encodeComponent(segment)
              .replaceAll('(', '%28')
              .replaceAll(')', '%29'),
    )
    .join('/');
String _code(String text) {
  final longest = RegExp(r'`+')
      .allMatches(text)
      .fold(0, (length, match) => math.max(length, match[0]!.length));
  final fence = '`' * math.max(3, longest + 1);
  return '$fence\n$text\n$fence';
}

Map<String, Uint8List> _copyFiles(Map<String, Uint8List> files) =>
    Map.unmodifiable({
      for (final entry in files.entries)
        entry.key: Uint8List.fromList(entry.value),
    });
bool _portablePath(String path) {
  if (path.length > 200) return false;
  for (final segment in path.split('/')) {
    if (segment.length > 120 ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        segment.contains(RegExp(r'[<>:"\\|?*\x00-\x1f\x7f]')))
      return false;
    final stem = segment.split('.').first.toUpperCase();
    if (const {
          'CON',
          'PRN',
          'AUX',
          'NUL',
          'CONIN\$',
          'CONOUT\$',
        }.contains(stem) ||
        RegExp(r'^(?:COM|LPT)[1-9¹²³]$').hasMatch(stem))
      return false;
  }
  return true;
}

Object? _freezeJson(Object? value) => switch (value) {
  final Map value => Map<String, Object?>.unmodifiable({
    for (final entry in value.entries)
      entry.key as String: _freezeJson(entry.value),
  }),
  final List value => List<Object?>.unmodifiable(value.map(_freezeJson)),
  _ => value,
};
