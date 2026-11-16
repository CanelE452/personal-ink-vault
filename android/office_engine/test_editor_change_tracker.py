"""Run EditorChangeTracker (plain Java) on engine frames and its changed() rule.

Host only: this checks the decision, not Android, JNI or whether the engine sends these frames on a device.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = (Path(__file__).resolve().parent /
          'src/main/java/io/github/canele452/personalinkvault/office/EditorChangeTracker.java')

HARNESS = r'''
import io.github.canele452.personalinkvault.office.EditorChangeTracker;
import java.nio.charset.StandardCharsets;

public class ChangeTrackerHarness {
  static int assertions;

  static void check(boolean condition, String what) {
    if (!condition) throw new AssertionError(what);
    assertions++;
  }

  static byte[] frame(String text) { return text.getBytes(StandardCharsets.UTF_8); }

  public static void main(String[] args) {
    EditorChangeTracker tracker = new EditorChangeTracker();
    check(!tracker.modified(), "a new tracker starts unmodified");
    check(!tracker.heard(), "no ModifiedStatus frame yet: the engine's state is unknown");
    tracker.onEngineMessage(frame("statechanged: .uno:Bold=true"));
    check(!tracker.heard(), "another state change is not the modified state");
    tracker.onEngineMessage(frame("statechanged: .uno:ModifiedStatus=true"));
    check(tracker.modified(), "ModifiedStatus=true marks the document modified");
    check(tracker.heard(), "a ModifiedStatus frame was heard");
    tracker.onEngineMessage(frame("statechanged: .uno:Bold=true"));
    tracker.onEngineMessage(frame("invalidatetiles: part=0"));
    tracker.onEngineMessage(new byte[0]);
    tracker.onEngineMessage(null);
    check(tracker.modified(), "other frames leave the state as it was");
    tracker.onEngineMessage(frame("statechanged: .uno:ModifiedStatus=false"));
    check(!tracker.modified(), "ModifiedStatus=false clears it (the engine saved in place)");
    tracker.onEngineMessage(frame("statechanged: {\"commandName\":\".uno:ModifiedStatus\",\"state\":\"true\"}"));
    check(tracker.modified(), "the JSON form of the state change counts too");

    check(!EditorChangeTracker.changed(false, "a", "a", false), "unmodified and the working copy is still the opened one");
    check(EditorChangeTracker.changed(false, "b", "a", false), "a background save already wrote the working copy");
    check(EditorChangeTracker.changed(true, "a", "a", false), "modified now");
    check(EditorChangeTracker.changed(false, "a", "a", true), "reopened from unsaved work");
    check(EditorChangeTracker.changed(false, null, "a", false), "an unreadable working copy counts as changed");

    check("unchanged".equals(EditorChangeTracker.closeStep(null, false, true, "a", "a")), "nothing changed: close without asking");
    check("ask".equals(EditorChangeTracker.closeStep(null, false, false, "a", "a")),
        "no ModifiedStatus frame ever arrived: ask instead of discarding");
    check("ask".equals(EditorChangeTracker.closeStep(null, true, true, "a", "a")), "modified: ask before closing");
    check("ask".equals(EditorChangeTracker.closeStep(null, false, true, "b", "a")), "saved in place in the background: still ask");
    check("save".equals(EditorChangeTracker.closeStep("save", false, true, "a", "a")), "the user chose 저장");
    check("discard".equals(EditorChangeTracker.closeStep("discard", true, true, "b", "a")), "the user chose 저장 안 함");

    check("unchanged".equals(EditorChangeTracker.loadingCloseReason("a", "a")),
        "closed while opening an untouched copy: unchanged");
    check(EditorChangeTracker.loadingCloseReason("b", "a") == null,
        "closed while reopening a copy that holds earlier work: no reason, so the app keeps it");
    check(EditorChangeTracker.loadingCloseReason(null, "a") == null, "an unreadable copy while opening: kept");
    System.out.println("HOST ONLY: " + assertions + " change tracker assertions passed; Android/native runtime unverified.");
  }
}
'''


class EditorChangeTrackerTests(unittest.TestCase):
    def test_modified_status_frames_and_changed_rule(self):
        self.assertTrue(SOURCE.is_file(), 'EditorChangeTracker is not implemented')
        suffix = '.exe' if os.name == 'nt' else ''
        java_home = os.environ.get('JAVA_HOME')
        javac = str(Path(java_home) / f'bin/javac{suffix}') if java_home else shutil.which('javac')
        java = str(Path(java_home) / f'bin/java{suffix}') if java_home else shutil.which('java')
        self.assertTrue(javac and java, 'A JDK is required; this test does not use Android/JNI')
        with tempfile.TemporaryDirectory(prefix='office-change-tracker-') as folder:
            harness = Path(folder) / 'ChangeTrackerHarness.java'
            harness.write_text(HARNESS, encoding='utf-8')
            compiled = subprocess.run([javac, '-encoding', 'UTF-8', '-d', folder, str(harness), str(SOURCE)],
                                      capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([java, '-cp', folder, 'ChangeTrackerHarness'],
                                    capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('change tracker assertions passed', result.stdout)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main(verbosity=2)
