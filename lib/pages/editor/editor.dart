import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:collapsible/collapsible.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' as flutter_quill;
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:keybinder/keybinder.dart';
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
import 'package:saber/components/theming/adaptive_alert_dialog.dart';
import 'package:saber/components/theming/adaptive_icon.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/components/theming/saber_theme.dart';
import 'package:saber/components/toolbar/color_bar.dart';
import 'package:saber/components/toolbar/editor_bottom_sheet.dart';
import 'package:saber/components/toolbar/editor_page_manager.dart';
import 'package:saber/components/toolbar/export_dialog.dart';
import 'package:saber/components/toolbar/note_function_row.dart';
import 'package:saber/components/toolbar/other_settings_panel.dart';
import 'package:saber/components/toolbar/shortcut_bar_editor.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
import 'package:saber/components/toolbar/toolbar.dart';
import 'package:saber/components/toolbar/toolbar_custom_dialog.dart';
import 'package:saber/components/toolbar/toolbar_dock.dart';
import 'package:saber/components/toolbar/toolbar_layout.dart';
import 'package:saber/components/toolbar/toolbar_settings_sheet.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_exporter.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:saber/data/extensions/change_notifier_extensions.dart';
import 'package:saber/data/extensions/matrix4_extensions.dart';
import 'package:saber/data/file_manager/file_manager.dart';
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
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor_chrome.dart';
import 'package:saber/pages/editor/link_dialog.dart';
import 'package:saber/pages/home/whiteboard.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/change.dart';
import 'package:stow_plain/stow_plain.dart';
import 'package:url_launcher/url_launcher.dart';

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

class EditorState extends State<Editor> {
  final log = Logger('EditorState');

  late var coreInfo = EditorCoreInfo.placeholder;

  final _canvasGestureDetectorKey = GlobalKey<CanvasGestureDetectorState>();
  final _transformationController = TransformationController();
  var _singlePageMode = false;

  var history = EditorHistory();

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
  Tool get currentTool => _currentTool;
  set currentTool(Tool tool) {
    _currentTool = tool;
    if (tool is! Eraser) _lastNonEraserTool = tool;
    stows.lastTool.value = tool.toolId;
    _rememberPenFamily(tool);
  }

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

  // used to prevent accidentally drawing when pinch zooming
  var lastSeenPointerCount = 0;
  Timer? _lastSeenPointerCountTimer;

  ValueNotifier<QuillStruct?> quillFocus = ValueNotifier(null);

  /// The last non-Eraser [currentTool] value.
  late Tool _lastNonEraserTool = Pen.currentPenFamily;

  /// If the stylus button is pressed, or was pressed, during the current draw gesture.
  ///
  /// For now, this also includes when an [PointerDeviceKind.inverseStylus] is
  /// used since the stylus rear-end and stylus button currently act the same.
  /// If we add customized button bindings, we may have to separate this again.
  var stylusButtonWasPressed = false;

  @override
  void initState() {
    DynamicMaterialApp.addFullscreenListener(_setState);

    _initializing = _initAsync();
    _assignKeybindings();

    super.initState();
    widget.chrome?.attach(this);
  }

