package io.github.canele452.personalinkvault.office;

import android.app.Activity;
import android.content.Intent;
import android.os.Build;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.InvalidPathException;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class OfficeEngineBridge {
    public static final int REQUEST_EDIT = 19472;
    private static final int REQUEST_REOPEN = 19475;
    public static final String VERSION = "26.04.6.0-962";
    public static final List<String> FORMATS = Arrays.asList("docx", "pptx", "doc", "ppt", "odt", "odp");
    private final Activity activity;
    private final ExecutorService files = Executors.newSingleThreadExecutor();
    private final Object launchOwner = new Object();
    private final OfficePreviewOutputs previews;
    private Completion pending;
    private boolean pendingPreview;
    private boolean pendingObservation;
    private String pendingObservationFormat;
    private String pendingConversionSourcePath;
    private String pendingSessionId;
    private String pendingInputSourceSha256;
    private volatile boolean disposed;
    private String launchedPreviewSessionId;
    private boolean previewResultPending;
    private String reopenAttempt;
    private String reopenSourceSha256;

    public interface Completion {
        void success(Map<String, Object> result);
        void error(String code, String message);
    }

    public OfficeEngineBridge(Activity activity) {
        this.activity = activity;
        previews = new OfficePreviewOutputs(new File(activity.getFilesDir(), "office-previews"));
    }

    public Map<String, Object> capabilities() {
        boolean bundled;
        try (InputStream ignored = activity.getAssets().open("office-engine-provenance.json")) {
            bundled = true;
        } catch (IOException error) {
            bundled = false;
        }
        boolean supported = Build.VERSION.SDK_INT >= 26 && Arrays.asList(Build.SUPPORTED_ABIS).contains("arm64-v8a");
        Map<String, Object> result = new HashMap<>();
        result.put("available", bundled && supported);
        result.put("engineVersion", VERSION);
        result.put("editableFormats", bundled && supported ? FORMATS : Collections.emptyList());
        result.put("supportsHwp", false);
        result.put("supportsHwpx", false);
        result.put("supportsLegacyConversion", bundled && supported);
        result.put("restartRequired", OfficeEngineHealth.requiresRestart());
        return result;
    }

    public void edit(String sourcePath, String sessionId, Completion completion) {
        open(sourcePath, sessionId, false, completion);
    }

    public void preview(String sourcePath, String sessionId, Completion completion) {
        open(sourcePath, sessionId, true, completion);
    }

    public void inspect(String sourcePath, String sessionId, String inputSourceSha256, Completion completion) {
        try {
            OfficeSessionJournal.validateRequest(sessionId, inputSourceSha256);
            if (sourcePath == null || !new File(sourcePath).isAbsolute()
                    || !Arrays.asList("ppt", "pptx", "odp").contains(extension(sourcePath))) {
                throw new IOException("invalid_office_observation");
            }
        } catch (IOException error) {
            completion.error("invalid_request", "관측할 프레젠테이션 원본과 세션을 확인하세요.");
            return;
        }
        open(sourcePath, sessionId, true, true, false, inputSourceSha256, completion);
    }

    public void convertLegacy(String sourcePath, String sessionId, String inputSourceSha256, Completion completion) {
        try {
            OfficeSessionJournal.validateRequest(sessionId, inputSourceSha256);
            if (sourcePath == null || OfficePreviewOutputs.legacyTarget(extension(sourcePath)) == null) {
                throw new IOException("Invalid legacy conversion format");
            }
        } catch (IOException error) {
            completion.error("invalid_request", "변환할 구형 문서 원본과 세션을 확인하세요.");
            return;
        }
        open(sourcePath, sessionId, true, false, true, inputSourceSha256, completion);
    }

    public void releasePreview(String sessionId, Completion completion) {
        if (files.isShutdown()) {
            completion.success(Collections.emptyMap());
            return;
        }
        files.execute(() -> {
            try {
                previews.release(sessionId);
            } catch (IOException ignored) {
                // Cleanup is best effort and never changes the consumed result.
            }
            activity.runOnUiThread(() -> completion.success(Collections.emptyMap()));
        });
    }

    public void recover(String sessionId, String inputSourceSha256, Completion completion) {
        recovery(sessionId, inputSourceSha256, false, completion);
    }

    public void resume(String sessionId, String inputSourceSha256, Completion completion) {
        recovery(sessionId, inputSourceSha256, true, completion);
    }

    public void validateLegacySource(String sourcePath, String format, String sourceSha256, Completion completion) {
        if (disposed) {
            completion.error("office_interrupted", "문서 복구 화면이 종료되었습니다.");
            return;
        }
        files.execute(() -> {
            try {
                File source = recoverySource(sourcePath, format, sourceSha256);
                verifyRecoveryHash(source, sourceSha256);
                try {
                    OfficeLegacyContainer.validate(source, format);
                } finally {
                    verifyRecoveryHash(source, sourceSha256);
                }
                activity.runOnUiThread(() -> {
                    if (disposed) completion.error("office_interrupted", "문서 복구 화면이 종료되었습니다.");
                    else completion.success(Collections.emptyMap());
                });
            } catch (OfficeLegacyContainer.FormatMismatch error) {
                activity.runOnUiThread(() -> completion.error(OfficeLegacyContainer.MISMATCH_CODE,
                        OfficeLegacyContainer.MISMATCH_MESSAGE));
            } catch (IOException | InvalidPathException error) {
                activity.runOnUiThread(() -> completion.error("office_recovery_invalid",
                        "복구 원본 파일과 기록을 확인하지 못했습니다. 파일은 보관됩니다."));
            }
        });
    }

    private static File recoverySource(String sourcePath, String format, String hash) throws IOException {
        if (sourcePath == null || !OfficeLegacyContainer.supports(format)) throw new IOException("Invalid recovery source");
        Path path = new File(sourcePath).toPath();
        int count = path.getNameCount();
        if (!path.isAbsolute() || !path.equals(path.normalize()) || count < 6) throw new IOException("Invalid recovery path");
        Path tail = path.subpath(count - 6, count);
        if (!".workspace".equals(tail.getName(0).toString()) || !"office-recovery".equals(tail.getName(1).toString())
                || !"native".equals(tail.getName(4).toString()) || !("edited." + format).equals(tail.getFileName().toString())) {
            throw new IOException("Invalid recovery path");
        }
        OfficeSessionJournal.validateSessionId(tail.getName(2).toString());
        OfficeSessionJournal.validateRequest(tail.getName(3).toString(), hash);
        Path owned = path;
        for (int index = 0; index < 6; index++, owned = owned.getParent()) {
            if (Files.isSymbolicLink(owned)) throw new IOException("Invalid recovery link");
        }
        return path.toFile();
    }

    private static void verifyRecoveryHash(File source, String expected) throws IOException {
        if (!expected.equals(OfficeNativeObservation.sourceSha256(source))) throw new IOException("Invalid recovery digest");
    }

    private boolean available(Completion completion) {
        if (disposed) {
            completion.error("office_interrupted", "문서 편집 화면이 종료되었습니다.");
            return false;
        }
        if (pending != null || previewResultPending || OfficeSessionJournal.hasLiveEditor()) {
            completion.error("office_busy", "문서 편집기가 이미 열려 있습니다.");
            return false;
        }
        return true;
    }

    private OfficeSessionJournal journal() throws IOException {
        return new OfficeSessionJournal(new File(activity.getFilesDir(), "office-sessions"), VERSION);
    }

    private void recovery(String sessionId, String inputSourceSha256, boolean resume, Completion completion) {
        if (!available(completion)) return;
        try {
            OfficeSessionJournal.validateRequest(sessionId, inputSourceSha256);
        } catch (IOException error) {
            completion.error("invalid_request", "복구할 문서 세션과 원본 해시를 확인하세요.");
            return;
        }
        pending = completion;
        pendingPreview = false;
        pendingObservation = false;
        pendingObservationFormat = null;
        pendingConversionSourcePath = null;
        pendingSessionId = sessionId;
        pendingInputSourceSha256 = inputSourceSha256;
        files.execute(() -> {
            try {
                Map<String, Object> result = journal().recover(sessionId, inputSourceSha256);
                activity.runOnUiThread(() -> {
                    if (disposed || pending != completion) return;
                    if ("source_ready".equals(result.get("status"))) {
                        if (resume) startSourceReopen(null);
                        else {
                            Map<String, Object> working = new HashMap<>(result);
                            working.put("status", "working");
                            working.remove("sourcePath");
                            working.remove("sourceSha256");
                            succeed(working);
                        }
                        return;
                    }
                    if (!resume || "saved".equals(result.get("status"))) {
                        succeed(result);
                    } else if ("working".equals(result.get("status"))) {
                        if (OfficeEngineHealth.requiresRestart()) {
                            fail(OfficeEngineHealth.ERROR_CODE, OfficeEngineHealth.RECOVERY_MESSAGE);
                            return;
                        }
                        if (!Boolean.TRUE.equals(capabilities().get("available"))) {
                            fail("office_unavailable", "이 기기에 맞는 문서 편집 엔진이 없습니다.");
                            return;
                        }
                        File working = new File((String) result.get("workingPath"));
                        launch(working, working.getParentFile(), extension(working.getName()), sessionId, inputSourceSha256, false);
                    } else {
                        fail("office_session_missing", "기기에 보관된 문서 작업을 찾을 수 없습니다.");
                    }
                });
            } catch (IOException error) {
                activity.runOnUiThread(() -> {
                    if (pending != completion) return;
                    if (error instanceof OfficeLegacyContainer.FormatMismatch) {
                        fail(OfficeLegacyContainer.MISMATCH_CODE, OfficeLegacyContainer.MISMATCH_MESSAGE);
                    } else {
                        fail("office_recovery_invalid", "문서 복구 파일과 세션 결합을 확인하지 못했습니다. 파일은 보관됩니다.");
                    }
                });
            }
        });
    }

    private void open(String sourcePath, String sessionId, boolean previewOnly, Completion completion) {
        open(sourcePath, sessionId, previewOnly, false, false, null, completion);
    }

    private void open(String sourcePath, String sessionId, boolean previewOnly, boolean observeNative,
            boolean convertLegacy, String expectedSourceSha256, Completion completion) {
        if (!available(completion)) return;
        if (OfficeEngineHealth.requiresRestart()) {
            completion.error(OfficeEngineHealth.ERROR_CODE, OfficeEngineHealth.RECOVERY_MESSAGE);
            return;
        }
        if (!Boolean.TRUE.equals(capabilities().get("available"))) {
            completion.error("office_unavailable", "이 기기에 맞는 문서 편집 엔진이 없습니다.");
            return;
        }
        if (sourcePath == null || sessionId == null || sessionId.isEmpty()) {
            completion.error("invalid_request", "편집할 문서 정보가 없습니다.");
            return;
        }
        String extension = extension(sourcePath);
        if (!FORMATS.contains(extension)) {
            completion.error("format_unsupported", "이 형식은 아직 원본 편집을 지원하지 않습니다.");
            return;
        }
        pending = completion;
        pendingPreview = previewOnly;
        pendingObservation = observeNative;
        pendingObservationFormat = observeNative ? extension : null;
        pendingConversionSourcePath = convertLegacy ? sourcePath : null;
        pendingSessionId = sessionId;
        pendingInputSourceSha256 = null;
        files.execute(() -> {
            boolean previewCreated = false;
            try {
                File original = convertLegacy
                        ? OfficePreviewOutputs.conversionInput(activity.getCacheDir(), sourcePath, extension)
                        : new File(sourcePath).getCanonicalFile();
                if (!original.isFile() || original.length() == 0 || original.length() > 128L * 1024 * 1024) throw new IOException("문서 파일을 읽을 수 없습니다.");
                final File working;
                final String inputHash;
                if (previewOnly) {
                    File directory = previews.create(sessionId);
                    previewCreated = true;
                    working = new File(directory, "working." + extension);
                    if (convertLegacy) {
                        try (InputStream input = Files.newInputStream(original.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                            Files.copy(input, working.toPath());
                        }
                        if (!expectedSourceSha256.equals(OfficeNativeObservation.sourceSha256(original))) {
                            throw new IOException("Invalid conversion input digest");
                        }
                    } else {
                        Files.copy(original.toPath(), working.toPath());
                    }
                    if ((observeNative || convertLegacy)
                            && !expectedSourceSha256.equals(OfficeNativeObservation.sourceSha256(working))) {
                        throw new IOException(convertLegacy ? "Invalid conversion working digest" : "invalid_office_observation");
                    }
                    if (OfficeLegacyContainer.supports(extension)) OfficeSessionJournal.validateOffice(working, extension);
                    inputHash = observeNative || convertLegacy ? expectedSourceSha256 : null;
                } else {
                    Map<String, Object> prepared = journal().create(original, sessionId, extension);
                    working = new File((String) prepared.get("workingPath"));
                    inputHash = (String) prepared.get("inputSourceSha256");
                }
                activity.runOnUiThread(() -> {
                    if (disposed || pending != completion) {
                        if (previewOnly) discardPreview(sessionId, null);
                        return;
                    }
                    pendingInputSourceSha256 = inputHash;
                    launch(working, working.getParentFile(), extension, sessionId, inputHash, previewOnly);
                });
            } catch (IOException | InvalidPathException error) {
                if (previewCreated) {
                    try { previews.discard(sessionId); } catch (IOException ignored) {}
                }
                activity.runOnUiThread(() -> {
                    if (pending == completion) {
                        if (error instanceof OfficeLegacyContainer.FormatMismatch) {
                            fail(OfficeLegacyContainer.MISMATCH_CODE, OfficeLegacyContainer.MISMATCH_MESSAGE);
                        } else if (convertLegacy) {
                            fail("invalid_office_conversion", "변환할 구형 문서 원본을 확인하지 못했습니다.");
                        } else {
                            fail(observeNative ? OfficeNativeObservation.errorCode(error) : "office_open_failed", error.getMessage());
                        }
                    }
                    if (disposed && previewOnly) files.shutdown();
                });
            }
        });
    }

    private void launch(File working, File directory, String extension, String sessionId, String inputHash, boolean previewOnly) {
        launch(working, directory, extension, sessionId, inputHash, previewOnly, false);
    }

    private void launch(File working, File directory, String extension, String sessionId, String inputHash,
            boolean previewOnly, boolean reopenedSource) {
        if (disposed || pending == null || activity.isFinishing() || activity.isDestroyed()) {
            if (previewOnly) discardPreview(sessionId, () -> fail("office_interrupted", "문서 미리보기 화면이 종료되었습니다."));
            return;
        }
        if (!OfficeSessionJournal.reserveEditor(sessionId, launchOwner)) {
            if (previewOnly) discardPreview(sessionId, () -> fail("office_busy", "문서 편집기가 이미 열려 있습니다."));
            else fail("office_busy", "문서 편집기가 이미 열려 있습니다.");
            return;
        }
        try {
            Class.forName(OfficeEditorActivity.class.getName(), true, activity.getClassLoader());
            Intent intent = new Intent(activity, OfficeEditorActivity.class)
                    .setAction(previewOnly ? Intent.ACTION_VIEW : Intent.ACTION_EDIT)
                    .putExtra("piv.workingPath", working.getPath())
                    .putExtra("piv.sessionDirectory", directory.getPath())
                    .putExtra("piv.sessionId", sessionId)
                    .putExtra("piv.inputSourceSha256", inputHash)
                    .putExtra("piv.previewOnly", previewOnly)
                    .putExtra("piv.nativeObservation", pendingObservation)
                    .putExtra("piv.legacyConversion", pendingConversionSourcePath != null)
                    .putExtra("piv.reopenedSource", reopenedSource)
                    .putExtra("piv.format", extension);
            activity.startActivityForResult(intent, reopenedSource ? REQUEST_REOPEN : REQUEST_EDIT);
            if (previewOnly && !reopenedSource) launchedPreviewSessionId = sessionId;
        } catch (Throwable error) {
            OfficeSessionJournal.releaseEditor(launchOwner);
            String message = "문서 편집 엔진을 열지 못했습니다. " + error.getClass().getSimpleName();
            if (previewOnly) discardPreview(sessionId, () -> fail("office_engine_load_failed", message));
            else fail("office_engine_load_failed", message);
        }
    }

    public boolean handleActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == REQUEST_REOPEN) {
            finishSourceReopen(resultCode, data);
            return true;
        }
        if (requestCode != REQUEST_EDIT) return false;
        if (reopenAttempt != null) return true;
        if (resultCode == Activity.RESULT_OK && data != null && data.getBooleanExtra("piv.sourceReady", false)) {
            if (pending != null && !pendingPreview && pendingInputSourceSha256 != null
                    && pendingSessionId.equals(data.getStringExtra("sessionId"))
                    && pendingInputSourceSha256.equals(data.getStringExtra("inputSourceSha256"))) {
                OfficeSessionJournal.releaseEditor(launchOwner);
                startSourceReopen(data);
            }
            return true;
        }
        OfficeSessionJournal.releaseEditor(launchOwner);
        Completion completion = pending;
        boolean previewOnly = pendingPreview;
        boolean observeNative = pendingObservation;
        String observationFormat = pendingObservationFormat;
        String conversionSourcePath = pendingConversionSourcePath;
        String expectedSession = pendingSessionId;
        String expectedInputHash = pendingInputSourceSha256;
        String closedPreviewSession = launchedPreviewSessionId;
        launchedPreviewSessionId = null;
        if (completion == null && closedPreviewSession == null) return true;
        if (closedPreviewSession != null) previewOnly = true;
        if (previewOnly) previewResultPending = true;
        pending = null;
        pendingSessionId = null;
        pendingInputSourceSha256 = null;
        pendingObservation = false;
        pendingObservationFormat = null;
        pendingConversionSourcePath = null;
        if (previewOnly) {
            finishPreviewResult(expectedSession == null ? closedPreviewSession : expectedSession,
                    completion, resultCode, data, observeNative, expectedInputHash, observationFormat, conversionSourcePath);
            return true;
        }
        if (completion == null) return true;
        if (data != null && data.hasExtra("sessionId") && !expectedSession.equals(data.getStringExtra("sessionId"))) {
            completion.error("invalid_office_result", "다른 문서의 저장 결과를 거부했습니다.");
            return true;
        }
        if (data != null && data.hasExtra("errorCode")) {
            completion.error(data.getStringExtra("errorCode"), data.getStringExtra("errorMessage"));
            return true;
        }
        if (!previewOnly && data != null && data.hasExtra("inputSourceSha256") &&
                (expectedInputHash == null || !expectedInputHash.equals(data.getStringExtra("inputSourceSha256")))) {
            completion.error("invalid_office_result", "다른 원본의 저장 결과를 거부했습니다.");
            return true;
        }
        Map<String, Object> result = new HashMap<>();
        result.put("engineVersion", VERSION);
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.put("status", "cancelled");
            if (!previewOnly) {
                result.put("sessionId", expectedSession);
                result.put("inputSourceSha256", expectedInputHash);
            }
        } else if (!previewOnly) {
            files.execute(() -> {
                try {
                    Map<String, Object> saved = journal().recover(expectedSession, expectedInputHash);
                    if (!"saved".equals(saved.get("status"))) throw new IOException("Missing saved marker");
                    for (String key : new String[]{"sourcePath", "pdfPath", "sourceSha256", "pdfSha256", "sessionId", "inputSourceSha256"}) {
                        if (!saved.get(key).equals(data.getStringExtra(key))) throw new IOException("Saved result binding mismatch");
                    }
                    if (!saved.get("pdfPageCount").equals(data.getIntExtra("pdfPageCount", 0))) throw new IOException("Saved page count mismatch");
                    activity.runOnUiThread(() -> {
                        if (disposed) completion.error("office_interrupted", "문서 결과는 기기에 보관됩니다. 복구에서 다시 확인하세요.");
                        else completion.success(saved);
                    });
                } catch (OfficeLegacyContainer.FormatMismatch error) {
                    activity.runOnUiThread(() -> completion.error(OfficeLegacyContainer.MISMATCH_CODE,
                            OfficeLegacyContainer.MISMATCH_MESSAGE));
                } catch (IOException error) {
                    activity.runOnUiThread(() -> completion.error("invalid_office_result", "보관된 문서 저장 결과의 무결성을 확인하지 못했습니다."));
                }
            });
            return true;
        } else {
            result.put("status", previewOnly ? "previewed" : "saved");
            for (String key : new String[]{"sourcePath", "pdfPath", "sourceSha256", "pdfSha256", "sessionId"}) {
                result.put(key, data.getStringExtra(key));
            }
            result.put("pdfPageCount", data.getIntExtra("pdfPageCount", 0));
        }
        completion.success(result);
        return true;
    }

    private void startSourceReopen(Intent sourceResult) {
        String sessionId = pendingSessionId;
        String inputHash = pendingInputSourceSha256;
        String attempt = UUID.randomUUID().toString();
        reopenAttempt = attempt;
        files.execute(() -> {
            try {
                awaitClosed(sessionId);
                Map<String, Object> source = journal().recover(sessionId, inputHash);
                if (sourceResult != null) {
                    for (String key : new String[]{"sessionId", "inputSourceSha256", "sourcePath", "sourceSha256"}) {
                        String returned = sourceResult.getStringExtra(key);
                        if (returned == null || !returned.equals(source.get(key))) {
                            throw new IOException("Saved source result binding mismatch");
                        }
                    }
                }
                if ("saved".equals(source.get("status"))) {
                    activity.runOnUiThread(() -> {
                        if (attempt.equals(reopenAttempt)) succeed(source);
                    });
                    return;
                }
                if (!"source_ready".equals(source.get("status"))) throw new IOException("Missing saved source");
                String sourceHash = (String) source.get("sourceSha256");
                File edited = new File((String) source.get("sourcePath"));
                String format = extension(edited.getName());
                File directory = previews.create(attempt);
                File working = new File(directory, "working." + format);
                try (InputStream input = Files.newInputStream(edited.toPath(), LinkOption.NOFOLLOW_LINKS)) {
                    Files.copy(input, working.toPath());
                }
                verifyRecoveryHash(working, sourceHash);
                activity.runOnUiThread(() -> {
                    if (!attempt.equals(reopenAttempt)) return;
                    if (OfficeEngineHealth.requiresRestart()) {
                        discardPreview(attempt, () -> fail(OfficeEngineHealth.ERROR_CODE, OfficeEngineHealth.RECOVERY_MESSAGE));
                        return;
                    }
                    if (!Boolean.TRUE.equals(capabilities().get("available"))) {
                        discardPreview(attempt, () -> fail("office_unavailable", "이 기기에 맞는 문서 편집 엔진이 없습니다."));
                        return;
                    }
                    reopenSourceSha256 = sourceHash;
                    launch(working, directory, format, attempt, sourceHash, true, true);
                });
            } catch (IOException | InvalidPathException error) {
                try { previews.discard(attempt); } catch (IOException ignored) {}
                activity.runOnUiThread(() -> {
                    if (!attempt.equals(reopenAttempt)) return;
                    if (error instanceof OfficeLegacyContainer.FormatMismatch) {
                        fail(OfficeLegacyContainer.MISMATCH_CODE, OfficeLegacyContainer.MISMATCH_MESSAGE);
                    } else {
                        fail("office_reopen_failed", "필기용 PDF를 준비하지 못했습니다. 저장한 원본은 복구에 남아 있습니다.");
                    }
                });
            }
        });
    }

    private void finishSourceReopen(int resultCode, Intent data) {
        String attempt = reopenAttempt;
        String sourceHash = reopenSourceSha256;
        if (attempt == null || sourceHash == null || (data != null && data.hasExtra("sessionId")
                && !attempt.equals(data.getStringExtra("sessionId")))) return;
        reopenSourceSha256 = null;
        OfficeSessionJournal.releaseEditor(launchOwner);
        String sessionId = pendingSessionId;
        String inputHash = pendingInputSourceSha256;
        files.execute(() -> {
            Map<String, Object> saved = null;
            String errorCode = "office_reopen_failed";
            boolean closed = false;
            try {
                awaitClosed(attempt);
                closed = true;
                if (resultCode == Activity.RESULT_OK && data != null) {
                    if (!attempt.equals(data.getStringExtra("sessionId"))
                            || !sourceHash.equals(data.getStringExtra("sourceSha256"))) {
                        throw new IOException("Reopened preview result binding mismatch");
                    }
                    File pdf = previews.complete(attempt, data.getStringExtra("pdfPath"));
                    saved = journal().recordReopenedPreview(sessionId, inputHash, sourceHash, pdf,
                            data.getStringExtra("pdfSha256"), data.getIntExtra("pdfPageCount", 0));
                } else if (data == null || !data.hasExtra("errorCode")) {
                    errorCode = "office_reopen_cancelled";
                } else {
                    errorCode = data.getStringExtra("errorCode");
                }
            } catch (IOException | InvalidPathException error) {
                if (error instanceof OfficeLegacyContainer.FormatMismatch) errorCode = OfficeLegacyContainer.MISMATCH_CODE;
            } finally {
                if (closed) {
                    try { previews.discard(attempt); } catch (IOException ignored) {}
                }
            }
            final Map<String, Object> result = saved;
            final String code = errorCode;
            activity.runOnUiThread(() -> {
                if (!attempt.equals(reopenAttempt)) return;
                if (result != null) succeed(result);
                else fail(code, "필기용 PDF를 마치지 못했습니다. 저장한 원본은 복구에 남아 있습니다.");
            });
        });
    }

    private void discardClosedReopen(String attempt) {
        try {
            awaitClosed(attempt);
            previews.discard(attempt);
        } catch (IOException ignored) {}
    }

    public void dispose() {
        disposed = true;
        boolean previewInFlight = (pending != null && pendingPreview)
                || launchedPreviewSessionId != null || previewResultPending;
        String attempt = reopenAttempt;
        if (attempt != null) files.execute(() -> discardClosedReopen(attempt));
        if (pending != null) fail("office_interrupted", "문서 편집 화면이 종료되었습니다. 작업 복사본은 기기에 보관됩니다.");
        if (!previewInFlight) files.shutdown();
    }

    private void discardPreview(String sessionId, Runnable after) {
        files.execute(() -> {
            try { previews.discard(sessionId); } catch (IOException ignored) {}
            activity.runOnUiThread(() -> {
                previewResultPending = false;
                if (after != null) after.run();
                if (disposed) files.shutdown();
            });
        });
    }

    private void finishPreviewResult(String sessionId, Completion completion, int resultCode, Intent data,
            boolean observeNative, String expectedSourceHash, String expectedFormat, String conversionSourcePath) {
        files.execute(() -> {
            Map<String, Object> result = new HashMap<>();
            result.put("engineVersion", VERSION);
            String errorCode = null;
            String errorMessage = null;
            boolean ready = false;
            if (data != null && data.hasExtra("sessionId")
                    && (sessionId == null || !sessionId.equals(data.getStringExtra("sessionId")))) {
                errorCode = "invalid_office_result";
                errorMessage = "다른 문서의 미리보기 결과를 거부했습니다.";
            } else if (data != null && data.hasExtra("errorCode")) {
                errorCode = data.getStringExtra("errorCode");
                errorMessage = data.getStringExtra("errorMessage");
            } else if (resultCode != Activity.RESULT_OK || data == null) {
                result.put("status", "cancelled");
                if (observeNative || conversionSourcePath != null) result.put("sessionId", sessionId);
            } else if (!disposed && completion != null && conversionSourcePath != null) {
                try {
                    completeLegacyConversion(result, data, sessionId, expectedSourceHash, conversionSourcePath);
                    ready = true;
                } catch (IOException | InvalidPathException error) {
                    errorCode = "invalid_office_conversion";
                    errorMessage = "이 작업의 편집용 복사본을 확인하지 못했습니다.";
                }
            } else if (!disposed && completion != null) {
                try {
                    File pdf = previews.complete(sessionId, data.getStringExtra("pdfPath"));
                    result.put("status", "previewed");
                    result.put("sessionId", sessionId);
                    result.put("pdfPath", pdf.getPath());
                    result.put("sourceSha256", data.getStringExtra("sourceSha256"));
                    result.put("pdfSha256", data.getStringExtra("pdfSha256"));
                    result.put("pdfPageCount", data.getIntExtra("pdfPageCount", 0));
                    if (observeNative) {
                        if (expectedSourceHash == null || expectedFormat == null
                                || !expectedSourceHash.equals(data.getStringExtra("sourceSha256"))
                                || !expectedFormat.equals(data.getStringExtra("format"))
                                || !OfficeNativeObservation.sourceSha256(pdf).equals(data.getStringExtra("pdfSha256"))) {
                            throw new IOException("invalid_office_observation");
                        }
                        Map<String, Object> observation = OfficeNativeObservation.read(pdf.getParentFile(),
                                sessionId, expectedSourceHash, expectedFormat, VERSION);
                        for (String key : new String[]{"observationPath", "observationSha256"}) {
                            if (!observation.get(key).equals(data.getStringExtra(key))) {
                                throw new IOException("invalid_office_observation");
                            }
                        }
                        if (!observation.get("observationByteLength").equals(data.getIntExtra("observationByteLength", 0))
                                || !observation.get("partCount").equals(data.getIntExtra("partCount", 0))) {
                            throw new IOException("invalid_office_observation");
                        }
                        result.putAll(observation);
                        result.put("status", "inspected");
                    }
                    ready = true;
                } catch (IOException error) {
                    errorCode = observeNative ? OfficeNativeObservation.errorCode(error) : "invalid_office_preview";
                    errorMessage = "이 미리보기 작업에 속한 PDF를 확인하지 못했습니다.";
                }
            }
            if (!ready) {
                try { previews.discard(sessionId); } catch (IOException ignored) {}
            }
            final String code = errorCode;
            final String message = errorMessage;
            final boolean retained = ready;
            activity.runOnUiThread(() -> {
                if (disposed || completion == null) {
                    if (retained) discardPreview(sessionId, null);
                    else {
                        previewResultPending = false;
                        if (disposed) files.shutdown();
                    }
                    if (completion != null) completion.error("office_interrupted", "문서 미리보기 화면이 종료되었습니다.");
                } else {
                    previewResultPending = false;
                    if (code != null) completion.error(code, message == null ? code : message);
                    else completion.success(result);
                }
            });
        });
    }

    private void completeLegacyConversion(Map<String, Object> result, Intent data, String sessionId,
            String expectedSourceHash, String sourcePath) throws IOException {
        OfficeSessionJournal.validateRequest(sessionId, expectedSourceHash);
        String sourceFormat = extension(sourcePath);
        String target = OfficePreviewOutputs.legacyTarget(sourceFormat);
        if (!sessionId.equals(data.getStringExtra("sessionId")) || target == null
                || !target.equals(data.getStringExtra("targetExtension"))
                || !expectedSourceHash.equals(data.getStringExtra("inputSourceSha256"))) {
            throw new IOException("Invalid conversion result identity");
        }
        // Android can dispatch Activity results before the old editor's onDestroy.
        // Dart may immediately reopen the converted copy to create its PDF.
        awaitClosed(sessionId);
        File input = OfficePreviewOutputs.conversionInput(activity.getCacheDir(), sourcePath, sourceFormat);
        File converted = previews.completeConversion(sessionId, data.getStringExtra("sourcePath"), sourceFormat);
        File working = new File(converted.getParentFile(), "working." + sourceFormat);
        OfficeSessionJournal.validateOffice(converted, target);
        String convertedHash = OfficeNativeObservation.sourceSha256(converted);
        if (!convertedHash.equals(data.getStringExtra("sourceSha256"))
                || !expectedSourceHash.equals(OfficeNativeObservation.sourceSha256(input))
                || !expectedSourceHash.equals(OfficeNativeObservation.sourceSha256(working))) {
            throw new IOException("Invalid conversion result digest");
        }
        result.put("status", "converted");
        result.put("sessionId", sessionId);
        result.put("inputSourceSha256", expectedSourceHash);
        result.put("targetExtension", target);
        result.put("sourcePath", converted.getPath());
        result.put("sourceSha256", convertedHash);
    }

    private void fail(String code, String message) {
        Completion completion = pending;
        pending = null;
        pendingSessionId = null;
        pendingInputSourceSha256 = null;
        pendingObservation = false;
        pendingObservationFormat = null;
        pendingConversionSourcePath = null;
        reopenAttempt = null;
        reopenSourceSha256 = null;
        if (completion != null) completion.error(code, message == null ? code : message);
    }

    private void succeed(Map<String, Object> result) {
        Completion completion = pending;
        pending = null;
        pendingSessionId = null;
        pendingInputSourceSha256 = null;
        pendingObservation = false;
        pendingObservationFormat = null;
        pendingConversionSourcePath = null;
        reopenAttempt = null;
        reopenSourceSha256 = null;
        if (completion != null) completion.success(result);
    }

    private static void awaitClosed(String sessionId) throws IOException {
        try {
            if (!OfficeSessionJournal.awaitEditorRelease(sessionId, 10000)) {
                throw new IOException("Timed out waiting for the office editor to close");
            }
        } catch (InterruptedException error) {
            Thread.currentThread().interrupt();
            throw new IOException("Interrupted while closing the office editor", error);
        }
    }

    private static String extension(String path) {
        int dot = path.lastIndexOf('.');
        return dot < 0 ? "" : path.substring(dot + 1).toLowerCase(Locale.ROOT);
    }
}
