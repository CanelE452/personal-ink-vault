package io.github.canele452.personalinkvault.office;

import android.app.Activity;
import android.content.ContentProviderClient;
import android.content.Context;
import android.os.Binder;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;
import android.webkit.WebView;

import java.util.concurrent.atomic.AtomicLong;

/** The engine-process (":office") side of an Office Activity. Logs carry steps, PIDs and IDs only. */
final class OfficeEngineProcess {
    static final String TAG = "PIVOffice";
    private static final long STOP_DELAY_MILLIS = 300;
    private static final long UI_PROBE_MILLIS = 500;
    private static final long UI_STALL_MILLIS = 1000;
    // Held for the process lifetime: its death notice tells the main process this engine is gone.
    private static final Binder PROCESS_TOKEN = new Binder();
    private static boolean prepared;
    private static ContentProviderClient link;

    private OfficeEngineProcess() {}

    /** Once per engine process, before any WebView exists. */
    static synchronized void prepare() {
        if (prepared) return;
        prepared = true;
        if (Build.VERSION.SDK_INT >= 28) {
            try {
                // The main process may create WebViews too, and two processes cannot share one data folder.
                WebView.setDataDirectorySuffix("office");
            } catch (IllegalStateException alreadyStarted) {
                log("webview data directory already fixed");
            }
        }
        watchUiThread();
        log("engine process start");
    }

    /** Asks the main process whether this Activity belongs to a launch it started. */
    static synchronized boolean attach(Context context, String sessionId, String launchId, boolean previewOnly) {
        try {
            if (link == null) {
                // Holding the provider also keeps the main process at least as important as this one.
                link = context.getContentResolver().acquireContentProviderClient(
                        context.getPackageName() + OfficeEngineLink.AUTHORITY_SUFFIX);
            }
            if (link == null) return false;
            Bundle extras = new Bundle();
            extras.putString("sessionId", sessionId);
            extras.putString("launchId", launchId);
            extras.putBoolean("previewOnly", previewOnly);
            extras.putBinder("token", PROCESS_TOKEN);
            Bundle reply = link.call(OfficeEngineLink.ATTACH, null, extras);
            return reply != null && reply.getBoolean("allowed", false);
        } catch (Exception error) {
            log("attach failed " + error.getClass().getSimpleName());
            return false;
        }
    }

    /** After an Office Activity released its native document: end this process unless the Activity is only recreated. */
    static void stopAfterRelease(Activity activity) {
        if (activity.isChangingConfigurations() || OfficeSessionJournal.hasLiveEditor()) return;
        log("engine process stop");
        new Handler(Looper.getMainLooper()).postDelayed(() -> {
            if (!OfficeSessionJournal.hasLiveEditor()) Process.killProcess(Process.myPid());
        }, STOP_DELAY_MILLIS);
    }

    static void log(String message) {
        Log.i(TAG, message + " pid=" + Process.myPid());
    }

    /** Logs the main-thread stack once whenever the UI thread runs no posted work for over a second. */
    private static void watchUiThread() {
        Handler main = new Handler(Looper.getMainLooper());
        AtomicLong lastRun = new AtomicLong(SystemClock.uptimeMillis());
        Thread watcher = new Thread(() -> {
            boolean reported = false;
            while (true) {
                main.post(() -> lastRun.set(SystemClock.uptimeMillis()));
                try {
                    Thread.sleep(UI_PROBE_MILLIS);
                } catch (InterruptedException stopped) {
                    return;
                }
                long stalled = SystemClock.uptimeMillis() - lastRun.get();
                if (stalled <= UI_STALL_MILLIS) {
                    reported = false;
                    continue;
                }
                if (reported) continue;
                reported = true;
                StringBuilder stack = new StringBuilder("ui thread stalled ").append(stalled).append(" ms");
                for (StackTraceElement frame : Looper.getMainLooper().getThread().getStackTrace()) {
                    stack.append("\n  at ").append(frame);
                }
                log(stack.toString());
            }
        }, "piv-office-ui-watch");
        watcher.setDaemon(true);
        watcher.start();
    }
}
