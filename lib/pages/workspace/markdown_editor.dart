import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable, listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:saber/data/vault/dataview_result.dart';
import 'package:saber/data/vault/markdown_template.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/workspace_markdown_templates.dart';

part 'markdown_callout.dart';
part 'markdown_dataview.dart';
part 'markdown_outline.dart';

final _obsidianImageDimensions = RegExp(
  r'^[ \t]*([0-9]{1,9})(?:[ \t]*x[ \t]*([0-9]{1,9}))?[ \t]*$',
);
const _embeddedAnchorParent = 'data-ink-embedded-anchor-parent';

class _WikiLinkSyntax extends md.InlineSyntax {
  new(this.enableNoteEmbeds, this.enablePdfEmbeds)
    : super(r'(!)?\[\[([^\]\n]+)\]\]');

  final bool enableNoteEmbeds, enablePdfEmbeds;

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final parts = match[2]!.split('|');
    final destination = parts.first.trim();
    final hash = destination.indexOf('#');
    final target = hash < 0 ? destination : destination.substring(0, hash);
    final anchor = hash < 0 ? null : destination.substring(hash + 1);
    if (target.isEmpty && (anchor == null || anchor.isEmpty)) return false;
    final label = parts.length > 1
        ? parts.sublist(1).join('|').trim()
        : destination;
    final href =
        'inkwiki:${Uri.encodeComponent(target)}'
        '${anchor == null ? '' : '#${Uri.encodeComponent(anchor)}'}';
    final kind = obsidianAttachmentKind(target.split('/').last);
    final pdf =
        match[1] != null &&
            enablePdfEmbeds &&
            kind == 'pdf' &&
            _vaultLinkPath(Uri.parse(href), wiki: true) != null
        ? _pdfEmbedOptions(anchor)
        : null;
    if (match[1] != null && anchor == null && kind == 'image') {
      parser.addNode(
        md.Element.empty('img')
          ..attributes['src'] = href
          ..attributes['alt'] = label,
      );
    } else if (pdf != null) {
      parser.addNode(
        md.Element.empty('ink-pdf-embed')
          ..attributes['href'] = href
          ..attributes['label'] = label.isEmpty ? target : label
          ..attributes['page'] = '${pdf.page}'
          ..attributes['height'] = '${pdf.height}',
      );
    } else if (match[1] != null && enableNoteEmbeds && kind == null) {
      parser.addNode(
        md.Element.empty('img')
          ..attributes['src'] = 'inkembed:${Uri.encodeComponent(href)}'
          ..attributes['data-ink-embed'] = 'true'
          ..attributes['alt'] = label.isEmpty ? destination : label,
      );
    } else {
      parser.addNode(
        md.Element.text('a', label.isEmpty ? destination : label)
          ..attributes['href'] = href,
      );
    }
    return true;
  }
}

({int page, int height})? _pdfEmbedOptions(String? fragment) {
  int? page, height;
  for (final field in fragment?.split('&') ?? const <String>[]) {
    final separator = field.indexOf('=');
    final key = separator < 0 ? field : field.substring(0, separator);
    if (key != 'page' && key != 'height') continue;
    if (separator < 0) return null;
    final value = field.substring(separator + 1);
    if (!RegExp(r'^[0-9]+$').hasMatch(value)) return null;
    final number = int.tryParse(value);
    if (number == null || number < 1 || number > 2147483647) return null;
    if (key == 'page') {
      if (page != null) return null;
      page = number;
    } else {
      if (height != null) return null;
      height = number;
    }
  }
  return (page: page ?? 1, height: (height ?? 480).clamp(96, 720).toInt());
}

bool _isSafeWikiLink(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'inkwiki' &&
      !uri.hasAuthority &&
      !uri.hasQuery &&
      (uri.path.isNotEmpty || uri.fragment.isNotEmpty);
}

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

class _PdfEmbedBuilder extends MarkdownElementBuilder {
  new(this.buildPreview);

  final Widget Function(md.Element) buildPreview;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => buildPreview(element);
}

class _BlockIdSyntax extends md.InlineSyntax {
  new() : super(r'\^([A-Za-z0-9-]+)[ \t]*$');

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    if (parser.pos > 0 &&
        !RegExp(r'\s').hasMatch(parser.source[parser.pos - 1])) {
      return false;
    }
    parser.addNode(
      md.Element.text('ink-block-id', '^${match[1]}')
        ..attributes['id'] = match[1]!,
    );
    return true;
  }
}

class _BlockIdBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Text(element.textContent, style: preferredStyle ?? parentStyle);
}

class _FrontmatterSyntax extends md.BlockSyntax {
  const new();

  @override
  RegExp get pattern => RegExp(r'^\uFEFF?---[ \t]*$');

  @override
  bool canParse(md.BlockParser parser) {
    if (parser.parentSyntax != null ||
        !identical(parser.current, parser.lines.first) ||
        !pattern.hasMatch(parser.current.content))
      return false;
    for (var ahead = 1; parser.peek(ahead) != null; ahead++) {
      if (RegExp(r'^(---|\.\.\.)[ \t]*$')
          .hasMatch(parser.peek(ahead)!.content)) {
        return true;
      }
    }
    return false;
  }

  @override
  md.Node parse(md.BlockParser parser) {
    final lines = [parser.current.content];
    parser.advance();
    while (!parser.isDone) {
      final line = parser.current.content;
      lines.add(line);
      parser.advance();
      if (RegExp(r'^(---|\.\.\.)[ \t]*$').hasMatch(line)) break;
    }
    return md.Element('pre', [md.Element.text('code', lines.join('\n'))])
      ..attributes['data-ink-frontmatter'] = 'true';
  }
}

class _MarkdownAnchors {
  final candidates = <Map<String, Object?>>[];
  final targets = <GlobalKey>[];
  final elements = <md.Element>[];
  final _keys = <md.Element, GlobalKey>{};
  static const _blockTags = {
    'p',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'blockquote',
    'pre',
    _dataviewTag,
    'ul',
    'ol',
    'hr',
    'table',
  };

  void _add(Map<String, Object?> candidate, md.Element node) {
    candidates.add(Map.unmodifiable(candidate));
    elements.add(node);
    targets.add(_keys.putIfAbsent(node, GlobalKey.new));
  }

  Widget wrap(md.Element node, Widget child) {
    final key = _keys[node];
    return key == null ? child : KeyedSubtree(key: key, child: child);
  }

