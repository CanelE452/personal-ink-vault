import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/knowledge_index.dart';

typedef _GraphOptions = ({
  int depth,
  bool incoming,
  bool outgoing,
  bool interlinks,
});

class KnowledgePanel extends StatefulWidget {
  final KnowledgeIndex index;
  final String? selectedNoteId;
  final ValueChanged<String> onOpenNote;
  final ValueChanged<String>? onOpenMentionSource;
  final Future<void> Function(KnowledgeUnlinkedMention)? onLinkMention;
  final bool mentionsCurrent;
  final bool canLinkMentions;
  final String? linkDisabledReason;

  const new({
    super.key,
    required this.index,
    this.selectedNoteId,
    required this.onOpenNote,
    this.onOpenMentionSource,
    this.onLinkMention,
    this.mentionsCurrent = true,
    this.canLinkMentions = false,
    this.linkDisabledReason,
  });

  @override
  State<KnowledgePanel> createState() => _KnowledgePanelState();
}

class _KnowledgePanelState extends State<KnowledgePanel> {
  String? _selectedTag;
  var _localGraph = false;
  _GraphOptions _graphOptions = (
    depth: 1,
    incoming: true,
    outgoing: true,
    interlinks: false,
  );

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(text: '역링크'),
            Tab(text: '태그'),
            Tab(text: '그래프'),
          ],
        ),
        Expanded(
          child: TabBarView(children: [_backlinks(), _tags(), _graph()]),
        ),
      ],
    ),
  );

  Widget _document(KnowledgeDocument document) => ListTile(
    leading: const Icon(Icons.description_outlined),
    title: Text(document.title),
    subtitle: document.metadataConflict || document.markdownConflict
        ? const Text('여러 수정본이 보관되어 있습니다')
        : null,
    trailing: const Icon(Icons.chevron_right),
    onTap: () => widget.onOpenNote(document.id),
  );

  Widget _backlinks() {
    final selected = widget.selectedNoteId;
    if (selected == null)
      return const Center(child: Text('문서를 선택하면 역링크를 볼 수 있습니다.'));
    final backlinks = widget.index.backlinks(selected);
    final unresolved = widget.index.unresolved
        .where((link) => link.from == selected)
        .toList();
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        if (backlinks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('이 문서를 가리키는 링크가 없습니다.'),
          ),
        ...backlinks.map(_document),
        if (unresolved.isNotEmpty) ...[
          const Divider(),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text('연결할 문서를 찾지 못한 링크'),
          ),
          for (final link in unresolved)
            ListTile(
              leading: const Icon(Icons.link_off),
              title: Text(link.target),
              subtitle: const Text('문서가 없거나 같은 이름의 문서가 여러 개 있습니다.'),
            ),
        ],
        if (widget.onOpenMentionSource case final openSource?)
          _UnlinkedMentions(
            index: widget.index,
            targetId: selected,
            onOpenSource: openSource,
            onLinkMention: widget.onLinkMention,
            current: widget.mentionsCurrent,
            canLink: widget.canLinkMentions,
            linkDisabledReason: widget.linkDisabledReason,
          ),
      ],
    );
  }

  Widget _tags() {
    if (widget.index.tags.isEmpty)
      return const Center(child: Text('Markdown에 #태그를 적어 문서를 모아보세요.'));
    final selected = widget.index.tags.containsKey(_selectedTag)
        ? _selectedTag!
        : widget.index.tags.keys.first;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final tag in widget.index.tags.keys)
              FilterChip(
                label: Text('#$tag'),
                selected: tag == selected,
                onSelected: (_) => setState(() => _selectedTag = tag),
              ),
          ],
        ),
        const SizedBox(height: 12),
        for (final document in widget.index.tags[selected]!)
          _document(document),
      ],
    );
  }

  Widget _graph() {
    final canShowLocal = widget.index.documents.containsKey(
      widget.selectedNoteId,
    );
    final local = _localGraph && canShowLocal;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('전체'),
                selected: !local,
                onSelected: (_) => setState(() => _localGraph = false),
              ),
              ChoiceChip(
                label: const Text('현재 문서'),
                selected: local,
                onSelected: canShowLocal
                    ? (_) => setState(() => _localGraph = true)
                    : null,
              ),
              if (local)
                TextButton(
                  onPressed: _configureGraph,
                  child: const Text('그래프 설정'),
                ),
            ],
          ),
        ),
        Expanded(
          child: _KnowledgeGraph(
            index: widget.index,
            selectedNoteId: widget.selectedNoteId,
            options: local ? _graphOptions : null,
            onOpenNote: widget.onOpenNote,
          ),
        ),
      ],
    );
  }

  Future<void> _configureGraph() async {
    var (:depth, :incoming, :outgoing, :interlinks) = _graphOptions;
    final chosen = await showDialog<_GraphOptions>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('그래프 설정'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                key: const ValueKey('knowledge-graph-depth'),
                decoration: const InputDecoration(labelText: '연결 깊이'),
                initialValue: depth,
                items: [
                  for (var level = 1; level <= 5; level++)
                    DropdownMenuItem(value: level, child: Text('$level단계')),
                ],
                onChanged: (level) {
                  if (level != null) setDialogState(() => depth = level);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('나가는 링크'),
                value: outgoing,
                onChanged: (value) => setDialogState(() => outgoing = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('들어오는 링크'),
                value: incoming,
                onChanged: (value) => setDialogState(() => incoming = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('이웃 간 연결'),
                value: interlinks,
                onChanged: (value) => setDialogState(() => interlinks = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop((
                depth: depth,
                incoming: incoming,
                outgoing: outgoing,
                interlinks: interlinks,
              )),
              child: const Text('적용'),
            ),
          ],
        ),
      ),
    );
    if (mounted && chosen != null) setState(() => _graphOptions = chosen);
  }
}

