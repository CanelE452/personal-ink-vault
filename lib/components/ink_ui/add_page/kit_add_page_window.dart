import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:sbn/canvas_background_pattern.dart';

/// Where 노트 추가 puts a page: before or after the page on screen, or at
/// the end of the note.
enum KitAddPagePlace {
  before,
  after,
  end;

  String get label => switch (this) {
    before => '이 쪽 앞',
    after => '이 쪽 뒤',
    end => '맨 끝',
  };
}

/// A pattern 노트 추가 puts a page in: its card's name and the key part
/// of its card (the preview's sample class).
typedef KitAddPagePaper = ({
  CanvasBackgroundPattern pattern,
  String name,
  String key,
});

/// The window's patterns (`PAPER`), in its order.
const kitAddPagePapers = <KitAddPagePaper>[
  (pattern: CanvasBackgroundPattern.none, name: '빈 종이', key: 'blank'),
  (pattern: CanvasBackgroundPattern.lined, name: '줄', key: 'lined'),
  (pattern: CanvasBackgroundPattern.grid, name: '모눈', key: 'grid'),
  (pattern: CanvasBackgroundPattern.dots, name: '점', key: 'dot'),
];

/// The window's paper of [pattern], if it has one.
KitAddPagePaper? kitAddPagePaperOf(CanvasBackgroundPattern pattern) {
  for (final paper in kitAddPagePapers) {
    if (paper.pattern == pattern) return paper;
  }
  return null;
}

/// What the window was closed with: a page in a pattern, or a document or
/// pictures to bring in.
sealed class KitAddPageChoice {
  const new();
}

final class KitAddPageInPattern extends KitAddPageChoice {
  const new(this.pattern);

  final CanvasBackgroundPattern pattern;
}

final class KitAddPageImport extends KitAddPageChoice {
  const new({required this.document});

  /// A PDF (「문서 가져오기」); else pictures (「이미지 가져오기」).
  final bool document;
}

/// The 노트 추가 window's inside (12th draft `addHtml`): 「넣을 자리」 이 쪽
/// 앞 · 이 쪽 뒤 · 맨 끝, 「최근 양식」 ([recent], when there are any), 「양식」
/// 빈 종이 · 줄 · 모눈 · 점 and 「가져오기」 문서 · 이미지. A place pressed is
/// chosen at once ([onPlace]); a card or an import closes the window (the
/// popover's route) with its [KitAddPageChoice]. Without [document] the
/// document row is dimmed and takes no press.
class KitAddPageWindow extends StatefulWidget {
  const new({
    super.key,
    required this.place,
    required this.recent,
    required this.onPlace,
    this.document = true,
  });

  final KitAddPagePlace place;
  final List<KitAddPagePaper> recent;
  final ValueChanged<KitAddPagePlace> onPlace;
  final bool document;

  @override
  State<KitAddPageWindow> createState() => _KitAddPageWindowState();
}

class _KitAddPageWindowState extends State<KitAddPageWindow> {
  late var _place = widget.place;

  void _close(KitAddPageChoice choice) => Navigator.of(context).pop(choice);

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const ValueKey('kit-add-page-window'),
    width: KitTokens.addPagePanelWidth,
    child: Padding(
      padding: const EdgeInsets.only(bottom: KitTokens.addPagePadBottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: KitTokens.addPageTitlePad,
            child: KitText(
              '노트 추가',
              maxLines: 1,
              style: TextStyle(
                fontSize: KitTokens.toolWindowTitleSize,
                height: KitTokens.toolWindowTitleHeight,
                fontWeight: FontWeight.w600,
                color: KitTokens.menuInk,
                letterSpacing: 0,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          const _GroupTitle('넣을 자리'),
          _Places(
            place: _place,
            onPlace: (place) {
              setState(() => _place = place);
              widget.onPlace(place);
            },
          ),
          if (widget.recent.isNotEmpty) ...[
            const _GroupTitle('최근 양식'),
            _Cards(
              papers: widget.recent,
              keyPart: 'recent',
              onPaper: (paper) => _close(KitAddPageInPattern(paper.pattern)),
            ),
          ],
          const _GroupTitle('양식'),
          _Cards(
            papers: kitAddPagePapers,
            keyPart: 'card',
            onPaper: (paper) => _close(KitAddPageInPattern(paper.pattern)),
          ),
          const _GroupTitle('가져오기'),
          const _Line(),
          _ImportRow(
            key: const ValueKey('add-page-import-document'),
            icon: KitIconName.doc,
            label: '문서 가져오기',
            kind: 'PDF',
            onTap: widget.document
                ? () => _close(const KitAddPageImport(document: true))
                : null,
          ),
          const _Line(),
          _ImportRow(
            key: const ValueKey('add-page-import-image'),
            icon: KitIconName.image,
            label: '이미지 가져오기',
            kind: '사진',
            height: KitTokens.addPageRowUnderLine,
            onTap: () => _close(const KitAddPageImport(document: false)),
          ),
        ],
      ),
    ),
  );
}