  void collect(List<md.Node> nodes) {
    md.Element? previousBlock;
    for (var index = 0; index < nodes.length;) {
      final node = nodes[index];
      if (node is! md.Element) {
        if (node.textContent.trim().isNotEmpty) previousBlock = null;
        index++;
        continue;
      }
      if (node.tag == 'pre' ||
          node.tag == _dataviewTag ||
          node.tag == 'code' ||
          node.tag == 'math') {
        previousBlock =
            _blockTags.contains(node.tag) &&
                node.attributes['data-ink-frontmatter'] != 'true'
            ? node
            : null;
        index++;
        continue;
      }
      final children = node.children;
      final marker = children?.lastOrNull;
      final terminalMarker =
          marker is md.Element && marker.tag == 'ink-block-id' ? marker : null;
      final standalone =
          node.tag == 'p' &&
          terminalMarker != null &&
          children!
              .take(children.length - 1)
              .every(
                (child) => child is md.Text && child.textContent.trim().isEmpty,
              );
      if (standalone) {
        if (previousBlock != null) {
          _add({
            'kind': 'block',
            'id': terminalMarker.attributes['id']!,
          }, previousBlock);
          nodes.removeAt(index);
          continue;
        }
      }
      final level = RegExp(r'^h([1-6])$').firstMatch(node.tag)?[1];
      final inlineBlock = node.tag == 'p' || node.tag == 'li' || level != null;
      String? blockId;
      if (!standalone && inlineBlock && terminalMarker != null) {
        blockId = terminalMarker.attributes['id'];
        children!.removeLast();
        while (children.isNotEmpty && children.last is md.Text) {
          final trimmed = children.last.textContent.trimRight();
          children.removeLast();
          if (trimmed.isNotEmpty) {
            children.add(md.Text(trimmed));
            break;
          }
        }
      }
      if (level != null) {
        _add({
          'kind': 'heading',
          'text': node.textContent,
          'level': int.parse(level),
        }, node);
      }
      if (children != null) collect(children);
      if (blockId != null) _add({'kind': 'block', 'id': blockId}, node);
      if (_blockTags.contains(node.tag)) previousBlock = node;
      index++;
    }
  }
}

typedef MarkdownAnchorResolver = int? Function(
  String anchor,
  List<Map<String, Object?>> candidates,
);

String? _vaultLinkPath(Uri uri, {bool wiki = false}) {
  if (uri.hasAuthority ||
      uri.hasQuery ||
      (wiki ? uri.scheme != 'inkwiki' : uri.hasScheme)) {
    return null;
  }
  try {
    final path = Uri.decodeComponent(uri.path);
    if (path.startsWith('//') ||
        path.contains(':') ||
        path.contains(r'\') ||
        path.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]'))) {
      return null;
    }
    return path;
  } on FormatException {
    return null;
  }
}

bool _isLocalMarkdownLink(String value, {required bool allowAttachments}) {
  final uri = Uri.tryParse(value);
  if (uri == null) return false;
  final path = _vaultLinkPath(uri);
  if (path == null) return false;
  if (path.isEmpty) return uri.fragment.isNotEmpty;
  final leaf = path.split('/').last;
  final lower = leaf.toLowerCase();
  return lower.endsWith('.md') ||
      (leaf.isNotEmpty && !leaf.contains('.')) ||
      (allowAttachments &&
          (lower.endsWith('.csv') || obsidianAttachmentKind(leaf) != null));
}

typedef VaultMarkdownImageLoader = Future<Uint8List?> Function(String href);

final class VaultMarkdownEmbed {
  const new({
    required this.noteId,
    required this.title,
    required this.source,
    this.anchor,
  });

  final String noteId, title, source;
  final String? anchor;
}

final class VaultMarkdownEmbedAccess {
  const new({
    required this.sourceNoteId,
    required this.load,
    required this.openLink,
    required this.loadImage,
    this.loadPdf,
  });

  final String sourceNoteId;
  final Future<VaultMarkdownEmbed?> Function(String href, String fromNoteId)
  load;
  final void Function(String href, String fromNoteId) openLink;
  final Future<Uint8List?> Function(String href, String fromNoteId) loadImage;
  final Future<Uint8List?> Function(
    String href,
    String fromNoteId,
    int page,
    ValueListenable<bool> cancelled,
  )?
  loadPdf;
}

final class MarkdownDataviewAccess {
  const new({
    required this.evaluate,
    required this.openNote,
    this.evaluateFromNote,
    this.toggleTask,
    this.isCurrent,
  });

  final Future<DataviewResult> Function(String query) evaluate;
  final Future<DataviewResult> Function(String query, String noteId)?
  evaluateFromNote;
  final FutureOr<void> Function(String noteId) openNote;
  final Future<void> Function(DataviewRow row, bool completed)? toggleTask;
  final bool Function()? isCurrent;
}

typedef _PreparedMarkdown = ({
  List<md.Node> nodes,
  _MarkdownAnchors anchors,
  bool anchorMissing,
  List<_MarkdownEmbedSlot> embeds,
});

typedef _MarkdownEmbedResult = ({
  VaultMarkdownEmbed? content,
  _PreparedMarkdown? prepared,
  String? unavailable,
});

class _MarkdownEmbedSlot {
  new(this.href);

  final String href;
  final result = Completer<_MarkdownEmbedResult>();

  void reject(String reason) =>
      result.complete((content: null, prepared: null, unavailable: reason));
}

class _MarkdownEmbedPlan {
  new(this.access, this.anchorResolver, this.dataviewBudget);

  final VaultMarkdownEmbedAccess access;
  final MarkdownAnchorResolver? anchorResolver;
  final _DataviewBudget? dataviewBudget;
  final _notes = <(String, String), Future<VaultMarkdownEmbed?>>{};
  final images = <(String, String), Future<Uint8List?>>{};
  final _pdfs = <(String, String), Future<Uint8List?>>{};
  Future<void> _pdfTail = Future.value();
  final _pdfCancelled = ValueNotifier(false);
  final _finished = Completer<void>();
  var _placements = 0;
  var _renderedLength = 0;

  Future<void> get finished => _finished.future;

  void close() {
    if (_pdfCancelled.value) return;
    _pdfCancelled.value = true;
    _pdfCancelled.dispose();
    _finishNotes();
  }

  void _finishNotes() {
    if (!_finished.isCompleted) _finished.complete();
  }

