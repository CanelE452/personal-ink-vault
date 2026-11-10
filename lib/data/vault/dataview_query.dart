import 'dart:convert';

enum DataviewLayout { list, table, task }

final class DataviewColumn {
  const new(this.property, this.label);

  final String property;
  final String label;
}

sealed class DataviewSource {
  const new();
}

final class DataviewTagSource extends DataviewSource {
  const new(this.tag);

  final String tag;
}

final class DataviewFolderSource extends DataviewSource {
  const new(this.folder);

  final String folder;
}

final class DataviewLinkSource extends DataviewSource {
  const new(this.target, {required this.outgoing});

  final String target;
  final bool outgoing;
}

final class DataviewSourceLogical extends DataviewSource {
  const new(this.left, this.right, {required this.and});

  final DataviewSource left;
  final DataviewSource right;
  final bool and;
}

final class DataviewSourceNegation extends DataviewSource {
  const new(this.source);

  final DataviewSource source;
}

sealed class DataviewCondition {
  const new();

  bool referencesAny(Set<String> properties) => switch (this) {
    DataviewFilter(:final property) => properties.contains(property),
    DataviewNegation(:final condition) => condition.referencesAny(properties),
    DataviewLogical(:final left, :final right) =>
      left.referencesAny(properties) || right.referencesAny(properties),
  };
}

enum DataviewOperator {
  equal,
  notEqual,
  less,
  lessOrEqual,
  greater,
  greaterOrEqual,
  truthy,
}

final class DataviewFilter extends DataviewCondition {
  const new(this.property, this.operator, [this.value]);

  final String property;
  final DataviewOperator operator;
  final Object? value;
}

final class DataviewLogical extends DataviewCondition {
  const new(this.left, this.right, {required this.and});

  final DataviewCondition left;
  final DataviewCondition right;
  final bool and;
}

final class DataviewNegation extends DataviewCondition {
  const new(this.condition);

  final DataviewCondition condition;
}

final class DataviewSort {
  const new(this.property, {required this.descending});

  final String property;
  final bool descending;
}

final class DataviewGroupBy {
  const new(this.property, this.label, {required this.descending});

  final String property;
  final String label;
  final bool descending;
}

final class DataviewQuery {
  new _({
    required this.layout,
    required List<DataviewColumn> columns,
    required this.source,
    required this.condition,
    required List<DataviewSort> sorts,
    required this.groupBy,
    required this.limit,
  }) : columns = List.unmodifiable(columns),
       sorts = List.unmodifiable(sorts);

  factory parse(String text) => _Parser(text).parse();

  static const maxResults = 100;

  final DataviewLayout layout;
  final List<DataviewColumn> columns;
  final DataviewSource? source;
  final DataviewCondition? condition;
  final List<DataviewSort> sorts;
  final DataviewGroupBy? groupBy;
  final int limit;
}

final class _Token {
  const new(this.value, {this.quoted = false, this.wikiLink = false});

  final String value;
  final bool quoted;
  final bool wikiLink;

  bool get plain => !quoted && !wikiLink;
}

final class _Parser {
  new(this._input) {
    if (_input.length > 4096) {
      throw const FormatException('Dataview 쿼리는 4096자까지 지원합니다.');
    }
    _advance();
  }

  static final _space = RegExp(r'[ \t\r\n]+');
  static final _quoted = RegExp(
    r'"(?:[^"\\\x00-\x1f]|\\["\\/bfnrt]|\\u[0-9a-fA-F]{4})*"',
  );
  static final _wikiLink = RegExp(r'\[\[([^\[\]\x00-\x1f\x7f]{0,512})\]\]');
  static final _prefixMinus = RegExp(
    r'-(?=[ \t\r\n!#(\["-]|outgoing\b)',
    caseSensitive: false,
  );
  static final _operator = RegExp(r'!=|<=|>=|[(),=<>!&|]');
  static final _bare = RegExp(r'[^ \t\r\n(),=<>!&|\[\]]+');
  static final _property = RegExp(
    r'^[\p{L}\p{M}_][\p{L}\p{M}\p{N}_.-]*$',
    unicode: true,
  );
  static final _tagPart = RegExp(
    r'^[\p{L}\p{N}_-][\p{L}\p{M}\p{N}_-]*$',
    unicode: true,
  );
  static final _unsafeFolder = RegExp(r'[\x00-\x1f\x7f\\:*?"<>|]');
  static final _controls = RegExp(r'[\x00-\x1f\x7f]');
  static final _number = RegExp(
    r'^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$',
  );
  static final _limit = RegExp(r'^[1-9][0-9]{0,2}$');
  static const _comparisonOperators = {
    '=': DataviewOperator.equal,
    '!=': DataviewOperator.notEqual,
    '<': DataviewOperator.less,
    '<=': DataviewOperator.lessOrEqual,
    '>': DataviewOperator.greater,
    '>=': DataviewOperator.greaterOrEqual,
  };

