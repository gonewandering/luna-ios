import json
import time
from urllib.parse import quote
import httpx


class ConnectorError(Exception):
    def __init__(self, message, status=502):
        super().__init__(message)
        self.status = status


def path_id(value):
    return quote(str(value), safe="")


async def sse_events(lines):
    """SSE lines may span network frames; httpx handles incremental UTF-8."""
    data, name, event_id = [], "message", None
    async for line in lines:
        if not line:
            if data:
                raw = "\n".join(data)
                if raw != "[DONE]":
                    try:
                        payload = json.loads(raw)
                    except json.JSONDecodeError:
                        raise ConnectorError("Hermes returned an invalid streamed event.")
                    if isinstance(payload, dict):
                        yield {"type": payload.get("type") or payload.get("event") or name,
                               "data": payload, "id": event_id}
            data, name, event_id = [], "message", None
        elif not line.startswith(":"):
            field, _, value = line.partition(":")
            if value.startswith(" "):
                value = value[1:]
            if field == "data": data.append(value)
            elif field == "event": name = value
            elif field == "id": event_id = value


def content_text(content):
    if isinstance(content, str): return content
    if isinstance(content, list):
        parts = []
        for part in content:
            if not isinstance(part, dict): continue
            if part.get("type") in {"text", "output_text", "input_text"}:
                parts.append(str(part.get("text", "")))
            elif part.get("type") in {"image_url", "input_image"}:
                url = part.get("image_url", "")
                if isinstance(url, dict): url = url.get("url", "")
                if isinstance(url, str) and url.startswith("https://"):
                    parts.append(f"![Image]({url})")
        return "\n\n".join(parts)
    return "" if content is None else json.dumps(content, ensure_ascii=False)


def normalize_session(row):
    return {"id": str(row["id"]), "title": row.get("title") or "Untitled session",
            "preview": row.get("preview") or "", "source": row.get("source") or "Hermes",
            "updated_at": row.get("last_active") or row.get("started_at") or time.time(),
            "message_count": row.get("message_count") or 0}


def normalize_message(row, index):
    return {"id": str(row.get("id") or f"history-{index}"), "role": row.get("role", "assistant"),
            "content": content_text(row.get("content")), "tool_name": row.get("tool_name"),
            "created_at": row.get("timestamp") or time.time()}


class HermesHTTPConnector:
    def __init__(self, base_url, key, transport=None):
        self.http = httpx.AsyncClient(base_url=base_url.rstrip("/") + "/",
            headers={"Authorization": f"Bearer {key}"},
            timeout=httpx.Timeout(30, read=60), transport=transport)
        self.features = {}

    async def _json(self, method, path, **kwargs):
        try:
            response = await self.http.request(method, path.lstrip("/"), **kwargs)
        except httpx.HTTPError as exc:
            raise ConnectorError("Hermes is unreachable. Check the server address and network.") from exc
        if response.is_error:
            # Do not relay arbitrary upstream error bodies, which may contain secrets.
            labels = {401: "Hermes rejected its API key.", 403: "Hermes denied this operation.",
                      404: "Hermes session or run was not found.", 409: "Hermes rejected a conflicting operation.",
                      429: "Hermes is busy. Try again shortly."}
            raise ConnectorError(labels.get(response.status_code, f"Hermes returned HTTP {response.status_code}."), response.status_code)
        return response.json()

    async def capabilities(self):
        value = await self._json("GET", "/v1/capabilities")
        self.features = value.get("features", {})
        return value

    async def toolsets(self):
        value = await self._json("GET", "/v1/toolsets")
        rows = value.get("data", []) if isinstance(value, dict) else value
        if not isinstance(rows, list): raise ConnectorError("Hermes returned an invalid tool catalog.")
        return {"toolsets": [{"name": row["name"], "label": row.get("label", row["name"]),
                              "description": str(row.get("description", ""))[:500],
                              "enabled": row.get("enabled", False) is True,
                              "configured": row.get("configured", False) is True,
                              "tools": [name for name in row.get("tools", []) if isinstance(name, str)]}
                             for row in rows if isinstance(row, dict) and isinstance(row.get("name"), str)],
                "execution": "Hermes runs requested tools through send_prompt in the bound session. Enabled and configured are reported by Hermes; runtime credentials can still fail."}

    async def skills(self):
        value = await self._json("GET", "/v1/skills")
        rows = value.get("data", []) if isinstance(value, dict) else value
        if not isinstance(rows, list): raise ConnectorError("Hermes returned an invalid skill catalog.")
        return {"skills": [{"name": row["name"], "description": str(row.get("description", ""))[:500],
                            "category": str(row.get("category", ""))}
                           for row in rows if isinstance(row, dict) and isinstance(row.get("name"), str)]}

    async def sessions(self, offset=0, limit=50):
        value = await self._json("GET", "/api/sessions", params={"offset": offset, "limit": limit})
        return {"sessions": [normalize_session(s) for s in value.get("data", [])],
                "has_more": value.get("has_more", False)}

    async def session(self, sid):
        value = await self._json("GET", f"/api/sessions/{path_id(sid)}")
        return normalize_session(value["session"])

    async def create(self, title):
        value = await self._json("POST", "/api/sessions", json={"title": title, "source": "api_server"})
        return normalize_session(value["session"])

    async def rename(self, sid, title):
        await self._json("PATCH", f"/api/sessions/{path_id(sid)}", json={"title": title})
        return await self.session(sid)

    async def messages(self, sid, offset=0, limit=100):
        value = await self._json("GET", f"/api/sessions/{path_id(sid)}/messages",
                                 params={"offset": offset, "limit": limit, "order": "latest"})
        messages = [normalize_message(m, offset + i) for i, m in enumerate(value.get("data", []))
                    if m.get("role") in {"user", "assistant", "tool"}]
        return {"messages": messages, "has_more": len(value.get("data", [])) == limit,
                "resolved_session_id": value.get("session_id", sid)}

    async def submit(self, request):
        return await self._json("POST", "/v1/runs",
            headers={"Idempotency-Key": request["id"]},
            json={"session_id": request["session_id"], "input": request["text"]})

    async def status(self, rid):
        return await self._json("GET", f"/v1/runs/{path_id(rid)}")

    async def stop(self, rid):
        return await self._json("POST", f"/v1/runs/{path_id(rid)}/stop")

    async def approval(self, rid, request_id, choice):
        return await self._json("POST", f"/v1/runs/{path_id(rid)}/approval",
                                json={"request_id": request_id, "choice": choice})

    async def events(self, rid):
        async with self.http.stream("GET", f"v1/runs/{path_id(rid)}/events") as response:
            if response.is_error:
                raise ConnectorError("The Hermes stream disconnected.", response.status_code)
            async for event in sse_events(response.aiter_lines()):
                yield event

    async def close(self):
        await self.http.aclose()
