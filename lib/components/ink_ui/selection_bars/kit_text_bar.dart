import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';

import 'package:saber/components/ink_ui/pen_panel/kit_pen_color_row.dart'
    show showKitColorPicker;
import 'package:saber/components/ink_ui/selection_bars/selection_bar_anchor.dart';
import 'package:saber/components/ink_ui/selection_bars/selection_bar_parts.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_selection_bar.dart';
import 'package:saber/components/kit/kit_swatches.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The sizes of the size list (preview `FS_LIST`, line 2948).
const _sizes = [8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64];

/// The colour pages' names, as the pen panel's colour row names them.
const _colourPageNames = ['기본 색', '파스텔', '회색조'];

/// The text box's bar (preview-v9c 1-2, line 887), under the caret or the
/// chosen text at [caretRect] (in this widget's coordinates; it fills the
/// area it is given). Stage 1 has no AI slot, so it reads: text colour ·
/// size · format (B·I·U·S) · alignment · list | highlight · ⋯. Every button
/// changes [controller]'s selection, or the text typed next.
class KitTextBar extends StatefulWidget {
  const new({
    super.key,
    required this.controller,
    required this.caretRect,
    this.defaultSize = 28,
  });

  final QuillController controller;
  final Rect caretRect;

  /// The size shown for text without a size of its own (the note's body
  /// text: 0.7 of its line height, 28 at the default 40).
  final double defaultSize;

  @override
  State<KitTextBar> createState() => _KitTextBarState();
}

class _KitTextBarState extends State<KitTextBar> {
  final _colourAnchor = GlobalKey();
  final _sizeAnchor = GlobalKey();
  final _formatAnchor = GlobalKey();
  final _listAnchor = GlobalKey();
  final _moreAnchor = GlobalKey();

  /// The window open under the bar, whose button shows it.
  String? _open;

