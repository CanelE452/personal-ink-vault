import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';

class WorkspaceController extends ChangeNotifier {
  NoteRepository repository;
  WorkspaceStore get store => WorkspaceStore(repository);
  List<VaultNote> notes = [];
  NoteSession? activeSession;
  var markdown = '';
  var markdownDirty = false;
  var inkDirty = false;
  var remoteConflict = false;
  String? error;
  var editorGeneration = 0;
  var query = '';
  var showDeleted = false;
  StreamSubscription<void>? _changes;
  Future<void> _refreshTail = Future.value();
  var _disposed = false;
  var _markdownGeneration = 0;
  var _activityGeneration = 0;
  var inkBusy = false;
  NoteSession? _pendingImportSession;
  Timer? _markdownTimer;
  Future<void> _operationTail = Future.value();
  var _operations = 0;

  Future<T> _serialize<T>(Future<T> Function() operation) {
    _operations++;
    _activityGeneration++;
    final next = _operationTail.then((_) => operation());
    _operationTail = next
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _operations--);
    return next;
  }

  bool _current(NoteRepository repo, NoteSession? session) =>
      !_disposed &&
      identical(repository, repo) &&
      identical(activeSession, session);
  new(this.repository) {
    _listen();
  }
  bool get dirty => markdownDirty || inkDirty || inkBusy;

  static Future<WorkspaceController> openDefault() async {
    final support = await getApplicationSupportDirectory();
    final selection = File('${support.path}/vault-selection.json');
    var root = '${support.path}/vaults/offline';
    if (selection.existsSync()) {
      root =
          (jsonDecode(await selection.readAsString())
                  as Map<String, dynamic>)['root']
              as String;
    }
    final controller = WorkspaceController(
      await NoteRepository.open(Directory(root)),
    );
    await controller.refresh();
    return controller;
  }

  void _listen() {
    _changes = repository.changes.listen((_) {
      unawaited(refresh());
    });
  }

  Future<void> refresh() {
    final next = _refreshTail.then((_) => _refresh());
    _refreshTail = next.catchError((Object e) {
      error = '$e';
      if (!_disposed) notifyListeners();
    });
    return next;
  }

  Future<void> _refresh() async {
    if (_disposed) return;
    final repo = repository, session = activeSession;
    final generation = _activityGeneration;
    try {
      final source = WorkspaceStore(repo);
      final listed = showDeleted
          ? await source.list(includeDeleted: true)
          : await source.search(query);
      if (!_current(repo, session)) return;
      notes = listed;
      if (session != null) {
        final ink = await repo.heads(session.note.inkEntityId);
        final md = await repo.heads(session.note.markdownEntityId);
        final meta = await repo.heads(session.note.id);
        final updatedNote = (await source.list(includeDeleted: true))
            .where((n) => n.id == session.note.id)
            .firstOrNull;
        final inkIds = ink.map((r) => r.revisionId).toList();
        final mdIds = md.map((r) => r.revisionId).toList();
        final inkChanged = !setEquals(
          inkIds.toSet(),
          session.inkParents.toSet(),
        );
        final mdChanged = !setEquals(
          mdIds.toSet(),
          session.markdownParents.toSet(),
        );
        final conflict =
            meta.length > 1 ||
            (updatedNote?.deletionConflict ?? false) ||
            ink.length > 1 ||
            md.length > 1;
        String? incoming;
        if (!dirty && _operations == 0 && !conflict && mdChanged) {
          incoming = await session.readMarkdown(parents: mdIds);
        }
        if (!_current(repo, session)) return;
        session.inkHeads = ink;
        session.markdownHeads = md;
        final protected =
            dirty || _operations > 0 || generation != _activityGeneration;
        remoteConflict =
            conflict ||
            (protected &&
                (inkChanged ||
                    mdChanged ||
                    (updatedNote?.revision.deleted ?? false)));
        if (!protected && !remoteConflict) {
          if (updatedNote != null) session.note = updatedNote;
          if (updatedNote?.revision.deleted ?? false) {
            activeSession = null;
            editorGeneration++;
          } else {
            if (inkChanged) {
              session.inkParents = inkIds;
              editorGeneration++;
            }
            if (mdChanged && incoming != null) {
              session.markdownParents = mdIds;
              markdown = incoming;
            }
          }
        }
      } else {
        remoteConflict = false;
      }
      if (repo.integrityIssues.isNotEmpty || repo.pendingRevisionCount != 0) {
        error = '일부 자료가 누락되거나 손상되었거나 수신 중입니다. 이전 완전 버전만 표시합니다.';
      }
    } catch (e) {
      if (_current(repo, session)) error = '저장소를 읽을 수 없습니다: $e';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> replaceRepository(NoteRepository next) async {
    if (dirty) throw StateError('열린 노트를 저장한 뒤 저장소를 전환하세요.');
    final previous = repository;
    await _changes?.cancel();
    activeSession = null;
    repository = next;
    _listen();
    editorGeneration++;
    final support = await getApplicationSupportDirectory();
    await support.create(recursive: true);
    await File('${support.path}/vault-selection.json')
        .writeAsString(jsonEncode({'root': next.root.path}), flush: true);
    await previous.close();
    await refresh();
  }

  Future<void> reloadFromDisk() => _serialize(() async {
    final previous = repository;
    await _changes?.cancel();
    await _refreshTail;
    await previous.close();
    final next = await NoteRepository.open(previous.root);
    repository = next;
    activeSession?.repository = next;
    _listen();
  }).then((_) => refresh());

  Future<void> openNote(VaultNote note) async {
    if (dirty) throw StateError('먼저 현재 노트를 저장하세요.');
    activeSession = await store.open(note);
    markdown = await activeSession!.readMarkdown();
    editorGeneration++;
    await refresh();
  }

  Future<VaultNote> createNote(
    String title, {
    bool importingPdf = false,
  }) async {
    if (dirty) throw StateError('먼저 현재 노트를 저장하세요.');
    final note = await store.create(title);
    final session = await store.open(note);
    final core = EditorCoreInfo(filePath: '/.working/${note.id}/new/main')
      ..pages.add(EditorPage());
    try {
      await session.saveInk(await SaberInkAdapter.capture(core, 0));
    } finally {
      core.dispose();
    }
    await openNote(note);
    if (importingPdf) {
      _pendingImportSession = activeSession;
      inkBusy = true;
      inkDirty = true;
      notifyListeners();
    }
    return note;
  }

  Future<void> cancelPendingImport({required NoteSession session}) =>
      _serialize(() async {
        if (!identical(session, activeSession) ||
            !identical(session, _pendingImportSession)) {
          throw StateError('취소할 PDF 가져오기 작업이 없습니다.');
        }
        _pendingImportSession = null;
        activeSession =
            NoteSession(
                session.repository,
                session.note,
                session.inkHeads,
                session.markdownHeads,
              )
              ..inkParents = List.of(session.inkParents)
              ..markdownParents = List.of(session.markdownParents);
        inkDirty = false;
        inkBusy = false;
        editorGeneration++;
        if (!_disposed) notifyListeners();
      }).then((_) => refresh());

  void editMarkdown(String value) {
    markdown = value;
    markdownDirty = true;
    _markdownGeneration++;
    _activityGeneration++;
    _markdownTimer?.cancel();
    _markdownTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(
        saveMarkdown().catchError((Object e) {
          error = '기기 저장 실패: $e. 저장 버튼으로 다시 시도하세요.';
          if (!_disposed) notifyListeners();
        }),
      );
    });
    notifyListeners();
  }

  void setInkBusy(bool value, {NoteSession? session}) {
    if (session != null && !identical(session, activeSession)) return;
    if (value) _activityGeneration++;
    inkBusy = value;
    if (!value) _pendingImportSession = null;
    if (!_disposed) notifyListeners();
    if (!value && !_disposed) unawaited(refresh());
  }

  void setInkDirty(bool value, {NoteSession? session}) {
    if (session != null && !identical(session, activeSession)) return;
    if (value) _activityGeneration++;
    inkDirty = value;
    if (!_disposed) notifyListeners();
    if (!value && !_disposed) unawaited(refresh());
  }

  Future<void> saveMarkdown() {
    _markdownTimer?.cancel();
    final session = activeSession;
    return _serialize(() async {
      if (session == null || !identical(session, activeSession)) return;
      while (markdownDirty) {
        final text = markdown, generation = _markdownGeneration;
        await session.saveMarkdown(text);
        if (!identical(session, activeSession)) return;
        if (generation == _markdownGeneration) markdownDirty = false;
      }
      error = null;
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> saveInk(
    EditorCoreInfo core,
    int pageIndex, {
    NoteSession? session,
  }) {
    final owner = session ?? activeSession;
    return _serialize(() async {
      if (owner == null || !identical(owner, activeSession))
        throw StateError('이 필기 편집 세션은 이미 닫혔습니다.');
      await owner.saveInk(await SaberInkAdapter.capture(core, pageIndex));
    });
  }

  Future<void> flush() async {
    await saveMarkdown();
    await _operationTail;
    if (dirty) throw StateError('필기 또는 가져오기 작업을 마친 뒤 저장을 다시 시도하세요.');
  }

  Future<EditorCoreInfo> loadInk({NoteSession? session}) async {
    final owner = session ?? activeSession!;
    final repo = owner.repository;
    if (owner.inkParents.isEmpty)
      throw const FormatException('완전한 필기 snapshot이 없습니다.');
    final revision = (await repo.revisions()).singleWhere(
      (r) => r.revisionId == owner.inkParents.first,
    );
    return SaberInkAdapter.load(repo, revision);
  }

  Future<void> chooseRevision(RevisionRecord chosen) async {
    if (dirty) throw StateError('작업본을 먼저 저장하세요. 충돌 head는 보존됩니다.');
    await activeSession!.resolve(chosen);
    if (chosen.kind == EntityKind.markdown)
      markdown = await activeSession!.readMarkdown();
    if (chosen.kind == EntityKind.metadata && chosen.deleted)
      activeSession = null;
    editorGeneration++;
    await refresh();
  }

  Future<void> viewRevision(RevisionRecord chosen) async {
    if (dirty) throw StateError('먼저 작업본을 저장하세요.');
    if (chosen.kind == EntityKind.markdown) {
      activeSession!.markdownParents = [chosen.revisionId];
      markdown = await activeSession!.readMarkdown();
    } else if (chosen.kind == EntityKind.ink) {
      activeSession!.inkParents = [chosen.revisionId];
      editorGeneration++;
    }
    await refresh();
  }

  Future<void> mergeMarkdown() async {
    await activeSession!.mergeMarkdown(markdown);
    markdownDirty = false;
    await refresh();
  }

  @override
  void dispose() {
    _markdownTimer?.cancel();
    final pendingSave = saveMarkdown();
    _disposed = true;
    unawaited(_changes?.cancel());
    unawaited(
      pendingSave
          .catchError((Object e) {
            error = '$e';
          })
          .then((_) => _operationTail)
          .then((_) => repository.close()),
    );
    super.dispose();
  }
}
