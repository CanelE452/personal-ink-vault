import 'package:flutter/material.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/document_facts.dart';
import 'package:saber/data/vault/library_marks.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/library_cards.dart';
import 'package:saber/pages/workspace/library_home.dart';

/// The eight colours of labels and colour covers.
const libraryPalette = <int>[
  0xFFE53935,
  0xFFFB8C00,
  0xFFFDD835,
  0xFF43A047,
  0xFF00ACC1,
  0xFF1E88E5,
  0xFF3949AB,
  0xFF8E24AA,
];

const _red = Color(0xFFE53935);
const _menuShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(16)),
);

/// Notein's menus in light mode: white boxes with a soft shadow (사진
/// 1000319971·73·81). A dark theme keeps its own menu colours.
({Color? color, Color? tint, Color shadow, double elevation}) libraryMenuLook(
  BuildContext context,
) {
  final light = Theme.of(context).brightness == Brightness.light;
  return (
    color: light ? Colors.white : null,
    tint: light ? Colors.transparent : null,
    shadow: const Color(0x38000000),
    elevation: 8,
  );
}

/// Notein's thin lines in light mode: neutral grey, not the theme's tint.
Color? libraryLine(BuildContext context) =>
    Theme.of(context).brightness == Brightness.light
    ? const Color(0xFFE5E5EA)
    : null;

PopupMenuDivider _divider(BuildContext context) =>
    PopupMenuDivider(color: libraryLine(context));

/// [showMenu] with the library's menu look.
Future<T?> showLibraryMenu<T>(
  BuildContext context, {
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  double width = 240,
}) {
  final look = libraryMenuLook(context);
  return showMenu<T>(
    context: context,
    position: position,
    shape: _menuShape,
    color: look.color,
    surfaceTintColor: look.tint,
    shadowColor: look.shadow,
    elevation: look.elevation,
    constraints: BoxConstraints.tightFor(width: width),
    items: items,
  );
}

PopupMenuItem<T> _row<T>(
  T value,
  IconData icon,
  String label, {
  Key? key,
  Color? color,
  bool more = false,
}) => PopupMenuItem<T>(
  key: key,
  value: value,
  height: 48,
  child: Row(
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 14),
      Expanded(
        child: Text(
          label,
          style: color == null ? null : TextStyle(color: color),
        ),
      ),
      if (more) const Icon(Icons.chevron_right, size: 20),
    ],
  ),
);

/// Where a menu opens under [anchor], in the overlay's coordinates; a menu
/// near the right edge grows to the left from the anchor's right edge.
RelativeRect libraryMenuUnder(BuildContext anchor) {
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return RelativeRect.fromLTRB(
    rect.left,
    rect.bottom,
    overlay.size.width - rect.right,
    overlay.size.height - rect.bottom,
  );
}

/// A list row's ⌄ in the corner of its 48×48 touch area.
class _ArrowButton extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 48,
    height: 48,
    child: Align(
      alignment: Alignment.bottomRight,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Icon(Icons.expand_more, size: 20, color: Color(0xFF8A8A8A)),
      ),
    ),
  );
}

/// A card's ⌄ menu button: white menu in light mode, one button node. It
/// shows a grid card's [title] line with the ⌄ after it (StarNote's
/// 「내 연구 ⌄」) and opens under that line; without a title, a list row's ⌄.
Widget _cardMenu<T>(
  BuildContext context, {
  required String label,
  required PopupMenuItemSelected<T> onSelected,
  required PopupMenuItemBuilder<T> itemBuilder,
  String? title,
}) {
  final look = libraryMenuLook(context);
  return Semantics(
    container: true,
    button: true,
    label: label,
    child: PopupMenuButton<T>(
      tooltip: label,
      position: PopupMenuPosition.under,
      shape: _menuShape,
      color: look.color,
      surfaceTintColor: look.tint,
      shadowColor: look.shadow,
      elevation: look.elevation,
      constraints: const BoxConstraints.tightFor(width: 220),
      onSelected: onSelected,
      itemBuilder: itemBuilder,
      child: title == null
          ? const _ArrowButton()
          : LibraryCardTitle(title, chevron: true),
    ),
  );
}

enum _NoteRow {
  pin,
  rename,
  cover,
  makeCover,
  labels,
  move,
  preview,
  pdf,
  tools,
  trash,
  restore,
  details,
}

