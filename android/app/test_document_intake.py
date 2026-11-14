"""Host checks for the Android document import manifest and native stager."""

from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.etree import ElementTree


MODULE = Path(__file__).resolve().parent
SOURCE = MODULE / 'src/main/java/io/github/canele452/personalinkvault/DocumentIntake.java'
FOLDER_SOURCE = SOURCE.with_name('ObsidianFolderStager.java')
ANDROID = '{http://schemas.android.com/apk/res/android}'
TYPES = {
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-powerpoint',
    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'application/vnd.oasis.opendocument.text',
    'application/vnd.oasis.opendocument.presentation',
    'application/x-hwp',
    'application/haansofthwp',
    'application/vnd.hancom.hwp',
    'application/hwp+zip',
    'application/x-hwpx',
    'application/vnd.hancom.hwpx',
}

HARNESS = r'''
package io.github.canele452.personalinkvault;

import java.io.*;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;

public class IntakeHarness {
    interface Check { void run() throws Exception; }
    static void require(boolean condition) { if (!condition) throw new AssertionError(); }
    static void rejected(Check check) throws Exception {
        try { check.run(); } catch (IOException expected) { return; }
        throw new AssertionError("Accepted invalid input");
    }
    static ByteArrayInputStream stream(int size) { return new ByteArrayInputStream(new byte[size]); }
    static void verifyBoundedCopy(Path directory) throws Exception {
        Path scratch = Files.createTempFile(directory, "starnote-", ".note");
        byte[] exact = new byte[]{1, 2, 3, 4, 5, 6, 7, 8};
        require(DocumentIntake.copyBounded(scratch, exact.length, () -> new ByteArrayInputStream(exact), () -> false)
                == exact.length);
        require(Arrays.equals(exact, Files.readAllBytes(scratch)));

        ByteArrayInputStream oversized = stream(100);
        try {
            DocumentIntake.copyBounded(scratch, 8, () -> oversized, () -> false);
            throw new AssertionError("Accepted over-limit stream");
        } catch (DocumentIntake.SizeLimitExceeded expected) {
            require(oversized.available() == 91 && Files.size(scratch) <= 8);
        }

        AtomicBoolean opened = new AtomicBoolean();
        rejected(() -> DocumentIntake.copyBounded(scratch, 8, () -> {
            opened.set(true);
            return stream(8);
        }, () -> true));
        require(!opened.get());

        AtomicBoolean cancelled = new AtomicBoolean();
        AtomicBoolean closed = new AtomicBoolean();
        rejected(() -> DocumentIntake.copyBounded(scratch, 8, () -> new ByteArrayInputStream(exact) {
            @Override public synchronized int read(byte[] buffer, int offset, int length) {
                cancelled.set(true);
                return super.read(buffer, offset, length);
            }
            @Override public void close() { closed.set(true); }
        }, cancelled::get));
        require(closed.get() && Files.size(scratch) == 0);
        Files.delete(scratch);
    }
    public static void main(String[] args) throws Exception {
        File privateDirectory = new File(args[0]);
        verifyBoundedCopy(privateDirectory.toPath());
        DocumentIntake intake = new DocumentIntake(privateDirectory, 8, 12, 2);
        Object firstOwner = new Object();
        Object secondOwner = new Object();
        intake.restore();
        require(DocumentIntake.MAX_FILE_BYTES == 128L * 1024 * 1024);
        require(DocumentIntake.extensionForMime("Application/PDF").equals("pdf"));
        require(DocumentIntake.extensionForMime("application/hwp+zip").equals("hwpx"));
        require(DocumentIntake.extensionForMime("application/octet-stream") == null);
        require(DocumentIntake.documentFormat("application/octet-stream", null, "poster.PPTX").equals("pptx"));
        require(DocumentIntake.documentFormat("application/zip", "application/hwp+zip", "제목").equals("hwpx"));
        rejected(() -> DocumentIntake.documentFormat("application/pdf", "application/msword", "report.pdf"));
        rejected(() -> DocumentIntake.documentFormat("text/plain", "application/pdf", "report.pdf"));
        rejected(() -> DocumentIntake.documentFormat("application/octet-stream", null, "ignored.sbn"));
        require(DocumentIntake.fileName("../../\\..\\수업:요약.PDF", "pdf").equals("수업_요약.pdf"));
        require(DocumentIntake.fileName("CON.any.pdf", "pdf").equals("문서.pdf"));
        require(DocumentIntake.fileName("...", "pptx").equals("문서.pptx"));
        require(DocumentIntake.fileName("🔎".repeat(250), "docx").getBytes(StandardCharsets.UTF_8).length <= 255);
        rejected(() -> DocumentIntake.fileName("unexpected.pptx", "pdf"));
        rejected(() -> intake.stage("pdf", "empty.pdf", () -> stream(0)));
        rejected(() -> intake.stage("pdf", "large.pdf", () -> stream(9)));
        rejected(() -> intake.stage("pdf", "failed.pdf", () -> new InputStream() {
            int calls;
            @Override public int read() throws IOException {
                if (calls++ == 0) return 123;
                throw new IOException("provider read failed");
            }
        }));
        require(intake.claim(firstOwner).isEmpty());
        try (var staged = Files.walk(privateDirectory.toPath())) {
            require(staged.noneMatch(Files::isRegularFile));
        }

        byte[] document = new byte[]{0, 12, 34, 56, 78, -1};
        intake.stage("pdf", "equal.pdf", () -> new ByteArrayInputStream(document));
        var first = intake.claim(firstOwner).get(0);
        require(first.keySet().equals(Set.of("id", "path")));
        Path firstFile = Path.of((String) first.get("path"));
        require(Arrays.equals(document, Files.readAllBytes(firstFile)));
        rejected(() -> intake.stage("pdf", "over-total.pdf", () -> stream(7)));
        intake.stage("pdf", "equal.pdf", () -> stream(6));
        var entries = intake.claim(firstOwner);
        require(entries.size() == 2 && entries.get(0).equals(first));
        require(!entries.get(0).get("path").equals(entries.get(1).get("path")));
        rejected(() -> intake.stage("pdf", "third.pdf", () -> stream(1)));
        require(intake.claim(secondOwner).isEmpty());

        Path partialDirectory = Files.createDirectory(firstFile.getParent().getParent()
                .resolve("0000000000000000010_70bf425f-c413-457a-82cc-119c3f6cc8ae"));
        Path partial = Files.writeString(partialDirectory.resolve(".part"), "incomplete");
        DocumentIntake restarted = new DocumentIntake(privateDirectory, 8, 12, 2);
        restarted.restore();
        require(!Files.exists(partial) && Files.exists(firstFile));
        var recovered = restarted.claim(firstOwner);
        require(recovered.size() == 2);
        for (int index = 0; index < recovered.size(); index++) {
            require(recovered.get(index).keySet().equals(Set.of("id", "path", "recovered")));
            require(recovered.get(index).get("id").equals(entries.get(index).get("id")));
            require(recovered.get(index).get("path").equals(entries.get(index).get("path")));
            require(Boolean.TRUE.equals(recovered.get(index).get("recovered")));
        }
        require(restarted.claim(secondOwner).isEmpty());
        var unrelated = Files.writeString(privateDirectory.toPath().resolve("unrelated.txt"), "keep");
        require(!restarted.beginRelease(firstOwner, unrelated.toString()));
        require(Files.exists(unrelated));
        String firstId = (String) first.get("id");
        require(!restarted.beginRelease(secondOwner, firstId));
        require(restarted.beginRelease(firstOwner, firstId));
        restarted.abandon(firstOwner);
        require(restarted.claim(secondOwner).equals(recovered.subList(1, 2)));
        restarted.release(firstId);
        require(!Files.exists(firstFile) && Files.exists(Path.of((String) entries.get(1).get("path"))));
        restarted.stage("pdf", "new.pdf", () -> stream(6));
        var current = restarted.claim(secondOwner);
        require(current.size() == 2 && current.get(0).equals(recovered.get(1)));
        require(!current.get(1).containsKey("recovered"));
    }
}
'''

