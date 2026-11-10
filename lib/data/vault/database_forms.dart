import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/data/vault/workspace_database.dart';

const databaseFormPropertyTypes = [
  'title',
  'text',
  'number',
  'status',
  'select',
  'multiSelect',
  'date',
  'checkbox',
  'url',
  'email',
  'phone',
];

class DatabaseFormException implements Exception {
  const new(this.code, this.message, {this.propertyId, this.questionId});
  final String code;
  final String message;
  final String? propertyId;
  final String? questionId;
  @override
  String toString() => 'DatabaseFormException($code): $message';
}

class DatabaseFormQuestion {
  new _(Map<String, dynamic> raw) : _raw = _freezeMap(raw);
  factory create({
    String? id,
    required String propertyId,
    required String label,
    bool required = false,
    Map<String, dynamic>? visibleWhen,
  }) => DatabaseFormQuestion.fromJson({
    'id': id ?? newId(),
    'propertyId': propertyId,
    'label': label,
    'required': required,
    'visibleWhen': visibleWhen,
  });
  factory fromJson(Map<String, dynamic> json) {
    final raw = _copyMap(json);
    _id(raw['id']);
    _id(raw['propertyId']);
    _text(raw['label'], 'invalid_label');
    raw['required'] ??= false;
    if (raw['required'] is! bool)
      _raise('invalid_question', '질문의 필수 여부가 올바르지 않습니다.');
    if (raw['visibleWhen'] != null)
      raw['visibleWhen'] = _object(raw['visibleWhen']);
    return DatabaseFormQuestion._(raw);
  }
  final Map<String, dynamic> _raw;
  String get id => _raw['id'] as String;
  String get propertyId => _raw['propertyId'] as String;
  String get label => _raw['label'] as String;
  bool get required => _raw['required'] as bool;
  Map<String, dynamic>? get visibleWhen =>
      _raw['visibleWhen'] as Map<String, dynamic>?;
  DatabaseFormQuestion copyWith({
    String? label,
    bool? required,
    Map<String, dynamic>? visibleWhen,
    bool clearVisibleWhen = false,
  }) => DatabaseFormQuestion.fromJson({
    ...toJson(),
    'label': ?label,
    'required': ?required,
    if (visibleWhen != null || clearVisibleWhen)
      'visibleWhen': clearVisibleWhen ? null : visibleWhen,
  });
  Map<String, dynamic> toJson() => _copyMap(_raw);
}

class DatabaseForm {
  new _(Map<String, dynamic> raw, List<DatabaseFormQuestion> questions)
    : _raw = _freezeMap(raw),
      questions = List.unmodifiable(questions);
  factory create({
    String? id,
    required String title,
    String description = '',
    List<DatabaseFormQuestion> questions = const [],
    bool archived = false,
  }) => DatabaseForm.fromJson({
    'id': id ?? newId(),
    'title': title,
    'description': description,
    'questions': [for (final question in questions) question.toJson()],
    'archived': archived,
  });
  factory fromJson(Map<String, dynamic> json) {
    final raw = _copyMap(json);
    _id(raw['id']);
    _text(raw['title'], 'invalid_title');
    raw['description'] ??= '';
    raw['archived'] ??= false;
    if (raw['description'] is! String || raw['archived'] is! bool)
      _raise('invalid_form', '폼 설명이나 보관 상태가 올바르지 않습니다.');
    final items = _list(raw['questions'] ?? []);
    if (items.length > 128) _raise('question_limit', '폼 질문은 128개까지 만들 수 있습니다.');
    final questions = [
      for (final item in items) DatabaseFormQuestion.fromJson(_object(item)),
    ];
    if (questions.map((q) => q.id).toSet().length != questions.length)
      _raise('duplicate_question', '같은 질문 ID를 반복할 수 없습니다.');
    raw['questions'] = [for (final question in questions) question.toJson()];
    return DatabaseForm._(raw, questions);
  }
  final Map<String, dynamic> _raw;
  String get id => _raw['id'] as String;
  String get title => _raw['title'] as String;
  String get description => _raw['description'] as String;
  bool get archived => _raw['archived'] as bool;
  final List<DatabaseFormQuestion> questions;
  DatabaseForm copyWith({
    String? title,
    String? description,
    List<DatabaseFormQuestion>? questions,
    bool? archived,
  }) => DatabaseForm.fromJson({
    ...toJson(),
    'title': ?title,
    'description': ?description,
    if (questions != null)
      'questions': [for (final question in questions) question.toJson()],
    'archived': ?archived,
  });
  Map<String, dynamic> toJson() => _copyMap(_raw);
}

