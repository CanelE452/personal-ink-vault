import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:keybinder/keybinder.dart';
import 'package:saber/components/canvas/hud/canvas_hud.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/extensions/change_notifier_extensions.dart';
import 'package:saber/data/extensions/matrix4_extensions.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:vector_math/vector_math_64.dart';

class CanvasGestureDetector extends StatefulWidget {
  new({
    super.key,
    required this.filePath,
    required this.isDrawGesture,
    this.onInteractionEnd,
    required this.onDrawStart,
    required this.onDrawUpdate,
    required this.onDrawEnd,
    required this.updatePointerData,
    required this.onHovering,
    required this.onHoveringEnd,
    required this.onStylusButtonChanged,
    required this.undo,
    required this.redo,
    required this.pages,
    required this.initialPageIndex,
    this.initialSinglePageMode = false,
    required this.pageBuilder,
    required this.placeholderPageBuilder,
    required this.isTextEditing,
    TransformationController? transformationController,
  }) : _transformationController =
           transformationController ?? TransformationController();

  final String filePath;

  final bool Function(ScaleStartDetails scaleDetails) isDrawGesture;
  final ValueChanged<ScaleEndDetails>? onInteractionEnd;
  final ValueChanged<ScaleStartDetails> onDrawStart;
  final ValueChanged<ScaleUpdateDetails> onDrawUpdate;
  final ValueChanged<ScaleEndDetails> onDrawEnd;

  /// Called when the pressure of the stylus changes.
  /// The [pressure] value is normalized into a range of 0 to 1.
  final void Function(PointerDeviceKind kind, double? pressure)
  updatePointerData;
  final VoidCallback onHovering;
  final VoidCallback onHoveringEnd;
  final ValueChanged<bool> onStylusButtonChanged;

  final VoidCallback undo;
  final VoidCallback redo;

  final List<EditorPage> pages;
  final int? initialPageIndex;
  final bool initialSinglePageMode;
  final Widget Function(BuildContext context, int pageIndex) pageBuilder;
  final Widget Function(BuildContext context, int pageIndex)
  placeholderPageBuilder;

  final bool Function() isTextEditing;

  late final TransformationController _transformationController;

  @override
  State<CanvasGestureDetector> createState() => CanvasGestureDetectorState();

  static const kMinScale = 0.3;
  static const kMaxScale = 10.0;
  static const _pageTopInset = Editor.gapBetweenPages * 2;

  static double _fittedPageHeight(EditorPage page, double canvasWidth) =>
      page.size.height * min(page.size.width, canvasWidth) / page.size.width;

  static double getTopOfPage({
    required int pageIndex,
    required List<EditorPage> pages,
    required double screenWidth,
  }) {
    double top = _pageTopInset;

    for (int i = 0; i < pageIndex && i < pages.length; i++) {
      top += _fittedPageHeight(pages[i], screenWidth) + Editor.gapBetweenPages;
    }

    return top;
  }

  static int getPageIndex({
    required double scrollY,
    required List<EditorPage> pages,
    required double screenWidth,
  }) {
    double nextTop = _pageTopInset;

    for (int i = 0; i < pages.length; i++) {
      nextTop +=
          _fittedPageHeight(pages[i], screenWidth) + Editor.gapBetweenPages;
      if (scrollY < nextTop) return i;
    }

    return pages.length - 1;
  }
}

class CanvasGestureDetectorState extends State<CanvasGestureDetector> {
  late var containerBounds = const BoxConstraints();
  late bool _singlePageMode = widget.initialSinglePageMode;
  String? _singlePageId;
  int? _singlePageFallback;
  var _allowContinuousTopInset = false;
  final _motionReset = ValueNotifier(0);

  bool get singlePageMode => _singlePageMode;

  int? get singlePageIndex {
    final pages = widget.pages;
    if (!_singlePageMode || pages.isEmpty) return null;
    final index = pages.indexWhere((page) => page.pageId == _singlePageId);
    return index >= 0
        ? index
        : (_singlePageFallback ?? widget.initialPageIndex ?? 0).clamp(
            0,
            pages.length - 1,
          );
  }

