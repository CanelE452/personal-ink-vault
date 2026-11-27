import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/ink_ui/side_panel/side_row_parts.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// One recording of the audio tab: [title], [length] long, made at [madeAt].
/// [listening]: the one in the listening bar, [playing] while it plays;
/// [fresh]: just saved and not listened to yet (「새 녹음」).
class KitAudioRow {
  const new({
    required this.id,
    required this.title,
    required this.length,
    required this.madeAt,
    this.listening = false,
    this.playing = false,
    this.fresh = false,
  });

  final String id;
  final String title;
  final Duration length;
  final DateTime madeAt;
  final bool listening;
  final bool playing;
  final bool fresh;
}

/// A length or a position as the draft writes it (`mmss`): minutes and
/// seconds, two places each, in whole seconds rounded down, as the
/// recording pill's clock counts them (a length is the last time it
/// showed).
String kitAudioClock(Duration time) {
  final seconds = math.max(0, time.inSeconds);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(seconds ~/ 60)}:${two(seconds % 60)}';
}

/// When a recording was made, as the draft writes it: 「11월 27일 오후 2:05」,
/// in this device's time.
String kitAudioWhen(DateTime time) {
  final t = time.toLocal();
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  return '${t.month}월 ${t.day}일 ${t.hour < 12 ? '오전' : '오후'} $hour:$minute';
}

/// The audio tab (12th draft `sideHtml`, `arow`): 「이 노트의 녹음」 with the
/// count, the [rows] newest first, then a hint. A press on a row calls
/// [onPlay]; where the device cannot [play], the play circles are dim, a
/// press does nothing and a row is read out as not enabled. Where
/// [editable], each row has a ⋯ menu (「이름 바꾸기」 calls [onRenameStart],
/// 「지우기」 [onRemove]) and the row [renaming] names is a field with
/// 「완료」 ([onRename] with what was typed, [onRenameEdit] as it is typed;
/// Escape calls [onRename] with the old name). Without rows it shows the
/// tab's empty line, and nothing while the list is still [loading]. It
/// scrolls, building the rows as they come in, and ends [footRoom] over its
/// foot (the listening bar stands there).
class KitSideAudio extends StatelessWidget {
  const new({
    super.key,
    required this.rows,
    required this.play,
    required this.editable,
    this.loading = false,
    this.renaming,
    this.footRoom = 0,
    required this.onPlay,
    required this.onRenameStart,
    required this.onRenameEdit,
    required this.onRename,
    required this.onRemove,
  });

  final List<KitAudioRow> rows;
  final bool play;
  final bool editable;
  final bool loading;
  final String? renaming;
  final double footRoom;
  final ValueChanged<KitAudioRow> onPlay;
  final ValueChanged<KitAudioRow> onRenameStart;
  final void Function(KitAudioRow row, String title) onRenameEdit;
  final void Function(KitAudioRow row, String title) onRename;
  final ValueChanged<KitAudioRow> onRemove;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return loading
          ? const SizedBox.shrink()
          : const KitSideEmpty(KitSideTab.audio);
    }
    final items = <Object>[
      KitSideGroupTitle('이 노트의 녹음', count: '${rows.length}개'),
      ...rows,
      const KitSideHint('녹음을 누르면 아래에 듣기 막대가 뜹니다.'),
    ];
    return ListView.builder(
      padding: EdgeInsets.only(bottom: footRoom),
      itemCount: items.length,
      itemBuilder: (context, i) => switch (items[i]) {
        final KitAudioRow row when row.id == renaming && editable => _RenameRow(
          key: ValueKey('kit-audio-row-${row.id}'),
          row: row,
          play: play,
          onEdit: (title) => onRenameEdit(row, title),
          onDone: (title) => onRename(row, title),
        ),
        final KitAudioRow row => _Row(
          key: ValueKey('kit-audio-row-${row.id}'),
          row: row,
          play: play,
          editable: editable,
          onPlay: onPlay,
          onRename: onRenameStart,
          onRemove: onRemove,
        ),
        final item => item as Widget,
      },
    );
  }
}

const _nameStyle = TextStyle(
  fontSize: KitTokens.audioNameFontSize,
  height: KitTokens.sideLineHeight,
  letterSpacing: 0,
  fontWeight: FontWeight.w600,
  color: KitTokens.menuInk,
);

/// `.r1au .pp`: the row's play circle, the accent while [on], the pause
/// mark while [playing]; dim where the device cannot [play].
class _PlayCircle extends StatelessWidget {
  const new({required this.on, required this.playing, required this.play});

  final bool on;
  final bool playing;
  final bool play;

  @override
  Widget build(BuildContext context) {
    final circle = SizedBox.square(
      key: const ValueKey('kit-audio-play'),
      dimension: KitTokens.audioPlaySize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: on ? KitTokens.audioPlayOnBg : KitTokens.audioPlayBg,
          shape: BoxShape.circle,
        ),
        child: Center(
          child: KitIcon(
            on && playing ? KitIconName.pause : KitIconName.play,
            size: KitTokens.audioPlayIconSize,
            strokeWidth: KitTokens.audioPlayIconStroke,
            color: on ? KitTokens.audioPlayOnInk : KitTokens.audioPlayInk,
          ),
        ),
      ),
    );
    return play
        ? circle
        : Opacity(opacity: KitTokens.disabledOpacity, child: circle);
  }
}