class DatabaseFormPreview {
  new _(
    List<DatabaseFormQuestion> visibleQuestions,
    Map<String, Object?> values,
    List<DatabaseFormException> errors,
  ) : visibleQuestions = List.unmodifiable(visibleQuestions),
      values = _freezeMap(values),
      errors = List.unmodifiable(errors);
  final List<DatabaseFormQuestion> visibleQuestions;
  final Map<String, Object?> values;
  final List<DatabaseFormException> errors;
  bool get isValid => errors.isEmpty;
}

class DatabaseFormReceipt {
  new _(Map<String, dynamic> raw) : _raw = _freezeMap(raw);
  factory _fromJson(Map<String, dynamic> json) {
    final raw = _copyMap(json);
    for (final key in ['rowId', 'formId', 'requestId', 'inputRevision']) {
      _id(raw[key], 'invalid_receipt');
    }
    final submittedAt = raw['submittedAt'];
    final time = submittedAt is String ? DateTime.tryParse(submittedAt) : null;
    if (time == null || !time.isUtc)
      _raise('invalid_receipt', '응답 저장 시각이 올바르지 않습니다.');
    for (final key in ['answersDigest', 'formDigest']) {
      final digest = raw[key];
      if (digest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest))
        _raise('invalid_receipt', '응답 기록의 내용 해시가 올바르지 않습니다.');
    }
    return DatabaseFormReceipt._(raw);
  }
  final Map<String, dynamic> _raw;
  String get rowId => _raw['rowId'] as String;
  String get formId => _raw['formId'] as String;
  String get requestId => _raw['requestId'] as String;
  String get inputRevision => _raw['inputRevision'] as String;
  DateTime get submittedAt => DateTime.parse(_raw['submittedAt'] as String);
  String get formDigest => _raw['formDigest'] as String;
  String get answersDigest => _raw['answersDigest'] as String;
  Map<String, dynamic> toJson() => _copyMap(_raw);
}

class DatabaseFormSubmission {
  const new _({
    required this.database,
    required this.rowId,
    required this.duplicate,
    required this.receipt,
  });
  final WorkspaceDatabase database;
  final String rowId;
  final bool duplicate;
  final DatabaseFormReceipt receipt;
  DatabaseFormSubmission withDatabase(WorkspaceDatabase database) {
    if (database.id != this.database.id) {
      _raise('submission_database_mismatch', '응답의 데이터베이스를 바꿀 수 없습니다.');
    }
    if (!database.rows.any((row) => row.id == rowId && !row.archived)) {
      _raise('missing_submission_row', '응답 행은 같은 ID로 남아 있어야 합니다.');
    }
    final recorded = DatabaseForms(database).submissions
        .where((record) => record.requestId == receipt.requestId);
    if (recorded.length != 1 ||
        !_equal(recorded.single.toJson(), receipt.toJson())) {
      _raise('invalid_submission_receipt', '원래 응답의 저장 기록을 바꿀 수 없습니다.');
    }
    return DatabaseFormSubmission._(
      database: database,
      rowId: rowId,
      duplicate: duplicate,
      receipt: receipt,
    );
  }
}

/// Local snapshot preparation only. The caller persists the returned database
/// through its existing revision/save boundary and retains it for save retries.
class DatabaseForms {
  new(this.database);
  final WorkspaceDatabase database;
  List<DatabaseForm> get forms {
    final items = _list(database.toJson()['forms'] ?? []);
    if (items.length > 64) _raise('form_limit', '데이터베이스당 폼은 64개까지 만들 수 있습니다.');
    final result = [
      for (final item in items) DatabaseForm.fromJson(_object(item)),
    ];
    if (result.map((f) => f.id).toSet().length != result.length)
      _raise('duplicate_form', '같은 폼 ID가 반복되었습니다.');
    return List.unmodifiable(result);
  }

  List<DatabaseFormReceipt> get submissions {
    final items = _list(database.toJson()['formSubmissions'] ?? []);
    if (items.length > 10000) _raise('submission_limit', '폼 응답 기록 한도를 넘었습니다.');
    final result = [
      for (final item in items) DatabaseFormReceipt._fromJson(_object(item)),
    ];
    if (result.map((r) => r.requestId).toSet().length != result.length)
      _raise('invalid_receipt', '같은 요청의 응답 기록이 반복되었습니다.');
    return List.unmodifiable(result);
  }