  Size? get _viewportSize {
    final size = containerBounds.biggest;
    return size.isFinite && !size.isEmpty ? size : null;
  }

  void _selectSinglePage(int index) {
    _singlePageId = widget.pages[index].pageId;
    _singlePageFallback = index;
  }

  Rect _pageRect(int index, double width, {required bool single}) {
    final page = widget.pages[index];
    final fittedWidth = min(page.size.width, width);
    final top = single
        ? CanvasGestureDetector._pageTopInset
        : CanvasGestureDetector.getTopOfPage(
            pageIndex: index,
            pages: widget.pages,
            screenWidth: width,
          );
    return Rect.fromLTWH(
      (width - fittedWidth) / 2,
      top,
      fittedWidth,
      CanvasGestureDetector._fittedPageHeight(page, width),
    );
  }

  Offset _pageAnchor(Rect rect, Size viewport) {
    final point = widget._transformationController.toScene(
      viewport.center(Offset.zero),
    );
    return Offset(
      point.dx >= rect.left && point.dx < rect.right
          ? (point.dx - rect.left) / rect.width
          : 0.5,
      point.dy >= rect.top && point.dy < rect.bottom
          ? (point.dy - rect.top) / rect.height
          : 0.5,
    );
  }

  Matrix4 _centerPage(Rect rect, Size viewport, Offset anchor) {
    final scale = widget._transformationController.value.approxScale;
    return Matrix4.diagonal3Values(scale, scale, 1)..setTranslationRaw(
      viewport.width / 2 - (rect.left + rect.width * anchor.dx) * scale,
      viewport.height / 2 - (rect.top + rect.height * anchor.dy) * scale,
      0,
    );
  }

  bool setSinglePageMode(bool enabled) {
    if (enabled == _singlePageMode) return true;
    final viewport = _viewportSize;
    if (viewport == null || widget.pages.isEmpty || _hasActiveContacts) {
      return false;
    }
    final index =
        singlePageIndex ??
        CanvasGestureDetector.getPageIndex(
          scrollY: widget._transformationController
              .toScene(viewport.center(Offset.zero))
              .dy,
          pages: widget.pages,
          screenWidth: viewport.width,
        );
    final anchor = _pageAnchor(
      _pageRect(index, viewport.width, single: _singlePageMode),
      viewport,
    );
    final target = _pageRect(index, viewport.width, single: enabled);
    setState(() {
      _singlePageMode = enabled;
      _selectSinglePage(index);
    });
    _setProgrammaticTransform(
      _centerPage(target, viewport, anchor),
      // At the same zoom a short first page may need extra space above it.
      allowContinuousTopInset: !enabled,
    );
    return true;
  }

  /// If zooming is locked, this is the zoom level.
  /// Otherwise, this is null.
  late double? zoomLockedValue = stows.lastZoomLock.value
      ? widget._transformationController.value.approxScale
      : null;

  /// Whether single-finger panning is locked.
  /// Two-finger panning is always enabled.
  late bool singleFingerPanLock = stows.lastSingleFingerPanLock.value;

  /// Whether panning is locked to being horizontal or vertical.
  /// Otherwise, panning can be done in any (i.e. diagonal) direction.
  late bool axisAlignedPanLock = stows.lastAxisAlignedPanLock.value;

