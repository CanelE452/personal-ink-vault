import 'package:flutter/foundation.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/page.dart';

/// One page's change of strokes and pictures by their places: what was taken
/// out, at its place in the list before the change, and what was put in, at
/// its place in the list after it. Undoing it puts each thing back between
/// the neighbours it had.
@immutable
class InkSwap {
  const new({
    this.removedStrokes = const [],
    this.addedStrokes = const [],
    this.removedImages = const [],
    this.addedImages = const [],
  });

  final List<(int, Stroke)> removedStrokes;
  final List<(int, Stroke)> addedStrokes;
  final List<(int, EditorImage)> removedImages;
  final List<(int, EditorImage)> addedImages;

  /// The same change the other way round: undoing it redoes this one.
  InkSwap get reversed => InkSwap(
    removedStrokes: addedStrokes,
    addedStrokes: removedStrokes,
    removedImages: addedImages,
    addedImages: removedImages,
  );

  bool get isEmpty =>
      removedStrokes.isEmpty &&
      addedStrokes.isEmpty &&
      removedImages.isEmpty &&
      addedImages.isEmpty;

  /// Takes what was put in off [page] (the same objects) and puts back what
  /// was taken out, lowest place first, each at its place.
  void undoOn(EditorPage page) {
    _undoIn(page.strokes, removed: removedStrokes, added: addedStrokes);
    _undoIn(page.images, removed: removedImages, added: addedImages);
  }
}

void _undoIn<T extends Object>(
  List<T> list, {
  required List<(int, T)> removed,
  required List<(int, T)> added,
}) {
  for (final (_, item) in added) {
    final at = list.indexWhere((other) => identical(other, item));
    if (at != -1) list.removeAt(at);
  }
  final back = [...removed]..sort((a, b) => a.$1.compareTo(b.$1));
  for (final (at, item) in back) {
    list.insert(at.clamp(0, list.length), item);
  }
}

/// A page and the change of its strokes and pictures.
typedef PageSwap = ({EditorPage page, InkSwap swap});

/// Each page's change the other way round (what redo undoes).
List<PageSwap> reversedSwaps(List<PageSwap> swaps) => [
  for (final (:page, :swap) in swaps) (page: page, swap: swap.reversed),
];
