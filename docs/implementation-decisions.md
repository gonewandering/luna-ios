# Implementation decisions

## Standalone iOS

Luna now owns the orchestration previously performed by the Python helper. `HermesClient` reads sessions/history and submits runs directly to the built-in HTTP connector. `RunCoordinator` provides durable local admission, queues, cancellation, and recovery. `OpenAILiveSession` creates GPT-Live WebRTC sessions and owns a native authenticated sideband for structured tool calls. The old service is retained for reference and is not a runtime dependency.

The app accepts the user's own API keys at runtime. Each named agent profile owns a UUID-scoped Keychain account, and Luna voice uses a separate OpenAI account. Entries use `AfterFirstUnlockThisDeviceOnly`, do not synchronize to iCloud, and can be explicitly removed in Settings. URLSession uses ephemeral storage with no HTTP cookies/cache, and authenticated HTTP redirects are refused. API error messages do not relay arbitrary credential-bearing response bodies.

No supported public OAuth flow for a third-party GPT-Live app was verified. ChatGPT/Codex subscription tokens are not substituted for API keys. A distributed app using a developer-owned shared API key would still need a server-owned credential architecture; this implementation is for user-supplied keys.

## Structured voice commands

Home and agent-list composers also accept text through `LunaTextRouter` using OpenAI Responses and the same fourteen native tools. `MessageComposer` is shared with direct session chat. Outside chat, the user’s wording determines the destination; an open agent list is browsing context only. Discovery can list agents, resolve local names, list sessions, and search recent local memory without submitting agent work. Ambiguous destinations require clarification. Inside session chat, typed text also goes through the router with `bound_destination` set to that session; `LunaStore.checkBound` refuses any routing call that targets another session or creates/selects one, so a bound turn cannot leave its conversation. Photo sends from a session stay on the direct admission path because the router has no image input.

