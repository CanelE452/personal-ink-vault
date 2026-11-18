import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/document_facts.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_marks.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/library_add.dart';
import 'package:saber/pages/workspace/library_cards.dart';
import 'package:saber/pages/workspace/library_menus.dart';

export 'package:saber/pages/workspace/library_cards.dart'
    show LibraryImportJobView;

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

  /// Any Office·한글 original; shared files and older paths still use it.
  office,
  wordDocument,
  presentation,
  hwpx,
  folder,

  /// The + menu imports one format each, as Notein's do.
  importPpt,
  importWord,
  importHwp,

  /// 「새 노트」's 만들기: a page note with the pattern that was just stored
  /// in `stows.lastBackgroundPattern`.
  pageNoteWithPattern,
}

enum LibraryCollectionKind { folder, recent, favorites, label }

/// What the library lists: one folder, or documents from every folder
/// (the drawer's 최근, 즐겨찾기 and labels), which have no folder cards.
final class LibraryCollection {
  const new folder()
    : kind = LibraryCollectionKind.folder,
      noteIds = const [],
      labelId = null,
      name = null;

  /// The most recent first.
  const new recent(this.noteIds)
    : kind = LibraryCollectionKind.recent,
      labelId = null,
      name = null;
  const new favorites()
    : kind = LibraryCollectionKind.favorites,
      noteIds = const [],
      labelId = null,
      name = null;
  const new label(String this.labelId, String this.name)
    : kind = LibraryCollectionKind.label,
      noteIds = const [];

  final LibraryCollectionKind kind;
  final List<String> noteIds;
  final String? labelId;
  final String? name;
}

/// [preview] and [pdf] are for Office·한글 documents only.
enum LibraryNoteAction { rename, move, trash, restore, preview, pdf, tools }

enum LibraryFolderAction { rename, move, trash, restore }

enum LibraryBatchAction { move, trash, restore }

/// The library laid out as Notein's (설계 1–4절): a top bar with five
/// icons, four kind tabs, covers shaped like their documents, and the
/// pencil and + at the bottom right.
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

  /// The parent searches the documents; the search box opens in the top
  /// bar ([LibrarySearchField]) and the title's × clears the search.
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

  /// First in the top bar: the drawer or side panel button (☰).
  final Widget? leading;

  /// Dates, format, pages and cover shape of each document, by note id.
  final Map<String, DocumentFacts> facts;

  /// Favourites, pins, labels and colour covers.
  final LibraryMarks marks;

  /// Imports running in this folder; each is a card at the front, in the
  /// folder and in 최근, 즐겨찾기 and the label views shown over it.
  final List<LibraryImportJobView> importJobs;
  final ValueChanged<String>? onCancelImport;
  final void Function(String targetId)? onToggleFavorite;
  final void Function(String targetId)? onTogglePin;

  /// The workspace opens the label dialog (it knows the vault); an empty
  /// target asks for the label list itself (the ⋯ menu's 라벨 색상).
  final void Function(String targetId)? onEditLabels;
  final void Function(String targetId)? onChangeCover;

  /// 「첫 쪽 표지 만들기」 in the ⌄ menu of an Office original (not 한글)
  /// whose card has no first-page picture: the workspace converts it once
  /// (on Android, where no engine works in the background). Null hides it.
  final ValueChanged<VaultNote>? onMakeCover;

  /// The top bar's gear; without it the gear is not shown.
  final VoidCallback? onOpenSettings;

  /// False greys the gear out, while the workspace is busy.
  final bool settingsEnabled;

  /// The search box's search-expression switch.
  final ValueChanged<bool>? onSearchExpressionChanged;

  /// The top bar's cloud; without it, a crossed-out cloud.
  final Widget? syncButton;
  final LibraryCollection collection;

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
    this.facts = const {},
    this.marks = LibraryMarks.empty,
    this.importJobs = const [],
    this.onCancelImport,
    this.onToggleFavorite,
    this.onTogglePin,
    this.onEditLabels,
    this.onChangeCover,
    this.onMakeCover,
    this.onOpenSettings,
    this.settingsEnabled = true,
    this.onSearchExpressionChanged,
    this.syncButton,
    this.collection = const LibraryCollection.folder(),
  });

  @override
  State<LibraryHome> createState() => _LibraryHomeState();
}

typedef _FolderSummary = ({
  Map<String, int> counts,
  Map<String, DateTime> changed,
  Map<String, VaultNote> first,
});

