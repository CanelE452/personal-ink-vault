"""Exercise the real Office script ownership state in a plain JDK.

No Android, JSON, document engine, or native calls are involved.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).parent
SOURCE = MODULE / "src/main/java/io/github/canele452/personalinkvault/office/OfficeScriptSession.java"

HARNESS = r'''
import io.github.canele452.personalinkvault.office.OfficeScriptSession;
import io.github.canele452.personalinkvault.office.OfficeScriptSession.Kind;
import io.github.canele452.personalinkvault.office.OfficeScriptSession.Ticket;
import java.lang.reflect.Modifier;
import java.util.*;
import java.util.concurrent.*;

public final class ScriptSessionHarness {
  static final String ID = "01234567-89ab-4cde-8fab-0123456789ab";
  static void require(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }
  static void rejects(Runnable action, String message) {
    try { action.run(); }
    catch (IllegalArgumentException | IllegalStateException | NullPointerException expected) { return; }
    throw new AssertionError(message);
  }
  static void validateTicket(Ticket ticket, Kind kind) {
    require(ticket.kind == kind, "ticket retains the requested operation kind");
    require(ticket.id.length() <= 96, "ticket fits the response correlation bound");
    require(ticket.id.matches("pivcell-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}-[1-9][0-9]*"),
      "ticket is safe ASCII with a random instance nonce and a positive counter: " + ticket.id);
  }
  static void validation() {
    for (String bad : new String[]{null, "", " " + ID, ID + "\n", ID.toUpperCase(Locale.ROOT),
        "0123456789ab4cde8fab0123456789ab", "0-0-4-8-0", "../" + ID,
        "01234567-89ab-0cde-8fab-0123456789ab", "01234567-89ab-9cde-8fab-0123456789ab",
        "01234567-89ab-4cde-7fab-0123456789ab", "01234567-89ab-4cde-cfab-0123456789ab",
        "\uff101234567-89ab-4cde-8fab-0123456789ab", "01234567-89\uff41b-4cde-8fab-0123456789ab",
        "\u06601234567-89ab-4cde-8fab-0123456789ab", ID + "\u0000", ID + "\u200b"}) {
      rejects(() -> new OfficeScriptSession(bad), "invalid journal session ID accepted: " + bad);
    }
    for (char version = '1'; version <= '8'; version++) {
      for (char variant : new char[]{'8', '9', 'a', 'b'}) {
        String valid = "01234567-89ab-" + version + "cde-" + variant + "fab-0123456789ab";
        OfficeScriptSession state = new OfficeScriptSession(valid);
        require(state.pending() == null && !state.blocksSave(), "canonical journal IDs begin idle");
      }
    }
    OfficeScriptSession state = new OfficeScriptSession(ID);
    rejects(() -> state.begin(null), "null operation must not create a request");
    require(state.pending() == null && !state.blocksSave(), "invalid begin preserves idle state");
  }
  static void serialization() {
    OfficeScriptSession state = new OfficeScriptSession(ID);
    for (Kind first : Kind.values()) {
      Ticket ticket = state.begin(first);
      validateTicket(ticket, first);
      require(state.pending() == ticket && state.owns(ticket.id) && state.blocksSave(), "a live operation owns the only pending slot");
      for (Kind second : Kind.values()) rejects(() -> state.begin(second), "read and replace must share serialization");
      rejects(() -> state.begin(null), "invalid request cannot replace pending ownership");
      require(state.pending() == ticket, "rejected begin does not clobber the owner");
      require(!state.owns(null) && !state.owns("wrong") && !state.finish(null, true) && !state.finish("wrong", true),
        "unrelated replies do not claim ownership");
      require(state.pending() == ticket && state.blocksSave(), "wrong reply leaves the operation pending");
      require(state.finish(ticket.id, false), "matching reply finishes once");
      require(state.pending() == null && !state.owns(ticket.id) && !state.blocksSave(), "successful finish releases ownership before follow-up work");
      require(!state.finish(ticket.id, true) && !state.blocksSave(), "duplicate reply cannot quarantine an already finished request");
    }
    Ticket previous = state.begin(Kind.REPLACE);
    Ticket[] next = {null};
    Runnable callback = () -> {
      require(state.finish(previous.id, false), "callback completes its own request");
      next[0] = state.begin(Kind.READ);
    };
    callback.run();
    require(!state.finish(previous.id, false) && !state.finish(previous.id, true), "late callback cannot consume a newly registered operation");
    require(state.pending() == next[0] && state.owns(next[0].id), "follow-up request retains independent ownership");
    require(state.finish(next[0].id, false) && !state.blocksSave(), "follow-up operation remains completable");
  }
  static void identity() throws Exception {
    require(Modifier.isFinal(OfficeScriptSession.class.getModifiers()), "session state cannot be overridden");
    require(Modifier.isFinal(Ticket.class.getModifiers()), "ticket cannot be overridden");
    for (String field : List.of("id", "kind")) {
      int modifiers = Ticket.class.getField(field).getModifiers();
      require(Modifier.isPublic(modifiers) && Modifier.isFinal(modifiers), "ticket correlation fields are immutable");
    }
    Set<String> ids = new HashSet<>();
    for (int instance = 0; instance < 64; instance++) {
      OfficeScriptSession left = new OfficeScriptSession(ID);
      OfficeScriptSession right = new OfficeScriptSession(ID);
      Ticket foreign = right.begin(Kind.REPLACE);
      long previousCounter = 0;
      String nonce = null;
      for (int operation = 0; operation < 3; operation++) {
        Ticket ticket = left.begin(Kind.READ);
        validateTicket(ticket, Kind.READ);
        String currentNonce = ticket.id.substring(0, ticket.id.lastIndexOf('-'));
        long counter = Long.parseLong(ticket.id.substring(ticket.id.lastIndexOf('-') + 1));
        require(nonce == null || nonce.equals(currentNonce), "one instance keeps its own nonce");
        require(counter > previousCounter, "a completed ticket is never reused within an instance");
        require(ids.add(ticket.id) && !ticket.id.equals(foreign.id), "same journal session never shares a request ID across instances");
        require(!right.owns(ticket.id) && !right.finish(ticket.id, true), "cross-instance reply cannot consume or quarantine a live owner");
        require(right.pending() == foreign, "foreign reply leaves the other instance intact");
        require(!left.owns(foreign.id) && !left.finish(foreign.id, true), "ownership is not based on journal session alone");
        require(left.finish(ticket.id, false), "own ticket still completes after rejecting a foreign reply");
        nonce = currentNonce;
        previousCounter = counter;
      }
      require(right.finish(foreign.id, false) && !right.blocksSave(), "foreign failures do not poison an otherwise successful instance");
    }
  }
  static void uncertain() {
    for (Kind kind : Kind.values()) {
      OfficeScriptSession state = new OfficeScriptSession(ID);
      Ticket ticket = state.begin(kind);
      require(!state.finish("unrelated", true), "unrelated uncertain reply is ignored");
      require(state.finish(ticket.id, true), "matching ambiguous outcome is consumed");
      require(state.pending() == null && !state.owns(ticket.id) && state.blocksSave(), "uncertainty clears ownership while quarantining save");
      for (Kind next : Kind.values()) rejects(() -> state.begin(next), "uncertainty blocks every subsequent script");
      require(!state.finish(ticket.id, false) && !state.finish(null, false), "late success cannot clear quarantine");
      require(state.blocksSave(), "quarantine persists after stale replies");
      state.close();
      state.close();
      require(state.pending() == null && state.blocksSave(), "closing quarantined state never re-enables save");
    }
  }
  static void close() {
    for (Kind kind : Kind.values()) {
      OfficeScriptSession state = new OfficeScriptSession(ID);
      Ticket ticket = state.begin(kind);
      state.close();
      state.close();
      require(state.pending() == null && !state.owns(ticket.id) && state.blocksSave(), "close releases pending ownership and blocks save");
      require(!state.finish(ticket.id, false) && !state.finish(ticket.id, true) && !state.finish(null, true), "late close replies are ignored");
      for (Kind next : Kind.values()) rejects(() -> state.begin(next), "closed state cannot be reopened by begin");
      require(state.pending() == null && state.blocksSave(), "rejected late work leaves state closed");
    }
    OfficeScriptSession idle = new OfficeScriptSession(ID);
    idle.close();
    idle.close();
    require(idle.blocksSave() && idle.pending() == null, "closing idle state is idempotent and blocks save");
    rejects(() -> idle.begin(Kind.READ), "idle close is terminal too");
  }
  static void concurrent() throws Exception {
    OfficeScriptSession state = new OfficeScriptSession(ID);
    ExecutorService executor = Executors.newFixedThreadPool(8);
    try {
      CountDownLatch ready = new CountDownLatch(8), start = new CountDownLatch(1);
      List<Future<Ticket>> contenders = new ArrayList<>();
      for (int index = 0; index < 8; index++) {
        Kind kind = index % 2 == 0 ? Kind.READ : Kind.REPLACE;
        contenders.add(executor.submit(() -> {
          ready.countDown();
          start.await();
          try { return state.begin(kind); }
          catch (IllegalStateException busy) { return null; }
        }));
      }
      require(ready.await(5, TimeUnit.SECONDS), "contending requests reached the shared start");
      start.countDown();
      Ticket winner = null;
      int accepted = 0;
      for (Future<Ticket> contender : contenders) {
        Ticket ticket = contender.get(5, TimeUnit.SECONDS);
        if (ticket != null) { winner = ticket; accepted++; }
      }
      require(accepted == 1 && state.pending() == winner && state.blocksSave(), "concurrent read and replace accept exactly one owner");
      final String winningId = winner.id;
      List<Future<Boolean>> replies = new ArrayList<>();
      for (int index = 0; index < 8; index++) replies.add(executor.submit(() -> state.finish(winningId, false)));
      int consumed = 0;
      for (Future<Boolean> reply : replies) if (reply.get(5, TimeUnit.SECONDS)) consumed++;
      require(consumed == 1 && !state.blocksSave() && state.pending() == null, "concurrent duplicate replies consume ownership exactly once");
    } finally {
      executor.shutdownNow();
    }
  }
  public static void main(String[] args) throws Exception {
    switch (args[0]) {
      case "validation": validation(); break;
      case "serialization": serialization(); break;
      case "identity": identity(); break;
      case "uncertain": uncertain(); break;
      case "close": close(); break;
      case "concurrent": concurrent(); break;
      case "nonce": System.out.println("ticket=" + new OfficeScriptSession(ID).begin(Kind.READ).id); break;
      default: throw new AssertionError("unknown scenario");
    }
    System.out.println(args[0] + " scenarios passed");
  }
}
'''


class ScriptSessionTests(unittest.TestCase):
    def run_harness(self, scenario, repeats=1):
        self.assertTrue(SOURCE.is_file(), "OfficeScriptSession request lifecycle is not implemented")
        java_home = os.environ.get("JAVA_HOME")
        suffix = ".exe" if os.name == "nt" else ""
        javac = str(Path(java_home) / f"bin/javac{suffix}") if java_home else shutil.which("javac")
        java = str(Path(java_home) / f"bin/java{suffix}") if java_home else shutil.which("java")
        self.assertTrue(javac and java, "A JDK is required; this is not an Android/JNI test")
        outputs = []
        with tempfile.TemporaryDirectory(prefix="office-script-session-") as folder:
            harness = Path(folder) / "ScriptSessionHarness.java"
            harness.write_text(HARNESS, encoding="utf-8")
            compiled = subprocess.run([javac, "-encoding", "UTF-8", "-d", folder, str(harness), str(SOURCE)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            for _ in range(repeats):
                result = subprocess.run([java, "-cp", folder, "ScriptSessionHarness", scenario], capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("scenarios passed", result.stdout)
                outputs.append(result.stdout)
                print(result.stdout.strip())
        return outputs

    def test_rejects_noncanonical_and_unicode_journal_session_ids(self):
        self.run_harness("validation")

    def test_serializes_read_replace_and_preserves_reentrant_followup_ownership(self):
        self.run_harness("serialization")

    def test_same_session_instances_reject_foreign_and_stale_reply_ids(self):
        self.run_harness("identity")

    def test_uncertain_outcome_quarantines_script_and_save_until_close(self):
        self.run_harness("uncertain")

    def test_close_is_terminal_idempotent_and_ignores_late_replies(self):
        self.run_harness("close")

    def test_concurrent_requests_and_duplicate_replies_have_one_owner(self):
        self.run_harness("concurrent")

    def test_same_session_after_jvm_restart_uses_a_fresh_nonce(self):
        outputs = self.run_harness("nonce", repeats=2)
        tickets = [next(line for line in output.splitlines() if line.startswith("ticket=")) for output in outputs]
        self.assertNotEqual(tickets[0], tickets[1], "a process restart must not reuse script correlation IDs")


if __name__ == "__main__":
    unittest.main()
