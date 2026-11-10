import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:saber/data/vault/note_link.dart';

enum InlineMark { bold, italic, underline, strikethrough, code, highlight }

class BlockInlineRun {
  new({
    required this.start,
    required this.end,
    Set<InlineMark> marks = const {},
    this.link,
  }) : marks = Set.unmodifiable(marks),
       _extra = const {};

  new _(this.start, this.end, Set<InlineMark> marks, this.link, this._extra)
    : marks = Set.unmodifiable(marks);

  final int start;
  final int end;
  final Set<InlineMark> marks;
  final String? link;
  final Map<String, dynamic> _extra;

  Map<String, dynamic> _toJson() => {
    ..._copy(_extra),
    'start': start,
    'end': end,
    'marks': [
      for (final mark in InlineMark.values)
        if (marks.contains(mark)) mark.name,
    ],
    if (link != null) 'link': link,
  };
}

class BlockInlineSegment {
  new({required this.text, Set<InlineMark> marks = const {}, this.link})
    : marks = Set.unmodifiable(marks);

  final String text;
  final Set<InlineMark> marks;
  final String? link;
}

class BlockInlineText {
  new _(this.text, List<BlockInlineRun> runs, this._extra)
    : runs = List.unmodifiable(_merge(runs));

  factory plain(String text) => BlockInlineText._(text, [], {});

  factory fromJson(Map<String, dynamic> json, {required String text}) {
    final raw = _copy(json);
    if (raw.remove('format') != format ||
        raw.remove('textSha256') != _digest(text)) {
      throw const FormatException('Inline text does not match its source');
    }
    final encoded = raw.remove('runs');
    if (encoded is! List) throw const FormatException('Invalid inline runs');
    final boundaries = _boundaries(text).toSet();
    final runs = <BlockInlineRun>[];
    var previousEnd = 0;
    for (final value in encoded) {
      if (value is! Map) throw const FormatException('Invalid inline run');
      final run = _copy(Map<String, dynamic>.from(value));
      final start = run.remove('start'), end = run.remove('end');
      final marks = run.remove('marks'), link = run.remove('link');
      if (start is! int ||
          end is! int ||
          start < previousEnd ||
          start >= end ||
          !boundaries.contains(start) ||
          !boundaries.contains(end) ||
          marks is! List ||
          marks.any((mark) => mark is! String) ||
          marks.toSet().length != marks.length ||
          marks.any(
            (mark) => !InlineMark.values.any((known) => known.name == mark),
          ) ||
          link != null && (link is! String || !_safeLink(link))) {
        throw const FormatException('Invalid inline range, style or link');
      }
      previousEnd = end;
      runs.add(
        BlockInlineRun._(
          start,
          end,
          {for (final mark in marks) InlineMark.values.byName(mark as String)},
          link as String?,
          run,
        ),
      );
    }
    return BlockInlineText._(text, runs, raw);
  }

  static const format = 'personal-ink-inline-1';
  final String text;
  final List<BlockInlineRun> runs;
  final Map<String, dynamic> _extra;

  List<BlockInlineSegment> get segments {
    final result = <BlockInlineSegment>[];
    var offset = 0;
    for (final run in runs) {
      if (offset < run.start) {
        result.add(BlockInlineSegment(text: text.substring(offset, run.start)));
      }
      result.add(
        BlockInlineSegment(
          text: text.substring(run.start, run.end),
          marks: run.marks,
          link: run.link,
        ),
      );
      offset = run.end;
    }
    if (offset < text.length)
      result.add(BlockInlineSegment(text: text.substring(offset)));
    return List.unmodifiable(result);
  }

  Map<String, dynamic> toJson() => {
    ..._copy(_extra),
    'format': format,
    'textSha256': _digest(text),
    'runs': [for (final run in runs) run._toJson()],
  };

  BlockInlineText toggleMark(int start, int end, InlineMark mark) {
    final range = _range(start, end);
    final remove = hasMark(range.$1, range.$2, mark);
    return _edit(range.$1, range.$2, (run, from, to) {
      final marks = <InlineMark>{...?run?.marks};
      if (remove) {
        marks.remove(mark);
      } else {
        marks.add(mark);
      }
      return BlockInlineRun._(from, to, marks, run?.link, run?._extra ?? {});
    });
  }

