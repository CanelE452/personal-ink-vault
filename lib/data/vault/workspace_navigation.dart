import 'dart:convert';
import 'dart:io';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/infinite_document.dart';

class WorkspaceLocation {
  final String? noteId;
  final String? folderId;
  final String? pageId;
  final String? databaseViewId;
  final String? markdownAnchor;
  final bool markdown;
  const new({
    this.noteId,
    this.folderId,
    this.pageId,
    this.databaseViewId,
    this.markdownAnchor,
    this.markdown = false,
  });

  factory fromJson(Map<String, dynamic> json) {
    final note = _id(json['noteId']);
    final folder = _id(json['folderId']);
    final page = _id(json['pageId']);
    final databaseView = _id(json['databaseViewId']);
    final markdown = json['markdown'] ?? false;
    if (markdown is! bool ||
        note == null && (page != null || databaseView != null || markdown) ||
        page != null && databaseView != null) {
      throw const FormatException('Invalid workspace location');
    }
    final markdownAnchor = _markdownAnchor(json['markdownAnchor']);
    if (markdownAnchor != null && (note == null || !markdown || page != null)) {
      throw const FormatException(
        'A Markdown anchor requires its Markdown view',
      );
    }
    return WorkspaceLocation(
      noteId: note,
      folderId: folder,
      pageId: page,
      databaseViewId: databaseView,
      markdown: markdown,
      markdownAnchor: markdownAnchor,
    );
  }

  Map<String, Object?> toJson() => {
    'noteId': noteId,
    'folderId': folderId,
    'pageId': pageId,
    if (databaseViewId != null) 'databaseViewId': databaseViewId,
    'markdown': markdown,
    'markdownAnchor': markdownAnchor,
  };

  bool sameAs(WorkspaceLocation other) =>
      noteId == other.noteId &&
      folderId == other.folderId &&
      pageId == other.pageId &&
      databaseViewId == other.databaseViewId &&
      markdown == other.markdown &&
      markdownAnchor == other.markdownAnchor;
}

class WorkspaceDocumentTab {
  final String noteId;
  final String title;
  final WorkspaceLocation? location;
  const new(this.noteId, this.title, {this.location});
}

class WorkspaceNavigation {
  static const _recentLimit = 100;
  var _current = const WorkspaceLocation();
  final _tabs = <WorkspaceDocumentTab>[];
  final _back = <WorkspaceLocation>[];
  final _forward = <WorkspaceLocation>[];
  final _recentDocuments = <String>[];
  final _infiniteViews = <String, InfiniteViewport>{};
  Future<void> _saveTail = Future.value();

  WorkspaceLocation get current => _current;
  List<WorkspaceDocumentTab> get tabs => List.unmodifiable(_tabs);
  List<String> get recentDocumentIds => List.unmodifiable(_recentDocuments);
  WorkspaceLocation? get peekBack => _back.lastOrNull;
  WorkspaceLocation? get peekForward => _forward.lastOrNull;
  int get backLength => _back.length;
  InfiniteViewport? infiniteViewport(String noteId) => _infiniteViews[noteId];
  void setInfiniteViewport(String noteId, InfiniteViewport viewport) {
    validateId(noteId);
    _infiniteViews[noteId] = InfiniteViewport.fromJson(viewport.toJson());
  }

  void openDocument(
    String noteId,
    String title, {
    String? folderId,
    String? pageId,
    String? databaseViewId,
    bool markdown = false,
    String? markdownAnchor,
  }) {
    final location = WorkspaceLocation.fromJson(
      WorkspaceLocation(
        noteId: noteId,
        folderId: folderId,
        pageId: pageId,
        databaseViewId: databaseViewId,
        markdown: markdown,
        markdownAnchor: markdownAnchor,
      ).toJson(),
    );
    final index = _tabs.indexWhere((tab) => tab.noteId == noteId);
    final tab = WorkspaceDocumentTab(noteId, title, location: location);
    if (index < 0) {
      _tabs.add(tab);
    } else {
      _tabs[index] = tab;
    }
    _visit(location);
    _rememberRecentDocument();
  }

  void showLibrary(String? folderId) {
    if (folderId != null) validateId(folderId);
    _visit(WorkspaceLocation(folderId: folderId));
  }

  void _visit(WorkspaceLocation location) {
    if (_current.sameAs(location)) return;
    _push(_back, _current);
    _forward.clear();
    _current = location;
  }

  void goBack() {
    if (_back.isEmpty) return;
    _push(_forward, _current);
    _current = _back.removeLast();
    _rememberCurrentTab();
    _rememberRecentDocument();
  }

  void goForward() {
    if (_forward.isEmpty) return;
    _push(_back, _current);
    _current = _forward.removeLast();
    _rememberCurrentTab();
    _rememberRecentDocument();
  }

  void closeTab(String noteId) =>
      _tabs.removeWhere((tab) => tab.noteId == noteId);

  bool pruneDeletedDocuments(Set<String> noteIds) {
    if (noteIds.isEmpty) return false;
    final count =
        _tabs.length + _back.length + _forward.length + _recentDocuments.length;
    _tabs.removeWhere((tab) => noteIds.contains(tab.noteId));
    _back.removeWhere((location) => noteIds.contains(location.noteId));
    _forward.removeWhere((location) => noteIds.contains(location.noteId));
    _recentDocuments.removeWhere(noteIds.contains);
    if (noteIds.contains(_current.noteId)) {
      _current = WorkspaceLocation(folderId: _current.folderId);
      return true;
    }
    return count !=
        _tabs.length + _back.length + _forward.length + _recentDocuments.length;
  }

