package io.github.canele452.personalinkvault.office;

import android.app.Activity;
import android.content.Intent;
import android.graphics.pdf.PdfRenderer;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.graphics.Color;
import android.view.ViewGroup;
import android.view.Gravity;
import android.webkit.JavascriptInterface;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.TextView;
import android.widget.Toast;
import androidx.activity.OnBackPressedCallback;
import org.json.JSONObject;

import org.libreoffice.androidlib.LOActivity;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.security.MessageDigest;
import java.util.Map;

public final class OfficeEditorActivity extends LOActivity {
    private static final String FORMAT_MISMATCH = OfficeLegacyContainer.MISMATCH_CODE;
    private volatile boolean ready;
    private File directory;
    private String format;
    private String sessionId;
    private String inputSourceSha256;
    private boolean previewOnly;
    private boolean nativeObservation;
    private boolean legacyConversion;
    private boolean reopenedSource;
    private volatile boolean previewCancelled;
    private volatile boolean previewLoadFailed;
    private boolean previewRequested;
    private boolean previewResultSet;
    private File working;
    private String workingSha256;
    private long workingModified;
    private volatile OfficePresentationCells presentationCells;
    private boolean engineAttached;

    static { System.loadLibrary("piv_office_bridge"); }

    public static synchronized boolean hasLiveEditor() {
        return OfficeSessionJournal.hasLiveEditor();
    }