  BlockInlineText setLink(int start, int end, String? link) {
    if (link != null && !_safeLink(link))
      throw const FormatException('Unsafe inline link');
    final range = _range(start, end);
    return _edit(
      range.$1,
      range.$2,
      (run, from, to) =>
          BlockInlineRun._(from, to, run?.marks ?? {}, link, run?._extra ?? {}),
    );
  }

  BlockInlineText clearFormatting(int start, int end) {
    final range = _range(start, end);
    return _edit(
      range.$1,
      range.$2,
      (run, from, to) =>
          BlockInlineRun._(from, to, {}, null, run?._extra ?? {}),
    );
  }

  bool hasMark(int start, int end, InlineMark mark) {
    final range = _range(start, end);
    if (range.$1 == range.$2) return false;
    var covered = range.$1;
    for (final run in runs) {
      if (run.end <= covered) continue;
      if (run.start > covered || !run.marks.contains(mark)) return false;
      covered = run.end;
      if (covered >= range.$2) return true;
    }
    return false;
  }

  BlockInlineText replaceText(
    String nextText, {
    int? selectionStart,
    int? selectionEnd,
  }) {
    if (nextText == text) return this;
    final old = text.characters.toList(), next = nextText.characters.toList();
    final oldOffsets = _offsets(old), nextOffsets = _offsets(next);
    var prefix = 0, suffix = 0;
    var usedSelection = false;
    if (selectionStart != null &&
        selectionEnd != null &&
        selectionStart >= 0 &&
        selectionEnd >= selectionStart &&
        selectionEnd <= text.length &&
        oldOffsets.contains(selectionStart) &&
        oldOffsets.contains(selectionEnd)) {
      final tail = text.substring(selectionEnd);
      final head = text.substring(0, selectionStart);
      if (nextText.length >= head.length + tail.length &&
          nextText.startsWith(head) &&
          nextText.endsWith(tail) &&
          nextOffsets.contains(head.length) &&
          nextOffsets.contains(nextText.length - tail.length)) {
        prefix = oldOffsets.indexOf(selectionStart);
        suffix = old.length - oldOffsets.indexOf(selectionEnd);
        usedSelection = true;
      }
    }
    if (!usedSelection) {
      while (prefix < old.length &&
          prefix < next.length &&
          old[prefix] == next[prefix]) {
        prefix++;
      }
      while (suffix < old.length - prefix &&
          suffix < next.length - prefix &&
          old[old.length - suffix - 1] == next[next.length - suffix - 1]) {
        suffix++;
      }
    }
    final pieces = <(int, int, int)>[];
    if (prefix > 0) pieces.add((0, 0, prefix));
    if (usedSelection) {
      if (suffix > 0)
        pieces.add((old.length - suffix, next.length - suffix, suffix));
    } else {
      _matchingPieces(
        old,
        next,
        prefix,
        old.length - suffix,
        prefix,
        next.length - suffix,
        pieces,
      );
      if (suffix > 0)
        pieces.add((old.length - suffix, next.length - suffix, suffix));
    }
    final rebuilt = <BlockInlineRun>[];
    var oldCursor = 0, nextCursor = 0;
    void insertUntil(int nextEnd, int oldEnd) {
      if (nextEnd > nextCursor) {
        final position = oldOffsets[oldCursor];
        final replacing = oldEnd > oldCursor;
        final inherited = _styleAt(
          replacing || position == 0 ? position : position - 1,
        );
        final link =
            inherited != null &&
                (replacing
                    ? oldOffsets[oldEnd] <= inherited.end
                    : position > inherited.start && position < inherited.end)
            ? inherited.link
            : null;
        if (inherited != null)
          rebuilt.add(
            BlockInlineRun._(
              nextOffsets[nextCursor],
              nextOffsets[nextEnd],
              inherited.marks,
              link,
              inherited._extra,
            ),
          );
      }
      oldCursor = oldEnd;
      nextCursor = nextEnd;
    }

    for (final piece in pieces) {
      insertUntil(piece.$2, piece.$1);
      final oldStart = oldOffsets[piece.$1],
          oldEnd = oldOffsets[piece.$1 + piece.$3];
      final delta = nextOffsets[piece.$2] - oldStart;
      for (final run in runs) {
        final from = run.start > oldStart ? run.start : oldStart;
        final to = run.end < oldEnd ? run.end : oldEnd;
        if (from < to)
          rebuilt.add(
            BlockInlineRun._(
              from + delta,
              to + delta,
              run.marks,
              run.link,
              run._extra,
            ),
          );
      }
      oldCursor = piece.$1 + piece.$3;
      nextCursor = piece.$2 + piece.$3;
    }
    insertUntil(next.length, old.length);
    return BlockInlineText._(nextText, rebuilt, _extra);
  }

