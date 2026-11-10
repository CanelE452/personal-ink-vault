import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/vault/dataview_frontmatter.dart';
import 'package:saber/data/vault/knowledge_catalog.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/structured_document_text.dart';
import 'package:saber/data/vault/workspace_store.dart';

class KnowledgeLink {
  final String target;
  final String? anchor;
  final String? targetId;
  const new(this.target, this.anchor, this.targetId);
}

class KnowledgeEdge {
  final String from;
  final String to;
  const new(this.from, this.to);
}

class KnowledgeLocalGraph {
  final List<KnowledgeDocument> documents;
  final List<KnowledgeEdge> edges;

  new _(Iterable<KnowledgeDocument> documents, Iterable<KnowledgeEdge> edges)
    : documents = List.unmodifiable(documents),
      edges = List.unmodifiable(edges);
}

class UnresolvedKnowledgeLink {
  final String from;
  final String target;
  const new(this.from, this.target);
}

class KnowledgeTarget {
  final String noteId;
  final String? anchor;
  final String? attachmentName;
  const new(this.noteId, this.anchor, {this.attachmentName});
}

class KnowledgeSearchResult {
  final String id;
  final String title;
  final String snippet;
  final int score;
  final KnowledgeBodyMatch? bodyMatch;
  const new(this.id, this.title, this.snippet, this.score, {this.bodyMatch});
}

class KnowledgeBodyMatch {
  final String markdownRevisionId;
  final int start;
  final int end;
  final String text;
  final String excerpt;

  const new({
    required this.markdownRevisionId,
    required this.start,
    required this.end,
    required this.text,
    required this.excerpt,
  });
}

class KnowledgeIndexReadLimitExceeded implements Exception {
  const new();
}

class KnowledgeUnlinkedMentions {
  final List<KnowledgeUnlinkedMention> mentions;
  final bool truncated;

  new _(Iterable<KnowledgeUnlinkedMention> mentions, this.truncated)
    : mentions = List.unmodifiable(mentions);
}

class KnowledgeUnlinkedMention {
  final KnowledgeIndex _index;
  final _MentionSource _source;
  final _MentionSource _target;
  final String targetId;
  final String sourceId;
  final String text;
  final String snippet;
  final int start;
  final int end;

  const new _(
    this._index,
    this._source,
    this._target, {
    required this.targetId,
    required this.sourceId,
    required this.text,
    required this.snippet,
    required this.start,
    required this.end,
  });

  String get sourceMarkdownEntityId => _source.markdownEntityId;
  String get targetMarkdownEntityId => _target.markdownEntityId;

  Map<String, List<String>> get expectedHeads => {
    sourceId: [_source.metadataRevisionId],
    sourceMarkdownEntityId: [_source.markdownRevisionId],
    targetId: [_target.metadataRevisionId],
    targetMarkdownEntityId: [_target.markdownRevisionId],
  };
}

class _MentionSource {
  final String markdown;
  final int bytes;
  final List<String> aliases;
  final String metadataRevisionId;
  final String markdownEntityId;
  final String markdownRevisionId;

  const new({
    required this.markdown,
    required this.bytes,
    required this.aliases,
    required this.metadataRevisionId,
    required this.markdownEntityId,
    required this.markdownRevisionId,
  });
}

class KnowledgeDocument {
  final String id;
  final String title;
  final String markdown;
  final Set<String> tags;
  final List<KnowledgeLink> links;
  final bool metadataConflict;
  final bool markdownConflict;
  final String? searchFileName;
  final String? searchPath;
  final Set<String> searchTags;
  final Map<String, Object?> dataviewProperties;
  final Set<String> dataviewTags;
  final Set<String> dataviewBodyTags;
  final bool dataviewEligible;
  final String? dataviewFolder;
  final String? dataviewPath;
  final ({int bodyStart, String revisionId})? dataviewTaskSource;

