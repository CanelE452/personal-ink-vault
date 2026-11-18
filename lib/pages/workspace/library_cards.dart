import 'dart:math';

import 'package:flutter/material.dart';
import 'package:saber/data/vault/document_facts.dart';
import 'package:saber/data/vault/library_marks.dart';
import 'package:saber/data/vault/workspace_store.dart';

/// A document being imported, shown as a card at the front of its folder
/// (설계 4절, 사진 1000008251–53).
final class LibraryImportJobView {
  const new({required this.id, required this.title, this.progress, this.error});

  final String id;
  final String title;

  /// 0..1, or null while it is not known.
  final double? progress;

  /// Why the import failed; null while it runs.
  final String? error;
}

const libraryPptColor = Color(0xFFD24726);
const libraryWordColor = Color(0xFF2B579A);
const libraryHangulColor = Color(0xFF1E8BD8);
const libraryExcelColor = Color(0xFF217346);
const libraryPdfColor = Color(0xFFB4532A);
const _red = Color(0xFFE53935);
const _grey = Color(0xFF8A8A8A);

/// The mark an Office·한글 original carries (설계 3절). Excel cannot be
/// imported yet; its row waits for the day it can.
({String label, Color color})? libraryFormatOf(String? format) =>
    switch (format?.toLowerCase()) {
      'ppt' || 'pptx' => (label: 'PPT', color: libraryPptColor),
      'odp' => (label: 'ODP', color: libraryPptColor),
      'doc' || 'docx' => (label: 'Word', color: libraryWordColor),
      'odt' => (label: 'ODT', color: libraryWordColor),
      'hwp' || 'hwpx' => (label: '한글', color: libraryHangulColor),
      'xls' || 'xlsx' => (label: 'Excel', color: libraryExcelColor),
      'ods' => (label: 'ODS', color: libraryExcelColor),
      _ => null,
    };

/// Width / height of a document's cover (설계 1.3절): the measured first page
/// where there is one, otherwise the kind's usual shape.
double libraryCoverAspect(VaultDocumentKind kind, DocumentFacts? facts) {
  const page = .707;
  final measured = facts?.aspect;
  final aspect = switch (kind) {
    VaultDocumentKind.infinite => 1.0,
    VaultDocumentKind.markdown ||
    VaultDocumentKind.page ||
    VaultDocumentKind.database ||
    VaultDocumentKind.canvas => page,
    VaultDocumentKind.office =>
      measured ??
          (const {'ppt', 'pptx', 'odp'}.contains(facts?.format)
              ? 16 / 9
              : page),
    VaultDocumentKind.handwriting ||
    VaultDocumentKind.pdf ||
    VaultDocumentKind.image => measured ?? page,
  };
  return aspect.clamp(.25, 4.0);
}

/// The largest size of [aspect] that fits in [room].
Size libraryFit(double aspect, Size room) => room.width / room.height > aspect
    ? Size(room.height * aspect, room.height)
    : Size(room.width, room.width / aspect);

String _two(int value) => value.toString().padLeft(2, '0');

/// `yy/MM/dd`, as Notein's cards write dates.
String libraryDate(DateTime time) =>
    '${_two(time.year % 100)}/${_two(time.month)}/${_two(time.day)}';

String libraryDateTime(DateTime time) =>
    '${libraryDate(time)} ${_two(time.hour)}:${_two(time.minute)}';

/// The grey line under a card's title: `26/11/17 · 3 페이지`.
String libraryNoteSubtitle(VaultNote note, DocumentFacts? facts) {
  final changed = facts?.changed;
  if (changed == null) return libraryKindLabel(note.documentKind);
  final date = libraryDate(changed);
  if (note.documentKind == VaultDocumentKind.infinite) return '$date · ∞';
  final pages = facts?.pages;
  return pages == null ? date : '$date · $pages 페이지';
}

