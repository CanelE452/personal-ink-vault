import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:perfect_freehand/perfect_freehand.dart' show StrokeOptions;
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/editor_toolbar/toolbar_tools_layout.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/ink_ui/host_focus.dart';
import 'package:saber/components/ink_ui/hover_badge.dart';
import 'package:saber/components/ink_ui/ink_engine_support.dart';
import 'package:saber/components/ink_ui/kit_mode_pill.dart';
import 'package:saber/components/ink_ui/kit_zoom_badge.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/eraser_targets.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:sbn/tool_id.dart';

part 'infinite_ink_adapter.dart';

enum _Tool { pen, highlighter, eraser, lasso, pan }

class InfiniteCanvas extends StatefulWidget {
  final InfiniteDocument initialDocument;
  final Future<void> Function(InfiniteDocument) onSave;
  final InfiniteViewport initialViewport;
  final Future<void> Function(InfiniteViewport)? onSaveViewport;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<bool>? onBusyChanged;
  final Duration autosaveDelay;
  const new({
    super.key,
    required this.initialDocument,
    required this.onSave,
    this.initialViewport = const InfiniteViewport(),
    this.onSaveViewport,
    this.onDirtyChanged,
    this.onBusyChanged,
    this.autosaveDelay = const Duration(milliseconds: 700),
  });
  @override
  State<InfiniteCanvas> createState() => InfiniteCanvasState();
}

/// The infinite note (Task 18): the editor's toolbar with the tools its
/// engine has (펜 · 지우개 · 올가미 · 이동, and 원점으로 · 저장 at the end),
/// the floating bar and its windows for the pen, the highlighter and the
/// eraser ([_InkAdapter]), the pen tip badge, the mode pill and the zoom
/// badge over the page.
class InfiniteCanvasState extends State<InfiniteCanvas> {
  static const _teal = Color(0xff237d82);

  /// The pen widths, the floating bar's three among them; the highlighter's
  /// are [_highlighterScale] times as wide.
  static const _quickWidths = [1.0, 2.5, 5.0];
  static const _minWidth = 1.0;
  static const _maxWidth = 8.0;
  static const _highlighterScale = 5.0;
  late InfiniteDocument _document;
  var _view = const InfiniteViewport();

  /// The view scale for the zoom pill; it notifies only when the scale changes.
  final _zoomScale = ValueNotifier<double>(1);
  Size _surfaceSize = Size.zero;

  InfiniteViewport get _viewport => _view;
  set _viewport(InfiniteViewport value) {
    _view = value;
    _zoomScale.value = value.scale;
  }

  final _undo = <InfiniteDocument>[];
  final _redo = <InfiniteDocument>[];
  final _contacts = <int, PointerEvent>{};
  final _selected = <String>{};
  final _erased = <String>{};
  final _points = <InfinitePoint>[];
  final _lasso = <Offset>[];
  _Tool _tool = _Tool.pen;

  /// The pen or the highlighter last in hand, and the last tool that is not
  /// the eraser (its 「자동 해제」 goes back to it).
  _Tool _lastInk = _Tool.pen;
  _Tool _lastNonEraser = _Tool.pen;
  _Tool? _activeTool;

  /// The colour of new strokes: the floating bar's first dot at first
  /// (ledger ruling, Task 18), so that dot is ringed. It and the pen's
  /// [_width] are heard by the floating bar alone: changing them builds and
  /// paints nothing else.
  late final ValueNotifier<int> _color;
  final _width = ValueNotifier(2.5);
  var _activeWidth = 2.5;
  int? _activePointer;
  int? _panPointer;
  var _stylusDown = false;
  DateTime? _lastStylus;
  Offset? _selectionStart;
  Offset _selectionDelta = Offset.zero;
  InfiniteViewport? _touchStartViewport;
  Offset? _touchStartFocal;
  double _touchStartDistance = 1;
  var _generation = 0;
  var _savedGeneration = 0;
  var _lastDirty = false;
  var _lastBusy = false;
  var _saving = false;
  var _saveFailed = false;
  Timer? _autosave;
  Completer<void>? _interactionDone;
  Future<void>? _saveFuture;