Typed Luna turns never open an audio connection. Requests use `store: false` and carry complete reasoning/function output items between bounded tool rounds, following the [Responses function-calling flow](https://developers.openai.com/api/docs/guides/function-calling). History sent for a new turn is bounded to twelve messages and 12,000 characters. Router history is the last 24 user/Luna rows of the persisted transcript; the preview shows the newest Luna reply and dismissal is remembered by entry ID. Retrieved agent context still goes to OpenAI. Agent credentials are never included in router requests.

Only completed Responses execute commands. Canonical mutation arguments receive stable turn-scoped admission IDs so a repeated mutation with another call ID cannot resubmit work. Conflicting call identities fail, and native agent/session validation remains authoritative. The loop is bounded to twelve rounds/24 calls, supports cancellation, and stops on backgrounding without active voice. Stopping Luna does not cancel previously admitted agent tasks. Session selection or admission opens the correct chat; router replies remain accessible from their preview.

GPT-Live uses Responses delegation to a command router exposing fourteen functions. Captions are display data. Only complete function items belonging to a completed response execute; the native sideband correlates them through response and delegation IDs. The primary WebRTC data channel does not execute commands. Calls are deduplicated by call ID and prompt admission IDs derive from the voice-session/call identity.

The router delegates user-requested work through `send_prompt`, including terminal, file edits, browser, skills and MCP-backed work enabled in Hermes. Tool discovery retains the enabled/configured distinction. Runtime provider failures are reported as failures. Remote results and catalogs are treated as untrusted data, and voice cannot approve Hermes actions.

One app-level `VoiceController` spans all profiles. Targeted tools require both `agent_id` and `session_id`; the native layer validates both and prevents reusing an admission ID for a different destination. `select_session` updates navigation and the explicit voice destination without restarting audio. UI navigation alone cannot redirect voice. A `session.update` changes the delegated router’s destination instructions when the user explicitly switches. Completion commentary labels the originating agent/session; full details are available through a local read-only function.

`find_agents` resolves device-local names with case/diacritic/whitespace normalization, preferring exact names and otherwise returning partial matches. Multiple matches are explicitly ambiguous; the router must ask instead of choosing the first. No lookup contacts a backend. `pause_microphone` disables the WebRTC microphone track and leaves playback and agent work available; only the visible Resume control unmutes it.

## Profiles and local memory

`LunaStore` owns named profiles, one runtime/queue per agent, composite session addresses, and app-wide voice. Home lists profiles before the five latest known sessions across them. A failed connection does not block other agents. Generic sessions that happen to share an ID remain isolated by profile UUID. Existing single-Hermes settings, credentials, caches, model preferences and journals migrate once.

Profile names are protected local metadata. Renaming writes the registry before publishing the new label, updates chat/cache labels immediately, and preserves the same runtime, Keychain account, sessions, queues and voice destination. It works while offline or busy. Endpoint, connector or credential changes instead create a fresh identity to keep account context separate, and require active/uncertain tasks to be resolved first. Removing an agent deletes local files/keys but never remote sessions.

`TranscriptStore` (SQLite via the system `libsqlite3`, `transcript.sqlite` beside `profiles.json`, file protection until first unlock, excluded from backup) is the single conversation record. Each `TranscriptEntry` has a kind (`userToLuna`, `lunaTool`, `lunaToAgent`, `agentInterim`, `agentTool`, `agentFinal`, `lunaToUser`), a turn ID linking everything one utterance caused, an optional session address (nil for Luna-only rows until a destination is chosen, then moved with `attach(turn:to:)`), and a monotonically assigned `seq` that breaks timestamp ties and never changes on update. Streaming rows are staged in memory and flushed every 500 ms; reads merge staged rows. FTS5 (unicode61, diacritics removed) indexes text, tool names, arguments and results. Nothing is pruned. The schema is versioned with additive in-place upgrades.

`TranscriptRecorder` writes an agent's run lifecycle (prompt at admission, tool events one row per use, output staged while streaming) and reconciles each history page: a live row is matched by turn and content and takes the server's timestamp, local-only rows that followed it in the same turn are nudged after it so a turn never reorders, and unmatched history (other clients) is imported under IDs scoped by agent and session because server message IDs repeat across agents. Tool arguments live on the calling assistant turn in Hermes history, so results are paired with their call via `tool_call_id`. `memory.json` and each agent's `cache.json`/run journal are imported once per agent (`migrated_agents`); `LocalMemory` is retired and the old file is only read for that import.

## OpenAI-compatible agents

`CompatibleAgentClient` uses the configured HTTPS endpoint’s models and streamed Chat Completions APIs. It keeps sessions, model preferences and messages in profile-local files because the protocol has no session CRUD contract. A root URL receives `/v1`; an explicit `/v1` path is preserved. Authorization is omitted for endpoints that require no key. Request history is bounded and includes only that profile/session’s user/assistant messages.

Explicit stop closes local streaming and reports that remote cancellation cannot be confirmed. Pending requests after restart become interrupted and are never automatically replayed. Truncated/error streams retain partial output and never claim completion. The adapter does not advertise a tools catalog, arbitrary function execution, Hermes approvals, or durable remote-run recovery. The endpoint must run its own tools.

## Durable runs and history

An atomic protected journal records admission before network submission, then the upstream run ID. Requests are serialized per session; different sessions may progress independently. The request ID is the Hermes idempotency key.

Known runs recover by polling status, replacing output snapshots instead of appending a potentially replayed stream. Unknown submissions only retry when Hermes advertises durable idempotency within its retention window. Unknown outcomes block later work in that session until explicitly acknowledged. Journal read failures prevent connection/admission instead of discarding recovery information. Persistence failure prevents new submissions.

Pre-run history is frozen while the run overlay streams, avoiding duplicate prompts from Hermes' concurrent persistence. Completed overlays remain until matching authoritative history is available. Session revisions keep stale history reads from replacing newer streamed state. Output always follows its run's bound session, not current navigation.

## Session model selection

The Hermes model catalog is `/api/model/options`, not the compatibility `/v1/models` alias list. Catalog normalization retains provider identity and model IDs, filters unconfigured providers from the picker, and never stores upstream keys, endpoint URLs or arbitrary configuration. Normal opens use conservative discovery; explicit refresh requests `refresh=1`.

The session model endpoint must acknowledge the exact session, model and provider before Luna activates a choice. Each connection/credential identity has its own protected `models.json` preferences file. If local persistence fails after the server acknowledges, the UI explicitly reports that Hermes saved the change but this device did not. Corrupt model preferences stop connection instead of silently discarding the choice.

Typed and voice admission capture the session's model/provider pair in `AgentRun`. A duplicate admission reuses the original record; recovery and retries never consult the latest picker value. Older journal records still omit model/provider fields. Model changes are blocked during local active/queued work or an unresolved submission outcome, and sending waits for an in-progress model change.

Hermes' Runs route accepts explicit model/provider fields but still gives existing gateway `/model` overrides precedence and can apply server-configured fallbacks. The separate session model endpoint persists a browser/API lock; it does not make `/v1/runs` a strict fail-closed model lock. The UI and README disclose this constraint. No gateway/provider configuration is changed. An unselected session shows “Hermes settings,” with its historical model separately labeled “Last reported.” OpenAI voice models are independent of this picker.

## Auto routing

Auto is an explicit per-session preference alongside a fixed model. `SessionModelPreference` reads the previous provider/model entries unchanged and adds a tagged Auto entry, so existing choices migrate without loss. Changing to Auto atomically writes the connection-scoped preferences before activating it. No server-global model or credential is changed; Auto sends explicit model/provider fields per run instead of repeatedly rewriting the Hermes session model lock.

The native RunCoordinator performs selection after local admission and after earlier work in the same session has completed. It captures fresh session history, reads the selected agent’s model catalog, and calls OpenAI Responses using `OpenAILiveSession.routerModel`. This shares the live agent's reasoning model while allowing typed prompts to work without WebRTC or a microphone. The routing policy is common to both input paths. It favors lightweight models for simple tasks, balanced models for ordinary work, and stronger reasoning models for planning, complex implementation/debugging and contextual follow-ups.

The selector receives exact catalog candidates with provider identity and bounded capability metadata, plus the original prompt and at most eight recent user/assistant messages (6,000 total characters, at most 1,500 each). Known media/embedding-only models, explicit non-tool models and the multi-agent aggregator are excluded. A strict JSON schema returns a candidate index, complexity and short public rationale. The native parser validates completion, index bounds/integrality and complexity; refusals, incomplete output, unlisted choices and network failures prevent Hermes submission. The routing request has no tools and uses `store: false`. This setting does not assert zero API data retention.

The journal records `automaticModel` at admission, then saves the selected model/provider and `modelDecision` before `/v1/runs`. Retry/recovery uses that saved pair and never reclassifies a submitted request. Interrupted selection is distinct from ambiguous Hermes submission, so it does not require the Hermes idempotency window to resume. Cancellation during selection cancels the local task; cancellation checks after async work prevent late results from starting a run. Disk failure while saving the selection also blocks submission. Unsubmitted failed/cancelled prompts stay visible in chat.

The picker discloses OpenAI usage and recent-chat review. Its latest choice and rationale, the run's requested-model label, and voice response details expose the decision without claiming that Hermes ignored its own override/fallback settings. There is no automatic escalation loop or retry through a different provider after Hermes starts work.

The shared native reasoning backend is `gpt-5.6-luna`. It powers live delegation, typed Luna turns, and Auto model selection. `gpt-live-1` handles audio. Fixed Hermes session model choices are independent. The retained Python reference service is not on the native app's path.

References: [GPT-Live delegation](https://developers.openai.com/api/docs/guides/live-delegation), [Structured Outputs](https://developers.openai.com/api/docs/guides/structured-outputs), [GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna).

## Temporary notices

Finished-task and connection status notices expire after eight seconds; errors and unsuccessful-task notices expire after twelve. Each has a 44-point accessible close button. General errors use the same nonblocking presentation in the main screen and Settings sheet. Active work and approval controls remain visible. Finished tool activity clears on the same schedule, and the composer's Auto model detail is shown only while work is active.

`TransientNotices` owns presentation deadlines independently of the durable run journal. Timers continue across navigation, expire again on foregrounding, and reset when changing connections. Repeated history updates or failed connection refreshes do not resurrect dismissed notices; a new task or a new outage can display a fresh notice. Restored terminal tasks do not replay stale banners. Dismissal never stops an agent, removes prompts/output, marks history reconciled, or unblocks an uncertain submission. Task history retains task errors and model decisions; unresolved submissions keep a review button in the chat header and require explicit acknowledgement there before more work can proceed.

## iOS lifecycle

Active voice uses background audio, a play-and-record audio session, and manual WebRTC audio activation through `RTCAudioSession`. The microphone begins only after voice negotiation. Audio stops before closing network connections; interruptions and removal of an audio route stop voice. A stop arriving during session creation is remembered so the late-created session is closed.

Without active voice, backgrounding pauses network consumers and saves state. Returning to the foreground resumes queued work and polls accepted runs. Closing the app never cancels an accepted Hermes task. Background audio is not a general entitlement to run indefinitely: process termination or network loss still requires reconnection, and screen-lock audio must be verified on hardware.

The on-device demo contains clearly labeled sample responses and never executes real tools. Optional demo voice still reaches OpenAI and is billable. A demo stream interrupted by suspension reports interruption; a real Hermes run continues remotely.

## Storage and rendering

Protected Codable files are scoped by connection/credential identity and excluded from backup. Credentials never enter these files or UserDefaults. Completed journal records currently remain for deduplication; compaction and indexed storage are future work for large installations.

Chat uses a bottom scroll anchor for initial positioning and top alignment for short conversations. It follows measured content and viewport changes only while the reader is within 80 points of the visible bottom, excluding the composer/keyboard inset. While following, SwiftUI’s bottom resize anchor maintains the content edge through lazy row measurement and keyboard changes; scrolling away selects the top resize anchor. Explicit sends and resumed following scroll to the content edge after layout instead of aligning an invisible row. User scrolling pauses those requests; a send from the session composer explicitly resumes following. Newly observed runs, including Luna voice/API submissions, preserve a reader who has scrolled up. Tool activity and approvals are scoped to their run and appear after its user prompt, before its response. Reconciled runs leave the live cards when server history takes over. This uses [SwiftUI’s scroll anchors](https://developer.apple.com/documentation/swiftui/view/defaultscrollanchor(_:for:)).

Textual renders Markdown, highlighting and tables. Native code cards preserve source exactly for copying, including incomplete streaming fences. Highlighting for very large blocks is bounded until expanded. Content is rendered as data, never executed.

## Chat photos and host-served attachments

The session composer uses `PhotosPicker` for selected library items and `UIImagePickerController` for camera capture, requesting camera permission only on demand. ImageIO normalizes orientation, bounds resolution/encoded size, and re-encodes pixels without EXIF/GPS. A draft is per-session and in memory. Admission writes immutable, SHA-256-addressed JPEG files under a hashed agent scope before persisting their descriptors in the run journal. Protected files are excluded from backup and removed with the agent. Streams therefore never rewrite base64 images. Missing or changed image files fail before submission; idempotency and history reconciliation include photo identity. Existing journals decode without attachments.

`POST /v1/runs` uses `input: [{role: "user", content: [{type: "text", text: "…"}, {type: "image_url", image_url: {url: "data:image/jpeg;base64,…"}}]}]` for photos. The outer user-message array is required by the [Hermes Runs handler](https://github.com/NousResearch/hermes-agent/blob/main/gateway/platforms/api_server_runs.py); content parts alone are not equivalent. Text-only payloads retain the original string format. This requires a current multimodal-capable Hermes implementation; no dedicated photo capability flag is advertised. Auto uses the attachment count and catalog vision hints without sending image bytes to the selector.

Received attachments are derived from Markdown in both live output and history, with structured `image_url`, `video_url`, and URL-backed file parts normalized to the same format. Fenced/inline code stays code. Explicit `Video:`/`File:` link labels handle extensionless URLs. Photos use downsampled native previews; videos download on demand and play through AVPlayer; other files use Quick Look and the system share sheet. Remote video codecs and file preview support depend on iOS. No host file server is implicitly started and filesystem paths are not rewritten into invented URLs.

A separate ephemeral URLSession downloads media without agent credentials, cookies, or credential storage. It validates URLs/redirects, checks HTTP status, bounds downloads (20 MB images; 250 MB video/files), and uses protected temporary files owned by the chat card through preview/sharing. HTTPS is supported universally; HTTP media permits tailnet addresses, MagicDNS, and local names. Narrow ATS exceptions cover `.ts.net`, `100.64.0.0/10`, and `fd7a:115c:a1e0::/48`; API connection validation still requires HTTPS. iOS 18+ supports these CIDR exceptions according to [Apple’s ATS documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains). Host availability, Tailscale connectivity, ACLs, and expiring links remain server/network concerns; failures show a retry action and an open-link fallback.

## Coding-agent sessions

Coding work is delegated to a coding-agent session inside Hermes instead of running in whichever conversation happens to be open. `CodingAgentBackend` describes Claude, Grok and Codex by model-name fragment and by the providers dedicated to each family; `openai` is deliberately not treated as Codex, so Codex requires a Codex-named model rather than any model that account can reach. `CodingAgentResolver` matches those descriptions against `AutoModelRouter.candidates`, so unauthenticated providers, non-agent models and models that cannot call tools never appear. The three are alternatives, not a required set: resolution prefers an explicitly requested backend, then the agent's most recent coding session, then the server's current provider, then declared order. A requested backend that Hermes cannot run is reported with the available alternatives instead of silently substituted.

`CodingSessionRegistry` records one session per agent and backend in a protected, backup-excluded `coding.json` beside the agent's cache. `AppStore.startCodingTask` reuses that session only when Hermes still returns it, creates `Coding · <Backend>` otherwise, locks the session model when `session_model_lock` is advertised, and admits the prompt through `RunCoordinator.admit` with an explicit provider/model. Every Runs request carries that pair, so an unconfirmed session lock is reported but does not change what executes. Losing the registry costs reuse only; the task itself is journaled at admission. Generic OpenAI-compatible endpoints are refused because they have no session or run API.

`start_coding_task` and `list_coding_agents` join the router's native tools for both voice and typed Luna, with `coding_agent` optional so the router names one only when the user did. `start_coding_task` is a canonical mutation, so a repeated call with another call ID cannot resubmit the work.

`CodingProgressReporter` reports a delegated run about every 60 seconds until it finishes or fails. Each update is composed from the durable journal and the app's own activity rows: status, elapsed time, latest and failed steps, pending approvals, errors and an output excerpt. Reports never contact Hermes, never resend, and are not a completion claim. The interval, clock and sleep are injected, so the cadence is tested without waiting. Updates are written to the coding session's transcript as Luna→user rows and, when voice is live, to its commentary as JSON data. Step names come from the transcript's tool rows, so progress survives relaunches. Reporting stops with the run, pauses on backgrounding without active voice, and resumes for still-active runs on return.

## Summaries and spoken turns

When a run from a typed turn finishes, `summarizeTypedRun` makes one tool-free Responses call (`gpt-5.6-luna`, 400 output tokens) and writes a `lunaToUser` row with `summarizes: [<output entry>]`; the view shows the summary with the raw answer in a disclosure. Answers of 600 characters or less are shown as they are. The typed/spoken check reads the transcript, so runs that finish after a relaunch are still summarized. Spoken turns are not summarized in text: Luna's spoken reply is recorded as the summary instead.

GPT-Live sends only `session.input_transcript.delta` / `session.output_transcript.delta`, with `start_ms`/`end_ms` and no turn-complete event. `VoiceTurnSegmenter` closes a turn on a speaker change, `session.delegation.created` (the user's request is complete), a gap over 1.5 s, or session close. Tool calls in a voice response carry the current user turn's ID, linking admitted work to what was said.

## References

- [Hermes HTTP API](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server)
- [GPT-Live WebRTC](https://developers.openai.com/api/docs/guides/voice-webrtc?api=live)
- [GPT-Live delegation](https://developers.openai.com/api/docs/guides/live-delegation)
- [GPT-Live controls](https://developers.openai.com/api/docs/guides/voice-server-controls?api=live)
- [Textual](https://github.com/gonzalezreal/textual)
- [Native WebRTC distribution](https://github.com/stasel/WebRTC)