  String toMarkdown({String Function(String)? linkDestination}) {
    final parts = segments;
    var htmlStyles = false;
    for (var index = 0; index < parts.length; index++) {
      final segment = parts[index];
      if (segment.marks.isNotEmpty &&
          (segment.text.trim() != segment.text ||
              index > 0 && parts[index - 1].marks.isNotEmpty))
        htmlStyles = true;
    }
    return parts.map((segment) {
      return segment.text
          .split('\n')
          .map((line) {
            if (line.isEmpty) return '';
            if (htmlStyles || segment.link != null)
              return _segmentHtml(
                line,
                segment.marks,
                segment.link,
                linkDestination,
                markdownEntities: true,
              );
            var value = segment.marks.contains(InlineMark.code)
                ? _code(line)
                : _markdown(line);
            if (segment.marks.contains(InlineMark.bold)) value = '**$value**';
            if (segment.marks.contains(InlineMark.italic)) value = '*$value*';
            if (segment.marks.contains(InlineMark.underline))
              value = '<u>$value</u>';
            if (segment.marks.contains(InlineMark.strikethrough))
              value = '~~$value~~';
            if (segment.marks.contains(InlineMark.highlight))
              value = '<mark>$value</mark>';
            return value;
          })
          .join('\n');
    }).join();
  }

  String toHtml({String Function(String)? linkDestination}) => segments
      .map(
        (segment) => _segmentHtml(
          segment.text,
          segment.marks,
          segment.link,
          linkDestination,
          lineBreaks: true,
        ),
      )
      .join();

  static String _segmentHtml(
    String text,
    Set<InlineMark> marks,
    String? link,
    String Function(String)? linkDestination, {
    bool lineBreaks = false,
    bool markdownEntities = false,
  }) {
    var value = markdownEntities ? _markdownHtml(text) : _html(text);
    if (lineBreaks) value = value.replaceAll('\n', '<br>');
    for (final (mark, tag) in [
      (InlineMark.code, 'code'),
      (InlineMark.bold, 'strong'),
      (InlineMark.italic, 'em'),
      (InlineMark.underline, 'u'),
      (InlineMark.strikethrough, 'del'),
      (InlineMark.highlight, 'mark'),
    ]) {
      if (marks.contains(mark)) value = '<$tag>$value</$tag>';
    }
    final destination = _destination(link, linkDestination);
    return destination == null
        ? value
        : '<a href="${_html(destination)}">$value</a>';
  }

  (int, int) _range(int start, int end) {
    if (start < 0 || end < start || end > text.length)
      throw RangeError('Invalid inline selection');
    if (start == end) return (start, end);
    final boundaries = _boundaries(text);
    return (
      boundaries.lastWhere((offset) => offset <= start),
      boundaries.firstWhere((offset) => offset >= end),
    );
  }

  BlockInlineRun? _styleAt(int position) {
    for (final run in runs) {
      if (run.start <= position && position < run.end) return run;
      if (run.start > position) break;
    }
    return null;
  }

  BlockInlineText _edit(
    int start,
    int end,
    BlockInlineRun Function(BlockInlineRun?, int, int) edit,
  ) {
    if (start == end) return this;
    final points = {
      0,
      text.length,
      start,
      end,
      for (final run in runs) ...[run.start, run.end],
    }.toList()..sort();
    final result = <BlockInlineRun>[];
    for (var index = 0; index < points.length - 1; index++) {
      final from = points[index], to = points[index + 1];
      final run = _styleAt(from);
      if (from >= start && to <= end) {
        result.add(edit(run, from, to));
      } else if (run != null) {
        result.add(BlockInlineRun._(from, to, run.marks, run.link, run._extra));
      }
    }
    return BlockInlineText._(text, result, _extra);
  }
}