FOLDER_HARNESS = r'''
package io.github.canele452.personalinkvault;

import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicBoolean;

public class ObsidianFolderHarness {
    private static ObsidianFolderStager.Entry entry(String id, String name, boolean directory) {
        return new ObsidianFolderStager.Entry(id, name, directory);
    }

    private static void require(boolean condition) {
        if (!condition) throw new AssertionError();
    }

    private static class Provider implements ObsidianFolderStager.Tree {
        final Map<String, List<ObsidianFolderStager.Entry>> files = new HashMap<>();
        final Set<String> opened = new HashSet<>();
        @Override public void children(String id, ObsidianFolderStager.ChildVisitor visitor) throws IOException {
            for (var child : files.getOrDefault(id, List.of())) visitor.accept(child);
        }
        @Override public InputStream open(String id) throws IOException {
            opened.add(id);
            return switch (id) {
                case "empty" -> new ByteArrayInputStream(new byte[0]);
                case "page", "pdf", "bookmark" -> new ByteArrayInputStream(id.getBytes());
                case "oversize" -> new InputStream() {
                    @Override public int read() { return 0; }
                    @Override public int read(byte[] bytes, int offset, int length) { return length; }
                };
                default -> throw new IOException("Unexpected file read " + id);
            };
        }
    }

    public static void main(String[] args) throws Exception {
        var cache = Path.of(args[0]);
        var staged = cache.resolve("vault");
        var source = new Provider();
        source.files.put("root", List.of(entry("notes", "노트", true), entry("emptyDir", "Empty", true),
                entry("skip", "Other.bin", false), entry("hidden", ".git", true),
                entry("settings", ".obsidian", true), entry("empty", "Empty.md", false)));
        source.files.put("notes", List.of(entry("page", "Page.md", false), entry("pdf", "File.PDF", false)));
        source.files.put("settings", List.of(entry("bookmark", "bookmarks.json", false),
                entry("oversize", "templates.json", false), entry("private", "workspace.json", false)));
        ObsidianFolderStager.stage(source, "root", staged, () -> false);
        require(Files.readString(staged.resolve("노트/Page.md")).equals("page"));
        require(Files.readString(staged.resolve("노트/File.PDF")).equals("pdf"));
        require(Files.readString(staged.resolve(".obsidian/bookmarks.json")).equals("bookmark"));
        require(Files.isDirectory(staged.resolve(".obsidian/templates.json")));
        require(Files.isDirectory(staged.resolve("Empty")) && Files.size(staged.resolve("Empty.md")) == 0);
        require(Files.isRegularFile(staged.resolve("Other.bin")) && Files.notExists(staged.resolve(".git")));
        require(source.opened.equals(Set.of("page", "pdf", "bookmark", "empty", "oversize")));
        ObsidianFolderStager.remove(staged);

        for (var invalid : List.of(entry("page", "../escape.md", false),
                entry("root", "Cycle", true), entry("oversize", "Big.md", false))) {
            source.files.put("root", List.of(entry("page", "Partial.md", false), invalid));
            try {
                ObsidianFolderStager.stage(source, "root", staged, () -> false);
                throw new AssertionError("Invalid import completed");
            } catch (IOException expected) {
                require(Files.notExists(staged) && Files.notExists(cache.resolve("escape.md")));
            }
        }

        AtomicBoolean cancelled = new AtomicBoolean();
        var interrupted = new Provider() {
            @Override public InputStream open(String id) throws IOException {
                cancelled.set(true);
                return super.open(id);
            }
        };
        interrupted.files.put("root", List.of(entry("page", "Page.md", false)));
        try {
            ObsidianFolderStager.stage(interrupted, "root", staged, cancelled::get);
            throw new AssertionError("Cancelled import completed");
        } catch (InterruptedIOException expected) {
            require(Files.notExists(staged));
        }
    }
}
'''


