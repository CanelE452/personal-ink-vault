package io.github.canele452.personalinkvault.office;

import java.util.UUID;
import java.util.regex.Pattern;

/** Owns one live script request without executing scripts or invoking callbacks. */
public final class OfficeScriptSession {
    private static final Pattern SESSION_ID = Pattern.compile(
            "[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}");

    public enum Kind { READ, REPLACE }

    public static final class Ticket {
        public final String id;
        public final Kind kind;

        private Ticket(String id, Kind kind) {
            this.id = id;
            this.kind = kind;
        }
    }

    private final String nonce;
    private long sequence;
    private Ticket pending;
    private boolean uncertain;
    private boolean closed;

    public OfficeScriptSession(String sessionId) {
        if (sessionId == null || !SESSION_ID.matcher(sessionId).matches()) {
            throw new IllegalArgumentException("Invalid Office session ID");
        }
        nonce = UUID.randomUUID().toString();
    }

    public synchronized Ticket begin(Kind kind) {
        if (kind == null) throw new IllegalArgumentException("Office script kind is required");
        if (closed || uncertain || pending != null) {
            throw new IllegalStateException("Office script session is unavailable");
        }
        sequence = Math.incrementExact(sequence);
        pending = new Ticket("pivcell-" + nonce + "-" + sequence, kind);
        return pending;
    }

    public synchronized Ticket pending() {
        return pending;
    }

    public synchronized boolean owns(String id) {
        return pending != null && pending.id.equals(id);
    }

    public synchronized boolean finish(String id, boolean uncertain) {
        if (pending == null || !pending.id.equals(id)) return false;
        pending = null;
        this.uncertain = uncertain;
        return true;
    }

    public synchronized boolean blocksSave() {
        return closed || uncertain || pending != null;
    }

    public synchronized void close() {
        closed = true;
        pending = null;
    }
}