  new({
    required this.id,
    required this.title,
    required this.markdown,
    required Set<String> tags,
    required List<KnowledgeLink> links,
    required this.metadataConflict,
    required this.markdownConflict,
    this.searchFileName,
    this.searchPath,
    Set<String> searchTags = const {},
    Map<String, Object?> dataviewProperties = const {},
    Set<String> dataviewTags = const {},
    Set<String> dataviewBodyTags = const {},
    this.dataviewEligible = false,
    this.dataviewFolder,
    this.dataviewPath,
    this.dataviewTaskSource,
  }) : tags = Set.unmodifiable(tags),
       links = List.unmodifiable(links),
       searchTags = Set.unmodifiable(searchTags),
       dataviewProperties = Map.unmodifiable(dataviewProperties),
       dataviewTags = Set.unmodifiable(dataviewTags),
       dataviewBodyTags = Set.unmodifiable(dataviewBodyTags);
}

class KnowledgeIndex {
  final InkVaultNative _native;
  final Map<String, Map<String, Object?>> _lookup;
  final Map<String, _MentionSource> _mentionSources;
  final Map<String, String> _searchMarkdownRevisions;
  final Map<String, KnowledgeDocument> documents;
  final List<KnowledgeEdge> edges;
  final List<UnresolvedKnowledgeLink> unresolved;
  final Map<String, List<KnowledgeDocument>> tags;

  new _(
    this._native,
    this._lookup,
    Map<String, KnowledgeDocument> documents,
    List<KnowledgeEdge> edges,
    List<UnresolvedKnowledgeLink> unresolved,
    Map<String, _MentionSource> mentionSources,
    Map<String, String> searchMarkdownRevisions,
  ) : _mentionSources = Map.unmodifiable(mentionSources),
      _searchMarkdownRevisions = Map.unmodifiable(searchMarkdownRevisions),
      documents = Map.unmodifiable(documents),
      edges = List.unmodifiable(edges),
      unresolved = List.unmodifiable(unresolved),
      tags = _tagIndex(documents.values);