  final _actions = AppActionRegistry();
  late final _ink = _InkAdapter(this);
  final _floatingBarOpen = ValueNotifier(true);
  final _floatingBarFrom = ValueNotifier<double?>(null);
  final _hoverBadge = HoverBadgeController();
  final _focus = FocusNode(debugLabel: 'Infinite note');

  /// The tip of the stroke on the page now, on the screen: the floating bar
  /// fades out of its way.
  final _strokeAt = ValueNotifier<Offset?>(null);

  /// Whether fingers are on the page, for the zoom badge.
  final _touching = ValueNotifier(false);

  InfiniteDocument get document => _document;
  InfiniteViewport get viewport => _viewport;
  bool get _interacting => _activePointer != null;
  bool get _dirty => _generation != _savedGeneration;

  @override
  void initState() {
    super.initState();
    _document = widget.initialDocument;
    _viewport = widget.initialViewport;
    _color = ValueNotifier(floatingBarDotColours().first.toARGB32());
    stows.editorGestureMode.addListener(_gestureModeChanged);
    stows.editorFingerDrawing.addListener(_sharedSettingChanged);
    stows.lastZoomLock.addListener(_sharedSettingChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) takeFocusFromHost(_focus);
    });
  }

  /// Gesture mode on: the pen tip badge forgets where the pen was.
  void _gestureModeChanged() {
    if (stows.editorGestureMode.value) _hoverBadge.value = null;
  }

  /// 손가락 필기 and 확대 잠금 are the editor's settings: the actions and
  /// the zoom badge show them again.
  void _sharedSettingChanged() {
    if (mounted) setState(() {});
  }

  void _notifyState() {
    final busy = _interacting || _saving;
    if (_lastBusy != busy) {
      _lastBusy = busy;
      widget.onBusyChanged?.call(busy);
    }
    if (_lastDirty != _dirty) {
      _lastDirty = _dirty;
      widget.onDirtyChanged?.call(_dirty);
    }
  }

  void _scheduleSave() {
    _autosave?.cancel();
    _autosave = Timer(widget.autosaveDelay, () {
      if (mounted) unawaited(_saveFromUi());
    });
  }

  void _commit(InfiniteDocument next) {
    _undo.add(_document);
    _redo.clear();
    _document = next;
    _generation++;
    _notifyState();
    _scheduleSave();
  }

  void _undoOrRedo({required bool redo}) {
    if (_interacting) return;
    final source = redo ? _redo : _undo;
    if (source.isEmpty) return;
    setState(() {
      (redo ? _undo : _redo).add(_document);
      _document = source.removeLast();
      _selected.clear();
      _generation++;
      _notifyState();
      _scheduleSave();
    });
  }

  Future<void> save() {
    _autosave?.cancel();
    final existing = _saveFuture;
    if (existing != null) return existing;
    final saving = _saveCurrent();
    _saveFuture = saving;
    saving.then(
      (_) {
        if (identical(_saveFuture, saving)) _saveFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_saveFuture, saving)) _saveFuture = null;
      },
    );
    return saving;
  }

  Future<void> _saveCurrent() async {
    _saving = true;
    _notifyState();
    if (mounted) setState(() {});
    try {
      while (true) {
        await _interactionDone?.future;
        if (!_dirty) break;
        final generation = _generation;
        await widget.onSave(_document);
        _savedGeneration = generation;
        _saveFailed = false;
        _notifyState();
      }
      await widget.onSaveViewport?.call(_viewport);
    } catch (_) {
      _saveFailed = true;
      rethrow;
    } finally {
      _saving = false;
      if (mounted) {
        _notifyState();
        setState(() {});
      }
    }
  }

  Future<void> _saveFromUi() async {
    try {
      await save();
    } catch (_) {
      // The dirty document and retry action stay visible.
    }
  }

  bool _isStylus(PointerEvent event) =>
      event.kind == PointerDeviceKind.stylus ||
      event.kind == PointerDeviceKind.invertedStylus;

  InfinitePoint _point(PointerEvent event) {
    final world = _viewport.screenToWorld(event.localPosition);
    final range = event.pressureMax - event.pressureMin;
    final pressure = range > 0
        ? ((event.pressure - event.pressureMin) / range)
              .clamp(0.0, 1.0)
              .toDouble()
        : 1.0;
    return InfinitePoint(world.dx, world.dy, pressure: pressure);
  }

  void _down(PointerDownEvent event) {
    final stylus = _isStylus(event);
    // gesture mode: pens and fingers move the view and draw nothing
    final gesture = stows.editorGestureMode.value;
    if (event.kind == PointerDeviceKind.touch &&
        (_stylusDown ||
            (_lastStylus != null &&
                DateTime.now().difference(_lastStylus!) <
                    const Duration(milliseconds: 300))))
      return;
    if (stylus) {
      if (_activePointer != null &&
          _contacts[_activePointer]?.kind == PointerDeviceKind.touch) {
        setState(() => _finish(cancel: true));
      }
      _stylusDown = true;
      _lastStylus = DateTime.now();
      _contacts.removeWhere(
        (_, contact) => contact.kind == PointerDeviceKind.touch,
      );
    }
    _contacts[event.pointer] = event;
    _touching.value = _touches.isNotEmpty;
    if (event.kind == PointerDeviceKind.touch) {
      final touches = _touches;
      if (touches.length > 1 ||
          !stows.editorFingerDrawing.value ||
          _tool == _Tool.pan ||
          gesture) {
        if (_activePointer != null &&
            _contacts[_activePointer]?.kind == PointerDeviceKind.touch)
          _finish(cancel: true);
        _resetTouch();
        return;
      }
    }
    if (_activePointer != null) return;
    if (_tool == _Tool.pan ||
        gesture ||
        (event.kind == PointerDeviceKind.mouse &&
            event.buttons & (kMiddleMouseButton | kSecondaryMouseButton) !=
                0)) {
      _panPointer = event.pointer;
      return;
    }
    setState(() {
      _activePointer = event.pointer;
      final activeTool = event.kind == PointerDeviceKind.invertedStylus
          ? _Tool.eraser
          : _tool;
      _activeTool = activeTool;
      _activeWidth = _width.value * _widthScale(activeTool);
      _interactionDone = Completer<void>();
      _points.clear();
      _lasso.clear();
      _erased.clear();
      _selectionStart = null;
      _selectionDelta = Offset.zero;
      _strokeAt.value = event.position;
      final world = _viewport.screenToWorld(event.localPosition);
      if (_activeTool == _Tool.lasso) {
        if (_selectionBounds?.inflate(12 / _viewport.scale).contains(world) ??
            false) {
          _selectionStart = world;
        } else {
          _selected.clear();
          _lasso.add(world);
        }
      } else if (_activeTool == _Tool.eraser) {
        _eraseAt(world);
      } else {
        _selected.clear();
        _points.add(_point(event));
      }
      _notifyState();
    });
  }

  List<PointerEvent> get _touches => _contacts.values
      .where((contact) => contact.kind == PointerDeviceKind.touch)
      .take(2)
      .toList();

  Offset _focal(List<PointerEvent> touches) => touches.length == 1
      ? touches.first.localPosition
      : (touches[0].localPosition + touches[1].localPosition) / 2;

  void _resetTouch() {
    final touches = _touches;
    _touchStartViewport = touches.isEmpty ? null : _viewport;
    _touchStartFocal = touches.isEmpty ? null : _focal(touches);
    _touchStartDistance = touches.length < 2
        ? 1
        : math.max(
            1,
            (touches[0].localPosition - touches[1].localPosition).distance,
          );
  }

  void _move(PointerMoveEvent event) {
    if (!_contacts.containsKey(event.pointer)) return;
    _contacts[event.pointer] = event;
    if (_isStylus(event)) _lastStylus = DateTime.now();
    if (_panPointer == event.pointer) {
      setState(() => _viewport = _viewport.pan(event.localDelta));
      return;
    }
    if (_activePointer == event.pointer) {
      _strokeAt.value = event.position;
      setState(() {
        final world = _viewport.screenToWorld(event.localPosition);
        if (_activeTool == _Tool.lasso) {
          if (_selectionStart != null)
            _selectionDelta = world - _selectionStart!;
          else if (stows.selectRectangle.value)
            _lassoBox(world);
          else
            _lasso.add(world);
        } else if (_activeTool == _Tool.eraser) {
          _eraseAt(world);
        } else {
          _points.add(_point(event));
        }
      });
      return;
    }
    if (event.kind == PointerDeviceKind.touch &&
        !_stylusDown &&
        _touchStartViewport != null) {
      final touches = _touches;
      if (touches.isEmpty) return;
      final focal = _focal(touches);
      // 확대 잠금 (the editor's): two fingers move the view only
      final factor = touches.length < 2 || stows.lastZoomLock.value
          ? 1.0
          : (touches[0].localPosition - touches[1].localPosition).distance /
                _touchStartDistance;
      setState(
        () => _viewport = _touchStartViewport!
            .zoomAt(_touchStartFocal!, math.max(.01, factor))
            .pan(focal - _touchStartFocal!),
      );
    }
  }

  void _up(PointerEvent event, {bool cancel = false}) {
    // a touch on the page brings the keys here (on lifting: a field
    // elsewhere gives its focus back as the touch lands)
    if (!_focus.hasFocus) _focus.requestFocus();
    _contacts.remove(event.pointer);
    _touching.value = _touches.isNotEmpty;
    if (_isStylus(event)) {
      _stylusDown = false;
      _lastStylus = DateTime.now();
    }
    if (_activePointer == event.pointer) {
      setState(() => _finish(cancel: cancel && _activeTool == _Tool.lasso));
    }
    if (_panPointer == event.pointer) _panPointer = null;
    if (event.kind == PointerDeviceKind.touch) _resetTouch();
  }

  void _finish({required bool cancel}) {
    if (!cancel) {
      if (_activeTool == _Tool.lasso) {
        if (_selectionStart != null && _selectionDelta != Offset.zero) {
          _commit(
            InfiniteDocument(
              strokes: [
                for (final stroke in _document.strokes)
                  if (_selected.contains(stroke.id))
                    stroke.translated(_selectionDelta)
                  else
                    stroke,
              ],
            ),
          );
        } else if (_lasso.length >= 3) {
          final path = Path()..addPolygon(_lasso, true);
          for (final stroke in _document.strokes) {
            if (!_lassoPicks(stroke)) continue;
            if (stroke.points.any((point) => path.contains(point.offset)) ||
                _crossesLasso(stroke))
              _selected.add(stroke.id);
          }
        }
      } else if (_activeTool == _Tool.eraser) {
        if (_erased.isNotEmpty)
          _commit(
            InfiniteDocument(
              strokes: _document.strokes
                  .where((stroke) => !_erased.contains(stroke.id))
                  .toList(),
            ),
          );
        // 「자동 해제」: back to the tool before the eraser
        if (_tool == _Tool.eraser && stows.disableEraserAfterUse.value)
          _pickTool(_lastNonEraser);
      } else if (_points.isNotEmpty) {
        _commit(
          InfiniteDocument(
            strokes: [
              ..._document.strokes,
              InfiniteStroke(
                id: newId(),
                tool: _activeTool == _Tool.highlighter
                    ? InfiniteInkTool.highlighter
                    : InfiniteInkTool.pen,
                color: _color.value,
                width: _activeWidth,
                points: _points,
              ),
            ],
          ),
        );
      }
    }
    _activePointer = null;
    _activeTool = null;
    _points.clear();
    _lasso.clear();
    _erased.clear();
    _selectionStart = null;
    _selectionDelta = Offset.zero;
    _strokeAt.value = null;
    _interactionDone?.complete();
    _interactionDone = null;
    _notifyState();
  }

  /// The rectangle lasso (`stows.selectRectangle`): the box from where the
  /// loop started to [corner], closed.
  void _lassoBox(Offset corner) {
    final start = _lasso.first;
    _lasso
      ..clear()
      ..addAll([
        start,
        Offset(corner.dx, start.dy),
        corner,
        Offset(start.dx, corner.dy),
        start,
      ]);
  }

  /// Whether the lasso picks [stroke] up (「선택 대상」 손글씨, 형광펜). With
  /// both off (the editor left only others on) it takes handwriting, the
  /// first row its window shows and keeps on.
  bool _lassoPicks(InfiniteStroke stroke) {
    final ink = stows.selectInk.value;
    final marker = stows.selectHighlighter.value;
    if (stroke.tool == InfiniteInkTool.highlighter) return marker;
    return ink || !marker;
  }

  /// The eraser's size (`stows.eraserSize`, 10 at first) is its reach on the
  /// screen; it rubs out the kinds of stroke its 「지울 대상」 has on, or
  /// with none of its rows on the first (its window keeps that one on).
  void _eraseAt(Offset point) {
    final radius = stows.eraserSize.value / _viewport.scale;
    final shown = _ink.engine.eraserTargets!;
    final on = EraserTargets.value.where(shown.contains).toSet();
    final targets = on.isEmpty ? {shown.first} : on;
    for (final stroke in _document.strokes) {
      final kind = stroke.tool == InfiniteInkTool.highlighter
          ? StrokeKind.highlighter
          : StrokeKind.pen;
      if (!targets.contains(kind)) continue;
      if (!stroke.bounds.inflate(radius).contains(point)) continue;
      if (stroke.points.length == 1 &&
          (stroke.points.first.offset - point).distance <=
              radius + stroke.width / 2)
        _erased.add(stroke.id);
      for (var i = 1; i < stroke.points.length; i++) {
        if (_distanceToSegment(
              point,
              stroke.points[i - 1].offset,
              stroke.points[i].offset,
            ) <=
            radius + stroke.width / 2)
          _erased.add(stroke.id);
      }
    }
  }

  bool _crossesLasso(InfiniteStroke stroke) {
    for (var i = 1; i < stroke.points.length; i++) {
      for (var j = 0; j < _lasso.length; j++) {
        if (_intersects(
          stroke.points[i - 1].offset,
          stroke.points[i].offset,
          _lasso[j],
          _lasso[(j + 1) % _lasso.length],
        ))
          return true;
      }
    }
    return false;
  }

  Rect? get _selectionBounds {
    Rect? result;
    for (final stroke in _document.strokes.where(
      (stroke) => _selected.contains(stroke.id),
    )) {
      result = result == null
          ? stroke.bounds
          : result.expandToInclude(stroke.bounds);
    }
    return result;
  }

  void _signal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _interacting) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      final scroll = event as PointerScrollEvent;
      final zoom = HardwareKeyboard.instance.isControlPressed;
      // 확대 잠금: Ctrl and the wheel do nothing
      if (zoom && stows.lastZoomLock.value) return;
      setState(
        () => _viewport = zoom
            ? _viewport.zoomAt(
                scroll.localPosition,
                math.exp(-scroll.scrollDelta.dy / 300),
              )
            : _viewport.pan(-scroll.scrollDelta),
      );
    });
  }

  /// Takes [tool] up (the lasso keeps what it holds).
  void _setTool(_Tool tool) => setState(() => _pickTool(tool));

  void _pickTool(_Tool tool) {
    _tool = tool;
    if (tool == _Tool.pen || tool == _Tool.highlighter) _lastInk = tool;
    if (tool != _Tool.eraser) _lastNonEraser = tool;
    if (tool != _Tool.lasso) _selected.clear();
  }

  double _widthScale(_Tool tool) =>
      tool == _Tool.highlighter ? _highlighterScale : 1;

  void _selectWidth(double width) {
    final next = width.clamp(_minWidth, _maxWidth);
    if (_interacting) return;
    _width.value = next;
  }

  void _setColor(Color color) {
    if (_interacting) return;
    _color.value = color.toARGB32();
  }

  void _goToOrigin() => setState(() => _viewport = const InfiniteViewport());

  /// Zooms around the centre of the view to [target] (the zoom badge goes
  /// back to 100 %, the workspace row's 「확대 비율」 picks a scale).
  void zoomTo(double target) {
    if (_interacting) return;
    final focal = _surfaceSize.center(Offset.zero);
    setState(
      () => _viewport = _viewport.zoomAt(focal, target / _viewport.scale),
    );
  }

  /// The floating bar: for the pen, the highlighter and the eraser while the
  /// toolbar shows it, not in gesture mode.
  Widget _floatingBar() => ListenableBuilder(
    listenable: Listenable.merge([
      _floatingBarOpen,
      stows.editorGestureMode,
      _color,
      _width,
    ]),
    builder: (context, _) => KitFloatingBar(
      currentTool: _ink.currentTool,
      setTool: _ink.setTool,
      setColor: _setColor,
      actions: _actions,
      penPanelCollapsed: stows.penPanelCollapsed,
      growFrom: _floatingBarFrom,
      strokeAt: _strokeAt,
      engine: _ink.engine,
      visible:
          !stows.editorGestureMode.value &&
          _floatingBarOpen.value &&
          (_tool == _Tool.pen ||
              _tool == _Tool.highlighter ||
              _tool == _Tool.eraser),
    ),
  );

  /// The pen tip badge with the tool in hand; none in gesture mode.
  Widget _hoverBadgeLayer() => ListenableBuilder(
    listenable: Listenable.merge([
      stows.editorGestureMode,
      stows.selectRectangle,
    ]),
    builder: (context, _) => stows.editorGestureMode.value
        ? const SizedBox.shrink()
        : KitHoverBadge(
            controller: _hoverBadge,
            toolIcon: toolbarToolIcon(
              _ink.toolbarTool,
              lassoRect: stows.selectRectangle.value,
            ),
          ),
  );

  @override
  Widget build(BuildContext context) {
    _actions.publish(this, _ink.actions());
    return AppActionScope(
      actions: _actions,
      child: CallbackShortcuts(
        bindings: _keys(context),
        child: Focus(
          focusNode: _focus,
          autofocus: true,
          child: _screen(context),
        ),
      ),
    );
  }

  Widget _screen(BuildContext context) => Column(
    children: [
      SafeArea(
        bottom: false,
        child: KitEditorToolbar(
          actions: _actions,
          title: '',
          floatingBarOpen: _floatingBarOpen,
          floatingBarFrom: _floatingBarFrom,
          tools: _infiniteTools,
          docMenu: false,
          engine: _ink.engine,
        ),
      ),
      if (_saveFailed)
        Material(
          color: Theme.of(context).colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Expanded(child: Text('저장하지 못했습니다. 다시 시도하세요.')),
                TextButton(
                  key: const ValueKey('infinite-retry-save'),
                  onPressed: () => unawaited(_saveFromUi()),
                  child: const Text('다시 시도'),
                ),
              ],
            ),
          ),
        ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            _surfaceSize = constraints.biggest;
            return Stack(
              children: [
                Positioned.fill(
                  child: HoverBadgeListener(
                    controller: _hoverBadge,
                    child: ClipRect(
                      child: Listener(
                        key: const ValueKey('infinite-surface'),
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _down,
                        onPointerMove: _move,
                        onPointerUp: _up,
                        onPointerCancel: (event) => _up(event, cancel: true),
                        onPointerSignal: _signal,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // the paper and the finished strokes, painted
                            // again only when the document or the view
                            // changes (structure review #1)
                            RepaintBoundary(
                              key: const ValueKey('infinite-strokes'),
                              child: CustomPaint(
                                painter: _StrokesPainter(
                                  document: _document,
                                  viewport: _viewport,
                                  erased: Set.of(_erased),
                                  selected: Set.of(_selected),
                                  selectionDelta: _selectionDelta,
                                ),
                                child: const SizedBox.expand(),
                              ),
                            ),
                            CustomPaint(
                              key: const ValueKey('infinite-active'),
                              painter: _ActivePainter(
                                viewport: _viewport,
                                activePoints: List.of(_points),
                                activeTool: _activeTool,
                                color: _color.value,
                                width: _activeWidth,
                                selectionBounds: _selectionBounds,
                                selectionDelta: _selectionDelta,
                                lasso: List.of(_lasso),
                              ),
                              child: const SizedBox.expand(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: KitZoomBadge(
                    scale: _zoomScale,
                    shouldShow: () => true,
                    touching: _touching,
                    // locked, as the editor's, it cannot be pressed
                    onReset: _interacting || stows.lastZoomLock.value
                        ? null
                        : () => zoomTo(1),
                  ),
                ),
                Positioned.fill(child: _floatingBar()),
                Positioned.fill(child: _hoverBadgeLayer()),
                Positioned.fill(
                  child: KitModePill(gestureMode: stows.editorGestureMode),
                ),
              ],
            );
          },
        ),
      ),
    ],
  );

  /// The editor's keys that the infinite note has (editor_actions.dart):
  /// Ctrl+Z undoes, Ctrl+Y and Ctrl+Shift+Z redo, Ctrl+F finger writing,
  /// Ctrl+E the eraser (with its bar, out of gesture mode), Ctrl+C shows
  /// and hides the floating bar.
  Map<ShortcutActivator, VoidCallback> _keys(BuildContext context) {
    void run(String id) => _actions.run(id, context);
    return {
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
          run(AppActionIds.undo),
      const SingleActivator(LogicalKeyboardKey.keyY, control: true): () =>
          run(AppActionIds.redo),
      const SingleActivator(
        LogicalKeyboardKey.keyZ,
        control: true,
        shift: true,
      ): () =>
          run(AppActionIds.redo),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
          run(AppActionIds.finger),
      const SingleActivator(LogicalKeyboardKey.keyE, control: true): () {
        stows.editorGestureMode.value = false;
        run(AppActionIds.toolEraser);
        _floatingBarOpen.value = true;
      },
      const SingleActivator(LogicalKeyboardKey.keyC, control: true): () =>
          _floatingBarOpen.value = !_floatingBarOpen.value,
    };
  }

  @override
  void dispose() {
    stows.editorGestureMode.removeListener(_gestureModeChanged);
    stows.editorFingerDrawing.removeListener(_sharedSettingChanged);
    stows.lastZoomLock.removeListener(_sharedSettingChanged);
    _focus.dispose();
    _actions.dispose();
    _floatingBarOpen.dispose();
    _floatingBarFrom.dispose();
    _color.dispose();
    _width.dispose();
    _hoverBadge.dispose();
    _strokeAt.dispose();
    _touching.dispose();
    _zoomScale.dispose();
    _autosave?.cancel();
    _interactionDone?.complete();
    _interactionDone = null;
    super.dispose();
  }
}

