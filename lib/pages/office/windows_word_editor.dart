part of 'windows_office_editor.dart';

typedef _WordTarget = (String, String, String);
typedef _WordBlock = (String, String);

class _WordOp {
  const new(this.operation, [this.owner, this.localIndex]);
  final WindowsOfficeOperation operation;
  final _WordTarget? owner;
  final int? localIndex;
}

class _WordImage {
  const new({
    required this.id,
    this.ownerId,
    this.paragraphId,
    this.tableId,
    this.cell,
    this.anchorType,
    this.offsetUtf16,
    this.width,
    this.height,
    this.nativeGraphicSha256,
    this.image,
    this.canMove = false,
    this.canDelete = false,
    this.isAdded = false,
  });

  factory fromSnapshot(WindowsOfficeWordImage source) => _WordImage(
    id: source.id,
    ownerId: source.ownerId,
    paragraphId: source.paragraphId,
    tableId: source.tableId,
    cell: source.cell,
    anchorType: source.anchorType,
    offsetUtf16: source.offsetUtf16,
    width: source.width,
    height: source.height,
    nativeGraphicSha256: source.nativeGraphicSha256,
    image: source.image,
    canMove: source.canMove,
    canDelete: source.canDelete,
  );

  final String id;
  final String? ownerId, paragraphId, tableId, cell, anchorType;
  final int? offsetUtf16;
  final double? width, height;
  final String? nativeGraphicSha256;
  final WindowsOfficeImageDetails? image;
  final bool canMove, canDelete, isAdded;

  _WordImage at(String owner, String paragraph, int offset) => _WordImage(
    id: id,
    ownerId: owner,
    paragraphId: paragraph,
    tableId: tableId,
    cell: cell,
    anchorType: anchorType,
    offsetUtf16: offset,
    width: width,
    height: height,
    nativeGraphicSha256: nativeGraphicSha256,
    image: image,
    canMove: canMove,
    canDelete: canDelete,
    isAdded: isAdded,
  );
}

class _WordNode {
  new(
    this.target,
    this.text,
    this.format,
    this.capabilities, {
    required this.ownerId,
    this.isNew = false,
  });
  final _WordTarget target;
  _TextDraft text;
  final Map<String, Object?> format;
  final Map<String, bool> capabilities;
  final String? ownerId;
  final bool isNew;
  final focus = FocusNode();
  var observed = <WindowsOfficeOperation>[];
  String get id => target.$2;
  void dispose() {
    text.dispose();
    focus.dispose();
  }
}

class _WordNodeState {
  new(_WordNode node)
    : target = node.target,
      ownerId = node.ownerId,
      text = node.text.text.text,
      details = node.text.details == null
          ? null
          : WindowsOfficeTextDetails.fromJson({
              ..._wordTextDetails(node.text),
              'canReplace': node.text.details?.canReplace,
              'canStyle': node.text.details?.canStyle,
              'truncated': node.text.details?.truncated,
            }),
      validSnapshot = node.text._validSnapshot,
      selection = node.text._selection,
      format = Map.of(node.format),
      capabilities = Map.of(node.capabilities),
      isNew = node.isNew;
  final _WordTarget target;
  final String? ownerId;
  final String text;
  final WindowsOfficeTextDetails? details;
  final bool validSnapshot;
  final TextSelection selection;
  final Map<String, Object?> format;
  final Map<String, bool> capabilities;
  final bool isNew;
}

class _WordCheckpoint {
  new(
    this.blocks,
    this.nodes,
    this.journal,
    this.ownerId,
    this.activeId,
    this.pageStyles,
    this.pageStyleId,
    this.images,
    this.imageAssets,
    this.imageTargets,
  );
  final Map<String, List<_WordBlock>> blocks;
  final List<_WordNodeState> nodes;
  final List<_WordOp> journal;
  final String ownerId;
  final String? activeId;
  final List<WindowsOfficePageStyle> pageStyles;
  final String? pageStyleId;
  final List<_WordImage> images;
  final Map<String, String> imageAssets;
  final List<WindowsOfficeWordImageTarget>? imageTargets;
}

class _WordUndo {
  new(this.before, this.after, this.owner);
  final _WordCheckpoint before;
  _WordCheckpoint after;
  final _WordTarget? owner;
}

Map<String, dynamic> _wordTextDetails(
  _TextDraft draft, {
  int start = 0,
  int? end,
}) {
  final stop = end ?? draft.text.text.length;
  final text = draft.text.text.substring(start, stop);
  return {
    'utf16Length': text.length,
    'textSha256': _TextDraft._digest(text),
    'canReplace': draft.canReplace,
    'canStyle': draft.details?.canStyle == true,
    'truncated': false,
    'runs': [
      for (final run in draft._runs)
        if (run.start < stop && run.end > start)
          {
            'startUtf16': math.max(start, run.start) - start,
            'endUtf16': math.min(stop, run.end) - start,
            ...run.style,
          },
    ],
    'protectedRanges': [
      for (final range in draft._protected)
        if (range.start >= start && range.end <= stop)
          {
            'startUtf16': range.start - start,
            'endUtf16': range.end - start,
            'type': range.type,
          },
    ],
  };
}

Map<String, dynamic> _plainWordDetails(String text) => {
  'utf16Length': text.length,
  'textSha256': _TextDraft._digest(text),
  'canReplace': true,
  'canStyle': true,
  'truncated': false,
  'runs': [
    {
      'startUtf16': 0,
      'endUtf16': text.length,
      'fontSize': null,
      'bold': null,
      'italic': null,
      'underline': null,
      'fontFamily': null,
      'color': null,
    },
  ],
  'protectedRanges': <Object?>[],
};

bool _wordLiveTextMatches(
  _TextDraft expected,
  String text,
  WindowsOfficeTextDetails? details,
) {
  final old = expected.details;
  if (old == null) return details == null && text == expected.text.text;
  if (details == null ||
      !expected._validSnapshot ||
      details.truncated ||
      details.utf16Length != text.length ||
      details.textSha256 != _TextDraft._digest(text) ||
      !_TextDraft._validUtf16(text) ||
      !old.canReplace && details.canReplace ||
      !old.canStyle && details.canStyle)
    return false;
  var end = 0;
  for (final run in details.runs) {
    if (run.startUtf16 < end ||
        run.endUtf16 < run.startUtf16 ||
        !_TextDraft._boundary(text, run.startUtf16) ||
        !_TextDraft._boundary(text, run.endUtf16))
      return false;
    end = run.endUtf16;
  }
  end = 0;
  for (final range in details.protectedRanges) {
    if (range.startUtf16 < end ||
        range.endUtf16 < range.startUtf16 ||
        !_TextDraft._boundary(text, range.startUtf16) ||
        !_TextDraft._boundary(text, range.endUtf16))
      return false;
    end = range.endUtf16;
  }
  final runs = [
    for (final run in details.runs)
      (
        run.startUtf16,
        run.endUtf16,
        <String, Object?>{
          'fontSize': run.fontSize,
          'bold': run.bold,
          'italic': run.italic,
          'underline': run.underline,
          'fontFamily': run.fontFamily,
          'color': run.color,
        },
      ),
  ];
  bool sameStyle(Map<String, Object?>? left, Map<String, Object?>? right) =>
      left == null || right == null
      ? left == null && right == null
      : const [
          'fontSize',
          'bold',
          'italic',
          'underline',
          'fontFamily',
          'color',
        ].every((key) => left[key] == right[key]);
  bool literal(int a, int stop, int b, int finish) {
    if (expected.text.text.substring(a, stop) != text.substring(b, finish))
      return false;
    while (a < stop) {
      final left = expected._runs
          .where((run) => run.start <= a && run.end > a)
          .firstOrNull;
      final right = runs.where((run) => run.$1 <= b && run.$2 > b).firstOrNull;
      if (!sameStyle(left?.style, right?.$3)) return false;
      final nextLeft =
          left?.end ??
          expected._runs.where((run) => run.start > a).firstOrNull?.start ??
          stop;
      final nextRight =
          right?.$2 ??
          runs.where((run) => run.$1 > b).firstOrNull?.$1 ??
          finish;
      final count = math.min(
        math.min(nextLeft - a, stop - a),
        math.min(nextRight - b, finish - b),
      );
      if (count <= 0) return false;
      a += count;
      b += count;
    }
    return b == finish;
  }

  if (expected._protected.length != details.protectedRanges.length)
    return false;
  var a = 0, b = 0;
  for (var index = 0; index < expected._protected.length; index++) {
    final left = expected._protected[index],
        right = details.protectedRanges[index];
    if (left.type != right.type ||
        left.start < a ||
        left.end < left.start ||
        left.end > expected.text.text.length ||
        !literal(a, left.start, b, right.startUtf16))
      return false;
    if (left.type != 'TextField' &&
        expected.text.text.substring(left.start, left.end) !=
            text.substring(right.startUtf16, right.endUtf16))
      return false;
    a = left.end;
    b = right.endUtf16;
  }
  if (!literal(a, expected.text.text.length, b, text.length)) return false;
  if (text.isEmpty &&
      !sameStyle(expected._runs.firstOrNull?.style, runs.firstOrNull?.$3))
    return false;
  return true;
}