  static Future<KnowledgeIndex> build(
    NoteRepository repository,
    InkVaultNative native, {
    ({int documents, int bytes})? readLimits,
  }) async {
    final catalog = await KnowledgeCatalog.capture(repository);
    final grouped = catalog.notes;
    if (readLimits != null && grouped.length > readLimits.documents) {
      throw const KnowledgeIndexReadLimitExceeded();
    }
    var remaining = readLimits?.bytes;
    void reserveBytes(int bytes) {
      final budget = remaining;
      if (budget == null) return;
      if (bytes > budget) throw const KnowledgeIndexReadLimitExceeded();
      remaining = budget - bytes;
    }

    Future<Map<String, Uint8List>> readContent(RevisionRecord revision) {
      if (remaining != null) {
        for (final blob in revision.blobs.values) {
          reserveBytes(blob.length);
        }
      }
      return repository.readFiles(revision);
    }

    final titles = <String, String>{};
    final bodies = <String, List<String>>{};
    final markdownConflicts = <String>{};
    final mentionSources = <String, _MentionSource>{};
    final searchMarkdownRevisions = <String, String>{};
    final summaries = <String, DataviewFrontmatter>{};
    final frontmatter = <String, DataviewFrontmatter>{};
    final taskSources = <String, ({int bodyStart, String revisionId})>{};
    final locations = <String, ({String? folder, String? path})>{};
    final searchLocations = <String, ({String? file, String? path})>{};
    final office = OfficeDocumentStore(repository);
    for (final entry in grouped.entries) {
      titles[entry.key] = catalog.documents[entry.key]!['title'] as String;
      final entityIds = entry.value
          .map((note) => note.markdownEntityId)
          .toSet();
      final heads = <RevisionRecord>[];
      for (final id in entityIds) {
        heads.addAll(catalog.heads[id] ?? const []);
      }
      if (heads.length > 1) markdownConflicts.add(entry.key);
      heads.sort((a, b) => a.revisionId.compareTo(b.revisionId));
      bodies[entry.key] = [];
      for (final head in heads.where((head) => !head.deleted)) {
        final bytes = (await readContent(head))['summary.md'];
        if (bytes == null)
          throw const FormatException('Missing Markdown source');
        bodies[entry.key]!.add(utf8.decode(bytes));
      }
      final note = entry.value.singleOrNull;
      final metadata = catalog.heads[entry.key]?.singleOrNull;
      final head = heads.singleOrNull;
      if (note != null &&
          !note.trashed &&
          !note.deletionConflict &&
          metadata != null &&
          metadata.kind == EntityKind.metadata &&
          !metadata.deleted &&
          metadata.revisionId == note.revision.revisionId) {
        final folder = _logicalFolder(catalog, note);
        final file = await _searchFileName(catalog, office, note, reserveBytes);
        final path = _logicalPath(folder, file);
        searchLocations[entry.key] = (file: file, path: path);
        if (head != null &&
            head.kind == EntityKind.markdown &&
            !head.deleted &&
            head.ownerNoteId == note.id) {
          if (note.documentKind == VaultDocumentKind.markdown) {
            searchMarkdownRevisions[entry.key] = head.revisionId;
          }
          final parsed = DataviewFrontmatter.parse(bodies[entry.key]!.single);
          if (parsed != null) {
            summaries[entry.key] = parsed;
            mentionSources[entry.key] = _MentionSource(
              markdown: bodies[entry.key]!.single,
              bytes: head.blobs['summary.md']!.length,
              aliases: parsed.aliases,
              metadataRevisionId: metadata.revisionId,
              markdownEntityId: head.entityId,
              markdownRevisionId: head.revisionId,
            );
            if (note.documentKind == VaultDocumentKind.markdown) {
              frontmatter[entry.key] = parsed;
              taskSources[entry.key] = (
                bodyStart: parsed.bodyStart,
                revisionId: head.revisionId,
              );
              locations[entry.key] = (folder: folder, path: path);
            }
          }
        }
      }
      final projected = <String>{};
      for (final note in entry.value.where(
        (n) =>
            const {'page', 'canvas', 'database'}.contains(n.documentKind.name),
      )) {
        final contentHeads =
            catalog.heads[note.inkEntityId] ?? const <RevisionRecord>[];
        if (contentHeads.length > 1) markdownConflicts.add(entry.key);
        for (final head in contentHeads.where((r) => !r.deleted)) {
          if (projected.add('${note.documentKind.name}/${head.revisionId}')) {
            final files = await readContent(head);
            final text = structuredDocumentText(note.documentKind.name, files);
            if (text.isNotEmpty) bodies[entry.key]!.add(text);
            final links = structuredDocumentLinkText(
              note.documentKind.name,
              files,
            );
            if (links.isNotEmpty) bodies[entry.key]!.add(links);
          }
        }
      }
    }
    final tags = <String, Set<String>>{};
    final bodyTags = <String, Set<String>>{};
    final links = <String, Map<String, KnowledgeLink>>{};
    final edges = <String, KnowledgeEdge>{};
    final unresolved = <String, UnresolvedKnowledgeLink>{};
    final rounds = bodies.values.fold<int>(
      1,
      (value, versions) => max(value, versions.length),
    );
    final hasPropertyLinks = frontmatter.values.any(
      (value) => value.propertyLinkMarkdown.isNotEmpty,
    );
    // Parse branches separately so an unfinished code fence in one branch does
    // not hide the valid links and tags from another branch.
    for (var round = 0; round < rounds + (hasPropertyLinks ? 1 : 0); round++) {
      final propertyRound = round == rounds;
      final response = native.invoke({
        'op': 'analyze_documents',
        'documents': [
          for (final id in titles.keys)
            {
              ...catalog.documents[id]!,
              // The property projection is read-only and has no body offsets.
              'markdown': propertyRound
                  ? frontmatter[id]?.propertyLinkMarkdown ?? ''
                  : round < bodies[id]!.length
                  ? bodies[id]![round]
                  : '',
            },
        ],
      });
      for (final value in response['documents'] as List) {
        final document = jsonObject(value);
        final id = document['id'] as String;
        if (!titles.containsKey(id))
          throw const FormatException('Unknown analyzed document');
        if (!propertyRound) {
          final roundTags = (document['tags'] as List).cast<String>();
          (tags[id] ??= {}).addAll(roundTags);
          if (round > 0 && (summaries[id]?.bodyStart ?? 0) > 0) {
            (bodyTags[id] ??= {}).addAll(roundTags);
          }
        }
        for (final value in document['links'] as List) {
          final link = jsonObject(value);
          final target = link['target'] as String;
          final anchor = link['anchor'] as String?;
          final targetId = link['targetId'] as String?;
          (links[id] ??= {})[jsonEncode([target, anchor, targetId])] =
              KnowledgeLink(target, anchor, targetId);
        }
      }
      for (final value in response['edges'] as List) {
        final edge = jsonObject(value);
        final from = edge['from'] as String;
        final to = edge['to'] as String;
        edges[jsonEncode([from, to])] = KnowledgeEdge(from, to);
      }
      for (final value in response['unresolved'] as List) {
        final link = jsonObject(value);
        final from = link['from'] as String;
        final target = link['target'] as String;
        unresolved[jsonEncode([from, target])] = UnresolvedKnowledgeLink(
          from,
          target,
        );
      }
    }
    final metadataTags = _normalizeDataviewTags(native, frontmatter.values);
    final headerDocuments = [
      for (final entry in summaries.entries)
        if (entry.value.bodyStart > 0 &&
            entry.value.bodyStart < bodies[entry.key]!.first.length)
          {
            'id': entry.key,
            'title': '',
            'markdown': bodies[entry.key]!.first.substring(
              entry.value.bodyStart,
            ),
          },
    ];
    if (headerDocuments.isNotEmpty) {
      final response = native.invoke({
        'op': 'analyze_documents',
        'documents': headerDocuments,
      });
      for (final value in response['documents'] as List) {
        final document = jsonObject(value);
        (bodyTags[document['id'] as String] ??= {}).addAll(
          (document['tags'] as List).cast<String>(),
        );
      }
    }
    return KnowledgeIndex._(
      native,
      catalog.documents,
      {
        for (final id in titles.keys)
          id: KnowledgeDocument(
            id: id,
            title: titles[id]!,
            markdown: bodies[id]!.join('\n\n---\n\n'),
            tags: tags[id] ?? {},
            links: (links[id] ?? {}).values.toList(),
            metadataConflict: grouped[id]!.length > 1,
            markdownConflict: markdownConflicts.contains(id),
            searchFileName: searchLocations[id]?.file,
            searchPath: searchLocations[id]?.path,
            searchTags: {
              ...((summaries[id]?.bodyStart ?? 0) > 0
                  ? bodyTags[id] ?? const <String>{}
                  : tags[id] ?? const <String>{}),
              ...?summaries[id]?.tags,
            },
            dataviewEligible: frontmatter.containsKey(id),
            dataviewProperties: frontmatter[id]?.properties ?? const {},
            dataviewTags: {
              for (final tag in frontmatter[id]?.tags ?? const <String>{})
                metadataTags[tag]!,
            },
            dataviewBodyTags: frontmatter[id]?.bodyStart == 0
                ? tags[id] ?? const {}
                : bodyTags[id] ?? const {},
            dataviewFolder: locations[id]?.folder,
            dataviewPath: locations[id]?.path,
            dataviewTaskSource: taskSources[id],
          ),
      },
      edges.values.toList(),
      unresolved.values.toList(),
      mentionSources,
      {
        for (final entry in searchMarkdownRevisions.entries)
          if (bodies[entry.key]!.length == 1) entry.key: entry.value,
      },
    );
  }

