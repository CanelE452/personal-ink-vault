package io.github.canele452.personalinkvault.office;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/** Private read-only native bytes; JSON interpretation and permissions belong to the caller. */
public final class OfficeNativeObservation {
    public static final int MAX_BYTES = 128 * 1024;
    public static final int MAX_PARTS = 256;
    private static final int MAX_MARKER_BYTES = 4096;
    private static final String PAYLOAD = "native-observation.json";
    private static final String MARKER = "native-observation.properties";
    private static final String[] FIELDS = {"version", "sessionId", "inputSourceSha256",
            "format", "engineVersion", "partCount", "byteLength", "sha256"};
    private static final Pattern ID = Pattern.compile("[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}");
    private static final Pattern HASH = Pattern.compile("[0-9a-f]{64}");
    private static final Pattern VERSION = Pattern.compile("[0-9A-Za-z_.+\\-]{1,80}");

    private OfficeNativeObservation() {}

    public static Map<String, Object> write(File directory, String sessionId, String inputSourceSha256,
            String format, String engineVersion, int partCount, byte[] nativeJson) throws IOException {
        validateBinding(sessionId, inputSourceSha256, format, engineVersion);
        if (partCount < 1 || partCount > MAX_PARTS) throw invalid();
        if (nativeJson == null || nativeJson.length == 0 || nativeJson.length > MAX_BYTES) {
            throw new IOException("office_native_observation_too_large");
        }
        byte[] bytes = Arrays.copyOf(nativeJson, nativeJson.length);
        utf8(bytes);
        Path parent = requireDirectory(directory);
        Path payload = parent.resolve(PAYLOAD);
        Path marker = parent.resolve(MARKER);
        if (Files.exists(payload, LinkOption.NOFOLLOW_LINKS)
                || Files.exists(marker, LinkOption.NOFOLLOW_LINKS)) throw invalid();
        Map<String, String> values = new LinkedHashMap<>();
        values.put("version", "1");
        values.put("sessionId", sessionId);
        values.put("inputSourceSha256", inputSourceSha256);
        values.put("format", format);
        values.put("engineVersion", engineVersion);
        values.put("partCount", Integer.toString(partCount));
        values.put("byteLength", Integer.toString(bytes.length));
        values.put("sha256", digest(bytes));
        StringBuilder text = new StringBuilder();
        for (String key : FIELDS) text.append(key).append('=').append(values.get(key)).append('\n');
        Files.write(payload, bytes, StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
        Files.write(marker, text.toString().getBytes(StandardCharsets.UTF_8),
                StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE);
        return read(directory, sessionId, inputSourceSha256, format, engineVersion);
    }

    public static Map<String, Object> read(File directory, String sessionId, String inputSourceSha256,
            String format, String engineVersion) throws IOException {
        validateBinding(sessionId, inputSourceSha256, format, engineVersion);
        Path parent = requireDirectory(directory);
        Map<String, String> values = marker(bounded(parent.resolve(MARKER), MAX_MARKER_BYTES));
        if (!"1".equals(values.get("version")) || !sessionId.equals(values.get("sessionId"))
                || !inputSourceSha256.equals(values.get("inputSourceSha256"))
                || !format.equals(values.get("format")) || !engineVersion.equals(values.get("engineVersion"))
                || !HASH.matcher(values.get("sha256")).matches()) throw invalid();
        int parts = integer(values.get("partCount"), MAX_PARTS);
        int length = integer(values.get("byteLength"), MAX_BYTES);
        byte[] bytes = bounded(parent.resolve(PAYLOAD), MAX_BYTES);
        if (bytes.length != length || !digest(bytes).equals(values.get("sha256"))) throw invalid();
        String json = utf8(bytes);
        Map<String, Object> result = new HashMap<>();
        result.put("sessionId", sessionId);
        result.put("sourceSha256", inputSourceSha256);
        result.put("format", format);
        result.put("engineVersion", engineVersion);
        result.put("partCount", parts);
        result.put("observationPath", parent.resolve(PAYLOAD).toString());
        result.put("observationSha256", values.get("sha256"));
        result.put("observationByteLength", bytes.length);
        result.put("nativeJson", json);
        return result;
    }

    public static String sourceSha256(File file) throws IOException {
        Path path = file.toPath();
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path)
                || Files.size(path) < 1 || Files.size(path) > 128L * 1024 * 1024) throw invalid();
        MessageDigest digest = sha256();
        long length = 0;
        try (InputStream input = Files.newInputStream(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
            byte[] buffer = new byte[65536];
            int count;
            while ((count = input.read(buffer)) != -1) {
                length += count;
                if (length > 128L * 1024 * 1024) throw invalid();
                digest.update(buffer, 0, count);
            }
        }
        return hex(digest.digest());
    }

