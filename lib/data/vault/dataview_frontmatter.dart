import 'dart:convert';
import 'dart:math';

import 'package:markdown/markdown.dart' as md;
import 'package:yaml/yaml.dart';

final class DataviewFrontmatter {
  final Map<String, Object?> properties;
  final Set<String> tags;
  final int bodyStart;
  final String propertyLinkMarkdown;
  final List<FrontmatterPropertyLink> propertyLinks;
  final List<String> aliases;

  const new(
    this.properties,
    this.tags,
    this.bodyStart, {
    this.propertyLinkMarkdown = '',
    this.propertyLinks = const [],
    this.aliases = const [],
  });

  static final _opening = RegExp(r'^\uFEFF?---[ \t]*(?:\r?\n|$)');
  static final _closing = RegExp(r'^---[ \t]*(?:\r?\n|$)', multiLine: true);
  static final _control = RegExp(r'[\x00-\x1f\x7f]');
  static final _wikiPropertyLink = RegExp(r'^\[\[[^\[\]]+\]\]$');
  static final _tag = RegExp(
    r'^[\p{L}\p{N}_-][\p{L}\p{M}\p{N}_-]*(?:/[\p{L}\p{N}_-][\p{L}\p{M}\p{N}_-]*)*$',
    unicode: true,
  );

  static DataviewFrontmatter? parse(
    String markdown, {
    bool includePropertySpans = false,
  }) {
    final bound = min(markdown.length, 64 * 1024);
    final prefix = markdown.substring(0, bound);
    final open = _opening.matchAsPrefix(prefix);
    if (open == null) return const DataviewFrontmatter({}, {}, 0);
    final close = _closing.firstMatch(prefix.substring(open.end));
    if (close == null) return null;
    final bodyStart = open.end + close.end;
    if (bodyStart == bound &&
        bound < markdown.length &&
        !prefix.endsWith('\n')) {
      return null;
    }

    try {
      final yaml = loadYamlNode(
        prefix.substring(open.end, open.end + close.start),
      );
      if (yaml.value == null)
        return DataviewFrontmatter(const {}, const {}, bodyStart);
      if (yaml is! YamlMap) return null;

      md.Document? linkDocument;
      bool isLink(String value) {
        if (value.length > 4096 ||
            !value.startsWith('[') ||
            _control.hasMatch(value)) {
          return false;
        }
        if (_wikiPropertyLink.hasMatch(value)) return true;
        if (!value.endsWith(')')) return false;
        final nodes = (linkDocument ??= md.Document()).parseInline(value);
        if (nodes case [md.Element(tag: 'a')]) return true;
        return false;
      }

      if (!includePropertySpans && yaml.length > 128) return null;
      final properties = <String, Object?>{};
      Object? rawAliases;
      for (final entry in yaml.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String ||
            key.isEmpty ||
            key.length > 128 ||
            _control.hasMatch(key)) {
          continue;
        }
        if (key.toLowerCase() == 'aliases') rawAliases ??= value;
        if (value == null ||
            value is bool ||
            (value is num && value.isFinite) ||
            (value is String && value.length <= 4096)) {
          properties[key] = value;
        }
      }

      final rawTags = yaml['tags'];
      final List<Object?> values = switch (rawTags) {
        final String tag => [tag],
        final YamlList tags => tags,
        _ => const [],
      };
      if (!includePropertySpans && values.length > 128) return null;
      final tags = <String>{};
      for (final raw in values.whereType<String>()) {
        final text = raw.trim();
        final tag = text.startsWith('#') ? text.substring(1) : text;
        if (tag.length <= 128 && _tag.hasMatch(tag)) tags.add(tag);
      }
      final aliasValues = switch (rawAliases) {
        final String alias => [alias],
        final YamlList list => list.whereType<String>(),
        _ => const <String>[],
      };
      final aliases = <String>{};
      for (final raw in aliasValues) {
        final alias = raw.trim();
        if (alias.isNotEmpty &&
            alias.length <= 255 &&
            !_control.hasMatch(alias)) {
          aliases.add(alias);
          if (aliases.length == 63) break;
        }
      }
      return DataviewFrontmatter(
        properties,
        tags,
        bodyStart,
        propertyLinkMarkdown: _propertyLinkMarkdown(yaml, isLink),
        propertyLinks: includePropertySpans
            ? _propertyLinkSpans(yaml, open.end, isLink)
            : const [],
        aliases: List.unmodifiable(aliases),
      );
    } on YamlException {
      return null;
    } on StackOverflowError {
      return null;
    }
  }

  static String _propertyLinkMarkdown(
    YamlMap yaml,
    bool Function(String) isLink,
  ) {
    final links = <String>{};
    var remaining = 512;

    void visit(Object? value, int depth) {
      if (remaining == 0) return;
      remaining--;
      if (depth > 8) return;
      if (value is String) {
        if (isLink(value)) links.add(value);
        return;
      }
      final Iterable<Object?> children = switch (value) {
        final YamlMap map => map.values,
        final YamlList list => list,
        _ => const [],
      };
      for (final child in children) {
        visit(child, depth + 1);
        if (remaining == 0) break;
      }
    }

    visit(yaml, 0);
    return links.join('\n\n');
  }

  static List<FrontmatterPropertyLink> _propertyLinkSpans(
    YamlMap yaml,
    int headerStart,
    bool Function(String) isLink,
  ) {
    // An alias reuses its target node. Visit each value and key node once.
    final values = Set<YamlNode>.identity();
    final keys = Set<YamlNode>.identity();
    final links = <YamlScalar>[];
    final pending = <(YamlNode, bool)>[(yaml, false)];
    while (pending.isNotEmpty) {
      final (node, insideKey) = pending.removeLast();
      if (!(insideKey ? keys : values).add(node)) continue;
      switch (node) {
        case YamlMap(:final nodes):
          for (final entry in nodes.entries) {
            pending.add((entry.key as YamlNode, true));
            pending.add((entry.value, insideKey));
          }
        case YamlList(:final nodes):
          for (final child in nodes) {
            pending.add((child, insideKey));
          }
        case final YamlScalar scalar when !insideKey:
          final value = scalar.value;
          if (value is String && isLink(value)) links.add(scalar);
      }
    }
    links.sort((a, b) => a.span.start.offset.compareTo(b.span.start.offset));
    return List.unmodifiable([
      for (final node in links)
        FrontmatterPropertyLink._(node, headerStart, keys.contains(node)),
    ]);
  }
}

