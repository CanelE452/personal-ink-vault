import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:yaml/yaml.dart';

const _maxTemplate = 1024 * 1024;
const _maxExpanded = 4 * 1024 * 1024;
const _maxHeader = 64 * 1024;
const _maxFormat = 128;
const _defaultDate = 'YYYY-MM-DD';
const _defaultTime = 'HH:mm';
const _same = DeepCollectionEquality();

final _variable = RegExp(
  r'{{(title|date|time)(?::([^\r\n]{0,128}?))?}}',
  caseSensitive: false,
);
final _localizedToken = RegExp(r'\[[^\]]*\]|\\.|LTS|LT|L{1,4}|l{1,4}');
final _formatToken = RegExp(
  r'\[[^\]]*\]|\\.|YYYYYY|YYYY|YY|GGGG|GG|MMMM|MMM|MM|Mo|M|'
  r'DDDD|DDD|DD|Do|D|dddd|ddd|dd|d|E|WW|Wo|W|Q|HH|H|hh|h|kk|k|mm|m|'
  r'ss|s|S{1,9}|A|a|ZZ|Z|X|x|.',
  unicode: true,
);
final _control = RegExp(r'[\x00-\x1f\x7f]');
final _opening = RegExp(r'^\uFEFF?---[ \t]*(\r?\n|$)');
final _closing = RegExp(r'^---[ \t]*(?:\r?\n|$)', multiLine: true);

/// Inserts a Markdown template into a UTF-16 selection and returns the new
/// caret. Leading template properties are merged into one YAML header.
({String text, int caretOffset}) applyMarkdownTemplate({
  required String document,
  required int selectionStart,
  required int selectionEnd,
  required String template,
  required String title,
  required DateTime now,
  String dateFormat = _defaultDate,
  String timeFormat = _defaultTime,
}) {
  if (selectionStart < 0 ||
      selectionEnd < selectionStart ||
      selectionEnd > document.length ||
      _splitsSurrogate(document, selectionStart) ||
      _splitsSurrogate(document, selectionEnd)) {
    throw const FormatException('본문 선택 위치를 확인해 주세요.');
  }
  final expanded = _expand(template, title, now, dateFormat, timeFormat);
  final incoming = _Frontmatter.parse(expanded);
  final current = _Frontmatter.parse(document);
  if (current == null && (incoming == null || selectionStart == 0)) {
    final inserted =
        incoming != null &&
            incoming.bodyStart == expanded.length &&
            selectionEnd < document.length
        ? incoming.withBody(expanded, hasBody: true)
        : expanded;
    return (
      text: document.replaceRange(selectionStart, selectionEnd, inserted),
      caretOffset: selectionStart + inserted.length,
    );
  }
  final currentBodyStart = current?.bodyStart ?? 0;
  final start = selectionStart == 0 && selectionEnd == 0
      ? currentBodyStart
      : selectionStart;
  final end = start == selectionStart ? selectionEnd : start;
  if (start < currentBodyStart) {
    throw const FormatException('속성 영역 아래의 본문에 템플릿을 삽입해 주세요.');
  }
  final inserted = expanded.substring(incoming?.bodyStart ?? 0);
  final body = document.substring(currentBodyStart);
  final offset = start - currentBodyStart;
  final newBody = body.replaceRange(offset, end - currentBodyStart, inserted);
  final header = current == null
      ? incoming!.withBody(
          expanded.substring(0, incoming.bodyStart),
          hasBody: newBody.isNotEmpty,
        )
      : current.withBody(
          incoming == null
              ? document.substring(0, current.bodyStart)
              : current.merge(document, incoming),
          hasBody: newBody.isNotEmpty,
        );
  return (
    text: header + newBody,
    caretOffset: header.length + offset + inserted.length,
  );
}

bool _splitsSurrogate(String value, int offset) {
  if (offset <= 0 || offset >= value.length) return false;
  final left = value.codeUnitAt(offset - 1);
  final right = value.codeUnitAt(offset);
  return left >= 0xd800 && left <= 0xdbff && right >= 0xdc00 && right <= 0xdfff;
}

