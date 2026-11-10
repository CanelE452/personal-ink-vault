final class DataviewTask {
  const new({
    required this.text,
    required this.line,
    required this.status,
    required this.statusOffset,
    required this.revisionId,
  });

  final String text;
  final int line;
  final String status;
  final int statusOffset;
  final String revisionId;

  bool get checked => status != ' ';
  bool get completed => status == 'x' || status == 'X';
}

final class DataviewRow {
  const new({
    required this.noteId,
    required this.title,
    this.path,
    required this.values,
    this.task,
  });

  final String noteId;
  final String title;
  final String? path;
  final List<Object?> values;
  final DataviewTask? task;
}

final class DataviewTaskGroup {
  new(this.key, List<DataviewRow> rows) : rows = List.unmodifiable(rows);

  final Object? key;
  final List<DataviewRow> rows;
}

final class DataviewTaskGroupLimitException implements Exception {
  const new(this.limit);

  final int limit;
  String get message =>
      '그룹의 할 일이 $limit개를 넘습니다. FROM, WHERE 또는 LIMIT로 범위를 줄이세요.';
}

final class DataviewDocumentGroup {
  new(this.key, List<DataviewRow> rows, List<Object?> values)
    : rows = List.unmodifiable(rows),
      values = List.unmodifiable(values);

  final Object? key;
  final List<DataviewRow> rows;
  final List<Object?> values;
}

final class DataviewDocumentGroupLimitException implements Exception {
  const new(this.limit);

  final int limit;
  String get message =>
      '그룹의 노트가 $limit개를 넘습니다. FROM, WHERE 또는 LIMIT로 범위를 줄이세요.';
}

final class DataviewResult {
  const new({
    required this.table,
    this.task = false,
    required this.columns,
    required this.rows,
  }) : groups = null,
       documentGroups = null,
       documentGroupLabel = null,
       documentLinkColumns = const {};

  new groupedTasks(List<DataviewTaskGroup> groups)
    : table = false,
      task = true,
      columns = const [],
      rows = const [],
      groups = List.unmodifiable(groups),
      documentGroups = null,
      documentGroupLabel = null,
      documentLinkColumns = const {};

  new groupedDocuments({
    required this.table,
    required List<String> columns,
    required String groupLabel,
    required List<DataviewDocumentGroup> groups,
    required Set<int> documentLinkColumns,
  }) : task = false,
       columns = List.unmodifiable(columns),
       rows = const [],
       groups = null,
       documentGroups = List.unmodifiable(groups),
       documentGroupLabel = groupLabel,
       documentLinkColumns = Set.unmodifiable(documentLinkColumns);

  final bool table;
  final bool task;
  final List<String> columns;
  final List<DataviewRow> rows;
  final List<DataviewTaskGroup>? groups;
  final List<DataviewDocumentGroup>? documentGroups;
  final String? documentGroupLabel;
  final Set<int> documentLinkColumns;

  bool get isEmpty =>
      groups?.isEmpty ?? documentGroups?.isEmpty ?? rows.isEmpty;
}
