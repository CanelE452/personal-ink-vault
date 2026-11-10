import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_history.dart';

class BlockPageHistorySheet extends StatefulWidget {
  const new({
    super.key,
    required this.snapshot,
    required this.onRestore,
    required this.isCurrent,
  });

  final BlockPageHistorySnapshot snapshot;
  final Future<void> Function(RevisionRecord) onRestore;
  final bool Function() isCurrent;

  @override
  State<BlockPageHistorySheet> createState() => _BlockPageHistorySheetState();
}

class _BlockPageHistorySheetState extends State<BlockPageHistorySheet> {
  static const _teal = Color(0xff237d82);
  static const _paper = Color(0xfffdfdf9);
  static const _border = Color(0xffd7dfd8);
  late RevisionRecord _selected;
  BlockPageDocument? _preview;
  BlockPageHistoryDiff? _diff;
  var _generation = 0;
  var _loading = false;
  var _restoring = false;
  String? _error;

  bool get _selectedIsCurrent =>
      _selected.revisionId == widget.snapshot.currentRevision.revisionId;

  @override
  void initState() {
    super.initState();
    _selected = widget.snapshot.currentRevision;
    _preview = widget.snapshot.currentDocument;
    _diff = BlockPageHistoryDiff.compare(_preview!, _preview!);
  }

  bool _accept(int generation) {
    if (!mounted || generation != _generation) return false;
    if (widget.isCurrent()) return true;
    setState(() {
      _loading = false;
      _restoring = false;
      _error = '열린 페이지가 바뀌었습니다. 이력을 닫고 다시 여세요.';
    });
    return false;
  }

  Future<void> _select(RevisionRecord revision) async {
    if (_restoring) return;
    if (!widget.isCurrent()) {
      _accept(_generation);
      return;
    }
    final generation = ++_generation;
    setState(() {
      _selected = revision;
      _preview = null;
      _diff = null;
      _error = null;
      _loading = !revision.deleted;
    });
    if (revision.deleted) return;
    try {
      final document = await widget.snapshot.readRevision(revision);
      final diff = BlockPageHistoryDiff.compare(
        document,
        widget.snapshot.currentDocument,
      );
      if (!_accept(generation)) return;
      setState(() {
        _preview = document;
        _diff = diff;
        _loading = false;
      });
    } catch (_) {
      if (!_accept(generation)) return;
      setState(() {
        _loading = false;
        _error = '이 판본을 읽지 못했습니다. 다시 선택해 보세요.';
      });
    }
  }

  Future<void> _restore() async {
    if (_restoring ||
        _loading ||
        _preview == null ||
        _selected.deleted ||
        _selectedIsCurrent) {
      return;
    }
    final generation = _generation;
    if (!_accept(generation)) return;
    setState(() {
      _restoring = true;
      _error = null;
    });
    try {
      await widget.onRestore(_selected);
      if (!mounted || !_accept(generation)) return;
      setState(() => _restoring = false);
      Navigator.of(context).pop();
    } catch (_) {
      if (!_accept(generation)) return;
      setState(() {
        _restoring = false;
        _error = '복원하지 못했습니다. 현재 저장본을 확인한 뒤 다시 시도하세요.';
      });
    }
  }

  Widget _revisions() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Text('저장된 판본', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      for (final revision in widget.snapshot.revisions)
        ListTile(
          key: ValueKey('history-revision-${revision.revisionId}'),
          selected: _selected.revisionId == revision.revisionId,
          selectedTileColor: _teal.withValues(alpha: .08),
          selectedColor: _teal,
          enabled: !_restoring && widget.isCurrent(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
          title: Text(
            _short(revision.revisionId),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          ),
          subtitle: Text(
            [
              '기기 ${_short(revision.deviceId)}',
              if (revision.revisionId ==
                  widget.snapshot.currentRevision.revisionId)
                '현재',
              if (revision.deleted) '삭제됨',
            ].join(' · '),
            style: const TextStyle(fontSize: 12),
          ),
          trailing: _selected.revisionId == revision.revisionId
              ? const Icon(Icons.check, size: 18)
              : null,
          onTap: () => unawaited(_select(revision)),
        ),
    ],
  );

