import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:saber/data/vault/block_page_linked_database.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/database_query_native.dart';
import 'package:saber/data/vault/linked_database_session.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/database_editor.dart';

class LinkedDatabaseAccess {
  const new({
    required this.owner,
    required this.open,
    required this.save,
    required this.readMedia,
    required this.isCurrent,
    this.loadDatabases,
    this.queryRuntime,
    this.actionRuntime,
  });

  final Object owner;
  final Future<LinkedDatabaseSession> Function(String noteId) open;
  final Future<void> Function(
    LinkedDatabaseSession session,
    WorkspaceDatabase database,
    Map<String, Uint8List> files,
  )
  save;
  final Future<Uint8List> Function(
    LinkedDatabaseSession session,
    String rowId,
    BlockPageMedia media,
  )
  readMedia;
  final bool Function() isCurrent;
  final Future<Map<String, WorkspaceDatabase>> Function()? loadDatabases;
  final DatabaseQueryRuntime? queryRuntime;
  final DatabaseActionRuntime? actionRuntime;
}

class LinkedDatabaseBlock extends StatefulWidget {
  const new({
    super.key,
    required this.reference,
    required this.access,
    required this.onViewChanged,
    required this.onDirtyChanged,
    required this.onBusyChanged,
    required this.onSaved,
    this.notes = const [],
    this.onOpenNote,
  });

  final BlockLinkedDatabase reference;
  final LinkedDatabaseAccess access;
  final ValueChanged<DatabaseView> onViewChanged;
  final ValueChanged<bool> onDirtyChanged;
  final ValueChanged<bool> onBusyChanged;
  final VoidCallback onSaved;
  final List<BlockPageNote> notes;
  final ValueChanged<String>? onOpenNote;

  @override
  State<LinkedDatabaseBlock> createState() => LinkedDatabaseBlockState();
}