/// A document's ⌄ menu (사진 1000319971; the user asked for a v shape where
/// Notein draws ⋮): in the grid the whole title line with the ⌄ after the
/// title, as StarNote has it; at a list row's end the ⌄ alone.
class LibraryNoteMenu extends StatelessWidget {
  const new({
    super.key,
    required this.note,
    required this.pinned,
    required this.onDetails,
    this.title,
    this.onNoteAction,
    this.onTogglePin,
    this.onChangeCover,
    this.onMakeCover,
    this.onEditLabels,
  });

  final VaultNote note;
  final bool pinned;
  final VoidCallback onDetails;

  /// A grid card's title, shown as the button; null for a list row's ⌄.
  final String? title;
  final void Function(VaultNote, LibraryNoteAction)? onNoteAction;
  final void Function(String targetId)? onTogglePin;
  final void Function(String targetId)? onChangeCover;

  /// 「첫 쪽 표지 만들기」; null hides the row.
  final VoidCallback? onMakeCover;
  final void Function(String targetId)? onEditLabels;

  @override
  Widget build(BuildContext context) => _cardMenu<_NoteRow>(
    context,
    label: '문서 메뉴',
    onSelected: _choose,
    itemBuilder: _rows,
    title: title,
  );

  List<PopupMenuEntry<_NoteRow>> _rows(BuildContext context) {
    final act = onNoteAction != null;
    if (note.trashed) {
      return [
        if (act)
          _row(_NoteRow.restore, Icons.restore_from_trash_outlined, '복원'),
      ];
    }
    return [
      if (onTogglePin != null)
        _row(_NoteRow.pin, Icons.push_pin_outlined, pinned ? '고정 해제' : '고정'),
      if (act) _row(_NoteRow.rename, Icons.edit_outlined, '이름 바꾸기'),
      if (onChangeCover != null)
        _row(_NoteRow.cover, Icons.photo_library_outlined, '표지 변경'),
      if (onMakeCover != null)
        _row(
          _NoteRow.makeCover,
          Icons.image_outlined,
          '첫 쪽 표지 만들기',
          key: const ValueKey('library-note-cover-make'),
        ),
      if (onEditLabels != null)
        _row(_NoteRow.labels, Icons.label_outline, '라벨 추가'),
      if (act) _row(_NoteRow.move, Icons.drive_file_move_outline, '이동'),
      // A tap edits an Office·한글 original; the menu keeps its preview, the
      // PDF made from it for handwriting, and the Office screen's tools.
      if (act && note.documentKind == VaultDocumentKind.office) ...[
        _row(
          _NoteRow.preview,
          Icons.preview_outlined,
          '미리보기',
          key: const ValueKey('library-note-preview'),
        ),
        _row(
          _NoteRow.pdf,
          Icons.picture_as_pdf_outlined,
          'PDF로 바꾸기',
          key: const ValueKey('library-note-pdf'),
        ),
        _row(
          _NoteRow.tools,
          Icons.history,
          '기록·도구',
          key: const ValueKey('library-note-tools'),
        ),
      ],
      if (act) ...[
        _divider(context),
        _row(_NoteRow.trash, Icons.delete_outline, '휴지통으로 이동', color: _red),
      ],
      _divider(context),
      _row(_NoteRow.details, Icons.pending_outlined, '상세 정보', more: true),
    ];
  }

  void _choose(_NoteRow row) {
    void act(LibraryNoteAction action) => onNoteAction!(note, action);
    switch (row) {
      case _NoteRow.pin:
        onTogglePin!(note.id);
      case _NoteRow.cover:
        onChangeCover!(note.id);
      case _NoteRow.makeCover:
        onMakeCover!();
      case _NoteRow.labels:
        onEditLabels!(note.id);
      case _NoteRow.details:
        onDetails();
      case _NoteRow.rename:
        act(LibraryNoteAction.rename);
      case _NoteRow.move:
        act(LibraryNoteAction.move);
      case _NoteRow.preview:
        act(LibraryNoteAction.preview);
      case _NoteRow.pdf:
        act(LibraryNoteAction.pdf);
      case _NoteRow.tools:
        act(LibraryNoteAction.tools);
      case _NoteRow.trash:
        act(LibraryNoteAction.trash);
      case _NoteRow.restore:
        act(LibraryNoteAction.restore);
    }
  }
}

enum _FolderRow { pin, rename, cover, labels, move, trash, restore }

