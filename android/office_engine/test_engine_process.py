"""Host checks for the Office engine running in its own Android process (":office").

The Java scenarios run the real OfficeSessionJournal, OfficeEngineBridge and OfficePreviewOutputs
sources with the JDK stubs shared with test_session_journal. The engine process is modelled only by
the main-process calls it causes (attach through the link provider, Binder death notice); no
Android runtime, Binder or Collabora code is executed here.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

import test_session_journal as recovery


MODULE = Path(__file__).parent
JAVA = recovery.JAVA
MANIFEST = MODULE / "src/main/AndroidManifest.xml"
REOPEN_REQUEST = 19475

HARNESS = r'''
package io.github.canele452.personalinkvault.office;

import android.app.Activity;
import android.content.Intent;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

public final class EngineProcessHarness {
  static final String ID = "01234567-89ab-4cde-8fab-0123456789ab";
  static final String SECOND = "01234567-89ab-4cde-8fab-0123456789ac";
  static final String THIRD = "01234567-89ab-4cde-8fab-0123456789ad";

  static void require(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }

  static final class Done implements OfficeEngineBridge.Completion {
    final CountDownLatch latch = new CountDownLatch(1);
    volatile Map<String, Object> result;
    volatile String code;
    public void success(Map<String, Object> value) { result = value; latch.countDown(); }
    public void error(String errorCode, String message) { code = errorCode; latch.countDown(); }
    void await(String route) throws Exception {
      require(latch.await(10, TimeUnit.SECONDS), route + " must complete");
    }
  }

  static void waitLaunches(Activity activity, int count) throws Exception {
    long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(10);
    while (activity.launches < count && System.nanoTime() < until) Thread.sleep(5);
    require(activity.launches == count, "expected " + count + " launches, got " + activity.launches);
  }

  static File document(File folder, String name, String format) throws Exception {
    File file = new File(folder, name);
    var helper = Class.forName("RecoveryHarness").getDeclaredMethod("office", File.class, String.class, String.class);
    helper.setAccessible(true);
    helper.invoke(null, file, format, "engine process fixture");
    return file;
  }

  static File home(File root, String name) throws Exception {
    File folder = new File(root, name);
    Files.createDirectories(folder.toPath());
    return folder;
  }

  static File writePdf(Intent launch) throws Exception {
    File pdf = new File(launch.getStringExtra("piv.sessionDirectory"), "preview.pdf");
    Files.write(pdf.toPath(), "%PDF-1.7 engine fixture".getBytes(StandardCharsets.US_ASCII));
    return pdf;
  }

  static Intent pdfResult(Intent launch, File pdf, String sessionId) throws Exception {
    return new Intent().putExtra("pdfPath", pdf.getPath())
        .putExtra("sourceSha256", launch.getStringExtra("piv.inputSourceSha256"))
        .putExtra("pdfSha256", OfficeNativeObservation.sourceSha256(pdf))
        .putExtra("pdfPageCount", 2).putExtra("sessionId", sessionId)
        .putExtra(OfficeEngineBridge.PREVIEW_PDF_READY_EXTRA, true);
  }

  static void attach() throws Exception {
    Object launcher = new Object();
    require(OfficeSessionJournal.reserveEditor(ID, launcher, "launch-1"), "a launch reserves the editor");
    require(OfficeSessionJournal.attachEditor(ID, "launch-other", true, 101) == null, "a preview from another launch is rejected");
    require(OfficeSessionJournal.attachEditor(SECOND, "launch-1", true, 101) == null, "a preview for another session is rejected");
    Object attached = OfficeSessionJournal.attachEditor(ID, "launch-1", true, 101);
    require(attached != null, "a preview from its own launch attaches");
    require(OfficeSessionJournal.attachEditor(ID, "launch-1", true, 101) == attached,
        "an Activity recreated in the same engine process keeps its launch");
    require(OfficeSessionJournal.attachEditor(ID, "launch-1", true, 202) == null, "another process cannot take an attached launch");
    OfficeSessionJournal.releaseEditor(launcher);
    require(OfficeSessionJournal.hasLiveEditor(), "a result does not release a launch whose engine process still lives");
    require(!OfficeSessionJournal.hasClosingEditor(), "no engine is closing before its result");
    require(!OfficeSessionJournal.markEditorResult("launch-other"), "a result marks only its own launch");
    require(OfficeSessionJournal.markEditorResult("launch-1") && OfficeSessionJournal.hasClosingEditor(),
        "an attached launch is closing after its result");
    AtomicBoolean cleaned = new AtomicBoolean();
    require(OfficeSessionJournal.deferUntilEditorReleased(ID, () -> cleaned.set(true)), "cleanup waits for the engine process");
    AtomicBoolean woke = new AtomicBoolean();
    Thread waiter = new Thread(() -> {
      try { woke.set(OfficeSessionJournal.awaitEditorRelease(ID, 5000)); } catch (InterruptedException ignored) {}
    });
    waiter.start();
    Thread.sleep(100);
    require(waiter.isAlive(), "waiters block while the engine process lives");
    OfficeSessionJournal.editorProcessDied(attached);
    waiter.join(2000);
    require(woke.get() && cleaned.get() && !OfficeSessionJournal.hasLiveEditor(),
        "engine death releases the launch, wakes waiters and runs the deferred cleanup");
    OfficeSessionJournal.editorProcessDied(attached);
    require(!OfficeSessionJournal.hasLiveEditor(), "a repeated death notice is harmless");
    require(OfficeSessionJournal.wasAttached("launch-1") && !OfficeSessionJournal.markEditorResult("launch-1"),
        "a death notice before the result still leaves the launch known as attached, without a live engine");

    require(OfficeSessionJournal.attachEditor(ID, "launch-1", true, 303) == null,
        "an old preview screen restored after an app restart is rejected");
    Object recovered = OfficeSessionJournal.attachEditor(ID, "launch-2", false, 303);
    require(recovered != null && OfficeSessionJournal.hasLiveEditor(), "edit recovery attaches without a reservation");
    require(!OfficeSessionJournal.reserveEditor(SECOND, launcher, "launch-3"), "only one engine runs at a time");
    OfficeSessionJournal.editorProcessDied(recovered);

    require(OfficeSessionJournal.reserveEditor(ID, launcher, "launch-4"), "a later launch reserves again");
    OfficeSessionJournal.releaseEditor(launcher);
    require(!OfficeSessionJournal.hasLiveEditor(), "a launch that never attached is released by its result");
    require(!OfficeSessionJournal.wasAttached("launch-4"), "a launch that never attached is not remembered as attached");
    System.out.println("engine attach scenarios passed");
  }

  static void stop() throws Exception {
    List<Integer> stopped = Collections.synchronizedList(new ArrayList<>());
    OfficeSessionJournal.setProcessStopper(stopped::add);
    Object launcher = new Object();
    require(OfficeSessionJournal.reserveEditor(ID, launcher, "launch-5"), "reserve");
    require(!OfficeSessionJournal.stopEngine("launch-5"), "a launch that has not attached has no process to stop");
    Object attached = OfficeSessionJournal.attachEditor(ID, "launch-5", true, 404);
    require("launch-5".equals(OfficeSessionJournal.attachedLaunch(ID)), "the attached launch is known by session");
    require(OfficeSessionJournal.closingLaunch() == null, "a launch without a result is not closing");
    require(!OfficeSessionJournal.stopEngine("launch-other") && !OfficeSessionJournal.stopEngine(null),
        "stop targets only its own launch");
    require(OfficeSessionJournal.stopEngine("launch-5") && stopped.equals(List.of(404)), "stop uses the PID recorded at attach");
    OfficeSessionJournal.editorProcessDied(attached);
    require(!OfficeSessionJournal.stopEngine("launch-5") && stopped.size() == 1, "a dead launch is never stopped again");
    System.out.println("engine stop scenarios passed");
  }

  static void rescuePreview(File root) throws Exception {
    List<Integer> stopped = Collections.synchronizedList(new ArrayList<>());
    OfficeSessionJournal.setProcessStopper(stopped::add);
    for (String variant : List.of("death-first", "result-first", "wrong-source", "wrong-pdf", "no-record", "cancelled")) {
      File home = home(root, "preview-" + variant);
      File source = document(home, "slides.pptx", "pptx");
      Activity activity = new Activity(home);
      OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
      try {
        Done done = new Done();
        bridge.preview(source.getPath(), ID, done);
        waitLaunches(activity, 1);
        Intent launch = activity.lastIntent;
        String launchId = launch.getStringExtra("piv.launchId");
        require(launchId != null && !launchId.isEmpty(), "each launch carries its own id");
        Object engine = OfficeSessionJournal.attachEditor(ID, launchId, true, 505);
        require(engine != null, "the engine process attaches to its launch");
        File directory = new File(launch.getStringExtra("piv.sessionDirectory"));
        File pdf = writePdf(launch);
        String sourceHash = launch.getStringExtra("piv.inputSourceSha256");
        if (!variant.equals("no-record")) {
          OfficePreviewOutputs.writeResultRecord(directory, ID,
              variant.equals("wrong-source") ? "0".repeat(64) : sourceHash,
              variant.equals("wrong-pdf") ? "1".repeat(64) : OfficeNativeObservation.sourceSha256(pdf), 3);
        }
        if (variant.equals("cancelled")) {
          bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED,
              new Intent().putExtra("sessionId", ID).putExtra(OfficeEngineBridge.PREVIEW_CANCELLED_EXTRA, true));
          OfficeSessionJournal.editorProcessDied(engine);
        } else if (variant.equals("result-first")) {
          bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED, null);
          Thread.sleep(200);
          require(done.latch.getCount() == 1, "a result without data waits until the engine process is gone");
          OfficeSessionJournal.editorProcessDied(engine);
        } else {
          OfficeSessionJournal.editorProcessDied(engine);
          bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED, null);
        }
        done.await(variant);
        switch (variant) {
          case "death-first", "result-first" -> {
            require(done.result != null && "previewed".equals(done.result.get("status")), variant + " rescues the verified PDF, got " + done.code);
            require(pdf.getPath().equals(done.result.get("pdfPath")) && Integer.valueOf(3).equals(done.result.get("pdfPageCount"))
                && sourceHash.equals(done.result.get("sourceSha256")), variant + " returns the recorded PDF");
          }
          case "cancelled" -> require(done.result != null && "cancelled".equals(done.result.get("status")),
              "a cancel result ignores any written record");
          default -> require("office_preview_interrupted".equals(done.code), variant + " must not be accepted, got " + done.code);
        }
        require(!OfficeSessionJournal.hasLiveEditor(), variant + " leaves no live editor");
      } finally { bridge.dispose(); }
    }
    require(stopped.isEmpty(), "engines that exit by themselves are never stopped");
    System.out.println("preview rescue scenarios passed");
  }

  static void rescueEdit(File root) throws Exception {
    for (String variant : List.of("source-ready", "working")) {
      File home = home(root, "edit-" + variant);
      File source = document(home, "notes.docx", "docx");
      Activity activity = new Activity(home);
      OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
      try {
        Done done = new Done();
        bridge.edit(source.getPath(), ID, done);
        waitLaunches(activity, 1);
        Intent launch = activity.lastIntent;
        Object engine = OfficeSessionJournal.attachEditor(ID, launch.getStringExtra("piv.launchId"), false, 606);
        require(engine != null, "the edit engine attaches");
        if (variant.equals("source-ready")) {
          File session = new File(launch.getStringExtra("piv.workingPath")).getParentFile();
          document(session, "edited.docx", "docx");
          new OfficeSessionJournal(new File(home, "office-sessions"), OfficeEngineBridge.VERSION)
              .recordSourceReady(ID, launch.getStringExtra("piv.inputSourceSha256"));
        }
        OfficeSessionJournal.editorProcessDied(engine);
        bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED, null);
        if (variant.equals("source-ready")) {
          waitLaunches(activity, 2);
          Intent reopen = activity.lastIntent;
          require(reopen.getBooleanExtra("piv.reopenedSource", false), "a saved source continues to the PDF step");
          require(done.latch.getCount() == 1, "a saved edit is not reported as cancelled");
          bridge.handleActivityResult(%REOPEN_REQUEST%, Activity.RESULT_CANCELED, new Intent()
              .putExtra("sessionId", reopen.getStringExtra("piv.sessionId"))
              .putExtra(OfficeEngineBridge.PREVIEW_CANCELLED_EXTRA, true));
          done.await("reopen cancel");
          require(done.code != null, "a cancelled reopen ends with an error that keeps the saved source");
        } else {
          done.await(variant);
          require("office_interrupted".equals(done.code),
              "an unsaved edit whose engine died is an interruption, not a cancel: " + done.code + " " + done.result);
        }
        require(!OfficeSessionJournal.hasLiveEditor(), variant + " leaves no live editor");
      } finally { bridge.dispose(); }
    }
    System.out.println("edit rescue scenarios passed");
  }

  static void closing(File root) throws Exception {
    AtomicReference<Object> killable = new AtomicReference<>();
    List<Integer> stopped = Collections.synchronizedList(new ArrayList<>());
    OfficeSessionJournal.setProcessStopper(pid -> {
      stopped.add(pid);
      Object engine = killable.get();
      if (engine != null) OfficeSessionJournal.editorProcessDied(engine);
    });
    File home = home(root, "closing");
    File first = document(home, "first.pptx", "pptx");
    File second = document(home, "second.pptx", "pptx");
    File third = document(home, "third.pptx", "pptx");
    Activity activity = new Activity(home);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    try {
      Done one = new Done();
      bridge.preview(first.getPath(), ID, one);
      waitLaunches(activity, 1);
      Intent launch = activity.lastIntent;
      Object engine = OfficeSessionJournal.attachEditor(ID, launch.getStringExtra("piv.launchId"), true, 707);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_OK, pdfResult(launch, writePdf(launch), ID));
      one.await("first conversion");
      require(one.result != null && "previewed".equals(one.result.get("status")), "the PDF returns before the engine exits");
      require(OfficeSessionJournal.hasClosingEditor(), "the first engine is still closing");

      Done two = new Done();
      bridge.preview(second.getPath(), SECOND, two);
      Thread.sleep(300);
      require(activity.launches == 1 && two.latch.getCount() == 1, "the next conversion waits for the closing engine instead of failing busy");
      OfficeSessionJournal.editorProcessDied(engine);
      waitLaunches(activity, 2);
      require(SECOND.equals(activity.lastIntent.getStringExtra("piv.sessionId")), "the next conversion starts after the engine exits");
      require(stopped.isEmpty(), "an engine that exits by itself is never stopped");

      OfficeEngineBridge.engineExitGraceMillis = 300;
      Intent secondLaunch = activity.lastIntent;
      Object stuck = OfficeSessionJournal.attachEditor(SECOND, secondLaunch.getStringExtra("piv.launchId"), true, 808);
      killable.set(stuck);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_OK, pdfResult(secondLaunch, writePdf(secondLaunch), SECOND));
      two.await("second conversion");
      Done three = new Done();
      bridge.preview(third.getPath(), THIRD, three);
      waitLaunches(activity, 3);
      require(stopped.equals(List.of(808)), "an engine that never exits is stopped once by its recorded PID, got " + stopped);
      require(THIRD.equals(activity.lastIntent.getStringExtra("piv.sessionId")), "the third conversion starts after the stop");
      killable.set(null);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED,
          new Intent().putExtra("sessionId", THIRD).putExtra(OfficeEngineBridge.PREVIEW_CANCELLED_EXTRA, true));
      three.await("third cancel");
    } finally {
      OfficeEngineBridge.engineExitGraceMillis = 25000;
      bridge.dispose();
    }
    System.out.println("closing engine scenarios passed");
  }

  static void failure(File root) throws Exception {
    List<Integer> stopped = Collections.synchronizedList(new ArrayList<>());
    OfficeSessionJournal.setProcessStopper(stopped::add);
    File home = home(root, "failure");
    File source = document(home, "broken.pptx", "pptx");
    Activity activity = new Activity(home);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    try {
      OfficeEngineBridge.engineExitGraceMillis = 300;
      Done done = new Done();
      bridge.preview(source.getPath(), ID, done);
      waitLaunches(activity, 1);
      Object engine = OfficeSessionJournal.attachEditor(ID, activity.lastIntent.getStringExtra("piv.launchId"), true, 909);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED, new Intent()
          .putExtra("sessionId", ID).putExtra("errorCode", OfficeEngineHealth.ERROR_CODE)
          .putExtra("errorMessage", OfficeEngineHealth.RECOVERY_MESSAGE));
      require(stopped.isEmpty(), "a failed engine is not stopped at once: its native thread may still finish a save");
      done.await("engine failure");
      require(OfficeEngineHealth.ERROR_CODE.equals(done.code), "the engine failure reaches Flutter");
      long until = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
      while (stopped.isEmpty() && System.nanoTime() < until) Thread.sleep(10);
      require(stopped.equals(List.of(909)), "a failed engine that stays is stopped after the grace period, got " + stopped);
      OfficeSessionJournal.editorProcessDied(engine);
      require(!OfficeEngineHealth.requiresRestart(), "the main process never needs an app restart for an engine failure");
    } finally {
      OfficeEngineBridge.engineExitGraceMillis = 25000;
      bridge.dispose();
    }
    System.out.println("engine failure scenarios passed");
  }

  static void loadFailure(File root) throws Exception {
    File home = home(root, "load-failure");
    File source = document(home, "never.docx", "docx");
    File other = document(home, "other.docx", "docx");
    Activity activity = new Activity(home);
    OfficeEngineBridge bridge = new OfficeEngineBridge(activity);
    try {
      Done crashed = new Done();
      bridge.edit(source.getPath(), ID, crashed);
      waitLaunches(activity, 1);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED, null);
      crashed.await("engine crash before attach");
      require("office_engine_load_failed".equals(crashed.code),
          "an engine process that died before attaching is a failure, not a cancel: " + crashed.code + " " + crashed.result);
      require(!OfficeSessionJournal.hasLiveEditor(), "the failed launch is released");
      Done cancelled = new Done();
      bridge.edit(other.getPath(), SECOND, cancelled);
      waitLaunches(activity, 2);
      Object engine = OfficeSessionJournal.attachEditor(SECOND, activity.lastIntent.getStringExtra("piv.launchId"), false, 1111);
      bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED,
          new Intent().putExtra("sessionId", SECOND));
      cancelled.await("edit closed before its document loaded");
      require(cancelled.result != null && "cancelled".equals(cancelled.result.get("status")),
          "a close that carries data before the document loads is still a cancel: " + cancelled.code);
      OfficeSessionJournal.editorProcessDied(engine);
    } finally { bridge.dispose(); }
    System.out.println("engine load failure scenarios passed");
  }

  static void awaitLive() throws Exception {
    List<Integer> stopped = Collections.synchronizedList(new ArrayList<>());
    OfficeSessionJournal.setProcessStopper(stopped::add);
    var awaitClosed = OfficeEngineBridge.class.getDeclaredMethod("awaitClosed", String.class);
    awaitClosed.setAccessible(true);
    OfficeEngineBridge.engineExitGraceMillis = 200;
    try {
      Object launcher = new Object();
      require(OfficeSessionJournal.reserveEditor(ID, launcher, "launch-live"), "reserve");
      Object engine = OfficeSessionJournal.attachEditor(ID, "launch-live", true, 1212);
      try {
        awaitClosed.invoke(null, ID);
        throw new AssertionError("an engine that has not returned its result does not count as closed");
      } catch (java.lang.reflect.InvocationTargetException expected) {
        require(expected.getCause() instanceof java.io.IOException, "the wait reports a timeout");
      }
      require(stopped.isEmpty(), "a wait never stops an engine that has not returned its result");
      require(OfficeSessionJournal.markEditorResult("launch-live"), "the result marks the launch");
      OfficeSessionJournal.setProcessStopper(pid -> {
        stopped.add(pid);
        OfficeSessionJournal.editorProcessDied(engine);
      });
      awaitClosed.invoke(null, ID);
      require(stopped.equals(List.of(1212)), "a closing engine that stays is stopped by its recorded PID, got " + stopped);
    } finally { OfficeEngineBridge.engineExitGraceMillis = 25000; }
    System.out.println("live engine wait scenarios passed");
  }

  public static void main(String[] args) throws Exception {
    File root = Files.createTempDirectory("office-engine-process-").toFile();
    switch (args[0]) {
      case "attach" -> attach();
      case "stop" -> stop();
      case "rescue-preview" -> rescuePreview(root);
      case "rescue-edit" -> rescueEdit(root);
      case "closing" -> closing(root);
      case "failure" -> failure(root);
      case "load-failure" -> loadFailure(root);
      case "await-live" -> awaitLive();
      default -> throw new IllegalArgumentException(args[0]);
    }
    System.exit(0);
  }
}
'''.replace("%REOPEN_REQUEST%", str(REOPEN_REQUEST))


def method(text, signature):
    start = text.index(signature)
    body = text.index("{", start)
    level = 1
    end = body + 1
    while level:
        level += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


class EngineProcessScenarioTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        java_home = os.environ.get("JAVA_HOME")
        suffix = ".exe" if os.name == "nt" else ""
        cls.javac = str(Path(java_home) / f"bin/javac{suffix}") if java_home else shutil.which("javac")
        cls.java = str(Path(java_home) / f"bin/java{suffix}") if java_home else shutil.which("java")
        if not (cls.javac and cls.java):
            raise unittest.SkipTest("A JDK is required for the host engine-process scenarios")
        cls.folder = tempfile.TemporaryDirectory(prefix="office-engine-process-")
        root = Path(cls.folder.name)
        (root / "RecoveryHarness.java").write_text(recovery.HARNESS, encoding="utf-8")
        package = root / "io/github/canele452/personalinkvault/office"
        package.mkdir(parents=True)
        (package / "EngineProcessHarness.java").write_text(HARNESS, encoding="utf-8")
        classifier_source = (JAVA / "OfficeLegacyContainer.java").read_text(encoding="utf-8")
        classifier = root / "OfficeLegacyContainer.java"
        classifier.write_text(classifier_source
                              .replace("private static native int classifyNative(byte[] path);", recovery.CLASSIFIER_DOUBLE)
                              .replace('static { System.loadLibrary("ink_hwp_native"); }', ""), encoding="utf-8")
        stubs = []
        for name, content in recovery.STUBS.items():
            path = root / "stubs" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
            stubs.append(str(path))
        sources = [root / "RecoveryHarness.java", package / "EngineProcessHarness.java", classifier] + [
            JAVA / name for name in ("OfficeSessionJournal.java", "OfficeEngineBridge.java", "OfficeEngineHealth.java",
                                     "OfficePreviewOutputs.java", "OfficeNativeObservation.java")]
        compiled = subprocess.run([cls.javac, "-encoding", "UTF-8", "-d", str(root / "classes"),
                                   *map(str, sources), *stubs], capture_output=True, text=True, timeout=60)
        cls.compile_error = None if compiled.returncode == 0 else compiled.stdout + compiled.stderr

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def run_scenario(self, name):
        self.assertIsNone(self.compile_error, self.compile_error)
        result = subprocess.run([self.java, "-cp", str(Path(self.folder.name) / "classes"),
                                 "io.github.canele452.personalinkvault.office.EngineProcessHarness", name],
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        print(result.stdout.strip())

    def test_attach_follows_the_launch_and_engine_death_releases_it(self):
        self.run_scenario("attach")

    def test_stop_targets_only_the_recorded_engine_process(self):
        self.run_scenario("stop")

    def test_verified_pdf_is_rescued_only_after_the_engine_process_is_gone(self):
        self.run_scenario("rescue-preview")

    def test_saved_edit_survives_an_engine_that_died_before_its_result(self):
        self.run_scenario("rescue-edit")

    def test_next_conversion_waits_for_a_closing_engine_and_stops_a_stuck_one(self):
        self.run_scenario("closing")

    def test_engine_failure_restarts_only_the_engine_process(self):
        self.run_scenario("failure")

    def test_edit_engine_that_died_before_attaching_is_a_failure_not_a_cancel(self):
        self.run_scenario("load-failure")

    def test_wait_never_stops_an_engine_that_has_not_returned_its_result(self):
        self.run_scenario("await-live")


class EngineProcessSourceTests(unittest.TestCase):
    def read(self, name):
        return (JAVA / name).read_text(encoding="utf-8")

    def test_manifest_runs_only_the_office_activity_in_its_own_process(self):
        text = MANIFEST.read_text(encoding="utf-8")
        editor = re.search(r'<activity\s+android:name="io\.github\.canele452\.personalinkvault\.office\.OfficeEditorActivity"[^>]*/>', text, re.S)
        slideshow = re.search(r'<activity\s+android:name="org\.libreoffice\.androidlib\.SlideShowActivity"[^>]*/>', text, re.S)
        link = re.search(r'<provider\s+android:name="io\.github\.canele452\.personalinkvault\.office\.OfficeEngineLink"[^>]*/>', text, re.S)
        self.assertTrue(editor and slideshow and link, text)
        self.assertIn('android:process=":office"', editor.group(0))
        self.assertNotIn("android:process", slideshow.group(0))
        self.assertIn('android:authorities="${applicationId}.office-link"', link.group(0))
        self.assertIn('android:exported="false"', link.group(0))
        self.assertNotIn("android:process", link.group(0), "the link provider must live in the main process")

    def test_main_process_never_initializes_the_engine_class(self):
        bridge = self.read("OfficeEngineBridge.java")
        self.assertIn("Class.forName(OfficeEditorActivity.class.getName(), false, activity.getClassLoader())", bridge)
        self.assertNotIn("Class.forName(OfficeEditorActivity.class.getName(), true", bridge)
        self.assertIn('.putExtra("piv.launchId", launchId)', bridge)

    def test_engine_activity_attaches_before_it_opens_anything(self):
        editor = self.read("OfficeEditorActivity.java")
        on_create = method(editor, "public void onCreate(Bundle savedInstanceState)")
        order = [on_create.index(marker) for marker in (
            "OfficeEngineProcess.prepare();",
            "OfficeEngineProcess.attach(this, sessionId, launchId, previewOnly)",
            "OfficeSessionJournal.engineEditorOpened(sessionId, this)",
            "super.onCreate(")]
        self.assertEqual(order, sorted(order))
        self.assertNotIn("OfficeSessionJournal.editorOpened(", editor)
        self.assertLess(on_create.index("if (!previewOnly && alreadyExported == null)"),
                        on_create.index("super.onCreate(alreadyExported == null"),
                        "the editor's default result (a cancel with data) is set before the engine starts")
        self.assertIn("if (engineAttached) OfficeEngineProcess.stopAfterRelease(this)",
                      method(editor, "protected void onEmbeddedActivityReleased()"))
        self.assertIn("OfficePreviewOutputs.deleteResultRecord(directory)", method(editor, "private void cancelPreview()"))
        self.assertIn("OfficePreviewOutputs.deleteResultRecord(directory)", method(editor, "protected void onNewIntent(Intent intent)"))
        self.assertIn("OfficePreviewOutputs.writeResultRecord(", method(editor, "private boolean finishPreview()"))

    def test_link_trusts_only_this_app_and_watches_the_engine_process(self):
        link = self.read("OfficeEngineLink.java")
        call = method(link, "public Bundle call(String method, String arg, Bundle extras)")
        self.assertIn("Binder.getCallingUid() != Process.myUid()", call)
        self.assertIn("Binder.getCallingPid()", call)
        self.assertIn(".linkToDeath(", call)
        self.assertLess(call.index("watchedEngines.add(token)"), call.index(".linkToDeath("),
                        "the engine token is held before its death notice is armed")
        self.assertEqual(call.count("watchedEngines.remove(token)"), 2, "the token is let go on death or failed linking")
        self.assertIn("OfficeSessionJournal.setProcessStopper(", method(link, "public boolean onCreate()"))

    def test_engine_process_helpers(self):
        process = self.read("OfficeEngineProcess.java")
        prepare = method(process, "static synchronized void prepare()")
        self.assertIn("Build.VERSION.SDK_INT >= 28", prepare)
        self.assertIn('WebView.setDataDirectorySuffix("office")', prepare)
        self.assertIn("acquireContentProviderClient(", process)
        stop = method(process, "static void stopAfterRelease(Activity activity)")
        self.assertIn("isChangingConfigurations()", stop)
        self.assertIn("Process.killProcess(Process.myPid())", stop)


if __name__ == "__main__":
    unittest.main(verbosity=2)
