import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_synced_reference.dart';
import 'package:saber/data/vault/synced_block_store.dart';
import 'package:saber/pages/workspace/block_inline_controller.dart';

class SyncedBlockAccess {
  const new({
    required this.owner,
    required this.ownerNoteId,
    required this.isCurrent,
    required this.changes,
    required this.listPages,
    required this.listSources,
    required this.open,
    required this.save,
    this.detach,
  });

  final Object owner;
  final String ownerNoteId;
  final bool Function() isCurrent;
  final Stream<void> changes;
  final Future<List<({String id, String title})>> Function() listPages;
  final Future<List<SyncedBlockTarget>> Function(String noteId) listSources;
  final Future<SyncedBlockTarget> Function(BlockSyncedReference reference) open;
  final Future<void> Function(
    SyncedBlockTarget target,
    String ownerBlockId,
    String text,
  )
  save;
  final Future<BlockPageDocument> Function(
    SyncedBlockTarget target,
    String ownerBlockId,
    void Function() requireWrite,
  )?
  detach;
}

class SyncedBlockView extends StatefulWidget {
  const new({
    super.key,
    required this.blockId,
    required this.reference,
    required this.access,
    required this.onDirtyChanged,
    required this.onSaveRequested,
    this.onOpenSource,
    this.onDetachRequested,
  });

  final String blockId;
  final BlockSyncedReference reference;
  final SyncedBlockAccess access;
  final ValueChanged<bool> onDirtyChanged;
  final VoidCallback onSaveRequested;
  final VoidCallback? onOpenSource;
  final Future<void> Function(
    SyncedBlockTarget target,
    void Function() requireWrite,
  )?
  onDetachRequested;

  @override
  State<SyncedBlockView> createState() => SyncedBlockViewState();
}