  Widget _documentPanel(String title, BlockPageDocument document) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: _paper,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              SelectableText(
                document.toMarkdown().trimRight(),
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
              if (document.blocks.isEmpty)
                const Text('빈 페이지', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );

  Widget _changes(BlockPageHistoryDiff diff) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: 20),
      const Text('변경 내용', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      const Text('선택한 판본 → 현재 저장본', style: TextStyle(fontSize: 12)),
      if (diff.pageMetadataChanged)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('페이지 속성이 바뀌었습니다.'),
        ),
      if (diff.changes.isEmpty && !diff.pageMetadataChanged)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('변경된 내용이 없습니다.'),
        ),
      for (final change in diff.changes)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: _border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              title: Text(
                '블록 ${_short(change.blockId)}',
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                change.kinds.map(_kindLabel).join(' · '),
                style: const TextStyle(fontSize: 12),
              ),
              children: [
                if (change.kinds.contains(BlockPageChangeKind.moved))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      '${_position(change.beforeParentId, change.beforeIndex)}'
                      ' → ${_position(change.afterParentId, change.afterIndex)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                _rawBlock('과거 블록 속성', change.before),
                const SizedBox(height: 10),
                _rawBlock('현재 블록 속성', change.after),
              ],
            ),
          ),
        ),
    ],
  );

  Widget _rawBlock(String title, BlockPageBlock? block) => Align(
    alignment: Alignment.centerLeft,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 6),
        SelectableText(
          block == null
              ? '없음'
              : const JsonEncoder.withIndent('  ').convert(block.toJson()),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
      ],
    ),
  );

  Widget _comparison() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (_loading)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 28),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (_selected.deleted)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: Text('삭제된 판본은 본문 비교와 복원을 지원하지 않습니다.'),
        )
      else if (_preview != null)
        LayoutBuilder(
          builder: (context, constraints) {
            final past = _documentPanel('과거 판본', _preview!);
            final current = _documentPanel(
              '현재 저장본',
              widget.snapshot.currentDocument,
            );
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [past, const SizedBox(height: 12), current],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: past),
                const SizedBox(width: 12),
                Expanded(child: current),
              ],
            );
          },
        ),
      if (_diff != null) _changes(_diff!),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_restoring,
    child: Dialog(
      backgroundColor: _paper,
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1080, maxHeight: 860),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '페이지 저장 이력',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '닫기',
                    onPressed: _restoring ? null : () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth < 760) {
                      return SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 200),
                              child: SingleChildScrollView(child: _revisions()),
                            ),
                            const Divider(height: 24),
                            _comparison(),
                          ],
                        ),
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: 216,
                          child: SingleChildScrollView(child: _revisions()),
                        ),
                        const VerticalDivider(width: 32),
                        Expanded(
                          child: SingleChildScrollView(child: _comparison()),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('page-history-restore'),
                style: FilledButton.styleFrom(backgroundColor: _teal),
                onPressed:
                    _restoring ||
                        _loading ||
                        _preview == null ||
                        _selected.deleted ||
                        _selectedIsCurrent ||
                        !widget.isCurrent()
                    ? null
                    : () => unawaited(_restore()),
                icon: _restoring
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.restore, size: 18),
                label: Text(_restoring ? '복원 중…' : '이 판본으로 복원'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

String _position(String? parentId, int? index) =>
    '${parentId == null ? '페이지' : '블록 ${_short(parentId)}'}'
    ' · ${(index ?? 0) + 1}번째';

String _kindLabel(BlockPageChangeKind kind) => switch (kind) {
  BlockPageChangeKind.added => '추가',
  BlockPageChangeKind.deleted => '삭제',
  BlockPageChangeKind.moved => '이동',
  BlockPageChangeKind.content => '본문',
  BlockPageChangeKind.type => '종류',
  BlockPageChangeKind.checked => '체크 상태',
  BlockPageChangeKind.collapsed => '접기 상태',
  BlockPageChangeKind.link => '문서 연결',
  BlockPageChangeKind.formatting => '글자 서식',
  BlockPageChangeKind.unknown => '추가 속성',
};
