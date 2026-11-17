import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Which editor holds a document: the Office engine (Word·PPT) or the HWP editor.
enum OfficeEditorKind { office, hwp }

/// How an open editor closed: saved as a new version, 저장 안 함, nothing changed, or an error
/// (its work stays in the recovery records).
enum OfficeEditorOutcome { saved, discarded, unchanged, failed }

/// One Office·한글 document whose editor is open behind the app's tabs.
class OfficeOpenEdit {
  const new({
    required this.noteId,
    required this.title,
    required this.sessionId,
    required this.kind,
    required this.workingPath,
    required this.inputSourceSha256,
  });

  final String noteId;
  final String title;
  final String sessionId;
  final OfficeEditorKind kind;
  final String workingPath;
  final String inputSourceSha256;

  Map<String, Object?> _toJson() => {
    'noteId': noteId,
    'title': title,
    'sessionId': sessionId,
    'kind': kind.name,
    'workingPath': workingPath,
    'inputSourceSha256': inputSourceSha256,
  };

  /// A list written by 227 also holds the screen to return to (returnNoteId, returnFolderId);
  /// 228 opens editors over the current screen, so those fields are not read.
  static OfficeOpenEdit? _fromJson(Object? value) {
    if (value is! Map) return null;
    final kind = OfficeEditorKind.values.where((kind) => kind.name == value['kind']).singleOrNull;
    final fields = [value['noteId'], value['title'], value['sessionId'], value['workingPath'], value['inputSourceSha256']];
    if (kind == null || fields.any((field) => field is! String)) return null;
    return OfficeOpenEdit(
      noteId: fields[0] as String,
      title: fields[1] as String,
      sessionId: fields[2] as String,
      kind: kind,
      workingPath: fields[3] as String,
      inputSourceSha256: fields[4] as String,
    );
  }
}

/// The documents whose editors are open, kept in the vault ([file] =
/// `<vault>/.workspace/office-open-edits.json`) so a restarted app still shows them as open and
/// still asks before closing them. One editor of each kind at a time.
class OfficeOpenEdits extends ChangeNotifier {
  new(this.file);

  final File file;
  final _entries = <String, OfficeOpenEdit>{};
  final _outcomes = <String, OfficeEditorOutcome>{};

  /// Notes whose editor a call in this app run waits for: false while the editor is open, true once
  /// it closed and its result is being handled. Kept in memory only (after a restart no call waits).
  final _calls = <String, bool>{};
  Future<void> _writes = Future.value();

  List<OfficeOpenEdit> get entries => List.unmodifiable(_entries.values);

  OfficeOpenEdit? forNote(String noteId) => _entries[noteId];

  OfficeOpenEdit? forKind(OfficeEditorKind kind) =>
      _entries.values.where((edit) => edit.kind == kind).firstOrNull;

  /// A missing or damaged list reads as no open editors.
  Future<void> load() async {
    _entries.clear();
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['version'] == 1 && decoded['edits'] is List) {
        for (final item in decoded['edits'] as List) {
          final edit = OfficeOpenEdit._fromJson(item);
          if (edit != null) _entries[edit.noteId] = edit;
        }
      }
    } on FileSystemException {
      // No list yet.
    } on FormatException {
      // A damaged list: the recovery records still hold every unfinished edit.
    }
    notifyListeners();
  }

  /// Adds or replaces [edit]'s document; another document of the same kind is refused.
  Future<void> put(OfficeOpenEdit edit) async {
    final other = forKind(edit.kind);
    if (other != null && other.noteId != edit.noteId) {
      throw StateError('같은 종류의 다른 문서 편집기가 이미 열려 있습니다. 그 문서를 먼저 닫아 주세요.');
    }
    _entries[edit.noteId] = edit;
    await _save();
    notifyListeners();
  }

  bool waitsFor(String noteId) => _calls.containsKey(noteId);

  bool closing(String noteId) => _calls[noteId] ?? false;

  void waiting(String noteId) => _calls[noteId] = false;

  /// The editor returned: its result is being handled, so other screens show it as saving.
  void closed(String noteId) {
    if (!_calls.containsKey(noteId)) return;
    _calls[noteId] = true;
    notifyListeners();
  }

  /// [outcome] is for a screen that brought this editor back while the one that opened it was
  /// gone: it takes the outcome with [takeOutcome] and finishes the close there.
  Future<void> remove(String noteId, {OfficeEditorOutcome? outcome}) async {
    _calls.remove(noteId);
    if (outcome != null) _outcomes[noteId] = outcome;
    if (_entries.remove(noteId) == null) {
      // Already gone: a screen that brought this editor back can still take the outcome.
      if (outcome != null) notifyListeners();
      return;
    }
    await _save();
    notifyListeners();
  }

  OfficeEditorOutcome? takeOutcome(String noteId) => _outcomes.remove(noteId);

  Future<void> _save() {
    final content = jsonEncode({
      'version': 1,
      'edits': [for (final edit in _entries.values) edit._toJson()],
    });
    return _writes = _writes.then((_) async {
      await file.parent.create(recursive: true);
      final staging = File('${file.path}.tmp');
      await staging.writeAsString(content, flush: true);
      await staging.rename(file.path);
    });
  }
}
