"""Run the generated Java close/open methods with a deterministic native queue.

This validates lifecycle scheduling, not Android, JNI or device rendering.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

from prepare_engine import patch_activity, ROOT


def method(text, signature):
    start = text.index(signature)
    body = text.index("{", start)
    level = 1
    end = body + 1
    while level:
        level += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


class LifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = ROOT / "cache/source/android/lib/src/main/java/org/libreoffice/androidlib/LOActivity.java"
        cls.generated = patch_activity(source.read_text(encoding="utf-8"))

    def test_destroy_never_waits_for_native_close_on_the_ui_thread(self):
        body = method(self.generated, "protected void onDestroy()")
        self.assertNotIn("postMobileMessageNative", body)
        self.assertNotIn("nativeLooper.quit", body)
        self.assertIn("queueEmbeddedNativeClose()", body)

    def test_all_native_modal_progress_is_reserved_for_original_editing(self):
        calls = re.findall(r"^\s*(.*mProgressDialog\.(?:determinate|indeterminate)\(R\.string\.\w+\);)$", self.generated, re.MULTILINE)
        self.assertEqual(len(calls), 5)
        for call in calls:
            self.assertTrue(call.startswith("if (!isEmbeddedPreviewOnly()) "), call)

    def test_exact_generated_methods_preserve_close_once_and_cross_activity_order(self):
        bodies = "\n".join(method(self.generated, signature) for signature in [
            "protected boolean isEmbeddedDocumentBusy()",
            "private void closeEmbeddedNativeDocument()",
            "private void queueEmbeddedNativeClose()",
            "private void openEmbeddedNativeDocument(",
            "private void cancelEmbeddedNativeWatchdog()",
            "private void watchEmbeddedNativeOperation()",
            "private void failEmbeddedNativeSession()",
            "protected void finishWithProgress()",
            "protected void onDestroy()",
            "public void postMobileMessage(String message)",
        ])
        ready_case = method(self.generated, 'case "hideProgressbar":')
        editor = (Path(__file__).parent / 'src/main/java/io/github/canele452/personalinkvault/office/OfficeEditorActivity.java').read_text(encoding='utf-8')
        preview_callbacks = '\n'.join(method(editor, signature) for signature in [
            'protected boolean onEmbeddedNativeMessage(byte[] message)',
            'private static String previewLoadFailure(byte[] message)',
            'private void cancelPreview()',
            'private void deliverPreviewResult(int code, Intent result)',
            'public void postMobileMessage(String message)',
        ])
        self.assertIn("nativeHandler = embeddedNativeHandler();", self.generated)
        self.assertEqual(self.generated.count('new android.os.HandlerThread("office-native-messages")'), 1)
        harness = r'''
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.CountDownLatch;
import java.nio.charset.StandardCharsets;
import android.app.Activity;
import android.content.Intent;
import io.github.canele452.personalinkvault.office.OfficeEngineBridge;
import io.github.canele452.personalinkvault.office.OfficeEngineHealth;
class Parent { protected void onDestroy() {} }
public class Harness extends Parent {
  static final List<String> events = Collections.synchronizedList(new ArrayList<>());
  static final Handler queue = new Handler();
  static boolean runningNative;
  static class Handler {
    final ArrayDeque<Runnable> jobs = new ArrayDeque<>();
    Runnable delayed;
    boolean post(Runnable task) { jobs.add(task); return true; }
    boolean postDelayed(Runnable task,long ignored) { delayed=task; return true; }
    void removeCallbacks(Runnable task) { if(delayed==task) delayed=null; }
    void drain() { while(!jobs.isEmpty()) { runningNative=true; jobs.remove().run(); runningNative=false; } }
  }
  static class Task { void cancel(boolean ignored) {} }
  static class Progress {
    boolean shown;
    void dismiss() { shown=false; }
    void indeterminate(int ignored) { shown=true; }
  }
  static class AssetManager {}
  static class WebView { void loadUrl(String ignored) {} }
  static class R { static class string { static final int exiting=1; } }
  static class Log {
    static void i(String tag,String text) {}
    static void d(String tag,String text) {}
  }
  final String TAG="fixture";
  final String id;
  final Handler nativeHandler = queue;
  final Handler mainHandler = new Handler();
  final Progress mProgressDialog = new Progress();
  final AtomicBoolean pivNativeClosed = new AtomicBoolean();
  final AtomicBoolean pivNativeHelloStarted = new AtomicBoolean();
  final CountDownLatch pivNativeHello = new CountDownLatch(1);
  static final long PIV_HANDSHAKE_TIMEOUT_MILLIS=250;
  static final long PIV_OPERATION_TIMEOUT_MILLIS=45000;
  final ArrayDeque<Runnable> ui = new ArrayDeque<>();
  volatile boolean pivDestroyed, documentLoaded;
  volatile boolean pivNativeReleased;
  Runnable pivNativeWatchdog;
  boolean pivNativeOpened, pivClosing, finishing, preview;
  boolean pivAwaitingReady;
  Task pivPreparationTask;
  WebView mWebView = new WebView();
  Runnable onCreateNative, onSave;
  boolean allowSave=true;
  boolean automaticHello=true;
  CountDownLatch blockedClose;
  String lastError;
  boolean keepPreviewResult;
  Harness(String id) { this.id=id; }
  void createCOOLWSD(String a,String b,String c,AssetManager d,String e,String f,String g) {
    require(runningNative,"create must run on native queue");
    events.add("open:"+id);
    if(onCreateNative!=null) onCreateNative.run();
    if(automaticHello) pivNativeHello.countDown();
  }
  void postMobileMessageNative(String command) {
    require(runningNative,"UI must never block in BYE");
    if(blockedClose!=null) try { blockedClose.await(); } catch(InterruptedException e) { throw new RuntimeException(e); }
    events.add("close:"+id);
  }
  boolean beforeEmbeddedDocumentClose() {
    events.add("save:"+id);
    if(onSave!=null) onSave.run();
    return allowSave;
  }
  void runOnUiThread(Runnable task) { ui.add(task); }
  Handler getMainHandler() { return mainHandler; }
  android.content.Intent getIntent() { return new android.content.Intent().putExtra("piv.sessionId",id); }
  void setResult(int code,android.content.Intent intent) { lastError=intent.getStringExtra("errorCode"); }
  void drainUi() { while(!ui.isEmpty()) ui.remove().run(); }
  void destroyEmbeddedWebView() { mWebView=null; }
  void onEmbeddedActivityReleased() {
    require(pivDestroyed && mWebView==null,"an Activity releases only after destruction and WebView cleanup");
    events.add("release:"+id);
  }
  void stopWatchingForHardwareKeyboard() {}
  boolean isFinishing() { return finishing; }
  boolean isDestroyed() { return pivDestroyed; }
  boolean isEmbeddedPreviewOnly() { return preview; }
  boolean hasEmbeddedPreviewResult() { return keepPreviewResult; }
  boolean canAllFilesAccessHelp() { return false; }
  void askForAllFilesAccess() { throw new AssertionError("unexpected permission request"); }
  void afterMessageFromWebView(String[] messageAndParam) {}
  boolean beforeMessageFromWebView(String[] messageAndParam) {
    switch (messageAndParam[0]) { __READY_CASE__ }
    return true;
  }
  void finish() { finishing=true; }
  void open() { openEmbeddedNativeDocument("a","b","c",new AssetManager(),"d","e","f","g"); }
  static void require(boolean condition,String message) { if(!condition) throw new AssertionError(message); }
__METHODS__
  public static void main(String[] args) {
    if(args.length>0 && args[0].equals("queued-close")) { queuedCloseTimeoutScenario(); return; }
    if(args.length>0 && args[0].equals("preview")) { previewReadinessScenario(); return; }
    if(args.length>0 && args[0].equals("preview-close")) { previewCloseWatchdogScenario(); return; }
    if(args.length>0) { watchdogScenario(); return; }
    Harness a=new Harness("a"); a.open(); queue.drain(); a.drainUi();
    a.onSave=()->a.onDestroy();
    a.finishWithProgress();
    queue.drain(); a.drainUi();
    // The engine process sends the only native close from onDestroy and then exits; the main process
    // starts the next Office Activity only after that process is gone.
    require(events.equals(Arrays.asList("open:a","save:a","close:a","release:a")),"save/destroy order: "+events);
    Harness b=new Harness("b"); b.open();
    queue.drain(); b.drainUi();
    require(events.equals(Arrays.asList("open:a","save:a","close:a","release:a","open:b")),"next open follows the release: "+events);
    a.onDestroy(); queue.drain();
    require(Collections.frequency(events,"close:a")==1,"native close must happen once");
    Harness kept=new Harness("kept"); kept.open(); queue.drain(); kept.drainUi();
    kept.finishWithProgress(); queue.drain(); kept.drainUi();
    require(kept.finishing && events.contains("save:kept") && !events.contains("close:kept"),
        "finish delivers the result and leaves the native close to onDestroy: "+events);
    kept.onDestroy(); queue.drain(); kept.drainUi();
    require(Collections.frequency(events,"close:kept")==1 && events.indexOf("save:kept")<events.indexOf("close:kept"),
        "onDestroy closes the native document once, after the save: "+events);
    Harness cancelled=new Harness("cancel"); cancelled.open(); cancelled.onDestroy(); queue.drain();
    require(!events.contains("open:cancel")&&!events.contains("close:cancel"),"cancel before native load must not open an orphan document");
    Harness finished=new Harness("finished"); finished.open(); finished.finishWithProgress(); queue.drain();
    require(finished.finishing && !events.contains("open:finished"),"cancel must prevent queued open before destruction");
    Harness during=new Harness("during"); during.onCreateNative=()->during.onDestroy();
    during.open(); queue.drain(); during.drainUi();
    require(Collections.frequency(events,"close:during")==1,"destroy during native create must close once");
    require(events.indexOf("release:during")>events.indexOf("close:during"),"a destroyed Activity releases ownership after native close");
    Harness failed=new Harness("failed"); failed.open(); queue.drain(); failed.drainUi();
    failed.allowSave=false; failed.finishWithProgress(); queue.drain(); failed.drainUi();
    require(!failed.pivClosing&&!failed.pivNativeClosed.get(),"failed save must retain the live document for retry");
    failed.onDestroy(); queue.drain();
    require(Collections.frequency(events,"close:failed")==1,"failed save must later close on destroy");
    b.finishWithProgress(); queue.drain(); b.drainUi(); b.onDestroy(); queue.drain();
    require(Collections.frequency(events,"close:b")==1,"normal finish plus destroy must not send duplicate BYE");
    Harness pending=new Harness("hello"); pending.automaticHello=false;
    pending.open(); queue.drain(); pending.drainUi(); pending.onDestroy();
    Harness afterHello=new Harness("afterHello"); afterHello.open();
    Thread nativeWorker=new Thread(()->queue.drain()); nativeWorker.start();
    try { Thread.sleep(50); } catch(InterruptedException error) { throw new RuntimeException(error); }
    require(!events.contains("close:hello")&&!events.contains("open:afterHello"),"close and next open must retain ownership until HULLO");
    require(!events.contains("release:hello"),"destroying a pending handshake must keep its ownership");
    pending.pivNativeHello.countDown();
    try { nativeWorker.join(2000); } catch(InterruptedException error) { throw new RuntimeException(error); }
    require(!nativeWorker.isAlive(),"native close must complete after HULLO");
    pending.drainUi();
    require(events.indexOf("release:hello")>events.indexOf("close:hello"),"ownership must follow native close");
    require(events.indexOf("close:hello")<events.indexOf("open:afterHello"),"late HULLO must not close a later document");
    Harness timedOut=new Harness("timeout"); timedOut.automaticHello=false;
    timedOut.open(); queue.drain(); timedOut.drainUi(); timedOut.finishWithProgress(); queue.drain(); timedOut.drainUi();
    require(timedOut.finishing && timedOut.mainHandler.delayed==null
        && !io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart(),
        "finish delivers the result without waiting for HULLO and ends its close watchdog");
    timedOut.onDestroy(); queue.drain(); timedOut.drainUi();
    require(io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart(),"HULLO timeout at the native close must quarantine this engine process");
    require(events.contains("release:timeout"),"the quarantined Activity still releases so its engine process can exit: "+events);
    Harness rejected=new Harness("rejected"); rejected.open(); queue.drain(); rejected.drainUi();
    require(!events.contains("open:rejected")&&rejected.finishing,"quarantined engine must reject a later open without entering native code");
    System.out.println("generated lifecycle queue scenarios passed");
  }
  static void watchdogScenario() {
    Harness stalled=new Harness("stalled"); stalled.open(); queue.drain(); stalled.drainUi();
    require(stalled.mainHandler.delayed!=null,"opening must be bounded before readiness");
    stalled.postMobileMessage("hideProgressbar"); stalled.drainUi();
    require(stalled.mainHandler.delayed==null,"readiness must release the opening watchdog");
    stalled.blockedClose=new CountDownLatch(1);
    stalled.finishWithProgress();
    Runnable closeDeadline=stalled.mainHandler.delayed;
    require(closeDeadline!=null,"closing must arm a new watchdog");
    stalled.postMobileMessage("hideProgressbar delayed"); stalled.drainUi();
    require(stalled.mainHandler.delayed==closeDeadline,"late readiness must not cancel the close watchdog");
    require(stalled.mProgressDialog.shown,"late readiness must not dismiss editor close progress");
    Thread nativeWorker=new Thread(()->queue.drain()); nativeWorker.start();
    try { Thread.sleep(25); } catch(InterruptedException e) { throw new RuntimeException(e); }
    require(!stalled.pivNativeReleased,"fixture must hold native close open");
    stalled.mainHandler.delayed.run();
    require(stalled.finishing && io.github.canele452.personalinkvault.office.OfficeEngineHealth.ERROR_CODE.equals(stalled.lastError),"UI watchdog must finish with an error while native close is blocked");
    require(!io.github.canele452.personalinkvault.office.OfficeEngineHealth.RECOVERY_MESSAGE.contains("강제 종료")
        && io.github.canele452.personalinkvault.office.OfficeEngineHealth.RECOVERY_MESSAGE.contains("다시 시작"),
        "recovery restarts only the engine process; no Android force-stop is needed");
    stalled.blockedClose.countDown();
    try { nativeWorker.join(2000); } catch(InterruptedException e) { throw new RuntimeException(e); }
    require(!nativeWorker.isAlive(),"fixture worker must be released");
    Harness rejected=new Harness("afterStall"); rejected.open(); queue.drain(); rejected.drainUi();
    require(!events.contains("open:afterStall")&&rejected.finishing,"completed late native close must not silently clear quarantine");
    System.out.println("generated lifecycle watchdog scenarios passed");
  }
  static void queuedCloseTimeoutScenario() {
    Harness expired=new Harness("expired"); expired.open(); queue.drain(); expired.drainUi();
    expired.finishWithProgress();
    expired.mainHandler.delayed.run();
    queue.drain(); expired.drainUi();
    require(expired.finishing && io.github.canele452.personalinkvault.office.OfficeEngineHealth.ERROR_CODE.equals(expired.lastError),"timeout must retain its failure result");
    require(!events.contains("save:expired"),"close that timed out in the queue must not start exporting later");
    System.out.println("generated lifecycle queued-close scenarios passed");
  }
  static void previewCloseWatchdogScenario() {
    Harness exported = new Harness("exported"); exported.preview = true;
    exported.open(); queue.drain(); exported.drainUi();
    exported.keepPreviewResult = true;
    exported.finishWithProgress();
    exported.mainHandler.delayed.run();
    require(exported.finishing && exported.lastError==null,
        "a close deadline must keep the already-published preview result");
    require(io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart(),
        "stalled native close still prevents another native request");
    System.out.println("preview close watchdog scenarios passed");
  }
  static void previewReadinessScenario() {
    PreviewEditor preview = new PreviewEditor();
    byte[] status = "status: {\"type\":\"presentation\",\"parts\":3}".getBytes(StandardCharsets.US_ASCII);
    preview.onEmbeddedNativeMessage(status);
    require(preview.exports==1, "native document status must start export without a WebView readiness message");
    preview.onEmbeddedNativeMessage(status);
    preview.postMobileMessage("hideProgressbar");
    require(preview.exports==1, "repeated readiness must not start a second export");
    PreviewEditor stillLoading = new PreviewEditor();
    stillLoading.postMobileMessage("hideProgressbar");
    require(stillLoading.exports==0, "dismissing a WebView dialog cannot start export before native document load");
    stillLoading.previewCancelled=true;
    stillLoading.onEmbeddedNativeMessage(status);
    require(stillLoading.exports==0, "late native status cannot export a cancelled preview");
    PreviewEditor cancelled = new PreviewEditor();
    cancelled.ready=true;
    cancelled.requestCancel();
    require(cancelled.finishing && cancelled.closes==0 && cancelled.previewResultSet
        && cancelled.result.getBooleanExtra("piv.previewCancelled",false),
        "user cancellation leaves the preview screen before the native queue drains");
    cancelled.receiveResult(Activity.RESULT_OK,new Intent().putExtra("piv.previewPdfReady",true));
    require(cancelled.resultCode==Activity.RESULT_CANCELED,"a late PDF cannot overwrite explicit cancellation");
    PreviewEditor exported = new PreviewEditor();
    exported.receiveResult(Activity.RESULT_OK,new Intent().putExtra("piv.previewPdfReady",true));
    require(exported.finishing && exported.closes==0 && exported.previewResultSet
        && exported.resultCode==Activity.RESULT_OK,"a validated PDF leaves the preview screen before close");
    for (String kind : List.of("faileddocloading", "passwordrequired:to-view", "wrongpassword")) {
      PreviewEditor failed = new PreviewEditor();
      byte[] failure = ("error: cmd=load kind="+kind).getBytes(StandardCharsets.US_ASCII);
      require(failed.onEmbeddedNativeMessage(failure), "terminal load errors must exit the preview overlay");
      require(failed.finishing && failed.closes==0 && failed.exports==0,
          "a failed load must return before waiting for native close");
      require("office_preview_load_failed".equals(failed.result.getStringExtra("errorCode")), "the caller receives a load failure");
      require(failed.result.getStringExtra("errorMessage").contains("암호")==kind.contains("password"), "only password errors request an unlocked copy");
      failed.onEmbeddedNativeMessage(status);
      failed.onEmbeddedNativeMessage(failure);
      require(failed.closes==0, "late native messages cannot restart a failed preview");
    }
    PreviewEditor unloading = new PreviewEditor();
    require(!unloading.onEmbeddedNativeMessage("error: cmd=load kind=docunloading".getBytes(StandardCharsets.US_ASCII)),
        "a transient unloading response must reach Collabora");
    unloading.onEmbeddedNativeMessage(status);
    require(unloading.exports==1 && unloading.closes==1, "a transient response can still lead to a PDF");
    PreviewEditor editable = new PreviewEditor();
    editable.previewOnly = false;
    require(!editable.onEmbeddedNativeMessage("error: cmd=load kind=passwordrequired:to-view".getBytes(StandardCharsets.US_ASCII))
        && editable.result==null, "the interactive editor retains its password dialog");
    Harness watchdog = new Harness("preview-load");
    watchdog.preview=true;
    watchdog.open(); queue.drain(); watchdog.drainUi();
    Runnable deadline=watchdog.mainHandler.delayed;
    require(deadline!=null, "native loading must have a deadline");
    watchdog.postMobileMessage("hideProgressbar"); watchdog.drainUi();
    require(watchdog.mainHandler.delayed==deadline, "a WebView dialog cannot cancel the preview load deadline");
    System.out.println("native preview readiness scenarios passed");
  }
}
class OfficeEngineProcess { static void log(String message) {} }
class OfficePreviewOutputs { static void deleteResultRecord(java.io.File directory) {} }
class PreviewParent { public void postMobileMessage(String message) {} }
class PreviewEditor extends PreviewParent {
  java.io.File directory;
  static class PresentationCells {
    boolean onNativeMessage(byte[] message) { return false; }
    void installButton() {}
  }
  PresentationCells presentationCells;
  final String sessionId = "preview";
  boolean previewOnly=true, previewRequested, previewCancelled, previewLoadFailed, ready;
  boolean finishing, previewResultSet;
  Intent result;
  int exports, closes, resultCode;
  boolean isCellEditorReady() { return ready; }
  boolean isFinishing() { return finishing; }
  boolean isDestroyed() { return false; }
  void setResult(int code, Intent value) { resultCode=code; result=value; }
  void finish() { finishing=true; }
  void requestCancel() { cancelPreview(); }
  void receiveResult(int code, Intent value) { deliverPreviewResult(code,value); }
  void finishWithProgress() { closes++; if (ready) exports++; }
  void runOnUiThread(Runnable action) { action.run(); }
__PREVIEW_CALLBACKS__
}
'''.replace("__METHODS__", bodies).replace("__READY_CASE__", ready_case).replace("__PREVIEW_CALLBACKS__", preview_callbacks)
        java_home = os.environ.get("JAVA_HOME")
        javac = str(Path(java_home) / "bin/javac.exe") if java_home and os.name == "nt" else shutil.which("javac")
        java = str(Path(java_home) / "bin/java.exe") if java_home and os.name == "nt" else shutil.which("java")
        self.assertTrue(javac and java, "A JDK is required for the source-method lifecycle harness")
        with tempfile.TemporaryDirectory(prefix="office-lifecycle-") as folder:
            path = Path(folder)
            (path / "Harness.java").write_text(harness, encoding="utf-8")
            (path / "android/content").mkdir(parents=True)
            (path / "android/app").mkdir(parents=True)
            (path / "android/content/Intent.java").write_text('package android.content; public class Intent { final java.util.Map<String,Object> values=new java.util.HashMap<>(); public Intent putExtra(String key,String value) { values.put(key,value); return this; } public Intent putExtra(String key,boolean value) { values.put(key,value); return this; } public String getStringExtra(String key) { return (String)values.get(key); } public boolean getBooleanExtra(String key,boolean fallback) { return values.containsKey(key)?(Boolean)values.get(key):fallback; } }')
            (path / "android/app/Activity.java").write_text('package android.app; public class Activity { public static final int RESULT_CANCELED=0, RESULT_OK=-1; }')
            health = Path(__file__).parent / "src/main/java/io/github/canele452/personalinkvault/office/OfficeEngineHealth.java"
            bridge = path / "OfficeEngineBridge.java"
            declarations = '\n'.join('public ' + line.strip() for line in re.findall(r'^    static final String PREVIEW_.*;$', health.with_name('OfficeEngineBridge.java').read_text(encoding='utf-8'), re.MULTILINE))
            bridge.write_text('package io.github.canele452.personalinkvault.office;\npublic class OfficeEngineBridge {\n' + declarations + '\n}\n', encoding='utf-8')
            compiled = subprocess.run([javac, "-encoding", "UTF-8", "-d", folder, str(path / "Harness.java"), str(path / "android/content/Intent.java"), str(path / "android/app/Activity.java"), str(health), str(bridge)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            result = subprocess.run([java, "-cp", folder, "Harness"], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("scenarios passed", result.stdout)
            watchdog = subprocess.run([java, "-cp", folder, "Harness", "watchdog"], capture_output=True, text=True, timeout=10)
            self.assertEqual(watchdog.returncode, 0, watchdog.stderr)
            self.assertIn("watchdog scenarios passed", watchdog.stdout)
            queued = subprocess.run([java, "-cp", folder, "Harness", "queued-close"], capture_output=True, text=True, timeout=10)
            self.assertEqual(queued.returncode, 0, queued.stderr)
            self.assertIn("queued-close scenarios passed", queued.stdout)
            preview = subprocess.run([java, "-cp", folder, "Harness", "preview"], capture_output=True, text=True, timeout=10)
            self.assertEqual(preview.returncode, 0, preview.stderr)
            self.assertIn("native preview readiness scenarios passed", preview.stdout)
            preview_close = subprocess.run([java, "-cp", folder, "Harness", "preview-close"], capture_output=True, text=True, timeout=10)
            self.assertEqual(preview_close.returncode, 0, preview_close.stderr)
            self.assertIn("preview close watchdog scenarios passed", preview_close.stdout)


if __name__ == "__main__":
    unittest.main()