/// The room of a row (`.r1au`): at least 60, 12 on the left, [right] on
/// the right.
Widget _room({required double right, required Widget child}) => ConstrainedBox(
  constraints: const BoxConstraints(minHeight: KitTokens.audioRowHeight),
  child: Padding(
    padding: EdgeInsets.only(left: KitTokens.audioRowPadLeft, right: right),
    child: child,
  ),
);

/// `.r1au`: a recording's play circle, its name over its length and date,
/// and its ⋯.
class _Row extends StatefulWidget {
  const new({
    super.key,
    required this.row,
    required this.play,
    required this.editable,
    required this.onPlay,
    required this.onRename,
    required this.onRemove,
  });

  final KitAudioRow row;
  final bool play;
  final bool editable;
  final ValueChanged<KitAudioRow> onPlay;
  final ValueChanged<KitAudioRow> onRename;
  final ValueChanged<KitAudioRow> onRemove;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  final _below = GlobalKey();
  final _above = GlobalKey();
  var _menuOpen = false;

  KitAudioRow get row => widget.row;

  Future<void> _openMenu() async {
    setState(() => _menuOpen = true);
    final picked = await showKitSideRowMenu(
      context,
      below: _below,
      above: _above,
    );
    if (mounted) setState(() => _menuOpen = false);
    switch (picked) {
      case KitSideRowAction.rename:
        widget.onRename(row);
      case KitSideRowAction.remove:
        widget.onRemove(row);
      case null:
    }
  }

  @override
  Widget build(BuildContext context) {
    final menu = widget.editable;
    return Semantics(
      button: true,
      enabled: widget.play,
      label: '${row.title} ${row.listening && row.playing ? '일시 정지' : '듣기'}',
      selected: row.listening,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.play ? () => widget.onPlay(row) : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            // `.r1au.on` comes after `.r1au.mopen`
            color: row.listening
                ? KitTokens.audioRowOnBg
                : _menuOpen
                ? KitTokens.sideRowMenuOpenBg
                : null,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _room(
                right: menu
                    ? KitTokens.audioRowPadRight - kitSideMenuReach
                    : KitTokens.audioRowPadLeft,
                child: Row(
                  children: [
                    ExcludeSemantics(
                      child: _PlayCircle(
                        on: row.listening,
                        playing: row.playing,
                        play: widget.play,
                      ),
                    ),
                    const SizedBox(width: KitTokens.audioRowGap),
                    Expanded(
                      child: ExcludeSemantics(child: _Text(row: row)),
                    ),
                    if (menu) ...[
                      const SizedBox(
                        width: KitTokens.audioRowGap - kitSideMenuReach,
                      ),
                      KitSideMoreButton(
                        buttonKey: const ValueKey('kit-audio-more'),
                        label: '${row.title} 메뉴',
                        open: _menuOpen,
                        onTap: _openMenu,
                      ),
                    ],
                  ],
                ),
              ),
              ...kitSideMenuAnchors(_below, _above),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.r1au .tx`: the name (with 「새 녹음」 after it) over the length and
/// the date.
class _Text extends StatelessWidget {
  const new({required this.row});

  final KitAudioRow row;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          Flexible(
            child: KitText(
              row.title,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: _nameStyle,
            ),
          ),
          if (row.fresh) ...[
            const SizedBox(width: KitTokens.audioNewGap),
            DecoratedBox(
              decoration: BoxDecoration(
                color: KitTokens.audioNewBg,
                borderRadius: BorderRadius.circular(KitTokens.audioNewRadius),
              ),
              child: const Padding(
                padding: KitTokens.audioNewPadding,
                child: KitText(
                  '새 녹음',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: KitTokens.audioNewFontSize,
                    height: KitTokens.sideLineHeight,
                    letterSpacing: 0,
                    fontWeight: FontWeight.w600,
                    color: KitTokens.audioNewInk,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: KitTokens.audioMetaGap),
      KitText(
        '${kitAudioClock(row.length)} · ${kitAudioWhen(row.madeAt)}',
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: KitTokens.audioMetaFontSize,
          height: KitTokens.sideLineHeight,
          letterSpacing: 0,
          color: KitTokens.audioMetaInk,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    ],
  );
}

/// A row whose name is being changed: its play circle, the name field (read
/// out 「녹음 이름」) and 「완료」.
class _RenameRow extends StatelessWidget {
  const new({
    super.key,
    required this.row,
    required this.play,
    required this.onEdit,
    required this.onDone,
  });

  final KitAudioRow row;
  final bool play;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onDone;

  @override
  Widget build(BuildContext context) => _room(
    right: KitTokens.audioRowPadRight,
    child: Row(
      children: [
        ExcludeSemantics(
          child: _PlayCircle(on: false, playing: false, play: play),
        ),
        const SizedBox(width: KitTokens.audioRowGap),
        Expanded(
          child: KitSideRenameField(
            title: row.title,
            label: '녹음 이름',
            fieldKey: const ValueKey('kit-audio-rename'),
            style: _nameStyle.copyWith(fontWeight: FontWeight.w400),
            gap: KitTokens.audioRowGap,
            onEdit: onEdit,
            onDone: onDone,
          ),
        ),
      ],
    ),
  );
}
