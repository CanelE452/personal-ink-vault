#include <jni.h>
#include <memory>
#include <cstddef>
#include <dlfcn.h>
#include <string>
#include <string_view>
#include "COKit.hxx"

std::shared_ptr<COKitDocument> getLOKDocumentForAndroidOnly();

namespace {
constexpr char kPresentationPdfOptions[] =
    R"({"ExportHiddenSlides":{"type":"boolean","value":"true"},)"
    R"("ExportNotesPages":{"type":"boolean","value":"false"},)"
    R"("ExportOnlyNotesPages":{"type":"boolean","value":"false"}})";

void throwOfficeError(JNIEnv* env, const char* code) {
    if (env->ExceptionCheck()) return;
    jclass exception = env->FindClass("java/io/IOException");
    if (exception) {
        env->ThrowNew(exception, code);
        env->DeleteLocalRef(exception);
    }
}

bool isPresentationFormat(std::string_view format) {
    return format == "ppt" || format == "pptx" || format == "odp";
}

bool requireDocumentFamily(JNIEnv* env, COKitDocument& document, std::string_view format) {
    const bool word = format == "doc" || format == "docx" || format == "odt";
    try {
        const auto actual = document.getDocumentType();
        if ((word && actual == COKitDocumentType::TEXT) ||
                (isPresentationFormat(format) && actual == COKitDocumentType::PRESENTATION)) return true;
    } catch (...) {
        return false;
    }
    throwOfficeError(env, "office_format_mismatch");
    return false;
}
}

extern "C" JNIEXPORT jboolean JNICALL
Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_savePreviewPdf(
    JNIEnv* env, jobject, jstring pdf, jstring format) {
    auto document = getLOKDocumentForAndroidOnly();
    if (!document) return JNI_FALSE;
    const char* formatName = env->GetStringUTFChars(format, nullptr);
    if (!formatName) return JNI_FALSE;
    const bool matches = requireDocumentFamily(env, *document, formatName);
    const char* options = isPresentationFormat(formatName) ? kPresentationPdfOptions : nullptr;
    env->ReleaseStringUTFChars(format, formatName);
    if (!matches) return JNI_FALSE;
    const char* pdfUri = env->GetStringUTFChars(pdf, nullptr);
    if (!pdfUri) return JNI_FALSE;
    bool pdfSaved = false;
    try {
        pdfSaved = document->saveAs(pdfUri, "pdf", options);
    } catch (...) {
        throwOfficeError(env, "office_preview_failed");
    }
    env->ReleaseStringUTFChars(pdf, pdfUri);
    return pdfSaved ? JNI_TRUE : JNI_FALSE;
}

