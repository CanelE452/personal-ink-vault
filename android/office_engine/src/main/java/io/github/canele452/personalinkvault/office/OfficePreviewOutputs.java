package io.github.canele452.personalinkvault.office;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;

/** Ownership of this bridge's temporary, read-only conversions only. */
public final class OfficePreviewOutputs {
    static final String RESULT_RECORD = "preview-result.properties";
    private static final long MAX_RECORD_BYTES = 4096;
    private final Path root;
    private final Map<String, Output> outputs = new HashMap<>();

    private static final class Output {
        final Path directory;
        boolean ready;
        Output(Path directory) { this.directory = directory; }
    }

    interface Cleanup {
        void run() throws IOException;
    }

    public OfficePreviewOutputs(File root) {
        this.root = root.toPath().toAbsolutePath().normalize();
    }

    public static File requireSessionDirectory(File filesDirectory, String directoryPath, boolean previewOnly) throws IOException {
        File allowed = new File(filesDirectory, previewOnly ? "office-previews" : "office-sessions");
        File requested = new File(directoryPath).getAbsoluteFile();
        if (!Files.isDirectory(allowed.toPath(), LinkOption.NOFOLLOW_LINKS)
                || !Files.isDirectory(requested.toPath(), LinkOption.NOFOLLOW_LINKS)
                || Files.isSymbolicLink(allowed.toPath()) || Files.isSymbolicLink(requested.toPath())) {
            throw new IOException("Invalid private session directory");
        }
        File directory = requested.getCanonicalFile();
        if (!allowed.getCanonicalFile().equals(directory.getParentFile())) {
            throw new IOException("Invalid private session parent");
        }
        return directory;
    }

    public synchronized File create(String sessionId) throws IOException {
        if (sessionId == null || sessionId.trim().isEmpty() || outputs.containsKey(sessionId)) {
            throw new IOException("Invalid or already owned preview session");
        }
        if (!Files.exists(root, LinkOption.NOFOLLOW_LINKS)) Files.createDirectory(root);
        Path directory = Files.createTempDirectory(requireRoot(), "preview-");
        outputs.put(sessionId, new Output(directory));
        return directory.toFile();
    }

    public synchronized File complete(String sessionId, String pdfPath) throws IOException {
        return complete(sessionId, pdfPath, "preview.pdf");
    }

    static String legacyTarget(String sourceFormat) {
        if ("doc".equals(sourceFormat)) return "docx";
        if ("ppt".equals(sourceFormat)) return "pptx";
        return null;
    }

    static File conversionInput(File cacheDirectory, String sourcePath, String format) throws IOException {
        if (sourcePath == null || legacyTarget(format) == null) throw new IOException("Invalid conversion source");
        Path path = new File(sourcePath).toPath();
        Path parent = path.getParent();
        Path cache = cacheDirectory.toPath().toAbsolutePath();
        String prefix = "piv-office-legacy-copy-";
        if (!path.isAbsolute() || !path.equals(path.normalize()) || parent == null
                || !cache.equals(parent.getParent()) || !parent.getFileName().toString().startsWith(prefix)
                || parent.getFileName().toString().length() == prefix.length()
                || !("source." + format).equals(path.getFileName().toString())
                || !Files.isDirectory(cache, LinkOption.NOFOLLOW_LINKS)
                || !Files.isDirectory(parent, LinkOption.NOFOLLOW_LINKS)
                || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("Invalid private conversion source");
        }
        return path.toFile();
    }

    public synchronized File completeConversion(String sessionId, String path, String sourceFormat) throws IOException {
        String target = legacyTarget(sourceFormat);
        if (target == null) throw new IOException("Invalid conversion format");
        return complete(sessionId, path, "converted." + target);
    }