    @Override
    public void onCreate(Bundle savedInstanceState) {
        OfficeEngineProcess.prepare();
        Map<String, Object> alreadyExported = null;
        sessionId = getIntent().getStringExtra("piv.sessionId");
        previewOnly = getIntent().getBooleanExtra("piv.previewOnly", false);
        String launchId = getIntent().getStringExtra("piv.launchId");
        // This Activity runs in the ":office" process; the main process owns the launch it belongs to.
        engineAttached = sessionId != null && !sessionId.isEmpty()
                && OfficeEngineProcess.attach(this, sessionId, launchId, previewOnly);
        boolean opened = engineAttached && OfficeSessionJournal.engineEditorOpened(sessionId, this);
        OfficeEngineProcess.log("editor create preview=" + previewOnly + " opened=" + opened
                + " session=" + sessionId + " launch=" + launchId);
        try {
            if (!opened) throw new IOException("Invalid or busy office session");
            nativeObservation = getIntent().getBooleanExtra("piv.nativeObservation", false);
            legacyConversion = getIntent().getBooleanExtra("piv.legacyConversion", false);
            reopenedSource = getIntent().getBooleanExtra("piv.reopenedSource", false);
            if (nativeObservation && !previewOnly) throw new IOException("invalid_office_observation");
            if (legacyConversion && (!previewOnly || nativeObservation)) throw new IOException("invalid_office_conversion");
            if (reopenedSource && (!previewOnly || nativeObservation || legacyConversion)) {
                throw new IOException("invalid_office_reopen");
            }
            directory = OfficePreviewOutputs.requireSessionDirectory(getFilesDir(),
                    getIntent().getStringExtra("piv.sessionDirectory"), previewOnly);
            format = getIntent().getStringExtra("piv.format");
            if (!OfficeEngineBridge.FORMATS.contains(format)) throw new IOException("Unsupported format");
            working = new File(getIntent().getStringExtra("piv.workingPath")).getCanonicalFile();
            if (!directory.equals(working.getParentFile())) throw new IOException("Invalid working copy");
            if (previewOnly) {
                if (!working.isFile()) throw new IOException("Missing preview working copy");
                workingSha256 = sha256(working);
                workingModified = working.lastModified();
                if (reopenedSource && (!workingSha256.equals(getIntent().getStringExtra("piv.inputSourceSha256"))
                        || !new File(directory, "working." + format).equals(working))) {
                    throw new IOException("invalid_office_reopen");
                }
                if (nativeObservation) {
                    inputSourceSha256 = getIntent().getStringExtra("piv.inputSourceSha256");
                    OfficeSessionJournal.validateRequest(sessionId, inputSourceSha256);
                    if (!workingSha256.equals(inputSourceSha256) ||
                            !("ppt".equals(format) || "pptx".equals(format) || "odp".equals(format))) {
                        throw new IOException("invalid_office_observation");
                    }
                }
                if (legacyConversion) {
                    inputSourceSha256 = getIntent().getStringExtra("piv.inputSourceSha256");
                    OfficeSessionJournal.validateRequest(sessionId, inputSourceSha256);
                    if (!workingSha256.equals(inputSourceSha256) || OfficePreviewOutputs.legacyTarget(format) == null
                            || !new File(directory, "working." + format).equals(working)) {
                        throw new IOException("invalid_office_conversion");
                    }
                }
                if (reopenedSource || OfficeLegacyContainer.supports(format)) {
                    OfficeSessionJournal.validateOffice(working, format);
                }
            } else {
                inputSourceSha256 = getIntent().getStringExtra("piv.inputSourceSha256");
                Map<String, Object> recovery = journal().recover(sessionId, inputSourceSha256);
                if ("saved".equals(recovery.get("status")) || "source_ready".equals(recovery.get("status"))) {
                    alreadyExported = recovery;
                    // A recreated finished session must never autosave its older working copy.
                    getIntent().putExtra("piv.previewOnly", true);
                } else if (!"working".equals(recovery.get("status")) || !working.getPath().equals(recovery.get("workingPath"))) {
                    throw new IOException("Invalid private recovery working copy");
                }
            }
            if (alreadyExported == null) getIntent().setData(Uri.fromFile(working));
            else getIntent().setData(null);
        } catch (Exception error) {
            getIntent().putExtra("piv.previewOnly", true);
            getIntent().setData(null);
            super.onCreate(null);
            if (previewOnly && !opened) {
                setResult(Activity.RESULT_CANCELED, new Intent().putExtra("sessionId", sessionId));
            } else if (!finishOnFormatMismatch(error)) {
                setResult(Activity.RESULT_CANCELED, new Intent().putExtra("sessionId", sessionId)
                        .putExtra("errorCode", legacyConversion ? "invalid_office_conversion"
                                : nativeObservation ? "invalid_office_observation"
                                : reopenedSource ? "office_reopen_failed" : "office_recovery_invalid")
                        .putExtra("errorMessage", "문서 작업 파일과 세션 결합을 확인하지 못했습니다. 파일은 보관됩니다."));
            }
            finish();
            return;
        }
        if (!previewOnly && alreadyExported == null) {
            // Every intended close of the editor carries data; a result without data means its process died.
            setResult(Activity.RESULT_CANCELED, new Intent().putExtra("sessionId", sessionId));
        }
        super.onCreate(alreadyExported == null ? savedInstanceState : null);
        if (alreadyExported != null) {
            setResult(Activity.RESULT_OK, editResult(alreadyExported));
            finish();
            return;
        }
        if (!previewOnly) {
            presentationCells = new OfficePresentationCells(this, sessionId, working, format);
            if (ready) presentationCells.installButton();
        }
        if (previewOnly) showPreviewProgress();
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override public void handleOnBackPressed() {
                if (previewOnly) {
                    cancelPreview();
                } else if (presentationCells == null || !presentationCells.handleBack()) {
                    handleEmbeddedBack();
                }
            }
        });
    }

    @Override
    protected void onDestroy() {
        OfficeEngineProcess.log("editor destroy session=" + sessionId);
        try {
            if (presentationCells != null) presentationCells.close();
        } finally {
            super.onDestroy();
        }
    }

    @Override
    protected void onEmbeddedActivityReleased() {
        OfficeSessionJournal.releaseEditor(this);
        // A refused Activity's process may be reused for the next launch; only an attached one ends it.
        if (engineAttached) OfficeEngineProcess.stopAfterRelease(this);
    }

    @Override
    protected boolean hasEmbeddedPreviewResult() {
        return previewResultSet;
    }

    @Override
    protected void onNewIntent(Intent intent) {
        // Flutter owns the next private session; do not open an unbound base Activity.
        if (previewOnly) {
            previewCancelled = true;
            OfficePreviewOutputs.deleteResultRecord(directory);
            finish();
        } else if (presentationCells == null || !presentationCells.handleBack()) {
            finishWithProgress();
        }
    }

    @Override
    protected boolean isEmbeddedDocumentBusy() {
        return presentationCells != null && presentationCells.blocksSave();
    }

    @Override
    protected boolean onEmbeddedNativeMessage(byte[] message) {
        if (previewOnly) {
            // Collabora sends status after loading the native document. A WebView
            // progress notification can also come from an unrelated dialog.
            String prefix = "status: ";
            boolean loaded = message.length > prefix.length() && message[0] == 's'
                    && prefix.equals(new String(message, 0, prefix.length(), StandardCharsets.US_ASCII));
            String failure = loaded ? null : previewLoadFailure(message);
            if (!loaded && failure == null) return false;
            runOnUiThread(() -> {
                if (previewRequested || previewCancelled || isFinishing() || isDestroyed()
                        || OfficeEngineHealth.requiresRestart()) return;
                previewRequested = true;
                if (loaded) {
                    OfficeEngineProcess.log("document loaded session=" + sessionId);
                    ready = true;
                    finishWithProgress();
                } else {
                    previewLoadFailed = true;
                    deliverPreviewResult(Activity.RESULT_CANCELED, new Intent().putExtra("sessionId", sessionId)
                            .putExtra("errorCode", "office_preview_load_failed").putExtra("errorMessage", failure));
                }
            });
            return failure != null;
        }
        return presentationCells != null && presentationCells.onNativeMessage(message);
    }

    private static String previewLoadFailure(byte[] message) {
        if (message.length == 0 || message[0] != 'e') return null;
        String prefix = "error: cmd=load kind=";
        String header = new String(message, 0, Math.min(message.length, 256), StandardCharsets.US_ASCII);
        if (!header.startsWith(prefix)) return null;
        String kind = header.substring(prefix.length()).split("\\s", 2)[0];
        return switch (kind) {
            case "passwordrequired", "passwordrequired:to-view", "passwordrequired:to-modify", "wrongpassword" ->
                    "암호가 걸린 문서입니다. 암호를 해제한 사본으로 PDF 만들기를 다시 시도해 주세요.";
            case "faileddocloading", "docloadtimeout", "uriinvalid", "syntax" ->
                    "변환기가 문서를 열지 못했습니다. 원본을 확인한 뒤 다시 시도해 주세요.";
            default -> null;
        };
    }

    boolean isCellEditorReady() {
        return ready && !previewOnly && !isFinishing() && !isDestroyed()
                && !OfficeEngineHealth.requiresRestart();
    }

    boolean postCellScript(String requestId, String script) {
        return sendEmbeddedScript(requestId, script);
    }

    JSONObject planCellText(String oldText, String newText) throws IOException {
        byte[] oldUtf8 = OfficeTextStylePlan.encodeText(oldText, 200000);
        byte[] newUtf8 = OfficeTextStylePlan.encodeText(newText, 8192);
        return OfficeTextStylePlan.decode(nativePlanCellText(oldUtf8, newUtf8), oldText, newText);
    }

    void completeCellScript() { completeEmbeddedScript(); }

    void closeCellEditor() { finishWithProgress(); }

    private OfficeSessionJournal journal() throws IOException {
        return new OfficeSessionJournal(new File(getFilesDir(), "office-sessions"), OfficeEngineBridge.VERSION);
    }

    private Intent editResult(Map<String, Object> exported) {
        Intent result = new Intent();
        for (String key : new String[]{"sourcePath", "sourceSha256", "sessionId", "inputSourceSha256"}) {
            result.putExtra(key, (String) exported.get(key));
        }
        if ("source_ready".equals(exported.get("status"))) return result.putExtra("piv.sourceReady", true);
        return result.putExtra("pdfPath", (String) exported.get("pdfPath"))
                .putExtra("pdfSha256", (String) exported.get("pdfSha256"))
                .putExtra("pdfPageCount", (Integer) exported.get("pdfPageCount"));
    }

    private void showPreviewProgress() {
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setGravity(Gravity.CENTER);
        content.setBackgroundColor(Color.WHITE);
        content.setClickable(true);
        content.setFocusableInTouchMode(true);
        content.setPadding(32, 32, 32, 32);
        content.addView(new ProgressBar(this));
        TextView label = new TextView(this);
        label.setText(reopenedSource ? "저장한 원본을 다시 열어 필기용 PDF를 준비하고 있습니다."
                : "원본을 바꾸지 않고 PDF를 준비하고 있습니다.");
        label.setPadding(0, 24, 0, 24);
        content.addView(label);
        Button cancel = new Button(this);
        cancel.setText("취소");
        cancel.setOnClickListener(view -> cancelPreview());
        content.addView(cancel);
        addContentView(content, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        content.requestFocus();
    }

    private void cancelPreview() {
        if (isFinishing()) return;
        previewCancelled = true;
        OfficePreviewOutputs.deleteResultRecord(directory);
        setResult(Activity.RESULT_CANCELED, new Intent().putExtra("sessionId", sessionId)
                .putExtra(OfficeEngineBridge.PREVIEW_CANCELLED_EXTRA, true));
        previewResultSet = true;
        finish();
    }

    private void deliverPreviewResult(int code, Intent result) {
        long posted = System.nanoTime();
        runOnUiThread(() -> {
            OfficeEngineProcess.log("preview result " + code + " reached the UI thread after "
                    + (System.nanoTime() - posted) / 1_000_000 + " ms session=" + sessionId);
            if (!previewCancelled && !isFinishing()) {
                setResult(code, result);
                previewResultSet = code == Activity.RESULT_CANCELED
                        || result.getBooleanExtra(OfficeEngineBridge.PREVIEW_PDF_READY_EXTRA, false);
                if (previewResultSet) finish();
            }
        });
    }

    @Override
    @JavascriptInterface
    public void postMobileMessage(String message) {
        if (!previewOnly && (message.equals("hideProgressbar") || message.startsWith("hideProgressbar "))) ready = true;
        super.postMobileMessage(message);
        if (!previewOnly && ready && presentationCells != null) {
            runOnUiThread(() -> {
                if (isCellEditorReady() && presentationCells != null) presentationCells.installButton();
            });
        }
    }

    @Override
    protected boolean beforeEmbeddedDocumentClose() {
        if (isEmbeddedDocumentBusy()) return false;
        if (previewOnly) return finishPreview();
        if (!ready || directory == null) {
            // Carries data: a result without data means the engine process died first.
            setResult(Activity.RESULT_CANCELED, new Intent().putExtra("sessionId", sessionId));
            return true;
        }
        File source = new File(directory, "edited." + format);
        try {
            Map<String, Object> previous = journal().recover(sessionId, inputSourceSha256);
            if ("saved".equals(previous.get("status")) || "source_ready".equals(previous.get("status"))) {
                runOnUiThread(() -> setResult(Activity.RESULT_OK, editResult(previous)));
                return true;
            }
            if (!"working".equals(previous.get("status"))) throw new IOException("Missing private working session");
            if (!saveOriginal(source.toURI().toString(), format)) {
                throw new IOException("문서 원본을 저장하지 못했습니다.");
            }
            Intent result = editResult(journal().recordSourceReady(sessionId, inputSourceSha256));
            runOnUiThread(() -> setResult(Activity.RESULT_OK, result));
            return true;
        } catch (Exception error) {
            if (finishOnFormatMismatch(error)) return true;
            runOnUiThread(() -> Toast.makeText(this,
                    "저장을 마치지 못했습니다. 다시 뒤로가기를 눌러주세요. 작업 복사본은 보관됩니다.", Toast.LENGTH_LONG).show());
            return false;
        }
    }

    private boolean finishPreview() {
        if (previewCancelled || previewLoadFailed) return true;
        if (!ready || directory == null) {
            deliverPreviewResult(Activity.RESULT_CANCELED, new Intent().putExtra("sessionId", sessionId)
                    .putExtra("errorCode", "office_preview_load_failed")
                    .putExtra("errorMessage", "변환기가 문서를 열지 못했습니다. PDF가 만들어지지 않았습니다."));
            return true;
        }
        if (legacyConversion) return finishLegacyConversion();
        File pdf = new File(directory, "preview.pdf");
        try {
            Map<String, Object> observation = null;
            if (nativeObservation) {
                int parts = nativePresentationPartCount();
                byte[] information = readNativePresentationInfo();
                observation = OfficeNativeObservation.write(directory, sessionId, inputSourceSha256,
                        format, OfficeEngineBridge.VERSION, parts, information);
            }
            if (!savePreviewPdf(pdf.toURI().toString(), format)) {
                throw new IOException("PDF 내보내기를 마치지 못했습니다.");
            }
            if (!working.isFile() || working.lastModified() != workingModified || !sha256(working).equals(workingSha256)) {
                throw new IOException("미리보기 작업 원본이 바뀌었습니다.");
            }
            if (!pdf.isFile() || pdf.length() == 0 || pdf.length() > 128L * 1024 * 1024) throw new IOException("PDF 파일을 확인하지 못했습니다.");
            int pages;
            try (ParcelFileDescriptor descriptor = ParcelFileDescriptor.open(pdf, ParcelFileDescriptor.MODE_READ_ONLY);
                 PdfRenderer renderer = new PdfRenderer(descriptor)) {
                pages = renderer.getPageCount();
                if (pages == 0) throw new IOException("PDF 페이지를 만들지 못했습니다.");
            }
            String pdfSha256 = sha256(pdf);
            OfficeEngineProcess.log("pdf ready pages=" + pages + " session=" + sessionId);
            if (!nativeObservation && !reopenedSource && !previewCancelled) {
                try {
                    // Lets the main process still accept this PDF if the engine process dies before finish().
                    OfficePreviewOutputs.writeResultRecord(directory, sessionId, workingSha256, pdfSha256, pages);
                    if (previewCancelled) OfficePreviewOutputs.deleteResultRecord(directory);
                } catch (IOException recordError) {
                    OfficeEngineProcess.log("preview result record not written session=" + sessionId);
                }
            }
            Intent result = new Intent().putExtra("pdfPath", pdf.getPath())
                    .putExtra("sourceSha256", workingSha256).putExtra("pdfSha256", pdfSha256)
                    .putExtra("pdfPageCount", pages).putExtra("sessionId", sessionId);
            if (observation != null) {
                result.putExtra("observationPath", (String) observation.get("observationPath"))
                        .putExtra("observationSha256", (String) observation.get("observationSha256"))
                        .putExtra("observationByteLength", (Integer) observation.get("observationByteLength"))
                        .putExtra("partCount", (Integer) observation.get("partCount"))
                        .putExtra("format", format);
            }
            if (!nativeObservation && !reopenedSource) {
                result.putExtra(OfficeEngineBridge.PREVIEW_PDF_READY_EXTRA, true);
            }
            deliverPreviewResult(Activity.RESULT_OK, result);
            return true;
        } catch (Exception error) {
            if (finishOnFormatMismatch(error)) return true;
            Intent result = new Intent().putExtra("sessionId", sessionId)
                    .putExtra("errorCode", nativeObservation ? OfficeNativeObservation.errorCode(error) : "office_preview_failed")
                    .putExtra("errorMessage", "PDF를 준비하지 못했습니다. 원본과 작업 복사본은 보관됩니다.");
            deliverPreviewResult(Activity.RESULT_CANCELED, result);
            return true;
        }
    }

    private boolean finishLegacyConversion() {
        String target = OfficePreviewOutputs.legacyTarget(format);
        try {
            if (target == null) throw new IOException("Invalid legacy conversion format");
            File converted = new File(directory, "converted." + target);
            if (Files.exists(converted.toPath(), LinkOption.NOFOLLOW_LINKS)
                    || !saveLegacyCopy(converted.toURI().toString(), format)) {
                throw new IOException("Unable to export a legacy document copy");
            }
            if (working.lastModified() != workingModified
                    || !workingSha256.equals(OfficeNativeObservation.sourceSha256(working))) {
                throw new IOException("The legacy working copy changed during conversion");
            }
            Intent result = new Intent().putExtra("sessionId", sessionId)
                    .putExtra("inputSourceSha256", workingSha256)
                    .putExtra("targetExtension", target)
                    .putExtra("sourcePath", new File(getIntent().getStringExtra("piv.sessionDirectory"), converted.getName()).getPath())
                    .putExtra("sourceSha256", OfficeNativeObservation.sourceSha256(converted));
            deliverPreviewResult(Activity.RESULT_OK, result);
        } catch (IOException error) {
            if (finishOnFormatMismatch(error)) return true;
            Intent result = new Intent().putExtra("sessionId", sessionId)
                    .putExtra("errorCode", "office_legacy_conversion_failed")
                    .putExtra("errorMessage", "편집용 복사본을 만들지 못했습니다. 기존 문서는 보관됩니다.");
            deliverPreviewResult(Activity.RESULT_CANCELED, result);
        }
        return true;
    }

    private boolean finishOnFormatMismatch(Exception error) {
        if (!(error instanceof IOException) || !FORMAT_MISMATCH.equals(error.getMessage())) return false;
        Intent result = new Intent().putExtra("sessionId", sessionId)
                .putExtra("errorCode", FORMAT_MISMATCH)
                .putExtra("errorMessage", OfficeLegacyContainer.MISMATCH_MESSAGE);
        if (previewOnly) deliverPreviewResult(Activity.RESULT_CANCELED, result);
        else runOnUiThread(() -> setResult(Activity.RESULT_CANCELED, result));
        return true;
    }

    private static String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] block = new byte[65536];
            int count;
            while ((count = input.read(block)) != -1) digest.update(block, 0, count);
        }
        StringBuilder hex = new StringBuilder();
        for (byte value : digest.digest()) hex.append(String.format("%02x", value & 255));
        return hex.toString();
    }

    private native boolean saveOriginal(String sourceUri, String format) throws IOException;
    private native boolean savePreviewPdf(String pdfUri, String format) throws IOException;
    private native boolean saveLegacyCopy(String sourceUri, String format) throws IOException;
    private native int nativePresentationPartCount() throws IOException;
    private native byte[] readNativePresentationInfo() throws IOException;
    private native byte[] nativePlanCellText(byte[] oldUtf8, byte[] newUtf8) throws IOException;
}
