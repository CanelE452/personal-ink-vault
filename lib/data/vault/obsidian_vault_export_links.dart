import 'dart:convert';

import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/dataview_frontmatter.dart';
import 'package:saber/data/vault/knowledge_catalog.dart';

Map<String, String> portableObsidianMarkdown({
  required InkVaultNative native,
  required KnowledgeCatalog catalog,
  required Map<String, String> pathsById,
  required Map<String, String> markdownPathsById,
  required Map<String, String> markdownById,
  required List<String> warnings,
}) {
  const batchBytes = 8 * 1024 * 1024;
  const propertyBatchBytes = 512 * 1024;
  final result = Map<String, String>.of(markdownById);
  final paths = {
    for (final entry in pathsById.entries)
      entry.key: {
        'primary': entry.value,
        'markdown': ?markdownPathsById[entry.key],
      },
  };
  final batch = <String, String>{};
  final headers = <String, DataviewFrontmatter>{};
  var bytes = 0, propertyBytes = 0;
  void warn(String id, String message) {
    if (warnings.length < 1000) {
      warnings.add('${markdownPathsById[id]} · $message');
    } else if (warnings.length == 1000) {
      warnings.add('이 외에 경로를 확인할 링크가 더 있습니다.');
    }
  }

  void rewriteBatch() {
    if (batch.isEmpty) return;
    final response = native.invoke({
      'op': 'portable_obsidian_links',
      'paths': paths,
      'properties': {
        for (final entry in headers.entries)
          entry.key: [for (final link in entry.value.propertyLinks) link.text],
      },
      'documents': [
        for (final document in catalog.documents.entries)
          {...document.value, 'markdown': batch[document.key] ?? ''},
      ],
    });
    final documents = response['documents'];
    if (documents is! Map || documents.length != batch.length) {
      throw const FormatException('잘못된 Obsidian 링크 처리 결과');
    }
    for (final id in batch.keys) {
      final document = documents[id];
      if (document is! Map ||
          document['markdown'] is! String ||
          document['properties'] is! List ||
          document['warnings'] is! List) {
        throw const FormatException('잘못된 Obsidian Markdown 처리 결과');
      }
      final text = document['markdown'] as String;
      final header = headers[id];
      if (header == null) {
        result[id] = text;
      } else {
        final values = (document['properties'] as List).cast<String>();
        try {
          result[id] = _rewritePortableProperties(text, header, values);
        } on StateError {
          result[id] = text;
          warn(id, '기존 형식을 유지할 수 없는 YAML 속성 링크가 있습니다.');
        }
      }
      for (final warning in (document['warnings'] as List).cast<String>()) {
        warn(id, '링크 경로 확인 필요 · $warning');
      }
    }
    batch.clear();
    headers.clear();
    bytes = 0;
    propertyBytes = 0;
  }

  for (final entry in markdownById.entries) {
    if (entry.value.isEmpty) continue;
    final length = utf8.encode(entry.value).length;
    if (length > batchBytes) {
      throw const FormatException('Obsidian Markdown 내보내기 크기 한도 초과');
    }
    final header = DataviewFrontmatter.parse(
      entry.value,
      includePropertySpans: true,
    );
    final links = header?.propertyLinks ?? const <FrontmatterPropertyLink>[];
    final yamlBytes = links.fold<int>(
      0,
      (total, link) => total + utf8.encode(link.text).length,
    );
    final canRewriteHeader =
        links.isNotEmpty &&
        links.length <= 512 &&
        yamlBytes <= propertyBatchBytes;
    if (links.isNotEmpty && !canRewriteHeader) {
      warn(entry.key, 'YAML 속성 링크 개수 또는 크기 한도를 넘었습니다.');
    }
    if (length > batchBytes - bytes ||
        canRewriteHeader && yamlBytes > propertyBatchBytes - propertyBytes) {
      rewriteBatch();
    }
    batch[entry.key] = entry.value;
    bytes += length;
    if (canRewriteHeader) {
      headers[entry.key] = header!;
      propertyBytes += yamlBytes;
    }
  }
  rewriteBatch();
  return result;
}

String _rewritePortableProperties(
  String text,
  DataviewFrontmatter header,
  List<String> values,
) {
  final links = header.propertyLinks;
  if (links.length != values.length) {
    throw const FormatException('잘못된 Obsidian 속성 링크 처리 결과');
  }
  var updated = text;
  var boundary = header.bodyStart;
  for (var i = links.length - 1; i >= 0; i--) {
    final link = links[i];
    if (link.end > boundary) throw StateError('YAML links overlap');
    boundary = link.start;
    if (values[i] == link.text) continue;
    updated = updated.replaceRange(
      link.start,
      link.end,
      link.encodeReplacement(text.substring(link.start, link.end), values[i]),
    );
  }
  if (updated == text) return text;
  final verified = DataviewFrontmatter.parse(
    updated,
    includePropertySpans: true,
  )?.propertyLinks;
  if (verified == null ||
      verified.length != values.length ||
      verified.indexed.any((entry) => entry.$2.text != values[entry.$1])) {
    throw StateError('Rewriting changed the recognized YAML link values');
  }
  return updated;
}
