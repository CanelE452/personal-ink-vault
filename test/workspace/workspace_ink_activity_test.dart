import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

/// Counts the vault reads the controller starts.
class _CountingController extends WorkspaceController {
  new(super.repository);
  var refreshes = 0;
  Future<void>? lastRefresh;

  @override
  Future<void> refresh() {
    refreshes++;
    return lastRefresh = super.refresh();
  }
}

/// The editor reports busy and dirty on every stroke; the workspace builds
/// again on each notice, so a notice comes only when `dirty` changes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  test('strokes while dirty do not notify the workspace', () async {
    final directory = await Directory.systemTemp.createTemp('ink-activity-');
    final c = _CountingController(await NoteRepository.open(directory));
    try {
      var heard = 0;
      c.addListener(() => heard++);
      // The editor's calls for one stroke: pen down (busy, dirty), the
      // autosave wait and the stroke's end (dirty again), pen up (not busy).
      void stroke() {
        c
          ..setInkBusy(true)
          ..setInkDirty(true)
          ..setInkDirty(true)
          ..setInkDirty(true)
          ..setInkBusy(false);
      }

      stroke();
      expect(heard, 1, reason: 'the first stroke after a save makes it dirty');
      expect(c.dirty, isTrue);
      expect(c.refreshes, 0, reason: 'a stroke end does not read the vault');

      for (var i = 0; i < 3; i++) {
        stroke();
      }
      expect(heard, 1, reason: 'strokes while dirty change nothing seen');
      expect(c.refreshes, 0);

      // The save ends.
      c.setInkDirty(false);
      expect(heard, 2);
      expect(c.dirty, isFalse);
      expect(c.refreshes, 1);
      // Saying clean again (the editor does after each save) reads nothing.
      c
        ..setInkDirty(false)
        ..setInkBusy(false);
      expect(heard, 2);
      expect(c.refreshes, 1);
      await c.lastRefresh;
    } finally {
      c.dispose();
      await c.repository.close().timeout(const Duration(seconds: 20));
      await directory.delete(recursive: true);
    }
  });
}