String _expand(
  String template,
  String title,
  DateTime now,
  String dateFormat,
  String timeFormat,
) {
  if (template.length > _maxTemplate) {
    throw const FormatException('템플릿이 너무 큽니다.');
  }
  var length = template.length;
  var count = 0;
  return template.replaceAllMapped(_variable, (match) {
    final field = match[1]!.toLowerCase();
    final override = match[2];
    final replacement = field == 'title'
        ? (override == null ? title : match[0]!)
        : _formatDate(
            now,
            override != null && override.isNotEmpty
                ? override
                : field == 'date'
                ? (dateFormat.isEmpty ? _defaultDate : dateFormat)
                : (timeFormat.isEmpty ? _defaultTime : timeFormat),
          );
    length += replacement.length - match[0]!.length;
    if (++count > 4096 || length > _maxExpanded) {
      throw const FormatException('템플릿 변수 결과가 너무 큽니다.');
    }
    return replacement;
  });
}

const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _localizedFormats = {
  'L': 'MM/DD/YYYY',
  'LL': 'MMMM D, YYYY',
  'LLL': 'MMMM D, YYYY h:mm A',
  'LLLL': 'dddd, MMMM D, YYYY h:mm A',
  'l': 'M/D/YYYY',
  'll': 'MMM D, YYYY',
  'lll': 'MMM D, YYYY h:mm A',
  'llll': 'ddd, MMM D, YYYY h:mm A',
  'LT': 'h:mm A',
  'LTS': 'h:mm:ss A',
};

