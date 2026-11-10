package io.github.canele452.personalinkvault.office;

import java.io.File;
import java.io.IOException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Ownership of this bridge's temporary, read-only conversions only. */
public final class OfficePreviewOutputs {
    private final Path root;
    private final Map<String, Output> outputs = new HashMap<>();

    private static final class Output {
        final Path directory;
        boolean ready;
        Output(Path directory) { this.directory = directory; }
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

    public synchronized void release(String sessionId) throws IOException {
        Output output = outputs.get(sessionId);
        if (output == null || !output.ready) return;
        outputs.remove(sessionId);
        deleteOwned(output);
    }

    public synchronized void discard(String sessionId) throws IOException {
        Output output = outputs.remove(sessionId);
        if (output != null) deleteOwned(output);
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