class _UnlinkedMentions extends StatefulWidget {
  final KnowledgeIndex index;
  final String targetId;
  final ValueChanged<String> onOpenSource;
  final Future<void> Function(KnowledgeUnlinkedMention)? onLinkMention;
  final bool current;
  final bool canLink;
  final String? linkDisabledReason;

  const new({
    required this.index,
    required this.targetId,
    required this.onOpenSource,
    required this.onLinkMention,
    required this.current,
    required this.canLink,
    required this.linkDisabledReason,
  });

  @override
  State<_UnlinkedMentions> createState() => _UnlinkedMentionsState();
}

class _UnlinkedMentionsState extends State<_UnlinkedMentions> {
  Future<KnowledgeUnlinkedMentions>? _scan;
  var _writing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scanIfCurrent();
  }

  @override
  void didUpdateWidget(_UnlinkedMentions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.index, widget.index) ||
        oldWidget.targetId != widget.targetId) {
      _scan = null;
      _error = null;
    }
    _scanIfCurrent();
  }

  void _scanIfCurrent() {
    if (widget.current) {
      _scan ??= widget.index.unlinkedMentions(widget.targetId);
    }
  }

  Future<void> _link(KnowledgeUnlinkedMention mention) async {
    final write = widget.onLinkMention;
    if (write == null || _writing || !widget.current || !widget.canLink) return;
    setState(() {
      _writing = true;
      _error = null;
    });
    try {
      await write(mention);
    } on StateError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '이 언급을 링크로 연결하지 못했습니다.');
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Widget _message(String message, {bool error = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
    child: Text(
      message,
      style: error
          ? TextStyle(color: Theme.of(context).colorScheme.error)
          : null,
    ),
  );

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(),
      _message('미연결 언급'),
      if (_error case final error?) _message(error, error: true),
      FutureBuilder<KnowledgeUnlinkedMentions>(
        future: _scan,
        builder: (context, snapshot) {
          if (!widget.current ||
              snapshot.connectionState != ConnectionState.done) {
            return _message('미연결 언급을 찾는 중입니다.');
          }
          if (snapshot.hasError) {
            final error = snapshot.error;
            return _message(
              error is InkVaultNativeException &&
                      error.code == 'unknown_operation'
                  ? '현재 설치본에서 미연결 언급을 검색할 수 없습니다.'
                  : '미연결 언급을 불러오지 못했습니다.',
            );
          }
          final result = snapshot.requireData;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (result.mentions.isEmpty)
                _message('이 문서 이름이나 별칭을 언급하는 문장이 없습니다.'),
              if (result.mentions.isNotEmpty &&
                  widget.linkDisabledReason != null)
                _message(widget.linkDisabledReason!),
              for (final mention in result.mentions)
                ListTile(
                  key: ValueKey((mention.sourceId, mention.start, mention.end)),
                  title: Text(
                    widget.index.documents[mention.sourceId]?.title ?? '원문',
                  ),
                  subtitle: Text(
                    mention.snippet,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => widget.onOpenSource(mention.sourceId),
                  trailing: TextButton(
                    onPressed:
                        widget.canLink &&
                            !_writing &&
                            widget.onLinkMention != null
                        ? () => _link(mention)
                        : null,
                    child: const Text('링크로 연결'),
                  ),
                ),
              if (result.truncated)
                _message('미연결 언급 검색 한도에 도달했습니다. 일부 결과만 표시합니다.'),
            ],
          );
        },
      ),
    ],
  );
}