  List<DatabaseProperty> get supportedProperties => List.unmodifiable(
    database.properties.where(
      (p) => databaseFormPropertyTypes.contains(p.type) && !p.isComputed,
    ),
  );
  DatabaseForm getForm(String formId) {
    _id(formId);
    for (final form in forms) {
      if (form.id == formId) return form;
    }
    _raise('missing_form', '폼을 찾을 수 없습니다.');
  }

  void validateForm(DatabaseForm form) {
    final properties = {
      for (final property in database.properties) property.id: property,
    };
    final prior = <String, DatabaseFormQuestion>{};
    final used = <String>{};
    for (final question in form.questions) {
      final property = properties[question.propertyId];
      if (property == null)
        _raise('missing_property', '질문에 연결된 속성이 삭제되었습니다.', question: question);
      if (!databaseFormPropertyTypes.contains(property.type) ||
          property.isComputed)
        _raise(
          'unsupported_property',
          '이 속성은 폼 입력을 지원하지 않습니다.',
          question: question,
        );
      if (!used.add(question.propertyId))
        _raise(
          'duplicate_property',
          '속성마다 질문을 하나만 연결할 수 있습니다.',
          question: question,
        );
      if (question.visibleWhen != null)
        _validateCondition(question.visibleWhen!, question, prior, properties);
      prior[question.id] = question;
    }
  }

  WorkspaceDatabase putForm(DatabaseForm form) {
    validateForm(form);
    final current = forms;
    final exists = current.any((f) => f.id == form.id);
    if (!exists && current.length >= 64)
      _raise('form_limit', '데이터베이스당 폼은 64개까지 만들 수 있습니다.');
    return WorkspaceDatabase.fromJson({
      ...database.toJson(),
      'forms': [
        for (final existing in current)
          if (existing.id == form.id) form.toJson() else existing.toJson(),
        if (!exists) form.toJson(),
      ],
    });
  }

  DatabaseFormPreview preview(String formId, Map<String, Object?> answers) {
    final form = getForm(formId);
    validateForm(form);
    if (form.archived) _raise('archived_form', '보관된 폼은 새 응답을 받지 않습니다.');
    final copied = _copyMap(answers);
    final acceptedProperties = form.questions.map((q) => q.propertyId).toSet();
    for (final propertyId in copied.keys) {
      if (!acceptedProperties.contains(propertyId))
        _raise(
          'unknown_answer',
          '이 폼에 없는 속성의 응답이 있습니다.',
          propertyId: propertyId,
        );
    }
    final properties = {
      for (final property in database.properties) property.id: property,
    };
    final visibleQuestions = <DatabaseFormQuestion>[];
    final prior = <String, DatabaseFormQuestion>{};
    final values = <String, Object?>{};
    final errors = <DatabaseFormException>[];
    for (final question in form.questions) {
      final visible =
          question.visibleWhen == null ||
          _matches(question.visibleWhen!, prior, values);
      prior[question.id] = question;
      if (!visible) continue;
      visibleQuestions.add(question);
      final value = copied[question.propertyId];
      if (question.required && _empty(value)) {
        errors.add(
          DatabaseFormException(
            'required',
            '필수 질문에 응답해 주세요.',
            propertyId: question.propertyId,
            questionId: question.id,
          ),
        );
        continue;
      }
      try {
        properties[question.propertyId]!.validateValue(value);
      } on FormatException {
        errors.add(
          DatabaseFormException(
            'invalid_answer',
            '속성에 맞는 값을 입력해 주세요.',
            propertyId: question.propertyId,
            questionId: question.id,
          ),
        );
        continue;
      }
      if (copied.containsKey(question.propertyId))
        values[question.propertyId] = value;
    }
    return DatabaseFormPreview._(visibleQuestions, values, errors);
  }