  Future<Uint8List?>? pdf(
    String href,
    String origin,
    String pageHref,
    int page,
  ) {
    final loader = access.loadPdf;
    if (_pdfCancelled.value || loader == null) return null;
    final key = (origin, pageHref);
    final cached = _pdfs[key];
    if (cached != null) return cached;
    if (_pdfs.length >= 6) return null;
    final next = _pdfTail.then((_) async {
      if (_pdfCancelled.value) return null;
      try {
        final bytes = await loader(href, origin, page, _pdfCancelled);
        return _pdfCancelled.value ? null : bytes;
      } catch (_) {
        return null;
      }
    });
    _pdfTail = next.then<void>((_) {});
    return _pdfs[key] = next;
  }

  Future<void> load(_PreparedMarkdown prepared) async {
    final origin = access.sourceNoteId;
    try {
      await _loadInOrder(prepared, origin, [(origin, null)]);
    } finally {
      _finishNotes();
    }
  }

  Future<void> _loadInOrder(
    _PreparedMarkdown prepared,
    String origin,
    List<(String, String?)> ancestors,
  ) async {
    for (final slot in prepared.embeds) {
      if (_finished.isCompleted) return;
      if (ancestors.length > 5 || _placements >= 24) {
        slot.reject('포함할 수 있는 노트 수를 넘었습니다.');
        continue;
      }
      _placements++;
      VaultMarkdownEmbed? content;
      try {
        content = await _notes.putIfAbsent((
          origin,
          slot.href,
        ), () => access.load(slot.href, origin));
      } catch (_) {
        content = null;
      }
      if (_finished.isCompleted) return;
      if (content == null) {
        slot.reject('포함된 노트를 열 수 없습니다.');
        continue;
      }
      final key = (content.noteId, content.anchor);
      if (ancestors.contains(key)) {
        slot.reject('순환 포함을 건너뛰었습니다.');
        continue;
      }
      final length = content.source.length;
      if (length > 512 * 1024 || _renderedLength + length > 1024 * 1024) {
        slot.reject('포함할 수 있는 본문 크기를 넘었습니다.');
        continue;
      }
      _renderedLength += length;
      final child = _prepareMarkdown(
        content.source,
        enableEmbeds: true,
        enablePdfEmbeds: access.loadPdf != null,
        dataviewBudget: dataviewBudget,
        embedded: true,
        anchor: content.anchor,
        anchorResolver: anchorResolver,
      );
      slot.result.complete((
        content: content,
        prepared: child,
        unavailable: null,
      ));
      await _loadInOrder(child, content.noteId, [...ancestors, key]);
    }
  }
}

typedef _MarkdownInclusion = ({
  String origin,
  _PreparedMarkdown prepared,
  _MarkdownEmbedPlan plan,
});

({List<md.Node> nodes, int index})? _embeddedSection(
  List<md.Node> nodes,
  md.Element target,
  int? headingLevel,
) {
  for (var index = 0; index < nodes.length; index++) {
    final node = nodes[index];
    if (identical(node, target)) {
      if (headingLevel == null) return (nodes: [target], index: index);
      var end = index + 1;
      while (end < nodes.length) {
        final next = nodes[end];
        final level =
            next is md.Element && RegExp(r'^h[1-6]$').hasMatch(next.tag)
            ? int.parse(next.tag.substring(1))
            : null;
        if (level != null && level <= headingLevel) break;
        end++;
      }
      return (nodes: nodes.sublist(index, end), index: index);
    }
    if (node is! md.Element || node.children == null) continue;
    final selected = _embeddedSection(node.children!, target, headingLevel);
    if (selected == null) continue;
    if (const {'blockquote', 'ul', 'ol', 'li'}.contains(node.tag)) {
      final container = md.Element(node.tag, selected.nodes)
        ..attributes.addAll(node.attributes);
      if (node.tag == 'blockquote') {
        container.attributes[_embeddedAnchorParent] = 'true';
      }
      if (node.tag == 'ol' && selected.index > 0) {
        final start = int.tryParse(node.attributes['start'] ?? '1') ?? 1;
        container.attributes['start'] = '${start + selected.index}';
      }
      return (nodes: [container], index: index);
    }
    return (nodes: selected.nodes, index: index);
  }
  return null;
}

_PreparedMarkdown _prepareMarkdown(
  String source, {
  required bool enableEmbeds,
  required bool enablePdfEmbeds,
  _DataviewBudget? dataviewBudget,
  bool embedded = false,
  String? anchor,
  MarkdownAnchorResolver? anchorResolver,
}) {
  final document = md.Document(
    blockSyntaxes: [
      const _FrontmatterSyntax(),
      const _ObsidianCalloutSyntax(),
      if (dataviewBudget != null) const _DataviewFenceSyntax(),
    ],
    inlineSyntaxes: [
      _MathSyntax(),
      _WikiLinkSyntax(enableEmbeds, enablePdfEmbeds),
      _BlockIdSyntax(),
    ],
    extensionSet: _outlineMarkdownExtensions,
    encodeHtml: false,
  );
  var nodes = _parseMarkdownWithHeadingLocations(document, source);
  final anchors = _MarkdownAnchors()..collect(nodes);
  var anchorMissing = false;
  if (embedded) {
    if (anchor == null) {
      nodes = [
        for (final node in nodes)
          if (node is! md.Element ||
              node.attributes['data-ink-frontmatter'] != 'true')
            node,
      ];
    } else {
      List<md.Node>? selection;
      try {
        final index = anchorResolver?.call(
          anchor,
          List.unmodifiable(anchors.candidates),
        );
        if (index != null && index >= 0 && index < anchors.elements.length) {
          selection = _embeddedSection(
            nodes,
            anchors.elements[index],
            anchors.candidates[index]['level'] as int?,
          )?.nodes;
        }
      } catch (_) {
        selection = null;
      }
      anchorMissing = selection == null;
      nodes = selection ?? const [];
    }
  }
  final slots = <_MarkdownEmbedSlot>[];
  void collectEmbeds(List<md.Node> nodes) {
    for (final node in nodes) {
      if (node is! md.Element) continue;
      if (node.tag == 'img' &&
          (node.attributes['src']?.startsWith('inkembed:') ?? false)) {
        final uri = Uri.tryParse(node.attributes['src']!);
        final href = node.attributes.remove('data-ink-embed') == 'true'
            ? _vaultEmbedHref(uri)
            : null;
        if (href == null) {
          node.attributes['src'] = 'inkembed:unavailable';
        } else {
          node.attributes['src'] = 'inkembed:${slots.length}';
          slots.add(_MarkdownEmbedSlot(href));
        }
      }
      if (node.children != null) collectEmbeds(node.children!);
    }
  }

  if (enableEmbeds) collectEmbeds(nodes);
  dataviewBudget?.reserve(nodes);
  return (
    nodes: nodes,
    anchors: anchors,
    anchorMissing: anchorMissing,
    embeds: slots,
  );
}

