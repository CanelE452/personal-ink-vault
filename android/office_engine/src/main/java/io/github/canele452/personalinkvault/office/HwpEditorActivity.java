package io.github.canele452.personalinkvault.office;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Insets;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.text.TextUtils;
import android.util.Base64;
import android.util.Log;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.webkit.ConsoleMessage;
import android.webkit.JavascriptInterface;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Collections;
import java.util.Locale;

/**
 * Full HWP/HWPX editor: the bundled rhwp-studio (APK assets/hwp-studio/) in a WebView that never leaves the
 * app. The page loads the working copy from /__piv/document and hands the saved bytes back through PivHwpHost;
 * this Activity writes them to edited.&lt;ext&gt; beside the working copy and returns to HwpEditorBridge.
 */
public final class HwpEditorActivity extends Activity {
    static final String EXTRA_WORKING = "piv.workingPath";
    static final String EXTRA_OUTPUT = "piv.outputPath";
    static final String EXTRA_SESSION = "piv.sessionId";
    static final String EXTRA_FORMAT = "piv.format";
    static final String EXTRA_NAME = "piv.fileName";
    static final String RESULT_SOURCE_SHA256 = "piv.sourceSha256";
    static final String RESULT_ERROR_CODE = "piv.errorCode";
    static final String RESULT_ERROR_MESSAGE = "piv.errorMessage";
    private static final String TAG = "PIVHwpEditor";
    private static final String HOST = "appassets.androidplatform.net";
    private static final String ASSETS = "hwp-studio";
    private static final String START = "https://" + HOST + "/__piv/host.html";

