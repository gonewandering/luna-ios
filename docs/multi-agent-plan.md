# Luna memory, multiple agents, and global voice

## Intended behavior

Luna owns a protected, searchable memory of the latest 12 user/assistant messages per known session. Entries carry an agent ID, session ID, message time, freshness information, and truncation/partial-output flags. The local search/context tools never call an external agent. Voice still requires an OpenAI connection to understand speech; retrieved context is supplied to that voice conversation.

Settings manages named Hermes and OpenAI-compatible connections. Each has its own Keychain credential, cache, model preferences, backend, and durable request queue. The existing Hermes connection migrates once, retaining its sessions, preferences, and pending work. Connection failures remain isolated. The home screen uses AGENTS and SESSIONS section labels, with plain named agent rows above five recent conversations across configured agents, including visibly cached sessions when an agent is offline. Each agent opens its full session list.

Global voice can start from Home or a conversation. Tools enumerate agents/sessions, search/read local context, create/select sessions, send work, inspect progress, discover Hermes tools/skills, and cancel explicitly targeted work. Execution always specifies both IDs; changing the visible conversation cannot redirect an admitted task. Names are display data, never unique routing keys. Ambiguous destinations require disambiguation. Pausing the microphone disables its outgoing track, keeps playback/agent work available, and exposes a tap-to-resume control.

## Implementation

1. Add profile registry and local memory types using protected atomic files; keep all credentials in Keychain. Reuse one independent AppStore/RunCoordinator per profile beneath a new top-level LunaStore.
2. Add a streaming Chat Completions adapter with local sessions, `/models` discovery and per-session models. This adapter owns its local transcript and reports interrupted streams after app suspension/restart; it cannot claim Hermes remote-run recovery, server tools or approvals. It never automatically replays an uncertain request.
3. Add agent management, home/agent session navigation, local-memory search, and a persistent global voice control. Retain existing rich chat, model selection, Auto routing, and dismissible notices.
4. Add explicit global voice tools and routing, with current agent/session context and labeled completion notices. Keep response/call deduplication and native per-session task queues.
5. Validate migration, session-ID collisions, recent-five ordering, offline search with no backend reads, bounded chronological memory, credential separation, simultaneous agent routing, deletion/edit guards, streaming completion/interruption and microphone mute. Build and visually inspect the app in the simulator. Live microphone/background behavior still requires an iPhone.

## Compatibility and limits

- Hermes uses its existing capabilities, sessions, Runs, catalog, tools and approval APIs.
- OpenAI-compatible means an HTTPS base URL serving `/models` and streaming `/chat/completions` (under `/v1` when the base is a server root). Arbitrary remote function-call execution is not part of Chat Completions compatibility; the endpoint must execute its own agent tools.
- Memory is a recent local snapshot, not a complete or necessarily current server history. Empty/unfetched context and older retained records are reported honestly. Messages are bounded to 6,000 characters per entry, with truncation labeled.
- Removing an agent removes its local memory, cache and key; it does not delete remote conversations. Active or uncertain tasks must be handled first.
- No external Luna helper is introduced.

API references: [GPT-Live delegation](https://developers.openai.com/api/docs/guides/live-delegation), [Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create).

## Follow-up: names and chat position

Agent names are saved locally and editable without reconnecting or stopping active work. Add an explicit local `find_agents` tool that resolves a spoken name to profile IDs, handles case/accents/spacing, and flags duplicate or partial matches for clarification. Keep identity-based routing after resolution. Verify names survive relaunch and failed saves leave current labels intact.

Replace the chat’s conditional “follow only while bottom is visible” behavior with automatic bottom scrolling for new messages and streaming output. Preserve top alignment for short conversations and avoid treating pagination of earlier history as a new reply. Verify the rendered scroll position after scrolling upward, receiving a message, and growing a streamed response.