  final String _input;
  var _offset = 0;
  var _sources = 0;
  var _conditions = 0;
  _Token? _current;

  DataviewQuery parse() {
    final DataviewLayout layout;
    if (_consume('LIST')) {
      layout = DataviewLayout.list;
    } else if (_consume('TABLE')) {
      layout = DataviewLayout.table;
    } else if (_consume('TASK')) {
      layout = DataviewLayout.task;
    } else {
      throw const FormatException('LIST, TABLE 또는 TASK로 시작해야 합니다.');
    }

    final columns = <DataviewColumn>[];
    final firstField = _current;
    if (layout == DataviewLayout.table) {
      do {
        if (columns.length == 16) {
          throw const FormatException('Dataview 표 열은 16개까지 지원합니다.');
        }
        final property = _readProperty();
        final label = _consume('AS') ? _readLabel() : property;
        columns.add(DataviewColumn(property, label));
      } while (_consume(','));
    } else if (layout == DataviewLayout.list &&
        firstField != null &&
        firstField.plain &&
        !const {
          'FROM',
          'WHERE',
          'SORT',
          'GROUP',
          'LIMIT',
        }.contains(firstField.value.toUpperCase())) {
      final property = _readProperty();
      columns.add(DataviewColumn(property, property));
    }

    final source = _consume('FROM') ? _readSource(0) : null;
    final condition = _consume('WHERE') ? _readCondition(0) : null;
    final sorts = <DataviewSort>[];
    if (_consume('SORT')) {
      do {
        if (sorts.length == 8) {
          throw const FormatException('Dataview 정렬 키는 8개까지 지원합니다.');
        }
        sorts.add(_readSort());
      } while (_consume(','));
    }

    DataviewGroupBy? groupBy;
    if (_consume('GROUP')) {
      if (!_consume('BY')) {
        throw const FormatException('GROUP 뒤에 BY를 입력하세요.');
      }
      final property = _readProperty();
      final label = _consume('AS')
          ? _readLabel(allowIdentifier: true)
          : property;
      if (label == 'rows' ||
          (layout != DataviewLayout.task && label.startsWith('rows.'))) {
        throw const FormatException(
          'GROUP BY 이름으로 rows나 rows.로 시작하는 이름을 쓸 수 없습니다.',
        );
      }
      final groupSort = _consume('SORT') ? _readSort() : null;
      if (groupSort != null &&
          groupSort.property != 'key' &&
          groupSort.property != label) {
        throw const FormatException('GROUP BY 뒤에는 key 또는 그룹 이름으로 정렬하세요.');
      }
      groupBy = DataviewGroupBy(
        property,
        label,
        descending: groupSort?.descending ?? false,
      );
    }

    var limit = DataviewQuery.maxResults;
    if (_consume('LIMIT')) {
      final token = _take();
      if (!token.plain || !_limit.hasMatch(token.value)) {
        throw const FormatException('LIMIT는 1부터 100 사이의 정수여야 합니다.');
      }
      limit = int.parse(token.value);
      if (limit > DataviewQuery.maxResults) {
        throw const FormatException('LIMIT는 1부터 100 사이의 정수여야 합니다.');
      }
    }

    if (_current != null) {
      throw const FormatException('지원하지 않는 Dataview 구문이 있습니다.');
    }
    if (groupBy == null &&
        layout == DataviewLayout.list &&
        columns.isNotEmpty) {
      throw const FormatException('LIST에 표시할 속성은 GROUP BY와 함께 지정하세요.');
    }
    if (groupBy != null && layout != DataviewLayout.task) {
      for (final column in columns) {
        final property = column.property;
        if (property == 'key' || property == groupBy.label) continue;
        if (!_isMemberProjection(property)) {
          throw const FormatException(
            '문서 그룹에는 key, 그룹 이름 또는 rows.속성을 표시할 수 있습니다.',
          );
        }
      }
    }
    return DataviewQuery._(
      layout: layout,
      columns: columns,
      source: source,
      condition: condition,
      sorts: sorts,
      groupBy: groupBy,
      limit: limit,
    );
  }