/// A group's title (`.gt`).
class _GroupTitle extends StatelessWidget {
  const new(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: KitTokens.addPageGroupPad,
    child: KitText(
      text,
      maxLines: 1,
      style: const TextStyle(
        fontSize: KitTokens.toolWindowGroupSize,
        height: KitTokens.addPageGroupLine,
        fontWeight: FontWeight.w600,
        color: KitTokens.menuSub,
        letterSpacing: 0,
        decoration: TextDecoration.none,
      ),
    ),
  );
}

/// 「넣을 자리」 (`.r1seg`): three buttons, one of them chosen, read out as
/// radio buttons.
class _Places extends StatelessWidget {
  const new({required this.place, required this.onPlace});

  final KitAddPagePlace place;
  final ValueChanged<KitAddPagePlace> onPlace;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: KitTokens.addPageSegmentMargin,
    ),
    child: Semantics(
      label: '넣을 자리',
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: KitTokens.addPageSegmentBg,
          borderRadius: BorderRadius.circular(KitTokens.addPageSegmentRadius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(KitTokens.addPageSegmentPad),
          child: Row(
            children: [
              for (final each in KitAddPagePlace.values)
                Expanded(child: _place(each)),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _place(KitAddPagePlace each) {
    final on = each == place;
    final shape = BorderRadius.circular(KitTokens.addPageSegmentButtonRadius);
    return Semantics(
      key: ValueKey('add-page-place-${each.name}'),
      container: true,
      inMutuallyExclusiveGroup: true,
      checked: on,
      label: each.label,
      onTap: () => onPlace(each),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onPlace(each),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: on ? KitTokens.addPageSegmentOnBg : null,
            borderRadius: shape,
            boxShadow: on ? KitTokens.addPageSegmentShadow : null,
          ),
          child: SizedBox(
            height: KitTokens.addPageSegmentHeight,
            child: Center(
              child: KitText(
                each.label,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: KitTokens.addPageSegmentSize,
                  height: KitTokens.lineHeightOne,
                  fontWeight: FontWeight.w600,
                  color: on ? KitTokens.menuInk : KitTokens.menuSub,
                  letterSpacing: 0,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A row of pattern cards (`.r1cards`): four columns; [papers] from the
/// first. Each card's key is `add-page-[keyPart]-[paper key]`.
class _Cards extends StatelessWidget {
  const new({
    required this.papers,
    required this.keyPart,
    required this.onPaper,
  });

  final List<KitAddPagePaper> papers;
  final String keyPart;
  final ValueChanged<KitAddPagePaper> onPaper;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: KitTokens.addPageCardsPadH),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: KitTokens.addPageCardsGap,
      children: [
        for (var i = 0; i < KitTokens.addPageCardsColumns; i++)
          Expanded(
            child: i < papers.length
                ? _Card(
                    key: ValueKey('add-page-$keyPart-${papers[i].key}'),
                    paper: papers[i],
                    onTap: () => onPaper(papers[i]),
                  )
                : const SizedBox.shrink(),
          ),
      ],
    ),
  );
}

/// A pattern card (`.r1card`): the sample over its name; pressed, white.
class _Card extends StatelessWidget {
  const new({super.key, required this.paper, required this.onTap});

  final KitAddPagePaper paper;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(KitTokens.addPageCardRadius);
    return Semantics(
      button: true,
      label: '${paper.name} 쪽 넣기',
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: shape,
          highlightColor: KitTokens.addPageCardOnBg,
          splashColor: Colors.transparent,
          onTap: onTap,
          child: Padding(
            padding: KitTokens.addPageCardPad,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              spacing: KitTokens.addPageCardGap,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: KitTokens.addPageSampleBg,
                    borderRadius: BorderRadius.circular(
                      KitTokens.addPageSampleRadius,
                    ),
                    boxShadow: KitTokens.addPageSampleShadow,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      KitTokens.addPageSampleRadius,
                    ),
                    child: CustomPaint(
                      size: KitTokens.addPageSampleSize,
                      painter: _Sample(paper.pattern),
                    ),
                  ),
                ),
                KitText(
                  paper.name,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: KitTokens.addPageCardTextSize,
                    height: KitTokens.addPageCardTextHeight,
                    color: KitTokens.menuInk,
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A card's sample (`.pp.lined`, `.grid`, `.dot`; 빈 종이 is plain).
class _Sample extends CustomPainter {
  const new(this.pattern);

  final CanvasBackgroundPattern pattern;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    switch (pattern) {
      case CanvasBackgroundPattern.lined:
        paint.color = KitTokens.addPageLineColor;
        for (
          var y = KitTokens.addPageLineFirst;
          y < size.height;
          y += KitTokens.addPageLineStep
        ) {
          canvas.drawRect(
            Rect.fromLTWH(0, y, size.width, KitTokens.addPageSampleLine),
            paint,
          );
        }
      case CanvasBackgroundPattern.grid:
        paint.color = KitTokens.addPageGridColor;
        for (
          var y = KitTokens.addPageGridFirst;
          y < size.height;
          y += KitTokens.addPageGridStep
        ) {
          canvas.drawRect(
            Rect.fromLTWH(0, y, size.width, KitTokens.addPageSampleLine),
            paint,
          );
        }
        for (
          var x = KitTokens.addPageGridFirst;
          x < size.width;
          x += KitTokens.addPageGridStep
        ) {
          canvas.drawRect(
            Rect.fromLTWH(x, 0, KitTokens.addPageSampleLine, size.height),
            paint,
          );
        }
      case CanvasBackgroundPattern.dots:
        paint.color = KitTokens.addPageDotColor;
        for (
          var y = KitTokens.addPageDotFirst;
          y < size.height;
          y += KitTokens.addPageDotStep
        ) {
          for (
            var x = KitTokens.addPageDotFirst;
            x < size.width;
            x += KitTokens.addPageDotStep
          ) {
            canvas.drawCircle(Offset(x, y), KitTokens.addPageDotRadius, paint);
          }
        }
      default:
    }
  }

  @override
  bool shouldRepaint(_Sample old) => old.pattern != pattern;
}

/// The 1 line over an import row (`.grp`, `.it+.it`).
class _Line extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => const SizedBox(
    height: KitTokens.menuLineWidth,
    width: double.infinity,
    child: ColoredBox(color: KitTokens.menuLine),
  );
}

/// An import row (`.it`), [height] high: the icon, the name and the kind
/// at the end; without [onTap], dimmed.
class _ImportRow extends StatelessWidget {
  const new({
    super.key,
    required this.icon,
    required this.label,
    required this.kind,
    this.height = KitTokens.addPageRowHeight,
    required this.onTap,
  });

  final KitIconName icon;
  final String label;
  final String kind;
  final double height;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: label,
    onTap: onTap,
    excludeSemantics: true,
    child: Material(
      color: KitTokens.menuGroupBg,
      child: InkWell(
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? KitTokens.disabledOpacity : 1,
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: KitTokens.menuPaddingH,
              ),
              child: Row(
                children: [
                  KitIcon(
                    icon,
                    size: KitTokens.menuIconSize,
                    strokeWidth: KitTokens.menuIconStroke,
                    color: KitTokens.menuInk,
                  ),
                  const SizedBox(width: KitTokens.menuIconGap),
                  Expanded(
                    child: KitText(
                      label,
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: KitTokens.addPageRowTextSize,
                        height: KitTokens.addPageGroupLine,
                        color: KitTokens.menuInk,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                  KitText(
                    kind,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: KitTokens.menuValueSize,
                      height: KitTokens.addPageGroupLine,
                      color: KitTokens.menuValue,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
