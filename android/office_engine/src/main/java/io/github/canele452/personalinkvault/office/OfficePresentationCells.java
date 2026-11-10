package io.github.canele452.personalinkvault.office;

import android.app.AlertDialog;
import android.content.DialogInterface;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;

/** Native presentation-cell dialogs. Android JSUNO exposure still requires device verification. */
public final class OfficePresentationCells {
    private final OfficeEditorActivity host;
    private final String sessionId;
    private final String documentUrl;
    private final boolean presentation;
    private final OfficeScriptSession session;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ArrayList<AlertDialog> dialogs = new ArrayList<>();
    private Button button;
    private AlertDialog progress, editor, recovery;
    private EditText draft;
    private TextView original;
    private JSONObject selectedTable;
    private int selectedRow, selectedColumn;
    private Runnable timeout;
    private boolean closed, closeAfterPending;
    private String program;

    public OfficePresentationCells(OfficeEditorActivity host, String sessionId, File working, String format) {
        this.host = host;
        this.sessionId = sessionId;
        documentUrl = Uri.fromFile(working).toString();
        presentation = "ppt".equals(format) || "pptx".equals(format) || "odp".equals(format);
        session = new OfficeScriptSession(sessionId);
    }

    public void installButton() {
        if (!alive() || !presentation || button != null || !host.isCellEditorReady() || OfficeEngineHealth.requiresRestart()) return;
        button = new Button(host);
        button.setText("표 셀");
        button.setOnClickListener(view -> send(OfficeScriptSession.Kind.READ, null));
        FrameLayout.LayoutParams layout = new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.END);
        layout.topMargin = 48;
        layout.rightMargin = 12;
        host.addContentView(button, layout);
    }

    public boolean blocksSave() { return session.blocksSave() || OfficeEngineHealth.requiresRestart(); }

    public synchronized boolean onNativeMessage(byte[] frame) {
        OfficeScriptSession.Ticket ticket = session.pending();
        if (!OfficeCellReply.matches(frame, ticket)) return false;
        byte[] captured = frame.length > 1024 * 1024 ? null : frame.clone();
        host.runOnUiThread(() -> receive(ticket, captured));
        return true;
    }

    public boolean handleBack() {
        if (closed) return false;
        if (session.pending() != null) { waitThenClose(); return true; }
        if (blocksSave()) { showRecovery(); return true; }
        return false;
    }

    public synchronized void close() {
        if (closed) return;
        closed = true;
        cancelTimeout();
        session.close();
        for (AlertDialog dialog : dialogs) dialog.dismiss();
        dialogs.clear();
        if (button != null) button.setVisibility(View.GONE);
    }

    private boolean alive() { return !closed && !host.isFinishing() && !host.isDestroyed(); }

    private void send(OfficeScriptSession.Kind kind, String text) {
        if (!alive() || !host.isCellEditorReady() || blocksSave()) return;
        OfficeScriptSession.Ticket ticket = session.begin(kind);
        String script;
        try {
            JSONObject request = new JSONObject().put("protocol", "piv-cell-1").put("sessionId", sessionId)
                    .put("documentUrl", documentUrl).put("action", kind == OfficeScriptSession.Kind.READ ? "read" : "replace");
            if (kind == OfficeScriptSession.Kind.REPLACE) {
                JSONObject selected = selectedTable.getJSONArray("cells")
                        .getJSONObject(selectedRow * selectedTable.getInt("columns") + selectedColumn);
                JSONObject stylePlan = host.planCellText(selected.getString("text"), text);
                if (!alive() || session.pending() != ticket) return;
                request.put("expected", selectedTable).put("row", selectedRow).put("column", selectedColumn)
                        .put("text", text).put("stylePlan", stylePlan);
            }
            script = program() + "(" + request.toString().replace("\u2028", "\\u2028").replace("\u2029", "\\u2029") + ");";
            if (script.getBytes(StandardCharsets.UTF_8).length > 512 * 1024) throw new IOException("Cell script exceeds bound");
        } catch (IOException | JSONException | LinkageError error) {
            if (session.finish(ticket.id, false)) {
                closeAfterPending = false;
                showFailure();
            }
            return;
        }
        if (!alive() || session.pending() != ticket) return;
        progress = new AlertDialog.Builder(host).setTitle("표 셀")
                .setMessage(kind == OfficeScriptSession.Kind.READ ? "표 셀을 읽는 중입니다." : "셀의 변경을 확인하고 있습니다.")
                .setView(new ProgressBar(host)).setNegativeButton("작업 후 닫기", null).setCancelable(false).create();
        progress.setOnKeyListener((dialog, code, event) -> {
            if (code != KeyEvent.KEYCODE_BACK) return false;
            if (event.getAction() == KeyEvent.ACTION_UP) waitThenClose();
            return true;
        });
        show(progress);
        progress.getButton(DialogInterface.BUTTON_NEGATIVE).setOnClickListener(view -> waitThenClose());
        timeout = () -> {
            if (alive() && session.owns(ticket.id)) finish(ticket, null, true);
        };
        handler.postDelayed(timeout, 20000);
        boolean accepted;
        try { accepted = host.postCellScript(ticket.id, script); }
        catch (RuntimeException error) { finish(ticket, null, true); return; }
        if (!accepted && session.owns(ticket.id)) {
            session.finish(ticket.id, false);
            closeAfterPending = false;
            cancelTimeout();
            dismissProgress();
            showFailure();
        }
    }

    private String program() throws IOException {
        if (program != null) return program;
        try (InputStream input = host.getAssets().open("piv-presentation-cells.js");
             ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int count;
            while ((count = input.read(buffer)) != -1) {
                if (bytes.size() + count > 65536) throw new IOException("Cell program exceeds bound");
                bytes.write(buffer, 0, count);
            }
            program = StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes.toByteArray())).toString().trim();
            if (program.isEmpty()) throw new IOException("Cell program is missing");
            return program;
        }
    }

    private void receive(OfficeScriptSession.Ticket ticket, byte[] frame) {
        if (!alive() || session.pending() != ticket) return;
        try {
            if (frame == null) throw new IOException("Cell reply exceeds bound");
            OfficeCellReply.Result result = OfficeCellReply.decode(frame, ticket, sessionId, documentUrl);
            if (result == null) return;
            finish(ticket, result, result.uncertain);
        } catch (IOException error) { finish(ticket, null, true); }
    }

    private void finish(OfficeScriptSession.Ticket ticket, OfficeCellReply.Result result, boolean uncertain) {
        if (!alive() || !session.finish(ticket.id, uncertain)) return;
        cancelTimeout();
        dismissProgress();
        host.completeCellScript();
        if (uncertain) {
            OfficeEngineHealth.quarantine();
            if (button != null) button.setVisibility(View.GONE);
            showRecovery();
            return;
        }
        if (result == null || !result.success) { closeAfterPending = false; showFailure(); return; }
        if (closeAfterPending) { closeAfterPending = false; host.closeCellEditor(); return; }
        try {
            if (ticket.kind == OfficeScriptSession.Kind.REPLACE) {
                JSONObject table = result.body.getJSONObject("table");
                if (editor != null) editor.dismiss();
                editor = null;
                draft = null;
                showCells(table);
            } else if (editor != null && editor.isShowing()) {
                refreshEditor(result.body.getJSONArray("tables"));
            } else showTables(result.body.getJSONArray("tables"));
        } catch (JSONException error) { showFailure(); }
    }

    private void waitThenClose() {
        if (!alive() || session.pending() == null) return;
        closeAfterPending = true;
        if (progress != null) progress.setMessage("변경을 확인한 뒤 닫습니다");
    }

    private void cancelTimeout() {
        if (timeout != null) handler.removeCallbacks(timeout);
        timeout = null;
    }

    private void dismissProgress() {
        if (progress != null) progress.dismiss();
        progress = null;
    }

    private void showTables(JSONArray tables) throws JSONException {
        if (tables.length() == 0) {
            show(new AlertDialog.Builder(host).setTitle("문서의 표").setMessage("문서에서 표를 찾지 못했습니다.")
                    .setPositiveButton("닫기", null).create());
            return;
        }
        String[] labels = new String[tables.length()];
        for (int index = 0; index < labels.length; index++) {
            JSONObject table = tables.getJSONObject(index);
            labels[index] = "슬라이드 " + (table.getInt("slide") + 1) + " · 도형 " + (table.getInt("shape") + 1)
                    + " · " + table.getInt("rows") + " × " + table.getInt("columns") + "  " + table.getString("name");
        }
        show(new AlertDialog.Builder(host).setTitle("문서의 표").setItems(labels, (dialog, index) -> {
            if (!alive()) return;
            try { showCells(tables.getJSONObject(index)); } catch (JSONException error) { showFailure(); }
        }).setNegativeButton("닫기", null).create());
    }

    private void showCells(JSONObject table) throws JSONException {
        JSONArray cells = table.getJSONArray("cells");
        String[] labels = new String[cells.length()];
        for (int index = 0; index < labels.length; index++) {
            JSONObject cell = cells.getJSONObject(index);
            String text = cell.getString("text").replace('\n', ' ');
            int end = text.offsetByCodePoints(0, Math.min(40, text.codePointCount(0, text.length())));
            labels[index] = (cell.getInt("row") + 1) + "행 " + (cell.getInt("column") + 1) + "열 · "
                    + (cell.getBoolean("editable") ? "수정 가능" : "읽기 전용") + "  " + text.substring(0, end);
        }
        show(new AlertDialog.Builder(host).setTitle("표의 셀").setItems(labels, (dialog, index) -> {
            if (!alive()) return;
            try { showEditor(table, cells.getJSONObject(index)); } catch (JSONException error) { showFailure(); }
        }).setNeutralButton("새로 읽기", (dialog, which) -> send(OfficeScriptSession.Kind.READ, null))
                .setNegativeButton("닫기", null).create());
    }

    private void showEditor(JSONObject table, JSONObject cell) throws JSONException {
        if (!cell.getBoolean("editable")) {
            show(new AlertDialog.Builder(host).setTitle("읽기 전용 셀").setMessage(cell.getString("text"))
                    .setPositiveButton("닫기", null).create());
            return;
        }
        selectedTable = table;
        selectedRow = cell.getInt("row");
        selectedColumn = cell.getInt("column");
        LinearLayout content = new LinearLayout(host);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(24, 12, 24, 12);
        TextView notice = new TextView(host);
        notice.setText("셀 텍스트의 기존 글자 서식을 유지해 교체합니다. 병합 셀은 수정할 수 없습니다.");
        content.addView(notice);
        draft = new EditText(host);
        draft.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        draft.setMinLines(4);
        draft.setGravity(Gravity.TOP | Gravity.START);
        draft.setText(cell.getString("text"));
        content.addView(draft);
        original = new TextView(host);
        original.setTextIsSelectable(true);
        original.setText("현재 원문\n" + cell.getString("text"));
        content.addView(original);
        ScrollView scroll = new ScrollView(host);
        scroll.addView(content);
        editor = new AlertDialog.Builder(host).setTitle("셀 텍스트").setView(scroll)
                .setPositiveButton("적용", null).setNeutralButton("새로 읽기", null).setNegativeButton("닫기", null).create();
        show(editor);
        editor.getButton(DialogInterface.BUTTON_POSITIVE).setOnClickListener(view -> {
            if (!alive() || blocksSave()) return;
            String text = draft.getText().toString();
            if (!validText(text)) { draft.setError("8192자 이내의 올바른 텍스트를 입력해주세요."); return; }
            send(OfficeScriptSession.Kind.REPLACE, text);
        });
        editor.getButton(DialogInterface.BUTTON_NEUTRAL).setOnClickListener(view -> send(OfficeScriptSession.Kind.READ, null));
    }

    private void refreshEditor(JSONArray tables) throws JSONException {
        editor.getButton(DialogInterface.BUTTON_POSITIVE).setEnabled(false);
        for (int index = 0; index < tables.length(); index++) {
            JSONObject table = tables.getJSONObject(index);
            if (table.getInt("slide") != selectedTable.getInt("slide") || table.getInt("shape") != selectedTable.getInt("shape")) continue;
            if (selectedRow >= table.getInt("rows") || selectedColumn >= table.getInt("columns")) break;
            JSONObject cell = table.getJSONArray("cells").getJSONObject(selectedRow * table.getInt("columns") + selectedColumn);
            selectedTable = table;
            original.setText("새로 읽은 현재 원문\n" + cell.getString("text"));
            editor.getButton(DialogInterface.BUTTON_POSITIVE).setEnabled(cell.getBoolean("editable"));
            return;
        }
        original.setText("선택한 셀을 다시 찾지 못했습니다. 입력한 내용은 남아 있습니다.");
    }

    private static boolean validText(String text) {
        if (text.length() > 8192) return false;
        for (int index = 0; index < text.length(); index++) {
            char code = text.charAt(index);
            if (Character.isHighSurrogate(code)) {
                if (++index >= text.length() || !Character.isLowSurrogate(text.charAt(index))) return false;
            } else if (Character.isLowSurrogate(code)) return false;
        }
        return true;
    }

    private void showFailure() {
        if (!alive()) return;
        show(new AlertDialog.Builder(host).setTitle("셀 작업을 완료하지 못했습니다")
                .setMessage("입력한 내용은 남아 있습니다. 표를 새로 읽고 현재 원문을 확인해주세요.")
                .setPositiveButton("확인", null).create());
    }

    private void showRecovery() {
        if (!alive() || recovery != null && recovery.isShowing()) return;
        recovery = new AlertDialog.Builder(host).setTitle("작업 복사본을 확인해주세요")
                .setMessage(OfficeEngineHealth.RECOVERY_MESSAGE).setCancelable(false)
                .setPositiveButton("저장하지 않고 닫기", (dialog, which) -> { if (alive()) host.finish(); }).create();
        show(recovery);
    }

    private void show(AlertDialog dialog) {
        if (!alive()) return;
        dialogs.removeIf(previous -> !previous.isShowing());
        dialogs.add(dialog);
        dialog.show();
    }
}
