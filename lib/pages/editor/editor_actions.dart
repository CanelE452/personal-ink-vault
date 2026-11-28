part of 'editor.dart';

/// What the editor offers its bars, menus and keys (its rows of the
/// publisher table in `AppActionIds`), and the code the old toolbar's
/// callbacks share with those actions.
extension _EditorActions on EditorState {
  /// The editor's actions in its current state. Published on every build;
  /// the registry tells listeners only when what they show changed.
  List<AppAction> _editorActions() {
    final fullscreen = DynamicMaterialApp.isFullscreen;
    final tool = currentTool;
    final editable = !coreInfo.readOnly;
    // ⋯ 「읽기 전용」: nothing that changes the note
    final writable = editable && !inkLocked.value;
    final pageWritable = _showPageActions && !inkLocked.value;
    final selected = tool is Select && tool.doneSelecting && writable;
    // A lasso around pictures only has no colour to change.
    final strokesSelected =
        selected && tool.selectResult.strokes.isNotEmpty;
    AppAction toolAction(
      String id,
      String label,
      KitIconName icon, {
      required bool checked,
      required VoidCallback pick,
    }) => AppAction(
      id: id,
      label: label,
      icon: icon,
      // The laser pointer works on a read-only note too; the text box is
      // writing.
      enabled:
          (id == AppActionIds.toolText ? writable : editable) ||
          id == AppActionIds.toolLaser,
      checked: checked,
      run: (_) => pick(),
    );

    return [
      ..._addPageActions(pageWritable),
      AppAction(
        id: AppActionIds.pageMode,
        label: _singlePageMode ? '연속 스크롤' : '한 쪽씩 보기',
        icon: KitIconName.scrollDir,
        enabled: _showPageMode,
        // on: one page at a time, turned sideways (⋯ 「쪽 배치」)
        checked: _singlePageMode,
        widgetKey: const ValueKey('editor-single-page-toggle'),
        run: (_) => _togglePageMode(),
      ),
      if (!stows.hideFingerDrawingToggle.value)
        AppAction(
          id: AppActionIds.finger,
          label: '손가락 필기',
          icon: KitIconName.tap,
          enabled: editable,
          checked: stows.editorFingerDrawing.value,
          run: (_) => _toggleFingerDrawing(),
        ),
      // The toolbar's mode button, ⋯ 「확대 잠금」 and the old toolbar's keys.
      // They work on a read-only note too (the lock and the mode are views).
      AppAction(
        id: AppActionIds.gestureMode,
        label: '제스처 모드',
        icon: KitIconName.palm,
        run: (_) => stows.editorGestureMode.value =
            !stows.editorGestureMode.value,
      ),
      AppAction(
        id: AppActionIds.floatingBar,
        label: '떠 있는 막대',
        icon: KitIconName.brush,
        run: (_) => _floatingBarOpen.value = !_floatingBarOpen.value,
      ),
      AppAction(
        id: AppActionIds.zoomLock,
        label: '확대 잠금',
        icon: KitIconName.zoom,
        run: (_) => stows.lastZoomLock.value = !stows.lastZoomLock.value,
      ),
      // as the toolbar's eraser button: writing again, with the bar
      AppAction(
        id: AppActionIds.eraserBar,
        label: '지우개',
        icon: KitIconName.eraser,
        run: (context) {
          stows.editorGestureMode.value = false;
          _actions.run(AppActionIds.toolEraser, context);
          _floatingBarOpen.value = true;
        },
      ),
      AppAction(
        id: AppActionIds.fullscreen,
        label: '전체 화면',
        icon: fullscreen ? KitIconName.collapse : KitIconName.expand,
        checked: fullscreen,
        run: (_) =>
            DynamicMaterialApp.setFullscreen(!fullscreen, updateSystem: true),
      ),
      AppAction(
        id: AppActionIds.export,
        label: '파일 내보내기',
        icon: KitIconName.share,
        enabled: _showPageActions,
        run: (_) => _openExportDialog(),
      ),
      AppAction(
        id: AppActionIds.linkAdd,
        label: '링크 추가',
        icon: KitIconName.link,
        enabled: pageWritable,
        checked: _placingLink,
        widgetKey: const ValueKey('editor-link-add'),
        run: (_) => _linkAdd(),
      ),
      AppAction(
        id: AppActionIds.undo,
        label: '실행 취소',
        icon: KitIconName.undo,
        enabled: history.canUndo && !inkLocked.value,
        run: (_) => undo(),
      ),
      AppAction(
        id: AppActionIds.redo,
        label: '다시 실행',
        icon: KitIconName.redo,
        enabled: history.canRedo && !inkLocked.value,
        run: (_) => redo(),
      ),
      AppAction(
        id: AppActionIds.pickPhoto,
        label: '사진',
        icon: KitIconName.image,
        enabled: writable,
        run: (_) => unawaited(_pickPhotos()),
      ),
      AppAction(
        id: AppActionIds.paste,
        label: '붙여넣기',
        icon: KitIconName.paste,
        enabled: writable,
        run: (_) => unawaited(paste()),
      ),
      AppAction(
        id: AppActionIds.duplicateSelection,
        label: '복제',
        icon: KitIconName.dup,
        enabled: selected,
        run: (_) => _duplicateSelection(),
      ),
      AppAction(
        id: AppActionIds.deleteSelection,
        label: '삭제',
        icon: KitIconName.trash,
        enabled: selected,
        run: (_) => _deleteSelection(),
      ),
      AppAction(
        id: AppActionIds.recolorSelection,
        label: '색 바꾸기',
        icon: KitIconName.colorDd,
        enabled: strokesSelected,
        run: _openRecolor,
      ),
      AppAction(
        id: AppActionIds.linkSelection,
        label: '링크',
        icon: KitIconName.link,
        enabled: selected,
        run: (_) => unawaited(_linkSelection()),
      ),
      // the left panel (supplement Task 9), lit while it is open
      AppAction(
        id: AppActionIds.pageList,
        label: '쪽 목록',
        icon: KitIconName.sidebar,
        enabled: _showPageActions,
        checked: _side.panelOpen.value,
        widgetKey: const ValueKey('note-page-list'),
        run: (_) => _side.togglePanel(),
      ),
      toolAction(
        AppActionIds.toolLasso,
        '올가미',
        KitIconName.lassoFree,
        checked: tool is Select,
        pick: () => _setTool(Select.currentSelect),
      ),
      toolAction(
        AppActionIds.toolPen,
        '펜',
        KitIconName.pen,
        checked: isInkTool(tool) && tool is! Highlighter && tool is! Pencil,
        pick: () =>
            _setTool(isInkTool(currentTool) ? currentTool : _lastInkTool),
      ),
      toolAction(
        AppActionIds.toolEraser,
        '지우개',
        KitIconName.eraser,
        checked: tool is Eraser,
        pick: () => _setTool(Eraser()),
      ),
      toolAction(
        AppActionIds.toolText,
        '글상자',
        KitIconName.text,
        checked: tool == Tool.textEditing,
        pick: _toggleTextEditing,
      ),
      toolAction(
        AppActionIds.toolShapes,
        '도형',
        KitIconName.shapes,
        checked: tool is ShapePen,
        pick: () => _setTool(
          Pen.currentPen is ShapePen ? Pen.currentPen : ShapePen(),
        ),
      ),
      toolAction(
        AppActionIds.toolHighlighter,
        '형광펜',
        KitIconName.marker,
        checked: tool is Highlighter,
        pick: () => _setTool(Highlighter.currentHighlighter),
      ),
      toolAction(
        AppActionIds.toolPencil,
        '연필',
        KitIconName.pencil,
        checked: tool is Pencil,
        pick: () => _setTool(Pencil.currentPencil),
      ),
      toolAction(
        AppActionIds.toolLaser,
        '레이저 포인터',
        KitIconName.laser,
        checked: tool is LaserPointer,
        pick: () => _setTool(LaserPointer.currentLaserPointer),
      ),
      AppAction(
        id: AppActionIds.eyedropper,
        label: '스포이트',
        icon: KitIconName.eyedrop,
        enabled: writable,
        checked: _eyedropping,
        run: (_) => _toggleEyedropper(),
      ),
      // the eraser's 「고급 설정」 asks first, then runs it
      AppAction(
        id: AppActionIds.clearPage,
        label: '쪽 비우기',
        icon: KitIconName.delPage,
        enabled: writable,
        run: (_) => clearPage(currentPageIndex),
      ),
      AppAction(
        id: AppActionIds.toolbarCustomize,
        label: '도구 막대 사용자화',
        icon: KitIconName.tune,
        run: (_) => _customizing.value = true,
      ),
      // ⋯ 「읽기 전용」: on, the page takes no ink but still moves
      AppAction(
        id: AppActionIds.readOnly,
        label: '읽기 전용',
        icon: KitIconName.readonly,
        enabled: editable,
        checked: inkLocked.value,
        run: (_) {
          inkLocked.value = !inkLocked.value;
          // the text box in hand goes back to the pen, a 링크 추가 or the
          // eyedropper waiting for its tap stops
          if (inkLocked.value && currentTool == Tool.textEditing) {
            _toggleTextEditing();
          }
          if (inkLocked.value) {
            _stopPlacingLink();
            _stopEyedropper();
            // nothing stays lassoed for the lasso bar to change
            if (currentTool is Select) Select.currentSelect.unselect();
            // unlocked again, the badge waits for the pen to move
            _hoverBadge.value = null;
          }
          _setState();
        },
      ),
      // ⋯ 「쪽 N」: the page on screen. 「쪽 즐겨찾기」 only where the vault
      // holds favourites, not on a note that may not change.
      if (_side.favoritesAvailable && editable)
        AppAction(
          id: AppActionIds.pageBookmark,
          label: '쪽 즐겨찾기',
          icon: KitIconName.bookmark,
          enabled: _noteReady,
          checked: _side.isFavorite(
            coreInfo.pages.elementAtOrNull(currentPageIndex)?.pageId,
          ),
          run: (_) {
            final page = coreInfo.pages.elementAtOrNull(currentPageIndex);
            if (page != null) unawaited(_side.toggleFavorite(page.pageId));
          },
        ),
      // 「개요에 추가」: the page on screen, as 「쪽 N」, its name open to
      // change in the outline tab (the user's outline is a page mark too)
      if (_side.favoritesAvailable && editable)
        AppAction(
          id: AppActionIds.outlineAdd,
          label: '개요에 추가',
          icon: KitIconName.outlineAdd,
          enabled: _noteReady,
          run: (_) => unawaited(_side.addOutline(currentPageIndex)),
        ),
      // 녹음 (supplement Task 12): ⋯ 「읽기 전용」 leaves it on, a recording
      // being an attachment as a favourite is
      if (_side.canRecord && editable)
        AppAction(
          id: AppActionIds.record,
          label: _side.audio.recordingOn ? '녹음 멈춤' : '녹음 시작',
          icon: KitIconName.mic,
          checked: _side.audio.recordingOn,
          enabled: !_side.audio.savingRecording,
          run: (_) => unawaited(_side.audio.toggleRecording()),
        ),
      // 노트 창 (supplement Task 13): the quick note is an attachment too
      if (_side.quickNote.available.value && editable)
        AppAction(
          id: AppActionIds.quickNote,
          label: '노트 창',
          icon: KitIconName.noteUp,
          enabled: _noteReady,
          checked: _noteSheetOpen.value,
          run: (_) => _noteSheetOpen.value = !_noteSheetOpen.value,
        ),
      AppAction(
        id: AppActionIds.pageDuplicate,
        label: '쪽 복제',
        icon: KitIconName.dup,
        enabled: pageWritable,
        run: (_) => _duplicatePage(currentPageIndex),
      ),
      AppAction(
        id: AppActionIds.templateChange,
        label: '템플릿 바꾸기',
        icon: KitIconName.template,
        enabled: pageWritable,
        run: (_) => _openPageMenu(),
      ),
      AppAction(
        id: AppActionIds.goToPage,
        label: '쪽으로 이동',
        icon: KitIconName.gotoPage,
        enabled: _showPageMode,
        run: _openGoToPage,
      ),
      // ⋯ 「지금 저장」: dimmed with nothing waiting to be saved
      AppAction(
        id: AppActionIds.saveNow,
        label: '지금 저장',
        icon: KitIconName.saved,
        enabled:
            editable &&
            (savingState.value == SavingState.waitingToSave ||
                savingState.value == SavingState.failed),
        run: (_) => unawaited(saveToFile()),
      ),
      AppAction(
        id: AppActionIds.docInfo,
        label: '문서 정보',
        icon: KitIconName.info,
        enabled: _noteReady,
        run: _openDocInfo,
      ),
      // ⋯ 「전체 설정 열기」: a host's 설정 wins; an editor alone (Saber's
      // screen, an Office PDF apart from the workspace) opens the page itself
      if (!(widget.chrome?.actions.parent?.has(AppActionIds.openSettings) ??
          false))
        AppAction(
          id: AppActionIds.openSettings,
          label: '설정',
          icon: KitIconName.settings,
          run: (context) => unawaited(
            Navigator.of(context).push(appSettingsRoute(actions: _actions)),
          ),
        ),
      // A host saves the document itself (the workspace's 기기에 저장).
      if (widget.chrome == null)
        AppAction(
          id: AppActionIds.save,
          label: '기기에 저장',
          icon: KitIconName.download,
          enabled: editable,
          run: (_) => unawaited(saveToFile()),
        ),
    ];
  }

