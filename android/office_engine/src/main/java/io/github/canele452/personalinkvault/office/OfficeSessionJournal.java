package io.github.canele452.personalinkvault.office;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.RandomAccessFile;
import java.lang.ref.WeakReference;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Enumeration;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.regex.Pattern;
import java.util.zip.CRC32;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.concurrent.TimeUnit;

/** Private file recovery only. It neither opens an editor nor imports a vault revision. */
public final class OfficeSessionJournal {
    private static final Object LOCK = new Object();
    private static final Object EDITOR_LOCK = new Object();
    private static WeakReference<Object> liveEditor = new WeakReference<>(null);
    private static String liveSessionId;
    private static boolean editorActive;
    private static String liveLaunchId;
    private static EngineAttachment attachedEngine;
    private static ProcessStopper processStopper;
    // A death notice may arrive before the Activity result, so whether a launch attached outlives the attachment.
    private static final Set<String> attachedLaunchIds = new java.util.LinkedHashSet<>();
    private static final int REMEMBERED_LAUNCHES = 16;
    private static final List<Runnable> editorReleaseCallbacks = new ArrayList<>();
    private static final long MAX_FILE_BYTES = 128L * 1024 * 1024;
    private static final int MAX_MARKER_BYTES = 8192;
    private static final Pattern ID = Pattern.compile("[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}");
    private static final Pattern HASH = Pattern.compile("[0-9a-f]{64}");
    private static final Set<String> FORMATS = new HashSet<>(Arrays.asList("docx", "pptx", "doc", "ppt", "odt", "odp"));
    private static final Set<String> SESSION_FIELDS = new HashSet<>(Arrays.asList(
            "version", "sessionId", "inputSourceSha256", "format", "workingName", "engineVersion"));
    private static final Set<String> SOURCE_READY_FIELDS = new HashSet<>(Arrays.asList(
            "version", "sessionId", "inputSourceSha256", "format", "engineVersion", "sourceName",
            "sourceSha256", "sourceLength", "workingSha256"));
    private static final Set<String> SAVED_FIELDS = new HashSet<>(Arrays.asList(
            "version", "sessionId", "inputSourceSha256", "format", "engineVersion", "sourceName", "pdfName",
            "sourceSha256", "pdfSha256", "sourceLength", "pdfLength", "pdfPageCount"));
    private final File root;
    private final String engineVersion;

    public static boolean hasLiveEditor() {
        synchronized (EDITOR_LOCK) { return liveEditor.get() != null; }
    }

    /** Stops one of this app's Office engine processes by PID; installed by {@link OfficeEngineLink}. */
    interface ProcessStopper {
        void stop(int pid);
    }

    /** Main process: an Office Activity running in the engine process (":office") for one launch. */
    static final class EngineAttachment {
        final String sessionId;
        final String launchId;
        final int pid;
        boolean resultDelivered;

        EngineAttachment(String sessionId, String launchId, int pid) {
            this.sessionId = sessionId;
            this.launchId = launchId;
            this.pid = pid;
        }
    }

    public static boolean reserveEditor(String sessionId, Object owner) {
        return reserveEditor(sessionId, owner, null);
    }

    public static boolean reserveEditor(String sessionId, Object owner, String launchId) {
        synchronized (EDITOR_LOCK) {
            if (liveEditor.get() != null) return false;
            editorReleaseCallbacks.clear();
            liveEditor = new WeakReference<>(owner);
            liveSessionId = sessionId;
            liveLaunchId = launchId;
            attachedEngine = null;
            editorActive = false;
            return true;
        }
    }

    /**
     * Main process: an Office Activity in the engine process binds itself to the launch that opened it.
     * A preview must match the launch this process reserved, so a screen restored after an app restart
     * is refused; an edit may attach without a reservation to continue its private recovery.
     */
    static EngineAttachment attachEditor(String sessionId, String launchId, boolean previewOnly, int pid) {
        if (sessionId == null || launchId == null || pid <= 0) return null;
        synchronized (EDITOR_LOCK) {
            Object current = liveEditor.get();
            if (current != null && current == attachedEngine) {
                EngineAttachment attached = attachedEngine;
                // An Activity recreated in the same engine process keeps its launch.
                return attached.sessionId.equals(sessionId) && attached.launchId.equals(launchId) && attached.pid == pid
                        ? attached : null;
            }
            if (current != null && liveLaunchId != null && !liveLaunchId.equals(launchId)) return null;
            EngineAttachment attachment = new EngineAttachment(sessionId, launchId, pid);
            if (!editorOpened(sessionId, attachment, previewOnly)) return null;
            liveLaunchId = launchId;
            // liveEditor only holds a weak reference.
            attachedEngine = attachment;
            attachedLaunchIds.add(launchId);
            if (attachedLaunchIds.size() > REMEMBERED_LAUNCHES) {
                attachedLaunchIds.remove(attachedLaunchIds.iterator().next());
            }
            return attachment;
        }
    }

