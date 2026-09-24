# Luna

A native iPhone and iPad app for multiple Hermes and OpenAI-compatible agents, with dark, rich chat, local conversation memory, and app-wide OpenAI GPT-Live voice control. **No external Luna helper is required.** The phone connects directly to each agent and OpenAI; credentials stay in the device’s Keychain.

## Run

You need Xcode, XcodeGen, and an iOS 18+ simulator:

```sh
./scripts/run-ios.sh
```

This builds the app and opens its on-device demo. The demo needs no server or credentials and produces labeled sample responses. You can also open `ios/Luna.xcodeproj`, select the **Luna** scheme, and run. If you change sources or `ios/project.yml`, regenerate with `cd ios && xcodegen generate`.

## Connect agents and voice

1. Enable Hermes' HTTP connector with `API_SERVER_ENABLED=true` and a private `API_SERVER_KEY`, then start its gateway. See [Hermes' setup documentation](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server).
2. Open **Settings → Add agent** in Luna. Give it a name, choose **Hermes**, and enter its HTTPS address and API key. Tap **Save and connect**. Repeat for other agents. For the configured Jetson, the address is `https://jetson.tail428f1f.ts.net:8443`. A physical phone must join the same Tailscale network.
3. In Settings, save your own OpenAI API key under **Luna and Auto mode**. Luna uses it for voice, typed messages outside session chat, and Auto model selection. Direct text inside a fixed-model agent session does not need a separate OpenAI key. Voice uses `gpt-live-1`; structured command routing uses `gpt-5.6-luna`. These features incur OpenAI API usage.
4. Home shows your agents above the five latest known sessions across them. Home, agent lists, and session chat share the same text input and microphone button. Outside session chat, type or speak to Luna: “Find the conversation about our migration plan,” then “Use Research and continue that plan.” Luna searches names, sessions, and remembered messages, asks when the destination is unclear, and opens the exact conversation when sending work. Merely browsing an agent’s list does not select a destination. Text entered inside a session goes directly to that agent/session.

Choose **OpenAI compatible** for a server exposing `/models` and streaming `/chat/completions`. Enter its HTTPS base URL ending in `/v1` (a server root gets `/v1` appended), its key if required, and an optional default model. These conversations are created and stored in Luna because Chat Completions has no session-list API. The endpoint must execute any agent tools itself. **Stop reply** closes the local stream; it cannot guarantee that remote work stopped. Interrupted requests are not automatically replayed.

To rename an agent, open **Settings → agent → Name in Luna → Save name**. Names persist locally, work offline, and do not interrupt tasks or rename the remote service. Luna resolves these names before choosing an agent; duplicate names require clarification.

This version uses API keys. It does not implement ChatGPT/Codex OAuth or use subscription login tokens for voice API access. Each user's key is entered at runtime, never embedded in the app. Each agent profile has its own Keychain entry and isolated conversation files; Luna’s voice key is only sent to OpenAI. Agent API connections require HTTPS except for loopback development. Authenticated HTTP redirects are rejected to avoid forwarding credentials.

The development launcher can provision the simulator from the existing ignored `service/.env`, without starting the old service:

```sh
./scripts/run-ios.sh --connect
```

It reads `HERMES_BASE_URL`, `HERMES_API_KEY`, and `OPENAI_API_KEY` (preferring the process environment for the OpenAI key). This optional launcher path uses the existing `.venv` and `python-dotenv`. Credentials pass through the simulator launch environment, not command arguments, and are saved in the profile and Keychain before the connection is attempted. Provisioning is limited to simulator debug builds. Normal app setup needs no Python.

For a physical iPhone, select your Apple development team in Xcode's Signing settings. Allow microphone access when starting voice.

## Photos and received files

Inside a Hermes session, tap **+ → Take Photo** or **Photo Library**. Attach up to four pictures, remove any unwanted preview, and send with or without text. Photos are resized to at most 1,600 pixels on the long edge and encoded as JPEGs of at most 750 KB each, with location/EXIF metadata removed. Only selected library items are read; camera access is requested when taking a photo. Unsent photos stay in that session’s draft while the app is open. Submitted photos persist with the request for recovery and remain visible in chat.

Sending pictures requires a Hermes version whose Runs API passes multimodal input through to the agent, and a model that can interpret images. Auto avoids models explicitly marked as lacking vision and receives only the photo count, not image bytes. Generic OpenAI-compatible chats currently support text submissions only.

Hermes can return files hosted on a reachable HTTP(S) file server. The phone must have Tailscale connected and permission to reach that host and port. Luna shows photos inline; tap **Download** on a video or file for playback/Quick Look and **Share** to save it to Files or another app. Image downloads are limited to 20 MB; videos and other files to 250 MB. Unsupported preview formats can still be saved or opened using **Open link**. Downloaded copies are temporary; use Share to keep them.

Use absolute URLs, for example:

```markdown
![Chart](<http://jetson:8000/chart.png>)
[Video: demo.mp4](<http://100.100.20.30:8000/demo.mp4>)
[File: report.pdf](<https://jetson.example-tailnet.ts.net/files/report.pdf>)
```

