import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:saber/components/canvas/canvas_background_preview.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/pages/workspace/library_cards.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/library_menus.dart';
import 'package:sbn/canvas_background_pattern.dart';

const _blue = Color(0xFF3D5AFE);
const _paleBlue = Color(0xFFD9E3FF);
const _navy = Color(0xFF1B2F6E);

/// What the 「새 노트」 dialog's list makes, in its order (설계 2.3절).
const _noteKinds = [
  (LibraryCreateAction.infinite, Icons.all_out, '무한 노트'),
  (LibraryCreateAction.quickNote, Icons.bolt_outlined, '빠른 메모'),
  (LibraryCreateAction.markdown, Icons.article_outlined, 'Markdown'),
  (LibraryCreateAction.canvas, Icons.dashboard_customize_outlined, '카드 캔버스'),
  (LibraryCreateAction.page, Icons.view_agenda_outlined, '블록 페이지'),
  (LibraryCreateAction.database, Icons.table_chart_outlined, '데이터베이스'),
  (LibraryCreateAction.dailyNote, Icons.today_outlined, '오늘 노트'),
  (LibraryCreateAction.datedNote, Icons.calendar_month_outlined, '날짜별 노트'),
  (
    LibraryCreateAction.dailyNoteTemplate,
    Icons.edit_calendar_outlined,
    '날짜별 노트 템플릿',
  ),
  (LibraryCreateAction.wordDocument, Icons.description_outlined, '새 Word 문서'),
  (LibraryCreateAction.presentation, Icons.slideshow_outlined, '새 프레젠테이션'),
  (LibraryCreateAction.hwpx, Icons.article_outlined, '새 한글 문서'),
];

/// The imports in the + menu, after 새 노트… and 새 폴더 (설계 2.2절).
const _imports = [
  (
    LibraryCreateAction.pdf,
    Icons.picture_as_pdf_outlined,
    'PDF 가져오기',
    libraryPdfColor,
  ),
  (
    LibraryCreateAction.importPpt,
    Icons.slideshow_outlined,
    'PPT 가져오기',
    libraryPptColor,
  ),
  (
    LibraryCreateAction.importWord,
    Icons.description_outlined,
    'Word 가져오기',
    libraryWordColor,
  ),
  (
    LibraryCreateAction.importHwp,
    Icons.article_outlined,
    '한글 가져오기',
    libraryHangulColor,
  ),
  (LibraryCreateAction.image, Icons.image_outlined, '이미지 가져오기', null),
  (LibraryCreateAction.camera, Icons.photo_camera_outlined, '사진 촬영', null),
];

/// 「다른 앱에서 가져오기 ›」.
const _otherApps = [
  (
    LibraryCreateAction.obsidianVault,
    'obsidian',
    Icons.folder_open_outlined,
    'Obsidian 보관함',
  ),
  (
    LibraryCreateAction.notionZip,
    'notion',
    Icons.folder_zip_outlined,
    'Notion ZIP',
  ),
  (
    LibraryCreateAction.starnote,
    'starnote',
    Icons.auto_stories_outlined,
    'StarNote',
  ),
];

enum _AddRow { newNote, otherApps }

bool _makesPageNotes(Set<LibraryCreateAction> available) =>
    available.contains(LibraryCreateAction.handwriting) ||
    available.contains(LibraryCreateAction.pageNoteWithPattern);

/// Notein's two round buttons at the bottom right (사진 1000319963): a small
/// pale pencil that makes a page note at once, and the big blue + with the
/// add menu.
class LibraryAddButtons extends StatefulWidget {
  const new({super.key, required this.available, required this.onCreate});

  final Set<LibraryCreateAction> available;
  final ValueChanged<LibraryCreateAction> onCreate;

  @override
  State<LibraryAddButtons> createState() => _LibraryAddButtonsState();
}

class _LibraryAddButtonsState extends State<LibraryAddButtons> {
  /// A second tap right after the first (a double tap) makes no second note.
  Timer? _pencilRest;

  @override
  void dispose() {
    _pencilRest?.cancel();
    super.dispose();
  }

  void _pencil() {
    if (_pencilRest?.isActive ?? false) return;
    _pencilRest = Timer(const Duration(milliseconds: 600), () {});
    widget.onCreate(LibraryCreateAction.handwriting);
  }