class _WordDocumentDraft {
  new(this.snapshot, this.onChanged, this.editor) {
    selectedOwnerId = bodyOwnerId;
    _blocks[bodyOwnerId] = [
      for (final block in snapshot.blocks!) (block.kind, block.id),
    ];
    for (final owner
        in snapshot.wordOwners ?? const <WindowsOfficeWordOwner>[]) {
      _blocks[owner.id] = [
        for (final block in owner.blocks) (block.kind, block.id),
      ];
    }
    _readNodes(snapshot);
    pageStyles = List.of(snapshot.pageStyles ?? const []);
    images = [
      for (final image
          in snapshot.wordImages ?? const <WindowsOfficeWordImage>[])
        _WordImage.fromSnapshot(image),
    ];
    imageTargets = snapshot.wordImageTargets == null
        ? null
        : List.of(snapshot.wordImageTargets!);
    usedIds.addAll([
      bodyOwnerId,
      for (final entry in _blocks.entries) ...[
        entry.key,
        for (final block in entry.value) block.$2,
      ],
      for (final node in nodes.values) node.id,
      for (final table in snapshot.tables) table.id,
      for (final style in pageStyles) style.id,
    ]);
    _imageIdsValid =
        images.map((image) => image.id).toSet().length == images.length &&
        images.every((image) => !usedIds.contains(image.id));
    usedIds.addAll(images.map((image) => image.id));
    activeId = snapshot.paragraphs.firstOrNull?.id;
    _stable = _capture();
  }

  void _readNodes(
    WindowsOfficeSnapshot source, {
    Set<String> newIds = const {},
  }) {
    for (final entry in [
      for (final paragraph in source.paragraphs) (bodyOwnerId, paragraph),
      for (final owner in source.wordOwners ?? const <WindowsOfficeWordOwner>[])
        for (final paragraph in owner.paragraphs) (owner.id, paragraph),
    ]) {
      final paragraph = entry.$2;
      final format = paragraph.paragraphFormat, structure = paragraph.structure;
      _addNode(
        ('paragraph', paragraph.id, ''),
        paragraph.text,
        paragraph.textDetails,
        {
          'styleName': format?.styleName,
          'alignment': format?.alignment,
          'listKind': format?.listKind,
          'listLevel': format?.listLevel,
          'pageBreakBefore': format?.pageBreakBefore,
        },
        {
          'split': structure?.canSplit == true,
          'delete': structure?.canDelete == true,
          'before': structure?.canInsertBefore == true,
          'after': structure?.canInsertAfter == true,
          'join': structure?.canJoinNext == true,
        },
        ownerId: entry.$1,
        isNew: newIds.contains(paragraph.id),
      );
    }
    for (final table in source.tables) {
      for (final cell in table.cells.entries) {
        _addNode(
          ('cell', table.id, cell.key),
          cell.value,
          table.cellTextDetails[cell.key],
          {},
          {},
          ownerId:
              table.ownerId ??
              (snapshot.bodyOwnerId == null ? bodyOwnerId : null),
        );
      }
    }
  }

  final WindowsOfficeSnapshot snapshot;
  final VoidCallback onChanged;
  final WindowsOfficeEditorState editor;
  late List<_WordImage> images;
  late List<WindowsOfficeWordImageTarget>? imageTargets;
  late bool _imageIdsValid;
  final imageAssets = <String, String>{};
  final _knownImageHashes = <String, String>{};
  late List<WindowsOfficePageStyle> pageStyles;
  String? pageStyleId;
  var pagePanelOpen = false;
  final pageInputs = <String, TextEditingController>{
    for (final property in [
      'width',
      'height',
      'leftMargin',
      'rightMargin',
      'topMargin',
      'bottomMargin',
    ])
      property: TextEditingController(),
  };
  var pageLandscape = false;
  String? pageError;
  var previewing = false;
  String? previewPath;
  _WordCheckpoint? _pendingGeometry;
  bool get locked =>
      previewing || _pendingGeometry != null || editor._pickingImage;
  bool get hasPendingGeometry => _pendingGeometry != null;
  WindowsOfficePageStyle? get pageStyle =>
      pageStyles.where((style) => style.id == pageStyleId).firstOrNull;
  bool get canEditPage =>
      pageStyle?.canEditGeometry == true &&
      pageStyle?.landscape != null &&
      pageStyle?.layoutSha256 != null &&
      _geometry(pageStyle!).values
          .every((value) => value != null && value.isFinite);
  bool get canOpenPages =>
      !editor._busy &&
      !locked &&
      !composing &&
      pageStyles.isNotEmpty &&
      editor.widget.onPreview != null;
  bool get canRefreshPreview =>
      !editor._busy &&
      !locked &&
      !composing &&
      editor.widget.onPreview != null &&
      operations.isNotEmpty;

  void _invalidatePreview() {
    previewPath = null;
    editor._showPreview = false;
  }

  final _blocks = <String, List<_WordBlock>>{};
  String get bodyOwnerId => snapshot.bodyOwnerId ?? 'body';
  late String selectedOwnerId;
  List<_WordBlock> get blocks => _blocks[selectedOwnerId]!;
  bool get isBody => selectedOwnerId == bodyOwnerId;
  final nodes = <_WordTarget, _WordNode>{};
  final usedIds = <String>{};
  final _journal = <_WordOp>[];
  final _undo = <_WordUndo>[];
  final _redo = <_WordUndo>[];
  late _WordCheckpoint _stable;
  String? activeId;
  String? _error;
  var _performing = false;
  var _disposed = false;
  var _restoring = false;

  List<WindowsOfficeOperation> get operations => [
    for (final entry in _journal) entry.operation,
  ];
  _WordNode? get active =>
      activeId == null ? null : nodes[('paragraph', activeId!, '')];
  bool get composing => nodes.values.any((node) => node.text._composing);
  String? get error =>
      _error ??
      nodes.values
          .map((node) => node.text.lastEditError)
          .whereType<String>()
          .firstOrNull;
  bool get canUndo =>
      (_pendingGeometry != null || _undo.isNotEmpty) &&
      !composing &&
      !editor._busy &&
      !previewing &&
      !editor._pickingImage;
  bool get canRedo =>
      _redo.isNotEmpty && !composing && !locked && !editor._busy;

  void selectOwner(String id) {
    if (_disposed || composing || locked || !_blocks.containsKey(id)) return;
    FocusManager.instance.primaryFocus?.unfocus();
    selectedOwnerId = id;
    activeId = blocks.where((block) => block.$1 == 'paragraph').firstOrNull?.$2;
    _stable = _capture();
    onChanged();
  }

  _WordNode _addNode(
    _WordTarget target,
    String text,
    WindowsOfficeTextDetails? details,
    Map<String, Object?> format,
    Map<String, bool> capabilities, {
    required String? ownerId,
    bool isNew = false,
  }) {
    final draft = _TextDraft(
      text,
      details: details,
      targetKind: target.$1,
      id: target.$2,
      cell: target.$1 == 'cell' ? target.$3 : null,
      onChanged: () => _draftChanged(target),
      canMergePrevious: () =>
          !_performing && _journal.lastOrNull?.owner == target,
      interceptInput: target.$1 == 'paragraph'
          ? (value) => _newline(target, value)
          : null,
    );
    final node = _WordNode(
      target,
      draft,
      Map.of(format),
      Map.of(capabilities),
      ownerId: ownerId,
      isNew: isNew,
    );
    nodes[target] = node;
    node.focus.addListener(() {
      if (_disposed || _restoring || !node.focus.hasFocus) return;
      if (node.ownerId case final owner? when _blocks.containsKey(owner)) {
        selectedOwnerId = owner;
      }
      activeId = target.$1 == 'paragraph' ? target.$2 : null;
      if (!_performing && !composing) _stable = _capture();
      onChanged();
    });
    node.focus.onKeyEvent = (_, event) => _key(node, event);
    return node;
  }