  void zoomIn() => widget._transformationController.value =
      setZoom(
        scaleDelta: 0.1,
        transformation: widget._transformationController.value,
        containerBounds: containerBounds,
      ) ??
      widget._transformationController.value;
  void zoomOut() => widget._transformationController.value =
      setZoom(
        scaleDelta: -0.1,
        transformation: widget._transformationController.value,
        containerBounds: containerBounds,
      ) ??
      widget._transformationController.value;
  @visibleForTesting
  static Matrix4? setZoom({
    required double scaleDelta,
    required Matrix4 transformation,
    required BoxConstraints containerBounds,
  }) {
    final oldScale = transformation.approxScale;
    final newScale = oldScale + scaleDelta;

    if (newScale < CanvasGestureDetector.kMinScale) return null;
    if (newScale > CanvasGestureDetector.kMaxScale) return null;

    final center = Vector3(
      containerBounds.maxWidth / 2,
      containerBounds.maxHeight / 2,
      0,
    );
    final translation =
        (transformation.getTranslation() - center) * (newScale / oldScale) +
        center;

    return Matrix4.translation(translation)
      ..scaleByDouble(newScale, newScale, newScale, 1);
  }

  final Map<AxisDirection, Timer> _arrowKeyPanTimers = {};
  void arrowKeyPan(AxisDirection direction, bool pressed) {
    _arrowKeyPanTimers.remove(direction)?.cancel();
    if (!pressed) return;

    // arrow keys are used to navigate around text
    if (widget.isTextEditing()) return;

    _arrowKeyPanNow(direction);

    // Wait for 200ms, then pan every 100ms
    const ms100 = Duration(milliseconds: 100);
    const ms200 = Duration(milliseconds: 200);
    _arrowKeyPanTimers[direction] = Timer(ms200, () {
      _arrowKeyPanTimers[direction] = Timer.periodic(ms100, (_) {
        _arrowKeyPanNow(direction);
      });
    });
  }

  void _arrowKeyPanNow(AxisDirection direction) {
    final transformation = widget._transformationController.value;
    const panAmount = 50.0;

    transformation.leftTranslateByDouble(
      switch (direction) {
        AxisDirection.left => panAmount,
        AxisDirection.right => -panAmount,
        AxisDirection.up => 0.0,
        AxisDirection.down => 0.0,
      },
      switch (direction) {
        AxisDirection.left => 0.0,
        AxisDirection.right => 0.0,
        AxisDirection.up => panAmount,
        AxisDirection.down => -panAmount,
      },
      0,
      1,
    );
    widget._transformationController.notifyListenersPlease();
  }

