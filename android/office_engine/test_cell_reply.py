"""HOST ONLY: validate the actual native cell-reply codec with real org.json.

This does not execute Android, JSUNO, a document engine, or an APK. The pinned
existing Gradle-cache JAR is read only; this test never downloads dependencies.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


MODULE = Path(__file__).resolve().parent
JAVA = MODULE / 'src/main/java/io/github/canele452/personalinkvault/office'
CODEC = JAVA / 'OfficeCellReply.java'
SESSION = JAVA / 'OfficeScriptSession.java'
JSON_JAR = Path('C:/Users/User/.gradle/caches/modules-2/files-2.1/org.json/json/20180813/8566b2b0391d9d4479ea225645c6ed47ef17fe41/json-20180813.jar')
JSON_SHA256 = '518080049ba83181914419d11a25d9bc9833a2d729b6a6e7469fa52851356da8'

HARNESS = r'''
import io.github.canele452.personalinkvault.office.OfficeCellReply;
import io.github.canele452.personalinkvault.office.OfficeScriptSession;
import io.github.canele452.personalinkvault.office.OfficeScriptSession.Kind;
import io.github.canele452.personalinkvault.office.OfficeScriptSession.Ticket;
import org.json.*;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class CellReplyHarness {
  static final String ID = "70bf425f-c413-457a-82cc-119c3f6cc8ae";
  static final String URL = "file:///data/user/0/io.github.canele452.personalinkvault/files/office-sessions/" + ID + "/working.pptx";
  static int assertions;
  interface Checked { void run() throws Exception; }
  static void require(boolean value, String message) {
    assertions++;
    if (!value) throw new AssertionError(message);
  }
  static void rejected(Checked action, String message) throws Exception {
    try { action.run(); } catch (IOException expected) { assertions++; return; }
    throw new AssertionError(message);
  }
  static Ticket ticket(Kind kind) { return new OfficeScriptSession(ID).begin(kind); }
  static JSONObject cell(int row, int column, String text) {
    return new JSONObject().put("row", row).put("column", column).put("text", text).put("editable", true);
  }
  static JSONObject table() {
    return new JSONObject().put("slide", 0).put("shape", 1).put("pageCount", 2).put("shapeCount", 3)
      .put("name", "표 😀").put("rows", 1).put("columns", 2).put("x", -100).put("y", 20)
      .put("width", 3000).put("height", 1200).put("cells", new JSONArray()
      .put(cell(0, 0, "한글 😀\nsecond line")).put(cell(0, 1, "")));
  }
  static JSONObject body(Kind kind, boolean success, boolean changed) {
    JSONObject value = new JSONObject().put("protocol", "piv-cell-1").put("sessionId", ID)
      .put("documentUrl", URL).put("action", kind == Kind.READ ? "read" : "replace")
      .put("success", success).put("mayHaveMutated", changed);
    return success ? value.put(kind == Kind.READ ? "tables" : "table", kind == Kind.READ ? new JSONArray().put(table()) : table())
      : value.put("code", "stale_snapshot");
  }
  static byte[] raw(Ticket ticket, String tail) {
    // Preserve intentionally invalid DTO UTF16 as JSON escapes, rather than
    // allowing the Java UTF8 encoder to silently replace the fixture with '?'.
    tail = tail.replace("\ud800", "\\ud800").replace("\udc00", "\\udc00");
    return ("executescriptresult: {\"id\":\"" + ticket.id + "\"" + tail).getBytes(StandardCharsets.UTF_8);
  }
  static byte[] frame(Ticket ticket, JSONObject body) { return raw(ticket, ",\"ok\":" + body + "}"); }
  static OfficeCellReply.Result decode(Ticket ticket, JSONObject body) throws Exception {
    return OfficeCellReply.decode(frame(ticket, body), ticket, ID, URL);
  }
  static JSONObject copy(JSONObject value) { return new JSONObject(value.toString()); }

  static void happy() throws Exception {
    for (Kind kind : Kind.values()) {
      Ticket ticket = ticket(kind);
      JSONObject data = body(kind, true, kind == Kind.REPLACE);
      byte[] input = frame(ticket, data), original = input.clone();
      require(OfficeCellReply.matches(input, ticket), "exact owned native prefix is recognized");
      OfficeCellReply.Result result = OfficeCellReply.decode(input, ticket, ID, URL);
      require(result.success && !result.uncertain && result.body != null && result.code == null, "successful DTO retains its typed body");
      JSONObject t = kind == Kind.READ ? result.body.getJSONArray("tables").getJSONObject(0) : result.body.getJSONObject("table");
      require(t.getJSONArray("cells").getJSONObject(0).getString("text").equals("한글 😀\nsecond line"), "Unicode and newlines survive exactly");
      require(Arrays.equals(input, original), "codec never mutates native frame bytes");
      data.put("documentUrl", URL.replace("file:///", "file:/"));
      require(decode(ticket, data).success, "local file URL slash count is canonicalized");
      data.put("documentUrl", URL.replace("file:///", "file://///"));
      require(decode(ticket, data).success, "extra local slash spelling follows program canonicalization");
    }
    Ticket read = ticket(Kind.READ);
    require(decode(read, body(Kind.READ, true, false).put("tables", new JSONArray())).success, "empty presentation table catalogue is valid");
  }
  static void ownership() throws Exception {
    Ticket own = ticket(Kind.REPLACE), foreign = ticket(Kind.REPLACE);
    byte[][] frames = {frame(foreign, body(Kind.REPLACE, true, true)), new byte[]{(byte)0xff},
      ("executescriptresult: {\"id\":\"" + own.id + "-suffix\",bad}").getBytes(StandardCharsets.US_ASCII),
      ("executescriptresult:{\"id\":\"" + own.id + "\",bad}").getBytes(StandardCharsets.US_ASCII),
      raw(own, "x,bad}"), "other-event".getBytes(StandardCharsets.UTF_8)};
    for (byte[] value : frames) {
      byte[] original = value.clone();
      require(!OfficeCellReply.matches(value, own), "foreign or non-native prefix is not owned");
      require(OfficeCellReply.decode(value, own, ID, URL) == null, "foreign frames do not parse or consume ownership");
      require(Arrays.equals(original, value), "foreign byte identity is preserved");
    }
    require(OfficeCellReply.matches(raw(own, "}"), own), "closing object is an exact ID boundary");
    rejected(() -> OfficeCellReply.decode(raw(own, "}"), own, ID, URL), "owned missing outcome is malformed");
  }
  static void failures() throws Exception {
    for (Kind kind : Kind.values()) {
      Ticket ticket = ticket(kind);
      OfficeCellReply.Result failure = decode(ticket, body(kind, false, false));
      require(!failure.success && !failure.uncertain && failure.code.equals("stale_snapshot"), "clean program failure is retryable");
      if (kind == Kind.REPLACE) {
        failure = decode(ticket, body(kind, false, true));
        require(!failure.success && failure.uncertain && failure.code.equals("stale_snapshot"), "possible replacement mutation is uncertain");
      } else rejected(() -> decode(ticket, body(kind, false, true)), "read never claims mutation");
      for (String err : new String[]{"\"native private error\"", "{\"private\":\"native detail\"}"}) {
        failure = OfficeCellReply.decode(raw(ticket, ",\"err\":" + err + "}"), ticket, ID, URL);
        require(!failure.success && failure.uncertain == (kind == Kind.REPLACE) && failure.code.equals("native_error") && failure.body == null,
          "native errors are closed codes and replacement errors quarantine");
      }
      failure = OfficeCellReply.decode(raw(ticket, ",\"ok\":" + body(kind, true, kind == Kind.REPLACE) + ",\"legacyUnoApi\":true}"), ticket, ID, URL);
      require(!failure.success && failure.uncertain == (kind == Kind.REPLACE) && failure.code.equals("unsupported_bridge"), "legacy bridge cannot grant success");
      require(OfficeCellReply.decode(raw(ticket, ",\"ok\":" + body(kind, true, kind == Kind.REPLACE) + ",\"legacyUnoApi\":false}"), ticket, ID, URL).success,
        "explicit modern bridge false is valid");
    }
  }
  static void malformed() throws Exception {
    Ticket ticket = ticket(Kind.READ);
    for (String tail : new String[]{"}", ",\"ok\":null}", ",\"ok\":true}", ",\"err\":4}", ",\"err\":null}",
      ",\"ok\":{}", ",\"ok\":{},\"err\":\"both\"}", ",\"legacyUnoApi\":true}", ",\"legacyUnoApi\":\"true\",\"ok\":{}}",
      ",\"ok\":{},\"id\":\"different\"}", ",\"ok\":{}} trailing", ",\"err\":{'detail':'lenient JSON'}}",
      ",\"err\":{detail:1}}", ",\"err\":{\"detail\":01}}", ",\"err\":{\"x\":1,\"\\u0078\":2}}"}) {
      rejected(() -> OfficeCellReply.decode(raw(ticket, tail), ticket, ID, URL), "owned malformed envelope must fail: " + tail);
    }
    byte[] valid = frame(ticket, body(Kind.READ, true, false));
    byte[] invalidUtf8 = Arrays.copyOf(valid, valid.length + 2);
    invalidUtf8[valid.length] = (byte)0xc0; invalidUtf8[valid.length + 1] = (byte)0xaf;
    rejected(() -> OfficeCellReply.decode(invalidUtf8, ticket, ID, URL), "invalid UTF8 must not be replaced with U+FFFD");
    byte[] huge = Arrays.copyOf(valid, 1024 * 1024 + 1);
    rejected(() -> OfficeCellReply.decode(huge, ticket, ID, URL), "raw byte budget checked before decode");
    rejected(() -> OfficeCellReply.decode(raw(ticket, ",\"err\":" + "{\"nested\":".repeat(40) + "0" + "}".repeat(40) + "}"), ticket, ID, URL), "deep otherwise valid native error rejected before org.json parsing");
    require(OfficeCellReply.decode(raw(ticket, ",\"err\":" + "{\"nested\":".repeat(31) + "0" + "}".repeat(31) + "}"), ticket, ID, URL).code.equals("native_error"),
      "exactly 32 container levels including envelope are allowed");
    JSONObject text = body(Kind.READ, true, false);
    text.getJSONArray("tables").getJSONObject(0).getJSONArray("cells").getJSONObject(0).put("text", "[\\\"".repeat(500));
    require(decode(ticket, text).success, "brackets and escaped quotes inside text do not consume nesting depth");
  }
  static void bindingAndTypes() throws Exception {
    Ticket ticket = ticket(Kind.READ);
    for (Object[] change : new Object[][]{{"protocol", "other"}, {"sessionId", ID.toUpperCase(Locale.ROOT)}, {"action", "replace"},
      {"success", "true"}, {"mayHaveMutated", 0}, {"extra", "untrusted"}, {"tables", new JSONObject()}}) {
      JSONObject data = body(Kind.READ, true, false).put((String)change[0], change[1]);
      rejected(() -> decode(ticket, data), "DTO protocol/session/action/closed typed fields cannot be coerced");
    }
    for (String url : new String[]{URL.replace("working", "other"), URL.replace("working", "%77orking"), "https://example.invalid/a.pptx",
      "file://remote/a.pptx", "file:relative.pptx", "file:///a/../b.pptx", "file:///a/./b.pptx", "file:///a\\b.pptx", URL + "?q", URL + "#x", "file:///"}) {
      rejected(() -> decode(ticket, body(Kind.READ, true, false).put("documentUrl", url)), "foreign URL must not bind: " + url);
    }
    for (String code : new String[]{"native secret", "unsupported_bridge", "", "native_error"}) {
      rejected(() -> decode(ticket, body(Kind.READ, false, false).put("code", code)), "program failure codes are closed");
    }
    rejected(() -> decode(ticket, body(Kind.READ, true, true)), "successful read cannot mutate");
    Ticket replace = ticket(Kind.REPLACE);
    rejected(() -> decode(replace, body(Kind.REPLACE, true, false)), "successful replace must report mutation");
    rejected(() -> decode(ticket, body(Kind.READ, false, false).put("tables", new JSONArray())), "failure DTO contains only base fields and code");
  }
  static void tables() throws Exception {
    Ticket ticket = ticket(Kind.READ);
    JSONObject original = table();
    for (Object[] change : new Object[][]{{"rows", 0}, {"columns", -1}, {"rows", 257}, {"rows", "1"}, {"slide", 2},
      {"slide", -1}, {"pageCount", 129}, {"shape", 3}, {"shapeCount", 2049}, {"width", 0}, {"height", -1},
      {"x", 2147483648L}, {"x", 1.5}, {"name", "\ud800"}, {"name", true}, {"extra", 1}}) {
      JSONObject changed = copy(original).put((String)change[0], change[1]);
      rejected(() -> decode(ticket, body(Kind.READ, true, false).put("tables", new JSONArray().put(changed))), "invalid table bounds/types rejected: " + change[0]);
    }
    for (Object[] change : new Object[][]{{"row", 1}, {"column", 1}, {"row", "0"}, {"editable", "true"}, {"text", "\udc00"}, {"extra", 1}}) {
      JSONObject changed = copy(original);
      changed.getJSONArray("cells").getJSONObject(0).put((String)change[0], change[1]);
      rejected(() -> decode(ticket, body(Kind.READ, true, false).put("tables", new JSONArray().put(changed))), "cell positions/order/types and Unicode are exact");
    }
    rejected(() -> decode(ticket, body(Kind.READ, true, false).put("tables", new JSONArray().put(original).put(copy(original)))), "duplicate slide/shape tables are rejected");
    JSONObject many = copy(original).put("rows", 16).put("columns", 16).put("cells", new JSONArray());
    for (int row=0; row<16; row++) for (int col=0; col<16; col++) many.getJSONArray("cells").put(cell(row,col,""));
    JSONArray max = new JSONArray();
    for (int n=0; n<4; n++) max.put(copy(many).put("shape",n).put("shapeCount",5));
    require(decode(ticket, body(Kind.READ,true,false).put("tables",max)).success, "1024 total cells and 256 per table are allowed");
    max.put(copy(many).put("shape",4).put("shapeCount",5));
    rejected(() -> decode(ticket, body(Kind.READ,true,false).put("tables",max)), "total cell budget is enforced");
    JSONObject large = body(Kind.READ,true,false);
    large.getJSONArray("tables").getJSONObject(0).getJSONArray("cells").getJSONObject(0).put("text", "한".repeat(200000));
    rejected(() -> decode(ticket,large), "whole DTO UTF16 budget includes structure and all cell text");
  }
  public static void main(String[] args) throws Exception {
    happy(); ownership(); failures(); malformed(); bindingAndTypes(); tables();
    System.out.println("HOST ONLY: " + assertions + " codec assertions passed; Android/native runtime unverified.");
  }
}
'''


class CellReplyTests(unittest.TestCase):
    def test_actual_codec_rejects_foreign_malformed_unbounded_and_untyped_native_replies(self):
        self.assertTrue(CODEC.is_file(), 'OfficeCellReply bounded native reply codec is not implemented')
        self.assertTrue(JSON_JAR.is_file(), 'The existing read-only org.json Gradle-cache JAR is required')
        self.assertEqual(hashlib.sha256(JSON_JAR.read_bytes()).hexdigest(), JSON_SHA256)
        suffix = '.exe' if os.name == 'nt' else ''
        java_home = os.environ.get('JAVA_HOME')
        javac = str(Path(java_home) / f'bin/javac{suffix}') if java_home else shutil.which('javac')
        java = str(Path(java_home) / f'bin/java{suffix}') if java_home else shutil.which('java')
        self.assertTrue(javac and java, 'A JDK is required; this test does not use Android/JNI')
        with tempfile.TemporaryDirectory(prefix='office-cell-reply-') as folder:
            harness = Path(folder) / 'CellReplyHarness.java'
            harness.write_text(HARNESS, encoding='utf-8')
            compiled = subprocess.run([javac, '-encoding', 'UTF-8', '-cp', str(JSON_JAR), '-d', folder,
                                       str(harness), str(CODEC), str(SESSION)], capture_output=True, text=True, timeout=30)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([java, '-cp', folder + os.pathsep + str(JSON_JAR), 'CellReplyHarness'],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('codec assertions passed', result.stdout)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main(verbosity=2)