/// A folder card's ⌄: the folder actions plus 고정, 표지 변경 and 라벨. In the
/// grid it is the title line, as for documents.
class LibraryFolderMenu extends StatelessWidget {
  const new({
    super.key,
    required this.folder,
    required this.pinned,
    this.title,
    this.onFolderAction,
    this.onTogglePin,
    this.onChangeCover,
    this.onEditLabels,
  });

  final VaultFolder folder;
  final bool pinned;

  /// A grid card's title, shown as the button; null for a list row's ⌄.
  final String? title;
  final void Function(VaultFolder, LibraryFolderAction)? onFolderAction;
  final void Function(String targetId)? onTogglePin;
  final void Function(String targetId)? onChangeCover;
  final void Function(String targetId)? onEditLabels;

  /// Whether the menu has anything to offer.
  bool get hasRows => folder.trashed
      ? onFolderAction != null
      : onFolderAction != null ||
            onTogglePin != null ||
            onChangeCover != null ||
            onEditLabels != null;

  @override
  Widget build(BuildContext context) => _cardMenu<_FolderRow>(
    context,
    label: '폴더 메뉴',
    onSelected: _choose,
    itemBuilder: _rows,
    title: title,
  );

  List<PopupMenuEntry<_FolderRow>> _rows(BuildContext context) {
    final act = onFolderAction != null;
    if (folder.trashed) {
      return [
        if (act)
          _row(_FolderRow.restore, Icons.restore_from_trash_outlined, '복원'),
      ];
    }
    return [
      if (onTogglePin != null)
        _row(_FolderRow.pin, Icons.push_pin_outlined, pinned ? '고정 해제' : '고정'),
      if (act) _row(_FolderRow.rename, Icons.edit_outlined, '이름 바꾸기'),
      if (onChangeCover != null)
        _row(_FolderRow.cover, Icons.photo_library_outlined, '표지 변경'),
      if (onEditLabels != null)
        _row(_FolderRow.labels, Icons.label_outline, '라벨 추가'),
      if (act) ...[
        _row(_FolderRow.move, Icons.drive_file_move_outline, '이동'),
        _divider(context),
        _row(_FolderRow.trash, Icons.delete_outline, '휴지통으로 이동', color: _red),
      ],
    ];
  }

  void _choose(_FolderRow row) {
    void act(LibraryFolderAction action) => onFolderAction!(folder, action);
    switch (row) {
      case _FolderRow.pin:
        onTogglePin!(folder.id);
      case _FolderRow.cover:
        onChangeCover!(folder.id);
      case _FolderRow.labels:
        onEditLabels!(folder.id);
      case _FolderRow.rename:
        act(LibraryFolderAction.rename);
      case _FolderRow.move:
        act(LibraryFolderAction.move);
      case _FolderRow.trash:
        act(LibraryFolderAction.trash);
      case _FolderRow.restore:
        act(LibraryFolderAction.restore);
    }
  }
}

enum _ViewRow { grid, list, sort, labels }

/// The ⋯ at the end of the top bar (사진 1000319981): 격자형 and 목록형 side
/// by side, then 정렬 › and 라벨 색상 ›.
class LibraryViewMenu extends StatelessWidget {
  const new({
    super.key,
    required this.grid,
    required this.sort,
    required this.labels,
    required this.onGrid,
    required this.onSort,
    this.onEditLabels,
  });

  final bool grid;

  /// `default`, `title`, `changed` or `created`.
  final String sort;
  final List<LibraryLabel> labels;
  final ValueChanged<bool> onGrid;
  final ValueChanged<String> onSort;
  final void Function(String targetId)? onEditLabels;