  DatabaseFormSubmission prepareSubmission({
    required String formId,
    required Map<String, Object?> answers,
    required String requestId,
    required String inputRevision,
    required DateTime capturedAt,
  }) {
    _id(formId);
    _id(requestId, 'invalid_request_id');
    _id(inputRevision, 'invalid_input_revision');
    if (!capturedAt.isUtc) _raise('utc_required', '응답 시각은 UTC로 전달해야 합니다.');
    final copied = _copyMap(answers);
    final digest = _digest({'formId': formId, 'answers': copied});
    final receipts = submissions;
    for (final receipt in receipts) {
      if (receipt.requestId != requestId) continue;
      if (receipt.formId != formId || receipt.answersDigest != digest)
        _raise('request_conflict', '같은 요청 ID를 다른 응답에 사용할 수 없습니다.');
      if (receipt.rowId != _rowId(database.id, formId, requestId))
        _raise('invalid_receipt', '응답 기록과 행 ID가 일치하지 않습니다.');
      if (!database.rows.any((r) => r.id == receipt.rowId))
        _raise('missing_submission_row', '기존 응답의 행이 삭제되었습니다.');
      return DatabaseFormSubmission._(
        database: database,
        rowId: receipt.rowId,
        duplicate: true,
        receipt: receipt,
      );
    }
    final previewed = preview(formId, copied);
    if (!previewed.isValid) throw previewed.errors.first;
    if (receipts.length >= 10000)
      _raise('submission_limit', '폼 응답 기록 한도를 넘었습니다.');
    final rowId = _rowId(database.id, formId, requestId);
    if (database.rows.any((r) => r.id == rowId))
      _raise('row_identity_conflict', '응답의 행 ID가 기존 행과 충돌합니다.');
    final receipt = DatabaseFormReceipt._fromJson({
      'formId': formId,
      'requestId': requestId,
      'rowId': rowId,
      'inputRevision': inputRevision,
      'submittedAt': capturedAt.toIso8601String(),
      'answersDigest': digest,
      'formDigest': _digest(getForm(formId).toJson()),
    });
    final updated = database.addRow(
      DatabaseRow.create(id: rowId, values: previewed.values),
    );
    final result = WorkspaceDatabase.fromJson({
      ...updated.toJson(),
      'formSubmissions': [
        for (final previous in receipts) previous.toJson(),
        receipt.toJson(),
      ],
    });
    return DatabaseFormSubmission._(
      database: result,
      rowId: rowId,
      duplicate: false,
      receipt: receipt,
    );
  }
}

void _validateCondition(
  Map<String, dynamic> condition,
  DatabaseFormQuestion question,
  Map<String, DatabaseFormQuestion> prior,
  Map<String, DatabaseProperty> properties,
) {
  var nodes = 0;
  void visit(Map<String, dynamic> node, int depth) {
    if (++nodes > 128 || depth > 16)
      _raise('condition_limit', '표시 조건의 깊이나 개수 한도를 넘었습니다.', question: question);
    final logical = ['and', 'or', 'not'].where(node.containsKey).toList();
    if (logical.isNotEmpty) {
      if (logical.length != 1 ||
          node.containsKey('questionId') ||
          node.containsKey('operator'))
        _raise(
          'invalid_condition',
          '표시 조건의 구조가 올바르지 않습니다.',
          question: question,
        );
      final op = logical.single;
      if (op == 'not') {
        visit(_object(node[op]), depth + 1);
        return;
      }
      final children = _list(node[op]);
      if (children.isEmpty || children.length > 128)
        _raise(
          'invalid_condition',
          '논리 조건에는 하위 조건이 필요합니다.',
          question: question,
        );
      for (final child in children) {
        visit(_object(child), depth + 1);
      }
      return;
    }
    final ref = node['questionId'];
    final target = ref is String ? prior[ref] : null;
    if (target == null)
      _raise(
        'invalid_condition_reference',
        '표시 조건은 앞선 질문만 참조할 수 있습니다.',
        question: question,
      );
    final op = node['operator'];
    if (!['eq', 'notEq', 'contains', 'isEmpty', 'isNotEmpty'].contains(op))
      _raise('unsupported_condition', '지원하지 않는 표시 조건입니다.', question: question);
    if (op == 'isEmpty' || op == 'isNotEmpty') return;
    if (!node.containsKey('value'))
      _raise('invalid_condition_value', '비교할 값이 필요합니다.', question: question);
    final property = properties[target.propertyId]!;
    final value = node['value'];
    try {
      if (op == 'contains') {
        if (property.type == 'multiSelect') {
          if (value is! String) throw const FormatException();
          property.validateValue([value]);
        } else if ([
          'title',
          'text',
          'phone',
          'url',
          'email',
          'status',
          'select',
        ].contains(property.type)) {
          if (value is! String) throw const FormatException();
        } else {
          throw const FormatException();
        }
      } else {
        property.validateValue(value);
      }
    } on FormatException {
      _raise(
        'invalid_condition_value',
        '표시 조건의 비교 값이 속성 형식과 맞지 않습니다.',
        question: question,
      );
    }
  }

  visit(condition, 0);
}