Images and common file URLs are recognized by extension; the `Video:` and `File:` labels also work with extensionless or signed download URLs. This works in live replies and saved conversation history. Luna asks Hermes to use this format, but an actual file server must already expose the referenced file; a host filesystem path alone is insufficient. Media downloads do not receive the agent’s API key or cookies. Use tailnet access controls or signed links if the file server requires authorization. HTTP media links can use MagicDNS names, `.ts.net` hosts, and Tailscale IPv4/IPv6 addresses; other Internet hosts require HTTPS.

## What Luna does

- Keeps multiple named agents, independent connections, and the five most recent known sessions on Home. Cached conversations remain available when an agent is offline.
- Remembers the latest 12 user/assistant messages per session, ordered by time, with a 6,000-character limit per message. Search and voice context retrieval read this device state without contacting agents; partial, truncated, and approximate-time messages are labeled.
- Browses, searches, creates, and renames sessions, with paginated Hermes history and unread activity.
- Accepts typed requests to Luna on Home and agent lists, using the same discovery and routing tools as voice. Search-only requests report matches without starting agent tasks. Written replies have a dismiss control and open into a rich conversation view for clarification and follow-ups. This short Luna conversation stays in memory until the app closes; agent histories retain their normal persistence.
- Streams typed and voice-delegated work into its original agent/session, independent of the conversation currently open. Chat follows streamed content and tool activity while near the bottom, preserves your place when you scroll up, and resumes following when you return to the bottom or send from the session composer. Each run’s activity appears after its submitted prompt.
- Lets each session request its own agent model. Tap the model control above the message box (or **… → Choose model**) to search the server's available models by model/provider and refresh the catalog. Choices apply to both typed and voice prompts and survive reopening.
- Offers **Auto** in the session model picker. Luna chooses a lightweight model for simple questions, a balanced model for ordinary work, and a stronger model for planning or difficult tasks. Each new request gets its own choice using recent conversation context; the requested model and brief reason appear in chat and the picker.
- Renders Markdown, selectable text, tables, remote images, and tool activity. Code cards use a dark syntax palette with language labels, exact copying, line counts, and horizontal scrolling or optional line wrapping. Common language aliases and fenced JSON are recognized; incomplete streamed blocks remain visible.
- Sends camera or photo-library pictures directly to Hermes, with removable previews and optional captions. Receives photos, videos, and downloadable files through links, including files served by a host on the tailnet.
- Discovers Hermes' configured toolsets and skills, including reported MCP tools. The full configured Hermes tool surface is available through task delegation; Hermes enforces its own permissions and provider credentials.
- Shows approval requests with allow-once and deny controls. Voice cannot approve tools for the user.
- Starts Luna voice from Home, agent lists, or session chat, switches agent/session without restarting voice, and pauses its microphone when asked. Tap **Resume microphone** to speak again. Microphone mute, speaker mute, agent cancellation, and ending voice remain separate controls.
- Saves keys in device-only Keychain entries and excludes protected conversation caches and task journals from backups.
- Launches with the untitled sage cat-and-moon artwork, matched to the dark UI. `Info.plist` selects `LaunchScreen.storyboard`, which fits the complete image against the app’s canvas color.

Hermes remains the owner of agent history and execution. Luna writes each request to an atomic local journal before submitting it, serializes work per session, and uses stable idempotency IDs. Known remote runs recover by polling authoritative status. An ambiguous submission is retried only when Hermes advertises durable idempotency and its retention window remains valid. Otherwise Luna displays an unknown outcome and pauses queued followers until the user checks Hermes and dismisses that task.

An active, user-started voice conversation is configured to continue when the screen locks using iOS background audio. Without active voice, Luna pauses local network work and catches up when reopened. iOS does not guarantee uninterrupted networking or execution after termination; already accepted Hermes tasks continue on their host. Unsubmitted tasks remain queued locally until Luna resumes. There are no push notifications or always-on background agent controls in this version.

New typed and voice-delegated requests ask Hermes to return source, commands, configuration, and diffs in language-labeled Markdown fences. The original user prompt is unchanged, and explicit requests for plain text or an exact output still take precedence. Presentation instructions are saved with each admitted request so reconnecting or upgrading the app does not change the payload of an idempotent retry.

For Hermes, the model picker reads authenticated `GET /api/model/options`; explicit refresh uses `?refresh=1`. Only providers reported as authenticated with returned models are offered. Saving requires Hermes' `session_model_lock` capability and acknowledgement from `POST /api/sessions/{id}/model`. Luna keeps a protected, connection-scoped copy and includes both `model` and `provider` in each new Runs request. The selected pair is journaled at admission, so an already admitted request or retry retains its original model. Model changes wait until that session's active/queued tasks finish.