  bool ownsUnlinkedMention(KnowledgeUnlinkedMention mention) =>
      identical(mention._index, this);

  Future<KnowledgeUnlinkedMentions> unlinkedMentions(String targetId) async {
    const resultLimit = 128;
    const batchDocuments = 16;
    const batchBytes = 1024 * 1024;
    const scanDocuments = 512;
    const scanBytes = 8 * batchBytes;
    final target = _mentionSources[targetId];
    if (target == null) return KnowledgeUnlinkedMentions._([], false);
    final names = {documents[targetId]!.title.trim(), ...target.aliases};
    final control = RegExp(r'[\x00-\x1f\x7f-\x9f]');
    names.removeWhere(
      (name) => name.isEmpty || name.length > 255 || control.hasMatch(name),
    );
    if (names.isEmpty) return KnowledgeUnlinkedMentions._([], false);

    final mentions = <KnowledgeUnlinkedMention>[];
    final batch = <String, _MentionSource>{};
    var pendingBytes = 0;
    var scannedBytes = 0;
    var scannedDocuments = 0;
    var truncated = false;

    Future<void> scanBatch() async {
      await Future<void>.delayed(Duration.zero);
      final response = _native.invoke({
        'op': 'find_unlinked_mentions',
        'targetId': targetId,
        'names': names.toList(),
        'documents': [
          for (final entry in batch.entries)
            {'id': entry.key, 'markdown': entry.value.markdown},
        ],
        'limit': resultLimit - mentions.length,
      });
      for (final value in response['mentions'] as List) {
        final match = jsonObject(value);
        final id = match['sourceId'] as String;
        final source = batch[id];
        final start = match['start'] as int;
        final end = match['end'] as int;
        final text = match['text'] as String;
        if (source == null ||
            start < 0 ||
            start >= end ||
            end > source.markdown.length ||
            source.markdown.substring(start, end) != text) {
          throw const FormatException('Invalid unlinked mention range');
        }
        mentions.add(
          KnowledgeUnlinkedMention._(
            this,
            source,
            target,
            targetId: targetId,
            sourceId: id,
            text: text,
            snippet: _mentionSnippet(source.markdown, start, end),
            start: start,
            end: end,
          ),
        );
      }
      truncated |= response['truncated'] as bool;
      batch.clear();
      pendingBytes = 0;
    }

    for (final entry in _mentionSources.entries) {
      final source = entry.value;
      if (entry.key == targetId || source.markdown.isEmpty) continue;
      if (source.bytes > batchBytes) {
        truncated = true;
        continue;
      }
      if (scannedDocuments == scanDocuments ||
          scannedBytes + source.bytes > scanBytes) {
        truncated = true;
        break;
      }
      if (batch.length == batchDocuments ||
          pendingBytes + source.bytes > batchBytes) {
        await scanBatch();
        if (mentions.length == resultLimit) {
          truncated = true;
          break;
        }
      }
      batch[entry.key] = source;
      pendingBytes += source.bytes;
      scannedDocuments++;
      scannedBytes += source.bytes;
    }
    if (batch.isNotEmpty) await scanBatch();
    return KnowledgeUnlinkedMentions._(mentions, truncated);
  }

