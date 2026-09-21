import asyncio
import json
import time
from .hermes import ConnectorError
from .store import TERMINAL


class RunManager:
    def __init__(self, store, connector):
        self.store, self.connector = store, connector
        self.tasks, self.locks = {}, {}
        self.on_finished = None

    async def start(self):
        for request in self.store.requests(active=True):
            self.schedule(request["id"], recovering=True)

    async def admit(self, request_id, session_id, text):
        existing = self.store.get(request_id)
        if existing:
            record, _ = self.store.admit(request_id, session_id, text)
            return record
        if not self.connector.features:
            await self.connector.capabilities()
        if not self.connector.features.get("run_submission") or not self.connector.features.get("run_events_sse"):
            raise ConnectorError("This Hermes version does not advertise the Runs streaming API. Upgrade Hermes before submitting work.", 503)
        await self.connector.session(session_id)
        if len(self.store.requests(active=True)) >= 30:
            raise ConnectorError("Too many queued requests. Wait for a run to finish.", 429)
        record, new = self.store.admit(request_id, session_id, text)
        if new:
            self.publish(record)
            self.schedule(request_id)
        return record

    def publish(self, record):
        public = {k: v for k, v in record.items() if k != "history"}
        self.store.emit("run.updated", record["session_id"], record["id"], run=public)

    def schedule(self, request_id, recovering=False):
        if request_id not in self.tasks:
            task = asyncio.create_task(self.execute(request_id, recovering))
            self.tasks[request_id] = task
            task.add_done_callback(lambda _: self.tasks.pop(request_id, None))

    async def execute(self, request_id, recovering):
        request = self.store.get(request_id)
        lock = self.locks.setdefault(request["session_id"], asyncio.Lock())
        async with lock:
            request = self.store.get(request_id)
            if request["status"] in TERMINAL: return
            try:
                if not request["upstream_id"]:
                    if request["stop_requested"]:
                        self.publish(self.store.update(request_id, status="cancelled"))
                        return
                    if recovering and request["status"] != "queued":
                        capability = self.connector.features.get("runs_idempotency", {})
                        safe = (isinstance(capability, dict) and capability.get("durable")
                                and time.time() - request["created"] < capability.get("retention_seconds", 0))
                        if not safe:
                            raise ConnectorError("Submission outcome is unknown. Check Hermes before sending again.")
                    if not request["history"]:
                        history = await self.connector.messages(request["session_id"])
                        request = self.store.update(request_id, history=json.dumps(history["messages"]))
                    self.publish(self.store.update(request_id, status="submitting"))
                    upstream = await self.connector.submit(request)
                    rid = str(upstream["run_id"])
                    request = self.store.update(request_id, upstream_id=rid, status="running")
                    self.publish(request)
                    if request["stop_requested"]:
                        await self.connector.stop(rid)
                    recovering = False
                if recovering:
                    await self.poll_until_terminal(request_id)
                else:
                    try:
                        async for event in self.connector.events(request["upstream_id"]):
                            if await self.consume(request_id, event): break
                    except (ConnectorError, OSError, TimeoutError):
                        pass
                    except Exception:
                        # Recover by polling. Never blindly concatenate a replayed delta stream.
                        pass
                    if self.store.get(request_id)["status"] not in TERMINAL:
                        await self.poll_until_terminal(request_id)
            except asyncio.CancelledError:
                # An app-service restart does not cancel Hermes. Persist state for reconciliation.
                raise
            except Exception as exc:
                current = self.store.get(request_id)
                status = "unknown" if current["status"] == "submitting" or current["upstream_id"] else "failed"
                message = str(exc) if isinstance(exc, ConnectorError) else "The run could not be reconciled. Check Hermes before retrying."
                self.publish(self.store.update(request_id, status=status, error=message))
            finally:
                result = self.store.get(request_id)
                if result["status"] in TERMINAL and self.on_finished:
                    await self.on_finished(result)

    async def poll_until_terminal(self, request_id):
        request = self.store.get(request_id)
        self.store.emit("run.reconnecting", request["session_id"], request_id)
        failures = 0
        while True:
            try:
                status = await self.connector.status(request["upstream_id"])
                failures = 0
                state = status.get("status", "running")
                if state in TERMINAL:
                    await self.consume(request_id, {"type": "run." + state, "data": status})
                    return
                if state in {"running", "stopping", "waiting_for_approval", "queued"}:
                    self.publish(self.store.update(request_id, status=state))
                    if status.get("approval"):
                        await self.consume(request_id, {"type": "approval.request", "data": status["approval"]})
            except ConnectorError as exc:
                failures += 1
                if exc.status == 404 or failures >= 12:
                    raise ConnectorError("Run status is unavailable. Its outcome is unknown; check Hermes.")
            await asyncio.sleep(2 if failures == 0 else min(failures * 2, 20))

    async def consume(self, request_id, event):
        request = self.store.get(request_id)
        if request["status"] in TERMINAL: return True
        kind, data = event["type"], event["data"]
        if kind in {"message.delta", "assistant.delta", "response.output_text.delta"}:
            delta = data.get("delta", "")
            if isinstance(delta, str):
                self.store.update(request_id, output=request["output"] + delta)
                self.store.emit("message.delta", request["session_id"], request_id, delta=delta)
        elif kind.startswith("run.") and kind.removeprefix("run.") in TERMINAL:
            status = kind.removeprefix("run.")
            output = data.get("output")
            if not isinstance(output, str): output = request["output"]
            self.publish(self.store.update(request_id, status=status, output=output, error=data.get("error")))
            return True
        elif kind in {"tool.started", "tool.completed", "tool.failed", "subagent.start", "subagent.complete", "approval.request"}:
            # Restrict forwarded fields; upstream telemetry may carry implementation details.
            allowed = {"tool", "preview", "error", "duration", "request_id", "command", "description", "choices", "summary", "child_session_id"}
            payload = {k: v for k, v in data.items() if k in allowed}
            if kind == "approval.request":
                payload["approval_id"] = payload.pop("request_id", None)
                self.publish(self.store.update(request_id, status="waiting_for_approval"))
            self.store.emit(kind, request["session_id"], request_id, **payload)
        return False

    async def stop(self, request_id):
        request = self.store.get(request_id)
        if not request: raise ConnectorError("Run not found.", 404)
        if request["status"] in TERMINAL: return request
        request = self.store.update(request_id, stop_requested=1)
        if request["upstream_id"]:
            await self.connector.stop(request["upstream_id"])
            request = self.store.update(request_id, status="stopping")
        elif request["status"] == "queued":
            request = self.store.update(request_id, status="cancelled")
        self.publish(request)
        return request

    async def close(self):
        tasks = list(self.tasks.values())
        for task in tasks: task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
