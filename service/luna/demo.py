"""Explicit demo connector: deterministic sample content, never presented as real execution."""
import asyncio
import json
import time
import uuid
from .hermes import ConnectorError

WELCOME = """I've reviewed the session routing design. Every request keeps its original session ID, even when you switch conversations.

### The implementation

```swift
struct AgentRequest: Codable {
    let sessionID: String
    let prompt: String
    let requestID: UUID
}
```

| Component | Responsibility |
| --- | --- |
| iOS app | Voice and rich chat |
| Luna service | Routing and reconnects |
| Hermes | Agent execution |

> This is sample content from the demo connector. Connect your Hermes server to run real tasks.
"""


class DemoConnector:
    def __init__(self, store):
        self.store = store
        self.features = {"run_submission": True, "run_events_sse": True, "run_stop": True,
                         "runs_idempotency": {"supported": True, "durable": True}}
        self.runs = {}
        self.stopped = set()
        with store.db:
            store.db.executescript("""
              CREATE TABLE IF NOT EXISTS demo_sessions(id TEXT PRIMARY KEY, title TEXT, updated REAL);
              CREATE TABLE IF NOT EXISTS demo_messages(id TEXT PRIMARY KEY, session_id TEXT, role TEXT, content TEXT, created REAL);
            """)
            if not store.db.execute("SELECT 1 FROM demo_sessions LIMIT 1").fetchone():
                now = time.time()
                for sid, title in [("demo-luna", "Building Luna"), ("demo-design", "A quieter interface"), ("demo-research", "Weekend reading")]:
                    store.db.execute("INSERT INTO demo_sessions VALUES (?,?,?)", (sid, title, now))
                self._message("demo-luna", "user", "How should we connect voice to Hermes?")
                self._message("demo-luna", "assistant", WELCOME)
                self._message("demo-design", "assistant", "A warm canvas, clear typography, and room to think.\n\n- Keep the conversation in focus\n- Make voice a natural part of chat\n- Let background tasks stay in their own sessions")

    def _message(self, sid, role, text, mid=None):
        with self.store.db:
            self.store.db.execute("INSERT OR IGNORE INTO demo_messages VALUES (?,?,?,?,?)",
                                  (mid or str(uuid.uuid4()), sid, role, text, time.time()))
            self.store.db.execute("UPDATE demo_sessions SET updated=? WHERE id=?", (time.time(), sid))

    async def capabilities(self): return {"features": self.features}

    async def toolsets(self):
        return {"toolsets": [], "execution": "Demo mode only produces sample responses; no real tools execute."}

    async def skills(self): return {"skills": []}

    async def sessions(self, offset=0, limit=50):
        rows = self.store.db.execute("SELECT * FROM demo_sessions ORDER BY updated DESC LIMIT ? OFFSET ?", (limit, offset)).fetchall()
        return {"sessions": [await self.session(r["id"]) for r in rows], "has_more": len(rows) == limit}

    async def session(self, sid):
        row = self.store.db.execute("SELECT * FROM demo_sessions WHERE id=?", (sid,)).fetchone()
        if not row: raise ConnectorError("Session not found.", 404)
        messages = self.store.db.execute("SELECT content FROM demo_messages WHERE session_id=? ORDER BY created", (sid,)).fetchall()
        return {"id": sid, "title": row["title"], "updated_at": row["updated"], "source": "Demo",
                "preview": messages[-1][0][:140] if messages else "", "message_count": len(messages)}

    async def create(self, title):
        sid = "demo-" + str(uuid.uuid4())
        with self.store.db:
            self.store.db.execute("INSERT INTO demo_sessions VALUES (?,?,?)", (sid, title, time.time()))
        return await self.session(sid)

    async def rename(self, sid, title):
        await self.session(sid)
        with self.store.db:
            self.store.db.execute("UPDATE demo_sessions SET title=? WHERE id=?", (title, sid))
        return await self.session(sid)

    async def messages(self, sid, offset=0, limit=100):
        await self.session(sid)
        rows = self.store.db.execute("SELECT * FROM demo_messages WHERE session_id=? ORDER BY created DESC LIMIT ? OFFSET ?", (sid, limit, offset)).fetchall()
        return {"messages": [{"id": r["id"], "role": r["role"], "content": r["content"], "created_at": r["created"], "tool_name": None} for r in reversed(rows)], "has_more": len(rows) == limit, "resolved_session_id": sid}

    async def submit(self, request):
        rid = "demo-run-" + request["id"]
        self.runs.setdefault(rid, {"run_id": rid, "session_id": request["session_id"], "status": "running", "output": ""})
        self._message(request["session_id"], "user", request["text"], request["id"] + "-user")
        return {"run_id": rid}

    async def status(self, rid):
        return self.runs.get(rid, {"status": "interrupted", "error": "The demo service restarted."})

    async def stop(self, rid):
        self.stopped.add(rid)
        return {"status": "stopping"}

    async def events(self, rid):
        state = self.runs[rid]
        yield {"type": "tool.started", "data": {"tool": "Demo preview", "preview": "Preparing sample content"}}
        await asyncio.sleep(0.35)
        yield {"type": "tool.completed", "data": {"tool": "Demo preview", "preview": "Sample ready"}}
        output = "Here is a **streaming demo response**. Your prompt stayed in this session.\n\n" + WELCOME
        for i in range(0, len(output), 22):
            if rid in self.stopped:
                state["status"] = "cancelled"
                yield {"type": "run.cancelled", "data": {"status": "cancelled"}}
                return
            state["output"] += output[i:i+22]
            yield {"type": "message.delta", "data": {"delta": output[i:i+22]}}
            await asyncio.sleep(0.065)
        self._message(state["session_id"], "assistant", output, rid + "-assistant")
        state["status"] = "completed"
        yield {"type": "run.completed", "data": {"status": "completed", "output": output}}

    async def close(self): pass
