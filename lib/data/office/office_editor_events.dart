import 'dart:async';

import 'package:flutter/services.dart';
import 'package:saber/data/app_external_screen.dart';

/// What an Office·한글 editor kept open behind the app's tabs reports without a waiting call:
/// the user went back to the tabs (`editorLeft`), or it finished while no call waited for its
/// result (`editorFinished`, after the app restarted).
class OfficeEditorEvents {
  new({MethodChannel? events, MethodChannel? engine})
    : _engine = engine ?? const MethodChannel('personal_ink_vault/office_engine') {
    (events ?? const MethodChannel('personal_ink_vault/office_editor_events'))
        .setMethodCallHandler(_receive);
  }

  static final instance = OfficeEditorEvents();

  final MethodChannel _engine;
  final _left = StreamController<String>.broadcast();
  final _finished = StreamController<({String sessionId, String status})>.broadcast();

  Stream<String> get editorLeft => _left.stream;
  Stream<({String sessionId, String status})> get editorFinished => _finished.stream;

  /// Back at the library's first screen with an editor open behind it: the app goes to the back
  /// instead of ending, so the editor and its result keep their place.
  Future<void> moveAppToBack() => _engine.invokeMethod<Object?>('moveTaskToBack');

  Future<Object?> _receive(MethodCall call) async {
    final arguments = call.arguments;
    final sessionId = arguments is Map ? arguments['sessionId'] : null;
    if (sessionId is! String) return null;
    switch (call.method) {
      case 'editorLeft':
        AppExternalScreen.editorBehind(sessionId);
        _left.add(sessionId);
      case 'editorFinished':
        AppExternalScreen.editorBehind(sessionId);
        final status = arguments is Map ? arguments['status'] : null;
        _finished.add((
          sessionId: sessionId,
          status: status is String ? status : 'failed',
        ));
    }
    return null;
  }
}