  @override
  void didUpdateWidget(Editor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.chrome, widget.chrome)) {
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

  Keybinding? _ctrlZ, _ctrlY, _ctrlShiftZ;
  void _assignKeybindings() {
    _ctrlZ = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyZ),
    ], inclusive: true);
    _ctrlY = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.keyY),
    ], inclusive: true);
    _ctrlShiftZ = Keybinding([
      KeyCode.ctrl,
      KeyCode.shift,
      KeyCode.from(LogicalKeyboardKey.keyZ),
    ], inclusive: true);
    Keybinder.bind(_ctrlZ!, undo);
    Keybinder.bind(_ctrlY!, redo);
    Keybinder.bind(_ctrlShiftZ!, redo);
  }

  void _removeKeybindings() {
    if (_ctrlZ != null) Keybinder.remove(_ctrlZ!);
    if (_ctrlY != null) Keybinder.remove(_ctrlY!);
    if (_ctrlShiftZ != null) Keybinder.remove(_ctrlShiftZ!);
  }

  /// Creates pages until the given page index exists,
  /// plus an extra blank page
  void createPage(int pageIndex, {String? firstPageId}) {
    while (pageIndex >= coreInfo.pages.length - 1) {
      final page = EditorPage(pageId: firstPageId);
      firstPageId = null;
      coreInfo.pages.add(page);
      listenToQuillChanges(page.quill);
    }
  }

  void removeExcessPages() {
    bool removedAPage = false;

    // remove excess pages if all pages >= this one are empty
    for (int i = coreInfo.pages.length - 1; i >= 1; --i) {
      final thisPage = coreInfo.pages[i];
      final prevPage = coreInfo.pages[i - 1];
      // Links are not content (isEmpty), but a page carrying one is kept:
      // removing it here would lose the link without an undo step.
      if (thisPage.isEmpty && thisPage.links.isEmpty && prevPage.isEmpty) {
        final page = coreInfo.pages.removeAt(i);
        page.dispose();
        removedAPage = true;
      } else {
        break;
      }
    }

    if (removedAPage) {
      // scroll to the last page (only if we're below the last page)
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
  }

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
          // remove the page at the given index
          coreInfo.pages.removeAt(item.pageIndex);

          // fix the page indices of all pages after this one
          for (int i = item.pageIndex; i < coreInfo.pages.length; ++i) {
            final page = coreInfo.pages[i];
            page.updatePageIndex(i);
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
          coreInfo.backgroundPattern = item.backgroundPatternChange!.previous;

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
    }
  }

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

  /// The position of the previous draw gesture event.
  /// Used to move a selection.
  Offset previousPosition = .zero;

  /// The total offset of the current move gesture.
  /// Used to record a move in the history.
  Offset moveOffset = .zero;

  var isHovering = true;
  int? dragPageIndex;

  /// Whether the last pen or eraser gesture added a history item.
  var _lastDrawRecorded = false;
  PointerDeviceKind? currentPointerKind;
  double? currentPressure;
  bool isDrawGesture(ScaleStartDetails details) {
    if (coreInfo.readOnly ||
        _initialImportPending ||
        _loadingSnapshot ||
        _placingLink)
      return false;

    CanvasImage.activeListener
        .notifyListenersPlease(); // un-select active image

    final acceptedStylus =
        details.pointerCount == 1 &&
        (details.kind == PointerDeviceKind.stylus ||
            details.kind == PointerDeviceKind.invertedStylus);
    _lastSeenPointerCountTimer?.cancel();
    if (acceptedStylus) {
      // The touch debounce must not delay a pen or undo its completed stroke.
      lastSeenPointerCount = 0;
    } else if (lastSeenPointerCount >= 2) {
      // was a zoom gesture, ignore
      return false;
    } else if (details.pointerCount >= 2) {
      // is a zoom gesture, remove accidental stroke
      // Only the first finger's own change: a stroke or erase that changed
      // nothing left no history, and the item before it is the user's.
      if (lastSeenPointerCount == 1 &&
          _lastDrawRecorded &&
          stows.editorFingerDrawing.value &&
          (currentTool is Pen || currentTool is Eraser)) {
        _lastDrawRecorded = false;
        final item = history.removeAccidentalStroke();
        if (item != null) undo(item);
      }
      lastSeenPointerCount = details.pointerCount;
      return false;
    } else {
      // is a stroke
      lastSeenPointerCount = details.pointerCount;
    }

    dragPageIndex = onWhichPageIsFocalPoint(details.focalPoint);
    if (dragPageIndex == null) return false;

    if (currentTool == Tool.textEditing) {
      return false;
    } else if (acceptedStylus ||
        stows.editorFingerDrawing.value ||
        currentPointerKind == PointerDeviceKind.stylus ||
        currentPointerKind == PointerDeviceKind.invertedStylus ||
        currentPressure != null) {
      return true;
    } else {
      log.fine('Non-stylus found, rejected stroke');
      return false;
    }
  }

  void onDrawStart(ScaleStartDetails details) {
    _drawing = true;
    _editGeneration++;
    _reportBusy();
    widget.onDirtyChanged?.call(true);
    final page = coreInfo.pages[dragPageIndex!];
    final position = page.renderBox!.globalToLocal(details.focalPoint);
    history.canRedo = false;

    if (currentTool is Pen) {
      (currentTool as Pen).onDragStart(
        position,
        page,
        dragPageIndex!,
        currentPressure,
        // The page's zoom and fit on screen, so the stabiliser smooths the
        // same on screen however far the page is zoomed.
        screenScale: page.renderBox!.getTransformTo(null).getMaxScaleOnAxis(),
      );
    } else if (currentTool is Eraser) {
      final eraser = currentTool as Eraser;
      if (stows.eraserMode.value == EraserMode.lasso) {
        // Nothing is erased until the loop is closed (onDrawEnd).
        eraser.startLasso(position, dragPageIndex!);
      } else {
        // Empty pages are tidied in onDrawEnd: removing the page under the
        // eraser here would leave the drag on a page that is gone.
        for (final stroke in eraser.checkForOverlappingStrokes(
          position,
          page.strokes,
        )) {
          page.strokes.remove(stroke);
        }
      }
    } else if (currentTool is Select) {
      final select = currentTool as Select;
      if (select.doneSelecting &&
          select.selectResult.pageIndex == dragPageIndex! &&
          select.selectResult.path.contains(position)) {
        // drag selection in onDrawUpdate
      } else {
        select.onDragStart(position, dragPageIndex!);
        history.canRedo = true; // selection doesn't affect history
      }
    } else if (currentTool is LaserPointer) {
      (currentTool as LaserPointer).onDragStart(position, page, dragPageIndex!);
    }

    previousPosition = position;
    moveOffset = .zero;

    if (currentTool is! Select) {
      Select.currentSelect.unselect();
    }

    // setState to let canvas know about currentStroke
    setState(() {});
  }

  void onDrawUpdate(ScaleUpdateDetails details) {
    final page = coreInfo.pages[dragPageIndex!];
    final position = page.renderBox!.globalToLocal(details.focalPoint);
    final offset = position - previousPosition;

    if (currentTool is Pen) {
      (currentTool as Pen).onDragUpdate(position, currentPressure);
      page.redrawStrokes();
    } else if (currentTool is Eraser) {
      final eraser = currentTool as Eraser;
      if (eraser.lassoPath != null) {
        eraser.extendLasso(position);
        page.redrawStrokes();
      } else {
        for (final stroke in eraser.checkForOverlappingStrokes(
          position,
          page.strokes,
        )) {
          page.strokes.remove(stroke);
        }
        page.redrawStrokes();
      }
    } else if (currentTool is Select) {
      final select = currentTool as Select;
      if (select.doneSelecting) {
        for (final stroke in select.selectResult.strokes) {
          stroke.shift(offset);
        }
        for (final image in select.selectResult.images) {
          image.dstRect = image.dstRect.shift(offset);
        }
        select.selectResult.path = select.selectResult.path.shift(offset);
      } else {
        select.onDragUpdate(position);
      }
      page.redrawStrokes();
    } else if (currentTool is LaserPointer) {
      (currentTool as LaserPointer).onDragUpdate(position);
      page.redrawStrokes();
    }
    previousPosition = position;
    moveOffset += offset;
  }

  void onDrawEnd(ScaleEndDetails details) {
    final page = coreInfo.pages[dragPageIndex!];
    bool shouldSave = true;
    _lastDrawRecorded = false;
    setState(() {
      if (currentTool is Pen) {
        final newStroke = (currentTool as Pen).onDragEnd();
        if (newStroke == null) return;
        if (newStroke.isEmpty) return;

        if (stows.autoStraightenLines.value &&
            currentTool is! ShapePen &&
            newStroke.isStraightLine()) {
          newStroke.convertToLine();
        }

        createPage(newStroke.pageIndex);
        page.insertStroke(newStroke);
        history.recordChange(
          EditorHistoryItem(
            type: .draw,
            pageIndex: dragPageIndex!,
            strokes: [newStroke],
            images: [],
          ),
        );
        _lastDrawRecorded = true;
      } else if (currentTool is Eraser) {
        final eraser = currentTool as Eraser;
        if (eraser.lassoPath != null) {
          if (details.pointerCount > 0) {
            // Another finger landed (a pinch), so the gesture ended with the
            // loop unfinished: drop it rather than erase half a loop.
            eraser.cancelLasso();
          } else {
            // The pen was lifted: erase what the loop holds, in one undo step.
            final inside = eraser.finishLasso(page.strokes);
            for (final stroke in inside) {
              page.strokes.remove(stroke);
            }
            if (inside.isNotEmpty) page.redrawStrokes();
          }
        }
        final erased = eraser.onDragEnd();
        // Only once the eraser is lifted, never under it.
        if (erased.isNotEmpty) removeExcessPages();
        if (stylusButtonWasPressed || stows.disableEraserAfterUse.value) {
          // restore previous tool
          stylusButtonWasPressed = false;
          currentTool = _lastNonEraserTool;
        }
        if (erased.isEmpty) return;
        history.recordChange(
          EditorHistoryItem(
            type: .erase,
            pageIndex: dragPageIndex!,
            strokes: erased,
            images: [],
          ),
        );
        _lastDrawRecorded = true;
      } else if (currentTool is Select) {
        if (moveOffset == .zero) return;
        final select = currentTool as Select;
        if (select.doneSelecting) {
          history.recordChange(
            EditorHistoryItem(
              type: .move,
              pageIndex: dragPageIndex!,
              strokes: select.selectResult.strokes,
              images: select.selectResult.images,
              offset: .fromLTRB(
                moveOffset.dx,
                moveOffset.dy,
                moveOffset.dx,
                moveOffset.dy,
              ),
            ),
          );
        } else {
          shouldSave = false;
          select.onDragEnd(page.strokes, page.images);

          if (select.selectResult.isEmpty) {
            Select.currentSelect.unselect();
          }
        }
      } else if (currentTool is LaserPointer) {
        shouldSave = false;
        final newStroke = (currentTool as LaserPointer).onDragEnd(
          page.redrawStrokes,
          (Stroke stroke) {
            page.laserStrokes.remove(stroke);
          },
        );
        if (newStroke != null) page.laserStrokes.add(newStroke);
      }
    });

    _drawing = false;
    if (shouldSave) autosaveAfterDelay();
    widget.onDirtyChanged?.call(
      !history.isCurrentStateSaved || _initialImportPending,
    );
    _reportBusy();
  }

  void onInteractionEnd(ScaleEndDetails details) {
    // reset after 1ms to keep track of the same gesture only
    _lastSeenPointerCountTimer?.cancel();
    _lastSeenPointerCountTimer = Timer(const Duration(milliseconds: 10), () {
      lastSeenPointerCount = 0;
    });
  }

  void updatePointerData(PointerDeviceKind kind, double? pressure) {
    currentPointerKind = kind;
    currentPressure = pressure;
  }

  void onHovering() {
    isHovering = true;
  }

  void onHoveringEnd() {
    isHovering = false;
  }

  void onStylusButtonChanged(bool buttonIsPressed) {
    stylusButtonWasPressed |= buttonIsPressed;

    if (!isHovering) return;
    if (buttonIsPressed) {
      // button pressed while hovering, switch to Eraser
      if (currentTool is! Eraser) {
        currentTool = Eraser();
      }
    } else {
      // button was released while hovering, switch back to non-Eraser
      if (currentTool is Eraser) {
        currentTool = _lastNonEraserTool;
      }
    }

    if (mounted) setState(() {});
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
        savingState.value = .waitingToSave;
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
      savingState.value = .waitingToSave;
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
    if (stows.recentColorsDontSavePresets.value) {
      if (ColorBar.colorPresets.any(
        (colorPreset) => colorPreset.color == color,
      )) {
        return;
      }
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
  Future<int> _pickPhotos([List<_PhotoInfo>? photoInfos]) async {
    if (coreInfo.readOnly) return 0;

    final currentPageIndex = this.currentPageIndex;

    photoInfos ??= await _pickPhotosWithFilePicker();
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
      ),
    );
    createPage(currentPageIndex);
    coreInfo.pages[currentPageIndex].images.addAll(images);
    autosaveAfterDelay();

    return images.length;
  }

  Future<List<_PhotoInfo>> _pickPhotosWithFilePicker() async {
    final List<PlatformFile> files = await FilePicker.pickFiles(
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
  Future<bool> importPdf() async {
    if (coreInfo.readOnly) return false;
    if (!Editor.canRasterPdf) return false;

    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );
    if (file == null) return false;

    return importPdfFromFilePath(file.path!);
  }

  Future<bool> importPdfFromFilePath(
    String path, {
    String Function(int)? baselinePageId,
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

    final emptyPage = note.pages.removeLast();
    assert(emptyPage.isEmpty);
    for (final (pdfPage, pageSize) in pages) {
      final page = EditorPage(
        pageId: baselinePageId?.call(pdfPage.pageNumber - 1),
        size: pageSize,
        backgroundImage: PdfEditorImage(
          id: note.nextImageId++,
          pdfBytes: null,
          pdfFile: File(path),
          pdfPage: pdfPage.pageNumber - 1,
          pageIndex: note.pages.length,
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
      note.pages.add(page);
      if (baselinePageId == null) {
        // TODO(adil192): Group multiple pages into one atomic change
        history.recordChange(
          EditorHistoryItem(
            type: .insertPage,
            pageIndex: note.pages.length - 1,
            strokes: const [],
            images: const [],
            page: page,
          ),
        );
      } else {
        listenToQuillChanges(page.quill);
      }
    }

    note.pages.add(emptyPage);
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
  /// or dots when [background] is off. PDF pages and pictures stay.
  EditorCoreInfo _exportInfo(bool background) => background
      ? coreInfo
      : coreInfo.copyWith(backgroundPattern: CanvasBackgroundPattern.none);

  Future<void> exportAsPdf(
    BuildContext context, {
    String? name,
    bool background = true,
  }) async {
    final pdf = await EditorExporter.generatePdf(
      _exportInfo(background),
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
        coreInfo: _exportInfo(background),
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
    final platform = Theme.of(context).platform;
    final toolbarAlignment = _alignmentStow.value;
    _reportChrome();
    final isToolbarVertical =
        toolbarAlignment == AxisDirection.left ||
        toolbarAlignment == AxisDirection.right;

    final Widget canvas = CanvasGestureDetector(
      key: _canvasGestureDetectorKey,
      filePath: coreInfo.filePath,
      isDrawGesture: isDrawGesture,
      onInteractionEnd: onInteractionEnd,
      onDrawStart: onDrawStart,
      onDrawUpdate: onDrawUpdate,
      onDrawEnd: onDrawEnd,
      onHovering: onHovering,
      onHoveringEnd: onHoveringEnd,
      onStylusButtonChanged: onStylusButtonChanged,
      updatePointerData: updatePointerData,
      undo: undo,
      redo: redo,
      pages: coreInfo.pages,
      initialPageIndex: coreInfo.initialPageIndex,
      initialSinglePageMode: _singlePageMode,
      pageBuilder: pageBuilder,
      isTextEditing: () => currentTool == Tool.textEditing,
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

    final Widget toolbar = Collapsible(
      axis: isToolbarVertical
          ? CollapsibleAxis.horizontal
          : CollapsibleAxis.vertical,
      collapsed:
          coreInfo.readOnly ||
          DynamicMaterialApp.isFullscreen &&
              !stows.editorToolbarShowInFullscreen.value,
      maintainState: true,
      child: SafeArea(
        bottom: toolbarAlignment != AxisDirection.up,
        child: Toolbar(
          alignment: toolbarAlignment,
          readOnly: coreInfo.readOnly,
          setTool: (tool) {
            if (tool is Eraser && currentTool is Eraser) {
              // setTool(Eraser) is a special case to toggle the eraser on/off
              tool = _lastNonEraserTool;
            }

            currentTool = tool;

            if (tool is Highlighter) {
              Highlighter.currentHighlighter = tool;
            } else if (tool is Pencil) {
              Pencil.currentPencil = tool;
            } else if (tool is Pen) {
              Pen.currentPen = tool;
            }

            if (mounted) setState(() {});
          },
          currentTool: currentTool,
          duplicateSelection: () {
            final select = currentTool as Select;
            if (!select.doneSelecting) return;

            setState(() {
              final page = coreInfo.pages[select.selectResult.pageIndex];
              final strokes = select.selectResult.strokes;
              final images = select.selectResult.images;

              const duplicationFeedbackOffset = Offset(25, -25);

              final duplicatedStrokes = strokes.map((stroke) {
                return stroke.copy()..shift(duplicationFeedbackOffset);
              }).toList();

              final duplicatedImages = images.map((image) {
                return image.copy()
                  ..id = coreInfo.nextImageId++
                  ..dstRect.shift(duplicationFeedbackOffset);
              }).toList();

              page.strokes.addAll(duplicatedStrokes);
              page.images.addAll(duplicatedImages);

              select.selectResult = select.selectResult.copyWith(
                strokes: duplicatedStrokes,
                images: duplicatedImages,
                path: select.selectResult.path.shift(duplicationFeedbackOffset),
              );

              history.recordChange(
                EditorHistoryItem(
                  type: .draw,
                  pageIndex: select.selectResult.pageIndex,
                  strokes: duplicatedStrokes,
                  images: duplicatedImages,
                ),
              );
              autosaveAfterDelay();
            });
          },
          deleteSelection: () {
            final select = currentTool as Select;
            if (!select.doneSelecting) {
              return;
            }

            setState(() {
              final page = coreInfo.pages[select.selectResult.pageIndex];
              final strokes = select.selectResult.strokes;
              final images = select.selectResult.images;

              for (final stroke in strokes) {
                page.strokes.remove(stroke);
              }
              for (final image in images) {
                page.images.remove(image);
              }

              select.unselect();

              history.recordChange(
                EditorHistoryItem(
                  type: .erase,
                  pageIndex: strokes.first.pageIndex,
                  strokes: strokes,
                  images: images,
                ),
              );
              autosaveAfterDelay();
            });
          },
          linkSelection: () => unawaited(_linkSelection()),
          setColor: (color) {
            setState(() {
              updateColorBar(color);

              // setColor also keeps the colour for the next pen of that kind.
              if (currentTool is Highlighter) {
                (currentTool as Highlighter).setColor(
                  color.withAlpha(Highlighter.alpha),
                );
              } else if (currentTool is Pen) {
                (currentTool as Pen).setColor(color);
              } else if (currentTool is Select) {
                // Changes color of selected strokes
                final select = currentTool as Select;
                if (select.doneSelecting) {
                  final strokes = select.selectResult.strokes;

                  final colorChange = <Stroke, Change<Color>>{};
                  for (final stroke in strokes) {
                    colorChange[stroke] = Change(
                      previous: stroke.color,
                      current: color,
                    );
                    stroke.color = color;
                  }

                  history.recordChange(
                    EditorHistoryItem(
                      type: .changeColor,
                      pageIndex: strokes.first.pageIndex,
                      strokes: strokes,
                      colorChange: colorChange,
                      images: [],
                    ),
                  );
                  autosaveAfterDelay();
                }
              }
            });
          },
          quillFocus: quillFocus,
          textEditing: currentTool == Tool.textEditing,
          toggleTextEditing: () => setState(() {
            if (currentTool == Tool.textEditing) {
              // Back to the pen button's pen, the pencil if it was chosen.
              currentTool = Pen.currentPenFamily;
              for (final page in coreInfo.pages) {
                // unselect text, but maintain cursor position
                page.quill.controller.moveCursorToPosition(
                  page.quill.controller.selection.extentOffset,
                );
                page.quill.focusNode.unfocus();
              }
            } else {
              currentTool = Tool.textEditing;
              quillFocus.value = coreInfo.pages[currentPageIndex].quill
                ..focusNode.requestFocus();
            }
          }),
          undo: undo,
          isUndoPossible: history.canUndo,
          redo: redo,
          isRedoPossible: history.canRedo,
          toggleFingerDrawing: _toggleFingerDrawing,
          pickPhoto: _pickPhotos,
          paste: paste,
          exportAsSba: exportAsSba,
          exportAsPdf: exportAsPdf,
          exportAsPng: exportAsPng,
          exportTitle: widget.customTitle ?? coreInfo.fileName,
          leading: [
            ToolbarDockHandle(
              axis: isToolbarVertical ? Axis.vertical : Axis.horizontal,
            ),
          ],
        ),
      ),
    );

    final Widget body = ToolbarDock(
      alignment: toolbarAlignment,
      onAlignmentChanged: _setToolbarAlignment,
      toolbar: toolbar,
      child: Column(
        children: [
          Expanded(child: canvas),
          readonlyBanner,
        ],
      ),
    );

    return ValueListenableBuilder(
      valueListenable: savingState,
      builder: (context, savingState, child) {
        // don't allow user to go back until saving is done
        return PopScope(
          canPop: widget.onBack != null || savingState == .saved,
          onPopInvokedWithResult: (didPop, _) {
            if (widget.onBack != null) return;
            switch (savingState) {
              case .waitingToSave:
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
                // 기타 설정 opens from the function row, not from a button the end drawer would add here.
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
        // StarNote's "기타 설정" panel, when no host draws it.
        endDrawer: widget.chrome != null
            ? null
            : Drawer(
                width: 280,
                child: OtherSettingsPanel(
                  sections: otherSettingsSections(
                    close: () => _scaffoldKey.currentState?.closeEndDrawer(),
                  ),
                ),
              ),
        body: Column(
          children: [
            if (widget.chrome == null && !DynamicMaterialApp.isFullscreen)
              _ownFunctionRow(),
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
  }

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int? _chromeSignature;

  /// Workspace notes keep their own toolbar position (top by default);
  /// Saber's preference only moves the standalone editor's toolbar.
  PlainStow<AxisDirection> get _alignmentStow => widget.onSaveSnapshot == null
      ? stows.editorToolbarAlignment
      : stows.workspaceToolbarAlignment;

  void _setToolbarAlignment(AxisDirection alignment) =>
      setState(() => _alignmentStow.value = alignment);

  /// The note is loaded and its PDF import saved. The function row stays on
  /// screen while the body shows the import's spinner, so its page actions
  /// wait for this.
  bool get _noteReady => !_loadingSnapshot && !_initialImportPending;

  bool get _showPageActions => !coreInfo.readOnly && _noteReady;

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
      _initialImportPending,
      DynamicMaterialApp.isFullscreen,
      stows.editorFingerDrawing.value,
      _alignmentStow.value,
      _placingLink,
    );
    if (signature == _chromeSignature) return;
    _chromeSignature = signature;
    chrome.changed();
  }

  void _toggleFingerDrawing() {
    stows.editorFingerDrawing.value = !stows.editorFingerDrawing.value;
    lastSeenPointerCount = 0;
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

  void _insertPageAfterCurrent() => setState(() {
    final currentPageIndex = this.currentPageIndex;
    insertPageAfter(currentPageIndex);
    _scrollToPage(currentPageIndex + 1);
  });

  /// StarNote's "문서 개요": the page thumbnails (the former 쪽 관리).
  void _openOverview() => unawaited(
    showDialog<void>(
      context: context,
      builder: (context) => AdaptiveAlertDialog(
        title: const Text('문서 개요'),
        content: pageManager(context),
        actions: const [],
      ),
    ),
  );

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

  void _openOtherSettings() {
    final open = widget.chrome?.openOtherSettings;
    if (open != null) return open();
    _scaffoldKey.currentState?.openEndDrawer();
  }

  /// The editor's shortcuts for the note's function row (StarNote's shortcut
  /// bar): the page actions and the screen toggles that were in the toolbar.
  List<NoteShortcut> chromeShortcuts() {
    final fullscreen = DynamicMaterialApp.isFullscreen;
    return [
      NoteShortcut(
        id: 'insertPage',
        label: '페이지 추가',
        icon: const AdaptiveIcon(
          icon: Icons.insert_page_break,
          cupertinoIcon: CupertinoIcons.add,
        ),
        onPressed: _showPageActions ? _insertPageAfterCurrent : null,
      ),
      NoteShortcut(
        id: 'pageMode',
        label: _singlePageMode ? '연속 스크롤' : '한 쪽씩 보기',
        icon: Icon(
          _singlePageMode
              ? Icons.view_agenda_outlined
              : Icons.description_outlined,
        ),
        buttonKey: const ValueKey('editor-single-page-toggle'),
        onPressed: _showPageMode ? _togglePageMode : null,
      ),
      if (!stows.hideFingerDrawingToggle.value)
        NoteShortcut(
          id: 'finger',
          label: '손가락 필기',
          icon: const Icon(CupertinoIcons.hand_draw),
          selected: stows.editorFingerDrawing.value,
          onPressed: coreInfo.readOnly ? null : _toggleFingerDrawing,
        ),
      NoteShortcut(
        id: 'fullscreen',
        label: '전체 화면',
        icon: AdaptiveIcon(
          icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
          cupertinoIcon: fullscreen
              ? CupertinoIcons.fullscreen_exit
              : CupertinoIcons.fullscreen,
        ),
        selected: fullscreen,
        onPressed: () =>
            DynamicMaterialApp.setFullscreen(!fullscreen, updateSystem: true),
      ),
      NoteShortcut(
        id: 'export',
        label: '파일 내보내기',
        icon: const AdaptiveIcon(
          icon: Icons.share,
          cupertinoIcon: CupertinoIcons.share,
        ),
        onPressed: _showPageActions ? _openExportDialog : null,
      ),
      NoteShortcut(
        id: 'linkAdd',
        label: '링크 추가',
        icon: const Icon(Icons.add_link),
        buttonKey: const ValueKey('editor-link-add'),
        selected: _placingLink,
        onPressed: _showPageActions ? _linkAdd : null,
      ),
    ];
  }

  /// StarNote's two shortcuts at the bar's right end.
  List<NoteShortcut> chromeFixed() => [
    NoteShortcut(
      id: 'overview',
      label: '문서 개요',
      icon: const Icon(Icons.grid_view),
      buttonKey: const ValueKey('note-overview'),
      onPressed: _showPageActions ? _openOverview : null,
    ),
    NoteShortcut(
      id: 'otherSettings',
      label: '기타 설정',
      icon: const Icon(Icons.tune),
      buttonKey: const ValueKey('note-other-settings'),
      onPressed: _noteReady ? _openOtherSettings : null,
    ),
  ];

  /// The editor's sections of StarNote's "기타 설정" panel. [close] closes the
  /// panel before a row opens something else.
  List<Widget> otherSettingsSections({required VoidCallback close}) {
    final pages = coreInfo.pages.length;
    void then(VoidCallback action) {
      close();
      action();
    }

    return [
      Padding(
        key: const ValueKey('other-settings-title'),
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          widget.customTitle ?? coreInfo.fileName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextTheme.of(context).titleSmall,
        ),
      ),
      OtherSettingsSection(
        title: '페이지 설정',
        trailing: pages == 0 ? null : '${currentPageIndex + 1} / $pages',
        children: [
          OtherSettingsNavRow(
            key: const ValueKey('other-settings-template'),
            label: '템플릿 변경',
            onTap: _showPageActions ? () => then(_openPageMenu) : null,
          ),
          _GoToPageRow(
            pages: pages,
            onGo: (page) => then(() => _scrollToPage(page - 1)),
          ),
          OtherSettingsNavRow(
            key: const ValueKey('other-settings-overview'),
            label: '문서 개요',
            onTap: _showPageActions ? () => then(_openOverview) : null,
          ),
        ],
      ),
      OtherSettingsSection(
        title: '문서 내보내기',
        children: [
          OtherSettingsNavRow(
            key: const ValueKey('other-settings-export-image'),
            label: '현재 페이지를 이미지로 내보내기',
            onTap: _showPageActions ? () => then(_openExportDialog) : null,
          ),
          OtherSettingsNavRow(
            key: const ValueKey('other-settings-export'),
            label: '파일 내보내기',
            onTap: _showPageActions ? () => then(_openExportDialog) : null,
          ),
        ],
      ),
      OtherSettingsSection(
        title: '일반 설정',
        children: [
          ToolbarPositionRow(
            alignment: _alignmentStow.value,
            onChanged: _setToolbarAlignment,
          ),
          SwitchListTile(
            key: const ValueKey('other-settings-continuous'),
            contentPadding: EdgeInsets.zero,
            title: const Text('연속 스크롤'),
            value: !_singlePageMode,
            onChanged: _showPageMode ? (_) => _togglePageMode() : null,
          ),
          OtherSettingsNavRow(
            key: const ValueKey('other-settings-toolbar-custom'),
            label: '사용자 지정 도구 모음',
            onTap: () => then(() {
              // The dialog rewrites pageToolbarLayout with the tools only; the
              // shortcut bar still follows its 228 switches until it has its own.
              final kept = keptShortcutLayout(
                stows.noteShortcutLayout.value,
                stows.pageToolbarLayout.value,
              );
              if (kept != null) stows.noteShortcutLayout.value = kept;
              unawaited(
                showToolbarCustomDialog(
                  context,
                  items: pageToolbarItems,
                  layout: stows.pageToolbarLayout,
                ),
              );
            }),
          ),
          OtherSettingsNavRow(
            key: const ValueKey('other-settings-shortcut-custom'),
            label: '사용자 지정 바로가기 막대',
            onTap: () => then(_openShortcutEditor),
          ),
          const ToolbarWritingSettings(),
        ],
      ),
    ];
  }

  void _openShortcutEditor() => unawaited(
    showShortcutBarEditor(
      context,
      layout: stows.noteShortcutLayout,
      legacyToolbar: stows.pageToolbarLayout.value,
    ),
  );

  /// The function row the editor draws itself when no host does.
  Widget _ownFunctionRow() => ListenableBuilder(
    listenable: Listenable.merge([
      stows.noteShortcutLayout,
      stows.editorFingerDrawing,
    ]),
    builder: (context, _) => NoteFunctionRow(
      shortcuts: chromeShortcuts(),
      fixed: chromeFixed(),
      layout: ShortcutLayout.decode(
        noteShortcutItems,
        stows.noteShortcutLayout.value,
        legacyToolbar: stows.pageToolbarLayout.value,
      ),
      onCustomize: _openShortcutEditor,
    ),
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
        if (coreInfo.readOnly) return;
        final previous = coreInfo.backgroundPattern;
        coreInfo.backgroundPattern = pattern;
        stows.lastBackgroundPattern.value = pattern;
        history.recordChange(
          EditorHistoryItem(
            type: .backgroundPattern,
            pageIndex: currentPageIndex,
            backgroundPatternChange: Change(
              previous: previous,
              current: pattern,
            ),
            strokes: [],
            images: [],
          ),
        );
        autosaveAfterDelay();
      }),
      setLineHeight: (lineHeight) => setState(() {
        if (coreInfo.readOnly) return;
        coreInfo.lineHeight = lineHeight;
        stows.lastLineHeight.value = lineHeight;
        autosaveAfterDelay();
      }),
      setLineThickness: (lineThickness) => setState(() {
        if (coreInfo.readOnly) return;
        coreInfo.lineThickness = lineThickness;
        stows.lastLineThickness.value = lineThickness;
        autosaveAfterDelay();
      }),
      removeBackgroundImage: () => setState(() {
        if (coreInfo.readOnly) return;

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
        if (coreInfo.readOnly) return;
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
        readOnly: coreInfo.readOnly,
        ignoring: currentTool is Select || currentTool == Tool.textEditing,
        onAction: (link, action) =>
            unawaited(_onLinkAction(page, link, action)),
        onPlace: _placingLink
            ? (point) => unawaited(_placeLink(page, point))
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

  Widget pageManager(BuildContext context) {
    return EditorPageManager(
      coreInfo: coreInfo,
      currentPageIndex: currentPageIndex,
      redrawAndSave: () => setState(() {
        if (coreInfo.readOnly) return;
        autosaveAfterDelay();
      }),
      insertPageAfter: insertPageAfter,
      duplicatePage: (int pageIndex) => setState(() {
        if (coreInfo.readOnly) return;
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
        coreInfo.pages.insert(pageIndex + 1, newPage);
        listenToQuillChanges(newPage.quill);
        history.recordChange(
          EditorHistoryItem(
            type: .insertPage,
            pageIndex: pageIndex,
            strokes: const [],
            images: const [],
            page: newPage,
          ),
        );
        autosaveAfterDelay();
      }),
      clearPage: clearPage,
      deletePage: (int pageIndex) => setState(() {
        if (coreInfo.readOnly) return;
        final page = coreInfo.pages.removeAt(pageIndex);
        createPage(pageIndex - 1);
        history.recordChange(
          EditorHistoryItem(
            type: .deletePage,
            pageIndex: pageIndex,
            strokes: const [],
            images: const [],
            page: page,
          ),
        );
        autosaveAfterDelay();
      }),
      onPageSelected: _scrollToPage,
    );
  }

  void insertPageAfter(int pageIndex) => setState(() {
    if (coreInfo.readOnly) return;
    final page = EditorPage();
    coreInfo.pages.insert(pageIndex + 1, page);
    listenToQuillChanges(page.quill);
    history.recordChange(
      EditorHistoryItem(
        type: .insertPage,
        pageIndex: pageIndex + 1,
        strokes: const [],
        images: const [],
        page: page,
      ),
    );
    autosaveAfterDelay();
  });

  void clearPage(int pageIndex) {
    if (coreInfo.readOnly) return;
    final page = coreInfo.pages[pageIndex];
    setState(() {
      final removedStrokes = page.strokes.toList();
      final removedImages = page.images.toList();
      page.strokes.clear();
      page.images.clear();
      removeExcessPages();
      history.recordChange(
        EditorHistoryItem(
          type: .erase,
          pageIndex: pageIndex,
          strokes: removedStrokes,
          images: removedImages,
        ),
      );
      autosaveAfterDelay();
    });
  }

  void clearAllPages() {
    if (coreInfo.readOnly) return;
    setState(() {
      final removedStrokes = <Stroke>[];
      final removedImages = <EditorImage>[];
      for (final page in coreInfo.pages) {
        removedStrokes.addAll(page.strokes);
        removedImages.addAll(page.images);
        page.strokes.clear();
        page.images.clear();
      }
      removeExcessPages();
      history.recordChange(
        EditorHistoryItem(
          type: .erase,
          pageIndex: 0,
          strokes: removedStrokes,
          images: removedImages,
        ),
      );
    });
    autosaveAfterDelay();
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
    if (coreInfo.readOnly) return;
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
    if (note.readOnly || index < 0) return false;
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
    if (note.readOnly || index < 0) return;
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
    if (pageIndex < 0 || coreInfo.readOnly) return false;
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
      _lastDrawRecorded = false;
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
    widget.chrome?.detach(this);
    // The hint lives in the app's messenger, which outlives the editor.
    _closePlacingHint();

    _delayedSaveTimer?.cancel();
    _watchServerTimer?.cancel();
    _lastSeenPointerCountTimer?.cancel();

    _removeKeybindings();

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

/// StarNote's "페이지로 이동 [n] 페이지" in the 기타 설정 panel.
class _GoToPageRow extends StatefulWidget {
  const new({required this.pages, required this.onGo});

  final int pages;
  final ValueChanged<int> onGo;

  @override
  State<_GoToPageRow> createState() => _GoToPageRowState();
}

class _GoToPageRowState extends State<_GoToPageRow> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(String text) {
    final page = int.tryParse(text.trim());
    if (page == null || page < 1 || page > widget.pages) return;
    widget.onGo(page);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('other-settings-go-to-page'),
    height: 48,
    child: Row(
      children: [
        Expanded(
          child: Text('페이지로 이동', style: TextTheme.of(context).bodyLarge),
        ),
        SizedBox(
          width: 76,
          height: 36,
          child: TextField(
            key: const ValueKey('other-settings-go-to-page-field'),
            controller: _controller,
            enabled: widget.pages > 0,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              hintText: '1',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onSubmitted: _go,
          ),
        ),
        const SizedBox(width: 8),
        const Text('페이지'),
      ],
    ),
  );
}
