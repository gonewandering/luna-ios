# Chat message flow: one on-device, chronological transcript

Every exchange in a conversation is stored on the phone and rendered in order:

1. **User → Luna**, typed or spoken.
2. **Luna's own tool use** (agent/session lookups, local context search).
3. **Luna → agent**, the prompt Luna actually delegates.
4. **Agent → Luna**, including interim text, tool calls and the final response.
5. **Luna → user**, Luna's interpretation or summary, with the raw agent response
   available by expanding it.

Labels always use the active agent's saved name (for example "LUNA → JETSON"),
never a hard-coded "Hermes".

## Where things stand

| Leg | Today | Gap |
|---|---|---|
| User → Luna, typed | `LunaStore.sendLunaText` appends to `lunaText.messages` (memory only, capped at 24) | Lost on relaunch; never shown in the session it routed to |
| User → Luna, spoken | `transcript` callback keeps a 600-character running string | Not persisted or segmented into turns |
| Luna → agent | `send_prompt` / `start_coding_task` → `RunCoordinator.admit`; `RunCard` renders `run.text` as **YOU** | Luna's rewrite looks like the user's words; no link to the original utterance |
| Agent → Luna, interim/tools | `AppStore.apply` → `activity[sid]` (memory only, capped at 30, notice-dismissed) | Lost on relaunch or after history refresh |
| Agent → Luna, final | `run.output`, then replaced by Hermes history | Works, but is the only durable leg |
| Luna → user | Voice gets a 350-character excerpt via `OpenAILiveSession.finished`; the spoken summary is never stored. Typed Luna replies only at admission | No summary ↔ raw link; typed Luna never reports results |
| Context on mic | `startVoice` passes `agent_id` and `session_id` only | No history, no agent or session name. `LocalMemory` keeps 12 messages at 6,000 characters |

Three stores (`ChatCache`, `LocalMemory`, `lunaText`) are replaced by one.

## Decisions

- **Retention:** keep everything. No automatic pruning. Removing an agent still
  deletes its local transcript.
- **Luna's tool use is shown**, collapsed as "Luna checked 3 things".
- **All typed input goes through Luna,** including the session composer. The
  composer pins the open session as the destination, but Luna still interprets the
  message, delegates it, and summarizes the response. The direct composer-to-agent
  path is removed from the UI. Without an OpenAI key, the composer is disabled with
  a Settings prompt rather than silently sending direct.
- **Storage:** SQLite via the system `libsqlite3`, with no new package dependency.

## Plan

### 1. One persistent transcript model

```swift
struct TranscriptEntry: Codable, Identifiable {
  let id: String            // stable: turnID, runID+"-prompt", toolCallID, server message id
  let turnID: String        // links everything caused by one user utterance
  var address: SessionAddress?   // nil = Luna-only thread until a destination is chosen
  let kind: Kind            // userToLuna, lunaTool, lunaToAgent, agentInterim,
                            // agentTool, agentFinal, lunaToUser
  var source: Source?       // typed, spoken
  var text: String
  var tool: ToolCall?       // name, arguments preview, result preview, status
  var runID: String?, upstreamID: String?
  var agentName: String?    // name at write time; fallback if the agent is removed
  var summarizes: [String]? // lunaToUser → agentFinal ids (the expandable raw response)
  var status: Status        // streaming, final, failed, partial
  let createdAt: Double; var seq: Int  // seq breaks timestamp ties
}
```

- `TranscriptStore` owns `transcript.sqlite` beside `profiles.json`. It has an
  `entries` table indexed on `(agent_id, session_id, created_at, seq)`, plus an FTS5
  index so `search_local_context` covers everything retained. The file uses
  `completeFileProtectionUntilFirstUserAuthentication` and is excluded from backup,
  like `ProtectedFile`.
- Streaming updates upsert one entry in place and are coalesced about every 500 ms.
  Final states commit immediately.
- One-time migration imports `ChatCache.messages`, `runs` and `memory.json`.
  `LocalMemory` search and context read from `TranscriptStore` afterwards.
- Labels show the current profile name for `address.agentID`. The stored
  `agentName` is used only once that agent has been removed.

### 2. Capture every leg at its source

| Kind | Hook |
|---|---|
| userToLuna, typed | `sendLunaText` (global composer and session composer), at the existing `turnID` |
| userToLuna, spoken | Completed input transcript events in `OpenAILiveSession.handle` (today only `.delta` is read). Every tool call in that response shares the turn's `turnID` |
| lunaTool | `LunaStore.executeVoice` for the local tools (`list_agents`, `find_agents`, `list_sessions`, `search_local_context`, `get_session_context`, `select_session`, `create_session`, `refresh_session`, `get_response_details`, and the tool/skill discovery calls) |
| lunaToAgent | `send_prompt` / `start_coding_task` at admission, with `runID` and `turnID` |
| agentInterim / agentTool | `RunCoordinator.consume` deltas and the `tool.*` / `subagent.*` events via `AppStore.apply`, persisted instead of held in `activity` |
| agentFinal | `onFinished` with the final run output |
| lunaToUser | Voice: completed output transcript per response. Typed: the router reply and the post-run summary |