    public static String errorCode(Exception error) {
        String code = error.getMessage();
        if ("office_native_observation_unavailable".equals(code)
                || "office_native_observation_unsupported".equals(code)
                || "office_native_observation_too_large".equals(code)) return code;
        return "invalid_office_observation";
    }

    private static void validateBinding(String sessionId, String source, String format, String version) throws IOException {
        if (sessionId == null || !ID.matcher(sessionId).matches()
                || source == null || !HASH.matcher(source).matches()
                || !("ppt".equals(format) || "pptx".equals(format) || "odp".equals(format))
                || version == null || !VERSION.matcher(version).matches()) throw invalid();
    }

    private static Path requireDirectory(File directory) throws IOException {
        Path path = directory.toPath().toAbsolutePath().normalize();
        if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path)
                || !path.equals(directory.getCanonicalFile().toPath())) throw invalid();
        return path;
    }

    private static byte[] bounded(Path path, int maximum) throws IOException {
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path)
                || Files.size(path) < 1 || Files.size(path) > maximum) throw invalid();
        try (InputStream input = Files.newInputStream(path, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (output.size() > maximum - count) throw invalid();
                output.write(buffer, 0, count);
            }
            if (output.size() == 0) throw invalid();
            return output.toByteArray();
        }
    }

    private static String utf8(byte[] bytes) throws IOException {
        try {
            return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString();
        } catch (CharacterCodingException error) {
            throw invalid();
        }
    }

    private static Map<String, String> marker(byte[] bytes) throws IOException {
        Map<String, String> values = new HashMap<>();
        Set<String> expected = new HashSet<>(Arrays.asList(FIELDS));
        for (String raw : utf8(bytes).split("\n", -1)) {
            String line = raw.endsWith("\r") ? raw.substring(0, raw.length() - 1) : raw;
            if (line.isEmpty() || line.startsWith("#") || line.startsWith("!")) continue;
            int separator = line.indexOf('=');
            if (separator < 1) throw invalid();
            String key = line.substring(0, separator), value = line.substring(separator + 1);
            if (!expected.contains(key) || values.put(key, value) != null) throw invalid();
        }
        if (!values.keySet().equals(expected)) throw invalid();
        return values;
    }

    private static int integer(String value, int maximum) throws IOException {
        if (value == null || !value.matches("[1-9][0-9]{0,8}")) throw invalid();
        try {
            int number = Integer.parseInt(value);
            if (number > maximum) throw invalid();
            return number;
        } catch (NumberFormatException error) {
            throw invalid();
        }
    }

    private static MessageDigest sha256() throws IOException {
        try { return MessageDigest.getInstance("SHA-256"); }
        catch (NoSuchAlgorithmException error) { throw new IOException(error); }
    }

    private static String digest(byte[] bytes) throws IOException {
        return hex(sha256().digest(bytes));
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) result.append(String.format("%02x", value & 255));
        return result.toString();
    }

    private static IOException invalid() { return new IOException("invalid_office_observation"); }
}
