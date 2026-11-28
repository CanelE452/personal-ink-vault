import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:collapsible/collapsible.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as flutter_quill;
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/_asset_cache.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/canvas.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/canvas_image.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/components/canvas/page_link_layer.dart';
import 'package:saber/components/canvas/save_indicator.dart';
import 'package:saber/components/editor/read_only_banner.dart';
import 'package:saber/components/ink_ui/add_page/kit_add_page_window.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_save_chip.dart';
import 'package:saber/components/ink_ui/editor_toolbar/toolbar_customize_sheet.dart';
import 'package:saber/components/ink_ui/editor_toolbar/toolbar_tools_layout.dart'
    show kitIconForTool;
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/ink_ui/host_focus.dart';
import 'package:saber/components/ink_ui/hover_badge.dart';
import 'package:saber/components/ink_ui/kit_mode_pill.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_color_row.dart'
    show KitPenColorRow;
import 'package:saber/components/ink_ui/pen_panel/pen_panel_common.dart'
    show PenPanelSurface, inkInverted;
import 'package:saber/components/ink_ui/selection_bars/kit_lasso_bar.dart';
import 'package:saber/components/ink_ui/selection_bars/kit_text_bar.dart';
import 'package:saber/components/kit/kit_icons.g.dart';
import 'package:saber/components/kit/kit_pen_art.dart'
    show KitPenDash, KitPenKind;
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/theming/adaptive_alert_dialog.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/components/theming/saber_theme.dart';
import 'package:saber/components/toolbar/editor_bottom_sheet.dart';
import 'package:saber/components/toolbar/export_dialog.dart';
import 'package:saber/components/user_error_text.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/actions/shortcut_keys.dart';
import 'package:saber/data/app_external_screen.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_exporter.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/ink_swap.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/page_clipboard.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:saber/data/editor/page_list.dart';
import 'package:saber/data/editor/pdf_page_extract.dart';
import 'package:saber/data/extensions/change_notifier_extensions.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/extensions/matrix4_extensions.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/ink/pen_kind.dart'
    show isInkTool, penKindOf, toolForPenKind;
import 'package:saber/data/ink/stroke_style.dart' show InkNib;
import 'package:saber/data/nextcloud/saber_syncer.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/data/user_error.dart';
import 'package:saber/i18n/extensions/canvas_background_pattern_localized.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor_add_page_host.dart';
import 'package:saber/pages/editor/editor_chrome.dart';
import 'package:saber/pages/editor/editor_ink_input.dart';
import 'package:saber/pages/editor/editor_page_actions.dart';
import 'package:saber/pages/editor/editor_side_host.dart';
import 'package:saber/pages/editor/link_dialog.dart';
import 'package:saber/pages/home/whiteboard.dart';
import 'package:saber/pages/settings/app_settings_page.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/change.dart';
import 'package:url_launcher/url_launcher.dart';

part 'editor_actions.dart';
part 'editor_add_page.dart';
part 'editor_page_ops.dart';
part 'editor_toolbar_area.dart';

typedef _PhotoInfo = ({Uint8List bytes, String extension});

class Editor extends StatefulWidget {
  new({
    super.key,
    String? path,
    this.customTitle,
    this.pdfPath,
    this.initialPdfBaselinePageId,
    this.loadSnapshot,
    this.onSaveSnapshot,
    this.onDirtyChanged,
    this.onBusyChanged,
    this.onLoaded,
    this.onCancelImport,
    this.onBack,
    this.showDocumentHeader = true,
    this.workspaceReadOnly = false,
    this.chrome,
  }) : initialPath = path != null
           ? Future.value(path)
           : FileManager.newFilePath('/'),
       needsNaming = path == null;

  final Future<String> initialPath;
  final bool needsNaming;

  final String? customTitle;
  final String? pdfPath;
  final String Function(int)? initialPdfBaselinePageId;
  final Future<EditorCoreInfo> Function()? loadSnapshot;
  final Future<void> Function(EditorCoreInfo, int)? onSaveSnapshot;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<bool>? onBusyChanged;
  final ValueChanged<EditorCoreInfo>? onLoaded;
  final Future<void> Function()? onCancelImport;
  final VoidCallback? onBack;
  final bool showDocumentHeader;
  final bool workspaceReadOnly;

  /// The host's view of the note's function row and "기타 설정" panel. Without
  /// one, the editor draws them itself (the Office PDF ink view).
  final EditorChromeController? chrome;

  /// The file extension used by the app.
  /// Files with this extension are
  /// encoded in BSON format.
  static const extension = '.sbn2';

  /// The old file extension used by the app.
  /// Files with this extension are
  /// encoded in JSON format.
  static const extensionOldJson = '.sbn';

  static const double gapBetweenPages = 16;

  /// Returns true if [path] belongs to a hidden file
  /// used by other functions of the app
  static bool isReservedPath(String path) {
    return _reservedFilePaths.any((regex) => regex.hasMatch(path));
  }

  static final _reservedFilePaths = <RegExp>[
    RegExp(RegExp.escape(Whiteboard.filePath)),
  ];

  /// Whether the platform can rasterize a pdf
  static var canRasterPdf = true;

  @override
  State<Editor> createState() => EditorState();
}

class EditorState extends State<Editor> implements EditorInkHost {
  final log = Logger('EditorState');

  @override
  late var coreInfo = EditorCoreInfo.placeholder;

  final _canvasGestureDetectorKey = GlobalKey<CanvasGestureDetectorState>();
  final _transformationController = TransformationController();
  var _singlePageMode = false;

  /// Its listener publishes the actions; set, it moves to the new history.
  @override
  EditorHistory get history => _history;
  set history(EditorHistory value) {
    _history.removeListener(_publishActions);
    _history = value..addListener(_publishActions);
  }

  var _history = EditorHistory();

  /// The note's pages as a list: making, tidying, putting in, moving.
  @override
  late final pageList = PageList(
    pages: () => coreInfo.pages,
    history: () => history,
    onPageAdded: (page) => listenToQuillChanges(page.quill),
    onEndTidied: _scrollUpToLastPage,
  );

  late bool needsNaming = widget.needsNaming && stows.editorPromptRename.value;

  // A pen kind restored here also becomes the pen button's kind, so the
  // button and the pen in hand agree from the start.
  late Tool _currentTool = _rememberPenFamily(() {
    switch (stows.lastTool.value) {
      case .fountainPen:
        if (Pen.currentPen.toolId != stows.lastTool.value) {
          Pen.currentPen = Pen.fountainPen();
        }
        return Pen.currentPen;
      case .calligraphyPen:
        if (Pen.currentPen.toolId != stows.lastTool.value) {
          Pen.currentPen = Pen.calligraphyPen();
        }
        return Pen.currentPen;
      case .brush:
        if (Pen.currentPen.toolId != stows.lastTool.value) {
          Pen.currentPen = Pen.brush();
        }
        return Pen.currentPen;
      case .ballpointPen:
        if (Pen.currentPen.toolId != stows.lastTool.value) {
          Pen.currentPen = Pen.ballpointPen();
        }
        return Pen.currentPen;
      case .shapePen:
        if (Pen.currentPen.toolId != stows.lastTool.value) {
          Pen.currentPen = ShapePen();
        }
        return Pen.currentPen;
      case .highlighter:
        // the round highlighter when it was the last one in hand
        if (stows.lastHighlighterKind.value ==
            KitPenKind.highlighterRound.previewId) {
          return InkToolState.roundHighlighter();
        }
        return Highlighter.currentHighlighter;
      case .pencil:
        return Pencil.currentPencil;
      case .eraser:
        return Eraser();
      case .select:
        return Select.currentSelect;
      case .textEditing:
        return Tool.textEditing;
      case .laserPointer:
        return LaserPointer.currentLaserPointer;
    }
  }());
  @override
  Tool get currentTool => _currentTool;
  @override
  set currentTool(Tool tool) {
    _currentTool = tool;
    _ink.toolState.update(tool: tool);
    if (tool is! Eraser) _lastNonEraserTool = tool;
    if (isInkTool(tool)) _lastInkTool = tool;
    stows.lastTool.value = tool.toolId;
    if (tool is Highlighter) {
      stows.lastHighlighterKind.value = penKindOf(tool)!.previewId;
    }
    _rememberPenFamily(tool);
  }

  /// The pen panel's pen (fine-nib pen, fine pen, pencil, highlighter) used
  /// last: the pen action and leaving the text box bring it back. Unlike
  /// [Pen.currentPenFamily] it keeps the highlighter and skips the shape pen.
  late Tool _lastInkTool;

  /// Every way a pen kind gets in hand (the toolbar, leaving the text box,
  /// the stylus button giving the pen back) keeps the pen button in step.
  static Tool _rememberPenFamily(Tool tool) {
    if (Pen.isPenFamily(tool)) stows.lastPenFamily.value = tool.toolId;
    return tool;
  }

  ValueNotifier<SavingState> savingState = ValueNotifier(SavingState.saved);
  Timer? _delayedSaveTimer;
  Timer? _watchServerTimer;
  String? _snapshotError;
  var _editGeneration = 0;
  Future<void>? _snapshotSave;
  Future<void>? _initializing;
  var _initializingSnapshot = false;
  var _drawing = false;
  var _loadingSnapshot = true;
  late var _initialImportPending = widget.pdfPath != null;
  var _pdfImported = false;
  var _editorDisposed = false;

  /// 「링크 추가」 without a selection: the next tap on a page puts a link
  /// icon there, and drags do not draw.
  var _placingLink = false;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _placingHint;

  /// Whether [_placingHint] has reached the screen (it may wait behind
  /// another message).
  var _placingHintShown = false;

  /// The eyedropper waits for its tap on a page.
  bool get _eyedropping => _ink.toolState.eyedropper;
  Future<void>? _eyedropperPick;

  /// The eyedropper's last reading of the page, for tests to wait for.
  @visibleForTesting
  Future<void>? get eyedropperPick => _eyedropperPick;

