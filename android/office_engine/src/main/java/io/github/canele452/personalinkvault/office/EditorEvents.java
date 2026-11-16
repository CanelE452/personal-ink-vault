package io.github.canele452.personalinkvault.office;

/** What the app hears from its open editors without a waiting Dart call; MainActivity forwards these to Dart. */
public interface EditorEvents {
    /** The user went back to the app's tabs; the editor stays open behind them. */
    void left(String sessionId);

    /** An editor result arrived that no Dart call waited for: "saved", "cancelled" or "failed". */
    void finished(String sessionId, String status);
}