Until you choose a model in Luna, the control says **Hermes settings**; the picker's **Last reported** value is historical metadata, not a claim about the next run. Selecting a row marked **Server default** pins that current model for this session; it does not follow later global changes. Provider credentials remain on Hermes. The Runs API still applies Hermes' existing `/model` overrides and configured fallbacks; its session model acknowledgement is not a guarantee against those server-side routing rules. Luna does not change the global default or the OpenAI voice model.

**Auto** uses your saved OpenAI API key and the same `gpt-5.6-luna` reasoning model behind the live agent. Before a typed or voice-delegated task starts, a separate structured Responses request selects a model from the chosen agent’s available model catalog. This also works without an active voice connection. It sends the prompt plus up to eight recent user/assistant messages (bounded to 6,000 characters), adds OpenAI API usage and some latency, and does not send tool outputs, credentials, or the full transcript to the selector. The selector has no execution tools. It prefers smaller models when sufficient; this is a routing preference, not a guarantee of the cheapest price or best result.

Auto is saved per connection and session in Luna. It replaces that session's manual Luna choice without changing Hermes' global configuration. A task first enters **Choosing model**, then its validated model/provider and brief rationale are saved in the durable journal before submission. Retries keep that choice. An interrupted selection can resume safely; a failed selection never silently submits through the default model. Stopping during selection prevents Hermes execution. Choose a manual model again to leave Auto. Hermes' existing override/fallback rules still apply. The on-device demo uses explicitly labeled sample choices without calling OpenAI.

## Voice design

WebRTC carries audio directly between the phone and OpenAI. A second authenticated connection on the phone receives completed command-router function calls. Fourteen functions list/find agents, list sessions, search/read local context, select/create sessions, send prompts, read progress, explicitly refresh history, discover tools/skills, stop agent work, and pause the microphone. Transcript fragments only update captions; they never submit work.

One voice conversation spans agents and sessions. Every targeted action includes both an agent ID and a session ID; merely navigating the UI cannot redirect voice work. A deliberate voice destination change updates the live router without restarting audio. Names and titles are untrusted labels and may be duplicated. Function calls are deduplicated, and completion commentary includes the agent/session so overlapping tasks stay distinct. Full responses remain in their own chat. Luna does not record microphone audio to disk.

Local context is a recent snapshot, not a complete or live server history. Online agents hydrate cached sessions as they refresh; the local search/context tools themselves make no external agent requests. Speech processing still requires OpenAI and retrieved context is sent to that voice conversation. Fresh history requires the explicit refresh tool. Pausing the microphone disables outgoing audio; Luna does not unmute itself.

## Tests

```sh
xcodebuild -project ios/Luna.xcodeproj -scheme Luna \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGN_IDENTITY=- test
```

Leave ad-hoc signing enabled so simulator Keychain access works. The ordinary suite checks direct HTTP authentication, credential separation, secure addresses, SSE framing, exact code copying, Keychain updates/removal, durable request admission, per-session queues, recovery, cancellation, voice-call deduplication, model catalog normalization, acknowledged model changes, model persistence/retry payloads, legacy migration, local memory bounds/search, multi-agent routing, local names and ambiguous lookup, compatible streaming/interruption, and actual chat viewport positioning after new messages and streamed updates. Text-router checks cover complete tool output, stateless continuation, duplicate mutations, clarification history, exact destinations, cancellation, and bounded requests. Rendered views check the common composer on all three screens.

The opt-in **LunaLiveCheck** scheme uses keys already saved in the app. It checks direct Hermes reads using the first configured Hermes profile, harmless prompts in dedicated test sessions, on-device streaming, and real OpenAI WebRTC plus native command routing. The global voice check uses demo agents to verify name resolution, local search, exact session routing, and microphone pause. The global text check searches without starting work, then routes a follow-up to an explicitly named demo agent/session without audio. Live tests are billable. They create no outgoing microphone track; the playback test enables local audio output.

```sh
xcodebuild -project ios/Luna.xcodeproj -scheme LunaLiveCheck \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  CODE_SIGN_IDENTITY=- test
```

The previous Python helper remains in `service/` as an optional reference implementation. The native app does not call it, and `scripts/run-demo.sh` is only for that legacy service. Its tests remain available through `.venv/bin/python -m pytest service/tests -q`.

## Current limits

The Jetson HTTP API accepts its key and serves sessions, history, and capability catalogs. A direct native run returned the requested marker and saved it in the correct Hermes history. The earlier Anthropic authentication failure did not recur in this check. Luna did not change Hermes' provider or copy its OpenAI key to the Jetson.

Physical-device camera capture and live multimodal submissions, microphone quality, screen-lock audio, AirPods, interruptions, and cellular handoffs still need device validation. Live approval/cancellation against this Jetson and TestFlight distribution are not yet verified. Non-image uploads, push notifications, retrieval of unserved host filesystem paths, and cache/journal compaction for very long histories remain outside this version. Generic compatible endpoints do not provide Hermes’ durable remote-run recovery, tools catalog, or approval APIs.

See [verification](docs/verification.md), [implementation decisions](docs/implementation-decisions.md), [the multi-agent plan](docs/multi-agent-plan.md), and [the original plan](docs/ios-hermes-plan.md).