  /// The editor's keys, while the focus is in it (not in the Markdown beside
  /// it, not in another editor): the keys it shares with the infinite note
  /// ([appShortcutKeys]: Ctrl+Z undo, Ctrl+Y and Ctrl+Shift+Z redo, Ctrl+F
  /// finger drawing, Ctrl+E the eraser with the bar, Ctrl+C the floating bar,
  /// Ctrl+S 「지금 저장」, Ctrl+Shift+S export, F11 full screen, Ctrl+V paste)
  /// each run their action id. Esc ends the eyedropper's wait. Ctrl+= (and
  /// Ctrl++) zooms in, Ctrl+− out, and the arrows move the page while the
  /// editor itself has the focus (keybinder's global keys before Task 19):
  /// no action stands behind these, so they stay here. [_EditorKeyAction]
  /// leaves all of them to a text field inside the editor that has the focus.
  Map<ShortcutActivator, Intent> _keyboardShortcuts() => {
    for (final (key, id) in appShortcutKeys)
      key: _EditorKeyIntent(_EditorKey.action, id),
    const SingleActivator(LogicalKeyboardKey.equal, control: true):
        const _EditorKeyIntent(_EditorKey.zoomIn),
    const SingleActivator(LogicalKeyboardKey.equal, control: true, shift: true):
        const _EditorKeyIntent(_EditorKey.zoomIn),
    const SingleActivator(LogicalKeyboardKey.add, control: true):
        const _EditorKeyIntent(_EditorKey.zoomIn),
    const SingleActivator(LogicalKeyboardKey.minus, control: true):
        const _EditorKeyIntent(_EditorKey.zoomOut),
    const SingleActivator(LogicalKeyboardKey.arrowLeft):
        const _EditorKeyIntent(_EditorKey.panLeft),
    const SingleActivator(LogicalKeyboardKey.arrowRight):
        const _EditorKeyIntent(_EditorKey.panRight),
    const SingleActivator(LogicalKeyboardKey.arrowUp):
        const _EditorKeyIntent(_EditorKey.panUp),
    const SingleActivator(LogicalKeyboardKey.arrowDown):
        const _EditorKeyIntent(_EditorKey.panDown),
    if (_eyedropping)
      const SingleActivator(LogicalKeyboardKey.escape):
          const _EditorKeyIntent(_EditorKey.stopEyedropper),
  };

