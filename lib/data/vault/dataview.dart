import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/dataview_query.dart';
import 'package:saber/data/vault/dataview_result.dart';
import 'package:saber/data/vault/knowledge_index.dart';

final _lineBreak = RegExp(r'\r\n?|\n');

DataviewResult evaluateDataview(
  KnowledgeIndex index,
  InkVaultNative native,
  DataviewQuery query, {
  String? originNoteId,
}) {
  final source = query.source;
  final includes = source == null
      ? null
      : _sourceFilter(index, native, source, originNoteId);
  final candidates = index.documents.values.where(
    (document) =>
        document.dataviewEligible && (includes?.call(document) ?? true),
  );
  if (query.layout == DataviewLayout.task) {
    return _evaluateTasks(candidates, native, query);
  }
  final matches = candidates.where(
    (document) => _matches(document, query.condition),
  );
  if (query.groupBy case final groupBy?) {
    return _evaluateDocumentGroups(matches, query, groupBy);
  }
  final documents = matches.toList()
    ..sort((a, b) => _compare(a, b, query.sorts));
  return DataviewResult(
    table: query.layout == DataviewLayout.table,
    columns: List.unmodifiable(query.columns.map((column) => column.label)),
    rows: List.unmodifiable([
      for (final document in documents.take(query.limit))
        DataviewRow(
          noteId: document.id,
          title: document.title,
          path: document.dataviewPath,
          values: List.unmodifiable([
            for (final column in query.columns)
              _property(document, column.property),
          ]),
        ),
    ]),
  );
}

bool Function(KnowledgeDocument) _sourceFilter(
  KnowledgeIndex index,
  InkVaultNative native,
  DataviewSource source,
  String? originNoteId,
) {
  final resolvedLinks = <String, String?>{};

  bool Function(KnowledgeDocument) compile(DataviewSource current) {
    switch (current) {
      case DataviewTagSource(:final tag):
        final normalizedTag =
            (native.invoke({
                      'op': 'normalize_workspace_segments',
                      'segments': tag.split('/'),
                    })['segments']
                    as List)
                .cast<String>()
                .join('/');
        return (document) =>
            document.dataviewBodyTags.contains(normalizedTag) ||
            document.dataviewTags.any(
              (tag) =>
                  tag == normalizedTag || tag.startsWith('$normalizedTag/'),
            );
      case DataviewFolderSource(:final folder):
        return (document) {
          final path = document.dataviewFolder;
          return path != null &&
              (folder.isEmpty || path == folder || path.startsWith('$folder/'));
        };
      case DataviewLinkSource(:final target, :final outgoing):
        final noteId = resolvedLinks.putIfAbsent(target, () {
          if (target.isEmpty) {
            if (originNoteId == null ||
                !index.documents.containsKey(originNoteId)) {
              throw const FormatException('빈 링크는 조회할 원본 Markdown 문서가 필요합니다.');
            }
            return originNoteId;
          }
          final resolved = index.resolveWikiLink(
            'inkwiki:${Uri.encodeComponent(target)}',
            fromNoteId: originNoteId,
          );
          return resolved?.attachmentName == null ? resolved?.noteId : null;
        });
        if (noteId == null) return (_) => false;
        final linkedDocument = index.documents[noteId]!;
        if (outgoing &&
            (linkedDocument.metadataConflict ||
                linkedDocument.markdownConflict)) {
          return (_) => false;
        }
        final matches = {
          for (final edge in index.edges)
            if (outgoing && edge.from == noteId)
              edge.to
            else if (!outgoing && edge.to == noteId)
              edge.from,
        };
        return (document) => matches.contains(document.id);
      case DataviewSourceLogical(:final left, :final right, :final and):
        final includesLeft = compile(left);
        final includesRight = compile(right);
        return and
            ? (document) => includesLeft(document) && includesRight(document)
            : (document) => includesLeft(document) || includesRight(document);
      case DataviewSourceNegation(:final source):
        final includes = compile(source);
        return (document) => !includes(document);
    }
  }

  return compile(source);
}

DataviewResult _evaluateDocumentGroups(
  Iterable<KnowledgeDocument> documents,
  DataviewQuery query,
  DataviewGroupBy groupBy,
) {
  final membersByKey = <Object?, List<KnowledgeDocument>>{};
  for (final document in documents) {
    final key = _property(document, groupBy.property);
    (membersByKey[key] ??= []).add(document);
  }
  final keys = membersByKey.keys.toList()
    ..sort((left, right) {
      final order = _compareGroupKeys(left, right);
      return groupBy.descending ? -order : order;
    });

  final groups = <DataviewDocumentGroup>[];
  var memberCount = 0;
  for (final key in keys.take(query.limit)) {
    final members = membersByKey[key]!;
    memberCount += members.length;
    if (memberCount > DataviewQuery.maxResults) {
      throw const DataviewDocumentGroupLimitException(DataviewQuery.maxResults);
    }
    members.sort((left, right) => _compare(left, right, query.sorts));
    groups.add(
      DataviewDocumentGroup(
        key,
        [
          for (final member in members)
            DataviewRow(
              noteId: member.id,
              title: member.title,
              path: member.dataviewPath,
              values: const [],
            ),
        ],
        [
          for (final column in query.columns)
            if (column.property.startsWith('rows.'))
              List<Object?>.unmodifiable([
                for (final member in members)
                  _groupedMemberProperty(
                    member,
                    column.property.substring('rows.'.length),
                  ),
              ])
            else
              key,
        ],
      ),
    );
  }
  return DataviewResult.groupedDocuments(
    table: query.layout == DataviewLayout.table,
    columns: [for (final column in query.columns) column.label],
    groupLabel: groupBy.label,
    groups: groups,
    documentLinkColumns: {
      for (final (index, column) in query.columns.indexed)
        if (column.property == 'rows.file.name' ||
            column.property == 'rows.file.link')
          index,
    },
  );
}