  void updateView({
    required bool markdown,
    String? pageId,
    String? databaseViewId,
    String? markdownAnchor,
  }) {
    if (_current.noteId == null) return;
    _current = WorkspaceLocation.fromJson(
      WorkspaceLocation(
        noteId: _current.noteId,
        folderId: _current.folderId,
        pageId: pageId,
        databaseViewId: databaseViewId,
        markdown: markdown,
        markdownAnchor: markdownAnchor,
      ).toJson(),
    );
    _rememberCurrentTab();
  }

  void updateTitle(String noteId, String title) {
    final index = _tabs.indexWhere((tab) => tab.noteId == noteId);
    if (index >= 0) {
      _tabs[index] = WorkspaceDocumentTab(
        noteId,
        title,
        location: _tabs[index].location,
      );
    }
  }

  void _rememberCurrentTab() {
    final index = _tabs.indexWhere((tab) => tab.noteId == _current.noteId);
    if (index >= 0) {
      final tab = _tabs[index];
      _tabs[index] = WorkspaceDocumentTab(
        tab.noteId,
        tab.title,
        location: _current,
      );
    }
  }

  void _rememberRecentDocument() {
    final id = _current.noteId;
    if (id == null) return;
    _recentDocuments.remove(id);
    _recentDocuments.insert(0, id);
    if (_recentDocuments.length > _recentLimit) _recentDocuments.removeLast();
  }

  static void _push(List<WorkspaceLocation> stack, WorkspaceLocation location) {
    stack.add(location);
    if (stack.length > 100) stack.removeAt(0);
  }

  Map<String, Object?> toJson() => {
    'version': 1,
    'current': _current.toJson(),
    'tabs': [
      for (final tab in _tabs)
        {
          'noteId': tab.noteId,
          'title': tab.title,
          if (tab.location != null) 'location': tab.location!.toJson(),
        },
    ],
    'back': [for (final location in _back) location.toJson()],
    'forward': [for (final location in _forward) location.toJson()],
    'recentDocumentIds': recentDocumentIds,
    'infiniteViews': {
      for (final entry in _infiniteViews.entries)
        entry.key: entry.value.toJson(),
    },
  };

  static WorkspaceNavigation fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['tabs'] is! List ||
        json['back'] is! List ||
        json['forward'] is! List) {
      throw const FormatException('Unsupported workspace navigation');
    }
    final result = WorkspaceNavigation();
    final views = json['infiniteViews'];
    if (views != null) {
      for (final entry in jsonObject(views).entries) {
        validateId(entry.key);
        result._infiniteViews[entry.key] = InfiniteViewport.fromJson(
          jsonObject(entry.value),
        );
      }
    }
    result._current = WorkspaceLocation.fromJson(jsonObject(json['current']));
    for (final raw
        in (json['back'] as List).reversed.take(100).toList().reversed) {
      result._back.add(WorkspaceLocation.fromJson(jsonObject(raw)));
    }
    for (final raw
        in (json['forward'] as List).reversed.take(100).toList().reversed) {
      result._forward.add(WorkspaceLocation.fromJson(jsonObject(raw)));
    }
    final previousLocations = <String, WorkspaceLocation>{};
    for (final location in [
      result._current,
      ...result._back.reversed,
      ...result._forward.reversed,
    ]) {
      final id = location.noteId;
      if (id != null) previousLocations.putIfAbsent(id, () => location);
    }
    final storedRecents = json['recentDocumentIds'];
    if (storedRecents != null && storedRecents is! List) {
      throw const FormatException('Invalid recent documents');
    }
    final recentIds = <String>{};
    for (final raw in (storedRecents as List?) ?? previousLocations.keys) {
      final id = _id(raw);
      if (id == null) throw const FormatException('Invalid recent document id');
      recentIds.add(id);
      if (recentIds.length == _recentLimit) break;
    }
    result._recentDocuments.addAll(recentIds);
    final ids = <String>{};
    for (final raw in json['tabs'] as List) {
      final tab = jsonObject(raw);
      final id = _id(tab['noteId']);
      if (id == null || tab['title'] is! String || !ids.add(id))
        throw const FormatException('Invalid document tab');
      final rawLocation = tab['location'];
      final location = rawLocation == null
          ? previousLocations[id]
          : WorkspaceLocation.fromJson(jsonObject(rawLocation));
      if (location != null && location.noteId != id) {
        throw const FormatException('Invalid document tab location');
      }
      result._tabs.add(
        WorkspaceDocumentTab(id, tab['title'] as String, location: location),
      );
    }
    result._rememberCurrentTab();
    return result;
  }

  static Future<WorkspaceNavigation> load(File file) async => file.existsSync()
      ? fromJson(jsonObject(jsonDecode(await file.readAsString())))
      : WorkspaceNavigation();

  Future<void> save(File file) {
    final contents = jsonEncode(toJson());
    final next = _saveTail.then((_) async {
      await file.parent.create(recursive: true);
      final pending = File('${file.path}.${newId()}.pending');
      try {
        await pending.writeAsString(contents, flush: true);
        await pending.rename(file.path);
      } finally {
        if (pending.existsSync()) await pending.delete();
      }
    });
    _saveTail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}

String? _id(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('Invalid workspace id');
  validateId(value);
  return value;
}

String? _markdownAnchor(Object? value) {
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.length > 2048 ||
      value.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]'))) {
    throw const FormatException('Invalid Markdown anchor');
  }
  return value;
}