  void _runKey(_EditorKeyIntent intent) {
    switch (intent.key) {
      case _EditorKey.action:
        _actions.run(intent.actionId!, context);
      case _EditorKey.stopEyedropper:
        _stopEyedropper();
      case _EditorKey.zoomIn:
        _canvasGestureDetectorKey.currentState?.zoomIn();
      case _EditorKey.zoomOut:
        _canvasGestureDetectorKey.currentState?.zoomOut();
      case _EditorKey.panLeft:
        _canvasGestureDetectorKey.currentState?.arrowKeyPan(AxisDirection.left);
      case _EditorKey.panRight:
        _canvasGestureDetectorKey.currentState?.arrowKeyPan(AxisDirection.right);
      case _EditorKey.panUp:
        _canvasGestureDetectorKey.currentState?.arrowKeyPan(AxisDirection.up);
      case _EditorKey.panDown:
        _canvasGestureDetectorKey.currentState?.arrowKeyPan(AxisDirection.down);
    }
  }

  /// The ink tool the pen action brings back at first: the tool in hand if
  /// it is one, then the pen button's last kind if it is one, else the
  /// fine-nib pen (pens in hand are used again).
  Tool _firstInkTool() {
    if (isInkTool(currentTool)) return currentTool;
    for (final kind in KitPenKind.values) {
      if (kind.toolId == stows.lastPenFamily.value) {
        return toolForPenKind(kind, _ink.toolState);
      }
    }
    return toolForPenKind(KitPenKind.fountain, _ink.toolState);
  }