  static const sorts = [
    ('title', '이름순'),
    ('changed', '고친 날'),
    ('created', '만든 날'),
    ('default', '기본 순서'),
  ];

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '보기',
    icon: const Icon(Icons.pending_outlined),
    iconSize: 22,
    style: libraryBarButtonStyle,
    onPressed: () => _open(context),
  );

  Future<void> _open(BuildContext context) async {
    final position = libraryMenuUnder(context);
    final choice = await showLibraryMenu<_ViewRow>(
      context,
      position: position,
      items: [
        _LayoutChoices(grid: grid),
        _divider(context),
        _row(
          _ViewRow.sort,
          Icons.sort,
          '정렬',
          key: const ValueKey('library-view-sort'),
          more: true,
        ),
        if (onEditLabels != null) ...[
          _divider(context),
          _row(
            _ViewRow.labels,
            Icons.label_outline,
            '라벨 색상',
            key: const ValueKey('library-view-labels'),
            more: true,
          ),
        ],
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case _ViewRow.grid:
        onGrid(true);
      case _ViewRow.list:
        onGrid(false);
      case _ViewRow.sort:
        final picked = await showLibraryMenu<String>(
          context,
          position: position,
          items: [
            for (final (value, label) in sorts)
              CheckedPopupMenuItem(
                key: ValueKey('library-sort-$value'),
                value: value,
                checked: value == sort,
                child: Text(label),
              ),
          ],
        );
        if (picked != null) onSort(picked);
      case _ViewRow.labels:
        final picked = await showLibraryMenu<String>(
          context,
          position: position,
          items: [
            for (final label in labels)
              PopupMenuItem(
                value: label.id,
                height: 48,
                child: Row(
                  children: [
                    _Dot(Color(label.color), size: 14),
                    const SizedBox(width: 14),
                    Expanded(child: Text(label.name)),
                  ],
                ),
              ),
            _row('', Icons.add, '라벨 관리'),
          ],
        );
        if (picked != null) onEditLabels!('');
      case null:
        break;
    }
  }
}

/// The two cells on top of the ⋯ menu.
class _LayoutChoices extends PopupMenuEntry<_ViewRow> {
  const new({required this.grid});

  final bool grid;

  @override
  double get height => 76;

  @override
  bool represents(_ViewRow? value) =>
      value == _ViewRow.grid || value == _ViewRow.list;

  @override
  State<_LayoutChoices> createState() => _LayoutChoicesState();
}

class _LayoutChoicesState extends State<_LayoutChoices> {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(_ViewRow value, IconData icon, String label, bool chosen) =>
        Expanded(
          child: InkWell(
            key: ValueKey('library-view-${value.name}'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => Navigator.pop(context, value),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: chosen ? scheme.primary : null),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: chosen ? scheme.primary : null,
                      fontWeight: chosen ? FontWeight.w600 : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          cell(_ViewRow.grid, Icons.apps, '격자형', widget.grid),
          cell(_ViewRow.list, Icons.view_list, '목록형', !widget.grid),
        ],
      ),
    );
  }
}

/// The small round buttons of the top bar (about 40 apart, as in Notein).
final libraryBarButtonStyle = IconButton.styleFrom(
  fixedSize: const Size(40, 40),
  minimumSize: const Size(40, 40),
  padding: EdgeInsets.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);

/// 상세 정보: kind, dates, pages and where the document is.
Future<void> showLibraryDetails(
  BuildContext context, {
  required VaultNote note,
  required DocumentFacts? facts,
  required String location,
}) {
  final created = facts?.created;
  final changed = facts?.changed;
  final pages = facts?.pages;
  final format = libraryFormatOf(facts?.format);
  Widget fact(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('library-details-dialog'),
      title: Text(note.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            fact('종류', libraryKindLabel(note.documentKind)),
            if (format != null)
              fact('원본', '${format.label} (${facts!.format})'),
            fact('만든 날', created == null ? '알 수 없음' : libraryDateTime(created)),
            fact('고친 날', changed == null ? '알 수 없음' : libraryDateTime(changed)),
            fact(
              '쪽 수',
              note.documentKind == VaultDocumentKind.infinite
                  ? '∞'
                  : pages == null
                  ? '알 수 없음'
                  : '$pages 페이지',
            ),
            fact('위치', location),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    ),
  );
}

class _Dot extends StatelessWidget {
  const new(this.color, {this.size = 18, this.ring = false});

  final Color color;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: ring
            ? Border.all(
                color: Theme.of(context).colorScheme.onSurface,
                width: 2,
              )
            : null,
      ),
    ),
  );
}

class _Swatches extends StatelessWidget {
  const new({required this.chosen, required this.onPick});

  final int chosen;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        for (final (index, color) in libraryPalette.indexed)
          InkResponse(
            key: ValueKey('library-label-color-$index'),
            radius: 18,
            onTap: () => onPick(color),
            child: _Dot(Color(color), size: 26, ring: color == chosen),
          ),
      ],
    ),
  );
}

/// The labels after a label dialog, and the ones checked for the document.
typedef LibraryLabelChoice = ({
  List<LibraryLabel> labels,
  Set<String> selected,
});

