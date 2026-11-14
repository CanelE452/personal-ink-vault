import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/pdf_note_original.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_history.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_media_worker.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/database_automation_coordinator.dart';
import 'package:saber/data/vault/database_history_snapshot.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/database_media_worker.dart';
import 'package:saber/data/vault/dataview_result.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/linked_database_session.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/pdf_import_state.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_navigation.dart';
import 'package:saber/data/vault/workspace_store.dart';

typedef _AutomationActivity = (int, int, NoteSession?, String?, String);
typedef ResolvedInkPageLink = ({
  ({String pageId, EditorImage? background}) page,
  int repositoryGeneration,
});
typedef PdfTextSearchAccess = ({
  Future<PdfTextSearchResult?> Function(String, bool Function()) search,
  Future<ResolvedInkPageLink?> Function(PdfTextSearchHit) resolve,
});

class WorkspaceController extends ChangeNotifier {
  NoteRepository repository;
  final InkVaultNative? native;
  final Future<Directory> Function() _directoryProvider;
  KnowledgeIndex? knowledge;
  String? _knowledgeSignature;
  int? _knowledgeRepositoryGeneration;
  bool get knowledgeCurrent =>
      knowledge != null &&
      _knowledgeRepositoryGeneration == repositoryGeneration;
  WorkspaceStore get store => WorkspaceStore(repository, native: native);
  LibraryStore get library => LibraryStore(repository, native: native);
  List<VaultNote> notes = [];
  List<VaultFolder> folders = [];
  String? currentFolderId;
  var navigation = WorkspaceNavigation();
  List<String> get recentDocumentIds => navigation.recentDocumentIds;
  NoteSession? activeSession;
  var markdown = '';
  var markdownDirty = false;
  var inkDirty = false;
  var remoteConflict = false;
  String? error;
  var editorGeneration = 0;
  var _query = '';
  NoteRepository? _bookmarkQueryRepository;
  NoteRepository? _expressionQueryRepository;
  var _literalBookmarkQuery = false;
  var _searchGeneration = 0;
  var _displayedSearchGeneration = 0;
  var _displayedSearchIncludesDeleted = false;
  String? _searchError;
  ({NoteRepository repository, Map<String, KnowledgeBodyMatch> matches})?
  _bodyMatchResults;
  String get query => _query;
  set query(String value) => setSearchQuery(value);
  bool get searchesFromBookmark =>
      identical(_bookmarkQueryRepository, repository);
  bool get searchesWithOperators =>
      identical(_expressionQueryRepository, repository);
  bool get searchesAcrossFolders =>
      searchesFromBookmark ||
      (searchesWithOperators && query.trim().isNotEmpty);
  bool get searchesLiterally => searchesFromBookmark && _literalBookmarkQuery;
  bool get searchPending =>
      _displayedSearchGeneration != _searchGeneration ||
      (searchesWithOperators &&
          query.trim().isNotEmpty &&
          _displayedSearchIncludesDeleted != showDeleted);
  String? get searchError => searchPending ? null : _searchError;
  Map<String, KnowledgeBodyMatch> get searchBodyMatches {
    final results = _bodyMatchResults;
    if (results == null ||
        searchPending ||
        showDeleted ||
        !knowledgeCurrent ||
        !identical(results.repository, repository)) {
      return const {};
    }
    return results.matches;
  }

  void setSearchQuery(
    String value, {
    bool bookmark = false,
    bool literal = false,
    bool expression = false,
  }) {
    final fromBookmark = bookmark && value.trim().isNotEmpty;
    final literalSearch = fromBookmark && literal && !expression;
    if (_query == value &&
        searchesFromBookmark == fromBookmark &&
        searchesLiterally == literalSearch &&
        searchesWithOperators == expression) {
      return;
    }
    _query = value;
    _bookmarkQueryRepository = fromBookmark ? repository : null;
    _expressionQueryRepository = expression ? repository : null;
    _literalBookmarkQuery = literalSearch;
    _searchGeneration++;
  }

  var showDeleted = false;
  StreamSubscription<void>? _changes;
  Future<void> _refreshTail = Future.value();
  var _disposed = false;
  var _markdownGeneration = 0;
  var _activityGeneration = 0;
  var inkBusy = false;
  var externalBusy = false;
  var _externalMutations = 0;
  var repositoryGeneration = 0;
  NoteSession? _pendingImportSession;
  PdfImportPreparation? _pdfPreparation;
  ({NoteSession session, int? number, String? pageId})? _inkPageLink;
  var _pdfImportCancelled = false;
  Timer? _markdownTimer;
  Future<void> _operationTail = Future.value();
  var _operations = 0;
  DatabaseAutomationCoordinator? _automations;
  var _repositorySwitching = false;
  DatabaseAutomationPass? get lastAutomationPass => _automations?.lastPass;

  DatabaseAutomationCoordinator createAutomationCoordinator({
    DatabaseActionRuntime? actionRuntime,
    bool Function()? canRun,
    DateTime Function()? clock,
    Duration interval = const Duration(minutes: 1),
    int maxNotes = 16,
    int maxPagesPerNote = 4,
    int maxEventsPerPass = 64,
  }) {
    if (_automations != null && !_automations!.isDisposed) return _automations!;
    return _automations = DatabaseAutomationCoordinator(
      repository: () => repository,
      runtimeFor: (repo) =>
          actionRuntime ??
          (native == null
              ? null
              : DatabaseActionRuntime(
                  deviceId: repo.deviceId,
                  invoke: native!.invoke,
                )),
      captureActivity: _captureAutomationActivity,
      commit: _commitAutomation,
      canRun: canRun,
      clock: clock,
      interval: interval,
      maxNotes: maxNotes,
      maxPagesPerNote: maxPagesPerNote,
      maxEventsPerPass: maxEventsPerPass,
    );
  }

  Object? _captureAutomationActivity() =>
      _disposed ||
          _repositorySwitching ||
          dirty ||
          externalBusy ||
          _operations != 0
      ? null
      : (
          _activityGeneration,
          editorGeneration,
          activeSession,
          currentFolderId,
          query,
        );

  bool _automationCurrent(
    DatabaseAutomationPlan plan, {
    bool ownOperation = false,
    bool locked = false,
  }) {
    if (_disposed ||
        _repositorySwitching ||
        !identical(repository, plan.repository) ||
        !plan.isCurrent() ||
        dirty ||
        externalBusy && !locked ||
        _operations != (ownOperation ? 1 : 0) ||
        plan.activity is! _AutomationActivity)
      return false;
    final activity = plan.activity as _AutomationActivity;
    return _activityGeneration == activity.$1 + (ownOperation ? 1 : 0) &&
        editorGeneration == activity.$2 &&
        identical(activeSession, activity.$3) &&
        currentFolderId == activity.$4 &&
        query == activity.$5;
  }

  Future<bool> _automationHeadsMatch(DatabaseAutomationPlan plan) async {
    final repo = plan.repository;
    final metadata = await repo.heads(plan.note.id),
        ink = await repo.heads(plan.note.inkEntityId);
    if (metadata.length != 1 ||
        metadata.single.deleted ||
        metadata.single.revisionId != plan.note.revision.revisionId ||
        ink.length != 1 ||
        ink.single.deleted ||
        ink.single.revisionId != plan.inputRevision.revisionId ||
        plan.inputRevision.kind != EntityKind.ink ||
        plan.inputRevision.ownerNoteId != plan.note.id ||
        plan.inputRevision.vaultId != repo.vaultId)
      return false;
    for (final folder in plan.folderHeads.entries) {
      final heads = await repo.heads(folder.key);
      if (heads.length != 1 ||
          heads.single.deleted ||
          heads.single.revisionId != folder.value)
        return false;
    }
    return true;
  }

  Future<DatabaseAutomationCommit> _commitAutomation(
    DatabaseAutomationPlan plan,
  ) async {
    if (!_automationCurrent(plan))
      return const DatabaseAutomationCommit('stale');
    try {
      return await _serialize(() async {
        if (!_automationCurrent(plan, ownOperation: true))
          return const DatabaseAutomationCommit('stale');
        externalBusy = true;
        if (!_disposed) notifyListeners();
        try {
          if (!await _automationHeadsMatch(plan) ||
              !_automationCurrent(plan, ownOperation: true, locked: true))
            return const DatabaseAutomationCommit('stale');
          final snapshot = await prepareDatabaseMediaInWorker(
            plan.database,
            existingFiles: plan.files,
            addedFiles: const {},
          );
          bool current() =>
              _automationCurrent(plan, ownOperation: true, locked: true);
          void requireWrite() {
            if (!current()) throw StateError('Automatic save became stale');
          }

          if (!current()) return const DatabaseAutomationCommit('stale');
          final detached = NoteSession(plan.repository, plan.note, [
            plan.inputRevision,
          ], []);
          try {
            await detached.saveInk(
              snapshot.files,
              expectedHeads: {
                plan.note.id: [plan.note.revision.revisionId],
                plan.note.inkEntityId: [plan.inputRevision.revisionId],
                for (final folder in plan.folderHeads.entries)
                  folder.key: [folder.value],
              },
              requireWrite: requireWrite,
            );
          } on StateError {
            if (!current() || !await _automationHeadsMatch(plan)) {
              return const DatabaseAutomationCommit('stale');
            }
            rethrow;
          }
          final newId = detached.inkParents.single;
          final heads = await plan.repository.heads(plan.note.inkEntityId);
          final clean = current();
          final unique =
              heads.length == 1 &&
              !heads.single.deleted &&
              heads.single.revisionId == newId;
          if (clean && unique && activeSession?.note.id == plan.note.id) {
            activeSession!.inkParents = List.of(detached.inkParents);
            activeSession!.inkHeads = heads;
            editorGeneration++;
          } else if (!clean && activeSession?.note.id == plan.note.id ||
              !unique) {
            remoteConflict = true;
          }
          return DatabaseAutomationCommit(
            clean && unique ? 'committed' : 'conflict',
            revisionId: newId,
          );
        } finally {
          externalBusy = false;
          if (!_disposed) notifyListeners();
        }
      });
    } finally {
      await _operationTail;
      if (!_disposed) await refresh();
    }
  }

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
  new(
    this.repository, {
    this.native,
    Future<Directory> Function()? directoryProvider,
  }) : _directoryProvider =
           directoryProvider ?? getApplicationSupportDirectory {
    _listen();
  }
  bool get dirty => markdownDirty || inkDirty || inkBusy;
  bool get canCreateDocument =>
      !_disposed && !_repositorySwitching && _operations == 0 && !externalBusy;

