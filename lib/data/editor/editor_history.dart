import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:sbn/canvas_background_pattern.dart';
import 'package:sbn/change.dart';

class EditorHistory {
  static const maxHistoryLength = 100;

  /// A stack of the changes that have been made in the editor.
  /// The last element is used when undoing.
  ///
  /// See also: [_future]
  final List<EditorHistoryItem> _past = [];

  /// A stack of the changes that have been undone in the editor.
  /// The last element is used when redoing.
  ///
  /// See also: [_past]
  final List<EditorHistoryItem> _future = [];

  /// The last saved state in the history.
  /// This is used to determine whether an autosave is needed.
  EditorHistoryItem? _lastSaved;

  /// True if redo is possible.
  /// We don't directly clear [_future] because we sometimes need to
  /// reject strokes (i.e. accidental strokes when zooming).
  var _isRedoPossible = false;

  /// Heard after a change is recorded, undone or redone. One listener only
  /// (the editor's 노트 추가 notice); a second one would make it a list.
  VoidCallback? onChange;

  /// Removes an element from the [_past] stack,
  /// adds it to the [_future] stack, and returns it.
  ///
  /// Please check [canUndo] first: this method will
  /// throw an exception if there is nothing to undo.
  EditorHistoryItem undo() {
    if (_past.isEmpty) throw Exception('Nothing to undo');
    final item = _past.removeLast();
    _future.add(item);
    onChange?.call();
    return item;
  }

  /// Removes an element from the [_future] stack,
  /// adds it to the [_past] stack, and returns it.
  ///
  /// Please check [canRedo] first: this method will
  /// throw an exception if there is nothing to redo.
  EditorHistoryItem redo() {
    if (_future.isEmpty) throw Exception('Nothing to redo');
    final item = _future.removeLast();
    _past.add(item);
    onChange?.call();
    return item;
  }

  /// Allows you to see the last item in the [_past] stack
  /// without removing it.
  ///
  /// Please check [canUndo] first: this method will
  /// throw an exception if there is nothing to undo.
  EditorHistoryItem peekUndo() {
    if (_past.isEmpty) throw Exception('Nothing to undo');
    return _past.last;
  }

  /// Allows you to see the last item in the [_future] stack
  /// without removing it.
  ///
  /// Please check [canRedo] first: this method will
  /// throw an exception if there is nothing to redo.
  EditorHistoryItem peekRedo() {
    if (_future.isEmpty) throw Exception('Nothing to redo');
    return _future.last;
  }

  /// Adds an item to the [_past] stack.
  void recordChange(EditorHistoryItem item) {
    assert(
      item.type != .quillUndoneChange,
      'EditorHistoryItemType.quillUndoneChange is just a hack to make undoing quill changes easier. It should just be recorded as a quill change.',
    );

    _past.add(item);
    if (_past.length > maxHistoryLength) _past.removeAt(0);
    _isRedoPossible = false;
    onChange?.call();
  }

  /// Marks the last change as saved to disk.
  /// This does not modify the history stacks, but allows us to know
  /// whether the current state is saved or not.
  void markLastChangeAsSaved() {
    _lastSaved = _past.lastOrNull;
  }

  /// Whether the current state is saved to disk.
  ///
  /// Note that this explicitly checks the last change in the history,
  /// not whether _past is empty. This is because _past items can be discarded
  /// if the history exceeds [maxHistoryLength].
  bool get isCurrentStateSaved {
    return _past.lastOrNull == _lastSaved;
  }

  /// Removes the last history item due to a rejected stroke.
  /// This does essentially the opposite of [recordChange].
  EditorHistoryItem? removeAccidentalStroke() {
    _isRedoPossible = true;
    if (_past.isEmpty) return null;
    // The eraser's first finger of a pinch leaves an erase instead.
    assert(
      _past.last.type == .draw || _past.last.type == .erase,
      'Accidental stroke is not a draw or an erase',
    );
    assert(
      _past.last.type != .draw || _past.last.strokes.length == 1,
      'Accidental strokes should be single-stroke',
    );
    assert(
      _past.last.images.isEmpty,
      'Accidental strokes should not contain images',
    );
    return _past.removeLast();
  }

  /// Whether a change to undo or redo holds [page] (put it in, moved it,
  /// deleted it): undoing or redoing it finds that page, so the tidying of
  /// empty pages at the note's end stops there.
  bool holds(EditorPage page) =>
      _past.any((item) => identical(item.page, page)) ||
      _future.any((item) => identical(item.page, page));