    /** Main process: whether the engine process of this launch ever attached, even if it already died. */
    static boolean wasAttached(String launchId) {
        synchronized (EDITOR_LOCK) {
            return launchId != null && attachedLaunchIds.contains(launchId);
        }
    }

    /** Main process: the engine process that held this launch is gone. */
    static void editorProcessDied(Object attachment) {
        if (attachment != null) releaseEditor(attachment);
    }

    /** Engine process: one Office Activity per process once the main process accepted its launch. */
    static boolean engineEditorOpened(String sessionId, Object owner) {
        return editorOpened(sessionId, owner, false);
    }

    /** Main process: the attached launch returned its result and is now only waiting for its process to exit. */
    static boolean markEditorResult(String launchId) {
        synchronized (EDITOR_LOCK) {
            EngineAttachment attached = liveAttachment();
            if (attached == null || launchId == null || !attached.launchId.equals(launchId)) return false;
            attached.resultDelivered = true;
            return true;
        }
    }

    static boolean hasClosingEditor() {
        return closingLaunch() != null;
    }

    static String closingLaunch() {
        synchronized (EDITOR_LOCK) {
            EngineAttachment attached = liveAttachment();
            return attached != null && attached.resultDelivered ? attached.launchId : null;
        }
    }

    static String attachedLaunch(String sessionId) {
        synchronized (EDITOR_LOCK) {
            EngineAttachment attached = liveAttachment();
            return attached != null && attached.sessionId.equals(sessionId) ? attached.launchId : null;
        }
    }

    static void setProcessStopper(ProcessStopper stopper) {
        synchronized (EDITOR_LOCK) { processStopper = stopper; }
    }

    /** Main process: stops the engine process of exactly this launch, using the PID recorded at attach. */
    static boolean stopEngine(String launchId) {
        int pid;
        ProcessStopper stopper;
        synchronized (EDITOR_LOCK) {
            EngineAttachment attached = liveAttachment();
            if (launchId == null || attached == null || !attached.launchId.equals(launchId) || processStopper == null) {
                return false;
            }
            pid = attached.pid;
            stopper = processStopper;
        }
        stopper.stop(pid);
        return true;
    }

    private static EngineAttachment liveAttachment() {
        return attachedEngine != null && liveEditor.get() == attachedEngine ? attachedEngine : null;
    }

    static boolean editorOpened(String sessionId, Object owner, boolean previewOnly) {
        synchronized (EDITOR_LOCK) {
            Object currentOwner = liveEditor.get();
            if (currentOwner == null && previewOnly) return false;
            if (currentOwner == null) {
                editorReleaseCallbacks.clear();
            } else {
                if (!sessionId.equals(liveSessionId)) return false;
                if (editorActive) return currentOwner == owner;
            }
            liveEditor = new WeakReference<>(owner);
            liveSessionId = sessionId;
            editorActive = true;
            return true;
        }
    }

    public static void releaseEditor(Object owner) {
        List<Runnable> callbacks;
        synchronized (EDITOR_LOCK) {
            if (liveEditor.get() != owner) return;
            liveEditor.clear();
            liveSessionId = null;
            liveLaunchId = null;
            attachedEngine = null;
            editorActive = false;
            callbacks = new ArrayList<>(editorReleaseCallbacks);
            editorReleaseCallbacks.clear();
            EDITOR_LOCK.notifyAll();
        }
        for (Runnable callback : callbacks) callback.run();
    }

    static boolean deferUntilEditorReleased(String sessionId, Runnable callback) {
        synchronized (EDITOR_LOCK) {
            if (!sessionId.equals(liveSessionId) || liveEditor.get() == null) return false;
            editorReleaseCallbacks.add(callback);
            return true;
        }
    }

