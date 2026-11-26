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
import 'package:go_router/go_router.dart' show GoRouterHelper;
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/drive.dart' show SyncPhase;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart' show PdfDocument, PdfImage, PdfImageExt;
import 'package:saber/components/drive/drive_panel.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/components/ink_ui/kit_tab_row.dart';
import 'package:saber/components/kit/kit_icons.g.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_toolbar.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/components/toolbar/note_function_row.dart';
import 'package:saber/components/toolbar/shortcut_bar_editor.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
import 'package:saber/components/user_error_text.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
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
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_editor_events.dart';
import 'package:saber/data/office/office_open_edits.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/pdf_note_original.dart';
import 'package:saber/data/planner/handwriting_recognizer.dart';
import 'package:saber/data/planner/planner_platform.dart';
import 'package:saber/data/planner/planner_store.dart';
import 'package:saber/data/planner/planner_widget_sync.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/routes.dart';
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
import 'package:saber/data/vault/document_facts.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_marks.dart';
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
import 'package:saber/pages/editor/editor_chrome.dart';
import 'package:saber/pages/office/office_workspace.dart';
import 'package:saber/pages/planner/calendar_page.dart';
import 'package:saber/pages/planner/planner_screen.dart';
import 'package:saber/pages/planner/reminder_page.dart';
import 'package:saber/pages/settings/app_settings_page.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/block_page_history_sheet.dart';
import 'package:saber/pages/workspace/card_canvas.dart';
import 'package:saber/pages/workspace/daily_note_template_settings_dialog.dart';
import 'package:saber/pages/workspace/database_editor.dart';
import 'package:saber/pages/workspace/database_history_sheet.dart';
import 'package:saber/pages/workspace/import_jobs.dart';
import 'package:saber/pages/workspace/infinite_canvas.dart';
import 'package:saber/pages/workspace/knowledge_panel.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/library_menus.dart';
import 'package:saber/pages/workspace/linked_database_block.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/office_editor_hosts.dart';
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

part 'workspace_actions.dart';

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

/// The drawer's three tabs (설계 1.9절).
enum _DrawerTab { browse, folders, labels }

/// The + menu's imports of one Office·한글 format each (설계 2.2절): the
/// extensions a chosen file must have and the types the Android picker offers.
const _officeImportFormats = {
  LibraryCreateAction.importPpt: (
    label: 'PPT',
    extensions: ['ppt', 'pptx', 'odp'],
    mimeTypes: [
      'application/vnd.ms-powerpoint',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'application/vnd.oasis.opendocument.presentation',
    ],
  ),
  LibraryCreateAction.importWord: (
    label: 'Word',
    extensions: ['doc', 'docx', 'odt'],
    mimeTypes: [
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.oasis.opendocument.text',
    ],
  ),
  LibraryCreateAction.importHwp: (
    label: '한글',
    extensions: ['hwp', 'hwpx'],
    mimeTypes: [
      'application/x-hwp',
      'application/haansofthwp',
      'application/vnd.hancom.hwp',
      'application/vnd.hancom.hwpx',
      'application/octet-stream',
    ],
  ),
};

class StudyWorkspace extends StatefulWidget {
  static final pendingDocumentImport = SharedDocumentInbox();
  final WorkspaceController? controller;
  final bool enableDrive;
  final DriveConnectionController Function(WorkspaceController)?
  createDriveConnection;
  final ThumbnailCache Function(Directory) thumbnailCacheFactory;
  final OfficePreviewEngine? officePreviewEngine;

  /// The Office documents' Android editor; tests inject one so nothing on
  /// the test machine is started.
  final AndroidOfficeEngine? officeEngine;

