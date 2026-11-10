import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/card_canvas_raster.dart';

typedef _CanvasRasterKey = (String, String);

class CardCanvasNote {
  const new(this.id, this.title, {this.isRaster = false});
  final String id;
  final String title;
  final bool isRaster;
}

class CardCanvas extends StatefulWidget {
  const new({
    super.key,
    required this.initialDocument,
    required this.onSave,
    required this.onBack,
    this.onDirtyChanged,
    this.onBusyChanged,
    this.notes = const [],
    this.onOpenNote,
    this.onOpenFile,
    this.onOpenExternal,
    this.loadRaster,
    this.rasterScope,
    this.initialViewport = const CardCanvasViewport(),
    this.fitOnFirstLayout = false,
    this.onSaveViewport,
    this.autosaveDelay = const Duration(milliseconds: 700),
  });
  final CardCanvasDocument initialDocument;
  final Future<void> Function(CardCanvasDocument) onSave;
  final VoidCallback onBack;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<bool>? onBusyChanged;
  final List<CardCanvasNote> notes;
  final ValueChanged<String>? onOpenNote;
  final ValueChanged<CardCanvasNode>? onOpenFile;
  final ValueChanged<String>? onOpenExternal;
  final Future<CardCanvasRaster?> Function(CardCanvasNode)? loadRaster;
  final Object? rasterScope;
  final CardCanvasViewport initialViewport;
  final bool fitOnFirstLayout;
  final Future<void> Function(CardCanvasViewport)? onSaveViewport;
  final Duration autosaveDelay;
  @override
  State<CardCanvas> createState() => CardCanvasState();
}

class CardCanvasState extends State<CardCanvas> {
  static const _teal = Color(0xff237d82);
  static const _edgeHitRadius = 10.0;
  static const _rasterLimit = 12;
  static const _rasterMaxDimension = 1024;
  late CardCanvasDocument _document;
  late CardCanvasViewport _viewport;
  final _undo = <CardCanvasDocument>[];
  final _redo = <CardCanvasDocument>[];
  final _contacts = <int, Offset>{};
  final _text = TextEditingController();
  final _rasterReads = <_CanvasRasterKey, Future<CardCanvasRaster?>>{};
  Future<void> _rasterTail = Future.value();
  String? _selected;
  String? _selectedEdge;
  String? _pressedEdge;
  String? _connectFrom;
  var _panMode = false;
  var _saving = false;
  var _saveFailed = false;
  var _generation = 0;
  var _savedGeneration = 0;
  var _reportedDirty = false;
  var _reportedBusy = false;
  late bool _initialFitPending = widget.fitOnFirstLayout;
  var _surfaceSize = Size.zero;
  int? _activePointer;
  Offset? _down;
  CardCanvasNode? _dragNode;
  CardCanvasDocument? _beforeDrag;
  CardCanvasViewport? _startView;
  Offset? _startFocal;
  var _startDistance = 1.0;
  Completer<void>? _interactionDone;
  Timer? _autosave;
  Future<void>? _saveFuture;

  CardCanvasDocument get document => _document;
  CardCanvasViewport get viewport => _viewport;
  bool get _dirty => _generation != _savedGeneration;
  CardCanvasNode? get _node =>
      _document.nodes.where((node) => node.id == _selected).singleOrNull;
  CardCanvasEdge? get _edge =>
      _document.edges.where((edge) => edge.id == _selectedEdge).singleOrNull;
  CardCanvasNote? _knownNote(String? id) =>
      widget.notes.where((note) => note.id == id).firstOrNull;

  @override
  void initState() {
    super.initState();
    _document = widget.initialDocument;
    _viewport = widget.initialViewport;
  }