    private WebView web;
    private Button save;
    private File working;
    private File output;
    private String sessionId;
    private String format;
    private String name;
    private boolean opened;
    private boolean saving;
    private boolean closing;
    private Object backCallback;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Intent intent = getIntent();
        working = file(intent.getStringExtra(EXTRA_WORKING));
        output = file(intent.getStringExtra(EXTRA_OUTPUT));
        sessionId = intent.getStringExtra(EXTRA_SESSION);
        format = intent.getStringExtra(EXTRA_FORMAT);
        name = intent.getStringExtra(EXTRA_NAME);
        if (working == null || output == null || TextUtils.isEmpty(sessionId) || !working.isFile()
                || !("hwp".equals(format) || "hwpx".equals(format))) {
            fail("hwp_editor_invalid", "편집할 HWP 작업 파일을 확인하지 못했습니다. 원본은 보관됩니다.");
            return;
        }
        setContentView(layout());
        configure();
        if (Build.VERSION.SDK_INT >= 33) {
            android.window.OnBackInvokedCallback callback = this::requestClose;
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback);
            backCallback = callback;
        }
        web.loadUrl(START);
    }

    @SuppressWarnings("deprecation")
    @Override
    public void onBackPressed() {
        requestClose();
    }

    @Override
    protected void onDestroy() {
        if (Build.VERSION.SDK_INT >= 33 && backCallback != null) {
            getOnBackInvokedDispatcher().unregisterOnBackInvokedCallback(
                    (android.window.OnBackInvokedCallback) backCallback);
        }
        if (web != null) {
            web.stopLoading();
            web.destroy();
            web = null;
        }
        super.onDestroy();
    }

    private View layout() {
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(0xffffffff);
        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);
        int pad = dp(6);
        bar.setPadding(pad, pad, pad, pad);
        Button close = new Button(this);
        close.setText("닫기");
        close.setOnClickListener(v -> requestClose());
        TextView title = new TextView(this);
        title.setText(TextUtils.isEmpty(name) ? "HWP 편집" : name);
        title.setSingleLine(true);
        title.setEllipsize(TextUtils.TruncateAt.MIDDLE);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        title.setPadding(dp(12), 0, dp(12), 0);
        save = new Button(this);
        save.setText("저장하고 닫기");
        save.setEnabled(false);
        save.setOnClickListener(v -> requestSave());
        bar.addView(close);
        bar.addView(title, new LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f));
        bar.addView(save);
        web = new WebView(this);
        root.addView(bar, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT));
        root.addView(web, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));
        if (Build.VERSION.SDK_INT >= 30) {
            root.setOnApplyWindowInsetsListener((view, insets) -> {
                Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime()
                        | WindowInsets.Type.displayCutout());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
                return WindowInsets.CONSUMED;
            });
        } else {
            root.setFitsSystemWindows(true);
        }
        return root;
    }

    private void configure() {
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setSupportMultipleWindows(false);
        settings.setJavaScriptCanOpenWindowsAutomatically(false);
        settings.setMediaPlaybackRequiresUserGesture(true);
        web.addJavascriptInterface(new Host(), "PivHwpHost");
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage message) {
                Log.i(TAG, "console " + message.messageLevel() + ": " + message.message());
                return true;
            }
        });
        web.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                return serve(request);
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                // The editor page must stay loaded; only the initial page and the studio frame may load.
                Uri url = request.getUrl();
                boolean local = "https".equals(url.getScheme()) && HOST.equals(url.getHost());
                return !local || request.isForMainFrame();
            }

            @Override
            public boolean onRenderProcessGone(WebView view, RenderProcessGoneDetail detail) {
                // A WebView whose renderer is gone must leave the view tree and be destroyed at once.
                Log.w(TAG, "renderer gone, crashed=" + detail.didCrash());
                if (view.getParent() instanceof android.view.ViewGroup) {
                    ((android.view.ViewGroup) view.getParent()).removeView(view);
                }
                view.destroy();
                web = null;
                fail("hwp_editor_crashed", "편집 화면이 멈췄습니다. 원본과 작업 파일은 보관됩니다.");
                return true;
            }
        });
    }

    /** Serves the bundled editor and the working copy; every other request is refused (the editor stays offline). */
    private WebResourceResponse serve(WebResourceRequest request) {
        Uri url = request.getUrl();
        if (!"https".equals(url.getScheme()) || !HOST.equals(url.getHost()) || !"GET".equals(request.getMethod())) {
            return status(403, "Forbidden");
        }
        String path = url.getPath();
        if (path == null || path.isEmpty() || "/".equals(path)) path = "/index.html";
        if (path.contains("..") || path.contains("\\")) return status(404, "Not Found");
        try {
            if ("/__piv/document".equals(path)) {
                return new WebResourceResponse("application/octet-stream", null, 200, "OK",
                        Collections.singletonMap("Cache-Control", "no-store"), new FileInputStream(working));
            }
            InputStream data = getAssets().open(ASSETS + path);
            String mime = mime(path);
            String encoding = mime.startsWith("text/") || mime.endsWith("json") ? "utf-8" : null;
            return new WebResourceResponse(mime, encoding, 200, "OK", Collections.emptyMap(), data);
        } catch (IOException missing) {
            return status(404, "Not Found");
        }
    }

    private static WebResourceResponse status(int code, String reason) {
        return new WebResourceResponse("text/plain", "utf-8", code, reason, Collections.emptyMap(),
                new ByteArrayInputStream(new byte[0]));
    }

    static String mime(String path) {
        String lower = path.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".html")) return "text/html";
        if (lower.endsWith(".js") || lower.endsWith(".mjs")) return "text/javascript";
        if (lower.endsWith(".css")) return "text/css";
        if (lower.endsWith(".wasm")) return "application/wasm";
        if (lower.endsWith(".woff2")) return "font/woff2";
        if (lower.endsWith(".woff")) return "font/woff";
        if (lower.endsWith(".ttf")) return "font/ttf";
        if (lower.endsWith(".otf")) return "font/otf";
        if (lower.endsWith(".json")) return "application/json";
        if (lower.endsWith(".svg")) return "image/svg+xml";
        if (lower.endsWith(".png")) return "image/png";
        if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) return "image/jpeg";
        if (lower.endsWith(".gif")) return "image/gif";
        if (lower.endsWith(".ico")) return "image/x-icon";
        if (lower.endsWith(".txt") || lower.endsWith(".md")) return "text/plain";
        return "application/octet-stream";
    }

    private void requestSave() {
        if (!opened || saving || web == null) return;
        saving = true;
        save.setEnabled(false);
        save.setText("저장하는 중…");
        web.evaluateJavascript("window.pivSave()", null);
    }

    private void requestClose() {
        if (closing) return;
        if (!opened || web == null) {
            cancel();
            return;
        }
        web.evaluateJavascript("window.pivDirty()", null);
    }

    private void onDirty(boolean dirty) {
        if (!dirty) {
            cancel();
            return;
        }
        new AlertDialog.Builder(this)
                .setMessage("고친 내용을 저장하지 않고 닫을까요?")
                .setPositiveButton("저장하지 않고 닫기", (dialog, which) -> cancel())
                .setNegativeButton("계속 편집", null)
                .show();
    }

    private void onState(String state, String detail) {
        Log.i(TAG, "state " + state + (TextUtils.isEmpty(detail) ? "" : " " + detail));
        switch (state) {
            case "opened":
                opened = true;
                save.setEnabled(true);
                break;
            case "openFailed":
                fail("hwp_editor_open_failed", "편집 화면에서 문서를 열지 못했습니다. 원본은 보관됩니다.");
                break;
            case "saveFailed":
                saving = false;
                save.setEnabled(true);
                save.setText("저장하고 닫기");
                Toast.makeText(this, "문서를 저장하지 못했습니다. 다시 시도해 주세요.", Toast.LENGTH_LONG).show();
                break;
            default:
                break;
        }
    }

    private void onSaved(byte[] data) {
        if (closing) return;
        if (!signatureMatches(data, format)) {
            onState("saveFailed", "unexpected " + format + " bytes");
            return;
        }
        File staging = new File(output.getParentFile(), output.getName() + ".tmp");
        try (FileOutputStream stream = new FileOutputStream(staging)) {
            stream.write(data);
            stream.getFD().sync();
        } catch (IOException error) {
            staging.delete();
            onState("saveFailed", "write failed");
            return;
        }
        if (!staging.renameTo(output)) {
            staging.delete();
            onState("saveFailed", "rename failed");
            return;
        }
        closing = true;
        Intent result = new Intent()
                .putExtra(EXTRA_SESSION, sessionId)
                .putExtra(RESULT_SOURCE_SHA256, HwpEditorBridge.sha256(data));
        setResult(RESULT_OK, result);
        finish();
    }

    static boolean signatureMatches(byte[] data, String format) {
        if (data == null || data.length < 8) return false;
        if ("hwp".equals(format)) {
            byte[] cfb = {(byte) 0xd0, (byte) 0xcf, 0x11, (byte) 0xe0, (byte) 0xa1, (byte) 0xb1, 0x1a, (byte) 0xe1};
            for (int i = 0; i < cfb.length; i++) if (data[i] != cfb[i]) return false;
            return true;
        }
        return data[0] == 'P' && data[1] == 'K' && data[2] == 3 && data[3] == 4;
    }

    private void cancel() {
        closing = true;
        setResult(RESULT_CANCELED, new Intent().putExtra(EXTRA_SESSION, sessionId));
        finish();
    }

    private void fail(String code, String message) {
        closing = true;
        setResult(RESULT_FIRST_USER, new Intent()
                .putExtra(EXTRA_SESSION, sessionId)
                .putExtra(RESULT_ERROR_CODE, code)
                .putExtra(RESULT_ERROR_MESSAGE, message));
        finish();
    }

    private static File file(String path) {
        return path == null || path.isEmpty() ? null : new File(path);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    /** Called by host.js on a WebView background thread. */
    private final class Host {
        @JavascriptInterface
        public String documentInfo() {
            try {
                return new JSONObject().put("name", name == null ? "document." + format : name)
                        .put("format", format).toString();
            } catch (JSONException impossible) {
                return "{}";
            }
        }

        @JavascriptInterface
        public void state(String state, String detail) {
            runOnUiThread(() -> onState(state == null ? "" : state, detail));
        }

        @JavascriptInterface
        public void dirty(boolean value) {
            runOnUiThread(() -> onDirty(value));
        }

        @JavascriptInterface
        public void saved(String encoded) {
            byte[] data;
            try {
                data = Base64.decode(encoded == null ? "" : encoded, Base64.DEFAULT);
            } catch (IllegalArgumentException invalid) {
                data = null;
            }
            byte[] bytes = data;
            runOnUiThread(() -> onSaved(bytes));
        }
    }
}
