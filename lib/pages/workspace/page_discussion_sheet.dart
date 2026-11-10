import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/discussion_anchor.dart';
import 'package:saber/data/vault/discussion_store.dart';

Future<void> showPageDiscussionSheet({
  required BuildContext context,
  required DiscussionStore store,
  required String pageId,
  required Future<RevisionRecord> Function() pageForWrite,
  DiscussionAnchor? initialAnchor,
}) async {
  final anchor = initialAnchor ?? DiscussionAnchor.page(pageId: pageId);
  if (anchor.pageId != pageId) {
    throw ArgumentError('The discussion anchor belongs to another page');
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: FractionallySizedBox(
        heightFactor: .88,
        child: _PageDiscussionSheet(
          store: store,
          anchor: anchor,
          pageForWrite: pageForWrite,
        ),
      ),
    ),
  );
}

typedef _ReplyTarget = ({String threadId, String messageId});
typedef _StatusChoice = ({String threadId, bool resolved});
typedef _StatusWrite = ({List<String> heads, String eventId});

final class _Draft {
  final controller = TextEditingController();
  String? _submittedText;
  String? _eventId;

  String eventIdFor(String text) {
    if (_submittedText != text) {
      _submittedText = text;
      _eventId = newId();
    }
    return _eventId!;
  }

  void clear() {
    _submittedText = null;
    _eventId = null;
    controller.clear();
  }
}

class _PageDiscussionSheet extends StatefulWidget {
  const new({
    required this.store,
    required this.anchor,
    required this.pageForWrite,
  });

  final DiscussionStore store;
  final DiscussionAnchor anchor;
  final Future<RevisionRecord> Function() pageForWrite;

  @override
  State<_PageDiscussionSheet> createState() => _PageDiscussionSheetState();
}

class _PageDiscussionSheetState extends State<_PageDiscussionSheet> {
  final _scroll = ScrollController();
  final _newDraft = _Draft();
  final _replyDrafts = <_ReplyTarget, _Draft>{};
  final _statusWrites = <_StatusChoice, _StatusWrite>{};
  late final StreamSubscription<void> _changes;
  List<DiscussionThread>? _threads;
  _ReplyTarget? _reply;
  var _loading = false;
  var _reloadRequested = false;
  var _saving = false;
  var _dismissed = false;
  var _loadError = false;
  var _writeError = false;

  bool get _active => mounted && !_dismissed;
  bool get _canEdit => _threads != null && !_loadError && !_saving;
  bool get _canWrite => _canEdit && !_loading;
  String get _pageId => widget.anchor.pageId;
  _Draft get _draft => switch (_reply) {
    final target? => _replyDrafts.putIfAbsent(target, _Draft.new),
    null => _newDraft,
  };

