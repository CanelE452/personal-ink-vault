"""Run the Java save/reopen bridge with Activity doubles and optional real UNO files."""

import re
import unittest
from unittest.mock import patch

import test_session_journal as recovery


SCENARIOS = r'''
  static final int REOPEN_REQUEST = 19475;

  static class ReopenActivity extends Activity {
    final CountDownLatch reopenLaunched = new CountDownLatch(1);
    volatile int lastRequest;

    ReopenActivity(File home) { super(home); }

    @Override public void startActivityForResult(Intent intent, int request) {
      lastRequest = request;
      super.startActivityForResult(intent, request);
      if (request == REOPEN_REQUEST) reopenLaunched.countDown();
    }
  }

  static class SourceSave {
    final String format;
    final File original;
    final String inputHash;
    final ReopenActivity activity;
    final OfficeEngineBridge bridge;
    final Completion saved = new Completion();
    final OfficeSessionJournal journal;
    final File edited;
    final String editedHash;
    final Path modernFixtures;
    final int previewPages;
    final Object nativeOwner = new Object();

    SourceSave(File home, String format) throws Exception {
      this.format = format;
      boolean legacy = format.equals("doc") || format.equals("ppt");
      String modernFixturePath = System.getenv("PIV_OFFICE_TEST_REOPEN_FIXTURES");
      modernFixtures = legacy || modernFixturePath == null ? null : Path.of(modernFixturePath);
      previewPages = modernFixtures != null && (format.equals("pptx") || format.equals("odp")) ? 3 : 1;
      Files.createDirectories(home.toPath());
      original = new File(home, "original." + format);
      if (modernFixtures == null) office(original, format, "original Office source");
      else Files.copy(modernFixtures.resolve("working." + format), original.toPath());
      inputHash = hash(original);
      activity = new ReopenActivity(home);
      bridge = new OfficeEngineBridge(activity);
      journal = new OfficeSessionJournal(new File(home, "office-sessions"), VERSION);
      bridge.edit(original.getPath(), ID, saved);
      waitLaunch(activity, 1);
      require(activity.lastRequest == OfficeEngineBridge.REQUEST_EDIT, "initial launch enters the editor");
      require(!activity.lastIntent.getBooleanExtra("piv.previewOnly", false), "initial launch can edit");
      require(OfficeEditorActivity.attach(ID, nativeOwner, false), "activity adopts the editor reservation");
      edited = new File(activity.lastIntent.getStringExtra("piv.sessionDirectory"), "edited." + format);
      String legacyFixtures = System.getProperty("piv.test.legacy-fixtures");
      if (modernFixtures != null) {
        Files.copy(modernFixtures.resolve("saved." + format), edited.toPath());
      } else if (legacy && legacyFixtures != null) {
        Files.copy(Path.of(legacyFixtures, "edited." + format), edited.toPath());
      } else {
        office(edited, format, "serialized, changed Office source");
      }
      editedHash = hash(edited);
      require(!inputHash.equals(editedHash), "fixture distinguishes original bytes from serialized output");
      binding(journal.recordSourceReady(ID, inputHash), "source_ready", inputHash);
    }

    Intent sourceResult(String session, String inputDigest) {
      return new Intent().putExtra("piv.sourceReady", true).putExtra("sessionId", session)
        .putExtra("inputSourceSha256", inputDigest).putExtra("sourcePath", edited.getPath())
        .putExtra("sourceSha256", editedHash);
    }

    void rejectStaleSourceReady() throws Exception {
      require(bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_OK, sourceResult(OTHER, inputHash)),
        "another session's stale source-ready callback is consumed");
      require(bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_OK, sourceResult(ID, WRONG)),
        "another source digest's stale source-ready callback is consumed");
      require(!saved.done.await(220, TimeUnit.MILLISECONDS) && activity.launches == 1,
        "stale source-ready callbacks cannot complete or launch preview for the active session");
    }

    void finishEditor() throws Exception {
      Intent result = sourceResult(ID, inputHash);
      require(bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_OK, result),
        "bridge accepts the editor source-ready callback");
      require(!activity.reopenLaunched.await(220, TimeUnit.MILLISECONDS),
        "reopen must wait for the actual editor to release its ownership");
      require(saved.done.getCount() == 1 && activity.launches == 1,
        "source-ready callback keeps the original request pending while the editor is closing");
      require(!new File(edited.getParentFile(), "saved.properties").exists(), "source alone cannot publish a saved pair");
      OfficeSessionJournal.releaseEditor(nativeOwner);
    }

    Intent attempt(int launchCount) throws Exception {
      waitLaunch(activity, launchCount);
      require(activity.lastRequest == REOPEN_REQUEST, "a distinct request code identifies the read-only reopen");
      Intent intent = activity.lastIntent;
      String attempt = intent.getStringExtra("piv.sessionId");
      require(attempt != null && !attempt.equals(ID), "attempt ID is distinct from the durable session");
      UUID.fromString(attempt);
      require(intent.getBooleanExtra("piv.previewOnly", false), "reopen uses the preview route");
      require(intent.getBooleanExtra("piv.reopenedSource", false), "activity is told it is previewing saved source bytes");
      require(editedHash.equals(intent.getStringExtra("piv.inputSourceSha256")), "attempt is bound to serialized source digest");
      File copy = new File(intent.getStringExtra("piv.workingPath"));
      File attemptDir = new File(intent.getStringExtra("piv.sessionDirectory"));
      require(copy.getParentFile().equals(attemptDir) && copy.getName().equals("working." + format), "format and attempt directory stay bound");
      require(attemptDir.getParentFile().equals(new File(activity.getFilesDir(), "office-previews")), "attempt uses the private preview root");
      require(Arrays.equals(Files.readAllBytes(edited.toPath()), Files.readAllBytes(copy.toPath())), "preview stages exact edited bytes");
      return intent;
    }

    Intent previewResult(Intent attempt, String content) throws Exception {
      File preview = new File(attempt.getStringExtra("piv.sessionDirectory"), "preview.pdf");
      if (modernFixtures == null) pdf(preview, content);
      else Files.copy(modernFixtures.resolve(format + "-reopen-ink.pdf"), preview.toPath());
      return new Intent().putExtra("sessionId", attempt.getStringExtra("piv.sessionId"))
        .putExtra("sourceSha256", editedHash).putExtra("pdfPath", preview.getPath())
        .putExtra("pdfSha256", hash(preview)).putExtra("pdfPageCount", previewPages);
    }

    void requireSaved(Completion completion, Intent result) throws Exception {
      String attempt = result.getStringExtra("sessionId");
      File temporaryPdf = new File(result.getStringExtra("pdfPath"));
      Object previewOwner = new Object();
      require(OfficeEditorActivity.attach(attempt, previewOwner, true), "reopened activity adopts its reservation");
      try {
        require(bridge.handleActivityResult(OfficeEngineBridge.REQUEST_EDIT, Activity.RESULT_CANCELED,
          new Intent().putExtra("sessionId", ID)), "late editor cancellation is consumed");
        require(bridge.handleActivityResult(REOPEN_REQUEST, Activity.RESULT_OK, result), "reopen callback handled");
        require(!completion.done.await(220, TimeUnit.MILLISECONDS), "PDF promotion must wait for the reopened activity to close");
        require(temporaryPdf.isFile(), "live activity retains its private PDF");
        requireRetained("closing reopened activity");
      } finally { OfficeSessionJournal.releaseEditor(previewOwner); }
      completion.await();
      require(completion.code == null, "expected saved pair; got " + completion.code);
      binding(completion.result, "saved", inputHash);
      File savedPdf = new File((String) completion.result.get("pdfPath"));
      require(edited.getPath().equals(completion.result.get("sourcePath")), "returned source is durable edited file");
      require(edited.getParentFile().equals(savedPdf.getParentFile()), "returned PDF is durable and colocated with source");
      require(editedHash.equals(completion.result.get("sourceSha256")) && editedHash.equals(hash(edited)), "edited bytes stay exact");
      require(result.getStringExtra("pdfSha256").equals(hash(savedPdf)), "journal published exact bytes from reopened PDF");
      require(Integer.valueOf(previewPages).equals(completion.result.get("pdfPageCount")), "journal preserved observed page count");
      require(completion.result.equals(journal.recover(ID, inputHash)), "fresh journal read has the exact saved pair");
      require(inputHash.equals(hash(original)), "original remains untouched");
      require(!temporaryPdf.getParentFile().exists(), "published preview attempt is cleaned up");
    }

    void requireRetained(String context) throws Exception {
      Map<String,Object> retained = journal.recover(ID, inputHash);
      binding(retained, "source_ready", inputHash);
      require(editedHash.equals(hash(edited)) && editedHash.equals(retained.get("sourceSha256")), context + " retains source bytes");
      require(!new File(edited.getParentFile(), "saved.properties").exists(), context + " cannot publish a saved pair");
    }

    void close() {
      OfficeSessionJournal.releaseEditor(nativeOwner);
      bridge.dispose();
    }
  }

  static void reopenScenario(File root, String mode) throws Exception {
    if (mode.equals("reopen-stale-preview")) {
      Object stale = new Object();
      require(!OfficeEditorActivity.attach(ID, stale, true),
          "restored preview without a live launch must be rejected");
      require(!OfficeSessionJournal.hasLiveEditor(), "stale intent must not claim the editor");

      Object original = new Object();
      require(OfficeEditorActivity.attach(ID, original, false),
          "interactive edit may reopen from the journal after process death");
      OfficeSessionJournal.releaseEditor(original);

      Object launcher = new Object();
      require(OfficeSessionJournal.reserveEditor(ID, launcher), "preview launch reserves the editor");
      require(!OfficeEditorActivity.attach(OTHER, stale, true),
          "a stale preview must not take a different launch reservation");
      Object preview = new Object();
      require(OfficeEditorActivity.attach(ID, preview, true), "the requested preview adopts its live launch");
      require(!OfficeEditorActivity.attach(ID, stale, true), "a second Activity cannot take an active preview");
      OfficeSessionJournal.releaseEditor(preview);
      require(!OfficeEditorActivity.attach(ID, stale, true), "a completed preview cannot be restored");
    } else if (mode.equals("reopen-cancel-while-closing")) {
      SourceSave edit = new SourceSave(new File(root, "cancel-while-closing"), "pptx");
      Object preview = new Object();
      try {
        edit.finishEditor();
        Intent attempt = edit.attempt(2);
        String attemptId = attempt.getStringExtra("piv.sessionId");
        File directory = new File(attempt.getStringExtra("piv.sessionDirectory"));
        require(OfficeEditorActivity.attach(attemptId, preview, true), "native preview adopts the reopen attempt");
        Intent cancel = new Intent().putExtra("sessionId", attemptId).putExtra("piv.previewCancelled", true);
        edit.bridge.handleActivityResult(REOPEN_REQUEST, Activity.RESULT_CANCELED, cancel);
        require(edit.saved.done.await(2, TimeUnit.SECONDS) && "office_reopen_cancelled".equals(edit.saved.code),
            "cancel returns to the workspace while the engine closes");
        edit.requireRetained("cancel before native release");
        require(directory.isDirectory(), "the active engine still owns the temporary copy");
        OfficeSessionJournal.releaseEditor(preview);
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        while (directory.exists() && System.nanoTime() < deadline) Thread.sleep(5);
        require(!directory.exists(), "only the released preview directory is removed");
        edit.requireRetained("cancel after native release");
      } finally {
        OfficeSessionJournal.releaseEditor(preview);
        edit.close();
      }
    } else if (mode.startsWith("reopen-save-")) {
      List<String> formats = mode.equals("reopen-save-legacy") ? List.of("doc", "ppt") : List.of("docx", "pptx", "odt", "odp");
      for (String format : formats) {
        SourceSave edit = new SourceSave(new File(root, "save-" + format), format);
        try {
          edit.rejectStaleSourceReady();
          edit.finishEditor();
          Intent attempt = edit.attempt(2);
          edit.requireSaved(edit.saved, edit.previewResult(attempt, "preview from serialized " + format));
        } finally { edit.close(); }
      }
    } else {
      String format = mode.substring("reopen-retry-".length());
      SourceSave edit = new SourceSave(new File(root, "retry-" + format), format);
      try {
        edit.finishEditor();
        Intent first = edit.attempt(2);
        Intent stale = edit.previewResult(first, "late first result");
        Intent cancel = new Intent().putExtra("sessionId", first.getStringExtra("piv.sessionId"));
        require(edit.bridge.handleActivityResult(REOPEN_REQUEST, Activity.RESULT_CANCELED, cancel), "reopen cancellation handled");
        edit.saved.await();
        require("office_reopen_cancelled".equals(edit.saved.code), "cancel reports retained preview work");
        edit.requireRetained("cancel");
        require(!new File(first.getStringExtra("piv.sessionDirectory")).exists(), "cancel cleans up the private preview attempt");

        Completion recovered = new Completion();
        edit.bridge.recover(ID, edit.inputHash, recovered);
        recovered.await();
        binding(recovered.result, "working", edit.inputHash);
        require(edit.activity.launches == 2, "read-only recovery lookup does not launch Office");

        Completion failed = new Completion();
        edit.bridge.resume(ID, edit.inputHash, failed);
        Intent second = edit.attempt(3);
        require(!second.getStringExtra("piv.sessionId").equals(first.getStringExtra("piv.sessionId")), "retry gets a new attempt ID");
        require(edit.bridge.handleActivityResult(REOPEN_REQUEST, Activity.RESULT_OK, stale), "late callback consumed");
        require(!failed.done.await(220, TimeUnit.MILLISECONDS), "late callback cannot consume a newer attempt");
        Intent tampered = edit.previewResult(second, "different preview bytes").putExtra("pdfSha256", WRONG);
        require(edit.bridge.handleActivityResult(REOPEN_REQUEST, Activity.RESULT_OK, tampered), "bad result consumed");
        failed.await();
        require(failed.code != null && failed.result == null, "digest mismatch cannot return a saved pair");
        edit.requireRetained("bad PDF digest");

        Completion resumed = new Completion();
        edit.bridge.resume(ID, edit.inputHash, resumed);
        Intent third = edit.attempt(4);
        edit.requireSaved(resumed, edit.previewResult(third, "fresh, verified reopened PDF"));
      } finally { edit.close(); }
    }
    System.out.println("native Office " + mode + " scenarios passed");
  }
'''


