import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/components/toolbar/ink_width_presets.dart';
import 'package:saber/data/vault/infinite_document.dart';

enum _Tool { pen, highlighter, eraser, lasso, pan }

class InfiniteCanvas extends StatefulWidget {
  final InfiniteDocument initialDocument;
  final Future<void> Function(InfiniteDocument) onSave;
  final InfiniteViewport initialViewport;
  final Future<void> Function(InfiniteViewport)? onSaveViewport;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<bool>? onBusyChanged;
  final VoidCallback? onBack;
  final Duration autosaveDelay;
  const new({
    super.key,
    required this.initialDocument,
    required this.onSave,
    this.initialViewport = const InfiniteViewport(),
    this.onSaveViewport,
    this.onDirtyChanged,
    this.onBusyChanged,
    this.onBack,
    this.autosaveDelay = const Duration(milliseconds: 700),
  });
  @override
  State<InfiniteCanvas> createState() => InfiniteCanvasState();
}

class InfiniteCanvasState extends State<InfiniteCanvas> {
  static const _teal = Color(0xff237d82);
  static const _quickWidths = [1.0, 2.5, 5.0];
  late InfiniteDocument _document;
  var _viewport = const InfiniteViewport();
  final _undo = <InfiniteDocument>[];
  final _redo = <InfiniteDocument>[];
  final _contacts = <int, PointerEvent>{};
  final _selected = <String>{};
  final _erased = <String>{};
  final _points = <InfinitePoint>[];
  final _lasso = <Offset>[];
  _Tool _tool = _Tool.pen;
  _Tool? _activeTool;
  var _color = 0xff202923;
  var _width = 2.5;
  var _activeWidth = 2.5;
  var _fingerInk = false;
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

  InfiniteDocument get document => _document;
  InfiniteViewport get viewport => _viewport;
  bool get _interacting => _activePointer != null;
  bool get _dirty => _generation != _savedGeneration;