  void _requireCreationTarget(
    NoteRepository repo,
    NoteSession? previous,
    int generation,
    String? folderId,
  ) {
    if (!_current(repo, previous) ||
        generation != _activityGeneration ||
        currentFolderId != folderId ||
        !canCreateDocument ||
        dirty)
      throw StateError('문서를 만드는 중 대상이나 입력이 바뀌었습니다. 저장된 목록을 확인하세요.');
  }

  void _requireCreatedDocument(NoteRepository repo, VaultNote note) {
    if (_disposed ||
        _repositorySwitching ||
        !identical(repository, repo) ||
        activeSession?.note.id != note.id ||
        !identical(activeSession?.repository, repo))
      throw StateError('문서를 여는 중 저장소가 바뀌었습니다. 원래 저장소의 목록을 확인하세요.');
  }

  String? get pendingPdfPath =>
      _pdfImportCancelled || pdfPeerPreview ? null : _pdfPreparation?.path;
  bool get pdfPeerPreview =>
      !_pdfImportCancelled && _pdfPreparation?.peerPreview == true;
  String? get pdfPeerPreviewPath =>
      pdfPeerPreview ? _pdfPreparation?.path : null;
  String? get pdfImportError => _pdfImportCancelled
      ? 'PDF 가져오기를 보류했습니다. 원본과 저장된 필기는 보존됩니다.'
      : _pdfPreparation?.message;

  Future<VaultNote> importPdf(
    String title, {
    required String fileName,
    required Uint8List bytes,
  }) => _importPdf(title, fileName: fileName, bytes: bytes);

  /// [keptOriginal] is the converted Office/HWP file; the new PDF note keeps it so a newer engine can convert it
  /// into another PDF note later (PdfNoteOriginalStore).
  Future<VaultNote> importOfficePdf(
    String title, {
    required String fileName,
    required Uint8List bytes,
    int? pdfPageNumber,
    String? sharedRequestId,
    SharedOfficeOriginal? sharedOfficeOriginal,
    ({String fileName, Uint8List bytes, String? engineVersion})? keptOriginal,
  }) => _importPdf(
    title,
    fileName: fileName,
    bytes: bytes,
    pdfPageNumber: pdfPageNumber,
    sharedRequestId: sharedRequestId,
    sharedOfficeOriginal: sharedOfficeOriginal,
    keptOriginal: keptOriginal,
  );

  Future<VaultNote> importSharedPdf(
    String title, {
    required String fileName,
    required Uint8List bytes,
    required String requestId,
  }) {
    final header = latin1.decode(
      bytes.sublist(0, bytes.length < 1024 ? bytes.length : 1024),
    );
    if (!header.contains('%PDF-'))
      throw const FormatException('공유 PDF의 형식을 확인할 수 없습니다.');
    return _importPdf(
      title,
      fileName: fileName,
      bytes: bytes,
      sharedRequestId: requestId,
    );
  }

  Future<VaultNote> _importPdf(
    String title, {
    required String fileName,
    required Uint8List bytes,
    String? sharedRequestId,
    SharedOfficeOriginal? sharedOfficeOriginal,
    int? pdfPageNumber,
    ({String fileName, Uint8List bytes, String? engineVersion})? keptOriginal,
  }) async {
    if (dirty) throw StateError('먼저 현재 노트를 저장하세요.');
    final repo = repository, source = store;
    final previous = activeSession;
    final generation = _activityGeneration;
    final folderId = currentFolderId;
    _requireCreationTarget(repo, previous, generation, folderId);
    final note = await source.createWithSource(
      title,
      fileName: fileName,
      bytes: bytes,
      documentKind: VaultDocumentKind.pdf,
      folderId: folderId,
      sharedRequestId: sharedRequestId,
      sharedOfficeOriginal: sharedOfficeOriginal,
    );
    if (note.trashed) return note;
    if (keptOriginal != null) {
      try {
        await PdfNoteOriginalStore(repo).attach(
          note,
          fileName: keptOriginal.fileName,
          bytes: keptOriginal.bytes,
          engineVersion: keptOriginal.engineVersion,
        );
      } catch (error) {
        // The PDF note is complete without it; only a later re-conversion needs the original.
        debugPrint('PIVImport: the Office original was not kept: $error');
      }
    }
    _requireCreationTarget(repo, previous, generation, folderId);
    final session = await source.open(note);
    _requireCreationTarget(repo, previous, generation, folderId);
    if (session.inkHeads.isEmpty) {
      final core = EditorCoreInfo(filePath: '/.working/${note.id}/new/main')
        ..pages.add(EditorPage());
      try {
        final files = await SaberInkAdapter.capture(core, 0);
        _requireCreationTarget(repo, previous, generation, folderId);
        await session.saveInk(files);
      } finally {
        core.dispose();
      }
    }
    _requireCreationTarget(repo, previous, generation, folderId);
    await openNote(note, pdfPageNumber: pdfPageNumber);
    _requireCreatedDocument(repo, note);
    return note;
  }

  Future<void> retryPdfImport({required NoteSession session}) async {
    if (!identical(session, activeSession))
      throw StateError('이 PDF 문서는 이미 닫혔습니다.');
    final request = hasPendingInkPageLink(session) ? _inkPageLink : null;
    await openNote(
      session.note,
      recordNavigation: false,
      pageId: request?.pageId,
      revealLinkedPage: request?.pageId != null,
      pdfPageNumber: request?.number,
    );
  }

  Future<void> beginPdfInkHere({required NoteSession session}) =>
      _serialize(() async {
        final repo = repository;
        final preview = _pdfPreparation;
        if (!_current(repo, session) ||
            !pdfPeerPreview ||
            dirty ||
            remoteConflict) {
          throw StateError('현재 PDF를 다시 연 뒤 필기를 시작하세요.');
        }
        final preparation = await PdfImportPreparation.prepare(
          session,
          initializeHere: true,
        );
        final ink = await repo.heads(session.note.inkEntityId);
        if (!_current(repo, session) ||
            !identical(_pdfPreparation, preview) ||
            preparation.signature != preview?.signature ||
            !setEquals(
              ink.map((row) => row.revisionId).toSet(),
              session.inkParents.toSet(),
            ) ||
            dirty ||
            preparation.message != null) {
          throw StateError('PDF나 필기 판본이 바뀌었습니다. 수신된 문서를 다시 확인하세요.');
        }
        _installPdfPreparation(session, preparation);
        editorGeneration++;
        notifyListeners();
      });

  bool hasPendingInkPageLink(NoteSession session) =>
      identical(_inkPageLink?.session, session) &&
      identical(activeSession, session);

  Future<ResolvedInkPageLink?>? resolveLinkedInkPage(
    NoteSession session,
    EditorCoreInfo core,
  ) {
    final pageId = _inkPageLink?.pageId;
    if (pageId == null || !hasPendingInkPageLink(session)) return null;
    _inkPageLink = null;
    final page = core.pages.where((page) => page.pageId == pageId).singleOrNull;
    return Future.value(
      page == null
          ? null
          : (
              page: (pageId: pageId, background: page.backgroundImage),
              repositoryGeneration: repositoryGeneration,
            ),
    );
  }

  Future<ResolvedInkPageLink?>? resolvePdfPageLink(
    NoteSession session,
    EditorCoreInfo core,
  ) {
    final number = _inkPageLink?.number;
    if (number == null || !hasPendingInkPageLink(session)) return null;
    _inkPageLink = null;
    final preparation = _pdfPreparation;
    final repo = repository;
    final ink = session.inkParents.singleOrNull;

    Future<ResolvedInkPageLink?> resolve() async {
      if (preparation == null || ink == null) return null;
      final destination = await preparation.findPage(core, number);
      if (destination == null || !_current(repo, session)) return null;
      final generation = repositoryGeneration;
      try {
        await preparation.validateCurrent(session);
        final heads = await repo.heads(session.note.inkEntityId);
        return _current(repo, session) &&
                repositoryGeneration == generation &&
                heads.singleOrNull?.revisionId == ink
            ? (page: destination, repositoryGeneration: generation)
            : null;
      } on StateError {
        return null;
      }
    }

    return resolve();
  }

  bool canSearchPdfText(NoteSession session) =>
      _current(repository, session) &&
      !_repositorySwitching &&
      !_pdfImportCancelled &&
      !inkDirty &&
      !inkBusy &&
      !externalBusy &&
      !remoteConflict &&
      _pdfPreparation?.complete == true &&
      _pdfPreparation?.marker != null &&
      session.inkParents.length == 1;

  PdfTextSearchAccess? pdfTextSearch(NoteSession session, EditorCoreInfo core) {
    final preparation = _pdfPreparation;
    if (preparation == null || !canSearchPdfText(session)) return null;
    final repo = repository;
    final generation = repositoryGeneration;
    final editor = editorGeneration;
    final ink = session.inkParents.single;
    bool current() =>
        identical(repository, repo) &&
        repositoryGeneration == generation &&
        editorGeneration == editor &&
        identical(_pdfPreparation, preparation) &&
        canSearchPdfText(session) &&
        session.inkParents.singleOrNull == ink;

    Future<bool> savedScope() async {
      if (!current()) return false;
      try {
        await preparation.validateCurrent(session);
      } on StateError {
        return false;
      }
      if (!current()) return false;
      final heads = await repo.heads(session.note.inkEntityId);
      return current() && heads.singleOrNull?.revisionId == ink;
    }

    return (
      search: (query, active) async {
        if (!active() || !await savedScope() || !active()) return null;
        final result = await preparation.searchText(
          core,
          query,
          isCurrent: () => active() && current(),
        );
        return active() && await savedScope() && active() ? result : null;
      },
      resolve: (hit) async => await savedScope()
          ? (page: hit.destination, repositoryGeneration: generation)
          : null,
    );
  }