  bool _isMemberProjection(String property) {
    if (!property.startsWith('rows.')) return false;
    final field = property.substring('rows.'.length);
    if (field == 'file' || field.startsWith('file.')) {
      return const {
        'file.name',
        'file.path',
        'file.folder',
        'file.link',
      }.contains(field);
    }
    return _property.hasMatch(field);
  }

  void _advance() {
    _offset = _space.matchAsPrefix(_input, _offset)?.end ?? _offset;
    if (_offset == _input.length) {
      _current = null;
      return;
    }
    final link = _wikiLink.matchAsPrefix(_input, _offset);
    if (link != null) {
      _offset = link.end;
      _current = _Token(link[1]!, wikiLink: true);
      return;
    }
    final operator =
        _operator.matchAsPrefix(_input, _offset) ??
        _prefixMinus.matchAsPrefix(_input, _offset);
    if (operator != null) {
      _current = _Token(operator[0]!);
      _offset = operator.end;
      return;
    }
    if (_input[_offset] == '"') {
      final match = _quoted.matchAsPrefix(_input, _offset);
      if (match == null ||
          (match.end < _input.length &&
              _bare.matchAsPrefix(_input, match.end) != null)) {
        throw const FormatException('큰따옴표 문자열 형식이 올바르지 않습니다.');
      }
      _offset = match.end;
      _current = _Token(jsonDecode(match.group(0)!) as String, quoted: true);
      return;
    }
    final match = _bare.matchAsPrefix(_input, _offset);
    if (match == null) {
      throw const FormatException('Dataview 링크는 [[문서]] 형식으로 입력하세요.');
    }
    _offset = match.end;
    _current = _Token(match.group(0)!);
  }

  bool _consume(String value) {
    final token = _current;
    if (token == null || !token.plain || token.value.toUpperCase() != value) {
      return false;
    }
    _advance();
    return true;
  }

  _Token _take() {
    final token = _current;
    if (token == null) {
      throw const FormatException('Dataview 쿼리에 값이 빠졌습니다.');
    }
    _advance();
    return token;
  }

  String _readProperty() {
    final token = _take();
    if (!token.plain ||
        token.value.length > 128 ||
        !_property.hasMatch(token.value)) {
      throw const FormatException('문서 속성 이름 형식이 올바르지 않습니다.');
    }
    return token.value;
  }

  DataviewSource _readSource(int depth) {
    var result = _readSourceTerm(depth);
    while (true) {
      final and = _consume('AND') || _consume('&');
      if (!and && !_consume('OR') && !_consume('|')) return result;
      result = DataviewSourceLogical(result, _readSourceTerm(depth), and: and);
    }
  }

  DataviewSource _readSourceTerm(int depth) {
    if (depth > 16) {
      throw const FormatException('FROM의 괄호와 부정은 16단계까지 지원합니다.');
    }
    if (_consume('!') || _consume('-')) {
      return DataviewSourceNegation(_readSourceTerm(depth + 1));
    }
    if (_consume('(')) {
      final source = _readSource(depth + 1);
      if (!_consume(')')) {
        throw const FormatException('FROM 괄호를 닫으세요.');
      }
      return source;
    }
    if (++_sources > 24) {
      throw const FormatException('FROM의 조회 대상은 24개까지 지원합니다.');
    }
    if (_consume('OUTGOING')) {
      if (!_consume('(')) {
        throw const FormatException('outgoing([[문서]]) 형식으로 입력하세요.');
      }
      final target = _take();
      if (!target.wikiLink || !_consume(')')) {
        throw const FormatException('outgoing([[문서]]) 형식으로 입력하세요.');
      }
      return DataviewLinkSource(_linkTarget(target.value), outgoing: true);
    }
    final token = _take();
    if (token.wikiLink) {
      return DataviewLinkSource(_linkTarget(token.value), outgoing: false);
    }
    if (token.quoted) return DataviewFolderSource(_folder(token.value));
    return DataviewTagSource(_tag(token.value));
  }

