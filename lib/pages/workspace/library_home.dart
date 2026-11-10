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

enum LibraryNoteAction { rename, move, trash, restore }

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
  final ValueChanged<String>? onSearchChanged;
  final ValueChanged<bool>? onSearchExpressionChanged;
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
    this.onSearchExpressionChanged,
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
  });

  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

class _LibraryHomeState extends State<LibraryHome> {
  static const _teal = Color(0xff237d82);
  final _createTileMenu =
      GlobalKey<PopupMenuButtonState<LibraryCreateAction>>();
  late final _searchText = TextEditingController(text: widget.searchQuery);
  String get _query => _searchText.text;
  var _filter = 'all';
  var _grid = true;
  var _sortByTitle = false;
  final _scheduledPreviews = <String>{};
  final _selectedNoteIds = <String>{};

  @override
  void didUpdateWidget(covariant LibraryHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    final query = widget.searchQuery;
    if (query != null && query != _searchText.text) {
      _searchText.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
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
    _searchText.dispose();
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

  bool _matchesKind(VaultDocumentKind kind) => switch (_filter) {
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

  List<VaultNote> get _notes {
    if (!widget.showTrash && widget.searchPending) return [];
    final query = _query.trim().toLowerCase();
    final notes = widget.notes.where((note) {
      final inLocation = widget.showTrash
          ? note.trashed
          : ((widget.searchAcrossFolders && query.isNotEmpty) ||
                    note.folderId == widget.currentFolderId) &&
                (!note.trashed || note.deletionConflict);
      return inLocation &&
          _matchesKind(note.documentKind) &&
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

  Widget _createButton() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
    decoration: BoxDecoration(
      color: _teal,
      borderRadius: BorderRadius.circular(9),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.add, size: 20, color: Colors.white),
        SizedBox(width: 6),
        Text(
          '생성',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );

  Widget _breadcrumbs() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        TextButton(
          key: const ValueKey('library-root'),
          onPressed: () => widget.onOpenFolder(null),
          child: Text(
            widget.showTrash ? '휴지통' : '내 문서',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 21,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (!widget.showTrash)
          for (final folder in _path) ...[
            const Icon(Icons.chevron_right, size: 19),
            TextButton(
              onPressed: () => widget.onOpenFolder(folder.id),
              child: Text(
                folder.title,
                style: const TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
      ],
    ),
  );

  Widget _search() => TextField(
    key: const ValueKey('library-search'),
    controller: _searchText,
    autocorrect: !widget.searchExpression,
    smartDashesType: widget.searchExpression ? SmartDashesType.disabled : null,
    smartQuotesType: widget.searchExpression ? SmartQuotesType.disabled : null,
    onChanged: (value) {
      setState(_selectedNoteIds.clear);
      widget.onSearchChanged?.call(value);
    },
    enabled: !widget.selectionBusy,
    decoration: InputDecoration(
      hintText: '문서 검색',
      prefixIcon: const Icon(Icons.search, size: 23),
      isDense: true,
      filled: true,
      fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
      border: OutlineInputBorder(
        borderSide: BorderSide.none,
        borderRadius: BorderRadius.circular(10),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
  );

  Widget _searchControls() {
    if (widget.showTrash || widget.onSearchExpressionChanged == null) {
      return _search();
    }
    return Row(
      children: [
        Expanded(child: _search()),
        const SizedBox(width: 8),
        FilterChip(
          key: const ValueKey('library-search-expression'),
          label: const Text('검색식'),
          selected: widget.searchExpression,
          onSelected: widget.selectionBusy
              ? null
              : widget.onSearchExpressionChanged,
        ),
      ],
    );
  }

  Widget _sortAndLayout() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      PopupMenuButton<bool>(
        tooltip: '정렬',
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.sort, size: 22),
              const SizedBox(width: 6),
              Text(_sortByTitle ? '이름순' : '기본 순서'),
            ],
          ),
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

  Widget _filters() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final item in const [
          ('all', '모두'),
          ('ink', '필기'),
          ('pdf', 'PDF'),
          ('markdown', 'Markdown'),
          ('canvas', '캔버스'),
          ('page', '페이지'),
          ('database', '데이터베이스'),
          ('office', 'Office·한글'),
        ])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              key: ValueKey('library-filter-${item.$1}'),
              label: Text(item.$2),
              selected: _filter == item.$1,
              showCheckmark: false,
              onSelected: widget.selectionBusy
                  ? null
                  : (_) {
                      if (_filter == item.$1) return;
                      setState(() {
                        _filter = item.$1;
                        _selectedNoteIds.clear();
                      });
                    },
              selectedColor: _teal.withValues(alpha: .12),
              side: _filter == item.$1
                  ? const BorderSide(color: _teal)
                  : BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
              labelStyle: TextStyle(
                color: _filter == item.$1 ? _teal : null,
                fontWeight: _filter == item.$1
                    ? FontWeight.w600
                    : FontWeight.normal,
              ),
            ),
          ),
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
            if (widget.onFolderAction != null)
              PopupMenuButton<LibraryFolderAction>(
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
                    const PopupMenuItem(
                      value: LibraryFolderAction.move,
                      child: Text('이동'),
                    ),
                    const PopupMenuItem(
                      value: LibraryFolderAction.trash,
                      child: Text('휴지통으로 이동'),
                    ),
                  ],
                ],
              ),
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
                      fontSize: 15,
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
            Row(
              children: [
                Expanded(child: _breadcrumbs()),
                if (canCreate) ...[
                  const SizedBox(width: 10),
                  _createMenu(tile: false),
                ],
              ],
            ),
            const SizedBox(height: 14),
            if (compact) ...[
              _searchControls(),
              Align(alignment: Alignment.centerRight, child: _sortAndLayout()),
            ] else
              Row(
                children: [
                  Expanded(child: _searchControls()),
                  const SizedBox(width: 16),
                  _sortAndLayout(),
                ],
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
            const SizedBox(height: 12),
            _filters(),
            if (widget.selecting) _selectionActions(selectable),
            const SizedBox(height: 18),
            Expanded(
              child: CustomScrollView(
                key: PageStorageKey(
                  'library-${widget.showTrash ? 'trash' : widget.currentFolderId ?? 'root'}-$_grid',
                ),
                slivers: [
                  if (folders.isNotEmpty) ...[
                    SliverGrid(
                      delegate: SliverChildBuilderDelegate(
                        (_, index) => _folderCard(folders[index]),
                        childCount: folders.length,
                      ),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 300,
                            mainAxisExtent: 80,
                            crossAxisSpacing: 16,
                            mainAxisSpacing: 12,
                          ),
                    ),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                  if (_grid)
                    SliverGrid(
                      key: const ValueKey('library-grid'),
                      delegate: SliverChildBuilderDelegate((_, index) {
                        if (canCreate && index == 0) {
                          return Padding(
                            padding: const EdgeInsets.all(4),
                            child: _createMenu(tile: true),
                          );
                        }
                        final note = notes[index - (canCreate ? 1 : 0)];
                        return _noteCard(note, selectable.containsKey(note.id));
                      }, childCount: notes.length + (canCreate ? 1 : 0)),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 245,
                            mainAxisExtent: 290,
                            crossAxisSpacing: 24,
                            mainAxisSpacing: 24,
                          ),
                    )
                  else
                    SliverList(
                      key: const ValueKey('library-list'),
                      delegate: SliverChildBuilderDelegate((_, index) {
                        if (canCreate && index == 0) {
                          return SizedBox(
                            height: 76,
                            child: _createMenu(tile: true),
                          );
                        }
                        final note = notes[index - (canCreate ? 1 : 0)];
                        return _noteRow(note, selectable.containsKey(note.id));
                      }, childCount: notes.length + (canCreate ? 1 : 0)),
                    ),
                  if (notes.isEmpty &&
                      (widget.showTrash || widget.searchError == null))
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 30),
                        child: Text(
                          !widget.showTrash && widget.searchPending
                              ? '검색 중…'
                              : _query.isNotEmpty || _filter != 'all'
                              ? '조건에 맞는 문서가 없습니다.'
                              : widget.showTrash
                              ? '휴지통이 비어 있습니다.'
                              : '생성을 눌러 이 폴더에 문서를 추가하세요.',
                          style: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 28)),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
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
