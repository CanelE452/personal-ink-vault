package io.github.canele452.personalinkvault.office;

/** A failed native session is never reused before Android restarts the process. */
public final class OfficeEngineHealth {
    public static final String ERROR_CODE = "office_engine_restart_required";
    public static final String RECOVERY_MESSAGE =
            "문서 엔진이 응답을 마치지 못했습니다. 원본과 작업 복사본은 보관됩니다. "
            + "Android 설정에서 이 앱을 강제 종료한 뒤 다시 열어주세요. 다른 앱 기능은 계속 사용할 수 있습니다.";
    private static volatile boolean restartRequired;

    private OfficeEngineHealth() {}

    public static boolean requiresRestart() { return restartRequired; }

    public static void quarantine() { restartRequired = true; }
}