  List<PopupMenuEntry<Object>> _menu() {
    final available = widget.available;
    final groups = [
      <PopupMenuEntry<Object>>[
        if (_makesPageNotes(available) ||
            _noteKinds.any((kind) => available.contains(kind.$1)))
          _row(
            _AddRow.newNote,
            'library-add-note',
            Icons.note_add_outlined,
            '새 노트…',
          ),
        if (available.contains(LibraryCreateAction.folder))
          _row(
            LibraryCreateAction.folder,
            'library-add-folder',
            Icons.create_new_folder_outlined,
            '새 폴더',
          ),
      ],
      <PopupMenuEntry<Object>>[
        for (final (action, icon, label, color) in _imports)
          if (available.contains(action))
            _row(
              action,
              'library-add-${action.name}',
              icon,
              label,
              color: color,
            ),
      ],
      <PopupMenuEntry<Object>>[
        if (_otherApps.any((app) => available.contains(app.$1)))
          _row(
            _AddRow.otherApps,
            'library-add-other',
            Icons.apps_outlined,
            '다른 앱에서 가져오기',
            more: true,
          ),
      ],
    ].where((group) => group.isNotEmpty).toList();
    return [
      for (final (index, group) in groups.indexed) ...[
        if (index > 0) PopupMenuDivider(color: libraryLine(context)),
        ...group,
      ],
    ];
  }

