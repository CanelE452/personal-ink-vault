import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/data/vault/database_forms.dart';
import 'package:saber/data/vault/workspace_database.dart';

class DatabaseFormsPanel extends StatefulWidget {
  const new({
    super.key,
    required this.initialDatabase,
    required this.onSave,
    required this.currentRevision,
    required this.onBack,
    this.onDirtyChanged,
    this.onBusyChanged,
    this.prepareSubmission,
  });
  final WorkspaceDatabase initialDatabase;
  final Future<void> Function(WorkspaceDatabase) onSave;
  final String Function() currentRevision;
  final VoidCallback onBack;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<bool>? onBusyChanged;
  final DatabaseFormSubmission Function(DatabaseFormSubmission)?
  prepareSubmission;
  @override
  State<DatabaseFormsPanel> createState() => DatabaseFormsPanelState();
}

class DatabaseFormsPanelState extends State<DatabaseFormsPanel> {
  static const _teal = Color(0xff237d82);
  late WorkspaceDatabase _database;
  String? _selected;
  Map<String, dynamic>? _draft;
  var _mode = 'edit';
  String? _error;
  String? _addProperty;
  var _generation = 0, _savedGeneration = 0, _responseAttempt = 0;
  var _saving = false, _responseActive = false, _showAnswerErrors = false;
  var _reportedDirty = false, _reportedBusy = false;
  Future<void>? _saveFuture;
  DatabaseFormSubmission? _prepared;
  DatabaseFormReceipt? _lastReceipt;
  final _answers = <String, Object?>{};
  final _controllers = <String, TextEditingController>{};

  WorkspaceDatabase get database => _database;
  bool get _dirty => _generation != _savedGeneration || _responseActive;
  bool get _locked => _prepared != null;
  List<Map<String, dynamic>> get _questions => [
    for (final q in (_draft?['questions'] as List? ?? []))
      Map<String, dynamic>.from(q as Map),
  ];
  DatabaseForms get _forms => DatabaseForms(_database);