final class MarkdownBookmarkLocation {
  const new _(
    this._fragments, {
    required this.index,
    required this.label,
    required this.subtitle,
    required this.isBlock,
  });

  final int index;
  final String label;
  final String? subtitle;
  final bool isBlock;
  final List<String> _fragments;
}

final class MarkdownBookmarkLocations {
  new _(this.items, this._candidates);

  factory parse(String source) {
    final anchors = _prepareMarkdown(
      source,
      enableEmbeds: true,
      enablePdfEmbeds: true,
      dataviewBudget: _DataviewBudget(),
    ).anchors;
    final candidates = List<Map<String, Object?>>.unmodifiable(
      anchors.candidates,
    );
    if (candidates.length > 10000) {
      return MarkdownBookmarkLocations._(const [], candidates);
    }
    final items = <MarkdownBookmarkLocation>[];
    final trail = <({int level, String text})>[];
    for (var index = 0; index < candidates.length; index++) {
      final candidate = candidates[index];
      if (candidate['id'] case final String id) {
        final fragment = '^$id';
        if (!_validMarkdownBookmarkFragment(fragment)) continue;
        final preview = _bookmarkDisplayText(
          anchors.elements[index].textContent,
        );
        items.add(
          MarkdownBookmarkLocation._(
            [fragment],
            index: index,
            label: fragment,
            subtitle: preview.isEmpty
                ? null
                : String.fromCharCodes(preview.runes.take(120)),
            isBlock: true,
          ),
        );
      } else {
        final level = candidate['level'] as int;
        final text = _bookmarkDisplayText(candidate['text'] as String);
        while (trail.isNotEmpty && trail.last.level >= level) {
          trail.removeLast();
        }
        final subtitle = trail.map((heading) => heading.text).join(' › ');
        trail.add((level: level, text: text));
        final fragments = [
          for (var start = trail.length - 1; start >= 0; start--)
            trail.skip(start).map((heading) => heading.text).join('#'),
        ].where(_validMarkdownBookmarkFragment).toList(growable: false);
        if (text.isEmpty || fragments.isEmpty) continue;
        items.add(
          MarkdownBookmarkLocation._(
            fragments,
            index: index,
            label: text,
            subtitle: subtitle.isEmpty ? null : subtitle,
            isBlock: false,
          ),
        );
      }
    }
    return MarkdownBookmarkLocations._(List.unmodifiable(items), candidates);
  }

  final List<MarkdownBookmarkLocation> items;
  final List<Map<String, Object?>> _candidates;

  String? resolve(
    MarkdownBookmarkLocation location,
    MarkdownAnchorResolver resolver,
  ) {
    for (final fragment in location._fragments) {
      if (resolver(fragment, _candidates) == location.index) return fragment;
    }
    return null;
  }
}

String _bookmarkDisplayText(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();

bool _validMarkdownBookmarkFragment(String value) =>
    value.isNotEmpty &&
    value.length <= 2048 &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]'));

String? _vaultEmbedHref(Uri? uri) {
  if (uri == null || uri.hasAuthority || uri.hasQuery || uri.hasFragment)
    return null;
  try {
    final href = Uri.decodeComponent(uri.path);
    final wikiUri = Uri.tryParse(href);
    return wikiUri != null &&
            _isSafeWikiLink(href) &&
            _vaultLinkPath(wikiUri, wiki: true) != null
        ? href
        : null;
  } on FormatException {
    return null;
  }
}

class MarkdownPreview extends StatefulWidget {
  final _MarkdownInclusion? _inclusion;
  final String source;
  final ValueChanged<String> onOpenLink;
  final String? targetAnchor;
  final int anchorRequest;
  final MarkdownAnchorResolver? anchorResolver;
  final ValueChanged<String>? onAnchorUnavailable;
  final VaultMarkdownImageLoader? loadVaultImage;
  final Object? vaultImageScope;
  final VaultMarkdownEmbedAccess? vaultEmbeds;
  final MarkdownDataviewAccess? dataview;
  final bool allowTaskEdits;
  const new({
    super.key,
    required this.source,
    required this.onOpenLink,
    this.targetAnchor,
    this.anchorRequest = 0,
    this.anchorResolver,
    this.onAnchorUnavailable,
    this.loadVaultImage,
    this.vaultImageScope,
    this.vaultEmbeds,
    this.dataview,
    this.allowTaskEdits = true,
  }) : _inclusion = null;

  const new _embedded({
    required this.source,
    required this.onOpenLink,
    required this.anchorResolver,
    required this.vaultImageScope,
    required this.vaultEmbeds,
    required this.dataview,
    required this.allowTaskEdits,
    required this._inclusion,
  }) : targetAnchor = null,
       anchorRequest = 0,
       onAnchorUnavailable = null,
       loadVaultImage = null;

  @override
  State<MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<MarkdownPreview>
    implements MarkdownBuilderDelegate {
  final _scroll = ScrollController();
  final _recognizers = <GestureRecognizer>[];
  final _imageLoads = <String, Future<Uint8List?>>{};
  List<Widget> _children = const [];
  var _anchors = _MarkdownAnchors();
  _MarkdownEmbedPlan? _embedPlan;
  List<_MarkdownEmbedSlot> _embedSlots = const [];
  var _embeddedAnchorMissing = false;

  void _open(String href) {
    final context = widget._inclusion;
    if (context == null) {
      widget.onOpenLink(href);
    } else {
      widget.vaultEmbeds!.openLink(href, context.origin);
    }
  }

  var _jumpGeneration = 0;
  String? _anchorFailure;
  (String, String, int)? _reportedUnavailable;
  (String, String, int)? _handledRequest;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _parse();
    _scheduleJump();
  }

  @override
  void didUpdateWidget(MarkdownPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = widget.source != oldWidget.source;
    final imagesChanged =
        widget.vaultImageScope != oldWidget.vaultImageScope ||
        (widget.loadVaultImage == null) != (oldWidget.loadVaultImage == null);
    final embedsChanged =
        widget.vaultEmbeds?.sourceNoteId !=
            oldWidget.vaultEmbeds?.sourceNoteId ||
        (widget.vaultEmbeds?.loadPdf == null) !=
            (oldWidget.vaultEmbeds?.loadPdf == null) ||
        widget._inclusion != oldWidget._inclusion;
    if (sourceChanged ||
        imagesChanged ||
        embedsChanged ||
        !identical(widget.dataview, oldWidget.dataview) ||
        widget.allowTaskEdits != oldWidget.allowTaskEdits) {
      _parse();
    }
    if (sourceChanged ||
        imagesChanged ||
        widget.targetAnchor != oldWidget.targetAnchor ||
        widget.anchorRequest != oldWidget.anchorRequest ||
        (widget.anchorResolver == null) != (oldWidget.anchorResolver == null)) {
      _anchorFailure = null;
      if ((widget.anchorResolver == null) !=
          (oldWidget.anchorResolver == null)) {
        _handledRequest = null;
      }
      _scheduleJump();
    }
  }