    static boolean awaitEditorRelease(String sessionId, long timeoutMillis) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis);
        synchronized (EDITOR_LOCK) {
            while (sessionId.equals(liveSessionId) && liveEditor.get() != null) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) return false;
                TimeUnit.NANOSECONDS.timedWait(EDITOR_LOCK, remaining);
            }
            return true;
        }
    }

    static boolean awaitAnyEditorRelease(long timeoutMillis) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis);
        synchronized (EDITOR_LOCK) {
            while (liveEditor.get() != null) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) return false;
                TimeUnit.NANOSECONDS.timedWait(EDITOR_LOCK, remaining);
            }
            return true;
        }
    }

    public OfficeSessionJournal(File sessionsRoot, String engineVersion) throws IOException {
        requireVersion(engineVersion);
        File absolute = sessionsRoot.getAbsoluteFile();
        if (Files.exists(absolute.toPath(), LinkOption.NOFOLLOW_LINKS)) {
            if (!Files.isDirectory(absolute.toPath(), LinkOption.NOFOLLOW_LINKS)) throw invalid();
        } else {
            Files.createDirectories(absolute.toPath());
        }
        root = absolute.getCanonicalFile();
        this.engineVersion = engineVersion;
    }

    public Map<String, Object> create(File input, String sessionId, String format) throws IOException {
        synchronized (LOCK) {
            validateSessionId(sessionId);
            if (!FORMATS.contains(format)) throw invalid();
            requireRoot();
            if (locate(sessionId) != null) throw new IOException("Office session already exists; recover it instead");
            requireRegular(input);
            validateOffice(input, format);
            String inputHash = hash(input);
            File directory = new File(root, UUID.randomUUID().toString());
            Files.createDirectory(directory.toPath());
            File working = new File(directory, "working." + format);
            Files.copy(input.toPath(), working.toPath());
            if (!inputHash.equals(hash(working))) throw invalid();
            Map<String, String> header = new LinkedHashMap<>();
            header.put("version", "1");
            header.put("sessionId", sessionId);
            header.put("inputSourceSha256", inputHash);
            header.put("format", format);
            header.put("workingName", working.getName());
            header.put("engineVersion", engineVersion);
            Map<String, Object> result = working(new Session(directory, header));
            writeAtomic(new File(directory, "session.properties"), header);
            return result;
        }
    }

    public Map<String, Object> recover(String sessionId, String inputSourceSha256) throws IOException {
        synchronized (LOCK) {
            validateRequest(sessionId, inputSourceSha256);
            Session session = bound(sessionId, inputSourceSha256);
            if (session == null) return result("missing", sessionId, inputSourceSha256, engineVersion);
            if (Files.exists(session.savedMarker().toPath(), LinkOption.NOFOLLOW_LINKS)) return saved(session);
            if (Files.exists(session.sourceReadyMarker().toPath(), LinkOption.NOFOLLOW_LINKS)) return sourceReady(session);
            return working(session);
        }
    }

    /** Checkpoint the serialized edit before releasing the native document. */
    public Map<String, Object> recordSourceReady(String sessionId, String inputSourceSha256) throws IOException {
        synchronized (LOCK) {
            Session session = requireSession(sessionId, inputSourceSha256);
            if (Files.exists(session.savedMarker().toPath(), LinkOption.NOFOLLOW_LINKS)) return saved(session);
            if (Files.exists(session.sourceReadyMarker().toPath(), LinkOption.NOFOLLOW_LINKS)) return sourceReady(session);
            File source = owned(session.directory, "edited." + session.format());
            validateOffice(source, session.format());
            syncFile(source);
            Map<String, String> marker = new LinkedHashMap<>();
            marker.put("version", "1");
            marker.put("sessionId", sessionId);
            marker.put("inputSourceSha256", inputSourceSha256);
            marker.put("format", session.format());
            marker.put("engineVersion", session.header.get("engineVersion"));
            marker.put("sourceName", source.getName());
            marker.put("sourceSha256", hash(source));
            marker.put("sourceLength", Long.toString(source.length()));
            marker.put("workingSha256", (String) working(session).get("workingSha256"));
            writeAtomic(session.sourceReadyMarker(), marker);
            return sourceReady(session);
        }
    }

    /** Commit a PDF exported from the verified read-only reopen, keeping the source checkpoint on failure. */
    public Map<String, Object> recordReopenedPreview(String sessionId, String inputSourceSha256,
            String sourceSha256, File preview, String pdfSha256, int pageCount) throws IOException {
        synchronized (LOCK) {
            Session session = requireSession(sessionId, inputSourceSha256);
            if (pageCount < 1 || sourceSha256 == null || !HASH.matcher(sourceSha256).matches()
                    || pdfSha256 == null || !HASH.matcher(pdfSha256).matches()) throw invalid();
            if (Files.exists(session.savedMarker().toPath(), LinkOption.NOFOLLOW_LINKS)) {
                Map<String, Object> existing = saved(session);
                if (!sourceSha256.equals(existing.get("sourceSha256")) || !pdfSha256.equals(existing.get("pdfSha256"))
                        || !Integer.valueOf(pageCount).equals(existing.get("pdfPageCount"))) throw invalid();
                return existing;
            }
            if (!sourceSha256.equals(sourceReady(session).get("sourceSha256")) || preview == null
                    || preview.getAbsoluteFile().getParentFile() == null
                    || !Files.isDirectory(preview.getAbsoluteFile().getParentFile().toPath(), LinkOption.NOFOLLOW_LINKS)) {
                throw invalid();
            }
            requireRegular(preview);
            File pdf = new File(session.directory, "preview.pdf");
            if (Files.exists(pdf.toPath(), LinkOption.NOFOLLOW_LINKS)
                    && (!Files.isRegularFile(pdf.toPath(), LinkOption.NOFOLLOW_LINKS)
                    || Files.isSameFile(preview.toPath(), pdf.toPath()))) throw invalid();
            File pending = new File(session.directory, ".preview." + UUID.randomUUID() + ".tmp");
            try {
                Files.copy(preview.toPath(), pending.toPath());
                validatePdf(pending);
                if (!pdfSha256.equals(hash(pending))) throw invalid();
                syncFile(pending);
                Files.move(pending.toPath(), pdf.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                return publishSaved(session, pageCount, sourceSha256, pdfSha256);
            } finally {
                Files.deleteIfExists(pending.toPath());
            }
        }
    }

    /** Support the original v1 saved receipt contract. */
    public Map<String, Object> recordSaved(String sessionId, String inputSourceSha256, int pageCount) throws IOException {
        synchronized (LOCK) {
            validateRequest(sessionId, inputSourceSha256);
            if (pageCount < 1) throw invalid();
            Session session = bound(sessionId, inputSourceSha256);
            if (session == null) throw invalid();
            if (Files.exists(session.savedMarker().toPath(), LinkOption.NOFOLLOW_LINKS)) {
                Map<String, Object> existing = saved(session);
                if (!Integer.valueOf(pageCount).equals(existing.get("pdfPageCount"))) throw invalid();
                return existing;
            }
            if (Files.exists(session.sourceReadyMarker().toPath(), LinkOption.NOFOLLOW_LINKS)) throw invalid();
            return publishSaved(session, pageCount, null, null);
        }
    }

    private Map<String, Object> publishSaved(Session session, int pageCount, String expectedSourceSha256,
            String expectedPdfSha256) throws IOException {
        File source = owned(session.directory, "edited." + session.format());
        File pdf = owned(session.directory, "preview.pdf");
        validateOffice(source, session.format());
        validatePdf(pdf);
        String sourceSha256 = hash(source), pdfSha256 = hash(pdf);
        if (expectedSourceSha256 != null
                && (!expectedSourceSha256.equals(sourceSha256) || !expectedPdfSha256.equals(pdfSha256))) throw invalid();
        Map<String, String> marker = new LinkedHashMap<>();
        marker.put("version", "1");
        marker.put("sessionId", session.header.get("sessionId"));
        marker.put("inputSourceSha256", session.header.get("inputSourceSha256"));
        marker.put("format", session.format());
        marker.put("engineVersion", engineVersion);
        marker.put("sourceName", source.getName());
        marker.put("pdfName", pdf.getName());
        marker.put("sourceSha256", sourceSha256);
        marker.put("pdfSha256", pdfSha256);
        marker.put("sourceLength", Long.toString(source.length()));
        marker.put("pdfLength", Long.toString(pdf.length()));
        marker.put("pdfPageCount", Integer.toString(pageCount));
        writeAtomic(session.savedMarker(), marker);
        return saved(session);
    }

    private Session requireSession(String sessionId, String inputSourceSha256) throws IOException {
        validateRequest(sessionId, inputSourceSha256);
        Session session = bound(sessionId, inputSourceSha256);
        if (session == null) throw invalid();
        return session;
    }

    static void validateSessionId(String sessionId) throws IOException {
        if (sessionId == null || !ID.matcher(sessionId).matches()) throw invalid();
    }

    static void validateRequest(String sessionId, String inputSourceSha256) throws IOException {
        validateSessionId(sessionId);
        if (inputSourceSha256 == null || !HASH.matcher(inputSourceSha256).matches()) throw invalid();
    }

    private Session bound(String sessionId, String inputHash) throws IOException {
        requireRoot();
        Session session = locate(sessionId);
        if (session != null && !inputHash.equals(session.header.get("inputSourceSha256"))) throw invalid();
        return session;
    }

    private Session locate(String sessionId) throws IOException {
        File[] entries = root.listFiles();
        if (entries == null) throw invalid();
        Session match = null;
        for (File entry : entries) {
            if (Files.isSymbolicLink(entry.toPath())) throw invalid();
            if (!Files.isDirectory(entry.toPath(), LinkOption.NOFOLLOW_LINKS)) continue;
            File header = new File(entry, "session.properties");
            File completed = new File(entry, "saved.properties");
            File sourceReady = new File(entry, "source-ready.properties");
            boolean hasHeader = Files.exists(header.toPath(), LinkOption.NOFOLLOW_LINKS);
            if (!hasHeader && !Files.exists(completed.toPath(), LinkOption.NOFOLLOW_LINKS)
                    && !Files.exists(sourceReady.toPath(), LinkOption.NOFOLLOW_LINKS)) continue;
            validateSessionId(entry.getName());
            if (!entry.getCanonicalFile().getParentFile().equals(root) || !hasHeader) throw invalid();
            Map<String, String> values = readMarker(header, SESSION_FIELDS);
            if (!"1".equals(values.get("version"))) throw invalid();
            validateRequest(values.get("sessionId"), values.get("inputSourceSha256"));
            requireVersion(values.get("engineVersion"));
            String format = values.get("format");
            if (!FORMATS.contains(format) || !("working." + format).equals(values.get("workingName"))) throw invalid();
            if (sessionId.equals(values.get("sessionId"))) {
                if (match != null) throw new IOException("Ambiguous Office session identity");
                match = new Session(entry.getCanonicalFile(), values);
            }
        }
        return match;
    }

    private Map<String, Object> working(Session session) throws IOException {
        File working = owned(session.directory, session.header.get("workingName"));
        validateOffice(working, session.format());
        Map<String, Object> result = result("working", session.header.get("sessionId"),
                session.header.get("inputSourceSha256"), session.header.get("engineVersion"));
        result.put("workingPath", working.getPath());
        result.put("workingSha256", hash(working));
        return result;
    }

    private Map<String, Object> sourceReady(Session session) throws IOException {
        Map<String, String> values = readMarker(session.sourceReadyMarker(), SOURCE_READY_FIELDS);
        if (!"1".equals(values.get("version"))
                || !session.header.get("sessionId").equals(values.get("sessionId"))
                || !session.header.get("inputSourceSha256").equals(values.get("inputSourceSha256"))
                || !session.format().equals(values.get("format"))
                || !session.header.get("engineVersion").equals(values.get("engineVersion"))
                || !("edited." + session.format()).equals(values.get("sourceName"))
                || !HASH.matcher(values.get("sourceSha256")).matches()
                || !HASH.matcher(values.get("workingSha256")).matches()) throw invalid();
        File source = owned(session.directory, values.get("sourceName"));
        if (source.length() != positive(values.get("sourceLength"), MAX_FILE_BYTES)
                || !hash(source).equals(values.get("sourceSha256"))) throw invalid();
        validateOffice(source, session.format());
        Map<String, Object> result = result("source_ready", values.get("sessionId"),
                values.get("inputSourceSha256"), values.get("engineVersion"));
        result.put("workingPath", new File(session.directory, session.header.get("workingName")).getPath());
        result.put("workingSha256", values.get("workingSha256"));
        result.put("sourcePath", source.getPath());
        result.put("sourceSha256", values.get("sourceSha256"));
        return result;
    }

    private Map<String, Object> saved(Session session) throws IOException {
        Map<String, String> values = readMarker(session.savedMarker(), SAVED_FIELDS);
        if (!"1".equals(values.get("version")) ||
                !session.header.get("sessionId").equals(values.get("sessionId")) ||
                !session.header.get("inputSourceSha256").equals(values.get("inputSourceSha256")) ||
                !session.format().equals(values.get("format")) ||
                !("edited." + session.format()).equals(values.get("sourceName")) ||
                !"preview.pdf".equals(values.get("pdfName"))) throw invalid();
        requireVersion(values.get("engineVersion"));
        if (!HASH.matcher(values.get("sourceSha256")).matches() || !HASH.matcher(values.get("pdfSha256")).matches()) throw invalid();
        long sourceLength = positive(values.get("sourceLength"), MAX_FILE_BYTES);
        long pdfLength = positive(values.get("pdfLength"), MAX_FILE_BYTES);
        int pages = (int) positive(values.get("pdfPageCount"), Integer.MAX_VALUE);
        File source = owned(session.directory, values.get("sourceName"));
        File pdf = owned(session.directory, values.get("pdfName"));
        if (source.length() != sourceLength || pdf.length() != pdfLength ||
                !hash(source).equals(values.get("sourceSha256")) || !hash(pdf).equals(values.get("pdfSha256"))) throw invalid();
        validateOffice(source, session.format());
        validatePdf(pdf);
        Map<String, Object> result = result("saved", values.get("sessionId"), values.get("inputSourceSha256"), values.get("engineVersion"));
        result.put("sourcePath", source.getPath());
        result.put("pdfPath", pdf.getPath());
        result.put("sourceSha256", values.get("sourceSha256"));
        result.put("pdfSha256", values.get("pdfSha256"));
        result.put("pdfPageCount", pages);
        return result;
    }

    private void requireRoot() throws IOException {
        if (!Files.isDirectory(root.toPath(), LinkOption.NOFOLLOW_LINKS) || !root.getCanonicalFile().equals(root)) throw invalid();
    }

    private File owned(File directory, String name) throws IOException {
        requireRoot();
        if (!Files.isDirectory(directory.toPath(), LinkOption.NOFOLLOW_LINKS) ||
                !directory.getCanonicalFile().getParentFile().equals(root) || !directory.getCanonicalFile().equals(directory)) throw invalid();
        File file = new File(directory, name);
        if (!file.getCanonicalFile().getParentFile().equals(directory)) throw invalid();
        requireRegular(file);
        return file.getCanonicalFile();
    }

    private static void requireRegular(File file) throws IOException {
        if (!Files.isRegularFile(file.toPath(), LinkOption.NOFOLLOW_LINKS) || file.length() < 1 || file.length() > MAX_FILE_BYTES) throw invalid();
    }

    static void validateOffice(File file, String format) throws IOException {
        requireRegular(file);
        if (!FORMATS.contains(format)) throw invalid();
        if (OfficeLegacyContainer.supports(format)) {
            OfficeLegacyContainer.validate(file, format);
            return;
        }
        try (RandomAccessFile input = new RandomAccessFile(file, "r")) {
            if (input.readInt() != 0x504b0304) throw invalid();
        }
        String[] required = format.equals("docx") ? new String[]{"[Content_Types].xml", "word/document.xml"}
                : format.equals("pptx") ? new String[]{"[Content_Types].xml", "ppt/presentation.xml"}
                : new String[]{"mimetype", "content.xml"};
        byte[] mime = format.equals("odt") ? "application/vnd.oasis.opendocument.text".getBytes(StandardCharsets.US_ASCII)
                : format.equals("odp") ? "application/vnd.oasis.opendocument.presentation".getBytes(StandardCharsets.US_ASCII) : null;
        Set<String> requiredParts = new HashSet<>(Arrays.asList(required));
        Set<String> checkedParts = new HashSet<>();
        Set<String> names = new HashSet<>();
        long expanded = 0;
        byte[] buffer = new byte[65536];
        int directoryEntries = validateZipAttributes(file);
        try (ZipFile archive = new ZipFile(file)) {
            if (archive.size() != directoryEntries) throw invalid();
            Enumeration<? extends ZipEntry> entries = archive.entries();
            while (entries.hasMoreElements()) {
                ZipEntry entry = entries.nextElement();
                String name = entry.getName();
                String logical = entry.isDirectory() && name.endsWith("/") ? name.substring(0, name.length() - 1) : name;
                if (logical.isEmpty() || logical.indexOf('\\') >= 0 || logical.indexOf(':') >= 0 || !names.add(logical)) throw invalid();
                for (String segment : logical.split("/", -1)) {
                    if (segment.isEmpty() || segment.equals(".") || segment.equals("..")) throw invalid();
                }
                for (int index = 0; index < logical.length(); index++) {
                    if (logical.charAt(index) < 32) throw invalid();
                }
                if (entry.getSize() < 0 || entry.getSize() > MAX_FILE_BYTES - expanded || entry.getCrc() < 0) throw invalid();
                if (entry.isDirectory() && entry.getSize() != 0) throw invalid();
                CRC32 crc = new CRC32();
                long length = 0;
                ByteArrayOutputStream mimeBytes = mime != null && name.equals("mimetype") ? new ByteArrayOutputStream(mime.length) : null;
                try (InputStream input = archive.getInputStream(entry)) {
                    int count;
                    while ((count = input.read(buffer)) != -1) {
                        length += count;
                        if (length > entry.getSize() || length > MAX_FILE_BYTES - expanded) throw invalid();
                        crc.update(buffer, 0, count);
                        if (mimeBytes != null) {
                            if (length > mime.length) throw invalid();
                            mimeBytes.write(buffer, 0, count);
                        }
                    }
                }
                if (length != entry.getSize() || crc.getValue() != entry.getCrc()) throw invalid();
                expanded += length;
                if (mimeBytes != null && !Arrays.equals(mime, mimeBytes.toByteArray())) throw invalid();
                if (requiredParts.contains(name)) {
                    if (entry.isDirectory() || length == 0) throw invalid();
                    checkedParts.add(name);
                }
            }
            if (!checkedParts.equals(requiredParts)) throw invalid();
        }
    }

    private static int validateZipAttributes(File file) throws IOException {
        try (RandomAccessFile input = new RandomAccessFile(file, "r")) {
            int tailLength = (int) Math.min(input.length(), 65557L);
            byte[] tail = new byte[tailLength];
            input.seek(input.length() - tailLength);
            input.readFully(tail);
            int end = -1;
            for (int index = tail.length - 22; index >= 0; index--) {
                if (zip32(tail, index) == 0x06054b50L && index + 22 + zip16(tail, index + 20) == tail.length) {
                    if (end != -1) throw invalid();
                    end = index;
                }
            }
            if (end == -1 || zip16(tail, end + 4) != 0 || zip16(tail, end + 6) != 0) throw invalid();
            long endOffset = input.length() - tailLength + end;
            long countOnDisk = zip16(tail, end + 8), count = zip16(tail, end + 10);
            long size = zip32(tail, end + 12), offset = zip32(tail, end + 16);
            long centralLimit = endOffset;
            boolean hasZip64 = count == 0xffff || countOnDisk == 0xffff || size == 0xffffffffL || offset == 0xffffffffL;
            byte[] locator = new byte[20];
            if (endOffset >= locator.length) {
                input.seek(endOffset - locator.length);
                input.readFully(locator);
                hasZip64 |= zip32(locator, 0) == 0x07064b50L;
            }
            if (hasZip64) {
                long legacyCount = count, legacyCountOnDisk = countOnDisk, legacySize = size, legacyOffset = offset;
                if (zip32(locator, 0) != 0x07064b50L || zip32(locator, 4) != 0 || zip32(locator, 16) != 1) throw invalid();
                long zip64Offset = zip64(locator, 8);
                if (zip64Offset > endOffset - locator.length - 56) throw invalid();
                byte[] record = new byte[56];
                input.seek(zip64Offset);
                input.readFully(record);
                long recordLength = zip64(record, 4);
                if (zip32(record, 0) != 0x06064b50L || recordLength < 44 ||
                        recordLength != endOffset - locator.length - zip64Offset - 12 ||
                        zip32(record, 16) != 0 || zip32(record, 20) != 0) throw invalid();
                countOnDisk = zip64(record, 24);
                count = zip64(record, 32);
                size = zip64(record, 40);
                offset = zip64(record, 48);
                centralLimit = zip64Offset;
                if (legacyCount != 0xffff && legacyCount != count || legacyCountOnDisk != 0xffff && legacyCountOnDisk != countOnDisk ||
                        legacySize != 0xffffffffL && legacySize != size || legacyOffset != 0xffffffffL && legacyOffset != offset) throw invalid();
            }
            if (count != countOnDisk || count > Integer.MAX_VALUE || count > size / 46 ||
                    offset > centralLimit || size != centralLimit - offset) throw invalid();
            long cursor = offset, centralEnd = offset + size;
            byte[] header = new byte[46];
            for (long index = 0; index < count; index++) {
                if (centralEnd - cursor < header.length) throw invalid();
                input.seek(cursor);
                input.readFully(header);
                if (zip32(header, 0) != 0x02014b50L || zip16(header, 34) != 0) throw invalid();
                // ZipEntry does not expose Unix external attributes. Check the
                // actual central record, including nonessential package parts.
                if (((zip32(header, 38) >>> 16) & 0xf000) == 0xa000) throw invalid();
                long next = cursor + header.length + zip16(header, 28) + zip16(header, 30) + zip16(header, 32);
                if (next > centralEnd) throw invalid();
                cursor = next;
            }
            if (cursor != centralEnd) {
                // The optional central-directory signature carries no entries.
                if (centralEnd - cursor < 6) throw invalid();
                input.seek(cursor);
                byte[] signature = new byte[6];
                input.readFully(signature);
                if (zip32(signature, 0) != 0x05054b50L || cursor + 6 + zip16(signature, 4) != centralEnd) throw invalid();
            }
            return (int) count;
        }
    }

    private static int zip16(byte[] bytes, int offset) {
        return (bytes[offset] & 255) | ((bytes[offset + 1] & 255) << 8);
    }

    private static long zip32(byte[] bytes, int offset) {
        return (zip16(bytes, offset) & 65535L) | ((zip16(bytes, offset + 2) & 65535L) << 16);
    }

    private static long zip64(byte[] bytes, int offset) throws IOException {
        long value = zip32(bytes, offset) | (zip32(bytes, offset + 4) << 32);
        if (value < 0) throw invalid();
        return value;
    }

    private static void validatePdf(File file) throws IOException {
        requireRegular(file);
        try (RandomAccessFile input = new RandomAccessFile(file, "r")) {
            byte[] header = new byte[5];
            input.readFully(header);
            if (!Arrays.equals(header, "%PDF-".getBytes(StandardCharsets.US_ASCII))) throw invalid();
            input.seek(Math.max(0, input.length() - 2048));
            byte[] tail = new byte[(int) (input.length() - input.getFilePointer())];
            input.readFully(tail);
            if (!new String(tail, StandardCharsets.ISO_8859_1).contains("%%EOF")) throw invalid();
        }
    }

    private static String hash(File file) throws IOException {
        requireRegular(file);
        try (InputStream input = new FileInputStream(file)) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[65536];
            long total = 0;
            int count;
            while ((count = input.read(buffer)) != -1) {
                total += count;
                if (total > MAX_FILE_BYTES) throw invalid();
                digest.update(buffer, 0, count);
            }
            if (total < 1) throw invalid();
            StringBuilder result = new StringBuilder();
            for (byte value : digest.digest()) result.append(String.format("%02x", value & 255));
            return result.toString();
        } catch (NoSuchAlgorithmException unavailable) {
            throw new IOException("SHA-256 unavailable", unavailable);
        }
    }

    private static void syncFile(File file) throws IOException {
        try (RandomAccessFile output = new RandomAccessFile(file, "rw")) {
            output.getFD().sync();
        }
    }

    private static Map<String, String> readMarker(File file, Set<String> fields) throws IOException {
        requireRegular(file);
        Properties properties = new Properties() {
            @Override public synchronized Object put(Object key, Object value) {
                if (containsKey(key)) throw new IllegalArgumentException("Duplicate Office marker field");
                return super.put(key, value);
            }
        };
        try (InputStream input = new FileInputStream(file); ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[1024];
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (bytes.size() + count > MAX_MARKER_BYTES) throw invalid();
                bytes.write(buffer, 0, count);
            }
            properties.load(new ByteArrayInputStream(bytes.toByteArray()));
        } catch (IllegalArgumentException error) {
            throw new IOException("Invalid Office marker", error);
        }
        if (!properties.stringPropertyNames().equals(fields)) throw invalid();
        Map<String, String> result = new LinkedHashMap<>();
        for (String field : fields) result.put(field, properties.getProperty(field));
        return result;
    }

    private static void writeAtomic(File file, Map<String, String> values) throws IOException {
        if (Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)) throw invalid();
        File pending = new File(file.getParentFile(), "." + file.getName() + "." + UUID.randomUUID() + ".tmp");
        try {
            try (FileOutputStream output = new FileOutputStream(pending)) {
                StringBuilder text = new StringBuilder();
                for (Map.Entry<String, String> entry : values.entrySet()) text.append(entry.getKey()).append('=').append(entry.getValue()).append('\n');
                output.write(text.toString().getBytes(StandardCharsets.UTF_8));
                output.flush();
                output.getFD().sync();
            }
            if (Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)) throw invalid();
            Files.move(pending.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE);
        } finally {
            try { Files.deleteIfExists(pending.toPath()); } catch (IOException ignored) { /* Retain only this incomplete marker. */ }
        }
    }

    private static long positive(String value, long max) throws IOException {
        if (value == null || !value.matches("[1-9][0-9]{0,18}")) throw invalid();
        try {
            long parsed = Long.parseLong(value);
            if (parsed > max) throw invalid();
            return parsed;
        } catch (NumberFormatException error) { throw invalid(); }
    }

    private static void requireVersion(String version) throws IOException {
        if (version == null || !version.matches("[A-Za-z0-9._-]{1,128}")) throw invalid();
    }

    private static Map<String, Object> result(String status, String sessionId, String inputHash, String version) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("status", status);
        result.put("sessionId", sessionId);
        result.put("inputSourceSha256", inputHash);
        result.put("engineVersion", version);
        return result;
    }

    private static IOException invalid() { return new IOException("Invalid private Office recovery files or binding"); }

    private static final class Session {
        final File directory;
        final Map<String, String> header;
        Session(File directory, Map<String, String> header) { this.directory = directory; this.header = header; }
        String format() { return header.get("format"); }
        File sourceReadyMarker() { return new File(directory, "source-ready.properties"); }
        File savedMarker() { return new File(directory, "saved.properties"); }
    }
}