  static String _mentionSnippet(String markdown, int start, int end) {
    var from = max(0, start - 56);
    var to = min(markdown.length, end + 56);
    final previousBreak = markdown.substring(from, start).lastIndexOf('\n');
    final nextBreak = markdown.substring(end, to).indexOf('\n');
    final leadingEllipsis =
        previousBreak < 0 && from > 0 && markdown.codeUnitAt(from - 1) != 0x0a;
    final trailingEllipsis =
        nextBreak < 0 &&
        to < markdown.length &&
        markdown.codeUnitAt(to) != 0x0a;
    if (previousBreak >= 0) from += previousBreak + 1;
    if (nextBreak >= 0) to = end + nextBreak;
    bool insideSurrogatePair(int offset) =>
        offset < markdown.length &&
        (markdown.codeUnitAt(offset) & 0xfc00) == 0xdc00;
    if (insideSurrogatePair(from)) from--;
    if (insideSurrogatePair(to)) to++;
    final line = markdown.substring(from, to).trim();
    return '${leadingEllipsis ? '…' : ''}$line${trailingEllipsis ? '…' : ''}';
  }

  List<KnowledgeDocument> backlinks(String noteId) {
    final sources = edges
        .where((edge) => edge.to == noteId)
        .map((edge) => edge.from)
        .toSet();
    return _sorted(
      documents.values.where((document) => sources.contains(document.id)),
    );
  }