class _KnowledgeGraph extends StatelessWidget {
  final KnowledgeIndex index;
  final String? selectedNoteId;
  final _GraphOptions? options;
  final ValueChanged<String> onOpenNote;
  const new({
    required this.index,
    required this.selectedNoteId,
    required this.options,
    required this.onOpenNote,
  });

  @override
  Widget build(BuildContext context) {
    if (index.documents.isEmpty)
      return const Center(child: Text('문서를 만들고 [[문서 이름]]으로 연결해보세요.'));
    final List<KnowledgeDocument> documents;
    final List<KnowledgeEdge> edges;
    final center = selectedNoteId;
    final settings = options;
    if (center != null && settings != null) {
      final graph = index.localGraph(
        center,
        depth: settings.depth,
        incoming: settings.incoming,
        outgoing: settings.outgoing,
        interlinks: settings.interlinks,
      );
      documents = graph.documents;
      edges = graph.edges;
    } else {
      documents = index.documents.values.toList()
        ..sort((a, b) => a.id.compareTo(b.id));
      final selected = documents.indexWhere((d) => d.id == center);
      if (selected > 0) documents.insert(0, documents.removeAt(selected));
      edges = index.edges;
    }
    final relative = <String, Offset>{documents.first.id: Offset.zero};
    var cursor = 1;
    var radius = 0.0;
    while (cursor < documents.length) {
      radius += 150;
      final count = math.min(
        documents.length - cursor,
        (2 * math.pi * radius / 130).floor(),
      );
      for (var i = 0; i < count; i++) {
        final angle = -math.pi / 2 + 2 * math.pi * i / count;
        relative[documents[cursor++].id] = Offset(
          math.cos(angle) * radius,
          math.sin(angle) * radius,
        );
      }
    }
    final side = math.max(360.0, radius * 2 + 150);
    final positions = relative.map(
      (id, offset) => MapEntry(id, offset + Offset(side / 2, side / 2)),
    );
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            '${documents.length}개 문서 · ${edges.length}개 연결\n확대하거나 문서를 눌러 열 수 있습니다.',
            textAlign: TextAlign.center,
          ),
        ),
        Expanded(
          child: InteractiveViewer(
            key: ValueKey((documents.first.id, options)),
            minScale: .5,
            maxScale: 6,
            child: Center(
              child: FittedBox(
                child: SizedBox(
                  width: side,
                  height: side,
                  child: CustomPaint(
                    painter: _GraphPainter(
                      positions,
                      edges,
                      colors.outlineVariant,
                    ),
                    child: Stack(
                      children: [
                        for (final document in documents)
                          Positioned(
                            left: positions[document.id]!.dx - 58,
                            top: positions[document.id]!.dy - 30,
                            width: 116,
                            height: 60,
                            child: Semantics(
                              button: true,
                              label: '문서: ${document.title}',
                              onTap: () => onOpenNote(document.id),
                              child: ExcludeSemantics(
                                child: Tooltip(
                                  message: '${document.title} 열기',
                                  child: TextButton(
                                    key: ValueKey(
                                      'knowledge-node-${document.id}',
                                    ),
                                    style: TextButton.styleFrom(
                                      backgroundColor:
                                          document.id == selectedNoteId
                                          ? colors.primaryContainer
                                          : colors.surfaceContainerHighest,
                                      foregroundColor:
                                          document.id == selectedNoteId
                                          ? colors.onPrimaryContainer
                                          : colors.onSurface,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 8,
                                      ),
                                    ),
                                    onPressed: () => onOpenNote(document.id),
                                    child: Text(
                                      document.title,
                                      textAlign: TextAlign.center,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GraphPainter extends CustomPainter {
  final Map<String, Offset> positions;
  final List<KnowledgeEdge> edges;
  final Color color;
  new(this.positions, this.edges, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    for (final edge in edges) {
      final from = positions[edge.from];
      final to = positions[edge.to];
      if (from != null && to != null && from != to)
        canvas.drawLine(from, to, paint);
    }
  }

  @override
  bool shouldRepaint(_GraphPainter oldDelegate) =>
      oldDelegate.positions != positions ||
      oldDelegate.edges != edges ||
      oldDelegate.color != color;
}