Object? _groupedMemberProperty(KnowledgeDocument document, String field) =>
    field == 'file.link'
    ? Map<String, Object?>.unmodifiable({
        'type': 'file',
        'noteId': document.id,
        'title': document.title,
        'path': document.dataviewPath,
      })
    : _property(document, field);

typedef _TaskMatch = ({
  KnowledgeDocument document,
  DataviewTask task,
  Object? groupKey,
});

DataviewResult _evaluateTasks(
  Iterable<KnowledgeDocument> candidates,
  InkVaultNative native,
  DataviewQuery query,
) {
  final condition = query.condition;
  final groupBy = query.groupBy;
  final taskFilter =
      condition?.referencesAny(const {
        'text',
        'line',
        'status',
        'checked',
        'completed',
      }) ??
      false;
  final matches = <_TaskMatch>[];
  // Keep one extra row so we can distinguish a group cut from an oversized group result.
  final retained = groupBy == null ? query.limit : DataviewQuery.maxResults + 1;
  int compare(_TaskMatch a, _TaskMatch b) {
    if (groupBy != null) {
      final order = _compareGroupKeys(a.groupKey, b.groupKey);
      if (order != 0) return groupBy.descending ? -order : order;
    }
    return _compare(
      a.document,
      b.document,
      query.sorts,
      leftTask: a.task,
      rightTask: b.task,
    );
  }

  for (final document in candidates) {
    if (!taskFilter && !_matches(document, condition)) continue;
    for (final task in _readTasks(document, native)) {
      if (taskFilter && !_matches(document, condition, task)) continue;
      matches.add((
        document: document,
        task: task,
        groupKey: groupBy == null
            ? null
            : _property(document, groupBy.property, task),
      ));
      if (matches.length == 2 * retained) {
        matches.sort(compare);
        matches.removeRange(retained, matches.length);
      }
    }
  }
  matches.sort(compare);
  if (groupBy != null) {
    return _groupedTaskResult(matches.take(retained), query.limit);
  }
  return DataviewResult(
    table: false,
    task: true,
    columns: const [],
    rows: List.unmodifiable(matches.take(query.limit).map(_taskRow)),
  );
}

DataviewResult _groupedTaskResult(
  Iterable<_TaskMatch> matches,
  int groupLimit,
) {
  final groups = <DataviewTaskGroup>[];
  var rows = <DataviewRow>[];
  Object? key;
  var count = 0;
  for (final match in matches) {
    if (rows.isNotEmpty && _compareGroupKeys(key, match.groupKey) != 0) {
      groups.add(DataviewTaskGroup(key, rows));
      if (groups.length == groupLimit)
        return DataviewResult.groupedTasks(groups);
      rows = [];
    }
    if (++count > DataviewQuery.maxResults) {
      throw const DataviewTaskGroupLimitException(DataviewQuery.maxResults);
    }
    if (rows.isEmpty) key = match.groupKey;
    rows.add(_taskRow(match));
  }
  if (rows.isNotEmpty) groups.add(DataviewTaskGroup(key, rows));
  return DataviewResult.groupedTasks(groups);
}

DataviewRow _taskRow(_TaskMatch match) => DataviewRow(
  noteId: match.document.id,
  title: match.document.title,
  path: match.document.dataviewPath,
  values: const [],
  task: match.task,
);

int _compareGroupKeys(Object? a, Object? b) {
  if (a == b) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  return _compareValues(a, b);
}