  KnowledgeLocalGraph localGraph(
    String centerId, {
    int depth = 1,
    bool incoming = true,
    bool outgoing = true,
    bool interlinks = false,
  }) {
    if (depth < 1 || depth > 5) throw RangeError.range(depth, 1, 5, 'depth');
    final center = documents[centerId];
    if (center == null) return KnowledgeLocalGraph._(const [], const []);
    if (!incoming && !outgoing)
      return KnowledgeLocalGraph._([center], const []);

    final adjacent = <String, List<(String, KnowledgeEdge)>>{};
    for (final edge in edges) {
      if (edge.from == edge.to ||
          !documents.containsKey(edge.from) ||
          !documents.containsKey(edge.to)) {
        continue;
      }
      if (outgoing) (adjacent[edge.from] ??= []).add((edge.to, edge));
      if (incoming) (adjacent[edge.to] ??= []).add((edge.from, edge));
    }

    final visible = {centerId};
    final traversed = <KnowledgeEdge>{};
    var frontier = [centerId];
    for (var hop = 0; hop < depth && frontier.isNotEmpty; hop++) {
      final next = <String>{};
      for (final id in frontier) {
        for (final (neighbor, edge)
            in adjacent[id] ?? const <(String, KnowledgeEdge)>[]) {
          if (visible.contains(neighbor)) continue;
          next.add(neighbor);
          if (!interlinks) traversed.add(edge);
        }
      }
      // Admit the whole layer together so shared neighbors keep every route.
      frontier = next.toList()..sort();
      visible.addAll(frontier);
    }

    return KnowledgeLocalGraph._(
      visible.map((id) => documents[id]!),
      interlinks
          ? edges.where(
              (edge) =>
                  edge.from != edge.to &&
                  visible.contains(edge.from) &&
                  visible.contains(edge.to),
            )
          : edges.where(traversed.contains),
    );
  }

  List<KnowledgeSearchResult> search(
    String query, {
    bool expression = false,
    bool includeBodyMatches = false,
  }) {
    final result = _native.invoke({
      'op': expression ? 'search_expression' : 'search',
      'query': query,
      if (includeBodyMatches) 'includeBodyMatch': true,
      'documents': [
        for (final document in documents.values)
          if (expression)
            {
              ..._requestDocument(document),
              'file': document.searchFileName,
              'path': document.searchPath,
              'tags': document.searchTags.toList(),
            }
          else
            _requestDocument(document),
      ],
    });
    return (result['matches'] as List).map((value) {
      final match = jsonObject(value);
      final id = match['id'] as String;
      return KnowledgeSearchResult(
        id,
        match['title'] as String,
        match['snippet'] as String,
        match['score'] as int,
        bodyMatch: includeBodyMatches
            ? _searchBodyMatch(id, match['bodyMatch'])
            : null,
      );
    }).toList();
  }

