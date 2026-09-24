# Verification record

Standalone refactor verified September 18, 2026, with Xcode 26.3 and an iPhone 16 Pro simulator running iOS 18.5. The previous Luna Python helper was stopped before direct integration checks; nothing was listening on its port 8787.

## Chat run ordering and scrolling — September 23, 2026

- All 66 ordinary tests passed on iPhone 16 Pro / iOS 18.5 with Xcode 26.3. All six rendered viewport tests also passed on iPhone 17 Pro / iOS 26.2.
- The added delegated-run regression failed against the prior implementation: a new Luna/API request moved a reader from the top of the history to the bottom. The final checks preserve the offset during new requests, streamed growth and history reconciliation, and verify that returning to the bottom resumes following. A reader 120 points above the bottom stays put even with the composer inset.
- Rendered checks cover short conversations, varied message heights, new tool activity and approvals, multiline drafts, keyboard presentation/dismissal, terminal status changes, and reconciliation while following. Screenshot text bounds verify that activity sits between its own prompt and the next queued prompt, approvals precede the response, and the final response ends above the composer without excess blank space.
- Inspected the retained ordering and final-response screenshots on both simulator OS versions. These checks use local fixtures; no live API calls were needed.

Logs and screenshot attachments are retained locally under `artifacts/chat-feed-stability/` and in the Xcode test result bundles.

## Shared text/voice input and launch artwork — September 19, 2026

- All 55 ordinary tests passed. After correcting the agent-list inset, both rendered viewport checks passed again; after the final response-validation change, all seven text-routing tests and the shared-composer view check passed again. Coverage includes clarification history, explicit agent/session admission, duplicate-send suppression, reasoning/tool-output continuation, malformed/incomplete response rejection, bounded loops, cancellation, and preserving drafts when the OpenAI key is missing.
- A live `gpt-5.6-luna` Responses check searched local messages across two temporary demo agents without submitting work or changing navigation. A follow-up named Research while another agent’s list was the browsing context; Luna resolved that name and admitted exactly one prompt in its correct session. No audio connection or real Hermes task was created.
- Visually inspected the common text/microphone input on Home, an agent’s session list, and session chat. Also inspected Luna’s dismissible clarification reply and typed follow-up with the send button. The actual chat viewport regression continues to pass after extracting the common input control. These simulator screenshots do not establish physical-device keyboard or microphone behavior.
- `Info.plist` selects the new launch storyboard. Its asset is byte-for-byte the approved untitled sage cat/moon image. A fresh isolated simulator installation verified that aspect-fit keeps the full artwork visible against the UI’s dark canvas. Temporary preview installations were removed without deleting the main app’s state.
- Credential and Swift whitespace scans pass across 78 nonignored project files. The native reasoning model remains `gpt-5.6-luna`, with `gpt-live-1` for audio. The final build was installed and launched using the existing main app’s Keychain and saved state.

Logs: `build-shared-composer-tests.log`, `build-shared-composer-ui-final.log`, `build-shared-composer-final.log`, `build-global-text-live.log`, `build-launch-cover-final.log`, and `build-luna-composer-installed.log`. Screenshots: retained attachments under `artifacts/shared-composer-keyboard/`, `artifacts/shared-composer-final/`, `artifacts/luna-home-shared-input.png`, and `artifacts/luna-launch-cover-fit.png`.

## Multiple agents, local memory, global voice, and Home updates — September 19, 2026

- All 47 ordinary tests pass on the iPhone 16 Pro / iOS 18.5 simulator. Coverage includes migration, distinct profile/session identities, recent-five ordering, bounded chronological memory, offline searches with zero backend reads, independent credentials/connections, explicit voice destinations, duplicate admission protection, compatible streaming and interrupted/truncated replies, and microphone pause state.
- Agent names survive relaunch, normalize case/accents/spacing for voice lookup, and flag ambiguous matches. Renaming while a task is active preserves its runtime, queue, key and voice destination; offline renaming makes no backend request. Blank names and failed registry writes leave the current labels intact.
- A rendered SwiftUI chat test starts with a long history, scrolls to the top, appends a message, then streams a growing reply. Each update ends at the actual bottom of the viewport. The retained screenshot shows the final streamed sentence above the composer. The test also checks initial bottom positioning.
- A real OpenAI global-voice check passed with two temporary demo agents. It resolved a newly renamed Research agent using `find_agents`, listed sessions, searched/read local context, switched to the exact Research session, sent exactly one prompt there, and paused the microphone. The other agent received no work, and no external history refresh occurred. A live `session.update` for destination instructions was also accepted. The check injected text into a receive-only WebRTC session: it validates live command routing, not physical microphone input or speech recognition.
- Home now has **AGENTS** and **SESSIONS** section labels, with no decorative icons beside agent names. The connection dots remain. The multi-agent Home and the streamed chat were visually inspected in the dark layout. The final app build and simulator installation succeed.
- Credential and Swift whitespace scans pass across all 63 nonignored project files. Agent keys stay in Keychain; no new service is required. Physical microphone/background behavior and real third-party compatible servers still require their own device/integration checks.