double _distanceToSegment(Offset point, Offset a, Offset b) {
  final segment = b - a;
  final squaredLength = segment.dx * segment.dx + segment.dy * segment.dy;
  if (squaredLength == 0) return (point - a).distance;
  final relative = point - a;
  final t =
      ((relative.dx * segment.dx + relative.dy * segment.dy) / squaredLength)
          .clamp(0.0, 1.0);
  return (point - (a + segment * t)).distance;
}

bool _intersects(Offset a, Offset b, Offset c, Offset d) {
  double cross(Offset u, Offset v) => u.dx * v.dy - u.dy * v.dx;
  final ab = b - a;
  final cd = d - c;
  final denominator = cross(ab, cd);
  if (denominator.abs() < 1e-10) return false;
  final t = cross(c - a, cd) / denominator;
  final u = cross(c - a, ab) / denominator;
  return t >= 0 && t <= 1 && u >= 0 && u <= 1;
}

/// The paper and the finished strokes (a lassoed group shifted while it is
/// dragged, erased ones left out while the eraser goes): what changes only
/// with the document and the view.
class _StrokesPainter extends CustomPainter {
  final InfiniteDocument document;
  final InfiniteViewport viewport;
  final Set<String> erased;
  final Set<String> selected;
  final Offset selectionDelta;
  const new({
    required this.document,
    required this.viewport,
    required this.erased,
    required this.selected,
    required this.selectionDelta,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0xfffffbed), BlendMode.src);
    var spacing = 40 * viewport.scale;
    while (spacing < 18) {
      spacing *= 2;
    }
    final dots = Paint()..color = const Color(0xffd4d8c8);
    for (var x = viewport.offset.dx % spacing; x < size.width; x += spacing) {
      for (
        var y = viewport.offset.dy % spacing;
        y < size.height;
        y += spacing
      ) {
        canvas.drawCircle(Offset(x, y), .65, dots);
      }
    }
    final worldBounds = Rect.fromPoints(
      viewport.screenToWorld(Offset.zero),
      viewport.screenToWorld(Offset(size.width, size.height)),
    );
    for (final stroke in document.strokes) {
      if (erased.contains(stroke.id)) continue;
      final delta = selected.contains(stroke.id) ? selectionDelta : Offset.zero;
      if (!stroke.bounds.shift(delta).overlaps(worldBounds)) continue;
      _paintInk(
        canvas,
        viewport,
        stroke.points,
        stroke.color,
        stroke.width,
        stroke.tool,
        delta,
      );
    }
  }

  @override
  bool shouldRepaint(_StrokesPainter old) =>
      !identical(document, old.document) ||
      viewport.offset != old.viewport.offset ||
      viewport.scale != old.viewport.scale ||
      !setEquals(erased, old.erased) ||
      !setEquals(selected, old.selected) ||
      selectionDelta != old.selectionDelta;
}