  static String _linkTarget(String value) {
    final end = value.indexOf(RegExp(r'[#|]'));
    return (end < 0 ? value : value.substring(0, end)).trim();
  }

  DataviewCondition _readCondition(int depth) {
    if (depth > 16) {
      throw const FormatException('WHERE 괄호는 16단계까지 지원합니다.');
    }
    var result = _readConditionTerm(depth);
    // Dataview gives AND and OR the same precedence.
    while (true) {
      final and = _consume('AND') || _consume('&');
      if (!and && !_consume('OR') && !_consume('|')) return result;
      result = DataviewLogical(result, _readConditionTerm(depth), and: and);
    }
  }

  DataviewCondition _readConditionTerm(int depth) {
    final negated = _consume('!');
    final DataviewCondition condition;
    if (_consume('(')) {
      condition = _readCondition(depth + 1);
      if (!_consume(')')) {
        throw const FormatException('WHERE 괄호를 닫으세요.');
      }
    } else {
      if (++_conditions > 64) {
        throw const FormatException('WHERE 조건은 64개까지 지원합니다.');
      }
      final property = _readProperty();
      final token = _current;
      final operator = token == null || !token.plain
          ? null
          : _comparisonOperators[token.value];
      if (operator != null && !negated) {
        _advance();
        condition = DataviewFilter(property, operator, _literal(_take()));
      } else {
        condition = DataviewFilter(property, DataviewOperator.truthy);
      }
    }
    return negated ? DataviewNegation(condition) : condition;
  }

  DataviewSort _readSort() {
    final property = _readProperty();
    final descending = _consume('DESC') || _consume('DESCENDING');
    if (!descending && !_consume('ASC')) _consume('ASCENDING');
    return DataviewSort(property, descending: descending);
  }

  String _readLabel({bool allowIdentifier = false}) {
    final token = _take();
    if (allowIdentifier &&
        token.plain &&
        token.value.length <= 128 &&
        _property.hasMatch(token.value)) {
      return token.value;
    }
    if (!token.quoted ||
        token.value.trim().isEmpty ||
        token.value.length > 256 ||
        _controls.hasMatch(token.value)) {
      throw FormatException(
        allowIdentifier
            ? 'AS 뒤에 속성 이름이나 큰따옴표로 감싼 그룹 이름을 입력하세요.'
            : 'AS 뒤에 큰따옴표로 감싼 열 이름을 입력하세요.',
      );
    }
    return token.value;
  }

  static String _tag(String source) {
    if (!source.startsWith('#') || source.length > 129) {
      throw const FormatException(
        'FROM에는 #태그, 큰따옴표로 감싼 폴더, [[문서]]를 넣을 수 있습니다.',
      );
    }
    final tag = source.substring(1);
    if (!tag.split('/').every(_tagPart.hasMatch)) {
      throw const FormatException('FROM의 태그 형식이 올바르지 않습니다.');
    }
    return tag;
  }

  static String _folder(String source) {
    if (source == '' || source == '/') return '';
    if (source.length > 512 || _unsafeFolder.hasMatch(source)) {
      throw const FormatException('FROM의 폴더 경로가 올바르지 않습니다.');
    }
    final start = source.startsWith('/') ? 1 : 0;
    final end = source.endsWith('/') ? source.length - 1 : source.length;
    final folder = source.substring(start, end);
    if (folder
        .split('/')
        .any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw const FormatException('FROM의 폴더 경로가 올바르지 않습니다.');
    }
    return folder;
  }

  static Object? _literal(_Token token) {
    final value = token.value;
    if (token.quoted) {
      if (value.length <= 1024) return value;
      throw const FormatException('WHERE의 문자열은 1024자까지 지원합니다.');
    }
    if (token.plain) {
      switch (value.toLowerCase()) {
        case 'null':
          return null;
        case 'true':
          return true;
        case 'false':
          return false;
      }
      if (_number.hasMatch(value)) {
        final number = num.tryParse(value);
        if (number != null && number.isFinite) return number;
      }
    }
    throw const FormatException(
      'WHERE에는 문자열, 숫자, true, false, null을 넣을 수 있습니다.',
    );
  }
}