  void _parse() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
    _imageLoads.clear();
    final inclusion = widget._inclusion;
    final access = widget.vaultEmbeds;
    final dataviewBudget = inclusion == null && widget.dataview != null
        ? _DataviewBudget()
        : null;
    final prepared =
        inclusion?.prepared ??
        _prepareMarkdown(
          widget.source,
          enableEmbeds: access != null,
          enablePdfEmbeds: access?.loadPdf != null,
          dataviewBudget: dataviewBudget,
        );
    if (inclusion == null) {
      _embedPlan?.close();
      _embedPlan =
          access == null || (prepared.embeds.isEmpty && access.loadPdf == null)
          ? null
          : _MarkdownEmbedPlan(access, widget.anchorResolver, dataviewBudget);
    } else {
      _embedPlan = inclusion.plan;
    }
    _anchors = prepared.anchors;
    _embedSlots = prepared.embeds;
    _embeddedAnchorMissing = prepared.anchorMissing;
    final style = MarkdownStyleSheet.fromTheme(Theme.of(context))
        .copyWith(textScaler: MediaQuery.textScalerOf(context));
    _children = MarkdownBuilder(
      delegate: this,
      selectable: true,
      styleSheet: style,
      imageDirectory: null,
      imageBuilder: _buildImage,
      checkboxBuilder: null,
      bulletBuilder: null,
      builders: {
        'math': _MathBuilder(),
        'ink-block-id': _BlockIdBuilder(),
        'ink-pdf-embed': _PdfEmbedBuilder(_buildPdf),
        if (widget.dataview case final dataview?)
          _dataviewTag: _DataviewFenceBuilder(
            dataview,
            widget.allowTaskEdits,
            inclusion?.origin,
          ),
      },
      paddingBuilders: const {},
      blockWrapper: (element, child) => _anchors.wrap(
        element,
        _wrapObsidianCallout(
          element,
          child,
          expandInitially: element.attributes[_embeddedAnchorParent] == 'true',
        ),
      ),
      fitContent: true,
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.baseline,
      contextMenuBuilder: (context, state) =>
          AdaptiveTextSelectionToolbar.editableText(editableTextState: state),
    ).build(prepared.nodes);
    final plan = _embedPlan;
    if (inclusion == null && plan != null) unawaited(plan.load(prepared));
  }

  Widget _buildPdf(md.Element element) {
    final plan = _embedPlan!;
    final href = element.attributes['href']!;
    final label = element.attributes['label']!;
    final page = int.parse(element.attributes['page']!);
    final height = double.parse(element.attributes['height']!);
    final origin = widget._inclusion?.origin ?? plan.access.sourceNoteId;
    final pageHref = '${href.split('#').first}#page%3D$page';
    final open = TextButton.icon(
      onPressed: () => plan.access.openLink(pageHref, origin),
      icon: const Icon(Icons.edit_outlined),
      label: Text('PDF 필기 열기 · $page쪽'),
    );
    final future = plan.pdf(href, origin, pageHref, page);
    if (future == null) return open;
    return Card.outlined(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
            open,
            SizedBox(
              height: height,
              child: FutureBuilder<Uint8List?>(
                future: future,
                builder: (_, snapshot) {
                  const unavailable = Center(
                    child: Text('PDF 페이지를 미리 볼 수 없습니다.'),
                  );
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: Text('PDF 페이지를 불러오는 중…'));
                  }
                  final bytes = snapshot.data;
                  if (bytes == null) return unavailable;
                  return Image.memory(
                    bytes,
                    height: height,
                    fit: BoxFit.contain,
                    semanticLabel: label,
                    errorBuilder: (_, _, _) => unavailable,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImage(Uri uri, String? _, String? alt) {
    if (uri.scheme == 'inkembed') return _buildEmbed(uri, alt ?? '');
    final inclusion = widget._inclusion;
    final loader = inclusion == null
        ? widget.loadVaultImage
        : widget.vaultEmbeds?.loadImage;
    final path = _vaultLinkPath(uri, wiki: uri.scheme == 'inkwiki');
    if (loader == null ||
        path == null ||
        uri.hasFragment ||
        obsidianAttachmentKind(path.split('/').last) != 'image') {
      return Text('[이미지 비활성화: ${alt ?? ''}]');
    }
    final href = uri.toString();
    final fileName = path.split('/').last;
    final separator = alt?.lastIndexOf('|') ?? -1;
    final size = alt != null && (separator >= 0 || uri.scheme == 'inkwiki')
        ? _obsidianImageDimensions.firstMatch(alt.substring(separator + 1))
        : null;
    final caption = size != null && separator >= 0
        ? alt!.substring(0, separator).trim()
        : '';
    final label = size == null ? alt : (caption.isEmpty ? fileName : caption);
    double? dimension(int group) {
      final value = int.tryParse(size?.group(group) ?? '');
      return value == null || value == 0
          ? null
          : value.clamp(1, 4096).toDouble();
    }

    final width = dimension(1);
    final height = dimension(2);
    Widget openAttachment() => TextButton(
      onPressed: () => _open(href),
      child: Text('첨부 열기: ${label?.isNotEmpty == true ? label! : fileName}'),
    );
    final Future<Uint8List?> future;
    if (inclusion == null) {
      if (!_imageLoads.containsKey(href) && _imageLoads.length >= 32)
        return openAttachment();
      future = _imageLoads.putIfAbsent(
        href,
        () => widget.loadVaultImage!(href),
      );
    } else {
      final key = (inclusion.origin, href);
      final images = inclusion.plan.images;
      if (!images.containsKey(key) && images.length >= 16)
        return openAttachment();
      future = images.putIfAbsent(
        key,
        () => widget.vaultEmbeds!.loadImage(href, inclusion.origin),
      );
    }
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (_, snapshot) {
        final bytes = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return Text('[이미지 불러오는 중: ${label ?? ''}]');
        }
        if (bytes == null) return openAttachment();
        return Image(
          image: ResizeImage(
            MemoryImage(bytes),
            width: 960,
            height: 960,
            policy: ResizeImagePolicy.fit,
          ),
          width: width,
          height: height,
          fit: width != null && height != null
              ? BoxFit.fill
              : width != null || height != null
              ? BoxFit.contain
              : null,
          semanticLabel: label,
          errorBuilder: (_, _, _) => openAttachment(),
        );
      },
    );
  }

  Widget _buildEmbed(Uri uri, String label) {
    final plan = _embedPlan;
    final access = widget.vaultEmbeds;
    final inclusion = widget._inclusion;
    final index = int.tryParse(uri.path);
    if (plan == null ||
        access == null ||
        index == null ||
        index < 0 ||
        index >= _embedSlots.length ||
        uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment) {
      return Text(label);
    }
    final slot = _embedSlots[index];
    final href = slot.href;
    final origin = inclusion?.origin ?? access.sourceNoteId;
    Widget open() => TextButton(
      onPressed: () => access.openLink(href, origin),
      child: Text('원본 열기 · $label'),
    );
    Widget unavailable(String reason) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(reason), open()],
    );
    return FutureBuilder<_MarkdownEmbedResult>(
      future: slot.result.future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Text('포함된 노트 불러오는 중 · $label');
        }
        final result = snapshot.requireData;
        final content = result.content;
        final prepared = result.prepared;
        if (content == null || prepared == null) {
          return unavailable(result.unavailable!);
        }
        return Card.outlined(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Tooltip(message: content.title, child: open()),
                MarkdownPreview._embedded(
                  source: content.source,
                  onOpenLink: widget.onOpenLink,
                  anchorResolver: widget.anchorResolver,
                  vaultImageScope: widget.vaultImageScope,
                  vaultEmbeds: access,
                  dataview: widget.dataview,
                  allowTaskEdits: widget.allowTaskEdits,
                  inclusion: (
                    origin: content.noteId,
                    prepared: prepared,
                    plan: plan,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () {
        if (href != null &&
            (NoteLink.parse(href) != null ||
                isSafeExternalLink(href) ||
                _isSafeWikiLink(href) ||
                _isLocalMarkdownLink(
                  href,
                  allowAttachments:
                      widget.loadVaultImage != null ||
                      widget._inclusion != null,
                ))) {
          _open(href);
        }
      };
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) => TextSpan(
    style: styleSheet.code,
    text: code.replaceAll(RegExp(r'\n$'), ''),
  );

  void _unavailable(String anchor, {bool unsupported = false}) {
    if (!mounted) return;
    final signature = (widget.source, anchor, widget.anchorRequest);
    _handledRequest = signature;
    setState(
      () => _anchorFailure = unsupported
          ? '이 연결에서는 문서 안의 위치 이동을 사용할 수 없습니다.'
          : '연결된 제목이나 문단 위치를 찾지 못했습니다.',
    );
    if (_reportedUnavailable != signature) {
      _reportedUnavailable = signature;
      widget.onAnchorUnavailable?.call(anchor);
    }
  }

  Future<void> _revealAnchor(BuildContext target) async {
    final generation = _jumpGeneration;
    if (_revealObsidianCalloutAncestors(target)) {
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted || !target.mounted || generation != _jumpGeneration) return;
    await Scrollable.ensureVisible(
      target,
      alignment: .05,
      duration: const Duration(milliseconds: 160),
    );
  }

  Future<void> _jumpToOutline(
    MarkdownOutlineHeading heading,
    String source,
  ) async {
    if (widget.source != source) return;
    final generation = ++_jumpGeneration;
    final plan = _embedSlots.isEmpty ? null : _embedPlan;
    if (plan != null) await plan.finished;
    if (!mounted || generation != _jumpGeneration) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        generation != _jumpGeneration ||
        widget.source != source ||
        (_embedSlots.isNotEmpty && !identical(plan, _embedPlan))) {
      return;
    }
    final current = _outlineHeadings(_anchors)
        .where((item) => item.offset == heading.offset)
        .firstOrNull;
    if (current == null) return;
    final target = _anchors.targets[current.candidateIndex].currentContext;
    if (target != null && target.mounted) await _revealAnchor(target);
  }

  void _scheduleJump() {
    final generation = ++_jumpGeneration;
    final anchor = widget.targetAnchor;
    if (anchor == null) {
      _handledRequest = null;
      return;
    }
    final signature = (widget.source, anchor, widget.anchorRequest);
    if (_handledRequest == signature) return;
    final plan = _embedSlots.isEmpty ? null : _embedPlan;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || generation != _jumpGeneration) return;
      if (plan != null) {
        await plan.finished;
        if (!mounted || generation != _jumpGeneration) return;
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || generation != _jumpGeneration) return;
      }
      final resolver = widget.anchorResolver;
      if (resolver == null) {
        _unavailable(anchor, unsupported: true);
        return;
      }
      int? index;
      try {
        index = resolver(anchor, List.unmodifiable(_anchors.candidates));
      } catch (_) {
        _unavailable(anchor);
        return;
      }
      if (!mounted || generation != _jumpGeneration) return;
      if (index == null || index < 0 || index >= _anchors.targets.length) {
        _unavailable(anchor);
        return;
      }
      final target = _anchors.targets[index].currentContext;
      if (target == null || !target.mounted) {
        _unavailable(anchor);
        return;
      }
      _handledRequest = signature;
      try {
        await _revealAnchor(target);
      } catch (_) {
        if (mounted && generation == _jumpGeneration) _unavailable(anchor);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _children,
    );
    if (widget._inclusion != null) {
      return _embeddedAnchorMissing
          ? const Text('포함된 제목이나 블록을 찾을 수 없습니다.')
          : body;
    }
    final content = SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.all(20),
      child: body,
    );
    return _anchorFailure == null
        ? content
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _anchorFailure!,
                  key: const ValueKey('markdown-anchor-unavailable'),
                ),
              ),
              Expanded(child: content),
            ],
          );
  }

  @override
  void dispose() {
    _jumpGeneration++;
    if (widget._inclusion == null) _embedPlan?.close();
    _scroll.dispose();
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }
}

