package io.github.canele452.personalinkvault.office;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;

/** Validates one owned native reply without changing request or document state. */
public final class OfficeCellReply {
    private static final String NATIVE_PREFIX = "executescriptresult: ";
    private static final Set<String> CODES = new HashSet<>(Arrays.asList(
            "invalid_request", "invalid_document_url", "document_mismatch", "unsupported_document",
            "api_unavailable", "invalid_native_state", "observation_limit", "invalid_text",
            "cell_out_of_bounds", "stale_snapshot", "cell_uneditable", "write_failed", "verification_failed"));

    private OfficeCellReply() { }

    public static final class Result {
        public final boolean success;
        public final boolean uncertain;
        public final JSONObject body;
        public final String code;

        private Result(boolean success, boolean uncertain, JSONObject body, String code) {
            this.success = success;
            this.uncertain = uncertain;
            this.body = body;
            this.code = code;
        }
    }

    public static boolean matches(byte[] frame, OfficeScriptSession.Ticket ticket) {
        if (frame == null || ticket == null) return false;
        byte[] prefix = (NATIVE_PREFIX + "{\"id\":\"" + ticket.id + "\"").getBytes(StandardCharsets.US_ASCII);
        if (frame.length <= prefix.length) return false;
        for (int index = 0; index < prefix.length; index++) {
            if (frame[index] != prefix[index]) return false;
        }
        return frame[prefix.length] == ',' || frame[prefix.length] == '}';
    }

