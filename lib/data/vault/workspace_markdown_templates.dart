import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/markdown_template.dart';
import 'package:saber/data/vault/workspace_store.dart';

final class WorkspaceMarkdownTemplateSettings {
  new _(
    this._repository,
    Iterable<String> revisionIds, {
    this.folderId,
    this.dateFormat = defaultDateFormat,
    this.timeFormat = defaultTimeFormat,
  }) : revisionIds = List.unmodifiable(revisionIds);

  static const defaultDateFormat = 'YYYY-MM-DD';
  static const defaultTimeFormat = 'HH:mm';

  final NoteRepository _repository;
  final String? folderId;
  final String dateFormat;
  final String timeFormat;
  final List<String> revisionIds;

  bool get conflicted => revisionIds.length > 1;
}

final class WorkspaceMarkdownTemplateChoice {
  new _(
    this._repository,
    this._folderId,
    this.noteId,
    this.label,
    this._markdown,
    this._guards,
  );

  final NoteRepository _repository;
  final String _folderId;
  final String noteId;
  final String label;
  final RevisionRecord _markdown;
  final Map<String, List<String>> _guards;
}

final class WorkspaceDailyNoteTemplateSettings {
  new _(
    this._repository,
    Iterable<String> revisionIds, {
    this.folderId,
    this.noteId,
  }) : revisionIds = List.unmodifiable(revisionIds);

  final NoteRepository _repository;
  final String? folderId;
  final String? noteId;
  final List<String> revisionIds;

  bool get conflicted => revisionIds.length > 1;
}

final class WorkspaceMarkdownTemplateStore {
  new(this.repository);

  final NoteRepository repository;

  // Scoped by the repository and retained when a vault is cloned.
  static const _settingsId = 'ed535140-6850-5d21-8c8f-e965c2bffb1a';
  static const _settingsFile = 'workspace-markdown-templates.json';
  static const _dailySettingsId = '4801145b-8a2b-5a3f-8d34-38a81fe793d1';
  static const _dailySettingsFile = 'workspace-daily-note-template.json';
  static const _settingsMaxBytes = 4096;
  static const _markdownFile = 'summary.md';
  static const _markdownMaxBytes = 1024 * 1024;
  static final _invalidFormat = RegExp(
    r'[\x00-\x1f\x7f-\x9f\ud800-\udfff]',
    unicode: true,
  );

  Future<WorkspaceMarkdownTemplateSettings> settings() async {
    final heads = await repository.heads(_settingsId);
    final observed = <WorkspaceMarkdownTemplateSettings>[];
    for (final head in heads) {
      observed.add(await _readSettings(head));
    }
    final ids = heads.map((head) => head.revisionId).toList();
    await _requireHeads({_settingsId: ids});
    return observed.length == 1
        ? observed.single
        : WorkspaceMarkdownTemplateSettings._(repository, ids);
  }