  /// Takes [tool] in hand. The eraser again puts the tool before it back.
  void _setTool(Tool tool) {
    if (tool is Eraser && currentTool is Eraser) {
      // setTool(Eraser) is a special case to toggle the eraser on/off
      tool = _lastNonEraserTool;
    }
    if (currentTool == Tool.textEditing && tool != Tool.textEditing) {
      _leaveTextBox();
    }

    currentTool = tool;

    // the round highlighter is kept by the tool state, not here
    if (tool is Highlighter) {
      if (tool.nib == InkNib.chisel) Highlighter.currentHighlighter = tool;
    } else if (tool is Pencil) {
      Pencil.currentPencil = tool;
    } else if (tool is Pen) {
      Pen.currentPen = tool;
    }

    if (mounted) _setState();
  }

  /// The text box: on, or off back to the last ink tool.
  void _toggleTextEditing() {
    if (currentTool == Tool.textEditing) {
      _leaveTextBox();
      currentTool = _lastInkTool;
    } else {
      currentTool = Tool.textEditing;
      quillFocus.value = coreInfo.pages[currentPageIndex].quill
        ..focusNode.requestFocus();
    }
    _setState();
  }

  /// The text box is put down: its text stays unselected with the cursor
  /// where it was, and the keys it had come back to the editor (Ctrl+Z
  /// undoes ink again).
  void _leaveTextBox() {
    final hadKeys = _editorFocus.hasFocus;
    for (final page in coreInfo.pages) {
      final text = page.quill.controller;
      // Quietly: flutter_quill rebuilds a text box that changed, and one
      // losing the focus while it waits to rebuild asks for it again.
      text.ignoreFocusOnTextChange = true;
      text.moveCursorToPosition(text.selection.extentOffset);
      text.ignoreFocusOnTextChange = false;
      page.quill.focusNode.unfocus();
    }
    if (hadKeys) _editorFocus.requestFocus();
  }