  @override
  void initState() {
    super.initState();
    _changes = widget.store.repository.changes.listen((_) {
      unawaited(_reload());
    });
    unawaited(_reload());
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    _scroll.dispose();
    _newDraft.controller.dispose();
    for (final draft in _replyDrafts.values) {
      draft.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _reload() async {
    if (!_active) return;
    _reloadRequested = true;
    if (_loading || _saving) return;
    setState(() => _loading = true);
    try {
      while (_active && _reloadRequested) {
        _reloadRequested = false;
        try {
          final threads = await widget.store.listThreads(_pageId);
          if (!_active || _reloadRequested) continue;
          setState(() {
            _threads = threads;
            _loadError = false;
          });
        } catch (_) {
          if (!_active || _reloadRequested) continue;
          setState(() => _loadError = true);
        }
      }
    } finally {
      if (_active) setState(() => _loading = false);
    }
  }

  Future<void> _write(
    Future<String> Function(RevisionRecord) publish,
    VoidCallback onSaved,
  ) async {
    if (!_active || !_canWrite) return;
    setState(() {
      _saving = true;
      _writeError = false;
    });
    try {
      final page = await widget.pageForWrite();
      if (!_active) return;
      if (page.entityId != _pageId ||
          page.vaultId != widget.store.repository.vaultId) {
        throw StateError('The discussion page is no longer current');
      }
      await publish(page);
      if (_active) setState(onSaved);
    } catch (_) {
      if (_active) setState(() => _writeError = true);
    } finally {
      if (_active) {
        setState(() => _saving = false);
        unawaited(_reload());
      }
    }
  }

  DiscussionMessage? _replyMessage(_ReplyTarget target) {
    final thread = (_threads ?? const <DiscussionThread>[])
        .where((thread) => thread.id == target.threadId)
        .firstOrNull;
    if (thread == null) return null;
    return target.messageId == thread.id
        ? thread.root
        : thread.replies
              .where((message) => message.id == target.messageId)
              .firstOrNull;
  }

  void _submit() {
    if (!_canWrite) return;
    final target = _reply;
    if (target != null && _replyMessage(target) == null) return;
    final draft = _draft;
    final body = draft.controller.text;
    if (body.trim().isEmpty) return;
    final eventId = draft.eventIdFor(body);
    unawaited(
      _write(
        (page) => target == null
            ? widget.store.createThread(
                page: page,
                anchor: widget.anchor,
                body: body,
                eventId: eventId,
              )
            : widget.store.reply(
                page: page,
                threadId: target.threadId,
                replyToId: target.messageId,
                body: body,
                eventId: eventId,
              ),
        () {
          draft.clear();
          _reply = null;
        },
      ),
    );
  }

  void _selectReply(DiscussionThread thread, DiscussionMessage message) {
    if (!_canWrite) return;
    setState(() => _reply = (threadId: thread.id, messageId: message.id));
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _setResolved(DiscussionThread thread, bool resolved) {
    if (!_canWrite) return;
    final choice = (threadId: thread.id, resolved: resolved);
    final heads = thread.statusHeadIds;
    final previous = _statusWrites[choice];
    final eventId =
        previous != null &&
            previous.heads.length == heads.length &&
            previous.heads.toSet().containsAll(heads)
        ? previous.eventId
        : newId();
    _statusWrites[choice] = (heads: heads, eventId: eventId);
    unawaited(
      _write(
        (page) => widget.store.setResolved(
          page: page,
          threadId: thread.id,
          resolved: resolved,
          expectedStatusIds: heads,
          eventId: eventId,
        ),
        () => _statusWrites.remove(choice),
      ),
    );
  }

  String _anchorLabel(DiscussionAnchor anchor) => switch (anchor.kind) {
    DiscussionAnchorKind.page => '페이지 전체',
    DiscussionAnchorKind.block => '블록 전체',
    DiscussionAnchorKind.quote => '선택 문구',
  };

  Widget _composer() {
    final reply = _reply;
    final replying = reply != null;
    final target = replying ? _replyMessage(reply) : null;
    final draft = _draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          replying ? '답글 작성' : _anchorLabel(widget.anchor),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (replying)
          Text(
            target?.body ?? '답글 대상을 찾을 수 없습니다.',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          )
        else if (widget.anchor.quoteText case final quote?)
          Text(quote, maxLines: 3, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        TextField(
          key: Key(replying ? 'discussion-reply-body' : 'discussion-new-body'),
          controller: draft.controller,
          enabled: _canEdit,
          minLines: 2,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            labelText: replying ? '답글 내용' : '댓글 내용',
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            alignment: WrapAlignment.end,
            children: [
              if (replying)
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() => _reply = null),
                  child: const Text('새 댓글로 돌아가기'),
                ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: draft.controller,
                builder: (_, value, _) => FilledButton(
                  key: Key(
                    replying ? 'discussion-reply-submit' : 'discussion-create',
                  ),
                  onPressed:
                      _canWrite &&
                          (!replying || target != null) &&
                          value.text.trim().isNotEmpty
                      ? _submit
                      : null,
                  child: Text(replying ? '답글 등록' : '댓글 등록'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _message(DiscussionThread thread, DiscussionMessage message) =>
      Padding(
        padding: EdgeInsetsDirectional.only(
          start: message.replyToId == null ? 0 : 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '기기 ${message.authorDeviceId.substring(0, 8)}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 2),
            Text(message.body),
            TextButton(
              key: ValueKey('discussion-reply-to-${message.id}'),
              onPressed: _canWrite ? () => _selectReply(thread, message) : null,
              child: const Text('답글'),
            ),
          ],
        ),
      );

  Widget _thread(DiscussionThread thread) {
    final status = thread.status;
    final label = switch (status) {
      DiscussionThreadStatus.open => '열림',
      DiscussionThreadStatus.resolved => '해결됨',
      DiscussionThreadStatus.conflict => '상태 충돌',
    };
    final anchorNotice = switch (thread.anchorStatus) {
      DiscussionAnchorStatus.attached => null,
      DiscussionAnchorStatus.missingPage => '원래 페이지를 찾을 수 없습니다.',
      DiscussionAnchorStatus.missingBlock => '원래 블록을 찾을 수 없습니다.',
      DiscussionAnchorStatus.changedQuote => '원래 선택 문구가 바뀌었습니다.',
    };
    return Card(
      key: ValueKey('discussion-thread-${thread.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Chip(label: Text(label)),
                Text(_anchorLabel(thread.anchor)),
              ],
            ),
            if (thread.anchor.quoteText case final quote?)
              Text(quote, maxLines: 3, overflow: TextOverflow.ellipsis),
            if (anchorNotice != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(anchorNotice),
              ),
            _message(thread, thread.root),
            for (final reply in thread.replies) _message(thread, reply),
            if (status == DiscussionThreadStatus.conflict)
              const Text('서로 다른 상태가 저장되어 있습니다. 유지할 상태를 선택하세요.'),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                if (status != DiscussionThreadStatus.resolved)
                  TextButton(
                    key: ValueKey('discussion-resolve-${thread.id}'),
                    onPressed: _canWrite
                        ? () => _setResolved(thread, true)
                        : null,
                    child: Text(
                      status == DiscussionThreadStatus.conflict
                          ? '해결 상태로 정리'
                          : '해결',
                    ),
                  ),
                if (status != DiscussionThreadStatus.open)
                  TextButton(
                    key: ValueKey('discussion-reopen-${thread.id}'),
                    onPressed: _canWrite
                        ? () => _setResolved(thread, false)
                        : null,
                    child: Text(
                      status == DiscussionThreadStatus.conflict
                          ? '열린 상태로 정리'
                          : '다시 열기',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final threads = _threads ?? const <DiscussionThread>[];
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _dismissed = true;
      },
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '댓글',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: '댓글 닫기',
                    onPressed: () {
                      _dismissed = true;
                      Navigator.of(context).pop();
                    },
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            if (_loading || _saving)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                itemCount: threads.length + 2,
                itemBuilder: (_, index) {
                  if (index == 0) return _composer();
                  if (index > 1) return _thread(threads[index - 2]);
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_writeError)
                          Semantics(
                            liveRegion: true,
                            child: const Text(
                              '저장 결과를 확인하지 못했습니다. 최신 상태를 확인한 뒤 다시 시도하세요.',
                              key: Key('discussion-write-error'),
                            ),
                          ),
                        if (_loadError) ...[
                          const Text('댓글을 불러오지 못했습니다.'),
                          TextButton(
                            onPressed: _loading || _saving
                                ? null
                                : () => unawaited(_reload()),
                            child: const Text('다시 불러오기'),
                          ),
                        ] else if (_threads != null && threads.isEmpty)
                          const Text('아직 댓글이 없습니다.'),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