static jboolean saveOfficeSource(JNIEnv* env, jstring source, jstring format, bool convertLegacy) {
    auto document = getLOKDocumentForAndroidOnly();
    if (!document) return JNI_FALSE;
    const char* formatName = env->GetStringUTFChars(format, nullptr);
    if (!formatName) return JNI_FALSE;
    const std::string_view inputFormat(formatName);
    const char* target = formatName;
    if (convertLegacy) {
        target = inputFormat == "doc" ? "docx" : inputFormat == "ppt" ? "pptx" : nullptr;
    }
    const bool matches = target && requireDocumentFamily(env, *document, inputFormat);
    const char* sourceUri = matches ? env->GetStringUTFChars(source, nullptr) : nullptr;
    bool saved = false;
    if (sourceUri) {
        try {
            saved = document->saveAs(sourceUri, target, nullptr);
        } catch (...) {
            throwOfficeError(env, convertLegacy ? "office_legacy_conversion_failed" : "office_save_failed");
        }
        env->ReleaseStringUTFChars(source, sourceUri);
    }
    env->ReleaseStringUTFChars(format, formatName);
    return saved ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jboolean JNICALL
Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_saveLegacyCopy(
    JNIEnv* env, jobject, jstring source, jstring format) {
    return saveOfficeSource(env, source, format, true);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_saveOriginal(
    JNIEnv* env, jobject, jstring source, jstring format) {
    return saveOfficeSource(env, source, format, false);
}


namespace {
constexpr int kMaximumPresentationParts = 256;
constexpr std::size_t kMaximumPresentationInfoBytes = 128 * 1024;

std::shared_ptr<COKitDocument> presentationDocument(JNIEnv* env) {
    auto document = getLOKDocumentForAndroidOnly();
    if (!document) {
        throwOfficeError(env, "office_native_observation_unavailable");
        return {};
    }
    if (document->getDocumentType() != COKitDocumentType::PRESENTATION) {
        throwOfficeError(env, "office_native_observation_unsupported");
        return {};
    }
    const int parts = document->getParts();
    if (parts < 1 || parts > kMaximumPresentationParts) {
        throwOfficeError(env, parts > kMaximumPresentationParts
                ? "office_native_observation_too_large" : "invalid_office_observation");
        return {};
    }
    return document;
}
}

extern "C" JNIEXPORT jint JNICALL
Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_nativePresentationPartCount(
    JNIEnv* env, jobject) {
    try {
        auto document = presentationDocument(env);
        return document ? document->getParts() : 0;
    } catch (...) {
        throwOfficeError(env, "invalid_office_observation");
        return 0;
    }
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_readNativePresentationInfo(
    JNIEnv* env, jobject) {
    try {
        auto document = presentationDocument(env);
        if (!document) return nullptr;
        const std::string information = document->getPresentationInfo();
        if (information.empty() || information.size() > kMaximumPresentationInfoBytes) {
            throwOfficeError(env, information.empty()
                    ? "invalid_office_observation" : "office_native_observation_too_large");
            return nullptr;
        }
        jbyteArray bytes = env->NewByteArray(static_cast<jsize>(information.size()));
        if (!bytes) return nullptr;
        env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(information.size()),
                reinterpret_cast<const jbyte*>(information.data()));
        if (env->ExceptionCheck()) {
            env->DeleteLocalRef(bytes);
            return nullptr;
        }
        return bytes;
    } catch (...) {
        throwOfficeError(env, "invalid_office_observation");
        return nullptr;
    }
}

namespace {
constexpr std::size_t kMaximumStyleRequestBytes = 2 * 1024 * 1024;
constexpr std::size_t kMaximumStyleReplyBytes = 1024 * 1024;

struct RustStylePlanner {
    using Request = char* (*)(const char*);
    using Free = void (*)(char*);
    void* library;
    Request request;
    Free release;
};

const RustStylePlanner& stylePlanner() {
    static const RustStylePlanner planner = [] {
        RustStylePlanner api{dlopen("libink_vault_native.so", RTLD_NOW | RTLD_LOCAL), nullptr, nullptr};
        if (api.library) {
            api.request = reinterpret_cast<RustStylePlanner::Request>(dlsym(api.library, "ink_vault_request"));
            api.release = reinterpret_cast<RustStylePlanner::Free>(dlsym(api.library, "ink_vault_free"));
        }
        // Rust TLS and response ownership require the paired library to stay loaded.
        return api;
    }();
    return planner;
}

bool appendStyleText(std::string& request, const std::string& text) {
    static constexpr char hex[] = "0123456789abcdef";
    request += '"';
    for (unsigned char code : text) {
        if (code == '"' || code == '\\') {
            request += '\\';
            request += static_cast<char>(code);
        } else if (code < 32) {
            request += "\\u00";
            request += hex[code >> 4];
            request += hex[code & 15];
        } else request += static_cast<char>(code);
        if (request.size() > kMaximumStyleRequestBytes) return false;
    }
    request += '"';
    return request.size() <= kMaximumStyleRequestBytes;
}
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_io_github_canele452_personalinkvault_office_OfficeEditorActivity_nativePlanCellText(
    JNIEnv* env, jobject, jbyteArray oldUtf8, jbyteArray newUtf8) {
    try {
        if (!oldUtf8 || !newUtf8) {
            throwOfficeError(env, "invalid_request");
            return nullptr;
        }
        const jsize oldLength = env->GetArrayLength(oldUtf8), newLength = env->GetArrayLength(newUtf8);
        if (env->ExceptionCheck()) return nullptr;
        // A valid UTF-16 code unit needs at most three standard UTF-8 bytes.
        if (oldLength < 0 || oldLength > 600000 || newLength < 0 || newLength > 24576) {
            throwOfficeError(env, "invalid_request");
            return nullptr;
        }
        std::string oldText(static_cast<std::size_t>(oldLength), '\0');
        std::string newText(static_cast<std::size_t>(newLength), '\0');
        if (oldLength) env->GetByteArrayRegion(oldUtf8, 0, oldLength, reinterpret_cast<jbyte*>(oldText.data()));
        if (env->ExceptionCheck()) return nullptr;
        if (newLength) env->GetByteArrayRegion(newUtf8, 0, newLength, reinterpret_cast<jbyte*>(newText.data()));
        if (env->ExceptionCheck()) return nullptr;
        std::string request = "{\"op\":\"text_style_map\",\"protocol\":\"piv-text-style-map-1\",\"oldText\":";
        if (!appendStyleText(request, oldText)) {
            throwOfficeError(env, "invalid_request");
            return nullptr;
        }
        request += ",\"newText\":";
        if (!appendStyleText(request, newText) || request.size() >= kMaximumStyleRequestBytes) {
            throwOfficeError(env, "invalid_request");
            return nullptr;
        }
        request += '}';
        const RustStylePlanner& planner = stylePlanner();
        if (!planner.request || !planner.release) {
            throwOfficeError(env, "invalid_request");
            return nullptr;
        }
        std::unique_ptr<char, RustStylePlanner::Free> response(planner.request(request.c_str()), planner.release);
        if (!response) {
            throwOfficeError(env, "invalid_request");
            return nullptr;
        }
        std::size_t length = 0;
        while (length <= kMaximumStyleReplyBytes && response.get()[length]) ++length;
        if (length == 0 || length > kMaximumStyleReplyBytes) {
            throwOfficeError(env, "invalid_request");
            return nullptr;
        }
        jbyteArray bytes = env->NewByteArray(static_cast<jsize>(length));
        if (!bytes) return nullptr;
        env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(length), reinterpret_cast<const jbyte*>(response.get()));
        if (env->ExceptionCheck()) {
            env->DeleteLocalRef(bytes);
            return nullptr;
        }
        return bytes;
    } catch (...) {
        throwOfficeError(env, "invalid_request");
        return nullptr;
    }
}