  /// Copies the lassoed strokes and pictures a little to the side and
  /// lassoes the copies, as one undo step.
  void _duplicateSelection() {
    final select = currentTool;
    if (select is! Select || !select.doneSelecting) return;

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
        page: page,
      ),
    );
    autosaveAfterDelay();
    _setState();
  }

  /// Removes the lassoed strokes and pictures, as one undo step.
  void _deleteSelection() {
    final select = currentTool;
    if (select is! Select || !select.doneSelecting) return;

    // The lasso's page (unselect() forgets it); it may hold pictures only.
    final pageIndex = select.selectResult.pageIndex;
    final page = coreInfo.pages[pageIndex];
    // Their places before they go, so undoing puts each back there.
    final swap = InkSwap(
      removedStrokes: [
        for (final stroke in select.selectResult.strokes)
          (page.strokes.indexOf(stroke), stroke),
      ],
      removedImages: [
        for (final image in select.selectResult.images)
          (page.images.indexOf(image), image),
      ],
    );

    for (final (_, stroke) in swap.removedStrokes) {
      page.strokes.remove(stroke);
    }
    for (final (_, image) in swap.removedImages) {
      page.images.remove(image);
    }

    select.unselect();

    pageList.recordReplace([(page: page, swap: swap)]);
    autosaveAfterDelay();
    _setState();
  }

  /// Gives the pen in hand [color] (and keeps it for the next pen of that
  /// kind), or the lassoed strokes with the lasso in hand. Only the
  /// lassoed strokes build the editor again: the pen's windows follow
  /// [_ink]'s tool state.
  void _setColor(Color color) {
    updateColorBar(color);

    // setColor also keeps the colour for the next pen of that kind.
    if (currentTool is Highlighter) {
      (currentTool as Highlighter).setColor(
        color.withAlpha(Highlighter.alpha),
      );
    } else if (currentTool is Pen) {
      (currentTool as Pen).setColor(color);
    } else if (currentTool is Select) {
      _recolorSelection(color);
      return _setState();
    }
    _ink.toolState.update(tool: currentTool);
  }

  /// Gives the lassoed strokes [color], as one undo step; nothing when the
  /// lasso holds pictures only.
  void _recolorSelection(Color color) {
    final select = currentTool;
    if (select is! Select || !select.doneSelecting) return;
    final strokes = select.selectResult.strokes;
    if (strokes.isEmpty) return;

    final colorChange = <Stroke, Change<Color>>{};
    for (final stroke in strokes) {
      colorChange[stroke] = Change(previous: stroke.color, current: color);
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

  /// 「색 바꾸기」: the colours in a small window on [context]; the one
  /// chosen recolours the lassoed strokes.
  void _openRecolor(BuildContext context) => unawaited(
    showDialog<void>(
      context: context,
      builder: (dialog) => Dialog(
        child: PenPanelSurface(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: KitPenColorRow(
              selected: Select.currentSelect.getDominantStrokeColor(),
              onSelected: (color) {
                Navigator.pop(dialog);
                _recolorSelection(color);
                if (mounted) _setState();
              },
            ),
          ),
        ),
      ),
    ),
  );

  /// 스포이트: the next tap on a page gives the pen the colour there, and
  /// draws nothing. Pressed again, or Esc, it stops waiting.
  void _toggleEyedropper() {
    if (_eyedropping) return _stopEyedropper();
    _ink.toolState.update(eyedropper: true);
    _setState();
    // Esc reaches the editor's keys only while the focus is in it.
    if (!_editorFocus.hasFocus) _editorFocus.requestFocus();
  }

  void _stopEyedropper() {
    if (!_eyedropping) return;
    _ink.toolState.update(eyedropper: false);
    _setState();
  }

  /// The eyedropper's tap at [point] of [page]: reads the page's picture
  /// there and gives the pen that colour, as it is drawn (a page shown
  /// inverted is read back).
  void _pickColour(EditorPage page, Offset point) {
    final boundary = page.innerCanvasKey.currentContext?.findRenderObject();
    if (boundary is RenderRepaintBoundary) {
      final invert = inkInverted(context);
      _eyedropperPick = () async {
        try {
          // Read before this tap's rebuild repaints the page.
          final image = await boundary.toImage();
          try {
            final pixels = await image.toByteData();
            if (pixels == null || !mounted) return;
            final x = point.dx.floor().clamp(0, image.width - 1);
            final y = point.dy.floor().clamp(0, image.height - 1);
            final at = (y * image.width + x) * 4;
            final seen = Color.fromARGB(
              255,
              pixels.getUint8(at),
              pixels.getUint8(at + 1),
              pixels.getUint8(at + 2),
            );
            _setColor(seen.withInversion(invert));
          } finally {
            image.dispose();
          }
        } catch (error, stackTrace) {
          logUserError(error, stackTrace);
        }
      }();
    }
    _stopEyedropper();
  }
}

