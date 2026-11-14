"""Execute actual Activity lifecycle/delegation bodies with small host stubs.

The journal, native transport and Android platform are stubs here; separate
tests execute the actual journal, transport, reply codec and UI controller.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from test_lifecycle import method
from test_cell_reply import JSON_JAR

MODULE = Path(__file__).parent
SOURCE = MODULE / 'src/main/java/io/github/canele452/personalinkvault/office/OfficeEditorActivity.java'
HEALTH = MODULE / 'src/main/java/io/github/canele452/personalinkvault/office/OfficeEngineHealth.java'

HARNESS = r'''
package io.github.canele452.personalinkvault.office;
import java.util.*;import java.io.IOException;import org.json.*;import java.nio.charset.StandardCharsets;import java.security.MessageDigest;
class Intent {
  final Map<String,String> extras = new HashMap<>();
  Intent putExtra(String key, String value) { extras.put(key, value); return this; }
  boolean getBooleanExtra(String key, boolean fallback) {
    return extras.containsKey(key) ? Boolean.parseBoolean(extras.get(key)) : fallback;
  }
}
class Activity { static final int RESULT_CANCELED = 0; }
class OfficeEngineBridge { static final String PREVIEW_PDF_READY_EXTRA = "piv.previewPdfReady"; }
class Parent {
  static final List<String> events = new ArrayList<>();
  boolean parentThrows;
  protected void onDestroy() {
    events.add("native-destroy");
    if (parentThrows) throw new IllegalStateException("native cleanup fixture");
  }
  protected void onEmbeddedActivityReleased() {}
}
class OfficeSessionJournal {
  static void releaseEditor(Object owner) { Parent.events.add("release-owner"); }
}
class OfficePresentationCells {
  boolean busy, consumed, closeThrows;
  byte[] received;
  void close() {
    Parent.events.add("cell-destroy");
    if (closeThrows) throw new IllegalStateException("dialog cleanup fixture");
  }
  boolean handleBack() { Parent.events.add("cell-back"); return consumed; }
  boolean blocksSave() { return busy; }
  boolean onNativeMessage(byte[] frame) { received = frame; return consumed; }
}
class OfficeEngineProcess {
  static void log(String message) {}
  static void stopAfterRelease(Object activity) { Parent.events.add("engine-stop"); }
}
class OfficePreviewOutputs {
  static void deleteResultRecord(java.io.File directory) {}
}
public final class CellActivityHarness extends Parent {
  __FORMAT_MISMATCH__
  OfficePresentationCells presentationCells;
  java.io.File directory;
  boolean engineAttached = true;
  boolean previewOnly, previewCancelled, previewRequested, previewLoadFailed, previewResultSet;
  boolean ready, finishing, destroyed;
  String sessionId = "fixture-session";
  Intent result;
  int resultCode = -1;
  String sentId, sentScript;
  byte[] plannedOld, plannedNew, plannedReply;
  byte[] nativePlanCellText(byte[] old,byte[] text) { plannedOld=old; plannedNew=text; return plannedReply; }
  boolean isFinishing() { return finishing; }
  boolean isDestroyed() { return destroyed; }
  void runOnUiThread(Runnable action) { action.run(); }
  void setResult(int code, Intent data) { resultCode = code; result = data; }
  void finish() { finishing = true; events.add("finish-preview"); }
  void finishWithProgress() { events.add("safe-save-close"); }
  boolean sendEmbeddedScript(String id, String source) {
    sentId = id; sentScript = source; return true;
  }
  void completeEmbeddedScript() { events.add("complete-script"); }
  __METHODS__
  static void require(boolean value, String message) {
    if (!value) throw new AssertionError(message + ": " + events);
  }
  static void cleanup() {
    for (boolean dialogThrows : new boolean[]{false,true}) {
      for (boolean nativeThrows : new boolean[]{false,true}) {
        events.clear();
        CellActivityHarness h = new CellActivityHarness();
        h.presentationCells = new OfficePresentationCells();
        h.presentationCells.closeThrows = dialogThrows;
        h.parentThrows = nativeThrows;
        try { h.onDestroy(); } catch (IllegalStateException expected) {}
        require(events.equals(List.of("cell-destroy","native-destroy")),
          "dialog cleanup failure must not skip native cleanup or release early");
        h.onEmbeddedActivityReleased();
        require(events.subList(events.size()-2, events.size()).equals(List.of("release-owner","engine-stop")),
          "native release ends ownership before the engine process stops");
      }
    }
    events.clear(); CellActivityHarness h = new CellActivityHarness();
    h.onDestroy(); h.onEmbeddedActivityReleased();
    require(events.equals(List.of("native-destroy","release-owner","engine-stop")),
      "non-cell session still releases native ownership, then stops the engine process");
    events.clear(); CellActivityHarness refused = new CellActivityHarness();
    refused.engineAttached = false;
    refused.onDestroy(); refused.onEmbeddedActivityReleased();
    require(events.equals(List.of("native-destroy","release-owner")),
      "an Activity the main process refused never ends a process the next launch may reuse");
  }
  static void replacement() {
    events.clear(); CellActivityHarness h = new CellActivityHarness();
    h.presentationCells = new OfficePresentationCells(); h.presentationCells.consumed = true;
    h.onNewIntent(new Intent());
    require(events.equals(List.of("cell-back")), "pending replacement waits for owned edit instead of opening an unbound Activity");
    events.clear(); h.presentationCells.consumed = false; h.onNewIntent(new Intent());
    require(events.equals(List.of("cell-back","safe-save-close")), "idle replacement saves its current private session");
    events.clear(); h.previewOnly = true; h.onNewIntent(new Intent());
    require(h.previewCancelled && events.equals(List.of("finish-preview")), "preview replacement finishes without waiting for its native close");
  }
  static void bridge() {
    CellActivityHarness h = new CellActivityHarness();
    byte[] frame = new byte[]{0,1,(byte)255};
    require(!h.isEmbeddedDocumentBusy() && !h.onEmbeddedNativeMessage(frame), "no cell owner leaves native frames untouched");
    h.presentationCells = new OfficePresentationCells(); h.presentationCells.busy = true;
    require(h.isEmbeddedDocumentBusy(), "pending owner blocks saves");
    require(!h.onEmbeddedNativeMessage(frame) && h.presentationCells.received == frame, "foreign response decision and exact bytes are delegated");
    h.presentationCells.consumed = true;
    require(h.onEmbeddedNativeMessage(frame), "only owner can consume its response");
    require(h.postCellScript("ticket","program") && h.sentId.equals("ticket") && h.sentScript.equals("program"), "request is forwarded without replacing its ID or program");
    events.clear(); h.completeCellScript(); h.closeCellEditor();
    require(events.equals(List.of("complete-script","safe-save-close")), "completion and close preserve native hooks");
    require(!h.isCellEditorReady(), "not-ready editor cannot expose controls");
    h.ready = true; require(h.isCellEditorReady(), "loaded edit session is available");
    h.previewOnly = true; require(!h.isCellEditorReady(), "preview cannot expose mutation controls");
    h.previewOnly = false; h.finishing = true; require(!h.isCellEditorReady(), "finishing owner cannot begin another edit");
    h.finishing = false; h.destroyed = true; require(!h.isCellEditorReady(), "destroyed owner cannot begin another edit");
    h.destroyed = false; OfficeEngineHealth.quarantine(); require(!h.isCellEditorReady(), "quarantined native engine cannot expose edit controls");
  }
  static String hash(String text)throws Exception {StringBuilder s=new StringBuilder();for(byte b:MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)))s.append(String.format(Locale.ROOT,"%02x",b&255));return s.toString();}
  static void planner()throws Exception {
    CellActivityHarness h=new CellActivityHarness();String old="한😀\u0000",text="바😀\u0000";
    h.plannedReply=new JSONObject().put("protocol","piv-text-style-map-1").put("oldUtf16Length",old.length()).put("newUtf16Length",text.length()).put("oldSha256",hash(old)).put("newSha256",hash(text)).put("paragraphs",new JSONArray().put(new JSONObject().put("sourceParagraph",0).put("segments",new JSONArray().put(new JSONObject().put("kind","inherit").put("newStart",0).put("newEnd",text.length()).put("oldStart",0).put("oldEnd",1))))).toString().getBytes(StandardCharsets.UTF_8);
    require(h.planCellText(old,text).getString("protocol").equals("piv-text-style-map-1"),"actual Activity verifies native plan before returning it");
    require(Arrays.equals(h.plannedOld,old.getBytes(StandardCharsets.UTF_8))&&Arrays.equals(h.plannedNew,text.getBytes(StandardCharsets.UTF_8)),"JNI receives standard UTF8 including supplementary scalar and literal NUL");
    h.plannedOld=null;try{h.planCellText("\ud800",text);throw new AssertionError("invalid Unicode passed native boundary");}catch(IOException expected){}
    require(h.plannedOld==null,"invalid original is rejected before JNI");
    h.plannedReply=null;try{h.planCellText(old,text);throw new AssertionError("missing native reply accepted");}catch(IOException expected){}
  }
  static void mismatch() {
    CellActivityHarness h = new CellActivityHarness();
    require(!h.finishOnFormatMismatch(new IOException("ordinary export failure")) && h.result == null,
        "an ordinary export error keeps the existing retry path");
    require(h.finishOnFormatMismatch(new IOException("office_format_mismatch")),
        "an Office family mismatch is terminal");
    require(h.resultCode == Activity.RESULT_CANCELED
        && h.sessionId.equals(h.result.extras.get("sessionId"))
        && "office_format_mismatch".equals(h.result.extras.get("errorCode"))
        && h.result.extras.get("errorMessage").contains("실제 문서 종류"),
        "the Activity closes with a session-bound mismatch error");
  }
  public static void main(String[] args)throws Exception {
    switch (args[0]) {
      case "cleanup": cleanup(); break;
      case "replacement": replacement(); break;
      case "bridge": bridge(); break;
      case "planner": planner(); break;
      case "mismatch": mismatch(); break;
      default: throw new AssertionError("Unknown scenario");
    }
    System.out.println(args[0] + " actual Activity body checks passed (host only)");
  }
}
'''


class CellActivityTests(unittest.TestCase):
    def test_actual_activity_releases_native_owner_even_if_dialog_cleanup_throws(self):
        self.run_harness('cleanup')

    def test_actual_activity_replacement_saves_its_private_session(self):
        self.run_harness('replacement')

    def test_actual_activity_delegates_only_to_live_owned_cell_controller(self):
        self.run_harness('bridge')

    def test_actual_activity_uses_standard_utf8_and_validates_native_plan(self):
        self.run_harness('planner')

    def test_actual_activity_closes_only_the_permanent_format_mismatch(self):
        self.run_harness('mismatch')

    def run_harness(self, scenario):
        text = SOURCE.read_text(encoding='utf-8')
        signatures = ('protected void onDestroy()', 'protected void onEmbeddedActivityReleased()',
                      'protected void onNewIntent(Intent intent)',
                      'protected boolean isEmbeddedDocumentBusy()', 'protected boolean onEmbeddedNativeMessage(byte[] message)',
                      'private static String previewLoadFailure(byte[] message)',
                      'boolean isCellEditorReady()', 'boolean postCellScript(String requestId, String script)',
                      'void completeCellScript()', 'void closeCellEditor()',
                      'JSONObject planCellText(String oldText, String newText)',
                      'private void deliverPreviewResult(int code, Intent result)',
                      'private boolean finishOnFormatMismatch(Exception error)')
        bodies = '\n'.join(method(text, signature) for signature in signatures)
        mismatch = next(line.strip() for line in text.splitlines()
                        if 'private static final String FORMAT_MISMATCH =' in line)
        java_home = os.environ.get('JAVA_HOME')
        suffix = '.exe' if os.name == 'nt' else ''
        javac = str(Path(java_home) / f'bin/javac{suffix}') if java_home else shutil.which('javac')
        java = str(Path(java_home) / f'bin/java{suffix}') if java_home else shutil.which('java')
        self.assertTrue(javac and java, 'A JDK is required; this is not Android/JNI execution')
        with tempfile.TemporaryDirectory(prefix='office-cell-activity-') as folder:
            source = Path(folder) / 'CellActivityHarness.java'
            source.write_text(HARNESS.replace('__METHODS__', bodies)
                              .replace('__FORMAT_MISMATCH__', mismatch), encoding='utf-8')
            result = subprocess.run([javac, '-encoding', 'UTF-8', '-cp', str(JSON_JAR), '-d', folder, str(source), str(HEALTH),
                                    str(SOURCE.with_name('OfficeLegacyContainer.java')),
                                    str(MODULE / 'src/main/java/io/github/canele452/personalinkvault/office/OfficeTextStylePlan.java'),
                                    str(MODULE / 'src/main/java/io/github/canele452/personalinkvault/office/OfficeCellReply.java'),
                                    str(MODULE / 'src/main/java/io/github/canele452/personalinkvault/office/OfficeScriptSession.java')],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([java, '-cp', folder+os.pathsep+str(JSON_JAR),
                'io.github.canele452.personalinkvault.office.CellActivityHarness', scenario],
                capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main(verbosity=2)
