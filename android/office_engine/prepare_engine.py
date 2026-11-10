#!/usr/bin/env python3
"""Prepare the pinned open-source Android Office engine without building it."""

import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import stat
import urllib.request
import zipfile
import zlib


MODULE = Path(__file__).resolve().parent
REPOSITORY = MODULE.parent.parent
ROOT = REPOSITORY / "build" / "office-engine"
ASSET_POLICY_VERSION = 1
LEGACY_APP_PROFILES = frozenset({"baseline.prof", "baseline.profm"})


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_if_changed(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.read_bytes() == data:
        return
    path.write_bytes(data)


def copy_if_changed(source, destination):
    if destination.is_file() and source.stat().st_size == destination.stat().st_size:
        if digest(source) == digest(destination):
            return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def matches_zip_entry(path, item):
    if not path.is_file() or path.stat().st_size != item.file_size:
        return False
    checksum = 0
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            checksum = zlib.crc32(block, checksum)
    return checksum == item.CRC


def acquire(url, destination, expected_hash, expected_bytes, maximum_bytes):
    if destination.exists() and digest(destination) == expected_hash:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_suffix(destination.suffix + ".part")
    try:
        with urllib.request.urlopen(url, timeout=60) as response, partial.open("wb") as output:
            length = int(response.headers.get("Content-Length", "0"))
            if length > maximum_bytes:
                raise ValueError("Office download exceeds its pinned size limit")
            total = 0
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                total += len(block)
                if total > maximum_bytes:
                    raise ValueError("Office download exceeds its pinned size limit")
                output.write(block)
        if total != expected_bytes or digest(partial) != expected_hash:
            raise ValueError("Office download identity did not match engine.lock.json")
        partial.replace(destination)
    finally:
        if partial.exists():
            partial.unlink()


def patch_activity(text):
    back_callback = """            public void handleOnBackPressed() {
                if (!documentLoaded) {
                    finishAndRemoveTask();
                    return;
                }

                if (mCurrentFullScreenView != null) {
                    hideFullScreenView();
                    return;
                } else if (mSlideShowActive) {
                    callFakeWebsocketOnMessage("mobile: slideshowback");
                    return;
                } else if (mMobileWizardVisible) {
                    // just return one level up in the mobile-wizard (or close it)
                    callFakeWebsocketOnMessage("mobile: mobilewizardback");
                    return;
                } else if (mIsEditModeActive) {
                    callFakeWebsocketOnMessage("mobile: readonlymode");
                    return;
                }

                finishWithProgress();
            }"""
    image_cancel = """            if (requestCode == REQUEST_SELECT_IMAGE_FILE) {
                valueCallback.onReceiveValue(null);
                valueCallback = null;
            }"""
    image_success = """            case REQUEST_SELECT_IMAGE_FILE:
                if (valueCallback == null)
                    return;
                valueCallback.onReceiveValue(WebChromeClient.FileChooserParams.parseResult(resultCode, intent));
                valueCallback = null;
                return;"""
    for marker in (back_callback, image_cancel, image_success):
        if text.count(marker) != 1:
            raise ValueError("Pinned Office interaction patch no longer matches its source")
    text = text.replace(back_callback, """            public void handleOnBackPressed() {
                handleEmbeddedBack();
            }""", 1)
    text = text.replace(image_cancel, """            if (requestCode == REQUEST_SELECT_IMAGE_FILE) {
                deliverEmbeddedImageResult(resultCode, intent);
            }""", 1)
    text = text.replace(image_success, """            case REQUEST_SELECT_IMAGE_FILE:
                deliverEmbeddedImageResult(resultCode, intent);
                return;""", 1)
    text = text.replace(
        "    private boolean documentLoaded = false;",
        "    private volatile boolean documentLoaded = false;\n"
        "    private volatile boolean pivDestroyed = false;\n"
        "    private final java.util.concurrent.atomic.AtomicBoolean pivNativeClosed =\n"
        "            new java.util.concurrent.atomic.AtomicBoolean();\n"
        "    private final java.util.concurrent.CountDownLatch pivNativeHello =\n"
        "            new java.util.concurrent.CountDownLatch(1);\n"
        "    private final java.util.concurrent.atomic.AtomicBoolean pivNativeHelloStarted =\n"
        "            new java.util.concurrent.atomic.AtomicBoolean();\n"
        "    private boolean pivNativeOpened = false;\n"
        "    private volatile boolean pivNativeReleased = false;\n"
        "    private Runnable pivNativeWatchdog;\n"
        "    private static final long PIV_HANDSHAKE_TIMEOUT_MILLIS = 10000;\n"
        "    private static final long PIV_OPERATION_TIMEOUT_MILLIS = 45000;\n"
        "    private static Handler pivSharedNativeHandler;\n"
        "    private AsyncTask<Void, Void, Boolean> pivPreparationTask;\n"
        "    private static final Object PIV_ASSET_LOCK = new Object();",
        1,
    )
    init_start = text.index("    private void init() {")
    init_end = text.index("    /** Actual initialization of the UI. */", init_start)
    text = text[:init_start] + """    private void init() {
        if (pivDestroyed || isFinishing() || isDestroyed()) return;
        if (sPrefs.getString(ASSETS_EXTRACTED_GIT_COMMIT, "").equals(BuildConfig.GIT_COMMIT)) {
            initUI();
            return;
        }
        mProgressDialog.indeterminate(R.string.preparing_for_the_first_start_after_an_update);
        final AssetManager applicationAssets = getApplicationContext().getAssets();
        final String dataDirectory = getApplicationInfo().dataDir;
        pivPreparationTask = new AsyncTask<Void, Void, Boolean>() {
            @Override
            protected Boolean doInBackground(Void... voids) {
                synchronized (PIV_ASSET_LOCK) {
                    if (isCancelled()) return false;
                    if (sPrefs.getString(ASSETS_EXTRACTED_GIT_COMMIT, "").equals(BuildConfig.GIT_COMMIT)) return true;
                    boolean copied = copyFromAssets(applicationAssets, "unpack", dataDirectory);
                    if (copied) sPrefs.edit().putString(ASSETS_EXTRACTED_GIT_COMMIT, BuildConfig.GIT_COMMIT).apply();
                    return copied;
                }
            }

            @Override
            protected void onPostExecute(Boolean copied) {
                pivPreparationTask = null;
                if (isCancelled() || pivDestroyed || isFinishing() || isDestroyed()) return;
                if (!copied) {
                    mProgressDialog.dismiss();
                    Toast.makeText(LOActivity.this, R.string.failed_to_load_file, Toast.LENGTH_LONG).show();
                    finish();
                    return;
                }
                initUI();
            }

            @Override
            protected void onCancelled(Boolean ignored) {
                pivPreparationTask = null;
            }
        }.execute();
    }

""" + text[init_end:]
    text = text.replace(
        "    private void initUI() {",
        "    private void initUI() {\n"
        "        if (pivDestroyed || isFinishing() || isDestroyed()) return;",
        1,
    )
    thread_start = text.index("            nativeMsgThread = new Thread(new Runnable() {")
    thread_end = text.index("            nativeMsgThread.start();", thread_start) + len("            nativeMsgThread.start();")
    text = text[:thread_start] + """            nativeHandler = embeddedNativeHandler();
            nativeLooper = nativeHandler.getLooper();
            nativeMsgThread = nativeLooper.getThread();""" + text[thread_end:]
    destroy_start = text.index("    @Override\n    protected void onDestroy() {")
    destroy_end = text.index("    @Override\n    public void onActivityResult", destroy_start)
    text = text[:destroy_start] + """    @Override
    protected void onDestroy() {
        pivDestroyed = true;
        if (pivPreparationTask != null) {
            pivPreparationTask.cancel(false);
            pivPreparationTask = null;
        }
        stopWatchingForHardwareKeyboard();
        if (nativeHandler != null && !io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart())
            watchEmbeddedNativeOperation();
        queueEmbeddedNativeClose();
        mProgressDialog.dismiss();
        super.onDestroy();
    }

""" + text[destroy_end:]
    intent_close = """        getMainHandler().post(new Runnable() {
            @Override
            public void run() {
                documentLoaded = false;
                postMobileMessageNative("BYE");
                //copyTempBackToIntent();
            }
        });"""
    if text.count(intent_close) != 1:
        raise ValueError("Pinned Office new-intent close patch no longer matches its source")
    text = text.replace(intent_close, "        queueEmbeddedNativeClose();", 1)
    text = text.replace('        if (documentLoaded) {\n            postMobileMessageNative("save dontTerminateEdit=1 dontSaveIfUnmodified=1");',
                        '        if (documentLoaded) {\n            queueEmbeddedAutoSave();', 1)
    text = text.replace('    protected void onNewIntent(Intent intent) {',
                        '    protected void onNewIntent(Intent intent) {\n        if (isEmbeddedDocumentBusy()) return;', 1)
    start = text.index("    private void finishWithProgress() {")
    end = text.index("    private void loadDocument() {", start)
    replacement = """    private boolean pivClosing = false;

    protected void handleEmbeddedBack() {
        if (pivDestroyed || isDestroyed() || isFinishing() || pivClosing || pivNativeClosed.get() || isEmbeddedDocumentBusy()) return;
        if (!documentLoaded) {
            finishWithProgress();
            return;
        }
        if (mCurrentFullScreenView != null) {
            hideFullScreenView();
            return;
        } else if (mSlideShowActive) {
            callFakeWebsocketOnMessage("mobile: slideshowback");
            return;
        } else if (mMobileWizardVisible) {
            callFakeWebsocketOnMessage("mobile: mobilewizardback");
            return;
        } else if (mIsEditModeActive) {
            callFakeWebsocketOnMessage("mobile: readonlymode");
            return;
        }
        finishWithProgress();
    }

    protected void deliverEmbeddedImageResult(int resultCode, Intent intent) {
        final ValueCallback<Uri[]> callback = valueCallback;
        valueCallback = null;
        if (callback == null || pivDestroyed || isDestroyed() || isFinishing() ||
                pivClosing || pivNativeClosed.get() || isEmbeddedPreviewOnly()) return;
        final Uri[] selected = resultCode == RESULT_OK
                ? WebChromeClient.FileChooserParams.parseResult(resultCode, intent) : null;
        callback.onReceiveValue(selected);
    }

    // Personal Ink Vault: close the embedded editor after its new revision is saved.
    protected boolean beforeEmbeddedDocumentClose() { return true; }

    protected boolean isEmbeddedDocumentBusy() { return false; }

    protected boolean onEmbeddedNativeMessage(byte[] message) { return false; }

    protected final boolean sendEmbeddedScript(String requestId, String script) {
        if (requestId == null || !requestId.matches("[A-Za-z0-9_-]{1,96}") || script == null ||
                !documentLoaded || !pivNativeOpened || isEmbeddedPreviewOnly() || pivDestroyed ||
                isDestroyed() || isFinishing() || pivClosing || pivNativeClosed.get() || nativeHandler == null ||
                io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart()) return false;
        try {
            java.nio.ByteBuffer encoded = java.nio.charset.StandardCharsets.UTF_8.newEncoder()
                    .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                    .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
                    .encode(java.nio.CharBuffer.wrap(script));
            if (encoded.remaining() > 512 * 1024) return false;
        } catch (java.nio.charset.CharacterCodingException invalid) {
            return false;
        }
        watchEmbeddedNativeOperation();
        boolean accepted = nativeHandler.post(() -> {
            if (!documentLoaded || !pivNativeOpened || isEmbeddedPreviewOnly() || pivDestroyed ||
                    isDestroyed() || pivClosing || pivNativeClosed.get() ||
                    io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart()) return;
            postMobileMessageNative("executescript " + requestId + " 1 piv-presentation-cells.js\\n" + script);
        });
        if (!accepted) completeEmbeddedScript();
        return accepted;
    }

    protected final void completeEmbeddedScript() {
        runOnUiThread(this::cancelEmbeddedNativeWatchdog);
    }

    private void queueEmbeddedAutoSave() {
        if (!documentLoaded || !pivNativeOpened || isEmbeddedPreviewOnly() || isEmbeddedDocumentBusy() ||
                pivDestroyed || isDestroyed() || pivClosing || pivNativeClosed.get() || nativeHandler == null ||
                io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart()) return;
        nativeHandler.post(() -> {
            if (!documentLoaded || !pivNativeOpened || isEmbeddedPreviewOnly() || isEmbeddedDocumentBusy() ||
                    pivDestroyed || isDestroyed() || pivClosing || pivNativeClosed.get() ||
                    io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart()) return;
            postMobileMessageNative("save dontTerminateEdit=1 dontSaveIfUnmodified=1");
        });
    }

    protected boolean isEmbeddedPreviewOnly() {
        return getIntent().getBooleanExtra("piv.previewOnly", false);
    }

    private static synchronized Handler embeddedNativeHandler() {
        if (pivSharedNativeHandler == null) {
            android.os.HandlerThread thread = new android.os.HandlerThread("office-native-messages");
            thread.start();
            pivSharedNativeHandler = new Handler(thread.getLooper());
        }
        return pivSharedNativeHandler;
    }

    // All native open/save/close work shares the process-wide FIFO. A queued
    // close retains this Activity until its document is actually released.
    private void closeEmbeddedNativeDocument() {
        if (!pivNativeOpened) {
            pivNativeReleased = true;
            return;
        }
        if (pivNativeClosed.get() || io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart()) return;
        // COKit's BYE closes the notification pipe created by HULLO. Keep the
        // WebView alive until that initial handshake has actually returned.
        try {
            if (!pivNativeHello.await(PIV_HANDSHAKE_TIMEOUT_MILLIS, java.util.concurrent.TimeUnit.MILLISECONDS)) {
                io.github.canele452.personalinkvault.office.OfficeEngineHealth.quarantine();
                runOnUiThread(this::failEmbeddedNativeSession);
                return;
            }
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            io.github.canele452.personalinkvault.office.OfficeEngineHealth.quarantine();
            runOnUiThread(this::failEmbeddedNativeSession);
            return;
        }
        if (!pivNativeClosed.compareAndSet(false, true)) return;
        documentLoaded = false;
        postMobileMessageNative("BYE");
        pivNativeReleased = true;
        runOnUiThread(this::cancelEmbeddedNativeWatchdog);
    }

    private void queueEmbeddedNativeClose() {
        final Handler queue = nativeHandler;
        if (queue != null) {
            queue.post(() -> {
                closeEmbeddedNativeDocument();
                runOnUiThread(() -> {
                    destroyEmbeddedWebView();
                    if (pivNativeReleased || io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart())
                        cancelEmbeddedNativeWatchdog();
                });
            });
        } else {
            destroyEmbeddedWebView();
        }
    }

    private void openEmbeddedNativeDocument(String dataDir, String cacheDir,
            String apkFile, AssetManager assetManager, String documentUrl,
            String uiMode, String userName, String webUrl) {
        watchEmbeddedNativeOperation();
        nativeHandler.post(() -> {
            if (io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart()) {
                runOnUiThread(this::failEmbeddedNativeSession);
                return;
            }
            if (pivDestroyed || pivNativeClosed.get()) return;
            pivNativeOpened = true;
            createCOOLWSD(dataDir, cacheDir, apkFile, assetManager, documentUrl, uiMode, userName);
            documentLoaded = true;
            runOnUiThread(() -> {
                if (!pivNativeClosed.get() && mWebView != null)
                    mWebView.loadUrl(webUrl);
            });
            if (pivDestroyed) {
                closeEmbeddedNativeDocument();
                return;
            }
        });
    }

    private void cancelEmbeddedNativeWatchdog() {
        if (pivNativeWatchdog != null) {
            getMainHandler().removeCallbacks(pivNativeWatchdog);
            pivNativeWatchdog = null;
        }
    }

    private void watchEmbeddedNativeOperation() {
        cancelEmbeddedNativeWatchdog();
        pivNativeWatchdog = () -> {
            if (!pivNativeReleased) failEmbeddedNativeSession();
        };
        getMainHandler().postDelayed(pivNativeWatchdog, PIV_OPERATION_TIMEOUT_MILLIS);
    }

    private void failEmbeddedNativeSession() {
        io.github.canele452.personalinkvault.office.OfficeEngineHealth.quarantine();
        cancelEmbeddedNativeWatchdog();
        if (pivDestroyed) return;
        mProgressDialog.dismiss();
        android.content.Intent failure = new android.content.Intent()
                .putExtra("sessionId", getIntent().getStringExtra("piv.sessionId"))
                .putExtra("errorCode", io.github.canele452.personalinkvault.office.OfficeEngineHealth.ERROR_CODE)
                .putExtra("errorMessage", io.github.canele452.personalinkvault.office.OfficeEngineHealth.RECOVERY_MESSAGE);
        setResult(android.app.Activity.RESULT_CANCELED, failure);
        if (!isFinishing()) finish();
    }

    private void destroyEmbeddedWebView() {
        if (mWebView != null) {
            ViewGroup parent = (ViewGroup) mWebView.getParent();
            if (parent != null) parent.removeView(mWebView);
            mWebView.destroy();
            mWebView = null;
        }
        mMobileSocket = null;
    }

    protected void finishWithProgress() {
        if (pivClosing || pivDestroyed || isFinishing() || isEmbeddedDocumentBusy()) return;
        if (!documentLoaded) { finish(); return; }
        pivClosing = true;
        watchEmbeddedNativeOperation();
        mProgressDialog.indeterminate(R.string.exiting);
        nativeHandler.post(() -> {
            if (!pivDestroyed && !beforeEmbeddedDocumentClose()) {
                runOnUiThread(() -> {
                    if (pivDestroyed) return;
                    pivClosing = false;
                    cancelEmbeddedNativeWatchdog();
                    mProgressDialog.dismiss();
                });
                return;
            }
            closeEmbeddedNativeDocument();
            runOnUiThread(() -> {
                if (pivDestroyed) return;
                destroyEmbeddedWebView();
                mProgressDialog.dismiss();
                finish();
            });
        });
    }

"""
    text = text[:start] + replacement + text[end:]
    text = text.replace(
        "    private void loadDocument() {",
        "    private void loadDocument() {\n"
        "        if (pivDestroyed || isFinishing() || isDestroyed()) return;",
        1,
    )
    create_marker = "        createCOOLWSD(dataDir, cacheDir, apkFile, assetManager, urlToLoad, uiMode, userName);"
    load_marker = "        mWebView.loadUrl(finalUrlToLoad);\n\n        documentLoaded = true;"
    mobile_marker = "    public void postMobileMessage(String message) {"
    raw_marker = "    void rawCallFakeWebsocketOnMessage(final byte[] message) {\n        try {\n            mMobileSocket.queueSend(message, () -> {\n                mWebView.post(() -> {\n                    mWebView.loadUrl(\"javascript:window.socket.doSend();\");\n                });\n            });"
    for marker in (create_marker, load_marker, mobile_marker, raw_marker):
        if text.count(marker) != 1:
            raise ValueError("Pinned Office native lifecycle patch no longer matches its source")
    text = text.replace(create_marker, "", 1)
    text = text.replace(load_marker, "        openEmbeddedNativeDocument(dataDir, cacheDir, apkFile, assetManager, urlToLoad, uiMode, userName, finalUrlToLoad);", 1)
    text = text.replace(mobile_marker, mobile_marker + """
        if (pivNativeClosed.get()) return;
        if (io.github.canele452.personalinkvault.office.OfficeEngineHealth.requiresRestart()) return;
        if (message.equals("HULLO")) {
            if (!pivNativeHelloStarted.compareAndSet(false, true)) return;
            postMobileMessageNative(message);
            pivNativeHello.countDown();
            return;
        }
        if (pivDestroyed) return;
        if (message.equals("hideProgressbar") || message.startsWith("hideProgressbar "))
            runOnUiThread(this::cancelEmbeddedNativeWatchdog);""", 1)
    text = text.replace(raw_marker, """    void rawCallFakeWebsocketOnMessage(final byte[] message) {
        if (pivDestroyed || pivNativeClosed.get()) return;
        if (onEmbeddedNativeMessage(message)) return;
        final var socket = mMobileSocket;
        if (socket == null) return;
        try {
            socket.queueSend(message, () -> {
                runOnUiThread(() -> {
                    if (!pivDestroyed && !pivNativeClosed.get() && mWebView != null)
                        mWebView.loadUrl("javascript:window.socket.doSend();");
                });
            });""", 1)
    text = text.replace("            runOnUiThread(() -> {\n                JSONObject messageJSON;", "            runOnUiThread(() -> {\n                if (pivDestroyed || pivNativeClosed.get()) return;\n                JSONObject messageJSON;", 1)
    text = text.replace('            runOnUiThread(() -> mProgressDialog.dismiss());', '            runOnUiThread(() -> { if (!pivDestroyed && !pivNativeClosed.get()) mProgressDialog.dismiss(); });', 1)
    readonly_marker = "        if (!canDocumentBeExported())\n            isDocEditable = false;"
    pause_marker = '        if (documentLoaded)\n            postMobileMessageNative("save dontTerminateEdit=1 dontSaveIfUnmodified=1");'
    message_marker = "    private boolean beforeMessageFromWebView(String[] messageAndParam) {"
    permission_marker = "                        if (canAllFilesAccessHelp())"
    for marker in (readonly_marker, pause_marker, message_marker, permission_marker):
        if text.count(marker) != 1:
            raise ValueError("Pinned Office preview patch no longer matches its source")
    text = text.replace(readonly_marker, readonly_marker + "\n        if (isEmbeddedPreviewOnly()) isDocEditable = false;", 1)
    text = text.replace(pause_marker, '        queueEmbeddedAutoSave();', 1)
    text = text.replace(message_marker, message_marker + """
        if (isEmbeddedPreviewOnly()) {
            switch (messageAndParam[0]) {
                case "SAVE": case "save": case "uno": case "EDITMODE":
                case "downloadas": case "exportfile": case "REQUESTFILECOPY":
                case "PRINT": case "HYPERLINK":
                    return false;
            }
        }""", 1)
    text = text.replace(permission_marker, "                        if (!isEmbeddedPreviewOnly() && canAllFilesAccessHelp())", 1)
    return text


def remove_legacy_app_profiles(apk, generated):
    namespace = generated / "assets" / "dexopt"
    owner = generated.parent.resolve()
    reparse_point = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
    for directory in (generated, generated / "assets", namespace):
        try:
            info = directory.lstat()
        except FileNotFoundError:
            continue
        if (not stat.S_ISDIR(info.st_mode) or
                getattr(info, "st_file_attributes", 0) & reparse_point or
                not directory.resolve().is_relative_to(owner)):
            raise ValueError("Generated Office assets must use owned plain directories")
    if not namespace.exists():
        return

    # Authenticate the complete old namespace before removing any file. Only
    # these two known profiles can come from the earlier producer policy.
    originals = []
    with zipfile.ZipFile(apk) as archive:
        for path in namespace.iterdir():
            info = path.lstat()
            if (path.name not in LEGACY_APP_PROFILES or
                    not stat.S_ISREG(info.st_mode) or
                    getattr(info, "st_file_attributes", 0) & reparse_point):
                raise ValueError("Unknown or linked generated APK profile must be preserved")
            try:
                expected = archive.read("assets/dexopt/" + path.name)
            except KeyError as error:
                raise ValueError("The pinned APK cannot authenticate a legacy profile") from error
            if info.st_size != len(expected) or path.read_bytes() != expected:
                raise ValueError("Foreign generated APK profile must be preserved")
            originals.append(path)
    for path in originals:
        path.unlink()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apk-path", type=Path)
    args = parser.parse_args()
    lock_path = MODULE / "engine.lock.json"
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    cache = ROOT / "cache"
    apk = cache / "collabora-arm64.apk"
    if args.apk_path:
        if digest(args.apk_path) != lock["apk"]["sha256"]:
            raise ValueError("Supplied Office APK does not match the pinned SHA-256")
        apk.parent.mkdir(parents=True, exist_ok=True)
        if args.apk_path.resolve() != apk.resolve():
            shutil.copyfile(args.apk_path, apk)
    acquire(lock["apk"]["url"], apk, lock["apk"]["sha256"],
            lock["apk"]["bytes"], lock["apk"]["maximumBytes"])

    def acquire_source(entry):
        relative = PurePosixPath(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Invalid pinned Office source path")
        path = cache / "source" / str(relative)
        acquire(lock["sourceBaseUrl"] + str(relative), path, entry["sha256"],
                entry["bytes"], 1000000)
        return entry, path

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        sources = list(pool.map(acquire_source, lock["sources"]))

    generated = ROOT / "generated"
    remove_legacy_app_profiles(apk, generated)
    generated.mkdir(parents=True, exist_ok=True)
    for entry, source in sources:
        relative = entry["path"]
        if relative.startswith("android/lib/src/main/"):
            destination = generated / relative.removeprefix("android/lib/src/main/")
        elif relative.endswith("COKit.hxx"):
            destination = generated / "include" / "COKit.hxx"
        else:
            destination = generated / "assets" / "office-engine-source-license.txt"
        if relative.endswith("/LOActivity.java"):
            write_if_changed(destination, patch_activity(source.read_text(encoding="utf-8")).encode("utf-8"))
        else:
            copy_if_changed(source, destination)

    with zipfile.ZipFile(apk) as archive:
        for item in archive.infolist():
            relative = PurePosixPath(item.filename)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Invalid path in pinned Office APK")
            if item.is_dir() or relative.parts[:2] == ("assets", "dexopt"):
                continue
            if item.filename == "assets/unpack/etc/fonts/fonts.conf":
                text = archive.read(item).decode("utf-8").replace(
                    "/data/data/com.collabora.libreoffice/fontconfig",
                    "/data/data/io.github.canele452.personalinkvault/cache/office-fontconfig")
                write_if_changed(generated / item.filename, text.encode("utf-8"))
                continue
            if relative.parts[:2] == ("lib", "arm64-v8a"):
                destination = generated / "jniLibs" / "arm64-v8a" / relative.name
            elif relative.parts[0] == "assets":
                destination = generated / str(relative)
            else:
                continue
            if matches_zip_entry(destination, item):
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(item) as source, destination.open("wb") as output:
                shutil.copyfileobj(source, output)

    preferred_runtime = generated / "app-jni" / "arm64-v8a" / "libc++_shared.so"
    copy_if_changed(generated / "jniLibs/arm64-v8a/libc++_shared.so", preferred_runtime)
    provenance = {
        "engine": lock["engine"], "version": lock["version"],
        "sourceRevision": lock["sourceRevision"],
        "sourceUrl": "https://github.com/CollaboraOnline/online.mirror/tree/" + lock["sourceRevision"],
        "apkUrl": lock["apk"]["url"], "apkSha256": lock["apk"]["sha256"],
        "modificationVersion": "piv-4",
        "assetPolicyVersion": ASSET_POLICY_VERSION,
        "changes": ["Embedded close/save hook in LOActivity", "Cancelled preparation lifecycle guards", "Shared native open/save/close FIFO with asynchronous destroy and close-once ownership", "Application font cache path", "Read-only automatic PDF preview with original autosave and edit messages disabled", "Destroyed Activity native and WebView callback guards", "Upstream APK dexopt profiles excluded from engine assets"],
        "licenses": ["license.html", "notice.txt", "office-engine-source-license.txt"],
    }
    write_if_changed(generated / "assets/office-engine-provenance.json",
                     (json.dumps(provenance, indent=2) + "\n").encode("utf-8"))
    write_if_changed(generated / "prepared.json", (json.dumps({
        "lockSha256": digest(lock_path), "sourceFiles": len(sources),
        "apkSha256": lock["apk"]["sha256"], "version": lock["version"],
        "assetPolicyVersion": ASSET_POLICY_VERSION,
    }, indent=2) + "\n").encode("utf-8"))
    print("Prepared pinned Collabora Android engine and embedded Office UI:", generated)


if __name__ == "__main__":
    main()