List<BlockInlineRun> _merge(List<BlockInlineRun> runs) {
  final result = <BlockInlineRun>[];
  for (final run in runs) {
    if (run.start == run.end ||
        run.marks.isEmpty && run.link == null && run._extra.isEmpty)
      continue;
    if (result.isNotEmpty) {
      final previous = result.last;
      if (previous.end == run.start &&
          previous.link == run.link &&
          previous.marks.length == run.marks.length &&
          previous.marks.containsAll(run.marks) &&
          jsonEncode(previous._extra) == jsonEncode(run._extra)) {
        result[result.length - 1] = BlockInlineRun._(
          previous.start,
          run.end,
          previous.marks,
          previous.link,
          previous._extra,
        );
        continue;
      }
    }
    result.add(run);
  }
  return result;
}

// Unique unchanged graphemes anchor separate edits; repeated text uses the
// surrounding unchanged ranges or the editor's explicit old selection.
void _matchingPieces(
  List<String> old,
  List<String> next,
  int oldStart,
  int oldEnd,
  int nextStart,
  int nextEnd,
  List<(int, int, int)> result,
) {
  if (oldStart == oldEnd || nextStart == nextEnd) return;
  final exact = _nearbyMatches(old, next, oldStart, oldEnd, nextStart, nextEnd);
  if (exact != null) {
    result.addAll(exact);
    return;
  }
  final oldPositions = <String, int>{}, nextPositions = <String, int>{};
  for (var index = oldStart; index < oldEnd; index++) {
    oldPositions.update(old[index], (_) => -1, ifAbsent: () => index);
  }
  for (var index = nextStart; index < nextEnd; index++) {
    nextPositions.update(next[index], (_) => -1, ifAbsent: () => index);
  }
  final anchors = <(int, int)>[];
  for (var index = oldStart; index < oldEnd; index++) {
    final position = nextPositions[old[index]];
    if (oldPositions[old[index]] == index && position != null && position >= 0)
      anchors.add((index, position));
  }
  if (anchors.isEmpty) return;
  final tails = <int>[], previous = List.filled(anchors.length, -1);
  for (var index = 0; index < anchors.length; index++) {
    var low = 0, high = tails.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (anchors[tails[middle]].$2 < anchors[index].$2) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low > 0) previous[index] = tails[low - 1];
    if (low == tails.length) {
      tails.add(index);
    } else {
      tails[low] = index;
    }
  }
  final retained = <(int, int)>[];
  var cursor = tails.last;
  while (cursor >= 0) {
    retained.add(anchors[cursor]);
    cursor = previous[cursor];
  }
  var fromOld = oldStart, fromNext = nextStart;
  for (final anchor in retained.reversed) {
    var prefix = 0;
    while (fromOld + prefix < anchor.$1 &&
        fromNext + prefix < anchor.$2 &&
        old[fromOld + prefix] == next[fromNext + prefix]) {
      prefix++;
    }
    if (prefix > 0) result.add((fromOld, fromNext, prefix));
    var suffix = 0;
    while (anchor.$1 - suffix > fromOld + prefix &&
        anchor.$2 - suffix > fromNext + prefix &&
        old[anchor.$1 - suffix - 1] == next[anchor.$2 - suffix - 1]) {
      suffix++;
    }
    if (suffix > 0)
      result.add((anchor.$1 - suffix, anchor.$2 - suffix, suffix));
    result.add((anchor.$1, anchor.$2, 1));
    fromOld = anchor.$1 + 1;
    fromNext = anchor.$2 + 1;
  }
  var prefix = 0;
  while (fromOld + prefix < oldEnd &&
      fromNext + prefix < nextEnd &&
      old[fromOld + prefix] == next[fromNext + prefix]) {
    prefix++;
  }
  if (prefix > 0) result.add((fromOld, fromNext, prefix));
  var suffix = 0;
  while (oldEnd - suffix > fromOld + prefix &&
      nextEnd - suffix > fromNext + prefix &&
      old[oldEnd - suffix - 1] == next[nextEnd - suffix - 1]) {
    suffix++;
  }
  if (suffix > 0) result.add((oldEnd - suffix, nextEnd - suffix, suffix));
}