    public static Result decode(byte[] frame, OfficeScriptSession.Ticket ticket,
                                String sessionId, String expectedDocumentUrl) throws IOException {
        if (!matches(frame, ticket)) return null;
        if (frame.length > 1024 * 1024) throw invalid();
        try {
            String text = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(frame)).toString();
            String json = text.substring(NATIVE_PREFIX.length());
            checkJson(json);
            JSONObject envelope = new JSONObject(json);
            fields(envelope, "id", "ok", "err", "legacyUnoApi");
            if (!ticket.id.equals(string(envelope, "id"))) throw invalid();
            if (envelope.has("ok") == envelope.has("err")) throw invalid();
            Object value = envelope.get(envelope.has("ok") ? "ok" : "err");
            if (!(value instanceof JSONObject) && !(envelope.has("err") && value instanceof String)) throw invalid();
            if (envelope.has("legacyUnoApi") && bool(envelope, "legacyUnoApi")) {
                return new Result(false, ticket.kind == OfficeScriptSession.Kind.REPLACE, null, "unsupported_bridge");
            }
            if (envelope.has("err")) {
                return new Result(false, ticket.kind == OfficeScriptSession.Kind.REPLACE, null, "native_error");
            }
            JSONObject body = (JSONObject) value;
            if (body.toString().length() > 200000 || !"piv-cell-1".equals(string(body, "protocol"))
                    || sessionId == null || !sessionId.equals(string(body, "sessionId"))
                    || !fileUrl(expectedDocumentUrl).equals(fileUrl(string(body, "documentUrl")))) throw invalid();
            boolean replace = ticket.kind == OfficeScriptSession.Kind.REPLACE;
            if (!(replace ? "replace" : "read").equals(string(body, "action"))) throw invalid();
            boolean success = bool(body, "success"), mutated = bool(body, "mayHaveMutated");
            if (!replace && mutated) throw invalid();
            if (!success) {
                exact(body, "protocol", "sessionId", "documentUrl", "action", "success", "mayHaveMutated", "code");
                String code = string(body, "code");
                if (!CODES.contains(code)) throw invalid();
                return new Result(false, mutated, body, code);
            }
            if (replace != mutated) throw invalid();
            exact(body, "protocol", "sessionId", "documentUrl", "action", "success", "mayHaveMutated", replace ? "table" : "tables");
            if (replace) {
                table(object(body, "table"));
            } else {
                JSONArray tables = array(body, "tables");
                if (tables.length() > 1024) throw invalid();
                int cells = 0;
                Set<String> identities = new HashSet<>();
                for (int index = 0; index < tables.length(); index++) {
                    Object entry = tables.get(index);
                    if (!(entry instanceof JSONObject)) throw invalid();
                    JSONObject table = (JSONObject) entry;
                    cells += table(table);
                    if (cells > 1024 || !identities.add(integer(table, "slide") + ":" + integer(table, "shape"))) throw invalid();
                }
            }
            return new Result(true, false, body, null);
        } catch (CharacterCodingException | JSONException error) {
            throw new IOException("Invalid native cell reply", error);
        }
    }

    private static int table(JSONObject table) throws IOException, JSONException {
        exact(table, "slide", "shape", "pageCount", "shapeCount", "name", "rows", "columns", "x", "y", "width", "height", "cells");
        int slide = integer(table, "slide"), shape = integer(table, "shape");
        int pages = integer(table, "pageCount"), shapes = integer(table, "shapeCount");
        int rows = integer(table, "rows"), columns = integer(table, "columns");
        if (pages < 1 || pages > 128 || slide < 0 || slide >= pages || shapes < 1 || shapes > 2048
                || shape < 0 || shape >= shapes || rows < 1 || columns < 1 || rows > 256 || columns > 256
                || rows * columns > 256) throw invalid();
        integer(table, "x");
        integer(table, "y");
        if (integer(table, "width") <= 0 || integer(table, "height") <= 0) throw invalid();
        string(table, "name");
        JSONArray cells = array(table, "cells");
        if (cells.length() != rows * columns) throw invalid();
        for (int index = 0; index < cells.length(); index++) {
            Object entry = cells.get(index);
            if (!(entry instanceof JSONObject)) throw invalid();
            JSONObject cell = (JSONObject) entry;
            exact(cell, "row", "column", "text", "editable");
            if (integer(cell, "row") != index / columns || integer(cell, "column") != index % columns) throw invalid();
            string(cell, "text");
            bool(cell, "editable");
        }
        return cells.length();
    }

    private static void fields(JSONObject value, String... allowed) throws IOException {
        Set<String> names = new HashSet<>(Arrays.asList(allowed));
        Iterator<String> keys = value.keys();
        while (keys.hasNext()) if (!names.contains(keys.next())) throw invalid();
    }

    private static void exact(JSONObject value, String... names) throws IOException {
        if (value.length() != names.length) throw invalid();
        fields(value, names);
    }

    private static JSONObject object(JSONObject value, String key) throws IOException, JSONException {
        Object entry = value.get(key);
        if (!(entry instanceof JSONObject)) throw invalid();
        return (JSONObject) entry;
    }

    private static JSONArray array(JSONObject value, String key) throws IOException, JSONException {
        Object entry = value.get(key);
        if (!(entry instanceof JSONArray)) throw invalid();
        return (JSONArray) entry;
    }

    private static boolean bool(JSONObject value, String key) throws IOException, JSONException {
        Object entry = value.get(key);
        if (!(entry instanceof Boolean)) throw invalid();
        return (Boolean) entry;
    }

    private static int integer(JSONObject value, String key) throws IOException, JSONException {
        Object entry = value.get(key);
        if (!(entry instanceof Number)) throw invalid();
        double number = ((Number) entry).doubleValue();
        if (number < Integer.MIN_VALUE || number > Integer.MAX_VALUE || !Double.isFinite(number) || number != Math.rint(number)) throw invalid();
        return (int) number;
    }

    private static String string(JSONObject value, String key) throws IOException, JSONException {
        Object entry = value.get(key);
        if (!(entry instanceof String) || !unicode((String) entry)) throw invalid();
        return (String) entry;
    }

    private static boolean unicode(String text) {
        for (int index = 0; index < text.length(); index++) {
            char code = text.charAt(index);
            if (Character.isHighSurrogate(code)) {
                if (++index >= text.length() || !Character.isLowSurrogate(text.charAt(index))) return false;
            } else if (Character.isLowSurrogate(code)) return false;
        }
        return true;
    }

    private static String fileUrl(String value) throws IOException {
        if (value == null || value.length() > 8192 || !unicode(value) || !value.startsWith("file:/")) throw invalid();
        for (int index = 0; index < value.length(); index++) {
            char code = value.charAt(index);
            if (code <= 32 || code == 127 || code == '\\' || code == '?' || code == '#') throw invalid();
        }
        int path = 5;
        while (path < value.length() && value.charAt(path) == '/') path++;
        if (path == 7 || path == value.length()) throw invalid();
        String tail = value.substring(path);
        for (String segment : tail.split("/", -1)) if (segment.equals(".") || segment.equals("..")) throw invalid();
        return "file:///" + tail;
    }

    private static IOException invalid() { return new IOException("Invalid native cell reply"); }

    static void checkJson(String json) throws IOException { new JsonBounds(json).check(); }

    /** Bounds parsing before org.json, including its permissive Android implementation. */
    private static final class JsonBounds {
        private final String text;
        private int position;

        JsonBounds(String text) { this.text = text; }

        void check() throws IOException {
            value(0);
            whitespace();
            if (position != text.length()) throw invalid();
        }

        private void value(int depth) throws IOException {
            whitespace();
            char next = peek();
            if (next == '{' || next == '[') {
                if (depth >= 32) throw invalid();
                position++;
                boolean object = next == '{';
                char close = object ? '}' : ']';
                Set<String> keys = object ? new HashSet<>() : null;
                whitespace();
                if (take(close)) return;
                do {
                    whitespace();
                    if (object) {
                        if (peek() != '"' || !keys.add(quoted())) throw invalid();
                        whitespace();
                        if (!take(':')) throw invalid();
                    }
                    value(depth + 1);
                    whitespace();
                    if (take(close)) return;
                    if (!take(',')) throw invalid();
                } while (true);
            }
            if (next == '"') { quoted(); return; }
            for (String literal : new String[]{"true", "false", "null"}) {
                if (text.startsWith(literal, position)) { position += literal.length(); return; }
            }
            if (take('-') && position == text.length()) throw invalid();
            if (!take('0')) digits();
            if (take('.')) digits();
            if (take('e') || take('E')) { if (!take('+')) take('-'); digits(); }
        }

        private String quoted() throws IOException {
            if (!take('"')) throw invalid();
            StringBuilder value = new StringBuilder();
            while (position < text.length()) {
                char code = text.charAt(position++);
                if (code == '"') return value.toString();
                if (code < 32) throw invalid();
                if (code == '\\') {
                    if (position == text.length()) throw invalid();
                    code = text.charAt(position++);
                    if (code == 'u') {
                        if (position + 4 > text.length()) throw invalid();
                        int decoded = 0;
                        for (int digit = 0; digit < 4; digit++) {
                            char hex = text.charAt(position++);
                            int number = hex >= '0' && hex <= '9' ? hex - '0'
                                    : hex >= 'a' && hex <= 'f' ? hex - 'a' + 10 : hex >= 'A' && hex <= 'F' ? hex - 'A' + 10 : -1;
                            if (number < 0) throw invalid();
                            decoded = decoded * 16 + number;
                        }
                        code = (char) decoded;
                    } else {
                        int escape = "\"\\/bfnrt".indexOf(code);
                        if (escape < 0) throw invalid();
                        code = new char[]{'"', '\\', '/', '\b', '\f', '\n', '\r', '\t'}[escape];
                    }
                }
                value.append(code);
            }
            throw invalid();
        }

        private void digits() throws IOException {
            int start = position;
            while (position < text.length() && text.charAt(position) >= '0' && text.charAt(position) <= '9') position++;
            if (start == position) throw invalid();
        }

        private char peek() throws IOException {
            if (position == text.length()) throw invalid();
            return text.charAt(position);
        }

        private boolean take(char code) {
            if (position < text.length() && text.charAt(position) == code) { position++; return true; }
            return false;
        }

        private void whitespace() {
            while (position < text.length() && " \t\r\n".indexOf(text.charAt(position)) >= 0) position++;
        }
    }
}
