# Coding work delegation: Hermes coding-agent sessions

Issue: *Delegate coding work to a Hermes Claude/Grok/Codex session with ~1-minute
progress reports* (gonewandering/luna-ios#1).

## Where coding work is routed today

Every request reaches Hermes through one admission point, `RunCoordinator.admit`,
which journals the request before `HermesClient.submit` posts `/v1/runs`:

- Voice: `OpenAILiveSession` `send_prompt` → `LunaStore.executeVoice` →
  `AppStore.executeVoice` → `RunCoordinator.admit`.
- Typed Luna: `LunaStore.sendLunaText` → `LunaTextRouter.reply` (tools from
  `LunaVoiceTools`) → the same `executeVoice` path.
- Session composer: `AppStore.send(_:)` → `RunCoordinator.admit`.

Nothing distinguishes coding work, nothing owns a dedicated coding session, and
`Claude`/`Grok`/`Codex` appear only as ordinary rows in the model catalog read
from `GET /api/model/options`. Progress reaches the user only once, when
`RunCoordinator.onFinished` calls `OpenAILiveSession.finished`.

## Plan

1. **Coding backends as interchangeable alternatives.**
   `CodingAgentBackend` describes Claude, Grok and Codex by provider slug and
   model-name hints, and resolves each against the live Hermes catalog. All three
   are supported; none is compiled in as the default. Resolution order is the
   caller's explicit request, then the session's own remembered backend, then the
   server's current provider, then catalog order. Unauthenticated providers are
   simply absent, and Luna reports which alternatives exist.

2. **A reused coding session inside Hermes.**
   `CodingSessionRegistry` keeps one `(agent, backend) → session` record per agent
   profile in a protected, backup-excluded file. Coding work reuses that session
   when it still exists on the server and creates one named after the backend
   otherwise, locking the session to the resolved provider/model when Hermes
   advertises `session_model_lock`.

3. **A routing entry point for coding work.**
   A `start_coding_task` tool joins `LunaVoiceTools`, so both voice and typed Luna
   delegate implementation work instead of sending it to whatever conversation is
   open. It takes the prompt, an agent, and an optional backend; it returns the
   chosen backend, the reused-or-created session, the admitted request ID and the
   available alternatives. Direct sends from a session composer keep their
   explicit destination.

4. **Progress at roughly one-minute intervals.**
   `CodingProgressReporter` watches an admitted coding run and emits an update
   about every 60 seconds until it finishes or fails: status, elapsed time, the
   latest tool activity, an output excerpt, and blockers such as
   `waiting_for_approval` or an unknown outcome. Updates append to the Luna
   conversation and, when voice is live, to its commentary as data. The interval
   and clock are injectable so the cadence is testable without waiting.

5. **Tests and docs.** `LunaTests/CodingAgentTests.swift` covers backend
   resolution, session reuse and creation, the admitted payload, progress cadence
   and blocker reporting. README and `docs/implementation-decisions.md` record the
   behaviour and its limits.

## Constraints kept

- Admission stays durable and idempotent: coding work goes through
  `RunCoordinator.admit`, so recovery, per-session queues and stable request IDs
  are unchanged.
- The backend list is data from Hermes, not a hard-coded roster of one.
- Progress is best-effort presentation. It never resends work, and an update is
  not a claim that Hermes finished.
