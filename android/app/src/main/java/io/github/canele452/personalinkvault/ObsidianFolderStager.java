package io.github.canele452.personalinkvault;

import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.function.BooleanSupplier;

final class ObsidianFolderStager {
    private static final long MIB = 1024L * 1024;
    static final int MAX_ENTRIES = 10000;
    private static final int MAX_DEPTH = 64;
    private static final long MAX_MARKDOWN = 128 * MIB;
    private static final long MAX_ATTACHMENTS = 192 * MIB;

    static final class InvalidFolder extends IOException {
        InvalidFolder(String message) {
            super(message);
        }
    }

    static final class Entry {
        final String id;
        final String name;
        final boolean directory;

        Entry(String id, String name, boolean directory) {
            this.id = id;
            this.name = name;
            this.directory = directory;
        }
    }

    interface Tree {
        void children(String directoryId, ChildVisitor visitor) throws IOException;
        InputStream open(String fileId) throws IOException;
    }

    interface ChildVisitor {
        void accept(Entry entry) throws IOException;
    }

    private final Tree source;
    private final BooleanSupplier cancelled;
    private final Set<String> directories = new HashSet<>();
    private int entries;
    private long markdownBytes;
    private long attachmentBytes;

    private ObsidianFolderStager(Tree source, BooleanSupplier cancelled) {
        this.source = source;
        this.cancelled = cancelled;
    }

    static void stage(Tree source, String rootId, Path destination, BooleanSupplier cancelled)
            throws IOException {
        ObsidianFolderStager stager = new ObsidianFolderStager(source, cancelled);
        stager.checkCancelled();
        Files.createDirectory(destination);
        try {
            stager.directories.add(rootId);
            stager.copyChildren(rootId, destination, 0, false);
            stager.checkCancelled();
        } catch (IOException | RuntimeException failure) {
            try {
                remove(destination);
            } catch (IOException cleanup) {
                failure.addSuppressed(cleanup);
            }
            throw failure;
        }
    }

    private void copyChildren(String id, Path destination, int depth, boolean settings)
            throws IOException {
        checkCancelled();
        // Close the provider cursor before opening another directory or file stream.
        List<Entry> children = new ArrayList<>();
        source.children(id, entry -> {
            checkCancelled();
            if (++entries > MAX_ENTRIES) {
                throw new InvalidFolder("보관함은 최대 10,000개 항목까지 가져올 수 있습니다.");
            }
            children.add(entry);
        });
        Set<String> names = new HashSet<>();
        for (Entry entry : children) {
            checkCancelled();
            String name = entry.name;
            if (name == null || name.isEmpty() || !validName(name)) throw invalidPath();
            boolean settingsFolder = depth == 0 && entry.directory && name.equals(".obsidian");
            if (settings) {
                if (entry.directory || !(name.equals("bookmarks.json") || name.equals("templates.json"))) continue;
            } else if (name.startsWith(".") && !settingsFolder) {
                continue;
            }
            if (entry.id == null || entry.id.isEmpty() || !names.add(name)) {
                throw invalidPath();
            }
            Path target = destination.resolve(name);
            if (entry.directory) {
                if (depth >= MAX_DEPTH) throw new InvalidFolder("보관함 폴더 깊이는 최대 64단계입니다.");
                if (!directories.add(entry.id)) throw invalidPath();
                Files.createDirectory(target);
                copyChildren(entry.id, target, depth + 1, settingsFolder);
            } else {
                copyFile(entry, target, settings);
            }
        }
    }

    private void copyFile(Entry entry, Path target, boolean settings) throws IOException {
        String name = entry.name.toLowerCase(Locale.ROOT);
        boolean markdown = !settings && name.endsWith(".md");
        long limit = settings ? (name.equals("bookmarks.json") ? 256 * 1024 : 16 * 1024)
                : markdown ? Math.min(8 * MIB, MAX_MARKDOWN - markdownBytes)
                : switch (extension(name)) {
                    case "canvas" -> Math.min(8 * MIB, MAX_ATTACHMENTS - attachmentBytes);
                    case "pdf", "png", "jpg", "jpeg", "webp", "doc", "docx", "odt", "ppt", "pptx",
                         "odp", "hwp", "hwpx" -> Math.min(64 * MIB, MAX_ATTACHMENTS - attachmentBytes);
                    default -> -1;
                };
        Files.createFile(target);
        if (limit < 0) return; // The importer counts skipped files without opening their data.
        try {
            long bytes = DocumentIntake.copyBounded(target, limit, () -> source.open(entry.id), cancelled, true);
            if (markdown) markdownBytes += bytes;
            else if (!settings) attachmentBytes += bytes;
        } catch (DocumentIntake.SizeLimitExceeded error) {
            if (!settings) throw error;
            // The importer will report an unreadable setting without blocking its notes.
            Files.delete(target);
            Files.createDirectory(target);
        }
    }

    private void checkCancelled() throws InterruptedIOException {
        if (cancelled.getAsBoolean()) throw new InterruptedIOException("Folder import cancelled");
    }

    private static String extension(String name) {
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(dot + 1) : "";
    }

    private static boolean validName(String name) {
        return !name.equals(".") && !name.equals("..") && name.length() <= 255 &&
                name.getBytes(StandardCharsets.UTF_8).length <= 255 &&
                name.chars().noneMatch(ch -> Character.isISOControl(ch) || "<>:\"/\\|?*".indexOf(ch) >= 0);
    }

    private static InvalidFolder invalidPath() {
        return new InvalidFolder("보관함에 중복되거나 사용할 수 없는 파일 경로가 있습니다.");
    }

    static void remove(Path path) throws IOException {
        if (Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
            try (DirectoryStream<Path> children = Files.newDirectoryStream(path)) {
                for (Path child : children) remove(child);
            }
        }
        Files.deleteIfExists(path);
    }
}
