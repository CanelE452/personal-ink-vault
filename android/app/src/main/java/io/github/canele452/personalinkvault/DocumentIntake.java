package io.github.canele452.personalinkvault;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.text.Normalizer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.function.BooleanSupplier;
import java.util.regex.Pattern;

final class DocumentIntake {
    static final long MAX_FILE_BYTES = 128L * 1024 * 1024;
    static final int MAX_ENTRIES = 8;
    private static final Pattern OWNED_DIRECTORY = Pattern.compile(
            "([0-9]{19})_([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})");
    private static final Pattern WINDOWS_DEVICE = Pattern.compile("CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]");

    interface Source {
        InputStream open() throws IOException;
    }

    static final class SizeLimitExceeded extends IOException {
        SizeLimitExceeded() {
            super("Document size limit exceeded");
        }
    }

    private static final class Entry {
        final Path file;
        final long bytes;
        final boolean recovered;
        Object owner;
        boolean releasing;

        Entry(Path file, long bytes, boolean recovered) {
            this.file = file;
            this.bytes = bytes;
            this.recovered = recovered;
        }
    }

    private final Path root;
    private final long fileLimit;
    private final long inboxLimit;
    private final int entryLimit;
    private final LinkedHashMap<String, Entry> entries = new LinkedHashMap<>();
    private long stagedBytes;
    private long lastSequence;
    private boolean rootReady;

    DocumentIntake(File privateDirectory) {
        this(privateDirectory, MAX_FILE_BYTES, 2 * MAX_FILE_BYTES, MAX_ENTRIES);
    }

    DocumentIntake(File privateDirectory, long fileLimit, long inboxLimit, int entryLimit) {
        root = privateDirectory.toPath().toAbsolutePath().normalize().resolve("incoming-documents");
        this.fileLimit = fileLimit;
        this.inboxLimit = inboxLimit;
        this.entryLimit = entryLimit;
    }

    static String extensionForMime(String mime) {
        if (mime == null) return null;
        return switch (mime.toLowerCase(Locale.ROOT)) {
            case "application/pdf" -> "pdf";
            case "application/msword" -> "doc";
            case "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> "docx";
            case "application/vnd.ms-powerpoint" -> "ppt";
            case "application/vnd.openxmlformats-officedocument.presentationml.presentation" -> "pptx";
            case "application/vnd.oasis.opendocument.text" -> "odt";
            case "application/vnd.oasis.opendocument.presentation" -> "odp";
            case "application/x-hwp", "application/haansofthwp", "application/vnd.hancom.hwp" -> "hwp";
            case "application/hwp+zip", "application/x-hwpx", "application/vnd.hancom.hwpx" -> "hwpx";
            default -> null;
        };
    }

    private static boolean documentExtension(String extension) {
        return switch (extension) {
            case "pdf", "doc", "docx", "ppt", "pptx", "odt", "odp", "hwp", "hwpx" -> true;
            default -> false;
        };
    }

    static boolean genericMime(String mime) {
        return mime == null || mime.equalsIgnoreCase("application/octet-stream") || mime.equalsIgnoreCase("application/zip");
    }

    static String documentFormat(String offeredMime, String providerMime, String displayName) throws IOException {
        String offered = extensionForMime(offeredMime);
        String provided = extensionForMime(providerMime);
        if ((offered == null && !genericMime(offeredMime)) || (provided == null && !genericMime(providerMime)) ||
                (offered != null && provided != null && !offered.equals(provided))) {
            throw new IOException("Document type not supported or does not match provider");
        }
        String named = extensionOf(displayBasename(displayName));
        String extension = offered != null ? offered : provided != null ? provided : named;
        if (!documentExtension(extension) || (documentExtension(named) && !extension.equals(named))) {
            throw new IOException("Document type not supported or does not match name");
        }
        return extension;
    }

