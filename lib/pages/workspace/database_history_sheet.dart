import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/database_history.dart';
import 'package:saber/data/vault/database_history_snapshot.dart';

class DatabaseHistorySheet extends StatefulWidget {
  const new({
    super.key,
    required this.snapshot,
    required this.isCurrent,
    required this.onRestore,
  });

  final DatabaseHistorySnapshot snapshot;
  final bool Function() isCurrent;
  final Future<void> Function(RevisionRecord) onRestore;

  @override
  State<DatabaseHistorySheet> createState() => _DatabaseHistorySheetState();
}

class _DatabaseHistorySheetState extends State<DatabaseHistorySheet> {
  late RevisionRecord _selected;
  DatabaseHistoryDiff? _diff;
  String? _error;
  var _generation = 0;
  var _loading = false;
  var _restoring = false;

  bool _isHead(RevisionRecord revision) =>
      revision.revisionId == widget.snapshot.currentRevision.revisionId;

  @override
  void initState() {
    super.initState();
    _selected = widget.snapshot.currentRevision;
  }

  bool _accept(int generation) {
    if (!mounted || generation != _generation) return false;
    if (widget.isCurrent()) return true;
    setState(() {
      _loading = false;
      _restoring = false;
      _diff = null;
      _error = '열린 데이터베이스가 바뀌었습니다. 이력을 닫고 다시 여세요.';
    });
    return false;
  }

  Future<void> _select(RevisionRecord revision) async {
    if (_restoring || !_accept(_generation)) return;
    final generation = ++_generation;
    setState(() {
      _selected = revision;
      _diff = null;
      _error = null;
      _loading = !_isHead(revision) && !revision.deleted;
    });
    if (!_loading) return;
    try {
      final diff = await widget.snapshot.compare(revision);
      if (!_accept(generation)) return;
      setState(() {
        _diff = diff;
        _loading = false;
      });
    } catch (_) {
      if (!_accept(generation)) return;
      setState(() {
        _loading = false;
        _error = '판본을 비교하지 못했습니다. 다시 선택해 보세요.';
      });
    }
  }

  Future<void> _restore() async {
    if (_restoring || _diff == null || !_accept(_generation)) return;
    final generation = _generation;
    final chosen = _selected;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('판본 복원'),
        content: const Text(
          '선택한 데이터베이스 내용을 새 판본으로 저장합니다. '
          '새 판본은 현재 자동화 규칙과 자동화 실행·폼 제출 기록을 이어받습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('database-history-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('복원'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_accept(generation)) return;
    setState(() {
      _restoring = true;
      _error = null;
    });
    try {
      await widget.onRestore(chosen);
      if (!mounted) return;
      setState(() => _restoring = false);
      if (ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
    } catch (_) {
      if (!_accept(generation)) return;
      setState(() {
        _restoring = false;
        _error = '복원하지 못했습니다. 이력을 닫고 현재 저장본을 다시 확인하세요.';
      });
    }
  }

  Widget _revisions() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Text('저장된 판본', style: TextStyle(fontWeight: FontWeight.w600)),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: widget.snapshot.revisions.length,
          itemBuilder: (context, index) {
            final revision = widget.snapshot.revisions[index];
            return ListTile(
              key: ValueKey('database-history-revision-${revision.revisionId}'),
              enabled: !_restoring && widget.isCurrent(),
              dense: true,
              selected: _selected.revisionId == revision.revisionId,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              title: Tooltip(
                message: revision.revisionId,
                child: Text('판본 ${_short(revision.revisionId)}'),
              ),
              subtitle: Tooltip(
                message: revision.deviceId,
                child: Text(
                  [
                    '기기 ${_short(revision.deviceId)}',
                    if (_isHead(revision)) '현재',
                    if (revision.deleted) '삭제됨',
                  ].join(' · '),
                ),
              ),
              onTap: () => unawaited(_select(revision)),
            );
          },
        ),
      ),
    ],
  );

  Widget _details(DatabaseHistoryDiff diff) {
    final sections = [
      ('항목', diff.rows),
      ('속성', diff.properties),
      ('보기', diff.views),
      ('템플릿', diff.templates),
      ('첨부', diff.attachments),
    ];
    return ListView.builder(
      key: ValueKey('database-history-diff-${_selected.revisionId}'),
      itemCount:
          2 +
          sections.fold(
            0,
            (total, section) => total + 1 + section.$2.items.length,
          ),
      itemBuilder: (context, index) {
        if (index == 0) return const Text('선택한 판본 → 현재 저장본');
        if (index == 1) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '현재 활동',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                if (diff.settingsChanged) const Text('데이터베이스 설정에 차이가 있습니다.'),
                if (diff.executionRecordsChanged)
                  const Text('자동화 실행 또는 폼 제출 기록에 차이가 있습니다.'),
                const Text('복원 판본은 현재 자동화 규칙과 실행·제출 기록을 이어받습니다.'),
              ],
            ),
          );
        }
        var itemIndex = index - 2;
        for (final (label, changes) in sections) {
          if (itemIndex == 0) {
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                changes.items.isEmpty
                    ? '변경 없음'
                    : '추가 ${changes.added} · 삭제 ${changes.removed}'
                          ' · 변경 ${changes.changed} · 이동 ${changes.moved}',
              ),
            );
          }
          if (itemIndex <= changes.items.length) {
            final change = changes.items[itemIndex - 1];
            return ListTile(
              dense: true,
              title: Tooltip(
                message: '${change.label}\n${change.id}',
                child: Text(
                  change.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              subtitle: Text(change.kinds.map(_changeLabel).join(' · ')),
            );
          }
          itemIndex -= 1 + changes.items.length;
        }
        return null;
      },
    );
  }

  Widget _comparison() {
    final diff = _diff;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : diff != null
              ? _details(diff)
              : Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    _selected.deleted
                        ? '삭제된 판본은 비교하거나 복원할 수 없습니다.'
                        : '비교할 이전 판본을 선택하세요.',
                  ),
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_restoring,
    child: Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '데이터베이스 저장 이력',
                      style: Theme.of(context).textTheme.titleLarge,
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
                    if (constraints.maxWidth < 640) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: math.min(190.0, constraints.maxHeight * .4),
                            child: _revisions(),
                          ),
                          const Divider(height: 24),
                          Expanded(child: _comparison()),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 220, child: _revisions()),
                        const VerticalDivider(width: 24),
                        Expanded(child: _comparison()),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('database-history-restore'),
                onPressed: _diff == null || _restoring
                    ? null
                    : () => unawaited(_restore()),
                child: Text(_restoring ? '복원 중…' : '이 판본으로 복원'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

String _short(String id) => id.length > 8 ? id.substring(0, 8) : id;

String _changeLabel(DatabaseHistoryChangeKind kind) => switch (kind) {
  DatabaseHistoryChangeKind.added => '추가',
  DatabaseHistoryChangeKind.removed => '삭제',
  DatabaseHistoryChangeKind.changed => '변경',
  DatabaseHistoryChangeKind.moved => '이동',
};