    private File complete(String sessionId, String path, String outputName) throws IOException {
        Output output = outputs.get(sessionId);
        if (output == null || path == null) throw new IOException("Unknown preview output");
        requireDirectory(output.directory);
        Path expected = output.directory.resolve(outputName);
        if (!expected.equals(new File(path).toPath().toAbsolutePath().normalize())
                || !Files.isRegularFile(expected, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("Result does not match the owned output");
        }
        output.ready = true;
        return expected.toFile();
    }

    /**
     * Engine process: records a verified preview PDF next to it, so the main process can still accept
     * it if the engine process dies before its Activity result is delivered.
     */
    static void writeResultRecord(File directory, String sessionId, String sourceSha256, String pdfSha256,
            int pageCount) throws IOException {
        Properties record = new Properties();
        record.setProperty("version", "1");
        record.setProperty("sessionId", sessionId);
        record.setProperty("sourceSha256", sourceSha256);
        record.setProperty("pdfSha256", pdfSha256);
        record.setProperty("pdfPageCount", Integer.toString(pageCount));
        Path temporary = Files.createTempFile(directory.toPath(), "preview-result-", ".tmp");
        try {
            try (OutputStream output = Files.newOutputStream(temporary)) {
                record.store(output, null);
            }
            Files.move(temporary, directory.toPath().resolve(RESULT_RECORD),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(temporary);
        }
    }

    /** Engine process: a cancelled preview must never be accepted from its record. */
    static void deleteResultRecord(File directory) {
        if (directory == null) return;
        try {
            Files.deleteIfExists(directory.toPath().resolve(RESULT_RECORD));
        } catch (IOException ignored) {
            // The main process accepts a record only for a result without data, never after a cancel result.
        }
    }

    /** Main process, after the engine process is gone: the recorded preview PDF if it still verifies. */
    public synchronized Map<String, Object> rescuedResult(String sessionId) throws IOException {
        Output output = outputs.get(sessionId);
        if (output == null) throw new IOException("Unknown preview output");
        requireDirectory(output.directory);
        Path recordPath = output.directory.resolve(RESULT_RECORD);
        if (!Files.isRegularFile(recordPath, LinkOption.NOFOLLOW_LINKS) || Files.size(recordPath) > MAX_RECORD_BYTES) {
            throw new IOException("Missing preview result record");
        }
        Properties record = new Properties();
        try (InputStream input = Files.newInputStream(recordPath, LinkOption.NOFOLLOW_LINKS)) {
            record.load(input);
        }
        String sourceSha256 = record.getProperty("sourceSha256", "");
        String pdfSha256 = record.getProperty("pdfSha256", "");
        int pageCount;
        try {
            pageCount = Integer.parseInt(record.getProperty("pdfPageCount", ""));
        } catch (NumberFormatException error) {
            throw new IOException("Invalid preview result record", error);
        }
        if (!"1".equals(record.getProperty("version")) || !sessionId.equals(record.getProperty("sessionId"))
                || pageCount < 1 || !sourceSha256.matches("[0-9a-f]{64}") || !pdfSha256.matches("[0-9a-f]{64}")) {
            throw new IOException("Invalid preview result record");
        }
        File pdf = complete(sessionId, output.directory.resolve("preview.pdf").toString(), "preview.pdf");
        if (!pdfSha256.equals(sha256(pdf.toPath()))) {
            throw new IOException("Preview result record does not match its PDF");
        }
        Map<String, Object> result = new HashMap<>();
        result.put("status", "previewed");
        result.put("sessionId", sessionId);
        result.put("pdfPath", pdf.getPath());
        result.put("sourceSha256", sourceSha256);
        result.put("pdfSha256", pdfSha256);
        result.put("pdfPageCount", pageCount);
        return result;
    }

    private static String sha256(Path file) throws IOException {
        java.security.MessageDigest digest;
        try {
            digest = java.security.MessageDigest.getInstance("SHA-256");
        } catch (java.security.NoSuchAlgorithmException error) {
            throw new IOException("SHA-256 is unavailable", error);
        }
        try (InputStream input = Files.newInputStream(file, LinkOption.NOFOLLOW_LINKS)) {
            byte[] block = new byte[65536];
            int count;
            while ((count = input.read(block)) != -1) digest.update(block, 0, count);
        }
        StringBuilder hex = new StringBuilder();
        for (byte value : digest.digest()) hex.append(String.format("%02x", value & 255));
        return hex.toString();
    }

    public synchronized void release(String sessionId) throws IOException {
        cleanup(sessionId, false).run();
    }

    public synchronized void discard(String sessionId) throws IOException {
        cleanup(sessionId, true).run();
    }

    synchronized Cleanup cleanup(String sessionId, boolean discard) {
        Output output = outputs.get(sessionId);
        if (output == null || (!discard && !output.ready)) return () -> {};
        return () -> remove(sessionId, output);
    }

    private synchronized void remove(String sessionId, Output output) throws IOException {
        if (outputs.get(sessionId) != output) return;
        outputs.remove(sessionId);
        deleteOwned(output);
    }

    private Path requireRoot() throws IOException {
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(root)) {
            throw new IOException("Preview root is not a private regular directory");
        }
        // The Activity validates the canonical path even if Android supplies an aliased files directory.
        return root.toFile().getCanonicalFile().toPath();
    }

    private void requireDirectory(Path directory) throws IOException {
        if (!requireRoot().equals(directory.getParent())
                || !Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)
                || Files.isSymbolicLink(directory)) {
            throw new IOException("Preview directory ownership changed");
        }
    }

    private void deleteOwned(Output output) throws IOException {
        requireDirectory(output.directory);
        List<Path> children = new ArrayList<>();
        try (DirectoryStream<Path> entries = Files.newDirectoryStream(output.directory)) {
            for (Path child : entries) {
                if (!Files.isRegularFile(child, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(child)) {
                    throw new IOException("Refusing a non-regular preview child");
                }
                children.add(child);
            }
        }
        for (Path child : children) Files.delete(child);
        Files.delete(output.directory);
    }
}
