"""Run OfficeEngineBridge with Activity doubles: an open editor is brought back or asked to close in place, a
resumed session may reuse its still-open editor, a new session never does, and a result no Dart call waits for
is announced. Host only; Android task ordering itself is checked on the device."""

import unittest
from unittest.mock import patch

import test_session_journal as recovery


SCENARIOS = r'''
  static class Events implements EditorEvents {
    final List<String> left = new ArrayList<>();
    final List<String> finished = new ArrayList<>();
    public void left(String sessionId) { left.add(sessionId); }
    public void finished(String sessionId, String status) { finished.add(sessionId + ":" + status); }
  }

  static boolean reorders(Intent intent) {
    return (intent.getFlags() & Intent.FLAG_ACTIVITY_REORDER_TO_FRONT) != 0;
  }

  static void reorderScenario(File root) throws Exception {
    Fixture f = fixture(root, "reorder");
    Activity activity = new Activity(f.root);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    Events events = new Events();
    bridge.setEditorEvents(events);
    try {
      Completion notOpen = new Completion();
      bridge.show(ID, notOpen); notOpen.await();
      require("office_editor_not_open".equals(notOpen.code), "show needs an editor this app opened");
      require(activity.starts == 0 && activity.launches == 0, "show never starts an editor of its own");

      Completion resumed = new Completion();
      bridge.resume(ID, f.inputHash, resumed); waitLaunch(activity, 1);
      require(reorders(activity.lastIntent), "a resumed session reuses its editor if one is still open");
      require(activity.lastRequest == OfficeEngineBridge.REQUEST_EDIT, "a resumed editor reports to the edit request");

      Completion shown = new Completion();
      bridge.show(ID, shown); shown.await();
      require(shown.code == null && activity.starts == 1 && activity.launches == 1,
          "show brings the open editor back without another launch");
      require(reorders(activity.lastStarted) && ID.equals(activity.lastStarted.getStringExtra("piv.sessionId"))
          && !activity.lastStarted.getBooleanExtra("piv.requestClose", false), "show only brings the editor forward");
      Completion other = new Completion();
      bridge.show(OTHER, other); other.await();
      require("office_editor_not_open".equals(other.code), "show is refused for a session that is not open");

      Completion close = new Completion();
      bridge.requestClose(ID, close); close.await();
      require(close.code == null && activity.starts == 2 && reorders(activity.lastStarted)
          && activity.lastStarted.getBooleanExtra("piv.requestClose", false), "a close request asks the open editor");

      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED,
          new Intent().putExtra("sessionId", ID).putExtra("piv.closeReason", "discarded"));
      resumed.await();
      require("cancelled".equals(resumed.result.get("status")) && "discarded".equals(resumed.result.get("closeReason")),
          "the close reason reaches Dart: " + resumed.result);
      require(events.finished.isEmpty(), "a result a Dart call waited for is not announced again");

      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED,
          new Intent().putExtra("sessionId", ID).putExtra("piv.closeReason", "unchanged"));
      require(events.finished.equals(List.of(ID + ":cancelled")), "a late result is announced: " + events.finished);

      Completion fresh = new Completion();
      bridge.edit(f.input.getPath(), OTHER, fresh); waitLaunch(activity, 2);
      require(!reorders(activity.lastIntent), "a new session never takes over an editor that is already open");
      String otherHash = hash(f.input);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED,
          new Intent().putExtra("sessionId", OTHER).putExtra("piv.closeReason", "unchanged"));
      fresh.await();
      require("unchanged".equals(fresh.result.get("closeReason")), "an unchanged close says so");

      Completion discarded = new Completion();
      bridge.discardSession(OTHER, otherHash, discarded); discarded.await();
      require(discarded.code == null, "discard succeeds for a closed unsaved session: " + discarded.code);
      require("missing".equals(f.reopened().recover(OTHER, otherHash).get("status")), "the discarded session is gone");
    } finally { bridge.dispose(); }
    System.out.println("native reorder bridge scenarios passed");
  }
'''


class EditorReorderBridgeTests(unittest.TestCase):
    def test_show_close_request_resume_reorder_and_late_results(self):
        scenario_dispatch = 'else bridgeScenarios(root);'
        class_declaration = 'public class RecoveryHarness {'
        self.assertIn(scenario_dispatch, recovery.HARNESS)
        self.assertIn(class_declaration, recovery.HARNESS)
        harness = recovery.HARNESS.replace(class_declaration, class_declaration + SCENARIOS).replace(
            scenario_dispatch,
            'else if (args[0].equals("reorder")) reorderScenario(root);\n    ' + scenario_dispatch,
        )
        with patch.object(recovery, 'HARNESS', harness):
            recovery.SessionJournalTests.run_harness(self, 'reorder')


if __name__ == '__main__':
    unittest.main(verbosity=2)
