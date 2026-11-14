package io.github.canele452.personalinkvault.office;

import android.app.Activity;
import android.content.Intent;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

/**
 * Opens a Dart-prepared HWP/HWPX working copy in HwpEditorActivity and reports the result in the shape of the
 * Office edit flow: {status, sessionId, inputSourceSha256[, sourcePath, sourceSha256]}. The edited file is
 * always edited.&lt;ext&gt; in the working copy's folder; Dart renders preview.pdf beside it.
 */
public final class HwpEditorBridge {
    public interface Completion {
        void success(Map<String, Object> value);

        void error(String code, String message);
    }

    static final int REQUEST_EDIT = 19478;
    private static final Pattern SESSION = Pattern.compile("[A-Za-z0-9-]{1,128}");
    private static final long MAX_BYTES = 128L * 1024 * 1024;

    private final Activity activity;
    private Completion pending;
    private String pendingSession;
    private String pendingInputSha256;
    private File pendingOutput;

    public HwpEditorBridge(Activity activity) {
        this.activity = activity;
    }

    public void edit(String sourcePath, String sessionId, String displayName, Completion completion) {
        if (pending != null) {
            completion.error("hwp_editor_busy", "HWP 편집 화면이 이미 열려 있습니다.");
            return;
        }
        File source;
        String format;
        try {
            if (sourcePath == null || sessionId == null || !SESSION.matcher(sessionId).matches())
                throw new IOException("request");
            source = new File(sourcePath).getCanonicalFile();
            String data = activity.getApplicationInfo().dataDir;
            String root = new File(data).getCanonicalPath() + File.separator;
            String fileName = source.getName().toLowerCase(Locale.ROOT);
            format = fileName.equals("original.hwp") ? "hwp" : fileName.equals("original.hwpx") ? "hwpx" : null;
            if (format == null || !source.getPath().startsWith(root) || !source.isFile()
                    || source.length() == 0 || source.length() > MAX_BYTES)
                throw new IOException("source");
        } catch (IOException invalid) {
            completion.error("invalid_request", "편집할 HWP 작업 파일을 확인하지 못했습니다.");
            return;
        }
        String inputSha256;
        try {
            inputSha256 = sha256(source);
        } catch (IOException error) {
            completion.error("file_error", "HWP 작업 파일을 읽지 못했습니다. 원본은 보관됩니다.");
            return;
        }
        File output = new File(source.getParentFile(), "edited." + format);
        if (output.exists() && !output.delete()) {
            completion.error("file_error", "이전 편집 파일을 정리하지 못했습니다. 원본은 보관됩니다.");
            return;
        }
        Intent intent = new Intent(activity, HwpEditorActivity.class)
                .putExtra(HwpEditorActivity.EXTRA_WORKING, source.getPath())
                .putExtra(HwpEditorActivity.EXTRA_OUTPUT, output.getPath())
                .putExtra(HwpEditorActivity.EXTRA_SESSION, sessionId)
                .putExtra(HwpEditorActivity.EXTRA_FORMAT, format)
                .putExtra(HwpEditorActivity.EXTRA_NAME, title(displayName, format));
        pending = completion;
        pendingSession = sessionId;
        pendingInputSha256 = inputSha256;
        pendingOutput = output;
        try {
            activity.startActivityForResult(intent, REQUEST_EDIT);
        } catch (RuntimeException error) {
            clear();
            completion.error("hwp_editor_unavailable", "HWP 편집 화면을 열지 못했습니다.");
        }
    }

    public boolean handleActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != REQUEST_EDIT) return false;
        Completion completion = pending;
        String session = pendingSession;
        String input = pendingInputSha256;
        File output = pendingOutput;
        clear();
        if (completion == null) return true;
        String returned = data == null ? null : data.getStringExtra(HwpEditorActivity.EXTRA_SESSION);
        if (resultCode == Activity.RESULT_OK) {
            String reported = data == null ? null : data.getStringExtra(HwpEditorActivity.RESULT_SOURCE_SHA256);
            try {
                String actual = sha256(output);
                if (!session.equals(returned) || !actual.equals(reported)) throw new IOException("mismatch");
                Map<String, Object> value = base(session, input, "saved");
                value.put("sourcePath", output.getPath());
                value.put("sourceSha256", actual);
                completion.success(value);
            } catch (IOException error) {
                completion.error("invalid_hwp_result", "편집한 HWP 파일을 확인하지 못했습니다. 원본은 보관됩니다.");
            }
        } else if (resultCode == Activity.RESULT_CANCELED) {
            completion.success(base(session, input, "cancelled"));
        } else {
            String code = data == null ? null : data.getStringExtra(HwpEditorActivity.RESULT_ERROR_CODE);
            String message = data == null ? null : data.getStringExtra(HwpEditorActivity.RESULT_ERROR_MESSAGE);
            completion.error(code == null ? "hwp_editor_failed" : code,
                    message == null ? "HWP 편집 화면이 끝나지 못했습니다. 원본은 보관됩니다." : message);
        }
        return true;
    }

    /** A plain file name for the title bar and the studio; falls back to document.&lt;ext&gt;. */
    static String title(String name, String format) {
        if (name == null || name.isEmpty() || name.length() > 255 || name.contains("/") || name.contains("\\")
                || name.indexOf('\0') >= 0) return "document." + format;
        return name;
    }

    private void clear() {
        pending = null;
        pendingSession = null;
        pendingInputSha256 = null;
        pendingOutput = null;
    }

    private static Map<String, Object> base(String session, String input, String status) {
        Map<String, Object> value = new HashMap<>();
        value.put("status", status);
        value.put("sessionId", session);
        value.put("inputSourceSha256", input);
        return value;
    }

    static String sha256(File file) throws IOException {
        try (InputStream stream = new FileInputStream(file)) {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] buffer = new byte[64 * 1024];
            for (int read; (read = stream.read(buffer)) > 0; ) digest.update(buffer, 0, read);
            return hex(digest.digest());
        } catch (NoSuchAlgorithmException impossible) {
            throw new IOException(impossible);
        }
    }

    static String sha256(byte[] data) {
        try {
            return hex(MessageDigest.getInstance("SHA-256").digest(data));
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException(impossible);
        }
    }

    private static String hex(byte[] bytes) {
        StringBuilder text = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) text.append(String.format("%02x", b & 0xff));
        return text.toString();
    }
}