  /// Returns true if there is something to undo.
  bool get canUndo {
    return _past.isNotEmpty;
  }

  /// Returns true if there is something to redo.
  bool get canRedo {
    return _isRedoPossible && _future.isNotEmpty;
  }

  set canRedo(bool isRedoPossible) {
    _isRedoPossible = isRedoPossible;
  }

  void clearRedo() {
    _future.clear();
  }
}

class EditorHistoryItem {
  new({
    required this.type,
    required this.pageIndex,
    required this.strokes,
    required this.images,
    this.offset,
    this.toIndex,
    this.page,
    this.quillChange,
    this.colorChange,
    this.backgroundPatternChange,
    this.patternFollowers,
    this.link,
    this.replacedLink,
  }) : assert(
         type != .move || offset != null,
         'Offset must be provided for move',
       ),
       assert(
         type != .movePage || toIndex != null,
         'toIndex must be provided for movePage',
       ),
       assert(
         (type != .addLink && type != .removeLink) ||
             (page != null && link != null),
         'Page and link must be provided for addLink and removeLink',
       ),
       assert(
         type != .deletePage || page != null,
         'Page must be provided for deletePage',
       ),
       assert(
         type != .insertPage || page != null,
         'Page must be provided for insertPage',
       ),
       assert(
         type != .quillChange || quillChange != null,
         'Quill change must be provided for quillChange',
       ),
       assert(
         type != .quillUndoneChange || quillChange != null,
         'Quill change must be provided for quillUndoneChange',
       ),
       assert(
         type != .changeColor || colorChange?.length == strokes.length,
         'colorChange must be provided and contain each of strokes',
       ),
       assert(
         type != .backgroundPattern || backgroundPatternChange != null,
         'Background pattern change must be provided for backgroundPattern',
       );

  final EditorHistoryItemType type;
  final int pageIndex;
  final List<Stroke> strokes;
  final List<EditorImage> images;
  final Rect? offset;

  /// Where a [EditorHistoryItemType.movePage] put the page that was at
  /// [pageIndex].
  final int? toIndex;
  final EditorPage? page;
  final DocChange? quillChange;
  final Map<Stroke, Change<Color>>? colorChange;
  final Change<CanvasBackgroundPattern>? backgroundPatternChange;

  /// The pages a [EditorHistoryItemType.backgroundPattern] change made follow
  /// the note: they had its new pattern as their own.
  final PatternFollowers? patternFollowers;

  /// The link [EditorHistoryItemType.addLink] added or
  /// [EditorHistoryItemType.removeLink] removed, on [page].
  final PageLink? link;

  /// The link an edit replaced with [link] (an [EditorHistoryItemType.addLink]
  /// in its place): undoing the edit puts it back.
  final PageLink? replacedLink;

  EditorHistoryItem copyWith({
    EditorHistoryItemType? type,
    int? pageIndex,
    List<Stroke>? strokes,
    List<EditorImage>? images,
    Rect? offset,
    int? toIndex,
    EditorPage? page,
    DocChange? quillChange,
    Map<Stroke, Change<Color>>? colorChange,
    Change<CanvasBackgroundPattern>? backgroundPatternChange,
    PatternFollowers? patternFollowers,
    PageLink? link,
    PageLink? replacedLink,
  }) {
    return EditorHistoryItem(
      type: type ?? this.type,
      pageIndex: pageIndex ?? this.pageIndex,
      strokes: strokes ?? this.strokes,
      images: images ?? this.images,
      offset: offset ?? this.offset,
      toIndex: toIndex ?? this.toIndex,
      page: page ?? this.page,
      quillChange: quillChange ?? this.quillChange,
      colorChange: colorChange ?? this.colorChange,
      backgroundPatternChange:
          backgroundPatternChange ?? this.backgroundPatternChange,
      patternFollowers: patternFollowers ?? this.patternFollowers,
      link: link ?? this.link,
      replacedLink: replacedLink ?? this.replacedLink,
    );
  }
}

enum EditorHistoryItemType {
  draw,
  erase,
  deletePage,
  insertPage,
  move,
  movePage,
  quillChange,
  quillUndoneChange,
  changeColor,
  backgroundPattern,
  addLink,
  removeLink,
}
