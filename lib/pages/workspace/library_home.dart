import 'package:flutter/material.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

enum LibraryCreateAction {
  handwriting,
  quickNote,
  infinite,
  markdown,
  dailyNote,
  datedNote,
  dailyNoteTemplate,
  obsidianVault,
  notionZip,
  starnote,
  canvas,
  page,
  database,
  pdf,
  image,
  camera,
  office,
  wordDocument,
  presentation,
  hwpx,
  folder,
}

/// [preview] and [pdf] are for Office·한글 documents only.
enum LibraryNoteAction { rename, move, trash, restore, preview, pdf, tools }

enum LibraryFolderAction { rename, move, trash, restore }

enum LibraryBatchAction { move, trash, restore }

class LibraryHome extends StatefulWidget {
  final List<VaultNote> notes;
  final List<VaultFolder> folders;
  final String? currentFolderId;
  final ValueChanged<VaultNote> onOpenNote;
  final Map<String, KnowledgeBodyMatch> searchBodyMatches;
  final void Function(VaultNote, KnowledgeBodyMatch)? onOpenBodyMatch;
  final ValueChanged<String?> onOpenFolder;
  final ValueChanged<LibraryCreateAction> onCreate;
  final Map<String, ImageProvider> thumbnails;
  final ValueChanged<VaultNote>? onPreviewRequested;

  /// The parent searches the documents (its box is in the side bar,
  /// [LibrarySearchField]); the title's × clears the search through it.
  final ValueChanged<String>? onSearchChanged;
  final String? searchQuery;
  final bool searchAcrossFolders;
  final bool searchExpression;
  final bool searchPending;
  final String? searchError;
  final void Function(VaultNote, LibraryNoteAction)? onNoteAction;
  final void Function(VaultFolder, LibraryFolderAction)? onFolderAction;
  final bool selecting;
  final bool selectionBusy;
  final bool allowBatchMove;
  final ValueChanged<bool>? onSelectionChanged;
  final Future<Set<String>> Function(List<VaultNote>, LibraryBatchAction)?
  onBatchAction;
  final bool showTrash;
  final Set<LibraryCreateAction> availableCreateActions;

  /// Left of the title in the header: the button that shows the hidden side
  /// bar, or the drawer button on a phone (the library has no top row).
  final Widget? leading;

