import 'package:flutter/material.dart';
import 'package:saber/data/vault/block_inline_text.dart';

class BlockInlineController extends TextEditingController {
  new({required String text, BlockInlineText? inlineText})
    : _inline = inlineText ?? BlockInlineText.plain(text),
      super(text: text);

  BlockInlineText _inline;
  var showFormatting = true;
  TextEditingValue? _previousTextValue;

  BlockInlineText get inlineText => _inline;
  TextEditingValue? get previousTextValue => _previousTextValue;

  @override
  set value(TextEditingValue next) {
    final previous = value;
    if (previous.text != next.text) {
      _previousTextValue = previous;
      _inline = _inline.replaceText(
        next.text,
        selectionStart: previous.selection.isValid
            ? previous.selection.start
            : null,
        selectionEnd: previous.selection.isValid
            ? previous.selection.end
            : null,
      );
    }
    super.value = next;
  }

  void sync(String text, BlockInlineText? inlineText, {required bool enabled}) {
    final previous = value;
    final nextInline = inlineText ?? BlockInlineText.plain(text);
    final changed =
        !identical(_inline, inlineText) || showFormatting != enabled;
    showFormatting = enabled;
    _inline = nextInline;
    if (previous.text != text) {
      final selection = previous.selection;
      super.value = TextEditingValue(
        text: text,
        selection: selection.isValid
            ? TextSelection(
                baseOffset: selection.baseOffset.clamp(0, text.length),
                extentOffset: selection.extentOffset.clamp(0, text.length),
                affinity: selection.affinity,
                isDirectional: selection.isDirectional,
              )
            : TextSelection.collapsed(offset: text.length),
      );
    }
    if (changed) notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (!showFormatting) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final composing = value.composing;
    final showComposing =
        withComposing &&
        composing.isValid &&
        !composing.isCollapsed &&
        composing.end <= text.length;
    final children = <TextSpan>[];
    var start = 0;
    for (final segment in _inline.segments) {
      final end = start + segment.text.length;
      final boundaries = <int>{
        start,
        end,
        if (showComposing && composing.start > start && composing.start < end)
          composing.start,
        if (showComposing && composing.end > start && composing.end < end)
          composing.end,
      }.toList()..sort();
      final marks = segment.marks;
      for (var i = 0; i + 1 < boundaries.length; i++) {
        final from = boundaries[i], to = boundaries[i + 1];
        final underlines = <TextDecoration>[
          if (style?.decoration != null) style!.decoration!,
          if (marks.contains(InlineMark.underline) ||
              segment.link != null ||
              showComposing && from >= composing.start && to <= composing.end)
            TextDecoration.underline,
          if (marks.contains(InlineMark.strikethrough))
            TextDecoration.lineThrough,
        ];
        children.add(
          TextSpan(
            text: text.substring(from, to),
            style: TextStyle(
              fontWeight: marks.contains(InlineMark.bold)
                  ? FontWeight.bold
                  : null,
              fontStyle: marks.contains(InlineMark.italic)
                  ? FontStyle.italic
                  : null,
              fontFamily: marks.contains(InlineMark.code) ? 'monospace' : null,
              backgroundColor: marks.contains(InlineMark.highlight)
                  ? const Color(0xffffe7a1)
                  : marks.contains(InlineMark.code)
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : null,
              color: segment.link == null ? null : const Color(0xff237d82),
              decoration: underlines.isEmpty
                  ? null
                  : TextDecoration.combine(underlines),
            ),
          ),
        );
      }
      start = end;
    }
    return TextSpan(style: style, children: children);
  }
}