  /// Ctrl+Z and the editor's other keys work while the focus is in here.
  final _editorFocus = FocusNode(debugLabel: 'Editor');

  /// Whether the floating bar is out: the toolbar's pen and eraser buttons
  /// show and hide it (it shows only for the pens and the eraser).
  final _floatingBarOpen = ValueNotifier(true);

  /// Where across the screen the toolbar button that last showed or hid the
  /// floating bar is: the bar grows from it and goes back into it.
  final _floatingBarFrom = ValueNotifier<double?>(null);

  /// The tip of the stroke on the page now, on the screen; null while none
  /// is drawn. The floating bar and the save chip fade out of its way.
  final _strokeAt = ValueNotifier<Offset?>(null);

  /// Where the S Pen hovers over the page area, for the badge by its tip.
  final _hoverBadge = HoverBadgeController();

  /// The note window of the toolbar's second button.
  final _noteSheetOpen = ValueNotifier(false);

  /// 「도구 막대 사용자화」 is open over the page.
  final _customizing = ValueNotifier(false);

  /// The left panel and the favourites (supplement Task 9).
  late final _side = _sideHost();

  @visibleForTesting
  EditorSideHost get side => _side;

  /// Saves what the quick note has not saved yet (the app goes to the
  /// background).
  Future<void> saveQuickNote() => _side.quickNote.flush();

  /// Closes 「도구 막대 사용자화」, the note window or the left panel if one
  /// is open over the page, and says whether one was: Android's back closes
  /// them before the note (the host's back asks this first).
  bool closeOpenWindow() {
    if (_customizing.value) {
      _customizing.value = false;
      return true;
    }
    if (_noteSheetOpen.value) {
      _noteSheetOpen.value = false;
      return true;
    }
    if (_side.panelOpen.value) {
      _side.panelOpen.value = false;
      return true;
    }
    return false;
  }

  /// ⋯ 「읽기 전용」: the pen and the fingers do not write, the page still
  /// moves and zooms. Not saved; it goes with the editor.
  final inkLocked = ValueNotifier(false);

  /// When this editor last changed the note (「문서 정보」).
  DateTime? _lastEditedAt;

  /// When this editor last changed the note, for its host's tab ⌄.
  DateTime? get lastEditedAt => _lastEditedAt;

  /// The loaded note may not change (a newer version, a damaged file, a
  /// preview), or it could not be read (the vault keeps no snapshot this app
  /// can open safely, a note from a newer app among them): the toolbar is
  /// folded away, so a host keeps its function row. Not while it is read.
  bool get readOnlyNote =>
      coreInfo.readOnly && (!_loadingSnapshot || _snapshotError != null);

  AppActionRegistry? _ownRegistry;

  /// The actions of an editor without a host (Saber's screen, an Office PDF
  /// without the workspace).
  AppActionRegistry get _ownActions => _ownRegistry ??= AppActionRegistry();

  /// Where this editor publishes its actions: the host's document registry,
  /// or its own.
  AppActionRegistry get _actions => widget.chrome?.actions ?? _ownActions;

  @visibleForTesting
  AppActionRegistry get actions => _actions;

  /// What the editor's ink windows read and ask of it.
  late final _ink = _EditorInkHost(this);

  /// 「지금 저장」 dims when there is nothing to save, and the tools and
  /// undo follow the tool state and the history: saving, a colour and a
  /// change do not always build the editor again.
  void _publishActions() => _actions.publish(this, _editorActions());

  void _reportBusy() => widget.onBusyChanged?.call(
    _drawing || _initialImportPending || _snapshotSave != null,
  );

  Future<void> _cancelImport() async {
    if (_initializingSnapshot ||
        _snapshotSave != null ||
        !_initialImportPending ||
        _editorDisposed)
      return;
    await widget.onCancelImport?.call();
  }

  ValueNotifier<QuillStruct?> quillFocus = ValueNotifier(null);

  /// The last non-Eraser [currentTool] value.
  late Tool _lastNonEraserTool = Pen.currentPenFamily;

