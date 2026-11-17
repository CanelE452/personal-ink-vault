import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/office_open_edits.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/office/office_workspace.dart';

/// Office·한글 editors on Android, each driven by an OfficeWorkspace the app does not draw (a host):
/// the screen the user is on stays while an editor opens, waits behind it and closes.
/// [OfficeEditorHostLayer] puts the hosts beside that screen.
class OfficeEditorHosts extends ChangeNotifier {
  new({
    required this.onDeclined,
    required this.onError,
    required this.onFinished,
  });

  /// No editor could open for this document (no engine, a format this device cannot edit, two
  /// versions to choose from): the app shows the Office screen instead. The host is gone.
  final void Function(VaultNote note) onDeclined;

  /// What went wrong on a host, which has no place to show it.
  final void Function(VaultNote note, String message) onError;

  /// The document's editor closed. The host is gone.
  final void Function(VaultNote note, OfficeEditorOutcome outcome) onFinished;

  final _hosts = <String, _EditorHost>{};
  NoteRepository? _repository;
  var _disposed = false;

  /// An editor is opening, or a host is preparing one or saving its result as a version.
  bool get working => _hosts.values.any((host) => host.launching || host.busy);

  /// One editor opens at a time: two of one kind cannot be told apart by the engine.
  bool get launching => _hosts.values.any((host) => host.launching);

  bool isBusy(String noteId) => _hosts[noteId]?.busy ?? false;

  /// Hands [request] to [note]'s host, making the host if there is none.
  void request(
    NoteRepository repository,
    VaultNote note,
    OfficeOpenRequest request,
  ) {
    forgetOtherVaults(repository);
    _repository = repository;
    final host = _hosts.putIfAbsent(note.id, () => _EditorHost(note));
    host.launchTimeout?.cancel();
    host.launchTimeout = null;
    host.note = note;
    host.request = request;
    host.launching = request.action == OfficeOpenAction.edit;
    if (host.launching) {
      // A host that never reports back must not keep every other document from opening.
      host.launchTimeout = Timer(
        const Duration(seconds: 30),
        () => _settled(host),
      );
    }
    notifyListeners();
  }

  /// A vault switch drops every host: their documents are not in the new vault. Otherwise a
  /// host leaves only through its own report (its editor finished, no editor could open, or an
  /// error): only it knows when its work is done.
  void forgetOtherVaults(NoteRepository? repository) {
    if (_hosts.isEmpty || identical(_repository, repository)) return;
    _drop();
    notifyListeners();
  }

  void _settled(_EditorHost host) {
    host.launchTimeout?.cancel();
    host.launchTimeout = null;
    if (!host.launching || _disposed) return;
    host.launching = false;
    notifyListeners();
  }

  void _busy(_EditorHost host, bool value) {
    if (host.busy == value || _disposed) return;
    host.busy = value;
    notifyListeners();
  }

  void _declined(_EditorHost host) {
    _remove(host);
    if (!_disposed) onDeclined(host.note);
  }

  void _failed(_EditorHost host, String message, OfficeOpenEdits openEdits) {
    _settled(host);
    if (_disposed) return;
    onError(host.note, message);
    if (openEdits.forNote(host.note.id) == null) _remove(host);
  }

  void _finished(_EditorHost host, OfficeEditorOutcome outcome) {
    _remove(host);
    if (!_disposed) onFinished(host.note, outcome);
  }

  void _remove(_EditorHost host) {
    host.launchTimeout?.cancel();
    if (_disposed || !identical(_hosts[host.note.id], host)) return;
    _hosts.remove(host.note.id);
    notifyListeners();
  }

  void _drop() {
    for (final host in _hosts.values) {
      host.launchTimeout?.cancel();
    }
    _hosts.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _drop();
    super.dispose();
  }
}

/// The hosts of [hosts], laid out beside the app's screen without drawing anything, so they outlive
/// any change of the document shown.
class OfficeEditorHostLayer extends StatelessWidget {
  const new({
    super.key,
    required this.hosts,
    required this.repository,
    required this.openEdits,
    this.engine,
    this.previewEngine,
  });

  final OfficeEditorHosts hosts;
  final NoteRepository repository;
  final OfficeOpenEdits openEdits;
  final AndroidOfficeEngine? engine;
  final OfficePreviewEngine? previewEngine;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: hosts,
    builder: (context, _) => Offstage(
      key: const ValueKey('office-editor-hosts'),
      child: Column(
        children: [
          for (final host in hosts._hosts.values)
            OfficeWorkspace(
              key: host.key,
              hosted: true,
              showBackButton: false,
              repository: repository,
              note: host.note,
              engine: engine,
              previewEngine: previewEngine,
              openRequest: host.request,
              onOpenRequestHandled: (request) {
                if (identical(host.request, request)) host.request = null;
              },
              openEdits: openEdits,
              onEditorStarted: () => hosts._settled(host),
              onEditDeclined: () => hosts._declined(host),
              onHostError: (message) => hosts._failed(host, message, openEdits),
              onEditorFinished: (outcome) => hosts._finished(host, outcome),
              onBusyChanged: (value) => hosts._busy(host, value),
              onBack: () {},
            ),
        ],
      ),
    ),
  );
}

/// One document's editor and the request its host is handling.
class _EditorHost {
  new(this.note);

  VaultNote note;
  final key = GlobalKey<OfficeWorkspaceState>();
  OfficeOpenRequest? request;

  /// From an edit request until its editor starts, it is declined, or it fails.
  var launching = false;

  /// Preparing the editor or saving its result as a version.
  var busy = false;
  Timer? launchTimeout;
}