  KnowledgeBodyMatch? _searchBodyMatch(String id, Object? value) {
    final revision = _searchMarkdownRevisions[id];
    if (revision == null ||
        value is! Map ||
        value['start'] is! int ||
        value['end'] is! int ||
        value['text'] is! String) {
      return null;
    }
    final markdown = documents[id]!.markdown;
    final start = value['start'] as int;
    final end = value['end'] as int;
    final text = value['text'] as String;
    if (start < 0 ||
        end <= start ||
        end > markdown.length ||
        _splitsSurrogatePair(markdown, start) ||
        _splitsSurrogatePair(markdown, end) ||
        markdown.substring(start, end) != text) {
      return null;
    }

    var excerptStart = max(0, start - 24);
    if (_splitsSurrogatePair(markdown, excerptStart)) excerptStart--;
    var excerptEnd = min(markdown.length, excerptStart + 178);
    if (_splitsSurrogatePair(markdown, excerptEnd)) excerptEnd--;
    return KnowledgeBodyMatch(
      markdownRevisionId: revision,
      start: start,
      end: end,
      text: text,
      excerpt:
          '${excerptStart == 0 ? '' : '…'}'
          '${markdown.substring(excerptStart, excerptEnd)}'
          '${excerptEnd == markdown.length ? '' : '…'}',
    );
  }

  static bool _splitsSurrogatePair(String text, int offset) {
    if (offset == 0 || offset == text.length) return false;
    final left = text.codeUnitAt(offset - 1);
    final right = text.codeUnitAt(offset);
    return left >= 0xd800 &&
        left <= 0xdbff &&
        right >= 0xdc00 &&
        right <= 0xdfff;
  }

  KnowledgeTarget? resolveWikiLink(String value, {String? fromNoteId}) {
    String target;
    String? anchor;
    final wiki = value.startsWith('inkwiki:');
    if (wiki) {
      final uri = Uri.tryParse(value);
      if (uri == null ||
          uri.scheme != 'inkwiki' ||
          uri.hasAuthority ||
          uri.hasQuery)
        return null;
      try {
        target = Uri.decodeComponent(uri.path);
        anchor = uri.hasFragment ? Uri.decodeComponent(uri.fragment) : null;
      } on FormatException {
        return null;
      }
    } else {
      final hash = value.indexOf('#');
      target = hash < 0 ? value : value.substring(0, hash);
      anchor = hash < 0 ? null : value.substring(hash + 1);
    }
    if ('$target${anchor ?? ''}'.contains(RegExp(r'[\r\n\x00]'))) return null;
    if (target.isEmpty &&
        (fromNoteId == null || anchor == null || anchor.isEmpty))
      return null;
    if (fromNoteId != null && !documents.containsKey(fromNoteId)) return null;
    final probe = fromNoteId ?? 'knowledge-resolution-probe';
    final destination =
        'inkwiki:${Uri.encodeComponent(target)}${anchor == null ? '' : '#${Uri.encodeComponent(anchor)}'}';
    return _resolveProbe('[link](<$destination>)', probe);
  }

  KnowledgeTarget? resolveMarkdownLink(
    String href, {
    required String fromNoteId,
  }) {
    if (!documents.containsKey(fromNoteId) ||
        href.contains(RegExp(r'[\r\n\x00]')))
      return null;
    final uri = Uri.tryParse(href);
    if (uri == null || uri.hasAuthority || uri.hasQuery || uri.hasScheme)
      return null;
    final destination = href.replaceAll('<', '%3C').replaceAll('>', '%3E');
    return _resolveProbe('[link](<$destination>)', fromNoteId);
  }

  KnowledgeTarget? _resolveProbe(String markdown, String probe) {
    final response = _native.invoke({
      'op': 'analyze_documents',
      'documents': [
        for (final document in documents.values)
          {
            ..._lookup[document.id]!,
            'markdown': document.id == probe ? markdown : '',
          },
        if (!documents.containsKey(probe))
          {'id': probe, 'title': '', 'markdown': markdown},
      ],
    });
    final result = (response['documents'] as List)
        .map(jsonObject)
        .singleWhere((item) => item['id'] == probe);
    final links = result['links'] as List;
    if (links.length != 1) return null;
    final link = jsonObject(links.single);
    final id = link['targetId'] as String?;
    if (id == null || !documents.containsKey(id)) return null;
    final anchor = link['anchor'] as String?;
    return KnowledgeTarget(
      id,
      anchor == '' ? null : anchor,
      attachmentName: link['attachmentName'] as String?,
    );
  }
}