  /// The planner's Android side: home-screen widgets, alarms and the screen a
  /// widget tap opens. Android makes its own; a test injects one, which also
  /// turns the widgets and alarms on off Android.
  final PlannerPlatform? plannerPlatform;
  const new({
    super.key,
    this.controller,
    this.enableDrive = false,
    this.createDriveConnection,
    this.thumbnailCacheFactory = ThumbnailCache.new,
    this.officePreviewEngine,
    this.officeEngine,
    this.plannerPlatform,
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
  // The app level actions (settings, vault tools, logs); the settings page lists them. Published on every build.
  final _appActions = AppActionRegistry();
  NoteRepository? _mcpRepository;
  final _scaffold = GlobalKey<ScaffoldState>();
  // The open note's editor gives the function row its shortcuts, and its ⋯ 「문서 정보」 asks here for the file's
  // time and the Drive state.
  // The ink editor and an Office PDF's editor share it; their page links open notes here. Its registry holds the
  // open document's actions (the editor's and this screen's); the app's are found through its parent.
  late final _editorChrome = EditorChromeController(appActions: _appActions)
    ..openLink = _openEditorLink
    ..listNotes = _linkableNotes
    ..docInfo = (() => _docInfo());
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
  final _coverFacts = <String, ({int? pages, double? aspect})>{};
  // The listed documents' dates and formats, and the vault change and documents they were read for;
  // only the last read is kept.
  var _documentFacts = <String, DocumentFacts>{};

  /// The open document and its heads as last seen; new heads for the same document mean it was saved, so its
  /// 「마지막 편집」 (the tab ⌄, ⋯ 「문서 정보」) is now.
  (String, int)? _seenHeads;

  /// Whether the open document had unsaved changes when the controller last told of a change.
  var _seenDirty = false;

  /// The open ink editor's note was read-only when last heard (its toolbar folded away; the function row stays).
  var _editorReadOnly = false;
  (NoteRepository, int)? _factsScope;
  var _factsIds = const <String>[];
  var _factsRequest = 0;
  // Favourites, pins, labels and colour covers, read again when the vault or its contents change.
  // Changes are written one after another, beside the screen's own work.
  var _marks = LibraryMarks.empty;
  (NoteRepository, int)? _marksScope;
  var _marksRequest = 0;
  var _marksWrites = Future<void>.value();
  // The vault whose failed marks read was shown; each vault's is shown once.
  NoteRepository? _marksFailureShown;
  // Revision file times by revision id, for the facts reads of one vault: a committed revision file never
  // changes, so its time is read once.
  var _revisionTimes = <String, DateTime>{};
  // The planner (설계 6·7절): its two screens over the workspace, the home-screen widgets and alarms fed from
  // the open vault, and Google Calendar signed in with Drive's OAuth client.
  late final PlannerPlatform _planner;
  StreamSubscription<String>? _plannerOpens;
  // The planner screen opened last; it is open while its route is in the navigator.
  ({PlannerScreen screen, Route<void> route})? _plannerShown;
  // A widget tap that came before a vault was open; only the latest waits.
  PlannerScreen? _plannerWaiting;
  var _plannerRequests = 0;
  // The vault and change the planner last heard of. Open planner screens hear of each change.
  (NoteRepository, int)? _plannerScope;
  final _plannerChanges = ValueNotifier(0);
  Timer? _plannerWidgetTimer;
  // The home-screen widgets and alarms, and Google Calendar signed in with Drive's OAuth client.
  late final PlannerWidgetSync _plannerWidgets;
  // The drawer's tab, and what the library lists: a folder, 최근, 즐겨찾기 or a label.
  var _drawerTab = _DrawerTab.browse;
  var _libraryCollection = const LibraryCollection.folder();
  // PDF·Office·image imports running beside the library, each a card in its folder (설계 4절);
  // they belong to the vault they started in and end with it.
  late final _importJobs = ImportJobs(trash: _trashImported);
  NoteRepository? _importVault;
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
  // What the library asked the Office document it opened to do first.
  ({NoteSession session, OfficeOpenRequest request})? _officeOpenRequest;
  StreamSubscription<({String sessionId, String status})>? _editorFinishedEvents;
  // Android: each Office·한글 document whose editor is open or opening has a host the app does
  // not draw, so opening, leaving and closing the editor never change the screen behind it.
  late final _editorHosts = OfficeEditorHosts(
    onDeclined: _hostDeclined,
    onError: _hostError,
    onFinished: _hostFinished,
  );
  // Work that arrived while the workspace was busy; it runs once the current work is done.
  final _whenIdle = <Future<void> Function()>[];
  // 닫고 열기 waits here for how the editor it asked to close ended (null: left for the tabs).
  final _closeWaits = <String, Completer<OfficeEditorOutcome?>>{};
  NoteSession? _rememberedPageSession;
  ({NoteRepository repository, NoteSession? outgoing})? _documentTabChange;
  var _markdownAnchorRequest = 0;
  var _searchSelectionRequest = 0;
  ({NoteSession session, KnowledgeBodyMatch match})? _searchSelection;
  (WorkspaceController, _VaultMarkdownScope, MarkdownDataviewAccess)? _dataview;
  Object? _startupError;
  String? _closeError;
  var markdownTab = false;
  var busy = false;

  /// Folders the user folded in the sidebar tree.
  final _collapsedFolders = <String>{};
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
  static final _libraryLog = Logger('PIVLibrary');
  static final _plannerLog = Logger('PIVPlanner');
  @override
  void initState() {
    super.initState();
    _planner = widget.plannerPlatform ?? PlannerPlatform();
    _plannerWidgets = PlannerWidgetSync(
      platform: _planner,
      drive: () => _driveConnection,
    );
    // A widget or alarm tapped while the app runs; the tap that started it is taken once a vault is open.
    if (_plannerNative) {
      _plannerOpens = _planner.openRequests.listen(_plannerRequested);
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _automationForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    _appliedLifecycle = lifecycle ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    AppExternalScreen.open.addListener(_externalScreenChanged);
    DynamicMaterialApp.addFullscreenListener(_fullscreenChanged);
    if (Platform.isWindows) {
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true));
    }
    StudyWorkspace.pendingDocumentImport.addListener(_sharedDocument);
    stows.noteTabBarHidden.addListener(_tabBarHiddenChanged);
    stows.editorFingerDrawing.addListener(_fingerDrawingChanged);
    _editorChrome.addListener(_editorChromeChanged);
    _editorHosts.addListener(_editorHostsChanged);
    _editorFinishedEvents = OfficeEditorEvents.instance.editorFinished.listen(
      _onLateEditorResult,
    );
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
      // A restored Office·한글 document is not a screen on Android: its editor opens from a tap.
      // Start-up waits only when there is such a location to leave (the check reads nothing);
      // otherwise the first screen is drawn at once.
      if (_hostsEditors) {
        value.officeOpensInEditor = true;
        if (value.remembersOfficeLocation) {
          try {
            await value.leaveOfficeDocument();
            await value.forgetOfficeVisits();
          } catch (_) {
            // The restored screen stays as it was; the app still opens.
          }
        }
      }
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
      _readLibraryInfo(value);
      _plannerVaultChanged(value);
      setState(() {});
      _invalidateThumbnailScope();
      _sharedDocument();
      if (_plannerNative) unawaited(_takePlannerLaunch());
    } catch (e) {
      if (mounted) setState(() => _startupError = e);
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
      if (_officeOpenRequest case final pending?
          when !identical(c?.activeSession, pending.session)) {
        _officeOpenRequest = null;
      }
      _editorHosts.forgetOtherVaults(c?.repository);
      _noteSaves(c);
      if (!identical(_importVault, c?.repository)) {
        // Imports end with the vault they were going into: nothing is written to another one.
        _importVault = c?.repository;
        _importJobs.cancelAll();
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
        _relatedDatabases = _loadRelatedDatabases(c.repository)..ignore();
      }
      if (_mcp?.connected == true &&
          !identical(_mcpRepository, controller?.repository)) {
        unawaited(
          _mcp!.stop().catchError((Object _) {
            controller?.error = 'AI 연결을 종료했습니다. 연결 설정 파일의 정리는 다시 확인하세요.';
          }),
        );
      }
      if (c != null) _readLibraryInfo(c);
      if (c != null) _plannerVaultChanged(c);
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
    _coverFacts.clear();
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
      final facts = file == null
          ? null
          : await ThumbnailCache.readCoverFacts(file);
      if (!current()) return;
      final currentKey = await cache.coverKey(repo, note);
      if (!current() || currentKey != key) return;
      _thumbnailAttempts[note.id] = (key, generation);
      if (file != null) {
        setState(() {
          _thumbnailKeys[note.id] = key!;
          _thumbnails[note.id] = FileImage(file);
          if (facts == null) {
            _coverFacts.remove(note.id);
          } else {
            _coverFacts[note.id] = facts;
          }
        });
      } else if (_thumbnails.containsKey(note.id)) {
        setState(() {
          _thumbnailKeys.remove(note.id);
          _thumbnails.remove(note.id);
          _coverFacts.remove(note.id);
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

  /// Reads the vault's library marks when the vault or its contents change (a change event moves
  /// [WorkspaceController.repositoryGeneration]), and the facts of the listed documents when those
  /// change or other documents are listed, while the library shows: with a note open, a change is read
  /// when the library returns. A refresh that lists the same documents reads nothing. A later read
  /// replaces one still running.
  void _readLibraryInfo(WorkspaceController c) {
    final repository = c.repository;
    final scope = (repository, c.repositoryGeneration);
    final sameVault = identical(_marksScope?.$1, repository);
    if (_marksScope != scope && !(sameVault && c.activeSession != null)) {
      if (!sameVault) {
        // Another vault: nothing of the last one stays.
        _marks = LibraryMarks.empty;
        _documentFacts = {};
        _factsScope = null;
        _revisionTimes = {};
        _libraryCollection = const LibraryCollection.folder();
      }
      _marksScope = scope;
      final request = ++_marksRequest;
      _readInBackground(
        () => LibraryMarksStore(repository).read().then(
          (marks) {
            if (mounted && request == _marksRequest) {
              setState(() => _marks = marks);
            }
          },
          onError: (Object error) {
            _libraryLog.warning('Library marks were not read: $error');
            // Shown once for each vault; later reads fail quietly.
            if (mounted &&
                request == _marksRequest &&
                !identical(_marksFailureShown, repository)) {
              _marksFailureShown = repository;
              showUserErrorSnackBar(context, error);
            }
          },
        ),
      );
    }
    if (c.activeSession != null) return;
    final notes = c.notes;
    final ids = [for (final note in notes) note.id];
    if (_factsScope != scope || !listEquals(_factsIds, ids)) {
      // The same vault change with other documents listed: their facts join the ones already read.
      final merge = _factsScope == scope;
      _factsScope = scope;
      _factsIds = ids;
      final request = ++_factsRequest;
      _readInBackground(
        () => readDocumentFacts(repository, notes, times: _revisionTimes).then(
          (facts) {
            if (mounted &&
                request == _factsRequest &&
                identical(controller?.repository, repository)) {
              setState(
                () => _documentFacts = merge
                    ? {..._documentFacts, ...facts}
                    : facts,
              );
            }
          },
          onError: (Object error) {
            _libraryLog.warning('Document facts were not read: $error');
          },
        ),
      );
    }
  }

  /// Runs a library read beside the screen, in the root zone: the read takes its turn in the
  /// vault's queue of reads and writes, and it must not wait there for whatever zone noticed the
  /// change (in a widget test, the fake clock's next frame, which would hold every later vault
  /// call made in real time).
  static void _readInBackground(Future<void> Function() read) =>
      unawaited(Zone.root.run(read));

  /// What the cards show: the vault's dates and formats, with the page count
  /// and shape each cover found.
  Map<String, DocumentFacts> _libraryFacts() {
    if (_coverFacts.isEmpty) return _documentFacts;
    return {
      ..._documentFacts,
      for (final MapEntry(key: id, value: cover) in _coverFacts.entries)
        id: (_documentFacts[id] ?? const DocumentFacts()).withCover(
          pages: cover.pages,
          aspect: cover.aspect,
        ),
    };
  }

  /// Applies [change] to the marks as the vault holds them now and shows the
  /// result. Changes are written one after another, beside the screen's own
  /// work, so a heart never waits for it; a failure is shown.
  Future<void> _changeMarks(LibraryMarks Function(LibraryMarks marks) change) {
    final repository = controller!.repository;
    bool current() =>
        mounted && identical(controller?.repository, repository);
    return _marksWrites = _marksWrites
        .then((_) async {
          if (!current()) return;
          final store = LibraryMarksStore(repository);
          final marks = await store.write(change(await store.read()));
          if (!current()) return;
          // A read that started before this write would bring the old marks back.
          _marksRequest++;
          setState(() => _marks = marks);
        })
        .catchError((Object error) {
          if (mounted) showUserErrorSnackBar(context, error);
        });
  }

  /// Hearts, pins, labels and covers are kept in vault format 2: on a format-1 vault the first one asks
  /// to upgrade it, as the + menu's documents do. True when the marks can be written now.
  Future<bool> _marksWritable(WorkspaceController c) async {
    if (c.repository.formatVersion >= 2) return true;
    var upgraded = false;
    await _run(() async {
      upgraded = await _upgradeLegacyVault(c);
    });
    return upgraded && mounted && identical(controller, c);
  }

  /// A heart or a pin.
  Future<void> _mark(LibraryMarks Function(LibraryMarks marks) change) async {
    final c = controller;
    if (c != null && await _marksWritable(c)) await _changeMarks(change);
  }

  /// 라벨 추가 for [targetId], or the label list alone when it is empty (⋯ ›
  /// 라벨 색상, the drawer's 새 라벨). Labels added, renamed or recoloured in the
  /// dialog are stored with the time of this change, so they win a merge with
  /// an older copy from another device; a deleted one leaves every document
  /// (and its view closes); of [targetId]'s labels only the ones ticked or
  /// unticked here change.
  Future<void> _editLabels(String targetId) async {
    final c = controller;
    if (c == null || !await _marksWritable(c) || !mounted) return;
    final repository = c.repository;
    final shown = _marks;
    final choice = await showLibraryLabelsDialog(
      context,
      labels: shown.labels,
      selected: targetId.isEmpty
          ? null
          : shown.labelsOf[targetId] ?? const <String>{},
    );
    if (choice == null || !mounted || !identical(c.repository, repository)) {
      return;
    }
    final before = {for (final label in shown.labels) label.id: label};
    final changed = [
      for (final label in choice.labels)
        if (before[label.id]?.name != label.name ||
            before[label.id]?.color != label.color)
          label,
    ];
    final kept = {for (final label in choice.labels) label.id};
    final deleted = [
      for (final id in before.keys)
        if (!kept.contains(id)) id,
    ];
    final had = shown.labelsOf[targetId] ?? const <String>{};
    final added = choice.selected.difference(had);
    final removed = had.difference(choice.selected);
    await _changeMarks((marks) {
      final now = DateTime.now().microsecondsSinceEpoch;
      var next = marks;
      for (final id in deleted) {
        next = next.removeLabel(id);
      }
      for (final label in changed) {
        next = next.putLabel(
          LibraryLabel(
            id: label.id,
            name: label.name,
            color: label.color,
            changedAt: now,
          ),
        );
      }
      if (targetId.isEmpty) return next;
      // A label another device gave the document while the dialog was open stays.
      return next.setLabels(
        targetId,
        {...?next.labelsOf[targetId], ...added}.difference(removed),
      );
    });
    if (mounted && deleted.contains(_libraryCollection.labelId)) {
      setState(() => _libraryCollection = const LibraryCollection.folder());
    }
  }

  /// 표지 변경: the first page again, an Office·한글 original's format cover, or one of eight colours.
  Future<void> _changeCover(String targetId) async {
    final c = controller;
    if (c == null || !await _marksWritable(c) || !mounted) return;
    final repository = c.repository;
    final office = c.notes.any(
      (note) =>
          note.id == targetId && note.documentKind == VaultDocumentKind.office,
    );
    final choice = await showLibraryCoverDialog(
      context,
      current: _marks.covers[targetId]?.color,
      format: office ? _documentFacts[targetId]?.format : null,
    );
    if (choice == null || !mounted || !identical(c.repository, repository)) {
      return;
    }
    await _changeMarks((marks) => marks.setCover(targetId, choice.color));
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

  /// Starts an import beside the library (설계 4절): its card shows in the current folder while the
  /// file is read and stored, and the rest of the screen stays usable. [write] stores the file in the
  /// vault and folder the import started in.
  void _startImport(
    WorkspaceController c, {
    required String title,
    required ImportRead read,
    required Future<VaultNote> Function(
      NoteRepository repository,
      String? folderId,
      Uint8List bytes,
    )
    write,
  }) {
    // The screen closed while the picker was open: there is nothing to import into.
    if (!mounted) return;
    final repository = c.repository;
    final folderId = c.currentFolderId;
    _importVault = repository;
    _importJobs.start(
      title: title,
      folderId: folderId,
      read: read,
      write: (bytes) => write(repository, folderId, bytes),
      done: _imported,
    );
  }

  /// Imports [fileName] as a new [kind] document that keeps only the original; its pages or its
  /// cover are made later (설계 13절).
  void _importOriginal(
    WorkspaceController c, {
    required String fileName,
    required VaultDocumentKind kind,
    required ImportRead read,
  }) {
    final title = p.basenameWithoutExtension(fileName);
    _startImport(
      c,
      title: title,
      read: read,
      write: (repository, folderId, bytes) => c.createDocumentQuietly(
        expectedRepository: repository,
        title: title,
        fileName: fileName,
        bytes: bytes,
        kind: kind,
        folderId: folderId,
      ),
    );
  }

  /// Reads a chosen file for an import in chunks, telling how far it got; a cancelled import
  /// stops reading.
  static Future<Uint8List> _readForImport(
    Future<int?> Function() length,
    Stream<List<int>> Function() openRead,
    void Function(double) progress,
    bool Function() cancelled,
  ) async {
    final total = await length();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in openRead()) {
      // The cancelled import drops what was read.
      if (cancelled()) break;
      bytes.add(chunk);
      if (total != null && total > 0) progress(bytes.length / total);
    }
    return bytes.takeBytes();
  }

  /// A finished import opens nothing: the library lists it, and the message offers to open it. 열기
  /// tapped while the workspace is busy (another note opening, a save) waits for that work.
  void _imported(VaultNote note) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(importDoneMessage(note.title)),
        persist: false,
        action: SnackBarAction(
          label: '열기',
          onPressed: () {
            if (mounted) unawaited(_runWhenIdle(() => _openImported(note.id)));
          },
        ),
      ),
    );
  }

  /// 「열기」 on an import's message: the document opens as its card would open it.
  Future<void> _openImported(String id) async {
    final note = (await controller!.store.list())
        .where((n) => n.id == id)
        .firstOrNull;
    if (note == null) throw StateError('문서를 찾을 수 없습니다. 수신 상태나 휴지통을 확인하세요.');
    await _open(
      note,
      officeAction: note.documentKind == VaultDocumentKind.office
          ? OfficeOpenAction.edit
          : null,
    );
  }

  /// An import cancelled while it was stored: the document, which was never opened, goes straight to
  /// the trash of the vault the imports belong to, so an unsaved note does not hold it up. If it cannot,
  /// the message names it.
  Future<void> _trashImported(VaultNote note) async {
    final repository = _importVault;
    try {
      if (repository == null || note.revision.vaultId != repository.vaultId)
        throw StateError('The imported document is not in this vault');
      await WorkspaceStore(
        repository,
        native: controller?.native,
      ).setDeleted(note, true);
    } catch (error) {
      _importLog.warning('A cancelled import was not trashed: $error');
      if (mounted) {
        showUserErrorSnackBar(
          context,
          StateError('‘${note.title}’ 가져오기를 취소했지만 휴지통으로 옮기지 못했습니다.'),
        );
      }
    }
  }

  /// Asks how to store an Office·한글 original and imports it; 「PDF 필기용」 converts it and opens
  /// the PDF. With [readInBackground] (the + menu's imports), 「Office 편집용」 becomes an import
  /// beside the library that stores only the original (설계 4절, 13절): it reads the file with
  /// [readInBackground] itself, and true is returned.
  Future<bool> _importOfficeFile(
    WorkspaceController c, {
    required String fileName,
    required Future<Uint8List?> Function() readOriginal,
    required bool Function() isCurrent,
    String? Function()? staleReason,
    String? sharedRequestId,
    ImportRead? readInBackground,
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
      if (bytes == null) return false;
      final prior = await c.store.readSharedOfficeImport(sharedRequestId, (
        fileName: fileName,
        bytes: bytes,
      ));
      await requireCurrent();
      if (prior != null) {
        if (_opensInEditor(prior)) {
          await _openInEditor(c, prior);
        } else if (!prior.trashed) {
          await c.openNote(prior);
        }
        _finishOfficeImport(c, repository, prior);
        return false;
      }
    }

    if (!mounted) return false;
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
    if (mode == null) return false;
    await requireCurrent();
    if (mode == _OfficeImportMode.office && readInBackground != null) {
      _importOriginal(
        c,
        fileName: fileName,
        kind: VaultDocumentKind.office,
        read: (progress, cancelled) async {
          final original = await readInBackground(progress, cancelled);
          if (original.isEmpty && !cancelled())
            throw const FormatException('빈 Office·한글 파일은 가져올 수 없습니다.');
          return original;
        },
      );
      return true;
    }
    bytes ??= await readOriginal();
    await requireCurrent();
    if (bytes == null) return false;
    if (bytes.isEmpty)
      throw const FormatException('빈 Office·한글 파일은 가져올 수 없습니다.');
    final title = p.basenameWithoutExtension(fileName);
    final VaultNote note;
    if (mode == _OfficeImportMode.pdf) {
      final converted =
          await (widget.officePreviewEngine ?? OfficePreviewEngine())
              .convertToPdf(fileName: fileName, original: bytes);
      await requireCurrent();
      if (converted == null) return false;
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
      if (!note.trashed && isCurrent()) {
        // The edition [bytes] were stored as, so the kept PDF stays with it even if a newer one arrives.
        final source = note.sourceEntityId;
        final edition = source == null
            ? null
            : (await repository.heads(source)).singleOrNull;
        await _makeOfficeCover(
          repository,
          note,
          fileName: fileName,
          bytes: bytes,
          revisionId: edition?.revisionId,
        );
        if (await _settledAfterExternalScreen(isCurrent)) {
          if (_opensInEditor(note)) {
            await _openInEditor(c, note);
          } else {
            await c.openNote(note);
          }
        }
      }
    }
    _finishOfficeImport(c, repository, note);
    return false;
  }

  /// An Office original imported on Android is converted once so the library shows its first page as the cover
  /// (HWP and Windows covers are made in the background). Cancelling or a failure only leaves the cover out;
  /// the result says whether a cover was kept. [revisionId] names the edition [bytes] came from, so the PDF stays
  /// with that edition even when a newer one arrives during the conversion (the latest edition when null).
  Future<bool> _makeOfficeCover(
    NoteRepository repository,
    VaultNote note, {
    required String fileName,
    required Uint8List bytes,
    String? revisionId,
  }) async {
    final engine = widget.officePreviewEngine ?? OfficePreviewEngine();
    if (defaultTargetPlatform != TargetPlatform.android ||
        engine.supportsBackgroundPreview(fileName)) {
      return false;
    }
    try {
      final converted = await engine.convertToPdf(
        fileName: fileName,
        original: bytes,
      );
      if (converted == null) return false;
      await OfficeDocumentStore(repository).keepFirstPdf(
        note,
        pdfBytes: converted.bytes,
        pageCount: converted.pageCount,
        revisionId: revisionId,
      );
      return true;
    } catch (error) {
      _importLog.warning('Office cover was not made: $error');
      return false;
    }
  }

  /// 「첫 쪽 표지 만들기」: the conversion an Android import used to make, run for a card without a first-page
  /// picture. The conversion screen shows because the user asked; then the card's cover is drawn again.
  Future<void> _makeCover(VaultNote note) => _run(() async {
    final c = controller;
    if (c == null) return;
    final repository = c.repository;
    final documents = OfficeDocumentStore(repository);
    final edition = await documents.readLatest(note);
    final kept =
        edition.pdfBytes != null ||
        (await documents.readPdfVariants(note, edition)).isNotEmpty;
    if (!mounted || !identical(c.repository, repository)) return;
    if (kept) {
      // Its first page is already kept: draw it again instead of converting a PDF nobody would keep.
      _readInBackground(() => _requestThumbnail(note));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('이미 첫 쪽 표지가 있습니다')));
      return;
    }
    final made = await _makeOfficeCover(
      repository,
      note,
      fileName: edition.originalFileName,
      bytes: edition.originalBytes,
      revisionId: edition.revision.revisionId,
    );
    if (mounted && identical(c.repository, repository)) {
      if (made) {
        _readInBackground(() => _requestThumbnail(note));
      } else {
        // Only this row says so; an import without a cover goes on quietly.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('첫 쪽 표지를 만들지 못했습니다')),
        );
      }
    }
  });

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
    if (_whenIdle.isNotEmpty) {
      unawaited(_run(_whenIdle.removeAt(0)));
      return;
    }
    _sharedDocument();
  }

  /// Runs [operation] now, or after the work the workspace is busy with (an editor that
  /// finishes while the user is doing something else must still close its tab).
  Future<void> _runWhenIdle(Future<void> Function() operation) {
    if (!busy) return _run(operation);
    _whenIdle.add(operation);
    return Future.value();
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
        showUserErrorSnackBar(context, e);
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

  /// The open editor that must close before [note] can do [action]: one editor of each kind,
  /// and Word·PPT previews and PDFs need the Office engine its open editor holds.
  Future<OfficeOpenEdit?> _blockingEditor(
    WorkspaceController c,
    VaultNote note,
    OfficeOpenAction action,
  ) async {
    final edits = c.officeOpenEdits;
    if (edits.entries.isEmpty) return null;
    final kind = await _editorKind(c, note);
    final open = edits.forKind(kind);
    if (open == null) return null;
    if (action == OfficeOpenAction.edit) return open.noteId == note.id ? null : open;
    if (action == OfficeOpenAction.close) return null;
    return kind == OfficeEditorKind.office ? open : null;
  }

  Future<OfficeEditorKind> _editorKind(WorkspaceController c, VaultNote note) async {
    final edition = await OfficeDocumentStore(c.repository).readLatest(note);
    final extension = p.extension(edition.originalFileName).toLowerCase();
    return extension == '.hwp' || extension == '.hwpx'
        ? OfficeEditorKind.hwp
        : OfficeEditorKind.office;
  }

  /// '제목' 문서를 먼저 닫아야 합니다: [닫고 열기] asks [blocking]'s editor to close (it asks
  /// the user when something changed), then runs [then] once it has closed. Leaving that
  /// editor for the tabs instead cancels.
  Future<void> _askToCloseFirst(
    WorkspaceController c,
    OfficeOpenEdit blocking,
    Future<void> Function() then,
  ) async {
    final close = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text("'${blocking.title}' 문서를 먼저 닫아야 합니다."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('닫고 열기'),
          ),
        ],
      ),
    );
    if (close != true || !mounted || !identical(c, controller)) return;
    // The editor's outcome, not the open-edit list: the list empties before its save is a version.
    final finished = Completer<OfficeEditorOutcome?>();
    _closeWaits[blocking.noteId] = finished;
    final left = OfficeEditorEvents.instance.editorLeft.listen((sessionId) {
      if (sessionId == blocking.sessionId && !finished.isCompleted) {
        finished.complete(null);
      }
    });
    final OfficeEditorOutcome? outcome;
    try {
      if (!await _requestEditorClose(c, blocking.noteId)) return;
      outcome = await finished.future;
    } finally {
      if (identical(_closeWaits[blocking.noteId], finished)) {
        _closeWaits.remove(blocking.noteId);
      }
      await left.cancel();
    }
    if (outcome == null ||
        outcome == OfficeEditorOutcome.failed ||
        !mounted ||
        !identical(c, controller)) {
      return;
    }
    // Its save is a version now: its tab closes, then the other document opens.
    if (c.navigation.tabs.any((tab) => tab.noteId == blocking.noteId)) {
      await _changeDocumentTab(c, () => c.closeDocumentTab(blocking.noteId));
    }
    await then();
  }

  /// Asks [noteId]'s open editor to close through its host: the editor comes to the front and
  /// asks before it closes, and the tab closes when it reports back. False when the document is
  /// gone.
  Future<bool> _requestEditorClose(WorkspaceController c, String noteId) async {
    final note = (await c.store.list())
        .where((note) => note.id == noteId)
        .firstOrNull;
    if (note == null || !mounted || !identical(c, controller)) return false;
    _editorHosts.request(
      c.repository,
      note,
      OfficeOpenRequest(OfficeOpenAction.close),
    );
    return true;
  }

  /// Android: an Office·한글 document opens in its editor, never as a screen of the app.
  bool get _hostsEditors => defaultTargetPlatform == TargetPlatform.android;

  bool _opensInEditor(VaultNote note, {bool markdown = false}) =>
      _hostsEditors &&
      note.documentKind == VaultDocumentKind.office &&
      !markdown &&
      !note.trashed &&
      !note.deletionConflict;

  /// Opens [note]'s editor, or brings it back, over the current screen, which stays as it is.
  /// The document keeps a tab (marked 편집 중) without becoming the open document.
  Future<void> _openInEditor(WorkspaceController c, VaultNote note) async {
    if (_editorHosts.launching || _editorHosts.isBusy(note.id)) return;
    final blocking = await _blockingEditor(c, note, OfficeOpenAction.edit);
    if (!mounted || !identical(c, controller)) return;
    if (blocking != null) {
      return _askToCloseFirst(c, blocking, () => _openInEditor(c, note));
    }
    await c.keepDocumentTab(note);
    if (!mounted || !identical(c, controller)) return;
    _editorHosts.request(
      c.repository,
      note,
      OfficeOpenRequest(OfficeOpenAction.edit),
    );
  }

  void _editorHostsChanged() {
    if (mounted) setState(() {});
  }

  /// No editor could open (no engine, a format this device cannot edit, two versions to choose
  /// from): the Office screen opens instead, as before.
  void _hostDeclined(VaultNote note) {
    if (!mounted) return;
    unawaited(_runWhenIdle(() => _open(note, officeScreen: true)));
  }

  void _hostError(VaultNote note, String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// The host's editor closed. 닫고 열기 takes the outcome; otherwise a save, 저장 안 함 or
  /// nothing changed closes the document's tab, unless the user is looking at that document
  /// (기록·도구). An error keeps the tab: tapping it tries again.
  void _hostFinished(VaultNote note, OfficeEditorOutcome outcome) {
    final noteId = note.id;
    final waiting = _closeWaits.remove(noteId);
    if (waiting != null) {
      if (!waiting.isCompleted) waiting.complete(outcome);
      return;
    }
    final c = controller;
    if (outcome == OfficeEditorOutcome.failed || !mounted || c == null) return;
    unawaited(
      _runWhenIdle(() async {
        if (!identical(c, controller) ||
            c.activeSession?.note.id == noteId ||
            !c.navigation.tabs.any((tab) => tab.noteId == noteId)) {
          return;
        }
        await c.closeDocumentTab(noteId);
      }),
    );
  }

  /// An editor finished while no call waited for it (after an app restart): its result is in the
  /// recovery records, and the document's screen publishes it when it opens.
  void _onLateEditorResult(({String sessionId, String status}) event) {
    final c = controller;
    if (c == null) return;
    final open = c.officeOpenEdits.entries
        .where((edit) => edit.sessionId == event.sessionId)
        .firstOrNull;
    if (open != null) unawaited(c.officeOpenEdits.remove(open.noteId));
  }

  Future<void> _back() async {
    if (_scaffold.currentState?.isDrawerOpen ?? false) {
      _scaffold.currentState?.closeDrawer();
      return;
    }
    // a window over the note's page (the note window, 「도구 막대 사용자화」)
    // closes before the note
    if (_editorChrome.editor?.closeOpenWindow() ?? false) return;
    final session = controller?.activeSession;
    if (session == null) {
      final c = controller;
      if (c != null && _librarySelection == _librarySelectionScope(c)) {
        if (!busy) setState(() => _librarySelection = null);
        return;
      }
      // From 최근, 즐겨찾기 or a label, back returns to the folders.
      if (_libraryCollection.kind != LibraryCollectionKind.folder) {
        setState(() => _libraryCollection = const LibraryCollection.folder());
        return;
      }
      if (c?.currentFolderId != null) {
        final folder = c!.folders
            .where((f) => f.id == c.currentFolderId)
            .firstOrNull;
        await _run(() => c.openFolder(folder?.parentId));
      } else if (c != null && c.officeOpenEdits.entries.isNotEmpty) {
        // The library's first screen with an editor open behind it: the app goes to the back
        // and keeps both, instead of ending (the editor's result needs this screen).
        await _run(OfficeEditorEvents.instance.moveAppToBack);
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

  /// [officeAction] is what an Office·한글 document does as soon as it is
  /// open (the library card's tap and ⋮ menu). On Android an Office·한글 document opens in its
  /// editor over the current screen; [officeScreen] (기록·도구 and the fallback when no editor
  /// can open) shows the Office screen instead.
  Future<void> _open(
    VaultNote note, {
    KnowledgeBodyMatch? bodyMatch,
    OfficeOpenAction? officeAction,
    bool officeScreen = false,
  }) async {
    final c = controller!;
    final repository = c.repository;
    if (!officeScreen &&
        bodyMatch == null &&
        (officeAction == null || officeAction == OfficeOpenAction.edit) &&
        _opensInEditor(note)) {
      return _openInEditor(c, note);
    }
    if (officeAction != null &&
        note.documentKind == VaultDocumentKind.office) {
      final blocking = await _blockingEditor(c, note, officeAction);
      if (!mounted || !identical(c, controller)) return;
      if (blocking != null) {
        return _askToCloseFirst(
          c,
          blocking,
          () => _open(note, bodyMatch: bodyMatch, officeAction: officeAction),
        );
      }
    }
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
    if (officeAction != null &&
        session != null &&
        session.note.id == note.id &&
        session.note.documentKind == VaultDocumentKind.office) {
      setState(() {
        _officeOpenRequest = (
          session: session,
          request: OfficeOpenRequest(officeAction),
        );
      });
    }
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

        final notes = <String, VaultNote>{};
        final folders = <String, VaultFolder>{};
        // A save that lands while the catalog is read (such as the Markdown autosave half a second after an
        // edit, which "더 많은 작업" → 빠른 문서 전환 can easily overlap) changes the vault: read it again a
        // few times before asking the user to search again.
        for (var attempt = 1; ; attempt++) {
          final catalogGeneration = c.repositoryGeneration;
          notes.clear();
          folders.clear();
          final seenNotes = <String>{};
          for (final note in await c.store.list()) {
            if (!seenNotes.add(note.id)) {
              notes.remove(note.id);
            } else if (!note.trashed && !note.deletionConflict) {
              notes[note.id] = note;
            }
          }
          if (!current()) return;
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
          if (catalogGeneration == c.repositoryGeneration) break;
          if (attempt == 3) {
            throw StateError('보관함 내용이 바뀌었습니다. 최신 문서를 다시 검색하세요.');
          }
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
        final chosen = notes[id];
        final chosenTab = c.navigation.tabs
            .where((tab) => tab.noteId == id)
            .singleOrNull;
        if (chosen != null &&
            _opensInEditor(
              chosen,
              markdown: chosenTab?.location?.markdown ?? false,
            )) {
          return _openInEditor(c, chosen);
        }
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

  /// The ink editor is on screen, with its own toolbar and ⋯ (Task 17: they hold what the function row held). A
  /// read-only note (a newer version, a damaged file, a PDF previewed from another device) keeps the row: its editor
  /// folds the toolbar away with its ⋯.
  bool _inkEditorShown(
    WorkspaceController c,
    NoteSession session, {
    required bool sideBySide,
  }) {
    switch (session.note.documentKind) {
      case VaultDocumentKind.handwriting || VaultDocumentKind.image:
        break;
      case VaultDocumentKind.pdf:
        if (c.pdfImportError != null || c.pdfPeerPreview) return false;
      default:
        return false;
    }
    if (_editorChrome.editorReadOnly) return false;
    return !markdownTab || sideBySide;
  }

  /// The open document's rows above it: the tab row (the user can hide it), and under it the function row of a
  /// document that is not the ink editor (design 「다른 문서와 무한 노트」). Full screen hides both, together with the
  /// editor's own bars. [sideBySide] (a wide desktop window) shows the note and its Markdown together.
  PreferredSizeWidget? _noteBar(
    WorkspaceController c,
    NoteSession session, {
    required bool sideBySide,
  }) {
    if (DynamicMaterialApp.isFullscreen) return null;
    final tabsShown = !stows.noteTabBarHidden.value;
    final rowShown = !_inkEditorShown(c, session, sideBySide: sideBySide);
    if (!tabsShown && !rowShown) return null;
    return PreferredSize(
      preferredSize: Size.fromHeight(
        (tabsShown ? KitTokens.tabRowHeight : 0) +
            (rowShown ? NoteFunctionRow.height : 0),
      ),
      child: Material(
        // under the status bar: the colour of the row at the top
        color: tabsShown ? KitTokens.tabRowBg : KitTokens.toolbarBg,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              if (tabsShown)
                SizedBox(
                  key: const ValueKey('note-tab-row'),
                  height: KitTokens.tabRowHeight,
                  child: _documentTabs(c, fallbackTitle: session.note.title),
                ),
              if (rowShown) _functionRow(c, session, sideBySide: sideBySide),
            ],
          ),
        ),
      ),
    );
  }

  void _tabBarHiddenChanged() {
    if (mounted) setState(() {});
  }

  /// 손가락 필기 changed (the infinite note's row ⋯ shows it as a switch): publish it again.
  void _fingerDrawingChanged() {
    if (mounted) setState(() {});
  }

  /// The ink editor's note became read-only or editable again: the function row comes or goes with its toolbar.
  void _editorChromeChanged() {
    final readOnly = _editorChrome.editorReadOnly;
    if (mounted && readOnly != _editorReadOnly) {
      setState(() => _editorReadOnly = readOnly);
    }
  }

  /// A save of the open document (its heads changed, same document, with changes unsaved before): its last edit is
  /// now, until the library reads the vault's time. Heads that change with nothing unsaved (a sync download, a revision
  /// opened, an automation) are no edit here.
  void _noteSaves(WorkspaceController? c) {
    final session = c?.activeSession;
    if (session == null) {
      _seenHeads = null;
      return;
    }
    final heads = (
      session.note.id,
      Object.hashAll([...session.inkParents, ...session.markdownParents]),
    );
    final last = _seenHeads;
    final wasDirty = _seenDirty;
    _seenHeads = heads;
    _seenDirty = c!.dirty;
    if (last == null || last.$1 != heads.$1 || last.$2 == heads.$2) return;
    if (!wasDirty && !c.dirty) return;
    final facts = _documentFacts[heads.$1] ?? const DocumentFacts();
    _documentFacts = {
      ..._documentFacts,
      heads.$1: DocumentFacts(
        changed: DateTime.now(),
        created: facts.created,
        format: facts.format,
        pages: facts.pages,
        aspect: facts.aspect,
      ),
    };
  }

  /// StarNote's function row in the kit tool bar's look: the shortcut bar with the open document's actions (placed as
  /// the user arranged them), an Office PDF editor's 문서 개요, and ⋯ 더 많은 기능. With the tab row hidden it starts
  /// with the way back and the button that shows the tab row (its home is gone with it).
  Widget _functionRow(
    WorkspaceController c,
    NoteSession session, {
    required bool sideBySide,
  }) => ListenableBuilder(
    listenable: Listenable.merge([
      _editorChrome,
      _editorChrome.actions,
      stows.noteShortcutLayout,
    ]),
    builder: (context, _) {
      // The editor's shortcuts only while it is on screen, not under the Markdown view.
      final editorShown = !markdownTab || sideBySide;
      final tabsHidden = stows.noteTabBarHidden.value;
      // The infinite note's bar has no ⋯: its 손가락 필기 and 확대 비율 sit at the top of the row's ⋯.
      final infinite = session.note.documentKind == VaultDocumentKind.infinite;
      final finger = infinite ? _editorChrome.actions.lookup(AppActionIds.finger) : null;
      final switches = <NoteSwitch>[
        if (finger != null) (action: finger, on: () => stows.editorFingerDrawing.value),
      ];
      return NoteFunctionRow(
        back: tabsHidden
            ? KitToolbarButton(
                key: const ValueKey('workspace-back-to-library'),
                icon: KitIconName.back,
                tooltip: '문서 목록으로',
                onPressed: busy ? null : () => unawaited(_back()),
              )
            : null,
        leading: [
          if (tabsHidden)
            KitToolbarButton(
              key: const ValueKey('note-tab-bar-show'),
              icon: KitIconName.noteTab,
              tooltip: '탭 줄 보이기',
              onPressed: () => stows.noteTabBarHidden.value = false,
            ),
        ],
        shortcuts: [
          for (final action in _rowShortcuts(c, editorShown: editorShown))
            if (!identical(action, finger)) action,
        ],
        switches: switches,
        zoom: infinite
            ? DocZoom(
                scale: () => _infinite.currentState?.viewport.scale ?? 1,
                zoomTo: (scale) => _infinite.currentState?.zoomTo(scale),
              )
            : null,
        fixed: [
          if (editorShown) ?_editorChrome.actions.lookup(AppActionIds.pageList),
        ],
        layout: ShortcutLayout.decode(
          noteShortcutItems,
          stows.noteShortcutLayout.value,
          legacyToolbar: stows.pageToolbarLayout.value,
        ),
        onCustomize: () => unawaited(
          showShortcutBarEditor(
            context,
            layout: stows.noteShortcutLayout,
            legacyToolbar: stows.pageToolbarLayout.value,
          ),
        ),
      );
    },
  );

  /// The first button of the library's top bar, ☰ as in Notein: on a tablet it
  /// shows and hides the side panel; on a phone it opens the drawer.
  Widget _libraryLeading({required bool panel}) {
    if (!panel) return const DrawerButton();
    return ValueListenableBuilder(
      valueListenable: stows.libraryPanelOpen,
      builder: (context, _, _) {
        final open = _libraryPanelOpen();
        return IconButton(
          key: const ValueKey('library-panel-toggle'),
          tooltip: open ? '왼쪽 바 숨기기' : '왼쪽 바 보이기',
          icon: const Icon(Icons.menu),
          onPressed: () => stows.libraryPanelOpen.value = !open,
        );
      },
    );
  }

  bool _libraryPanelOpen() =>
      stows.libraryPanelOpen.value ?? MediaQuery.sizeOf(context).width >= 1000;

  /// The library's side panel sits beside the documents instead of covering them, so both stay usable; the top
  /// bar's ☰ opens and closes it. In light mode it is white, as Notein's drawer.
  Widget _libraryPanel(WorkspaceController c) => ValueListenableBuilder(
    valueListenable: stows.libraryPanelOpen,
    builder: (context, _, _) => AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.centerLeft,
      child: _libraryPanelOpen()
          ? Row(
              key: const ValueKey('library-panel'),
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 260,
                  child: Material(
                    color: _drawerBackground(context),
                    child: _library(c),
                  ),
                ),
                VerticalDivider(width: 1, color: libraryLine(context)),
              ],
            )
          // Keeps the full height so only the width animates.
          : const SizedBox(height: double.infinity),
    ),
  );

  /// Switches the open note between its own view and its Markdown (the `viewToggle` action).
  void _toggleMarkdownTab() => setState(() => markdownTab = !markdownTab);

  /// The tab row (9th draft c): home, the open documents' tabs (the open one's ⌄ shows its state and 이름 변경), + to
  /// open another one in a new tab, and 229's open-tabs menu. A long press on a tab offers 닫기 and 다른 탭 닫기.
  Widget _documentTabs(WorkspaceController c, {String? fallbackTitle}) {
    final repository = c.repository;
    final tabs = c.navigation.tabs;
    final enabled = !busy && !c.externalBusy;
    void select(String id) {
      if (busy ||
          c.externalBusy ||
          !identical(controller, c) ||
          !identical(c.repository, repository) ||
          !c.navigation.tabs.any((tab) => tab.noteId == id)) {
        return;
      }
      final active = c.activeSession;
      if (active?.note.id == id) {
        // The open document's editor is behind the app: bring it back.
        if (active != null &&
            c.officeOpenEdits.forNote(id) != null &&
            _hostsEditors) {
          unawaited(_run(() => _openInEditor(c, active.note)));
        }
        return;
      }
      unawaited(
        _run(() async {
          // An Office·한글 tab opens its editor over this screen unless it was left on its memo.
          final tab = c.navigation.tabs
              .where((tab) => tab.noteId == id)
              .firstOrNull;
          if (_hostsEditors && !(tab?.location?.markdown ?? false)) {
            final note = (await c.store.list())
                .where((note) => note.id == id)
                .firstOrNull;
            if (!identical(controller, c)) return;
            if (note != null && _opensInEditor(note)) {
              return _openInEditor(c, note);
            }
          }
          await _changeDocumentTab(c, () => c.activateDocumentTab(id));
        }),
      );
    }

    // A document whose editor is open asks that editor first.
    void close(String id) => unawaited(
      _run(
        () => c.officeOpenEdits.forNote(id) != null
            ? _requestEditorClose(c, id)
            : _changeDocumentTab(c, () => c.closeDocumentTab(id)),
      ),
    );

    return KitTabRow(
      tabs: [
        for (final tab in tabs)
          KitTab(
            id: tab.noteId,
            title: tab.title,
            editing: c.officeOpenEdits.forNote(tab.noteId) != null,
          ),
      ],
      activeId: c.activeSession?.note.id,
      fallbackTitle: fallbackTitle,
      onHome: busy ? null : () => unawaited(_back()),
      onSelect: enabled ? select : null,
      onClose: enabled ? close : null,
      onCloseOthers: enabled
          ? (id) => unawaited(_run(() => _closeOtherTabs(c, keep: id)))
          : null,
      onNewTab: enabled ? _quickSwitch : null,
      docInfo: _docInfo,
      // 이름 변경 runs the rename action when that can run
      onRename:
          enabled &&
              (_editorChrome.actions.lookup(AppActionIds.rename)?.enabled ??
                  false)
          ? () => _editorChrome.actions.run(AppActionIds.rename, context)
          : null,
      trailing: WorkspaceTabSwitcher(
        tabs: tabs,
        activeNoteId: c.activeSession?.note.id,
        onSelected: enabled ? select : null,
        onHideTabBar: () => stows.noteTabBarHidden.value = true,
        onCloseOthers: () {
          final active = c.activeSession?.note.id;
          if (active != null) {
            unawaited(_run(() => _closeOtherTabs(c, keep: active)));
          }
        },
      ),
    );
  }

  /// 다른 탭 닫기: opens [keep] if it is not the open document, then closes every other tab. A tab whose Office·한글
  /// editor is open stays, since closing it needs that editor's answer about saving.
  Future<void> _closeOtherTabs(
    WorkspaceController c, {
    required String keep,
  }) async {
    final repository = c.repository;
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repository);
    if (c.activeSession?.note.id != keep) {
      await _changeDocumentTab(c, () => c.activateDocumentTab(keep));
      if (!current() || c.activeSession?.note.id != keep) return;
    }
    // Closing a tab flushes the vault, which refuses unsaved ink: save the open note first, as × does.
    await _save();
    if (!current()) return;
    var keptEditors = false;
    for (final tab in [...c.navigation.tabs]) {
      if (tab.noteId == keep) continue;
      if (c.officeOpenEdits.forNote(tab.noteId) != null) {
        keptEditors = true;
        continue;
      }
      await c.closeDocumentTab(tab.noteId);
      if (!current()) return;
    }
    if (keptEditors && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('편집기가 열린 탭은 남겼습니다')));
    }
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
    if (mounted) {
      setState(() => _libraryCollection = const LibraryCollection.folder());
    }
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
          '이 기능을 쓰려면 보관함 형식 2가 필요합니다. '
          '현재 기기에 저장된 문서와 이력을 새 보관함에 복사한 뒤 하던 일을 이어갑니다. '
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
      LibraryCreateAction.importPpt ||
      LibraryCreateAction.importWord ||
      LibraryCreateAction.importHwp ||
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
    if (action == LibraryCreateAction.handwriting ||
        action == LibraryCreateAction.pageNoteWithPattern) {
      // As in Notein, the pencil and 「새 노트」's 만들기 make a page note at once; it takes the
      // last page pattern, which the dialog has just stored.
      await controller!.createNote('새 노트');
      markdownTab = false;
      _scaffold.currentState?.closeDrawer();
      return;
    }
    if (action == LibraryCreateAction.image ||
        action == LibraryCreateAction.camera) {
      final ImportRead read;
      final String name;
      if (action == LibraryCreateAction.camera) {
        final captured = await const NativeImageCapture().capture();
        if (captured == null) return;
        if (await captured.length() > 64 * 1024 * 1024)
          throw StateError('사진이 너무 큽니다(최대 64 MiB).');
        name = p.basename(captured.path);
        read = (progress, cancelled) => _readForImport(
          captured.length,
          captured.openRead,
          progress,
          cancelled,
        );
      } else {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp'],
        );
        if (file == null) return;
        if ((await file.length() ?? 0) > 64 * 1024 * 1024)
          throw StateError('이미지가 너무 큽니다(최대 64 MiB).');
        name = p.basename(file.name);
        read = (progress, cancelled) => _readForImport(
          file.length,
          file.readAsByteStream,
          progress,
          cancelled,
        );
      }
      final c = controller!;
      final title = action == LibraryCreateAction.camera
          ? '촬영한 사진'
          : p.basenameWithoutExtension(name);
      // Beside the library like the other imports; the importer stores the image with its page.
      _startImport(
        c,
        title: title,
        read: read,
        write: (repository, folderId, bytes) async {
          void requireVault() {
            if (!identical(c.repository, repository))
              throw StateError('가져오기 대상 보관함이 바뀌었습니다.');
          }

          requireVault();
          final note = await ImageNoteImporter(repository).import(
            title: title,
            fileName: name,
            bytes: bytes,
            folderId: folderId,
          );
          requireVault();
          return note;
        },
      );
      return;
    }
    // Any Office·한글 original, or one format from the + menu: its picker offers
    // only that format, and a file of another one is refused before it is read.
    final officeFormat = _officeImportFormats[action];
    if (action == LibraryCreateAction.office || officeFormat != null) {
      void requireFormat(String fileName) {
        final name = fileName.toLowerCase();
        if (officeFormat != null &&
            !officeFormat.extensions.any((ext) => name.endsWith('.$ext'))) {
          throw FormatException('${officeFormat.label} 파일을 고르세요.');
        }
      }

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
        final selection = await source.choose(
          mimeTypes: officeFormat?.mimeTypes,
        );
        if (selection == null) return;
        // An import that takes the document over lets it go itself.
        var handedOver = false;
        try {
          requireFormat(selection.name);
          if (!await _settledAfterExternalScreen(current)) {
            _importLog.warning('Office import stopped after the picker: ${stale()}');
            return;
          }
          Future<Uint8List?> readStaged(
            bool Function() wanted, [
            void Function(double)? progress,
          ]) async {
            final staged = await source.stage(selection);
            return _readExternalDocument(
              staged.file.length,
              staged.file.openRead,
              expectedLength: staged.bytes,
              maxBytes: _officeImportMaxBytes,
              tooLarge: _officeImportTooLarge,
              current: wanted,
              progress: progress,
            );
          }

          handedOver = await _importOfficeFile(
            c,
            fileName: selection.name,
            staleReason: stale,
            readOriginal: () => readStaged(current),
            readInBackground: (progress, cancelled) async {
              try {
                return await readStaged(() => !cancelled(), progress) ??
                    (throw StateError('가져오기를 취소했습니다.'));
              } finally {
                // The picker holds one document at a time: it is let go as soon as it is read.
                await source.release(selection.id);
              }
            },
            isCurrent: current,
          );
        } finally {
          if (!handedOver) await source.release(selection.id);
        }
      } else {
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions:
              officeFormat?.extensions ??
              OfficeDocumentStore.supportedExtensions,
        );
        if (file == null) return;
        requireFormat(file.name);
        await _importOfficeFile(
          c,
          fileName: p.basename(file.name),
          readOriginal: file.readAsBytes,
          readInBackground: (progress, cancelled) => _readForImport(
            file.length,
            file.readAsByteStream,
            progress,
            cancelled,
          ),
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
      if (_opensInEditor(note)) {
        await _openInEditor(c, note);
      } else {
        await c.openNote(note);
      }
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
      case LibraryNoteAction.preview:
        return _open(note, officeAction: OfficeOpenAction.preview);
      case LibraryNoteAction.pdf:
        return _open(note, officeAction: OfficeOpenAction.pdf);
      case LibraryNoteAction.tools:
        return _open(note, officeScreen: true);
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
      final c = controller!;
      if (c.repository.formatVersion >= 2) {
        // Read in chunks beside the library; only the original is stored, and its pages are
        // made when it is first opened.
        _importOriginal(
          c,
          fileName: p.basename(path),
          kind: VaultDocumentKind.pdf,
          read: (progress, cancelled) => _readForImport(
            picked.length,
            picked.readAsByteStream,
            progress,
            cancelled,
          ),
        );
        return;
      }
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

  /// A link on a handwritten page (the ink editor's or an Office PDF's): another note opens here, a
  /// web page outside. One followed while the workspace is busy opens after that work.
  Future<void> _openEditorLink(String link) =>
      _runWhenIdle(() => _openLink(link));

  /// The link dialog's 「노트」 tab: the vault's notes outside the trash, the open one too, by title.
  Future<List<({String id, String title})>> _linkableNotes() async {
    final c = controller;
    if (c == null) return const [];
    final store = c.store;
    final notes = await Zone.root.run(store.list);
    final seen = <String>{};
    return [
      for (final note in notes)
        if (!note.trashed && seen.add(note.id))
          (id: note.id, title: note.title),
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
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
      // A link to an Office·한글 document (not to one of its pages) opens its editor.
      if (!showMarkdown && link?.pageId == null && _opensInEditor(note)) {
        await _openInEditor(c, note);
        return;
      }
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

  /// The backlinks, tags and graph window, on [tab] (0, 1 or 2).
  Future<void> _knowledge({int tab = 0}) async {
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
                    initialTab: tab,
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
    void Function(double)? progress,
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
      if (progress != null && length != null && length > 0) {
        progress(bytes.length / length);
      }
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

  /// Searches the library: the side bar's box, and the title's clear button.
  void _searchLibrary(WorkspaceController c, String query) {
    setState(() {
      c.setSearchQuery(
        query,
        bookmark: c.searchesFromBookmark,
        literal: c.searchesLiterally,
        expression: !c.showDeleted && c.searchesWithOperators,
      );
    });
    unawaited(c.refresh());
  }

  static Color _drawerBackground(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light
      ? Colors.white
      : Theme.of(context).colorScheme.surface;

  /// The library's drawer, as Notein's (설계 1.9절): three tabs on top — 둘러보기 (the library's
  /// views, then bookmarks, tags, backlinks, graph and the quick switch), 폴더 (the folder tree)
  /// and 라벨 — and the Drive state at the bottom. Search and settings are in the library's top bar.
  Widget _library(WorkspaceController c) {
    final folders = [
      for (final folder in c.folders)
        if (!folder.trashed || folder.deletionConflict) folder,
    ];
    final ids = {for (final folder in folders) folder.id};
    final children = <String?, List<VaultFolder>>{};
    for (final folder in folders) {
      final parent = ids.contains(folder.parentId) ? folder.parentId : null;
      (children[parent] ??= []).add(folder);
    }
    for (final list in children.values) {
      list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    // Documents per folder, counting the folders inside it.
    final parents = {for (final folder in folders) folder.id: folder.parentId};
    final counts = <String, int>{};
    var trashed = 0;
    for (final note in c.notes) {
      if (note.trashed) {
        trashed++;
        continue;
      }
      var id = note.folderId;
      final seen = <String>{};
      while (id != null && seen.add(id)) {
        counts[id] = (counts[id] ?? 0) + 1;
        id = parents[id];
      }
    }
    Widget count(int value) => Text(
      '$value',
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    final rows = <Widget>[];
    void addFolders(String? parent, int depth, Set<String> seen) {
      for (final folder in children[parent] ?? const <VaultFolder>[]) {
        if (!seen.add(folder.id)) continue;
        final hasChildren = children[folder.id]?.isNotEmpty ?? false;
        final collapsed = _collapsedFolders.contains(folder.id);
        rows.add(
          Padding(
            padding: EdgeInsets.only(left: (depth.clamp(0, 6) * 14).toDouble()),
            child: ListTile(
              key: ValueKey('sidebar-folder-${folder.id}'),
              dense: true,
              contentPadding: const EdgeInsets.only(left: 4, right: 4),
              horizontalTitleGap: 6,
              leading: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 32,
                    child: hasChildren
                        ? IconButton(
                            key: ValueKey('sidebar-folder-toggle-${folder.id}'),
                            tooltip: collapsed ? '펼치기' : '접기',
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            iconSize: 20,
                            onPressed: () => setState(() {
                              if (!_collapsedFolders.remove(folder.id)) {
                                _collapsedFolders.add(folder.id);
                              }
                            }),
                            icon: Icon(
                              collapsed ? Icons.chevron_right : Icons.expand_more,
                            ),
                          )
                        : null,
                  ),
                  Icon(
                    folder.deletionConflict
                        ? Icons.warning_amber
                        : Icons.folder_outlined,
                  ),
                ],
              ),
              title: Text(
                folder.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              selected:
                  !c.showDeleted &&
                  _libraryCollection.kind == LibraryCollectionKind.folder &&
                  folder.id == c.currentFolderId,
              onTap: busy ? null : () => _run(() => _goFolder(folder.id)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  count(counts[folder.id] ?? 0),
                  PopupMenuButton<LibraryFolderAction>(
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
                ],
              ),
            ),
          ),
        );
        if (!collapsed) addFolders(folder.id, depth + 1, seen);
      }
    }

    // A row in the drawer closes it first; the tablet's side panel stays.
    void tap(VoidCallback action) {
      if (_scaffold.currentState?.isDrawerOpen ?? false) {
        _scaffold.currentState!.closeDrawer();
      }
      action();
    }

    final scheme = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    // Notein's rows: an icon and a name, the chosen one on a pale blue pill.
    Widget row(
      String label,
      IconData icon,
      VoidCallback? action, {
      Key? key,
      Color? iconColor,
      Widget? trailing,
      bool selected = false,
    }) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: ListTile(
        key: key,
        enabled: action != null,
        minTileHeight: 48,
        shape: const StadiumBorder(),
        selectedTileColor: light
            ? const Color(0xFFDCE8FC)
            : scheme.secondaryContainer,
        selectedColor: scheme.onSurface,
        leading: Icon(icon, color: iconColor),
        title: Text(label),
        trailing: trailing,
        selected: selected,
        onTap: action == null ? null : () => tap(action),
      ),
    );

    final repository = c.repository;
    final ready = !busy && !c.externalBusy;
    final shown = c.showDeleted ? null : _libraryCollection;
    final List<Widget> items;
    switch (_drawerTab) {
      case _DrawerTab.browse:
        items = [
          row(
            '모두',
            Icons.archive_outlined,
            busy
                ? null
                : () => _run(() async {
                    c.showDeleted = false;
                    await c.refresh();
                    await _goFolder(null);
                  }),
            key: const ValueKey('library-nav-all'),
            selected: shown?.kind == LibraryCollectionKind.folder,
          ),
          row(
            '최근',
            Icons.history,
            busy
                ? null
                : () => _run(
                    () => _openCollection(const LibraryCollection.recent([])),
                  ),
            key: const ValueKey('library-nav-recent'),
            selected: shown?.kind == LibraryCollectionKind.recent,
          ),
          row(
            '즐겨찾기',
            Icons.favorite_border,
            busy
                ? null
                : () => _run(
                    () => _openCollection(const LibraryCollection.favorites()),
                  ),
            key: const ValueKey('library-nav-favorites'),
            selected: shown?.kind == LibraryCollectionKind.favorites,
          ),
          row(
            '리마인더',
            Icons.alarm,
            busy
                ? null
                : () => _run(() => _openPlanner(PlannerScreen.reminder)),
            key: const ValueKey('library-nav-reminder'),
          ),
          row(
            '달력',
            Icons.calendar_month_outlined,
            busy
                ? null
                : () => _run(() => _openPlanner(PlannerScreen.calendar)),
            key: const ValueKey('library-nav-calendar'),
          ),
          row(
            '휴지통',
            Icons.delete_outline,
            busy
                ? null
                : () => _run(() async {
                    await _goFolder(null);
                    c.showDeleted = true;
                    await c.refresh();
                  }),
            key: const ValueKey('library-nav-trash'),
            trailing: count(trashed),
            selected: c.showDeleted,
          ),
          Divider(indent: 16, endIndent: 16, color: libraryLine(context)),
          if (repository.formatVersion >= 2)
            row(
              '북마크',
              Icons.bookmark_border,
              ready ? _bookmarks : null,
              key: const ValueKey('workspace-bookmarks'),
            ),
          if (c.native != null) ...[
            row(
              '태그',
              Icons.tag,
              busy ? null : () => unawaited(_knowledge(tab: 1)),
              key: const ValueKey('library-tags'),
            ),
            row(
              '역링크',
              Icons.link,
              busy ? null : () => unawaited(_knowledge()),
              key: const ValueKey('library-backlinks'),
            ),
            row(
              '그래프',
              Icons.hub_outlined,
              busy ? null : () => unawaited(_knowledge(tab: 2)),
              key: const ValueKey('library-graph'),
            ),
          ],
          row(
            '빠른 문서 전환',
            Icons.manage_search,
            ready ? _quickSwitch : null,
            key: const ValueKey('workspace-quick-switch'),
          ),
        ];
      case _DrawerTab.folders:
        addFolders(null, 0, <String>{});
        items = [
          row(
            '새 폴더',
            Icons.add,
            busy
                ? null
                : () => _run(() => _createDocument(LibraryCreateAction.folder)),
            key: const ValueKey('library-drawer-new-folder'),
          ),
          ...rows,
        ];
      case _DrawerTab.labels:
        items = [
          for (final label in _marks.labels)
            row(
              label.name,
              Icons.label,
              busy
                  ? null
                  : () => _run(
                      () => _openCollection(
                        LibraryCollection.label(label.id, label.name),
                      ),
                    ),
              key: ValueKey('library-drawer-label-${label.id}'),
              iconColor: Color(label.color),
              selected:
                  shown?.kind == LibraryCollectionKind.label &&
                  shown?.labelId == label.id,
            ),
          row(
            '새 라벨',
            Icons.add,
            () => unawaited(_editLabels('')),
            key: const ValueKey('library-drawer-new-label'),
          ),
        ];
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: _drawerTabs(),
        ),
        // Below the tabs everything scrolls together, so a short screen (a
        // tablet held sideways with the keyboard up) still reaches every row.
        // Each tab keeps its own place in the list.
        Expanded(
          child: ListView(
            key: PageStorageKey<_DrawerTab>(_drawerTab),
            children: items,
          ),
        ),
        if (_driveConnection case final drive?) DrivePanel(controller: drive),
      ],
    );
  }

  /// The drawer's head: 둘러보기, 폴더 and 라벨 in a grey pill, the chosen one
  /// white, as Notein's (사진 1000319965).
  Widget _drawerTabs() {
    final scheme = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    Widget cell(_DrawerTab tab, String label) {
      final chosen = _drawerTab == tab;
      return Expanded(
        child: Semantics(
          selected: chosen,
          child: InkWell(
            key: ValueKey('library-drawer-${tab.name}'),
            borderRadius: BorderRadius.circular(16),
            onTap: () => setState(() => _drawerTab = tab),
            child: DecoratedBox(
              decoration: chosen
                  ? BoxDecoration(
                      color: light ? Colors.white : scheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x24000000),
                          blurRadius: 4,
                          offset: Offset(0, 1),
                        ),
                      ],
                    )
                  : const BoxDecoration(),
              child: SizedBox(
                height: 32,
                child: Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: chosen ? FontWeight.w600 : FontWeight.normal,
                      color: chosen ? scheme.onSurface : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Material(
      color: light ? const Color(0xFFEFEFF1) : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          children: [
            cell(_DrawerTab.browse, '둘러보기'),
            cell(_DrawerTab.folders, '폴더'),
            cell(_DrawerTab.labels, '라벨'),
          ],
        ),
      ),
    );
  }

  /// The drawer's 최근, 즐겨찾기 and labels: the open document is saved and
  /// closed and the trash left, then the library lists [collection] from every
  /// folder.
  Future<void> _openCollection(LibraryCollection collection) async {
    final c = controller!;
    final repository = c.repository;
    bool current() =>
        mounted &&
        identical(controller, c) &&
        identical(c.repository, repository);
    await _save();
    if (!current()) return;
    final session = c.activeSession;
    if (session != null) await c.closeNote(session: session);
    if (!current()) return;
    if (c.showDeleted || c.searchesAcrossFolders) {
      c.showDeleted = false;
      if (c.searchesAcrossFolders) c.query = '';
      await c.refresh();
      if (!current()) return;
    }
    setState(() {
      _libraryCollection = collection;
      _librarySelection = null;
    });
    _scaffold.currentState?.closeDrawer();
  }

  /// What the library lists now: 최근 is the 50 documents opened last that are still in the vault
  /// and out of the trash, and a label shows its current name.
  LibraryCollection _collectionFor(WorkspaceController c) {
    final collection = _libraryCollection;
    switch (collection.kind) {
      case LibraryCollectionKind.recent:
        final live = {
          for (final note in c.notes)
            if (!note.trashed || note.deletionConflict) note.id,
        };
        return LibraryCollection.recent(
          c.recentDocumentIds.where(live.contains).take(50).toList(),
        );
      case LibraryCollectionKind.label:
        final label = _marks.labels
            .where((label) => label.id == collection.labelId)
            .firstOrNull;
        return label == null
            ? collection
            : LibraryCollection.label(label.id, label.name);
      case LibraryCollectionKind.folder:
      case LibraryCollectionKind.favorites:
        return collection;
    }
  }

  /// Widgets, alarms and widget taps go through Android; a test injects them.
  bool get _plannerNative => widget.plannerPlatform != null || Platform.isAndroid;

  /// The drawer's 리마인더 and 달력, and a widget or alarm tap (설계 6·7절). Each screen exists once:
  /// the one asked for stays when it is open, and takes the other's place when that one is.
  /// A format-1 vault is upgraded first, as for the + menu's documents.
  Future<void> _openPlanner(PlannerScreen screen) async {
    final c = controller;
    if (c == null || !mounted) return;
    final shown = _plannerShown;
    if (shown != null && shown.route.isActive && shown.screen == screen) return;
    if (c.repository.formatVersion == 1 && !await _upgradeLegacyVault(c)) return;
    if (!mounted || !identical(controller, c)) return;
    final google = screen == PlannerScreen.calendar
        ? await _plannerWidgets.googleCalendar()
        : null;
    if (!mounted || !identical(controller, c)) return;
    final store = PlannerStore(c.repository);
    final route = MaterialPageRoute<void>(
      builder: (_) => switch (screen) {
        PlannerScreen.reminder => ReminderPage(
          store: store,
          platform: _planner,
          changes: _plannerChanges,
        ),
        PlannerScreen.calendar => CalendarPage(
          store: store,
          platform: _planner,
          sync: google?.sync,
          // One for the app, so a model download outlives the calendar screen.
          recognizer: PlatformHandwritingRecognizer.shared,
          onConnectGoogle: google == null
              ? null
              : () async {
                  try {
                    await google.auth.connect();
                  } catch (error) {
                    if (mounted) showUserErrorSnackBar(context, error);
                  }
                },
          onDisconnectGoogle: google == null
              ? null
              : () async {
                  await google.auth.disconnect();
                  await google.sync.clear();
                },
          changes: _plannerChanges,
        ),
      },
    );
    // A phone's drawer closes first, as for the drawer's other rows.
    _scaffold.currentState?.closeDrawer();
    final navigator = Navigator.of(context);
    final other = _plannerShown;
    _plannerShown = (screen: screen, route: route);
    if (other != null && other.route.isActive) {
      // The other screen gives its place, with whatever was opened over it.
      navigator.popUntil((open) => identical(open, other.route));
      unawaited(navigator.pushReplacement(route));
    } else {
      unawaited(navigator.push(route));
    }
  }

  /// A widget or alarm tapped while the app runs: its screen opens over what is shown, after the
  /// workspace's current work, or once a vault is open.
  void _plannerRequested(String target) {
    final screen = PlannerScreen.values.asNameMap()[target];
    if (screen == null || !mounted) return;
    _plannerRequests++;
    if (controller == null) {
      _plannerWaiting = screen;
      return;
    }
    unawaited(_runWhenIdle(() => _openPlanner(screen)));
  }

  /// The screen of the widget or alarm tap that started the app, taken once the first vault is open.
  /// A tap that came while the vault was opening is newer, and one handled meanwhile wins.
  Future<void> _takePlannerLaunch() async {
    final requests = _plannerRequests;
    String? target;
    try {
      target = await _planner.takeLaunchTarget();
    } catch (error) {
      _plannerLog.warning('The planner launch target was not read: $error');
    }
    final waiting = _plannerWaiting;
    _plannerWaiting = null;
    final screen = waiting ?? PlannerScreen.values.asNameMap()[target];
    // A tap handled while the target was read is newer than both.
    if (screen == null || !mounted || requests != _plannerRequests) return;
    unawaited(_runWhenIdle(() => _openPlanner(screen)));
  }

  /// Another vault (or the first) sends its widgets at once, and an open planner screen, which works
  /// on the vault left, closes. A change in the vault tells the open planner screen, and sends the
  /// widgets two seconds after the last change when what they show changed.
  void _plannerVaultChanged(WorkspaceController c) {
    final scope = (c.repository, c.repositoryGeneration);
    final last = _plannerScope;
    if (last == scope) return;
    _plannerScope = scope;
    _plannerWidgetTimer?.cancel();
    if (last == null || !identical(last.$1, scope.$1)) {
      if (last != null) _closePlannerScreen();
      _sendPlannerWidgets();
      return;
    }
    // The screens read the vault in the root zone, as the library's reads do (see _readInBackground).
    Zone.root.run(() => _plannerChanges.value++);
    if (_plannerNative) {
      _plannerWidgetTimer = Timer(
        const Duration(seconds: 2),
        _sendPlannerWidgets,
      );
    }
  }

  /// The open planner screen, with whatever was opened over it.
  void _closePlannerScreen() {
    final shown = _plannerShown;
    _plannerShown = null;
    if (shown == null || !shown.route.isActive) return;
    Navigator.of(context)
      ..popUntil((route) => identical(route, shown.route))
      ..pop();
  }

  /// The open vault's reminders and calendar for the home-screen widgets, and its alarms
  /// ([PlannerWidgetSync]), in the root zone like the library's reads.
  void _sendPlannerWidgets() {
    final c = controller;
    if (!mounted || c == null || !_plannerNative) return;
    final repository = c.repository;
    _readInBackground(
      () => _plannerWidgets.send(
        repository,
        isCurrent: () =>
            mounted && identical(controller?.repository, repository),
      ),
    );
  }

  /// The top bar's cloud: Drive's state, and a tap opens the drawer or side panel, where the Drive
  /// panel is. Null without Drive, which leaves the library's own crossed-out cloud.
  Widget? _driveCloud({required bool panel}) {
    final drive = _driveConnection;
    if (drive == null) return null;
    return ListenableBuilder(
      listenable: drive,
      builder: (context, _) {
        final (icon, state) = _driveState(drive);
        return IconButton(
          key: const ValueKey('library-sync'),
          tooltip: state,
          icon: Icon(icon),
          iconSize: 22,
          style: libraryBarButtonStyle,
          onPressed: () {
            if (panel) {
              stows.libraryPanelOpen.value = true;
            } else {
              _scaffold.currentState?.openDrawer();
            }
          },
        );
      },
    );
  }

  /// The cloud's icon and words, as the Drive panel says them: not set up or signed out, connected and
  /// at rest, working, or a problem (an error, or another sync holding the lease).
  static (IconData, String) _driveState(DriveConnectionController drive) {
    if (drive.error != null) {
      return (Icons.sync_problem_outlined, 'Drive 연결 확인 필요');
    }
    if (drive.waitingForLease) {
      return (Icons.sync_problem_outlined, '다른 Drive 동기화 작업 대기 중');
    }
    if (!drive.ready || drive.busy) {
      return (Icons.cloud_sync_outlined, 'Drive 준비 중');
    }
    if (!drive.connected) return (Icons.cloud_off_outlined, 'Drive 미연결');
    return switch (drive.status.phase) {
      SyncPhase.pending => (Icons.cloud_sync_outlined, '업로드 대기'),
      SyncPhase.syncing => (Icons.cloud_sync_outlined, 'Drive 송수신 중'),
      SyncPhase.conflict => (Icons.sync_problem_outlined, '충돌 확인 필요'),
      SyncPhase.retryWaiting => (Icons.sync_problem_outlined, '연결 복구 후 재시도'),
      SyncPhase.authenticationRequired => (
        Icons.sync_problem_outlined,
        'Drive 재로그인 필요',
      ),
      SyncPhase.error => (Icons.sync_problem_outlined, 'Drive 오류'),
      SyncPhase.synced => (Icons.cloud_done_outlined, 'Drive 반영 완료'),
      SyncPhase.idle ||
      SyncPhase.closed => (Icons.cloud_done_outlined, 'Drive 연결됨'),
    };
  }

  /// Dark status bar icons on a light screen and light ones on a dark screen,
  /// as an AppBar sets them.
  static SystemUiOverlayStyle _statusBarIcons(Brightness brightness) =>
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        statusBarBrightness: brightness,
        systemStatusBarContrastEnforced: false,
      );

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c == null)
      return Scaffold(
        body: Center(
          child: _startupError == null
              ? const CircularProgressIndicator()
              : UserErrorText.of(
                  _startupError!,
                  prefix: '저장소를 열 수 없습니다',
                  textAlign: TextAlign.center,
                ),
        ),
      );
    return _buildWorkspace(context, c);
  }

  Widget _buildWorkspace(BuildContext context, WorkspaceController c) {
    _publishAppActions(c);
    final session = c.activeSession;
    final selectingLibrary = _librarySelection == _librarySelectionScope(c);
    final pdfPeerPreview = c.pdfPeerPreview;
    final desktop = defaultTargetPlatform != TargetPlatform.android;
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= 1000;
    // The open document's actions sit beside its editor's in the editor host's registry.
    if (session == null) {
      _editorChrome.actions.withdraw(this);
    } else {
      _publishDocumentActions(c, session, sideBySide: desktop && wide);
    }
    // The library keeps its side panel beside the documents on tablets (824 dp upright) and wider windows, so both
    // stay usable; phones and narrow windows keep the drawer.
    final libraryPanel = session == null && width >= 720;
    final showNoteRail = wide && desktop && session != null;
    Widget body;
    if (session == null) {
      _dataview = null;
      Widget libraryHome() => LibraryHome(
        leading: _libraryLeading(panel: libraryPanel),
        thumbnails: _thumbnails,
        // In the root zone, like the marks and facts: a cover's vault reads take turns with every other vault
        // call, and must not wait for the zone that built the card (a widget test's paused clock).
        onPreviewRequested: (note) =>
            _readInBackground(() => _requestThumbnail(note)),
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
          LibraryCreateAction.pageNoteWithPattern,
          if (c.canCreateDocument) LibraryCreateAction.quickNote,
          LibraryCreateAction.infinite,
          LibraryCreateAction.importPpt,
          LibraryCreateAction.importWord,
          LibraryCreateAction.importHwp,
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
        // An Office·한글 card opens straight into its editor.
        onOpenNote: (note) => _run(
          () => _open(
            note,
            officeAction: note.documentKind == VaultDocumentKind.office
                ? OfficeOpenAction.edit
                : null,
          ),
        ),
        searchBodyMatches: c.searchBodyMatches,
        onOpenBodyMatch: (note, match) =>
            _run(() => _open(note, bodyMatch: match)),
        onOpenFolder: (id) => _run(() => _goFolder(id)),
        onCreate: (action) => _run(() => _createDocument(action)),
        onNoteAction: (note, action) => _run(() => _noteAction(note, action)),
        onFolderAction: (folder, action) =>
            _run(() => _folderAction(folder, action)),
        // The search box opens in the top bar; the title's × clears it.
        onSearchChanged: (query) => _searchLibrary(c, query),
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
        onOpenSettings: () {
          if (!busy) _appActions.run(AppActionIds.openSettings, context);
        },
        settingsEnabled: !busy,
        syncButton: _driveCloud(panel: libraryPanel),
        facts: _libraryFacts(),
        marks: _marks,
        collection: _collectionFor(c),
        // Marks are written beside the screen's work, not through it.
        onToggleFavorite: (id) =>
            unawaited(_mark((marks) => marks.toggleFavorite(id))),
        onTogglePin: (id) => unawaited(_mark((marks) => marks.togglePin(id))),
        onEditLabels: (id) => unawaited(_editLabels(id)),
        onChangeCover: (id) => unawaited(_changeCover(id)),
        // Only Android has no Office engine for covers in the background.
        onMakeCover: defaultTargetPlatform == TargetPlatform.android
            ? (note) => unawaited(_makeCover(note))
            : null,
        // The imports going into this folder; × cancels one, or closes a failed one's card.
        importJobs: [
          for (final job in _importJobs.jobs)
            if (job.folderId == c.currentFolderId)
              LibraryImportJobView(
                id: job.id,
                title: job.title,
                progress: job.progress,
                error: job.error,
              ),
        ],
        onCancelImport: _importJobs.cancel,
      );
      // An import's progress builds the library again, not the whole workspace.
      body = ListenableBuilder(
        listenable: _importJobs,
        builder: (context, _) => libraryHome(),
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
          // The FutureBuilder still gets its errors; ignore() only keeps a late "Repository is closed", after the
          // screen is gone, from becoming an unhandled error.
          _relatedDatabases = _loadRelatedDatabases(c.repository)..ignore();
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
                    child: UserErrorText.of(
                      snapshot.error!,
                      prefix: '데이터베이스를 열 수 없습니다',
                      textAlign: TextAlign.center,
                    ),
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
                    child: UserErrorText.of(
                      snapshot.error!,
                      prefix: '페이지를 열 수 없습니다',
                      textAlign: TextAlign.center,
                    ),
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
                    child: UserErrorText.of(
                      snapshot.error!,
                      prefix: '카드 캔버스를 열 수 없습니다',
                      textAlign: TextAlign.center,
                    ),
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
              editorChrome: _editorChrome,
              repository: c.repository,
              note: session.note,
              engine: widget.officeEngine,
              previewEngine: widget.officePreviewEngine,
              pageLink: identical(_officePageLink?.session, session)
                  ? _officePageLink?.request
                  : null,
              onPageLinkHandled: (request) {
                if (identical(_officePageLink?.request, request)) {
                  _officePageLink = null;
                }
              },
              openRequest: identical(_officeOpenRequest?.session, session)
                  ? _officeOpenRequest?.request
                  : null,
              onOpenRequestHandled: (request) {
                if (identical(_officeOpenRequest?.request, request)) {
                  _officeOpenRequest = null;
                }
              },
              openEdits: c.officeOpenEdits,
              // An editor this screen opened (기록·도구 → 원본 편집) closed: the screen stays. 닫고 열기
              // asked it to close: it closes the tab and goes on itself.
              onEditorFinished: (outcome) {
                final waiting = _closeWaits.remove(session.note.id);
                if (waiting != null && !waiting.isCompleted) {
                  waiting.complete(outcome);
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
                    child: UserErrorText.of(
                      snapshot.error!,
                      prefix: '무한 노트를 열 수 없습니다',
                      textAlign: TextAlign.center,
                    ),
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
              chrome: _editorChrome,
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
    final noteBar = session == null
        ? null
        : _noteBar(c, session, sideBySide: desktop && wide);
    final workspace = PopScope(
      canPop:
          !selectingLibrary &&
          session == null &&
          c.currentFolderId == null &&
          _libraryCollection.kind == LibraryCollectionKind.folder &&
          !busy &&
          !c.dirty &&
          c.officeOpenEdits.entries.isEmpty,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_back());
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        // the tab row and the function row are dark: light icons over them
        value: _statusBarIcons(
          noteBar == null ? Theme.of(context).brightness : Brightness.dark,
        ),
        child: Scaffold(
        key: _scaffold,
        // The library has no top row, like StarNote's: its side bar and the
        // header above the documents hold its buttons.
        // An open document: the tab row, and the function row of a document that is not the ink editor.
        appBar: noteBar,
        // The drawer stays in the tree even where the library uses its side panel: removing it while it closes
        // would leave the Scaffold remembering it as open, and the next note would show it open again.
        drawer: wide
            ? null
            : Drawer(
                width: 260,
                backgroundColor: _drawerBackground(context),
                child: SafeArea(child: _library(c)),
              ),
        drawerEnableOpenDragGesture: !libraryPanel,
        // Without a top row the library starts below the status bar, full screen or not.
        // Without the workspace's rows (an ink note with the tab row hidden) the page starts below the status bar too.
        body: SafeArea(
          top:
              session == null ||
              noteBar == null && !DynamicMaterialApp.isFullscreen,
          bottom: false,
          left: false,
          right: false,
          child: Row(
            children: [
              if (libraryPanel)
                _libraryPanel(c)
              else if (showNoteRail) ...[
                SizedBox(width: 300, child: _library(c)),
                const VerticalDivider(width: 1),
              ],
              Expanded(
                child: Column(
                  children: [
                    if (busy ||
                        c.externalBusy ||
                        StudyWorkspace.pendingDocumentImport.processing ||
                        _editorHosts.working)
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
                        content: UserErrorText(
                          message: c.error!,
                          details: c.errorDetails,
                        ),
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
        ),
        ),
      ),
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyO, control: true):
            _quickSwitch,
      },
      child: Focus(
        autofocus: true,
        // The editor hosts sit beside the screen without drawing it, so they outlive any change
        // of the document shown.
        child: Stack(
          fit: StackFit.expand,
          children: [
            workspace,
            OfficeEditorHostLayer(
              hosts: _editorHosts,
              repository: c.repository,
              openEdits: c.officeOpenEdits,
              engine: widget.officeEngine,
              previewEngine: widget.officePreviewEngine,
            ),
          ],
        ),
      ),
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

  // The pen toolbar's full screen button also hides this screen's note bar.
  void _fullscreenChanged() {
    if (mounted) setState(() {});
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
    DynamicMaterialApp.removeFullscreenListener(_fullscreenChanged);
    _automation?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    if (Platform.isWindows) windowManager.removeListener(this);
    StudyWorkspace.pendingDocumentImport.removeListener(_sharedDocument);
    stows.noteTabBarHidden.removeListener(_tabBarHiddenChanged);
    stows.editorFingerDrawing.removeListener(_fingerDrawingChanged);
    _editorChrome.removeListener(_editorChromeChanged);
    _plannerWidgetTimer?.cancel();
    unawaited(_plannerOpens?.cancel());
    _plannerChanges.dispose();
    _plannerWidgets.dispose();
    _editorChrome.dispose();
    _editorHosts
      ..removeListener(_editorHostsChanged)
      ..dispose();
    _appActions.dispose();
    _importJobs
      ..cancelAll()
      ..dispose();
    unawaited(_editorFinishedEvents?.cancel());
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