/// 라벨 추가 for one document ([selected] holds its labels), or, without
/// [selected], the label list alone (the ⋯ menu's 라벨 색상): check labels,
/// recolour them, add new ones, and rename or delete them from each label's
/// menu (deleting asks first). New, renamed or recoloured labels get a fresh
/// changedAt so they win when two devices' marks are merged; a deleted label
/// is missing from the returned list.
Future<LibraryLabelChoice?> showLibraryLabelsDialog(
  BuildContext context, {
  required List<LibraryLabel> labels,
  Set<String>? selected,
}) => showDialog<LibraryLabelChoice>(
  context: context,
  builder: (_) => _LabelsDialog(labels: labels, selected: selected),
);

class _LabelsDialog extends StatefulWidget {
  const new({required this.labels, required this.selected});

  final List<LibraryLabel> labels;
  final Set<String>? selected;

  @override
  State<_LabelsDialog> createState() => _LabelsDialogState();
}

class _LabelsDialogState extends State<_LabelsDialog> {
  late final _labels = [...widget.labels];
  late final _selected = {...?widget.selected};
  final _name = TextEditingController();
  String? _recolouring;
  var _adding = false;
  var _colour = libraryPalette.first;

  static int get _now => DateTime.now().microsecondsSinceEpoch;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _add() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final label = LibraryLabel(
      id: newId(),
      name: name,
      color: _colour,
      changedAt: _now,
    );
    setState(() {
      _labels.add(label);
      if (widget.selected != null) _selected.add(label.id);
      _adding = false;
      _name.clear();
    });
  }

  /// 이름 바꾸기 asks for the new name; 삭제 asks first, and the label leaves
  /// the list and the document's checks.
  Future<void> _labelMenu(LibraryLabel label, _LabelRow row) async {
    switch (row) {
      case _LabelRow.rename:
        final name = (await showDialog<String>(
          context: context,
          builder: (_) => _LabelNameDialog(name: label.name),
        ))?.trim();
        final at = _labels.indexWhere((other) => other.id == label.id);
        if (!mounted || at < 0 || name == null || name.isEmpty) return;
        if (name == _labels[at].name) return;
        setState(
          () => _labels[at] = LibraryLabel(
            id: label.id,
            name: name,
            color: _labels[at].color,
            changedAt: _now,
          ),
        );
      case _LabelRow.delete:
        final delete = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('‘${label.name}’ 라벨을 삭제할까요?'),
            content: const Text('이 라벨이 붙은 문서에서도 라벨이 빠집니다.'),
            actions: [
              TextButton(
                key: const ValueKey('library-label-delete-cancel'),
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              TextButton(
                key: const ValueKey('library-label-delete-ok'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('삭제', style: TextStyle(color: _red)),
              ),
            ],
          ),
        );
        if (!(delete ?? false) || !mounted) return;
        setState(() {
          _labels.removeWhere((other) => other.id == label.id);
          _selected.remove(label.id);
          if (_recolouring == label.id) _recolouring = null;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final choosing = widget.selected != null;
    final look = libraryMenuLook(context);
    return AlertDialog(
      key: const ValueKey('library-labels-dialog'),
      title: Text(choosing ? '라벨 추가' : '라벨 색상'),
      content: SizedBox(
        width: 320,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, label) in _labels.indexed) ...[
                Row(
                  children: [
                    InkResponse(
                      key: ValueKey('library-label-dot-${label.id}'),
                      radius: 18,
                      onTap: () => setState(() {
                        _adding = false;
                        _recolouring = _recolouring == label.id
                            ? null
                            : label.id;
                      }),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: _Dot(Color(label.color)),
                      ),
                    ),
                    Expanded(child: Text(label.name)),
                    if (choosing)
                      Checkbox(
                        key: ValueKey('library-label-check-${label.id}'),
                        value: _selected.contains(label.id),
                        onChanged: (on) => setState(() {
                          if (on ?? false) {
                            _selected.add(label.id);
                          } else {
                            _selected.remove(label.id);
                          }
                        }),
                      ),
                    PopupMenuButton<_LabelRow>(
                      key: ValueKey('library-label-menu-${label.id}'),
                      tooltip: '라벨 메뉴',
                      icon: const Icon(Icons.more_vert, size: 20),
                      shape: _menuShape,
                      color: look.color,
                      surfaceTintColor: look.tint,
                      shadowColor: look.shadow,
                      elevation: look.elevation,
                      onSelected: (row) => _labelMenu(label, row),
                      itemBuilder: (_) => [
                        _row(
                          _LabelRow.rename,
                          Icons.edit_outlined,
                          '이름 바꾸기',
                          key: ValueKey('library-label-rename-${label.id}'),
                        ),
                        _row(
                          _LabelRow.delete,
                          Icons.delete_outline,
                          '삭제',
                          key: ValueKey('library-label-delete-${label.id}'),
                          color: _red,
                        ),
                      ],
                    ),
                  ],
                ),
                if (_recolouring == label.id)
                  _Swatches(
                    chosen: label.color,
                    onPick: (colour) => setState(() {
                      _labels[index] = LibraryLabel(
                        id: label.id,
                        name: label.name,
                        color: colour,
                        changedAt: _now,
                      );
                      _recolouring = null;
                    }),
                  ),
              ],
              if (_adding) ...[
                TextField(
                  key: const ValueKey('library-label-name'),
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(hintText: '라벨 이름'),
                  onSubmitted: (_) => _add(),
                ),
                _Swatches(
                  chosen: _colour,
                  onPick: (colour) => setState(() => _colour = colour),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    key: const ValueKey('library-label-add'),
                    onPressed: _add,
                    child: const Text('추가'),
                  ),
                ),
              ] else
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('library-label-new'),
                    onPressed: () => setState(() {
                      _adding = true;
                      _recolouring = null;
                    }),
                    icon: const Icon(Icons.add),
                    label: const Text('새 라벨'),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        TextButton(
          key: const ValueKey('library-labels-save'),
          onPressed: () => Navigator.pop<LibraryLabelChoice>(context, (
            labels: _labels,
            selected: _selected,
          )),
          child: const Text('저장'),
        ),
      ],
    );
  }
}

