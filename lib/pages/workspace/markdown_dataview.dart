part of 'markdown_editor.dart';

const _dataviewTag = 'ink-dataview';
const _dataviewQueryAttribute = 'query';

class _DataviewFenceSyntax extends md.FencedCodeBlockSyntax {
  const new();

  @override
  md.Node parse(md.BlockParser parser) {
    final fence = super.parse(parser);
    if (fence case md.Element(children: final children?)) {
      final code = children.singleOrNull;
      if (code is md.Element &&
          code.attributes['class'] == 'language-dataview') {
        return md.Element.empty(_dataviewTag)
          ..attributes[_dataviewQueryAttribute] = code.textContent;
      }
    }
    return fence;
  }
}

class _DataviewBudget {
  static const limit = 12;
  var _remaining = limit;

  void reserve(List<md.Node> nodes) {
    for (final node in nodes) {
      if (node is! md.Element) continue;
      if (node.tag == _dataviewTag) {
        if (_remaining == 0) {
          node.attributes.remove(_dataviewQueryAttribute);
        } else {
          _remaining--;
        }
      }
      if (node.children case final children?) reserve(children);
    }
  }
}

class _DataviewFenceBuilder extends MarkdownElementBuilder {
  new(this.access, this.allowTaskEdits, this.originNoteId);

  final MarkdownDataviewAccess access;
  final bool allowTaskEdits;
  final String? originNoteId;

  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final query = element.attributes[_dataviewQueryAttribute];
    return query == null
        ? const Text('Dataview 조회는 이 미리보기에서 ${_DataviewBudget.limit}개까지 표시합니다.')
        : _DataviewBlock(
            query: query,
            access: access,
            allowTaskEdits: allowTaskEdits,
            originNoteId: originNoteId,
          );
  }
}

class _DataviewBlock extends StatefulWidget {
  const new({
    required this.query,
    required this.access,
    required this.allowTaskEdits,
    required this.originNoteId,
  });

  final String query;
  final MarkdownDataviewAccess access;
  final bool allowTaskEdits;
  final String? originNoteId;

  @override
  State<_DataviewBlock> createState() => _DataviewBlockState();
}

class _DataviewBlockState extends State<_DataviewBlock> {
  Future<DataviewResult>? _result;
  var _savingTask = false;

  @override
  void didUpdateWidget(_DataviewBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != oldWidget.query ||
        widget.originNoteId != oldWidget.originNoteId ||
        !identical(widget.access, oldWidget.access)) {
      _result = null;
    }
  }

  Future<DataviewResult> _evaluate() async {
    final origin = widget.originNoteId;
    final evaluateFromNote = widget.access.evaluateFromNote;
    if (origin != null && evaluateFromNote != null) {
      return evaluateFromNote(widget.query, origin);
    }
    return widget.access.evaluate(widget.query);
  }

  Future<void> _open(String noteId, Future<DataviewResult> result) async {
    if (!mounted || !identical(_result, result)) return;
    try {
      await widget.access.openNote(noteId);
    } catch (_) {
      if (mounted && identical(_result, result)) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('노트를 열 수 없습니다.')));
      }
    }
  }

  Future<void> _toggleTask(
    DataviewRow row,
    bool completed,
    Future<DataviewResult> result,
  ) async {
    final toggle = widget.access.toggleTask;
    if (!mounted ||
        !identical(_result, result) ||
        !widget.allowTaskEdits ||
        _savingTask ||
        toggle == null) {
      return;
    }
    setState(() => _savingTask = true);
    var saved = false;
    try {
      await toggle(row, completed);
      saved = true;
    } catch (_) {
      if (mounted && identical(_result, result)) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('할 일 상태를 저장할 수 없습니다. 원본 노트를 확인하세요.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _savingTask = false;
          if (saved &&
              identical(_result, result) &&
              (widget.access.isCurrent?.call() ?? true)) {
            _result = null;
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result ??= _evaluate();
    return Padding(
      padding: const EdgeInsets.all(8),
      child: FutureBuilder<DataviewResult>(
        future: result,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Semantics(
              liveRegion: true,
              child: const Text('Dataview 결과 불러오는 중'),
            );
          }
          if (snapshot.hasError) {
            if (snapshot.error
                case final DataviewTaskGroupLimitException error) {
              return Text(error.message);
            }
            if (snapshot.error
                case final DataviewDocumentGroupLimitException error) {
              return Text(error.message);
            }
            return Text(
              snapshot.error is FormatException
                  ? '지원하지 않는 Dataview 쿼리입니다.'
                  : 'Dataview 결과를 불러올 수 없습니다.',
            );
          }
          final data = snapshot.requireData;
          if (data.isEmpty) {
            return Text(data.task ? '조건에 맞는 할 일이 없습니다.' : '조건에 맞는 노트가 없습니다.');
          }
          return _DataviewRows(
            result: data,
            openNote: (noteId) => unawaited(_open(noteId, result)),
            toggleTask:
                widget.allowTaskEdits &&
                    widget.access.toggleTask != null &&
                    !_savingTask
                ? (row, completed) =>
                      unawaited(_toggleTask(row, completed, result))
                : null,
          );
        },
      ),
    );
  }
}