  var _setupKeybindings = false;
  late Keybinding _ctrlPlus, _ctrlEquals, _ctrlMinus;
  late Keybinding _leftKey, _rightKey, _upKey, _downKey;
  void _assignKeybindings() {
    _ctrlPlus = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.add),
    ], inclusive: true);
    _ctrlEquals = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.equal),
    ], inclusive: true);
    _ctrlMinus = Keybinding([
      KeyCode.ctrl,
      KeyCode.from(LogicalKeyboardKey.minus),
    ], inclusive: true);
    Keybinder.bind(_ctrlPlus, zoomIn);
    Keybinder.bind(_ctrlEquals, zoomIn);
    Keybinder.bind(_ctrlMinus, zoomOut);

    _leftKey = Keybinding([
      KeyCode.from(LogicalKeyboardKey.arrowLeft),
    ], inclusive: true);
    _rightKey = Keybinding([
      KeyCode.from(LogicalKeyboardKey.arrowRight),
    ], inclusive: true);
    _upKey = Keybinding([
      KeyCode.from(LogicalKeyboardKey.arrowUp),
    ], inclusive: true);
    _downKey = Keybinding([
      KeyCode.from(LogicalKeyboardKey.arrowDown),
    ], inclusive: true);
    Keybinder.bind(
      _leftKey,
      (bool pressed) => arrowKeyPan(AxisDirection.left, pressed),
    );
    Keybinder.bind(
      _rightKey,
      (bool pressed) => arrowKeyPan(AxisDirection.right, pressed),
    );
    Keybinder.bind(
      _upKey,
      (bool pressed) => arrowKeyPan(AxisDirection.up, pressed),
    );
    Keybinder.bind(
      _downKey,
      (bool pressed) => arrowKeyPan(AxisDirection.down, pressed),
    );

    _setupKeybindings = true;
  }

  void _removeKeybindings() {
    if (!_setupKeybindings) return;
    _setupKeybindings = false;

    Keybinder.remove(_ctrlPlus);
    Keybinder.remove(_ctrlEquals);
    Keybinder.remove(_ctrlMinus);

    Keybinder.remove(_leftKey);
    Keybinder.remove(_rightKey);
    Keybinder.remove(_upKey);
    Keybinder.remove(_downKey);
    _arrowKeyPanTimers.forEach((_, timer) => timer.cancel());
  }

  @override
  void initState() {
    widget._transformationController.addListener(onTransformChanged);
    _assignKeybindings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setInitialTransform();
    });
    super.initState();
  }

  /// When the widget is created, we still have an empty coreInfo.
  /// Wait for note to be loaded before setting the initial transform.
  @override
  void didUpdateWidget(CanvasGestureDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filePath != widget.filePath &&
        !widget.pages.any((page) => page.pageId == _singlePageId)) {
      _singlePageId = null;
      _singlePageFallback = null;
    } else if (singlePageIndex case final index?) {
      final previousId = _singlePageId;
      _selectSinglePage(index);
      if (previousId != null && previousId != _singlePageId) {
        final selected = _singlePageId;
        final path = widget.filePath;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              widget.filePath == path &&
              _singlePageId == selected &&
              singlePageIndex != null) {
            scrollToPage(singlePageIndex!);
          }
        });
      }
    }
    if (oldWidget.initialPageIndex != widget.initialPageIndex ||
        oldWidget.filePath != widget.filePath) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setInitialTransform();
      });
    }
  }

  /// Sets the initial transform so that we're scrolled to the correct page.
  /// Has no effect if note hasn't yet loaded or if the user has already scrolled.
  void setInitialTransform() {
    // wait for note to be loaded
    if (widget.filePath.isEmpty) return;

    // don't override user's scroll
    if (!widget._transformationController.value.isIdentity()) return;

    final transformCacheItem = CanvasTransformCache.get(widget.filePath);

    if (_singlePageMode) {
      final cachedId = transformCacheItem?.singlePageId;
      final cachedIndex = widget.pages.indexWhere(
        (page) => page.pageId == cachedId,
      );
      if (transformCacheItem != null &&
          cachedIndex >= 0 &&
          (widget.initialPageIndex == null ||
              widget.initialPageIndex == cachedIndex)) {
        setState(() => _selectSinglePage(cachedIndex));
        _setProgrammaticTransform(transformCacheItem.transform.clone());
        if (zoomLockedValue != null) {
          zoomLockedValue = transformCacheItem.transform.approxScale;
        }
      } else if (singlePageIndex case final index?) {
        scrollToPage(index);
      }
    } else if (transformCacheItem != null &&
        transformCacheItem.singlePageId == null) {
      // if we're opening the same note, restore the last transform
      _setProgrammaticTransform(
        transformCacheItem.transform.clone(),
        allowContinuousTopInset: true,
      );
      if (zoomLockedValue != null) {
        zoomLockedValue = transformCacheItem.transform.approxScale;
      }
    } else if (widget.initialPageIndex != null) {
      // if we're opening a different note, scroll to the last recorded page
      scrollToPage(widget.initialPageIndex!);
    }
  }

  Timer? _snapZoomTimer;

  bool scrollToPage(int pageIndex) {
    final viewport = _viewportSize;
    final pages = widget.pages;
    if (viewport == null || pages.isEmpty) return false;

    final index = pageIndex.clamp(0, pages.length - 1);
    if (_singlePageMode) {
      if (_hasActiveContacts) return false;
      final previous = singlePageIndex;
      if (previous != null && previous != index) {
        pages[previous].quill.focusNode.unfocus();
      }
      setState(() => _selectSinglePage(index));
      _setProgrammaticTransform(
        _centerPage(
          _pageRect(index, viewport.width, single: true),
          viewport,
          const Offset(0.5, 0.5),
        ),
      );
      return true;
    }

    final width = viewport.width;
    final height = viewport.height;
    final top = CanvasGestureDetector.getTopOfPage(
      pageIndex: index,
      pages: pages,
      screenWidth: width,
    );
    final pageHeight = CanvasGestureDetector._fittedPageHeight(
      pages[index],
      width,
    );
    final center = top + pageHeight / 2;
    // Zoom when a short page is too high to center at 1x without overscroll.
    final scale = (height / (2 * center))
        .clamp(1.0, CanvasGestureDetector.kMaxScale)
        .toDouble();
    final translationY = min(0.0, height / 2 - center * scale);
    final visibleCenter = (height / 2 - translationY) / scale;
    if (!(visibleCenter >= top && visibleCenter < top + pageHeight)) {
      return false;
    }

    _setProgrammaticTransform(
      Matrix4.diagonal3Values(scale, scale, 1)
        ..setTranslationRaw(width * (1 - scale) / 2, translationY, 0),
    );
    return true;
  }

  void _setProgrammaticTransform(
    Matrix4 transform, {
    bool allowContinuousTopInset = false,
  }) {
    _motionReset.value++;
    _allowContinuousTopInset = allowContinuousTopInset;
    try {
      widget._transformationController.value = transform;
    } finally {
      _allowContinuousTopInset = false;
    }
    // Retain an intentional zoom that is needed to keep a short page centered.
    _snapZoomTimer?.cancel();
  }

  /// Corrects the transform if it's out of bounds.
  /// If the scale is less than 1, centers the pages horizontally.
  /// Otherwise, prevents the user from scrolling past the edges.
  void onTransformChanged() {
    final scale = widget._transformationController.value.approxScale;
    final translation = widget._transformationController.value.getTranslation();

    double adjustmentX = 0;
    double adjustmentY = 0;

    // snap to 1.0x zoom
    _snapZoomTimer?.cancel();
    final diffFrom1 = (scale - 1).abs();
    // allow 0.001 leeway for floating point error
    if (diffFrom1 < 0.05 && diffFrom1 > 0.001)
      _snapZoomTimer = Timer(const Duration(milliseconds: 200), resetZoom);

    final viewport = _viewportSize;
    final index = singlePageIndex;
    if (index != null && viewport != null) {
      final rect = _pageRect(index, viewport.width, single: true);
      double constrain(double value, double start, double end, double extent) {
        final leading = -start * scale;
        final trailing = extent - end * scale;
        return value
            .clamp(min(leading, trailing), max(leading, trailing))
            .toDouble();
      }

      adjustmentX =
          constrain(translation.x, rect.left, rect.right, viewport.width) -
          translation.x;
      adjustmentY =
          constrain(translation.y, rect.top, rect.bottom, viewport.height) -
          translation.y;
    } else if (scale < 1) {
      // horizontally center pages if zoomed out
      final center = containerBounds.maxWidth * (1 - scale) / 2;
      adjustmentX = center - translation.x;
    } else {
      // if zoomed in, don't allow scrolling past the edges
      late final minX = containerBounds.maxWidth * (1 - scale);
      if (translation.x > 0) {
        adjustmentX = -translation.x;
      } else if (translation.x < minX) {
        adjustmentX = minX - translation.x;
      }

      if (translation.y > 0 && !_allowContinuousTopInset) {
        adjustmentY = -translation.y;
      }
    }

    if (adjustmentX.abs() > 0.1 || adjustmentY.abs() > 0.1) {
      widget._transformationController.value.leftTranslateByDouble(
        adjustmentX,
        adjustmentY,
        0,
        1,
      );
    }
  }

  /// Resets the zoom level to 1.0x
  void resetZoom() {
    final transformation = widget._transformationController.value;
    final scale = transformation.approxScale;
    if (scale == 1) return;

    widget._transformationController.value =
        setZoom(
          scaleDelta: 1 - scale,
          transformation: transformation,
          containerBounds: containerBounds,
        ) ??
        transformation;
  }

  final _pointerContacts = <int>{};
  int? _stylusPointer;
  var _panZoomActive = false;

  bool get _hasActiveContacts => _pointerContacts.isNotEmpty || _panZoomActive;

  bool _isStylus(PointerEvent event) =>
      event.kind == PointerDeviceKind.stylus ||
      event.kind == PointerDeviceKind.invertedStylus;

  bool _ignorePointer(PointerEvent event) =>
      _stylusPointer != null && _stylusPointer != event.pointer;

  void _listenerPointerDownEvent(PointerDownEvent event) {
    if (_ignorePointer(event)) return;
    if (_isStylus(event)) {
      _stylusPointer = event.pointer;
      _pointerContacts.clear();
    }
    _pointerContacts.add(event.pointer);
    _listenerPointerEvent(event);
  }

  void _listenerPointerEvent(PointerEvent event) {
    if (!_pointerContacts.contains(event.pointer)) return;
    final isStylus = _isStylus(event);
    if (isStylus && event is PointerDownEvent) {
      _detectStylusButton(event);
    }

    final double? pressure;
    if (isStylus) {
      if (event.pressureMin != event.pressureMax) {
        pressure = _inverseLerp(
          event.pressure,
          min: event.pressureMin,
          max: event.pressureMax,
        );
      } else {
        // Detected as stylus, but no pressure values
        pressure = null;
      }
    } else {
      pressure = null;
    }
    widget.updatePointerData(event.kind, pressure);

    if (isStylus &&
        stows.autoDisableFingerDrawingWhenStylusDetected.value &&
        // Don't change if the user has a fixed value for finger drawing
        !stows.hideFingerDrawingToggle.value) {
      stows.editorFingerDrawing.value = false;
    }
  }

  var stylusButtonWasPressed = false;

  void _listenerPointerHoverEvent(PointerEvent event) {
    if (!_isStylus(event) || _ignorePointer(event)) return;

    // Apparently flutter synthesizes a hover event on pointer down,
    // so these are used to detect when hovering ends
    if (event.synthesized) {
      widget.onHoveringEnd();
    } else {
      widget.onHovering();
    }

    _detectStylusButton(event);
  }

  void _detectStylusButton(PointerEvent event) {
    final pressed =
        event.buttons == kSecondaryButton || event.kind == .invertedStylus;
    if (stylusButtonWasPressed != pressed) {
      stylusButtonWasPressed = pressed;
      widget.onStylusButtonChanged(pressed);
    }
  }

  void _listenerPointerUpEvent(PointerEvent event) {
    if (!_pointerContacts.remove(event.pointer)) return;
    if (_stylusPointer == event.pointer) _stylusPointer = null;
    widget.updatePointerData(event.kind, null);
    if (_isStylus(event) && stylusButtonWasPressed) {
      stylusButtonWasPressed = false;
      widget.onStylusButtonChanged(false);
    }
  }

  void _updateBounds(BoxConstraints bounds) {
    if (containerBounds == bounds) return;
    final previous = _viewportSize;
    containerBounds = bounds;
    final viewport = _viewportSize;
    final index = singlePageIndex;
    final selected = _singlePageId;
    if (previous == null ||
        viewport == null ||
        index == null ||
        selected == null) {
      return;
    }
    final anchor = _pageAnchor(
      _pageRect(index, previous.width, single: true),
      previous,
    );
    final before = widget._transformationController.value.clone();
    final path = widget.filePath;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = singlePageIndex;
      if (current == null ||
          selected != _singlePageId ||
          widget.filePath != path ||
          _viewportSize != viewport ||
          _hasActiveContacts ||
          widget._transformationController.value != before) {
        return;
      }
      _setProgrammaticTransform(
        _centerPage(
          _pageRect(current, viewport.width, single: true),
          viewport,
          anchor,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.sizeOf(context);
    final selected = singlePageIndex;

    return Stack(
      children: [
        Listener(
          onPointerDown: _listenerPointerDownEvent,
          onPointerMove: _listenerPointerEvent,
          onPointerUp: _listenerPointerUpEvent,
          onPointerCancel: _listenerPointerUpEvent,
          onPointerHover: _listenerPointerHoverEvent,
          onPointerPanZoomStart: (_) => _panZoomActive = true,
          onPointerPanZoomEnd: (_) => _panZoomActive = false,
          child: GestureDetector(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints containerBounds) {
                _updateBounds(containerBounds);

                return InteractiveCanvasViewer.builder(
                  minScale: zoomLockedValue ?? CanvasGestureDetector.kMinScale,
                  maxScale: zoomLockedValue ?? CanvasGestureDetector.kMaxScale,
                  panEnabled: !singleFingerPanLock,
                  panAxis: axisAlignedPanLock ? PanAxis.aligned : PanAxis.free,

                  // Smoother scrolling fling gesture than the default
                  interactionEndFrictionCoefficient: 0.1,

                  // we need a non-zero boundary margin so we can zoom out
                  // past the size of the page (for minScale < 1)
                  boundaryMargin: _singlePageMode
                      ? const EdgeInsets.all(double.infinity)
                      : .symmetric(horizontal: screenSize.width * 2),

                  transformationController: widget._transformationController,
                  resetMotion: _motionReset,

                  isDrawGesture: widget.isDrawGesture,
                  onInteractionEnd: widget.onInteractionEnd,
                  onDrawStart: widget.onDrawStart,
                  onDrawUpdate: widget.onDrawUpdate,
                  onDrawEnd: widget.onDrawEnd,
                  ignorePointer: _ignorePointer,

                  builder: (BuildContext context, Quad viewport) {
                    return _PagesBuilder(
                      pages: widget.pages,
                      pageBuilder: widget.pageBuilder,
                      placeholderPageBuilder: widget.placeholderPageBuilder,
                      boundingBox: _axisAlignedBoundingBox(viewport),
                      containerWidth: containerBounds.maxWidth,
                      singlePageIndex: selected,
                    );
                  },
                );
              },
            ),
          ),
        ),
        Positioned.fill(
          child: CanvasHud(
            transformationController: widget._transformationController,
            zoomLock: zoomLockedValue != null,
            setZoomLock: (bool zoomLock) => setState(() {
              zoomLockedValue = zoomLock
                  ? widget._transformationController.value.approxScale
                  : null;
              stows.lastZoomLock.value = zoomLock;
            }),
            resetZoom: zoomLockedValue != null ? null : resetZoom,
            singleFingerPanLock: singleFingerPanLock,
            setSingleFingerPanLock: (bool singleFingerPanLock) => setState(() {
              this.singleFingerPanLock = singleFingerPanLock;
              stows.lastSingleFingerPanLock.value = singleFingerPanLock;
            }),
            axisAlignedPanLock: axisAlignedPanLock,
            setAxisAlignedPanLock: (bool axisAlignedPanLock) => setState(() {
              this.axisAlignedPanLock = axisAlignedPanLock;
              stows.lastAxisAlignedPanLock.value = axisAlignedPanLock;
            }),
          ),
        ),
        if (selected != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: SafeArea(
              top: false,
              child: Center(
                child: Material(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(24),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: '이전 쪽',
                        onPressed: selected > 0
                            ? () => scrollToPage(selected - 1)
                            : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text('${selected + 1} / ${widget.pages.length}'),
                      IconButton(
                        tooltip: '다음 쪽',
                        onPressed: selected + 1 < widget.pages.length
                            ? () => scrollToPage(selected + 1)
                            : null,
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _snapZoomTimer?.cancel();
    final selected = singlePageIndex;
    CanvasTransformCache.add(
      widget.filePath,
      widget._transformationController.value,
      singlePageId: selected == null ? null : widget.pages[selected].pageId,
    );
    widget._transformationController.removeListener(onTransformChanged);
    widget._transformationController.dispose();
    _motionReset.dispose();
    _removeKeybindings();
    super.dispose();
  }

  /// Returns the axis aligned bounding box for the given Quad,
  /// which might not be axis aligned.
  /// From https://api.flutter.dev/flutter/widgets/InteractiveViewer/builder.html
  static Rect _axisAlignedBoundingBox(Quad quad) {
    final List<Vector3> points = [
      quad.point0,
      quad.point1,
      quad.point2,
      quad.point3,
    ];

    final left = points.map((point) => point.x).reduce(min);
    final right = points.map((point) => point.x).reduce(max);
    final top = points.map((point) => point.y).reduce(min);
    final bottom = points.map((point) => point.y).reduce(max);

    return .fromLTRB(left, top, right, bottom);
  }
}

class _PagesBuilder extends StatelessWidget {
  const new({
    required this.pages,
    required this.pageBuilder,
    required this.placeholderPageBuilder,
    required this.boundingBox,
    required this.containerWidth,
    required this.singlePageIndex,
  });

  final List<EditorPage> pages;
  final Widget Function(BuildContext context, int pageIndex) pageBuilder;
  final Widget Function(BuildContext context, int pageIndex)
  placeholderPageBuilder;
  final Rect boundingBox;
  final double containerWidth;
  final int? singlePageIndex;

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = [
      SizedBox(
        width: singlePageIndex == null
            ? Editor.gapBetweenPages
            : containerWidth,
        height: CanvasGestureDetector._pageTopInset,
      ),
    ];

    double topOfPage = CanvasGestureDetector._pageTopInset;
    for (int pageIndex = 0; pageIndex < pages.length; pageIndex++) {
      final page = pages[pageIndex];
      if (singlePageIndex != null && pageIndex != singlePageIndex) {
        page.isRendered = false;
        continue;
      }
      final pageHeight = CanvasGestureDetector._fittedPageHeight(
        page,
        containerWidth,
      );
      final bottomOfPage = topOfPage + pageHeight;

      final isFocused = page.quill.focusNode.hasFocus;
      final isInViewport =
          boundingBox.bottom >= topOfPage && boundingBox.top <= bottomOfPage;
      final shouldRender = singlePageIndex != null || isFocused || isInViewport;

      page.isRendered = shouldRender;
      children.add(
        KeyedSubtree(
          key: ObjectKey(page),
          child: shouldRender
              ? pageBuilder(context, pageIndex)
              : placeholderPageBuilder(context, pageIndex),
        ),
      );

      children.add(const SizedBox.square(dimension: Editor.gapBetweenPages));

      topOfPage = bottomOfPage + Editor.gapBetweenPages;
    }

    children.add(const SizedBox.square(dimension: Editor.gapBetweenPages));
    return Column(children: children);
  }
}

@visibleForTesting
class CanvasTransformCache {
  static const _maxCacheSize = 5;
  static final _cache = LinkedList<CanvasTransformCacheItem>();

  new _();

  static void add(String filePath, Matrix4 transform, {String? singlePageId}) {
    for (final entry in _cache) {
      if (entry.filePath != filePath) continue;
      entry.unlink();
      break;
    }
    _cache.add(
      CanvasTransformCacheItem(filePath, transform, singlePageId: singlePageId),
    );

    if (_cache.length > _maxCacheSize) {
      _cache.first.unlink();
    }
  }

  static CanvasTransformCacheItem? get(String filePath) {
    try {
      return _cache.firstWhere((item) => item.filePath == filePath);
    } on StateError {
      return null;
    }
  }

  @visibleForTesting
  static void clear() {
    _cache.clear();
  }
}

@visibleForTesting
base class CanvasTransformCacheItem
    extends LinkedListEntry<CanvasTransformCacheItem> {
  final String filePath;
  final Matrix4 transform;
  final String? singlePageId;

  new(this.filePath, this.transform, {this.singlePageId});
}

double _inverseLerp(num value, {required num min, required num max}) {
  assert(max >= min, 'Max ($max) must be >= min ($min)');
  assert(
    value >= min && value <= max,
    'Value ($value) must be between $min and $max',
  );
  return (value - min) / (max - min);
}