A turn's first entries may have no destination yet. They live in the Luna thread
and gain an `address` once Luna selects or creates a session, after which they also
render in that session.

### 3. Reconcile with agent history

When the server's messages load:

- A server `user` message equal to `run.text` resolves to the `lunaToAgent` entry,
  reusing the pairing in `ConversationHistory.reconciledRunIDs`.
- Server `tool` messages resolve to `agentTool` entries.
- Messages that don't match, such as work from other clients, are imported as
  they are.

This removes the duplicate **YOU** bubble for Luna's prompts.

### 4. Luna interprets and summarizes every result

- When a run finishes, Luna writes a `lunaToUser` entry with
  `summarizes: [agentFinal.id]`, whether the user typed or spoke.
  - **Voice:** the spoken reply following the `finished` commentary becomes the
    summary.
  - **Typed:** a small Responses call with no tools and about 400 tokens
    interprets `run.output`. It is skipped when the output is already short, in
    which case the raw response is shown directly.
- Coding progress updates and final summaries land in the session timeline as
  `lunaToUser` entries, not only in the Luna sheet.
- The session composer routes through `sendLunaText` with the open session as a
  fixed destination. `LunaTextRouter` instructions gain a "bound session" mode
  that delegates to that session without asking where to send.
- Cost: every typed message now costs at least two OpenAI calls, one to
  interpret and one to summarize.

### 5. Distinct rendering

A single `TranscriptView` replaces the `MessageView`, `RunCard` and
`ToolActivityView` stack, and the Luna sheet reuses it.

- **You → Luna:** right-aligned bubble labelled "YOU · spoken" or "YOU · typed".
- **Luna's tool use:** collapsed "Luna checked 3 things" row that expands to each
  call and result.
- **Luna → agent:** narrow handoff card, "LUNA → {AGENT NAME}", with an arrow
  glyph and muted ink. Long prompts are clipped with "show full prompt".
- **Agent → Luna, interim:** a thin timeline rail grouped per run. Tool rows show
  name, status and a one-line preview, and tap to expand to arguments and result.
  The group collapses to "{Agent name} · 7 steps" when the run finishes.
- **Agent → Luna, final:** full rich message with the agent's name. When
  summarized, it is collapsed under the summary.
- **Luna → you:** Luna mark, serif, forest accent, with an expandable
  "View {agent name}'s full response".
- Existing hard-coded names are replaced by the agent's name:
  - `ChatView` "Hermes needs your approval"
  - `MessageView`'s default `agentName = "Hermes"`
  - `AppStore.agentName`'s fallback
  - `PendingApproval`'s default description

  Text that describes the Hermes server software, such as the model picker's
  provider note and connector instructions, stays.

### 6. Context on mic, session reactivation and session switch

- `TranscriptStore.context(address, budget:)` returns the agent name and ID, the
  session title and ID, and the latest entries, bounded to about 40 entries or
  12,000 characters. Tool entries are compressed to name plus status, and
  truncation is flagged.
- `LunaStore.startVoice(target:)` includes it in `initialContext`.
  `setVoiceTarget` / `updateDestination` send the new session's context when the
  destination changes during voice.
- `sendLunaText` uses the destination session's transcript as history in place
  of the 24-message `lunaText` buffer.
- `get_session_context` reads the same store, and `refresh_session` updates it.
- Everything is supplied as labelled, untrusted data, as today.

### 7. Phases

Each phase is a coherent commit with tests on `feature/chat-message-flow`.

1. `TranscriptStore`, the model and migration. Tests cover ordering, streaming
   upserts, FTS search, file protection and migration.
2. Capture for typed, Luna tool and agent legs, plus history reconciliation.
   Extend `ChatViewportTests` and `MultiAgentTests`.
3. Spoken capture from transcript completion events, with
   `OpenAILiveSession.handle` fixture tests.
4. `TranscriptView` styles, the raw-response expansion and agent-name labels,
   with a simulator visual check.
5. Context injection on mic, reactivation and session switch, with tests on
   `initialContext` and destination updates.
6. Composer through Luna, plus typed summaries.
7. Retire the `lunaText` buffer, the transient `activity` store and the
   12-message `LocalMemory`, and update `docs/multi-agent-plan.md` and the README.

## To verify early

- Whether Hermes' SSE `tool.*` events include arguments and results, or only
  `preview` (Luna reads only `tool`, `name` and `preview` today).
- The OpenAI Live event name for completed input and output transcripts (only
  `.delta` is handled today).
- OpenAI-compatible agents emit no tool events, so they show only final responses.
- Live microphone and background behaviour still require an iPhone.
