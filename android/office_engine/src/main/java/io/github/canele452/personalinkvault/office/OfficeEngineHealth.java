package io.github.canele452.personalinkvault.office;

/**
 * A failed native session is never reused. The engine runs in its own process (":office"), which the
 * main process stops after the failure, so the next document starts a fresh engine.
 */
public final class OfficeEngineHealth {
    public static final String ERROR_CODE = "office_engine_restart_required";
    public static final String RECOVERY_MESSAGE =
            "문서 엔진이 응답하지 않아 엔진을 다시 시작합니다. 원본과 작업 복사본은 보관됩니다. "
            + "잠시 뒤 다시 시도해 주세요. 다른 앱 기능은 계속 사용할 수 있습니다.";
    private static volatile boolean restartRequired;

    private OfficeEngineHealth() {}

    public static boolean requiresRestart() { return restartRequired; }

    public static void quarantine() { restartRequired = true; }
}
