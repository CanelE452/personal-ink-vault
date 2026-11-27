part of 'editor.dart';

/// What [EditorPageOps.cutPage] did.
enum PageCut {
  /// Nothing: the note may not change, the page may not go, or a copy
  /// started later overtook this one's.
  nothing,

  /// The page was copied but could not be deleted after: it went, or became
  /// the empty last page, while it was being copied.
  copied,

  /// The page was copied and deleted.
  cut,
}

/// What the page thumbnail menu and the drag-to-reorder do to the note's
/// pages: move, put one in before another, delete, copy, cut and paste. Each
/// does nothing in a locked note (copying changes nothing, so it still
/// works), or for an index that is not a page. Public so that the thumbnails
/// (and tests) outside this library can call them.
extension EditorPageOps on EditorState {
  bool _isPage(int index) => index >= 0 && index < coreInfo.pages.length;

  /// Whether page [index] can be deleted or cut: not the only page, and not
  /// the empty last page (the spare one the note always ends with).
  bool canDeletePage(int index) {
    if (!_isPage(index) || coreInfo.pages.length < 2) return false;
    return !(index == coreInfo.pages.length - 1 &&
        coreInfo.pages[index].isEmpty);
  }

  /// Moves page [from] so that it is page [to]; one undo step.
  void movePage(int from, int to) {
    if (_noteLocked || from == to || !_isPage(from) || !_isPage(to)) return;
    final page = coreInfo.pages[from];
    _movePageNow(page, to);
    history.recordChange(
      EditorHistoryItem(
        type: .movePage,
        pageIndex: from,
        toIndex: to,
        strokes: const [],
        images: const [],
        page: page,
      ),
    );
    autosaveAfterDelay();
    _setState();
  }

  /// Moves [page] so that it is page [to]; also what undo and redo do. The
  /// changes around the move count pages by their places, so it goes to
  /// [to] itself: when the note is shorter now (empty pages at its end were
  /// tidied away), empty pages fill the places up to it, and one follows it
  /// if it has something or a link on it, as the note ends with an empty
  /// page. A page not in the note is put in there.
  void _movePageNow(EditorPage page, int to) {
    final pages = coreInfo.pages;
    final from = pages.indexOf(page);
    if (from != -1) pages.removeAt(from);
    final shorter = to > pages.length;
    if (shorter) createPage(to - 2);
    pages.insert(to, page);
    _renumberPages(from != -1 && from < to ? from : to);
    if (shorter && (page.isNotEmpty || page.links.isNotEmpty)) {
      createPage(pages.length - 1);
    }
  }

  void insertPageBefore(int index) {
    if (_noteLocked || !_isPage(index)) return;
    _putPage(index, EditorPage());
    autosaveAfterDelay();
    _setState();
  }

  /// Deletes page [index]; whether it did.
  bool deletePageAt(int index) {
    if (_noteLocked || !canDeletePage(index)) return false;
    final page = coreInfo.pages.removeAt(index);
    _renumberPages(index);
    createPage(index - 1);
    history.recordChange(
      EditorHistoryItem(
        type: .deletePage,
        pageIndex: index,
        strokes: const [],
        images: const [],
        page: page,
      ),
    );
    autosaveAfterDelay();
    _setState();
    return true;
  }

  /// Copies page [index] for pasting; whether this copy is the one held (a
  /// copy started after it, ending first, is kept instead).
  Future<bool> copyPage(int index) async {
    if (!_isPage(index)) return false;
    final page = coreInfo.pages[index];
    return PageClipboard.hold(
      () => clipPage(
        page,
        notePattern: coreInfo.backgroundPattern,
        assetCache: coreInfo.assetCache,
        extractPdfPage: extractPdfPage,
      ),
    );
  }

  /// Copies page [index], then deletes it. The copy is kept even when the
  /// page could not be deleted after it; a page whose copy a later copy
  /// overtook is not deleted (it would be in none).
  Future<PageCut> cutPage(int index) async {
    if (_noteLocked || !canDeletePage(index)) return .nothing;
    final page = coreInfo.pages[index];
    if (!await copyPage(index) || !mounted) return .nothing;
    // the note may have changed while the page was being copied
    return deletePageAt(coreInfo.pages.indexOf(page)) ? .cut : .copied;
  }

