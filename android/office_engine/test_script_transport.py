"""Run generated script transport and autosave methods with deterministic queues.

The harness uses product Java method bodies and small lifecycle/socket stubs.
It does not run Android, JNI, a document engine, or JavaScript.
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
REQUIRED = (
    "protected boolean isEmbeddedDocumentBusy()",
    "protected boolean onEmbeddedNativeMessage(byte[] message)",
    "protected final boolean sendEmbeddedScript(String requestId, String script)",
    "protected final void completeEmbeddedScript()",
    "private void queueEmbeddedAutoSave()",
)

HARNESS = r'''
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;
import java.nio.*;
import java.nio.charset.*;

class Intent {
  Intent() {}
  Intent(Intent ignored) {}
  Intent setClass(Object activity, Class<?> target) { return this; }
}
class LOActivity {}
class Parent {
  protected void onPause() { TransportHarness.events.add("pause-super"); }
  protected void onNewIntent(Intent intent) { TransportHarness.events.add("intent-super"); }
}
public class TransportHarness extends Parent {
  static final List<String> events = new ArrayList<>();
  static final Handler fifo = new Handler(false);
  static boolean runningNative;
  static class Handler {
    final boolean ui;
    final ArrayDeque<Runnable> jobs = new ArrayDeque<>();
    boolean accepts = true;
    Handler(boolean ui) { this.ui = ui; }
    boolean post(Runnable task) { if (!accepts) return false; jobs.add(task); return true; }
    void drain() {
      while (!jobs.isEmpty()) {
        runningNative = !ui;
        try { jobs.remove().run(); } finally { runningNative = false; }
      }
    }
  }
  static class Progress { void indeterminate(int value) {} void dismiss() {} }
  static class R { static class string { static final int exiting = 1; } }
  static class Log { static void i(String tag, String value) {} static void d(String tag, String value) {} }
  static class WebView { void loadUrl(String value) { events.add("webview"); } }
  static class Socket {
    final List<byte[]> frames = new ArrayList<>();
    void queueSend(byte[] message, Runnable delivered) throws InterruptedException {
      frames.add(message);
      delivered.run();
    }
  }
  final String TAG = "fixture";
  final Handler mainHandler = new Handler(true);
  Handler nativeHandler = fifo;
  final AtomicBoolean pivNativeClosed = new AtomicBoolean();
  boolean documentLoaded = true, pivNativeOpened = true;
  boolean pivDestroyed, destroyed, finishing, pivClosing, preview;
  boolean watching;
  int watches, cancellations;
  final Progress mProgressDialog = new Progress();
  Socket mMobileSocket = new Socket();
  WebView mWebView = new WebView();
  Object mCurrentFullScreenView;
  boolean mSlideShowActive, mMobileWizardVisible, mIsEditModeActive;
  final List<String> sent = new ArrayList<>();
  Runnable nativeReply;
  boolean isDestroyed() { return destroyed; }
  boolean isFinishing() { return finishing; }
  boolean isEmbeddedPreviewOnly() { return preview; }
  Handler getMainHandler() { return mainHandler; }
  void runOnUiThread(Runnable action) { mainHandler.post(action); }
  void watchEmbeddedNativeOperation() { watches++; watching = true; }
  void cancelEmbeddedNativeWatchdog() {
    require(!runningNative, "watchdog cancellation must run on the UI queue");
    cancellations++;
    watching = false;
  }
  void failEmbeddedNativeSession() { events.add("failed"); }
  void postMobileMessageNative(String message) {
    require(runningNative, "script and autosave must run on the shared native FIFO");
    sent.add(message);
    events.add(message.startsWith("executescript ") ? "script" : message.startsWith("save ") ? "save" : message);
    if (nativeReply != null) nativeReply.run();
  }
  void queueEmbeddedNativeClose() { nativeHandler.post(this::closeEmbeddedNativeDocument); }
  void closeEmbeddedNativeDocument() {
    require(runningNative, "close must retain native FIFO ordering");
    events.add("close");
    pivNativeClosed.set(true);
    documentLoaded = false;
  }
  boolean beforeEmbeddedDocumentClose() { events.add("commit"); return true; }
  void destroyEmbeddedWebView() { mWebView = null; }
  void finish() { finishing = true; events.add("finish"); }
  void startActivity(Intent intent) { events.add("start"); }
  void hideFullScreenView() { events.add("fullscreen"); }
  void callFakeWebsocketOnMessage(String message) { events.add(message); }
  __METHODS__
  void autosaveNow() { queueEmbeddedAutoSave(); }

  static final class Editor extends TransportHarness {
    boolean busy;
    int hookCalls, ownReplies;
    boolean busyAtReply;
    @Override protected boolean isEmbeddedDocumentBusy() { return busy; }
    @Override protected boolean onEmbeddedNativeMessage(byte[] message) {
      hookCalls++;
      if (!Arrays.equals(message, "owned".getBytes(StandardCharsets.UTF_8))) return false;
      busyAtReply = busy;
      busy = false;
      ownReplies++;
      completeEmbeddedScript();
      return true;
    }
    boolean defaultBusy() { return super.isEmbeddedDocumentBusy(); }
    boolean defaultMessage(byte[] message) { return super.onEmbeddedNativeMessage(message); }
  }
  static void require(boolean condition, String message) {
    if (!condition) throw new AssertionError(message + "; events=" + events);
  }
  static void reset() { events.clear(); fifo.jobs.clear(); fifo.accepts = true; }
  static void state(Editor h, String name) {
    switch (name) {
      case "unloaded": h.documentLoaded = false; break;
      case "unopened": h.pivNativeOpened = false; break;
      case "preview": h.preview = true; break;
      case "destroyed": h.pivDestroyed = true; break;
      case "platform-destroyed": h.destroyed = true; break;
      case "closed": h.pivNativeClosed.set(true); break;
      case "closing": h.pivClosing = true; break;
      case "restart": io.github.canele452.personalinkvault.office.OfficeEngineHealth.restart = true; break;
      default: throw new AssertionError(name);
    }
  }
  static List<String> guards() {
    return List.of("unloaded", "unopened", "preview", "destroyed", "platform-destroyed", "closed", "closing", "restart");
  }
  static void send() {
    reset();
    Editor h = new Editor();
    h.busy = true;
    fifo.post(() -> events.add("before"));
    require(h.sendEmbeddedScript("pivcell-fixture-1", "return '\ud55c\uae00\ud83d\ude00';"), "ready owned request is accepted even though its child is busy");
    fifo.post(() -> events.add("after"));
    require(h.sent.isEmpty() && h.watching, "enqueue starts watchdog without synchronously entering native code");
    fifo.drain();
    require(events.equals(List.of("before", "script", "after")), "script follows the shared FIFO");
    require(h.sent.equals(List.of("executescript pivcell-fixture-1 1 piv-presentation-cells.js\nreturn '\ud55c\uae00\ud83d\ude00';")), "script uses the fixed filename and exact UTF-8-safe source");
    require(h.watching, "successful send watches until its response completes");
    fifo.post(h::completeEmbeddedScript);
    fifo.drain();
    require(h.watching, "completion on native callback defers cancellation to UI");
    h.mainHandler.drain();
    require(!h.watching && h.cancellations > 0, "completion cancels the watchdog on UI");

    reset();
    Editor rejected = new Editor();
    fifo.accepts = false;
    require(!rejected.sendEmbeddedScript("pivcell-fixture-2", "return 1;"), "rejected native queue returns false");
    rejected.mainHandler.drain();
    require(!rejected.watching && rejected.sent.isEmpty(), "rejected enqueue clears its watchdog and never runs native");
  }
  static void bounds() {
    for (String invalid : new String[]{null, "", "a".repeat(97), "space id", "line\nid", "tab\tid", "a/b", "a'b", "\ud55c\uae00", "fullwidth\uff41", "a\u0000b"}) {
      reset();
      Editor h = new Editor();
      require(!h.sendEmbeddedScript(invalid, "return 1;"), "unsafe request ID rejected");
      require(fifo.jobs.isEmpty() && h.sent.isEmpty() && !h.watching, "invalid ID has no native or watchdog side effects");
    }
    for (String invalid : new String[]{null, "x".repeat(524289), "\uac00".repeat(174762) + "aaa", "\ud800", "\udc00", "valid\ud800tail"}) {
      reset();
      Editor h = new Editor();
      require(!h.sendEmbeddedScript("pivcell-fixture-3", invalid), "oversized or malformed UTF-16 cannot be encoded as a script");
      require(fifo.jobs.isEmpty() && h.sent.isEmpty() && !h.watching, "invalid source is rejected before enqueue or watchdog");
    }
    for (String valid : new String[]{"x".repeat(524288), "\uac00".repeat(174762) + "aa", "return '\ud83d\ude00';"}) {
      reset();
      Editor h = new Editor();
      require(h.sendEmbeddedScript("a".repeat(96), valid), "exact UTF-8 byte limit and valid surrogate pair are accepted");
      fifo.drain();
      require(h.sent.size() == 1 && h.sent.get(0).endsWith("\n" + valid), "accepted source reaches native intact exactly once");
    }
  }
  static void initialGuards() {
    for (String guard : guards()) {
      reset();
      Editor h = new Editor();
      state(h, guard);
      require(!h.sendEmbeddedScript("pivcell-fixture-4", "return 1;"), "send rejects initial lifecycle state " + guard);
      require(fifo.jobs.isEmpty() && h.sent.isEmpty() && !h.watching, "blocked send does not enqueue or start a watchdog: " + guard);
    }
  }
  static void queuedGuards() {
    for (String guard : guards()) {
      reset();
      Editor h = new Editor();
      h.busy = true;
      require(h.sendEmbeddedScript("pivcell-fixture-5", "return 1;"), "live request first enqueues");
      state(h, guard);
      fifo.drain();
      h.mainHandler.drain();
      require(h.sent.isEmpty(), "queued script rechecks lifecycle before native entry: " + guard);
    }
  }
  static void noHandler() {
    reset();
    Editor h = new Editor();
    h.nativeHandler = null;
    require(!h.sendEmbeddedScript("pivcell-fixture-6", "return 1;"), "uninitialized native queue rejects script");
    h.autosaveNow();
    require(fifo.jobs.isEmpty() && !h.watching, "missing handler does not start transport or autosave");
  }
  static void raw() {
    reset();
    Editor h = new Editor();
    require(!h.defaultBusy() && !h.defaultMessage(new byte[]{1, 2}), "default parent hooks are nonintercepting");
    h.busy = true;
    h.mMobileSocket = null;
    h.nativeReply = () -> h.rawCallFakeWebsocketOnMessage("owned".getBytes(StandardCharsets.UTF_8));
    require(h.sendEmbeddedScript("pivcell-fixture-7", "return 1;"), "child registers ownership before native send");
    fifo.drain();
    require(h.ownReplies == 1 && h.busyAtReply && !h.busy, "reentrant native response reaches child ownership before any socket-null return");
    h.mainHandler.drain();
    require(!h.watching, "owned response completes its watch");

    byte[] foreign = "foreign\u0000\ud55c\uae00".getBytes(StandardCharsets.UTF_8);
    h.mMobileSocket = new Socket();
    h.nativeReply = null;
    h.rawCallFakeWebsocketOnMessage(foreign);
    require(h.mMobileSocket.frames.size() == 1 && h.mMobileSocket.frames.get(0) == foreign, "foreign frame bytes pass through unchanged");
    h.mainHandler.drain();
    for (String guard : List.of("destroyed", "closed")) {
      Editor late = new Editor();
      state(late, guard);
      late.rawCallFakeWebsocketOnMessage("owned".getBytes(StandardCharsets.UTF_8));
      late.rawCallFakeWebsocketOnMessage(foreign);
      require(late.hookCalls == 0 && late.mMobileSocket.frames.isEmpty(), "late native frame is discarded before hooks or socket delivery: " + guard);
    }
  }
  static void autosave() {
    reset();
    Editor h = new Editor();
    fifo.post(() -> events.add("before"));
    h.onPause();
    fifo.post(() -> events.add("after"));
    require(events.equals(List.of("pause-super")) && h.sent.isEmpty(), "pause calls super and queues its autosave without native entry");
    fifo.drain();
    require(events.equals(List.of("pause-super", "before", "save", "after")), "pause autosave uses the shared native FIFO");
    require(h.sent.equals(List.of("save dontTerminateEdit=1 dontSaveIfUnmodified=1")), "autosave keeps the established native save command");
    reset();
    Editor busy = new Editor();
    busy.busy = true;
    busy.autosaveNow();
    busy.onPause();
    require(fifo.jobs.isEmpty() && busy.sent.isEmpty(), "owned script prevents autosave before enqueue");
    reset();
    Editor becameBusy = new Editor();
    becameBusy.autosaveNow();
    becameBusy.busy = true;
    fifo.drain();
    require(becameBusy.sent.isEmpty(), "autosave rechecks script ownership after enqueue");
  }
  static void autosaveGuards(boolean queued) {
    for (String guard : guards()) {
      reset();
      Editor h = new Editor();
      if (queued) h.autosaveNow();
      state(h, guard);
      if (!queued) {
        h.autosaveNow();
        require(fifo.jobs.isEmpty(), "blocked autosave leaves no native queue work: " + guard);
      }
      fifo.drain();
      require(h.sent.isEmpty(), "autosave checks lifecycle " + (queued ? "inside FIFO: " : "before enqueue: ") + guard);
    }
  }
  static void closeAndIntent() {
    reset();
    Editor busy = new Editor();
    busy.busy = true;
    busy.mCurrentFullScreenView = new Object();
    busy.onNewIntent(new Intent());
    busy.finishWithProgress();
    busy.handleEmbeddedBack();
    require(events.isEmpty() && fifo.jobs.isEmpty() && !busy.pivClosing && !busy.finishing, "script ownership blocks intent replacement, close, and back before side effects");
    busy.busy = false;
    busy.onNewIntent(new Intent());
    require(events.equals(List.of("intent-super", "finish", "start")) && busy.sent.isEmpty(), "normal intent schedules native work and starts the replacement Activity");
    fifo.drain();
    require(events.equals(List.of("intent-super", "finish", "start", "save", "close")), "normal intent saves its document before close in the same native FIFO");
    require(busy.sent.equals(List.of("save dontTerminateEdit=1 dontSaveIfUnmodified=1")), "intent autosave runs exactly once");
  }
  public static void main(String[] args) {
    switch (args[0]) {
      case "send": send(); break;
      case "bounds": bounds(); break;
      case "initial": initialGuards(); break;
      case "queued": queuedGuards(); break;
      case "no-handler": noHandler(); break;
      case "raw": raw(); break;
      case "autosave": autosave(); break;
      case "autosave-initial": autosaveGuards(false); break;
      case "autosave-queued": autosaveGuards(true); break;
      case "close-intent": closeAndIntent(); break;
      default: throw new AssertionError("unknown scenario");
    }
    System.out.println(args[0] + " scenarios passed");
  }
}
'''

HEALTH = r'''package io.github.canele452.personalinkvault.office;
public final class OfficeEngineHealth {
  public static boolean restart;
  public static boolean requiresRestart() { return restart; }
}'''


class ScriptTransportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = ROOT / "cache/source/android/lib/src/main/java/org/libreoffice/androidlib/LOActivity.java"
        cls.generated = patch_activity(source.read_text(encoding="utf-8"))

    def run_harness(self, scenario):
        for signature in REQUIRED:
            self.assertTrue(signature in self.generated, "generated Office script transport is not implemented: " + signature)
        signatures = REQUIRED + (
            "protected void onPause()",
            "protected void onNewIntent(Intent intent)",
            "protected void finishWithProgress()",
            "protected void handleEmbeddedBack()",
        )
        bodies = "\n".join(method(self.generated, signature) for signature in signatures)
        raw_start = self.generated.index("void rawCallFakeWebsocketOnMessage(final byte[] message)")
        progress_start = self.generated.index("// update progress bar when loading", raw_start)
        # Execute the real dispatch prefix; unrelated progress JSON parsing is outside this harness.
        raw = self.generated[raw_start:progress_start] + "\n}"
        self.assertIn("onEmbeddedNativeMessage(message)", raw, "raw responses must reach the new hook before socket delivery")
        harness = HARNESS.replace("__METHODS__", bodies + "\n" + raw)
        java_home = os.environ.get("JAVA_HOME")
        suffix = ".exe" if os.name == "nt" else ""
        javac = str(Path(java_home) / f"bin/javac{suffix}") if java_home else shutil.which("javac")
        java = str(Path(java_home) / f"bin/java{suffix}") if java_home else shutil.which("java")
        self.assertTrue(javac and java, "A JDK is required; this is not an Android/JNI test")
        with tempfile.TemporaryDirectory(prefix="office-script-transport-") as folder:
            harness_path = Path(folder) / "TransportHarness.java"
            harness_path.write_text(harness, encoding="utf-8")
            health_path = Path(folder) / "OfficeEngineHealth.java"
            health_path.write_text(HEALTH, encoding="utf-8")
            compiled = subprocess.run([javac, "-encoding", "UTF-8", "-d", folder, str(harness_path), str(health_path)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([java, "-cp", folder, "TransportHarness", scenario], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("scenarios passed", result.stdout)
            print(result.stdout.strip())

    def test_script_wire_uses_shared_fifo_and_cancels_watchdog_on_ui(self):
        self.run_harness("send")

    def test_script_ids_and_utf8_byte_bounds_reject_before_enqueue(self):
        self.run_harness("bounds")

    def test_script_rejects_every_initial_lifecycle_and_health_gate(self):
        self.run_harness("initial")

    def test_queued_script_rechecks_lifecycle_without_rejecting_its_own_busy_state(self):
        self.run_harness("queued")

    def test_missing_native_handler_rejects_transport_and_autosave(self):
        self.run_harness("no-handler")

    def test_raw_response_hook_handles_owned_reentrant_reply_and_preserves_foreign_bytes(self):
        self.run_harness("raw")

    def test_pause_autosave_uses_fifo_and_rechecks_script_ownership(self):
        self.run_harness("autosave")

    def test_autosave_rejects_initial_lifecycle_and_health_gates(self):
        self.run_harness("autosave-initial")

    def test_queued_autosave_rechecks_lifecycle_and_health_gates(self):
        self.run_harness("autosave-queued")

    def test_busy_blocks_close_back_and_intent_then_normal_intent_saves_before_close(self):
        self.run_harness("close-intent")


if __name__ == "__main__":
    unittest.main()
