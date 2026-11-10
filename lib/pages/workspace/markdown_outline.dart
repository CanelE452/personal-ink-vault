part of 'markdown_editor.dart';

const _outlineOffset = 'data-ink-outline-offset';
const _outlineLineNumber = 'data-ink-outline-line';
const _maxOutlineHeadings = 10000;

final _outlineMarkdownExtensions = md.ExtensionSet([
  ...md.ExtensionSet.gitHubFlavored.blockSyntaxes,
  const _OutlineSetextSyntax(),
  const _OutlineAtxSyntax(),
], md.ExtensionSet.gitHubFlavored.inlineSyntaxes);

final class MarkdownOutlineHeading {
  const new _({
    required this.candidateIndex,
    required this.offset,
    required this.line,
    required this.level,
    required this.depth,
    required this.title,
  });

  final int candidateIndex;
  final int offset;
  final int line;
  final int level;
  final int depth;
  final String title;

  static List<MarkdownOutlineHeading> parse(String source) => _outlineHeadings(
    _prepareMarkdown(
      source,
      enableEmbeds: true,
      enablePdfEmbeds: true,
      dataviewBudget: _DataviewBudget(),
    ).anchors,
  );
}

class _OutlineSourceLine extends md.Line {
  new(super.content, this.offset, this.number);

  final int offset;
  final int number;
}

List<md.Node> _parseMarkdownWithHeadingLocations(
  md.Document document,
  String source,
) {
  final lines = <md.Line>[];
  var offset = 0;
  for (final content in const LineSplitter().convert(source)) {
    lines.add(_OutlineSourceLine(content, offset, lines.length + 1));
    offset += content.length;
    if (offset < source.length && source.codeUnitAt(offset) == 0x0d) offset++;
    if (offset < source.length && source.codeUnitAt(offset) == 0x0a) offset++;
  }
  return document.parseLineList(lines);
}

void _markOutlineLocation(md.BlockParser parser, md.Line? line, md.Node? node) {
  // Nested block parsers may receive transformed lines without source offsets.
  if (parser.parentSyntax != null ||
      line is! _OutlineSourceLine ||
      node is! md.Element) {
    return;
  }
  node.attributes[_outlineOffset] = '${line.offset}';
  node.attributes[_outlineLineNumber] = '${line.number}';
}

class _OutlineAtxSyntax extends md.HeaderSyntax {
  const new();

  @override
  md.Node parse(md.BlockParser parser) {
    final line = parser.current;
    final node = super.parse(parser);
    _markOutlineLocation(parser, line, node);
    return node;
  }
}

class _OutlineSetextSyntax extends md.SetextHeaderSyntax {
  const new();

  @override
  md.Node? parse(md.BlockParser parser) {
    final line = parser.linesToConsume.firstOrNull;
    final node = super.parse(parser);
    _markOutlineLocation(parser, line, node);
    return node;
  }
}

List<MarkdownOutlineHeading> _outlineHeadings(_MarkdownAnchors anchors) {
  final headings = <MarkdownOutlineHeading>[];
  final parentLevels = <int>[];
  for (var index = 0; index < anchors.candidates.length; index++) {
    final candidate = anchors.candidates[index];
    if (candidate['level'] case final int level) {
      final attributes = anchors.elements[index].attributes;
      final offset = int.tryParse(attributes[_outlineOffset] ?? '');
      final line = int.tryParse(attributes[_outlineLineNumber] ?? '');
      if (offset == null || line == null) continue;
      while (parentLevels.isNotEmpty && parentLevels.last >= level) {
        parentLevels.removeLast();
      }
      headings.add(
        MarkdownOutlineHeading._(
          candidateIndex: index,
          offset: offset,
          line: line,
          level: level,
          depth: parentLevels.length,
          title: _bookmarkDisplayText(candidate['text'] as String),
        ),
      );
      if (headings.length == _maxOutlineHeadings) break;
      parentLevels.add(level);
    }
  }
  return List.unmodifiable(headings);
}