  /// Puts the copied page in after page [index], as a new page.
  void pastePageAfter(int index) {
    final clip = PageClipboard.current.value;
    if (_noteLocked || clip == null || !_isPage(index)) return;
    final page = pastePage(
      clip,
      sbnPath: coreInfo.filePath,
      assetCache: coreInfo.assetCache,
      notePattern: coreInfo.backgroundPattern,
      pageIndex: index + 1,
    );
    // its pictures answer to this editor, as those of a note it opens do
    for (final image in [...page.images, ?page.backgroundImage]) {
      if (image.id == -1) image.id = coreInfo.nextImageId++;
      image.onMoveImage = onMoveImage;
      image.onDeleteImage = onDeleteImage;
      image.onMiscChange = autosaveAfterDelay;
    }
    _putPage(index + 1, page);
    autosaveAfterDelay();
    _setState();
  }
}

/// What the thumbnail menu does, with what it tells in the undo notice.
extension _EditorPageMenu on EditorState {
  /// The editor's side of [EditorPageActions].
  EditorPageActions _pageActions() => EditorPageActions(
    locks: inkLocked,
    editable: () => !_noteLocked,
    canPaste: () => PageClipboard.current.value != null,
    canDelete: canDeletePage,
    canClear: (index) =>
        coreInfo.pages[index].strokes.isNotEmpty ||
        coreInfo.pages[index].images.isNotEmpty,
    move: movePage,
    run: _runPageAction,
  );

  void _runPageAction(KitPageAction action, int index) {
    switch (action) {
      case .insertBefore:
        _putAndShow(index, () => insertPageBefore(index));
      case .insertAfter:
        _putAndShow(index + 1, () => insertPageAfter(index));
      case .duplicate:
        _putAndShow(index + 1, () => _duplicatePage(index));
      case .copy:
        unawaited(_copyPageAndTell(index));
      case .cut:
        unawaited(_cutPageAndTell(index));
      case .paste:
        final count = coreInfo.pages.length;
        pastePageAfter(index);
        if (coreInfo.pages.length > count) _tellPage('쪽을 붙여넣었습니다');
      case .clear:
        clearPage(index);
      case .delete:
        // not by the page count: deleting the last page puts an empty one in
        if (deletePageAt(index)) _tellPage('쪽을 삭제했습니다', undoable: true);
    }
  }

  /// Runs [put], which puts one page in at [at], and goes to that page.
  void _putAndShow(int at, VoidCallback put) {
    final count = coreInfo.pages.length;
    put();
    if (coreInfo.pages.length > count) _scrollToPage(at);
  }

  /// Copies page [index]; says so only when this copy is held. A page that
  /// cannot be copied is logged and says nothing.
  Future<void> _copyPageAndTell(int index) async {
    final bool held;
    try {
      held = await copyPage(index);
    } catch (error, stackTrace) {
      log.warning('Copying page $index failed', error, stackTrace);
      return;
    }
    if (mounted && held) _tellPage('쪽을 복사했습니다');
  }

  /// Cuts page [index] and says so; when the page could not be taken out
  /// after it was copied (it went meanwhile), says it was copied. A cut a
  /// later copy overtook says nothing: that copy has said its own.
  Future<void> _cutPageAndTell(int index) async {
    final PageCut cut;
    try {
      cut = await cutPage(index);
    } catch (error, stackTrace) {
      // the copy failed, so the page was not taken out
      log.warning('Cutting page $index failed', error, stackTrace);
      return;
    }
    if (!mounted) return;
    switch (cut) {
      case .cut:
        _tellPage('쪽을 잘라냈습니다', undoable: true);
      case .copied:
        _tellPage('쪽을 복사했습니다');
      case .nothing:
    }
  }

  /// Says [text] in the undo notice. With [undoable], 「되돌리기」 undoes the
  /// change just recorded, if it is still the last one; the next change (or
  /// undo) takes the notice away, as its button would have nothing of its
  /// own to undo.
  void _tellPage(String text, {bool undoable = false}) {
    if (undoable) {
      _showUndoNotice(text, action: '되돌리기');
    } else {
      _side.notice.show(text);
    }
  }

  /// Says [text] in the undo notice, its [action] button undoing the change
  /// just recorded if that is still the last one, then running [after]. The
  /// next change (or undo) takes the notice away: its button would have
  /// nothing of its own to undo. Notices share the one `history.onChange`
  /// slot, so a new one takes it over from the one before.
  void _showUndoNotice(
    String text, {
    String action = KitTokens.undoNoticeAction,
    VoidCallback? after,
  }) {
    final notice = _side.notice;
    final done = history.peekUndo();
    late final VoidCallback goes;
    void stopListening() {
      if (identical(history.onChange, goes)) history.onChange = null;
    }

    void undoIt() {
      stopListening();
      if (history.canUndo && identical(history.peekUndo(), done)) undo();
      after?.call();
    }

    goes = () {
      if (identical(notice.notice?.onAction, undoIt)) notice.hide();
    };
    notice.show(text, action: action, onAction: undoIt, onEnd: stopListening);
    history.onChange = goes;
  }
}