String libraryKindLabel(VaultDocumentKind kind) => switch (kind) {
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

IconData libraryKindIcon(VaultDocumentKind kind) => switch (kind) {
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

/// The ㄱ band along the top-left corner of an Office·한글 cover and its
/// name tag (사용자 사진 1000319977의 빨간 표시 자리). It fills the box its
/// parent gives it: 40% of the cover's width and 30% of its height.
class LibraryFormatMark extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.color,
    this.tag = true,
  });

  final String label;
  final Color color;

  /// The small tag with the format's name; too big for a list row's cover.
  final bool tag;

  @override
  Widget build(BuildContext context) {
    final paint = color.withValues(alpha: .85);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: CustomPaint(painter: _CornerBand(paint))),
        if (tag)
          Positioned(
            left: 5,
            top: 5,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: paint,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CornerBand extends CustomPainter {
  const new(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const inset = 1.5;
    const radius = 5.0;
    final path = Path()
      ..moveTo(inset, size.height)
      ..lineTo(inset, inset + radius)
      ..arcToPoint(
        const Offset(inset + radius, inset),
        radius: const Radius.circular(radius),
      )
      ..lineTo(size.width, inset);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_CornerBand oldDelegate) => oldDelegate.color != color;
}

/// A cover drawn at its document's shape: white with a soft shadow and
/// rounded corners, showing the cover picture (a document's first page), a
/// colour cover (the title's first letter), a light format colour with its
/// name (an Office·한글 original's 형식 표지, or its cover while it has no
/// picture), or the kind's icon.
class LibraryCover extends StatelessWidget {
  const new({
    super.key,
    required this.size,
    required this.title,
    this.image,
    this.color,
    this.format,
    this.icon,
    this.overlays = const [],
  });

  final Size size;
  final String title;
  final ImageProvider? image;

  /// What was chosen in 표지 변경: an ARGB colour cover, or
  /// [LibraryMarks.formatCover] for the [format]'s cover. Either wins over
  /// the picture; the format cover is ignored without a [format].
  final int? color;
  final ({String label, Color color})? format;
  final IconData? icon;

  /// Positioned children over the cover: the heart, the pin, the format mark.
  final List<Widget> overlays;

  @override
  Widget build(BuildContext context) {
    final formatChosen = color == LibraryMarks.formatCover;
    final letter = color != null && !formatChosen;
    final picture = formatChosen && format != null ? null : image;
    final fallback = switch (format) {
      final format? => ColoredBox(
        color: format.color.withValues(alpha: .12),
        child: Center(
          child: Text(
            format.label,
            maxLines: 1,
            style: TextStyle(
              color: format.color,
              fontSize: max(10, size.width * .2),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
      null when icon != null => Center(
        child: Icon(icon, size: max(14, size.width * .3), color: _grey),
      ),
      null => const SizedBox.shrink(),
    };
    final Widget content;
    if (letter) {
      final first = title.trim().characters.firstOrNull ?? '';
      content = Center(
        child: Text(
          first.toUpperCase(),
          style: TextStyle(
            color: Colors.white,
            fontSize: max(10, size.width * .45),
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    } else if (picture != null) {
      content = Image(
        image: picture,
        fit: BoxFit.cover,
        alignment: Alignment.topCenter,
        errorBuilder: (_, _, _) => fallback,
      );
    } else {
      content = fallback;
    }
    return SizedBox.fromSize(
      size: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: letter ? Color(color!) : Colors.white,
          borderRadius: BorderRadius.circular(6),
          boxShadow: const [
            BoxShadow(
              color: Color(0x24000000),
              blurRadius: 4,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Stack(fit: StackFit.expand, children: [content, ...overlays]),
        ),
      ),
    );
  }
}

/// A small mark (a heart, a ×) with Material's 48×48 touch area around it
/// and one button node for screen readers. [alignment] places the mark in
/// the area.
class LibraryTouchTarget extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
    this.tooltip,
    this.toggled,
    this.alignment = Alignment.center,
  });

  final String label;
  final VoidCallback? onTap;
  final Widget child;
  final String? tooltip;
  final bool? toggled;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    toggled: toggled,
    label: label,
    child: Tooltip(
      message: tooltip ?? label,
      child: SizedBox(
        width: 48,
        height: 48,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Align(alignment: alignment, child: child),
        ),
      ),
    ),
  );
}

/// A grid card's title line, centred under the cover as StarNote draws
/// 「내 연구 ⌄」: the title in up to two lines and, when the card has a menu
/// ([chevron]), a ⌄ right after the text on its last line. The ⌄ is not part
/// of the text, so a title cut short keeps it. The line is as wide as the
/// card and at least 32 tall: all of it is the menu's tap target. Screen
/// readers hear the title from the card ([LibraryCardCell.titleLine]).
class LibraryCardTitle extends StatelessWidget {
  const new(this.title, {super.key, this.chevron = false});

  final String title;
  final bool chevron;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ConstrainedBox(
      constraints: const BoxConstraints(
        minWidth: double.infinity,
        minHeight: 32,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          // The ⌄ sits on the last line, the title just above the date.
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                textWidthBasis: TextWidthBasis.longestLine,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (chevron) ...[
              const SizedBox(width: 2),
              const Icon(Icons.expand_more, size: 18, color: _grey),
            ],
          ],
        ),
      ),
    ),
  );
}