    static String fileName(String displayName, String extension) throws IOException {
        String basename = displayBasename(displayName);
        int dot = basename.lastIndexOf('.');
        if (dot >= 0) {
            String suffix = basename.substring(dot + 1).toLowerCase(Locale.ROOT);
            if (documentExtension(suffix)) {
                if (!extension.equals(suffix)) throw new IOException("Document type and name disagree");
                basename = basename.substring(0, dot);
            }
        }

        StringBuilder safe = new StringBuilder();
        for (int offset = 0, count = 0; offset < basename.length() && count < 60; count++) {
            int ch = basename.codePointAt(offset);
            offset += Character.charCount(ch);
            int type = Character.getType(ch);
            if (Character.isISOControl(ch) || type == Character.FORMAT || type == Character.SURROGATE ||
                    "<>:\"/\\|?*".indexOf(ch) >= 0) ch = '_';
            safe.appendCodePoint(ch);
        }
        String stem = trimFileName(safe.toString());
        int firstDot = stem.indexOf('.');
        String device = firstDot < 0 ? stem : trimFileName(stem.substring(0, firstDot));
        if (stem.isEmpty() || WINDOWS_DEVICE.matcher(device.toUpperCase(Locale.ROOT)).matches()) stem = "문서";
        return stem + "." + extension;
    }

    private static String displayBasename(String name) {
        String basename = name == null ? "" : name.replace('\\', '/');
        return trimFileName(Normalizer.normalize(basename.substring(basename.lastIndexOf('/') + 1), Normalizer.Form.NFC));
    }

    private static String extensionOf(String name) {
        int dot = name.lastIndexOf('.');
        return dot < 0 ? "" : name.substring(dot + 1).toLowerCase(Locale.ROOT);
    }

    private static String trimFileName(String value) {
        int start = 0;
        int end = value.length();
        while (start < end && (value.charAt(start) == '.' || Character.isWhitespace(value.charAt(start)))) start++;
        while (end > start && (value.charAt(end - 1) == '.' || Character.isWhitespace(value.charAt(end - 1)))) end--;
        return value.substring(start, end);
    }