  KeyEventResult _key(_WordNode node, KeyEvent event) {
    if (event is! KeyDownEvent || composing) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        redo();
      } else {
        undo();
      }
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isControlPressed &&
        event.logicalKey == LogicalKeyboardKey.keyY) {
      redo();
      return KeyEventResult.handled;
    }
    if (locked) return KeyEventResult.ignored;
    if (node.target.$1 != 'paragraph' || !node.text._selection.isCollapsed)
      return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        node.text._selection.start == 0) {
      final index = _index(node);
      if (index > 0 && blocks[index - 1].$1 == 'paragraph') {
        final before = _capture();
        activeId = blocks[index - 1].$2;
        if (canJoin) {
          join(undoBefore: before);
          return KeyEventResult.handled;
        }
        activeId = node.id;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.delete &&
        node.text._selection.start == node.text.text.text.length) {
      activeId = node.id;
      if (canJoin) {
        join();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _draftChanged(_WordTarget target) {
    if (_disposed || _restoring) return;
    final node = nodes[target];
    if (node == null) return;
    final current = node.text.operations, previous = node.observed;
    var prefix = 0;
    while (prefix < current.length &&
        prefix < previous.length &&
        identical(current[prefix], previous[prefix])) {
      prefix++;
    }
    final changed = prefix != current.length || prefix != previous.length;
    final merged =
        changed &&
        current.length == previous.length &&
        prefix == current.length - 1;
    if (changed) {
      _shiftImageText(node);
      _invalidatePreview();
      if (merged &&
          _journal.lastOrNull?.owner == target &&
          _journal.lastOrNull?.localIndex == prefix) {
        _journal[_journal.length - 1] = _WordOp(
          current[prefix],
          target,
          prefix,
        );
      } else {
        for (var index = prefix; index < current.length; index++) {
          _journal.add(_WordOp(current[index], target, index));
        }
      }
      node.observed = List.of(current);
      _error = null;
    }
    if (_performing) return;
    if (!composing) {
      final after = _capture();
      if (changed) {
        if (merged && _undo.lastOrNull?.owner == target && _redo.isEmpty) {
          _undo.last.after = after;
        } else {
          _remember(_stable, after, target);
        }
        _redo.clear();
      }
      _stable = after;
    }
    onChanged();
  }

  void _shiftImageText(_WordNode node) {
    if (node.target.$1 != 'paragraph') return;
    final before = _stable.nodes
        .where((state) => state.target == node.target)
        .singleOrNull
        ?.text;
    final after = node.text.text.text;
    if (before == null || before == after) return;
    var start = 0;
    while (start < before.length &&
        start < after.length &&
        before.codeUnitAt(start) == after.codeUnitAt(start)) {
      start++;
    }
    while (!_TextDraft._boundary(before, start) ||
        !_TextDraft._boundary(after, start)) {
      start--;
    }
    var end = before.length, nextEnd = after.length;
    while (end > start &&
        nextEnd > start &&
        before.codeUnitAt(end - 1) == after.codeUnitAt(nextEnd - 1)) {
      end--;
      nextEnd--;
    }
    while (!_TextDraft._boundary(before, end) ||
        !_TextDraft._boundary(after, nextEnd)) {
      end++;
      nextEnd++;
    }
    final delta = nextEnd - end;
    if (delta == 0) return;
    for (var index = 0; index < images.length; index++) {
      final image = images[index];
      final offset = image.offsetUtf16;
      if (image.ownerId == node.ownerId &&
          image.ownerId != null &&
          image.paragraphId == node.id &&
          offset != null &&
          offset >= end) {
        images[index] = image.at(image.ownerId!, node.id, offset + delta);
      }
    }
  }

  bool _newline(_WordTarget target, TextEditingValue incoming) {
    if (_disposed || _restoring) return false;
    final node = nodes[target];
    if (node == null ||
        incoming.text == node.text._currentText ||
        !incoming.text.contains(RegExp(r'[\r\n]')))
      return false;
    final draft = node.text, original = draft._currentText;
    final offset = incoming.text.indexOf('\n');
    final oneNewline =
        offset >= 0 &&
        incoming.text.indexOf('\n', offset + 1) < 0 &&
        !incoming.text.contains('\r');
    final confirmed =
        !incoming.composing.isValid || incoming.composing.isCollapsed;
    final simple =
        oneNewline &&
        incoming.text.replaceRange(offset, offset + 1, '') == original;
    draft._updating = true;
    draft.text.value = draft._acceptedValue;
    draft._updating = false;
    if (!confirmed ||
        !simple ||
        !_canSplit(node, TextSelection.collapsed(offset: offset))) {
      _error = '이 위치의 줄바꿈은 적용하지 않았습니다. 입력을 확정하고 안전한 문단 위치를 선택하세요.';
      scheduleMicrotask(() {
        if (!_disposed) onChanged();
      });
      return true;
    }
    draft._selection = TextSelection.collapsed(offset: offset);
    draft._updating = true;
    draft.text.selection = draft._selection;
    draft._acceptedValue = draft.text.value;
    draft._updating = false;
    scheduleMicrotask(() {
      if (!_disposed &&
          identical(nodes[target], node) &&
          node.text._currentText == original) {
        activeId = node.id;
        split();
      }
    });
    return true;
  }

  _WordCheckpoint _capture() => _WordCheckpoint(
    {for (final entry in _blocks.entries) entry.key: List.of(entry.value)},
    [for (final node in nodes.values) _WordNodeState(node)],
    List.of(_journal),
    selectedOwnerId,
    activeId,
    List.of(pageStyles),
    pageStyleId,
    List.of(images),
    Map.of(imageAssets),
    imageTargets == null ? null : List.of(imageTargets!),
  );

  void _remember(
    _WordCheckpoint before,
    _WordCheckpoint after, [
    _WordTarget? owner,
  ]) {
    _undo.add(_WordUndo(before, after, owner));
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
    editor._pruneAssets();
  }

  Set<String> get pinnedAssets {
    final result = <String>{};
    void collect(List<_WordOp> journal) {
      for (final entry in journal) {
        final assetId = entry.operation.toJson()['assetId'];
        if (assetId is String) result.add(assetId);
      }
    }

    collect(_journal);
    for (final entry in [..._undo, ..._redo]) {
      collect(entry.before.journal);
      collect(entry.after.journal);
    }
    return result;
  }

  bool get _canMutatePhotos =>
      !_disposed &&
      _imageIdsValid &&
      snapshot.wordImages != null &&
      !locked &&
      !composing &&
      !editor._busy &&
      editor.widget.allowFormatting;

  (_WordNode, int)? _imageTarget({required bool moving}) {
    if (!_canMutatePhotos || !isBody || snapshot.bodyOwnerId == null)
      return null;
    final node = active;
    if (node == null ||
        node.ownerId != bodyOwnerId ||
        !node.text.isRich ||
        !node.text.canReplace ||
        !node.text._validSnapshot)
      return null;
    final targets = imageTargets
        ?.where(
          (target) =>
              target.ownerId == bodyOwnerId && target.paragraphId == node.id,
        )
        .toList();
    if (targets == null ||
        targets.length != 1 ||
        !(moving ? targets.single.canMoveHere : targets.single.canAdd))
      return null;
    final selection = node.text._selection;
    if (!selection.isValid ||
        !selection.isCollapsed ||
        !_safePoint(node, selection.start))
      return null;
    return (node, selection.start);
  }

  bool get canAddImage =>
      editor.widget.onCommitWithAssets != null &&
      _imageTarget(moving: false) != null;

  _WordNode? _imageFrame(_WordImage image) {
    if (image.ownerId != bodyOwnerId ||
        image.paragraphId == null ||
        image.anchorType != 'AS_CHARACTER' ||
        image.offsetUtf16 == null ||
        image.tableId != null ||
        image.cell != null)
      return null;
    final node = nodes[('paragraph', image.paragraphId!, '')];
    if (node == null ||
        node.ownerId != image.ownerId ||
        !node.text._validSnapshot ||
        !image.isAdded &&
            !RegExp(r'^[0-9a-f]{64}$')
                .hasMatch(image.nativeGraphicSha256 ?? ''))
      return null;
    final samePoint = images.where(
      (other) =>
          other.ownerId == image.ownerId &&
          other.paragraphId == image.paragraphId &&
          other.offsetUtf16 == image.offsetUtf16,
    );
    final frames = node.text._protected.where(
      (range) =>
          range.type == 'Frame' &&
          range.start == image.offsetUtf16 &&
          range.end == image.offsetUtf16,
    );
    return samePoint.length == 1 && frames.length == 1 ? node : null;
  }

  bool canMoveImage(String id) {
    final image = images.where((image) => image.id == id).singleOrNull;
    return _canMutatePhotos &&
        image?.canMove == true &&
        _imageFrame(image!) != null &&
        _imageTarget(moving: true) != null;
  }

  bool canDeleteImage(String id) {
    final image = images.where((image) => image.id == id).singleOrNull;
    return _canMutatePhotos &&
        image?.canDelete == true &&
        _imageFrame(image!) != null;
  }

  void _addImageFrame(_WordNode node, int offset) {
    node.text._protected.add(_ProtectedDraft(offset, offset, 'Frame'));
    node.text._protected.sort(
      (a, b) => a.start != b.start
          ? a.start.compareTo(b.start)
          : a.end.compareTo(b.end),
    );
  }

  void _removeImageFrame(_WordNode node, int offset) {
    final index = node.text._protected.indexWhere(
      (range) =>
          range.type == 'Frame' && range.start == offset && range.end == offset,
    );
    node.text._protected.removeAt(index);
  }

  void addImage(String assetId, WindowsOfficeImageAsset asset) {
    if (!canAddImage) return;
    final target = _imageTarget(moving: false)!;
    var width = 25.4, height = width * asset.height / asset.width;
    if (height > 1000) {
      width *= 1000 / height;
      height = 1000;
    }
    width = double.parse(width.clamp(.01, 1000).toStringAsFixed(2));
    height = double.parse(height.clamp(.01, 1000).toStringAsFixed(2));
    _action(() {
      final id = _newId();
      images.add(
        _WordImage(
          id: id,
          ownerId: bodyOwnerId,
          paragraphId: target.$1.id,
          anchorType: 'AS_CHARACTER',
          offsetUtf16: target.$2,
          width: width,
          height: height,
          canMove: true,
          canDelete: true,
          isAdded: true,
        ),
      );
      imageAssets[id] = assetId;
      _addImageFrame(target.$1, target.$2);
      _journal.add(
        _WordOp(
          WindowsOfficeOperation.wordImageAdd(
            id: id,
            ownerId: bodyOwnerId,
            paragraphId: target.$1.id,
            offsetUtf16: target.$2,
            expectedTextSha256: _TextDraft._digest(target.$1.text.text.text),
            assetId: assetId,
            width: width,
            height: height,
          ),
        ),
      );
    });
  }

  void moveImage(String id) {
    if (!canMoveImage(id)) return;
    final index = images.indexWhere((image) => image.id == id);
    final image = images[index];
    final source = _imageFrame(image)!;
    final target = _imageTarget(moving: true)!;
    _action(() {
      _removeImageFrame(source, image.offsetUtf16!);
      _addImageFrame(target.$1, target.$2);
      images[index] = image.at(bodyOwnerId, target.$1.id, target.$2);
      _journal.add(
        _WordOp(
          WindowsOfficeOperation.wordImageMove(
            id: id,
            ownerId: bodyOwnerId,
            paragraphId: target.$1.id,
            offsetUtf16: target.$2,
            expectedTextSha256: _TextDraft._digest(target.$1.text.text.text),
          ),
        ),
      );
    });
  }

  void deleteImage(String id) {
    if (!canDeleteImage(id)) return;
    final image = images.firstWhere((image) => image.id == id);
    final node = _imageFrame(image)!;
    _action(() {
      _removeImageFrame(node, image.offsetUtf16!);
      images.removeWhere((image) => image.id == id);
      imageAssets.remove(id);
      _journal.add(_WordOp(WindowsOfficeOperation.wordImageDelete(id: id)));
    });
  }

  bool canReplaceImage(String id) {
    final image = images.where((image) => image.id == id).singleOrNull;
    if (!_imageIdsValid ||
        image == null ||
        locked ||
        composing ||
        editor._busy ||
        !editor.widget.allowFormatting ||
        editor.widget.onCommitWithAssets == null ||
        image.image?.canReplace != true ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(image.nativeGraphicSha256 ?? ''))
      return false;
    final node = image.paragraphId != null
        ? nodes[('paragraph', image.paragraphId!, '')]
        : nodes[('cell', image.tableId ?? '', image.cell ?? '')];
    return node != null &&
        image.ownerId != null &&
        node.ownerId == image.ownerId;
  }

  void replaceImage(String id, String assetId) {
    if (!canReplaceImage(id)) return;
    _action(() {
      imageAssets[id] = assetId;
      _journal.add(
        _WordOp(WindowsOfficeOperation.imageReplace(id: id, assetId: assetId)),
      );
    });
  }

  void _verifyImages(WindowsOfficeSnapshot live, void Function(bool) check) {
    if (snapshot.wordImages == null) return;
    final incoming = live.wordImages;
    check(
      incoming != null &&
          incoming.length == images.length &&
          incoming.map((image) => image.id).toSet().length == images.length,
    );
    for (final image in images) {
      final next = incoming!.where((next) => next.id == image.id).singleOrNull;
      check(next != null);
      check(
        (
              next!.ownerId,
              next.paragraphId,
              next.tableId,
              next.cell,
              next.anchorType,
              next.width,
              next.height,
            ) ==
            (
              image.ownerId,
              image.paragraphId,
              image.tableId,
              image.cell,
              image.anchorType,
              image.width,
              image.height,
            ),
      );
      check(
        next.image?.canReplace ==
            (image.isAdded ? true : image.image?.canReplace),
      );
      if (image.offsetUtf16 != null)
        check(next.offsetUtf16 == image.offsetUtf16);
      check(next.canMove == image.canMove && next.canDelete == image.canDelete);
      final assetId = imageAssets[image.id];
      if (assetId == null) {
        check(next.nativeGraphicSha256 == image.nativeGraphicSha256);
      } else {
        final asset = editor._imageAssets[assetId];
        check(
          asset != null &&
              next.image?.mimeType == asset.mimeType &&
              next.image?.pixelWidth == asset.width &&
              next.image?.pixelHeight == asset.height &&
              RegExp(r'^[0-9a-f]{64}$')
                  .hasMatch(next.nativeGraphicSha256 ?? ''),
        );
        final known = _knownImageHashes[assetId];
        if (known != null) check(next.nativeGraphicSha256 == known);
      }
    }
  }

  void _action(VoidCallback change, {_WordCheckpoint? before}) {
    if (_disposed || composing || locked) return;
    _invalidatePreview();
    final checkpoint = before ?? _capture();
    _performing = true;
    _error = null;
    try {
      change();
    } finally {
      _performing = false;
    }
    final after = _capture();
    _remember(checkpoint, after);
    _stable = after;
    onChanged();
  }

  String _newId() {
    var id = newId();
    while (!usedIds.add(id)) {
      id = newId();
    }
    return id;
  }

  int _index(_WordNode node) => blocks.indexOf(('paragraph', node.id));
  int get _paragraphCount =>
      blocks.where((block) => block.$1 == 'paragraph').length;
  bool _plain(_WordNode node) =>
      node.text.isRich && node.text.canReplace && node.text._protected.isEmpty;
  bool _safePoint(_WordNode node, int offset) =>
      _TextDraft._boundary(node.text.text.text, offset) &&
      !node.text._protected.any(
        (range) => offset >= range.start && offset <= range.end,
      );
  bool _canSplit(_WordNode node, TextSelection selection) =>
      !composing &&
      node.capabilities['split'] == true &&
      node.text.canReplace &&
      selection.isValid &&
      _safePoint(node, selection.start) &&
      _safePoint(node, selection.end) &&
      !node.text._protectedOverlap(selection.start, selection.end);
  bool get canSplit =>
      active != null && _canSplit(active!, active!.text._selection);
  bool get canDelete =>
      active != null &&
      !composing &&
      _paragraphCount > 1 &&
      _index(active!) < blocks.length - 1 &&
      active!.capabilities['delete'] == true &&
      _plain(active!);
  bool canInsert(bool before) =>
      active != null &&
      !composing &&
      active!.capabilities[before ? 'before' : 'after'] == true &&
      active!.text.canReplace;

  _WordNode? _next(_WordNode node) {
    final index = _index(node);
    if (index < 0 ||
        index + 1 >= blocks.length ||
        blocks[index + 1].$1 != 'paragraph')
      return null;
    return nodes[('paragraph', blocks[index + 1].$2, '')];
  }

  bool get canJoin {
    final left = active;
    if (left == null || composing || !_plain(left)) return false;
    final right = _next(left);
    return right != null &&
        _plain(right) &&
        left.capabilities['split'] == true &&
        right.capabilities['split'] == true &&
        (left.capabilities['join'] == true || left.isNew || right.isNew);
  }

  void _focus(_WordNode node, TextSelection selection) {
    activeId = node.id;
    node.text._selection = selection;
    node.text._updating = true;
    node.text.text.selection = selection;
    node.text._acceptedValue = node.text.text.value;
    node.text._updating = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed &&
          selectedOwnerId == node.ownerId &&
          identical(nodes[node.target], node))
        node.focus.requestFocus();
    });
  }

  void _replaceDraft(
    _WordNode node,
    String text,
    Map<String, dynamic> details,
  ) {
    final old = node.text;
    node.text = _TextDraft(
      text,
      details: WindowsOfficeTextDetails.fromJson(details),
      targetKind: node.target.$1,
      id: node.id,
      cell: node.target.$1 == 'cell' ? node.target.$3 : null,
      onChanged: () => _draftChanged(node.target),
      canMergePrevious: () =>
          !_performing && _journal.lastOrNull?.owner == node.target,
      interceptInput: node.target.$1 == 'paragraph'
          ? (value) => _newline(node.target, value)
          : null,
    );
    node.observed = [];
    old.dispose();
  }

  static const _newCapabilities = {
    'split': true,
    'delete': true,
    'before': true,
    'after': true,
    'join': true,
  };

  void split() {
    final node = active;
    if (node == null || !canSplit) return;
    _action(() {
      final selection = node.text._selection;
      final offset = selection.start;
      if (!selection.isCollapsed) {
        node.text.text.value = TextEditingValue(
          text: node.text.text.text.replaceRange(
            selection.start,
            selection.end,
            '',
          ),
          selection: TextSelection.collapsed(offset: offset),
        );
      }
      final original = node.text.text.text;
      final left = _wordTextDetails(node.text, end: offset),
          right = _wordTextDetails(node.text, start: offset);
      final id = _newId();
      _journal.add(
        _WordOp(
          WindowsOfficeOperation.paragraphSplit(
            id: node.id,
            newId: id,
            offsetUtf16: offset,
            expectedTextSha256: _TextDraft._digest(original),
          ),
        ),
      );
      _replaceDraft(node, original.substring(0, offset), left);
      final added = _addNode(
        ('paragraph', id, ''),
        original.substring(offset),
        WindowsOfficeTextDetails.fromJson(right),
        {...node.format, 'pageBreakBefore': false},
        _newCapabilities,
        ownerId: node.ownerId,
        isNew: true,
      );
      blocks.insert(_index(node) + 1, ('paragraph', id));
      _focus(added, const TextSelection.collapsed(offset: 0));
    });
  }

  void insert(bool before) {
    final reference = active;
    if (reference == null || !canInsert(before)) return;
    _action(() {
      final id = _newId();
      _journal.add(
        _WordOp(
          WindowsOfficeOperation.paragraphInsert(
            id: id,
            referenceId: reference.id,
            position: before ? 'before' : 'after',
            expectedTextSha256: _TextDraft._digest(reference.text.text.text),
            text: '',
          ),
        ),
      );
      final added = _addNode(
        ('paragraph', id, ''),
        '',
        WindowsOfficeTextDetails.fromJson(_plainWordDetails('')),
        {
          'styleName': reference.format['styleName'],
          'alignment': 'other',
          'listKind': 'other',
          'listLevel': null,
          'pageBreakBefore': false,
        },
        _newCapabilities,
        ownerId: reference.ownerId,
        isNew: true,
      );
      blocks.insert(_index(reference) + (before ? 0 : 1), ('paragraph', id));
      _focus(added, const TextSelection.collapsed(offset: 0));
    });
  }

  void delete() {
    final node = active;
    if (node == null || !canDelete) return;
    _action(() {
      final index = _index(node);
      final creation = _journal.indexWhere(
        (entry) =>
            entry.operation.toJson()['op'] == 'paragraphInsert' &&
            entry.operation.toJson()['id'] == node.id,
      );
      if (creation >= 0 &&
          _journal
              .skip(creation + 1)
              .every((entry) => entry.owner == node.target)) {
        _journal.removeRange(creation, _journal.length);
      } else {
        _journal.add(
          _WordOp(
            WindowsOfficeOperation.paragraphDelete(
              id: node.id,
              expectedTextSha256: _TextDraft._digest(node.text.text.text),
            ),
          ),
        );
      }
      blocks.removeAt(index);
      nodes.remove(node.target);
      node.dispose();
      final target =
          blocks
              .take(index)
              .where((block) => block.$1 == 'paragraph')
              .lastOrNull ??
          blocks.where((block) => block.$1 == 'paragraph').first;
      final next = nodes[('paragraph', target.$2, '')]!;
      _focus(next, TextSelection.collapsed(offset: next.text.text.text.length));
    });
  }

  void join({_WordCheckpoint? undoBefore}) {
    final left = active;
    if (left == null || !canJoin) return;
    final right = _next(left)!;
    _action(() {
      final offset = left.text.text.text.length;
      final mergedText = left.text.text.text + right.text.text.text;
      final details = _wordTextDetails(left.text),
          tail = _wordTextDetails(right.text);
      details['utf16Length'] = mergedText.length;
      details['textSha256'] = _TextDraft._digest(mergedText);
      details['runs'] = <Map<String, Object?>>[
        for (final run in details['runs'] as List)
          Map<String, Object?>.from(run as Map),
        for (final run in tail['runs'] as List)
          {
            ...Map<String, dynamic>.from(run as Map),
            'startUtf16': (run['startUtf16'] as int) + offset,
            'endUtf16': (run['endUtf16'] as int) + offset,
          },
      ];
      _journal.add(
        _WordOp(
          WindowsOfficeOperation.paragraphJoin(
            id: left.id,
            nextId: right.id,
            expectedTextSha256: _TextDraft._digest(left.text.text.text),
            expectedNextTextSha256: _TextDraft._digest(right.text.text.text),
          ),
        ),
      );
      _replaceDraft(left, mergedText, details);
      blocks.remove(('paragraph', right.id));
      nodes.remove(right.target);
      right.dispose();
      _focus(left, TextSelection.collapsed(offset: offset));
    }, before: undoBefore);
  }

  void format(Map<String, Object?> changes) {
    final node = active;
    if (node == null ||
        composing ||
        (!isBody && changes.containsKey('pageBreakBefore')))
      return;
    _action(() {
      _journal.add(
        _WordOp(
          WindowsOfficeOperation.paragraphFormat(
            id: node.id,
            expectedTextSha256: _TextDraft._digest(node.text.text.text),
            styleName: changes['styleName'] as String?,
            alignment: changes['alignment'] as String?,
            listKind: changes['listKind'] as String?,
            listLevel: changes['listLevel'] as int?,
            pageBreakBefore: changes['pageBreakBefore'] as bool?,
          ),
        ),
      );
      node.format.addAll(changes);
    });
  }

  Map<String, double?> _geometry(WindowsOfficePageStyle style) => {
    'width': style.width,
    'height': style.height,
    'leftMargin': style.leftMargin,
    'rightMargin': style.rightMargin,
    'topMargin': style.topMargin,
    'bottomMargin': style.bottomMargin,
  };

  void openPages() {
    if (!canOpenPages) return;
    pagePanelOpen = true;
    pageError = null;
    _loadPageInputs();
    onChanged();
  }

  void selectPageStyle(String id) {
    if (locked || composing || !pageStyles.any((style) => style.id == id))
      return;
    pageStyleId = id;
    pageError = null;
    _loadPageInputs();
    onChanged();
  }

  void _loadPageInputs() {
    final style = pageStyle;
    final values = style == null ? <String, double?>{} : _geometry(style);
    for (final entry in pageInputs.entries) {
      final value = values[entry.key];
      entry.value.text = value == null ? '' : value.toStringAsFixed(2);
    }
    pageLandscape = style?.landscape == true;
  }

  void direction(bool landscape) {
    if (locked || !canEditPage) return;
    final width = double.tryParse(pageInputs['width']!.text);
    final height = double.tryParse(pageInputs['height']!.text);
    if (width != null && height != null && width.isFinite && height.isFinite) {
      pageInputs['width']!.text =
          (landscape ? math.max(width, height) : math.min(width, height))
              .toString();
      pageInputs['height']!.text =
          (landscape ? math.min(width, height) : math.max(width, height))
              .toString();
    }
    pageLandscape = landscape;
    onChanged();
  }

  Future<void> applyPage() async {
    if (locked || composing || editor._busy || !canEditPage) return;
    final style = pageStyle!;
    final values = <String, double>{};
    try {
      for (final entry in pageInputs.entries) {
        final text = entry.value.text.trim();
        final value = double.tryParse(text);
        if (!RegExp(r'^\+?(?:\d+(?:\.\d{1,2})?|\.\d{1,2})$').hasMatch(text) ||
            value == null ||
            !value.isFinite) {
          throw const FormatException('크기와 여백을 소수점 두 자리 이하의 mm 숫자로 입력하세요.');
        }
        values[entry.key] = value;
      }
      final width = values['width']!, height = values['height']!;
      if (width <= 0 ||
          height <= 0 ||
          width > 1000 ||
          height > 1000 ||
          (pageLandscape ? width <= height : height <= width)) {
        throw const FormatException(
          '용지 크기와 방향을 확인하세요. 크기는 0보다 크고 1000mm 이하여야 합니다.',
        );
      }
      if (values.entries.any(
            (entry) => entry.key.endsWith('Margin') && entry.value < 0,
          ) ||
          values['leftMargin']! + values['rightMargin']! >= width ||
          values['topMargin']! + values['bottomMargin']! >= height) {
        throw const FormatException('여백의 합은 용지 크기보다 작아야 합니다.');
      }
      if (style.layoutSha256 == null ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(style.layoutSha256!)) {
        throw const FormatException('현재 페이지 설정을 확인하지 못했습니다. 문서를 다시 여세요.');
      }
      final old = _geometry(style);
      final sizeChanged =
          width != style.width ||
          height != style.height ||
          pageLandscape != style.landscape;
      final changes = {
        for (final entry in values.entries)
          if (entry.value != old[entry.key]) entry.key: entry.value,
      };
      if (changes.isEmpty && !sizeChanged) {
        pagePanelOpen = false;
        onChanged();
        return;
      }
      validate();
      _pendingGeometry = _capture();
      _journal.add(
        _WordOp(
          WindowsOfficeOperation.pageGeometry(
            id: style.id,
            expectedLayoutSha256: style.layoutSha256!,
            width: sizeChanged ? width : null,
            height: sizeChanged ? height : null,
            landscape: sizeChanged ? pageLandscape : null,
            leftMargin: changes['leftMargin'],
            rightMargin: changes['rightMargin'],
            topMargin: changes['topMargin'],
            bottomMargin: changes['bottomMargin'],
          ),
        ),
      );
      _redo.clear();
      _invalidatePreview();
      pageError = null;
    } catch (error) {
      pageError = '$error';
      onChanged();
      return;
    }
    await refreshPagePreview();
  }

  void _verifyLive(WindowsOfficeDraftPreview result) {
    final live = result.snapshot;
    void check(bool valid) {
      if (!valid) throw const FormatException('현재 문서의 영역과 일치하지 않는 미리보기입니다.');
    }

    void checkDetails(
      _WordTarget target,
      String text,
      WindowsOfficeTextDetails? details,
    ) {
      check(_wordLiveTextMatches(nodes[target]!.text, text, details));
    }

    check(
      result.baseSourceSha256 == snapshot.sourceSha256 &&
          live.sourceSha256 == snapshot.sourceSha256 &&
          live.kind == 'word' &&
          live.bodyOwnerId == snapshot.bodyOwnerId &&
          result.pdfPath.isNotEmpty &&
          result.signature.isNotEmpty &&
          live.blocks != null &&
          live.wordOwners != null &&
          live.pageStyles != null,
    );
    _verifyImages(live, check);
    final scopes = {
      bodyOwnerId: live.blocks!,
      for (final owner in live.wordOwners!) owner.id: owner.blocks,
    };
    check(
      scopes.length == _blocks.length &&
          scopes.keys.toSet().containsAll(_blocks.keys),
    );
    for (final entry in scopes.entries) {
      check(
        listEquals([
          for (final block in entry.value) (block.kind, block.id),
        ], _blocks[entry.key]),
      );
    }
    final owners = snapshot.wordOwners ?? const <WindowsOfficeWordOwner>[];
    check(live.wordOwners!.length == owners.length);
    for (final old in owners) {
      final owner = live.wordOwners!
          .where((owner) => owner.id == old.id)
          .singleOrNull;
      check(owner != null);
      check(
        owner!.kind == old.kind &&
            listEquals(owner.tableIds, old.tableIds) &&
            listEquals(
              [
                for (final ref in owner.references)
                  (ref.pageStyleId, ref.variant),
              ],
              [
                for (final ref in old.references)
                  (ref.pageStyleId, ref.variant),
              ],
            ),
      );
    }
    final returned = <_WordTarget>{};
    for (final entry in [
      (bodyOwnerId, live.paragraphs),
      for (final owner in live.wordOwners!) (owner.id, owner.paragraphs),
    ]) {
      check(
        listEquals(
          entry.$2.map((paragraph) => paragraph.id).toList(),
          _blocks[entry.$1]!
              .where((block) => block.$1 == 'paragraph')
              .map((block) => block.$2)
              .toList(),
        ),
      );
      for (final paragraph in entry.$2) {
        final target = ('paragraph', paragraph.id, '');
        check(
          returned.add(target) &&
              paragraph.ownerId == entry.$1 &&
              nodes.containsKey(target),
        );
        checkDetails(target, paragraph.text, paragraph.textDetails);
        final format = paragraph.paragraphFormat;
        final actualFormat = <String, Object?>{
          'styleName': format?.styleName,
          'alignment': format?.alignment,
          'listKind': format?.listKind,
          'listLevel': format?.listLevel,
          'pageBreakBefore': format?.pageBreakBefore,
        };
        for (final expected in nodes[target]!.format.entries) {
          if (expected.value != null && expected.value != 'other') {
            check(expected.value == actualFormat[expected.key]);
          }
        }
      }
    }
    check(
      listEquals(
        live.tables.map((table) => table.id).toList(),
        snapshot.tables.map((table) => table.id).toList(),
      ),
    );
    for (final table in live.tables) {
      final old = snapshot.tables.firstWhere((old) => old.id == table.id);
      check(
        table.ownerId == old.ownerId &&
            table.cells.length == old.cells.length &&
            table.cells.keys.toSet().containsAll(old.cells.keys),
      );
      for (final cell in table.cells.keys) {
        final target = ('cell', table.id, cell);
        check(returned.add(target) && nodes.containsKey(target));
        checkDetails(target, table.cells[cell]!, table.cellTextDetails[cell]);
      }
    }
    check(returned.length == nodes.length && returned.containsAll(nodes.keys));
    check(
      live.pageStyles!.length == pageStyles.length &&
          live.pageStyles!.map((style) => style.id).toSet().length ==
              pageStyles.length,
    );
    for (final style in pageStyles) {
      final next = live.pageStyles!
          .where((next) => next.id == style.id)
          .singleOrNull;
      check(next != null);
      check(next!.regions.length == style.regions.length);
      for (final region in style.regions.entries) {
        final values = next.regions[region.key];
        check(values != null && values.length == region.value.length);
        for (final value in region.value.entries)
          check(values![value.key] == value.value);
      }
      check(
        next.layoutSha256 != null &&
            RegExp(r'^[0-9a-f]{64}$').hasMatch(next.layoutSha256!),
      );
      if (style.id == pageStyleId) {
        final values = _geometry(next);
        check(values.values.every((value) => value != null && value.isFinite));
        final width = values['width']!, height = values['height']!;
        check(
          width > 0 &&
              height > 0 &&
              width <= 1000 &&
              height <= 1000 &&
              next.landscape != null &&
              (next.landscape! ? width > height : height > width) &&
              values.entries.every(
                (entry) => !entry.key.endsWith('Margin') || entry.value! >= 0,
              ) &&
              values['leftMargin']! + values['rightMargin']! < width &&
              values['topMargin']! + values['bottomMargin']! < height,
        );
      }
    }
  }

  Future<void> refreshPagePreview() async {
    final callback = editor.widget.onPreview;
    if (_disposed ||
        previewing ||
        composing ||
        editor._busy ||
        callback == null ||
        operations.isEmpty)
      return;
    final generation = editor._generation;
    previewing = true;
    pageError = null;
    onChanged();
    bool current() =>
        !_disposed &&
        editor.mounted &&
        identical(editor._wordDraft, this) &&
        generation == editor._generation;
    try {
      final result = await callback(
        List.unmodifiable(operations),
        Map.unmodifiable({
          for (final entry in editor._imageAssets.entries)
            if (operations.any(
              (operation) => operation.toJson()['assetId'] == entry.key,
            ))
              entry.key: entry.value,
        }),
      );
      if (!current()) return;
      _verifyLive(result);
      final selections = {
        for (final node in nodes.values) node.target: node.text._selection,
      };
      final validity = {
        for (final node in nodes.values) node.target: node.text._validSnapshot,
      };
      final newIds = {
        for (final node in nodes.values)
          if (node.isNew) node.id,
      };
      _restoring = true;
      for (final node in nodes.values) node.dispose();
      nodes.clear();
      _readNodes(result.snapshot, newIds: newIds);
      for (final node in nodes.values) {
        node.text._validSnapshot =
            node.text._validSnapshot && validity[node.target] == true;
        final selection = selections[node.target];
        if (selection != null &&
            selection.isValid &&
            selection.end <= node.text.text.text.length) {
          node.text._updating = true;
          node.text.text.selection = selection;
          node.text._selection = selection;
          node.text._acceptedValue = node.text.text.value;
          node.text._updating = false;
        }
      }
      pageStyles = List.of(result.snapshot.pageStyles!);
      if (snapshot.wordImages != null) {
        images = [
          for (final image in result.snapshot.wordImages!)
            _WordImage.fromSnapshot(image),
        ];
        for (final image in images) {
          final assetId = imageAssets[image.id];
          if (assetId != null)
            _knownImageHashes[assetId] = image.nativeGraphicSha256!;
        }
      }
      imageTargets = result.snapshot.wordImageTargets == null
          ? null
          : List.of(result.snapshot.wordImageTargets!);
      _restoring = false;
      final before = _pendingGeometry;
      _pendingGeometry = null;
      previewing = false;
      pagePanelOpen = false;
      previewPath = result.pdfPath;
      final after = _capture();
      if (before != null) _remember(before, after);
      _stable = after;
      _loadPageInputs();
    } catch (error) {
      if (current()) {
        _restoring = false;
        pageError = '미리보기를 만들지 못했습니다. 편집 내용은 남아 있습니다.\n$error';
      }
    } finally {
      if (current()) {
        previewing = false;
        onChanged();
      }
    }
  }

  void undo() {
    if (!canUndo) return;
    if (_pendingGeometry case final before?) {
      _pendingGeometry = null;
      pageError = null;
      _restore(before);
      return;
    }
    final entry = _undo.removeLast();
    _redo.add(entry);
    _restore(entry.before);
  }

  void redo() {
    if (!canRedo) return;
    final entry = _redo.removeLast();
    _undo.add(entry);
    _restore(entry.after);
  }

  void _restore(_WordCheckpoint checkpoint) {
    _invalidatePreview();
    pageStyles = List.of(checkpoint.pageStyles);
    pageStyleId = checkpoint.pageStyleId;
    images = List.of(checkpoint.images);
    imageTargets = checkpoint.imageTargets == null
        ? null
        : List.of(checkpoint.imageTargets!);
    imageAssets
      ..clear()
      ..addAll(checkpoint.imageAssets);
    _loadPageInputs();
    _restoring = true;
    for (final node in nodes.values) {
      node.dispose();
    }
    nodes.clear();
    _blocks
      ..clear()
      ..addAll({
        for (final entry in checkpoint.blocks.entries)
          entry.key: List.of(entry.value),
      });
    selectedOwnerId = checkpoint.ownerId;
    _journal
      ..clear()
      ..addAll(checkpoint.journal);
    for (final state in checkpoint.nodes) {
      final node = _addNode(
        state.target,
        state.text,
        state.details,
        state.format,
        state.capabilities,
        ownerId: state.ownerId,
        isNew: state.isNew,
      );
      node.text._validSnapshot = state.validSnapshot;
      node.text._updating = true;
      node.text.text.selection = state.selection;
      node.text._selection = state.selection;
      node.text._acceptedValue = node.text.text.value;
      node.text._updating = false;
    }
    activeId = checkpoint.activeId;
    _restoring = false;
    _error = null;
    _stable = _capture();
    if (active case final node?) _focus(node, node.text._selection);
    editor._pruneAssets();
    onChanged();
  }

  void validate() {
    for (final node in nodes.values) {
      node.text.validate();
    }
  }

  void dispose() {
    _disposed = true;
    for (final input in pageInputs.values) input.dispose();
    for (final node in nodes.values) {
      node.dispose();
    }
    nodes.clear();
  }
}