  @override
  void didUpdateWidget(covariant CardCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rasterScope != widget.rasterScope ||
        (oldWidget.loadRaster != widget.loadRaster &&
            (widget.rasterScope == null ||
                oldWidget.loadRaster == null ||
                widget.loadRaster == null))) {
      _rasterReads.clear();
      _rasterTail = Future.value();
    }
  }

  void _report() {
    if (!mounted) return;
    final busy = _saving || _contacts.isNotEmpty;
    if (_reportedDirty != _dirty) {
      _reportedDirty = _dirty;
      widget.onDirtyChanged?.call(_dirty);
    }
    if (_reportedBusy != busy) {
      _reportedBusy = busy;
      widget.onBusyChanged?.call(busy);
    }
  }

  void _schedule() {
    _autosave?.cancel();
    _autosave = Timer(widget.autosaveDelay, () {
      if (mounted) unawaited(_saveFromUi());
    });
  }

  void _commit(CardCanvasDocument next, {CardCanvasDocument? previous}) {
    _undo.add(previous ?? _document);
    _redo.clear();
    _document = next;
    _generation++;
    _report();
    _schedule();
  }

  void _select(String? id) {
    _selectedEdge = null;
    if (_selected != id) {
      _selected = id;
      final node = _node;
      _text.text = node?.type == 'text' ? node!.text! : '';
    }
  }

  void _addText() {
    if (_contacts.isNotEmpty) return;
    final center = _viewport.screenToWorld(_surfaceSize.center(Offset.zero));
    final node = CardCanvasNode.text(
      id: newId(),
      x: center.dx - 140,
      y: center.dy - 90,
    );
    setState(() {
      _commit(_document.copyWith(nodes: [..._document.nodes, node]));
      _select(node.id);
    });
  }

  void _addNote(CardCanvasNote note) {
    if (_contacts.isNotEmpty) return;
    final center = _viewport.screenToWorld(_surfaceSize.center(Offset.zero));
    final node = CardCanvasNode.note(
      id: newId(),
      noteId: note.id,
      title: note.title,
      x: center.dx - 140,
      y: center.dy - 90,
    );
    setState(() {
      _commit(_document.copyWith(nodes: [..._document.nodes, node]));
      _select(node.id);
    });
  }

  void _addGroup() {
    if (_contacts.isNotEmpty) return;
    final center = _viewport.screenToWorld(_surfaceSize.center(Offset.zero));
    final group = CardCanvasNode.group(
      id: newId(),
      label: '제목 없는 그룹',
      bounds: Rect.fromCenter(center: center, width: 480, height: 320),
    );
    setState(() {
      _commit(_document.copyWith(nodes: [..._document.nodes, group]));
      _select(group.id);
    });
  }

  Future<String?> _showNameDialog({
    required String original,
    required String title,
    required String fieldLabel,
    required String fieldKey,
  }) {
    var draft = original;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final navigator = Navigator.of(dialogContext);
        void confirm() =>
            navigator.pop(draft == original ? draft : draft.trim());
        return AlertDialog(
          title: Text(title),
          content: TextFormField(
            key: ValueKey(fieldKey),
            initialValue: original,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(labelText: fieldLabel),
            onChanged: (value) => draft = value,
            onFieldSubmitted: (_) => confirm(),
          ),
          actions: [
            TextButton(
              onPressed: () => navigator.pop(),
              child: const Text('취소'),
            ),
            FilledButton(onPressed: confirm, child: const Text('이름 저장')),
          ],
        );
      },
    );
  }

  Future<void> _renameGroup(CardCanvasNode group) async {
    final original = group.label ?? '';
    final label = await _showNameDialog(
      original: original,
      title: '그룹 이름 바꾸기',
      fieldLabel: '그룹 이름',
      fieldKey: 'card-canvas-group-name',
    );
    if (!mounted || label == null || label == original) return;
    final active = _node;
    if (active == null ||
        active.id != group.id ||
        (active.label ?? '') != original) {
      return;
    }
    setState(() => _replaceNode(active.withGroupLabel(label)));
  }

  Future<void> _renameEdge(CardCanvasEdge edge) async {
    final label = await _showNameDialog(
      original: edge.label ?? '',
      title: '연결선 이름 바꾸기',
      fieldLabel: '연결선 이름',
      fieldKey: 'card-canvas-edge-name',
    );
    if (!mounted || label == null || _contacts.isNotEmpty) return;
    final nextLabel = label.trim().isEmpty ? null : label;
    if (nextLabel == edge.label || !identical(_edge, edge)) return;
    setState(() {
      _commit(
        _document.copyWith(
          edges: [
            for (final item in _document.edges)
              if (item.id == edge.id) item.withLabel(nextLabel) else item,
          ],
        ),
      );
    });
  }

  void _deleteEdge(CardCanvasEdge edge) {
    if (_contacts.isNotEmpty || !identical(_edge, edge)) return;
    setState(() {
      _commit(
        _document.copyWith(
          edges: _document.edges.where((item) => item.id != edge.id).toList(),
        ),
      );
      _select(null);
    });
  }

  void _replaceNode(CardCanvasNode next) {
    if (_contacts.isNotEmpty) return;
    _commit(
      _document.copyWith(
        nodes: [
          for (final node in _document.nodes)
            if (node.id == next.id) next else node,
        ],
      ),
    );
  }

  void _delete() {
    final node = _node;
    if (node == null || _contacts.isNotEmpty) return;
    setState(() {
      _commit(
        _document.copyWith(
          nodes: _document.nodes.where((item) => item.id != node.id).toList(),
          edges: _document.edges
              .where(
                (edge) => edge.fromNode != node.id && edge.toNode != node.id,
              )
              .toList(),
        ),
      );
      _select(null);
      _connectFrom = null;
    });
  }

  void _history(bool redo) {
    if (_contacts.isNotEmpty) return;
    final source = redo ? _redo : _undo;
    if (source.isEmpty) return;
    setState(() {
      (redo ? _undo : _redo).add(_document);
      _document = source.removeLast();
      _select(null);
      _connectFrom = null;
      _generation++;
      _report();
      _schedule();
    });
  }

  Future<void> save() {
    _autosave?.cancel();
    final pending = _saveFuture;
    if (pending != null) return pending;
    late Future<void> tracked;
    tracked = _saveNow().whenComplete(() {
      if (identical(_saveFuture, tracked)) _saveFuture = null;
    });
    _saveFuture = tracked;
    return tracked;
  }

  Future<void> _saveNow() async {
    _saving = true;
    _report();
    if (mounted) setState(() {});
    try {
      while (true) {
        await _interactionDone?.future;
        if (_dirty) {
          final generation = _generation;
          await widget.onSave(_document);
          _savedGeneration = generation;
          _saveFailed = false;
          _report();
          continue;
        }
        final view = _viewport;
        await widget.onSaveViewport?.call(view);
        if (!_dirty && identical(view, _viewport) && _contacts.isEmpty) {
          _saveFailed = false;
          break;
        }
      }
    } catch (_) {
      _saveFailed = true;
      rethrow;
    } finally {
      _saving = false;
      if (mounted) {
        _report();
        setState(() {});
      }
    }
  }

  Future<void> _saveFromUi() async {
    try {
      await save();
    } catch (_) {}
  }

  Future<void> _back() async {
    try {
      await save();
      if (mounted) widget.onBack();
    } catch (_) {}
  }

  Future<void> _openFile(CardCanvasNode node) async {
    try {
      await save();
      final id = node.linkedNoteId;
      if (!mounted || id == null || _knownNote(id) == null) return;
      final openFile = widget.onOpenFile;
      if (openFile != null) {
        openFile(node);
      } else {
        widget.onOpenNote?.call(id);
      }
    } catch (_) {}
  }

  Future<void> _openExternal(String url) async {
    try {
      await save();
      if (mounted) widget.onOpenExternal?.call(url);
    } catch (_) {}
  }

  (CardCanvasNode?, CardCanvasNode?) _hitNodes(Offset world) {
    CardCanvasNode? group;
    for (final node in _document.nodes.reversed) {
      final bounds = node.bounds;
      if (!bounds.contains(world)) continue;
      if (node.type != 'group' ||
          world.dy < bounds.top + 36 ||
          !bounds.deflate(5 / _viewport.scale).contains(world)) {
        return (node, group);
      }
      group ??= node;
    }
    return (null, group);
  }

  String? _hitEdge(Offset screen) {
    final nodes = {for (final node in _document.nodes) node.id: node};
    String? hit;
    var best = _edgeHitRadius * _edgeHitRadius;
    for (final edge in _document.edges.reversed) {
      final ends = _connectionEnds(edge, nodes, _viewport);
      if (ends == null) continue;
      final (start, end) = ends;
      final segment = end - start;
      final relative = screen - start;
      final length = segment.distanceSquared;
      final closest = length == 0
          ? start
          : start +
                segment *
                    ((relative.dx * segment.dx + relative.dy * segment.dy) /
                            length)
                        .clamp(0.0, 1.0);
      final distance = (screen - closest).distanceSquared;
      if (distance < best) {
        hit = edge.id;
        best = distance;
      }
    }
    return hit;
  }

  void _downEvent(PointerDownEvent event) {
    _contacts[event.pointer] = event.localPosition;
    _interactionDone ??= Completer<void>();
    if (_contacts.length > 1) {
      _pressedEdge = null;
      if (_beforeDrag != null) _document = _beforeDrag!;
      _dragNode = null;
      _beforeDrag = null;
      final positions = _contacts.values.take(2).toList();
      _startFocal = (positions[0] + positions[1]) / 2;
      _startDistance = math.max(1, (positions[0] - positions[1]).distance);
      _startView = _viewport;
      _activePointer = null;
      _report();
      setState(() {});
      return;
    }
    _activePointer = event.pointer;
    _down = event.localPosition;
    _startView = _viewport;
    final world = _viewport.screenToWorld(event.localPosition);
    final (foreground, group) = _hitNodes(world);
    final node = foreground ?? group;
    _pressedEdge =
        !_panMode &&
            _connectFrom == null &&
            foreground == null &&
            event.buttons & kPrimaryButton != 0
        ? _hitEdge(event.localPosition)
        : null;
    setState(() {
      if (_connectFrom != null && node != null && node.id != _connectFrom) {
        _commit(
          _document.copyWith(
            edges: [
              ..._document.edges,
              CardCanvasEdge.connect(
                id: newId(),
                fromNode: _connectFrom!,
                toNode: node.id,
              ),
            ],
          ),
        );
        _connectFrom = null;
        _select(node.id);
        _dragNode = null;
      } else if (_pressedEdge != null) {
        _dragNode = null;
        _beforeDrag = null;
      } else if (!_panMode &&
          event.buttons & kMiddleMouseButton == 0 &&
          node != null) {
        _select(node.id);
        _dragNode = node;
        _beforeDrag = _document;
      } else {
        _select(null);
        _dragNode = null;
        _beforeDrag = null;
      }
    });
    _report();
  }

  void _moveEvent(PointerMoveEvent event) {
    if (!_contacts.containsKey(event.pointer)) return;
    _contacts[event.pointer] = event.localPosition;
    if (_contacts.length > 1) {
      final positions = _contacts.values.take(2).toList();
      final focal = (positions[0] + positions[1]) / 2;
      final scale =
          (_startView!.scale *
                  (positions[0] - positions[1]).distance /
                  _startDistance)
              .clamp(.1, 5.0)
              .toDouble();
      setState(
        () => _viewport = CardCanvasViewport(
          scale: scale,
          offset: focal - _startView!.screenToWorld(_startFocal!) * scale,
        ),
      );
      return;
    }
    if (_activePointer != event.pointer || _down == null) return;
    final delta = event.localPosition - _down!;
    final edgeDrag = _pressedEdge != null;
    if (edgeDrag && delta.distance < _edgeHitRadius) return;
    _pressedEdge = null;
    final node = _dragNode;
    setState(() {
      if (edgeDrag) _select(null);
      if (node != null) {
        final next = node.copyWith(
          x: node.x + delta.dx / _viewport.scale,
          y: node.y + delta.dy / _viewport.scale,
        );
        final original = _beforeDrag!;
        final move = next.bounds.topLeft - node.bounds.topLeft;
        _document = original.copyWith(
          nodes: [
            for (final item in original.nodes)
              if (item.id == node.id)
                next
              else if (node.type == 'group' &&
                  move != Offset.zero &&
                  node.bounds.expandToInclude(item.bounds) == node.bounds)
                item.copyWith(x: item.x + move.dx, y: item.y + move.dy)
              else
                item,
          ],
        );
      } else {
        _viewport = _startView!.pan(delta);
      }
    });
  }

  void _upEvent(PointerEvent event) {
    if (!_contacts.containsKey(event.pointer)) return;
    _contacts.remove(event.pointer);
    if (_contacts.isNotEmpty) {
      final remaining = _contacts.entries.first;
      _activePointer = remaining.key;
      _down = remaining.value;
      _startView = _viewport;
      _dragNode = null;
      _beforeDrag = null;
      return;
    }
    final before = _beforeDrag;
    final moved = _dragNode;
    if (event is PointerUpEvent &&
        _pressedEdge != null &&
        _activePointer == event.pointer &&
        (event.localPosition - _down!).distance < _edgeHitRadius) {
      _select(null);
      _selectedEdge = _pressedEdge;
    }
    _pressedEdge = null;
    if (before != null && moved != null) {
      final current = _document.nodes.firstWhere((node) => node.id == moved.id);
      if (current.x != moved.x || current.y != moved.y)
        _commit(_document, previous: before);
    }
    _dragNode = null;
    _beforeDrag = null;
    _activePointer = null;
    _down = null;
    final finished = _interactionDone;
    _interactionDone = null;
    finished?.complete();
    _report();
    setState(() {});
  }

  void _scroll(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        if (mounted)
          setState(
            () => _viewport = _viewport.zoomAt(
              event.localPosition,
              math.exp(-event.scrollDelta.dy / 400),
            ),
          );
      });
    }
  }

  void _fitInitialViewport() {
    if (!_initialFitPending || !_surfaceSize.isFinite || _surfaceSize.isEmpty)
      return;
    _initialFitPending = false;
    if (_document.nodes.isEmpty) return;
    final previous = _viewport;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(previous, _viewport) || _contacts.isNotEmpty)
        return;
      final bounds = _document.nodes
          .map((node) => node.bounds)
          .reduce((a, b) => a.expandToInclude(b));
      final scale = math
          .min(
            math.max(1, _surfaceSize.width - 32) / bounds.width,
            math.max(1, _surfaceSize.height - 32) / bounds.height,
          )
          .clamp(.1, 1.0)
          .toDouble();
      setState(() {
        _viewport = CardCanvasViewport(
          offset: _surfaceSize.center(Offset.zero) - bounds.center * scale,
          scale: scale,
        );
      });
    });
  }

  Widget _surface() => LayoutBuilder(
    builder: (context, constraints) {
      _surfaceSize = constraints.biggest;
      _fitInitialViewport();
      final visible = Rect.fromPoints(
        _viewport.screenToWorld(Offset.zero),
        _viewport.screenToWorld(_surfaceSize.bottomRight(Offset.zero)),
      );
      final nodes = _document.nodes.where(
        (node) => node.bounds.overlaps(visible),
      );
      final rasters = _visibleRasterReads(nodes);
      return Listener(
        key: const ValueKey('card-canvas-surface'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: _downEvent,
        onPointerMove: _moveEvent,
        onPointerUp: _upEvent,
        onPointerCancel: _upEvent,
        onPointerSignal: _scroll,
        child: ClipRect(
          child: ColoredBox(
            color: const Color(0xfff5f7f1),
            child: Stack(
              children: [
                for (final node in nodes)
                  if (node.type == 'group' && rasters.containsKey(node.id))
                    _positionNode(
                      node,
                      'backdrop',
                      IgnorePointer(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            8 * _viewport.scale,
                          ),
                          child: _withRaster(
                            rasters[node.id]!,
                            const SizedBox.shrink(),
                            (raster) => _image(node, raster, group: true),
                          ),
                        ),
                      ),
                    ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _ConnectionsPainter(
                      _document,
                      _viewport,
                      _selectedEdge,
                    ),
                  ),
                ),
                for (final node in nodes)
                  _positionNode(
                    node,
                    'card',
                    IgnorePointer(
                      child: Semantics(
                        label: _nodeTitle(node),
                        selected: _selected == node.id,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: node.type == 'group'
                                ? null
                                : _canvasColor(node.color).withValues(
                                    alpha: node.color == null ? 1 : .18,
                                  ),
                            borderRadius: BorderRadius.circular(
                              8 * _viewport.scale,
                            ),
                            border: Border.all(
                              color: _selected == node.id
                                  ? _teal
                                  : node.type == 'group' && node.color != null
                                  ? _canvasColor(node.color)
                                  : const Color(0xffcbd7cf),
                              width: _selected == node.id ? 2 : 1,
                            ),
                          ),
                          child: _nodeFace(node, rasters[node.id]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _positionNode(CardCanvasNode node, String layer, Widget child) {
    final origin = _viewport.worldToScreen(node.bounds.topLeft);
    return Positioned(
      key: ValueKey((node.id, layer)),
      left: origin.dx,
      top: origin.dy,
      width: node.width * _viewport.scale,
      height: node.height * _viewport.scale,
      child: child,
    );
  }

  Map<String, Future<CardCanvasRaster?>> _visibleRasterReads(
    Iterable<CardCanvasNode> nodes,
  ) {
    final load = widget.loadRaster;
    if (load == null) return const {};
    final requested = <_CanvasRasterKey, CardCanvasNode>{};
    final byNode = <String, _CanvasRasterKey>{};
    for (final node in nodes) {
      final path = node.backgroundPath;
      final noteId = node.linkedNoteId;
      final key = path != null
          ? ('group', path)
          : noteId != null &&
                node.subpath == null &&
                _knownNote(noteId)?.isRaster == true
          ? ('file', noteId)
          : null;
      if (key == null ||
          (requested.length == _rasterLimit && !requested.containsKey(key))) {
        continue;
      }
      requested.putIfAbsent(key, () => node);
      byNode[node.id] = key;
    }
    final evict = _rasterReads.keys
        .where((key) => !requested.containsKey(key))
        .toList();
    for (final entry in requested.entries) {
      if (_rasterReads.containsKey(entry.key)) continue;
      if (_rasterReads.length == _rasterLimit) {
        _rasterReads.remove(evict.removeAt(0));
      }
      // Queue one bounded read at a time and skip entries evicted before they start.
      late final Future<CardCanvasRaster?> read;
      read = _rasterTail.then((_) async {
        if (!mounted || !identical(_rasterReads[entry.key], read)) return null;
        return load(entry.value);
      });
      _rasterReads[entry.key] = read;
      _rasterTail = read.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
    }
    return {
      for (final entry in byNode.entries) entry.key: _rasterReads[entry.value]!,
    };
  }

  Widget _withRaster(
    Future<CardCanvasRaster?> read,
    Widget fallback,
    Widget Function(CardCanvasRaster) buildImage,
  ) => FutureBuilder<CardCanvasRaster?>(
    future: read,
    builder: (_, snapshot) {
      final raster = snapshot.connectionState == ConnectionState.done
          ? snapshot.data
          : null;
      return raster == null ? fallback : buildImage(raster);
    },
  );

  Widget _image(
    CardCanvasNode node,
    CardCanvasRaster raster, {
    required bool group,
  }) {
    final style = group ? node.backgroundStyle : 'ratio';
    final tile = style == 'repeat';
    final dimension = math.max(raster.width, raster.height);
    final resize = dimension > _rasterMaxDimension;
    final decodeScale = resize ? _rasterMaxDimension / dimension : 1.0;
    return Image.memory(
      raster.bytes,
      key: ValueKey('card-canvas-raster-${node.id}'),
      fit: switch (style) {
        'repeat' => BoxFit.none,
        'ratio' => BoxFit.contain,
        _ => BoxFit.cover,
      },
      repeat: tile ? ImageRepeat.repeat : ImageRepeat.noRepeat,
      alignment: tile ? Alignment.topLeft : Alignment.center,
      scale: tile ? decodeScale / _viewport.scale : 1,
      cacheWidth: resize && raster.width >= raster.height
          ? _rasterMaxDimension
          : null,
      cacheHeight: resize && raster.height > raster.width
          ? _rasterMaxDimension
          : null,
      excludeFromSemantics: true,
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
      frameBuilder: tile
          ? (_, child, _, _) {
              // The image widget owns the decoded frame. Paint the repeated
              // pattern once even when the group spans an enormous world area.
              if (child case RawImage(image: final bitmap?)) {
                return CustomPaint(
                  painter: _CanvasTilePainter(
                    bitmap,
                    _viewport.scale / decodeScale,
                  ),
                );
              }
              return const SizedBox.shrink();
            }
          : null,
    );
  }

  Widget _nodeFace(CardCanvasNode node, Future<CardCanvasRaster?>? read) {
    final scale = _viewport.scale;
    Widget label({int lines = 12}) => Text(
      _nodeTitle(node),
      style: TextStyle(fontSize: 14 * scale, color: const Color(0xff21352d)),
      maxLines: lines,
      overflow: TextOverflow.ellipsis,
    );
    final fallback = Padding(
      padding: EdgeInsets.all(14 * scale),
      child: ClipRect(child: label()),
    );
    if (read == null) return fallback;
    if (node.type == 'group') {
      return _withRaster(
        read,
        fallback,
        (_) => Padding(
          padding: EdgeInsets.all(14 * scale),
          child: ClipRect(
            child: Align(
              alignment: Alignment.topLeft,
              child: ColoredBox(
                color: const Color(0xeef5f7f1),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4 * scale),
                  child: label(lines: 1),
                ),
              ),
            ),
          ),
        ),
      );
    }
    final captionHeight = math.min(30, node.height * .3) * scale;
    return _withRaster(
      read,
      fallback,
      (raster) => ClipRRect(
        borderRadius: BorderRadius.circular(8 * scale),
        child: Stack(
          children: [
            Positioned.fill(
              bottom: captionHeight,
              child: _image(node, raster, group: false),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: captionHeight,
              child: ColoredBox(
                color: const Color(0xfff5f7f1),
                child: Center(child: label(lines: 1)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _nodeTitle(CardCanvasNode node) => switch (node.type) {
    'text' => node.text!.isEmpty ? '텍스트 카드' : node.text!,
    'file' =>
      _knownNote(node.linkedNoteId)?.title ??
          node.label ??
          node.file ??
          '문서 카드 · 연결 없음',
    'group' => switch (node.label) {
      final String label when label.isNotEmpty => label,
      _ => '그룹',
    },
    'link' => node.url ?? '웹 링크',
    _ => '지원하지 않는 카드 · 원본 정보 보존',
  };

  Widget _inspector() {
    final node = _node;
    final edge = _edge;
    final url = node?.safeUrl;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            edge != null
                ? '선택한 연결선'
                : node == null
                ? '카드 선택'
                : '선택한 카드',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (_connectFrom != null) const Text('연결할 카드를 누르세요.'),
          if (edge != null) ...[
            Text(
              edge.label ?? '이름 없는 연결선',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _contacts.isEmpty
                      ? () => unawaited(_renameEdge(edge))
                      : null,
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('연결선 이름 바꾸기'),
                ),
                TextButton.icon(
                  onPressed: _contacts.isEmpty ? () => _deleteEdge(edge) : null,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('연결선 삭제'),
                ),
              ],
            ),
          ] else if (node == null)
            const Text('메모나 문서를 추가하거나 이름을 붙일 연결선을 누르세요.')
          else if (node.type == 'text')
            TextField(
              key: const ValueKey('card-canvas-text'),
              enabled: _contacts.isEmpty,
              controller: _text,
              minLines: 3,
              maxLines: null,
              decoration: const InputDecoration(
                hintText: '카드 내용',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  setState(() => _replaceNode(node.copyWith(text: value))),
            )
          else if (node.type == 'file') ...[
            if (_knownNote(node.linkedNoteId) != null &&
                (widget.onOpenFile != null || widget.onOpenNote != null))
              FilledButton.icon(
                onPressed: () => unawaited(_openFile(node)),
                icon: const Icon(Icons.open_in_new),
                label: const Text('문서 열기'),
              )
            else
              const Text('연결할 수 없는 문서'),
          ] else if (node.type == 'link') ...[
            if (url != null && widget.onOpenExternal != null)
              FilledButton.icon(
                onPressed: () => unawaited(_openExternal(url)),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('웹 링크 열기'),
              )
            else
              const Text('열 수 없는 웹 링크'),
          ] else if (node.type == 'group')
            OutlinedButton.icon(
              onPressed: _contacts.isEmpty
                  ? () => unawaited(_renameGroup(node))
                  : null,
              icon: const Icon(Icons.edit_outlined),
              label: const Text('그룹 이름 바꾸기'),
            )
          else
            const Text('이 카드의 원본 정보는 저장됩니다. 내용 편집과 외부 경로 열기는 지원하지 않습니다.'),
        ],
      ),
    );
  }

  Widget _tools() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        IconButton(
          tooltip: '텍스트 카드 추가',
          onPressed: _contacts.isEmpty ? _addText : null,
          icon: const Icon(Icons.note_add_outlined),
        ),
        PopupMenuButton<CardCanvasNote>(
          tooltip: '문서 카드 추가',
          enabled: widget.notes.isNotEmpty && _contacts.isEmpty,
          onSelected: _addNote,
          itemBuilder: (_) => [
            for (final note in widget.notes)
              PopupMenuItem(value: note, child: Text(note.title)),
          ],
          icon: const Icon(Icons.post_add),
        ),
        IconButton(
          tooltip: '그룹 추가',
          onPressed: _contacts.isEmpty ? _addGroup : null,
          icon: const Icon(Icons.dashboard_customize_outlined),
        ),
        IconButton(
          tooltip: '카드 연결',
          isSelected: _connectFrom != null,
          onPressed: _node == null || _contacts.isNotEmpty
              ? null
              : () => setState(
                  () => _connectFrom = _connectFrom == null ? _selected : null,
                ),
          icon: const Icon(Icons.polyline_outlined),
        ),
        PopupMenuButton<String>(
          tooltip: '카드 색',
          enabled: _node != null && _contacts.isEmpty,
          onSelected: (color) {
            final node = _node;
            if (node != null)
              setState(() => _replaceNode(node.copyWith(color: color)));
          },
          itemBuilder: (_) => [
            for (final entry in const {
              '1': '빨강',
              '2': '주황',
              '3': '노랑',
              '4': '초록',
              '5': '청록',
              '6': '보라',
            }.entries)
              PopupMenuItem(
                value: entry.key,
                child: Row(
                  children: [
                    Icon(
                      Icons.circle,
                      size: 18,
                      color: _canvasColor(entry.key),
                    ),
                    const SizedBox(width: 12),
                    Text(entry.value),
                  ],
                ),
              ),
          ],
          icon: const Icon(Icons.palette_outlined),
        ),
        IconButton(
          tooltip: '선택 삭제',
          onPressed: _node == null || _contacts.isNotEmpty ? null : _delete,
          icon: const Icon(Icons.delete_outline),
        ),
        IconButton(
          tooltip: '실행 취소',
          onPressed: _undo.isEmpty || _contacts.isNotEmpty
              ? null
              : () => _history(false),
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          tooltip: '다시 실행',
          onPressed: _redo.isEmpty || _contacts.isNotEmpty
              ? null
              : () => _history(true),
          icon: const Icon(Icons.redo),
        ),
        IconButton(
          tooltip: '화면 이동',
          isSelected: _panMode,
          onPressed: _contacts.isEmpty
              ? () => setState(() => _panMode = !_panMode)
              : null,
          icon: const Icon(Icons.pan_tool_outlined),
        ),
        IconButton(
          tooltip: '축소',
          onPressed: _contacts.isEmpty
              ? () => setState(
                  () => _viewport = _viewport.zoomAt(
                    _surfaceSize.center(Offset.zero),
                    1 / 1.2,
                  ),
                )
              : null,
          icon: const Icon(Icons.remove),
        ),
        Text('${(_viewport.scale * 100).round()}%'),
        IconButton(
          tooltip: '확대',
          onPressed: _contacts.isEmpty
              ? () => setState(
                  () => _viewport = _viewport.zoomAt(
                    _surfaceSize.center(Offset.zero),
                    1.2,
                  ),
                )
              : null,
          icon: const Icon(Icons.add),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_back());
    },
    child: Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '문서 목록으로',
              onPressed: () => unawaited(_back()),
              icon: const Icon(Icons.arrow_back),
            ),
            Expanded(
              child: Text(
                '카드 캔버스',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            Text(
              _saving
                  ? '저장 중'
                  : _dirty
                  ? '변경 내용 있음'
                  : '저장됨',
            ),
            IconButton(
              tooltip: '저장',
              onPressed: () => unawaited(_saveFromUi()),
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        SizedBox(height: 52, child: _tools()),
        if (_saveFailed)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  const Expanded(child: Text('저장하지 못했습니다. 편집 내용은 남아 있습니다.')),
                  TextButton(
                    onPressed: () => unawaited(_saveFromUi()),
                    child: const Text('저장 재시도'),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 1000
                ? Row(
                    children: [
                      Expanded(child: _surface()),
                      SizedBox(width: 280, child: _inspector()),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: _surface()),
                      SizedBox(
                        height: math.min(190, constraints.maxHeight * .45),
                        child: _inspector(),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    ),
  );

  @override
  void dispose() {
    _autosave?.cancel();
    _text.dispose();
    _interactionDone?.complete();
    _interactionDone = null;
    super.dispose();
  }
}

class _CanvasTilePainter extends CustomPainter {
  const new(this.image, this.scale);

  final ui.Image image;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final shader = ui.ImageShader(
      image,
      ui.TileMode.repeated,
      ui.TileMode.repeated,
      Matrix4.diagonal3Values(scale, scale, 1).storage,
    );
    try {
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    } finally {
      shader.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _CanvasTilePainter oldDelegate) =>
      image != oldDelegate.image || scale != oldDelegate.scale;
}

Color _canvasColor(String? value) {
  if (value != null && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(value))
    return Color(0xff000000 | int.parse(value.substring(1), radix: 16));
  return switch (value) {
    '1' => const Color(0xffbe5555),
    '2' => const Color(0xffc57c37),
    '3' => const Color(0xffbea03f),
    '4' => const Color(0xff4d9062),
    '5' => const Color(0xff237d82),
    '6' => const Color(0xff8c68ab),
    _ => Colors.white,
  };
}

(Offset, Offset)? _connectionEnds(
  CardCanvasEdge edge,
  Map<String, CardCanvasNode> nodes,
  CardCanvasViewport viewport,
) {
  final from = nodes[edge.fromNode];
  final to = nodes[edge.toNode];
  if (from == null || to == null) return null;
  Offset anchor(CardCanvasNode node, String? side, {required bool start}) =>
      viewport.worldToScreen(switch (side) {
        'top' => node.bounds.topCenter,
        'bottom' => node.bounds.bottomCenter,
        'left' => node.bounds.centerLeft,
        'right' => node.bounds.centerRight,
        _ => start ? node.bounds.centerRight : node.bounds.centerLeft,
      });
  return (
    anchor(from, edge.fromSide, start: true),
    anchor(to, edge.toSide, start: false),
  );
}

class _ConnectionsPainter extends CustomPainter {
  const new(this.document, this.viewport, this.selectedEdge);
  final CardCanvasDocument document;
  final CardCanvasViewport viewport;
  final String? selectedEdge;

  @override
  void paint(Canvas canvas, Size size) {
    final byId = {for (final node in document.nodes) node.id: node};
    for (final edge in document.edges) {
      final ends = _connectionEnds(edge, byId, viewport);
      if (ends == null) continue;
      final (start, end) = ends;
      if (!Rect.fromPoints(start, end).inflate(16).overlaps(Offset.zero & size))
        continue;
      final raw = edge.toJson();
      final rawColor = raw['color'];
      final color = rawColor is String
          ? _canvasColor(rawColor)
          : const Color(0xff658475);
      if (selectedEdge == edge.id) {
        canvas.drawLine(
          start,
          end,
          Paint()
            ..color = CardCanvasState._teal
            ..strokeWidth = 5,
        );
      }
      canvas.drawLine(
        start,
        end,
        Paint()
          ..color = color
          ..strokeWidth = 1.5,
      );
      void arrow(Offset at, Offset toward) {
        final angle = math.atan2(toward.dy - at.dy, toward.dx - at.dx);
        canvas.drawPath(
          Path()
            ..moveTo(at.dx, at.dy)
            ..lineTo(
              at.dx + 10 * math.cos(angle + .45),
              at.dy + 10 * math.sin(angle + .45),
            )
            ..lineTo(
              at.dx + 10 * math.cos(angle - .45),
              at.dy + 10 * math.sin(angle - .45),
            )
            ..close(),
          Paint()..color = color,
        );
      }

      if (raw['fromEnd'] == 'arrow') arrow(start, end);
      if (raw['toEnd'] != 'none') arrow(end, start);
      if (edge.label case final String text) {
        final label = TextPainter(
          text: TextSpan(
            text: text,
            style: const TextStyle(fontSize: 12, color: Color(0xff284b3c)),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 220);
        label.paint(canvas, (start + end) / 2);
        label.dispose();
      }
    }
  }

  @override
  bool shouldRepaint(_ConnectionsPainter oldDelegate) =>
      oldDelegate.document != document ||
      oldDelegate.viewport != viewport ||
      oldDelegate.selectedEdge != selectedEdge;
}