  Future<WorkspaceMarkdownTemplateSettings> saveSettings(
    WorkspaceMarkdownTemplateSettings prior, {
    required String? folderId,
    required String dateFormat,
    required String timeFormat,
    void Function()? beforePublish,
  }) async {
    if (repository.formatVersion != 2 ||
        !identical(prior._repository, repository)) {
      throw const FormatException('템플릿 설정을 저장할 보관함이 바뀌었습니다.');
    }
    _validateFormat(dateFormat);
    _validateFormat(timeFormat);
    final current = await settings();
    if (!_sameIds(current.revisionIds, prior.revisionIds)) {
      throw const FormatException('템플릿 설정이 바뀌었습니다. 다시 열어 주세요.');
    }
    final folderPath = folderId == null
        ? const <VaultFolder>[]
        : _requireFolderPath(await _liveFolders(), folderId);
    final prepared = repository.prepareCommit(
      entityId: _settingsId,
      kind: EntityKind.attachment,
      files: {
        _settingsFile: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'folderId': folderId,
              'dateFormat': dateFormat,
              'timeFormat': timeFormat,
            }),
          ),
        ),
      },
      parentRevisionIds: current.revisionIds,
    );
    final revision = await repository.commitPreparedIfHeads(
      prepared,
      expectedHeads: {
        _settingsId: current.revisionIds,
        for (final folder in folderPath)
          folder.id: [folder.revision.revisionId],
      },
      beforePublish: beforePublish,
    );
    return WorkspaceMarkdownTemplateSettings._(
      repository,
      [revision.revisionId],
      folderId: folderId,
      dateFormat: dateFormat,
      timeFormat: timeFormat,
    );
  }

  Future<List<({String id, String label})>> folders() async {
    if (repository.formatVersion != 2) return const [];
    final records = await repository.revisions();
    final live = await _liveFolders();
    final choices = <({String id, String label})>[];
    for (final id in live.keys) {
      final path = _folderPath(live, id);
      if (path != null) {
        choices.add((
          id: id,
          label: path.map((folder) => folder.title).join('/'),
        ));
      }
    }
    choices.sort((a, b) => _compareChoices(a.label, b.label, a.id, b.id));
    await _requireSnapshot(records);
    return List.unmodifiable(choices);
  }

  Future<List<WorkspaceMarkdownTemplateChoice>> templates(
    String folderId,
  ) async {
    if (repository.formatVersion != 2) return const [];
    final records = await repository.revisions();
    final heads = _headsByEntity(records);
    final live = await _liveFolders();
    if (_folderPath(live, folderId) == null) {
      await _requireSnapshot(records);
      return const [];
    }
    final notes = await WorkspaceStore(repository).list(includeDeleted: true);
    final choices = <WorkspaceMarkdownTemplateChoice>[];
    for (final note in notes) {
      if (note.trashed ||
          note.deletionConflict ||
          note.documentKind != VaultDocumentKind.markdown ||
          heads[note.id]?.length != 1 ||
          note.folderId == null) {
        continue;
      }
      final path = _folderPath(live, note.folderId!);
      if (path == null) continue;
      final index = path.indexWhere((folder) => folder.id == folderId);
      if (index < 0) continue;
      final markdownHeads = heads[note.markdownEntityId];
      if (markdownHeads?.length != 1) continue;
      final markdown = markdownHeads!.single;
      final source = markdown.blobs[_markdownFile];
      if (markdown.deleted ||
          markdown.kind != EntityKind.markdown ||
          markdown.ownerNoteId != note.id ||
          source == null ||
          source.length > _markdownMaxBytes) {
        continue;
      }
      final label = [
        for (final folder in path.skip(index + 1)) folder.title,
        note.title,
      ].join('/');
      choices.add(
        WorkspaceMarkdownTemplateChoice._(
          repository,
          folderId,
          note.id,
          label,
          markdown,
          {
            for (final folder in path) folder.id: [folder.revision.revisionId],
            note.id: [note.revision.revisionId],
            markdown.entityId: [markdown.revisionId],
          },
        ),
      );
    }
    choices.sort(
      (a, b) => _compareChoices(a.label, b.label, a.noteId, b.noteId),
    );
    await _requireSnapshot(records);
    return List.unmodifiable(choices);
  }

  Future<String> readTemplate(
    String folderId,
    WorkspaceMarkdownTemplateChoice choice,
  ) async {
    if (!identical(choice._repository, repository) ||
        choice._folderId != folderId) {
      throw const FormatException('템플릿이 선택한 폴더에 없습니다.');
    }
    await _requireHeads(choice._guards);
    final bytes = await repository.readRevisionFile(
      choice._markdown,
      _markdownFile,
    );
    await _requireHeads(choice._guards);
    return utf8.decode(bytes);
  }

  Future<WorkspaceDailyNoteTemplateSettings> dailyNoteTemplateSettings() async {
    final heads = await repository.heads(_dailySettingsId);
    final observed = <WorkspaceDailyNoteTemplateSettings>[];
    for (final head in heads) {
      final data = await _readSettingsData(head, _dailySettingsFile);
      final folder = data['folderId'];
      final note = data['noteId'];
      if (data['version'] is! int ||
          data['version'] != 1 ||
          data.length != 3 ||
          !data.containsKey('folderId') ||
          !data.containsKey('noteId') ||
          !(folder == null && note == null ||
              folder is String && note is String)) {
        throw const FormatException('지원하지 않는 날짜별 노트 템플릿 설정입니다.');
      }
      if (folder is String) validateId(folder);
      if (note is String) validateId(note);
      observed.add(
        WorkspaceDailyNoteTemplateSettings._(
          repository,
          [head.revisionId],
          folderId: folder as String?,
          noteId: note as String?,
        ),
      );
    }
    final ids = heads.map((head) => head.revisionId).toList();
    await _requireHeads({_dailySettingsId: ids});
    return observed.length == 1
        ? observed.single
        : WorkspaceDailyNoteTemplateSettings._(repository, ids);
  }

  Future<WorkspaceDailyNoteTemplateSettings> saveDailyNoteTemplateSettings(
    WorkspaceDailyNoteTemplateSettings prior, {
    required WorkspaceMarkdownTemplateChoice? choice,
    void Function()? beforePublish,
  }) async {
    if (repository.formatVersion != 2 ||
        !identical(prior._repository, repository) ||
        choice != null && !identical(choice._repository, repository)) {
      throw const FormatException('날짜별 노트 템플릿을 저장할 보관함이 바뀌었습니다.');
    }
    final folderId = choice?._folderId;
    final noteId = choice?.noteId;
    final prepared = repository.prepareCommit(
      entityId: _dailySettingsId,
      kind: EntityKind.attachment,
      files: {
        _dailySettingsFile: Uint8List.fromList(
          utf8.encode(
            jsonEncode({'version': 1, 'folderId': folderId, 'noteId': noteId}),
          ),
        ),
      },
      parentRevisionIds: prior.revisionIds,
    );
    final revision = await repository.commitPreparedIfHeads(
      prepared,
      expectedHeads: {_dailySettingsId: prior.revisionIds, ...?choice?._guards},
      beforePublish: beforePublish,
    );
    return WorkspaceDailyNoteTemplateSettings._(
      repository,
      [revision.revisionId],
      folderId: folderId,
      noteId: noteId,
    );
  }

  Future<({Uint8List bytes, Map<String, List<String>> expectedHeads})?>
  initialDailyMarkdown(String title, DateTime now) async {
    final selected = await dailyNoteTemplateSettings();
    if (selected.conflicted) {
      throw const FormatException(
        '날짜별 노트 템플릿 설정이 충돌했습니다. 사용할 템플릿을 다시 선택해 주세요.',
      );
    }
    final folderId = selected.folderId;
    final noteId = selected.noteId;
    if (folderId == null || noteId == null) return null;

    final formats = await settings();
    if (formats.conflicted) {
      throw const FormatException('템플릿 날짜·시간 설정이 충돌했습니다. 템플릿 설정을 확인해 주세요.');
    }
    final choice = (await templates(folderId))
        .where((choice) => choice.noteId == noteId)
        .singleOrNull;
    if (choice == null) {
      throw const FormatException(
        '설정한 날짜별 노트 템플릿을 열 수 없습니다. 다시 선택하거나 사용을 해제해 주세요.',
      );
    }
    final template = await readTemplate(folderId, choice);
    final rendered = applyMarkdownTemplate(
      document: '',
      selectionStart: 0,
      selectionEnd: 0,
      template: template,
      title: title,
      now: now,
      dateFormat: formats.dateFormat,
      timeFormat: formats.timeFormat,
    );
    final guards = {
      _dailySettingsId: selected.revisionIds,
      _settingsId: formats.revisionIds,
      ...choice._guards,
    };
    await _requireHeads(guards);
    return (
      bytes: Uint8List.fromList(utf8.encode(rendered.text)),
      expectedHeads: guards,
    );
  }

  Future<Map<String, dynamic>> _readSettingsData(
    RevisionRecord head,
    String fileName,
  ) async {
    final file = head.blobs[fileName];
    if (head.formatVersion != 2 ||
        head.kind != EntityKind.attachment ||
        head.ownerNoteId != null ||
        head.deleted ||
        head.baseRefs.isNotEmpty ||
        head.blobs.length != 1 ||
        file == null ||
        file.length > _settingsMaxBytes) {
      throw const FormatException('템플릿 설정의 저장 형식을 확인할 수 없습니다.');
    }
    final bytes = await repository.readRevisionFile(head, fileName);
    return jsonObject(jsonDecode(utf8.decode(bytes)));
  }

  Future<WorkspaceMarkdownTemplateSettings> _readSettings(
    RevisionRecord head,
  ) async {
    final data = await _readSettingsData(head, _settingsFile);
    final folderId = data['folderId'];
    final dateFormat = data['dateFormat'];
    final timeFormat = data['timeFormat'];
    if (data['version'] is! int ||
        data['version'] != 1 ||
        data.length != 4 ||
        !data.containsKey('folderId') ||
        (folderId != null && folderId is! String) ||
        dateFormat is! String ||
        timeFormat is! String) {
      throw const FormatException('지원하지 않는 템플릿 설정입니다.');
    }
    final folder = folderId as String?;
    if (folder != null) validateId(folder);
    _validateFormat(dateFormat);
    _validateFormat(timeFormat);
    return WorkspaceMarkdownTemplateSettings._(
      repository,
      [head.revisionId],
      folderId: folder,
      dateFormat: dateFormat,
      timeFormat: timeFormat,
    );
  }

  Future<Map<String, VaultFolder>> _liveFolders() async {
    final folders = await LibraryStore(repository)
        .listFolders(includeDeleted: true);
    final live = <String, VaultFolder>{};
    final seen = <String>{};
    for (final folder in folders) {
      if (!seen.add(folder.id)) {
        live.remove(folder.id);
      } else if (!folder.trashed && !folder.deletionConflict) {
        live[folder.id] = folder;
      }
    }
    return live;
  }

  List<VaultFolder>? _folderPath(Map<String, VaultFolder> live, String id) {
    final reversed = <VaultFolder>[];
    final seen = <String>{};
    String? parent = id;
    while (parent != null) {
      final folder = live[parent];
      if (folder == null || !seen.add(parent) || reversed.length >= 64)
        return null;
      reversed.add(folder);
      parent = folder.parentId;
    }
    return reversed.reversed.toList();
  }

  List<VaultFolder> _requireFolderPath(
    Map<String, VaultFolder> live,
    String id,
  ) =>
      _folderPath(live, id) ??
      (throw const FormatException('템플릿 폴더가 없거나 변경 내용이 충돌합니다.'));

  Future<void> _requireSnapshot(List<RevisionRecord> records) async {
    final current = await repository.revisions();
    if (!_sameIds(
      current.map((r) => r.revisionId),
      records.map((r) => r.revisionId),
    )) {
      throw const FormatException('보관함이 바뀌었습니다. 템플릿 목록을 다시 열어 주세요.');
    }
  }

  Future<void> _requireHeads(Map<String, List<String>> guards) async {
    final heads = _headsByEntity(await repository.revisions());
    for (final entry in guards.entries) {
      final current = heads[entry.key] ?? const <RevisionRecord>[];
      if (!_sameIds(current.map((r) => r.revisionId), entry.value)) {
        throw const FormatException('템플릿 또는 설정이 바뀌었습니다. 다시 열어 주세요.');
      }
    }
  }

  static Map<String, List<RevisionRecord>> _headsByEntity(
    List<RevisionRecord> records,
  ) {
    final parents = records
        .expand((record) => record.parentRevisionIds)
        .toSet();
    final heads = <String, List<RevisionRecord>>{};
    for (final record in records) {
      if (!parents.contains(record.revisionId)) {
        (heads[record.entityId] ??= []).add(record);
      }
    }
    return heads;
  }

  static bool _sameIds(Iterable<String> a, Iterable<String> b) {
    final ids = a.toSet();
    return ids.length == b.length && b.every(ids.contains);
  }

  static int _compareChoices(String a, String b, String idA, String idB) {
    final order = a.toLowerCase().compareTo(b.toLowerCase());
    return order == 0 ? idA.compareTo(idB) : order;
  }

  static void _validateFormat(String value) {
    if (value.trim().isEmpty ||
        value.length > 128 ||
        _invalidFormat.hasMatch(value)) {
      throw const FormatException('날짜와 시간 형식은 128자 이내의 한 줄이어야 합니다.');
    }
  }
}