List<(int, int, int)>? _nearbyMatches(
  List<String> old,
  List<String> next,
  int oldStart,
  int oldEnd,
  int nextStart,
  int nextEnd,
) {
  final oldLength = oldEnd - oldStart, nextLength = nextEnd - nextStart;
  if ((oldLength - nextLength).abs() > 256) return null;
  final frontier = <int, int>{1: 0};
  final trace = <Map<int, int>>[];
  var work = 0;
  for (
    var distance = 0;
    distance <= 256 && distance <= oldLength + nextLength;
    distance++
  ) {
    trace.add(Map.of(frontier));
    for (var diagonal = -distance; diagonal <= distance; diagonal += 2) {
      var x =
          diagonal == -distance ||
              diagonal != distance &&
                  (frontier[diagonal - 1] ?? -1) <
                      (frontier[diagonal + 1] ?? -1)
          ? frontier[diagonal + 1] ?? 0
          : (frontier[diagonal - 1] ?? 0) + 1;
      var y = x - diagonal;
      while (x < oldLength &&
          y < nextLength &&
          old[oldStart + x] == next[nextStart + y]) {
        x++;
        y++;
        if (++work > 1000000) return null;
      }
      frontier[diagonal] = x;
      if (x < oldLength || y < nextLength) continue;
      final matches = <(int, int)>[];
      for (var step = distance; step >= 0; step--) {
        final before = trace[step], currentDiagonal = x - y;
        final previousDiagonal =
            currentDiagonal == -step ||
                currentDiagonal != step &&
                    (before[currentDiagonal - 1] ?? -1) <
                        (before[currentDiagonal + 1] ?? -1)
            ? currentDiagonal + 1
            : currentDiagonal - 1;
        final previousX = before[previousDiagonal] ?? 0;
        final previousY = previousX - previousDiagonal;
        while (x > previousX && y > previousY) {
          matches.add((oldStart + x - 1, nextStart + y - 1));
          x--;
          y--;
        }
        x = previousX;
        y = previousY;
      }
      final pieces = <(int, int, int)>[];
      for (final match in matches.reversed) {
        if (pieces.isNotEmpty &&
            pieces.last.$1 + pieces.last.$3 == match.$1 &&
            pieces.last.$2 + pieces.last.$3 == match.$2) {
          final last = pieces.removeLast();
          pieces.add((last.$1, last.$2, last.$3 + 1));
        } else {
          pieces.add((match.$1, match.$2, 1));
        }
      }
      return pieces;
    }
  }
  return null;
}

List<int> _boundaries(String text) => _offsets(text.characters.toList());
List<int> _offsets(List<String> graphemes) {
  final offsets = [0];
  for (final grapheme in graphemes) {
    offsets.add(offsets.last + grapheme.length);
  }
  return offsets;
}

String _digest(String text) => sha256.convert(utf8.encode(text)).toString();
Map<String, dynamic> _copy(Map<String, dynamic> value) {
  try {
    return Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  } on Object {
    throw const FormatException('Expected inline JSON data');
  }
}

bool _safeLink(String value) =>
    !value.contains(RegExp(r'[\x00-\x20\x7f-\x9f]')) &&
    (isSafeExternalLink(value) || NoteLink.parse(value) != null);
String? _destination(String? link, String Function(String)? resolve) {
  if (link == null || !_safeLink(link)) return null;
  final destination = resolve?.call(link) ?? link;
  final uri = Uri.tryParse(destination);
  if (uri == null ||
      destination.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]')) ||
      destination.contains('\\') ||
      destination.startsWith('//') ||
      uri.hasScheme && !_safeLink(destination))
    return null;
  return destination;
}

String _html(String value) =>
    const HtmlEscape(HtmlEscapeMode.element)
        .convert(value)
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
final _literalCharacters = RegExp(r'''[&<>"'\\`*_{}\[\]()#+.!|~\-]''');
final _markdownPunctuation = RegExp(r'[\\`*_{}\[\]()#+.!|~\-]');
String _markdown(String value) =>
    value.replaceAllMapped(_literalCharacters, (match) {
      final character = match[0]!;
      return _markdownPunctuation.hasMatch(character)
          ? '\\$character'
          : _html(character);
    });
String _markdownHtml(String value) =>
    value.replaceAllMapped(_literalCharacters, (match) {
      final character = match[0]!;
      return _markdownPunctuation.hasMatch(character)
          ? '&#${character.codeUnitAt(0)};'
          : _html(character);
    });
String _code(String value) {
  var width = 1;
  for (final match in RegExp(r'`+').allMatches(value)) {
    if (match[0]!.length >= width) width = match[0]!.length + 1;
  }
  final fence = '`' * width;
  final padding =
      value.startsWith('`') ||
          value.endsWith('`') ||
          value.startsWith(' ') && value.endsWith(' ')
      ? ' '
      : '';
  return '$fence$padding$value$padding$fence';
}
