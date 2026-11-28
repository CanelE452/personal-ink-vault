part of 'editor.dart';

/// The editor's toolbar (Task 13B-1, preview 9th draft c) and what lies over
/// its page area: the text box and lasso bars (Task 15), the floating bar,
/// the left panel (supplement Task 9), the quick note (Task 13) and 「도구
/// 막대 사용자화」.
extension _EditorToolbarArea on EditorState {
  /// The toolbar, folded away on a read-only note and in full screen unless
  /// it is kept there.
  List<Widget> _toolbarArea() => [
    Collapsible(
      axis: CollapsibleAxis.vertical,
      collapsed:
          coreInfo.readOnly ||
          DynamicMaterialApp.isFullscreen &&
              !stows.editorToolbarShowInFullscreen.value,
      maintainState: true,
      child: SafeArea(
        bottom: false,
        // 노트 창 where the vault keeps the quick note
        child: ValueListenableBuilder(
          valueListenable: _side.quickNote.available,
          builder: (context, quickNote, _) => KitEditorToolbar(
            actions: _actions,
            title: widget.customTitle ?? coreInfo.fileName,
            floatingBarOpen: _floatingBarOpen,
            noteSheetOpen: quickNote ? _noteSheetOpen : null,
            floatingBarFrom: _floatingBarFrom,
            pages: () =>
                (index: currentPageIndex, count: coreInfo.pages.length),
            recording: _side.audio.recording,
            insertPageAnchor: _side.addPage.anchor,
            zoom: DocZoom(
              scale: () => _transformationController.value.approxScale,
              zoomTo: (scale) =>
                  _canvasGestureDetectorKey.currentState?.zoomTo(scale),
            ),
          ),
        ),
      ),
    ),
  ];

  /// The page area: the canvas, and over it the text box or lasso bar, the
  /// floating bar (for the pens and the eraser while the toolbar shows it,
  /// not in gesture mode), the save chip, the pen tip badge, the left panel,
  /// the mode pill, the quick note, 「도구 막대 사용자화」, the listening
  /// bar, the recording pill and the undo notice. They follow their own
  /// notifiers, so opening one does not build the editor again. The bar and
  /// the chip fade out of a stroke's way.
  Widget _pageArea(Widget canvas) => Stack(
    children: [
      Positioned.fill(
        child: HoverBadgeListener(controller: _hoverBadge, child: canvas),
      ),
      Positioned.fill(child: _SelectionBarLayer(editor: this)),
      Positioned.fill(
        child: ListenableBuilder(
          listenable: Listenable.merge([
            _floatingBarOpen,
            stows.editorGestureMode,
          ]),
          builder: (context, _) => KitFloatingBar(
            host: _ink,
            actions: _actions,
            penPanelCollapsed: stows.penPanelCollapsed,
            growFrom: _floatingBarFrom,
            strokeAt: _strokeAt,
            visible:
                !coreInfo.readOnly &&
                !stows.editorGestureMode.value &&
                _floatingBarOpen.value &&
                (isInkTool(currentTool) || currentTool is Eraser),
          ),
        ),
      ),
      Positioned.fill(
        child: KitSaveChip(
          state: savingState,
          actions: _actions,
          strokeAt: _strokeAt,
        ),
      ),
      // the tool a touch would use; none while a touch would not use it
      // (the note may not change, gesture mode, the eyedropper or a link
      // waiting for its tap)
      Positioned.fill(
        child: ListenableBuilder(
          listenable: Listenable.merge([
            inkLocked,
            stows.selectRectangle,
            stows.editorGestureMode,
          ]),
          builder: (context, _) =>
              _noteLocked ||
                  stows.editorGestureMode.value ||
                  _eyedropping ||
                  _placingLink
              ? const SizedBox.shrink()
              : KitHoverBadge(
                  controller: _hoverBadge,
                  toolIcon: kitIconForTool(
                    currentTool,
                    lassoRect: stows.selectRectangle.value,
                  ),
                ),
        ),
      ),
      Positioned.fill(
        child: EditorSidePanelLayer(
          host: _side,
          coreInfo: coreInfo,
          goTo: _scrollToPage,
          pageActions: _pageActions(),
        ),
      ),
      Positioned.fill(
        child: KitModePill(
          gestureMode: stows.editorGestureMode,
          inkLocked: inkLocked,
        ),
      ),
      // the quick note (z 6) over the left panel (z 4); it writes with the
      // pen in hand, or the last pen kind where the lasso, the text box,
      // the laser or the shape pen is; under the record pill while it records
      Positioned.fill(
        child: EditorQuickNoteLayer(
          host: _side.quickNote,
          pen: () =>
              (isInkTool(currentTool) ? currentTool : _lastInkTool) as Pen,
          erasing: () => currentTool is Eraser,
          recording: _side.audio.recording,
          recordPill: _side.audio.recordPill,
        ),
      ),
      Positioned.fill(
        child: ValueListenableBuilder(
          valueListenable: _customizing,
          builder: (context, open, _) => open
              ? ToolbarCustomizeSheet(onClose: () => _customizing.value = false)
              : const SizedBox.shrink(),
        ),
      ),
      // the listening bar (z 7), under the notice
      Positioned.fill(child: EditorListenBarLayer(audio: _side.audio)),
      // the recording pill (z 7), its top right
      Positioned.fill(child: EditorRecordPillLayer(audio: _side.audio)),
      // over all of them, as the preview's toast (z 9); over the page flip
      // bar while that stands over the listening bar
      Positioned.fill(
        child: ValueListenableBuilder(
          valueListenable: _side.audio.footRoom,
          builder: (context, room, _) => KitUndoNotice(
            controller: _side.notice,
            bottom: _singlePageMode && room > 0
                ? KitTokens.undoNoticeOverPageFlip
                : KitTokens.undoNoticeBottom,
          ),
        ),
      ),
    ],
  );