Logs: `build-agent-names-scroll-final.log`, `build-global-voice-names-live.log`, and `build-multi-agent-ui-final.log`. Screenshots: `artifacts/luna-multi-agent-home.png` and the retained attachment under `artifacts/chat-viewport-check/`. The earlier real global voice check is recorded in `build-global-voice-live.log`. No outgoing microphone track or remote Hermes task was created by these new live checks.

## Temporary status and error notices

- Simulator build and all 32 unit tests pass. New checks cover independent notice deadlines, immediate dismissal, replacement notices surviving old deadlines, automatic expiry without a mounted view, and keeping chat content and task state intact. Repeated updates do not replay dismissed task/connection notices; a new failure or outage can show again. Uncertain submissions still block queued work until explicitly acknowledged.
- Status notices and finished activity expire after eight seconds; errors and unsuccessful-task notices after twelve. Active tasks and approval controls remain available. Task history preserves past error/model details, and uncertain tasks keep an accessible review action in the header.
- Inspected the dark error and reconnection cards with their close buttons on iOS 18.5 and 26.2. An isolated iOS 26.2 preview confirmed both notices disappeared automatically while the prompt and response remained. The fixture uses no network or stored credentials. Credential and Swift whitespace checks pass across all 55 nonignored project files.

Logs: `build-notice-tests.log` and `build-notice-final-tests.log`. Screenshots: `artifacts/luna-notices-visible.png`, `artifacts/luna-notices-visible-ios26.png`, and `artifacts/luna-notices-cleared.png`.

## Auto model selection

- Final simulator build and all 29 ordinary unit tests pass. Credentials and Swift whitespace checks pass across the 52 nonignored project files.
- Updated app installed and launched with existing Keychain credentials. Visually inspected `artifacts/luna-auto-model-picker.png`: Auto is prominent above the provider list, explains lightweight versus difficult-task routing, and displays the OpenAI usage disclosure within the existing dark layout.
- Live OpenAI routing check passed with a controlled pair from the authenticated Jetson catalog: `claude-haiku-4-5-20251001` was selected for “What is 2 + 2?”, and `claude-opus-5` for a distributed-database migration plan and a contextual “Implement that” follow-up. The complex tasks were classification inputs only and were not executed by Hermes.
- A full-catalog end-to-end check created only its own `Luna Auto check` session, fetched the real catalog, let OpenAI choose, and submitted one no-tools marker request through the normal native queue. Auto chose Anthropic Haiku, Hermes returned `LUNA_AUTO_OK`, the answer was stored in the correct session, and the global Hermes default remained unchanged.
- The native app integration check changed a fixed-model demo session to Auto, reconnected, sent typed and voice-command requests, and verified different per-request choices while another session remained manual. Returning to a fixed model exited Auto. The demo routing check used no OpenAI audio connection.
- Unit coverage includes authenticated/schema-constrained routing, bounded recent context with tool-output exclusion, rejection of invalid indexes/refusals/incomplete responses, manual-preference migration, per-request reevaluation after queued predecessors, frozen choices after recovery, cancellation during selection, routing failures and disk-write failure preventing Hermes submission, and safe resumption of interrupted selection without a Hermes idempotency window.

Logs: `build-auto-model-tests.log`, `build-auto-model-final-tests.log`, `build-auto-model-live.log`, and `build-auto-full-catalog.log`. These checks use no microphone. The routing policy is a model judgment, not a guarantee of optimal quality/cost across all tasks or providers. Hermes' own override/fallback rules remain outside Luna's per-request control.

## Session model picker

- All 20 ordinary iOS tests pass. New coverage checks authenticated catalog requests and explicit refresh, provider/model identity, filtering and deduplication, exact session/model/provider acknowledgement, protected preferences, corrupt-file handling, connection isolation, old journal compatibility, and stable model/provider payloads across duplicate admission and recovery.
- Two targeted native integration checks pass. The on-device check saves different models for two fresh demo sessions, reconnects, and verifies that typed and voice-command admission retain their respective choices. An attempted change while a session is busy leaves its previous choice intact. This check calls the native voice command path without opening an OpenAI audio session.
- The live Jetson check creates only its own session, `Luna model selection check`, explicitly chooses the non-default `claude-haiku-4-5-20251001` through the session model API, and sends a no-tools marker prompt through the Runs API. Hermes completes with `LUNA_MODEL_OK`; both the session's reported model and stored answer match. A fresh catalog confirms the global default did not change.
- Final simulator build/install/launch succeeds with existing Keychain credentials. The dark picker loads real providers/models; search, provider grouping, server-default label and matching horizontal margins were visually inspected. Screenshot: `artifacts/luna-session-model-picker.png`.
- Credentials scan passes across all 51 nonignored project files. No new service or provider credentials were introduced.

Local logs: `build-model-tests.log`, `build-model-live.log`, and `build-model-final.log`. The live model check did not open a microphone or OpenAI voice connection. Strict suppression of Hermes' gateway `/model` overrides and fallback chains is not provided by the Runs API; this limitation is described in the picker and implementation notes. Physical-device layout and model-provider availability beyond this harmless live check remain unverified.