  const new({
    super.key,
    required this.notes,
    required this.folders,
    required this.currentFolderId,
    required this.onOpenNote,
    required this.onOpenFolder,
    required this.onCreate,
    this.searchBodyMatches = const {},
    this.onOpenBodyMatch,
    this.thumbnails = const {},
    this.onPreviewRequested,
    this.onSearchChanged,
    this.searchQuery,
    this.searchAcrossFolders = false,
    this.searchExpression = false,
    this.searchPending = false,
    this.searchError,
    this.onNoteAction,
    this.onFolderAction,
    this.selecting = false,
    this.selectionBusy = false,
    this.allowBatchMove = true,
    this.onSelectionChanged,
    this.onBatchAction,
    this.showTrash = false,
    this.availableCreateActions = const {...LibraryCreateAction.values},
    this.leading,
  });

  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<LibraryHome>
    with SingleTickerProviderStateMixin {
  static const _teal = Color(0xff237d82);
  final _createTileMenu =
      GlobalKey<PopupMenuButtonState<LibraryCreateAction>>();
  String get _query => widget.searchQuery ?? '';
  var _filter = 'all';

  /// The document kinds as swipeable tabs, like StarNote's 모두·메모·PDF.
  static const _filterTabs = [
    ('all', '모두'),
    ('ink', '필기'),
    ('pdf', 'PDF'),
    ('markdown', 'Markdown'),
    ('canvas', '캔버스'),
    ('page', '페이지'),
    ('database', '데이터베이스'),
    ('office', 'Office·한글'),
  ];
  // A tab tap switches at once (taps on a sliding page would be ignored);
  // swiping still slides.
  late final _tabs = TabController(
    length: _filterTabs.length,
    vsync: this,
    animationDuration: Duration.zero,
  )..addListener(_tabChanged);

  void _tabChanged() {
    final next = _filterTabs[_tabs.index].$1;
    if (next == _filter) return;
    setState(() {
      _filter = next;
      _selectedNoteIds.clear();
    });
  }
  var _grid = true;
  var _sortByTitle = false;
  final _scheduledPreviews = <String>{};
  final _selectedNoteIds = <String>{};

  @override
  void didUpdateWidget(covariant LibraryHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.selecting ||
        !oldWidget.selecting ||
        oldWidget.currentFolderId != widget.currentFolderId ||
        oldWidget.showTrash != widget.showTrash ||
        oldWidget.searchQuery != widget.searchQuery ||
        oldWidget.searchAcrossFolders != widget.searchAcrossFolders ||
        oldWidget.searchExpression != widget.searchExpression) {
      _selectedNoteIds.clear();
    } else {
      _selectedNoteIds.retainAll(_selectable(_notes).keys);
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  List<VaultFolder> get _path {
    final path = <VaultFolder>[];
    final seen = <String>{};
    var id = widget.currentFolderId;
    while (id != null && seen.add(id)) {
      final matches = widget.folders.where((folder) => folder.id == id);
      if (matches.isEmpty) break;
      final folder = matches.first;
      path.insert(0, folder);
      id = folder.parentId;
    }
    return path;
  }

  bool _matchesKind(VaultDocumentKind kind, String filter) => switch (filter) {
    'ink' =>
      kind == VaultDocumentKind.handwriting ||
          kind == VaultDocumentKind.infinite ||
          kind == VaultDocumentKind.image,
    'pdf' => kind == VaultDocumentKind.pdf,
    'markdown' => kind == VaultDocumentKind.markdown,
    'office' => kind == VaultDocumentKind.office,
    'canvas' => kind == VaultDocumentKind.canvas,
    'page' => kind == VaultDocumentKind.page,
    'database' => kind == VaultDocumentKind.database,
    _ => true,
  };

  List<VaultNote> get _notes => _notesFor(_filter);

  List<VaultNote> _notesFor(String filter) {
    if (!widget.showTrash && widget.searchPending) return [];
    final query = _query.trim().toLowerCase();
    final notes = widget.notes.where((note) {
      final inLocation = widget.showTrash
          ? note.trashed
          : ((widget.searchAcrossFolders && query.isNotEmpty) ||
                    note.folderId == widget.currentFolderId) &&
                (!note.trashed || note.deletionConflict);
      return inLocation &&
          _matchesKind(note.documentKind, filter) &&
          (widget.onSearchChanged != null ||
              query.isEmpty ||
              note.title.toLowerCase().contains(query));
    }).toList();
    if (_sortByTitle)
      notes.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
    return notes;
  }

  Map<String, VaultNote> _selectable(List<VaultNote> visibleNotes) {
    final seen = <String>{}, ambiguous = <String>{};
    for (final note in widget.notes) {
      if (!seen.add(note.id)) ambiguous.add(note.id);
    }
    final restorableFolders = <String>{};
    if (widget.showTrash) {
      final blocked = <String>{};
      for (final folder in widget.folders) {
        if (folder.trashed || folder.deletionConflict) {
          blocked.add(folder.id);
        } else {
          restorableFolders.add(folder.id);
        }
      }
      restorableFolders.removeAll(blocked);
    }
    return {
      for (final note in visibleNotes)
        if (!note.deletionConflict &&
            !ambiguous.contains(note.id) &&
            (widget.showTrash
                ? note.revision.deleted &&
                      (note.folderId == null ||
                          restorableFolders.contains(note.folderId))
                : !note.trashed))
          note.id: note,
    };
  }

  List<VaultFolder> get _folders {
    if (!widget.showTrash &&
        widget.searchExpression &&
        _query.trim().isNotEmpty) {
      return [];
    }
    return widget.folders.where((folder) {
      final inLocation = widget.showTrash
          ? folder.trashed
          : folder.parentId == widget.currentFolderId &&
                (!folder.trashed || folder.deletionConflict);
      return inLocation &&
          (_query.trim().isEmpty ||
              folder.title.toLowerCase().contains(_query.trim().toLowerCase()));
    }).toList()..sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
  }

  Widget _createMenu({required bool tile}) {
    final quickGesture =
        tile &&
        widget.availableCreateActions.contains(LibraryCreateAction.quickNote);
    final trigger = tile ? _createTile(quickGesture) : _createButton();
    final menu = PopupMenuButton<LibraryCreateAction>(
      key: tile ? _createTileMenu : const ValueKey('library-create-button'),
      tooltip: '생성',
      enabled: !quickGesture,
      onSelected: widget.onCreate,
      itemBuilder: (context) => [
        for (final action in LibraryCreateAction.values)
          if (widget.availableCreateActions.contains(action))
            PopupMenuItem(
              key: switch (action) {
                LibraryCreateAction.starnote => const ValueKey(
                  'library-create-starnote',
                ),
                LibraryCreateAction.dailyNoteTemplate => const ValueKey(
                  'daily-note-template-create-action',
                ),
                _ => null,
              },
              value: action,
              child: Row(
                children: [
                  Icon(_createIcon(action), size: 22, color: _teal),
                  const SizedBox(width: 16),
                  Flexible(child: Text(_createLabel(action))),
                ],
              ),
            ),
      ],
      child: quickGesture
          ? Semantics(
              button: true,
              child: InkWell(
                onTap: () => _createTileMenu.currentState?.showButtonMenu(),
                onDoubleTap: () =>
                    widget.onCreate(LibraryCreateAction.quickNote),
                child: trigger,
              ),
            )
          : trigger,
    );
    return tile
        ? KeyedSubtree(key: const ValueKey('library-create-tile'), child: menu)
        : menu;
  }

  Widget _createTile(bool quickGesture) => CustomPaint(
    painter: const _CreateBorder(_teal),
    child: ColoredBox(
      color: _teal.withValues(alpha: .035),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const label = Text(
            '생성',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: _teal,
            ),
          );
          return Center(
            child: constraints.maxHeight < 120
                ? const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 28, color: _teal),
                      SizedBox(width: 10),
                      label,
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add, size: 48, color: _teal),
                      const SizedBox(height: 18),
                      label,
                      if (quickGesture) ...[
                        const SizedBox(height: 6),
                        Text(
                          '두 번 탭하면 빠른 메모가 열려요',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
          );
        },
      ),
    ),
  );

  Widget _createButton() => const Padding(
    padding: EdgeInsets.all(8),
    child: Icon(Icons.add, size: 24, color: _teal),
  );

  /// The header's title, as StarNote's: where the documents below are from.
  /// In a folder its ‹ goes up a folder; while searching, × clears it.
  Widget _title(bool compact) {
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurface,
      fontSize: compact ? 18 : 21,
      fontWeight: FontWeight.w700,
    );
    Widget title(String text) => Flexible(
      child: Text(
        text,
        key: const ValueKey('library-title'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
    final query = _query.trim();
    if (query.isNotEmpty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          title(
            widget.showTrash ? "휴지통 '$query' 검색 결과" : "'$query' 검색 결과",
          ),
          if (widget.onSearchChanged case final search?)
            IconButton(
              key: const ValueKey('library-search-clear'),
              tooltip: '검색 지우기',
              icon: const Icon(Icons.close),
              onPressed: widget.selectionBusy ? null : () => search(''),
            ),
        ],
      );
    }
    final path = widget.showTrash ? const <VaultFolder>[] : _path;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (path.isNotEmpty)
          IconButton(
            key: const ValueKey('library-up'),
            tooltip: '위 폴더로',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => widget.onOpenFolder(
              path.length > 1 ? path[path.length - 2].id : null,
            ),
          ),
        title(
          widget.showTrash
              ? '휴지통'
              : path.isEmpty
              ? '내 문서'
              : path.last.title,
        ),
      ],
    );
  }

  Widget _sortAndLayout() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      PopupMenuButton<bool>(
        tooltip: _sortByTitle ? '정렬: 이름순' : '정렬: 기본 순서',
        onSelected: (value) => setState(() => _sortByTitle = value),
        itemBuilder: (_) => [
          CheckedPopupMenuItem(
            value: false,
            checked: !_sortByTitle,
            child: const Text('기본 순서'),
          ),
          CheckedPopupMenuItem(
            value: true,
            checked: _sortByTitle,
            child: const Text('이름순'),
          ),
        ],
        child: const Padding(
          padding: EdgeInsets.all(8),
          child: Icon(Icons.sort, size: 22),
        ),
      ),
      if (widget.onSelectionChanged != null)
        IconButton(
          key: const ValueKey('library-select-mode'),
          tooltip: widget.selecting ? '일괄 관리 닫기' : '일괄 관리',
          isSelected: widget.selecting,
          onPressed: widget.selectionBusy
              ? null
              : () => widget.onSelectionChanged!(!widget.selecting),
          icon: const Icon(Icons.check_box_outlined),
          selectedIcon: const Icon(Icons.check_box),
        ),
      IconButton(
        key: const ValueKey('library-layout-toggle'),
        tooltip: _grid ? '목록으로 보기' : '표지로 보기',
        onPressed: () => setState(() => _grid = !_grid),
        icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view_outlined),
      ),
    ],
  );

  Widget _selectionActions(Map<String, VaultNote> selectable) {
    final selected = [
      for (final note in selectable.values)
        if (_selectedNoteIds.contains(note.id)) note,
    ];
    final all = selected.isNotEmpty && selected.length == selectable.length;
    final canSelect = !widget.selectionBusy && selectable.isNotEmpty;
    final canApply =
        !widget.selectionBusy &&
        widget.onBatchAction != null &&
        selected.isNotEmpty;
    Future<void> apply(LibraryBatchAction action) async {
      final completed = await widget.onBatchAction!(selected, action);
      if (mounted && widget.selecting && completed.isNotEmpty) {
        setState(() => _selectedNoteIds.removeAll(completed));
      }
    }

    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        TextButton.icon(
          key: const ValueKey('library-select-all'),
          onPressed: !canSelect
              ? null
              : () => setState(() {
                  if (all) {
                    _selectedNoteIds.clear();
                  } else {
                    _selectedNoteIds.addAll(selectable.keys);
                  }
                }),
          icon: Icon(all ? Icons.deselect : Icons.select_all),
          label: Text(all ? '전체 해제' : '전체 선택'),
        ),
        Text('${selected.length}개 선택'),
        if (!widget.showTrash && widget.allowBatchMove)
          TextButton.icon(
            key: const ValueKey('library-batch-move'),
            onPressed: canApply ? () => apply(LibraryBatchAction.move) : null,
            icon: const Icon(Icons.drive_file_move_outlined),
            label: const Text('이동'),
          ),
        if (widget.showTrash)
          TextButton.icon(
            key: const ValueKey('library-batch-restore'),
            onPressed: canApply
                ? () => apply(LibraryBatchAction.restore)
                : null,
            icon: const Icon(Icons.restore_from_trash_outlined),
            label: const Text('복원'),
          )
        else
          TextButton.icon(
            key: const ValueKey('library-batch-trash'),
            onPressed: canApply ? () => apply(LibraryBatchAction.trash) : null,
            icon: const Icon(Icons.delete_outline),
            label: const Text('휴지통으로'),
          ),
      ],
    );
  }

  Widget _filters() => IgnorePointer(
    ignoring: widget.selectionBusy,
    child: TabBar(
      key: const ValueKey('library-filter-tabs'),
      controller: _tabs,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      labelColor: _teal,
      unselectedLabelColor: Theme.of(context).colorScheme.onSurfaceVariant,
      indicatorColor: _teal,
      dividerColor: Colors.transparent,
      labelStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      unselectedLabelStyle: const TextStyle(fontSize: 15),
      tabs: [
        for (final (id, label) in _filterTabs)
          Tab(key: ValueKey('library-filter-$id'), text: label, height: 40),
      ],
    ),
  );

  Widget _folderCard(VaultFolder folder) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    borderRadius: BorderRadius.circular(9),
    child: InkWell(
      key: ValueKey('library-folder-${folder.id}'),
      borderRadius: BorderRadius.circular(9),
      onTap: () => widget.onOpenFolder(folder.id),
      child: Padding(
        padding: const EdgeInsets.only(left: 14, top: 12, bottom: 12),
        child: Row(
          children: [
            const Icon(Icons.folder_outlined, color: _teal, size: 29),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    folder.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (folder.deletionConflict) _conflict(),
                ],
              ),
            ),
            if (widget.onFolderAction != null) _folderMenu(folder),
          ],
        ),
      ),
    ),
  );

  Widget _folderMenu(VaultFolder folder) => PopupMenuButton<LibraryFolderAction>(
    tooltip: '폴더 메뉴',
    onSelected: (action) => widget.onFolderAction!(folder, action),
    itemBuilder: (_) => [
      if (folder.trashed)
        const PopupMenuItem(
          value: LibraryFolderAction.restore,
          child: Text('복원'),
        )
      else ...[
        const PopupMenuItem(
          value: LibraryFolderAction.rename,
          child: Text('이름 변경'),
        ),
        const PopupMenuItem(value: LibraryFolderAction.move, child: Text('이동')),
        const PopupMenuItem(
          value: LibraryFolderAction.trash,
          child: Text('휴지통으로 이동'),
        ),
      ],
    ],
  );

  /// Documents per folder, counting the folders inside it, for the covers.
  Map<String, int> _folderCounts() {
    final parents = {
      for (final folder in widget.folders) folder.id: folder.parentId,
    };
    final counts = <String, int>{};
    for (final note in widget.notes) {
      if (note.trashed) continue;
      var id = note.folderId;
      final seen = <String>{};
      while (id != null && seen.add(id)) {
        counts[id] = (counts[id] ?? 0) + 1;
        id = parents[id];
      }
    }
    return counts;
  }

  /// A folder as a cover the size of a document card, like StarNote.
  Widget _folderCover(VaultFolder folder, int count) => Material(
    color: Colors.transparent,
    child: InkWell(
      key: ValueKey('library-folder-${folder.id}'),
      borderRadius: BorderRadius.circular(10),
      onTap: () => widget.onOpenFolder(folder.id),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: CustomPaint(
                painter: const _FolderShape(
                  fill: Color(0xffe9f2f1),
                  border: Color(0xffcadcda),
                ),
                child: Center(
                  child: Icon(
                    Icons.folder_outlined,
                    size: 46,
                    color: _teal.withValues(alpha: .65),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    folder.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.onFolderAction != null) _folderMenu(folder),
              ],
            ),
            Text(
              '$count개 문서',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (folder.deletionConflict) _conflict(),
          ],
        ),
      ),
    ),
  );


  Widget _noteMenu(VaultNote note) => PopupMenuButton<LibraryNoteAction>(
    key: ValueKey('library-note-menu-${note.revision.revisionId}'),
    tooltip: '문서 메뉴',
    onSelected: (action) => widget.onNoteAction!(note, action),
    itemBuilder: (_) => [
      if (note.trashed)
        const PopupMenuItem(value: LibraryNoteAction.restore, child: Text('복원'))
      else ...[
        // A tap edits an Office·한글 original; the menu keeps its preview and
        // the PDF made from it for handwriting.
        if (note.documentKind == VaultDocumentKind.office) ...[
          const PopupMenuItem(
            key: ValueKey('library-note-preview'),
            value: LibraryNoteAction.preview,
            child: Text('미리보기'),
          ),
          const PopupMenuItem(
            key: ValueKey('library-note-pdf'),
            value: LibraryNoteAction.pdf,
            child: Text('PDF로 바꾸기'),
          ),
          // The Office screen itself: versions, PDF handwriting, detailed tools, kept edits.
          const PopupMenuItem(
            key: ValueKey('library-note-tools'),
            value: LibraryNoteAction.tools,
            child: Text('기록·도구'),
          ),
        ],
        const PopupMenuItem(
          value: LibraryNoteAction.rename,
          child: Text('이름 변경'),
        ),
        const PopupMenuItem(value: LibraryNoteAction.move, child: Text('이동')),
        const PopupMenuItem(
          value: LibraryNoteAction.trash,
          child: Text('휴지통으로 이동'),
        ),
      ],
    ],
  );

  Widget _conflict() => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xff95620d)),
      SizedBox(width: 3),
      Text('변경 충돌', style: TextStyle(fontSize: 11, color: Color(0xff95620d))),
    ],
  );

  Widget _preview(VaultNote note) {
    if (widget.onPreviewRequested != null &&
        _scheduledPreviews.add(note.revision.revisionId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduledPreviews.remove(note.revision.revisionId);
        if (mounted) widget.onPreviewRequested?.call(note);
      });
    }
    final image = widget.thumbnails[note.id];
    final surface = switch (note.documentKind) {
      VaultDocumentKind.handwriting => const Color(0xfffffbed),
      VaultDocumentKind.infinite => const Color(0xfff0f8f5),
      VaultDocumentKind.office => const Color(0xfff1f4fa),
      _ => const Color(0xfffdfdfc),
    };
    final fallback = Center(
      child: Icon(
        _kindIcon(note.documentKind),
        size: 42,
        color: _teal.withValues(alpha: .5),
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: surface,
        border: Border.all(color: const Color(0xffdedfd6)),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(16),
          bottomRight: Radius.circular(16),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: image == null
          ? fallback
          : Image(
              image: image,
              fit: BoxFit.contain,
              width: double.infinity,
              height: double.infinity,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }

  void _toggleSelection(String id) {
    setState(() {
      if (!_selectedNoteIds.add(id)) _selectedNoteIds.remove(id);
    });
  }

  VoidCallback? _noteActivation(VaultNote note, bool canSelect) {
    if (!widget.selecting) return () => widget.onOpenNote(note);
    if (!canSelect || widget.selectionBusy) return null;
    return () => _toggleSelection(note.id);
  }

  Widget _noteCheckbox(VaultNote note, bool canSelect) => Checkbox(
    key: ValueKey('library-select-note-${note.id}'),
    value: canSelect && _selectedNoteIds.contains(note.id),
    semanticLabel: '${note.title} 선택',
    onChanged: canSelect && !widget.selectionBusy
        ? (_) => _toggleSelection(note.id)
        : null,
  );

  Widget? _searchExcerpt(VaultNote note) {
    final open = widget.onOpenBodyMatch;
    final match = widget.searchBodyMatches[note.id];
    if (open == null ||
        match == null ||
        widget.selecting ||
        widget.searchPending ||
        widget.showTrash ||
        note.deletionConflict) {
      return null;
    }
    return Tooltip(
      message: '일치한 본문 열기',
      child: TextButton(
        key: ValueKey('library-search-body-${note.id}'),
        style: TextButton.styleFrom(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(vertical: 4),
        ),
        onPressed: () => open(note, match),
        child: Text(
          match.excerpt.replaceAll(RegExp(r'\s+'), ' '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  Widget _noteCard(VaultNote note, bool canSelect) => Material(
    color: Colors.transparent,
    child: InkWell(
      key: ValueKey('library-note-${note.revision.revisionId}'),
      borderRadius: BorderRadius.circular(10),
      onTap: _noteActivation(note, canSelect),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: _preview(note)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    note.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (widget.selecting)
                  _noteCheckbox(note, canSelect)
                else if (widget.onNoteAction != null)
                  _noteMenu(note),
              ],
            ),
            Text(
              _kindLabel(note.documentKind),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            ?_searchExcerpt(note),
            if (note.deletionConflict) _conflict(),
            if (note.trashed && !note.deletionConflict)
              Text(
                '휴지통',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    ),
  );

  Widget _noteRow(VaultNote note, bool canSelect) => ListTile(
    key: ValueKey('library-note-${note.revision.revisionId}'),
    leading: SizedBox(width: 40, height: 52, child: _preview(note)),
    title: Text(note.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: switch (_searchExcerpt(note)) {
      final excerpt? => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [Text(_kindLabel(note.documentKind)), excerpt],
      ),
      null =>
        note.deletionConflict
            ? _conflict()
            : Text(_kindLabel(note.documentKind)),
    },
    trailing: widget.selecting
        ? _noteCheckbox(note, canSelect)
        : widget.onNoteAction == null
        ? null
        : _noteMenu(note),
    onTap: _noteActivation(note, canSelect),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 560;
      final notes = _notes;
      final folders = _folders;
      final selectable = widget.selecting
          ? _selectable(notes)
          : const <String, VaultNote>{};
      final canCreate =
          !widget.showTrash &&
          !widget.selecting &&
          widget.availableCreateActions.isNotEmpty;
      return Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 16 : 28,
          16,
          compact ? 16 : 28,
          0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The title in the middle, as an AppBar centres it: the bar or
            // drawer button on its left, the view and create on its right.
            SizedBox(
              height: 56,
              child: NavigationToolbar(
                leading: widget.leading,
                middle: _title(compact),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _sortAndLayout(),
                    if (canCreate) _createMenu(tile: false),
                  ],
                ),
                middleSpacing: 8,
              ),
            ),
            if (!widget.showTrash && widget.searchExpression) ...[
              const SizedBox(height: 6),
              Text(
                '모든 폴더에서 검색 · file: path: tag: content: · 따옴표, -, OR, 괄호\n'
                '예시  (tag:#강의 OR path:"수업 자료") -file:초안',
                key: const ValueKey('library-search-help'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (widget.searchError case final message?)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    message,
                    key: const ValueKey('library-search-error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 4),
            _filters(),
            if (widget.selecting) _selectionActions(selectable),
            const SizedBox(height: 12),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                physics: widget.selectionBusy
                    ? const NeverScrollableScrollPhysics()
                    : null,
                children: [
                  for (final (filter, _) in _filterTabs)
                    _content(
                      filter,
                      notes: filter == _filter ? notes : _notesFor(filter),
                      folders: filter == 'all' ? folders : const [],
                      selectable: filter == _filter
                          ? selectable
                          : const <String, VaultNote>{},
                      // The 생성 card holds a GlobalKey, so only the current tab shows it.
                      canCreate: canCreate && filter == _filter,
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );

  Widget _content(
    String filter, {
    required List<VaultNote> notes,
    required List<VaultFolder> folders,
    required Map<String, VaultNote> selectable,
    required bool canCreate,
  }) {
    final counts = folders.isEmpty ? const <String, int>{} : _folderCounts();
    final leading = canCreate ? 1 : 0;
    return CustomScrollView(
      key: PageStorageKey(
        'library-${widget.showTrash ? 'trash' : widget.currentFolderId ?? 'root'}-$_grid-$filter',
      ),
      slivers: [
        if (_grid)
          SliverGrid(
            key: const ValueKey('library-grid'),
            delegate: SliverChildBuilderDelegate((_, index) {
              if (index < leading) {
                return Padding(
                  padding: const EdgeInsets.all(4),
                  child: _createMenu(tile: true),
                );
              }
              final position = index - leading;
              if (position < folders.length) {
                final folder = folders[position];
                return _folderCover(folder, counts[folder.id] ?? 0);
              }
              final note = notes[position - folders.length];
              return _noteCard(note, selectable.containsKey(note.id));
            }, childCount: leading + folders.length + notes.length),
            // Four columns and four rows on a tablet held upright (824 dp wide), six across when it lies flat.
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisExtent: 262,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
          )
        else ...[
          if (folders.isNotEmpty) ...[
            SliverGrid(
              delegate: SliverChildBuilderDelegate(
                (_, index) => _folderCard(folders[index]),
                childCount: folders.length,
              ),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 300,
                mainAxisExtent: 80,
                crossAxisSpacing: 16,
                mainAxisSpacing: 12,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
          SliverList(
            key: const ValueKey('library-list'),
            delegate: SliverChildBuilderDelegate((_, index) {
              if (index < leading) {
                return SizedBox(height: 76, child: _createMenu(tile: true));
              }
              final note = notes[index - leading];
              return _noteRow(note, selectable.containsKey(note.id));
            }, childCount: notes.length + leading),
          ),
        ],
        if (notes.isEmpty && (widget.showTrash || widget.searchError == null))
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Text(
                !widget.showTrash && widget.searchPending
                    ? '검색 중…'
                    : _query.isNotEmpty || filter != 'all'
                    ? '조건에 맞는 문서가 없습니다.'
                    : widget.showTrash
                    ? '휴지통이 비어 있습니다.'
                    : '생성을 눌러 이 폴더에 문서를 추가하세요.',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 28)),
      ],
    );
  }
}

/// A folder outline with a tab, behind the folder covers.
class _FolderShape extends CustomPainter {
  const new({required this.fill, required this.border});

  final Color fill;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    const tabHeight = 14.0;
    final tab = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, size.width * .4, tabHeight * 2),
      const Radius.circular(10),
    );
    final body = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, tabHeight, size.width, size.height - tabHeight),
      topRight: const Radius.circular(14),
      bottomLeft: const Radius.circular(14),
      bottomRight: const Radius.circular(14),
    );
    final outline = Path.combine(
      PathOperation.union,
      Path()..addRRect(tab),
      Path()..addRRect(body),
    );
    canvas
      ..drawPath(outline, Paint()..color = fill)
      ..drawPath(
        outline,
        Paint()
          ..color = border
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
  }

  @override
  bool shouldRepaint(_FolderShape oldDelegate) =>
      fill != oldDelegate.fill || border != oldDelegate.border;
}

String _createLabel(LibraryCreateAction action) => switch (action) {
  LibraryCreateAction.handwriting => '페이지 노트',
  LibraryCreateAction.quickNote => '빠른 메모',
  LibraryCreateAction.infinite => '무한 노트',
  LibraryCreateAction.markdown => 'Markdown',
  LibraryCreateAction.dailyNote => '오늘 노트',
  LibraryCreateAction.datedNote => '날짜별 노트',
  LibraryCreateAction.dailyNoteTemplate => '날짜별 노트 템플릿',
  LibraryCreateAction.obsidianVault => 'Obsidian 보관함 가져오기',
  LibraryCreateAction.notionZip => 'Notion ZIP 가져오기',
  LibraryCreateAction.starnote => 'StarNote 가져오기',
  LibraryCreateAction.canvas => '카드 캔버스',
  LibraryCreateAction.page => '블록 페이지',
  LibraryCreateAction.database => '데이터베이스',
  LibraryCreateAction.pdf => 'PDF 가져오기',
  LibraryCreateAction.image => '이미지 가져오기',
  LibraryCreateAction.camera => '사진 촬영',
  LibraryCreateAction.office => 'Office·한글 가져오기',
  LibraryCreateAction.wordDocument => 'Word 문서 만들기',
  LibraryCreateAction.presentation => '프레젠테이션 만들기',
  LibraryCreateAction.hwpx => '한글 문서 만들기',
  LibraryCreateAction.folder => '새 폴더',
};

IconData _createIcon(LibraryCreateAction action) => switch (action) {
  LibraryCreateAction.handwriting ||
  LibraryCreateAction.quickNote => Icons.note_alt_outlined,
  LibraryCreateAction.infinite => Icons.all_out,
  LibraryCreateAction.markdown => Icons.article_outlined,
  LibraryCreateAction.dailyNote ||
  LibraryCreateAction.datedNote => Icons.calendar_month,
  LibraryCreateAction.dailyNoteTemplate => Icons.edit_calendar_outlined,
  LibraryCreateAction.obsidianVault => Icons.folder_open_outlined,
  LibraryCreateAction.notionZip => Icons.folder_zip_outlined,
  LibraryCreateAction.starnote => Icons.picture_as_pdf_outlined,
  LibraryCreateAction.canvas => Icons.dashboard_customize_outlined,
  LibraryCreateAction.page => Icons.view_agenda_outlined,
  LibraryCreateAction.database => Icons.table_chart_outlined,
  LibraryCreateAction.pdf => Icons.picture_as_pdf_outlined,
  LibraryCreateAction.image => Icons.image_outlined,
  LibraryCreateAction.camera => Icons.camera_alt_outlined,
  LibraryCreateAction.office => Icons.description_outlined,
  LibraryCreateAction.wordDocument => Icons.description_outlined,
  LibraryCreateAction.presentation => Icons.slideshow_outlined,
  LibraryCreateAction.hwpx => Icons.description_outlined,
  LibraryCreateAction.folder => Icons.create_new_folder_outlined,
};

String _kindLabel(VaultDocumentKind kind) => switch (kind) {
  VaultDocumentKind.handwriting => '페이지 노트',
  VaultDocumentKind.infinite => '무한 노트',
  VaultDocumentKind.markdown => 'Markdown',
  VaultDocumentKind.canvas => '카드 캔버스',
  VaultDocumentKind.page => '블록 페이지',
  VaultDocumentKind.database => '데이터베이스',
  VaultDocumentKind.pdf => 'PDF',
  VaultDocumentKind.image => '이미지 노트',
  VaultDocumentKind.office => 'Office·한글',
};

IconData _kindIcon(VaultDocumentKind kind) => switch (kind) {
  VaultDocumentKind.handwriting => Icons.draw_outlined,
  VaultDocumentKind.infinite => Icons.all_out,
  VaultDocumentKind.markdown => Icons.article_outlined,
  VaultDocumentKind.canvas => Icons.dashboard_customize_outlined,
  VaultDocumentKind.page => Icons.view_agenda_outlined,
  VaultDocumentKind.database => Icons.table_chart_outlined,
  VaultDocumentKind.pdf => Icons.picture_as_pdf_outlined,
  VaultDocumentKind.image => Icons.image_outlined,
  VaultDocumentKind.office => Icons.description_outlined,
};

class _CreateBorder extends CustomPainter {
  final Color color;
  const new(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(10)),
      );
    final paint = Paint()
      ..color = color.withValues(alpha: .7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final metric in path.computeMetrics()) {
      for (double distance = 0; distance < metric.length; distance += 12) {
        canvas.drawPath(metric.extractPath(distance, distance + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CreateBorder oldDelegate) => oldDelegate.color != color;
}

/// The library's search box in the side bar: typing narrows the documents
/// beside it, as the box over the documents used to.
class LibrarySearchField extends StatefulWidget {
  const new({
    super.key,
    required this.query,
    required this.onChanged,
    this.expression = false,
    this.onExpressionChanged,
    this.enabled = true,
    this.onSubmitted,
  });

  final String query;
  final ValueChanged<String> onChanged;

  /// Whether the query is a search expression (file:, tag:, OR ...).
  final bool expression;

  /// Turns search expressions on or off; null hides the switch (the trash).
  final ValueChanged<bool>? onExpressionChanged;
  final bool enabled;
  final VoidCallback? onSubmitted;

  @override
  State<LibrarySearchField> createState() => _LibrarySearchFieldState();
}

class _LibrarySearchFieldState extends State<LibrarySearchField> {
  late final _text = TextEditingController(text: widget.query);

  @override
  void didUpdateWidget(covariant LibrarySearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A search set elsewhere (a bookmark, the title's ×) shows here too.
    final query = widget.query;
    if (query != _text.text) {
      _text.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expression = widget.onExpressionChanged;
    return TextField(
      key: const ValueKey('library-search'),
      controller: _text,
      enabled: widget.enabled,
      autocorrect: !widget.expression,
      smartDashesType: widget.expression ? SmartDashesType.disabled : null,
      smartQuotesType: widget.expression ? SmartQuotesType.disabled : null,
      textInputAction: TextInputAction.search,
      onChanged: widget.onChanged,
      onSubmitted: (_) => widget.onSubmitted?.call(),
      decoration: InputDecoration(
        hintText: '검색',
        prefixIcon: const Icon(Icons.search, size: 22),
        suffixIcon: expression == null
            ? null
            : IconButton(
                key: const ValueKey('library-search-expression'),
                tooltip: widget.expression ? '검색식 끄기' : '검색식 켜기',
                isSelected: widget.expression,
                icon: const Icon(Icons.manage_search),
                onPressed: widget.enabled
                    ? () => expression(!widget.expression)
                    : null,
              ),
        isDense: true,
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderSide: BorderSide.none,
          borderRadius: BorderRadius.circular(10),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }
}