  /// The left panel and the favourites, kept in the vault the host names. A
  /// favourite first saves the note (forced the first time, so the page ids
  /// it names are saved).
  EditorSideHost _sideHost() => EditorSideHost(
    binding: () => widget.chrome?.noteSide?.call(),
    saveNote: (force) async {
      if (force && savingState.value == SavingState.saved) {
        savingState.value = SavingState.waitingToSave;
      }
      await saveToFile();
    },
    pages: () => coreInfo.pages,
    pageOnScreen: () => currentPageIndex,
    pageMoves: _transformationController,
    onChanged: _publishActions,
    onError: (error) {
      if (mounted) showUserErrorSnackBar(context, error);
    },
    quickNoteOpen: _noteSheetOpen,
    noteWritable: () async {
      await _initializing;
      return !coreInfo.readOnly;
    },
  );

  /// 「문서 정보」: the name, the kind, the pages, the last edit (time ago),
  /// the Drive state and whether the note is kept on the device. The host
  /// gives the file's time and the Drive state. An editor alone does not
  /// know the Drive or the file's time (「알 수 없음」), and opened its note
  /// from a file on this device (「준비됨」).
  void _openDocInfo(BuildContext context) {
    final pdf = coreInfo.pages.any((page) => page.backgroundImage != null);
    final info =
        widget.chrome?.docInfo?.call() ??
        const DocInfo(syncLabel: '알 수 없음', offlineLabel: '준비됨');
    final edited = docLastEdited(editor: _lastEditedAt, vault: info.lastEdited);
    final rows = [
      ('이름', widget.customTitle ?? coreInfo.fileName, KitTokens.menuSub),
      ('종류', pdf ? 'PDF 필기' : '필기 노트', KitTokens.menuSub),
      ('쪽 수', '${coreInfo.pages.length}쪽', KitTokens.menuSub),
      (
        '마지막 편집',
        edited == null ? '알 수 없음' : docInfoAgo(edited, DateTime.now()),
        KitTokens.menuSub,
      ),
      // synced reads green (preview `.ksub` 「동기화됨」 #1d8a52)
      ('동기화', info.syncLabel, info.synced ? KitTokens.ok : KitTokens.menuSub),
      ('오프라인용 저장', info.offlineLabel, KitTokens.menuSub),
    ];
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialog) => Dialog(
          backgroundColor: KitTokens.menuBg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KitTokens.penPanelRadius),
          ),
          child: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Text(
                    '문서 정보',
                    style: TextStyle(
                      fontSize: KitTokens.menuTitleSize,
                      fontWeight: FontWeight.w600,
                      color: KitTokens.menuInk,
                    ),
                  ),
                ),
                ColoredBox(
                  color: KitTokens.menuGroupBg,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Column(
                      children: [
                        for (final (name, value, ink) in rows)
                          SizedBox(
                            height: 44,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    name,
                                    style: const TextStyle(
                                      fontSize: KitTokens.menuFontSize,
                                      color: KitTokens.menuInk,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      value,
                                      textAlign: TextAlign.end,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: KitTokens.menuFontSize,
                                        color: ink,
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
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: KitTokens.accent,
                    ),
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('닫기'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The text box's bar under the caret or the chosen text, and the lasso's
/// bar under the lassoed area (Task 15), in screen coordinates over the
/// page area. Where they go is read after each frame this is built in: the
/// editor builds it again when the tool or the lasso changes, and it follows
/// the zoom, the scroll and the text box's caret itself. It is hidden while
/// a stroke or a drag of the lassoed things goes on.
class _SelectionBarLayer extends StatefulWidget {
  const new({required this.editor});

  final EditorState editor;

  @override
  State<_SelectionBarLayer> createState() => _SelectionBarLayerState();
}

class _SelectionBarLayerState extends State<_SelectionBarLayer> {
  /// What the bar stands under, on this layer, and whose it is (the text
  /// box's controller or the lasso); null: no bar.
  (Rect, Object)? _target;

  // The text box last found, kept while it stays on screen.
  flutter_quill.RenderEditor? _textBox;
  QuillStruct? _textBoxOf;

  EditorState get _editor => widget.editor;

  /// The text box being written in, while the text tool is in hand.
  QuillStruct? get _quill {
    final quill = _editor.quillFocus.value;
    if (_editor.currentTool != Tool.textEditing || _editor.coreInfo.readOnly) {
      return null;
    }
    return quill;
  }

  bool get _lassoed =>
      _editor.currentTool is Select && Select.currentSelect.doneSelecting;

  void _measure() {
    if (!mounted) return;
    final layer = context.findRenderObject() as RenderBox?;
    if (layer == null || !layer.attached || !layer.hasSize) return;
    final target = _read(layer);
    if (target != _target) setState(() => _target = target);
  }

  (Rect, Object)? _read(RenderBox layer) {
    /// [rect] of [box] on the layer; null when it is off the layer.
    Rect? onLayer(RenderBox box, Rect rect) {
      if (!box.attached) return null;
      final onScreen = Rect.fromPoints(
        layer.globalToLocal(box.localToGlobal(rect.topLeft)),
        layer.globalToLocal(box.localToGlobal(rect.bottomRight)),
      );
      return (Offset.zero & layer.size).overlaps(onScreen.inflate(1))
          ? onScreen
          : null;
    }

    if (_quill case final quill?) {
      final box = _textBoxFor(quill);
      final at = quill.controller.selection;
      if (box == null || !at.isValid) return null;
      final start = box.getLocalRectForCaret(TextPosition(offset: at.start));
      final end = at.isCollapsed
          ? start
          : box.getLocalRectForCaret(TextPosition(offset: at.end));
      final rect = onLayer(box, start.expandToInclude(end));
      return rect == null ? null : (rect, quill.controller);
    }
    if (_lassoed) {
      final result = Select.currentSelect.selectResult;
      final page = _editor.coreInfo.pages.elementAtOrNull(result.pageIndex);
      final box = page?.renderBox;
      if (box == null) return null;
      final rect = onLayer(box, result.path.getBounds());
      return rect == null ? null : (rect, Select.currentSelect);
    }
    return null;
  }

  /// The Quill render box of [quill]'s page, looked up under the page.
  flutter_quill.RenderEditor? _textBoxFor(QuillStruct quill) {
    if (_textBoxOf == quill && (_textBox?.attached ?? false)) return _textBox;
    _textBox = null;
    _textBoxOf = quill;
    for (final page in _editor.coreInfo.pages) {
      if (page.quill != quill) continue;
      void visit(Element element) {
        if (_textBox != null) return;
        if (element is RenderObjectElement &&
            element.renderObject is flutter_quill.RenderEditor) {
          _textBox = element.renderObject as flutter_quill.RenderEditor;
          return;
        }
        element.visitChildren(visit);
      }

      page.innerCanvasKey.currentContext?.visitChildElements(visit);
      break;
    }
    return _textBox;
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _editor.quillFocus,
    builder: (context, _, _) => ListenableBuilder(
      listenable: Listenable.merge([
        _editor._transformationController,
        _editor._strokeAt,
        ?_quill?.controller,
      ]),
      builder: (context, _) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
        return RepaintBoundary(child: SizedBox.expand(child: _bar()));
      },
    ),
  );

  Widget? _bar() {
    // out of the way while a stroke is drawn or the lassoed things are
    // dragged; read again where they are let go
    if (_editor._strokeAt.value != null) return null;
    // a rectangle read for the other bar waits for the next reading
    if (_target case (final target, final owner)) {
      if (_quill case final quill?) {
        if (owner != quill.controller) return null;
        return KitTextBar(
          controller: quill.controller,
          caretRect: target,
          defaultSize: _editor.coreInfo.lineHeight * 0.7,
        );
      }
      if (!_lassoed || owner != Select.currentSelect) return null;
      return KitLassoBar(
        // what the 「색 바꾸기」 action does with the colour it is given,
        // while that action may run
        recolorSelection: (colour) {
          final recolor = AppActionScope.read(
            context,
          )?.lookup(AppActionIds.recolorSelection);
          if (!(recolor?.enabled ?? false)) return;
          _editor._recolorSelection(colour);
          _editor._setState();
        },
        selectionRect: target,
        selectionColor: Select.currentSelect.getDominantStrokeColor(),
      );
    }
    return null;
  }
}
