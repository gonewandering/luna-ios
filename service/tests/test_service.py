import asyncio
import json
import time
import uuid
from unittest.mock import AsyncMock

from fastapi.testclient import TestClient
import httpx
import pytest
from luna.app import create_app
from luna.config import Settings
from luna.hermes import HermesHTTPConnector, ConnectorError, sse_events
from luna.runs import RunManager
from luna.store import Store
from luna.voice import VoiceSession

AUTH = {"Authorization": "Bearer test-luna-token"}


def settings(tmp_path):
    return Settings(token="test-luna-token", database=str(tmp_path / "luna.sqlite"), demo=True)


def wait_for(client, request_id, terminal=True):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        rows = client.get("/v1/runs", headers=AUTH).json()["runs"]
        row = next((r for r in rows if r["id"] == request_id), None)
        if row and ((row["status"] in {"completed", "cancelled", "failed", "unknown"}) if terminal else row["status"] == "running"):
            return row
        time.sleep(0.02)
    raise AssertionError("Run did not reach expected state")


def test_authenticated_session_api_and_rich_history(tmp_path):
    with TestClient(create_app(settings(tmp_path))) as client:
        assert client.get("/health").status_code == 200
        assert client.get("/v1/sessions").status_code == 401
        assert client.get("/v1/events").status_code == 401
        assert client.get("/v1/tools").status_code == 401
        assert client.get("/v1/skills").status_code == 401
        assert client.get("/v1/tools", headers=AUTH).json()["toolsets"] == []
        assert client.get("/v1/skills", headers=AUTH).json()["skills"] == []
        page = client.get("/v1/sessions", headers=AUTH).json()
        assert len(page["sessions"]) == 3
        history = client.get("/v1/sessions/demo-luna/messages", headers=AUTH).json()
        assert "```swift" in history["messages"][-1]["content"]
        assert "| Component |" in history["messages"][-1]["content"]
        created = client.post("/v1/sessions", headers=AUTH, json={"title":"New work"}).json()
        assert created["title"] == "New work"
        assert client.patch(f"/v1/sessions/{created['id']}", headers=AUTH, json={"title":"Renamed"}).json()["title"] == "Renamed"


def test_submission_retry_and_session_isolation(tmp_path):
    with TestClient(create_app(settings(tmp_path))) as client:
        rid = str(uuid.uuid4())
        body = {"request_id":rid, "session_id":"demo-luna", "text":"Build the route"}
        assert client.post("/v1/requests", headers=AUTH, json=body).status_code == 202
        assert client.post("/v1/requests", headers=AUTH, json=body).status_code == 202
        wrong = {**body, "session_id":"demo-design"}
        assert client.post("/v1/requests", headers=AUTH, json=wrong).status_code == 409
        result = wait_for(client, rid)
        assert result["status"] == "completed"
        a = client.get("/v1/sessions/demo-luna/messages", headers=AUTH).json()["messages"]
        b = client.get("/v1/sessions/demo-design/messages", headers=AUTH).json()["messages"]
        assert sum(m["content"] == body["text"] for m in a) == 1
        assert not any(m["content"] == body["text"] for m in b)
        assert result["output"] == a[-1]["content"]


def test_active_snapshot_avoids_duplicate_early_user_message_and_stop_waits(tmp_path):
    with TestClient(create_app(settings(tmp_path))) as client:
        rid = str(uuid.uuid4())
        client.post("/v1/requests", headers=AUTH, json={"request_id":rid,"session_id":"demo-luna","text":"Stop this demo"})
        wait_for(client, rid, terminal=False)
        page = client.get("/v1/sessions/demo-luna/messages", headers=AUTH).json()
        assert not any(m["content"] == "Stop this demo" for m in page["messages"])
        assert page["runs"][0]["text"] == "Stop this demo"
        response = client.post(f"/v1/runs/{rid}/stop", headers=AUTH).json()
        assert response["status"] == "stopping"
        assert wait_for(client, rid)["status"] == "cancelled"


def test_event_ledger_survives_restart_and_rejects_rebinding(tmp_path):
    path = str(tmp_path / "ledger.sqlite")
    store = Store(path)
    store.bind("agent-A")
    event = store.emit("message.delta", "A", "run-1", delta="one")
    store.close()
    reopened = Store(path)
    reopened.bind("agent-A")
    assert reopened.events(0)[0]["cursor"] == event["cursor"]
    assert reopened.events(event["cursor"]) == []
    with pytest.raises(ValueError): reopened.bind("agent-B")
    reopened.close()


def test_sse_multiline_and_comment_frames():
    async def scenario():
        async def lines():
            for line in [": keepalive", "", "event: message.delta", 'data: {"delta":', 'data: "hello 🌙"}', "", "data: [DONE]", ""]:
                yield line
        values = [v async for v in sse_events(lines())]
        assert values == [{"type":"message.delta", "data":{"delta":"hello 🌙"}, "id":None}]
    asyncio.run(scenario())


def test_hermes_native_contract_and_profile_prefix():
    async def scenario():
        observed = []
        async def handle(request):
            observed.append(request)
            assert request.headers["Authorization"] == "Bearer private-hermes-key"
            if request.url.path.endswith("/v1/runs"):
                assert request.headers["Idempotency-Key"] == "request-123"
                assert json.loads(request.content) == {"session_id":"api_123", "input":"Do work"}
                return httpx.Response(202, json={"run_id":"run_1"})
            if request.url.path.endswith("/messages"):
                return httpx.Response(200, json={"session_id":"api_123", "data":[{"id":42,"role":"assistant","content":[{"type":"text","text":"Hello"}],"timestamp":1}]})
            return httpx.Response(200, json={"data":[{"id":"api_123","title":"Work","last_active":1}], "has_more":False})
        connector = HermesHTTPConnector("https://hermes.test/p/work", "private-hermes-key", httpx.MockTransport(handle))
        assert (await connector.sessions())["sessions"][0]["id"] == "api_123"
        assert (await connector.messages("api_123"))["messages"][0]["id"] == "42"
        await connector.submit({"id":"request-123", "session_id":"api_123", "text":"Do work"})
        assert all(r.url.path.startswith("/p/work/") for r in observed)
        await connector.close()
    asyncio.run(scenario())