class _DataviewRows extends StatelessWidget {
  const new({
    required this.result,
    required this.openNote,
    required this.toggleTask,
  });

  final DataviewResult result;
  final ValueChanged<String> openNote;
  final void Function(DataviewRow row, bool completed)? toggleTask;

  Widget _note(DataviewRow row) =>
      TextButton(onPressed: () => openNote(row.noteId), child: Text(row.title));

  Widget _value(String value, {TextStyle? style}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Text(value, style: style),
  );

  String _cell(DataviewRow row, int index) =>
      index < row.values.length ? row.values[index]?.toString() ?? '' : '';

  String _groupKeyLabel(Object? key) => switch (key) {
    null => '(값 없음)',
    '' => '(빈 문자열)',
    final value => value.toString(),
  };

  Widget _groupNoteLinks(DataviewDocumentGroup group) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final row in group.rows)
        Tooltip(message: row.path ?? row.title, child: _note(row)),
    ],
  );

  Widget _groupHeading(DataviewDocumentGroup group, TextStyle? style) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        child: _value(_groupKeyLabel(group.key), style: style),
      ),
      if (result.documentLinkColumns.isEmpty) _groupNoteLinks(group),
    ],
  );

  Widget _groupCell(DataviewDocumentGroup group, int column) {
    if (result.documentLinkColumns.contains(column))
      return _groupNoteLinks(group);
    final value = group.values[column];
    if (value is List<Object?>) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final item in value) _value(item?.toString() ?? '—')],
      );
    }
    return _value(_groupKeyLabel(value));
  }

  Widget _task(DataviewRow row, DataviewTask task) {
    final toggle = toggleTask;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!task.checked || task.completed)
          Checkbox(
            value: task.completed,
            semanticLabel: task.text,
            onChanged: toggle == null
                ? null
                : (value) {
                    if (value != null) toggle(row, value);
                  },
          )
        else
          SizedBox(
            width: kMinInteractiveDimension,
            height: kMinInteractiveDimension,
            child: Center(child: Text('[${task.status}]')),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(task.text),
                TextButton(
                  onPressed: () => openNote(row.noteId),
                  child: Text('${row.title} · ${task.line}줄'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _tasks(List<DataviewRow> rows) => [
    for (final row in rows)
      if (row.task case final task?) _task(row, task),
  ];

  @override
  Widget build(BuildContext context) {
    final rows = result.rows;
    if (result.task) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (result.groups case final groups?)
            for (final group in groups) ...[
              Semantics(
                header: true,
                child: _value(
                  _groupKeyLabel(group.key),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ..._tasks(group.rows),
            ]
          else
            ..._tasks(rows),
        ],
      );
    }
    final groups = result.documentGroups;
    final heading = Theme.of(context).textTheme.titleSmall;
    if (!result.table) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (groups == null)
            for (final row in rows) _note(row)
          else
            for (final (index, group) in groups.indexed) ...[
              if (index > 0) const Divider(),
              _groupHeading(group, heading),
              for (var column = 0; column < result.columns.length; column++)
                _groupCell(group, column),
            ],
        ],
      );
    }
    final columns = result.columns;
    final header = Theme.of(context).textTheme.labelLarge;
    final count = groups?.length ?? rows.length;
    Widget title(int index) => groups == null
        ? _note(rows[index])
        : _groupHeading(groups[index], heading);
    Widget cell(int index, int column) => groups == null
        ? _value(_cell(rows[index], column))
        : _groupCell(groups[index], column);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedWidth &&
            constraints.maxWidth >= 520 &&
            constraints.maxWidth >= (columns.length + 1) * 128) {
          return Table(
            defaultVerticalAlignment: groups == null
                ? TableCellVerticalAlignment.middle
                : TableCellVerticalAlignment.top,
            border: TableBorder(
              horizontalInside: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            children: [
              TableRow(
                children: [
                  _value(result.documentGroupLabel ?? '노트', style: header),
                  for (final column in columns) _value(column, style: header),
                ],
              ),
              for (var index = 0; index < count; index++)
                TableRow(
                  children: [
                    title(index),
                    for (var column = 0; column < columns.length; column++)
                      cell(index, column),
                  ],
                ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var index = 0; index < count; index++) ...[
              if (index > 0) const Divider(),
              if (result.documentGroupLabel case final label?)
                _value(label, style: header),
              title(index),
              for (var column = 0; column < columns.length; column++) ...[
                _value(columns[column], style: header),
                cell(index, column),
              ],
            ],
          ],
        );
      },
    );
  }
}
