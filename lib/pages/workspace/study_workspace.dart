import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show BytesBuilder;
import 'dart:ui' show ImageByteFormat;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart' show PdfDocument, PdfImage, PdfImageExt;
import 'package:saber/components/drive/drive_panel.dart';
import 'package:saber/data/app_external_screen.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/imports/android_document_source.dart';
import 'package:saber/data/imports/android_obsidian_folder.dart';
import 'package:saber/data/imports/image_capture.dart';
import 'package:saber/data/imports/image_note_importer.dart';
import 'package:saber/data/imports/shared_document_queue.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_render.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/pdf_note_original.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/card_canvas_raster.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/database_automation_coordinator.dart';
import 'package:saber/data/vault/database_query_native.dart';
import 'package:saber/data/vault/dataview.dart';
import 'package:saber/data/vault/dataview_query.dart';
import 'package:saber/data/vault/dataview_result.dart';
import 'package:saber/data/vault/discussion_anchor.dart';
import 'package:saber/data/vault/discussion_store.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/obsidian_vault_export.dart';
import 'package:saber/data/vault/obsidian_vault_import.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/pdf_import_state.dart' show PdfTextSearchHit;
import 'package:saber/data/vault/portable_document_export.dart';
import 'package:saber/data/vault/portable_document_pdf.dart';
import 'package:saber/data/vault/synced_block_store.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_bookmarks.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_markdown_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_workspace.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/block_page_history_sheet.dart';
import 'package:saber/pages/workspace/card_canvas.dart';
import 'package:saber/pages/workspace/daily_note_template_settings_dialog.dart';
import 'package:saber/pages/workspace/database_editor.dart';
import 'package:saber/pages/workspace/database_history_sheet.dart';
import 'package:saber/pages/workspace/infinite_canvas.dart';
import 'package:saber/pages/workspace/knowledge_panel.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/linked_database_block.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/page_discussion_sheet.dart';
import 'package:saber/pages/workspace/pdf_text_search_dialog.dart';
import 'package:saber/pages/workspace/portable_export_capture.dart';
import 'package:saber/pages/workspace/synced_block_view.dart';
import 'package:saber/pages/workspace/workspace_bookmark_sheet.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';
import 'package:saber/pages/workspace/workspace_quick_switcher.dart';
import 'package:saber/pages/workspace/workspace_tab_switcher.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';

export 'workspace_controller.dart';

typedef _VaultMarkdownScope = (
  NoteRepository,
  NoteSession,
  KnowledgeIndex?,
  int,
);

Uint8List _encodeObsidianCanvasZip(PortableExportBundle bundle) {
  final bytes = bundle.toZip();
  if (bytes.length > obsidianVaultZipMaxBytes) {
    throw const FormatException(
      'Obsidian Canvas ZIP은 최대 128 MiB까지 내보낼 수 있습니다.',
    );
  }
  return bytes;
}

Uint8List _encodeObsidianVaultZip(
  ({Map<String, Uint8List> files, List<String> folders}) data,
) => encodeObsidianVaultZip(files: data.files, folders: data.folders);

class _WorkspaceToolbarAction {
  const new(this.label, this.icon, this.onPressed, {this.key});

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final Key? key;

  IconButton button() => IconButton(
    key: key,
    tooltip: label,
    icon: Icon(icon),
    onPressed: onPressed,
  );
}

class _DocumentNameDialog extends StatefulWidget {
  final String title;
  final String initial;
  const new({required this.title, required this.initial});
  @override
  State<_DocumentNameDialog> createState() => _DocumentNameDialogState();
}

class _DocumentNameDialogState extends State<_DocumentNameDialog> {
  late final _text = TextEditingController(text: widget.initial);
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: _text,
      autofocus: true,
      onSubmitted: (value) => Navigator.pop(context, value),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text),
        child: const Text('확인'),
      ),
    ],
  );
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}

enum _OfficeImportMode { pdf, office }

class StudyWorkspace extends StatefulWidget {
  static final pendingDocumentImport = SharedDocumentInbox();
  final WorkspaceController? controller;
  final bool enableDrive;
  final DriveConnectionController Function(WorkspaceController)?
  createDriveConnection;
  final ThumbnailCache Function(Directory) thumbnailCacheFactory;
  final OfficePreviewEngine? officePreviewEngine;
  const new({
    super.key,
    this.controller,
    this.enableDrive = false,
    this.createDriveConnection,
    this.thumbnailCacheFactory = ThumbnailCache.new,
    this.officePreviewEngine,
  });
  @override
  State<StudyWorkspace> createState() => _StudyWorkspaceState();
}

typedef _LibrarySelectionScope = (NoteRepository, String?, bool);
typedef _RelatedDatabaseSource = ({
  VaultNote note,
  WorkspaceDatabase database,
  RevisionRecord body,
});