extension _StructuredWordView on WindowsOfficeEditorState {
  Widget _wordPagePanel(_WordDocumentDraft word) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: math.min(MediaQuery.sizeOf(context).height * .5, 420),
    ),
    child: SingleChildScrollView(
      child: Material(
        color: const Color(0xffedf0eb),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    '페이지 설정',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 16),
                  Flexible(
                    child: PopupMenuButton<String>(
                      key: const ValueKey('office-word-page-style'),
                      enabled: !word.locked && !word.composing,
                      onSelected: word.selectPageStyle,
                      itemBuilder: (_) => [
                        for (final style in word.pageStyles)
                          PopupMenuItem(
                            key: ValueKey('office-word-page-style-${style.id}'),
                            value: style.id,
                            child: Text(style.displayName),
                          ),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          '${word.pageStyle?.displayName ?? '페이지 스타일 선택'} ▾',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    key: const ValueKey('office-word-page-close'),
                    onPressed: word.locked
                        ? null
                        : () {
                            word.pagePanelOpen = false;
                            _changed();
                          },
                    child: const Text('닫기'),
                  ),
                ],
              ),
              const Text('선택한 페이지 스타일을 사용하는 모든 구역과 페이지에 적용됩니다. 단위: mm'),
              if (word.pageStyle != null && !word.canEditPage)
                const Text('이 페이지 스타일의 크기와 여백은 읽기 전용입니다.'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final property in [
                    ('width', '용지 너비'),
                    ('height', '용지 높이'),
                    ('leftMargin', '왼쪽 여백'),
                    ('rightMargin', '오른쪽 여백'),
                    ('topMargin', '위쪽 여백'),
                    ('bottomMargin', '아래쪽 여백'),
                  ])
                    SizedBox(
                      width: 170,
                      child: TextField(
                        key: ValueKey('office-word-page-${property.$1}'),
                        controller: word.pageInputs[property.$1],
                        readOnly: word.locked || !word.canEditPage,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: property.$2,
                          suffixText: 'mm',
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) {
                          word.pageError = null;
                          _changed();
                        },
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final direction in [
                    (false, '세로', 'portrait'),
                    (true, '가로', 'landscape'),
                  ])
                    ChoiceChip(
                      key: ValueKey('office-word-page-${direction.$3}'),
                      label: Text(direction.$2),
                      selected:
                          word.pageStyle != null &&
                          word.pageLandscape == direction.$1,
                      onSelected: word.locked || !word.canEditPage
                          ? null
                          : (_) => word.direction(direction.$1),
                    ),
                  FilledButton(
                    key: const ValueKey('office-word-page-apply'),
                    onPressed: word.locked || !word.canEditPage
                        ? null
                        : word.applyPage,
                    child: const Text('적용하고 미리보기 만들기'),
                  ),
                  if (word.hasPendingGeometry && !word.previewing)
                    TextButton(
                      key: const ValueKey('office-word-page-retry-preview'),
                      onPressed: word.refreshPagePreview,
                      child: const Text('미리보기 재시도'),
                    ),
                ],
              ),
              if (word.pageError != null)
                Text(
                  word.pageError!,
                  key: const ValueKey('office-word-page-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  String _wordOwnerLabel(_WordDocumentDraft word, String id) {
    if (id == word.bodyOwnerId) return '본문';
    final owner =
        (widget.snapshot.wordOwners ?? const <WindowsOfficeWordOwner>[])
            .firstWhere((owner) => owner.id == id);
    final kind = owner.kind == 'header' ? '머리말' : '꼬리말';
    final references = [
      for (final reference in owner.references)
        '${widget.snapshot.pageStyles?.where((style) => style.id == reference.pageStyleId).firstOrNull?.displayName ?? '페이지 스타일'} · ${switch (reference.variant) {
          'default' => '기본',
          'left' => '왼쪽',
          'right' => '오른쪽',
          'first' => '첫 페이지',
          _ => reference.variant,
        }}',
    ];
    return '$kind · ${references.join(' / ')}';
  }

  Widget _wordOwnerSelector(_WordDocumentDraft word) => PopupMenuButton<String>(
    key: const ValueKey('office-word-owner-selector'),
    tooltip: '편집 영역',
    enabled: !_busy && !word.composing && !word.locked,
    onSelected: word.selectOwner,
    itemBuilder: (_) => [
      for (final id in [
        word.bodyOwnerId,
        ...(widget.snapshot.wordOwners ?? const <WindowsOfficeWordOwner>[]).map(
          (owner) => owner.id,
        ),
      ])
        PopupMenuItem(
          key: ValueKey('office-word-owner-$id'),
          value: id,
          child: Text(_wordOwnerLabel(word, id)),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              _wordOwnerLabel(word, word.selectedOwnerId),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    ),
  );

  Widget _structuredWord() {
    final word = _wordDraft!;
    return Column(
      children: [
        _wordToolbar(word),
        if (word.pagePanelOpen) _wordPagePanel(word),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            key: ValueKey('office-word-owner-content-${word.selectedOwnerId}'),
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
            children: [
              for (final image in word.images.where(
                (image) =>
                    image.ownerId == word.selectedOwnerId ||
                    image.ownerId == null && word.isBody,
              ))
                _wordImage(word, image),
              for (final block in word.blocks)
                if (block.$1 == 'paragraph' &&
                    word.nodes.containsKey(('paragraph', block.$2, '')))
                  _wordParagraph(word, word.nodes[('paragraph', block.$2, '')]!)
                else if (block.$1 == 'table')
                  _wordTable(word, block.$2)
                else
                  Container(
                    key: ValueKey('office-word-opaque-${block.$2}'),
                    margin: const EdgeInsets.symmetric(vertical: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xffedf0eb),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.widgets_outlined),
                        SizedBox(width: 12),
                        Expanded(child: Text('포함된 개체 · 원본 미리보기에서 확인')),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _wordImage(_WordDocumentDraft word, _WordImage image) {
    Uint8List? bytes;
    final assetId = word.imageAssets[image.id];
    try {
      bytes = assetId == null
          ? image.image?.thumbnailBytes
          : _imageAssets[assetId]?.bytes;
    } on FormatException {
      bytes = null;
    }
    final actions = [
      IconButton(
        key: ValueKey('office-word-image-replace-${image.id}'),
        tooltip: '사진 교체',
        onPressed: word.canReplaceImage(image.id)
            ? () => _pickWordImage(image.id)
            : null,
        icon: const Icon(Icons.photo_library_outlined),
      ),
      IconButton(
        key: ValueKey('office-word-image-move-${image.id}'),
        tooltip: '현재 커서로 사진 이동',
        onPressed: word.canMoveImage(image.id)
            ? () => word.moveImage(image.id)
            : null,
        icon: const Icon(Icons.drive_file_move_outline),
      ),
      IconButton(
        key: ValueKey('office-word-image-delete-${image.id}'),
        tooltip: '사진 삭제',
        onPressed: word.canDeleteImage(image.id)
            ? () => word.deleteImage(image.id)
            : null,
        icon: const Icon(Icons.delete_outline),
      ),
    ];
    Widget details({Widget? trailing}) => ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 6),
      leading: SizedBox(
        width: 64,
        height: 48,
        child: bytes == null
            ? const Icon(Icons.image_outlined)
            : Image.memory(
                bytes,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(Icons.image_outlined),
              ),
      ),
      title: Text('문서 사진 ${word.images.indexOf(image) + 1}'),
      subtitle: image.cell == null ? null : Text('표 ${image.cell}'),
      trailing: trailing,
    );
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < 420
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                details(),
                Wrap(alignment: WrapAlignment.end, children: actions),
              ],
            )
          : details(
              trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
    );
  }

  Widget _wordToolbar(_WordDocumentDraft word) {
    final node = word.active;
    final enabled = !_busy && !word.composing && !word.locked && node != null;
    final styleName = node?.format['styleName'];
    final styleLabel =
        widget.snapshot.paragraphStyles
            .where((style) => style.name == styleName)
            .firstOrNull
            ?.displayName ??
        (styleName is String && styleName.isNotEmpty ? styleName : '기존 문단 스타일');
    Widget action(
      String key,
      String tooltip,
      IconData icon,
      bool allowed,
      VoidCallback callback,
    ) => IconButton(
      key: ValueKey('office-word-$key'),
      tooltip: tooltip,
      onPressed: !_busy && allowed && (!word.locked || key == 'undo')
          ? callback
          : null,
      icon: Icon(icon),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.snapshot.wordOwners?.isNotEmpty == true)
            _wordOwnerSelector(word),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                key: const ValueKey('office-word-image-add'),
                tooltip: '현재 커서에 사진 추가',
                onPressed: word.canAddImage ? () => _pickWordImage() : null,
                icon: const Icon(Icons.add_photo_alternate_outlined),
              ),
              IconButton(
                key: const ValueKey('office-word-page-settings'),
                tooltip: '페이지 설정',
                onPressed: word.canOpenPages ? word.openPages : null,
                icon: const Icon(Icons.settings_overscan),
              ),
              if (widget.onPreview != null)
                IconButton(
                  key: const ValueKey('office-word-refresh-preview'),
                  tooltip: '편집 미리보기 새로 만들기',
                  onPressed: word.canRefreshPreview
                      ? word.refreshPagePreview
                      : null,
                  icon: const Icon(Icons.preview_outlined),
                ),
              action('undo', '실행 취소', Icons.undo, word.canUndo, word.undo),
              action('redo', '다시 실행', Icons.redo, word.canRedo, word.redo),
              action(
                'split',
                '선택 위치에서 문단 나누기',
                Icons.call_split,
                word.canSplit,
                word.split,
              ),
              action(
                'insert-before',
                '앞에 문단 추가',
                Icons.vertical_align_top,
                word.canInsert(true),
                () => word.insert(true),
              ),
              action(
                'insert-after',
                '뒤에 문단 추가',
                Icons.vertical_align_bottom,
                word.canInsert(false),
                () => word.insert(false),
              ),
              action(
                'delete',
                '문단 삭제',
                Icons.delete_outline,
                word.canDelete,
                word.delete,
              ),
              action(
                'join',
                '다음 문단과 합치기',
                Icons.merge_type,
                word.canJoin,
                word.join,
              ),
              PopupMenuButton<String>(
                key: const ValueKey('office-word-style'),
                tooltip: '문단 스타일',
                enabled: enabled && widget.snapshot.paragraphStyles.isNotEmpty,
                onSelected: (name) => word.format({'styleName': name}),
                itemBuilder: (_) => [
                  for (final style in widget.snapshot.paragraphStyles)
                    PopupMenuItem(
                      value: style.name,
                      child: Text(style.displayName),
                    ),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(styleLabel),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
              for (final item in [
                ('left', '왼쪽 정렬', Icons.format_align_left),
                ('center', '가운데 정렬', Icons.format_align_center),
                ('right', '오른쪽 정렬', Icons.format_align_right),
                ('justify', '양쪽 정렬', Icons.format_align_justify),
              ])
                IconButton(
                  key: ValueKey('office-word-alignment-${item.$1}'),
                  tooltip: item.$2,
                  isSelected: node?.format['alignment'] == item.$1,
                  onPressed: enabled
                      ? () => word.format({'alignment': item.$1})
                      : null,
                  icon: Icon(item.$3),
                ),
              for (final item in [
                ('none', '목록 해제', Icons.format_clear),
                ('bullet', '글머리표 목록', Icons.format_list_bulleted),
                ('number', '번호 목록', Icons.format_list_numbered),
              ])
                IconButton(
                  key: ValueKey('office-word-list-${item.$1}'),
                  tooltip: item.$2,
                  isSelected: node?.format['listKind'] == item.$1,
                  onPressed: enabled
                      ? () => word.format({'listKind': item.$1})
                      : null,
                  icon: Icon(item.$3),
                ),
              PopupMenuButton<int>(
                key: const ValueKey('office-word-list-level'),
                tooltip: '목록 단계',
                enabled:
                    enabled &&
                    const [
                      'bullet',
                      'number',
                    ].contains(node.format['listKind']),
                onSelected: (level) => word.format({'listLevel': level}),
                itemBuilder: (_) => [
                  for (var i = 0; i < 9; i++)
                    PopupMenuItem(
                      key: ValueKey('office-word-list-level-$i'),
                      value: i,
                      child: Text('${i + 1}단계'),
                    ),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Text('목록 단계'),
                ),
              ),
              FilterChip(
                key: const ValueKey('office-word-page-break'),
                label: Text(
                  node?.format['pageBreakBefore'] == null
                      ? '원본 페이지 나누기 유지'
                      : '앞에서 페이지 나누기',
                ),
                selected: node?.format['pageBreakBefore'] == true,
                onSelected: enabled && word.isBody
                    ? (value) => word.format({'pageBreakBefore': value})
                    : null,
              ),
            ],
          ),
          if (node != null && widget.allowFormatting)
            _style(node.text, node.id),
          if (node != null && word.isBody && word.imageTargets != null)
            Text(
              '사진 추가·이동 위치: 본문 ${word.blocks.where((block) => block.$1 == 'paragraph').toList().indexWhere((block) => block.$2 == node.id) + 1}번 문단의 현재 커서',
            ),
          if (!word.pagePanelOpen && word.pageError != null)
            Text(
              word.pageError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const Text('편집 보기는 문서 흐름을 표시합니다. 저장한 배치·효과는 원본 미리보기에서 확인하세요.'),
        ],
      ),
    );
  }

  Widget _wordParagraph(_WordDocumentDraft word, _WordNode node) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: TextField(
      key: ValueKey('office-paragraph-${node.id}'),
      controller: node.text.text,
      focusNode: node.focus,
      readOnly: word.locked || !node.text.isRich || !node.text.canReplace,
      minLines: 1,
      maxLines: null,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      textAlign: switch (node.format['alignment']) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        'justify' => TextAlign.justify,
        _ => TextAlign.left,
      },
      onTap: () {
        word.activeId = node.id;
        _changed();
      },
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderSide: BorderSide(
            color: node.id == word.activeId
                ? WindowsOfficeEditorState._teal
                : const Color(0xffe1e5de),
          ),
        ),
      ),
    ),
  );

  Widget _wordTable(_WordDocumentDraft word, String id) => Container(
    margin: const EdgeInsets.symmetric(vertical: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xffcbd5ce)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('표', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final node in word.nodes.values.where(
              (node) => node.target.$1 == 'cell' && node.id == id,
            ))
              SizedBox(
                width: 210,
                child: TextField(
                  key: ValueKey('office-cell-$id-${node.target.$3}'),
                  controller: node.text.text,
                  focusNode: node.focus,
                  readOnly:
                      word.locked || !node.text.isRich || !node.text.canReplace,
                  minLines: 1,
                  maxLines: null,
                  onTap: () {
                    word.activeId = null;
                    _changed();
                  },
                  decoration: InputDecoration(
                    labelText: node.target.$3,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
          ],
        ),
      ],
    ),
  );
}
