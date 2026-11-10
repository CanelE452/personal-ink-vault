part of 'markdown_editor.dart';

const _calloutType = 'data-ink-callout-type';
const _calloutTitle = 'data-ink-callout-title';
const _calloutFold = 'data-ink-callout-fold';

class _ObsidianCalloutSyntax extends md.BlockquoteSyntax {
  const new();

  static final _header = RegExp(
    r'^[ ]{0,3}>[ \t]?\[!([^\]\r\n]+)\]([+-]?)(?:[ \t]+(.*))?$',
  );

  @override
  bool canParse(md.BlockParser parser) =>
      _header.hasMatch(parser.current.content);

  @override
  md.Node parse(md.BlockParser parser) {
    final header = _header.firstMatch(parser.current.content)!;
    final type = header[1]!
        .split('|')
        .first
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-');
    final title = header[3]?.trim() ?? '';
    final node = super.parse(parser) as md.Element;
    node.attributes[_calloutType] = type;
    node.attributes[_calloutFold] = header[2]!;
    node.attributes[_calloutTitle] = title;
    return node;
  }

  @override
  List<md.Line> parseChildLines(md.BlockParser parser) =>
      super.parseChildLines(parser)..removeAt(0);
}

Widget _wrapObsidianCallout(
  md.Element element,
  Widget child, {
  bool expandInitially = false,
}) {
  final type = element.attributes[_calloutType];
  if (type == null) return child;
  final customTitle = element.attributes[_calloutTitle]!;
  final words = type.replaceAll('-', ' ').trim();
  final title = customTitle.isNotEmpty
      ? customTitle
      : words.isEmpty
      ? 'Note'
      : words[0].toUpperCase() + words.substring(1);
  final fold = element.attributes[_calloutFold];
  final hasBody = element.children?.isNotEmpty ?? false;
  return _ObsidianCallout(
    key: ObjectKey(element),
    type: type,
    title: title,
    foldable: hasBody && (fold == '+' || fold == '-'),
    initiallyExpanded: expandInitially || fold != '-',
    body: hasBody ? child : null,
  );
}

bool _revealObsidianCalloutAncestors(BuildContext target) {
  var changed = false;
  var context = target;
  while (true) {
    final callout = context.findAncestorStateOfType<_ObsidianCalloutState>();
    if (callout == null) return changed;
    if (callout.expandForAnchor()) changed = true;
    context = callout.context;
  }
}

class _ObsidianCallout extends StatefulWidget {
  const new({
    super.key,
    required this.type,
    required this.title,
    required this.foldable,
    required this.initiallyExpanded,
    this.body,
  });

  final String type;
  final String title;
  final bool foldable;
  final bool initiallyExpanded;
  final Widget? body;

  @override
  State<_ObsidianCallout> createState() => _ObsidianCalloutState();
}

class _ObsidianCalloutState extends State<_ObsidianCallout> {
  late bool _expanded = widget.initiallyExpanded;

  bool expandForAnchor() {
    if (!widget.foldable || _expanded) return false;
    setState(() => _expanded = true);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (icon, accent, background) = switch (widget.type) {
      'warning' || 'caution' || 'attention' => (
        Icons.warning_amber_outlined,
        colors.onTertiaryContainer,
        colors.tertiaryContainer,
      ),
      'failure' || 'fail' || 'missing' || 'danger' || 'error' || 'bug' => (
        Icons.error_outline,
        colors.onErrorContainer,
        colors.errorContainer,
      ),
      'success' || 'check' || 'done' => (
        Icons.check_circle_outline,
        colors.onSecondaryContainer,
        colors.secondaryContainer,
      ),
      _ => (
        Icons.info_outline,
        colors.onPrimaryContainer,
        colors.primaryContainer,
      ),
    };
    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Icon(icon, size: 20, color: accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.title,
              style: theme.textTheme.titleSmall?.copyWith(color: accent),
            ),
          ),
          if (widget.foldable)
            Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              color: accent,
            ),
        ],
      ),
    );
    return Material(
      color: background,
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.foldable)
            Semantics(
              expanded: _expanded,
              child: InkWell(
                borderRadius: const BorderRadius.all(Radius.circular(8)),
                onTap: () => setState(() => _expanded = !_expanded),
                child: header,
              ),
            )
          else
            header,
          if (widget.body case final body?)
            Visibility(
              visible: _expanded,
              maintainState: true,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: body,
              ),
            ),
        ],
      ),
    );
  }
}
