package io.github.canele452.personalinkvault.office;

import java.nio.charset.StandardCharsets;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Whether an open editor has changes worth asking about when it closes.
 *
 * The Office engine announces '.uno:ModifiedStatus' as a state change. Its in-place background save clears
 * that flag, so a closing editor also compares its working copy with the bytes it opened.
 */
public final class EditorChangeTracker {
    private static final String PREFIX = "statechanged:";
    private static final Pattern TEXT = Pattern.compile("^\\s*\\.uno:ModifiedStatus=(true|false)\\s*$");
    private static final Pattern JSON_COMMAND = Pattern.compile("\"commandName\"\\s*:\\s*\"\\.uno:ModifiedStatus\"");
    private static final Pattern JSON_STATE = Pattern.compile("\"state\"\\s*:\\s*\"(true|false)\"");

    private volatile boolean modified;
    private volatile boolean heard;

    public void onEngineMessage(byte[] message) {
        if (message == null || message.length <= PREFIX.length() || message[0] != 's') return;
        String text = new String(message, StandardCharsets.UTF_8);
        if (!text.startsWith(PREFIX)) return;
        String payload = text.substring(PREFIX.length());
        Matcher plain = TEXT.matcher(payload);
        if (plain.matches()) {
            modified = Boolean.parseBoolean(plain.group(1));
            heard = true;
            return;
        }
        if (JSON_COMMAND.matcher(payload).find()) {
            Matcher state = JSON_STATE.matcher(payload);
            if (state.find()) {
                modified = Boolean.parseBoolean(state.group(1));
                heard = true;
            }
        }
    }

    public boolean modified() {
        return modified;
    }

    /** Whether any '.uno:ModifiedStatus' frame arrived; until one does, the engine's state is unknown. */
    public boolean heard() {
        return heard;
    }

    /**
     * What a closing editor does: "save" or "discard" once the user answered the close question, otherwise
     * "unchanged" (close without a new version) or "ask". Without any ModifiedStatus frame ([heard] false)
     * it asks, so a missing signal never discards edits.
     */
    public static String closeStep(String decision, boolean modified, boolean heard, String workingSha256,
            String inputSha256) {
        if ("save".equals(decision) || "discard".equals(decision)) return decision;
        return changed(modified || !heard, workingSha256, inputSha256, false) ? "ask" : "unchanged";
    }

    /**
     * The close reason of an editor closed before its document finished opening: only a working copy that is
     * still the opened original is "unchanged"; anything else (a reopened copy with earlier work, or an
     * unreadable one) has no reason, so the app keeps it to continue.
     */
    public static String loadingCloseReason(String workingSha256, String inputSha256) {
        return workingSha256 != null && workingSha256.equals(inputSha256) ? "unchanged" : null;
    }

    /** An unreadable working copy (null hash) counts as changed, so closing asks instead of discarding. */
    public static boolean changed(boolean modified, String workingSha256, String inputSha256, boolean resumedWithChanges) {
        return modified || resumedWithChanges || workingSha256 == null || !workingSha256.equals(inputSha256);
    }
}