bool _matches(
  Map<String, dynamic> condition,
  Map<String, DatabaseFormQuestion> prior,
  Map<String, Object?> values,
) {
  if (condition.containsKey('and'))
    return (condition['and'] as List).every(
      (n) => _matches(_object(n), prior, values),
    );
  if (condition.containsKey('or'))
    return (condition['or'] as List).any(
      (n) => _matches(_object(n), prior, values),
    );
  if (condition.containsKey('not'))
    return !_matches(_object(condition['not']), prior, values);
  final question = prior[condition['questionId']]!;
  final value = values[question.propertyId], compared = condition['value'];
  return switch (condition['operator']) {
    'eq' => _equal(value, compared),
    'notEq' => !_equal(value, compared),
    'isEmpty' => _empty(value),
    'isNotEmpty' => !_empty(value),
    'contains' =>
      value is String && compared is String
          ? value.contains(compared)
          : value is List && value.any((v) => _equal(v, compared)),
    _ => false,
  };
}

bool _empty(Object? value) =>
    value == null ||
    value == '' ||
    value is List && value.isEmpty ||
    value is Map && value.isEmpty;
bool _equal(Object? a, Object? b) {
  if (a is List && b is List)
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _equal(a[i], b[i]));
  if (a is Map && b is Map)
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _equal(a[k], b[k]));
  return a == b;
}

String _digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
Object? _canonical(Object? value) {
  if (value is List) return [for (final item in value) _canonical(item)];
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  return value;
}

String _rowId(String databaseId, String formId, String requestId) {
  const namespace = '9c6dfd841c2d5a3aa78ce46cd3368f16';
  final bytes = [
    for (var i = 0; i < namespace.length; i += 2)
      int.parse(namespace.substring(i, i + 2), radix: 16),
    ...utf8.encode(jsonEncode([databaseId, formId, requestId])),
  ];
  final hash = sha1.convert(bytes).bytes.take(16).toList();
  hash[6] = (hash[6] & 0x0f) | 0x50;
  hash[8] = (hash[8] & 0x3f) | 0x80;
  final hex = hash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Never _raise(
  String code,
  String message, {
  DatabaseFormQuestion? question,
  String? propertyId,
}) => throw DatabaseFormException(
  code,
  message,
  propertyId: propertyId ?? question?.propertyId,
  questionId: question?.id,
);
String _id(Object? value, [String code = 'invalid_id']) {
  if (value is! String ||
      !RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(value))
    _raise(code, '올바른 UUID가 필요합니다.');
  return value;
}

void _text(Object? value, String code) {
  if (value is! String || value.trim().isEmpty)
    _raise(code, '비어 있지 않은 문자가 필요합니다.');
}

List<dynamic> _list(Object? value) {
  if (value is! List) _raise('invalid_json', 'JSON 배열이 필요합니다.');
  return value;
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map || value.keys.any((k) => k is! String))
    _raise('invalid_json', 'JSON 객체가 필요합니다.');
  return Map<String, dynamic>.from(value);
}

Map<String, dynamic> _copyMap(Map<String, Object?> value) {
  var units = 0, nodes = 0;
  Object? copy(Object? item, int depth) {
    if (++nodes > 10000 || depth > 64)
      _raise('size_limit', 'JSON 구조 한도를 넘었습니다.');
    if (item is String) {
      units += item.length;
    }
    if (units > 1000000) _raise('size_limit', 'JSON 크기 한도를 넘었습니다.');
    if (item == null || item is String || item is bool) return item;
    if (item is num) {
      if (!item.isFinite) _raise('invalid_json', '유한한 JSON 숫자가 필요합니다.');
      return item;
    }
    if (item is List) return [for (final child in item) copy(child, depth + 1)];
    if (item is Map) {
      final object = _object(item);
      return {
        for (final entry in object.entries)
          (copy(entry.key, depth + 1) as String): copy(entry.value, depth + 1),
      };
    }
    _raise('invalid_json', 'JSON 값만 저장할 수 있습니다.');
  }

  return copy(value, 0) as Map<String, dynamic>;
}

Map<String, dynamic> _freezeMap(Map<String, Object?> value) =>
    Map<String, dynamic>.unmodifiable({
      for (final entry in value.entries) entry.key: _freeze(entry.value),
    });
Object? _freeze(Object? value) {
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  if (value is Map) return _freezeMap(_object(value));
  return value;
}