/// One grid cell: a cover box 80% of the cell wide and 1.33 times as tall
/// with the cover centred in it, the title and the grey line below. A note's
/// or folder's ⌄ follows its title ([LibraryCardTitle]); while selecting, a
/// check box sits at the box's bottom-right corner, at the same height
/// whatever the cover's shape (사진 1000319967).
class LibraryCardCell extends StatelessWidget {
  const new({
    super.key,
    required this.aspect,
    required this.cover,
    required this.title,
    this.titleLines = 1,
    this.titleLine,
    this.subtitle,
    this.below = const [],
    this.corner,
    this.coverCorner,
    this.onTap,
    this.stacked = false,
  });

  final double aspect;
  final Widget Function(Size size) cover;
  final String title;
  final int titleLines;

  /// The line under the cover in place of the plain [title]: a note's or
  /// folder's [LibraryCardTitle], inside its menu's button when it has one.
  /// That line keeps its text from screen readers; the card says [title].
  final Widget? titleLine;
  final Widget? subtitle;
  final List<Widget> below;

  /// The check box at the cover box's bottom-right corner while selecting.
  final Widget? corner;

  /// A 48×48 control whose top-right corner is the cover's (the heart, an
  /// import's ×). It lies over the cover but outside its clip, so the whole
  /// area takes touches however small the cover is.
  final Widget? coverCorner;
  final VoidCallback? onTap;

  /// A folder: two grey sheets peek out above the cover.
  final bool stacked;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final boxWidth = constraints.maxWidth * .8;
      final card = Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Flexible(
                child: SizedBox(
                  width: boxWidth,
                  height: boxWidth * 1.33,
                  child: LayoutBuilder(builder: _box),
                ),
              ),
              const SizedBox(height: 6),
              titleLine ??
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Text(
                      title,
                      maxLines: titleLines,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
              const SizedBox(height: 2),
              ?subtitle,
              ...below,
            ],
          ),
        ),
      );
      return titleLine == null ? card : Semantics(label: title, child: card);
    },
  );

  Widget _box(BuildContext context, BoxConstraints box) {
    const sheets = 12.0;
    final top = stacked ? sheets : 0.0;
    final room = Size(box.maxWidth, max(1, box.maxHeight - top));
    final size = libraryFit(aspect, room);
    final left = (box.maxWidth - size.width) / 2;
    final coverTop = top + (room.height - size.height) / 2;
    Widget sheet(Color color) => DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (stacked) ...[
          Positioned(
            left: left + size.width * .16,
            top: coverTop - sheets,
            width: size.width * .68,
            height: 20,
            child: sheet(const Color(0xFFEDEDED)),
          ),
          Positioned(
            left: left + size.width * .08,
            top: coverTop - sheets / 2,
            width: size.width * .84,
            height: 20,
            child: sheet(const Color(0xFFE0E0E0)),
          ),
        ],
        Positioned(
          left: left,
          top: coverTop,
          width: size.width,
          height: size.height,
          child: cover(size),
        ),
        if (corner case final corner?)
          Positioned(right: 0, bottom: 0, child: corner),
        if (coverCorner case final coverCorner?)
          Positioned(
            left: left + size.width - 48,
            top: coverTop,
            width: 48,
            height: 48,
            child: coverCorner,
          ),
      ],
    );
  }
}