String _formatDate(DateTime value, String format) {
  if (format.length > _maxFormat || _control.hasMatch(format)) {
    throw const FormatException('템플릿 날짜·시간 형식을 확인해 주세요.');
  }
  String pad(int number, int width) => number.toString().padLeft(width, '0');
  final day = DateTime.utc(value.year, value.month, value.day);
  final thursday = day.add(Duration(days: DateTime.thursday - day.weekday));
  final weekStart = DateTime.utc(thursday.year);
  final week = thursday.difference(weekStart).inDays ~/ 7 + 1;
  final dayOfYear = day.difference(DateTime.utc(day.year)).inDays + 1;
  final month = _months[value.month - 1];
  final weekday = _weekdays[value.weekday - 1];
  final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
  final meridiem = value.hour < 12 ? 'am' : 'pm';
  final minutes = value.timeZoneOffset.inMinutes;
  final zoneHours = '${minutes < 0 ? '-' : '+'}${pad(minutes.abs() ~/ 60, 2)}';
  final zoneMinutes = pad(minutes.abs() % 60, 2);
  String ordinal(int number) {
    final suffix = switch (number % 100) {
      11 || 12 || 13 => 'th',
      _ => switch (number % 10) {
        1 => 'st',
        2 => 'nd',
        3 => 'rd',
        _ => 'th',
      },
    };
    return '$number$suffix';
  }

  final expandedFormat = format.replaceAllMapped(_localizedToken, (match) {
    final token = match[0]!;
    return _localizedFormats[token] ?? token;
  });
  return expandedFormat.replaceAllMapped(_formatToken, (match) {
    final token = match[0]!;
    if (token.length > 1 && token.startsWith('[')) {
      return token.substring(1, token.length - 1);
    }
    if (token.length > 1 && token.startsWith(r'\')) return token.substring(1);
    if (token.startsWith('S')) {
      return pad(
        value.millisecond,
        3,
      ).padRight(9, '0').substring(0, token.length);
    }
    return switch (token) {
      'YYYYYY' => '${value.year < 0 ? '-' : '+'}${pad(value.year.abs(), 6)}',
      'YYYY' => pad(value.year, 4),
      'YY' => pad(value.year % 100, 2),
      'GGGG' => pad(thursday.year, 4),
      'GG' => pad(thursday.year % 100, 2),
      'Q' => ((value.month + 2) ~/ 3).toString(),
      'MMMM' => month,
      'MMM' => month.substring(0, 3),
      'MM' => pad(value.month, 2),
      'Mo' => ordinal(value.month),
      'M' => value.month.toString(),
      'DDDD' => pad(dayOfYear, 3),
      'DDD' => dayOfYear.toString(),
      'DD' => pad(value.day, 2),
      'Do' => ordinal(value.day),
      'D' => value.day.toString(),
      'dddd' => weekday,
      'ddd' => weekday.substring(0, 3),
      'dd' => weekday.substring(0, 2),
      'd' => (value.weekday % 7).toString(),
      'E' => value.weekday.toString(),
      'WW' => pad(week, 2),
      'Wo' => ordinal(week),
      'W' => week.toString(),
      'HH' => pad(value.hour, 2),
      'H' => value.hour.toString(),
      'hh' => pad(hour, 2),
      'h' => hour.toString(),
      'kk' => pad(value.hour == 0 ? 24 : value.hour, 2),
      'k' => (value.hour == 0 ? 24 : value.hour).toString(),
      'mm' => pad(value.minute, 2),
      'm' => value.minute.toString(),
      'ss' => pad(value.second, 2),
      's' => value.second.toString(),
      'A' => meridiem.toUpperCase(),
      'a' => meridiem,
      'Z' => '$zoneHours:$zoneMinutes',
      'ZZ' => '$zoneHours$zoneMinutes',
      'X' => (value.millisecondsSinceEpoch / 1000).floor().toString(),
      'x' => value.millisecondsSinceEpoch.toString(),
      _ => token,
    };
  });
}

final class _Frontmatter {
  const new(this.start, this.end, this.bodyStart, this.newline, this.yaml);

  final int start;
  final int end;
  final int bodyStart;
  final String newline;
  final YamlMap? yaml;

  static _Frontmatter? parse(String markdown) {
    final bound = min(markdown.length, _maxHeader);
    final prefix = markdown.substring(0, bound);
    final opening = _opening.matchAsPrefix(prefix);
    if (opening == null) return null;
    final closing = _closing.firstMatch(prefix.substring(opening.end));
    if (closing == null ||
        (opening.end + closing.end == bound &&
            bound < markdown.length &&
            !prefix.endsWith('\n'))) {
      throw const FormatException('YAML 속성 영역의 끝을 확인해 주세요.');
    }
    final end = opening.end + closing.start;
    final content = prefix.substring(opening.end, end);
    return _Frontmatter(
      opening.end,
      end,
      opening.end + closing.end,
      opening[1] == '\r\n' ? '\r\n' : '\n',
      _parseYaml(content),
    );
  }

  String withBody(String header, {required bool hasBody}) =>
      hasBody && !header.endsWith('\n') ? '$header$newline' : header;

  String merge(String document, _Frontmatter incoming) {
    final originalHeader = document.substring(start, end);
    final before = _readProperties(yaml);
    final template = _readProperties(incoming.yaml);
    if (template.isEmpty) return document.substring(0, bodyStart);
    final merged = _mergeMaps(before, template);
    final updates = <({int start, int end, String text})>[];
    final nodes = <String, (YamlNode, YamlNode)>{
      if (yaml != null)
        for (final entry in yaml!.nodes.entries)
          (entry.key as YamlNode).value as String: (
            entry.key as YamlNode,
            entry.value,
          ),
    };
    final additions = <String>[];
    for (final entry in merged.entries) {
      final existing = nodes[entry.key];
      if (existing == null) {
        additions.add('${jsonEncode(entry.key)}: ${jsonEncode(entry.value)}');
      } else if (!_same.equals(before[entry.key], entry.value)) {
        final (key, value) = existing;
        var valueStart = value.span.start.offset;
        var valueEnd = _contentEnd(value);
        if (valueStart < key.span.end.offset ||
            valueEnd < valueStart ||
            valueEnd > originalHeader.length ||
            value.span.text.startsWith('&') ||
            value.span.text.startsWith('!')) {
          throw const FormatException('이 YAML 속성은 원본을 보존하며 병합할 수 없습니다.');
        }
        var spacer = '';
        if (valueStart == valueEnd) {
          spacer = ' ';
          // YAML may place an empty value's span at the mapping delimiter.
          if (valueStart < originalHeader.length &&
              originalHeader[valueStart] == ':') {
            valueStart++;
            valueEnd++;
          } else if (yaml?.style == CollectionStyle.FLOW &&
              valueStart == key.span.end.offset) {
            spacer = ': ';
          }
        }
        updates.add((
          start: valueStart,
          end: valueEnd,
          text: '$spacer${jsonEncode(entry.value)}',
        ));
      }
    }
    if (additions.isNotEmpty) {
      if (yaml?.style == CollectionStyle.FLOW) {
        final close = yaml!.span.end.offset - 1;
        final last = nodes.isEmpty ? close : _contentEnd(nodes.values.last.$2);
        final trailingComma = originalHeader
            .substring(last, close)
            .trimLeft()
            .startsWith(',');
        final prefix = nodes.isEmpty || trailingComma ? '' : ', ';
        updates.add((
          start: close,
          end: close,
          text: '$prefix${additions.join(', ')}',
        ));
      } else {
        final indent =
            ' ' * (nodes.isEmpty ? 0 : nodes.values.first.$1.span.start.column);
        final appended = additions
            .map((entry) => '$indent$entry$newline')
            .join();
        updates.add((
          start: originalHeader.length,
          end: originalHeader.length,
          text: appended,
        ));
      }
    }
    updates.sort((a, b) => b.start.compareTo(a.start));
    var header = originalHeader;
    var boundary = header.length;
    for (final update in updates) {
      if (update.end > boundary) {
        throw const FormatException('겹치는 YAML 속성은 안전하게 병합할 수 없습니다.');
      }
      header = header.replaceRange(update.start, update.end, update.text);
      boundary = update.start;
    }
    if (header.length > _maxHeader ||
        !_same.equals(_readProperties(_parseYaml(header)), merged)) {
      throw const FormatException('YAML 속성을 안전하게 병합할 수 없습니다.');
    }
    return document.substring(0, start) +
        header +
        document.substring(end, bodyStart);
  }
}

YamlMap? _parseYaml(String text) {
  try {
    final node = loadYamlNode(text);
    if (node.value == null) return null;
    if (node is YamlMap) return node;
  } on YamlException {
    throw const FormatException('YAML 속성의 형식을 확인해 주세요.');
  } on StackOverflowError {
    throw const FormatException('YAML 속성의 깊이를 확인해 주세요.');
  }
  throw const FormatException('YAML 속성은 이름과 값으로 구성해야 합니다.');
}

Map<String, Object?> _readProperties(YamlMap? yaml) {
  var remaining = 2048;
  Object? read(Object? value, int depth) {
    if (depth > 16 || --remaining < 0) {
      throw const FormatException('YAML 속성의 크기나 깊이가 너무 큽니다.');
    }
    if (value is List) return [for (final item in value) read(item, depth + 1)];
    if (value is Map) {
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String || key.isEmpty || _control.hasMatch(key)) {
          throw const FormatException('YAML 속성 이름의 형식을 확인해 주세요.');
        }
        result[key] = read(entry.value, depth + 1);
      }
      return result;
    }
    if (value == null ||
        value is String ||
        value is bool ||
        (value is num && value.isFinite)) {
      return value;
    }
    throw const FormatException('지원하는 YAML 속성 값인지 확인해 주세요.');
  }

  return yaml == null ? {} : read(yaml, 0)! as Map<String, Object?>;
}

Map<String, Object?> _mergeMaps(
  Map<String, Object?> current,
  Map<String, Object?> incoming,
) {
  final result = {...current};
  for (final entry in incoming.entries) {
    final before = current[entry.key];
    final next = entry.value;
    if (before is Map<String, Object?> && next is Map<String, Object?>) {
      result[entry.key] = _mergeMaps(before, next);
    } else if (before is List && next is List) {
      result[entry.key] = {...before, ...next}.toList();
    } else if (next != null ||
        before == null ||
        before == false ||
        before == 0 ||
        before == '') {
      result[entry.key] = next;
    }
  }
  return result;
}

// Block collection spans include trailing comments and the next key's indent.
// Use the last value's actual end to leave that source text intact.
int _contentEnd(YamlNode node) {
  return switch (node) {
    YamlMap(:final nodes, style: CollectionStyle.BLOCK) when nodes.isNotEmpty =>
      max(
        (nodes.keys.last as YamlNode).span.end.offset,
        _contentEnd(nodes.values.last),
      ),
    YamlList(:final nodes, style: CollectionStyle.BLOCK)
        when nodes.isNotEmpty =>
      _contentEnd(nodes.last),
    _ => node.span.end.offset,
  };
}