class ReopenBridgeTests(unittest.TestCase):
    def test_reopen_request_is_unique_across_main_activity_routes(self):
        main_result = recovery.method(recovery.APP.read_text(encoding='utf-8'), 'override fun onActivityResult')
        routes = re.findall(r'(\w+Bridge)\?\.handleActivityResult\(', main_result)
        self.assertIn('officeBridge', routes)
        codes = {}
        source_pickers = {'starNoteSourceBridge', 'officeSourceBridge'}
        for route in routes:
            if route in source_pickers:
                source = recovery.APP.with_name('DocumentSourceBridge.kt').read_text(encoding='utf-8')
                kind = 'STARNOTE' if route == 'starNoteSourceBridge' else 'OFFICE'
                declarations = [(kind, re.search(rf'\b{kind}\("[a-z_]+", (\d+),', source).group(1))]
            else:
                source = (recovery.JAVA / 'OfficeEngineBridge.java' if route == 'officeBridge' else
                          recovery.APP.with_name(route[0].upper() + route[1:] + '.kt'))
                declarations = re.findall(r'\b(REQUEST_[A-Z_]+)\s*=\s*(\d+)\b', source.read_text(encoding='utf-8'))
            self.assertTrue(declarations, route)
            for request, value in declarations:
                self.assertNotIn(value, codes, f'{route}.{request} conflicts with {codes.get(value)}')
                codes[value] = f'{route}.{request}'
        self.assertEqual(codes.get('19475'), 'officeBridge.REQUEST_REOPEN')

    def run_reopen(self, scenario):
        scenario_dispatch = 'else bridgeScenarios(root);'
        class_declaration = 'public class RecoveryHarness {'
        self.assertIn(scenario_dispatch, recovery.HARNESS)
        self.assertIn(class_declaration, recovery.HARNESS)
        harness = recovery.HARNESS.replace(class_declaration, class_declaration + SCENARIOS).replace(
            scenario_dispatch,
            'else if (args[0].startsWith("reopen-")) reopenScenario(root,args[0]);\n    ' + scenario_dispatch,
        )
        stubs = dict(recovery.STUBS)
        activity = 'io/github/canele452/personalinkvault/office/OfficeEditorActivity.java'
        stubs[activity] = stubs[activity].rstrip().removesuffix('}') + '''
  public static boolean attach(String sessionId, Object owner, boolean previewOnly) {
    return OfficeSessionJournal.editorOpened(sessionId, owner, previewOnly);
  }
}'''
        with patch.object(recovery, 'HARNESS', harness), patch.object(recovery, 'STUBS', stubs):
            recovery.SessionJournalTests.run_harness(self, scenario)

    def test_legacy_edit_waits_then_publishes_reopened_document_and_pdf(self):
        self.run_reopen('reopen-save-legacy')

    def test_modern_edit_waits_then_publishes_reopened_document_and_pdf(self):
        self.run_reopen('reopen-save-modern')

    def test_reopened_source_cancel_returns_while_the_engine_closes(self):
        self.run_reopen('reopen-cancel-while-closing')

    def test_restored_preview_requires_a_matching_live_launch(self):
        activity = (recovery.JAVA / 'OfficeEditorActivity.java').read_text(encoding='utf-8')
        on_create = recovery.method(activity, 'public void onCreate(')
        self.assertLess(on_create.index('previewOnly = getIntent().getBooleanExtra'),
                        on_create.index('OfficeEngineProcess.attach(this, sessionId, launchId, previewOnly)'))
        self.assertIn('setResult(Activity.RESULT_CANCELED', recovery.method(on_create, 'if (previewOnly && !opened)'))
        self.run_reopen('reopen-stale-preview')

    def test_cancelled_or_bad_preview_retries_without_reediting_saved_source(self):
        self.run_reopen('reopen-retry-ppt')
        self.run_reopen('reopen-retry-docx')


if __name__ == '__main__':
    unittest.main()
