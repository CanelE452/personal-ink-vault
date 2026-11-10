import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:ink_vault_core/ink_vault_core.dart'
    show jsonObject, validateHash, validateId;
import 'package:saber/data/vault/block_page_document.dart';

enum DiscussionAnchorKind { page, block, quote }

enum DiscussionAnchorStatus {
  attached,
  missingPage,
  missingBlock,
  changedQuote,
}

final class DiscussionAnchor {
  const new _(
    this.kind,
    this.pageId, {
    this.blockId,
    this.startUtf16,
    this.endUtf16,
    this.quoteText,
    this.blockTextSha256,
  });

  factory page({required String pageId}) {
    validateId(pageId);
    return DiscussionAnchor._(DiscussionAnchorKind.page, pageId);
  }

  factory block({
    required String pageId,
    required BlockPageDocument document,
    required String blockId,
  }) {
    validateId(pageId);
    _existingBlock(document, blockId);
    return DiscussionAnchor._(
      DiscussionAnchorKind.block,
      pageId,
      blockId: blockId,
    );
  }

  factory quote({
    required String pageId,
    required BlockPageDocument document,
    required String blockId,
    required int startUtf16,
    required int endUtf16,
  }) {
    validateId(pageId);
    final block = _existingBlock(document, blockId);
    final text = block.text;
    if (!supportsQuote(block) ||
        startUtf16 < 0 ||
        endUtf16 <= startUtf16 ||
        endUtf16 > text.length ||
        endUtf16 - startUtf16 > maxQuoteUtf16 ||
        !_wellFormedUtf16(text) ||
        !_graphemeBoundaries(text, startUtf16, endUtf16)) {
      throw const FormatException('Invalid discussion quote selection');
    }
    final quote = text.substring(startUtf16, endUtf16);
    if (quote.trim().isEmpty) {
      throw const FormatException('Discussion quote is blank');
    }
    return DiscussionAnchor._(
      DiscussionAnchorKind.quote,
      pageId,
      blockId: blockId,
      startUtf16: startUtf16,
      endUtf16: endUtf16,
      quoteText: quote,
      blockTextSha256: _textSha256(text),
    );
  }

  factory fromJson(Object? value) {
    final json = jsonObject(value);
    final kind = switch (json['kind']) {
      'page' => DiscussionAnchorKind.page,
      'block' => DiscussionAnchorKind.block,
      'quote' => DiscussionAnchorKind.quote,
      _ => throw const FormatException('Unknown discussion anchor kind'),
    };
    final pageId = json['pageId'];
    final fields = {
      'version',
      'kind',
      'pageId',
      if (kind != DiscussionAnchorKind.page) 'blockId',
      if (kind == DiscussionAnchorKind.quote) ...{
        'startUtf16',
        'endUtf16',
        'quote',
        'blockTextSha256',
      },
    };
    if (json['version'] is! int ||
        json['version'] != 1 ||
        pageId is! String ||
        fields.length != json.length ||
        !fields.every(json.containsKey)) {
      throw const FormatException('Invalid discussion anchor object');
    }
    validateId(pageId);
    if (kind == DiscussionAnchorKind.page) {
      return DiscussionAnchor._(kind, pageId);
    }
    final blockId = json['blockId'];
    if (blockId is! String) throw const FormatException('Invalid block ID');
    validateId(blockId);
    if (kind == DiscussionAnchorKind.block) {
      return DiscussionAnchor._(kind, pageId, blockId: blockId);
    }

    final start = json['startUtf16'];
    final end = json['endUtf16'];
    final quote = json['quote'];
    final hash = json['blockTextSha256'];
    if (start is! int ||
        end is! int ||
        start < 0 ||
        end <= start ||
        quote is! String ||
        quote.length != end - start ||
        quote.length > maxQuoteUtf16 ||
        quote.trim().isEmpty ||
        !_wellFormedUtf16(quote) ||
        hash is! String) {
      throw const FormatException('Invalid discussion quote');
    }
    validateHash(hash);
    return DiscussionAnchor._(
      kind,
      pageId,
      blockId: blockId,
      startUtf16: start,
      endUtf16: end,
      quoteText: quote,
      blockTextSha256: hash,
    );
  }

  static const maxQuoteUtf16 = 512;

  static bool supportsQuote(BlockPageBlock block) =>
      _quoteTypes.contains(block.type);

  final DiscussionAnchorKind kind;
  final String pageId;
  final String? blockId;
  final int? startUtf16;
  final int? endUtf16;
  final String? quoteText;
  final String? blockTextSha256;

  Map<String, Object?> toJson() => {
    'version': 1,
    'kind': kind.name,
    'pageId': pageId,
    if (kind != DiscussionAnchorKind.page) 'blockId': blockId,
    if (kind == DiscussionAnchorKind.quote) ...{
      'startUtf16': startUtf16,
      'endUtf16': endUtf16,
      'quote': quoteText,
      'blockTextSha256': blockTextSha256,
    },
  };

  DiscussionAnchorStatus resolve({
    required String pageId,
    required BlockPageDocument? document,
  }) {
    if (pageId != this.pageId || document == null) {
      return DiscussionAnchorStatus.missingPage;
    }
    if (kind == DiscussionAnchorKind.page) {
      return DiscussionAnchorStatus.attached;
    }
    final block = _findBlock(document.blocks, blockId!);
    if (block == null) return DiscussionAnchorStatus.missingBlock;
    if (kind == DiscussionAnchorKind.block) {
      return DiscussionAnchorStatus.attached;
    }

    final start = startUtf16!;
    final end = endUtf16!;
    final text = block.text;
    if (!supportsQuote(block) ||
        end > text.length ||
        !_wellFormedUtf16(text) ||
        _textSha256(text) != blockTextSha256 ||
        !_graphemeBoundaries(text, start, end) ||
        text.substring(start, end) != quoteText) {
      return DiscussionAnchorStatus.changedQuote;
    }
    return DiscussionAnchorStatus.attached;
  }
}

const _quoteTypes = {
  'paragraph',
  'heading1',
  'heading2',
  'heading3',
  'todo',
  'bullet',
  'numbered',
  'toggle',
  'quote',
  'callout',
};

BlockPageBlock _existingBlock(BlockPageDocument document, String id) {
  validateId(id);
  final block = _findBlock(document.blocks, id);
  if (block == null) throw const FormatException('Discussion block is missing');
  return block;
}

BlockPageBlock? _findBlock(Iterable<BlockPageBlock> blocks, String id) {
  for (final block in blocks) {
    if (block.id == id) return block;
    final child = _findBlock(block.children, id);
    if (child != null) return child;
  }
  return null;
}

bool _graphemeBoundaries(String text, int start, int end) {
  var offset = 0;
  var startsAtBoundary = start == 0;
  for (final character in text.characters) {
    offset += character.length;
    if (offset >= end) return offset == end && startsAtBoundary;
    if (offset == start) startsAtBoundary = true;
  }
  return false;
}

String _textSha256(String text) => sha256.convert(utf8.encode(text)).toString();

// UTF-8 encoding replaces lone surrogates, which could otherwise share a hash.
bool _wellFormedUtf16(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i == text.length) return false;
      final low = text.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) return false;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}