final class MarkdownTemplateAccess {
  final WorkspaceMarkdownTemplateStore store;
  final String title;
  final bool Function() isCurrent;
  const new({
    required this.store,
    required this.title,
    required this.isCurrent,
  });
}

enum _MarkdownTemplateAction { configure }

class MarkdownEditor extends StatefulWidget {
  final String source;
  final bool readOnly;
  final bool dirty;
  final ValueChanged<String> onChanged;
  final VoidCallback onSave;
  final ValueChanged<String> onOpenLink;
  final String? targetAnchor;
  final int anchorRequest;
  final ({int start, int end, String text})? searchSelection;
  final int searchSelectionRequest;
  final MarkdownAnchorResolver? anchorResolver;
  final ValueChanged<String>? onAnchorUnavailable;
  final VaultMarkdownImageLoader? loadVaultImage;
  final Object? vaultImageScope;
  final VaultMarkdownEmbedAccess? vaultEmbeds;
  final MarkdownDataviewAccess? dataview;
  final MarkdownTemplateAccess? templates;
  const new({
    super.key,
    required this.source,
    required this.readOnly,
    required this.dirty,
    required this.onChanged,
    required this.onSave,
    required this.onOpenLink,
    this.targetAnchor,
    this.anchorRequest = 0,
    this.searchSelection,
    this.searchSelectionRequest = 0,
    this.anchorResolver,
    this.onAnchorUnavailable,
    this.loadVaultImage,
    this.vaultImageScope,
    this.vaultEmbeds,
    this.dataview,
    this.templates,
  });
  @override
  State<MarkdownEditor> createState() => _MarkdownEditorState();
}