final class FrontmatterPropertyLink {
  new _(YamlScalar node, int headerStart, this._usedAsKey)
    : text = node.value as String,
      start = headerStart + node.span.start.offset,
      end = headerStart + node.span.end.offset,
      _raw = node.span.text,
      _style = node.style;

  final String text;
  final int start;
  final int end;
  final String _raw;
  final ScalarStyle _style;
  final bool _usedAsKey;

  static final _scalarProperties = RegExp(r'^(?:[&!][^ \t]*[ \t]+){1,2}');
  static final _indent = RegExp(r'^ *');
  static final _nonLiteral = RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]');

  String encodeReplacement(String raw, String next) {
    if (raw != _raw || _usedAsKey) {
      throw StateError(
        'A YAML property reference shares an unsafe source span',
      );
    }
    final quote = switch (_style) {
      ScalarStyle.SINGLE_QUOTED => "'",
      ScalarStyle.DOUBLE_QUOTED => '"',
      _ => null,
    };
    if (quote != null && !raw.contains('\n') && !raw.contains('\r')) {
      final start = _scalarProperties.matchAsPrefix(raw)?.end ?? 0;
      if (raw.length > start + 1 &&
          raw[start] == quote &&
          raw.endsWith(quote)) {
        if (quote == '"') {
          final encoded = jsonEncode(next).replaceAllMapped(_nonLiteral, (m) {
            final hex = m[0]!.codeUnitAt(0).toRadixString(16).padLeft(4, '0');
            return '\\u$hex';
          });
          return raw.substring(0, start) + encoded;
        }
        if (!_nonLiteral.hasMatch(next)) {
          return "${raw.substring(0, start)}'${next.replaceAll("'", "''")}'";
        }
      }
    }
    if ((_style == ScalarStyle.LITERAL || _style == ScalarStyle.FOLDED) &&
        !_nonLiteral.hasMatch(next)) {
      final newline = raw.indexOf('\n');
      if (newline >= 0) {
        final content = raw.substring(newline + 1);
        final indentation = _indent.matchAsPrefix(content)!.end;
        if (content.substring(indentation) == text) {
          return raw.substring(0, newline + 1 + indentation) + next;
        }
      }
    }
    throw StateError(
      'A YAML property reference cannot preserve its scalar style',
    );
  }
}