def test_unknown_submission_is_not_automatically_reexecuted():
    async def scenario():
        store = Store(":memory:")
        store.admit("id", "A", "do work")
        store.update("id", status="submitting")
        connector = AsyncMock()
        connector.features = {}
        manager = RunManager(store, connector)
        await manager.execute("id", recovering=True)
        assert store.get("id")["status"] == "unknown"
        connector.submit.assert_not_called()
        store.close()
    asyncio.run(scenario())


def test_interrupted_stream_reconciles_final_output_without_concatenating_replay():
    async def scenario():
        store = Store(":memory:")
        store.admit("id", "A", "do work")
        store.update("id", status="running", upstream_id="upstream", output="partial")
        connector = AsyncMock()
        connector.status.return_value = {"status":"completed", "output":"Complete answer"}
        manager = RunManager(store, connector)
        await manager.execute("id", recovering=True)
        assert store.get("id")["output"] == "Complete answer"
        assert store.get("id")["status"] == "completed"
        connector.submit.assert_not_called()
        store.close()
    asyncio.run(scenario())


def test_voice_tools_pin_session_and_deduplicate_call_results():
    async def scenario():
        manager = AsyncMock()
        manager.store = Store(":memory:")
        manager.runs.admit.return_value = {"id":"request-1", "status":"queued"}
        voice = VoiceSession(manager, "live_1", "A")
        voice.send = AsyncMock()
        call = {"call_id":"call-1", "name":"send_prompt", "arguments":json.dumps({"prompt":"Do it", "session_id":"B"})}
        await voice.resolve_calls([call])
        await voice.resolve_calls([call])
        manager.runs.admit.assert_awaited_once()
        assert manager.runs.admit.call_args.args[1] == "A"
        manager.store.close()
    asyncio.run(scenario())


def test_discovery_keeps_mcp_names_and_distinguishes_disabled_or_unconfigured_tools():
    async def scenario():
        async def handle(request):
            assert request.url.path.startswith("/p/work/v1/")
            if request.url.path.endswith("toolsets"):
                return httpx.Response(200, json={"data": [
                    {"name":"file", "enabled":True, "configured":True, "tools":["read_file","write_file"]},
                    {"name":"mcp_workspace", "enabled":True, "configured":True,
                     "tools":["mcp_workspace_create_issue"], "headers":{"Authorization":"must-not-forward"}},
                    {"name":"disabled", "enabled":False, "configured":True, "tools":["disabled_tool"]},
                    {"name":"unconfigured", "enabled":True, "configured":False, "tools":["missing_tool"]},
                ]})
            return httpx.Response(200, json=[{"name":"review", "description":"Review code", "category":"code", "path":"private-path"}])
        connector = HermesHTTPConnector("https://hermes.test/p/work", "key", httpx.MockTransport(handle))
        catalog = await connector.toolsets()
        assert catalog["toolsets"][1]["tools"] == ["mcp_workspace_create_issue"]
        assert catalog["toolsets"][2]["enabled"] is False
        assert catalog["toolsets"][3]["configured"] is False
        assert "must-not-forward" not in json.dumps(catalog)
        skills = await connector.skills()
        assert skills == {"skills":[{"name":"review","description":"Review code","category":"code"}]}
        await connector.close()
    asyncio.run(scenario())


def test_voice_discovers_tools_without_starting_an_agent_run():
    async def scenario():
        manager = AsyncMock()
        manager.store = Store(":memory:")
        manager.connector.toolsets.return_value = {"toolsets":[{"name":"file","enabled":True,"configured":True,"tools":["write_file"]}]}
        manager.connector.skills.return_value = {"skills":[{"name":"review"}]}
        voice = VoiceSession(manager, "live_1", "A")
        tools = await voice.execute("get_hermes_tools", {}, "tool-call")
        skills = await voice.execute("get_hermes_skills", {}, "skill-call")
        assert tools["toolsets"][0]["tools"] == ["write_file"]
        assert skills["skills"][0]["name"] == "review"
        manager.runs.admit.assert_not_called()
        manager.store.close()
    asyncio.run(scenario())


def test_live_function_items_correlate_by_delegation_when_response_id_is_absent():
    async def scenario():
        manager = AsyncMock()
        manager.store = Store(":memory:")
        voice = VoiceSession(manager, "live_1", "A")
        voice.resolve_calls = AsyncMock()
        class Socket:
            def __aiter__(self):
                return self.events()
            async def events(self):
                for e in [
                    {"type":"response.created","response":{"id":"response-1"}},
                    {"type":"response.output_item.done","item":{"type":"function_call","call_id":"c1","name":"list_sessions","arguments":"{}"}},
                    {"type":"response.completed","response":{"id":"response-1","output":[]}},
                ]:
                    yield json.dumps({"type":"response.event","delegation_id":"d1","event":e})
                    await asyncio.sleep(0)
        voice.socket = Socket()
        await voice.receive()
        await asyncio.gather(*voice.jobs)
        voice.resolve_calls.assert_awaited_once()
        assert voice.resolve_calls.call_args.args[0][0]["call_id"] == "c1"
        manager.store.close()
    asyncio.run(scenario())