class _StudyWorkspaceState extends State<StudyWorkspace>
    with WidgetsBindingObserver, WindowListener {
  WorkspaceController? controller;
  DriveConnectionController? _driveConnection;
  NoteRepository? _driveRepository;
  McpAccessController? _mcp;
  NoteRepository? _mcpRepository;
  final _scaffold = GlobalKey<ScaffoldState>();
  _LibrarySelectionScope? _librarySelection;
  var _editor = GlobalKey<EditorState>();
  var _infinite = GlobalKey<InfiniteCanvasState>();
  var _office = GlobalKey<OfficeWorkspaceState>();
  var _cards = GlobalKey<CardCanvasState>();
  var _page = GlobalKey<BlockPageEditorState>();
  var _database = GlobalKey<DatabaseEditorState>();
  Future<(WorkspaceDatabase, List<BlockPageNote>)>? _databaseContents;
  Future<Map<String, _RelatedDatabaseSource>>? _relatedDatabases;
  var _relatedEpoch = -1;
  Future<(BlockPageDocument, List<BlockPageNote>, List<BlockPageNote>)>?
  _pageContents;
  LinkedDatabaseAccess? _linkedDatabaseAccess;
  SyncedBlockAccess? _syncedBlockAccess;
  Future<(CardCanvasDocument, List<CardCanvasNote>)>? _cardContents;
  (NoteRepository, NoteSession, int, CardCanvasRasterReader)? _cardRaster;
  Future<InfiniteDocument>? _infiniteDocument;
  final _thumbnails = <String, ImageProvider>{};
  NoteRepository? _thumbnailRepository;
  ThumbnailCache? _thumbnailCache;
  final _thumbnailKeys = <String, String>{};
  final _thumbnailAttempts = <String, (String?, int)>{};
  final _thumbnailRequests = <(ThumbnailCache, String)>{};
  final _retiringThumbnailWrites = <Future<void>>{};
  String? _editorIdentity;
  // The PDF note whose kept Office/HWP original was looked up, and whether it keeps one.
  (NoteRepository, String)? _keptOriginalLookup;
  var _keptOriginal = false;
  String? _pendingPdf;
  Object? _pendingPdfScope;
  String? _targetPage;
  ({NoteSession session, OfficePageLinkRequest request})? _officePageLink;
  NoteSession? _rememberedPageSession;
  ({NoteRepository repository, NoteSession? outgoing})? _documentTabChange;
  var _markdownAnchorRequest = 0;
  var _searchSelectionRequest = 0;
  ({NoteSession session, KnowledgeBodyMatch match})? _searchSelection;
  (WorkspaceController, _VaultMarkdownScope, MarkdownDataviewAccess)? _dataview;
  String? _startupError;
  String? _closeError;
  var markdownTab = false;
  var busy = false;
  var _exporting = false;
  final _sharedDocumentOwner = Object();
  Object? _sharedDocumentScope;
  Timer? _sharedDocumentTimer;
  var _sharedDocumentProcessing = false;
  var _sharedDocumentClosing = false;
  DatabaseAutomationCoordinator? _automation;
  NoteRepository? _automationRepository;
  var _automationForeground = true;
  Future<void>? _workspaceSave;
  var _driveLifecycleGeneration = 0;
  AppLifecycleState? _appliedLifecycle;
  Timer? _externalScreenGrace;
  static final _importLog = Logger('PIVImport');
  @override
  void initState() {
    super.initState();
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _automationForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _appliedLifecycle = lifecycle ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    AppExternalScreen.open.addListener(_externalScreenChanged);
    if (Platform.isWindows) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    StudyWorkspace.pendingDocumentImport.addListener(_sharedDocument);
    unawaited(_init());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sharedDocument();
  }

  Future<void> _init() async {
    try {
      final value =
          widget.controller ?? await WorkspaceController.openDefault();
      if (!mounted) {
        if (widget.controller == null) value.dispose();
        return;
      }
      controller = value;
      _mcp = McpAccessController(
        () {
          _mcpRepository = value.repository;
          return VaultMcpService(
            value,
            prepareMutation: _prepareMcpEdit,
            onOpenNote: _openMcpDocument,
            bodyValidators: {
              'canvas': (body) => CardCanvasDocument.fromJson(body).toJson(),
              'page': (body) => BlockPageDocument.fromJson(body).toJson(),
              'database': (body) => WorkspaceDatabase.fromJson(body).toJson(),
            },
          );
        },
        createExtraHandlers: () {
          final repo = value.repository;
          return {
            'render_page': (_, arguments, context) async {
              if (!identical(repo, value.repository))
                throw const VaultMcpException(
                  'vault_changed',
                  '연결된 저장소가 바뀌었습니다.',
                );
              final result = await renderVaultMcpPage(repo, arguments, context);
              if (!identical(repo, value.repository))
                throw const VaultMcpException(
                  'vault_changed',
                  '연결된 저장소가 바뀌었습니다.',
                );
              return result;
            },
          };
        },
      );
      markdownTab = value.navigation.current.markdown;
      _targetPage = value.navigation.current.pageId;
      _rememberedPageSession = value.activeSession;
      value.addListener(_changed);
      final createDriveConnection = widget.createDriveConnection;
      if (widget.enableDrive || createDriveConnection != null) {
        final drive = _driveConnection =
            createDriveConnection?.call(value) ??
            DriveConnectionController(
              repository: () => value.repository,
              onRepositoryChanged: value.replaceRepository,
              onRemoteUpdated: value.refresh,
              onResumeReload: value.reloadFromDisk,
            );
        _driveRepository = value.repository;
        if (!_automationForeground) unawaited(drive.setForeground(false));
        unawaited(drive.initialize());
      }
      if (value.native != null) {
        _automationRepository = value.repository;
        _automation = value.createAutomationCoordinator(
          canRun: () => mounted && !busy && _automationForeground,
        );
        _automation!.start();
      }
      setState(() {});
      _invalidateThumbnailScope();
      _sharedDocument();
    } catch (e) {
      if (mounted) setState(() => _startupError = '$e');
    }
  }

  void _changed() {
    if (mounted) {
      final c = controller;
      if (c == null ||
          c.activeSession != null ||
          _librarySelection != _librarySelectionScope(c)) {
        _librarySelection = null;
      }
      if (_driveConnection case final drive?) {
        final current = c?.repository;
        if (current != null && !identical(_driveRepository, current)) {
          _driveRepository = current;
          unawaited(drive.repositoryChanged());
        }
      }
      if (c != null) _applyDocumentTabView(c);
      if (c != null &&
          _pendingPdf != null &&
          _pendingPdfScope != null &&
          _pendingPdfScope != _sharedScope(c.repository)) {
        _pendingPdf = null;
        _pendingPdfScope = null;
      }
      if (_officePageLink case final pending?) {
        if (!identical(c?.activeSession, pending.session) ||
            !identical(c?.repository, pending.request.repository)) {
          _officePageLink = null;
        }
      }
      if (_automation != null &&
          !identical(_automationRepository, c?.repository)) {
        _automationRepository = c?.repository;
        _automation!.invalidate();
      }
      if (c != null &&
          c.activeSession?.note.documentKind == VaultDocumentKind.database &&
          _relatedEpoch != c.repositoryGeneration) {
        _relatedEpoch = c.repositoryGeneration;
        _relatedDatabases = _loadRelatedDatabases(c.repository);
      }
      if (_mcp?.connected == true &&
          !identical(_mcpRepository, controller?.repository)) {
        unawaited(
          _mcp!.stop().catchError((Object _) {
            controller?.error = 'AI 연결을 종료했습니다. 연결 설정 파일의 정리는 다시 확인하세요.';
          }),
        );
      }
      setState(() {});
      _invalidateThumbnailScope();
      _sharedDocument();
    }
  }

  Future<void> _prepareMcpEdit() async {
    if (!mounted || busy || controller!.externalBusy)
      throw StateError('앱의 현재 작업이 끝난 뒤 다시 시도하세요.');
    setState(() => busy = true);
    try {
      await _save();
    } finally {
      _finishBusy();
    }
  }

  Future<void> _openMcpDocument(String id) async {
    if (!mounted || busy || controller!.externalBusy)
      throw StateError('앱의 현재 작업이 끝난 뒤 다시 시도하세요.');
    setState(() => busy = true);
    try {
      await _openTab(id);
    } finally {
      _finishBusy();
    }
  }

  Future<(CardCanvasDocument, List<CardCanvasNote>)> _loadCardContents(
    WorkspaceController c,
    NoteSession session,
  ) async {
    final document = await c.loadCardCanvas(session: session);
    final notes = await c.store.list();
    return (
      document,
      [
        for (final note in notes)
          CardCanvasNote(
            note.id,
            note.title,
            isRaster: note.documentKind == VaultDocumentKind.image,
          ),
      ],
    );
  }

  CardCanvasRasterReader? _cardRasterReader(
    WorkspaceController c,
    NoteSession session,
  ) {
    final native = c.native;
    if (native == null) return null;
    final repository = c.repository;
    final generation = c.repositoryGeneration;
    final current = _cardRaster;
    if (current != null &&
        identical(current.$1, repository) &&
        identical(current.$2, session) &&
        current.$3 == generation) {
      return current.$4;
    }
    final reader = CardCanvasRasterReader(
      repository,
      native: native,
      isCurrent: () =>
          mounted &&
          identical(controller, c) &&
          identical(c.repository, repository) &&
          identical(c.activeSession, session) &&
          c.repositoryGeneration == generation,
    );
    _cardRaster = (repository, session, generation, reader);
    return reader;
  }

  Future<(BlockPageDocument, List<BlockPageNote>, List<BlockPageNote>)>
  _loadPageContents(WorkspaceController c, NoteSession session) async {
    final document = await c.loadBlockPage(session: session);
    final notes = await c.store.list();
    return (
      document,
      [for (final note in notes) BlockPageNote(note.id, note.title)],
      [
        for (final note in notes)
          if (note.documentKind == VaultDocumentKind.database &&
              !note.trashed &&
              !note.revision.deleted &&
              !note.deletionConflict)
            BlockPageNote(note.id, note.title),
      ],
    );
  }

  SyncedBlockAccess _syncedAccess(WorkspaceController c, NoteSession owner) {
    final repository = c.repository;
    final generation = c.editorGeneration;
    final store = SyncedBlockStore(repository);
    bool current() =>
        mounted &&
        identical(c, controller) &&
        identical(c.activeSession, owner) &&
        identical(c.repository, repository) &&
        c.editorGeneration == generation;
    return SyncedBlockAccess(
      owner: owner,
      ownerNoteId: owner.note.id,
      isCurrent: current,
      changes: repository.changes,
      listPages: () async => [
        for (final note in await WorkspaceStore(repository).list())
          if (note.id != owner.note.id &&
              note.documentKind == VaultDocumentKind.page &&
              !note.trashed &&
              !note.revision.deleted &&
              !note.deletionConflict)
            (id: note.id, title: note.title),
      ],
      listSources: store.listSources,
      open: store.open,
      save: (target, blockId, text) => store.saveText(
        target,
        owner: owner,
        ownerBlockId: blockId,
        text: text,
        requireWrite: () {
          if (!current() || c.externalBusy) {
            throw StateError('동기화 블록을 저장하는 동안 편집 페이지가 바뀌었습니다.');
          }
        },
      ),
      detach: (target, blockId, requireWrite) => store.detach(
        target,
        owner: owner,
        ownerBlockId: blockId,
        requireWrite: () {
          if (!current() || c.externalBusy || c.inkDirty || c.markdownDirty) {
            throw StateError('현재 페이지를 저장한 뒤 연결을 해제하세요.');
          }
          requireWrite();
        },
      ),
    );
  }

  Future<(WorkspaceDatabase, List<BlockPageNote>)> _loadDatabaseContents(
    WorkspaceController c,
    NoteSession session,
  ) async {
    final document = await c.loadDatabase(session: session);
    final notes = await c.store.list();
    return (
      document,
      [for (final note in notes) BlockPageNote(note.id, note.title)],
    );
  }

  Future<Map<String, _RelatedDatabaseSource>> _loadRelatedDatabases(
    NoteRepository repo,
  ) async {
    final notes = await WorkspaceStore(repo).list();
    final folders = <String, List<VaultFolder>>{};
    if (repo.formatVersion >= 2) {
      for (final folder in await LibraryStore(
        repo,
      ).listFolders(includeDeleted: true)) {
        (folders[folder.id] ??= []).add(folder);
      }
    }
    bool availableFolder(String? folderId) {
      final seen = <String>{};
      while (folderId != null) {
        if (!seen.add(folderId) || seen.length > 64) return false;
        final folder = folders[folderId]?.singleOrNull;
        if (folder == null || folder.trashed || folder.deletionConflict)
          return false;
        folderId = folder.parentId;
      }
      return true;
    }

    final result = <String, _RelatedDatabaseSource>{};
    final ambiguous = <String>{};
    for (final note in notes) {
      if (note.documentKind != VaultDocumentKind.database ||
          note.trashed ||
          note.deletionConflict ||
          !availableFolder(note.folderId)) {
        continue;
      }
      final metadata = (await repo.heads(note.id)).singleOrNull;
      if (metadata == null ||
          metadata.deleted ||
          metadata.kind != EntityKind.metadata ||
          metadata.vaultId != repo.vaultId ||
          metadata.revisionId != note.revision.revisionId)
        continue;
      final body = (await repo.heads(note.inkEntityId)).singleOrNull;
      if (body == null ||
          body.deleted ||
          body.kind != EntityKind.ink ||
          body.ownerNoteId != note.id ||
          body.vaultId != repo.vaultId)
        continue;
      final bytes = (await repo.readFiles(body))['database.json'];
      if (bytes == null) continue;
      try {
        final database = WorkspaceDatabase.fromJson(
          jsonObject(jsonDecode(utf8.decode(bytes))),
        );
        if (result.containsKey(database.id)) ambiguous.add(database.id);
        result[database.id] = (note: note, database: database, body: body);
      } on FormatException {
        continue;
      }
    }
    for (final id in ambiguous) {
      result.remove(id);
    }
    return result;
  }

  Future<void> _openDashboardView(
    WorkspaceController c,
    NoteSession owner,
    String databaseId,
    String viewId,
  ) => _run(() async {
    final repo = c.repository;
    final editorGeneration = c.editorGeneration;
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repo) &&
        identical(c.activeSession, owner) &&
        c.editorGeneration == editorGeneration &&
        !c.externalBusy &&
        !owner.note.trashed &&
        !owner.note.deletionConflict;
    if (!current()) return;
    await _changeDocumentTab(c, () async {
      if (!current()) return;
      final generation = c.repositoryGeneration;
      final related = await _loadRelatedDatabases(repo);
      final source = related[databaseId];
      final ownerSource = related[_database.currentState?.database.id];
      final view = source?.database.views
          .where((view) => view.id == viewId)
          .singleOrNull;
      if (!current() ||
          generation != c.repositoryGeneration ||
          source == null ||
          view == null ||
          !databaseViewTypes.contains(view.type) ||
          source.note.id == owner.note.id ||
          ownerSource?.note.id != owner.note.id ||
          ownerSource?.note.revision.revisionId !=
              owner.note.revision.revisionId ||
          ownerSource?.body.revisionId != owner.inkParents.singleOrNull) {
        throw StateError('대시보드나 연결된 보기가 바뀌었습니다. 최신 보기에서 다시 열어 주세요.');
      }
      final heads = await Future.wait([
        repo.heads(source.note.id),
        repo.heads(source.note.inkEntityId),
      ]);
      if (!current() ||
          generation != c.repositoryGeneration ||
          heads[0].singleOrNull?.revisionId !=
              source.note.revision.revisionId ||
          heads[1].singleOrNull?.revisionId != source.body.revisionId) {
        throw StateError('연결된 데이터베이스가 바뀌었습니다. 최신 보기에서 다시 열어 주세요.');
      }
      await c.openNote(
        source.note,
        databaseViewId: view.id,
        expectedRepositoryGeneration: generation,
        expectedDatabaseRevision: source.body.revisionId,
      );
    });
  });

  void _invalidateThumbnailScope() {
    if (_sharedDocumentClosing) return;
    final repo = controller?.repository;
    if (identical(_thumbnailRepository, repo)) return;
    _retireThumbnailScope();
    _thumbnailRepository = repo;
    _thumbnailCache = repo == null
        ? null
        : widget.thumbnailCacheFactory(
            Directory('${repo.root.path}/.cache/thumbnails'),
          );
    _thumbnails.clear();
    _thumbnailKeys.clear();
    _thumbnailAttempts.clear();
  }

  void _retireThumbnailScope() {
    final cache = _thumbnailCache;
    _thumbnailCache = null;
    _thumbnailRepository = null;
    if (cache == null) return;
    final pending = cache.retire();
    _retiringThumbnailWrites.add(pending);
    unawaited(
      pending.then<void>((_) {
        _retiringThumbnailWrites.remove(pending);
      }),
    );
  }

  Future<void> _requestThumbnail(VaultNote note) async {
    final c = controller;
    if (!mounted ||
        _sharedDocumentClosing ||
        c == null ||
        c.activeSession != null ||
        note.trashed)
      return;
    _invalidateThumbnailScope();
    final repo = c.repository;
    final cache = _thumbnailCache!;
    final request = (cache, note.id);
    if (!_thumbnailRequests.add(request)) return;
    final generation = c.repositoryGeneration;
    bool current() =>
        mounted &&
        identical(_thumbnailCache, cache) &&
        identical(c.repository, repo);
    try {
      final key = await cache.coverKey(repo, note);
      if (!current()) return;
      if (key != null &&
          _thumbnailKeys[note.id] == key &&
          _thumbnails.containsKey(note.id))
        return;
      if (_thumbnailAttempts[note.id] == (key, generation)) return;
      final file = key == null ? null : await cache.getOrCreate(repo, note);
      if (!current()) return;
      final currentKey = await cache.coverKey(repo, note);
      if (!current() || currentKey != key) return;
      _thumbnailAttempts[note.id] = (key, generation);
      if (file != null) {
        setState(() {
          _thumbnailKeys[note.id] = key!;
          _thumbnails[note.id] = FileImage(file);
        });
      } else if (_thumbnails.containsKey(note.id)) {
        setState(() {
          _thumbnailKeys.remove(note.id);
          _thumbnails.remove(note.id);
        });
      }
    } finally {
      _thumbnailRequests.remove(request);
      if (current() &&
          c.activeSession == null &&
          c.repositoryGeneration != generation) {
        final latest = c.notes
            .where(
              (value) =>
                  value.id == note.id &&
                  !value.trashed &&
                  value.folderId == c.currentFolderId,
            )
            .firstOrNull;
        if (latest != null) unawaited(_requestThumbnail(latest));
      }
    }
  }

  void _sharedDocument() {
    final c = controller;
    if (!mounted || c == null) return;
    if (_sharedDocumentScope == null || c.canCreateDocument)
      _sharedDocumentScope = _sharedScope(c.repository);
    final inbox = StudyWorkspace.pendingDocumentImport;
    inbox.bindUnassigned(_sharedDocumentScope!);
    setState(() {});
    if (inbox.pending.isEmpty || _sharedDocumentTimer != null) return;
    _sharedDocumentTimer = Timer(Duration.zero, () {
      _sharedDocumentTimer = null;
      unawaited(_deliverSharedDocument());
    });
  }

  Object _sharedScope(NoteRepository repo) => (
    repo.root.absolute.uri.normalizePath().toString(),
    repo.vaultId,
    repo.deviceId,
    repo.formatVersion,
  );

  Future<void> _deliverSharedDocument() async {
    final c = controller;
    if (!mounted ||
        c == null ||
        busy ||
        _sharedDocumentProcessing ||
        _sharedDocumentClosing ||
        !_automationForeground ||
        !c.canCreateDocument ||
        c.inkBusy ||
        c.pendingPdfPath != null ||
        _pendingPdf != null ||
        ModalRoute.of(context)?.isCurrent == false)
      return;
    final inbox = StudyWorkspace.pendingDocumentImport;
    final lease = inbox.claim(
      owner: _sharedDocumentOwner,
      scope: _sharedScope(c.repository),
    );
    if (lease == null) return;
    final repo = c.repository;
    final path = lease.request.path;
    final isPdf = p.extension(path).toLowerCase() == '.pdf';
    _sharedDocumentProcessing = true;
    setState(() => busy = true);
    Object? failure;
    try {
      await _save();
      if (!mounted ||
          !identical(controller, c) ||
          !identical(c.repository, repo) ||
          !inbox.isCurrent(lease))
        throw StateError('대상이 바뀌어 문서 가져오기 요청을 보관했습니다.');
      if (isPdf) {
        await _importPdfPath(
          path,
          expectedController: c,
          expectedRepository: repo,
          sharedRequestId: lease.request.sharedRequestId,
        );
      } else {
        await _importSharedOffice(path, c, repo, lease);
      }
    } catch (error) {
      failure = error;
    } finally {
      inbox.finish(lease, failure: failure);
      _sharedDocumentProcessing = false;
      _finishBusy();
    }
  }

  Future<void> _importSharedOffice(
    String path,
    WorkspaceController c,
    NoteRepository repo,
    SharedDocumentLease lease,
  ) async {
    final fileName = p.basename(path);
    final folder = c.currentFolderId;
    final session = c.activeSession;
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repo) &&
        identical(c.activeSession, session) &&
        c.currentFolderId == folder &&
        c.canCreateDocument &&
        !c.dirty &&
        StudyWorkspace.pendingDocumentImport.isCurrent(lease);
    final file = File(path);
    await _importOfficeFile(
      c,
      fileName: fileName,
      readOriginal: () => _readExternalDocument(
        file.length,
        file.openRead,
        maxBytes: _officeImportMaxBytes,
        tooLarge: _officeImportTooLarge,
        current: current,
      ),
      isCurrent: current,
      sharedRequestId: lease.request.sharedRequestId,
    );
  }

  /// After the app's own picker or Office engine screen the workspace may still be finishing a
  /// save or sync started around it. That is not a different vault or folder, so wait briefly.
  Future<bool> _settledAfterExternalScreen(bool Function() current) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!current()) {
      if (!mounted || !DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }

  Future<void> _importOfficeFile(
    WorkspaceController c, {
    required String fileName,
    required Future<Uint8List?> Function() readOriginal,
    required bool Function() isCurrent,
    String? Function()? staleReason,
    String? sharedRequestId,
  }) async {
    final repository = c.repository;
    Future<void> requireCurrent() async {
      if (await _settledAfterExternalScreen(isCurrent)) return;
      _importLog.warning('Office import stopped: ${staleReason?.call() ?? 'not current'}');
      throw StateError('가져올 보관함이나 폴더가 바뀌었습니다.');
    }

    await requireCurrent();
    Uint8List? bytes;
    if (sharedRequestId != null) {
      bytes = await readOriginal();
      await requireCurrent();
      if (bytes == null) return;
      final prior = await c.store.readSharedOfficeImport(sharedRequestId, (
        fileName: fileName,
        bytes: bytes,
      ));
      await requireCurrent();
      if (prior != null) {
        if (!prior.trashed) await c.openNote(prior);
        _finishOfficeImport(c, repository, prior);
        return;
      }
    }

    if (!mounted) return;
    final mode = await showDialog<_OfficeImportMode>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('office-import-mode'),
        title: const Text('문서를 어떻게 열까요?'),
        content: Text(
          '$fileName\n\n'
          'PDF 필기용은 PDF와 함께 원본도 보관해, 나중에 새 엔진으로 PDF를 다시 만들 수 있습니다. Office 편집용은 원본을 보관하고 편집할 수 있습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, _OfficeImportMode.office),
            child: const Text('Office 편집용'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _OfficeImportMode.pdf),
            child: const Text('PDF 필기용'),
          ),
        ],
      ),
    );
    if (mode == null) return;
    await requireCurrent();
    bytes ??= await readOriginal();
    await requireCurrent();
    if (bytes == null) return;
    if (bytes.isEmpty)
      throw const FormatException('빈 Office·한글 파일은 가져올 수 없습니다.');
    final title = p.basenameWithoutExtension(fileName);
    final VaultNote note;
    if (mode == _OfficeImportMode.pdf) {
      final converted =
          await (widget.officePreviewEngine ?? OfficePreviewEngine())
              .convertToPdf(fileName: fileName, original: bytes);
      await requireCurrent();
      if (converted == null) return;
      note = await _importConvertedOfficePdf(
        c,
        title: title,
        fileName: '$title.pdf',
        bytes: converted.bytes,
        pageCount: converted.pageCount,
        isCurrent: isCurrent,
        staleReason: staleReason,
        sharedRequestId: sharedRequestId,
        sharedOfficeOriginal: (fileName: fileName, bytes: bytes),
        keptOriginal: (
          fileName: fileName,
          bytes: bytes,
          engineVersion: converted.engineVersion,
        ),
      );
    } else {
      note = await OfficeDocumentStore(repository).importDocument(
        title: title,
        fileName: fileName,
        bytes: bytes,
        folderId: c.currentFolderId,
        sharedRequestId: sharedRequestId,
      );
      if (!note.trashed && isCurrent()) await c.openNote(note);
    }
    _finishOfficeImport(c, repository, note);
  }

  static const _officeImportMaxBytes = 128 * 1024 * 1024;
  static const _officeImportTooLarge = FormatException(
    'Office·한글 파일은 최대 128 MiB까지 가져올 수 있습니다.',
  );

  Future<VaultNote> _importConvertedOfficePdf(
    WorkspaceController c, {
    required String title,
    required String fileName,
    required Uint8List bytes,
    required int? pageCount,
    required bool Function() isCurrent,
    String? Function()? staleReason,
    int? pageNumber,
    String? sharedRequestId,
    SharedOfficeOriginal? sharedOfficeOriginal,
    ({String fileName, Uint8List bytes, String? engineVersion})? keptOriginal,
  }) async {
    PdfDocument? pdf;
    try {
      pdf = await PdfDocument.openData(bytes, useProgressiveLoading: false);
      final pages = pdf.pages.length;
      if (pages < 1 ||
          (pageCount != null && pageCount != pages) ||
          (pageNumber != null && (pageNumber < 1 || pageNumber > pages))) {
        throw const FormatException('Invalid PDF page count');
      }
    } catch (_) {
      throw const FormatException(
        '변환한 PDF를 열 수 없습니다. 원본에서 PDF 만들기를 다시 시도해 주세요.',
      );
    } finally {
      await pdf?.dispose();
    }
    if (!await _settledAfterExternalScreen(isCurrent)) {
      _importLog.warning('Office PDF import stopped: ${staleReason?.call() ?? 'not current'}');
      throw StateError('PDF를 저장할 보관함이나 폴더가 바뀌었습니다.');
    }
    return c.importOfficePdf(
      title,
      fileName: fileName,
      bytes: bytes,
      pdfPageNumber: pageNumber,
      sharedRequestId: sharedRequestId,
      sharedOfficeOriginal: sharedRequestId == null
          ? null
          : sharedOfficeOriginal,
      keptOriginal: keptOriginal,
    );
  }

  bool _keepsOriginal(WorkspaceController c, NoteSession session) {
    final lookup = (c.repository, session.note.id);
    if (_keptOriginalLookup != lookup) {
      _keptOriginalLookup = lookup;
      _keptOriginal = false;
      unawaited(
        PdfNoteOriginalStore(c.repository).has(session.note).then(
          (kept) {
            if (kept && mounted && _keptOriginalLookup == lookup) {
              setState(() => _keptOriginal = true);
            }
          },
          // Without the lookup the action stays hidden; the note is unaffected.
          onError: (Object _) {},
        ),
      );
    }
    return _keptOriginal;
  }

  /// Converts the kept original of a "PDF 필기용" note again and opens the
  /// result as a new PDF note. The note, its PDF and its ink stay as they are.
  Future<void> _remakePdfFromOriginal(
    WorkspaceController c,
    NoteSession session,
  ) async {
    final repository = c.repository;
    final folder = c.currentFolderId;
    final note = session.note;
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repository) &&
        identical(c.activeSession, session) &&
        c.currentFolderId == folder;
    final original = await PdfNoteOriginalStore(repository).read(note);
    if (!mounted || !current()) return;
    if (original == null) throw StateError('이 노트에는 보관된 원본이 없습니다.');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('새 엔진으로 PDF 다시 만들기'),
        content: Text(
          '보관된 원본 ${original.fileName}을(를) 지금 엔진으로 다시 변환해 '
          '새 노트로 엽니다. 이 노트와 PDF, 필기는 그대로 둡니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('새 노트로 만들기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !current()) return;
    // Saved before converting too: an Office conversion can end the app process.
    await _save();
    if (!current()) return;
    final converted =
        await (widget.officePreviewEngine ?? OfficePreviewEngine())
            .convertToPdf(fileName: original.fileName, original: original.bytes);
    if (converted == null || !current()) return;
    for (final head in await repository.heads(note.sourceEntityId!)) {
      final files = await repository.readFiles(head);
      if (files.values.any((pdf) => listEquals(pdf, converted.bytes))) {
        if (mounted && current()) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('새 엔진으로 만든 PDF가 지금 PDF와 같아 새 노트를 만들지 않았습니다.'),
            ),
          );
        }
        return;
      }
    }
    await _save();
    if (!current()) return;
    final name = p.basenameWithoutExtension(original.fileName);
    final pdf = await _importConvertedOfficePdf(
      c,
      title: '${note.title} (새 엔진)',
      fileName: '$name.pdf',
      bytes: converted.bytes,
      pageCount: converted.pageCount,
      isCurrent: current,
      keptOriginal: (
        fileName: original.fileName,
        bytes: original.bytes,
        engineVersion: converted.engineVersion,
      ),
    );
    _finishOfficeImport(c, repository, pdf);
  }

  void _finishOfficeImport(
    WorkspaceController c,
    NoteRepository repo,
    VaultNote note,
  ) {
    if (!mounted ||
        !identical(controller, c) ||
        !identical(c.repository, repo) ||
        c.activeSession?.note.id != note.id)
      return;
    setState(() {
      _pendingPdf = null;
      _targetPage = null;
      _searchSelection = null;
      markdownTab = false;
    });
    _scaffold.currentState?.closeDrawer();
  }

  void _finishBusy() {
    if (!mounted) return;
    setState(() => busy = false);
    _sharedDocument();
  }

  Widget? _sharedDocumentBanner(WorkspaceController c) {
    final inbox = StudyWorkspace.pendingDocumentImport;
    final request = inbox.pending.firstOrNull;
    if (request == null || inbox.processing) return null;
    final foreign =
        request.scope != null && request.scope != _sharedScope(c.repository);
    if (!foreign && request.failure == null) return null;
    final enabled = !busy && c.canCreateDocument;
    final kind = p.extension(request.path).toLowerCase() == '.pdf'
        ? 'PDF'
        : '문서';
    return MaterialBanner(
      forceActionsBelow: true,
      content: Text(
        request.needsDestinationConfirmation
            ? '이전에 받은 $kind 파일입니다. 가져올 보관함을 확인하세요. ${p.basename(request.path)}'
            : foreign
            ? '다른 저장소에서 받은 $kind 요청입니다: ${p.basename(request.path)}'
            : '$kind 파일을 가져오지 못했습니다. ${p.basename(request.path)} 파일과 저장 상태를 확인하세요.',
      ),
      actions: [
        TextButton(
          onPressed: !enabled
              ? null
              : () {
                  if (foreign)
                    inbox.useScope(request.id, _sharedScope(c.repository));
                  else
                    inbox.retry(request.id);
                },
          child: Text(foreign ? '현재 저장소에 가져오기' : '다시 시도'),
        ),
        TextButton(
          onPressed: !enabled ? null : () => inbox.defer(request.id),
          child: const Text('이 파일 건너뛰기'),
        ),
      ],
    );
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        _scaffold.currentState?.closeDrawer();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      _finishBusy();
    }
  }

  Future<void> _save() {
    final saving = _saveWorkspace();
    _workspaceSave = saving;
    return saving.whenComplete(() {
      if (identical(_workspaceSave, saving)) _workspaceSave = null;
    });
  }

  Future<void> _saveWorkspace() async {
    final c = controller!;
    final repository = c.repository;
    final session = c.activeSession;
    await _editor.currentState?.saveToFile();
    await _infinite.currentState?.save();
    await _cards.currentState?.save();
    await _page.currentState?.save();
    await _database.currentState?.save();
    await _office.currentState?.save();
    await c.flush();
    if (!mounted ||
        !identical(controller, c) ||
        !identical(c.repository, repository) ||
        !identical(c.activeSession, session)) {
      return;
    }
    final editor = _editor.currentState;
    await c.rememberView(
      markdown: markdownTab,
      markdownAnchor: markdownTab ? c.navigation.current.markdownAnchor : null,
      databaseViewId: session?.note.documentKind == VaultDocumentKind.database
          ? _database.currentState?.selectedViewId ??
                c.navigation.current.databaseViewId
          : null,
      pageId: markdownTab
          ? null
          : c.pdfPeerPreview
          ? c.navigation.current.pageId
          : editor?.coreInfo.pages
                .elementAtOrNull(editor.currentPageIndex)
                ?.pageId,
    );
  }

  Future<void> _back() async {
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      _scaffold.currentState?.closeDrawer();
      return;
    }
    final session = controller?.activeSession;
    if (session == null) {
      final c = controller;
      if (c != null && _librarySelection == _librarySelectionScope(c)) {
        if (!busy) setState(() => _librarySelection = null);
        return;
      }
      if (c?.currentFolderId != null) {
        final folder = c!.folders
            .where((f) => f.id == c.currentFolderId)
            .firstOrNull;
        await _run(() => c.openFolder(folder?.parentId));
      }
      return;
    }
    await _run(() async {
      await _save();
      await controller!.closeNote(session: session);
      if (!mounted) return;
      _pendingPdf = null;
      _targetPage = null;
      _searchSelection = null;
      markdownTab = false;
    });
  }

  Future<void> _open(VaultNote note, {KnowledgeBodyMatch? bodyMatch}) async {
    final c = controller!;
    final repository = c.repository;
    await _save();
    if (!mounted ||
        !identical(c, controller) ||
        !identical(repository, c.repository))
      return;
    _pendingPdf = null;
    _targetPage = null;
    _searchSelection = null;
    await c.openNote(note);
    if (!mounted ||
        !identical(c, controller) ||
        !identical(repository, c.repository))
      return;
    markdownTab = note.documentKind == VaultDocumentKind.markdown;
    final session = c.activeSession;
    final displayed = c.searchBodyMatches[note.id];
    if (bodyMatch != null &&
        displayed != null &&
        displayed.markdownRevisionId == bodyMatch.markdownRevisionId &&
        displayed.start == bodyMatch.start &&
        displayed.end == bodyMatch.end &&
        displayed.text == bodyMatch.text &&
        session != null &&
        session.note.id == note.id &&
        markdownTab &&
        !c.markdownDirty &&
        !c.remoteConflict &&
        session.markdownParents.singleOrNull == bodyMatch.markdownRevisionId &&
        bodyMatch.start >= 0 &&
        bodyMatch.end > bodyMatch.start &&
        bodyMatch.end <= c.markdown.length &&
        c.markdown.substring(bodyMatch.start, bodyMatch.end) ==
            bodyMatch.text) {
      _searchSelection = (session: session, match: bodyMatch);
      _searchSelectionRequest++;
    }
    _scaffold.currentState?.closeDrawer();
  }

  Future<void> _history({required bool forward}) async {
    await _save();
    final c = controller!;
    if (forward) {
      await c.forwardInHistory();
    } else {
      await c.backInHistory();
    }
    _pendingPdf = null;
    _targetPage = c.navigation.current.pageId;
    _searchSelection = null;
    _markdownAnchorRequest++;
    markdownTab = c.navigation.current.markdown;
  }

  Future<void> _openTab(String id) async {
    final note = (await controller!.store.list())
        .where((n) => n.id == id)
        .firstOrNull;
    if (note == null) throw StateError('문서를 찾을 수 없습니다. 수신 상태나 휴지통을 확인하세요.');
    await _open(note);
  }

  void _quickSwitch() {
    final c = controller;
    if (c == null || busy || c.externalBusy) return;
    unawaited(
      _run(() async {
        final repository = c.repository;
        final outgoing = c.activeSession;
        bool current() =>
            mounted &&
            identical(controller, c) &&
            identical(c.repository, repository) &&
            identical(c.activeSession, outgoing) &&
            !c.externalBusy;

        final catalogGeneration = c.repositoryGeneration;
        final notes = <String, VaultNote>{};
        final seenNotes = <String>{};
        for (final note in await c.store.list()) {
          if (!seenNotes.add(note.id)) {
            notes.remove(note.id);
          } else if (!note.trashed && !note.deletionConflict) {
            notes[note.id] = note;
          }
        }
        if (!current()) return;
        final folders = <String, VaultFolder>{};
        if (repository.formatVersion >= 2) {
          final seenFolders = <String>{};
          for (final folder in await c.library.listFolders()) {
            if (!seenFolders.add(folder.id)) {
              folders.remove(folder.id);
            } else if (!folder.trashed && !folder.deletionConflict) {
              folders[folder.id] = folder;
            }
          }
        }
        if (!mounted || !current()) return;
        if (catalogGeneration != c.repositoryGeneration) {
          throw StateError('보관함 내용이 바뀌었습니다. 최신 문서를 다시 검색하세요.');
        }
        String pathOf(VaultNote note) {
          final segments = [note.title];
          final ancestors = <String>{};
          for (var id = note.folderId; id != null;) {
            final folder = folders[id];
            if (folder == null || !ancestors.add(id)) {
              return '폴더 위치 확인 필요/${note.title}';
            }
            segments.add(folder.title);
            id = folder.parentId;
          }
          return '/${segments.reversed.join('/')}';
        }

        final id = await showWorkspaceQuickSwitcher(
          context,
          entries: [
            for (final note in notes.values)
              WorkspaceQuickSwitchEntry(
                id: note.id,
                title: note.title,
                path: pathOf(note),
              ),
          ],
          recentIds: c.recentDocumentIds,
          activeId: outgoing?.note.id,
        );
        if (id == null || id == outgoing?.note.id || !current()) return;
        await _changeDocumentTab(c, () async {
          if (!current()) return;
          final generation = c.repositoryGeneration;
          final matches = (await c.store.list()).where((note) => note.id == id);
          if (!current()) return;
          final note = matches.singleOrNull;
          if (generation != c.repositoryGeneration ||
              note == null ||
              note.trashed ||
              note.deletionConflict ||
              note.revision.revisionId != notes[id]?.revision.revisionId) {
            throw StateError('문서 상태가 바뀌었습니다. 최신 문서를 다시 검색하세요.');
          }
          final tab = c.navigation.tabs
              .where((tab) => tab.noteId == id)
              .singleOrNull;
          await c.openNote(
            note,
            markdownView: tab?.location?.markdown,
            markdownAnchor: tab?.location?.markdownAnchor,
            pageId: tab?.location?.pageId,
            databaseViewId: tab?.location?.databaseViewId,
            reuseSession: tab != null,
            expectedRepositoryGeneration: generation,
          );
        });
      }),
    );
  }

  Future<void> _changeDocumentTab(
    WorkspaceController c,
    Future<void> Function() change,
  ) async {
    final repository = c.repository;
    final outgoing = c.activeSession;
    await _save();
    if (!mounted ||
        !identical(controller, c) ||
        !identical(c.repository, repository) ||
        !identical(c.activeSession, outgoing) ||
        c.externalBusy) {
      return;
    }
    _searchSelection = null;
    _documentTabChange = (repository: repository, outgoing: outgoing);
    try {
      await change();
    } finally {
      _applyDocumentTabView(c);
      _documentTabChange = null;
    }
  }

  void _applyDocumentTabView(WorkspaceController c) {
    final change = _documentTabChange;
    final session = c.activeSession;
    final location = c.navigation.current;
    if (change == null ||
        !mounted ||
        !identical(controller, c) ||
        !identical(c.repository, change.repository) ||
        identical(session, change.outgoing) ||
        session?.note.id != location.noteId) {
      return;
    }
    _documentTabChange = null;
    _pendingPdf = null;
    _targetPage = location.pageId;
    _rememberedPageSession = session;
    _markdownAnchorRequest++;
    markdownTab = location.markdown;
    _scaffold.currentState?.closeDrawer();
  }

  Widget _documentTabs(WorkspaceController c) {
    final repository = c.repository;
    final tabs = c.navigation.tabs;
    final enabled = !busy && !c.externalBusy;
    void select(String id) {
      if (busy ||
          c.externalBusy ||
          !identical(controller, c) ||
          !identical(c.repository, repository) ||
          c.activeSession?.note.id == id ||
          !c.navigation.tabs.any((tab) => tab.noteId == id)) {
        return;
      }
      unawaited(
        _run(() => _changeDocumentTab(c, () => c.activateDocumentTab(id))),
      );
    }

    return SizedBox(
      height: 44,
      child: Row(
        children: [
          IconButton(
            tooltip: '이전 위치',
            icon: const Icon(Icons.arrow_back, size: 20),
            onPressed: !enabled || c.navigation.peekBack == null
                ? null
                : () => _run(() => _history(forward: false)),
          ),
          IconButton(
            tooltip: '다음 위치',
            icon: const Icon(Icons.arrow_forward, size: 20),
            onPressed: !enabled || c.navigation.peekForward == null
                ? null
                : () => _run(() => _history(forward: true)),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final tab in tabs)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Material(
                        color: c.activeSession?.note.id == tab.noteId
                            ? Theme.of(context).colorScheme.secondaryContainer
                            : Theme.of(context).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            InkWell(
                              key: ValueKey('document-tab-${tab.noteId}'),
                              onTap: enabled ? () => select(tab.noteId) : null,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 160,
                                  ),
                                  child: Text(
                                    tab.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '${tab.title} 탭 닫기',
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: !enabled
                                  ? null
                                  : () => _run(
                                      () => _changeDocumentTab(
                                        c,
                                        () => c.closeDocumentTab(tab.noteId),
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          WorkspaceTabSwitcher(
            tabs: tabs,
            activeNoteId: c.activeSession?.note.id,
            onSelected: enabled ? select : null,
          ),
        ],
      ),
    );
  }

  Future<void> _goFolder(String? id) async {
    final c = controller!;
    final repository = c.repository;
    await _save();
    if (!mounted ||
        !identical(controller, c) ||
        !identical(c.repository, repository))
      return;
    final session = c.activeSession;
    if (session != null) await c.closeNote(session: session);
    if (!mounted ||
        !identical(controller, c) ||
        !identical(c.repository, repository))
      return;
    await c.openFolder(id);
    if (c.searchesAcrossFolders) {
      c.query = '';
      await c.refresh();
    }
    _scaffold.currentState?.closeDrawer();
  }

  Future<bool> _upgradeLegacyVault(WorkspaceController c) async {
    final source = c.repository;
    bool isCurrent() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, source) &&
        c.canCreateDocument;

    if (!isCurrent()) return false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('보관함 형식 업데이트'),
        content: const Text(
          '이 문서를 만들려면 보관함 형식 2가 필요합니다. '
          '현재 기기에 저장된 문서와 이력을 새 보관함에 복사한 뒤 문서 생성을 이어갑니다. '
          '기존 보관함과 Drive 원본은 그대로 유지됩니다. '
          '복사본도 동기화하려면 Drive에서 ‘현재 로컬 vault를 Drive에 만들기’를 선택하세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('형식 2 복사본 만들기'),
          ),
        ],
      ),
    );
    if (accepted != true || !isCurrent()) return false;
    await _save();
    final support = await getApplicationSupportDirectory();
    if (!isCurrent()) return false;
    final destination = Directory(
      p.join(support.path, 'vaults', 'upgrade-${newId()}'),
    );
    final drive = _driveConnection;
    if (drive != null) {
      if (!await drive.upgradeLegacyRepository(source, destination)) {
        throw StateError(drive.error ?? '보관함 업데이트를 다시 시도해 주세요.');
      }
    } else {
      if (source.pendingRevisionCount != 0 ||
          source.integrityIssues.isNotEmpty) {
        throw StateError(
          '보관함에 아직 수신되지 않았거나 확인이 필요한 자료가 있습니다. '
          '자료를 확인한 뒤 다시 시도해 주세요.',
        );
      }
      final next = await BackupService.cloneToEmpty(
        source,
        destination,
        targetFormatVersion: 2,
      );
      try {
        if (!isCurrent()) return false;
        await c.replaceRepository(next);
      } finally {
        if (!identical(c.repository, next)) await next.close();
      }
    }
    final upgradedRoot = await destination.resolveSymbolicLinks();
    return mounted &&
        identical(controller, c) &&
        p.equals(c.repository.root.path, upgradedRoot);
  }

  Future<void> _createDocument(LibraryCreateAction action) async {
    final workspace = controller!;
    final requiresFormatTwo = switch (action) {
      LibraryCreateAction.infinite ||
      LibraryCreateAction.markdown ||
      LibraryCreateAction.dailyNote ||
      LibraryCreateAction.datedNote ||
      LibraryCreateAction.dailyNoteTemplate ||
      LibraryCreateAction.canvas ||
      LibraryCreateAction.page ||
      LibraryCreateAction.database ||
      LibraryCreateAction.image ||
      LibraryCreateAction.camera ||
      LibraryCreateAction.office ||
      LibraryCreateAction.wordDocument ||
      LibraryCreateAction.presentation ||
      LibraryCreateAction.hwpx ||
      LibraryCreateAction.folder => true,
      _ => false,
    };
    if (workspace.repository.formatVersion == 1 &&
        requiresFormatTwo &&
        !await _upgradeLegacyVault(workspace)) {
      return;
    }
    if (!mounted) return;
    if (action == LibraryCreateAction.dailyNoteTemplate) {
      return _configureDailyNoteTemplate();
    }
    if (action == LibraryCreateAction.quickNote) {
      final c = controller!;
      final repository = c.repository;
      final folderId = c.currentFolderId;
      if (!c.canCreateDocument) return;
      await _save();
      if (!mounted ||
          !identical(controller, c) ||
          !identical(c.repository, repository) ||
          c.currentFolderId != folderId ||
          !c.canCreateDocument) {
        return;
      }
      final note = await c.createNote('빠른 메모');
      if (!mounted ||
          !identical(controller, c) ||
          !identical(c.repository, repository) ||
          c.activeSession?.note.id != note.id) {
        return;
      }
      _pendingPdf = null;
      _targetPage = null;
      markdownTab = false;
      _scaffold.currentState?.closeDrawer();
      return;
    }
    if (action == LibraryCreateAction.dailyNote ||
        action == LibraryCreateAction.datedNote) {
      final c = controller!;
      final repository = c.repository;
      bool isCurrent() =>
          mounted &&
          identical(controller, c) &&
          identical(c.repository, repository);
      final today = DateTime.now();
      final date = action == LibraryCreateAction.dailyNote
          ? today
          : await showDatePicker(
              context: context,
              initialDate: today,
              firstDate: DateTime(1),
              lastDate: DateTime(9999, 12, 31),
              helpText: '날짜별 노트 열기',
              cancelText: '취소',
              confirmText: '열기',
            );
      if (date == null || !isCurrent()) return;
      await _save();
      if (!isCurrent()) return;
      final templates = WorkspaceMarkdownTemplateStore(repository);
      final note = await c.store.openDailyNote(
        date,
        loadInitialMarkdown: (title) =>
            templates.initialDailyMarkdown(title, DateTime.now()),
        beforePublish: () {
          if (!isCurrent()) throw StateError('열린 보관함이 바뀌었습니다.');
        },
      );
      if (!isCurrent()) return;
      await c.openNote(
        note,
        expectedRepositoryGeneration: c.repositoryGeneration,
      );
      if (!isCurrent() || c.activeSession?.note.id != note.id) return;
      _pendingPdf = null;
      _targetPage = null;
      markdownTab = true;
      _scaffold.currentState?.closeDrawer();
      return;
    }
    if (action == LibraryCreateAction.obsidianVault ||
        action == LibraryCreateAction.notionZip) {
      await _importExternalVault(
        notion: action == LibraryCreateAction.notionZip,
      );
      return;
    }
    if (action == LibraryCreateAction.starnote) {
      await _importStarNoteVault();
      return;
    }
    await _save();
    if (action == LibraryCreateAction.pdf) return _create(pdf: true);
    if (action == LibraryCreateAction.image ||
        action == LibraryCreateAction.camera) {
      final Uint8List bytes;
      final String name;
      if (action == LibraryCreateAction.camera) {
        final captured = await const NativeImageCapture().capture();
        if (captured == null) return;
        if (await captured.length() > 64 * 1024 * 1024)
          throw StateError('사진이 너무 큽니다(최대 64 MiB).');
        name = p.basename(captured.path);
        bytes = await captured.readAsBytes();
      } else {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        );
        if (file == null) return;
        if ((await file.length() ?? 0) > 64 * 1024 * 1024)
          throw StateError('이미지가 너무 큽니다(최대 64 MiB).');
        name = p.basename(file.name);
        bytes = await file.readAsBytes();
      }
      final c = controller!;
      final note = await ImageNoteImporter(c.repository).import(
        title: action == LibraryCreateAction.camera
            ? '촬영한 사진'
            : p.basenameWithoutExtension(name),
        fileName: name,
        bytes: bytes,
        folderId: c.currentFolderId,
      );
      await c.openNote(note);
      markdownTab = false;
      _pendingPdf = null;
      _targetPage = null;
      _scaffold.currentState?.closeDrawer();
      return;
    }
    if (action == LibraryCreateAction.office) {
      final c = controller!;
      final repository = c.repository;
      final session = c.activeSession;
      final folder = c.currentFolderId;
      String? stale() {
        if (!mounted) return 'screen closed';
        if (!identical(controller, c)) return 'workspace replaced';
        if (!identical(c.repository, repository)) return 'vault replaced';
        if (!identical(c.activeSession, session)) return 'open document changed';
        if (c.currentFolderId != folder) return 'folder changed';
        if (c.externalBusy) return 'automation running';
        if (!c.canCreateDocument) return 'workspace busy';
        if (c.dirty) return 'unsaved changes';
        return null;
      }

      bool current() => stale() == null;
      if (defaultTargetPlatform == TargetPlatform.android) {
        const source = AndroidDocumentSource.office;
        final selection = await source.choose();
        if (selection == null) return;
        try {
          if (!await _settledAfterExternalScreen(current)) {
            _importLog.warning('Office import stopped after the picker: ${stale()}');
            return;
          }
          await _importOfficeFile(
            c,
            fileName: selection.name,
            staleReason: stale,
            readOriginal: () async {
              final staged = await source.stage(selection);
              return _readExternalDocument(
                staged.file.length,
                staged.file.openRead,
                expectedLength: staged.bytes,
                maxBytes: _officeImportMaxBytes,
                tooLarge: _officeImportTooLarge,
                current: current,
              );
            },
            isCurrent: current,
          );
        } finally {
          await source.release(selection.id);
        }
      } else {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: OfficeDocumentStore.supportedExtensions,
        );
        if (file == null) return;
        final bytes = await file.readAsBytes();
        await _importOfficeFile(
          c,
          fileName: p.basename(file.name),
          readOriginal: () async => bytes,
          isCurrent: current,
        );
      }
      return;
    }
    if (action == LibraryCreateAction.wordDocument ||
        action == LibraryCreateAction.presentation ||
        action == LibraryCreateAction.hwpx) {
      final templateKind = switch (action) {
        LibraryCreateAction.wordDocument => OfficeTemplateKind.document,
        LibraryCreateAction.hwpx => OfficeTemplateKind.hwpx,
        _ => OfficeTemplateKind.presentation,
      };
      final input = await _input('문서 이름', switch (templateKind) {
        OfficeTemplateKind.document => '새 Word 문서',
        OfficeTemplateKind.hwpx => '새 한글 문서',
        OfficeTemplateKind.presentation => '새 프레젠테이션',
      });
      if (input == null || input.trim().isEmpty) return;
      final title = input.trim();
      final starter = OfficeTemplates.create(templateKind, title: title);
      final c = controller!;
      final note = await OfficeDocumentStore(c.repository).importDocument(
        title: title,
        fileName: starter.fileName,
        bytes: starter.bytes,
        folderId: c.currentFolderId,
      );
      _pendingPdf = null;
      _targetPage = null;
      markdownTab = false;
      await c.openNote(note);
      _scaffold.currentState?.closeDrawer();
      return;
    }
    final title = await _input(
      action == LibraryCreateAction.folder ? '새 폴더' : '문서 이름',
      action == LibraryCreateAction.markdown
          ? '새 Markdown'
          : action == LibraryCreateAction.canvas
          ? '새 캔버스'
          : action == LibraryCreateAction.page
          ? '새 페이지'
          : action == LibraryCreateAction.database
          ? '새 데이터베이스'
          : action == LibraryCreateAction.folder
          ? '새 폴더'
          : '새 노트',
    );
    if (title == null || title.trim().isEmpty) return;
    if (action == LibraryCreateAction.folder) {
      await controller!.createFolder(title.trim());
    } else {
      await controller!.createNote(
        title.trim(),
        documentKind: action == LibraryCreateAction.markdown
            ? VaultDocumentKind.markdown
            : action == LibraryCreateAction.canvas
            ? VaultDocumentKind.canvas
            : action == LibraryCreateAction.page
            ? VaultDocumentKind.page
            : action == LibraryCreateAction.database
            ? VaultDocumentKind.database
            : action == LibraryCreateAction.infinite
            ? VaultDocumentKind.infinite
            : VaultDocumentKind.handwriting,
      );
      markdownTab = action == LibraryCreateAction.markdown;
    }
    _scaffold.currentState?.closeDrawer();
  }

  Future<void> _configureDailyNoteTemplate() async {
    final c = controller!;
    final repository = c.repository;
    final generation = c.repositoryGeneration;
    bool sameRepository() =>
        identical(controller, c) &&
        identical(c.repository, repository) &&
        c.repositoryGeneration == generation;

    final store = WorkspaceMarkdownTemplateStore(repository);
    final settings = await store.dailyNoteTemplateSettings();
    if (!mounted || !sameRepository()) return;
    final folders = await store.folders();
    if (!mounted || !sameRepository()) return;
    final selection =
        await showDialog<({WorkspaceMarkdownTemplateChoice? choice})>(
          context: context,
          builder: (context) => DailyNoteTemplateSettingsDialog(
            store: store,
            settings: settings,
            folders: folders,
          ),
        );
    if (!mounted || !sameRepository() || selection == null) return;
    await store.saveDailyNoteTemplateSettings(
      settings,
      choice: selection.choice,
      beforePublish: () {
        if (!mounted || !sameRepository()) {
          throw StateError('열린 보관함이 바뀌었습니다.');
        }
      },
    );
  }

  Future<String?> _chooseFolder({List<VaultFolder>? folders}) =>
      showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('이동할 폴더'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('내 문서'),
            ),
            for (final folder in (folders ?? controller!.folders).where(
              (f) => !f.trashed,
            ))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, folder.id),
                child: Text(folder.title),
              ),
          ],
        ),
      );

  _LibrarySelectionScope _librarySelectionScope(WorkspaceController c) =>
      (c.repository, c.currentFolderId, c.showDeleted);

  Future<Set<String>> _batchNoteAction(
    List<VaultNote> selected,
    LibraryBatchAction action,
  ) async {
    final c = controller!;
    final scope = _librarySelectionScope(c);
    final search = (c.query, c.searchesWithOperators, c.searchesLiterally);
    final completed = <String>{};
    bool current() =>
        mounted &&
        identical(controller, c) &&
        c.activeSession == null &&
        _librarySelection == scope &&
        _librarySelectionScope(c) == scope &&
        (c.query, c.searchesWithOperators, c.searchesLiterally) == search;
    if (!current() || selected.isEmpty) return completed;

    await _run(() async {
      await _save();
      if (!mounted || !current()) return;
      final label = switch (action) {
        LibraryBatchAction.move => '이동',
        LibraryBatchAction.trash => '휴지통 이동',
        LibraryBatchAction.restore => '복원',
      };
      VaultFolder? destination;
      if (action == LibraryBatchAction.move) {
        final choices = c.folders
            .where((folder) => !folder.trashed && !folder.deletionConflict)
            .toList();
        final id = await _chooseFolder(folders: choices);
        if (!current() || id == null) return;
        if (id.isNotEmpty) {
          destination = choices.where((folder) => folder.id == id).singleOrNull;
          if (destination == null) throw StateError('이동할 폴더를 다시 선택하세요.');
        }
      } else {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('문서 ${selected.length}개 $label'),
            content: Text(
              action == LibraryBatchAction.trash
                  ? '선택한 문서를 휴지통으로 이동합니다.'
                  : '선택한 문서를 원래 위치로 복원합니다.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              FilledButton(
                key: const ValueKey('library-batch-confirm'),
                onPressed: () => Navigator.pop(context, true),
                child: Text(label),
              ),
            ],
          ),
        );
        if (!current() || confirmed != true) return;
      }

      void requireCurrent() {
        if (!current()) throw StateError('보관함이나 문서 선택 범위가 바뀌었습니다.');
      }

      final store = c.store;
      final repository = c.repository;
      try {
        await c.externalMutation((activeRepository) async {
          requireCurrent();
          if (!identical(activeRepository, repository)) {
            throw StateError('열린 보관함이 바뀌었습니다.');
          }
          Future<Set<String>> folderRevisions() async => {
            for (final revision in await repository.revisions())
              if (revision.kind == EntityKind.folder) revision.revisionId,
          };
          final expectedFolders = await folderRevisions();
          Future<void> requireSameFolders() async {
            requireCurrent();
            if (!setEquals(expectedFolders, await folderRevisions())) {
              throw StateError('폴더 구조가 바뀌었습니다.');
            }
          }

          final selectedIds = selected.map((note) => note.id).toSet();
          final notes = <String, List<VaultNote>>{};
          for (final note in await store.list(includeDeleted: true)) {
            if (selectedIds.contains(note.id)) {
              (notes[note.id] ??= []).add(note);
            }
          }
          final restorableFolders = <String>{};
          if (action == LibraryBatchAction.restore) {
            final blocked = <String>{};
            for (final folder in await c.library.listFolders(
              includeDeleted: true,
            )) {
              if (folder.trashed || folder.deletionConflict) {
                blocked.add(folder.id);
              } else {
                restorableFolders.add(folder.id);
              }
            }
            restorableFolders.removeAll(blocked);
          }
          if (destination case final folder?) {
            final heads = await repository.heads(folder.id);
            if (heads.length != 1 ||
                heads.single.revisionId != folder.revision.revisionId) {
              throw StateError('이동할 폴더가 바뀌었습니다.');
            }
          }
          for (final expected in selected) {
            final note = notes[expected.id]?.singleOrNull;
            if (note == null ||
                note.revision.revisionId != expected.revision.revisionId ||
                note.deletionConflict ||
                (action == LibraryBatchAction.restore
                    ? !note.revision.deleted ||
                          (note.folderId != null &&
                              !restorableFolders.contains(note.folderId))
                    : note.trashed)) {
              throw StateError('문서 판본이나 휴지통 상태가 바뀌었습니다.');
            }

            Future<void> requireCurrentNote() async {
              await requireSameFolders();
              final heads = await repository.heads(note.id);
              if (heads.singleOrNull?.revisionId != note.revision.revisionId) {
                throw StateError('문서 판본이 바뀌었습니다.');
              }
              requireCurrent();
            }

            await requireCurrentNote();
            if (action == LibraryBatchAction.move) {
              await store.moveNote(
                note,
                destination?.id,
                requireWrite: requireCurrent,
                onPrepared: (_) => requireCurrentNote(),
              );
            } else {
              await store.setDeleted(
                note,
                action == LibraryBatchAction.trash,
                requireWrite: requireCurrent,
                onPrepared: (_) => requireCurrentNote(),
              );
            }
            completed.add(note.id);
          }
        });
      } catch (error) {
        if (current()) {
          throw StateError(
            '${completed.length}개 $label 완료 · '
            '${selected.length - completed.length}개 미처리. $error',
          );
        }
        return;
      }
      if (mounted && current()) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${completed.length}개 문서 $label 완료')),
        );
      }
    });
    return completed;
  }

  Future<void> _noteAction(VaultNote note, LibraryNoteAction action) async {
    await _save();
    final c = controller!;
    Future<void> Function()? operation;
    switch (action) {
      case LibraryNoteAction.rename:
        final title = await _input('문서 이름', note.title);
        if (title != null && title.trim().isNotEmpty) {
          await _save();
          operation = () => c.store.rename(note, title.trim());
        }
      case LibraryNoteAction.move:
        final id = await _chooseFolder();
        if (id != null) {
          await _save();
          operation = () => c.store.moveNote(note, id.isEmpty ? null : id);
        }
      case LibraryNoteAction.trash:
        operation = () => c.store.setDeleted(note, true);
      case LibraryNoteAction.restore:
        operation = () => c.store.setDeleted(note, false);
    }
    final change = operation;
    if (change == null) {
      await c.refresh();
    } else {
      await c.externalMutation((_) => change());
    }
  }

  Future<void> _folderAction(
    VaultFolder folder,
    LibraryFolderAction action,
  ) async {
    await _save();
    final c = controller!;
    Future<void> Function()? operation;
    switch (action) {
      case LibraryFolderAction.rename:
        final title = await _input('폴더 이름', folder.title);
        if (title != null && title.trim().isNotEmpty) {
          await _save();
          operation = () => c.library.renameFolder(folder, title.trim());
        }
      case LibraryFolderAction.move:
        final id = await _chooseFolder();
        if (id != null) {
          await _save();
          operation = () =>
              c.library.moveFolder(folder, id.isEmpty ? null : id);
        }
      case LibraryFolderAction.trash:
        operation = () => c.library.setDeleted(folder, true);
      case LibraryFolderAction.restore:
        operation = () => c.library.setDeleted(folder, false);
    }
    final change = operation;
    if (change == null) {
      await c.refresh();
    } else {
      await c.externalMutation((_) => change());
    }
  }

  Future<void> _create({bool pdf = false}) async {
    await _save();
    String? path;
    if (pdf) {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (picked == null) return;
      path = picked.path;
      if (path == null) throw StateError('PDF 파일을 읽을 수 없습니다.');
    }
    if (path != null) {
      await _importPdfPath(path);
    } else {
      _pendingPdf = null;
      await controller!.createNote('새 노트');
    }
    _scaffold.currentState?.closeDrawer();
  }

  Future<void> _importPdfPath(
    String path, {
    WorkspaceController? expectedController,
    NoteRepository? expectedRepository,
    String? sharedRequestId,
  }) async {
    final c = expectedController ?? controller!;
    final repo = expectedRepository ?? c.repository;
    void requireCurrent() {
      if (!mounted ||
          !identical(controller, c) ||
          !identical(c.repository, repo))
        throw StateError('가져오기 대상이 바뀌었습니다. 원래 PDF 파일을 다시 선택하세요.');
    }

    requireCurrent();
    if (c.repository.formatVersion >= 2) {
      _pendingPdf = null;
      final bytes = await File(path).readAsBytes();
      requireCurrent();
      final title = p.basenameWithoutExtension(path);
      final fileName = p.basename(path);
      if (sharedRequestId == null) {
        await c.importPdf(title, fileName: fileName, bytes: bytes);
      } else {
        await c.importSharedPdf(
          title,
          fileName: fileName,
          bytes: bytes,
          requestId: sharedRequestId,
        );
      }
    } else {
      final retained = await _retainPdf(path);
      requireCurrent();
      final previous = c.activeSession;
      _pendingPdf = retained;
      _pendingPdfScope = _sharedScope(repo);
      try {
        await c.createNote(
          p.basenameWithoutExtension(path),
          importingPdf: true,
        );
      } catch (_) {
        if (_pendingPdf == retained && identical(c.activeSession, previous)) {
          _pendingPdf = null;
          _pendingPdfScope = null;
        }
        rethrow;
      }
    }
  }

  Future<String> _retainPdf(String path) async {
    final target = FileManager.getFile(
      '/.working/imports/${newId()}/original.pdf',
    );
    await target.parent.create(recursive: true);
    await File(path).copy(target.path);
    return target.path;
  }

  Future<void> _localVaults() async {
    await _save();
    final support = await getApplicationSupportDirectory();
    final parent = Directory('${support.path}/vaults');
    final roots = <Directory>[];
    if (parent.existsSync()) {
      await for (final entry in parent.list(followLinks: false)) {
        if (entry is Directory && File('${entry.path}/vault.json').existsSync())
          roots.add(entry);
      }
    }
    if (!mounted) return;
    final chosen = await showDialog<Directory>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('기기의 저장소'),
        children: [
          for (final root in roots)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, root),
              child: Text(p.basename(root.path)),
            ),
        ],
      ),
    );
    if (chosen != null &&
        chosen.absolute.path != controller!.repository.root.path) {
      await controller!.replaceRepository(await NoteRepository.open(chosen));
    }
  }

  Future<String?> _input(String title, String initial) => showDialog<String>(
    context: context,
    builder: (_) => _DocumentNameDialog(title: title, initial: initial),
  );
  Future<void> _openCanvasFile(CardCanvasNode node) async {
    final id = node.linkedNoteId;
    if (id == null) return;
    final subpath = node.subpath;
    if (subpath == null) {
      await _openTab(id);
    } else {
      await _openLink(NoteLink(id).toString(), canvasSubpath: subpath);
    }
  }

  Future<void> _openLink(
    String value, {
    String? canvasSubpath,
    String? fromNoteId,
    bool requireSingleMarkdown = false,
    bool bookmarkTarget = false,
    int? originalPdfPage,
  }) async {
    if (isSafeExternalLink(value)) {
      await launchUrl(Uri.parse(value), mode: LaunchMode.externalApplication);
      return;
    }
    final link = NoteLink.parse(value);
    final uri = Uri.tryParse(value);
    if (uri?.scheme == 'inkvault' && link == null) {
      throw const FormatException('노트 링크 형식을 확인하세요.');
    }
    final wiki = value.startsWith('inkwiki:');
    final local = uri != null && !uri.hasScheme && !uri.hasAuthority;
    if (wiki || local || link != null) {
      _searchSelection = null;
      final c = controller!, repo = c.repository, session = c.activeSession;
      bool isCurrent() =>
          mounted &&
          identical(controller, c) &&
          identical(c.repository, repo) &&
          identical(c.activeSession, session);
      final from = fromNoteId ?? session?.note.id;
      KnowledgeTarget? resolveTarget() => link != null
          ? null
          : wiki
          ? c.knowledge?.resolveWikiLink(value, fromNoteId: from)
          : from == null
          ? null
          : c.knowledge?.resolveMarkdownLink(value, fromNoteId: from);
      final embeddedLink = fromNoteId != null && link == null;
      final clickedTarget = embeddedLink ? resolveTarget() : null;
      await _save();
      if (!isCurrent()) return;
      final target = resolveTarget();
      if (embeddedLink &&
          (clickedTarget?.noteId != target?.noteId ||
              clickedTarget?.anchor != target?.anchor ||
              clickedTarget?.attachmentName != target?.attachmentName)) {
        throw StateError('연결 대상이 바뀌었습니다. 포함된 노트의 링크를 다시 눌러 주세요.');
      }
      final noteId = link?.noteId ?? target?.noteId;
      if (noteId == null) throw StateError('연결된 문서를 찾을 수 없거나 제목이 중복됩니다.');
      final officeTarget = link?.officePageTarget;
      final expectedGeneration =
          requireSingleMarkdown || bookmarkTarget || officeTarget != null
          ? c.repositoryGeneration
          : null;
      final matches = (await c.store.list())
          .where((n) => n.id == noteId)
          .toList();
      if (!isCurrent()) return;
      final note = matches.firstOrNull;
      if (note == null) throw StateError('연결된 문서가 없습니다.');
      if (officeTarget != null) {
        if (matches.length != 1 ||
            note.deletionConflict ||
            note.trashed ||
            note.documentKind != VaultDocumentKind.office ||
            originalPdfPage != null) {
          throw StateError('링크가 가리키는 Office 문서 판본을 확인할 수 없습니다.');
        }
        final request = await OfficeWorkspace.preparePageLink(
          repository: repo,
          noteId: note.id,
          target: officeTarget,
        );
        if (!isCurrent()) return;
        await c.openNote(
          note,
          markdownView: false,
          reuseSession: true,
          expectedRepositoryGeneration: expectedGeneration,
        );
        final opened = c.activeSession;
        if (!mounted ||
            !identical(controller, c) ||
            !identical(c.repository, repo) ||
            opened == null ||
            opened.note.id != note.id) {
          return;
        }
        setState(() {
          _officePageLink = (session: opened, request: request);
          _pendingPdf = null;
          _targetPage = null;
          _markdownAnchorRequest++;
          markdownTab = false;
        });
        return;
      }
      if (bookmarkTarget &&
          (matches.length != 1 || note.deletionConflict || note.trashed)) {
        throw StateError('북마크의 문서 판본을 확인할 수 없습니다.');
      }
      if (originalPdfPage != null &&
          (originalPdfPage < 1 ||
              note.documentKind != VaultDocumentKind.pdf ||
              note.sourceEntityId == null)) {
        throw StateError('북마크가 가리키는 원본 PDF를 찾을 수 없습니다.');
      }
      if (requireSingleMarkdown ||
          (bookmarkTarget && link?.markdownAnchor != null)) {
        final heads = await repo.heads(note.markdownEntityId);
        if (!isCurrent()) return;
        if (matches.length != 1 ||
            note.deletionConflict ||
            (requireSingleMarkdown &&
                note.documentKind != VaultDocumentKind.markdown) ||
            heads.length != 1 ||
            heads.single.deleted ||
            heads.single.kind != EntityKind.markdown ||
            heads.single.ownerNoteId != note.id) {
          throw StateError(
            bookmarkTarget
                ? '북마크가 가리키는 Markdown 판본을 확인할 수 없습니다.'
                : '조회 결과의 원본 Markdown 판본을 확인할 수 없습니다.',
          );
        }
      }
      final attachmentName = target?.attachmentName;
      if (attachmentName != null &&
          (matches.length != 1 ||
              note.deletionConflict ||
              note.sourceEntityId == null ||
              note.obsidianAttachmentName != attachmentName ||
              obsidianAttachmentKind(attachmentName) !=
                  note.documentKind.name)) {
        throw StateError('연결된 첨부 문서의 판본을 확인할 수 없습니다.');
      }
      final canvasAnchor = link != null && canvasSubpath != null
          ? canvasSubpath.substring(1)
          : null;
      final anchor = attachmentName == null
          ? link?.markdownAnchor ??
                target?.anchor ??
                (note.documentKind == VaultDocumentKind.markdown
                    ? canvasAnchor
                    : null)
          : null;
      final pdfAnchor = note.documentKind == VaultDocumentKind.pdf
          ? (attachmentName != null
                ? target?.anchor
                : matches.length == 1 &&
                      !note.deletionConflict &&
                      note.sourceEntityId != null &&
                      note.obsidianAttachmentName != null
                ? canvasAnchor
                : null)
          : null;
      final showMarkdown =
          attachmentName == null &&
          ((local && note.documentKind != VaultDocumentKind.database) ||
              (link?.isMarkdown ?? false) ||
              note.documentKind == VaultDocumentKind.markdown ||
              anchor != null);
      await c.openNote(
        note,
        markdownView: showMarkdown,
        markdownAnchor: anchor,
        pageId: showMarkdown ? null : link?.pageId,
        revealLinkedPage: !showMarkdown && link?.pageId != null,
        pdfPageNumber: originalPdfPage ?? _pdfPageNumberFromAnchor(pdfAnchor),
        reuseSession: showMarkdown,
        expectedRepositoryGeneration: expectedGeneration,
      );
      if (!mounted ||
          !identical(controller, c) ||
          !identical(c.repository, repo)) {
        return;
      }
      _pendingPdf = null;
      _targetPage = null;
      _markdownAnchorRequest++;
      markdownTab = showMarkdown;
    }
  }

  static int? _pdfPageNumberFromAnchor(String? anchor) {
    if (anchor == null) return null;
    int? number;
    for (final field in anchor.split('&')) {
      if (field != 'page' && !field.startsWith('page=')) continue;
      if (number != null || field == 'page') return 0;
      final value = field.substring(5);
      if (!RegExp(r'^[0-9]+$').hasMatch(value)) return 0;
      number = int.tryParse(value) ?? 0;
    }
    return number;
  }

  Future<void> _followInkPageLink(
    WorkspaceController c,
    NoteSession session,
    Future<ResolvedInkPageLink?> target, {
    bool linkedInkPage = false,
  }) async {
    final editor = _editor.currentState;
    final repo = c.repository;
    final editorGeneration = c.editorGeneration;
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repo) &&
        identical(c.activeSession, session) &&
        identical(_editor.currentState, editor) &&
        c.editorGeneration == editorGeneration &&
        _pdfCanvasVisible();
    final resolved = await target;
    if (!current()) return;
    final generation = resolved?.repositoryGeneration ?? c.repositoryGeneration;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !current() || c.repositoryGeneration != generation) return;
    final destination = resolved?.page;
    final location = c.navigation.current;
    if (linkedInkPage &&
        (location.noteId != session.note.id ||
            location.markdown ||
            (destination != null && location.pageId != destination.pageId))) {
      return;
    }
    if (destination != null &&
        editor?.revealPage(
              destination.pageId,
              background: destination.background,
            ) ==
            true) {
      await c.rememberView(markdown: false, pageId: destination.pageId);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            linkedInkPage
                ? '연결된 필기 페이지를 찾을 수 없습니다.'
                : '원본 PDF의 지정 페이지를 찾을 수 없습니다.',
          ),
        ),
      );
    }
  }

  bool _pdfCanvasVisible() =>
      !markdownTab ||
      (defaultTargetPlatform != TargetPlatform.android &&
          MediaQuery.sizeOf(context).width >= 1000);

  Future<void> _showPdfTextSearch(
    WorkspaceController c,
    NoteSession session,
  ) async {
    final editor = _editor.currentState;
    if (editor == null || !_pdfCanvasVisible()) return;
    final access = c.pdfTextSearch(session, editor.coreInfo);
    if (access == null) return;
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(_editor.currentState, editor) &&
        identical(c.activeSession, session) &&
        _pdfCanvasVisible();
    final hit = await showDialog<PdfTextSearchHit>(
      context: context,
      builder: (_) => PdfTextSearchDialog(
        search: (query, active) =>
            access.search(query, () => active() && current()),
      ),
    );
    if (hit == null || !current()) return;
    await _run(() => _followInkPageLink(c, session, access.resolve(hit)));
  }

  bool _currentVaultMarkdown(WorkspaceController c, _VaultMarkdownScope scope) {
    final (repo, session, index, generation) = scope;
    return mounted &&
        identical(controller, c) &&
        identical(c.repository, repo) &&
        identical(c.activeSession, session) &&
        identical(c.knowledge, index) &&
        c.repositoryGeneration == generation;
  }

  MarkdownDataviewAccess? _dataviewAccess(
    WorkspaceController c,
    _VaultMarkdownScope scope,
  ) {
    final (_, session, index, _) = scope;
    final engine = c.native;
    if (index == null || engine == null || !c.knowledgeCurrent) {
      _dataview = null;
      return null;
    }
    final cached = _dataview;
    if (cached != null && identical(cached.$1, c) && cached.$2 == scope) {
      return cached.$3;
    }
    bool isCurrent() => _currentVaultMarkdown(c, scope);
    Future<DataviewResult> evaluate(String source, String noteId) async {
      if (!isCurrent()) {
        throw StateError('조회할 보관함 판본이 바뀌었습니다.');
      }
      return evaluateDataview(
        index,
        engine,
        DataviewQuery.parse(source),
        originNoteId: noteId,
      );
    }

    final access = MarkdownDataviewAccess(
      evaluate: (source) => evaluate(source, session.note.id),
      evaluateFromNote: evaluate,
      openNote: (noteId) => _run(() async {
        if (!isCurrent()) return;
        await _openLink(
          NoteLink.markdown(noteId).toString(),
          requireSingleMarkdown: true,
        );
      }),
      toggleTask: (row, completed) =>
          c.setDataviewTask(row, completed, isCurrent: isCurrent),
      isCurrent: isCurrent,
    );
    _dataview = (c, scope, access);
    return access;
  }

  Future<VaultMarkdownEmbed?> _readVaultMarkdownEmbed(
    WorkspaceController c,
    _VaultMarkdownScope scope,
    String href,
    String fromNoteId,
  ) async {
    final (repo, _, index, _) = scope;
    bool isCurrent() => _currentVaultMarkdown(c, scope);
    if (!isCurrent() || index == null || !href.startsWith('inkwiki:')) {
      return null;
    }
    final target = index.resolveWikiLink(href, fromNoteId: fromNoteId);
    if (target == null || target.attachmentName != null) return null;
    final matches = (await WorkspaceStore(
      repo,
    ).list()).where((note) => note.id == target.noteId).toList();
    if (!isCurrent() || matches.length != 1) return null;
    final note = matches.single;
    if (note.trashed ||
        note.deletionConflict ||
        note.revision.deleted ||
        note.documentKind != VaultDocumentKind.markdown) {
      return null;
    }
    final metadataHeads = await repo.heads(note.id);
    if (!isCurrent() ||
        metadataHeads.singleOrNull?.revisionId != note.revision.revisionId) {
      return null;
    }
    final heads = await repo.heads(note.markdownEntityId);
    if (!isCurrent() || heads.length != 1) return null;
    final revision = heads.single;
    final summary = revision.blobs['summary.md'];
    if (revision.deleted ||
        revision.vaultId != repo.vaultId ||
        revision.entityId != note.markdownEntityId ||
        revision.ownerNoteId != note.id ||
        revision.kind != EntityKind.markdown ||
        summary == null ||
        summary.length > 512 * 1024) {
      return null;
    }
    try {
      final bytes = await repo.readRevisionFile(revision, 'summary.md');
      if (!isCurrent()) return null;
      return VaultMarkdownEmbed(
        noteId: note.id,
        title: note.title,
        source: utf8.decode(bytes),
        anchor: target.anchor,
      );
    } on FormatException {
      return null;
    }
  }

  Future<Uint8List?> _readVaultRaster(
    WorkspaceController c,
    _VaultMarkdownScope scope,
    String href, {
    String? fromNoteId,
  }) async {
    final (repo, session, index, _) = scope;
    bool isCurrent() => _currentVaultMarkdown(c, scope);
    if (!isCurrent()) return null;
    final from = fromNoteId ?? session.note.id;
    final target = href.startsWith('inkwiki:')
        ? index?.resolveWikiLink(href, fromNoteId: from)
        : index?.resolveMarkdownLink(href, fromNoteId: from);
    final name = target?.attachmentName;
    if (target == null ||
        target.anchor != null ||
        name == null ||
        obsidianAttachmentKind(name) != 'image') {
      return null;
    }
    final notes = (await WorkspaceStore(
      repo,
    ).list()).where((note) => note.id == target.noteId).toList();
    if (!isCurrent() || notes.length != 1) return null;
    final note = notes.single;
    final sourceId = note.sourceEntityId;
    if (note.deletionConflict ||
        note.documentKind != VaultDocumentKind.image ||
        note.obsidianAttachmentName != name ||
        sourceId == null) {
      return null;
    }
    final heads = await repo.heads(sourceId);
    if (!isCurrent() || heads.length != 1) return null;
    final revision = heads.single;
    final ref = revision.blobs[name];
    if (revision.deleted ||
        revision.vaultId != repo.vaultId ||
        revision.entityId != sourceId ||
        revision.ownerNoteId != note.id ||
        revision.kind != EntityKind.attachment ||
        revision.blobs.length != 1 ||
        ref == null ||
        ref.length < 1 ||
        ref.length > 16 * 1024 * 1024) {
      return null;
    }
    final bytes = await repo.readRevisionFile(revision, name);
    if (!isCurrent()) return null;
    final decoder = switch (p.extension(name).toLowerCase()) {
      '.png' => image.PngDecoder(),
      '.jpg' || '.jpeg' => image.JpegDecoder(),
      '.webp' => image.WebPDecoder(),
      _ => null,
    };
    final dimensions = decoder?.startDecode(bytes);
    if (dimensions == null ||
        dimensions.width < 1 ||
        dimensions.height < 1 ||
        dimensions.width > 40000000 ~/ dimensions.height) {
      return null;
    }
    return bytes;
  }

  Future<Uint8List?> _readVaultPdfPreview(
    WorkspaceController c,
    _VaultMarkdownScope scope,
    String href,
    String fromNoteId,
    int pageNumber,
    ValueListenable<bool> cancelled,
  ) async {
    final (repo, _, index, _) = scope;
    bool isCurrent() => !cancelled.value && _currentVaultMarkdown(c, scope);
    if (!isCurrent() || index == null || !href.startsWith('inkwiki:')) {
      return null;
    }
    final target = index.resolveWikiLink(href, fromNoteId: fromNoteId);
    final name = target?.attachmentName;
    if (target == null ||
        name == null ||
        obsidianAttachmentKind(name) != 'pdf' ||
        pageNumber < 1 ||
        pageNumber != (_pdfPageNumberFromAnchor(target.anchor) ?? 1)) {
      return null;
    }
    final matches = (await WorkspaceStore(
      repo,
    ).list()).where((note) => note.id == target.noteId).toList();
    if (!isCurrent() || matches.length != 1) return null;
    final note = matches.single;
    final sourceId = note.sourceEntityId;
    if (note.trashed ||
        note.deletionConflict ||
        note.revision.deleted ||
        note.documentKind != VaultDocumentKind.pdf ||
        note.obsidianAttachmentName != name ||
        sourceId == null) {
      return null;
    }
    Future<bool> metadataIsCurrent() async {
      final heads = await repo.heads(note.id);
      return isCurrent() &&
          heads.singleOrNull?.revisionId == note.revision.revisionId;
    }

    if (!await metadataIsCurrent()) return null;
    final heads = await repo.heads(sourceId);
    if (!isCurrent() || heads.length != 1) return null;
    final source = heads.single;
    final blob = source.blobs[name];
    if (source.deleted ||
        source.vaultId != repo.vaultId ||
        source.entityId != sourceId ||
        source.ownerNoteId != note.id ||
        source.kind != EntityKind.attachment ||
        source.blobs.length != 1 ||
        blob == null ||
        blob.length < 5 ||
        blob.length > 16 * 1024 * 1024) {
      return null;
    }
    final bytes = await repo.readRevisionFile(source, name);
    if (!isCurrent() || String.fromCharCodes(bytes.take(5)) != '%PDF-') {
      return null;
    }
    final png = await _renderVaultPdfPreview(
      bytes,
      pageNumber,
      cancelled,
      isCurrent,
    );
    if (png == null || !isCurrent() || !await metadataIsCurrent()) return null;
    final latest = await repo.heads(sourceId);
    return isCurrent() && latest.singleOrNull?.revisionId == source.revisionId
        ? png
        : null;
  }

  Future<Uint8List?> _renderVaultPdfPreview(
    Uint8List bytes,
    int pageNumber,
    ValueListenable<bool> cancelled,
    bool Function() isCurrent,
  ) async {
    const edge = 960;
    final document = await PdfDocument.openData(
      bytes,
      useProgressiveLoading: true,
    );
    try {
      if (!isCurrent() ||
          document.pages.length > 10000 ||
          pageNumber > document.pages.length) {
        return null;
      }
      if (!document.pages[pageNumber - 1].isLoaded) {
        await document.loadPagesProgressively<void>(
          onPageLoadProgress: (loaded, _, _) =>
              isCurrent() && loaded < pageNumber,
        );
      }
      final page = document.pages[pageNumber - 1];
      if (!isCurrent() ||
          !page.isLoaded ||
          !page.width.isFinite ||
          !page.height.isFinite ||
          page.width <= 0 ||
          page.height <= 0) {
        return null;
      }
      final largest = math.max(page.width, page.height);
      final width = math.max(1, (page.width / largest * edge).round());
      final height = math.max(1, (page.height / largest * edge).round());
      final token = page.createCancellationToken();
      void cancelRender() {
        if (cancelled.value) token.cancel();
      }

      final PdfImage? rendered;
      cancelled.addListener(cancelRender);
      try {
        rendered = await page.render(
          width: width,
          height: height,
          fullWidth: width.toDouble(),
          fullHeight: height.toDouble(),
          cancellationToken: token,
        );
      } finally {
        cancelled.removeListener(cancelRender);
      }
      if (rendered == null) return null;
      try {
        if (!isCurrent()) return null;
        final bitmap = await rendered.createImage();
        try {
          if (!isCurrent()) return null;
          final png = await bitmap.toByteData(format: ImageByteFormat.png);
          return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
        } finally {
          bitmap.dispose();
        }
      } finally {
        rendered.dispose();
      }
    } finally {
      await document.dispose();
    }
  }

  Future<void> _blockPageHistory() async {
    await _save();
    final c = controller!, session = controller!.activeSession!;
    final repo = c.repository;
    final history = await c.blockPageHistory(session: session);
    bool isCurrent() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repo) &&
        identical(c.activeSession, session) &&
        history.belongsTo(session);
    if (!mounted || !isCurrent()) return;
    await showDialog<void>(
      context: context,
      builder: (_) => BlockPageHistorySheet(
        snapshot: history,
        isCurrent: isCurrent,
        onRestore: (chosen) =>
            c.restoreBlockPageRevision(history, chosen, session: session),
      ),
    );
  }

  Future<void> _databaseHistory(
    WorkspaceController c,
    NoteSession session,
  ) async {
    final repo = c.repository;
    final editorGeneration = c.editorGeneration;
    bool isOpen() =>
        mounted &&
        !_sharedDocumentClosing &&
        identical(controller, c) &&
        identical(c.repository, repo) &&
        identical(c.activeSession, session) &&
        c.editorGeneration == editorGeneration;
    if (!isOpen()) return;
    await _save();
    if (!isOpen()) return;
    final history = await c.databaseHistory(session: session);
    bool isCurrent() =>
        isOpen() &&
        history.belongsTo(session) &&
        session.inkParents.singleOrNull == history.currentRevision.revisionId;
    if (!isCurrent() || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => DatabaseHistorySheet(
        snapshot: history,
        isCurrent: isCurrent,
        onRestore: (chosen) =>
            c.restoreDatabaseRevision(history, chosen, session: session),
      ),
    );
  }

  Future<void> _pageDiscussion(
    WorkspaceController c,
    NoteSession session,
    String? blockId,
    TextSelection? selection,
  ) async {
    final repo = session.repository;
    final pageId = session.note.id;
    bool isCurrent() =>
        mounted &&
        !_sharedDocumentClosing &&
        identical(controller, c) &&
        identical(c.repository, repo) &&
        identical(c.activeSession, session) &&
        !session.note.trashed;
    final document = _page.currentState?.document;
    if (!isCurrent() || document == null) return;
    final anchor = blockId == null
        ? null
        : selection == null
        ? DiscussionAnchor.block(
            pageId: pageId,
            document: document,
            blockId: blockId,
          )
        : DiscussionAnchor.quote(
            pageId: pageId,
            document: document,
            blockId: blockId,
            startUtf16: selection.start,
            endUtf16: selection.end,
          );
    await _save();
    if (!mounted || !isCurrent()) return;
    await showPageDiscussionSheet(
      context: context,
      store: DiscussionStore(repo),
      pageId: pageId,
      initialAnchor: anchor,
      pageForWrite: () async {
        if (!isCurrent()) throw StateError('페이지가 바뀌었습니다.');
        final heads = await repo.heads(pageId);
        if (!isCurrent() || heads.length != 1 || heads.single.deleted) {
          throw StateError('현재 페이지를 확인할 수 없습니다.');
        }
        return heads.single;
      },
    );
  }

  Future<void> _conflicts() async {
    await _save();
    final c = controller!, session = controller!.activeSession!;
    final heads = <RevisionRecord>[];
    for (final id in {
      session.note.id,
      session.note.inkEntityId,
      session.note.markdownEntityId,
      ...(await c.repository.revisions())
          .where((r) => r.ownerNoteId == session.note.id)
          .map((r) => r.entityId)
          .toSet(),
    }) {
      final values = await c.repository.heads(id);
      if (values.length > 1) heads.addAll(values);
    }
    final previews = <String, String>{};
    for (final head in heads) {
      if (head.kind == EntityKind.markdown) {
        final files = await c.repository.readFiles(head);
        final text = utf8.decode(files['summary.md']!);
        previews[head.revisionId] = text.length > 500
            ? '${text.substring(0, 500)}…'
            : text;
      }
    }
    if (!mounted) return;
    final chosen = await showDialog<Object>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('충돌 버전 선택'),
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '선택한 내용으로 새 리비전을 만듭니다. 양쪽 원본은 이력에 보존됩니다. Markdown은 원문을 비교하고 합친 뒤 저장할 수 있습니다.',
            ),
          ),
          for (final h in heads)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${h.kind.name} · ${h.revisionId.substring(0, 8)} · ${h.deviceId.substring(0, 8)}${h.deleted ? ' · 삭제' : ''}',
                  ),
                  if (previews[h.revisionId] != null)
                    SelectableText(previews[h.revisionId]!),
                  Wrap(
                    children: [
                      if (h.kind != EntityKind.metadata)
                        TextButton(
                          onPressed: () => Navigator.pop(context, ('view', h)),
                          child: const Text('이 버전 열람'),
                        ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, h),
                        child: const Text('이 내용을 선택해 해결'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (heads.any((r) => r.kind == EntityKind.markdown))
            TextButton(
              onPressed: () => Navigator.pop(context, 'merge'),
              child: const Text('현재 Markdown을 합친 결과로 확정'),
            ),
        ],
      ),
    );
    if (chosen is RevisionRecord) await c.chooseRevision(chosen);
    if (chosen case ('view', final RevisionRecord head))
      await c.viewRevision(head);
    if (chosen == 'merge') await c.mergeMarkdown();
  }

  Future<void> _backup() async {
    await _save();
    final bytes = await BackupService.exportSnapshot(controller!.repository);
    if (!mounted) return;
    await FileManager.exportFile(
      'ink-vault-backup.json',
      bytes,
      context: context,
    );
  }

  Future<void> _exportObsidianVault() async {
    final c = controller!;
    final repository = c.repository;
    final session = c.activeSession;
    final native = c.native;
    if (native == null || c.externalBusy) return;

    bool checkWorkspace() {
      if (!mounted || !identical(controller, c)) return false;
      if (!identical(c.repository, repository) ||
          c.dirty ||
          !c.canCreateDocument) {
        throw StateError('보관함이 바뀌었거나 저장 중입니다. 저장을 마친 뒤 다시 내보내세요.');
      }
      return true;
    }

    setState(() => _exporting = true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await _save();
      if (!checkWorkspace()) return;
      if (!identical(c.activeSession, session)) {
        throw StateError('편집 중인 문서가 바뀌었습니다. 저장을 마친 뒤 다시 내보내세요.');
      }
      final result = await buildObsidianVaultExport(
        repository: repository,
        native: native,
      );
      if (!checkWorkspace()) return;
      final bytes = await compute(_encodeObsidianVaultZip, (
        files: result.files,
        folders: result.folders,
      ));
      if (!checkWorkspace()) return;
      await result.ensureCurrent();
      if (!checkWorkspace()) return;
      final saved = await FilePicker.saveFile(
        fileName: 'personal-ink-vault-obsidian.zip',
        bytes: bytes,
        mimeType: 'application/zip',
        dialogTitle: 'Obsidian 보관함 내보내기',
      );
      if (saved == null ||
          !mounted ||
          !identical(controller, c) ||
          !identical(c.repository, repository)) {
        return;
      }
      _scaffold.currentState?.closeDrawer();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.warnings.isEmpty
                ? 'Obsidian에서 열 수 있는 보관함 ZIP을 내보냈습니다.'
                : 'Obsidian 보관함 ZIP을 내보냈습니다. ZIP의 변환 안내도 확인하세요.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportDocument(PortableExportFormat format) async {
    final c = controller!;
    final session = c.activeSession;
    if (session == null) return;
    setState(() => _exporting = true);
    try {
      await _save();
      if (!mounted || !identical(controller, c)) return;
      final capture = await capturePortableExport(c, session);
      PortablePdfResult? pdf;
      if (format == PortableExportFormat.pdf) {
        pdf = await renderPortableDocumentPdf(capture.source);
      }
      if (!mounted) return;
      capture.ensureCurrent();
      final bundle = buildPortableDocumentExport(
        capture.source,
        format,
        pdfBytes: pdf?.bytes,
        pdfWarnings: pdf?.warnings ?? const [],
      );
      final bytes = bundle.toZip();
      capture.ensureCurrent();
      final saved = await FilePicker.saveFile(
        fileName:
            '${p.basenameWithoutExtension(bundle.entrypoint)}-${format.name}.zip',
        bytes: bytes,
        mimeType: 'application/zip',
        dialogTitle: '문서 내보내기',
      );
      if (saved != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              bundle.warnings.isEmpty
                  ? '본문·첨부·원본 자료를 내보냈습니다.'
                  : '내보냈습니다. 압축 파일 안의 변환 안내도 확인하세요.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportObsidianCanvas() async {
    final c = controller!;
    final session = c.activeSession;
    if (session == null ||
        session.note.documentKind != VaultDocumentKind.canvas) {
      return;
    }
    final repository = c.repository;
    final metadataRevision = session.note.revision.revisionId;
    setState(() => _exporting = true);
    try {
      await _save();
      if (!mounted || !identical(controller, c)) return;
      if (!identical(c.repository, repository) ||
          !identical(c.activeSession, session) ||
          session.note.revision.revisionId != metadataRevision) {
        throw StateError('문서가 바뀌었습니다. 저장을 마친 뒤 다시 내보내세요.');
      }
      final capture = await captureObsidianCanvasExport(c, session);
      final bundle = capture.bundle;
      final bytes = await compute(_encodeObsidianCanvasZip, bundle);
      if (!mounted || !identical(controller, c)) return;
      await capture.ensureCurrent();
      if (!mounted || !identical(controller, c)) return;
      final saved = await FilePicker.saveFile(
        fileName: '${p.basenameWithoutExtension(bundle.entrypoint)}-canvas.zip',
        bytes: bytes,
        mimeType: 'application/zip',
        dialogTitle: 'Obsidian Canvas 내보내기',
      );
      if (saved != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              bundle.warnings.isEmpty
                  ? 'Obsidian Canvas와 연결 문서를 내보냈습니다.'
                  : '내보냈습니다. 압축 파일 안의 변환 안내도 확인하세요.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _knowledge() async {
    if (busy) return;
    final c = controller!;
    final repository = c.repository;
    bool sameWorkspace() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repository);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .8,
        child: AnimatedBuilder(
          animation: c,
          builder: (panelContext, _) {
            if (!sameWorkspace()) {
              return const Center(child: Text('문서 연결을 연 보관함이 바뀌었습니다.'));
            }
            final index = c.knowledge;
            final session = c.activeSession;
            final route = ModalRoute.of(panelContext);
            bool sameSelection() =>
                sameWorkspace() && identical(c.activeSession, session);
            bool currentMentions() =>
                sameSelection() &&
                panelContext.mounted &&
                route?.isCurrent == true &&
                identical(c.knowledge, index) &&
                c.knowledgeCurrent;
            bool canLinkMention() =>
                currentMentions() &&
                !busy &&
                !c.markdownDirty &&
                !c.externalBusy;
            return index == null
                ? const Center(child: Text('문서 연결을 준비 중입니다.'))
                : KnowledgePanel(
                    index: index,
                    selectedNoteId: session?.note.id,
                    mentionsCurrent: c.knowledgeCurrent,
                    canLinkMentions: canLinkMention(),
                    linkDisabledReason: c.markdownDirty
                        ? '현재 문서의 Markdown 변경을 저장한 뒤 연결할 수 있습니다.'
                        : null,
                    onLinkMention: (mention) => c.linkUnlinkedMention(
                      mention,
                      isCurrent: canLinkMention,
                    ),
                    onOpenMentionSource: (id) {
                      if (!currentMentions()) return;
                      Navigator.pop(sheetContext);
                      unawaited(
                        _run(() async {
                          if (sameSelection()) {
                            await _openLink(NoteLink.markdown(id).toString());
                          }
                        }),
                      );
                    },
                    onOpenNote: (id) {
                      if (!sameSelection() || route?.isCurrent != true) return;
                      Navigator.pop(sheetContext);
                      unawaited(
                        _run(() async {
                          final note = (await c.store.list())
                              .where((n) => n.id == id)
                              .firstOrNull;
                          if (!sameSelection()) return;
                          if (note == null) throw StateError('문서를 찾을 수 없습니다.');
                          await _open(note);
                        }),
                      );
                    },
                  );
          },
        ),
      ),
    );
  }

  Future<void> _bookmarks() async {
    final c = controller!;
    if (busy || c.externalBusy) return;
    final repository = c.repository;
    final session = c.activeSession;
    final note = session?.note;
    final bookmarks = WorkspaceBookmarkStore(repository);
    final noteTitles = <String, String>{};
    final folderTitles = <String, String>{};
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repository);
    void requireCurrent() {
      if (!current()) throw StateError('북마크를 연 보관함이 바뀌었습니다.');
    }

    final editor = _editor.currentState;
    final page = !markdownTab
        ? editor?.coreInfo.pages
              .elementAtOrNull(editor.currentPageIndex)
              ?.pageId
        : null;
    final pageLink = markdownTab
        ? null
        : _office.currentState?.currentPageLink ??
              (note != null && page != null ? NoteLink(note.id, page) : null);
    final native = c.native;
    await showWorkspaceBookmarkSheet(
      context,
      changes: repository.changes.map((_) {}),
      load: () async {
        requireCurrent();
        final items = await bookmarks.list();
        final notes = await c.store.list();
        final folders = await c.library.listFolders();
        requireCurrent();
        noteTitles
          ..clear()
          ..addEntries(notes.map((note) => MapEntry(note.id, note.title)));
        folderTitles
          ..clear()
          ..addEntries(
            folders.map((folder) => MapEntry(folder.id, folder.title)),
          );
        return items;
      },
      currentTargets: [
        if (note != null && !note.trashed) ...[
          WorkspaceBookmarkSpec(
            kind: WorkspaceBookmarkKind.note,
            target: NoteLink(note.id).toString(),
          ),
          if (pageLink != null)
            WorkspaceBookmarkSpec(
              kind: WorkspaceBookmarkKind.note,
              target: pageLink.toString(),
            ),
        ],
        if (session == null && !c.showDeleted) ...[
          if (c.currentFolderId case final id?)
            WorkspaceBookmarkSpec(
              kind: WorkspaceBookmarkKind.folder,
              target: id,
            ),
          if (c.query.trim().isNotEmpty &&
              !c.searchPending &&
              c.searchError == null)
            WorkspaceBookmarkSpec(
              kind: WorkspaceBookmarkKind.search,
              target: c.query.trim(),
              literalSearch: c.searchesLiterally,
              expressionSearch: c.searchesWithOperators,
            ),
        ],
      ],
      label: (spec) {
        if (spec.title case final title?) return title;
        final target = spec.target;
        switch (spec.kind) {
          case WorkspaceBookmarkKind.note:
            final link = target == null ? null : NoteLink.parse(target);
            final title =
                noteTitles[link?.noteId] ??
                (link?.noteId == note?.id ? note?.title : null) ??
                '수신되지 않은 문서';
            if (spec.pdfPageNumber case final number?)
              return '$title · $number쪽';
            if (link?.markdownAnchor case final anchor?)
              return '$title · $anchor';
            return link?.pageId == null && link?.officePageTarget == null
                ? title
                : '$title · 필기 페이지';
          case WorkspaceBookmarkKind.folder:
            return folderTitles[target] ?? '수신되지 않은 폴더';
          case WorkspaceBookmarkKind.search:
            return '검색 · $target';
          case WorkspaceBookmarkKind.url:
            return target ?? '웹 링크';
          case WorkspaceBookmarkKind.group:
            return '그룹';
        }
      },
      chooseMarkdownLocation:
          session != null &&
              native != null &&
              (markdownTab || note?.documentKind == VaultDocumentKind.markdown)
          ? (sheetContext) async {
              requireCurrent();
              await _save();
              if (!current() ||
                  !sheetContext.mounted ||
                  !identical(c.activeSession, session))
                return null;
              final source = c.markdown;
              final generation = c.repositoryGeneration;
              final anchor = await showMarkdownBookmarkAnchorChooser(
                sheetContext,
                source: source,
                resolveAnchor: (anchor, candidates) =>
                    native.invoke({
                          'op': 'resolve_markdown_anchor',
                          'anchor': anchor,
                          'candidates': candidates,
                        })['candidateIndex']
                        as int?,
              );
              if (anchor == null) return null;
              requireCurrent();
              if (!identical(c.activeSession, session) ||
                  c.markdown != source ||
                  c.repositoryGeneration != generation) {
                throw StateError('Markdown이 바뀌었습니다. 위치를 다시 선택하세요.');
              }
              return WorkspaceBookmarkSpec(
                kind: WorkspaceBookmarkKind.note,
                target: NoteLink.markdown(session.note.id, anchor).toString(),
              );
            }
          : null,
      add: (spec) async {
        requireCurrent();
        final link = spec.kind == WorkspaceBookmarkKind.note
            ? NoteLink.parse(spec.target ?? '')
            : null;
        if (link?.pageId case final pageId?) {
          await _save();
          requireCurrent();
          if (!identical(c.activeSession, session) ||
              c.dirty ||
              _editor.currentState?.coreInfo.pages.any(
                    (page) => page.pageId == pageId,
                  ) !=
                  true) {
            throw StateError('북마크를 추가하기 전에 현재 필기 페이지를 저장하세요.');
          }
        } else if (link?.officePageTarget case final officePage?) {
          await _save();
          requireCurrent();
          if (!identical(c.activeSession, session) ||
              c.dirty ||
              _office.currentState?.currentPageLink?.officePageTarget !=
                  officePage) {
            throw StateError('북마크를 추가하기 전에 현재 Office 필기 페이지를 저장하세요.');
          }
        }
        await bookmarks.add(spec);
      },
      update: (prior, spec) async {
        requireCurrent();
        await bookmarks.update(prior, spec);
      },
      remove: (prior) async {
        requireCurrent();
        await bookmarks.remove(prior);
      },
      resolve: (prior) async {
        requireCurrent();
        await bookmarks.resolve(prior);
      },
      open: (spec) => unawaited(
        _run(() async {
          requireCurrent();
          switch (spec.kind) {
            case WorkspaceBookmarkKind.note:
              await _openLink(
                spec.target!,
                bookmarkTarget: true,
                originalPdfPage: spec.pdfPageNumber,
              );
            case WorkspaceBookmarkKind.url:
              await _openLink(spec.target!);
            case WorkspaceBookmarkKind.folder:
            case WorkspaceBookmarkKind.search:
              final isSearch = spec.kind == WorkspaceBookmarkKind.search;
              final folderId = isSearch ? null : spec.target;
              await c.library.validateDestination(folderId);
              requireCurrent();
              await _goFolder(folderId);
              requireCurrent();
              setState(() {
                c.showDeleted = false;
                c.setSearchQuery(
                  isSearch ? spec.target! : '',
                  bookmark: isSearch,
                  literal: isSearch && spec.literalSearch,
                  expression: isSearch && spec.expressionSearch,
                );
              });
              await c.refresh();
            case WorkspaceBookmarkKind.group:
              break;
          }
        }),
      ),
    );
  }

  Future<void> _restore() async {
    await _save();
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (file == null) return;
    if (file.path == null ||
        await File(file.path!).length() > BackupService.defaultMaxBytes) {
      throw const FormatException('백업 파일이 너무 큽니다 (최대 128 MiB).');
    }
    final support = await getApplicationSupportDirectory();
    final restored = await BackupService.restoreToEmpty(
      await file.readAsBytes(),
      Directory('${support.path}/vaults/restored-${newId()}'),
    );
    await controller!.replaceRepository(restored);
  }

  Future<void> _importExternalVault({required bool notion}) async {
    final c = controller!;
    final previous = c.repository;
    final previousSession = c.activeSession;
    bool current() =>
        identical(controller, c) &&
        identical(c.repository, previous) &&
        identical(c.activeSession, previousSession) &&
        c.canCreateDocument &&
        !c.dirty;
    await _save();
    if (!mounted || !current()) return;

    final android = defaultTargetPlatform == TargetPlatform.android;
    final bool? useFolder =
        !notion && (android || defaultTargetPlatform == TargetPlatform.windows)
        ? await showDialog<bool>(
            context: context,
            builder: (context) => SimpleDialog(
              title: const Text('Obsidian 보관함 가져오기'),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text('Markdown과 폴더를 별도의 기기 저장소로 가져옵니다.'),
                ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('폴더 선택'),
                ),
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('ZIP 파일 선택'),
                ),
              ],
            ),
          )
        : false;
    if (useFolder == null || !mounted || !current()) return;

    Directory? folder;
    Uint8List? zip;
    final String name;
    const androidFolder = AndroidObsidianFolder();
    String? stagedFolderId;
    if (useFolder && android) {
      final selected = await androidFolder.pick();
      if (selected == null) return;
      stagedFolderId = selected.id;
      folder = selected.directory;
      name = selected.name;
    } else if (useFolder) {
      final selected = await FilePicker.getDirectoryPath(
        dialogTitle: 'Obsidian 보관함 폴더 선택',
      );
      if (selected == null || !mounted || !current()) return;
      if (!p.isAbsolute(selected)) {
        throw const FormatException('기기에서 Obsidian 보관함 폴더를 선택하세요.');
      }
      folder = Directory(selected);
      name = p.basename(p.normalize(selected));
    } else {
      final file = await FilePicker.pickFile(
        dialogTitle: notion ? 'Notion ZIP 파일 선택' : 'Obsidian 보관함 ZIP 파일 선택',
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
      if (file == null || !mounted || !current()) return;
      final tooLarge = FormatException(
        '${notion ? 'Notion' : 'Obsidian'} ZIP은 최대 128 MiB까지 가져올 수 있습니다.',
      );
      zip = await _readExternalDocument(
        file.length,
        file.readAsByteStream,
        maxBytes: obsidianVaultZipMaxBytes,
        tooLarge: tooLarge,
        current: current,
      );
      if (zip == null) return;
      name = p.basenameWithoutExtension(file.name);
    }

    final ObsidianVaultImportResult imported;
    try {
      if (!mounted || !current()) return;
      final support = await getApplicationSupportDirectory();
      if (!mounted || !current()) return;
      final vaultsDirectory = Directory(p.join(support.path, 'vaults'));
      imported = notion
          ? await importNotionVault(
              vaultsDirectory: vaultsDirectory,
              sourceZip: zip!,
              sourceName: name,
              native: c.native,
            )
          : await importObsidianVault(
              vaultsDirectory: vaultsDirectory,
              sourceFolder: folder,
              sourceZip: zip,
              sourceName: name,
              native: c.native,
            );
    } finally {
      if (stagedFolderId != null) await androidFolder.release(stagedFolderId);
    }
    final summary = notion
        ? 'Notion 페이지 ${imported.noteCount}개, 데이터베이스 ${imported.databaseCount}개, '
              '폴더 ${imported.folderCount}개, 첨부 파일 ${imported.attachmentCount}개를 가져왔습니다. '
              '건너뛴 파일 ${imported.skippedFiles}개.'
        : 'Markdown ${imported.noteCount}개와 폴더 ${imported.folderCount}개를 가져왔습니다. '
              '캔버스 ${imported.canvasCount}개, 첨부 파일 ${imported.attachmentCount}개. '
              '건너뛴 비Markdown 파일 ${imported.skippedFiles}개.'
              '${imported.bookmarksImported > 0 || imported.bookmarksSkipped > 0 ? ' 북마크 ${imported.bookmarksImported}개, 건너뛴 북마크 ${imported.bookmarksSkipped}개.' : ''}'
              '${imported.bookmarksUnreadable ? ' 북마크 설정을 읽지 못했습니다.' : ''}';
    await _selectImportedVault(c, imported.repository, current, summary);
  }

  Future<void> _importStarNoteVault() async {
    final c = controller!;
    final previous = c.repository;
    final previousSession = c.activeSession;
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, previous) &&
        identical(c.activeSession, previousSession) &&
        c.canCreateDocument &&
        !c.dirty;
    await _save();
    if (!current()) return;

    final archive = await _readStarNoteArchive(current);
    if (archive == null || !current()) return;
    final support = await getApplicationSupportDirectory();
    if (!current()) return;
    final imported = await importStarNoteVault(
      archive: archive,
      vaultsDirectory: Directory(p.join(support.path, 'vaults')),
      requireCurrent: () {
        if (!current()) throw StateError('가져오기 중 보관함이 바뀌었습니다.');
      },
    );
    if (!current()) return;
    final summary = 'StarNote 원본 PDF ${imported.documents}개를 가져왔습니다.';
    final NoteRepository next;
    try {
      next = await NoteRepository.open(imported.directory);
    } catch (error) {
      throw StateError('$summary $_openImportedVaultFromDevice ($error)');
    }
    await _selectImportedVault(c, next, current, summary);
  }

  Future<Uint8List?> _readStarNoteArchive(bool Function() current) async {
    const source = AndroidDocumentSource.starNote;
    final android = defaultTargetPlatform == TargetPlatform.android;
    final selection = android ? await source.choose() : null;
    try {
      final picked = android
          ? null
          : await FilePicker.pickFile(
              dialogTitle: 'StarNote .note 파일 선택',
              type: FileType.custom,
              allowedExtensions: const ['note'],
            );
      final name = selection?.name ?? picked?.name;
      if (name == null || !mounted || !current()) return null;
      if (p.extension(name).toLowerCase() != '.note') {
        throw const FormatException('StarNote .note 파일을 선택하세요.');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('StarNote 가져오기'),
          content: const Text(
            '파일에 들어 있는 원본 PDF를 별도 보관함으로 가져옵니다. '
            '가져온 PDF에서 새 필기를 시작할 수 있습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('PDF 가져오기'),
            ),
          ],
        ),
      );
      if (confirmed != true || !current()) return null;
      const tooLarge = FormatException(
        'StarNote .note는 최대 128 MiB까지 가져올 수 있습니다.',
      );
      if (selection == null) {
        return await _readExternalDocument(
          picked!.length,
          picked.readAsByteStream,
          maxBytes: starNoteArchiveMaxBytes,
          tooLarge: tooLarge,
          current: current,
        );
      }
      final staged = await source.stage(selection);
      if (!current()) return null;
      return await _readExternalDocument(
        staged.file.length,
        staged.file.openRead,
        expectedLength: staged.bytes,
        maxBytes: starNoteArchiveMaxBytes,
        tooLarge: tooLarge,
        current: current,
      );
    } finally {
      if (selection != null) await source.release(selection.id);
    }
  }

  Future<Uint8List?> _readExternalDocument(
    Future<int?> Function() getLength,
    Stream<List<int>> Function() openRead, {
    int? expectedLength,
    required int maxBytes,
    required FormatException tooLarge,
    required bool Function() current,
  }) async {
    if (expectedLength != null && expectedLength > maxBytes) throw tooLarge;
    const lengthMismatch = FormatException('선택한 문서의 파일 크기를 확인하지 못했습니다.');
    final length = await getLength();
    if (!mounted || !current()) return null;
    if (length != null && length > maxBytes) throw tooLarge;
    if (expectedLength != null && length != expectedLength)
      throw lengthMismatch;
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in openRead()) {
      if (!mounted || !current()) return null;
      if (chunk.length > maxBytes - bytes.length) throw tooLarge;
      if (expectedLength != null &&
          chunk.length > expectedLength - bytes.length) {
        throw lengthMismatch;
      }
      bytes.add(chunk);
    }
    if (expectedLength != null && bytes.length != expectedLength)
      throw lengthMismatch;
    return bytes.takeBytes();
  }

  static const _openImportedVaultFromDevice = '기기의 저장소에서 가져온 보관함을 열 수 있습니다.';

  Future<void> _selectImportedVault(
    WorkspaceController c,
    NoteRepository next,
    bool Function() current,
    String summary,
  ) async {
    try {
      if (mounted && current()) await c.replaceRepository(next);
    } catch (error) {
      if (identical(c.repository, next)) rethrow;
      throw StateError('$summary $_openImportedVaultFromDevice ($error)');
    } finally {
      if (!identical(c.repository, next)) await next.close();
    }
    if (!mounted) return;
    final selected = identical(controller, c) && identical(c.repository, next);
    if (selected) {
      _pendingPdf = null;
      _pendingPdfScope = null;
      _targetPage = null;
      markdownTab = false;
      _scaffold.currentState?.closeDrawer();
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          selected ? summary : '$summary $_openImportedVaultFromDevice',
        ),
      ),
    );
  }

  Widget _library(WorkspaceController c) {
    int depth(VaultFolder folder) {
      var count = 0;
      var id = folder.parentId;
      final seen = <String>{folder.id};
      while (id != null && seen.add(id)) {
        final parent = c.folders.where((f) => f.id == id).firstOrNull;
        if (parent == null) break;
        count++;
        id = parent.parentId;
      }
      return count;
    }

    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 28, 20, 20),
          child: Text(
            'Personal Ink Vault',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.library_books_outlined),
          title: const Text('내 문서'),
          selected: c.currentFolderId == null && !c.showDeleted,
          onTap: busy
              ? null
              : () => _run(() async {
                  c.showDeleted = false;
                  await c.refresh();
                  await _goFolder(null);
                }),
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('휴지통'),
          selected: c.showDeleted,
          onTap: busy
              ? null
              : () => _run(() async {
                  await _goFolder(null);
                  c.showDeleted = true;
                  await c.refresh();
                }),
        ),
        const Divider(),
        ListTile(
          title: const Text('폴더'),
          trailing: IconButton(
            tooltip: '새 폴더',
            onPressed: busy
                ? null
                : () => _run(() => _createDocument(LibraryCreateAction.folder)),
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        ),
        Expanded(
          child: ListView(
            children: [
              for (final folder in c.folders.where(
                (f) => !f.trashed || f.deletionConflict,
              ))
                Padding(
                  padding: EdgeInsets.only(
                    left: (depth(folder).clamp(0, 6) * 12).toDouble(),
                  ),
                  child: ListTile(
                    leading: Icon(
                      folder.deletionConflict
                          ? Icons.warning_amber
                          : Icons.folder_outlined,
                    ),
                    title: Text(
                      folder.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: folder.id == c.currentFolderId,
                    onTap: busy ? null : () => _run(() => _goFolder(folder.id)),
                    trailing: PopupMenuButton<LibraryFolderAction>(
                      onSelected: (action) =>
                          _run(() => _folderAction(folder, action)),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: LibraryFolderAction.rename,
                          child: Text('이름 변경'),
                        ),
                        PopupMenuItem(
                          value: LibraryFolderAction.move,
                          child: Text('이동'),
                        ),
                        PopupMenuItem(
                          value: LibraryFolderAction.trash,
                          child: Text('휴지통으로'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_driveConnection case final drive?) DrivePanel(controller: drive),
        Wrap(
          children: [
            TextButton(
              onPressed: busy ? null : () => _run(_localVaults),
              child: const Text('기기의 저장소'),
            ),
            TextButton(
              onPressed: busy ? null : () => _run(_backup),
              child: const Text('백업 내보내기'),
            ),
            TextButton(
              onPressed: busy || c.externalBusy || c.native == null
                  ? null
                  : () => _run(_exportObsidianVault),
              child: const Text('Obsidian 보관함 ZIP'),
            ),
            TextButton(
              onPressed: busy ? null : () => _run(_restore),
              child: const Text('별도 저장소로 복원'),
            ),
          ],
        ),
      ],
    );
  }

  List<Widget> _toolbarActions(
    WorkspaceController c,
    NoteSession? session, {
    required bool compact,
  }) {
    final repository = c.repository;
    final mcp = _mcp;
    final kind = session?.note.documentKind;
    final canvasExport = kind == VaultDocumentKind.canvas;
    final formats = <(PortableExportFormat, String)>[
      if (kind == VaultDocumentKind.page ||
          kind == VaultDocumentKind.database) ...[
        (PortableExportFormat.markdown, 'Markdown'),
        (PortableExportFormat.html, 'HTML'),
        if (kind == VaultDocumentKind.database)
          (PortableExportFormat.csv, 'CSV'),
        (PortableExportFormat.pdf, 'PDF'),
      ],
    ];
    final documentExport = canvasExport || formats.isNotEmpty;
    final vaultExport = session != null && c.native != null;
    final showExport = documentExport || (vaultExport && !compact);
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repository) &&
        identical(c.activeSession, session);
    void export(Future<void> Function() operation) {
      if (current() && !busy && !c.externalBusy) unawaited(_run(operation));
    }

    PopupMenuItem<void> vaultExportItem() => PopupMenuItem<void>(
      key: const ValueKey('workspace-vault-export'),
      enabled: !busy && !c.externalBusy,
      onTap: () => export(_exportObsidianVault),
      child: const Text('Obsidian 보관함 ZIP'),
    );

    final quickSwitch = _WorkspaceToolbarAction(
      '빠른 문서 전환',
      Icons.search,
      busy || c.externalBusy ? null : _quickSwitch,
      key: const ValueKey('workspace-quick-switch'),
    );
    final navigationActions = [
      if (!compact || session != null) quickSwitch,
      if (repository.formatVersion >= 2)
        _WorkspaceToolbarAction(
          '북마크',
          Icons.format_list_bulleted,
          busy || c.externalBusy ? null : _bookmarks,
          key: const ValueKey('workspace-bookmarks'),
        ),
      if (mcp != null)
        _WorkspaceToolbarAction(
          '다른 AI 연결 · MCP',
          Icons.smart_toy_outlined,
          () => showDialog<void>(
            context: context,
            builder: (_) => McpPanel(access: mcp),
          ),
        ),
      if (c.native != null)
        _WorkspaceToolbarAction(
          '문서 연결 · 태그 · 그래프',
          Icons.hub_outlined,
          busy ? null : _knowledge,
        ),
    ];
    final linkActions = [
      if (session != null && !c.pdfPeerPreview)
        _WorkspaceToolbarAction(
          '현재 페이지 링크 복사',
          Icons.link,
          () => _run(() async {
            if (session.note.documentKind == VaultDocumentKind.office) {
              final repository = c.repository;
              final office = _office.currentState;
              final link = await office?.saveCurrentPageLink();
              if (!mounted ||
                  !identical(controller, c) ||
                  !identical(c.repository, repository) ||
                  !identical(c.activeSession, session) ||
                  !identical(_office.currentState, office)) {
                return;
              }
              if (link == null) {
                throw StateError('Office의 PDF 필기 페이지를 연 뒤 링크를 복사하세요.');
              }
              await Clipboard.setData(ClipboardData(text: link.toString()));
              return;
            }
            final editor = _editor.currentState;
            final page = editor?.coreInfo.pages
                .elementAtOrNull(editor.currentPageIndex)
                ?.pageId;
            await Clipboard.setData(
              ClipboardData(text: NoteLink(session.note.id, page).toString()),
            );
          }),
        ),
      _WorkspaceToolbarAction(
        '노트 링크 열기',
        Icons.open_in_new,
        () => _run(() async {
          final link = await _input('inkvault 링크 열기', '');
          if (link != null) await _openLink(link);
        }),
      ),
    ];

    return [
      if (compact && session == null) quickSwitch.button(),
      if (!compact)
        for (final action in navigationActions) action.button(),
      if (session != null) ...[
        if (showExport)
          PopupMenuButton<void>(
            key: const ValueKey('portable-export-menu'),
            tooltip: documentExport ? '문서 내보내기' : '보관함 내보내기',
            enabled: !busy && !c.externalBusy,
            icon: const Icon(Icons.file_download_outlined),
            itemBuilder: (_) => [
              if (canvasExport)
                PopupMenuItem<void>(
                  onTap: () => export(_exportObsidianCanvas),
                  child: const Text('Obsidian Canvas ZIP'),
                ),
              for (final (format, label) in formats)
                PopupMenuItem<void>(
                  onTap: () => export(() => _exportDocument(format)),
                  child: Text(label),
                ),
              if (vaultExport) ...[
                if (documentExport) const PopupMenuDivider(),
                vaultExportItem(),
              ],
            ],
          ),
        IconButton(
          tooltip: '기기에 저장',
          onPressed: () => _run(_save),
          icon: const Icon(Icons.save_outlined),
        ),
        if (session.note.documentKind == VaultDocumentKind.pdf &&
            _pdfCanvasVisible())
          IconButton(
            tooltip: 'PDF 본문 검색',
            onPressed: busy || !c.canSearchPdfText(session)
                ? null
                : () => unawaited(_showPdfTextSearch(c, session)),
            icon: const Icon(Icons.search),
          ),
        if (session.note.documentKind == VaultDocumentKind.pdf &&
            _pdfCanvasVisible() &&
            _keepsOriginal(c, session))
          IconButton(
            key: const ValueKey('pdf-remake-from-original'),
            tooltip: '새 엔진으로 PDF 다시 만들기',
            onPressed: busy || c.externalBusy
                ? null
                : () => _run(() => _remakePdfFromOriginal(c, session)),
            icon: const Icon(Icons.autorenew),
          ),
      ],
      if (compact)
        PopupMenuButton<void>(
          key: const ValueKey('workspace-more-actions'),
          tooltip: '더 많은 작업',
          icon: const Icon(Icons.more_vert),
          itemBuilder: (_) => [
            if (vaultExport && !showExport) ...[
              vaultExportItem(),
              const PopupMenuDivider(),
            ],
            for (final action in [...navigationActions, ...linkActions])
              PopupMenuItem<void>(
                key: action.key,
                enabled: action.onPressed != null,
                onTap: () {
                  if (current()) action.onPressed?.call();
                },
                child: Text(action.label),
              ),
          ],
        )
      else
        for (final action in linkActions) action.button(),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null)
      return Scaffold(
        body: Center(
          child: _startupError == null
              ? const CircularProgressIndicator()
              : Text('저장소를 열 수 없습니다: $_startupError'),
        ),
      );
    final session = c.activeSession;
    final pdfNote = session?.note.documentKind == VaultDocumentKind.pdf;
    final extraPdfAction = c.native != null && pdfNote;
    final keptOriginalAction = pdfNote && _keepsOriginal(c, session!);
    return LayoutBuilder(
      builder: (context, constraints) => _buildWorkspace(
        context,
        c,
        compactToolbar:
            constraints.maxWidth <
            540 +
                (extraPdfAction ? kMinInteractiveDimension : 0) +
                (keptOriginalAction ? kMinInteractiveDimension : 0),
      ),
    );
  }

  Widget _buildWorkspace(
    BuildContext context,
    WorkspaceController c, {
    required bool compactToolbar,
  }) {
    final session = c.activeSession;
    final selectingLibrary = _librarySelection == _librarySelectionScope(c);
    final pdfPeerPreview = c.pdfPeerPreview;
    final desktop = defaultTargetPlatform != TargetPlatform.android;
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final showLibraryRail = wide && (desktop || session == null);
    Widget body;
    if (session == null) {
      _dataview = null;
      body = LibraryHome(
        thumbnails: _thumbnails,
        onPreviewRequested: (note) => unawaited(_requestThumbnail(note)),
        notes: c.notes,
        folders: c.folders,
        currentFolderId: c.currentFolderId,
        showTrash: c.showDeleted,
        selecting: selectingLibrary,
        selectionBusy: selectingLibrary && (busy || c.externalBusy),
        allowBatchMove: c.repository.formatVersion >= 2,
        onSelectionChanged: (selecting) {
          if (busy || c.externalBusy) return;
          setState(() {
            _librarySelection = selecting ? _librarySelectionScope(c) : null;
          });
        },
        onBatchAction: _batchNoteAction,
        availableCreateActions: {
          LibraryCreateAction.handwriting,
          if (c.canCreateDocument) LibraryCreateAction.quickNote,
          LibraryCreateAction.infinite,
          LibraryCreateAction.office,
          LibraryCreateAction.wordDocument,
          LibraryCreateAction.presentation,
          LibraryCreateAction.hwpx,
          LibraryCreateAction.image,
          LibraryCreateAction.camera,
          LibraryCreateAction.markdown,
          if (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.android) ...{
            if (c.repository.formatVersion >= 2) ...{
              LibraryCreateAction.dailyNote,
              LibraryCreateAction.datedNote,
              LibraryCreateAction.dailyNoteTemplate,
            },
            LibraryCreateAction.obsidianVault,
            LibraryCreateAction.notionZip,
            if (c.canCreateDocument) LibraryCreateAction.starnote,
          },
          LibraryCreateAction.canvas,
          LibraryCreateAction.page,
          LibraryCreateAction.database,
          LibraryCreateAction.pdf,
          LibraryCreateAction.folder,
        },
        onOpenNote: (note) => _run(() => _open(note)),
        searchBodyMatches: c.searchBodyMatches,
        onOpenBodyMatch: (note, match) =>
            _run(() => _open(note, bodyMatch: match)),
        onOpenFolder: (id) => _run(() => _goFolder(id)),
        onCreate: (action) => _run(() => _createDocument(action)),
        onNoteAction: (note, action) => _run(() => _noteAction(note, action)),
        onFolderAction: (folder, action) =>
            _run(() => _folderAction(folder, action)),
        onSearchChanged: (query) {
          setState(() {
            c.setSearchQuery(
              query,
              bookmark: c.searchesFromBookmark,
              literal: c.searchesLiterally,
              expression: !c.showDeleted && c.searchesWithOperators,
            );
          });
          unawaited(c.refresh());
        },
        onSearchExpressionChanged: (enabled) {
          setState(() {
            c.setSearchQuery(
              c.query,
              bookmark: c.searchesFromBookmark,
              expression: enabled,
            );
          });
          unawaited(c.refresh());
        },
        searchQuery: c.query,
        searchAcrossFolders: c.searchesAcrossFolders,
        searchExpression: c.searchesWithOperators,
        searchPending: c.searchPending,
        searchError: c.searchError,
      );
    } else {
      final identity = '${session.note.id}/${c.editorGeneration}';
      if (_editorIdentity != identity) {
        if (c.hasPendingInkPageLink(session)) {
          _targetPage = null;
          markdownTab = false;
        }
        _editor = GlobalKey<EditorState>();
        _infinite = GlobalKey<InfiniteCanvasState>();
        _office = GlobalKey<OfficeWorkspaceState>();
        _cards = GlobalKey<CardCanvasState>();
        _page = GlobalKey<BlockPageEditorState>();
        _database = GlobalKey<DatabaseEditorState>();
        _databaseContents =
            session.note.documentKind == VaultDocumentKind.database
            ? _loadDatabaseContents(c, session)
            : null;
        if (session.note.documentKind == VaultDocumentKind.database) {
          _relatedEpoch = c.repositoryGeneration;
          _relatedDatabases = _loadRelatedDatabases(c.repository);
        }
        _pageContents = session.note.documentKind == VaultDocumentKind.page
            ? _loadPageContents(c, session)
            : null;
        _syncedBlockAccess = session.note.documentKind == VaultDocumentKind.page
            ? _syncedAccess(c, session)
            : null;
        final linkedRepository = c.repository;
        final linkedEpoch = c.repositoryGeneration;
        _linkedDatabaseAccess =
            session.note.documentKind == VaultDocumentKind.page
            ? LinkedDatabaseAccess(
                owner: session,
                isCurrent: () =>
                    mounted &&
                    identical(c.activeSession, session) &&
                    identical(c.repository, linkedRepository) &&
                    c.repositoryGeneration == linkedEpoch,
                open: (id) => c.openLinkedDatabase(id, owner: session),
                save: (link, database, files) =>
                    c.saveLinkedDatabase(link, database, mediaFiles: files),
                readMedia: c.readLinkedDatabaseRowMedia,
                loadDatabases: () async =>
                    (await _loadRelatedDatabases(linkedRepository))
                        .map((id, source) => MapEntry(id, source.database)),
                queryRuntime: c.native == null
                    ? null
                    : DatabaseQueryRuntime(invoke: c.native!.invoke),
                actionRuntime: c.native == null
                    ? null
                    : DatabaseActionRuntime(
                        deviceId: linkedRepository.deviceId,
                        invoke: c.native!.invoke,
                      ),
              )
            : null;
        _cardContents = session.note.documentKind == VaultDocumentKind.canvas
            ? _loadCardContents(c, session)
            : null;
        _cardRaster = null;
        _infiniteDocument =
            session.note.documentKind == VaultDocumentKind.infinite
            ? c.loadInfinite(session: session)
            : null;
        _editorIdentity = identity;
      }
      final standaloneMarkdown =
          session.note.documentKind == VaultDocumentKind.markdown;
      final infinite = session.note.documentKind == VaultDocumentKind.infinite;
      final office = session.note.documentKind == VaultDocumentKind.office;
      final cards = session.note.documentKind == VaultDocumentKind.canvas;
      final page = session.note.documentKind == VaultDocumentKind.page;
      final database = session.note.documentKind == VaultDocumentKind.database;
      final ink = database
          ? FutureBuilder<(WorkspaceDatabase, List<BlockPageNote>)>(
              key: ValueKey('database-contents-$identity'),
              future: _databaseContents,
              builder: (_, snapshot) {
                if (snapshot.hasError)
                  return Center(
                    child: Text('데이터베이스를 열 수 없습니다: ${snapshot.error}'),
                  );
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                return FutureBuilder<Map<String, _RelatedDatabaseSource>>(
                  future: _relatedDatabases,
                  builder: (_, related) {
                    final sources =
                        related.data ??
                        const <String, _RelatedDatabaseSource>{};
                    final dashboardSourcesReady =
                        related.connectionState == ConnectionState.done &&
                        c.repositoryGeneration == _relatedEpoch;
                    return Column(
                      children: [
                        if (related.hasError)
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: Text(
                              '연결된 데이터베이스 일부를 읽지 못했습니다. 다른 판본이나 동기화 상태를 확인하세요.',
                            ),
                          ),
                        Expanded(
                          child: DatabaseEditor(
                            key: _database,
                            initialDatabase: snapshot.data!.$1,
                            notes: snapshot.data!.$2,
                            databases: sources.map(
                              (id, source) => MapEntry(id, source.database),
                            ),
                            dashboardDatabaseTitles: sources.map(
                              (id, source) => MapEntry(id, source.note.title),
                            ),
                            dashboardSourcesReady: dashboardSourcesReady,
                            initialViewId:
                                c.navigation.current.noteId == session.note.id
                                ? c.navigation.current.databaseViewId
                                : null,
                            onOpenDashboardView: (databaseId, viewId) =>
                                _openDashboardView(
                                  c,
                                  session,
                                  databaseId,
                                  viewId,
                                ),
                            currentRevision: () => session.inkParents.single,
                            queryRuntime: c.native == null
                                ? null
                                : DatabaseQueryRuntime(
                                    invoke: c.native!.invoke,
                                  ),
                            actionRuntime: c.native == null
                                ? null
                                : DatabaseActionRuntime(
                                    deviceId: c.repository.deviceId,
                                    invoke: c.native!.invoke,
                                  ),
                            onSave: (value) =>
                                c.saveDatabase(value, session: session),
                            onSaveWithMedia: (value, files) => c.saveDatabase(
                              value,
                              session: session,
                              mediaFiles: files,
                            ),
                            onReadRowMedia: (rowId, media) =>
                                c.readDatabaseRowMedia(
                                  rowId,
                                  media,
                                  session: session,
                                ),
                            onDirtyChanged: (value) =>
                                c.setInkDirty(value, session: session),
                            onBusyChanged: (value) =>
                                c.setInkBusy(value, session: session),
                            onBack: () => unawaited(_back()),
                            onHistory:
                                c.repository.formatVersion == 2 &&
                                    !session.note.trashed &&
                                    !session.note.deletionConflict
                                ? () => unawaited(
                                    _run(() => _databaseHistory(c, session)),
                                  )
                                : null,
                            onOpenNote: (id) => _run(() => _openTab(id)),
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            )
          : page
          ? FutureBuilder<
              (BlockPageDocument, List<BlockPageNote>, List<BlockPageNote>)
            >(
              key: ValueKey('page-contents-$identity'),
              future: _pageContents,
              builder: (_, snapshot) {
                if (snapshot.hasError)
                  return Center(
                    child: Text('페이지를 열 수 없습니다: ${snapshot.error}'),
                  );
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                return BlockPageEditor(
                  key: _page,
                  initialDocument: snapshot.data!.$1,
                  enableColumns: true,
                  linkedDatabaseAccess: _linkedDatabaseAccess,
                  syncedBlockAccess: _syncedBlockAccess,
                  databaseNotes: snapshot.data!.$3,
                  onHistory: () => _run(_blockPageHistory),
                  onDiscussion:
                      c.repository.formatVersion == 2 && !session.note.trashed
                      ? (blockId, selection) => unawaited(
                          _run(
                            () =>
                                _pageDiscussion(c, session, blockId, selection),
                          ),
                        )
                      : null,
                  notes: snapshot.data!.$2,
                  onSave: (document) =>
                      c.saveBlockPage(document, session: session),
                  onSaveWithMedia: (document, files) => c.saveBlockPage(
                    document,
                    session: session,
                    mediaFiles: files,
                  ),
                  onReadMedia: (media) =>
                      c.readBlockPageMedia(media, session: session),
                  onDirtyChanged: (value) =>
                      c.setInkDirty(value, session: session),
                  onBusyChanged: (value) =>
                      c.setInkBusy(value, session: session),
                  onBack: () => unawaited(_back()),
                  onOpenNote: (id) => _run(() => _openTab(id)),
                );
              },
            )
          : cards
          ? FutureBuilder<(CardCanvasDocument, List<CardCanvasNote>)>(
              future: _cardContents,
              builder: (_, snapshot) {
                if (snapshot.hasError)
                  return Center(
                    child: Text('카드 캔버스를 열 수 없습니다: ${snapshot.error}'),
                  );
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                final view = c.navigation.infiniteViewport(session.note.id);
                final raster = _cardRasterReader(c, session);
                return CardCanvas(
                  key: _cards,
                  initialDocument: snapshot.data!.$1,
                  notes: snapshot.data!.$2,
                  loadRaster: raster?.read,
                  rasterScope: raster,
                  initialViewport: CardCanvasViewport(
                    offset: view?.offset ?? Offset.zero,
                    scale: view?.scale ?? 1,
                  ),
                  fitOnFirstLayout:
                      view == null &&
                      session.note.obsidianAttachmentName != null,
                  onSaveViewport: (viewport) => c.rememberInfiniteView(
                    session.note.id,
                    InfiniteViewport(
                      offset: viewport.offset,
                      scale: viewport.scale,
                    ),
                  ),
                  onSave: (document) =>
                      c.saveCardCanvas(document, session: session),
                  onDirtyChanged: (value) =>
                      c.setInkDirty(value, session: session),
                  onBusyChanged: (value) =>
                      c.setInkBusy(value, session: session),
                  onBack: () => unawaited(_back()),
                  onOpenFile: (node) => _run(() => _openCanvasFile(node)),
                  onOpenExternal: (url) => _run(() => _openLink(url)),
                );
              },
            )
          : office
          ? OfficeWorkspace(
              key: _office,
              showBackButton: false,
              repository: c.repository,
              note: session.note,
              previewEngine: widget.officePreviewEngine,
              pageLink: identical(_officePageLink?.session, session)
                  ? _officePageLink?.request
                  : null,
              onPageLinkHandled: (request) {
                if (identical(_officePageLink?.request, request)) {
                  _officePageLink = null;
                }
              },
              onDirtyChanged: (value) => c.setInkDirty(value, session: session),
              onBusyChanged: (value) => c.setInkBusy(value, session: session),
              onBack: () => unawaited(_back()),
              onPdfCopy: (prepare) => _run(() async {
                final repository = c.repository;
                final folder = c.currentFolderId;
                bool current() =>
                    mounted &&
                    identical(controller, c) &&
                    identical(c.repository, repository) &&
                    identical(c.activeSession, session) &&
                    c.currentFolderId == folder;
                if (!current()) return;
                await _save();
                if (!current()) return;
                final copy = await prepare();
                if (copy == null || !current()) return;
                final pdf = await _importConvertedOfficePdf(
                  c,
                  title: '${session.note.title} (PDF)',
                  fileName: copy.fileName,
                  bytes: copy.bytes,
                  pageCount: copy.pageCount,
                  pageNumber: copy.pageNumber,
                  isCurrent: current,
                );
                _finishOfficeImport(c, repository, pdf);
              }),
              onConvertedCopy: (copy) => _run(() async {
                if (identical(controller, c) &&
                    c.activeSession?.note.id == session.note.id) {
                  await _open(copy);
                }
              }),
            )
          : infinite
          ? FutureBuilder<InfiniteDocument>(
              future: _infiniteDocument,
              builder: (_, snapshot) {
                if (snapshot.hasError)
                  return Center(
                    child: Text('무한 노트를 열 수 없습니다: ${snapshot.error}'),
                  );
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());
                return InfiniteCanvas(
                  key: _infinite,
                  initialDocument: snapshot.data!,
                  initialViewport:
                      c.navigation.infiniteViewport(session.note.id) ??
                      const InfiniteViewport(),
                  onSaveViewport: (viewport) =>
                      c.rememberInfiniteView(session.note.id, viewport),
                  onSave: (document) =>
                      c.saveInfinite(document, session: session),
                  onDirtyChanged: (value) =>
                      c.setInkDirty(value, session: session),
                  onBusyChanged: (value) =>
                      c.setInkBusy(value, session: session),
                );
              },
            )
          : session.note.documentKind == VaultDocumentKind.pdf &&
                c.pdfImportError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.picture_as_pdf_outlined, size: 48),
                    const SizedBox(height: 16),
                    Text(c.pdfImportError!, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      key: const ValueKey('pdf-import-retry'),
                      onPressed: busy
                          ? null
                          : () =>
                                _run(() => c.retryPdfImport(session: session)),
                      icon: const Icon(Icons.refresh),
                      label: const Text('PDF 가져오기 다시 시도'),
                    ),
                  ],
                ),
              ),
            )
          : standaloneMarkdown
          ? const SizedBox.shrink()
          : Editor(
              key: _editor,
              path: '/.working/${session.note.id}/new/main',
              customTitle: session.note.title,
              showDocumentHeader: false,
              pdfPath: pdfPeerPreview
                  ? c.pdfPeerPreviewPath
                  : c.pendingPdfPath ?? _pendingPdf,
              initialPdfBaselinePageId: pdfPeerPreview ? (_) => newId() : null,
              workspaceReadOnly: pdfPeerPreview,
              loadSnapshot: () async {
                final core = await c.loadInk(session: session);
                if (_targetPage != null && !pdfPeerPreview) {
                  final index = core.pages.indexWhere(
                    (page) => page.pageId == _targetPage,
                  );
                  if (index >= 0) {
                    core.initialPageIndex = index;
                  } else if (!identical(_rememberedPageSession, session)) {
                    core.dispose();
                    throw StateError('연결된 페이지를 찾을 수 없습니다.');
                  }
                }
                return core;
              },
              onSaveSnapshot: (core, page) =>
                  c.saveInk(core, page, session: session),
              onDirtyChanged: pdfPeerPreview
                  ? null
                  : (value) => c.setInkDirty(value, session: session),
              onBusyChanged: pdfPeerPreview
                  ? null
                  : (value) => c.setInkBusy(value, session: session),
              onLoaded: (core) {
                if (identical(c.activeSession, session) && !pdfPeerPreview) {
                  _pendingPdf = null;
                  final linkedInk = c.resolveLinkedInkPage(session, core);
                  final target =
                      linkedInk ?? c.resolvePdfPageLink(session, core);
                  if (target != null) {
                    unawaited(
                      _followInkPageLink(
                        c,
                        session,
                        target,
                        linkedInkPage: linkedInk != null,
                      ),
                    );
                  }
                }
                _sharedDocument();
              },
              onCancelImport: pdfPeerPreview
                  ? null
                  : () => _run(() async {
                      _pendingPdf = null;
                      _targetPage = null;
                      await c.cancelPendingImport(session: session);
                    }),
              onBack: () => unawaited(_back()),
            );
      final index = c.knowledge;
      final repository = c.repository;
      final editorGeneration = c.editorGeneration;
      final note = session.note;
      final markdownSource = c.markdown;
      final scope = (repository, session, index, c.repositoryGeneration);
      final requested = _searchSelection;
      final bodyMatch =
          requested != null &&
              markdownTab &&
              !c.markdownDirty &&
              !c.remoteConflict &&
              c.navigation.current.markdownAnchor == null &&
              identical(requested.session, session) &&
              session.markdownParents.singleOrNull ==
                  requested.match.markdownRevisionId
          ? requested.match
          : null;
      final markdown = MarkdownEditor(
        key: ValueKey(session.note.id),
        source: markdownSource,
        readOnly: false,
        dirty: c.markdownDirty,
        onChanged: (value) => c.editMarkdown(value, session: session),
        onSave: () => _run(c.saveMarkdown),
        onOpenLink: (url) => _run(() => _openLink(url)),
        loadVaultImage: index == null
            ? null
            : (href) => _readVaultRaster(c, scope, href),
        vaultImageScope: scope,
        dataview: _dataviewAccess(c, scope),
        templates: repository.formatVersion < 2
            ? null
            : MarkdownTemplateAccess(
                store: WorkspaceMarkdownTemplateStore(repository),
                title: note.title,
                isCurrent: () =>
                    mounted &&
                    identical(controller, c) &&
                    identical(c.repository, repository) &&
                    c.editorGeneration == editorGeneration &&
                    identical(c.activeSession, session) &&
                    c.markdown == markdownSource &&
                    session.note.revision.revisionId ==
                        note.revision.revisionId,
              ),
        vaultEmbeds: index == null
            ? null
            : VaultMarkdownEmbedAccess(
                sourceNoteId: session.note.id,
                load: (href, from) =>
                    _readVaultMarkdownEmbed(c, scope, href, from),
                openLink: (href, from) {
                  if (_currentVaultMarkdown(c, scope)) {
                    unawaited(_run(() => _openLink(href, fromNoteId: from)));
                  }
                },
                loadImage: (href, from) =>
                    _readVaultRaster(c, scope, href, fromNoteId: from),
                loadPdf: (href, from, page, cancelled) =>
                    _readVaultPdfPreview(c, scope, href, from, page, cancelled),
              ),
        targetAnchor: markdownTab ? c.navigation.current.markdownAnchor : null,
        anchorRequest: _markdownAnchorRequest,
        searchSelection: bodyMatch == null
            ? null
            : (
                start: bodyMatch.start,
                end: bodyMatch.end,
                text: bodyMatch.text,
              ),
        searchSelectionRequest: _searchSelectionRequest,
        anchorResolver: c.native == null
            ? null
            : (anchor, candidates) =>
                  c.native!.invoke({
                        'op': 'resolve_markdown_anchor',
                        'anchor': anchor,
                        'candidates': candidates,
                      })['candidateIndex']
                      as int?,
      );
      body = standaloneMarkdown
          ? markdown
          : desktop && wide
          ? Row(
              children: [
                Expanded(flex: 3, child: ink),
                const VerticalDivider(width: 1),
                Expanded(flex: 2, child: markdown),
              ],
            )
          : IndexedStack(index: markdownTab ? 1 : 0, children: [ink, markdown]);
    }
    final workspace = PopScope(
      canPop:
          !selectingLibrary &&
          session == null &&
          c.currentFolderId == null &&
          !busy &&
          !c.dirty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        key: _scaffold,
        appBar: AppBar(
          leading:
              !selectingLibrary && session == null && c.currentFolderId == null
              ? null
              : IconButton(
                  key: selectingLibrary
                      ? const ValueKey('workspace-exit-library-selection')
                      : session == null
                      ? null
                      : const ValueKey('workspace-back-to-library'),
                  tooltip: selectingLibrary
                      ? '일괄 관리 닫기'
                      : session == null
                      ? '상위 폴더로'
                      : '문서 목록으로',
                  onPressed: busy ? null : () => unawaited(_back()),
                  icon: const Icon(Icons.arrow_back),
                ),
          title: Text(
            session?.note.title ?? 'Personal Ink Vault',
            maxLines: compactToolbar ? 1 : null,
            overflow: compactToolbar ? TextOverflow.ellipsis : null,
          ),
          actions: _toolbarActions(c, session, compact: compactToolbar),
        ),
        drawer: wide ? null : Drawer(child: _library(c)),
        body: Row(
          children: [
            if (showLibraryRail) SizedBox(width: 300, child: _library(c)),
            if (showLibraryRail) const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  if (c.navigation.tabs.isNotEmpty ||
                      c.navigation.peekBack != null)
                    _documentTabs(c),
                  if (busy ||
                      c.externalBusy ||
                      StudyWorkspace.pendingDocumentImport.processing)
                    const LinearProgressIndicator(),
                  if (c.externalBusy)
                    const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('문서 변경 사항을 저장하고 있습니다.'),
                    ),
                  if (_closeError != null)
                    MaterialBanner(
                      content: Text(_closeError!),
                      actions: [
                        TextButton(
                          onPressed: busy ? null : onWindowClose,
                          child: const Text('다시 저장하고 닫기'),
                        ),
                      ],
                    ),
                  ?_sharedDocumentBanner(c),
                  if (c.error != null)
                    MaterialBanner(
                      content: Text(c.error!),
                      actions: [
                        TextButton(
                          onPressed: () => _run(c.refresh),
                          child: const Text('다시 읽기'),
                        ),
                      ],
                    ),
                  if (c.remoteConflict)
                    MaterialBanner(
                      content: const Text(
                        '다른 버전이 있습니다. 작업본과 기존 부모 리비전을 보존합니다.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => _run(_conflicts),
                          child: const Text('충돌 확인'),
                        ),
                      ],
                    ),
                  if (session != null && pdfPeerPreview)
                    MaterialBanner(
                      content: const Text(
                        '다른 기기의 첫 필기 판본을 기다리는 중입니다. '
                        '지금은 PDF를 읽기 전용으로 볼 수 있습니다.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: busy || c.dirty || c.remoteConflict
                              ? null
                              : () => _run(
                                  () => c.beginPdfInkHere(session: session),
                                ),
                          child: const Text('이 기기에서 필기 시작'),
                        ),
                      ],
                    ),
                  Expanded(
                    child: AbsorbPointer(
                      absorbing: c.externalBusy || _exporting,
                      child: ExcludeFocus(
                        excluding:
                            c.externalBusy ||
                            (_exporting &&
                                session?.note.documentKind ==
                                    VaultDocumentKind.canvas),
                        child: body,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar:
            session == null ||
                session.note.documentKind == VaultDocumentKind.markdown ||
                desktop && wide
            ? null
            : NavigationBar(
                selectedIndex: markdownTab ? 1 : 0,
                onDestinationSelected: (i) =>
                    setState(() => markdownTab = i == 1),
                destinations: [
                  NavigationDestination(
                    icon: Icon(
                      session.note.documentKind == VaultDocumentKind.page
                          ? Icons.view_agenda_outlined
                          : Icons.draw_outlined,
                    ),
                    label: session.note.documentKind == VaultDocumentKind.page
                        ? '페이지'
                        : session.note.documentKind ==
                              VaultDocumentKind.database
                        ? '데이터베이스'
                        : session.note.documentKind == VaultDocumentKind.canvas
                        ? '캔버스'
                        : 'PDF·필기',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.notes),
                    label: 'Markdown',
                  ),
                ],
              ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, control: true):
            _quickSwitch,
      },
      child: Focus(autofocus: true, child: workspace),
    );
  }

  @override
  void onWindowClose() {
    if (busy || _sharedDocumentClosing) return;
    _sharedDocumentClosing = true;
    _retireThumbnailScope();
    _automation?.pause();
    unawaited(
      _run(() async {
        var readyToClose = false;
        final drive = _driveConnection;
        try {
          await Future.wait(_retiringThumbnailWrites.toList());
          if (controller != null) {
            await _mcp?.stop();
            await _save();
          }
          if (drive != null) {
            await drive.cancelSignIn();
            await drive.setForeground(false);
          }
          readyToClose = true;
          await windowManager.setPreventClose(false);
          await windowManager.close();
        } catch (e) {
          try {
            if (readyToClose) await windowManager.setPreventClose(true);
          } finally {
            _sharedDocumentClosing = false;
            if (mounted) {
              _invalidateThumbnailScope();
              setState(() {
                _closeError = readyToClose
                    ? '창을 닫지 못했습니다: $e'
                    : '닫기 전에 저장하지 못했습니다: $e';
              });
            }
            if (_automationForeground && mounted) {
              _automation?.resume();
              unawaited(drive?.setForeground(true));
            }
          }
        }
      }),
    );
  }

  Future<void> _pauseDriveAfterSave(
    DriveConnectionController drive,
    int generation,
  ) async {
    final saving = _workspaceSave;
    if (saving != null) {
      try {
        await saving;
      } catch (_) {
        // The save caller reports its error. Previously saved changes can sync.
      }
    }
    if (mounted &&
        generation == _driveLifecycleGeneration &&
        identical(drive, _driveConnection)) {
      await drive.setForeground(false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The app's own document picker or Office engine is in front: the user has not left the app.
    if (AppExternalScreen.active) return;
    _externalScreenGrace?.cancel();
    _applyLifecycle(state);
  }

  void _externalScreenChanged() {
    _externalScreenGrace?.cancel();
    if (AppExternalScreen.active || !mounted) return;
    // The screen's result can arrive just before Android resumes the app; give it a moment.
    _externalScreenGrace = Timer(const Duration(seconds: 2), () {
      if (!mounted || AppExternalScreen.active) return;
      final state =
          WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
      if (state != _appliedLifecycle) _applyLifecycle(state);
    });
  }

  void _applyLifecycle(AppLifecycleState state) {
    _appliedLifecycle = state;
    _automationForeground = state == AppLifecycleState.resumed;
    if (_automationForeground) {
      _driveLifecycleGeneration++;
      _automation?.resume();
      _sharedDocument();
    } else {
      _automation?.pause();
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      if (controller != null && !busy) unawaited(_run(_save));
    }
    final drive = _driveConnection;
    if (drive != null && !_sharedDocumentClosing) {
      if (_automationForeground) {
        unawaited(drive.setForeground(true));
      } else if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.detached) {
        unawaited(_pauseDriveAfterSave(drive, ++_driveLifecycleGeneration));
      }
    }
  }

  @override
  void dispose() {
    _retireThumbnailScope();
    _sharedDocumentTimer?.cancel();
    _externalScreenGrace?.cancel();
    AppExternalScreen.open.removeListener(_externalScreenChanged);
    _automation?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) windowManager.removeListener(this);
    StudyWorkspace.pendingDocumentImport.removeListener(_sharedDocument);
    final workspace = controller;
    workspace?.removeListener(_changed);
    _mcp?.dispose();
    final ownsWorkspace = widget.controller == null;
    final drive = _driveConnection;
    if (drive != null) {
      unawaited(
        drive.close().whenComplete(() {
          if (ownsWorkspace) workspace?.dispose();
        }),
      );
    } else if (ownsWorkspace) {
      workspace?.dispose();
    }
    super.dispose();
  }
}
