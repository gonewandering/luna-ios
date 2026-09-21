import asyncio
from contextlib import asynccontextmanager
import hashlib
import json
import secrets
import time
from typing import Literal
from uuid import UUID
from fastapi import FastAPI, Depends, Header, HTTPException, Query, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field, field_validator
from .config import Settings
from .demo import DemoConnector
from .hermes import HermesHTTPConnector, ConnectorError
from .store import Store
from .runs import RunManager
from .voice import VoiceManager


class Prompt(BaseModel):
    request_id: UUID
    session_id: str = Field(min_length=1, max_length=256)
    text: str = Field(min_length=1, max_length=32000)

    @field_validator("text")
    @classmethod
    def meaningful(cls, v):
        if not v.strip(): raise ValueError("A prompt cannot be blank.")
        return v.strip()


class Title(BaseModel):
    title: str = Field(min_length=1, max_length=150)


class VoiceOffer(BaseModel):
    session_id: str = Field(min_length=1, max_length=256)
    sdp: str = Field(min_length=1, max_length=100000)


class Approval(BaseModel):
    approval_id: str = Field(min_length=1, max_length=256)
    choice: Literal["once", "deny"]


def create_app(settings: Settings, connector=None):
    store = Store(settings.database)
    identity = "demo" if settings.demo else hashlib.sha256((settings.hermes_url + "|" + settings.hermes_key).encode()).hexdigest()
    store.bind(identity)
    connector = connector or (DemoConnector(store) if settings.demo else HermesHTTPConnector(settings.hermes_url, settings.hermes_key))
    runs = RunManager(store, connector)
    voice = VoiceManager(settings, store, connector, runs)
    runs.on_finished = voice.finished

    @asynccontextmanager
    async def lifespan(app):
        # A temporarily offline Hermes must not make the local ledger inaccessible.
        try: await connector.capabilities()
        except ConnectorError: pass
        await runs.start()
        await voice.start()
        yield
        await runs.close()
        await voice.close()
        await connector.close()
        store.close()

    app = FastAPI(title="Luna", version="0.1.0", lifespan=lifespan)
    app.state.store, app.state.runs, app.state.voice = store, runs, voice

    async def authenticate(authorization: str = Header(default="")):
        expected = "Bearer " + settings.token
        if not secrets.compare_digest(authorization.encode(), expected.encode()):
            raise HTTPException(401, "Connect with your Luna access token.")

    auth = [Depends(authenticate)]

    @app.exception_handler(ConnectorError)
    async def connector_error(request, exc):
        return JSONResponse({"detail": str(exc)}, status_code=exc.status if exc.status in {400,401,403,404,409,429,503} else 502)

    @app.get("/health")
    async def health(): return {"status": "ok"}

    @app.get("/v1/config", dependencies=auth)
    async def config():
        capabilities = await connector.capabilities()
        return {"demo": settings.demo, "voice_available": bool(settings.openai_key),
                "voice_model": settings.voice_model, "features": capabilities.get("features", {})}

    @app.get("/v1/sessions", dependencies=auth)
    async def sessions(offset: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=200)):
        return await connector.sessions(offset, limit)

    @app.get("/v1/tools", dependencies=auth)
    async def tools(): return await connector.toolsets()

    @app.get("/v1/skills", dependencies=auth)
    async def skills(): return await connector.skills()

    @app.post("/v1/sessions", dependencies=auth, status_code=201)
    async def new_session(body: Title): return await connector.create(body.title.strip() or "New session")

    @app.patch("/v1/sessions/{sid}", dependencies=auth)
    async def rename(sid: str, body: Title): return await connector.rename(sid, body.title)

    @app.get("/v1/sessions/{sid}/messages", dependencies=auth)
    async def messages(sid: str, offset: int = Query(0, ge=0), limit: int = Query(100, ge=1, le=500)):
        for _ in range(3):
            before = store.cursor()
            snapshot = await connector.messages(sid, offset, limit)
            active = [r for r in store.requests(active=True) if r["session_id"] == sid]
            base = next((r["history"] for r in active if r.get("history")), None)
            if offset == 0 and base is not None:
                # Pair a pre-run history with one coherent local run snapshot.
                snapshot["messages"] = json.loads(base)
            elif offset == 0 and any(e["session_id"] == sid and e["type"] in {"run.updated", "message.delta"}
                                      for e in store.events(before)):
                # A run finished or started while the upstream history was being read.
                continue
            snapshot["runs"] = [{k: v for k, v in r.items() if k != "history"} for r in active] if offset == 0 else []
            snapshot["cursor"] = store.cursor()
            return snapshot
        raise ConnectorError("The conversation changed during refresh. Try again shortly.", 503)

    @app.get("/v1/runs", dependencies=auth)
    async def run_list():
        return {"runs": [{k: v for k, v in r.items() if k != "history"} for r in store.requests()[-100:]], "cursor": store.cursor()}

    @app.post("/v1/requests", dependencies=auth, status_code=202)
    async def prompt(body: Prompt):
        try:
            result = await runs.admit(str(body.request_id), body.session_id, body.text)
        except ValueError as exc:
            raise HTTPException(409, str(exc))
        return {k: v for k, v in result.items() if k != "history"}

    @app.post("/v1/runs/{rid}/stop", dependencies=auth)
    async def stop(rid: str): return await runs.stop(rid)

    @app.post("/v1/runs/{rid}/approval", dependencies=auth)
    async def approve(rid: str, body: Approval):
        record = store.get(rid)
        if not record or not record["upstream_id"]: raise HTTPException(404, "Run not found.")
        if settings.demo: raise HTTPException(409, "Demo runs do not request approvals.")
        return await connector.approval(record["upstream_id"], body.approval_id, body.choice)

    @app.get("/v1/events", dependencies=auth)
    async def events(request: Request, after: int = Query(0, ge=0)):
        async def stream():
            cursor = after
            keepalive = time.monotonic()
            # A restored database can have a lower cursor than the phone's cache.
            if cursor > store.cursor():
                cursor = store.cursor()
                yield f"id: {cursor}\ndata: {json.dumps({'type':'reset','cursor':cursor,'payload':{}})}\n\n"
            while not await request.is_disconnected():
                rows = store.events(cursor)
                for event in rows:
                    cursor = event["cursor"]
                    yield f"id: {cursor}\ndata: {json.dumps(event)}\n\n"
                if time.monotonic() - keepalive > 10:
                    yield ": keepalive\n\n"
                    keepalive = time.monotonic()
                if not rows: await asyncio.sleep(0.08)
        return StreamingResponse(stream(), media_type="text/event-stream", headers={"Cache-Control":"no-cache", "X-Accel-Buffering":"no"})

    @app.post("/v1/voice", dependencies=auth, status_code=201)
    async def create_voice(body: VoiceOffer): return await voice.create(body.session_id, body.sdp)

    @app.post("/v1/voice/{vid}/heartbeat", dependencies=auth)
    async def voice_heartbeat(vid: str):
        session = voice.sessions.get(vid)
        if not session or session.closed: raise HTTPException(410, "Voice has ended.")
        session.last_seen = time.monotonic()
        return {"status":"active"}

    @app.delete("/v1/voice/{vid}", dependencies=auth)
    async def end_voice(vid: str):
        session = voice.sessions.pop(vid, None)
        if session: await session.close()
        return {"status":"closed"}

    return app