enum _LabelRow { rename, delete }

/// 이름 바꾸기 of a label: its name, selected, to type over.
class _LabelNameDialog extends StatefulWidget {
  const new({required this.name});

  final String name;

  @override
  State<_LabelNameDialog> createState() => _LabelNameDialogState();
}

class _LabelNameDialogState extends State<_LabelNameDialog> {
  late final _text = TextEditingController(text: widget.name)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.name.length,
    );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(context, _text.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const ValueKey('library-label-rename-dialog'),
    title: const Text('라벨 이름 바꾸기'),
    content: SizedBox(
      width: 280,
      child: TextField(
        key: const ValueKey('library-label-rename-field'),
        controller: _text,
        autofocus: true,
        decoration: const InputDecoration(hintText: '라벨 이름'),
        onSubmitted: (_) => _done(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      TextButton(
        key: const ValueKey('library-label-rename-ok'),
        onPressed: _done,
        child: const Text('바꾸기'),
      ),
    ],
  );
}

/// 표지 변경: the first page (the usual cover), for an Office·한글 original
/// ([format] is its extension) its format's light cover with the format's
/// name, or one of eight colours. Returns null when cancelled; `(color:
/// null)` means the first page, [LibraryMarks.formatCover] the format cover.
Future<({int? color})?> showLibraryCoverDialog(
  BuildContext context, {
  int? current,
  String? format,
}) => showDialog<({int? color})>(
  context: context,
  builder: (context) => AlertDialog(
    key: const ValueKey('library-cover-dialog'),
    title: const Text('표지 변경'),
    content: SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            key: const ValueKey('library-cover-first'),
            leading: const Icon(Icons.description_outlined),
            title: const Text('첫 쪽'),
            selected: current == null,
            onTap: () => Navigator.pop<({int? color})>(context, (color: null)),
          ),
          if (libraryFormatOf(format) case final look?)
            ListTile(
              key: const ValueKey('library-cover-format'),
              leading: LibraryCover(
                size: const Size(28, 36),
                title: '',
                format: look,
                color: LibraryMarks.formatCover,
              ),
              title: const Text('형식 표지'),
              selected: current == LibraryMarks.formatCover,
              onTap: () => Navigator.pop<({int? color})>(context, (
                color: LibraryMarks.formatCover,
              )),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final (index, color) in libraryPalette.indexed)
                InkWell(
                  key: ValueKey('library-cover-color-$index'),
                  borderRadius: BorderRadius.circular(6),
                  onTap: () =>
                      Navigator.pop<({int? color})>(context, (color: color)),
                  child: SizedBox(
                    width: 34,
                    height: 46,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color(color),
                        borderRadius: BorderRadius.circular(6),
                        border: color == current
                            ? Border.all(
                                color: Theme.of(context).colorScheme.onSurface,
                                width: 2,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
    ],
  ),
);