Map<String, String> _normalizeDataviewTags(
  InkVaultNative native,
  Iterable<DataviewFrontmatter> frontmatter,
) {
  final tags = {for (final data in frontmatter) ...data.tags}.toList();
  final normalized = <String, String>{};
  for (var start = 0; start < tags.length; start += 1024) {
    final batch = tags.sublist(start, min(start + 1024, tags.length));
    final response = native.invoke({
      'op': 'normalize_workspace_segments',
      'segments': batch,
    });
    final values = (response['segments'] as List).cast<String>();
    for (var i = 0; i < batch.length; i++) {
      normalized[batch[i]] = values[i];
    }
  }
  return normalized;
}

String? _logicalFolder(KnowledgeCatalog catalog, VaultNote note) {
  // Equal paths can conceal different folder heads with the same title.
  final seen = <String>{};
  final ancestors = <String>[];
  var id = note.folderId;
  while (id != null) {
    if (!seen.add(id) || seen.length > 64) return null;
    final head = catalog.heads[id]?.singleOrNull;
    final branch = catalog.folders[id]?.singleOrNull;
    if (branch == null ||
        head == null ||
        branch.revision.revisionId != head.revisionId ||
        branch.trashed ||
        branch.deletionConflict ||
        !isObsidianPathSegment(branch.title)) {
      return null;
    }
    ancestors.add(branch.title);
    id = branch.parentId;
  }
  return ancestors.reversed.join('/');
}

String? _logicalPath(String? folder, String? file) {
  if (folder == null || file == null) return null;
  return folder.isEmpty ? file : '$folder/$file';
}

Future<String?> _searchFileName(
  KnowledgeCatalog catalog,
  OfficeDocumentStore office,
  VaultNote note,
  void Function(int) reserveBytes,
) async {
  final String? file;
  switch (note.documentKind) {
    case VaultDocumentKind.pdf:
    case VaultDocumentKind.image:
    case VaultDocumentKind.office:
      final source = catalog.heads[note.sourceEntityId]?.singleOrNull;
      if (source == null ||
          source.deleted ||
          source.kind != EntityKind.attachment ||
          source.ownerNoteId != note.id) {
        return null;
      }
      if (note.documentKind == VaultDocumentKind.office) {
        reserveBytes(source.blobs['edition.json']?.length ?? 0);
        file = await office.readOriginalFileName(note, source);
      } else {
        file = source.blobs.keys.singleOrNull;
      }
    case VaultDocumentKind.markdown:
      file = isObsidianPathSegment(note.title) ? '${note.title}.md' : null;
    case VaultDocumentKind.canvas:
      file =
          note.obsidianAttachmentName ??
          (note.title.toLowerCase().endsWith('.canvas')
              ? note.title
              : '${note.title}.canvas');
    case VaultDocumentKind.handwriting:
    case VaultDocumentKind.infinite:
    case VaultDocumentKind.page:
    case VaultDocumentKind.database:
      file = note.title;
  }
  return file != null && isObsidianPathSegment(file) ? file : null;
}

Map<String, Object> _requestDocument(KnowledgeDocument document) => {
  'id': document.id,
  'title': document.title,
  'markdown': document.markdown,
};

List<KnowledgeDocument> _sorted(Iterable<KnowledgeDocument> documents) =>
    documents.toList()..sort((a, b) {
      final title = a.title.compareTo(b.title);
      return title == 0 ? a.id.compareTo(b.id) : title;
    });

Map<String, List<KnowledgeDocument>> _tagIndex(
  Iterable<KnowledgeDocument> documents,
) {
  final result = <String, List<KnowledgeDocument>>{};
  for (final document in documents) {
    for (final tag in document.tags) {
      (result[tag] ??= []).add(document);
    }
  }
  return Map.unmodifiable({
    for (final tag in result.keys.toList()..sort())
      tag: List<KnowledgeDocument>.unmodifiable(_sorted(result[tag]!)),
  });
}