class LinkedDatabaseBlockState extends State<LinkedDatabaseBlock>
    with AutomaticKeepAliveClientMixin<LinkedDatabaseBlock> {
  final _editor = GlobalKey<DatabaseEditorState>();
  late Future<LinkedDatabaseSession> _future;
  LinkedDatabaseSession? _session;
  Map<String, WorkspaceDatabase> _databases = const {};
  String? _relatedWarning;
  var _generation = 0;
  var _loading = true;
  var _dirty = false;
  var _editorBusy = false;
  var _reportedDirty = false;
  var _reportedBusy = false;

  bool get hasPendingChanges => _dirty || _editorBusy;
  @override
  bool get wantKeepAlive => _loading || hasPendingChanges;

  @override
  void initState() {
    super.initState();
    _future = _load();
    _report();
  }

  @override
  void didUpdateWidget(LinkedDatabaseBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reference.noteId != widget.reference.noteId ||
        !identical(oldWidget.access.owner, widget.access.owner)) {
      _session?.close();
      _session = null;
      _dirty = _editorBusy = false;
      _generation++;
      _loading = true;
      _future = _load();
      _report();
    }
  }

  bool _current(LinkedDatabaseAccess access, int generation) =>
      mounted &&
      generation == _generation &&
      identical(access.owner, widget.access.owner) &&
      access.isCurrent();

  Future<LinkedDatabaseSession> _load() async {
    final access = widget.access;
    final generation = _generation;
    LinkedDatabaseSession? opened;
    try {
      opened = await access.open(widget.reference.noteId);
      var related = const <String, WorkspaceDatabase>{};
      String? relatedWarning;
      try {
        related = await access.loadDatabases?.call() ?? related;
      } catch (_) {
        relatedWarning = '관계 계산에 필요한 일부 데이터베이스를 읽지 못했습니다.';
      }
      if (!_current(access, generation)) {
        throw StateError('연결된 데이터베이스를 여는 페이지가 바뀌었습니다.');
      }
      _session = opened;
      _databases = Map.unmodifiable(related);
      _relatedWarning = relatedWarning;
      return opened;
    } catch (_) {
      opened?.close();
      rethrow;
    } finally {
      if (mounted && generation == _generation) {
        _loading = false;
        _report();
      }
    }
  }

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
    final busy = _loading || _editorBusy;
    if (_reportedBusy != busy) {
      _reportedBusy = busy;
      widget.onBusyChanged(busy);
    }
  }

  Future<void> save() async {
    try {
      await _future;
    } catch (_) {
      if (!_dirty) return;
      rethrow;
    }
    if (!mounted || !widget.access.isCurrent()) {
      throw StateError('연결된 데이터베이스의 페이지가 이미 닫혔습니다.');
    }
    await _editor.currentState?.save();
  }

  void reloadIfClean() {
    if (!mounted || _loading || hasPendingChanges) return;
    _session?.close();
    _session = null;
    setState(() {
      _generation++;
      _loading = true;
      _future = _load();
    });
    _report();
  }

  Future<void> _discardAndReload() async {
    final editor = _editor.currentState;
    final session = _session;
    final access = widget.access;
    final generation = _generation;
    if (_loading ||
        editor == null ||
        session == null ||
        !editor.canDiscardDraft)
      return;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('원본 DB 다시 읽기'),
        content: const Text(
          '저장하지 않은 항목·첨부 변경을 버리고 원본을 다시 읽습니다. '
          '이 페이지의 보기 설정과 이미 저장된 원본 DB 내용은 유지됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('초안 버리기'),
          ),
        ],
      ),
    );
    if (discard != true ||
        !_current(access, generation) ||
        !identical(_session, session) ||
        !editor.canDiscardDraft)
      return;
    editor.discardDraft();
    session.close();
    setState(() {
      _session = null;
      _dirty = _editorBusy = false;
      _generation++;
      _loading = true;
      _future = _load();
    });
    _report();
  }

  Future<void> _saveSource(
    LinkedDatabaseSession session,
    WorkspaceDatabase database,
    Map<String, Uint8List> files,
  ) async {
    final access = widget.access;
    final generation = _generation;
    if (!_current(access, generation) || !identical(_session, session)) {
      throw StateError('연결된 데이터베이스 편집 세션이 바뀌었습니다.');
    }
    await access.save(session, database, files);
    if (!_current(access, generation) || !identical(_session, session)) {
      throw StateError('연결된 데이터베이스를 저장하는 동안 페이지가 바뀌었습니다.');
    }
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<LinkedDatabaseSession>(
        future: _future,
        builder: (context, snapshot) {
          final session = snapshot.connectionState == ConnectionState.done
              ? snapshot.data
              : null;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: Row(
                  children: [
                    const Icon(Icons.table_view_outlined, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        session?.target.note.title ?? '연결된 데이터베이스',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: '연결된 데이터베이스 새로 고침',
                      onPressed: _loading
                          ? null
                          : hasPendingChanges
                          ? (_editor.currentState?.canDiscardDraft == true
                                ? () => unawaited(_discardAndReload())
                                : null)
                          : reloadIfClean,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Text(
                  '항목은 원본 DB에, 보기 설정은 이 페이지에 저장됩니다.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (snapshot.hasError)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('연결된 데이터베이스를 열 수 없습니다: ${snapshot.error}'),
                )
              else if (session == null)
                const SizedBox(
                  height: 100,
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                if (_relatedWarning != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_relatedWarning!),
                  ),
                SizedBox(
                  height: 520,
                  child: DatabaseEditor(
                    key: _editor,
                    initialDatabase: session.database,
                    viewOverride: widget.reference.view,
                    onViewOverrideChanged: widget.onViewChanged,
                    embedded: true,
                    onDiscardChanges: () => unawaited(_discardAndReload()),
                    currentRevision: () => session.revisionId,
                    queryRuntime: widget.access.queryRuntime,
                    actionRuntime: widget.access.actionRuntime,
                    databases: _databases,
                    notes: widget.notes,
                    onOpenNote: widget.onOpenNote,
                    onSave: (database) =>
                        _saveSource(session, database, const {}),
                    onSaveWithMedia: (database, files) =>
                        _saveSource(session, database, files),
                    onReadRowMedia: (rowId, media) =>
                        widget.access.readMedia(session, rowId, media),
                    onDirtyChanged: (dirty) {
                      if (!identical(_session, session)) return;
                      _dirty = dirty;
                      _report();
                    },
                    onBusyChanged: (busy) {
                      if (!identical(_session, session)) return;
                      _editorBusy = busy;
                      _report();
                    },
                    onBack: () {},
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _generation++;
    _session?.close();
    final dirty = widget.onDirtyChanged;
    final busy = widget.onBusyChanged;
    if (_reportedDirty) scheduleMicrotask(() => dirty(false));
    if (_reportedBusy) scheduleMicrotask(() => busy(false));
    super.dispose();
  }
}