## Code formatting update

- All 16 iOS unit tests pass, including four added checks for Windows line endings and incomplete streamed fences, language aliases and conservative JSON/diff inference, embedded Markdown fences remaining literal code, and formatting instructions preserving the original prompt and retry payload.
- A native integration check created "Code in Luna" on the Jetson and requested a Swift greeting function plus JSON without running tools or changing files. Hermes returned both language-labeled blocks, and the exact response was verified in that session's stored history.
- The updated simulator app displays that real response. Inspected `artifacts/luna-hermes-code.png`: Swift keywords/types/functions and JSON keys/strings/numbers have distinct readable colors; indentation, blank lines, language headers, Copy controls, wrap toggles, and line counts render correctly.
- Formatting guidance is sent in the supported Hermes Runs `instructions` field, separately from the unchanged user prompt. Each new admission saves its instructions; old records omit the field and keep their original idempotent request payload.
- Code wrapping uses a fence longer than every backtick sequence in the source. Exact Copy uses the original source, including when the display is shortened for large blocks. Unsupported languages remain readable plain code.

Local logs: `build-code-rendering-tests.log` and `build-hermes-code-live.log`. The code-only check does not start an OpenAI voice session.

## Passed for the standalone app

- Native simulator build with ad-hoc signing and successful launch. XcodeGen regeneration, launcher syntax, and Info.plist validation pass.
- Twelve unit tests: direct Hermes authentication with profile paths; separation of OpenAI credentials; redacted authentication failures; byte-by-byte SSE events with CR/LF, multiline data and Unicode; URL restrictions; Keychain isolation, updates and deletion; exact and incomplete code blocks; admission persisted before submission; deduplicated per-session queues; persistence failure preventing submission; known-run recovery without resubmission or replay; queued cancellation; unknown outcomes blocking queued followers; completed voice-call correlation and deduplication. Some tests cover multiple behaviors.
- Direct native Hermes read integration, using the saved Keychain credential: capabilities, sessions, history and tools.
- On-device streaming integration: a prompt submitted to one demo session completed there while another session was selected, without changing that other session's messages. The output includes rich code and table content.
- Direct native Hermes execution: created the session "Luna standalone check", submitted a no-tools prompt through RunCoordinator, received `LUNA_DIRECT_OK`, and confirmed that answer in the same session's stored history. This supersedes the earlier provider authentication blocker. No provider configuration or remote files were changed.
- Real OpenAI silent integration: direct GPT-Live session creation, receive-only WebRTC negotiation, native sideband function routing, exactly one completed demo task in the bound session, and graceful closure.
- Real OpenAI playback integration: the same flow with WebRTC audio enabled and the playback callback observed. No outgoing microphone track was created.
- Simulator connection provisioned from existing local credentials, which were saved to Keychain. The session browser showed the Jetson's 11 sessions before the final test added its own session. The direct catalog probe returned 28 toolsets and 84 skills.
- Dark session browser screenshot inspected with the direct connection. Existing dark Markdown/code/table rendering is preserved.
- Cold launch without credential environment variables reconnected from Keychain and displayed the successful real prompt/answer in its correct session. Inspected `artifacts/luna-direct-chat.png`.
- A scan of all 49 nonignored project files found none of the configured credentials in source or documentation.

The first native voice attempt waited on a WebSocket ping before applying the WebRTC answer and stalled. Removing that dependency resolved startup: WebRTC negotiation and sideband attachment now proceed together. Both the silent and playback checks subsequently passed. Simulator audio emitted platform diagnostic warnings but did not crash and completed the playback regression.

The ordinary suite is `Luna`. The five opt-in integration checks are in `LunaLiveCheck`. Integration checks were run in separate invocations to isolate the startup fix and avoid repeating billable voice sessions unnecessarily. Logs are ignored local files: `build-native-tests.log`, `build-native-live.log`, `build-native-live-silent.log`, and `build-native-live-final.log`.

## Previous checks retained as history

Before this refactor, twelve Python helper tests passed and simulator audio startup was verified on both iOS 18.5 and iOS 26.2. Those results apply to the previous helper architecture; the current native app does not depend on that helper. The initial provider error on the Jetson was later absent in the successful direct native execution check above.

## Still requires hardware or further integration testing

- Physical iPhone microphone input, actual spoken-output quality, screen-lock/background voice, AirPods, interruptions and cellular handoffs. Background audio is configured, but simulator checks do not establish these behaviors on hardware.
- Live approval and cancellation against the Jetson's runtime; the UI and HTTP paths are implemented, but the harmless successful task did not request approval or require cancellation.
- Speech-to-real-Hermes execution as one combined test: the live OpenAI router was exercised against the on-device demo and the native Hermes adapter was exercised separately against Jetson.
- TestFlight signing/distribution and long-running memory/storage performance. Journal/cache compaction remains future work.

No microphone audio was recorded in local files. Demo output is explicitly labeled and does not represent real tool execution.