  void _installPdfPreparation(
    NoteSession session,
    PdfImportPreparation? value,
  ) {
    _pdfPreparation = value;
    _pdfImportCancelled = false;
    _pendingImportSession = null;
    if (value?.path != null && value?.peerPreview == false) {
      _pendingImportSession = session;
      inkBusy = true;
      inkDirty = true;
    }
  }

  static Future<WorkspaceController> openDefault({
    InkVaultNative? Function() loadNative = InkVaultNative.open,
  }) async {
    final support = await getApplicationSupportDirectory();
    final selection = File('${support.path}/vault-selection.json');
    var root = '${support.path}/vaults/offline';
    if (selection.existsSync()) {
      root =
          (jsonDecode(await selection.readAsString())
                  as Map<String, dynamic>)['root']
              as String;
    }
    final controller = await _openLibrary(
      Directory(root),
      native: loadNative(),
      driveDirectory: Directory('${support.path}/drive'),
    );
    if (controller.repository.root.path != root) {
      await support.create(recursive: true);
      final pending = File('${selection.path}.${newId()}.pending');
      await pending.writeAsString(
        jsonEncode({'root': controller.repository.root.path}),
        flush: true,
      );
      await pending.rename(selection.path);
    }
    return controller;
  }

  static Future<WorkspaceController> openLibrary(
    Directory root, {
    InkVaultNative? native,
  }) => _openLibrary(root, native: native);

  static Future<WorkspaceController> _openLibrary(
    Directory root, {
    InkVaultNative? native,
    Directory? driveDirectory,
  }) async {
    var repository = await NoteRepository.open(root, createFormatVersion: 2);
    if (repository.formatVersion == 1 &&
        (driveDirectory == null ||
            !await _isBoundLegacyDriveVault(repository, driveDirectory))) {
      try {
        if (repository.pendingRevisionCount != 0 ||
            repository.integrityIssues.isNotEmpty) {
          throw const FormatException(
            '기존 저장소의 수신·복구를 완료한 뒤 새 작업공간을 여세요. 원본은 보존됩니다.',
          );
        }
        final next = await BackupService.cloneToEmpty(
          repository,
          Directory('${root.path}-v2-${newId()}'),
          targetFormatVersion: 2,
        );
        await repository.close();
        repository = next;
      } catch (_) {
        await repository.close();
        rethrow;
      }
    }
    final controller = WorkspaceController(repository, native: native);
    await controller.refresh();
    await controller._restoreNavigation();
    return controller;
  }

  static Future<bool> _isBoundLegacyDriveVault(
    NoteRepository repository,
    Directory driveDirectory,
  ) async {
    try {
      final binding = await DriveConnectionSettings.load(driveDirectory);
      return binding.folderId != null &&
          binding.rootPath == repository.root.path &&
          binding.vaultId == repository.vaultId &&
          (binding.vaultFormatVersion ?? 1) == 1;
    } on Object {
      // Drive reports connection settings errors independently of the library.
      return false;
    }
  }

  File get _navigationFile =>
      File('${repository.root.path}/.workspace/navigation.json');

  Future<void> _persistNavigation() async {
    try {
      await navigation.save(_navigationFile);
    } catch (e) {
      error = '문서는 보관됐지만 열린 탭 상태를 저장하지 못했습니다: $e';
    }
  }

  Future<void> _restoreNavigation() async {
    final repo = repository, session = activeSession;
    try {
      final restored = await WorkspaceNavigation.load(_navigationFile);
      final available = await WorkspaceStore(
        repo,
        native: native,
      ).list(includeDeleted: true);
      if (!_current(repo, session)) return;
      navigation = restored;
      if (_reconcileNavigation(available, keepNoteId: session?.note.id)) {
        await _persistNavigation();
      }
      if (!_current(repo, session)) return;
      await _openLocation(navigation.current);
    } catch (e) {
      if (!_disposed && identical(repository, repo)) {
        error = '이전 화면을 복원하지 못했습니다. 문서 목록에서 다시 여세요: $e';
        notifyListeners();
      }
    }
  }

  bool _reconcileNavigation(
    List<VaultNote> available, {
    required String? keepNoteId,
  }) {
    final byId = groupBy(available, (note) => note.id);
    var changed = navigation.pruneDeletedDocuments({
      for (final entry in byId.entries)
        if (entry.key != keepNoteId &&
            entry.value.every((note) => note.trashed && !note.deletionConflict))
          entry.key,
    });
    for (final tab in navigation.tabs) {
      final note = byId[tab.noteId]?.singleOrNull;
      if (note != null && note.title != tab.title) {
        navigation.updateTitle(tab.noteId, note.title);
        changed = true;
      }
    }
    return changed;
  }

