part of 'editor.dart';

/// 노트 추가 (supplement Task 14, 12th draft `insertPage`): the toolbar's
/// window ([EditorAddPageHost]) puts a page in the pattern pressed where it
/// says, or brings a PDF's pages or pictures in there; 「페이지 추가」 puts a
/// page in at once, where and as the window last did.
extension _EditorAddPage on EditorState {
  List<AppAction> _addPageActions(bool pageWritable) {
    final host = _side.addPage;
    return [
      AppAction(
        id: AppActionIds.insertPage,
        label: '페이지 추가',
        icon: KitIconName.pageAdd,
        enabled: pageWritable,
        run: (_) => unawaited(_insertPageNow()),
      ),
      AppAction(
        id: AppActionIds.insertPageMenu,
        label: '노트 추가',
        icon: KitIconName.pageAdd,
        enabled: pageWritable,
        checked: host.open.value,
        run: (context) => unawaited(_openAddPage(context)),
      ),
    ];
  }

  /// 「페이지 추가」: once the kept place and patterns are read, a page in
  /// the last pattern (the note's to start) at the last place.
  Future<void> _insertPageNow() async {
    final host = _side.addPage;
    await host.ready();
    if (!mounted) return;
    _insertPageAt(
      host.place,
      host.recent.firstOrNull?.pattern ?? coreInfo.backgroundPattern,
    );
  }

  Future<void> _openAddPage(BuildContext context) async {
    final host = _side.addPage;
    final choice = await host.show(context, document: Editor.canRasterPdf);
    if (!mounted) return;
    switch (choice) {
      case KitAddPageInPattern(:final pattern):
        if (_insertPageAt(host.place, pattern)) host.used(pattern);
      case KitAddPageImport(document: true):
        final at = _addPageIndex(host.place);
        if (await importPdf(at) && mounted) {
          _scrollToPage(min(at, coreInfo.pages.length - 1));
        }
      case KitAddPageImport(document: false):
        final photos = await _pickPhotosWithFilePicker();
        if (photos.isEmpty || !mounted || _noteLocked) return;
        final at = _addPageIndex(host.place);
        _putPage(at, EditorPage());
        await _pickPhotos(photos, at);
        _setState();
        _scrollToPage(at);
      case null:
    }
  }

  /// Where [place] puts a page: before or after the page on screen, or
  /// after the last page with something on it (before the blank page that
  /// ends the note, as a PDF brought in goes). After that blank page is
  /// before it too: the note keeps ending blank.
  int _addPageIndex(KitAddPagePlace place) {
    final pages = coreInfo.pages;
    final end = pages.isNotEmpty && pages.last.isEmpty
        ? pages.length - 1
        : pages.length;
    return switch (place) {
      KitAddPagePlace.before => currentPageIndex,
      KitAddPagePlace.after => min(currentPageIndex + 1, end),
      KitAddPagePlace.end => end,
    };
  }

  /// Puts a page in [pattern] where [place] says (following the note's
  /// pattern when it is that one, so the note stays version 19), goes to it
  /// and says so in the undo notice, until the next change; whether it did.
  bool _insertPageAt(KitAddPagePlace place, CanvasBackgroundPattern pattern) {
    if (_noteLocked) return false;
    final from = currentPageIndex;
    final at = _addPageIndex(place);
    final own = pattern == coreInfo.backgroundPattern ? null : pattern;
    _putPage(at, EditorPage(backgroundPattern: own));
    _setState();
    autosaveAfterDelay();
    _scrollToPage(at);
    _showUndoNotice(
      KitTokens.insertedNotice(
        at + 1,
        kitAddPagePaperOf(pattern)?.name ?? pattern.localizedName,
      ),
      after: () => _scrollToPage(from),
    );
    return true;
  }

  /// Puts [page] in at [at], as one undo step unless not [record]; the
  /// pages after it move on.
  void _putPage(int at, EditorPage page, {bool record = true}) {
    coreInfo.pages.insert(at, page);
    _renumberPages(at);
    listenToQuillChanges(page.quill);
    if (!record) return;
    history.recordChange(
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
  void _renumberPages(int from) {
    for (var i = from; i < coreInfo.pages.length; i++) {
      coreInfo.pages[i].updatePageIndex(i);
    }
  }
}
