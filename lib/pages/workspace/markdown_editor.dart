import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:saber/data/vault/note_link.dart';

class _MathSyntax extends md.InlineSyntax {
  new() : super(r'\$\$([\s\S]+?)\$\$|\$([^\n\$]+?)\$');
  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element.text('math', match[1] ?? match[2]!));
    return true;
  }
}

class _MathBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Math.tex(
    element.textContent,
    textStyle: preferredStyle,
    onErrorFallback: (error) => Text(element.textContent),
  );
}

class MarkdownPreview extends StatelessWidget {
  final String source;
  final ValueChanged<String> onOpenLink;
  const new({super.key, required this.source, required this.onOpenLink});
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: MarkdownBody(
      data: source,
      selectable: true,
      inlineSyntaxes: [_MathSyntax()],
      builders: {'math': _MathBuilder()},
      imageBuilder: (uri, title, alt) => Text('[이미지 비활성화: ${alt ?? ''}]'),
      onTapLink: (text, href, title) {
        if (href != null &&
            (NoteLink.parse(href) != null || isSafeExternalLink(href)))
          onOpenLink(href);
      },
    ),
  );
}

class MarkdownEditor extends StatefulWidget {
  final String source;
  final bool readOnly;
  final bool dirty;
  final ValueChanged<String> onChanged;
  final VoidCallback onSave;
  final ValueChanged<String> onOpenLink;
  const new({
    super.key,
    required this.source,
    required this.readOnly,
    required this.dirty,
    required this.onChanged,
    required this.onSave,
    required this.onOpenLink,
  });
  @override
  State<MarkdownEditor> createState() => _MarkdownEditorState();
}

class _MarkdownEditorState extends State<MarkdownEditor> {
  late final _text = TextEditingController(text: widget.source);
  var preview = true;
  @override
  void didUpdateWidget(MarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != _text.text)
      _text.value = TextEditingValue(
        text: widget.source,
        selection: TextSelection.collapsed(offset: widget.source.length),
      );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        title: Text(widget.readOnly ? 'Markdown 열람' : 'Markdown 정리'),
        subtitle: Text(widget.dirty ? '저장 대기' : '기기에 저장됨'),
        trailing: Wrap(
          children: [
            if (!widget.readOnly)
              IconButton(
                tooltip: preview ? '원문 편집' : '미리보기',
                onPressed: () => setState(() => preview = !preview),
                icon: Icon(preview ? Icons.code : Icons.visibility),
              ),
            if (!widget.readOnly)
              IconButton(
                tooltip: 'Markdown 저장',
                onPressed: widget.dirty ? widget.onSave : null,
                icon: const Icon(Icons.save_outlined),
              ),
          ],
        ),
      ),
      const Divider(height: 1),
      Expanded(
        child: preview || widget.readOnly
            ? MarkdownPreview(
                source: widget.source,
                onOpenLink: widget.onOpenLink,
              )
            : Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  controller: _text,
                  expands: true,
                  maxLines: null,
                  minLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: '# 정리\n\n수식: \$x^2\$',
                  ),
                  style: const TextStyle(fontFamily: 'monospace'),
                  onChanged: widget.onChanged,
                ),
              ),
      ),
    ],
  );
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
}
