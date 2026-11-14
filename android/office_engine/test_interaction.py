"""Run patched Office interaction methods in a plain JDK harness.

The generated helper and callback bodies are real product source. Android views,
URI parsing and native close are small stubs; this is not an Android/JNI test.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from prepare_engine import ROOT, patch_activity
from test_lifecycle import method


MODULE = Path(__file__).parent
ACTIVITY = MODULE / "src/main/java/io/github/canele452/personalinkvault/office/OfficeEditorActivity.java"

HARNESS = r'''
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;

public class InteractionHarness {
  static final int RESULT_OK=-1, RESULT_CANCELED=0;
  boolean pivDestroyed, pivClosing, finishing, destroyed;
  boolean documentLoaded=true, previewOnly, previewCancelled;
  boolean mSlideShowActive, mMobileWizardVisible, mIsEditModeActive;
  final AtomicBoolean pivNativeClosed=new AtomicBoolean();
  Object mCurrentFullScreenView;
  final List<String> events=new ArrayList<>();
  interface ValueCallback<T> { void onReceiveValue(T value); }
  static final class Uri { final String value; Uri(String value) {this.value=value;} }
  static final class Activity { static final int RESULT_CANCELED=0; }
  static final class OfficeEngineBridge { static final String PREVIEW_CANCELLED_EXTRA="piv.previewCancelled"; }
  static final class OfficePreviewOutputs { static void deleteResultRecord(java.io.File directory) {} }
  java.io.File directory;
  static final class Intent {
    final Uri[] values;
    final Map<String,Object> extras=new HashMap<>();
    Intent() { this(null); }
    Intent(Uri[] values) { this.values=values; }
    Intent putExtra(String key,Object value) { extras.put(key,value); return this; }
  }
  final String sessionId="preview-session";
  boolean previewResultSet;
  Intent result;
  int resultCode;
  void setResult(int code,Intent data) { resultCode=code; result=data; }
  ValueCallback<Uri[]> valueCallback;
  static final class WebChromeClient {
    static final class FileChooserParams {
      static int parses;
      static Runnable observer;
      static Uri[] parseResult(int code,Intent intent) {
        parses++;
        if (observer!=null) observer.run();
        return intent==null?null:intent.values;
      }
    }
  }
  boolean isFinishing() {return finishing;}
  boolean isDestroyed() {return destroyed;}
  boolean isEmbeddedPreviewOnly() {return previewOnly;}
  boolean isEmbeddedDocumentBusy() {return false;}
  static class CellUI {
    boolean pending = true;
    int backs;
    boolean handleBack() { backs++; return pending; }
  }
  CellUI presentationCells;
  void hideFullScreenView() {events.add("fullscreen");mCurrentFullScreenView=null;}
  void callFakeWebsocketOnMessage(String message) {events.add(message);}
  void finishAndRemoveTask() {events.add("REMOVE_FLUTTER_TASK");finishing=true;}
  void finish() {events.add("finish-preview");finishing=true;}
  void finishWithProgress() {
    if (pivDestroyed || destroyed || pivClosing || finishing || pivNativeClosed.get()) return;
    events.add(documentLoaded?"safe-save-close":"safe-empty-close");
    if (documentLoaded) pivClosing=true;
    else finishing=true;
  }
  __BACK_METHODS__
  __IMAGE_HELPER__

  static void require(boolean condition,String message) {
    if (!condition) throw new AssertionError(message);
  }
  static void expect(InteractionHarness h,String... events) {
    require(h.events.equals(Arrays.asList(events)),"expected "+Arrays.toString(events)+", actual "+h.events);
  }
  static void back(InteractionHarness h,boolean subclass) {
    if (subclass) h.childBack(); else h.parentBack();
  }
  static void backScenarios() {
    for (boolean subclass:new boolean[]{false,true}) {
      InteractionHarness h=new InteractionHarness();
      h.mCurrentFullScreenView=new Object();
      h.mSlideShowActive=true; h.mMobileWizardVisible=true; h.mIsEditModeActive=true;
      back(h,subclass); expect(h,"fullscreen");
      h.events.clear(); back(h,subclass); expect(h,"mobile: slideshowback");
      h.mSlideShowActive=false; h.events.clear(); back(h,subclass); expect(h,"mobile: mobilewizardback");
      h.mMobileWizardVisible=false; h.events.clear(); back(h,subclass); expect(h,"mobile: readonlymode");
      h.mIsEditModeActive=false; h.events.clear(); back(h,subclass); expect(h,"safe-save-close");
      back(h,subclass); expect(h,"safe-save-close");
      InteractionHarness loading=new InteractionHarness(); loading.documentLoaded=false;
      back(loading,subclass); back(loading,subclass); expect(loading,"safe-empty-close");
      for (String state:List.of("destroyed","platform-destroyed","finishing","closing","closed")) {
        InteractionHarness late=new InteractionHarness(); late.mCurrentFullScreenView=new Object();
        if (state.equals("destroyed")) late.pivDestroyed=true;
        if (state.equals("platform-destroyed")) late.destroyed=true;
        if (state.equals("finishing")) late.finishing=true;
        if (state.equals("closing")) late.pivClosing=true;
        if (state.equals("closed")) late.pivNativeClosed.set(true);
        back(late,subclass); back(late,subclass); expect(late);
      }
    }
    InteractionHarness preview=new InteractionHarness(); preview.previewOnly=true;
    preview.mCurrentFullScreenView=new Object(); preview.mSlideShowActive=true;
    preview.mMobileWizardVisible=true; preview.mIsEditModeActive=true;
    preview.childBack(); preview.childBack();
    require(preview.previewCancelled && preview.previewResultSet && preview.resultCode==RESULT_CANCELED
        && preview.sessionId.equals(preview.result.extras.get("sessionId"))
        && Boolean.TRUE.equals(preview.result.extras.get("piv.previewCancelled")),
        "preview back returns an explicit cancellation for the active session");
    expect(preview,"finish-preview");
    InteractionHarness cells=new InteractionHarness();
    cells.presentationCells=new CellUI();
    cells.childBack();
    require(cells.presentationCells.backs==1,"Activity back must reach the structured edit owner");
    expect(cells);
    cells.presentationCells.pending=false;
    cells.childBack();
    expect(cells,"safe-save-close");
    System.out.println("generated back interaction scenarios passed");
  }
  static void imageScenarios() {
    InteractionHarness h=new InteractionHarness();
    h.deliverEmbeddedImageResult(RESULT_CANCELED,null);
    require(WebChromeClient.FileChooserParams.parses==0,"cancel without a picker callback never parses or crashes");
    List<Uri[]> received=new ArrayList<>();
    h.valueCallback=value->{require(h.valueCallback==null,"cancel clears ownership before invoking its callback");received.add(value);};
    h.deliverEmbeddedImageResult(RESULT_CANCELED,null);
    require(received.size()==1 && received.get(0)==null,"cancel delivers exactly one null");
    h.deliverEmbeddedImageResult(RESULT_CANCELED,null);
    require(received.size()==1,"duplicate cancel is ignored after ownership is cleared");
    require(WebChromeClient.FileChooserParams.parses==0,"cancel does not ask Android to parse an image URI");

    Uri[] selected={new Uri("content://fixture/image")};
    ValueCallback<Uri[]> next=value->{require(value==null,"new picker receives its own cancellation");received.add(value);};
    h.valueCallback=value->{
      require(h.valueCallback==null,"success clears ownership before invoking callback");
      require(value==selected,"success forwards the selected URI array");
      h.valueCallback=next;
      received.add(value);
    };
    WebChromeClient.FileChooserParams.observer=()->require(h.valueCallback==null,"ownership is cleared before URI parsing too");
    h.deliverEmbeddedImageResult(RESULT_OK,new Intent(selected));
    require(h.valueCallback==next,"reentrant picker registration is not clobbered by completing the previous callback");
    require(WebChromeClient.FileChooserParams.parses==1,"live image success parses once");
    h.deliverEmbeddedImageResult(RESULT_CANCELED,null);
    require(h.valueCallback==null && received.size()==3,"the reentrant picker remains independently deliverable");
    h.deliverEmbeddedImageResult(RESULT_OK,new Intent(selected));
    require(WebChromeClient.FileChooserParams.parses==1,"late duplicate success with no callback never parses");
    WebChromeClient.FileChooserParams.observer=null;

    InteractionHarness recursive=new InteractionHarness();
    int[] calls={0,0};
    recursive.valueCallback=value->{
      calls[0]++;
      recursive.valueCallback=cancelled->{require(cancelled==null,"recursive cancel payload");calls[1]++;};
      recursive.deliverEmbeddedImageResult(RESULT_CANCELED,null);
    };
    recursive.deliverEmbeddedImageResult(RESULT_OK,new Intent(selected));
    require(Arrays.equals(calls,new int[]{1,1}) && recursive.valueCallback==null,"nested callback delivery keeps each owner exactly once");

    InteractionHarness throwing=new InteractionHarness();
    throwing.valueCallback=value->{throw new IllegalStateException("synthetic callback error");};
    try {throwing.deliverEmbeddedImageResult(RESULT_CANCELED,null);} catch (IllegalStateException expected) {}
    require(throwing.valueCallback==null,"a callback exception does not retain stale ownership");
    InteractionHarness empty=new InteractionHarness();
    empty.valueCallback=value->require(value==null,"a live OK result without URI data delivers null");
    empty.deliverEmbeddedImageResult(RESULT_OK,null);

    for (String state:List.of("destroyed","platform-destroyed","finishing","closing","closed","preview")) {
      for (int result:new int[]{RESULT_OK,RESULT_CANCELED}) {
        InteractionHarness late=new InteractionHarness();
        if (state.equals("destroyed")) late.pivDestroyed=true;
        if (state.equals("platform-destroyed")) late.destroyed=true;
        if (state.equals("finishing")) late.finishing=true;
        if (state.equals("closing")) late.pivClosing=true;
        if (state.equals("closed")) late.pivNativeClosed.set(true);
        if (state.equals("preview")) late.previewOnly=true;
        int before=WebChromeClient.FileChooserParams.parses;
        late.valueCallback=value->{throw new AssertionError("late image callback must be ignored: "+state);};
        late.deliverEmbeddedImageResult(result,new Intent(selected));
        require(late.valueCallback==null,"late callback reference is released: "+state);
        require(WebChromeClient.FileChooserParams.parses==before,"late URI parsing is suppressed: "+state);
      }
    }
    System.out.println("generated image interaction scenarios passed");
  }
  public static void main(String[] args) {
    if (args[0].equals("back")) backScenarios(); else imageScenarios();
  }
}
'''


class InteractionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = ROOT / "cache/source/android/lib/src/main/java/org/libreoffice/androidlib/LOActivity.java"
        cls.original = source.read_text(encoding="utf-8")
        cls.generated = patch_activity(cls.original)
        cls.child = ACTIVITY.read_text(encoding="utf-8")

    def run_harness(self, scenario):
        if scenario == "back":
            signature = "protected void handleEmbeddedBack()"
            self.assertTrue(signature in self.generated, "the generated parent must expose a shared safe back hook")
            back_methods = method(self.generated, signature)
            back_methods += "\n" + method(self.generated, "public void handleOnBackPressed()").replace("public void handleOnBackPressed()", "void parentBack()", 1)
            back_methods += "\n" + method(self.child, "public void handleOnBackPressed()").replace("public void handleOnBackPressed()", "void childBack()", 1)
            back_methods += "\n" + method(self.child, "private void cancelPreview()")
            image_helper = "void deliverEmbeddedImageResult(int resultCode, Intent intent) {throw new AssertionError(\"unused image helper\");}"
        else:
            signature = "protected void deliverEmbeddedImageResult(int resultCode, Intent intent)"
            self.assertTrue(signature in self.generated, "image results must detach callback ownership before delivery")
            image_helper = method(self.generated, signature)
            back_methods = "void parentBack() {} void childBack() {}"
        harness = HARNESS.replace("__BACK_METHODS__", back_methods).replace("__IMAGE_HELPER__", image_helper)
        java_home = os.environ.get("JAVA_HOME")
        suffix = ".exe" if os.name == "nt" else ""
        javac = str(Path(java_home) / f"bin/javac{suffix}") if java_home else shutil.which("javac")
        java = str(Path(java_home) / f"bin/java{suffix}") if java_home else shutil.which("java")
        self.assertTrue(javac and java, "A JDK is required for source-method tests; this is not Android/JNI execution")
        with tempfile.TemporaryDirectory(prefix="office-interaction-") as folder:
            source = Path(folder) / "InteractionHarness.java"
            source.write_text(harness, encoding="utf-8")
            compiled = subprocess.run([javac, "-d", folder, str(source)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([java, "-cp", folder, "InteractionHarness", scenario], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("scenarios passed", result.stdout)
            print(result.stdout.strip())

    def test_generated_back_preserves_nested_state_and_preview_boundary(self):
        self.run_harness("back")

    def test_generated_image_result_handles_null_late_and_reentrant_callbacks(self):
        self.run_harness("image")

    def test_parent_and_subclass_callbacks_share_safe_back_hook(self):
        parent = method(self.generated, "public void handleOnBackPressed()")
        child = method(self.child, "public void handleOnBackPressed()")
        self.assertIn("handleEmbeddedBack();", parent)
        self.assertNotIn("finishAndRemoveTask", parent)
        self.assertIn("handleEmbeddedBack();", child)
        self.assertIn("cancelPreview();", child)

    def test_image_case_wiring_preserves_original_export_cancel(self):
        result = method(self.generated, "public void onActivityResult(int requestCode, int resultCode, Intent intent)")
        cancelled = method(result, "if (requestCode == REQUEST_SELECT_IMAGE_FILE)")
        self.assertIn("deliverEmbeddedImageResult(resultCode, intent);", cancelled)
        start = result.index("case REQUEST_SELECT_IMAGE_FILE:")
        end = result.index("case REQUEST_EXPORT_FILE:", start)
        self.assertIn("deliverEmbeddedImageResult(resultCode, intent);", result[start:end])
        self.assertNotIn("valueCallback.onReceiveValue", result)
        export = "else if (requestCode == REQUEST_EXPORT_FILE && mPendingExportSourcePath != null)"
        self.assertEqual(method(self.generated, export), method(self.original, export))

    def test_pinned_interaction_patch_refuses_unmatched_upstream_bodies(self):
        mutations = [
            ('callFakeWebsocketOnMessage("mobile: slideshowback");', 'callFakeWebsocketOnMessage("mobile: other-slideshow-back");'),
            ('if (requestCode == REQUEST_SELECT_IMAGE_FILE) {\n                valueCallback.onReceiveValue(null);', 'if (requestCode == REQUEST_SELECT_IMAGE_FILE) {\n                valueCallback.onReceiveValue(new Uri[0]);'),
            ('valueCallback.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(resultCode, intent));', 'valueCallback.onReceiveValue(otherParseResult(resultCode, intent));'),
        ]
        for before, after in mutations:
            with self.subTest(marker=before):
                self.assertEqual(self.original.count(before), 1)
                with self.assertRaises(ValueError):
                    patch_activity(self.original.replace(before, after, 1))


if __name__ == "__main__":
    unittest.main()
