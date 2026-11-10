package io.github.canele452.personalinkvault.office;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

final class OfficeLegacyContainer {
    static final String MISMATCH_CODE = "office_format_mismatch";
    static final String MISMATCH_MESSAGE = "파일 확장자와 실제 문서 종류가 일치하지 않습니다. 원본은 보관됩니다.";

    private static final int WORD = 1;
    private static final int PRESENTATION = 2;

    private OfficeLegacyContainer() {}

    static boolean supports(String format) {
        return "doc".equals(format) || "ppt".equals(format);
    }

    static void validate(File file, String format) throws IOException {
        int expected = "doc".equals(format) ? WORD : PRESENTATION;
        int actual;
        try {
            actual = Library.classify(file.getPath().getBytes(StandardCharsets.UTF_8));
        } catch (LinkageError unavailable) {
            throw new IOException("구형 Office 파일의 형식 검사 엔진을 불러오지 못했습니다. 원본은 보관됩니다.", unavailable);
        }
        if (actual == expected) return;
        if (actual == WORD || actual == PRESENTATION) throw new FormatMismatch();
        throw new IOException("구형 Office 파일의 실제 형식을 확인하지 못했습니다. 원본은 보관됩니다.");
    }

    static final class FormatMismatch extends IOException {
        private FormatMismatch() {
            super(MISMATCH_CODE);
        }
    }

    private static native int classifyNative(byte[] path);

    private static final class Library {
        static { System.loadLibrary("ink_hwp_native"); }

        private static int classify(byte[] path) {
            return classifyNative(path);
        }
    }
}
