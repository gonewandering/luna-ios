import json
from pathlib import Path
import sqlite3
import time

TERMINAL = {"completed", "cancelled", "failed", "interrupted", "unknown"}


class Store:
    """Single event-loop owner. Transactions never span a network await."""

    def __init__(self, path: str):
        if path != ":memory:":
            Path(path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.executescript("""
          PRAGMA journal_mode=WAL;
          CREATE TABLE IF NOT EXISTS requests (
            id TEXT PRIMARY KEY, session_id TEXT NOT NULL, text TEXT NOT NULL,
            status TEXT NOT NULL, upstream_id TEXT, output TEXT NOT NULL DEFAULT '',
            error TEXT, created REAL NOT NULL, updated REAL NOT NULL,
            stop_requested INTEGER NOT NULL DEFAULT 0, history TEXT
          );
          CREATE TABLE IF NOT EXISTS events (
            cursor INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL, created REAL NOT NULL
          );
          CREATE TABLE IF NOT EXISTS voice_tools (
            id TEXT PRIMARY KEY, result TEXT NOT NULL
          );
          CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)

    def bind(self, identity: str):
        row = self.db.execute("SELECT value FROM metadata WHERE key='connector'").fetchone()
        if row and row[0] != identity:
            raise ValueError("This database belongs to a different Hermes connection. Choose a new LUNA_DATABASE.")
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO metadata VALUES ('connector', ?)", (identity,))

    def get(self, request_id):
        r = self.db.execute("SELECT * FROM requests WHERE id=?", (request_id,)).fetchone()
        return dict(r) if r else None

    def admit(self, request_id, session_id, text):
        existing = self.get(request_id)
        if existing:
            if existing["session_id"] != session_id or existing["text"] != text:
                raise ValueError("Request ID already belongs to a different prompt or session.")
            return existing, False
        now = time.time()
        with self.db:
            self.db.execute("INSERT INTO requests (id,session_id,text,status,created,updated) VALUES (?,?,?,'queued',?,?)",
                            (request_id, session_id, text, now, now))
        return self.get(request_id), True

    def update(self, request_id, **fields):
        allowed = {"status", "upstream_id", "output", "error", "stop_requested", "history"}
        assert set(fields) <= allowed
        fields["updated"] = time.time()
        with self.db:
            self.db.execute("UPDATE requests SET " + ",".join(k + "=?" for k in fields) + " WHERE id=?",
                            (*fields.values(), request_id))
        return self.get(request_id)

    def requests(self, active=False):
        rows = [dict(r) for r in self.db.execute("SELECT * FROM requests ORDER BY created")]
        return [r for r in rows if r["status"] not in TERMINAL] if active else rows

    def emit(self, kind, session_id=None, request_id=None, **payload):
        event = {"type": kind, "session_id": session_id, "request_id": request_id, "payload": payload}
        with self.db:
            cur = self.db.execute("INSERT INTO events(body,created) VALUES (?,?)", (json.dumps(event), time.time()))
        event["cursor"] = cur.lastrowid
        return event

    def events(self, after, limit=200):
        result = []
        for row in self.db.execute("SELECT cursor,body FROM events WHERE cursor>? ORDER BY cursor LIMIT ?", (after, limit)):
            result.append({**json.loads(row["body"]), "cursor": row["cursor"]})
        return result

    def cursor(self):
        return self.db.execute("SELECT COALESCE(MAX(cursor),0) FROM events").fetchone()[0]

    def tool_result(self, key, result=None):
        if result is not None:
            with self.db:
                self.db.execute("INSERT OR IGNORE INTO voice_tools VALUES (?,?)", (key, json.dumps(result)))
        row = self.db.execute("SELECT result FROM voice_tools WHERE id=?", (key,)).fetchone()
        return json.loads(row[0]) if row else None

    def close(self):
        self.db.close()
