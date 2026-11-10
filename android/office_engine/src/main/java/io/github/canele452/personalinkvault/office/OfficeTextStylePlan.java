package io.github.canele452.personalinkvault.office;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;

/** Validates bounded Rust planner output against the exact original and draft. */
public final class OfficeTextStylePlan {
    private OfficeTextStylePlan() { }

    static byte[] encodeText(String text, int maximum) throws IOException {
        if (text == null || text.length() > maximum) throw invalid();
        int paragraphs = 1;
        for (int index = 0; index < text.length(); index++) {
            char code = text.charAt(index);
            if (code == '\n' && ++paragraphs > 512) throw invalid();
            if (Character.isHighSurrogate(code)) {
                if (++index >= text.length() || !Character.isLowSurrogate(text.charAt(index))) throw invalid();
            } else if (Character.isLowSurrogate(code)) throw invalid();
        }
        return text.getBytes(StandardCharsets.UTF_8);
    }

    public static JSONObject decode(byte[] bytes, String oldText, String newText) throws IOException {
        byte[] oldUtf8 = encodeText(oldText, 200000), newUtf8 = encodeText(newText, 8192);
        if (bytes == null || bytes.length == 0 || bytes.length > 1024 * 1024) throw invalid();
        try {
            String json = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
            OfficeCellReply.checkJson(json);
            JSONObject plan = new JSONObject(json);
            exact(plan, "protocol", "oldUtf16Length", "newUtf16Length", "oldSha256", "newSha256", "paragraphs");
            if (!"piv-text-style-map-1".equals(string(plan, "protocol"))
                    || integer(plan, "oldUtf16Length") != oldText.length()
                    || integer(plan, "newUtf16Length") != newText.length()
                    || !sha256(oldUtf8).equals(string(plan, "oldSha256"))
                    || !sha256(newUtf8).equals(string(plan, "newSha256"))) throw invalid();
            String[] oldParagraphs = oldText.split("\n", -1), newParagraphs = newText.split("\n", -1);
            JSONArray paragraphs = array(plan, "paragraphs");
            if (paragraphs.length() != newParagraphs.length) throw invalid();
            for (int index = 0; index < paragraphs.length(); index++) {
                JSONObject paragraph = object(paragraphs.get(index));
                exact(paragraph, "sourceParagraph", "segments");
                int source = integer(paragraph, "sourceParagraph");
                if (source < 0 || source >= oldParagraphs.length) throw invalid();
                String oldLine = oldParagraphs[source], newLine = newParagraphs[index];
                JSONArray segments = array(paragraph, "segments");
                if (segments.length() == 0 || segments.length() > Math.max(1, newLine.length())) throw invalid();
                int covered = 0;
                for (int segmentIndex = 0; segmentIndex < segments.length(); segmentIndex++) {
                    JSONObject segment = object(segments.get(segmentIndex));
                    exact(segment, "kind", "newStart", "newEnd", "oldStart", "oldEnd");
                    String kind = string(segment, "kind");
                    int start = integer(segment, "newStart"), end = integer(segment, "newEnd");
                    int oldStart = integer(segment, "oldStart"), oldEnd = integer(segment, "oldEnd");
                    if (start != covered || end < start || end > newLine.length()
                            || oldStart < 0 || oldEnd < oldStart || oldEnd > oldLine.length()
                            || !boundary(newLine, start) || !boundary(newLine, end)
                            || !boundary(oldLine, oldStart) || !boundary(oldLine, oldEnd)) throw invalid();
                    if (newLine.isEmpty()) {
                        if (segments.length() != 1 || start != 0 || end != 0 || !"inherit".equals(kind)) throw invalid();
                    } else if (end == start) throw invalid();
                    if ("retain".equals(kind)) {
                        if (end - start != oldEnd - oldStart
                                || !newLine.regionMatches(start, oldLine, oldStart, end - start)) throw invalid();
                    } else if ("inherit".equals(kind)) {
                        if (oldLine.isEmpty() ? oldStart != 0 || oldEnd != 0 : oldStart == oldEnd) throw invalid();
                    } else throw invalid();
                    covered = end;
                }
                if (covered != newLine.length()) throw invalid();
            }
            return plan;
        } catch (JSONException error) {
            throw new IOException("Invalid native text style plan", error);
        }
    }

    private static boolean boundary(String text, int offset) {
        return offset >= 0 && offset <= text.length()
                && !(offset > 0 && offset < text.length() && Character.isHighSurrogate(text.charAt(offset - 1))
                && Character.isLowSurrogate(text.charAt(offset)));
    }

    private static String sha256(byte[] bytes) throws IOException {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            StringBuilder result = new StringBuilder(64);
            for (byte code : digest) {
                result.append(Character.forDigit((code & 255) >>> 4, 16));
                result.append(Character.forDigit(code & 15, 16));
            }
            return result.toString();
        } catch (NoSuchAlgorithmException error) { throw new IOException("SHA-256 unavailable", error); }
    }

    private static void exact(JSONObject object, String... names) throws IOException {
        if (object.length() != names.length) throw invalid();
        Set<String> allowed = new HashSet<>(Arrays.asList(names));
        Iterator<String> keys = object.keys();
        while (keys.hasNext()) if (!allowed.contains(keys.next())) throw invalid();
    }

    private static JSONObject object(Object value) throws IOException {
        if (!(value instanceof JSONObject)) throw invalid();
        return (JSONObject) value;
    }

    private static JSONArray array(JSONObject object, String key) throws JSONException, IOException {
        Object value = object.get(key);
        if (!(value instanceof JSONArray)) throw invalid();
        return (JSONArray) value;
    }

    private static int integer(JSONObject object, String key) throws JSONException, IOException {
        Object value = object.get(key);
        if (!(value instanceof Integer) && !(value instanceof Long)) throw invalid();
        long number = ((Number) value).longValue();
        if (number < Integer.MIN_VALUE || number > Integer.MAX_VALUE) throw invalid();
        return (int) number;
    }

    private static String string(JSONObject object, String key) throws JSONException, IOException {
        Object value = object.get(key);
        if (!(value instanceof String)) throw invalid();
        return (String) value;
    }

    private static IOException invalid() { return new IOException("Invalid native text style plan"); }
}
