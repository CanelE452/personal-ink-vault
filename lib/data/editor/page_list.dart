import 'package:flutter/foundation.dart';
import 'package:saber/data/editor/editor_history.dart';
import 'package:saber/data/editor/ink_swap.dart';
import 'package:saber/data/editor/page.dart';

/// The pages of one note as a list the editor and the ink input both
/// change: making pages up to a place, tidying empty ones off the end,
/// putting one in and moving one. It knows nothing of the screen; what the
/// screen must do comes back through the callbacks.
class PageList {
  const new({
    required this.pages,
    required this.history,
    required this.onPageAdded,
    this.onEndTidied,
  });

  /// Read at every use: the editor swaps its note's page list on load.
  final ValueGetter<List<EditorPage>> pages;

  /// Read at every use: the editor swaps its history object.
  final ValueGetter<EditorHistory> history;

  /// Called for each page [fillTo] or [put] added.
  final void Function(EditorPage page) onPageAdded;

  /// Called once when [tidyEnd] took pages off.
  final VoidCallback? onEndTidied;

  /// Adds blank pages until there is a page after [pageIndex]. Nothing is
  /// added when there already is one, whatever the last page holds.
  /// [firstPageId] names the first page made, and is dropped if none is.
  void fillTo(int pageIndex, {String? firstPageId}) {
    final list = pages();
    while (pageIndex >= list.length - 1) {
      final page = EditorPage(pageId: firstPageId);
      firstPageId = null;
      list.add(page);
      onPageAdded(page);
    }
  }

  /// Takes the empty pages off the end, down to the second page at most.
  /// A page a change to undo or redo holds (put in, moved) stays, and so do
  /// those before it: that change finds it as a page, the changes around
  /// it count pages by their places, and no undo step records this tidying.
  /// Links are not content (isEmpty), but a page carrying one is kept, and
  /// so is the empty page after it, as the note ends with one: removing it
  /// here would lose the link without an undo step. True if pages went.
  bool tidyEnd() {
    final list = pages();
    var removedAPage = false;
    for (var i = list.length - 1; i >= 1; --i) {
      final thisPage = list[i];
      final prevPage = list[i - 1];
      if (history().holds(thisPage)) break;
      if (thisPage.isEmpty &&
          thisPage.links.isEmpty &&
          prevPage.isEmpty &&
          prevPage.links.isEmpty) {
        list.removeAt(i).dispose();
        removedAPage = true;
      } else {
        break;
      }
    }
    if (removedAPage) onEndTidied?.call();
    return removedAPage;
  }

  /// Records [item], then [tidyEnd]s, so the page the record holds stays.
  /// For changes to strokes, pictures and text boxes; putting a page in,
  /// moving it and deleting it only record.
  bool recordThenTidy(EditorHistoryItem item) {
    history().recordChange(item);
    return tidyEnd();
  }

  /// Records [swaps], which the caller already made, as one undo step,
  /// then [tidyEnd]s: the record holds their pages, so they stay. Swaps
  /// that change nothing are left out; with none left nothing is recorded
  /// and false comes back.
  bool recordReplace(List<PageSwap> swaps) {
    final kept = [
      for (final swap in swaps)
        if (!swap.swap.isEmpty) swap,
    ];
    if (kept.isEmpty) return false;
    recordThenTidy(
      EditorHistoryItem(
        type: .replace,
        pageIndex: pages().indexOf(kept.first.page),
        strokes: const [],
        images: const [],
        swaps: kept,
      ),
    );
    return true;
  }

  /// Undoes [swaps] on their pages, where the pages are now. The record
  /// holds them, so each is in the note; one that is not is skipped. As
  /// the note ends with an empty page, one is added after a last page that
  /// has something again.
  void undoSwaps(List<PageSwap> swaps) {
    final list = pages();
    for (final (:page, :swap) in swaps) {
      final at = list.indexOf(page);
      if (at == -1) {
        assert(false, 'a replace is undone on a page not in the note');
        continue;
      }
      swap.undoOn(page);
      page.updatePageIndex(at);
    }
    if (list.isNotEmpty && list.last.isNotEmpty) fillTo(list.length - 1);
  }

  /// Makes [swaps] again (they were undone), then [tidyEnd]s, as when
  /// they were first made: what they empty may end the note in pages
  /// with nothing on them.
  void redoSwaps(List<PageSwap> swaps) {
    undoSwaps(reversedSwaps(swaps));
    tidyEnd();
  }

  /// Puts [page] in at [at], as one undo step unless not [record]; the
  /// pages after it move on.
  void put(int at, EditorPage page, {bool record = true}) {
    pages().insert(at, page);
    renumber(at);
    onPageAdded(page);
    if (!record) return;
    history().recordChange(
      EditorHistoryItem(
        type: .insertPage,
        pageIndex: at,
        strokes: const [],
        images: const [],
        page: page,
      ),
    );
  }

  /// Tells the pages from [from] on (their strokes and pictures) where they
  /// are now.
  void renumber(int from) {
    final list = pages();
    for (var i = from; i < list.length; i++) {
      list[i].updatePageIndex(i);
    }
  }

  /// Moves [page] so that it is page [to]; also what undo and redo do. The
  /// changes around the move count pages by their places, so it goes to
  /// [to] itself: when the note is shorter now (empty pages at its end were
  /// tidied away), empty pages fill the places up to it, and one follows it
  /// if it has something or a link on it, as the note ends with an empty
  /// page. A page not in the note is put in there.
  void move(EditorPage page, int to) {
    final list = pages();
    final from = list.indexOf(page);
    if (from != -1) list.removeAt(from);
    final shorter = to > list.length;
    if (shorter) fillTo(to - 2);
    list.insert(to, page);
    renumber(from != -1 && from < to ? from : to);
    if (shorter && (page.isNotEmpty || page.links.isNotEmpty)) {
      fillTo(list.length - 1);
    }
  }
}