  @override
  void initState() {
    super.initState();
    _document = widget.initialDocument;
    _viewport = widget.initialViewport;
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

  Future<void> _back() async {
    try {
      await save();
      if (mounted) widget.onBack?.call();
    } catch (_) {
      // Keep the editor open until its current document is saved.
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
    if (event.kind == PointerDeviceKind.touch) {
      final touches = _touches;
      if (touches.length > 1 || !_fingerInk || _tool == _Tool.pan) {
        if (_activePointer != null &&
            _contacts[_activePointer]?.kind == PointerDeviceKind.touch)
          _finish(cancel: true);
        _resetTouch();
        return;
      }
    }
    if (_activePointer != null) return;
    if (_tool == _Tool.pan ||
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
      _activeWidth = _width * _widthScale(activeTool);
      _interactionDone = Completer<void>();
      _points.clear();
      _lasso.clear();
      _erased.clear();
      _selectionStart = null;
      _selectionDelta = Offset.zero;
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
      setState(() {
        final world = _viewport.screenToWorld(event.localPosition);
        if (_activeTool == _Tool.lasso) {
          if (_selectionStart != null)
            _selectionDelta = world - _selectionStart!;
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
      final factor = touches.length < 2
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
    _contacts.remove(event.pointer);
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
                color: _color,
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
    _interactionDone?.complete();
    _interactionDone = null;
    _notifyState();
  }

  void _eraseAt(Offset point) {
    final radius = 10 / _viewport.scale;
    for (final stroke in _document.strokes) {
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
      setState(
        () => _viewport = HardwareKeyboard.instance.isControlPressed
            ? _viewport.zoomAt(
                scroll.localPosition,
                math.exp(-scroll.scrollDelta.dy / 300),
              )
            : _viewport.pan(-scroll.scrollDelta),
      );
    });
  }

  Widget _toolButton(_Tool tool, IconData icon, String label) => IconButton(
    key: ValueKey('infinite-tool-${tool.name}'),
    tooltip: label,
    isSelected: _tool == tool,
    style: IconButton.styleFrom(
      backgroundColor: _tool == tool ? _teal.withValues(alpha: .13) : null,
      foregroundColor: _tool == tool ? _teal : null,
    ),
    onPressed: _interacting
        ? null
        : () => setState(() {
            _tool = tool;
            if (tool != _Tool.lasso) _selected.clear();
          }),
    icon: Icon(icon),
  );

  double _widthScale(_Tool tool) => tool == _Tool.highlighter ? 5 : 1;

  void _selectWidth(double width) {
    if (_interacting || width == _width) return;
    setState(() => _width = width);
  }

  Widget _widthMenu(double scale, String label, {required bool wide}) =>
      PopupMenuButton<double>(
        key: const ValueKey('infinite-width-menu'),
        tooltip: wide ? '$label 더 보기' : label,
        enabled: !_interacting,
        initialValue: _width,
        onSelected: _selectWidth,
        itemBuilder: (_) => [
          for (final width in const [..._quickWidths, 8.0])
            PopupMenuItem(
              value: width,
              child: Text('${(width * scale).toStringAsFixed(1)} px'),
            ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Text('${(_width * scale).toStringAsFixed(1)} px'),
        ),
      );

  Widget _toolbar(BuildContext context, BoxConstraints constraints) {
    final wide = constraints.maxWidth >= 720;
    final scale = _widthScale(_tool);
    final widthLabel = _tool == _Tool.highlighter ? '형광펜 굵기' : '펜 굵기';
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          children: [
            if (widget.onBack != null)
              IconButton(
                tooltip: '문서 목록으로',
                onPressed: _interacting ? null : () => unawaited(_back()),
                icon: const Icon(Icons.arrow_back),
              ),
            IconButton(
              key: const ValueKey('infinite-undo'),
              tooltip: '실행 취소',
              onPressed: _undo.isEmpty || _interacting
                  ? null
                  : () => _undoOrRedo(redo: false),
              icon: const Icon(Icons.undo),
            ),
            IconButton(
              key: const ValueKey('infinite-redo'),
              tooltip: '다시 실행',
              onPressed: _redo.isEmpty || _interacting
                  ? null
                  : () => _undoOrRedo(redo: true),
              icon: const Icon(Icons.redo),
            ),
            const SizedBox(width: 8),
            _toolButton(_Tool.pen, Icons.edit_outlined, '펜'),
            _toolButton(_Tool.highlighter, Icons.border_color_outlined, '형광펜'),
            if (!wide) _widthMenu(scale, widthLabel, wide: false),
            _toolButton(_Tool.eraser, Icons.auto_fix_normal_outlined, '지우개'),
            _toolButton(_Tool.lasso, Icons.gesture, '올가미'),
            _toolButton(_Tool.pan, Icons.pan_tool_outlined, '이동'),
            const SizedBox(width: 12),
            for (final color in const [
              0xff202923,
              0xffb63a3a,
              0xff315fa0,
              0xff237d82,
              0xffd7a51c,
            ])
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Tooltip(
                  message: '펜 색상',
                  child: InkResponse(
                    onTap: _interacting
                        ? null
                        : () => setState(() => _color = color),
                    child: Container(
                      width: 27,
                      height: 27,
                      decoration: BoxDecoration(
                        color: Color(color),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == color ? _teal : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: _color == color
                          ? const Icon(
                              Icons.check,
                              size: 16,
                              color: Colors.white,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 8),
            if (wide) ...[
              InkWidthPresets(
                key: const ValueKey('infinite-quick-ink-widths'),
                widths: [for (final width in _quickWidths) width * scale],
                selectedWidth: _width * scale,
                onSelected: _interacting
                    ? null
                    : (width) => _selectWidth(width / scale),
                widthLabel: widthLabel,
              ),
              _widthMenu(scale, widthLabel, wide: true),
            ],
            IconButton(
              tooltip: _fingerInk ? '손가락 필기 켜짐' : '손가락으로 이동',
              isSelected: _fingerInk,
              onPressed: _interacting
                  ? null
                  : () => setState(() => _fingerInk = !_fingerInk),
              icon: const Icon(Icons.touch_app_outlined),
            ),
            IconButton(
              tooltip: '저장',
              onPressed: _saving || _interacting
                  ? null
                  : () => unawaited(_saveFromUi()),
              icon: Icon(
                _saving
                    ? Icons.hourglass_top
                    : _dirty
                    ? Icons.save_outlined
                    : Icons.check_circle_outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      LayoutBuilder(builder: _toolbar),
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
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRect(
                child: Listener(
                  key: const ValueKey('infinite-surface'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _down,
                  onPointerMove: _move,
                  onPointerUp: _up,
                  onPointerCancel: (event) => _up(event, cancel: true),
                  onPointerSignal: _signal,
                  child: CustomPaint(
                    painter: _InfinitePainter(
                      document: _document,
                      viewport: _viewport,
                      activePoints: List.of(_points),
                      activeTool: _activeTool,
                      color: _color,
                      width: _activeWidth,
                      erased: Set.of(_erased),
                      selected: Set.of(_selected),
                      selectionBounds: _selectionBounds,
                      selectionDelta: _selectionDelta,
                      lasso: List.of(_lasso),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 12,
              bottom: 12,
              child: Material(
                color: Theme.of(context).colorScheme.surface
                    .withValues(alpha: .9),
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '축소',
                      onPressed: _interacting
                          ? null
                          : () => setState(
                              () => _viewport = _viewport.zoomAt(
                                Offset.zero,
                                1 / 1.25,
                              ),
                            ),
                      icon: const Icon(Icons.remove, size: 19),
                    ),
                    Text(
                      '${(_viewport.scale * 100).round()}%',
                      style: const TextStyle(fontSize: 12),
                    ),
                    IconButton(
                      tooltip: '확대',
                      onPressed: _interacting
                          ? null
                          : () => setState(
                              () => _viewport = _viewport.zoomAt(
                                Offset.zero,
                                1.25,
                              ),
                            ),
                      icon: const Icon(Icons.add, size: 19),
                    ),
                    IconButton(
                      tooltip: '원점으로',
                      onPressed: _interacting
                          ? null
                          : () => setState(
                              () => _viewport = const InfiniteViewport(),
                            ),
                      icon: const Icon(Icons.my_location, size: 19),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ],
  );

  @override
  void dispose() {
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

class _InfinitePainter extends CustomPainter {
  final InfiniteDocument document;
  final InfiniteViewport viewport;
  final List<InfinitePoint> activePoints;
  final _Tool? activeTool;
  final int color;
  final double width;
  final Set<String> erased;
  final Set<String> selected;
  final Rect? selectionBounds;
  final Offset selectionDelta;
  final List<Offset> lasso;
  const new({
    required this.document,
    required this.viewport,
    required this.activePoints,
    required this.activeTool,
    required this.color,
    required this.width,
    required this.erased,
    required this.selected,
    required this.selectionBounds,
    required this.selectionDelta,
    required this.lasso,
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
      _ink(
        canvas,
        stroke.points,
        stroke.color,
        stroke.width,
        stroke.tool,
        delta,
      );
    }
    if (activePoints.isNotEmpty)
      _ink(
        canvas,
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

  void _ink(
    Canvas canvas,
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

  @override
  bool shouldRepaint(_InfinitePainter oldDelegate) => true;
}