  @override
  void initState() {
    DynamicMaterialApp.addFullscreenListener(_setState);
    // The finger toggle's action shows whether it is on.
    stows.editorFingerDrawing.addListener(_setState);
    stows.editorGestureMode.addListener(_gestureModeChanged);
    savingState.addListener(_publishActions);
    _ink.toolState.addListener(_publishActions);
    _history.addListener(_publishActions);

    _initializing = _initAsync();

    super.initState();
    widget.chrome?.attach(this);
    unawaited(_side.load());
    _lastInkTool = _firstInkTool();
    // A new note's name field keeps the focus it asks for.
    if (!needsNaming) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) takeFocusFromHost(_editorFocus);
      });
    }
  }

  @override
  void didUpdateWidget(Editor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chrome, widget.chrome)) {
      (oldWidget.chrome?.actions ?? _ownActions).withdraw(this);
      oldWidget.chrome?.detach(this);
      widget.chrome?.attach(this);
    }
  }

  Future<void> _initAsync() async {
    if (_initializingSnapshot || _editorDisposed) return;
    _initializingSnapshot = true;
    _snapshotError = null;
    try {
      final baselinePageId = widget.initialPdfBaselinePageId;
      final filePath = await widget.initialPath;
      await stows.lastSinglePageMode.waitUntilRead();
      if (_editorDisposed) return;
      _singlePageMode = stows.lastSinglePageMode.value;
      filenameTextEditingController.text = p.basename(filePath);
      if (needsNaming) {
        filenameTextEditingController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: filenameTextEditingController.text.length,
        );
      }
      if (!_pdfImported) {
        await _loadCoreInfo(filePath);
        if (_editorDisposed) return;
        if (_initialImportPending) {
          _reportBusy();
          if (baselinePageId == null) widget.onDirtyChanged?.call(true);
          if (coreInfo.readOnlyReason == .workspacePdfPreview)
            coreInfo.readOnlyReason = null;
          if (!await importPdfFromFilePath(
            widget.pdfPath!,
            baselinePageId: baselinePageId,
          )) {
            throw StateError('PDF 가져오기를 완료하지 못했습니다.');
          }
          _pdfImported = true;
          if (baselinePageId != null) {
            _initialImportPending = false;
            if (widget.workspaceReadOnly)
              coreInfo.readOnlyReason ??= .workspacePdfPreview;
            cancelAutosaveAndMarkSaved();
            _reportBusy();
          }
        }
      }
      _loadingSnapshot = false;
      if (_initialImportPending) {
        await saveToFile();
      } else if (!_editorDisposed) {
        widget.onLoaded?.call(coreInfo);
        if (_pdfImported && baselinePageId != null) _focusInitialTextPage();
      }
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) setState(() => _snapshotError = '필기를 열 수 없습니다: $error');
    } finally {
      _initializingSnapshot = false;
      if (mounted) setState(() {});
    }
  }

  Future _loadCoreInfo(String filePath) async {
    final loaded =
        await (widget.loadSnapshot?.call() ??
            EditorCoreInfo.loadFromFilePath(filePath));
    if (_editorDisposed) {
      loaded.dispose();
      throw StateError('편집기가 닫혔습니다.');
    }
    coreInfo = loaded;
    if (widget.workspaceReadOnly) {
      coreInfo.readOnlyReason ??= .workspacePdfPreview;
    }
    if (coreInfo.readOnly) {
      log.info('Loaded file as read-only: ${coreInfo.readOnlyReason}');
    }

    for (final page in coreInfo.pages) {
      listenToQuillChanges(page.quill);
    }

    if (coreInfo.isEmpty) {
      createPage(
        -1,
        firstPageId: _initialImportPending
            ? widget.initialPdfBaselinePageId?.call(-1)
            : null,
      );
    } else {
      for (final page in coreInfo.pages) {
        page.backgroundImage?.onMoveImage = onMoveImage;
        page.backgroundImage?.onDeleteImage = onDeleteImage;
        page.backgroundImage?.onMiscChange = autosaveAfterDelay;
        for (final image in page.images) {
          image.onMoveImage = onMoveImage;
          image.onDeleteImage = onDeleteImage;
          image.onMiscChange = autosaveAfterDelay;
        }
      }
    }

    if (!_initialImportPending || widget.initialPdfBaselinePageId == null)
      _focusInitialTextPage();

    if (coreInfo.filePath == Whiteboard.filePath &&
        stows.autoClearWhiteboardOnExit.value &&
        Whiteboard.needsToAutoClearWhiteboard) {
      // clear whiteboard (and add to history)
      clearAllPages();

      // save cleared whiteboard
      await saveToFile();
      Whiteboard.needsToAutoClearWhiteboard = false;
    } else {
      setState(() {});
    }
  }

  void _focusInitialTextPage() {
    if (currentTool != Tool.textEditing) return;
    final pageIndex = coreInfo.initialPageIndex ?? 0;
    assert(pageIndex < coreInfo.pages.length);
    quillFocus.value = coreInfo.pages[pageIndex].quill
      ..focusNode.requestFocus();
  }

  void _setState() => setState(() {});

  /// Gesture mode on: the pen tip badge forgets where the pen was, as
  /// 「읽기 전용」 does; back to writing, it waits for the pen to move.
  void _gestureModeChanged() {
    if (stows.editorGestureMode.value) _hoverBadge.value = null;
  }

  /// Creates pages until the given page index exists,
  /// plus an extra blank page
  void createPage(int pageIndex, {String? firstPageId}) =>
      pageList.fillTo(pageIndex, firstPageId: firstPageId);

  void removeExcessPages() => pageList.tidyEnd();

  /// After pages went off the end: scroll to the last page (only if we are
  /// below the last page).
  void _scrollUpToLastPage() {
    final canvas = _canvasGestureDetectorKey.currentState;
    final width = canvas?.containerBounds.maxWidth;
    if (canvas != null && width != null && width.isFinite && width > 0) {
      final bottomOfLastPage =
          CanvasGestureDetector.getTopOfPage(
            pageIndex: coreInfo.pages.length,
            pages: coreInfo.pages,
            screenWidth: width,
          ) -
          Editor.gapBetweenPages;
      if (_transformationController.toScene(Offset.zero).dy >
          bottomOfLastPage) {
        canvas.scrollToPage(coreInfo.pages.length - 1);
      }
    }
  }

  @override
  void undo([EditorHistoryItem? item]) {
    if (coreInfo.readOnly) return;
    if (item == null) {
      if (!history.canUndo) return;

      // if we disabled redo, re-enable it
      if (!history.canRedo) {
        // no redo is possible, so clear the redo stack
        history.clearRedo();
        // don't disable redoing anymore
        history.canRedo = true;
      }

      item = history.undo();
    }

    setState(() {
      switch (item!.type) {
        case .draw:
          for (final stroke in item.strokes) {
            coreInfo.pages[stroke.pageIndex].strokes.remove(stroke);
          }
          for (final image in item.images) {
            coreInfo.pages[image.pageIndex].images.remove(image);
          }
          removeExcessPages();

        case .erase:
          for (final stroke in item.strokes) {
            createPage(stroke.pageIndex);
            coreInfo.pages[stroke.pageIndex].insertStroke(stroke);
          }
          for (final image in item.images) {
            createPage(image.pageIndex);
            coreInfo.pages[image.pageIndex].images.add(image);
            image.newImage = true;
          }

        case .deletePage:
          // make sure we already have a (blank/otherwise) page at this index
          createPage(item.pageIndex - 1);

          // insert the page at the correct index
          coreInfo.pages.insert(item.pageIndex, item.page!);

          // fix the page indices of all pages after this one
          for (int i = item.pageIndex + 1; i < coreInfo.pages.length; ++i) {
            final page = coreInfo.pages[i];
            page.updatePageIndex(i);
          }

        case .insertPage:
          // remove that page wherever moves have put it. The tidying of
          // empty pages stops at a page the history holds, so it is there;
          // were it not, nothing is taken out rather than another page
          final index = coreInfo.pages.indexOf(item.page!);
          if (index != -1) {
            coreInfo.pages.removeAt(index);
            _renumberPages(index);
          }

        case .move:
          for (final stroke in item.strokes) {
            stroke.shift(Offset(-item.offset!.left, -item.offset!.top));
          }
          final select = Select.currentSelect;
          if (select.doneSelecting) {
            select.selectResult.path = select.selectResult.path.shift(
              Offset(-item.offset!.left, -item.offset!.top),
            );
          }
          for (final image in item.images) {
            image.dstRect = .fromLTRB(
              image.dstRect.left - item.offset!.left,
              image.dstRect.top - item.offset!.top,
              image.dstRect.right - item.offset!.right,
              image.dstRect.bottom - item.offset!.bottom,
            );
          }

        case .movePage:
          _movePageNow(item.page!, item.pageIndex);

        case .quillChange:
          final quill = coreInfo.pages[item.pageIndex].quill;
          quill.controller.undo();

        case .quillUndoneChange:
          final quill = coreInfo.pages[item.pageIndex].quill;
          quill.controller.redo();

        case .changeColor:
          for (final stroke in item.strokes) {
            stroke.color = item.colorChange![stroke]!.previous;
          }

        case .backgroundPattern:
          coreInfo.setNotePattern(
            item.backgroundPatternChange!.previous,
            item.patternFollowers,
          );

        case .addLink:
          _replaceLink(
            _linkPageOf(item),
            remove: item.link,
            put: item.replacedLink,
          );

        case .removeLink:
          _replaceLink(
            _linkPageOf(item),
            remove: item.replacedLink,
            put: item.link,
          );

        case .replace:
          pageList.undoSwaps(item.swaps!);
      }

      if (item.type != .move) {
        Select.currentSelect.unselect();
      }
    });

    autosaveAfterDelay();
  }

  void redo() {
    if (coreInfo.readOnly) return;
    if (!history.canRedo) return;
    final item = history.redo();

    switch (item.type) {
      case .draw:
        undo(item.copyWith(type: .erase));
      case .erase:
        undo(item.copyWith(type: .draw));
      case .deletePage:
        undo(item.copyWith(type: .insertPage));
      case .insertPage:
        undo(item.copyWith(type: .deletePage));
      case .move:
        undo(
          item.copyWith(
            offset: .fromLTRB(
              -item.offset!.left,
              -item.offset!.top,
              -item.offset!.right,
              -item.offset!.bottom,
            ),
          ),
        );
      case .movePage:
        undo(item.copyWith(pageIndex: item.toIndex, toIndex: item.pageIndex));
      case .quillChange:
        undo(item.copyWith(type: .quillUndoneChange));
      case .quillUndoneChange: // this will never happen
        throw Exception('history should not contain quillUndoneChange items');
      case .changeColor:
        undo(
          item.copyWith(
            colorChange: item.colorChange!.map(
              (key, value) => MapEntry(key, value.reverse()),
            ),
          ),
        );
      case .backgroundPattern:
        undo(
          item.copyWith(
            backgroundPatternChange: item.backgroundPatternChange!.reverse(),
          ),
        );
      case .addLink:
        undo(item.copyWith(type: .removeLink));
      case .removeLink:
        undo(item.copyWith(type: .addLink));
      case .replace:
        setState(() {
          pageList.redoSwaps(item.swaps!);
          Select.currentSelect.unselect();
        });
        autosaveAfterDelay();
    }
  }

  @override
  int? onWhichPageIsFocalPoint(Offset focalPoint) {
    for (int i = 0; i < coreInfo.pages.length; ++i) {
      if (coreInfo.pages[i].renderBox == null) continue;
      final pageBounds = Offset.zero & coreInfo.pages[i].size;
      if (pageBounds.contains(
        coreInfo.pages[i].renderBox!.globalToLocal(focalPoint),
      ))
        return i;
    }
    return null;
  }

  @override
  int? dragPageIndex;

  late final inkInput = EditorInkInput(this);

  @override
  bool get inkBlocked =>
      coreInfo.readOnly ||
      _initialImportPending ||
      _loadingSnapshot ||
      _placingLink ||
      _eyedropping ||
      // gesture mode and 읽기 전용: pens and fingers move and zoom the page
      stows.editorGestureMode.value ||
      inkLocked.value;

  @override
  Tool get lastNonEraserTool => _lastNonEraserTool;

  @override
  set strokeAt(Offset? at) => _strokeAt.value = at;

  @override
  void rebuild(VoidCallback fn) => setState(fn);

  @override
  void drawBegan() {
    _drawing = true;
    _editGeneration++;
    _reportBusy();
    widget.onDirtyChanged?.call(true);
  }

  @override
  void drawEnded({required bool save}) {
    _drawing = false;
    if (save) autosaveAfterDelay();
    widget.onDirtyChanged?.call(
      !history.isCurrentStateSaved || _initialImportPending,
    );
    _reportBusy();
  }

  void onMoveImage(EditorImage image, Rect offset) {
    history.recordChange(
      EditorHistoryItem(
        type: .move,
        pageIndex: image.pageIndex,
        strokes: [],
        images: [image],
        offset: offset,
      ),
    );
    // setState to update undo button
    setState(() {});
    autosaveAfterDelay();
  }

  void onDeleteImage(EditorImage image) {
    history.recordChange(
      EditorHistoryItem(
        type: .erase,
        pageIndex: image.pageIndex,
        strokes: [],
        images: [image],
      ),
    );
    setState(() {
      coreInfo.pages[image.pageIndex].images.remove(image);
    });
    autosaveAfterDelay();
  }

  void listenToQuillChanges(QuillStruct quill) {
    quill.changeSubscription?.cancel();
    quill.changeSubscription = quill.controller.changes.listen((event) {
      final pageIndex = coreInfo.pages.indexWhere(
        (page) => identical(page.quill, quill),
      );
      if (pageIndex < 0) return;
      final undoRedoButtonsNeedUpdating = !history.canUndo || history.canRedo;
      _addQuillChangeToHistory(
        quill: quill,
        pageIndex: pageIndex,
        event: event,
      );
      createPage(pageIndex); // create empty last page
      if (undoRedoButtonsNeedUpdating) {
        setState(() {});
      }
      autosaveAfterDelay();
    });
    quill.focusNode.addListener(_onQuillFocusChange);
  }

  void _onQuillFocusChange() {
    for (final page in coreInfo.pages) {
      if (!page.quill.focusNode.hasFocus) continue;
      quillFocus.value = page.quill;
    }
  }

  void _addQuillChangeToHistory({
    required QuillStruct quill,
    required int pageIndex,
    required flutter_quill.DocChange event,
  }) {
    final eventWasUndo = quill.controller.hasRedo;
    if (eventWasUndo) return;

    // the change subscription sometimes fires multiple times for the same change
    // so compare the "before" of each change to merge them
    if (history.canUndo && !history.canRedo) {
      final lastChange = history.peekUndo();
      if (lastChange.type == .quillChange &&
          lastChange.pageIndex == pageIndex &&
          lastChange.quillChange!.before == event.before) {
        history.undo(); // remove the last change, to be replaced
      }
    }

    history.recordChange(
      EditorHistoryItem(
        type: .quillChange,
        pageIndex: pageIndex,
        strokes: const [],
        images: const [],
        quillChange: event,
      ),
    );
  }

  void _refreshCurrentNote() async {
    if (coreInfo.readOnlyReason != .watchingServer) return;
    if (!stows.loggedIn) return;

    final relativeFilePath = coreInfo.filePath;
    assert(relativeFilePath.isNotEmpty, 'Cannot refresh unnamed file');
    final syncFile = await SaberSyncFile.relative(
      relativeFilePath + Editor.extension,
    );

    final bestFile = await SaberSyncInterface.getBestFile(
      syncFile,
      onLocalFileNotFound: .local,
      onEqualFiles: .local,
      preferCache: false,
    );
    if (bestFile != .remote) return;

    late final StreamSubscription<SaberSyncFile> subscription;
    void listener(SaberSyncFile transferred) {
      if (transferred != syncFile) return;
      subscription.cancel();
      _loadCoreInfo(relativeFilePath)
          .then((_) => coreInfo.readOnlyReason = .watchingServer);
    }

    subscription = syncer.downloader.transferStream.listen(listener);

    await syncer.downloader.enqueue(syncFile: syncFile);
    syncer.downloader.bringToFront(syncFile);
  }

  void autosaveAfterDelay() {
    if (coreInfo.readOnly) return;
    _editGeneration++;
    _side.pictureEdits++;
    _lastEditedAt = DateTime.now();
    widget.onDirtyChanged?.call(
      _drawing || _initialImportPending || !history.isCurrentStateSaved,
    );
    if (history.isCurrentStateSaved && !_initialImportPending)
      return cancelAutosaveAndMarkSaved();

    late final void Function() callback;

    void startTimer() {
      _delayedSaveTimer?.cancel();
      if (stows.autosaveDelay.value < 0) return;
      _delayedSaveTimer = Timer(
        Duration(milliseconds: stows.autosaveDelay.value),
        callback,
      );
    }

    callback = () {
      if (_drawing || _initialImportPending || Pen.currentStroke != null) {
        // don't save yet if the pen is currently drawing
        startTimer();
        return;
      }
      saveToFile();
    };

    savingState.value = .waitingToSave;
    startTimer();
  }

  void cancelAutosaveAndMarkSaved() {
    _delayedSaveTimer?.cancel();
    savingState.value = .saved;
    history.markLastChangeAsSaved();
    widget.onDirtyChanged?.call(_drawing || _initialImportPending);
  }

  Future<void> saveToFile() async {
    if (coreInfo.readOnly) return;
    if (widget.onSaveSnapshot != null) {
      if (_editorDisposed ||
          _drawing ||
          _loadingSnapshot ||
          Pen.currentStroke != null)
        return;
      final pending = _snapshotSave;
      if (pending != null) {
        await pending;
        if (savingState.value != SavingState.saved) await saveToFile();
        return;
      }
      if (savingState.value == SavingState.saved && !_initialImportPending)
        return;
      final completion = Completer<void>();
      _snapshotSave = completion.future;
      _reportBusy();
      _delayedSaveTimer?.cancel();
      final generation = _editGeneration;
      savingState.value = .saving;
      try {
        await widget.onSaveSnapshot!(coreInfo, currentPageIndex);
        if (_editorDisposed) return;
        if (_initialImportPending) {
          _initialImportPending = false;
          if (widget.workspaceReadOnly)
            coreInfo.readOnlyReason ??= .workspacePdfPreview;
          widget.onLoaded?.call(coreInfo);
        }
        if (generation == _editGeneration) {
          cancelAutosaveAndMarkSaved();
        } else {
          savingState.value = .waitingToSave;
          _delayedSaveTimer = Timer(
            const Duration(milliseconds: 500),
            saveToFile,
          );
        }
        if (mounted) setState(() => _snapshotError = null);
      } catch (error) {
        savingState.value = .failed;
        widget.onDirtyChanged?.call(true);
        if (mounted)
          setState(() => _snapshotError = '기기 저장 실패: $error. 다시 시도하세요.');
      } finally {
        _snapshotSave = null;
        completion.complete();
        if (!_editorDisposed) _reportBusy();
      }
      return;
    }

    switch (savingState.value) {
      case .saved:
        // avoid saving if nothing has changed
        return;
      case .saving:
        // avoid saving if already saving
        log.warning('saveToFile() called while already saving');
        return;
      case .waitingToSave:
      case .failed:
        // continue
        _delayedSaveTimer?.cancel();
        savingState.value = .saving;
    }
    if (history.isCurrentStateSaved) return cancelAutosaveAndMarkSaved();

    await _renameFileNow();

    final filePath = coreInfo.filePath + Editor.extension;
    final Uint8List bson;
    final OrderedAssetCache assets;
    coreInfo.assetCache.allowRemovingAssets = false;
    try {
      (bson, assets) = coreInfo.saveToBinary(
        currentPageIndex: currentPageIndex,
      );
    } finally {
      coreInfo.assetCache.allowRemovingAssets = true;
    }
    try {
      await Future.wait([
        FileManager.writeFile(filePath, bson, awaitWrite: true),
        for (int i = 0; i < assets.length; ++i)
          assets
              .getBytes(i)
              .then(
                (bytes) => FileManager.writeFile(
                  '$filePath.$i',
                  bytes,
                  awaitWrite: true,
                ),
              ),
        FileManager.removeUnusedAssets(filePath, numAssets: assets.length),
      ]);
      savingState.value = .saved;
      history.markLastChangeAsSaved();
    } catch (e, st) {
      log.severe('Failed to save file: $e', e, st);
      savingState.value = .failed;
      if (kDebugMode) rethrow;
      return;
    }

    if (!mounted) return;
    final page = coreInfo.pages.first;
    final previewHeight = page.previewHeight(lineHeight: coreInfo.lineHeight);
    final thumbnailSize = Size(720, 720 * previewHeight / page.size.width);
    final thumbnail = await EditorExporter.screenshotPage(
      coreInfo: coreInfo,
      pageIndex: 0,
      rasterizeAllStrokes: true,
      targetSize: thumbnailSize,
      cropHeight: previewHeight,
      pixelRatio: 1,
    );
    final thumbnailPng = await thumbnail.toByteData(format: .png);
    thumbnail.dispose();
    await FileManager.writeFile(
      // Note that this ends with .sbn2.p
      '$filePath.p',
      thumbnailPng!.buffer.asUint8List(),
      awaitWrite: true,
    );
  }

  late final _filenameFormKey = GlobalKey<FormState>();
  late final filenameTextEditingController = TextEditingController();
  Timer? _renameTimer;
  void renameFile([String? _]) {
    _renameTimer?.cancel();
    _renameTimer = Timer(const Duration(seconds: 5), _renameFileNow);
  }

  Future<void> _renameFileNow() async {
    if (widget.onSaveSnapshot != null) return;
    final newName = filenameTextEditingController.text.trim();
    if (newName == coreInfo.fileName) return;

    if (_filenameFormKey.currentState?.validate() ??
        _validateFilenameTextField(newName) == null) {
      coreInfo.filePath = await FileManager.moveFile(
        coreInfo.filePath + Editor.extension,
        newName.trim() + Editor.extension,
      );
      coreInfo.filePath = coreInfo.filePath.substring(
        0,
        coreInfo.filePath.lastIndexOf(Editor.extension),
      );
      needsNaming = false;
    }

    final actualName = coreInfo.fileName;
    if (actualName != newName) {
      // update text field if renamed differently
      filenameTextEditingController.value = filenameTextEditingController.value
          .copyWith(
            text: actualName,
            selection: TextSelection.fromPosition(
              TextPosition(offset: actualName.length),
            ),
            composing: TextRange.empty,
          );
    }
  }

  String? _validateFilenameTextField(String? newName) {
    if (newName == null) return null;
    return FileManager.validateFilename(newName);
  }

  void updateColorBar(Color color) {
    // 「기본 색」: the pen panel's first colour page (design 「기본 8색」);
    // pastel and grey colours go into the recent ones
    if (stows.recentColorsDontSavePresets.value &&
        KitTokens.penPanelColorPages.first.contains(color)) {
      return;
    }

    final newColorString = color.toARGB32().toString();

    // migrate from old pref format
    if (stows.recentColorsChronological.value.length !=
        stows.recentColorsPositioned.value.length) {
      log.info(
        'MIGRATING recentColors: ${stows.recentColorsChronological.value.length} vs ${stows.recentColorsPositioned.value.length}',
      );
      stows.recentColorsChronological.value = List.of(
        stows.recentColorsPositioned.value,
      );
    }

    if (stows.pinnedColors.value.contains(newColorString)) {
      // do nothing, color is already pinned
    } else if (stows.recentColorsPositioned.value.contains(newColorString)) {
      // if it's already a recent color, move it to the top
      stows.recentColorsChronological.value.remove(newColorString);
      stows.recentColorsChronological.value.add(newColorString);
      stows.recentColorsChronological.notifyListeners();
    } else {
      if (stows.recentColorsPositioned.value.length >=
          stows.recentColorsLength.value) {
        // if full, replace the oldest color with the new one
        final removedColorString = stows.recentColorsChronological.value
            .removeAt(0);
        stows.recentColorsChronological.value.add(newColorString);
        final int removedColorPosition = stows.recentColorsPositioned.value
            .indexOf(removedColorString);
        stows.recentColorsPositioned.value[removedColorPosition] =
            newColorString;
      } else {
        // if not full, add the new color to the end
        stows.recentColorsChronological.value.add(newColorString);
        stows.recentColorsPositioned.value.insert(0, newColorString);
      }
      stows.recentColorsChronological.notifyListeners();
      stows.recentColorsPositioned.notifyListeners();
    }
  }

  /// Prompts the user to pick photos from their device.
  /// Returns the number of photos picked.
  ///
  /// If [photoInfos] is provided, it will be used instead of the file picker.
  Future<int> _pickPhotos([List<_PhotoInfo>? photoInfos, int? at]) async {
    if (coreInfo.readOnly) return 0;

    final currentPageIndex = at ?? this.currentPageIndex;

    photoInfos ??= await _pickPhotosWithFilePicker();
    if (!mounted) return 0;
    if (photoInfos.isEmpty) return 0;

    // use the Select tool so that the user can move the new image
    currentTool = Select.currentSelect;

    final images = [
      for (final _PhotoInfo photoInfo in photoInfos)
        if (photoInfo.extension == '.svg')
          SvgEditorImage(
            id: coreInfo.nextImageId++,
            svgString: utf8.decode(photoInfo.bytes),
            svgFile: null,
            pageIndex: currentPageIndex,
            pageSize: coreInfo.pages[currentPageIndex].size,
            onMoveImage: onMoveImage,
            onDeleteImage: onDeleteImage,
            onMiscChange: autosaveAfterDelay,
            onLoad: () {
              if (mounted) setState(() {});
            },
            assetCache: coreInfo.assetCache,
          )
        else
          PngEditorImage(
            id: coreInfo.nextImageId++,
            extension: photoInfo.extension,
            imageProvider: MemoryImage(photoInfo.bytes),
            pageIndex: currentPageIndex,
            pageSize: coreInfo.pages[currentPageIndex].size,
            onMoveImage: onMoveImage,
            onDeleteImage: onDeleteImage,
            onMiscChange: autosaveAfterDelay,
            onLoad: () {
              if (mounted) setState(() {});
            },
            assetCache: coreInfo.assetCache,
          ),
    ];

    history.recordChange(
      EditorHistoryItem(
        type: .draw,
        pageIndex: currentPageIndex,
        strokes: [],
        images: images,
        page: coreInfo.pages[currentPageIndex],
      ),
    );
    createPage(currentPageIndex);
    coreInfo.pages[currentPageIndex].images.addAll(images);
    autosaveAfterDelay();

    return images.length;
  }

  Future<List<_PhotoInfo>> _pickPhotosWithFilePicker() async {
    // the app's own screen: a recording goes on while it is open
    final List<PlatformFile> files = await AppExternalScreen.run(
      () => FilePicker.pickFiles(
        type: FileType.custom,
        // Taken from
        // https://github.com/brendan-duncan/image/blob/main/doc/formats.md
        // (plus .svg)
        allowedExtensions: [
          'jpg',
          'jpeg',
          'png',
          'gif',
          'tiff',
          'bmp',
          'tga',
          'ico',
          'pvrtc',
          'svg',
          'webp',
          'psd',
          'exr',
        ],
      ),
    );
    if (files.isEmpty) return const [];

    return Future.wait([
      for (final file in files)
        () async {
          final extension = p.extension(file.path ?? file.name);
          if (extension.isEmpty) return null;
          final bytes = await file.readAsBytes();
          return (bytes: bytes, extension: extension);
        }(),
    ]).then((list) => list.nonNulls.toList());
  }

  /// Prompts the user to pick a PDF to import.
  /// Returns whether a PDF was picked.
  Future<bool> importPdf([int? at]) async {
    if (coreInfo.readOnly) return false;
    if (!Editor.canRasterPdf) return false;

    final file = await AppExternalScreen.run(
      () => FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      ),
    );
    if (file == null) return false;

    return importPdfFromFilePath(file.path!, at: at);
  }

  Future<bool> importPdfFromFilePath(
    String path, {
    String Function(int)? baselinePageId,
    int? at,
  }) async {
    final note = coreInfo;
    bool isCurrent() =>
        !_editorDisposed && identical(coreInfo, note) && !note.readOnly;
    if (!isCurrent()) return false;
    final pdfDocument = await note.assetCache.pdfDocumentCache.load(path);
    if (!isCurrent()) return false;

    // The headless cache guesses sizes until the progressive loader runs.
    if (pdfDocument.pages.any((page) => !page.isLoaded)) {
      await pdfDocument.loadPagesProgressively<void>(
        onPageLoadProgress: (_, _, _) => isCurrent(),
      );
    }
    if (!isCurrent() || _drawing || pdfDocument.pages.isEmpty) return false;

    final pages = <(PdfPage, Size)>[];
    for (final pdfPage in pdfDocument.pages) {
      assert(pdfPage.pageNumber >= 1, 'pdfrx page numbers start at 1');
      if (!pdfPage.isLoaded ||
          !pdfPage.width.isFinite ||
          !pdfPage.height.isFinite ||
          pdfPage.width <= 0 ||
          pdfPage.height <= 0) {
        return false;
      }

      // Normalize page widths so pen sizes stay consistent across the note.
      final height = EditorPage.defaultWidth * pdfPage.height / pdfPage.width;
      if (!height.isFinite || height <= 0) return false;
      pages.add((pdfPage, Size(EditorPage.defaultWidth, height)));
    }

    // pages may have gone while the file was picked and read
    var index = min(at ?? _addPageIndex(.end), note.pages.length);
    for (final (pdfPage, pageSize) in pages) {
      final page = EditorPage(
        pageId: baselinePageId?.call(pdfPage.pageNumber - 1),
        size: pageSize,
        backgroundImage: PdfEditorImage(
          id: note.nextImageId++,
          pdfBytes: null,
          pdfFile: File(path),
          pdfPage: pdfPage.pageNumber - 1,
          pageIndex: index,
          pageSize: pageSize,
          naturalSize: pdfPage.size,
          onMoveImage: onMoveImage,
          onDeleteImage: onDeleteImage,
          onMiscChange: autosaveAfterDelay,
          onLoad: () {
            if (mounted) setState(() {});
          },
          assetCache: note.assetCache,
        ),
      );
      // TODO(adil192): Group multiple pages into one atomic change
      _putPage(index++, page, record: baselinePageId == null);
    }

    if (note.pages.last.isNotEmpty) createPage(note.pages.length - 1);
    if (mounted) setState(() {});

    if (baselinePageId == null) autosaveAfterDelay();

    return true;
  }

  Future<void> paste() async {
    if (quillFocus.value?.focusNode.hasFocus ?? false) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Image clipboard paste is unavailable in this validation build. '
          'Use the image import button instead. Text fields support normal paste.',
        ),
      ),
    );
  }

  /// The note as the export dialog draws it: without the paper's lines, grid
  /// or dots when [background] is off, the pages' own too. PDF pages and
  /// pictures stay.
  @visibleForTesting
  EditorCoreInfo exportInfo(bool background) =>
      background ? coreInfo : coreInfo.withoutPatterns();

  Future<void> exportAsPdf(
    BuildContext context, {
    String? name,
    bool background = true,
  }) async {
    final pdf = await EditorExporter.generatePdf(
      exportInfo(background),
      context,
    );
    final bytes = await pdf.save();
    if (!context.mounted) return;
    await FileManager.exportFile(
      '${name ?? coreInfo.fileName}.pdf',
      bytes,
      context: context,
    );
  }

  /// Exports the current note as an SBA (Saber Archive) file.
  Future<void> exportAsSba(
    BuildContext context, {
    String? name,
    bool background = true,
  }) async {
    final sba = await coreInfo.saveToSba(currentPageIndex: currentPageIndex);
    if (!context.mounted) return;
    await FileManager.exportFile(
      '${name ?? coreInfo.fileName}.sba',
      Uint8List.fromList(sba),
      context: context,
    );
  }

  /// Exports the current page as a PNG image file.
  ///
  /// This captures the canvas natively via [EditorExporter.screenshotPage],
  /// which guarantees the correct background color and omits UI elements
  /// like selection bounds or the text cursor. It computes a dynamic [pixelRatio]
  /// to ensure high quality while averting Out-Of-Memory exceptions on large canvases.
  Future<void> exportAsPng(
    BuildContext context, {
    String? name,
    bool background = true,
  }) async {
    final page = coreInfo.pages[currentPageIndex];

    const maxRasterizableSize = 3000.0;
    var targetPixelRatio = maxRasterizableSize / page.size.longestSide;
    if (targetPixelRatio > 1) targetPixelRatio = 1;

    try {
      final image = await EditorExporter.screenshotPage(
        coreInfo: exportInfo(background),
        pageIndex: currentPageIndex,
        rasterizeAllStrokes: true,
        pixelRatio: targetPixelRatio,
      );
      final pngBytes = await image.toByteData(format: .png);
      image.dispose();

      if (!context.mounted) return;
      await FileManager.exportFile(
        '${name ?? coreInfo.fileName}_page_${currentPageIndex + 1}.png',
        pngBytes!.buffer.asUint8List(),
        isImage: true,
        context: context,
      );
    } catch (e, st) {
      log.severe('Failed to export PNG', e, st);
    }
  }

  @override
  Widget build(BuildContext context) {
    _actions.publish(this, _editorActions());
    final platform = Theme.of(context).platform;
    _reportChrome();

    final Widget canvas = CanvasGestureDetector(
      key: _canvasGestureDetectorKey,
      filePath: coreInfo.filePath,
      isDrawGesture: inkInput.isDrawGesture,
      onInteractionEnd: inkInput.onInteractionEnd,
      onDrawStart: inkInput.onDrawStart,
      onDrawUpdate: inkInput.onDrawUpdate,
      onDrawEnd: inkInput.onDrawEnd,
      onHovering: inkInput.onHovering,
      onHoveringEnd: inkInput.onHoveringEnd,
      onStylusButtonChanged: inkInput.onStylusButtonChanged,
      updatePointerData: inkInput.updatePointerData,
      undo: undo,
      redo: redo,
      pages: coreInfo.pages,
      initialPageIndex: coreInfo.initialPageIndex,
      initialSinglePageMode: _singlePageMode,
      pageBuilder: pageBuilder,
      isTextEditing: () => currentTool == Tool.textEditing,
      footRoom: _side.audio.footRoom,
      placeholderPageBuilder: (BuildContext context, int pageIndex) {
        return Canvas(
          path: coreInfo.filePath,
          page: coreInfo.pages[pageIndex],
          pageIndex: 0,
          textEditing: false,
          coreInfo: EditorCoreInfo.placeholder,
          currentStroke: null,
          currentStrokeDetectedShape: null,
          currentSelection: null,
          placeholder: true,
          setAsBackground: null,
          currentTool: currentTool,
          currentScale: double.minPositive,
        );
      },
      transformationController: _transformationController,
    );

    final readonlyBanner = ReadOnlyBanner(
      coreInfo.readOnlyReason,
      action: coreInfo.readOnlyReason == .versionTooNew
          ? showVersionTooNewDialog
          : null,
    );

    final Widget body = Column(
      children: [
        ..._toolbarArea(),
        Expanded(
          child: _pageArea(
            // A touch on the page brings the keys here, unless the text box
            // is in hand (it takes them for its text). Also from a field or
            // button inside the editor: a finger on Android does not unfocus
            // them. On lifting: as the touch lands, a text field elsewhere
            // gives its focus back to the screen (a mouse or pen tapping
            // outside it), after this editor would have asked.
            Listener(
              onPointerUp: (_) {
                if (!_editorFocus.hasPrimaryFocus &&
                    currentTool != Tool.textEditing) {
                  _editorFocus.requestFocus();
                }
              },
              child: canvas,
            ),
          ),
        ),
        readonlyBanner,
      ],
    );

    final Widget screen = ListenableBuilder(
      listenable: Listenable.merge([
        savingState,
        _noteSheetOpen,
        _customizing,
        _side.panelOpen,
      ]),
      builder: (context, child) {
        final saving = savingState.value;
        // Back closes a window over the page first (a host asks
        // closeOpenWindow itself); don't allow user to go back until saving
        // is done
        final windowOpen =
            widget.onBack == null &&
            (_noteSheetOpen.value ||
                _customizing.value ||
                _side.panelOpen.value);
        return PopScope(
          canPop: !windowOpen && (widget.onBack != null || saving == .saved),
          onPopInvokedWithResult: (didPop, _) {
            if (widget.onBack != null) return;
            if (!didPop && closeOpenWindow()) return;
            switch (saving) {
              case .waitingToSave:
              case .failed:
                assert(!didPop);
                saveToFile(); // trigger save now
                snackBarNeedsToSaveBeforeExiting();
              case .saving:
                assert(!didPop);
                snackBarNeedsToSaveBeforeExiting();
              case .saved:
                break;
            }
          },
          child: child!,
        );
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: DynamicMaterialApp.isFullscreen || !widget.showDocumentHeader
            ? null
            : AppBar(
                primary: widget.showDocumentHeader,
                automaticallyImplyLeading: widget.showDocumentHeader,
                automaticallyImplyActions: false,
                toolbarHeight: widget.showDocumentHeader ? kToolbarHeight : 48,
                title: !widget.showDocumentHeader
                    ? null
                    : widget.customTitle != null
                    ? Text(widget.customTitle!)
                    : Form(
                        key: _filenameFormKey,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        child: TextFormField(
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                          ),
                          controller: filenameTextEditingController,
                          onChanged: renameFile,
                          autofocus: needsNaming,
                          validator: _validateFilenameTextField,
                        ),
                      ),
                leading: widget.showDocumentHeader
                    ? SaveIndicator(
                        savingState: savingState,
                        triggerSave: saveToFile,
                        onBack: widget.onBack,
                      )
                    : null,
              ),
        body: Column(
          children: [
            if (_snapshotError != null)
              MaterialBanner(
                content: Text(_snapshotError!),
                actions: [
                  if (_initialImportPending && widget.onCancelImport != null)
                    TextButton(
                      onPressed: _initializingSnapshot || _snapshotSave != null
                          ? null
                          : _cancelImport,
                      child: const Text('PDF 가져오기 취소'),
                    ),
                  TextButton(
                    onPressed: _loadingSnapshot
                        ? () {
                            _initializing = _initAsync();
                          }
                        : coreInfo.readOnly
                        ? null
                        : saveToFile,
                    child: const Text('다시 저장'),
                  ),
                ],
              ),
            Expanded(
              child: _loadingSnapshot || _initialImportPending
                  ? Center(
                      child: _snapshotError == null
                          ? const CircularProgressIndicator()
                          : const Text('가져오기 또는 저장을 완료한 뒤 노트를 열 수 있습니다.'),
                    )
                  : body,
            ),
          ],
        ),
        // The way out of full screen whenever the toolbar (and its exit button) is folded away there.
        floatingActionButton:
            (DynamicMaterialApp.isFullscreen &&
                (coreInfo.readOnly ||
                    !stows.editorToolbarShowInFullscreen.value))
            ? FloatingActionButton(
                shape: platform.isCupertino ? const CircleBorder() : null,
                onPressed: () {
                  DynamicMaterialApp.setFullscreen(false, updateSystem: true);
                },
                child: const Icon(Icons.fullscreen_exit),
              )
            : null,
      ),
    );

    // Bars below read the actions with AppActionScope.read (the page and
    // the canvas never rebuild for them).
    return AppActionScope(
      actions: _actions,
      child: Shortcuts(
        shortcuts: _keyboardShortcuts(),
        child: Actions(
          actions: {
            _EditorKeyIntent: _EditorKeyAction(
              _runKey,
              () => _editorFocus.hasPrimaryFocus,
            ),
          },
          child: Focus(
            focusNode: _editorFocus,
            autofocus: !needsNaming,
            child: screen,
          ),
        ),
      ),
    );
  }

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int? _chromeSignature;

  /// The note is loaded and its PDF import saved. The function row stays on
  /// screen while the body shows the import's spinner, so its page actions
  /// wait for this.
  bool get _noteReady => !_loadingSnapshot && !_initialImportPending;

  bool get _showPageActions => !coreInfo.readOnly && _noteReady;

  /// The note may not change now: read-only, or ⋯ 「읽기 전용」 is on.
  bool get _noteLocked => coreInfo.readOnly || inkLocked.value;

  bool get _showPageMode =>
      !_loadingSnapshot && !_initialImportPending && coreInfo.pages.isNotEmpty;

  /// Tells the host's controller that what the function row shows changed.
  /// Not on every build: the editor rebuilds while drawing.
  void _reportChrome() {
    final chrome = widget.chrome;
    if (chrome == null) return;
    final signature = Object.hash(
      coreInfo.readOnly,
      _singlePageMode,
      coreInfo.pages.length,
      _loadingSnapshot,
      _snapshotError != null,
      _initialImportPending,
      DynamicMaterialApp.isFullscreen,
      stows.editorFingerDrawing.value,
      _placingLink,
    );
    if (signature == _chromeSignature) return;
    _chromeSignature = signature;
    chrome.changed();
  }

  void _toggleFingerDrawing() {
    stows.editorFingerDrawing.value = !stows.editorFingerDrawing.value;
    inkInput.lastSeenPointerCount = 0;
  }

  void _openExportDialog() {
    if (coreInfo.readOnly) return;
    unawaited(
      showExportDialog(
        context,
        title: widget.customTitle ?? coreInfo.fileName,
        pdf: exportAsPdf,
        image: exportAsPng,
        original: exportAsSba,
      ),
    );
  }

  /// "템플릿 변경": the page sheet (paper, lines, background, imports and
  /// clearing pages), the former 쪽 메뉴.
  void _openPageMenu() => unawaited(
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => bottomSheet(context),
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: ColorScheme.of(context).surface,
      constraints: const BoxConstraints(maxWidth: 500),
    ),
  );

  /// ⋯ 「쪽으로 이동」: asks for the page number, then goes there.
  void _openGoToPage(BuildContext context) => unawaited(
    showDialog<int>(
      context: context,
      builder: (_) => _GoToPageDialog(
        pages: coreInfo.pages.length,
        current: currentPageIndex + 1,
      ),
    ).then((page) {
      if (page != null && mounted) _scrollToPage(page - 1);
    }),
  );

  void snackBarNeedsToSaveBeforeExiting() {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t.editor.needsToSaveBeforeExiting)));
  }

  Widget bottomSheet(BuildContext context) {
    final Brightness brightness = Theme.brightnessOf(context);
    final invert = stows.editorAutoInvert.value && brightness == .dark;
    final int currentPageIndex = this.currentPageIndex;

    return EditorBottomSheet(
      invert: invert,
      coreInfo: coreInfo,
      currentPageIndex: currentPageIndex,
      setBackgroundPattern: (pattern) => setState(() {
        if (_noteLocked) return;
        final previous = coreInfo.backgroundPattern;
        final followers = coreInfo.setNotePattern(pattern);
        stows.lastBackgroundPattern.value = pattern;
        history.recordChange(
          EditorHistoryItem(
            type: .backgroundPattern,
            pageIndex: currentPageIndex,
            backgroundPatternChange: Change(
              previous: previous,
              current: pattern,
            ),
            patternFollowers: (own: pattern, pages: followers),
            strokes: [],
            images: [],
          ),
        );
        autosaveAfterDelay();
      }),
      setLineHeight: (lineHeight) => setState(() {
        if (_noteLocked) return;
        coreInfo.lineHeight = lineHeight;
        stows.lastLineHeight.value = lineHeight;
        autosaveAfterDelay();
      }),
      setLineThickness: (lineThickness) => setState(() {
        if (_noteLocked) return;
        coreInfo.lineThickness = lineThickness;
        stows.lastLineThickness.value = lineThickness;
        autosaveAfterDelay();
      }),
      removeBackgroundImage: () => setState(() {
        if (_noteLocked) return;

        final page = coreInfo.pages[currentPageIndex];
        if (page.backgroundImage == null) return;
        page.images.add(page.backgroundImage!);
        page.backgroundImage = null;

        autosaveAfterDelay();
      }),
      redrawImage: () => setState(() {}),
      clearPage: () {
        clearPage(currentPageIndex);
      },
      clearAllPages: clearAllPages,
      redrawAndSave: () => setState(() {
        if (_noteLocked) return;
        autosaveAfterDelay();
      }),
      pickPhotos: _pickPhotos,
      importPdf: importPdf,
      canRasterPdf: Editor.canRasterPdf,
      getIsWatchingServer: () => _watchServerTimer?.isActive ?? false,
      setIsWatchingServer: (bool watch) {
        if (watch) {
          _watchServerTimer ??= Timer.periodic(
            const Duration(seconds: 5),
            (_) => _refreshCurrentNote(),
          );
          if (coreInfo.readOnlyReason != .watchingServer) {
            assert(coreInfo.readOnlyReason == null);
            coreInfo.readOnlyReason = .watchingServer;
            if (mounted) setState(() {});
          }
        } else {
          _watchServerTimer?.cancel();
          _watchServerTimer = null;
          if (coreInfo.readOnlyReason == .watchingServer) {
            coreInfo.readOnlyReason = null;
            if (mounted) setState(() {});
          }
        }
      },
    );
  }

  Widget pageBuilder(BuildContext context, int pageIndex) {
    final page = coreInfo.pages[pageIndex];
    final currentStroke = Pen.currentStroke?.pageIndex == pageIndex
        ? Pen.currentStroke
        : null;
    return Canvas(
      path: coreInfo.filePath,
      page: page,
      pageIndex: pageIndex,
      textEditing: currentTool == Tool.textEditing,
      inkLocked: inkLocked.value,
      coreInfo: coreInfo,
      currentStroke: currentStroke,
      currentStrokeDetectedShape:
          currentTool is ShapePen && currentStroke != null
          ? ShapePen.detectedShape
          : null,
      currentSelection: () {
        // The eraser's loop shows like a lasso (the canvas draws it in the
        // error colour while the eraser is in hand).
        if (currentTool case final Eraser eraser) {
          final loop = eraser.lassoPath;
          if (loop == null || eraser.lassoPageIndex != pageIndex) return null;
          return SelectResult(
            pageIndex: pageIndex,
            strokes: const [],
            images: const [],
            path: loop,
          );
        }
        if (currentTool is! Select) return null;
        final selectResult = (currentTool as Select).selectResult;
        if (selectResult.pageIndex != pageIndex) return null;
        return selectResult;
      }(),
      setAsBackground: (EditorImage image) {
        if (page.backgroundImage != null) {
          // restore previous background image as normal image
          page.images.add(page.backgroundImage!);
        }
        page.images.remove(image);
        page.backgroundImage = image;

        CanvasImage.activeListener
            .notifyListenersPlease(); // un-select active image

        autosaveAfterDelay();
        setState(() {});
      },
      currentTool: currentTool,
      currentScale: _transformationController.value.approxScale,
      linkLayer: PageLinkLayer(
        links: page.links,
        pageSize: page.size,
        screenScale: _screenScale(page),
        readOnly: _noteLocked,
        ignoring: currentTool is Select || currentTool == Tool.textEditing,
        onAction: (link, action) =>
            unawaited(_onLinkAction(page, link, action)),
        // The eyedropper waits for its tap on the same layer as 링크 추가.
        onPlace: _placingLink && !inkLocked.value
            ? (point) => unawaited(_placeLink(page, point))
            : _eyedropping
            ? (point) => _pickColour(page, point)
            : null,
      ),
    );
  }

  /// Logical pixels on screen per unit of [page]: the page fitted to the
  /// canvas width, never enlarged (as CanvasGestureDetector lays pages out),
  /// times the zoom. Pages are built again whenever either changes.
  double _screenScale(EditorPage page) {
    final width =
        _canvasGestureDetectorKey.currentState?.containerBounds.maxWidth;
    final fit = width != null && width.isFinite && width > 0
        ? min(1.0, width / page.size.width)
        : 1.0;
    return fit * _transformationController.value.approxScale;
  }

  /// Puts a copy of page [pageIndex] after it, as one undo step.
  void _duplicatePage(int pageIndex) => setState(() {
    if (_noteLocked) return;
    final page = coreInfo.pages[pageIndex];
    final newPage = page.copyWith(
      newIdentity: true,
      strokes: page.strokes
          .map((stroke) => stroke.copy()..pageIndex += 1)
          .toList(),
      images: page.images
          .map((image) => image.copy()..pageIndex += 1)
          .toList(),
      quill: QuillStruct(
        controller: flutter_quill.QuillController(
          document: flutter_quill.Document.fromDelta(
            page.quill.controller.document.toDelta(),
          ),
          selection: const TextSelection.collapsed(offset: 0),
        ),
        focusNode: FocusNode(debugLabel: 'Quill Focus Node'),
      ),
      backgroundImage: page.backgroundImage?.copy()?..pageIndex += 1,
    );
    _putPage(pageIndex + 1, newPage);
    autosaveAfterDelay();
  });

  void insertPageAfter(int pageIndex) => setState(() {
    if (_noteLocked) return;
    _putPage(pageIndex + 1, EditorPage());
    autosaveAfterDelay();
  });

  /// Empties the page as one undo step, which puts everything back at its
  /// place on this page; a page with nothing on it records nothing.
  void clearPage(int pageIndex) {
    if (_noteLocked) return;
    final page = coreInfo.pages[pageIndex];
    if (page.strokes.isEmpty && page.images.isEmpty) return;
    setState(() {
      pageList.recordReplace([_emptied(page)]);
      autosaveAfterDelay();
    });
  }

  /// Empties every page that has strokes or pictures, as one undo step.
  void clearAllPages() {
    if (_noteLocked) return;
    setState(() {
      pageList.recordReplace([
        for (final page in coreInfo.pages)
          if (page.strokes.isNotEmpty || page.images.isNotEmpty)
            _emptied(page),
      ]);
    });
    autosaveAfterDelay();
  }

  /// Takes [page]'s strokes and pictures off; the change, by places.
  PageSwap _emptied(EditorPage page) {
    final swap = InkSwap(
      removedStrokes: [...page.strokes.indexed],
      removedImages: [...page.images.indexed],
    );
    page.strokes.clear();
    page.images.clear();
    return (page: page, swap: swap);
  }

  Future<void> showVersionTooNewDialog() async {
    final disableReadOnly =
        await showDialog(
          context: context,
          builder: (context) => AdaptiveAlertDialog(
            title: Text(t.editor.versionTooNew.title),
            content: Text(t.editor.versionTooNew.subtitle),
            actions: [
              CupertinoDialogAction(
                child: Text(t.common.cancel),
                onPressed: () => Navigator.pop(context, false),
              ),
              CupertinoDialogAction(
                child: Text(t.editor.versionTooNew.allowEditing),
                onPressed: () => Navigator.pop(context, true),
              ),
            ],
          ),
        ) ??
        false;

    if (!mounted) return;
    if (!disableReadOnly) return;

    if (coreInfo.readOnlyReason == .versionTooNew) {
      coreInfo.readOnlyReason = null;
      if (mounted) setState(() {});
    }
  }

  late int _lastCurrentPageIndex = coreInfo.initialPageIndex ?? 0;

  void _togglePageMode() {
    if (_drawing ||
        _loadingSnapshot ||
        _initialImportPending ||
        _snapshotSave != null ||
        savingState.value == .saving ||
        (quillFocus.value?.focusNode.hasFocus ?? false)) {
      return;
    }

    final next = !_singlePageMode;
    final canvas = _canvasGestureDetectorKey.currentState;
    if (canvas?.setSinglePageMode(next) != true) return;
    setState(() => _singlePageMode = next);
    stows.lastSinglePageMode.value = next;
  }

  void _scrollToPage(int pageIndex) {
    _canvasGestureDetectorKey.currentState?.scrollToPage(pageIndex);
  }

  bool revealPage(String pageId, {required EditorImage? background}) {
    if (_editorDisposed ||
        _loadingSnapshot ||
        _drawing ||
        savingState.value != .saved) {
      return false;
    }
    final index = coreInfo.pages.indexWhere(
      (page) =>
          page.pageId == pageId && identical(page.backgroundImage, background),
    );
    return index >= 0 &&
        (_canvasGestureDetectorKey.currentState?.scrollToPage(index) ?? false);
  }

  /// Shows the page with [pageId] (a link to a page of this note). False
  /// when the note has no such page.
  bool revealPageId(String pageId) {
    final index = coreInfo.pages.indexWhere((page) => page.pageId == pageId);
    if (index < 0) return false;
    _scrollToPage(index);
    return true;
  }

  List<({String pageId, int number})> _linkablePages() => [
    for (final (index, page) in coreInfo.pages.indexed)
      (pageId: page.pageId, number: index + 1),
  ];

  /// The rectangle around the lassoed strokes and pictures (not the loop).
  static Rect? _selectionArea(SelectResult selection) {
    Rect? area;
    for (final rect in [
      for (final stroke in selection.strokes) stroke.lowQualityPath.getBounds(),
      for (final image in selection.images) image.dstRect,
    ]) {
      area = area?.expandToInclude(rect) ?? rect;
    }
    return area;
  }

  /// The selection bar's 「링크」: a link over the lassoed strokes and pictures.
  Future<void> _linkSelection() async {
    final select = Select.currentSelect;
    if (currentTool is! Select || !select.doneSelecting) return;
    final page = coreInfo.pages.elementAtOrNull(select.selectResult.pageIndex);
    final area = _selectionArea(select.selectResult);
    if (page == null || area == null) return;
    if (await _addLink(page, area) && mounted) setState(select.unselect);
  }

  /// 「링크 추가」: a link over the lasso's selection or, without one,
  /// Notein's way: the next tap on a page puts a link icon there.
  void _linkAdd() {
    if (_noteLocked) return;
    if (currentTool is Select && Select.currentSelect.doneSelecting) {
      unawaited(_linkSelection());
      return;
    }
    if (_placingLink) return _stopPlacingLink();
    setState(() => _placingLink = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    // Shown after any message already on screen, which it never hides.
    late final ScaffoldFeatureController<SnackBar, SnackBarClosedReason> hint;
    hint = messenger.showSnackBar(
      SnackBar(
        content: const Text('링크를 둘 곳을 누르세요'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(label: '취소', onPressed: () {}),
        onVisible: () => _placingHintVisible(hint),
      ),
    );
    _placingHint = hint;
    _placingHintShown = false;
    // The wait lasts as long as its hint: 취소, a swipe or the timeout end it.
    unawaited(
      hint.closed.then((_) {
        if (!identical(_placingHint, hint)) return;
        _placingHint = null;
        _placingHintShown = false;
        if (mounted) setState(() => _placingLink = false);
      }),
    );
  }

  /// A SnackBar's controller may close it only while it is the one on screen
  /// (otherwise it would hide another app message). So a hint that is no
  /// longer wanted when its turn comes closes itself then.
  void _placingHintVisible(
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason> hint,
  ) {
    if (mounted && identical(_placingHint, hint)) {
      _placingHintShown = true;
    } else {
      hint.close();
    }
  }

  /// Closes the hint if it is on screen; a hint still waiting behind another
  /// message closes itself when it shows ([_placingHintVisible]).
  void _closePlacingHint() {
    final hint = _placingHint;
    final shown = _placingHintShown;
    _placingHint = null;
    _placingHintShown = false;
    if (hint != null && shown) hint.close();
  }

  void _stopPlacingLink() {
    _closePlacingHint();
    if (_placingLink) setState(() => _placingLink = false);
  }

  Future<void> _placeLink(EditorPage page, Offset point) async {
    _stopPlacingLink();
    await _addLink(page, point & Size.zero);
  }

  /// Asks where a link over [area] of [page] goes, then adds it. False when
  /// the dialog was cancelled or the note changed meanwhile.
  Future<bool> _addLink(EditorPage page, Rect area) async {
    final note = coreInfo;
    final index = note.pages.indexOf(page);
    if (note.readOnly || inkLocked.value || index < 0) return false;
    final target = await showPageLinkDialog(
      context,
      pages: _linkablePages(),
      listNotes: widget.chrome?.listNotes,
      current: index + 1,
    );
    if (target == null ||
        target.isEmpty ||
        !mounted ||
        !identical(coreInfo, note)) {
      return false;
    }
    return _changeLink(
      page,
      added: PageLink(id: newId(), rect: area, target: target),
    );
  }

  Future<void> _editLink(EditorPage page, PageLink link) async {
    final note = coreInfo;
    final index = note.pages.indexOf(page);
    if (note.readOnly || inkLocked.value || index < 0) return;
    final target = await showPageLinkDialog(
      context,
      pages: _linkablePages(),
      listNotes: widget.chrome?.listNotes,
      initial: link.target,
      current: index + 1,
    );
    if (target == null || !mounted || !identical(coreInfo, note)) return;
    if (target.isEmpty) {
      _changeLink(page, removed: link);
    } else if (target != link.target) {
      _changeLink(
        page,
        removed: link,
        added: PageLink(id: link.id, rect: link.rect, target: target),
      );
    }
  }

  /// Adds [added], removes [removed], or with both edits a link, as one undo
  /// step. False when [page] has left the note or the note is read-only.
  bool _changeLink(EditorPage page, {PageLink? added, PageLink? removed}) {
    final pageIndex = coreInfo.pages.indexOf(page);
    if (pageIndex < 0 || _noteLocked) return false;
    setState(() {
      _replaceLink(page, remove: removed, put: added);
      history.recordChange(
        EditorHistoryItem(
          type: added != null ? .addLink : .removeLink,
          pageIndex: pageIndex,
          strokes: const [],
          images: const [],
          page: page,
          link: added ?? removed,
          replacedLink: added != null ? removed : null,
        ),
      );
      // The last change is no longer a stroke that a pinch may take back.
      inkInput.lastDrawRecorded = false;
    });
    autosaveAfterDelay();
    return true;
  }

  /// The page of a link change: the same page wherever it is now, or, when
  /// that empty page was tidied away and made again (removeExcessPages, then
  /// createPage), the page in its place, as strokes come back by index.
  EditorPage _linkPageOf(EditorHistoryItem item) {
    final page = item.page!;
    if (coreInfo.pages.contains(page)) return page;
    if (item.pageIndex >= coreInfo.pages.length) createPage(item.pageIndex);
    return coreInfo.pages[item.pageIndex];
  }

  /// Takes [remove] off [page] and puts [put] in its place (or last).
  static void _replaceLink(
    EditorPage page, {
    PageLink? remove,
    PageLink? put,
  }) {
    final links = page.links;
    final index = remove == null
        ? -1
        : links.indexWhere((link) => link.id == remove.id);
    if (index >= 0) links.removeAt(index);
    if (put != null) links.insert(index < 0 ? links.length : index, put);
  }

  Future<void> _onLinkAction(
    EditorPage page,
    PageLink link,
    PageLinkAction action,
  ) async {
    switch (action) {
      case .open:
        await _followLink(link);
      case .edit:
        await _editLink(page, link);
      case .copy:
        await Clipboard.setData(ClipboardData(text: link.target));
        _linkMessage('링크를 복사했습니다');
      case .delete:
        _changeLink(page, removed: link);
    }
  }

  /// A page of this note opens here; other notes and web addresses through
  /// the host (the workspace's link opener). Without a host the editor opens
  /// web addresses itself.
  Future<void> _followLink(PageLink link) async {
    final open = widget.chrome?.openLink;
    try {
      switch (PageLink.kindOf(link.target)) {
        case PageLinkKind.page:
          if (!revealPageId(link.pageId!)) _linkMessage('링크한 페이지가 없습니다');
        case PageLinkKind.note:
          if (open == null) {
            _linkMessage('이 화면에서는 다른 노트를 열 수 없습니다');
          } else {
            await open(link.target);
          }
        case PageLinkKind.web:
          if (open != null) {
            await open(link.target);
          } else if (!await launchUrl(
            Uri.parse(link.target),
            mode: LaunchMode.externalApplication,
          )) {
            _linkMessage('링크를 열 수 없습니다');
          }
        case null:
          _linkMessage('링크를 열 수 없습니다');
      }
    } catch (error) {
      _linkMessage('링크를 열 수 없습니다: $error');
    }
  }

  void _linkMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// The index of the page that is currently centered on screen.
  int get currentPageIndex {
    if (!mounted) return _lastCurrentPageIndex;

    final canvas = _canvasGestureDetectorKey.currentState;
    final selectedIndex = canvas?.singlePageIndex;
    if (selectedIndex != null) return _lastCurrentPageIndex = selectedIndex;

    final bounds = canvas?.containerBounds;
    final screenWidth = bounds?.hasBoundedWidth == true
        ? bounds!.maxWidth
        : MediaQuery.sizeOf(context).width;
    final canvasHeight = bounds?.hasBoundedHeight == true
        ? bounds!.maxHeight
        : 0;
    final center = _transformationController.toScene(
      Offset(screenWidth / 2, canvasHeight / 2),
    );

    return _lastCurrentPageIndex = getPageIndexFromScrollPosition(
      scrollY: center.dy,
      screenWidth: screenWidth,
      pages: coreInfo.pages,
    );
  }

  @visibleForTesting
  static int getPageIndexFromScrollPosition({
    required double scrollY,
    required double screenWidth,
    required List<EditorPage> pages,
  }) => CanvasGestureDetector.getPageIndex(
    scrollY: scrollY,
    pages: pages,
    screenWidth: screenWidth,
  );

  @override
  void dispose() {
    _editorDisposed = true;
    unawaited(_cleanUpAsync());

    DynamicMaterialApp.removeFullscreenListener(_setState);
    stows.editorFingerDrawing.removeListener(_setState);
    stows.editorGestureMode.removeListener(_gestureModeChanged);
    savingState.removeListener(_publishActions);
    _ink.toolState.dispose();
    _history.removeListener(_publishActions);
    // Only this editor's: a new editor in the same host may hold them now.
    widget.chrome?.actions.withdraw(this);
    widget.chrome?.detach(this);
    _ownRegistry?.dispose();
    _editorFocus.dispose();
    _floatingBarOpen.dispose();
    _floatingBarFrom.dispose();
    _strokeAt.dispose();
    _hoverBadge.dispose();
    _noteSheetOpen.dispose();
    _customizing.dispose();
    _side.dispose();
    inkLocked.dispose();
    // Leaving the note leaves full screen (the old toolbar did this).
    DynamicMaterialApp.setFullscreen(false, updateSystem: true);
    // The hint lives in the app's messenger, which outlives the editor.
    _closePlacingHint();

    _delayedSaveTimer?.cancel();
    _watchServerTimer?.cancel();
    inkInput.dispose();

    // manually save pen properties since the listeners don't fire if a property is changed
    stows.lastFountainPenOptions.notifyListeners();
    stows.lastBallpointPenOptions.notifyListeners();
    stows.lastHighlighterOptions.notifyListeners();
    stows.lastPencilOptions.notifyListeners();
    stows.lastShapePenOptions.notifyListeners();

    super.dispose();
  }

  Future<void> _cleanUpAsync() async {
    try {
      if (_renameTimer?.isActive ?? false) {
        _renameTimer!.cancel();
        await _renameFileNow();
        filenameTextEditingController.dispose();
      }
      await _initializing;
      await _snapshotSave;
      if (widget.onSaveSnapshot == null) await saveToFile();
    } finally {
      coreInfo.dispose();
    }
  }
}

/// ⋯ 「쪽으로 이동」: the number of the page to go to, 1 to [pages].
class _GoToPageDialog extends StatefulWidget {
  const new({required this.pages, required this.current});

  final int pages;
  final int current;

  @override
  State<_GoToPageDialog> createState() => _GoToPageDialogState();
}

class _GoToPageDialogState extends State<_GoToPageDialog> {
  final _field = TextEditingController();

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _go() {
    final page = int.tryParse(_field.text.trim());
    if (page == null || page < 1 || page > widget.pages) return;
    Navigator.pop(context, page);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('쪽으로 이동'),
    content: TextField(
      key: const ValueKey('go-to-page-field'),
      controller: _field,
      autofocus: true,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      decoration: InputDecoration(
        hintText: '${widget.current}',
        suffixText: '/ ${widget.pages}',
      ),
      onSubmitted: (_) => _go(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      TextButton(onPressed: _go, child: const Text('이동')),
    ],
  );
}