/// The editor's side of the ink windows (the floating bar, the pen panel):
/// a tool goes through the toolbar's way of taking it, a colour through
/// [_EditorActions._setColor], a size and a stabilisation to the pen in
/// hand. Each then reaches [toolState] (the tool through
/// [EditorState.currentTool]), so only a new tool builds the editor again.
class _EditorInkHost implements InkToolHost {
  new(this._editor);

  final EditorState _editor;

  @override
  late final toolState = InkToolState(_editor.currentTool);

  @override
  void selectTool(Tool tool) => _editor._setTool(tool);

  @override
  void setColor(Color color) => _editor._setColor(color);

  @override
  void setSize(double size) {
    if (_editor.currentTool case final Pen pen) {
      pen.setSize(size);
      toolState.update(tool: pen);
    }
  }

  @override
  void setStabiliser(double value) {
    if (_editor.currentTool case final Pen pen) {
      pen.setStreamline(value);
      toolState.update(tool: pen);
    }
  }

  @override
  void setAlpha(int alpha) {
    if (_editor.currentTool case final Pen pen) {
      pen.setAlpha(alpha);
      toolState.update(tool: pen);
    }
  }

  @override
  void setLineStyle(KitPenDash style) {
    if (_editor.currentTool case final Pen pen) {
      pen.setLineStyle(style);
      toolState.update(tool: pen);
    }
  }
}