class _MarkdownEditorState extends State<MarkdownEditor> {
  late final _text = TextEditingController(text: widget.source);
  final _previewKey = GlobalKey<_MarkdownPreviewState>();
  final _sourceFieldKey = GlobalKey();
  var preview = true;
  var _templateBusy = false;
  var _editVersion = 0;

  @override
  void initState() {
    super.initState();
    _scheduleSearchSelection();
  }

  @override
  void didUpdateWidget(MarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != _text.text) {
      _editVersion++;
      _text.value = TextEditingValue(
        text: widget.source,
        selection: TextSelection.collapsed(offset: widget.source.length),
      );
    }
    if (widget.targetAnchor != null &&
        (widget.targetAnchor != oldWidget.targetAnchor ||
            widget.anchorRequest != oldWidget.anchorRequest))
      preview = true;
    if (widget.searchSelection != oldWidget.searchSelection ||
        widget.searchSelectionRequest != oldWidget.searchSelectionRequest) {
      _scheduleSearchSelection();
    }
  }

  void _scheduleSearchSelection() {
    final hit = widget.searchSelection;
    final source = widget.source;
    if (hit == null ||
        widget.readOnly ||
        hit.start < 0 ||
        hit.end <= hit.start ||
        hit.end > source.length ||
        source.substring(hit.start, hit.end) != hit.text) {
      return;
    }
    final request = widget.searchSelectionRequest;
    final editVersion = _editVersion;
    preview = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          preview ||
          widget.readOnly ||
          widget.searchSelectionRequest != request ||
          widget.searchSelection != hit ||
          _editVersion != editVersion ||
          _text.text != source) {
        return;
      }
      _revealSourceSelection(
        TextSelection(baseOffset: hit.start, extentOffset: hit.end),
      );
    });
  }

  Future<void> _insertTemplate() async {
    final access = widget.templates;
    if (access == null || _templateBusy || widget.readOnly) return;
    final source = _text.text;
    final selection = _text.selection;
    final editVersion = _editVersion;
    final anchorRequest = widget.anchorRequest;
    final searchRequest = widget.searchSelectionRequest;
    bool isCurrent() =>
        mounted &&
        !widget.readOnly &&
        identical(
          widget.templates?.store.repository,
          access.store.repository,
        ) &&
        _editVersion == editVersion &&
        widget.anchorRequest == anchorRequest &&
        widget.searchSelectionRequest == searchRequest &&
        _text.text == source &&
        access.isCurrent();

    setState(() => _templateBusy = true);
    try {
      while (isCurrent()) {
        final settings = await access.store.settings();
        if (!isCurrent()) return;
        final folder = settings.folderId;
        final choices = folder == null || settings.conflicted
            ? const <WorkspaceMarkdownTemplateChoice>[]
            : await access.store.templates(folder);
        if (!isCurrent()) return;
        final choice = await _chooseTemplate(settings, choices);
        if (!isCurrent() || choice == null) return;
        if (choice == _MarkdownTemplateAction.configure) {
          final folders = await access.store.folders();
          if (!isCurrent()) return;
          final updated = await _configureTemplates(settings, folders);
          if (!isCurrent() || updated == null) return;
          await access.store.saveSettings(
            settings,
            folderId: updated.folderId,
            dateFormat: updated.dateFormat,
            timeFormat: updated.timeFormat,
            beforePublish: () {
              if (!isCurrent()) {
                throw StateError('열린 노트가 바뀌었습니다. 다시 시도하세요.');
              }
            },
          );
          continue;
        }
        if (choice is! WorkspaceMarkdownTemplateChoice || folder == null)
          return;
        final template = await access.store.readTemplate(folder, choice);
        if (!isCurrent()) return;
        final latest = await access.store.settings();
        if (!isCurrent()) return;
        if (latest.conflicted ||
            latest.folderId != folder ||
            latest.dateFormat != settings.dateFormat ||
            latest.timeFormat != settings.timeFormat ||
            !listEquals(latest.revisionIds, settings.revisionIds)) {
          throw StateError('템플릿 설정이 바뀌었습니다. 다시 선택하세요.');
        }
        final validSelection =
            selection.isValid && selection.end <= source.length;
        final result = applyMarkdownTemplate(
          document: source,
          selectionStart: validSelection ? selection.start : source.length,
          selectionEnd: validSelection ? selection.end : source.length,
          template: template,
          title: access.title,
          now: DateTime.now(),
          dateFormat: settings.dateFormat,
          timeFormat: settings.timeFormat,
        );
        _text.value = TextEditingValue(
          text: result.text,
          selection: TextSelection.collapsed(offset: result.caretOffset),
        );
        setState(() => preview = false);
        _onChanged(result.text);
        return;
      }
    } catch (error) {
      if (mounted && isCurrent()) {
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text('템플릿 작업을 완료하지 못했습니다. $error')));
      }
    } finally {
      if (mounted) setState(() => _templateBusy = false);
    }
  }

  Future<Object?> _chooseTemplate(
    WorkspaceMarkdownTemplateSettings settings,
    List<WorkspaceMarkdownTemplateChoice> choices,
  ) => showDialog<Object>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('템플릿 삽입'),
      content: SizedBox(
        width: 440,
        child: choices.isEmpty
            ? Text(
                settings.conflicted
                    ? '템플릿 설정이 충돌했습니다. 설정에서 사용할 폴더와 형식을 저장하세요.'
                    : settings.folderId == null
                    ? '템플릿 폴더를 설정하세요.'
                    : '이 폴더에 삽입할 Markdown 템플릿이 없습니다.',
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: choices.length,
                  itemBuilder: (context, index) {
                    final choice = choices[index];
                    return ListTile(
                      key: ValueKey('markdown-template-${choice.noteId}'),
                      title: Text(choice.label),
                      trailing: const Icon(Icons.add),
                      onTap: () => Navigator.pop(context, choice),
                    );
                  },
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, _MarkdownTemplateAction.configure),
          child: const Text('폴더 설정'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    ),
  );

  Future<({String? folderId, String dateFormat, String timeFormat})?>
  _configureTemplates(
    WorkspaceMarkdownTemplateSettings settings,
    List<({String id, String label})> folders,
  ) {
    var folder = folders.any((folder) => folder.id == settings.folderId)
        ? settings.folderId!
        : '';
    var dateFormat = settings.dateFormat;
    var timeFormat = settings.timeFormat;
    return showDialog<
      ({String? folderId, String dateFormat, String timeFormat})
    >(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('템플릿 설정'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                key: const ValueKey('markdown-template-folder'),
                initialValue: folder,
                decoration: const InputDecoration(labelText: '템플릿 폴더'),
                isExpanded: true,
                items: [
                  const DropdownMenuItem(value: '', child: Text('지정 안 함')),
                  for (final folder in folders)
                    DropdownMenuItem(
                      value: folder.id,
                      child: Text(
                        folder.label,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => folder = value ?? '',
              ),
              TextFormField(
                key: const ValueKey('markdown-template-date-format'),
                initialValue: dateFormat,
                maxLength: 128,
                decoration: const InputDecoration(labelText: '날짜 형식'),
                onChanged: (value) => dateFormat = value,
              ),
              TextFormField(
                key: const ValueKey('markdown-template-time-format'),
                initialValue: timeFormat,
                maxLength: 128,
                decoration: const InputDecoration(labelText: '시간 형식'),
                onChanged: (value) => timeFormat = value,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('markdown-template-save-settings'),
            onPressed: () => Navigator.pop(context, (
              folderId: folder.isEmpty ? null : folder,
              dateFormat: dateFormat.trim().isEmpty
                  ? WorkspaceMarkdownTemplateSettings.defaultDateFormat
                  : dateFormat,
              timeFormat: timeFormat.trim().isEmpty
                  ? WorkspaceMarkdownTemplateSettings.defaultTimeFormat
                  : timeFormat,
            )),
            child: const Text('설정 저장'),
          ),
        ],
      ),
    );
  }

  void _onChanged(String value) {
    _editVersion++;
    widget.onChanged(value);
  }

  Future<void> _showOutline() async {
    final reading = preview || widget.readOnly;
    final source = reading ? widget.source : _text.text;
    final editVersion = _editVersion;
    final anchorRequest = widget.anchorRequest;
    final searchRequest = widget.searchSelectionRequest;
    final targetAnchor = widget.targetAnchor;
    final noteScope = widget.vaultImageScope;
    final reader = _previewKey.currentState;
    final headings = reader == null
        ? MarkdownOutlineHeading.parse(source)
        : _outlineHeadings(reader._anchors);
    final selected = await showDialog<MarkdownOutlineHeading>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('목차'),
        content: SizedBox(
          width: 440,
          child: headings.isEmpty
              ? const Text('이 문서에 제목이 없습니다.')
              : ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: headings.length,
                    itemBuilder: (context, index) {
                      final heading = headings[index];
                      return ListTile(
                        key: ValueKey(
                          'markdown-outline-heading-${heading.candidateIndex}',
                        ),
                        contentPadding: EdgeInsetsDirectional.only(
                          start: 16.0 + 14.0 * heading.depth,
                          end: 16,
                        ),
                        title: Text(
                          heading.title.isEmpty ? '(빈 제목)' : heading.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Text('${heading.line}행'),
                        onTap: () => Navigator.pop(context, heading),
                      );
                    },
                  ),
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
    if (!mounted ||
        selected == null ||
        _editVersion != editVersion ||
        widget.anchorRequest != anchorRequest ||
        widget.searchSelectionRequest != searchRequest ||
        widget.targetAnchor != targetAnchor ||
        widget.vaultImageScope != noteScope ||
        reading != (preview || widget.readOnly) ||
        source != (reading ? widget.source : _text.text)) {
      return;
    }
    if (reading) {
      if (identical(reader, _previewKey.currentState)) {
        await reader?._jumpToOutline(selected, source);
      }
      return;
    }
    _revealSourceSelection(TextSelection.collapsed(offset: selected.offset));
  }

  void _revealSourceSelection(TextSelection selection) {
    _text.selection = selection;
    // TextField owns the EditableText that can reveal the selection.
    EditableTextState? editor;
    void findEditor(Element element) {
      if (editor != null) return;
      if (element is StatefulElement) {
        final state = element.state;
        if (state is EditableTextState &&
            identical(state.widget.controller, _text)) {
          editor = state;
          return;
        }
      }
      element.visitChildren(findEditor);
    }

    _sourceFieldKey.currentContext?.visitChildElements(findEditor);
    editor?.widget.focusNode.requestFocus();
    editor?.bringIntoView(selection.extent);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      ListTile(
        title: Text(widget.readOnly ? 'Markdown 열람' : 'Markdown 정리'),
        subtitle: Text(widget.dirty ? '저장 대기' : '기기에 저장됨'),
        trailing: Wrap(
          children: [
            IconButton(
              key: const ValueKey('markdown-outline'),
              tooltip: '목차',
              onPressed: _showOutline,
              icon: const Icon(Icons.format_list_bulleted),
            ),
            if (!widget.readOnly && widget.templates != null)
              IconButton(
                key: const ValueKey('markdown-templates'),
                tooltip: '템플릿',
                onPressed: _templateBusy ? null : _insertTemplate,
                icon: const Icon(Icons.add),
              ),
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
                key: _previewKey,
                source: widget.source,
                onOpenLink: widget.onOpenLink,
                targetAnchor: widget.targetAnchor,
                anchorRequest: widget.anchorRequest,
                anchorResolver: widget.anchorResolver,
                onAnchorUnavailable: widget.onAnchorUnavailable,
                loadVaultImage: widget.loadVaultImage,
                vaultImageScope: widget.vaultImageScope,
                vaultEmbeds: widget.vaultEmbeds,
                dataview: widget.dataview,
                allowTaskEdits: !widget.readOnly,
              )
            : Padding(
                padding: const EdgeInsets.all(16),
                child: TextField(
                  key: _sourceFieldKey,
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
                  onChanged: _onChanged,
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