Iterable<DataviewTask> _readTasks(
  KnowledgeDocument document,
  InkVaultNative native,
) sync* {
  final source = document.dataviewTaskSource;
  if (source == null) return;
  final markdown = document.markdown;
  final body = markdown.substring(source.bodyStart);
  if (!body.contains('[')) return;
  final lineOffset = _lineBreak
      .allMatches(markdown.substring(0, source.bodyStart))
      .length;
  final markers = native.invoke({
    'op': 'dataview_task_markers',
    'markdown': body,
  })['tasks'];
  const invalid = FormatException('Invalid saved Markdown task position');
  if (markers is! List) throw invalid;

  final breaks = _lineBreak.allMatches(body).iterator;
  Match? nextBreak = breaks.moveNext() ? breaks.current : null;
  var bodyLine = 1;
  var lineStart = 0;
  var previousOffset = -1;
  for (final marker in markers) {
    if (marker is! Map ||
        marker['line'] is! int ||
        marker['statusOffset'] is! int ||
        marker['status'] is! String) {
      throw invalid;
    }
    final offset = marker['statusOffset'] as int;
    final line = marker['line'] as int;
    final status = marker['status'] as String;
    if (offset <= previousOffset || status.runes.length != 1) throw invalid;
    previousOffset = offset;
    while (nextBreak != null && offset >= nextBreak.start) {
      lineStart = nextBreak.end;
      nextBreak = breaks.moveNext() ? breaks.current : null;
      bodyLine++;
    }
    final closing = offset + status.length;
    final end = nextBreak?.start ?? body.length;
    if (line != bodyLine ||
        offset <= lineStart ||
        closing >= end ||
        body.substring(offset - 1, closing + 1) != '[$status]') {
      throw invalid;
    }
    yield DataviewTask(
      text: body.substring(closing + 1, end).trim(),
      line: line + lineOffset,
      status: status,
      statusOffset: offset + source.bodyStart,
      revisionId: source.revisionId,
    );
  }
}

bool _matches(
  KnowledgeDocument document,
  DataviewCondition? condition, [
  DataviewTask? task,
]) => switch (condition) {
  null => true,
  DataviewFilter() => _matchesFilter(document, condition, task),
  DataviewNegation(:final condition) => !_matches(document, condition, task),
  DataviewLogical(:final left, :final right, and: true) =>
    _matches(document, left, task) && _matches(document, right, task),
  DataviewLogical(:final left, :final right) =>
    _matches(document, left, task) || _matches(document, right, task),
};

bool _matchesFilter(
  KnowledgeDocument document,
  DataviewFilter filter,
  DataviewTask? task,
) {
  final property = filter.property;
  final value = _property(document, property, task);
  final operator = filter.operator;
  if (operator == DataviewOperator.truthy) {
    return switch (value) {
      bool() => value,
      num() => value != 0,
      String() => value.isNotEmpty,
      _ => false,
    };
  }
  if (value == null &&
      (const {'file.name', 'file.path', 'file.folder'}.contains(property) ||
          !document.dataviewProperties.containsKey(property))) {
    return false;
  }
  final expected = filter.value;
  if (operator == DataviewOperator.equal) return value == expected;
  if (operator == DataviewOperator.notEqual) return value != expected;
  final order = switch ((value, expected)) {
    (final num left, final num right) => left.compareTo(right),
    (final String left, final String right) => left.compareTo(right),
    (final bool left, final bool right) => (left ? 1 : 0).compareTo(
      right ? 1 : 0,
    ),
    _ => null,
  };
  if (order == null) return false;
  return switch (operator) {
    DataviewOperator.less => order < 0,
    DataviewOperator.lessOrEqual => order <= 0,
    DataviewOperator.greater => order > 0,
    DataviewOperator.greaterOrEqual => order >= 0,
    _ => false,
  };
}

int _compare(
  KnowledgeDocument a,
  KnowledgeDocument b,
  List<DataviewSort> sorts, {
  DataviewTask? leftTask,
  DataviewTask? rightTask,
}) {
  for (final sort in sorts) {
    final left = _property(a, sort.property, leftTask);
    final right = _property(b, sort.property, rightTask);
    if (left != null && right != null) {
      final order = _compareValues(left, right);
      if (order != 0) return sort.descending ? -order : order;
    } else if (left != null || right != null) {
      return left == null ? 1 : -1;
    }
  }
  final title = a.title.compareTo(b.title);
  if (title != 0) return title;
  final id = a.id.compareTo(b.id);
  if (id != 0) return id;
  return leftTask == null || rightTask == null
      ? 0
      : leftTask.line.compareTo(rightTask.line);
}

Object? _property(
  KnowledgeDocument document,
  String property, [
  DataviewTask? task,
]) {
  if (task != null) {
    switch (property) {
      case 'text':
        return task.text;
      case 'line':
        return task.line;
      case 'status':
        return task.status;
      case 'checked':
        return task.checked;
      case 'completed':
        return task.completed;
    }
  }
  return switch (property) {
    'file.name' => document.title,
    'file.path' => document.dataviewPath,
    'file.folder' => document.dataviewFolder,
    _ => document.dataviewProperties[property],
  };
}

int _compareValues(Object a, Object b) {
  if (a is num && b is num) return a.compareTo(b);
  if (a is bool && b is bool) return (a ? 1 : 0).compareTo(b ? 1 : 0);
  if (a is String && b is String) return a.compareTo(b);
  int type(Object value) => switch (value) {
    bool() => 0,
    num() => 1,
    _ => 2,
  };
  return type(a).compareTo(type(b));
}