  Future<void> _open(BuildContext anchor) async {
    final choice = await _showAbove(anchor, _menu());
    if (!mounted) return;
    switch (choice) {
      case final LibraryCreateAction action:
        widget.onCreate(action);
      case _AddRow.newNote:
        final action = await showLibraryNewNoteDialog(
          context,
          available: widget.available,
        );
        if (action != null && mounted) widget.onCreate(action);
      case _AddRow.otherApps:
        if (!anchor.mounted) return;
        final app = await _showAbove(anchor, [
          for (final (action, name, icon, label) in _otherApps)
            if (widget.available.contains(action))
              _row(action, 'library-import-$name', icon, label),
        ]);
        if (app is LibraryCreateAction && mounted) widget.onCreate(app);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _menu();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.available.contains(LibraryCreateAction.handwriting)) ...[
          _round(
            key: const ValueKey('library-new-note'),
            label: '새 노트',
            size: 40,
            color: _paleBlue,
            elevation: 3,
            onTap: _pencil,
            child: const Icon(Icons.edit, size: 20, color: _navy),
          ),
          const SizedBox(height: 12),
        ],
        if (rows.isNotEmpty)
          Builder(
            builder: (anchor) => _round(
              key: const ValueKey('library-create-button'),
              label: '추가',
              size: 56,
              color: _blue,
              elevation: 4,
              onTap: () => unawaited(_open(anchor)),
              child: const Icon(Icons.add, size: 28, color: Colors.white),
            ),
          ),
      ],
    );
  }

  /// A round button of [size] inside a touch area of at least 48×48: a
  /// touch on the ring around a small button still presses it, and screen
  /// readers see one button named [label].
  static Widget _round({
    required Key key,
    required String label,
    required double size,
    required Color color,
    required double elevation,
    required VoidCallback onTap,
    required Widget child,
  }) {
    final area = max(size, 48.0);
    return Semantics(
      container: true,
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: SizedBox(
          key: key,
          width: area,
          height: area,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: onTap,
            child: Center(
              child: SizedBox(
                width: size,
                height: size,
                child: Material(
                  color: color,
                  shape: const CircleBorder(),
                  elevation: elevation,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onTap,
                    child: Center(child: child),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

PopupMenuItem<Object> _row(
  Object value,
  String key,
  IconData icon,
  String label, {
  Color? color,
  bool more = false,
}) => PopupMenuItem<Object>(
  key: ValueKey(key),
  value: value,
  height: 48,
  child: Row(
    children: [
      Icon(icon, size: 22, color: color),
      const SizedBox(width: 14),
      Expanded(child: Text(label)),
      if (more) const Icon(Icons.chevron_right, size: 20),
    ],
  ),
);

/// Opens [items] as a menu standing on top of [anchor], right edges in line
/// (사진 1000319973). A menu taller than the room scrolls inside.
Future<Object?> _showAbove(
  BuildContext anchor,
  List<PopupMenuEntry<Object>> items,
) {
  final box = anchor.findRenderObject()! as RenderBox;
  final overlay =
      Navigator.of(anchor).overlay!.context.findRenderObject()! as RenderBox;
  final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  // PopupMenuItem/Divider heights plus the menu's 8 + 8 padding.
  final height = items.fold(16.0, (total, item) => total + item.height);
  final top = max(8.0, rect.top - 8 - height);
  return showLibraryMenu<Object>(
    anchor,
    position: RelativeRect.fromLTRB(
      rect.left,
      top,
      overlay.size.width - rect.right,
      max(0, overlay.size.height - top - height),
    ),
    items: items,
  );
}

/// The 「새 노트」 dialog (Notein's 「페이지 추가」, 사진 1000319987): the page
/// patterns for a page note above a list of the other kinds. 만들기 keeps the
/// chosen pattern for the next note too (the pencil uses it).
Future<LibraryCreateAction?> showLibraryNewNoteDialog(
  BuildContext context, {
  required Set<LibraryCreateAction> available,
}) => showDialog<LibraryCreateAction>(
  context: context,
  builder: (_) => _NewNoteDialog(available: available),
);

class _NewNoteDialog extends StatefulWidget {
  const new({required this.available});

  final Set<LibraryCreateAction> available;

  @override
  State<_NewNoteDialog> createState() => _NewNoteDialogState();
}

class _NewNoteDialogState extends State<_NewNoteDialog> {
  late var _pattern = stows.lastBackgroundPattern.value;

  static const _patterns = [
    (CanvasBackgroundPattern.lined, '선'),
    (CanvasBackgroundPattern.none, '공백'),
    (CanvasBackgroundPattern.grid, '정사각형'),
    (CanvasBackgroundPattern.cornell, '코넬'),
    (CanvasBackgroundPattern.dots, '점'),
    (CanvasBackgroundPattern.collegeLtr, '대학 노트'),
  ];

  void _create() {
    stows.lastBackgroundPattern.value = _pattern;
    Navigator.pop(context, LibraryCreateAction.pageNoteWithPattern);
  }

  @override
  Widget build(BuildContext context) {
    final pages = _makesPageNotes(widget.available);
    final kinds = [
      for (final kind in _noteKinds)
        if (widget.available.contains(kind.$1)) kind,
    ];
    final scheme = Theme.of(context).colorScheme;
    final light = Theme.of(context).brightness == Brightness.light;
    return Dialog(
      key: const ValueKey('library-new-note-dialog'),
      insetPadding: const EdgeInsets.all(16),
      // Notein's 「페이지 추가」 sheet: light grey, the kinds in a white group.
      backgroundColor: light ? const Color(0xFFF2F2F7) : null,
      surfaceTintColor: light ? Colors.transparent : null,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 540),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Row(
                children: [
                  FilledButton(
                    key: const ValueKey('library-new-note-cancel'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _paleBlue,
                      foregroundColor: _navy,
                      shape: const StadiumBorder(),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('취소'),
                  ),
                  const Expanded(
                    child: Text(
                      '새 노트',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  FilledButton(
                    key: const ValueKey('library-new-note-create'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _blue,
                      foregroundColor: Colors.white,
                      shape: const StadiumBorder(),
                    ),
                    onPressed: pages ? _create : null,
                    child: const Text(
                      '만들기',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (pages)
                      // The chosen pattern's border is Notein's blue.
                      Theme(
                        data: Theme.of(context).copyWith(
                          colorScheme: scheme.copyWith(primary: _blue),
                        ),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          // Six on one row on a tablet, three and three on
                          // a phone.
                          spacing: 10,
                          runSpacing: 12,
                          children: [
                            for (final (pattern, label) in _patterns)
                              _patternCard(pattern, label),
                          ],
                        ),
                      ),
                    if (pages && kinds.isNotEmpty) const SizedBox(height: 20),
                    if (kinds.isNotEmpty)
                      Material(
                        key: const ValueKey('library-new-kinds'),
                        color: light
                            ? Colors.white
                            : scheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(16),
                        clipBehavior: Clip.antiAlias,
                        child: Column(
                          children: [
                            for (final (index, (action, icon, label))
                                in kinds.indexed) ...[
                              if (index > 0)
                                Divider(
                                  height: 1,
                                  color: light ? const Color(0xFFE5E5EA) : null,
                                ),
                              ListTile(
                                key: ValueKey('library-new-${action.name}'),
                                minTileHeight: 52,
                                leading: Icon(icon),
                                title: Text(label),
                                trailing: const Icon(
                                  Icons.chevron_right,
                                  color: Color(0xFFAEAEB2),
                                ),
                                onTap: () => Navigator.pop(context, action),
                              ),
                            ],
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Keyed by the pattern's Dart name: the enum's own `name` field is its
  /// file name, which is empty for none.
  Widget _patternCard(CanvasBackgroundPattern pattern, String label) => InkWell(
    key: ValueKey('library-pattern-${EnumName(pattern).name}'),
    borderRadius: BorderRadius.circular(8),
    onTap: () => setState(() => _pattern = pattern),
    child: Padding(
      padding: const EdgeInsets.all(2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 70,
            height: 98,
            child: FittedBox(
              child: CanvasBackgroundPreview(
                selected: _pattern == pattern,
                invert: false,
                backgroundColor: null,
                backgroundPattern: pattern,
                backgroundImage: null,
                pageSize: EditorPage.defaultSize,
                lineHeight: stows.lastLineHeight.value,
                lineThickness: stows.lastLineThickness.value,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 13)),
        ],
      ),
    ),
  );
}