  Future<void> _openLocation(WorkspaceLocation location) async {
    if (location.noteId != null) {
      final note = (await store.list())
          .where((n) => n.id == location.noteId)
          .firstOrNull;
      if (note == null) throw StateError('이 문서는 삭제되었거나 아직 수신되지 않았습니다.');
      await openNote(note, recordNavigation: false);
    } else {
      if (activeSession != null) {
        await closeNote(session: activeSession!, recordNavigation: false);
      }
      await library.validateDestination(location.folderId);
      currentFolderId = location.folderId;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> backInHistory() => _navigateHistory(forward: false);
  Future<void> forwardInHistory() => _navigateHistory(forward: true);

  Future<void> _navigateHistory({required bool forward}) async {
    final repo = repository, session = activeSession, state = navigation;
    await flush();
    if (!_current(repo, session) ||
        !identical(state, navigation) ||
        _repositorySwitching) {
      return;
    }
    final location = forward ? state.peekForward : state.peekBack;
    if (location == null) return;
    await _openLocation(location);
    if (_disposed ||
        !identical(repo, repository) ||
        !identical(state, navigation) ||
        activeSession?.note.id != location.noteId ||
        !identical(location, forward ? state.peekForward : state.peekBack)) {
      return;
    }
    if (forward) {
      state.goForward();
    } else {
      state.goBack();
    }
    await _persistNavigation();
    if (!_disposed) notifyListeners();
  }

  Future<void> activateDocumentTab(String id) async {
    final repo = repository, session = activeSession;
    await flush();
    if (!_current(repo, session) || _repositorySwitching) {
      throw StateError('보관함이나 열린 문서가 바뀌었습니다. 탭을 다시 눌러 주세요.');
    }
    await _activateDocumentTab(id);
  }

  Future<void> _activateDocumentTab(String id) async {
    validateId(id);
    final repo = repository, session = activeSession, state = navigation;
    final generation = _activityGeneration;
    final catalogGeneration = repositoryGeneration;
    final note = (await store.list()).firstWhereOrNull(
      (note) => note.id == id && !note.trashed,
    );
    if (!_current(repo, session) ||
        _repositorySwitching ||
        !identical(state, navigation) ||
        generation != _activityGeneration ||
        catalogGeneration != repositoryGeneration ||
        dirty) {
      throw StateError('보관함이나 열린 문서가 바뀌었습니다. 탭을 다시 눌러 주세요.');
    }
    final tab = state.tabs.firstWhereOrNull((tab) => tab.noteId == id);
    if (tab == null || note == null) {
      throw StateError('문서를 찾을 수 없습니다. 수신 상태나 휴지통을 확인하세요.');
    }
    final location = tab.location;
    await openNote(
      note,
      markdownView: location?.markdown,
      pageId: location?.pageId,
      markdownAnchor: location?.markdownAnchor,
      databaseViewId: location?.databaseViewId,
      reuseSession: true,
      expectedRepositoryGeneration: catalogGeneration,
    );
  }

  Future<void> closeDocumentTab(String id) async {
    final repo = repository, session = activeSession, state = navigation;
    await flush();
    if (!_current(repo, session) ||
        _repositorySwitching ||
        !identical(state, navigation)) {
      throw StateError('보관함이나 열린 문서가 바뀌었습니다. 탭을 다시 눌러 주세요.');
    }
    final tabs = state.tabs;
    final index = tabs.indexWhere((tab) => tab.noteId == id);
    if (index < 0) return;
    if (session?.note.id == id) {
      final remaining = tabs.where((tab) => tab.noteId != id).toList();
      if (remaining.isEmpty) {
        await closeNote(session: session!);
      } else {
        final replacement = remaining[index.clamp(0, remaining.length - 1)];
        await _activateDocumentTab(replacement.noteId);
      }
    }
    if (_disposed ||
        !identical(repo, repository) ||
        !identical(state, navigation))
      return;
    state.closeTab(id);
    await _persistNavigation();
    if (!_disposed) notifyListeners();
  }

  Future<void> rememberView({
    required bool markdown,
    String? pageId,
    String? markdownAnchor,
    String? databaseViewId,
  }) async {
    final session = activeSession;
    if (session == null || navigation.current.noteId != session.note.id) return;
    navigation.updateView(
      markdown: markdown,
      pageId: pageId,
      databaseViewId: databaseViewId,
      markdownAnchor: markdown
          ? markdownAnchor ?? navigation.current.markdownAnchor
          : null,
    );
    await _persistNavigation();
  }

  Future<void> rememberInfiniteView(
    String noteId,
    InfiniteViewport viewport,
  ) async {
    if (activeSession?.note.id != noteId) return;
    navigation.setInfiniteViewport(noteId, viewport);
    await _persistNavigation();
  }

  Future<void> openFolder(String? id) async {
    await library.validateDestination(id);
    currentFolderId = id;
    navigation.showLibrary(id);
    await _persistNavigation();
    if (!_disposed) notifyListeners();
  }

  Future<VaultFolder> createFolder(String title) async {
    final folder = await library.createFolder(title, parentId: currentFolderId);
    await refresh();
    return folder;
  }

  void _listen() {
    _changes = repository.changes.listen((_) {
      repositoryGeneration++;
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
    final searchText = query;
    final literalSearch = searchesLiterally;
    final expression = searchesWithOperators;
    final searchGeneration = _searchGeneration;
    final includeDeleted = showDeleted;
    final hasExpression =
        !includeDeleted && expression && searchText.trim().isNotEmpty;
    bool currentSearch() =>
        _current(repo, session) &&
        _searchGeneration == searchGeneration &&
        showDeleted == includeDeleted;
    try {
      final source = WorkspaceStore(repo, native: native);
      final engine = native;
      String? searchError;
      final bodyMatches = <String, KnowledgeBodyMatch>{};
      var listed = includeDeleted
          ? await source.list(includeDeleted: true)
          : hasExpression && engine == null
          ? <VaultNote>[]
          : engine != null && !literalSearch
          ? await source.list()
          : await source.search(searchText);
      if (hasExpression && engine == null) {
        searchError = '이 설치에서는 검색식을 사용할 수 없습니다.';
      }
      if (engine != null) {
        final knowledgeGeneration = repositoryGeneration;
        final signature =
            '${repo.vaultId}/${(await repo.revisions()).map((r) => r.revisionId).join('/')}';
        if (_knowledgeSignature != signature) {
          final index = await KnowledgeIndex.build(repo, engine);
          if (!_current(repo, session)) return;
          knowledge = index;
          _knowledgeSignature = signature;
        }
        _knowledgeRepositoryGeneration = knowledgeGeneration;
        if (!includeDeleted && !literalSearch && searchText.trim().isNotEmpty) {
          if (!currentSearch()) return;
          try {
            final matches = knowledge!.search(
              searchText,
              expression: expression,
              includeBodyMatches: true,
            );
            final ids = {for (final match in matches) match.id};
            for (final match in matches) {
              if (match.bodyMatch case final body?)
                bodyMatches[match.id] = body;
            }
            listed = listed.where((note) => ids.contains(note.id)).toList();
          } on InkVaultNativeException catch (e) {
            if (!expression) rethrow;
            searchError = e.code == 'invalid_search_expression'
                ? '검색식 문법을 확인하세요.'
                : '검색식을 실행할 수 없습니다.';
            listed = [];
          }
        }
      }
      if (!_current(repo, session)) return;
      final available = await source.list(includeDeleted: true);
      if (!_current(repo, session)) return;
      if (_reconcileNavigation(available, keepNoteId: session?.note.id)) {
        await _persistNavigation();
      }
      if (!currentSearch()) return;
      final listedFolders = await LibraryStore(repo)
          .listFolders(includeDeleted: includeDeleted);
      if (!currentSearch()) return;
      notes = listed;
      folders = listedFolders;
      _searchError = searchError;
      _bodyMatchResults = bodyMatches.isEmpty
          ? null
          : (repository: repo, matches: Map.unmodifiable(bodyMatches));
      _displayedSearchGeneration = searchGeneration;
      _displayedSearchIncludesDeleted = includeDeleted;
      if (currentFolderId != null &&
          !folders.any((f) => f.id == currentFolderId && !f.trashed)) {
        currentFolderId = null;
      }
      if (session != null) {
        final ink = await repo.heads(session.note.inkEntityId);
        final md = await repo.heads(session.note.markdownEntityId);
        final meta = await repo.heads(session.note.id);
        final updatedNote = available
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
        var conflict =
            meta.length > 1 ||
            (updatedNote?.deletionConflict ?? false) ||
            ink.length > 1 ||
            md.length > 1;
        if (session.note.sourceEntityId != null) {
          final owned =
              (await repo.revisions())
                  .where((r) => r.ownerNoteId == session.note.id)
                  .map((r) => r.entityId)
                  .toSet()
                ..remove(session.note.inkEntityId)
                ..remove(session.note.markdownEntityId);
          for (final id in owned) {
            if ((await repo.heads(id)).length > 1) conflict = true;
          }
        }
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
                (inkChanged || mdChanged || (updatedNote?.trashed ?? false)));
        if (!protected && !remoteConflict) {
          if (updatedNote != null) session.note = updatedNote;
          if (updatedNote?.trashed ?? false) {
            activeSession = null;
            _inkPageLink = null;
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
            if (PdfImportPreparation.applies(session) && !_pdfImportCancelled) {
              final key = await PdfImportPreparation.signatureFor(session);
              if (key != _pdfPreparation?.signature) {
                final value = await PdfImportPreparation.prepare(session);
                if (!_current(repo, session) ||
                    dirty ||
                    generation != _activityGeneration)
                  return;
                final wasBlocked = pdfImportError != null;
                _installPdfPreparation(session, value);
                if (wasBlocked || value.message != null || value.path != null)
                  editorGeneration++;
              }
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
      if (currentSearch()) {
        _bodyMatchResults = null;
        if (hasExpression) {
          notes = [];
          _searchError = '검색을 완료하지 못했습니다.';
        } else {
          _searchError = null;
        }
        _displayedSearchGeneration = searchGeneration;
        _displayedSearchIncludesDeleted = includeDeleted;
        error = '저장소를 읽을 수 없습니다: $e';
      }
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> replaceRepository(NoteRepository next) async {
    if (_repositorySwitching) throw StateError('저장소 전환이 이미 진행 중입니다.');
    _repositorySwitching = true;
    _activityGeneration++;
    _automations?.invalidate();
    try {
      await _replaceRepository(next);
    } finally {
      _repositorySwitching = false;
      _automations?.invalidate();
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _replaceRepository(NoteRepository next) async {
    if (_operations != 0) throw StateError('저장 작업이 끝난 뒤 저장소를 전환하세요.');
    if (dirty) throw StateError('열린 노트를 저장한 뒤 저장소를 전환하세요.');
    final previous = repository;
    final session = activeSession;
    final previousMarkdown = markdown;
    final previousFolder = currentFolderId;
    final previousKnowledge = knowledge;
    final previousSignature = _knowledgeSignature;
    final previousKnowledgeGeneration = _knowledgeRepositoryGeneration;
    final previousNavigation = navigation;
    final previousPdfPreparation = _pdfPreparation;
    final previousInkPageLink = _inkPageLink;
    final previousPdfCancelled = _pdfImportCancelled;
    final generation = _activityGeneration;
    await _changes?.cancel();
    if (!_current(previous, session) ||
        generation != _activityGeneration ||
        dirty) {
      if (!_disposed && identical(repository, previous)) _listen();
      throw StateError('전환 중 새 입력이 생겼습니다. 현재 문서를 저장한 뒤 다시 시도하세요.');
    }
    final previousBookmarkSearch = searchesFromBookmark;
    final previousLiteralSearch = searchesLiterally;
    final previousExpressionSearch = searchesWithOperators;
    final previousQuery = query;
    final previousSearchError = _searchError;
    final previousBodyMatchResults = _bodyMatchResults;
    final previousSearchPending = searchPending;
    final previousDisplayedSearchIncludesDeleted =
        _displayedSearchIncludesDeleted;
    final previousNotes = notes;
    final previousFolders = folders;
    activeSession = null;
    _pdfPreparation = null;
    _inkPageLink = null;
    _pdfImportCancelled = false;
    markdown = '';
    currentFolderId = null;
    if (previousBookmarkSearch || previousExpressionSearch) query = '';
    repository = next;
    notes = [];
    folders = [];
    _searchError = null;
    _bodyMatchResults = null;
    navigation = WorkspaceNavigation();
    knowledge = null;
    _knowledgeSignature = null;
    _knowledgeRepositoryGeneration = null;
    _listen();
    editorGeneration++;
    if (!_disposed) notifyListeners();
    File? pendingSelection;
    try {
      final support = await _directoryProvider();
      await support.create(recursive: true);
      final target = File('${support.path}/vault-selection.json');
      pendingSelection = File('${target.path}.${newId()}.pending');
      await pendingSelection.writeAsString(
        jsonEncode({'root': next.root.path}),
        flush: true,
      );
      await pendingSelection.rename(target.path);
    } catch (_) {
      await _changes?.cancel();
      repository = previous;
      activeSession = session;
      _pdfPreparation = previousPdfPreparation;
      _inkPageLink = previousInkPageLink;
      _pdfImportCancelled = previousPdfCancelled;
      markdown = previousMarkdown;
      currentFolderId = previousFolder;
      setSearchQuery(
        previousQuery,
        bookmark: previousBookmarkSearch,
        literal: previousLiteralSearch,
        expression: previousExpressionSearch,
      );
      notes = previousNotes;
      folders = previousFolders;
      _searchError = previousSearchError;
      _bodyMatchResults = previousBodyMatchResults;
      if (!previousSearchPending)
        _displayedSearchGeneration = _searchGeneration;
      _displayedSearchIncludesDeleted = previousDisplayedSearchIncludesDeleted;
      knowledge = previousKnowledge;
      _knowledgeSignature = previousSignature;
      _knowledgeRepositoryGeneration = previousKnowledgeGeneration;
      navigation = previousNavigation;
      _listen();
      if (previousSearchPending) unawaited(refresh());
      editorGeneration++;
      if (!_disposed) notifyListeners();
      rethrow;
    } finally {
      if (pendingSelection != null && pendingSelection.existsSync())
        await pendingSelection.delete();
    }
    await previous.close();
    await refresh();
    await _restoreNavigation();
  }

  Future<void> reloadFromDisk() => _serialize(() async {
    await _refreshTail;
    await repository.reloadFromDisk();
  }).then((_) => _refreshTail);

  Future<void> openNote(
    VaultNote note, {
    bool recordNavigation = true,
    bool? markdownView,
    String? markdownAnchor,
    String? pageId,
    String? databaseViewId,
    bool revealLinkedPage = false,
    int? pdfPageNumber,
    bool reuseSession = false,
    int? expectedRepositoryGeneration,
    String? expectedDatabaseRevision,
  }) async {
    if (_operations != 0) throw StateError('저장 작업이 끝난 뒤 문서를 전환하세요.');
    if (dirty) throw StateError('먼저 현재 노트를 저장하세요.');
    if (expectedRepositoryGeneration != null &&
        repositoryGeneration != expectedRepositoryGeneration) {
      throw StateError('보관함이 바뀌었습니다. 갱신된 조회 결과를 다시 눌러 주세요.');
    }
    final markdownViewValue =
        markdownView ?? note.documentKind == VaultDocumentKind.markdown;
    if (databaseViewId != null &&
        note.documentKind != VaultDocumentKind.database) {
      throw const FormatException('데이터베이스 문서에서만 보기를 열 수 있습니다.');
    }
    WorkspaceLocation.fromJson(
      WorkspaceLocation(
        noteId: note.id,
        folderId: note.folderId,
        pageId: pageId,
        databaseViewId: databaseViewId,
        markdown: markdownViewValue,
        markdownAnchor: markdownAnchor,
      ).toJson(),
    );
    if (reuseSession &&
        expectedDatabaseRevision == null &&
        pdfPageNumber == null &&
        !revealLinkedPage &&
        activeSession?.note.id == note.id) {
      if (recordNavigation) {
        navigation.openDocument(
          note.id,
          note.title,
          folderId: note.folderId,
          markdown: markdownViewValue,
          markdownAnchor: markdownAnchor,
          pageId: pageId,
          databaseViewId: databaseViewId,
        );
        await _persistNavigation();
      }
      if (!_disposed) notifyListeners();
      return;
    }
    final repo = repository;
    final previous = activeSession;
    final generation = _activityGeneration;
    final next = await store.open(note);
    if (expectedDatabaseRevision != null &&
        next.inkParents.singleOrNull != expectedDatabaseRevision) {
      throw StateError('데이터베이스 원본이 바뀌었습니다. 최신 보기에서 다시 열어 주세요.');
    }
    final text = await next.readMarkdown();
    final pdfPreparation = PdfImportPreparation.applies(next)
        ? await PdfImportPreparation.prepare(next)
        : null;
    if (!_current(repo, previous) ||
        generation != _activityGeneration ||
        (expectedRepositoryGeneration != null &&
            repositoryGeneration != expectedRepositoryGeneration) ||
        dirty) {
      throw StateError('문서를 여는 중 새 입력이 생겼습니다. 현재 작업을 저장한 뒤 다시 여세요.');
    }
    activeSession = next;
    final originalPage = pdfPreparation == null ? null : pdfPageNumber;
    final linkedPage = revealLinkedPage && originalPage == null ? pageId : null;
    _inkPageLink = originalPage == null && linkedPage == null
        ? null
        : (session: next, number: originalPage, pageId: linkedPage);
    _installPdfPreparation(next, pdfPreparation);
    currentFolderId = note.folderId;
    markdown = text;
    editorGeneration++;
    if (recordNavigation) {
      navigation.openDocument(
        note.id,
        note.title,
        folderId: note.folderId,
        markdown: markdownViewValue,
        markdownAnchor: markdownAnchor,
        pageId: pageId,
        databaseViewId: databaseViewId,
      );
      await _persistNavigation();
    }
    await refresh();
  }

  Future<void> closeNote({
    required NoteSession session,
    bool recordNavigation = true,
  }) => _serialize(() async {
    if (!identical(activeSession, session))
      throw StateError('이 편집 세션은 이미 닫혔습니다.');
    if (dirty) throw StateError('현재 작업을 저장한 뒤 노트 목록으로 돌아가세요.');
    activeSession = null;
    _inkPageLink = null;
    _pendingImportSession = null;
    _pdfPreparation = null;
    _pdfImportCancelled = false;
    markdown = '';
    remoteConflict = false;
    if (recordNavigation) {
      navigation.showLibrary(currentFolderId);
      await _persistNavigation();
    }
    editorGeneration++;
    if (!_disposed) notifyListeners();
  }).then((_) => refresh());

  Future<VaultNote> createNote(
    String title, {
    bool importingPdf = false,
    VaultDocumentKind documentKind = VaultDocumentKind.handwriting,
  }) async {
    if (dirty) throw StateError('먼저 현재 노트를 저장하세요.');
    final repo = repository, source = store;
    final previous = activeSession;
    final generation = _activityGeneration;
    final folderId = currentFolderId;
    _requireCreationTarget(repo, previous, generation, folderId);
    final kind = importingPdf && repo.formatVersion >= 2
        ? VaultDocumentKind.pdf
        : documentKind;
    final note = await source.create(
      title,
      folderId: folderId,
      documentKind: kind,
    );
    _requireCreationTarget(repo, previous, generation, folderId);
    final session = await source.open(note);
    _requireCreationTarget(repo, previous, generation, folderId);
    if (kind == VaultDocumentKind.handwriting ||
        kind == VaultDocumentKind.pdf ||
        kind == VaultDocumentKind.image) {
      final core = EditorCoreInfo(filePath: '/.working/${note.id}/new/main')
        ..pages.add(EditorPage());
      try {
        final files = await SaberInkAdapter.capture(core, 0);
        _requireCreationTarget(repo, previous, generation, folderId);
        await session.saveInk(files);
      } finally {
        core.dispose();
      }
    } else if (kind == VaultDocumentKind.infinite) {
      await session.saveInk({
        'infinite.json': Uint8List.fromList(
          utf8.encode(jsonEncode(const InfiniteDocument.empty().toJson())),
        ),
      });
    } else if (kind == VaultDocumentKind.canvas) {
      await session.saveInk({
        'board.canvas': Uint8List.fromList(
          utf8.encode(jsonEncode(const CardCanvasDocument.empty().toJson())),
        ),
      });
    } else if (kind == VaultDocumentKind.page) {
      await session.saveInk({
        'page.json': Uint8List.fromList(
          utf8.encode(jsonEncode(const BlockPageDocument.empty().toJson())),
        ),
      });
    } else if (kind == VaultDocumentKind.database) {
      await session.saveInk({
        'database.json': Uint8List.fromList(
          utf8.encode(
            jsonEncode(WorkspaceDatabase.empty(id: note.id).toJson()),
          ),
        ),
      });
    }
    _requireCreationTarget(repo, previous, generation, folderId);
    await openNote(note);
    _requireCreatedDocument(repo, note);
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
        _inkPageLink = null;
        if (PdfImportPreparation.applies(session)) _pdfImportCancelled = true;
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

  void editMarkdown(String value, {NoteSession? session}) {
    if (activeSession == null ||
        session != null && !identical(session, activeSession))
      return;
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

  Future<void> setDataviewTask(
    DataviewRow row,
    bool completed, {
    required bool Function() isCurrent,
  }) async {
    final task = row.task;
    if (task == null || (task.checked && !task.completed)) {
      throw StateError('원본 노트에서 할 일 상태를 확인하세요.');
    }
    final repo = repository;
    final session = activeSession;
    final generation = _activityGeneration + 1;
    void requireWrite() {
      if (!_current(repo, session) ||
          _repositorySwitching ||
          externalBusy ||
          generation != _activityGeneration ||
          !isCurrent() ||
          (session?.note.id == row.noteId && dirty)) {
        throw StateError('할 일 원본이나 현재 작업이 바뀌었습니다.');
      }
    }

    try {
      await _serialize(() async {
        requireWrite();
        final source = WorkspaceStore(repo);
        final note = (await source.list(includeDeleted: true))
            .where((note) => note.id == row.noteId)
            .singleOrNull;
        if (note == null ||
            note.trashed ||
            note.deletionConflict ||
            note.revision.deleted ||
            note.documentKind != VaultDocumentKind.markdown) {
          throw StateError('할 일의 원본 노트를 열 수 없습니다.');
        }
        final target = await source.open(note);
        requireWrite();
        final revision = target.markdownHeads.singleOrNull;
        if (revision == null ||
            revision.deleted ||
            revision.kind != EntityKind.markdown ||
            revision.ownerNoteId != note.id ||
            revision.revisionId != task.revisionId) {
          throw StateError('할 일 원본의 Markdown 판본이 바뀌었습니다.');
        }
        final bytes = await repo.readRevisionFile(revision, 'summary.md');
        requireWrite();
        final text = utf8.decode(bytes);
        final offset = task.statusOffset;
        if (offset <= 0 ||
            offset + 1 >= text.length ||
            text.substring(offset - 1, offset + 2) != '[${task.status}]') {
          throw StateError('할 일의 원본 위치를 확인할 수 없습니다.');
        }
        if (task.completed == completed) return;
        final updated = text.replaceRange(
          offset,
          offset + 1,
          completed ? 'x' : ' ',
        );
        // The UTF-8 decoder strips a leading BOM. Keep it in the saved bytes.
        final hasBom =
            bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf;
        await target.saveMarkdown(
          hasBom ? '\uFEFF$updated' : updated,
          expectedHeads: {
            note.id: [note.revision.revisionId],
            note.markdownEntityId: [revision.revisionId],
          },
          requireWrite: requireWrite,
        );
      });
    } finally {
      await _operationTail;
      if (_current(repo, session)) await refresh();
    }
  }

  Future<void> linkUnlinkedMention(
    KnowledgeUnlinkedMention mention, {
    required bool Function() isCurrent,
  }) async {
    final repo = repository;
    final session = activeSession;
    final index = knowledge;
    final generation = _activityGeneration + 1;
    final expected = mention.expectedHeads;
    void requireWrite() {
      if (!_current(repo, session) ||
          session?.note.id != mention.targetId ||
          !knowledgeCurrent ||
          !identical(knowledge, index) ||
          index?.ownsUnlinkedMention(mention) != true ||
          _repositorySwitching ||
          externalBusy ||
          generation != _activityGeneration ||
          dirty ||
          !isCurrent()) {
        throw StateError('현재 문서나 연결되지 않은 언급 목록이 바뀌었습니다.');
      }
    }

    try {
      await _serialize(() async {
        requireWrite();
        final workspace = WorkspaceStore(repo);
        final notes = await workspace.list(includeDeleted: true);
        VaultNote requireNote(String id, String markdownId) {
          final note = notes.where((note) => note.id == id).singleOrNull;
          if (note == null ||
              note.trashed ||
              note.deletionConflict ||
              note.revision.deleted ||
              note.markdownEntityId != markdownId ||
              note.revision.revisionId != expected[id]?.singleOrNull) {
            throw StateError('언급 원본 또는 연결 대상의 문서 판본이 바뀌었습니다.');
          }
          return note;
        }

        final sourceNote = requireNote(
          mention.sourceId,
          mention.sourceMarkdownEntityId,
        );
        final targetNote = requireNote(
          mention.targetId,
          mention.targetMarkdownEntityId,
        );
        final source = await workspace.open(sourceNote);
        final targetHeads = await repo.heads(targetNote.markdownEntityId);
        requireWrite();

        RevisionRecord requireMarkdown(
          VaultNote note,
          List<RevisionRecord> heads,
        ) {
          final head = heads.singleOrNull;
          if (head == null ||
              head.deleted ||
              head.kind != EntityKind.markdown ||
              head.ownerNoteId != note.id ||
              head.revisionId !=
                  expected[note.markdownEntityId]?.singleOrNull) {
            throw StateError('언급 원본 또는 연결 대상의 Markdown 판본이 바뀌었습니다.');
          }
          return head;
        }

        final revision = requireMarkdown(sourceNote, source.markdownHeads);
        requireMarkdown(targetNote, targetHeads);
        final bytes = await repo.readRevisionFile(revision, 'summary.md');
        requireWrite();
        final text = utf8.decode(bytes);
        final start = mention.start;
        final end = mention.end;
        if (start < 0 ||
            start >= end ||
            end > text.length ||
            text.substring(start, end) != mention.text) {
          throw StateError('언급의 원본 위치를 다시 확인하세요.');
        }
        final label = mention.text.replaceAllMapped(
          RegExp(r'[\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e]'),
          (match) => '\\${match[0]}',
        );
        final link = NoteLink.markdown(mention.targetId);
        final updated = text.replaceRange(start, end, '[$label]($link)');
        final hasBom =
            bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf;
        await source.saveMarkdown(
          hasBom ? '\uFEFF$updated' : updated,
          expectedHeads: expected,
          requireWrite: requireWrite,
        );
      });
    } finally {
      await _operationTail;
      if (_current(repo, session)) await refresh();
    }
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
      final originalPdf = PdfImportPreparation.applies(owner);
      final preparation = originalPdf ? _pdfPreparation : null;
      if (originalPdf && (_pdfImportCancelled || preparation == null))
        throw StateError(pdfImportError ?? 'PDF 원본을 먼저 확인하세요.');
      if (preparation?.peerPreview == true) {
        throw StateError('PDF 미리보기에서는 필기 판본을 저장할 수 없습니다.');
      }
      final files = await SaberInkAdapter.capture(core, pageIndex);
      if (preparation != null) {
        await preparation.validateCurrent(owner);
        if (!preparation.complete) {
          final containsPdf = core.pages.any(
            (page) =>
                page.backgroundImage is PdfEditorImage ||
                page.images.any((image) => image is PdfEditorImage),
          );
          final containsOriginal = files.entries
              .where((file) => file.key != 'main.sbn2')
              .any(
                (file) =>
                    sha256.convert(file.value).toString() ==
                    preparation.marker!.sourceSha256,
              );
          if (!containsPdf || !containsOriginal)
            throw StateError('PDF 가져오기가 아직 완료되지 않았습니다. 원본은 보존됩니다.');
        }
        files[PdfImportMarker.fileName] = preparation.marker!.encode();
      }
      final initialPdfImport = preparation != null && !preparation.complete;
      await owner.saveInk(
        files,
        initialPdfImport: initialPdfImport,
        expectedHeads: initialPdfImport
            ? {
                owner.note.id: [owner.note.revision.revisionId],
                owner.note.inkEntityId: owner.inkParents,
                preparation.marker!.sourceEntityId: [
                  preparation.marker!.sourceRevisionId,
                ],
              }
            : null,
      );
      if (preparation != null && identical(_pdfPreparation, preparation))
        _pdfPreparation = preparation.completed();
    });
  }

  Future<InfiniteDocument> loadInfinite({required NoteSession session}) async {
    if (session.inkParents.isEmpty)
      throw const FormatException('무한 노트의 저장본이 없습니다.');
    final revision = (await session.repository.revisions()).singleWhere(
      (r) => r.revisionId == session.inkParents.first,
    );
    final files = await session.repository.readFiles(revision);
    final bytes = files['infinite.json'];
    if (bytes == null) throw const FormatException('무한 노트 본문이 없습니다.');
    return InfiniteDocument.fromJson(
      jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
    );
  }

  Future<void> saveInfinite(
    InfiniteDocument document, {
    required NoteSession session,
  }) => _serialize(() async {
    if (!identical(session, activeSession))
      throw StateError('이 무한 노트는 이미 닫혔습니다.');
    await session.saveInk({
      'infinite.json': Uint8List.fromList(
        utf8.encode(jsonEncode(document.toJson())),
      ),
    });
  });

  Future<CardCanvasDocument> loadCardCanvas({
    required NoteSession session,
  }) async {
    if (session.inkParents.isEmpty)
      throw const FormatException('카드 캔버스 저장본이 없습니다.');
    final revision = (await session.repository.revisions()).singleWhere(
      (r) => r.revisionId == session.inkParents.first,
    );
    final files = await session.repository.readFiles(revision);
    final bytes = files['board.canvas'];
    if (bytes == null) throw const FormatException('카드 캔버스 본문이 없습니다.');
    return CardCanvasDocument.fromJson(
      jsonObject(jsonDecode(utf8.decode(bytes))),
    );
  }

  Future<void> saveCardCanvas(
    CardCanvasDocument document, {
    required NoteSession session,
  }) => _serialize(() async {
    if (!identical(session, activeSession))
      throw StateError('이 카드 캔버스는 이미 닫혔습니다.');
    await session.saveInk({
      'board.canvas': Uint8List.fromList(
        utf8.encode(jsonEncode(document.toJson())),
      ),
    });
  });

  Future<void> flush() async {
    await saveMarkdown();
    await _operationTail;
    if (dirty) throw StateError('필기 또는 가져오기 작업을 마친 뒤 저장을 다시 시도하세요.');
    await _persistNavigation();
  }

  void _requireStructuredSession(
    NoteRepository repo,
    NoteSession session, {
    VaultDocumentKind kind = VaultDocumentKind.page,
    bool writing = false,
    List<String>? selected,
  }) {
    if (!_current(repo, session) ||
        writing && _repositorySwitching ||
        !identical(session.repository, repo) ||
        session.note.documentKind != kind) {
      throw StateError('이 문서는 이미 닫혔거나 저장소가 바뀌었습니다.');
    }
    if (selected != null && !listEquals(session.inkParents, selected)) {
      throw StateError('문서를 읽는 동안 선택한 판본이 바뀌었습니다.');
    }
  }

  Future<Map<String, Uint8List>> _structuredFiles(
    NoteRepository repo,
    NoteSession session, {
    VaultDocumentKind kind = VaultDocumentKind.page,
  }) async {
    _requireStructuredSession(repo, session, kind: kind);
    final selected = List<String>.of(session.inkParents);
    if (selected.length != 1) {
      throw const FormatException('문서 본문 판본을 먼저 선택하세요.');
    }
    final records = (await repo.revisions())
        .where((record) => record.revisionId == selected.single)
        .toList();
    _requireStructuredSession(repo, session, kind: kind);
    if (!listEquals(session.inkParents, selected)) {
      throw StateError('문서를 읽는 동안 선택한 판본이 바뀌었습니다.');
    }
    if (records.length != 1) {
      throw const FormatException('문서 본문 판본이 없습니다.');
    }
    final revision = records.single;
    if (revision.vaultId != repo.vaultId ||
        revision.entityId != session.note.inkEntityId ||
        revision.ownerNoteId != session.note.id ||
        revision.kind != EntityKind.ink ||
        revision.deleted) {
      throw const FormatException('이 문서에 속한 본문 판본이 아닙니다.');
    }
    final files = await repo.readFiles(revision);
    _requireStructuredSession(repo, session, kind: kind);
    if (!listEquals(session.inkParents, selected)) {
      throw StateError('문서를 읽는 동안 선택한 판본이 바뀌었습니다.');
    }
    return files;
  }

  Future<BlockPageMediaSnapshot> loadBlockPageSnapshot({
    required NoteSession session,
  }) async {
    final repo = repository;
    _requireStructuredSession(repo, session);
    final selected = List<String>.of(session.inkParents);
    final files = await _structuredFiles(repo, session);
    _requireStructuredSession(repo, session, selected: selected);
    final snapshot = await decodeBlockPageMediaInWorker(files);
    _requireStructuredSession(repo, session, selected: selected);
    return snapshot;
  }

  Future<BlockPageDocument> loadBlockPage({
    required NoteSession session,
  }) async => (await loadBlockPageSnapshot(session: session)).document;

  Future<Uint8List> readBlockPageMedia(
    BlockPageMedia media, {
    required NoteSession session,
  }) async {
    final repo = repository;
    _requireStructuredSession(repo, session);
    final selected = List<String>.of(session.inkParents);
    final files = await _structuredFiles(repo, session);
    _requireStructuredSession(repo, session, selected: selected);
    final body = files['page.json'];
    if (body == null) throw const FormatException('페이지 본문이 없습니다.');
    BlockPageDocument.fromJson(jsonObject(jsonDecode(utf8.decode(body))));
    final bytes = files[media.path];
    if (bytes == null) {
      throw const FormatException('이 페이지 판본에 첨부 파일이 없습니다.');
    }
    await verifyBlockPageMediaBytes(media, bytes);
    _requireStructuredSession(repo, session, selected: selected);
    return Uint8List.fromList(bytes);
  }

  Future<void> saveBlockPage(
    BlockPageDocument document, {
    required NoteSession session,
    Map<String, Uint8List> mediaFiles = const {},
  }) async {
    final repo = repository;
    _requireStructuredSession(repo, session, writing: true);
    final selected = List<String>.of(session.inkParents);
    final added = mediaFiles.map(
      (path, bytes) => MapEntry(path, Uint8List.fromList(bytes)),
    );
    return _serialize(() async {
      _requireStructuredSession(
        repo,
        session,
        writing: true,
        selected: selected,
      );
      final existing = await _structuredFiles(repo, session);
      _requireStructuredSession(
        repo,
        session,
        writing: true,
        selected: selected,
      );
      final snapshot = await prepareBlockPageMediaInWorker(
        document,
        existingFiles: existing,
        addedFiles: added,
      );
      _requireStructuredSession(
        repo,
        session,
        writing: true,
        selected: selected,
      );
      await session.saveInk(snapshot.files);
      _requireStructuredSession(repo, session, writing: true);
    });
  }

  Future<BlockPageHistorySnapshot> blockPageHistory({
    required NoteSession session,
  }) => _serialize(() async {
    final repo = repository;
    if (!_current(repo, session) || dirty)
      throw StateError('현재 페이지를 저장한 뒤 이력을 여세요.');
    final history = await BlockPageHistorySnapshot.read(session);
    if (!_current(repo, session) || !history.belongsTo(session))
      throw StateError('이력을 읽는 동안 페이지가 바뀌었습니다.');
    return history;
  });

  Future<void> restoreBlockPageRevision(
    BlockPageHistorySnapshot history,
    RevisionRecord chosen, {
    required NoteSession session,
  }) => _serialize(() async {
    final repo = repository;
    if (!_current(repo, session) || dirty || !history.belongsTo(session))
      throw StateError('현재 페이지를 저장하고 이력을 다시 여세요.');
    await session.restoreInkRevision(
      chosen,
      expectedHeadRevisionIds: history.expectedHeadRevisionIds,
      expectedHeads: history.expectedHeads,
    );
    if (!_current(repo, session) || !history.belongsTo(session))
      throw StateError('복원 중 페이지가 바뀌었습니다. 저장 이력을 확인하세요.');
    editorGeneration++;
    await refresh();
  });

  Future<DatabaseHistorySnapshot> databaseHistory({
    required NoteSession session,
  }) => _serialize(() async {
    final repo = repository;
    _requireStructuredSession(repo, session, kind: VaultDocumentKind.database);
    if (dirty) throw StateError('데이터베이스를 저장한 뒤 이력을 여세요.');
    final history = await DatabaseHistorySnapshot.read(session);
    if (!_current(repo, session) ||
        dirty ||
        !history.belongsTo(session) ||
        !listEquals(session.inkParents, [history.currentRevision.revisionId])) {
      throw StateError('이력을 읽는 동안 데이터베이스가 바뀌었습니다.');
    }
    return history;
  });

  Future<void> restoreDatabaseRevision(
    DatabaseHistorySnapshot history,
    RevisionRecord chosen, {
    required NoteSession session,
  }) => _serialize(() async {
    final repo = repository;
    void requireWrite() {
      _requireStructuredSession(
        repo,
        session,
        kind: VaultDocumentKind.database,
        writing: true,
      );
      if (dirty || !history.belongsTo(session)) {
        throw StateError('데이터베이스를 저장하고 이력을 다시 여세요.');
      }
    }

    requireWrite();
    final engine = native;
    await history.restore(
      chosen,
      requireWrite: requireWrite,
      validateActions: engine == null
          ? null
          : DatabaseActionRuntime(
              deviceId: repo.deviceId,
              invoke: engine.invoke,
            ).validate,
    );
    if (!_current(repo, session)) {
      throw StateError('복원 중 데이터베이스가 바뀌었습니다. 저장 이력을 확인하세요.');
    }
    editorGeneration++;
    await refresh();
  });

  Future<DatabaseMediaSnapshot> loadDatabaseSnapshot({
    required NoteSession session,
  }) async {
    final repo = repository;
    _requireStructuredSession(repo, session, kind: VaultDocumentKind.database);
    final selected = List<String>.of(session.inkParents);
    final files = await _structuredFiles(
      repo,
      session,
      kind: VaultDocumentKind.database,
    );
    _requireStructuredSession(
      repo,
      session,
      kind: VaultDocumentKind.database,
      selected: selected,
    );
    final snapshot = await decodeDatabaseMediaInWorker(files);
    _requireStructuredSession(
      repo,
      session,
      kind: VaultDocumentKind.database,
      selected: selected,
    );
    return snapshot;
  }

  Future<WorkspaceDatabase> loadDatabase({
    required NoteSession session,
  }) async => (await loadDatabaseSnapshot(session: session)).database;

  void _requireLinkedOwner(
    NoteRepository repo,
    NoteSession owner, {
    bool writing = false,
  }) {
    _requireStructuredSession(repo, owner, writing: writing);
    if (owner.note.trashed || owner.note.deletionConflict) {
      throw StateError('연결된 데이터베이스를 사용할 페이지가 삭제되었습니다.');
    }
  }

  void _requireLinkedSession(
    NoteRepository repo,
    LinkedDatabaseSession link, {
    bool writing = false,
    List<String>? selected,
  }) {
    _requireLinkedOwner(repo, link.owner, writing: writing);
    if (link.isClosed ||
        !identical(link.repository, repo) ||
        !identical(link.target.repository, repo) ||
        link.editorGeneration != editorGeneration ||
        link.owner.note.id != link.ownerNoteId ||
        link.owner.note.inkEntityId != link.ownerInkEntityId ||
        link.target.note.id != link.source.id ||
        link.target.note.inkEntityId != link.source.inkEntityId ||
        link.target.note.markdownEntityId != link.source.markdownEntityId ||
        link.target.note.documentKind != VaultDocumentKind.database ||
        link.target.inkParents.length != 1 ||
        selected != null && !listEquals(link.target.inkParents, selected)) {
      throw StateError('이 연결된 데이터베이스는 닫혔거나 읽은 판본이 바뀌었습니다.');
    }
  }

  Future<void> _requireLinkedHeads(
    NoteRepository repo,
    Map<String, List<String>> guards,
  ) async {
    for (final entry in guards.entries) {
      final heads = await repo.heads(entry.key);
      if (heads.length != entry.value.length ||
          heads.any((head) => head.deleted) ||
          !setEquals(
            heads.map((head) => head.revisionId).toSet(),
            entry.value.toSet(),
          )) {
        throw StateError('원본 데이터베이스나 폴더가 바뀌었습니다. 다시 연결해서 여세요.');
      }
    }
  }

  Future<LinkedDatabaseSession> openLinkedDatabase(
    String noteId, {
    required NoteSession owner,
  }) async {
    validateId(noteId);
    final repo = repository;
    _requireLinkedOwner(repo, owner);
    final generation = editorGeneration;
    void requireOwner() {
      _requireLinkedOwner(repo, owner);
      if (generation != editorGeneration) {
        throw StateError('데이터베이스를 읽는 동안 페이지가 바뀌었습니다.');
      }
    }

    final metadata = await repo.heads(noteId);
    requireOwner();
    if (metadata.length != 1 ||
        metadata.single.deleted ||
        metadata.single.kind != EntityKind.metadata ||
        metadata.single.vaultId != repo.vaultId) {
      throw StateError('원본 데이터베이스가 없거나 삭제·충돌 상태입니다.');
    }
    final metadataFiles = await repo.readFiles(metadata.single);
    requireOwner();
    final bytes = metadataFiles['note.json'];
    if (bytes == null) throw const FormatException('데이터베이스 정보가 없습니다.');
    final json = jsonObject(jsonDecode(utf8.decode(bytes)));
    if (json['documentKind'] != VaultDocumentKind.database.name) {
      throw StateError('선택한 문서가 데이터베이스가 아닙니다.');
    }
    final ink = json['inkEntityId'], markdown = json['markdownEntityId'];
    if (ink is! String || markdown is! String || json['title'] is! String) {
      throw const FormatException('데이터베이스 정보가 올바르지 않습니다.');
    }
    validateId(ink);
    validateId(markdown);
    final rawFolder = json['folderId'];
    if (rawFolder != null && rawFolder is! String) {
      throw const FormatException('데이터베이스 폴더 정보가 올바르지 않습니다.');
    }
    final guards = <String, List<String>>{
      noteId: [metadata.single.revisionId],
    };
    var folderId = rawFolder as String?;
    while (folderId != null) {
      validateId(folderId);
      if (guards.containsKey(folderId) || guards.length > 64) {
        throw const FormatException('데이터베이스 폴더 계층이 올바르지 않습니다.');
      }
      final heads = await repo.heads(folderId);
      requireOwner();
      if (heads.length != 1 ||
          heads.single.deleted ||
          heads.single.kind != EntityKind.folder ||
          heads.single.vaultId != repo.vaultId) {
        throw StateError('데이터베이스 폴더가 없거나 삭제·충돌 상태입니다.');
      }
      final files = await repo.readFiles(heads.single);
      requireOwner();
      final folderBytes = files['folder.json'];
      if (folderBytes == null) throw const FormatException('폴더 정보가 없습니다.');
      final folder = jsonObject(jsonDecode(utf8.decode(folderBytes)));
      final parent = folder['parentId'];
      if (folder['title'] is! String || parent != null && parent is! String) {
        throw const FormatException('데이터베이스 폴더 정보가 올바르지 않습니다.');
      }
      guards[folderId] = [heads.single.revisionId];
      folderId = parent as String?;
    }
    final heads = await repo.heads(ink);
    requireOwner();
    if (heads.length != 1 ||
        heads.single.deleted ||
        heads.single.kind != EntityKind.ink ||
        heads.single.ownerNoteId != noteId ||
        heads.single.vaultId != repo.vaultId) {
      throw StateError('데이터베이스 본문이 없거나 삭제·충돌 상태입니다.');
    }
    final files = await repo.readFiles(heads.single);
    requireOwner();
    final snapshot = await decodeDatabaseMediaInWorker(files);
    requireOwner();
    final markdownHeads = await repo.heads(markdown);
    requireOwner();
    await _requireLinkedHeads(repo, {
      ...guards,
      ink: [heads.single.revisionId],
      owner.note.id: [owner.note.revision.revisionId],
    });
    requireOwner();
    final note = VaultNote(
      noteId,
      json['title'] as String,
      ink,
      markdown,
      metadata.single,
      folderId: rawFolder,
      documentKind: VaultDocumentKind.database,
      metadata: json,
    );
    return LinkedDatabaseSession.create(
      owner: owner,
      target: NoteSession(repo, note, heads, markdownHeads),
      database: snapshot.database,
      editorGeneration: generation,
      metadataHeads: guards,
    );
  }

  Future<Map<String, Uint8List>> _linkedDatabaseFiles(
    NoteRepository repo,
    LinkedDatabaseSession link,
    List<String> selected,
  ) async {
    _requireLinkedSession(repo, link, selected: selected);
    final records = (await repo.revisions()).where(
      (record) => record.revisionId == selected.single,
    );
    _requireLinkedSession(repo, link, selected: selected);
    if (records.length != 1) {
      throw const FormatException('데이터베이스 본문 판본이 없습니다.');
    }
    final revision = records.single;
    if (revision.vaultId != repo.vaultId ||
        revision.entityId != link.source.inkEntityId ||
        revision.ownerNoteId != link.source.id ||
        revision.kind != EntityKind.ink ||
        revision.deleted) {
      throw const FormatException('이 데이터베이스에 속한 본문 판본이 아닙니다.');
    }
    final files = await repo.readFiles(revision);
    _requireLinkedSession(repo, link, selected: selected);
    return files;
  }

  Future<void> saveLinkedDatabase(
    LinkedDatabaseSession link,
    WorkspaceDatabase database, {
    Map<String, Uint8List> mediaFiles = const {},
  }) async {
    final repo = repository;
    _requireLinkedSession(repo, link, writing: true);
    final observed = List<String>.of(link.target.inkParents);
    final added = mediaFiles.map(
      (path, bytes) => MapEntry(path, Uint8List.fromList(bytes)),
    );
    return _serialize(() async {
      _requireLinkedSession(repo, link, writing: true, selected: observed);
      if (database.id != link.database.id ||
          !const DeepCollectionEquality().equals(
            database.views.map((view) => view.toJson()).toList(),
            link.database.views.map((view) => view.toJson()).toList(),
          )) {
        throw const FormatException('연결된 보기의 설정은 원본 데이터베이스를 바꿀 수 없습니다.');
      }
      final pending = link.pendingSnapshot;
      if (pending != null) {
        await _publishLinkedDatabase(repo, link, pending, link.pendingHeads!);
      }
      final selected = List<String>.of(link.target.inkParents);
      void requireWrite() =>
          _requireLinkedSession(repo, link, writing: true, selected: selected);
      requireWrite();
      final metadataHeads = {
        ...link.metadataHeads,
        link.owner.note.id: [link.owner.note.revision.revisionId],
      };
      await _requireLinkedHeads(repo, metadataHeads);
      requireWrite();
      final existing = await _linkedDatabaseFiles(repo, link, selected);
      requireWrite();
      final snapshot = await prepareDatabaseMediaInWorker(
        database,
        existingFiles: existing,
        addedFiles: added,
      );
      requireWrite();
      final guards = {...metadataHeads, link.source.inkEntityId: selected};
      final files = snapshot.files;
      if (files.length == existing.length &&
          files.entries.every(
            (entry) =>
                existing.containsKey(entry.key) &&
                listEquals(entry.value, existing[entry.key]),
          )) {
        await _requireLinkedHeads(repo, guards);
        requireWrite();
        link.saved(database);
        return;
      }
      await _publishLinkedDatabase(repo, link, snapshot, guards);
    });
  }

  Future<void> _publishLinkedDatabase(
    NoteRepository repo,
    LinkedDatabaseSession link,
    DatabaseMediaSnapshot snapshot,
    Map<String, List<String>> guards,
  ) async {
    final selected = guards[link.source.inkEntityId]!;
    void requireWrite() =>
        _requireLinkedSession(repo, link, writing: true, selected: selected);
    requireWrite();
    await _requireLinkedHeads(repo, {
      for (final entry in guards.entries)
        if (entry.key != link.source.inkEntityId) entry.key: entry.value,
    });
    requireWrite();
    link.stageSave(snapshot, guards);
    await link.target.saveInk(
      snapshot.files,
      expectedHeads: guards,
      requireWrite: requireWrite,
    );
    _requireLinkedSession(repo, link, writing: true);
    if (listEquals(link.target.inkParents, selected)) {
      throw StateError('원본에 더 새로운 판본이 있습니다. 연결된 데이터베이스를 다시 여세요.');
    }
    link.saved(snapshot.database);
  }

  Future<Uint8List> readLinkedDatabaseRowMedia(
    LinkedDatabaseSession link,
    String rowId,
    BlockPageMedia media,
  ) async {
    final repo = repository;
    _requireLinkedSession(repo, link);
    validateId(rowId);
    final selected = List<String>.of(link.target.inkParents);
    final guards = {
      ...link.metadataHeads,
      link.source.inkEntityId: selected,
      link.owner.note.id: [link.owner.note.revision.revisionId],
    };
    await _requireLinkedHeads(repo, guards);
    _requireLinkedSession(repo, link, selected: selected);
    final files = await _linkedDatabaseFiles(repo, link, selected);
    final snapshot = await decodeDatabaseMediaInWorker(files);
    _requireLinkedSession(repo, link, selected: selected);
    final rows = snapshot.database.rows.where((row) => row.id == rowId);
    if (rows.length != 1 || rows.single.archived) {
      throw StateError('데이터베이스 행이 삭제되었거나 보관되었습니다.');
    }
    final body = BlockPageDocument.fromJson(rows.single.body);
    if (!body.media.values.any(
      (reference) =>
          jsonEncode(reference.toJson()) == jsonEncode(media.toJson()),
    )) {
      throw const FormatException('이 행에 등록된 첨부 파일이 아닙니다.');
    }
    final bytes = files[media.path];
    if (bytes == null) throw const FormatException('첨부 파일이 없습니다.');
    await verifyBlockPageMediaBytes(media, bytes);
    await _requireLinkedHeads(repo, guards);
    _requireLinkedSession(repo, link, selected: selected);
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List> readDatabaseRowMedia(
    String rowId,
    BlockPageMedia media, {
    required NoteSession session,
  }) async {
    final repo = repository;
    _requireStructuredSession(repo, session, kind: VaultDocumentKind.database);
    validateId(rowId);
    final selected = List<String>.of(session.inkParents);
    final files = await _structuredFiles(
      repo,
      session,
      kind: VaultDocumentKind.database,
    );
    _requireStructuredSession(
      repo,
      session,
      kind: VaultDocumentKind.database,
      selected: selected,
    );
    final snapshot = await decodeDatabaseMediaInWorker(files);
    _requireStructuredSession(
      repo,
      session,
      kind: VaultDocumentKind.database,
      selected: selected,
    );
    final bytes = files[media.path];
    if (bytes == null) {
      throw const FormatException('이 데이터베이스 판본에 첨부 파일이 없습니다.');
    }
    await verifyBlockPageMediaBytes(media, bytes);
    _requireStructuredSession(
      repo,
      session,
      kind: VaultDocumentKind.database,
      selected: selected,
    );
    final rows = snapshot.database.rows.where((row) => row.id == rowId);
    if (rows.length != 1 || rows.single.archived) {
      throw StateError('이 데이터베이스 행은 삭제되었거나 보관되었습니다.');
    }
    return Uint8List.fromList(bytes);
  }

  Future<void> saveDatabase(
    WorkspaceDatabase database, {
    required NoteSession session,
    Map<String, Uint8List> mediaFiles = const {},
  }) async {
    final repo = repository;
    _requireStructuredSession(
      repo,
      session,
      kind: VaultDocumentKind.database,
      writing: true,
    );
    final selected = List<String>.of(session.inkParents);
    final added = mediaFiles.map(
      (path, bytes) => MapEntry(path, Uint8List.fromList(bytes)),
    );
    return _serialize(() async {
      _requireStructuredSession(
        repo,
        session,
        kind: VaultDocumentKind.database,
        writing: true,
        selected: selected,
      );
      final existing = await _structuredFiles(
        repo,
        session,
        kind: VaultDocumentKind.database,
      );
      _requireStructuredSession(
        repo,
        session,
        kind: VaultDocumentKind.database,
        writing: true,
        selected: selected,
      );
      final snapshot = await prepareDatabaseMediaInWorker(
        database,
        existingFiles: existing,
        addedFiles: added,
      );
      _requireStructuredSession(
        repo,
        session,
        kind: VaultDocumentKind.database,
        writing: true,
        selected: selected,
      );
      await session.saveInk(snapshot.files);
      _requireStructuredSession(
        repo,
        session,
        kind: VaultDocumentKind.database,
        writing: true,
      );
    });
  }

  Future<T> externalMutation<T>(
    Future<T> Function(NoteRepository) operation,
  ) async {
    var started = false;
    T? result;
    Object? failure;
    StackTrace? failureTrace;
    try {
      result = await _serialize(() async {
        if (dirty) throw StateError('현재 문서를 저장한 뒤 외부 편집을 다시 시도하세요.');
        externalBusy = true;
        _externalMutations++;
        started = true;
        if (!_disposed) notifyListeners();
        return await operation(repository);
      });
    } catch (error, trace) {
      failure = error;
      failureTrace = trace;
    }
    if (started) {
      try {
        await _operationTail;
        await refresh();
      } catch (error, trace) {
        if (failure == null) {
          failure = error;
          failureTrace = trace;
        }
      } finally {
        _externalMutations--;
        externalBusy = _externalMutations != 0;
        if (!_disposed) notifyListeners();
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureTrace!);
    return result as T;
  }

  Future<EditorCoreInfo> loadInk({NoteSession? session}) async {
    final owner = session ?? activeSession!;
    final repo = owner.repository;
    final pendingPdf =
        identical(owner, activeSession) &&
        (pendingPdfPath != null || pdfPeerPreviewPath != null);
    if (PdfImportPreparation.applies(owner) &&
        identical(owner, activeSession) &&
        pdfImportError != null)
      throw StateError(pdfImportError!);
    if (owner.inkParents.isEmpty && pendingPdf) {
      return EditorCoreInfo(filePath: '/.working/${owner.note.id}/new/main')
        ..pages.add(EditorPage());
    }
    if (owner.inkParents.isEmpty)
      throw const FormatException('완전한 필기 snapshot이 없습니다.');
    final revision = (await repo.revisions()).singleWhere(
      (r) => r.revisionId == owner.inkParents.first,
    );
    final core = await SaberInkAdapter.load(repo, revision);
    if (pendingPdf && (core.pages.isEmpty || core.pages.last.isNotEmpty))
      core.pages.add(EditorPage());
    return core;
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
    _automations?.dispose();
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