class DocumentIntakeTests(unittest.TestCase):
    def test_only_typed_document_open_and_share(self):
        manifest = ElementTree.parse(MODULE / 'src/main/AndroidManifest.xml')
        for action in ('VIEW', 'SEND'):
            filters = [
                node for node in manifest.findall('.//activity/intent-filter')
                if node.find('action').get(ANDROID + 'name') == 'android.intent.action.' + action
                and any(data.get(ANDROID + 'mimeType') == 'application/pdf' for data in node.findall('data'))
            ]
            self.assertEqual(len(filters), 1)
            data = filters[0].findall('data')
            self.assertEqual({item.get(ANDROID + 'mimeType') for item in data} - {None}, TYPES)
            self.assertEqual({item.get(ANDROID + 'scheme') for item in data} - {None},
                             {'content'} if action == 'VIEW' else set())
            self.assertTrue(all(item.get(ANDROID + 'pathPattern') is None for item in data))

    def test_actual_java_stager(self):
        with tempfile.TemporaryDirectory(prefix='piv-document-intake-') as work:
            root = Path(work)
            test = root / 'IntakeHarness.java'
            test.write_text(HARNESS, encoding='utf-8')
            subprocess.run(['javac', '-encoding', 'UTF-8', '-d', work, str(SOURCE), str(test)], check=True)
            cache = root / 'cache'
            cache.mkdir()
            subprocess.run(['java', '-cp', work, 'io.github.canele452.personalinkvault.IntakeHarness', str(cache)], check=True)

    def test_obsidian_folder_stager(self):
        with tempfile.TemporaryDirectory(prefix='piv-obsidian-folder-') as work:
            root = Path(work)
            test = root / 'ObsidianFolderHarness.java'
            test.write_text(FOLDER_HARNESS, encoding='utf-8')
            subprocess.run(['javac', '-encoding', 'UTF-8', '-d', work, str(SOURCE),
                            str(FOLDER_SOURCE), str(test)], check=True)
            subprocess.run(['java', '-cp', work,
                            'io.github.canele452.personalinkvault.ObsidianFolderHarness', work], check=True)


if __name__ == '__main__':
    unittest.main()