    // Discovery and staging share one worker. Claims are short operations on the in-memory index.
    void stage(String extension, String displayName, Source source) throws IOException {
        if (!documentExtension(extension)) throw new IOException("Unsupported document type");
        restore();
        String name = fileName(displayName, extension);
        long limit;
        synchronized (entries) {
            limit = Math.min(fileLimit, inboxLimit - stagedBytes);
            if (entries.size() >= entryLimit || limit <= 0) throw new IOException("Document inbox is full");
        }

        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS) || lastSequence == Long.MAX_VALUE) {
            throw new IOException("Invalid document spool");
        }
        String id = UUID.randomUUID().toString();
        Path directory = Files.createDirectory(root.resolve(String.format(Locale.ROOT, "%019d_%s", ++lastSequence, id)));
        Path partial = directory.resolve(".part");
        Path file = directory.resolve(name);
        boolean published = false;
        try {
            Files.createFile(partial);
            long bytes = copyBounded(partial, limit, source, () -> false);
            Files.move(partial, file, StandardCopyOption.ATOMIC_MOVE);
            published = true;
            synchronized (entries) {
                entries.put(id, new Entry(file, bytes, false));
                stagedBytes += bytes;
            }
        } finally {
            if (!published) {
                partial.toFile().delete();
                directory.toFile().delete();
            }
        }
    }

    static long copyBounded(Path destination, long limit, Source source, BooleanSupplier cancelled) throws IOException {
        if (cancelled.getAsBoolean()) throw new InterruptedIOException("Document copy cancelled");
        long bytes = 0;
        try (InputStream input = source.open()) {
            if (input == null) throw new IOException("Document provider returned no stream");
            try (FileOutputStream output = new FileOutputStream(destination.toFile())) {
                byte[] buffer = new byte[64 * 1024];
                while (!cancelled.getAsBoolean()) {
                    long remaining = limit - bytes;
                    // Read at most one byte beyond the limit to distinguish exact-size input from overflow.
                    int requested = remaining >= buffer.length ? buffer.length : (int) remaining + 1;
                    int count = input.read(buffer, 0, requested);
                    if (cancelled.getAsBoolean()) break;
                    if (count == -1) {
                        if (bytes == 0) throw new IOException("Empty document");
                        output.getFD().sync();
                        return bytes;
                    }
                    if (count <= 0 || count > requested) throw new IOException("Invalid provider stream read");
                    if (count > remaining) throw new SizeLimitExceeded();
                    output.write(buffer, 0, count);
                    bytes += count;
                }
            }
        }
        throw new InterruptedIOException("Document copy cancelled");
    }

    List<Map<String, Object>> claim(Object owner) {
        synchronized (entries) {
            List<Map<String, Object>> records = new ArrayList<>(entries.size());
            for (Map.Entry<String, Entry> entry : entries.entrySet()) {
                Entry document = entry.getValue();
                if (document.releasing || (document.owner != null && document.owner != owner)) continue;
                document.owner = owner;
                Map<String, Object> payload = new HashMap<>();
                payload.put("id", entry.getKey());
                payload.put("path", document.file.toString());
                if (document.recovered) payload.put("recovered", true);
                records.add(payload);
            }
            return records;
        }
    }

    void abandon(Object owner) {
        synchronized (entries) {
            for (Entry entry : entries.values()) {
                if (entry.owner == owner) entry.owner = null;
            }
        }
    }

    boolean beginRelease(Object owner, String id) {
        synchronized (entries) {
            Entry entry = entries.get(id);
            if (entry == null || entry.owner != owner || entry.releasing) return false;
            entry.releasing = true;
            return true;
        }
    }

    void release(String id) throws IOException {
        Entry entry;
        synchronized (entries) {
            entry = entries.get(id);
            if (entry == null || !entry.releasing) return;
        }
        Path directory = entry.file.getParent();
        try {
            if (Files.isSymbolicLink(root) || Files.isSymbolicLink(directory)) throw new IOException("Invalid staging path");
            Files.deleteIfExists(entry.file);
            directory.toFile().delete();
        } catch (IOException | RuntimeException failure) {
            synchronized (entries) {
                entry.releasing = false;
            }
            throw failure;
        }
        synchronized (entries) {
            entries.remove(id);
            stagedBytes -= entry.bytes;
        }
    }

    void restore() throws IOException {
        if (rootReady) return;
        Files.createDirectories(root);
        if (!Files.isDirectory(root, LinkOption.NOFOLLOW_LINKS)) throw new IOException("Invalid staging root");
        File[] directories = root.toFile().listFiles();
        if (directories == null) throw new IOException("Could not list document spool");
        java.util.Arrays.sort(directories, java.util.Comparator.comparing(File::getName));
        LinkedHashMap<String, Entry> recovered = new LinkedHashMap<>();
        long recoveredBytes = 0;
        for (File directory : directories) {
            var match = OWNED_DIRECTORY.matcher(directory.getName());
            if (!match.matches() || !Files.isDirectory(directory.toPath(), LinkOption.NOFOLLOW_LINKS)) continue;
            long sequence;
            try {
                sequence = Long.parseLong(match.group(1));
            } catch (NumberFormatException ignored) {
                continue;
            }
            lastSequence = Math.max(lastSequence, sequence);
            Path partial = directory.toPath().resolve(".part");
            if (Files.isRegularFile(partial, LinkOption.NOFOLLOW_LINKS)) Files.deleteIfExists(partial);
            File[] children = directory.listFiles();
            if (children == null) continue;
            if (children.length == 0) directory.delete();
            if (children.length != 1 || recovered.size() >= entryLimit) continue;
            File ready = children[0];
            String extension = extensionOf(ready.getName());
            if (!documentExtension(extension) || !ready.getName().equals(fileName(ready.getName(), extension)) ||
                    !Files.isRegularFile(ready.toPath(), LinkOption.NOFOLLOW_LINKS)) continue;
            long bytes = Files.size(ready.toPath());
            if (bytes == 0 || bytes > fileLimit || bytes > inboxLimit - recoveredBytes) continue;
            if (recovered.putIfAbsent(match.group(2), new Entry(ready.toPath(), bytes, true)) == null) recoveredBytes += bytes;
        }
        synchronized (entries) {
            entries.putAll(recovered);
            stagedBytes = recoveredBytes;
        }
        rootReady = true;
    }
}