/// The editor's keys: [action] runs the action id the key carries; the others
/// have no action and are the editor's own.
enum _EditorKey {
  action,
  stopEyedropper,
  zoomIn,
  zoomOut,
  panLeft,
  panRight,
  panUp,
  panDown,
}

class _EditorKeyIntent extends Intent {
  const new(this.key, [this.actionId]);

  final _EditorKey key;

  /// The action id of an [_EditorKey.action] key.
  final String? actionId;
}

/// Runs an editor key, unless the focus is in a text field inside the editor
/// (the file name, 「페이지로 이동」, the text box). Then the key goes on to
/// that field: Ctrl+Z undoes its text, not the ink. The arrows move the page
/// only while the editor itself has the focus ([_editorFocused]); on a button
/// inside it they go on to Flutter's arrow focus moves.
class _EditorKeyAction extends ContextAction<_EditorKeyIntent> {
  new(this._run, this._editorFocused);

  final void Function(_EditorKeyIntent intent) _run;
  final bool Function() _editorFocused;

  static const _arrows = {
    _EditorKey.panLeft,
    _EditorKey.panRight,
    _EditorKey.panUp,
    _EditorKey.panDown,
  };

  @override
  bool isEnabled(_EditorKeyIntent intent, [BuildContext? context]) {
    if (_arrows.contains(intent.key)) return _editorFocused();
    return context == null || !_editsText(context);
  }

  @override
  Object? invoke(_EditorKeyIntent intent, [BuildContext? context]) {
    _run(intent);
    return null;
  }

  /// Whether [context] (the focused node's) is in a widget that edits text:
  /// Flutter's text fields and the Quill text box both are a
  /// [TextSelectionDelegate].
  static bool _editsText(BuildContext context) {
    var found =
        context is StatefulElement && context.state is TextSelectionDelegate;
    if (!found) {
      context.visitAncestorElements((element) {
        found = element is StatefulElement &&
            element.state is TextSelectionDelegate;
        return !found;
      });
    }
    return found;
  }
}