/// One row of the list layout: a small cover, the title and its line.
class LibraryListRow extends StatelessWidget {
  const new({
    super.key,
    required this.aspect,
    required this.cover,
    required this.title,
    this.subtitle,
    this.trailing = const [],
    this.onTap,
  });

  final double aspect;
  final Widget Function(Size size) cover;
  final String title;
  final Widget? subtitle;
  final List<Widget> trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final size = libraryFit(aspect, const Size(40, 52));
    return ListTile(
      leading: SizedBox(
        width: 40,
        height: 52,
        child: Center(child: cover(size)),
      ),
      title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: subtitle,
      trailing: trailing.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: trailing),
      onTap: onTap,
    );
  }
}

/// A document still on its way in: an empty white cover with a download
/// sign, a red × to cancel, and the progress under its two-line title.
class LibraryImportCard extends StatelessWidget {
  const new({super.key, required this.job, this.onCancel, this.list = false});

  final LibraryImportJobView job;
  final VoidCallback? onCancel;

  /// A row of the list layout instead of a grid cell.
  final bool list;

  @override
  Widget build(BuildContext context) {
    final failed = job.error != null;
    final onTap = failed ? () => _explain(context) : null;
    Widget cover(Size size) =>
        LibraryCover(size: size, title: job.title, icon: Icons.download);
    if (list) {
      return LibraryListRow(
        aspect: .707,
        cover: cover,
        title: job.title,
        subtitle: _progress(context, align: CrossAxisAlignment.start),
        trailing: [_cancel(Alignment.center)],
        onTap: onTap,
      );
    }
    return LibraryCardCell(
      aspect: .707,
      cover: cover,
      title: job.title,
      titleLines: 2,
      subtitle: _progress(context, align: CrossAxisAlignment.center),
      coverCorner: _cancel(Alignment.topRight),
      onTap: onTap,
    );
  }

  /// The red × in a 48×48 touch area; on a failed import it closes the card.
  Widget _cancel(Alignment alignment) => LibraryTouchTarget(
    key: ValueKey('library-import-cancel-${job.id}'),
    label: job.error == null ? '가져오기 취소' : '닫기',
    alignment: alignment,
    onTap: onCancel,
    child: Padding(
      padding: EdgeInsets.all(alignment == Alignment.topRight ? 4 : 0),
      child: const SizedBox(
        width: 22,
        height: 22,
        child: DecoratedBox(
          decoration: BoxDecoration(color: _red, shape: BoxShape.circle),
          child: Icon(Icons.close, size: 15, color: Colors.white),
        ),
      ),
    ),
  );

  Widget _progress(BuildContext context, {required CrossAxisAlignment align}) {
    const small = TextStyle(fontSize: 12, color: _grey);
    if (job.error != null) {
      return const Text(
        '가져오지 못했습니다',
        style: TextStyle(fontSize: 12, color: _red),
      );
    }
    final progress = job.progress;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: align,
        children: [
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: progress,
            minHeight: 3,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(height: 4),
          Text(
            progress == null ? '가져오는 중' : '${(progress * 100).round()}%',
            style: small,
          ),
        ],
      ),
    );
  }

  Future<void> _explain(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(job.title),
      content: Text(job.error!),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    ),
  );
}
