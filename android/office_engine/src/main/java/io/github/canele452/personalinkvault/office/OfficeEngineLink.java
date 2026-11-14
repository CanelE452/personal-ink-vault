package io.github.canele452.personalinkvault.office;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Binder;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Process;
import android.os.RemoteException;
import android.util.Log;

import java.util.List;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Main-process end of the link with Office Activities in the engine process (":office").
 * Collabora force-exits its process after a document closes; this provider learns which process
 * holds a launch and releases the launch when that process dies.
 */
public final class OfficeEngineLink extends ContentProvider {
    static final String ATTACH = "attach";
    static final String AUTHORITY_SUFFIX = ".office-link";
    // A collected Binder proxy no longer reports its process death, so each engine token is held until then.
    private static final Set<IBinder> watchedEngines = ConcurrentHashMap.newKeySet();

    @Override
    public boolean onCreate() {
        OfficeSessionJournal.setProcessStopper(pid -> {
            if (pid != Process.myPid()) Process.killProcess(pid);
        });
        return true;
    }

    @Override
    public Bundle call(String method, String arg, Bundle extras) {
        Bundle reply = new Bundle();
        reply.putBoolean("allowed", false);
        if (!ATTACH.equals(method) || extras == null || Binder.getCallingUid() != Process.myUid()) return reply;
        int pid = Binder.getCallingPid();
        IBinder token = extras.getBinder("token");
        String sessionId = extras.getString("sessionId");
        String launchId = extras.getString("launchId");
        boolean previewOnly = extras.getBoolean("previewOnly", false);
        OfficeSessionJournal.EngineAttachment attachment = pid == Process.myPid() || token == null ? null
                : OfficeSessionJournal.attachEditor(sessionId, launchId, previewOnly, pid);
        if (attachment == null) {
            Log.i(OfficeEngineProcess.TAG, "attach rejected session=" + sessionId + " launch=" + launchId + " pid=" + pid);
            return reply;
        }
        long attachedAt = System.nanoTime();
        watchedEngines.add(token);
        try {
            token.linkToDeath(() -> {
                watchedEngines.remove(token);
                engineDied(attachment, attachedAt);
            }, 0);
        } catch (RemoteException alreadyDead) {
            watchedEngines.remove(token);
            engineDied(attachment, attachedAt);
            return reply;
        }
        reply.putBoolean("allowed", true);
        Log.i(OfficeEngineProcess.TAG, "attach session=" + sessionId + " launch=" + launchId + " pid=" + pid
                + " preview=" + previewOnly);
        return reply;
    }

    private void engineDied(OfficeSessionJournal.EngineAttachment attachment, long attachedAt) {
        OfficeSessionJournal.editorProcessDied(attachment);
        Log.i(OfficeEngineProcess.TAG, "engine process died pid=" + attachment.pid + " launch=" + attachment.launchId
                + " after " + (System.nanoTime() - attachedAt) / 1_000_000 + " ms");
        Context context = getContext();
        if (Build.VERSION.SDK_INT >= 30 && context != null) {
            new Thread(() -> logExitReason(context, attachment.pid), "piv-office-exit-reason").start();
        }
    }

    private static void logExitReason(Context context, int pid) {
        try {
            // Android records the exit shortly after the death notice.
            Thread.sleep(1000);
            ActivityManager manager = context.getSystemService(ActivityManager.class);
            List<ApplicationExitInfo> exits = manager.getHistoricalProcessExitReasons(null, pid, 1);
            if (exits.isEmpty()) {
                Log.i(OfficeEngineProcess.TAG, "engine exit reason unavailable pid=" + pid);
                return;
            }
            ApplicationExitInfo exit = exits.get(0);
            Log.i(OfficeEngineProcess.TAG, "engine exit pid=" + pid + " reason=" + exit.getReason()
                    + " status=" + exit.getStatus() + " description=" + exit.getDescription());
        } catch (InterruptedException | RuntimeException ignored) {
            // Diagnostic only.
        }
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        return null;
    }

    @Override
    public String getType(Uri uri) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }
}