class _LibraryHomeState extends State<LibraryHome>
    with SingleTickerProviderStateMixin {
  String get _query => widget.searchQuery ?? '';
  var _filter = 'all';
  var _searchOpen = false;

  /// Notein's four kinds as swipeable tabs (설계 1.2절).
  static const _filterTabs = [
    ('all', '모두'),
    ('pdf', 'PDF'),
    ('notes', '메모'),
    ('folders', '폴더'),
  ];
  // A tab tap switches at once (taps on a sliding page would be ignored);
  // swiping still slides.
  late final _tabs = TabController(
    length: _filterTabs.length,
    vsync: this,
    animationDuration: Duration.zero,
  )..addListener(_tabChanged);

  /// The grid or list and the order are kept between visits.
  final _layout = Listenable.merge([stows.libraryGrid, stows.librarySort]);
  final _scheduledPreviews = <String>{};
  final _selectedNoteIds = <String>{};

  void _tabChanged() {
    final next = _filterTabs[_tabs.index].$1;
    if (next == _filter) return;
    setState(() {
      _filter = next;
      _selectedNoteIds.clear();
    });
  }

  bool get _inCollection =>
      !widget.showTrash &&
      widget.collection.kind != LibraryCollectionKind.folder;

  bool get _hearts =>
      widget.onToggleFavorite != null && !widget.showTrash && !widget.selecting;

  @override
  void didUpdateWidget(covariant LibraryHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onSearchChanged == null) _searchOpen = false;
    if (!widget.selecting ||
        !oldWidget.selecting ||
        oldWidget.currentFolderId != widget.currentFolderId ||
        oldWidget.showTrash != widget.showTrash ||
        oldWidget.collection.kind != widget.collection.kind ||
        oldWidget.collection.labelId != widget.collection.labelId ||
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

  /// PDF holds PDFs and the Office·한글 originals (the format mark tells
  /// them apart); 메모 holds every other kind; 폴더 only the folders.
  bool _matchesKind(VaultDocumentKind kind, String filter) => switch (filter) {
    'pdf' => kind == VaultDocumentKind.pdf || kind == VaultDocumentKind.office,
    'notes' =>
      kind != VaultDocumentKind.pdf && kind != VaultDocumentKind.office,
    'folders' => false,
    _ => true,
  };

  List<VaultNote> get _notes => _notesFor(_filter);

  List<VaultNote> _notesFor(String filter) {
    if (!widget.showTrash && widget.searchPending) return [];
    final query = _query.trim().toLowerCase();
    bool shown(VaultNote note) =>
        _matchesKind(note.documentKind, filter) &&
        (widget.onSearchChanged != null ||
            query.isEmpty ||
            note.title.toLowerCase().contains(query));
    final Iterable<VaultNote> candidates;
    if (widget.showTrash) {
      candidates = widget.notes.where((note) => note.trashed);
    } else if (_inCollection) {
      candidates = _collectionNotes();
    } else {
      candidates = widget.notes.where(
        (note) =>
            ((widget.searchAcrossFolders && query.isNotEmpty) ||
                note.folderId == widget.currentFolderId) &&
            (!note.trashed || note.deletionConflict),
      );
    }
    return _sorted(candidates.where(shown).toList());
  }

  List<VaultNote> _collectionNotes() {
    final live = [
      for (final note in widget.notes)
        if (!note.trashed || note.deletionConflict) note,
    ];
    final collection = widget.collection;
    switch (collection.kind) {
      case LibraryCollectionKind.recent:
        final byId = <String, List<VaultNote>>{};
        for (final note in live) {
          (byId[note.id] ??= []).add(note);
        }
        final seen = <String>{};
        return [
          for (final id in collection.noteIds)
            if (seen.add(id)) ...?byId[id],
        ];
      case LibraryCollectionKind.favorites:
        return [
          for (final note in live)
            if (widget.marks.favorites.contains(note.id)) note,
        ];
      case LibraryCollectionKind.label:
        return [
          for (final note in live)
            if (widget.marks.labelsOf[note.id]?.contains(collection.labelId) ??
                false)
              note,
        ];
      case LibraryCollectionKind.folder:
        return live;
    }
  }

  /// Pinned documents first, then the chosen order; documents without the
  /// date being sorted on go last. Ties keep the given order.
  List<VaultNote> _sorted(List<VaultNote> notes) {
    final sort = stows.librarySort.value;
    final pinned = widget.marks.pinned;
    // VaultNote keeps Object's identity equality, so each note is its own key.
    final order = {for (final (index, note) in notes.indexed) note: index};
    DateTime? date(VaultNote note) => switch (sort) {
      'changed' => widget.facts[note.id]?.changed,
      'created' => widget.facts[note.id]?.created,
      _ => null,
    };
    int compare(VaultNote a, VaultNote b) {
      final pinA = pinned.contains(a.id), pinB = pinned.contains(b.id);
      if (pinA != pinB) return pinA ? -1 : 1;
      if (sort == 'title') {
        final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
        if (byTitle != 0) return byTitle;
      } else if (sort == 'changed' || sort == 'created') {
        final dateA = date(a), dateB = date(b);
        if (dateA == null && dateB != null) return 1;
        if (dateA != null && dateB == null) return -1;
        if (dateA != null && dateB != null) {
          final latest = dateB.compareTo(dateA);
          if (latest != 0) return latest;
        }
      }
      return order[a]!.compareTo(order[b]!);
    }

    return notes..sort(compare);
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
    if (_inCollection) return const [];
    if (!widget.showTrash &&
        widget.searchExpression &&
        _query.trim().isNotEmpty) {
      return [];
    }
    final query = _query.trim().toLowerCase();
    final pinned = widget.marks.pinned;
    return widget.folders.where((folder) {
      final inLocation = widget.showTrash
          ? folder.trashed
          : folder.parentId == widget.currentFolderId &&
                (!folder.trashed || folder.deletionConflict);
      return inLocation &&
          (query.isEmpty || folder.title.toLowerCase().contains(query));
    }).toList()..sort((a, b) {
      final pinA = pinned.contains(a.id), pinB = pinned.contains(b.id);
      if (pinA != pinB) return pinA ? -1 : 1;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  }

  /// Per folder: its documents (inside folders too), the latest change
  /// among them, and its first document for the cover.
  _FolderSummary _folderSummary() {
    final parents = {
      for (final folder in widget.folders) folder.id: folder.parentId,
    };
    final counts = <String, int>{};
    final changed = <String, DateTime>{};
    final first = <String, VaultNote>{};
    for (final note in widget.notes) {
      if (note.trashed) continue;
      if (note.folderId case final folder?)
        first.putIfAbsent(folder, () => note);
      final time = widget.facts[note.id]?.changed;
      var id = note.folderId;
      final seen = <String>{};
      while (id != null && seen.add(id)) {
        counts[id] = (counts[id] ?? 0) + 1;
        if (time != null && (changed[id]?.isBefore(time) ?? true)) {
          changed[id] = time;
        }
        id = parents[id];
      }
    }
    return (counts: counts, changed: changed, first: first);
  }

  String _locationOf(VaultNote note) {
    if (note.trashed) return '휴지통';
    final byId = {for (final folder in widget.folders) folder.id: folder};
    final names = <String>[];
    final seen = <String>{};
    var id = note.folderId;
    while (id != null && seen.add(id)) {
      final folder = byId[id];
      if (folder == null) break;
      names.insert(0, folder.title);
      id = folder.parentId;
    }
    return ['내 문서', ...names].join(' › ');
  }

  /// The title on the left of the top bar, after ☰ (사진 1000319967): ‹ and
  /// the folder's name inside a folder, nothing on the first screen.
  Widget _title(bool compact) {
    final style = TextStyle(
      color: Theme.of(context).colorScheme.onSurface,
      fontSize: compact ? 16 : 18,
      fontWeight: FontWeight.w600,
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
        children: [
          const SizedBox(width: 8),
          title(widget.showTrash ? "휴지통 '$query' 검색 결과" : "'$query' 검색 결과"),
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
    final named = widget.showTrash
        ? '휴지통'
        : switch (widget.collection.kind) {
            LibraryCollectionKind.recent => '최근',
            LibraryCollectionKind.favorites => '즐겨찾기',
            LibraryCollectionKind.label => widget.collection.name ?? '',
            LibraryCollectionKind.folder => null,
          };
    if (named != null) {
      return Row(children: [const SizedBox(width: 8), title(named)]);
    }
    final path = _path;
    if (path.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        IconButton(
          key: const ValueKey('library-up'),
          tooltip: '위 폴더로',
          icon: const Icon(Icons.chevron_left),
          onPressed: () => widget.onOpenFolder(
            path.length > 1 ? path[path.length - 2].id : null,
          ),
        ),
        title(path.last.title),
      ],
    );
  }

  /// Notein's top bar (사진 1000319963): ☰ and the title on the left; the
  /// cloud, search, settings, select and ⋯ on the right. Search opens its
  /// box in the bar itself.
  Widget _topBar(bool compact) {
    final search = widget.onSearchChanged;
    if (_searchOpen && search != null) {
      return SizedBox(
        height: 48,
        child: Row(
          children: [
            ?widget.leading,
            const SizedBox(width: 8),
            Expanded(
              child: LibrarySearchField(
                query: _query,
                onChanged: search,
                expression: widget.searchExpression,
                onExpressionChanged: widget.showTrash
                    ? null
                    : widget.onSearchExpressionChanged,
                enabled: !widget.selectionBusy,
                autofocus: true,
              ),
            ),
            IconButton(
              key: const ValueKey('library-search-toggle'),
              tooltip: '검색 닫기',
              icon: const Icon(Icons.close),
              iconSize: 22,
              style: libraryBarButtonStyle,
              onPressed: () => setState(() => _searchOpen = false),
            ),
            const SizedBox(width: 4),
          ],
        ),
      );
    }
    final select = widget.onSelectionChanged;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          ?widget.leading,
          Expanded(child: _title(compact)),
          widget.syncButton ??
              const Tooltip(
                message: '동기화 연결 없음',
                child: SizedBox(
                  key: ValueKey('library-sync'),
                  width: 40,
                  height: 40,
                  child: Icon(Icons.cloud_off_outlined, size: 22),
                ),
              ),
          if (search != null)
            IconButton(
              key: const ValueKey('library-search-toggle'),
              tooltip: '검색',
              icon: const Icon(Icons.search),
              iconSize: 22,
              style: libraryBarButtonStyle,
              onPressed: () => setState(() => _searchOpen = true),
            ),
          if (widget.onOpenSettings case final open?)
            IconButton(
              key: const ValueKey('library-settings'),
              tooltip: '설정',
              icon: const Icon(Icons.settings_outlined),
              iconSize: 22,
              style: libraryBarButtonStyle,
              onPressed: widget.settingsEnabled ? open : null,
            ),
          if (select != null)
            IconButton(
              key: const ValueKey('library-select-mode'),
              tooltip: widget.selecting ? '일괄 관리 닫기' : '일괄 관리',
              isSelected: widget.selecting,
              iconSize: 22,
              style: libraryBarButtonStyle,
              onPressed: widget.selectionBusy
                  ? null
                  : () => select(!widget.selecting),
              icon: const Icon(Icons.check_circle_outline),
              selectedIcon: const Icon(Icons.check_circle),
            ),
          LibraryViewMenu(
            key: const ValueKey('library-view-menu'),
            grid: stows.libraryGrid.value,
            sort: stows.librarySort.value,
            labels: widget.marks.labels,
            onGrid: (grid) => stows.libraryGrid.value = grid,
            onSort: (sort) => stows.librarySort.value = sort,
            onEditLabels: widget.onEditLabels,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

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

  /// The pill with four cells; the chosen one is a white pill (설계 1.2절).
  /// In light mode the track is Notein's light grey.
  Widget _filters() {
    final scheme = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    return IgnorePointer(
      ignoring: widget.selectionBusy,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: light
              ? const Color(0xFFEFEFF1)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: TabBar(
          key: const ValueKey('library-filter-tabs'),
          controller: _tabs,
          indicator: BoxDecoration(
            color: light ? Colors.white : scheme.surface,
            borderRadius: BorderRadius.circular(14),
            boxShadow: const [
              BoxShadow(
                color: Color(0x24000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          indicatorSize: TabBarIndicatorSize.tab,
          indicatorPadding: const EdgeInsets.all(2),
          dividerColor: Colors.transparent,
          labelColor: scheme.onSurface,
          unselectedLabelColor: scheme.onSurfaceVariant,
          labelStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          unselectedLabelStyle: const TextStyle(fontSize: 14),
          splashBorderRadius: BorderRadius.circular(16),
          tabs: [
            for (final (id, label) in _filterTabs)
              Tab(key: ValueKey('library-filter-$id'), text: label, height: 30),
          ],
        ),
      ),
    );
  }

  Widget _conflict() => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xff95620d)),
      SizedBox(width: 3),
      Text('변경 충돌', style: TextStyle(fontSize: 11, color: Color(0xff95620d))),
    ],
  );

  void _schedulePreview(VaultNote note) {
    if (widget.onPreviewRequested != null &&
        _scheduledPreviews.add(note.revision.revisionId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scheduledPreviews.remove(note.revision.revisionId);
        if (mounted) widget.onPreviewRequested?.call(note);
      });
    }
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

  /// The heart: drawn in the cover's top-right corner, touched anywhere in
  /// its 48×48 area.
  Widget _heart(String id, {Alignment alignment = Alignment.topRight}) {
    final favourite = widget.marks.favorites.contains(id);
    return LibraryTouchTarget(
      key: ValueKey('library-favorite-$id'),
      label: '즐겨찾기',
      tooltip: favourite ? '즐겨찾기 해제' : '즐겨찾기',
      toggled: favourite,
      alignment: alignment,
      onTap: () => widget.onToggleFavorite!(id),
      child: Padding(
        padding: EdgeInsets.all(alignment == Alignment.topRight ? 5 : 0),
        child: Icon(
          favourite ? Icons.favorite : Icons.favorite_border,
          size: 18,
          color: favourite ? const Color(0xFFE53935) : const Color(0xFF8A8A8A),
        ),
      ),
    );
  }

  /// The pin in a cover's bottom-left corner.
  List<Widget> _coverMarks(String id) => [
    if (widget.marks.pinned.contains(id))
      Positioned(
        left: 4,
        bottom: 4,
        child: Icon(
          Icons.push_pin,
          key: ValueKey('library-pin-$id'),
          size: 12,
          color: const Color(0xFF5F6368),
        ),
      ),
  ];

  Widget _noteCover(
    VaultNote note,
    DocumentFacts? facts,
    Size size, {
    bool small = false,
  }) {
    final format = note.documentKind == VaultDocumentKind.office
        ? libraryFormatOf(facts?.format)
        : null;
    return LibraryCover(
      key: ValueKey('library-cover-${note.id}'),
      size: size,
      title: note.title,
      image: widget.thumbnails[note.id],
      color: widget.marks.covers[note.id]?.color,
      format: format,
      icon: libraryKindIcon(note.documentKind),
      overlays: [
        if (format != null)
          Positioned(
            left: 0,
            top: 0,
            width: size.width * .4,
            height: size.height * .3,
            child: LibraryFormatMark(
              key: ValueKey('library-format-${note.id}'),
              label: format.label,
              color: format.color,
              tag: !small,
            ),
          ),
        ..._coverMarks(note.id),
      ],
    );
  }

  Widget _folderCover(
    VaultFolder folder,
    VaultNote? first,
    Size size, {
    bool small = false,
  }) => LibraryCover(
    key: ValueKey('library-cover-${folder.id}'),
    size: size,
    title: folder.title,
    image: first == null ? null : widget.thumbnails[first.id],
    color: widget.marks.covers[folder.id]?.color,
    icon: small ? Icons.folder_outlined : null,
    overlays: _coverMarks(folder.id),
  );

  /// The grey line: the date and pages, or a folder's documents, after up
  /// to three label colours.
  Widget _line(String text, String id, {required bool center}) {
    final colours = {
      for (final label in widget.marks.labels) label.id: Color(label.color),
    };
    final dots = [
      for (final labelId in widget.marks.labelsOf[id] ?? const <String>{})
        ?colours[labelId],
    ].take(3).toList();
    return Row(
      mainAxisAlignment: center
          ? MainAxisAlignment.center
          : MainAxisAlignment.start,
      children: [
        if (dots.isNotEmpty) ...[
          Row(
            key: ValueKey('library-label-dots-$id'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final colour in dots)
                Padding(
                  padding: const EdgeInsets.only(right: 3),
                  child: SizedBox(
                    width: 7,
                    height: 7,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colour,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 3),
        ],
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _noteLine(
    VaultNote note,
    DocumentFacts? facts, {
    required bool center,
  }) => note.deletionConflict
      ? _conflict()
      : _line(libraryNoteSubtitle(note, facts), note.id, center: center);

  Widget _folderLine(
    VaultFolder folder,
    _FolderSummary? summary, {
    required bool center,
  }) {
    if (folder.deletionConflict) return _conflict();
    final count = summary?.counts[folder.id] ?? 0;
    final changed = summary?.changed[folder.id];
    return _line(
      changed == null ? '$count 메모' : '${libraryDate(changed)} · $count 메모',
      folder.id,
      center: center,
    );
  }

  /// Whether the card offers 「첫 쪽 표지 만들기」: an Office original other
  /// than 한글 (which has a background engine) without a first-page picture.
  bool _canMakeCover(VaultNote note) =>
      widget.onMakeCover != null &&
      !note.trashed &&
      note.documentKind == VaultDocumentKind.office &&
      widget.thumbnails[note.id] == null &&
      switch (widget.facts[note.id]?.format) {
        null || 'hwp' || 'hwpx' => false,
        _ => true,
      };

  /// The ⌄ menu; in the [grid] it is the card's title line.
  Widget? _noteMenu(VaultNote note, {bool grid = false}) {
    if (note.trashed && widget.onNoteAction == null) return null;
    return LibraryNoteMenu(
      key: ValueKey('library-note-menu-${note.revision.revisionId}'),
      note: note,
      title: grid ? note.title : null,
      pinned: widget.marks.pinned.contains(note.id),
      onNoteAction: widget.onNoteAction,
      onTogglePin: widget.onTogglePin,
      onChangeCover: widget.onChangeCover,
      onMakeCover: _canMakeCover(note) ? () => widget.onMakeCover!(note) : null,
      onEditLabels: widget.onEditLabels,
      onDetails: () => unawaited(
        showLibraryDetails(
          context,
          note: note,
          facts: widget.facts[note.id],
          location: _locationOf(note),
        ),
      ),
    );
  }

  Widget? _folderMenu(VaultFolder folder, {bool grid = false}) {
    if (widget.selecting) return null;
    final menu = LibraryFolderMenu(
      key: ValueKey('library-folder-menu-${folder.id}'),
      folder: folder,
      title: grid ? folder.title : null,
      pinned: widget.marks.pinned.contains(folder.id),
      onFolderAction: widget.onFolderAction,
      onTogglePin: widget.onTogglePin,
      onChangeCover: widget.onChangeCover,
      onEditLabels: widget.onEditLabels,
    );
    return menu.hasRows ? menu : null;
  }

  VoidCallback? _cancel(LibraryImportJobView job) =>
      switch (widget.onCancelImport) {
        final cancel? => () => cancel(job.id),
        null => null,
      };

  Widget _gridItem(
    Object item,
    Map<String, VaultNote> selectable,
    _FolderSummary? summary,
  ) {
    switch (item) {
      case final LibraryImportJobView job:
        return LibraryImportCard(
          key: ValueKey('library-import-${job.id}'),
          job: job,
          onCancel: _cancel(job),
        );
      case final VaultFolder folder:
        final first = summary?.first[folder.id];
        if (first != null) _schedulePreview(first);
        return LibraryCardCell(
          key: ValueKey('library-folder-${folder.id}'),
          aspect: 4 / 3,
          stacked: true,
          cover: (size) => _folderCover(folder, first, size),
          title: folder.title,
          titleLine:
              _folderMenu(folder, grid: true) ?? LibraryCardTitle(folder.title),
          subtitle: _folderLine(folder, summary, center: true),
          // No heart: 즐겨찾기 lists documents only.
          onTap: () => widget.onOpenFolder(folder.id),
        );
      case final VaultNote note:
        _schedulePreview(note);
        final facts = widget.facts[note.id];
        final canSelect = selectable.containsKey(note.id);
        return LibraryCardCell(
          key: ValueKey('library-note-${note.revision.revisionId}'),
          aspect: libraryCoverAspect(note.documentKind, facts),
          cover: (size) => _noteCover(note, facts, size),
          title: note.title,
          // While selecting the title is plain; the check box takes the
          // cover box's corner.
          titleLine:
              (widget.selecting ? null : _noteMenu(note, grid: true)) ??
              LibraryCardTitle(note.title),
          subtitle: _noteLine(note, facts, center: true),
          below: [?_searchExcerpt(note)],
          corner: widget.selecting ? _noteCheckbox(note, canSelect) : null,
          coverCorner: _hearts ? _heart(note.id) : null,
          onTap: _noteActivation(note, canSelect),
        );
    }
    return const SizedBox.shrink();
  }

  Widget _listItem(
    Object item,
    Map<String, VaultNote> selectable,
    _FolderSummary? summary,
  ) {
    switch (item) {
      case final LibraryImportJobView job:
        return LibraryImportCard(
          key: ValueKey('library-import-${job.id}'),
          job: job,
          onCancel: _cancel(job),
          list: true,
        );
      case final VaultFolder folder:
        final first = summary?.first[folder.id];
        if (first != null) _schedulePreview(first);
        return LibraryListRow(
          key: ValueKey('library-folder-${folder.id}'),
          aspect: 4 / 3,
          cover: (size) => _folderCover(folder, first, size, small: true),
          title: folder.title,
          subtitle: _folderLine(folder, summary, center: false),
          trailing: [?_folderMenu(folder)],
          onTap: () => widget.onOpenFolder(folder.id),
        );
      case final VaultNote note:
        _schedulePreview(note);
        final facts = widget.facts[note.id];
        final canSelect = selectable.containsKey(note.id);
        final line = _noteLine(note, facts, center: false);
        final excerpt = _searchExcerpt(note);
        return LibraryListRow(
          key: ValueKey('library-note-${note.revision.revisionId}'),
          aspect: libraryCoverAspect(note.documentKind, facts),
          cover: (size) => _noteCover(note, facts, size, small: true),
          title: note.title,
          subtitle: excerpt == null
              ? line
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [line, excerpt],
                ),
          trailing: [
            if (_hearts) _heart(note.id, alignment: Alignment.center),
            if (widget.selecting)
              _noteCheckbox(note, canSelect)
            else
              ?_noteMenu(note),
          ],
          onTap: _noteActivation(note, canSelect),
        );
    }
    return const SizedBox.shrink();
  }

  /// Notein's empty screen (사진 1000319979) when nothing is here at all;
  /// a search, a kind tab or the trash keep their own words.
  Widget _empty() {
    final muted = TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    if (!widget.showTrash && widget.searchError != null) {
      return const SizedBox.shrink();
    }
    final String? words;
    if (!widget.showTrash && widget.searchPending) {
      words = '검색 중…';
    } else if (widget.showTrash) {
      words = _query.trim().isEmpty ? '휴지통이 비어 있습니다.' : '조건에 맞는 문서가 없습니다.';
    } else if (_query.trim().isNotEmpty ||
        _notesFor('all').isNotEmpty ||
        _folders.isNotEmpty) {
      words = '조건에 맞는 문서가 없습니다.';
    } else if (_inCollection) {
      // The first-run hint is for an empty folder only.
      words = switch (widget.collection.kind) {
        LibraryCollectionKind.favorites => '즐겨찾기한 문서가 없습니다',
        LibraryCollectionKind.recent => '최근에 연 문서가 없습니다',
        LibraryCollectionKind.label => '이 라벨이 붙은 문서가 없습니다',
        LibraryCollectionKind.folder => null,
      };
    } else {
      words = null;
    }
    if (words != null) {
      return Center(child: Text(words, style: muted));
    }
    final accent = Theme.of(context).colorScheme.primary;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          key: const ValueKey('library-empty'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.inventory_2_outlined, size: 48, color: accent),
            const SizedBox(height: 16),
            Text(
              '아직 노트가 없습니다',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: accent,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '아래쪽 모서리의 +를 탭하여 노트를 만들거나 문서를 가져오세요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: accent, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _layout,
    builder: (context, _) => LayoutBuilder(builder: _body),
  );

  Widget _body(BuildContext context, BoxConstraints constraints) {
    final compact = constraints.maxWidth < 560;
    final pad = compact ? 16.0 : 24.0;
    final width = constraints.maxWidth - 2 * pad;
    // A column is at least 128 wide; a phone always gets two.
    final columns = max(2, (width / 128).floor());
    final notes = _notes;
    final selectable = widget.selecting
        ? _selectable(notes)
        : const <String, VaultNote>{};
    final canCreate =
        !widget.showTrash &&
        !widget.selecting &&
        widget.availableCreateActions.isNotEmpty;
    final theme = Theme.of(context);
    // Notein's page is pure white; a dark theme keeps its own surface. A
    // Material, so list rows draw their ink on the page.
    return Material(
      key: const ValueKey('library-page'),
      color: theme.brightness == Brightness.light
          ? Colors.white
          : theme.colorScheme.surface,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _topBar(compact),
              Divider(
                key: const ValueKey('library-top-divider'),
                height: 1,
                color: libraryLine(context),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(pad, 8, pad, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!widget.showTrash && widget.searchExpression) ...[
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
                      const SizedBox(height: 8),
                    ],
                    _filters(),
                    if (widget.selecting) _selectionActions(selectable),
                  ],
                ),
              ),
              const SizedBox(height: 4),
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
                        selectable: filter == _filter
                            ? selectable
                            : const <String, VaultNote>{},
                        pad: pad,
                        cell: width / columns,
                        columns: columns,
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (canCreate)
            Positioned(
              right: pad,
              bottom: pad,
              child: LibraryAddButtons(
                available: widget.availableCreateActions,
                onCreate: widget.onCreate,
              ),
            ),
        ],
      ),
    );
  }

  Widget _content(
    String filter, {
    required List<VaultNote> notes,
    required Map<String, VaultNote> selectable,
    required double pad,
    required double cell,
    required int columns,
  }) {
    final grid = stows.libraryGrid.value;
    final folders = filter == 'all' || filter == 'folders'
        ? _folders
        : const <VaultFolder>[];
    // An import started from 최근, 즐겨찾기 or a label shows there too.
    final jobs = filter == 'folders' || widget.showTrash
        ? const <LibraryImportJobView>[]
        : widget.importJobs;
    final pinned = widget.marks.pinned;
    // Imports first, then what is pinned, folders before documents.
    final items = <Object>[
      ...jobs,
      for (final folder in folders)
        if (pinned.contains(folder.id)) folder,
      for (final note in notes)
        if (pinned.contains(note.id)) note,
      for (final folder in folders)
        if (!pinned.contains(folder.id)) folder,
      for (final note in notes)
        if (!pinned.contains(note.id)) note,
    ];
    final summary = folders.isEmpty ? null : _folderSummary();
    final excerpts =
        widget.onOpenBodyMatch != null &&
        widget.searchBodyMatches.isNotEmpty &&
        !widget.selecting &&
        !widget.searchPending &&
        !widget.showTrash;
    final location = widget.showTrash
        ? 'trash'
        : _inCollection
        ? '${widget.collection.kind.name}-${widget.collection.labelId}'
        : widget.currentFolderId ?? 'root';
    return CustomScrollView(
      key: PageStorageKey('library-$location-$grid-$filter'),
      slivers: [
        if (items.isNotEmpty) ...[
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            sliver: grid
                ? SliverGrid(
                    key: const ValueKey('library-grid'),
                    delegate: SliverChildBuilderDelegate(
                      (_, index) =>
                          _gridItem(items[index], selectable, summary),
                      childCount: items.length,
                    ),
                    // The cover box (80% of the column, 1.33 times as tall)
                    // and room for a two-line title and the progress of an
                    // import.
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisExtent:
                          cell * .8 * 1.33 + 88 + (excerpts ? 44 : 0),
                    ),
                  )
                : SliverList(
                    key: const ValueKey('library-list'),
                    delegate: SliverChildBuilderDelegate(
                      (_, index) =>
                          _listItem(items[index], selectable, summary),
                      childCount: items.length,
                    ),
                  ),
          ),
          // Documents are still being searched for under the folders and
          // imports already shown.
          if (!widget.showTrash && widget.searchPending)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    '검색 중…',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          // Room under the pencil and the +.
          const SliverToBoxAdapter(child: SizedBox(height: 136)),
        ] else
          SliverFillRemaining(hasScrollBody: false, child: _empty()),
      ],
    );
  }
}

/// The library's search box, opened in the top bar: typing narrows the
/// documents below it.
class LibrarySearchField extends StatefulWidget {
  const new({
    super.key,
    required this.query,
    required this.onChanged,
    this.expression = false,
    this.onExpressionChanged,
    this.enabled = true,
    this.onSubmitted,
    this.autofocus = false,
  });

  final String query;
  final ValueChanged<String> onChanged;

  /// Whether the query is a search expression (file:, tag:, OR ...).
  final bool expression;

  /// Turns search expressions on or off; null hides the switch (the trash).
  final ValueChanged<bool>? onExpressionChanged;
  final bool enabled;
  final VoidCallback? onSubmitted;
  final bool autofocus;

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
      autofocus: widget.autofocus,
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
    );
  }
}