class SyncedBlockViewState extends State<SyncedBlockView>
    with AutomaticKeepAliveClientMixin<SyncedBlockView> {
  final _text = BlockInlineController(text: '');
  StreamSubscription<void>? _changes;
  SyncedBlockTarget? _target;
  String? _savedText;
  Object? _error;
  Object? _detachError;
  var _generation = 0;
  var _loading = false;
  var _saving = false;
  var _editing = false;
  var _refreshPending = false;
  var _reportedDirty = false;

  bool get _dirty => _savedText != null && _text.text != _savedText;
  @override
  bool get wantKeepAlive => _editing || _dirty || _saving;

  @override
  void initState() {
    super.initState();
    _listen();
    _requestReload();
  }

  @override
  void didUpdateWidget(SyncedBlockView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.access.owner, widget.access.owner) &&
        oldWidget.blockId == widget.blockId &&
        oldWidget.reference.sourceNoteId == widget.reference.sourceNoteId &&
        oldWidget.reference.sourceBlockId == widget.reference.sourceBlockId) {
      return;
    }
    _generation++;
    _loading = _saving = _editing = false;
    _target = null;
    _savedText = null;
    _error = null;
    _detachError = null;
    _listen();
    _report();
    _requestReload();
  }

  void _listen() {
    unawaited(_changes?.cancel());
    _changes = widget.access.changes.listen((_) => _requestReload());
  }

  bool _current(int generation) =>
      mounted && generation == _generation && widget.access.isCurrent();

  void _report() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _report());
      return;
    }
    updateKeepAlive();
    if (_reportedDirty != _dirty) {
      _reportedDirty = _dirty;
      widget.onDirtyChanged(_dirty);
    }
  }

  void _requestReload() {
    _refreshPending = true;
    if (!_loading && !_saving && !_dirty && _current(_generation)) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final generation = _generation;
    _refreshPending = false;
    setState(() => _loading = true);
    try {
      final target = await widget.access.open(widget.reference);
      if (!_current(generation) || _dirty) return;
      setState(() {
        _target = target;
        _savedText = target.block.text;
        _error = null;
        _text.sync(target.block.text, target.block.inlineText, enabled: true);
      });
    } catch (error) {
      if (!_current(generation) || _dirty) return;
      setState(() {
        _target = null;
        _savedText = null;
        _error = error;
        _editing = false;
      });
    } finally {
      if (_current(generation)) {
        setState(() => _loading = false);
        _report();
        if (_refreshPending) _requestReload();
      }
    }
  }

  Future<void> save() async {
    if (!_dirty) return;
    final target = _target;
    final generation = _generation;
    if (target == null || _saving || !_current(generation)) {
      throw StateError('동기화 블록 편집 세션이 바뀌었습니다.');
    }
    final submitted = _text.text;
    setState(() => _saving = true);
    _report();
    try {
      await widget.access.save(target, widget.blockId, submitted);
      if (!_current(generation)) {
        throw StateError('저장하는 동안 연결된 페이지가 바뀌었습니다.');
      }
      setState(() {
        _savedText = submitted;
        _editing = false;
        _error = null;
      });
      _refreshPending = true;
    } catch (error) {
      if (_current(generation)) setState(() => _error = error);
      rethrow;
    } finally {
      if (_current(generation)) {
        setState(() => _saving = false);
        _report();
        if (_refreshPending) _requestReload();
      }
    }
  }

  Future<void> _discardDraft() async {
    final generation = _generation;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('동기화 블록 다시 읽기'),
        content: const Text('이 블록의 저장하지 않은 변경을 버리고 원본을 다시 읽습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('초안 버리기'),
          ),
        ],
      ),
    );
    if (discard != true || !_current(generation) || _saving) return;
    setState(() {
      _savedText = null;
      _editing = false;
      _error = null;
    });
    _report();
    _requestReload();
  }

  Future<void> _confirmDetach() async {
    final target = _target;
    final generation = _generation;
    if (target == null || !_canDetach || widget.onDetachRequested == null)
      return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('동기화 블록 연결 해제'),
        content: const Text('이 블록을 독립 복사본으로 저장합니다. 원본과 다른 동기화 블록은 계속 연결됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: ValueKey('synced-block-detach-confirm-${widget.blockId}'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('연결 해제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !_current(generation)) return;
    final detach = widget.onDetachRequested;
    if (detach == null || !_canDetach || !identical(_target, target)) {
      setState(() => _detachError = '페이지를 저장하고 최신 원본을 확인하세요.');
      return;
    }
    setState(() {
      _saving = true;
      _detachError = null;
    });
    _report();
    try {
      await detach(target, () {
        if (!_current(generation) ||
            !identical(_target, target) ||
            !_saving ||
            _dirty ||
            _editing) {
          throw StateError('연결을 해제하는 동안 블록이 바뀌었습니다.');
        }
      });
    } catch (error) {
      if (_current(generation)) setState(() => _detachError = error);
    } finally {
      if (_current(generation)) {
        setState(() => _saving = false);
        _report();
        if (_refreshPending) _requestReload();
      }
    }
  }

  bool get _canDetach =>
      !_loading && !_saving && !_editing && !_dirty && _target != null;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final target = _target;
    final style = Theme.of(context).textTheme.bodyLarge;
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              target == null ? '동기화 블록' : '동기화 블록 · ${target.sourceTitle}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            if (target != null)
              if (_editing)
                TextField(
                  key: ValueKey('synced-block-input-${widget.blockId}'),
                  controller: _text,
                  enabled: !_loading && !_saving,
                  maxLines: null,
                  decoration: const InputDecoration(labelText: '원본 블록 내용'),
                  onChanged: (_) {
                    setState(() {});
                    _report();
                    if (!_dirty && _refreshPending) _requestReload();
                  },
                )
              else
                SelectableText.rich(
                  _text.buildTextSpan(
                    context: context,
                    style: style,
                    withComposing: false,
                  ),
                ),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                '원본 블록을 처리할 수 없습니다. $_error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_detachError != null)
              Text(
                '연결을 해제할 수 없습니다. $_detachError',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Wrap(
              spacing: 4,
              children: [
                if (target != null && !_editing)
                  TextButton(
                    onPressed: _loading || _saving
                        ? null
                        : () {
                            setState(() => _editing = true);
                            _report();
                          },
                    child: const Text('원본 블록 편집'),
                  ),
                if (_dirty)
                  TextButton(
                    onPressed: _saving ? null : widget.onSaveRequested,
                    child: const Text('원본 블록 저장'),
                  ),
                if (_dirty || _editing)
                  TextButton(
                    onPressed: _saving
                        ? null
                        : _dirty
                        ? () => unawaited(_discardDraft())
                        : () {
                            setState(() => _editing = false);
                            _report();
                          },
                    child: Text(_dirty ? '초안 버리기…' : '편집 닫기'),
                  ),
                if (_error != null && !_dirty)
                  TextButton(
                    onPressed: _loading ? null : _requestReload,
                    child: const Text('다시 읽기'),
                  ),
                if (widget.access.detach != null)
                  TextButton(
                    key: ValueKey('synced-block-detach-${widget.blockId}'),
                    onPressed: _canDetach && widget.onDetachRequested != null
                        ? () => unawaited(_confirmDetach())
                        : null,
                    child: const Text('연결 해제…'),
                  ),
                if (widget.onOpenSource != null)
                  TextButton(
                    onPressed: _saving ? null : widget.onOpenSource,
                    child: const Text('원본 페이지 열기'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_changes?.cancel());
    _text.dispose();
    super.dispose();
  }
}