  @override
  void initState() {
    super.initState();
    _database = widget.initialDatabase;
    try {
      final first = _forms.forms.firstOrNull;
      if (first != null) {
        _selected = first.id;
        _draft = first.toJson();
      }
    } catch (error) {
      _error = _message(error);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _message(Object error) => error is DatabaseFormException
      ? error.message
      : error is StateError
      ? error.message
      : '$error';
  void _report() {
    if (!mounted) return;
    if (_reportedDirty != _dirty) {
      _reportedDirty = _dirty;
      widget.onDirtyChanged?.call(_dirty);
    }
    if (_reportedBusy != _saving) {
      _reportedBusy = _saving;
      widget.onBusyChanged?.call(_saving);
    }
  }

  void _touch(void Function() action) {
    if (_locked) return;
    setState(() {
      action();
      _generation++;
      _error = null;
      _lastReceipt = null;
    });
    _report();
  }

  void _run(void Function() action) {
    try {
      action();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  TextEditingController _controller(String id, String initial) =>
      _controllers.putIfAbsent(id, () => TextEditingController(text: initial));
  void _forget(String prefix) {
    final removed = [
      for (final key
          in _controllers.keys.where((key) => key.startsWith(prefix)).toList())
        _controllers.remove(key)!,
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final controller in removed) {
        controller.dispose();
      }
    });
  }

  void _applyDraft() {
    final raw = _draft;
    if (raw != null) _database = _forms.putForm(DatabaseForm.fromJson(raw));
  }

  void _select(String id) {
    if (_responseActive) throw StateError('작성 중인 응답을 제출하거나 취소해 주세요.');
    _applyDraft();
    final form = _forms.getForm(id);
    setState(() {
      _selected = id;
      _draft = form.toJson();
      _mode = 'edit';
      _error = null;
      _addProperty = null;
      _lastReceipt = null;
    });
  }

  void _create() {
    if (_responseActive) throw StateError('작성 중인 응답을 제출하거나 취소해 주세요.');
    _applyDraft();
    final title = _forms.supportedProperties
        .where((p) => p.type == 'title')
        .firstOrNull;
    final form = DatabaseForm.create(
      title: '새 폼',
      questions: [
        if (title != null)
          DatabaseFormQuestion.create(
            propertyId: title.id,
            label: title.name,
            required: true,
          ),
      ],
    );
    final next = _forms.putForm(form);
    _touch(() {
      _database = next;
      _selected = form.id;
      _draft = form.toJson();
      _mode = 'edit';
      _addProperty = null;
    });
  }

  void _question(int index, String key, Object? value) => _touch(() {
    final questions = _questions;
    questions[index][key] = value;
    _draft!['questions'] = questions;
  });
  void _move(int index, int offset) => _touch(() {
    final questions = _questions;
    final target = index + offset;
    if (target < 0 || target >= questions.length) return;
    final q = questions.removeAt(index);
    questions.insert(target, q);
    _draft!['questions'] = questions;
  });
  void _addQuestion() {
    final used = _questions.map((q) => q['propertyId']).toSet();
    final available = _forms.supportedProperties
        .where((p) => !used.contains(p.id))
        .toList();
    final property =
        available.where((p) => p.id == _addProperty).firstOrNull ??
        available.firstOrNull;
    if (property == null) return;
    _touch(() {
      _draft!['questions'] = [
        ..._questions,
        DatabaseFormQuestion.create(
          propertyId: property.id,
          label: property.name,
        ).toJson(),
      ];
      _addProperty = null;
    });
  }

  Future<void> save() {
    final current = _saveFuture;
    if (current != null) return current;
    if (_responseActive && _prepared == null) {
      final error = StateError('작성 중인 응답을 제출하거나 취소해 주세요.');
      if (mounted) setState(() => _error = _message(error));
      return Future.error(error);
    }
    return _saveTracked();
  }

  Future<void> _saveTracked() {
    final current = _saveFuture;
    if (current != null) return current;
    late Future<void> tracked;
    tracked = _flush().whenComplete(() {
      if (identical(_saveFuture, tracked)) _saveFuture = null;
    });
    _saveFuture = tracked;
    return tracked;
  }

  Future<void> _flush() async {
    _saving = true;
    if (mounted) {
      setState(() => _error = null);
      _report();
    }
    try {
      while (_generation != _savedGeneration || _prepared != null) {
        final prepared = _prepared;
        final generation = _generation;
        if (prepared == null) _applyDraft();
        final snapshot = prepared?.database ?? _database;
        await widget.onSave(snapshot);
        _savedGeneration = generation;
        if (prepared != null) {
          _database = snapshot;
          _lastReceipt = prepared.receipt;
          _prepared = null;
          _responseActive = false;
          _mode = 'preview';
          _answers.clear();
          _showAnswerErrors = false;
        }
        _report();
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
      rethrow;
    } finally {
      _saving = false;
      if (mounted) {
        setState(() {});
        _report();
      }
    }
  }

  Future<void> _saveFromUi() async {
    try {
      await save();
    } catch (_) {}
  }

  Future<void> _back() async {
    try {
      await save();
      if (mounted) widget.onBack();
    } catch (_) {}
  }

  void _showMode(String mode) {
    if (_responseActive) throw StateError('작성 중인 응답을 제출하거나 취소해 주세요.');
    _applyDraft();
    setState(() {
      _mode = mode;
      _error = null;
    });
  }

  void _startResponse() {
    if (_responseActive || _saving) return;
    _applyDraft();
    final form = _forms.getForm(_selected!);
    if (form.archived) throw StateError('보관된 폼은 응답을 받지 않습니다.');
    _forget('response-');
    setState(() {
      _mode = 'respond';
      _responseActive = true;
      _responseAttempt++;
      _showAnswerErrors = false;
      _error = null;
      _lastReceipt = null;
      _answers.clear();
      for (final question in form.questions) {
        final property = _database.properties
            .where((p) => p.id == question.propertyId)
            .firstOrNull;
        if (property?.type == 'checkbox') _answers[question.propertyId] = false;
      }
    });
    _report();
  }

  void _cancelResponse() {
    if (_prepared != null) throw StateError('제출한 응답 저장을 재시도해 주세요.');
    setState(() {
      _responseActive = false;
      _mode = 'edit';
      _answers.clear();
      _showAnswerErrors = false;
      _error = null;
    });
    _report();
  }

  void _answer(String propertyId, Object? value) {
    if (_locked) return;
    setState(() {
      _answers[propertyId] = value;
      _error = null;
    });
    _report();
  }

  Future<void> _submit() async {
    if (_saving) return;
    try {
      if (_prepared == null) {
        _applyDraft();
        final preview = _forms.preview(_selected!, _answers);
        setState(() => _showAnswerErrors = true);
        if (!preview.isValid) return;
        var prepared = _forms.prepareSubmission(
          formId: _selected!,
          answers: _answers,
          requestId: newId(),
          inputRevision: widget.currentRevision(),
          capturedAt: DateTime.now().toUtc(),
        );
        final transform = widget.prepareSubmission;
        if (transform != null) {
          prepared = prepared.withDatabase(transform(prepared).database);
        }
        setState(() => _prepared = prepared);
      }
      await _saveTracked();
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    List<DatabaseForm> forms = [];
    try {
      forms = _forms.forms;
    } catch (_) {}
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              IconButton(
                tooltip: '데이터베이스로 돌아가기',
                onPressed: _saving ? null : () => unawaited(_back()),
                icon: const Icon(Icons.arrow_back),
              ),
              const Text(
                '데이터베이스 폼',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              FilledButton.tonal(
                key: const ValueKey('forms-create'),
                onPressed: _saving || _responseActive
                    ? null
                    : () => _run(_create),
                child: const Text('새 폼'),
              ),
              FilledButton(
                key: const ValueKey('forms-save'),
                onPressed: _saving ? null : () => unawaited(_saveFromUi()),
                child: Text(_saving ? '저장 중' : '변경 저장'),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _error!,
              key: const ValueKey('forms-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final content = SingleChildScrollView(
                key: const ValueKey('forms-content'),
                padding: const EdgeInsets.all(16),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 860),
                    child: _content(),
                  ),
                ),
              );
              if (constraints.maxWidth >= 850)
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 210,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        children: [
                          for (final form in forms)
                            ListTile(
                              key: ValueKey('forms-select-${form.id}'),
                              selected: form.id == _selected,
                              selectedColor: _teal,
                              title: Text(form.title),
                              subtitle: form.archived
                                  ? const Text('보관됨')
                                  : null,
                              onTap: _saving || _responseActive
                                  ? null
                                  : () => _run(() => _select(form.id)),
                            ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: content),
                  ],
                );
              return Column(
                children: [
                  if (forms.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                      child: DropdownButtonFormField<String>(
                        key: const ValueKey('forms-select'),
                        initialValue: _selected,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: '폼 선택',
                          isDense: true,
                        ),
                        items: [
                          for (final form in forms)
                            DropdownMenuItem(
                              value: form.id,
                              child: Text(
                                '${form.title}${form.archived ? ' (보관됨)' : ''}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: _saving || _responseActive
                            ? null
                            : (id) {
                                if (id != null) _run(() => _select(id));
                              },
                      ),
                    ),
                  Expanded(child: content),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _content() {
    final draft = _draft;
    if (draft == null)
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('이 앱 안에서 응답을 받는 폼입니다.'),
          SizedBox(height: 16),
          Text('새 폼을 만들고 데이터베이스 속성을 질문으로 연결하세요.'),
        ],
      );
    final archived = draft['archived'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('이 앱 안에서 응답을 받습니다. 응답 하나가 데이터베이스 행 하나로 저장됩니다.'),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            TextButton(
              key: const ValueKey('forms-edit'),
              onPressed: _responseActive
                  ? null
                  : () => _run(() => _showMode('edit')),
              child: const Text('정의 편집'),
            ),
            TextButton(
              key: const ValueKey('forms-preview'),
              onPressed: _responseActive
                  ? null
                  : () => _run(() => _showMode('preview')),
              child: const Text('미리보기'),
            ),
            FilledButton.tonal(
              key: const ValueKey('forms-respond'),
              onPressed: _responseActive || _saving || archived
                  ? null
                  : () => _run(_startResponse),
              child: const Text('응답 작성'),
            ),
            if (_mode == 'edit')
              TextButton(
                key: const ValueKey('forms-archive'),
                onPressed: _locked
                    ? null
                    : () => _touch(() => _draft!['archived'] = !archived),
                child: Text(archived ? '보관 해제' : '폼 보관'),
              ),
          ],
        ),
        if (_lastReceipt != null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              '응답이 저장되었습니다.',
              key: ValueKey('forms-submitted'),
              style: TextStyle(color: _teal, fontWeight: FontWeight.w600),
            ),
          ),
        const SizedBox(height: 12),
        if (_mode == 'edit')
          ..._definition()
        else if (_mode == 'respond')
          ..._response()
        else
          ..._preview(),
      ],
    );
  }

  List<Widget> _definition() {
    final used = _questions.map((q) => q['propertyId']).toSet();
    final available = _forms.supportedProperties
        .where((p) => !used.contains(p.id))
        .toList();
    return [
      _textField(
        'forms-title-$_selected',
        '${_draft!['title']}',
        '폼 제목',
        (value) => _touch(() => _draft!['title'] = value),
      ),
      const SizedBox(height: 10),
      _textField(
        'forms-description-$_selected',
        '${_draft!['description'] ?? ''}',
        '설명',
        (value) => _touch(() => _draft!['description'] = value),
        maxLines: 2,
      ),
      const SizedBox(height: 16),
      const Text(
        '질문',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      for (var i = 0; i < _questions.length; i++) _questionCard(i),
      const SizedBox(height: 12),
      if (available.isNotEmpty) ...[
        DropdownButtonFormField<String>(
          key: const ValueKey('forms-add-property'),
          initialValue: available.any((p) => p.id == _addProperty)
              ? _addProperty
              : available.first.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '연결할 속성'),
          items: [
            for (final p in available)
              DropdownMenuItem(
                value: p.id,
                child: Text(p.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (value) => setState(() => _addProperty = value),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('forms-add-question'),
            onPressed: _addQuestion,
            icon: const Icon(Icons.add),
            label: const Text('질문 추가'),
          ),
        ),
      ],
      const Text('계산·관계·담당자·파일 속성은 폼 질문으로 연결할 수 없습니다.'),
    ];
  }

  Widget _questionCard(int index) {
    final questions = _questions, q = questions[index], id = q['id'] as String;
    final property = _database.properties
        .where((p) => p.id == q['propertyId'])
        .firstOrNull;
    final prior = questions.take(index).toList();
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            property?.name ?? '삭제된 속성',
            style: const TextStyle(color: _teal),
          ),
          const SizedBox(height: 6),
          _textField(
            'forms-question-label-$id',
            '${q['label']}',
            '질문 문구',
            (value) => _question(index, 'label', value),
          ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 4,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    key: ValueKey('forms-question-required-$id'),
                    value: q['required'] == true,
                    onChanged: (value) =>
                        _question(index, 'required', value ?? false),
                  ),
                  const Text('필수'),
                ],
              ),
              IconButton(
                key: ValueKey('forms-question-up-$id'),
                tooltip: '질문 위로',
                onPressed: index == 0 ? null : () => _move(index, -1),
                icon: const Icon(Icons.arrow_upward, size: 20),
              ),
              IconButton(
                key: ValueKey('forms-question-down-$id'),
                tooltip: '질문 아래로',
                onPressed: index == questions.length - 1
                    ? null
                    : () => _move(index, 1),
                icon: const Icon(Icons.arrow_downward, size: 20),
              ),
              IconButton(
                key: ValueKey('forms-question-remove-$id'),
                tooltip: '질문 제거',
                onPressed: () => _touch(() {
                  final next = _questions..removeAt(index);
                  _draft!['questions'] = next;
                }),
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
          ExpansionTile(
            key: ValueKey('forms-condition-editor-$id'),
            tilePadding: EdgeInsets.zero,
            title: const Text('표시 조건'),
            subtitle: Text(
              q['visibleWhen'] == null
                  ? '항상 표시'
                  : _conditionSummary(
                      Map<String, dynamic>.from(q['visibleWhen'] as Map),
                      prior,
                    ),
            ),
            children: [
              if (q['visibleWhen'] != null)
                _conditionTree(
                  id,
                  'root',
                  Map<String, dynamic>.from(q['visibleWhen'] as Map),
                  prior,
                  (value) => _question(index, 'visibleWhen', value),
                )
              else if (prior.isNotEmpty)
                TextButton(
                  onPressed: () =>
                      _question(index, 'visibleWhen', _defaultCondition(prior)),
                  child: const Text('조건 추가'),
                )
              else
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('앞선 질문이 있을 때 표시 조건을 추가할 수 있습니다.'),
                ),
              if (q['visibleWhen'] != null)
                TextButton(
                  onPressed: () => _question(index, 'visibleWhen', null),
                  child: const Text('표시 조건 제거'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _textField(
    String id,
    String initial,
    String label,
    ValueChanged<String> onChanged, {
    int maxLines = 1,
    String? storageKey,
    TextInputType? keyboardType,
    bool enabled = true,
  }) => TextField(
    key: ValueKey(id),
    controller: _controller(storageKey ?? id, initial),
    enabled: enabled,
    keyboardType: keyboardType,
    maxLines: maxLines,
    decoration: InputDecoration(
      labelText: label,
      border: const OutlineInputBorder(),
      isDense: true,
    ),
    onChanged: onChanged,
  );

  List<Widget> _preview() => [
    Text(
      '${_draft!['title']}',
      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
    ),
    if ('${_draft!['description'] ?? ''}'.isNotEmpty)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text('${_draft!['description']}'),
      ),
    const Text('읽기 전용 미리보기 · 조건부 질문은 응답에 따라 표시됩니다.'),
    for (final q in _questions)
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('${q['label']}${q['required'] == true ? ' *' : ''}'),
        subtitle: Text(q['visibleWhen'] == null ? '항상 표시' : '조건부 질문'),
      ),
  ];
  List<Widget> _response() {
    DatabaseFormPreview? preview;
    try {
      preview = _forms.preview(_selected!, _answers);
    } catch (error) {
      return [
        Text(_message(error)),
        const SizedBox(height: 12),
        TextButton(
          key: const ValueKey('forms-cancel-response'),
          onPressed: _saving || _locked ? null : _cancelResponse,
          child: const Text('응답 취소'),
        ),
      ];
    }
    final errors = {
      if (_showAnswerErrors)
        for (final error in preview.errors) error.propertyId: error.message,
    };
    return [
      Text(
        '${_draft!['title']}',
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
      ),
      if ('${_draft!['description'] ?? ''}'.isNotEmpty)
        Text('${_draft!['description']}'),
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text('숨겨진 답변은 저장·후속 조건 판단에서 제외됩니다. 필수 질문은 표시될 때만 응답합니다.'),
      ),
      for (final q in preview.visibleQuestions) ...[
        _rawInput(
          _database.properties.firstWhere((p) => p.id == q.propertyId),
          _answers[q.propertyId],
          '${q.label}${q.required ? ' *' : ''}',
          'forms-answer-${q.propertyId}',
          'response-$_responseAttempt-${q.propertyId}',
          (value) => _answer(q.propertyId, value),
          enabled: !_locked,
        ),
        if (errors[q.propertyId] != null)
          Text(
            errors[q.propertyId]!,
            key: ValueKey('forms-field-error-${q.propertyId}'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 16),
      ],
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton(
            key: const ValueKey('forms-submit'),
            onPressed: _saving ? null : () => unawaited(_submit()),
            child: Text(_prepared == null ? '응답 제출' : '저장 재시도'),
          ),
          TextButton(
            key: const ValueKey('forms-cancel-response'),
            onPressed: _saving || _locked ? null : _cancelResponse,
            child: const Text('응답 취소'),
          ),
        ],
      ),
    ];
  }

  List<({String id, String name})> _options(DatabaseProperty property) => [
    for (final option in property.config['options'] as List? ?? [])
      if (option is String)
        (id: option, name: option)
      else if (option is Map && option['id'] is String)
        (id: option['id'] as String, name: '${option['name'] ?? option['id']}'),
  ];
  Widget _rawInput(
    DatabaseProperty property,
    Object? value,
    String label,
    String key,
    String storageKey,
    ValueChanged<Object?> onChanged, {
    bool enabled = true,
  }) {
    final options = _options(property);
    if (property.type == 'checkbox')
      return CheckboxListTile(
        key: ValueKey(key),
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        controlAffinity: ListTileControlAffinity.leading,
        value: value == true,
        onChanged: enabled ? (value) => onChanged(value ?? false) : null,
      );
    if (['status', 'select'].contains(property.type) && options.isNotEmpty)
      return DropdownButtonFormField<String>(
        key: ValueKey(key),
        initialValue: value is String && options.any((o) => o.id == value)
            ? value
            : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: [
          const DropdownMenuItem(value: '', child: Text('선택 안 함')),
          for (final option in options)
            DropdownMenuItem(
              value: option.id,
              child: Text(option.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: enabled ? (value) => onChanged(value) : null,
      );
    if (property.type == 'multiSelect' && options.isNotEmpty)
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final option in options)
                FilterChip(
                  key: ValueKey(
                    '${key.replaceFirst('forms-answer-', 'forms-answer-option-')}-${option.id}',
                  ),
                  label: Text(option.name),
                  selected: value is List && value.contains(option.id),
                  onSelected: enabled
                      ? (selected) {
                          final current = value is List
                              ? value.cast<String>().toList()
                              : <String>[];
                          if (selected) {
                            current.add(option.id);
                          } else {
                            current.remove(option.id);
                          }
                          onChanged(current);
                        }
                      : null,
                ),
            ],
          ),
        ],
      );
    if (property.type == 'date') {
      final range = value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
      final start = value is String
          ? value
          : '${range['start'] ?? range['dateISO'] ?? ''}';
      void update(String part, String text) {
        if (part == 'start' &&
            range['end'] == null &&
            range['timeZone'] == null) {
          onChanged(text.isEmpty ? null : text);
          return;
        }
        final next = {...range, 'start': start};
        if (text.isEmpty && part != 'start') {
          next.remove(part);
        } else {
          next[part] = text;
        }
        onChanged(
          next['end'] == null && next['timeZone'] == null
              ? next['start']
              : next,
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _textField(
            key,
            start,
            '$label (ISO 날짜)',
            (text) => update('start', text),
            storageKey: storageKey,
            enabled: enabled,
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('기간·시간대'),
            children: [
              _textField(
                '$key-end',
                '${range['end'] ?? ''}',
                '종료 날짜 (선택)',
                (text) => update('end', text),
                storageKey: '$storageKey-end',
                enabled: enabled,
              ),
              const SizedBox(height: 8),
              _textField(
                '$key-zone',
                '${range['timeZone'] ?? ''}',
                '시간대 이름 (선택)',
                (text) => update('timeZone', text),
                storageKey: '$storageKey-zone',
                enabled: enabled,
              ),
            ],
          ),
        ],
      );
    }
    final initial = value == null
        ? ''
        : property.type == 'multiSelect' && value is List
        ? value.join(', ')
        : '$value';
    return _textField(
      key,
      initial,
      property.type == 'multiSelect' ? '$label (쉼표로 구분)' : label,
      (text) {
        if (property.type == 'number') {
          final number = num.tryParse(text);
          onChanged(
            text.isEmpty
                ? null
                : number != null && number.isFinite
                ? number
                : text,
          );
        } else if (property.type == 'multiSelect') {
          onChanged(
            text
                .split(',')
                .map((v) => v.trim())
                .where((v) => v.isNotEmpty)
                .toSet()
                .toList(),
          );
        } else {
          onChanged(text);
        }
      },
      storageKey: storageKey,
      enabled: enabled,
      maxLines: property.type == 'text' ? 3 : 1,
      keyboardType: switch (property.type) {
        'number' => const TextInputType.numberWithOptions(
          decimal: true,
          signed: true,
        ),
        'url' => TextInputType.url,
        'email' => TextInputType.emailAddress,
        'phone' => TextInputType.phone,
        _ => TextInputType.text,
      },
    );
  }

  Map<String, dynamic> _defaultCondition(List<Map<String, dynamic>> prior) => {
    'questionId': prior.first['id'],
    'operator': 'isNotEmpty',
  };
  String _conditionSummary(
    Map<String, dynamic> condition,
    List<Map<String, dynamic>> prior,
  ) {
    if (condition.containsKey('and')) return '모두 만족';
    if (condition.containsKey('or')) return '하나 이상 만족';
    if (condition.containsKey('not')) return '반대로';
    final ref = prior
        .where((q) => q['id'] == condition['questionId'])
        .firstOrNull;
    return '${ref?['label'] ?? '삭제된 질문'} · ${_operatorLabel('${condition['operator']}')}';
  }

  String _operatorLabel(String op) => switch (op) {
    'eq' => '같음',
    'notEq' => '다름',
    'contains' => '포함',
    'isEmpty' => '비어 있음',
    'isNotEmpty' => '비어 있지 않음',
    _ => '지원하지 않는 조건',
  };
  Widget _conditionTree(
    String questionId,
    String path,
    Map<String, dynamic> node,
    List<Map<String, dynamic>> prior,
    ValueChanged<Map<String, dynamic>> onChanged,
  ) {
    final kind = node.containsKey('and')
        ? 'and'
        : node.containsKey('or')
        ? 'or'
        : node.containsKey('not')
        ? 'not'
        : 'leaf';
    final storage = 'condition-$questionId-$path';
    void replace(String nextKind) {
      _forget(storage);
      final next = {...node}
        ..removeWhere(
          (key, _) => [
            'and',
            'or',
            'not',
            'questionId',
            'operator',
            'value',
          ].contains(key),
        );
      if (nextKind == 'leaf') {
        next.addAll(_defaultCondition(prior));
      } else if (nextKind == 'not') {
        next['not'] = node;
      } else {
        next[nextKind] = [node];
      }
      onChanged(next);
    }

    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            key: ValueKey('forms-condition-kind-$questionId-$path'),
            initialValue: kind,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '조건 묶음',
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(value: 'leaf', child: Text('질문 비교')),
              DropdownMenuItem(value: 'and', child: Text('모두 만족')),
              DropdownMenuItem(value: 'or', child: Text('하나 이상 만족')),
              DropdownMenuItem(value: 'not', child: Text('반대로')),
            ],
            onChanged: prior.isEmpty
                ? null
                : (value) {
                    if (value != null && value != kind) replace(value);
                  },
          ),
          const SizedBox(height: 8),
          if (kind == 'and' || kind == 'or') ...[
            for (var i = 0; i < (node[kind] as List).length; i++)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _conditionTree(
                    questionId,
                    '$path-$i',
                    Map<String, dynamic>.from(node[kind][i] as Map),
                    prior,
                    (value) {
                      final children = List<dynamic>.from(node[kind] as List);
                      children[i] = value;
                      onChanged({...node, kind: children});
                    },
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: '하위 조건 제거',
                      onPressed: (node[kind] as List).length <= 1
                          ? null
                          : () {
                              final children = List<dynamic>.from(
                                node[kind] as List,
                              )..removeAt(i);
                              _forget(storage);
                              onChanged({...node, kind: children});
                            },
                      icon: const Icon(Icons.remove_circle_outline, size: 18),
                    ),
                  ),
                ],
              ),
            TextButton.icon(
              key: ValueKey('forms-condition-add-$questionId-$path'),
              onPressed: prior.isEmpty
                  ? null
                  : () => onChanged({
                      ...node,
                      kind: [...node[kind] as List, _defaultCondition(prior)],
                    }),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('하위 조건 추가'),
            ),
          ] else if (kind == 'not')
            _conditionTree(
              questionId,
              '$path-not',
              Map<String, dynamic>.from(node['not'] as Map),
              prior,
              (value) => onChanged({...node, 'not': value}),
            )
          else
            ..._conditionLeaf(questionId, path, node, prior, onChanged),
        ],
      ),
    );
  }

  List<Widget> _conditionLeaf(
    String questionId,
    String path,
    Map<String, dynamic> node,
    List<Map<String, dynamic>> prior,
    ValueChanged<Map<String, dynamic>> onChanged,
  ) {
    final ref = prior.where((q) => q['id'] == node['questionId']).firstOrNull;
    final property = _database.properties
        .where((p) => p.id == ref?['propertyId'])
        .firstOrNull;
    final op = '${node['operator']}';
    return [
      DropdownButtonFormField<String>(
        key: ValueKey('forms-condition-ref-$questionId-$path'),
        initialValue: ref?['id'] as String?,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '앞선 질문', isDense: true),
        items: [
          for (final q in prior)
            DropdownMenuItem(
              value: q['id'] as String,
              child: Text('${q['label']}', overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (value) {
          _forget('condition-$questionId-$path');
          onChanged(
            {...node, 'questionId': value, 'operator': 'isNotEmpty'}
              ..remove('value'),
          );
        },
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        key: ValueKey('forms-condition-op-$questionId-$path'),
        initialValue:
            ['eq', 'notEq', 'contains', 'isEmpty', 'isNotEmpty'].contains(op)
            ? op
            : null,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '비교 방법', isDense: true),
        items: [
          for (final operator in [
            'eq',
            'notEq',
            'contains',
            'isEmpty',
            'isNotEmpty',
          ])
            DropdownMenuItem(
              value: operator,
              child: Text(_operatorLabel(operator)),
            ),
        ],
        onChanged: (value) {
          _forget('condition-$questionId-$path');
          final next = {...node, 'operator': value};
          if (value == 'isEmpty' || value == 'isNotEmpty') {
            next.remove('value');
          } else {
            next['value'] = property?.type == 'checkbox'
                ? false
                : property?.type == 'number'
                ? 0
                : property?.type == 'multiSelect' && value != 'contains'
                ? <String>[]
                : '';
          }
          onChanged(next);
        },
      ),
      if (property != null && !['isEmpty', 'isNotEmpty'].contains(op)) ...[
        const SizedBox(height: 8),
        _rawInput(
          property.type == 'multiSelect' && op == 'contains'
              ? property.copyWith(type: 'select')
              : property,
          node['value'],
          '비교 값',
          'forms-condition-value-$questionId-$path',
          'condition-$questionId-$path',
          (value) => onChanged({...node, 'value': value}),
        ),
      ],
    ];
  }
}