  QuillController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_changed);
  }

  @override
  void didUpdateWidget(KitTextBar old) {
    super.didUpdateWidget(old);
    if (old.controller != _c) {
      old.controller.removeListener(_changed);
      _c.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Map<String, Attribute> get _style => _c.getSelectionStyle().attributes;

  bool _has(Attribute attribute) => _style.containsKey(attribute.key);

  /// [attribute] on the selection, or off when it is there.
  void _toggle(Attribute attribute) => _c.formatSelection(
    _has(attribute) ? Attribute.clone(attribute, null) : attribute,
  );

  Future<void> _openWindow(String name, Future<void> Function() open) async {
    setState(() => _open = name);
    await open();
    if (mounted) setState(() => _open = null);
  }

  static String _hex(Color colour) =>
      '#${colour.toARGB32().toRadixString(16).padLeft(8, '0')}';

  /// A Quill colour (`#rrggbb` or `#aarrggbb`), or null.
  static Color? _colourOf(Object? value) {
    if (value is! String || !value.startsWith('#')) return null;
    var hex = value.substring(1);
    if (hex.length == 6) hex = 'ff$hex';
    final argb = hex.length == 8 ? int.tryParse(hex, radix: 16) : null;
    return argb == null ? null : Color(argb);
  }

  Color? get _textColour => _colourOf(_style[Attribute.color.key]?.value);

  double get _size {
    final value = _style[Attribute.size.key]?.value;
    final size = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value)
        : null;
    return size ?? widget.defaultSize;
  }

  static String _sizeText(double size) => size == size.roundToDouble()
      ? size.round().toString()
      : size.toStringAsFixed(1);

  String? get _align => _style[Attribute.align.key]?.value as String?;

  /// Left (no alignment of its own) → centre → right → left again.
  void _nextAlign() => _c.formatSelection(switch (_align) {
    'center' => Attribute.rightAlignment,
    'right' => Attribute.clone(Attribute.align, null),
    _ => Attribute.centerAlignment,
  });

  void _toggleHighlight() => _c.formatSelection(
    _has(Attribute.background)
        ? Attribute.clone(Attribute.background, null)
        : BackgroundAttribute(_hex(KitTokens.textHighlight)),
  );

  void _toggleList(Attribute list) => _c.formatSelection(
    _style[Attribute.list.key]?.value == list.value
        ? Attribute.clone(Attribute.list, null)
        : list,
  );

  /// The clipboard's text, without its look: it takes the look of the text
  /// where it goes, as typing there would.
  Future<void> _pasteMatchingStyle() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    final at = _c.selection;
    if (text == null || text.isEmpty || _c.readOnly || !at.isValid) return;
    _c.replaceText(
      at.start,
      at.end - at.start,
      text,
      TextSelection.collapsed(offset: at.start + text.length),
    );
  }

  /// 「링크」: a small window under ⋯ with the address. 「넣기」 puts it on
  /// the chosen text (https:// in front of an address without a scheme); an
  /// empty address or 「떼기」 takes the link off.
  Future<void> _askLink() async {
    String? address;
    await _openWindow(
      'more',
      () => showKitPopover<void>(
        context: context,
        anchor: _moreAnchor,
        radius: BorderRadius.circular(KitTokens.linkWindowRadius),
        shadows: KitTokens.linkWindowShadow,
        border: false,
        builder: (window) => _LinkWindow(
          initial: _style[Attribute.link.key]?.value as String? ?? '',
          onDone: (value) {
            address = value;
            Navigator.of(window).pop();
          },
        ),
      ),
    );
    final value = address;
    if (value == null) return;
    _c.formatSelection(
      value.isEmpty
          ? Attribute.clone(Attribute.link, null)
          : LinkAttribute(_withScheme(value)),
    );
  }

  /// [address] with https:// in front when it names no scheme of its own: a
  /// scheme is one followed by // (http://, ftp://) or one of those used
  /// without it (mailto:, tel:, …). `localhost:8080` is a host and a port.
  static String _withScheme(String address) =>
      _schemeWithSlashes.hasMatch(address) || _bareScheme.hasMatch(address)
      ? address
      : 'https://$address';

  static final _schemeWithSlashes = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://');
  static final _bareScheme = RegExp(
    r'^(mailto|tel|sms|geo|data|urn|news):',
    caseSensitive: false,
  );

  Future<void> _openColours() => _openWindow(
    'colour',
    () => showSelectionColours(
      context: context,
      anchor: _colourAnchor,
      row: (window) {
        void choose(Color colour) {
          Navigator.of(window).pop();
          _c.formatSelection(ColorAttribute(_hex(colour)));
        }

        final now = _textColour ?? KitTokens.textBarDefaultInk;
        return KitSwatches(
          key: const ValueKey('text-bar-colours'),
          pages: KitTokens.penPanelColorPages,
          pageNames: _colourPageNames,
          selected: now,
          onSelected: choose,
          // the colour wheel, as the pen panel's; letters are not inverted
          // on the dark page, so the colour is taken as it is
          onPalette: () async {
            final made = await showKitColorPicker(
              window,
              initial: now,
              pageInk: false,
            );
            if (made != null && window.mounted) choose(made);
          },
        );
      },
    ),
  );

  Future<void> _openSizes() {
    final chosen = _sizes.indexOf(_size.round());
    const row = KitTokens.sizeListRowHeight;
    const view = KitTokens.sizeListMaxHeight;
    // the chosen size in the middle of the list (preview `fsPlace`)
    final scroll = chosen < 0
        ? 0.0
        : (chosen * row - view / 2 + row / 2)
              .clamp(0.0, math.max(0.0, _sizes.length * row - view))
              .toDouble();
    return _openWindow(
      'size',
      () => showSelectionMenu(
        context: context,
        anchor: _sizeAnchor,
        width: KitTokens.sizeListWidth,
        rowHeight: row,
        fontSize: KitTokens.sizeListFontSize,
        maxHeight: view,
        initialScroll: scroll,
        groups: [
          [
            for (final size in _sizes)
              SelectionMenuRow(
                key: ValueKey('text-size-$size'),
                label: '$size',
                checked: size == _size,
                onTap: () => _c.formatSelection(
                  Attribute.fromKeyValue(Attribute.size.key, '$size'),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _formatButtons(BuildContext window) => ListenableBuilder(
    listenable: _c,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: KitTokens.selPopGap,
      children: [
        for (final (key, label, letter, style, attribute) in [
          ('bold', '굵게', 'B', null, Attribute.bold),
          (
            'italic',
            '기울임',
            'I',
            const TextStyle(
              fontStyle: FontStyle.italic,
              fontFamily: 'Georgia',
              fontFamilyFallback: ['serif'],
            ),
            Attribute.italic,
          ),
          (
            'underline',
            '밑줄',
            'U',
            const TextStyle(decoration: TextDecoration.underline),
            Attribute.underline,
          ),
          (
            'strike',
            '취소선',
            'S',
            const TextStyle(decoration: TextDecoration.lineThrough),
            Attribute.strikeThrough,
          ),
        ])
          SelectionPopButton(
            key: ValueKey('text-format-$key'),
            label: label,
            letter: letter,
            letterStyle: style,
            on: _has(attribute),
            onPressed: () => _toggle(attribute),
          ),
      ],
    ),
  );

  Widget _listButtons(BuildContext window) => ListenableBuilder(
    listenable: _c,
    builder: (context, _) => Row(
      mainAxisSize: MainAxisSize.min,
      spacing: KitTokens.selPopGap,
      children: [
        SelectionPopButton(
          key: const ValueKey('text-list-bullet'),
          label: '글머리표',
          icon: KitIconName.listBullet,
          on: _style[Attribute.list.key]?.value == Attribute.ul.value,
          onPressed: () => _toggleList(Attribute.ul),
        ),
        SelectionPopButton(
          key: const ValueKey('text-list-number'),
          label: '번호',
          icon: KitIconName.listNumber,
          on: _style[Attribute.list.key]?.value == Attribute.ol.value,
          onPressed: () => _toggleList(Attribute.ol),
        ),
      ],
    ),
  );

  // Cut, copy and paste go through the controller's clipboard, as Quill's
  // own text menu does (`QuillRawEditorState.copySelection`); flutter_quill
  // marks these @experimental.
  Future<void> _openMore() async {
    final clipboard = await Clipboard.hasStrings();
    if (!mounted) return;
    final collapsed = _c.selection.isCollapsed;
    final editable = !_c.readOnly;
    SelectionMenuRow format(String label, KitIconName icon, Attribute a) =>
        SelectionMenuRow(
          label: label,
          icon: icon,
          checked: _has(a),
          onTap: () => _toggle(a),
        );
    await _openWindow(
      'more',
      () => showSelectionMenu(
        context: context,
        anchor: _moreAnchor,
        groups: [
          [
            SelectionMenuRow(
              key: const ValueKey('text-cut'),
              label: '자르기',
              icon: KitIconName.scissors,
              onTap: collapsed || !editable
                  ? null
                  // ignore: experimental_member_use
                  : () => _c.clipboardSelection(false),
            ),
            SelectionMenuRow(
              key: const ValueKey('text-copy'),
              label: '복사하기',
              icon: KitIconName.copy2,
              onTap: collapsed
                  ? null
                  // ignore: experimental_member_use
                  : () => _c.clipboardSelection(true),
            ),
            SelectionMenuRow(
              key: const ValueKey('text-paste'),
              label: '붙여넣기',
              icon: KitIconName.paste,
              onTap: clipboard && editable
                  // ignore: experimental_member_use
                  ? () => unawaited(_c.clipboardPaste())
                  : null,
            ),
            SelectionMenuRow(
              key: const ValueKey('text-paste-match'),
              label: '붙여넣고 스타일 맞추기',
              note: '복사한 글의 서식은 버리고 지금 글자 모양으로 붙여 넣습니다.',
              icon: KitIconName.pasteStyle,
              onTap: clipboard && editable
                  ? () => unawaited(_pasteMatchingStyle())
                  : null,
            ),
          ],
          [
            SelectionMenuRow(
              key: const ValueKey('text-format-more'),
              label: '서식',
              icon: KitIconName.bi,
              submenu: [
                format('굵게', KitIconName.bold, Attribute.bold),
                format('기울임', KitIconName.italic, Attribute.italic),
                format('밑줄', KitIconName.underline, Attribute.underline),
                format('취소선', KitIconName.strike, Attribute.strikeThrough),
              ],
            ),
            SelectionMenuRow(
              key: const ValueKey('text-indent-more'),
              label: '들여쓰기',
              icon: KitIconName.indent,
              submenu: [
                SelectionMenuRow(
                  label: '들여쓰기',
                  onTap: () => _c.indentSelection(true),
                ),
                SelectionMenuRow(
                  label: '내어쓰기',
                  onTap: () => _c.indentSelection(false),
                ),
              ],
            ),
          ],
          [
            SelectionMenuRow(
              key: const ValueKey('text-highlight-more'),
              label: '글자 하이라이트',
              icon: KitIconName.textHl,
              checked: _has(Attribute.background),
              onTap: _toggleHighlight,
            ),
            SelectionMenuRow(
              key: const ValueKey('text-link'),
              label: '링크',
              icon: KitIconName.link,
              onTap: collapsed ? null : () => unawaited(_askLink()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _button({
    required String key,
    required KitIconName icon,
    required String label,
    required VoidCallback onPressed,
    bool selected = false,
  }) => KitSelectionBarButton(
    key: ValueKey('text-bar-$key'),
    icon: icon,
    tooltip: label,
    selected: selected,
    onPressed: onPressed,
  );

  @override
  Widget build(BuildContext context) {
    final colour = _textColour;
    final align = _align;
    final bar = KitSelectionBar(
      groups: [
        [
          selectionWindowAnchor(
            anchor: _colourAnchor,
            left: -KitTokens.selPopShift,
            button: SelectionColourChip(
              key: const ValueKey('text-bar-colour'),
              label: '글자 색',
              colour: colour ?? KitTokens.textBarDefaultInk,
              selected: _open == 'colour',
              onPressed: _openColours,
            ),
          ),
          selectionWindowAnchor(
            anchor: _sizeAnchor,
            // the list centred on the box (preview `fsPlace`), which stands
            // its margin into the button
            left:
                KitTokens.selNumMargin +
                KitTokens.selNumWidth / 2 -
                KitTokens.sizeListWidth / 2,
            foot:
                KitTokens.selBarPaddingV +
                (KitTokens.selBarButton - KitTokens.selNumHeight) / 2,
            button: _SizeBox(
              key: const ValueKey('text-bar-size'),
              text: _sizeText(_size),
              open: _open == 'size',
              onPressed: _openSizes,
            ),
          ),
          selectionWindowAnchor(
            anchor: _formatAnchor,
            left: -KitTokens.selPopShift,
            button: _button(
              key: 'format',
              icon: KitIconName.bi,
              label: '서식',
              selected: _open == 'format',
              onPressed: () => _openWindow(
                'format',
                () => showSelectionPop(
                  context: context,
                  anchor: _formatAnchor,
                  buttons: _formatButtons,
                ),
              ),
            ),
          ),
          _button(
            key: 'align',
            icon: switch (align) {
              'center' => KitIconName.alignCenter,
              'right' => KitIconName.alignRight,
              _ => KitIconName.alignLeft,
            },
            label: '정렬',
            onPressed: _nextAlign,
          ),
          selectionWindowAnchor(
            anchor: _listAnchor,
            left: -KitTokens.selPopShift,
            button: _button(
              key: 'list',
              icon: KitIconName.listBullet,
              label: '목록',
              selected: _open == 'list',
              onPressed: () => _openWindow(
                'list',
                () => showSelectionPop(
                  context: context,
                  anchor: _listAnchor,
                  buttons: _listButtons,
                ),
              ),
            ),
          ),
        ],
        [
          _button(
            key: 'highlight',
            icon: KitIconName.textHl,
            label: '글자 하이라이트',
            selected: _has(Attribute.background),
            onPressed: _toggleHighlight,
          ),
          selectionWindowAnchor(
            anchor: _moreAnchor,
            left: -KitTokens.textMenuShift,
            button: _button(
              key: 'more',
              icon: KitIconName.more,
              label: '더 보기',
              selected: _open == 'more',
              onPressed: _openMore,
            ),
          ),
        ],
      ],
    );
    return SelectionBarAnchor(
      target: widget.caretRect,
      // a press on the bar does not take the text box's keys away
      child: TextFieldTapRegion(child: bar),
    );
  }
}

/// The size box (`.kbar .num`, line 456): the size in a white box, a blue
/// ring while its list is open.
class _SizeBox extends StatelessWidget {
  const new({
    super.key,
    required this.text,
    required this.open,
    required this.onPressed,
  });

  final String text;
  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(KitTokens.selNumRadius);
    return Semantics(
      button: true,
      label: '글자 크기 $text',
      onTap: onPressed,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: KitTokens.selNumMargin),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: KitTokens.selNumWidth,
            minHeight: KitTokens.selNumHeight,
            maxHeight: KitTokens.selNumHeight,
          ),
          child: Material(
            color: KitTokens.selNumBg,
            shape: RoundedRectangleBorder(
              borderRadius: shape,
              side: open
                  ? const BorderSide(
                      color: KitTokens.accent,
                      width: KitTokens.selNumOnRing,
                    )
                  : BorderSide.none,
            ),
            child: InkWell(
              borderRadius: shape,
              onTap: onPressed,
              child: Center(
                widthFactor: 1,
                child: KitText(
                  text,
                  style: const TextStyle(
                    fontSize: KitTokens.selNumFontSize,
                    height: KitTokens.objMenuLineHeight,
                    fontWeight: FontWeight.w400,
                    color: KitTokens.selBarInk,
                    letterSpacing: 0,
                    decoration: TextDecoration.none,
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

/// The link window (preview `.pmlk`, line 470): the title by the link icon,
/// the address field, 「떼기」 and 「넣기」. [onDone] gets the trimmed
/// address (empty: take the link off).
class _LinkWindow extends StatefulWidget {
  const new({required this.initial, required this.onDone});

  final String initial;
  final ValueChanged<String> onDone;

  @override
  State<_LinkWindow> createState() => _LinkWindowState();
}

class _LinkWindowState extends State<_LinkWindow> {
  late final _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Widget _button(
    String key,
    String label,
    VoidCallback onTap, {
    bool go = false,
  }) {
    final shape = BorderRadius.circular(KitTokens.linkButtonRadius);
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: Material(
        key: ValueKey(key),
        color: go ? KitTokens.accent : Colors.transparent,
        borderRadius: shape,
        child: InkWell(
          borderRadius: shape,
          onTap: onTap,
          child: SizedBox(
            height: KitTokens.linkButtonHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: KitTokens.linkButtonPadH,
              ),
              child: Center(
                widthFactor: 1,
                child: KitText(
                  label,
                  style: TextStyle(
                    fontSize: KitTokens.objMenuFontSize,
                    height: KitTokens.objMenuLineHeight,
                    fontWeight: FontWeight.w600,
                    color: go ? KitTokens.onAccent : KitTokens.menuSub,
                    letterSpacing: 0,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: KitTokens.menuGroupBg,
    child: SizedBox(
      width: KitTokens.linkWindowWidth,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: KitTokens.linkWindowPadH,
          vertical: KitTokens.linkWindowPadV,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              spacing: KitTokens.linkWindowHeadGap,
              children: [
                KitIcon(
                  KitIconName.link,
                  size: KitTokens.menuIconSize,
                  strokeWidth: KitTokens.menuIconStroke,
                  color: KitTokens.menuInk,
                ),
                KitText(
                  '링크',
                  style: TextStyle(
                    fontSize: KitTokens.objMenuFontSize,
                    height: KitTokens.objMenuLineHeight,
                    fontWeight: FontWeight.w700,
                    color: KitTokens.menuInk,
                    letterSpacing: 0,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
            const SizedBox(height: KitTokens.linkWindowGap),
            Container(
              height: KitTokens.linkFieldHeight,
              padding: const EdgeInsets.symmetric(
                horizontal: KitTokens.linkFieldPadH,
              ),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: KitTokens.linkFieldBg,
                borderRadius: BorderRadius.circular(KitTokens.linkFieldRadius),
              ),
              child: TextField(
                key: const ValueKey('text-link-field'),
                controller: _field,
                autofocus: true,
                keyboardType: TextInputType.url,
                cursorColor: KitTokens.accent, // not the theme's purple
                style: const TextStyle(
                  fontSize: KitTokens.objMenuFontSize,
                  color: KitTokens.linkFieldInk,
                  letterSpacing: 0,
                ),
                decoration: const InputDecoration.collapsed(
                  hintText: 'https://',
                ),
                onSubmitted: (value) => widget.onDone(value.trim()),
              ),
            ),
            const SizedBox(height: KitTokens.linkWindowGap),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              spacing: KitTokens.linkButtonGap,
              children: [
                _button('text-link-remove', '떼기', () => widget.onDone('')),
                _button(
                  'text-link-set',
                  '넣기',
                  () => widget.onDone(_field.text.trim()),
                  go: true,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