/// Over the finished strokes: the stroke being drawn, the lassoed group's
/// box and the lasso's loop. Little to paint, so it paints with every build
/// of the note.
class _ActivePainter extends CustomPainter {
  final InfiniteViewport viewport;
  final List<InfinitePoint> activePoints;
  final _Tool? activeTool;
  final int color;
  final double width;
  final Rect? selectionBounds;
  final Offset selectionDelta;
  final List<Offset> lasso;
  const new({
    required this.viewport,
    required this.activePoints,
    required this.activeTool,
    required this.color,
    required this.width,
    required this.selectionBounds,
    required this.selectionDelta,
    required this.lasso,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (activePoints.isNotEmpty)
      _paintInk(
        canvas,
        viewport,
        activePoints,
        color,
        width,
        activeTool == _Tool.highlighter
            ? InfiniteInkTool.highlighter
            : InfiniteInkTool.pen,
        Offset.zero,
      );
    final selectionPaint = Paint()
      ..color = InfiniteCanvasState._teal
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    if (selectionBounds != null) {
      final bounds = selectionBounds!.shift(selectionDelta);
      canvas.drawRect(
        Rect.fromPoints(
          viewport.worldToScreen(bounds.topLeft),
          viewport.worldToScreen(bounds.bottomRight),
        ).inflate(5),
        selectionPaint,
      );
    }
    if (lasso.isNotEmpty)
      canvas.drawPath(
        Path()..addPolygon(lasso.map(viewport.worldToScreen).toList(), false),
        selectionPaint,
      );
  }

  @override
  bool shouldRepaint(_ActivePainter oldDelegate) => true;
}

/// One stroke of [points] on [canvas] seen through [viewport], moved by
/// [delta] in the world.
void _paintInk(
  Canvas canvas,
  InfiniteViewport viewport,
  List<InfinitePoint> points,
  int color,
  double width,
  InfiniteInkTool tool,
  Offset delta,
) {
  final paint = Paint()
    ..color = tool == InfiniteInkTool.highlighter
        ? Color(color).withValues(alpha: .3)
        : Color(color)
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  if (tool == InfiniteInkTool.highlighter) {
    paint.strokeWidth = width * viewport.scale;
    final path = Path()
      ..addPolygon(
        points
            .map((point) => viewport.worldToScreen(point.offset + delta))
            .toList(),
        false,
      );
    if (points.length == 1)
      canvas.drawCircle(
        viewport.worldToScreen(points.first.offset + delta),
        paint.strokeWidth / 2,
        paint..style = PaintingStyle.fill,
      );
    else
      canvas.drawPath(path, paint);
    return;
  }
  if (points.length == 1) {
    canvas.drawCircle(
      viewport.worldToScreen(points.single.offset + delta),
      width * (.2 + .8 * points.single.pressure) * viewport.scale / 2,
      paint..style = PaintingStyle.fill,
    );
    return;
  }
  for (var i = 1; i < points.length; i++) {
    paint.strokeWidth =
        width *
        (.2 + .4 * (points[i - 1].pressure + points[i].pressure)) *
        viewport.scale;
    canvas.drawLine(
      viewport.worldToScreen(points[i - 1].offset + delta),
      viewport.worldToScreen(points[i].offset + delta),
      paint,
    );
  }
}
