# Chat stream stability plan

## Goal

The session timeline must never become empty, replace text the user has already seen, or move unexpectedly while a response is streaming. A locally submitted prompt and its response keep the same UI identities before, during, and after Hermes adds them to server history.

## Current failure points

1. `AppStore.recordRunUpdate` replaces `messages[sessionID]` with `run.history` on every active-run update. `run.history` is a pre-submit snapshot and may be empty or stale.
2. `AppStore.loadMessages` performs the same replacement whenever a run is active. This can blank a populated timeline during submission or reconnect.
3. `ChatView` renders server messages and local runs as separate lists. Reconciliation removes a `RunCard` and inserts equivalent `ChatMessage` views with different IDs, so SwiftUI loses its scroll anchor.
4. `ChatView` scrolls to the bottom for every message, output delta, and approval change. It does this even when the user has scrolled up.
5. Stream checkpoints and server history are persisted in separate JSON files. There is no atomic operation that records the prompt, assistant placeholder, run, and stream cursor together.

## Target model: one durable timeline

Render one collection of `TimelineItem` values for each session. Do not render `messages` followed by a second collection of `runs`.

Each item has:

- an immutable local ID
- session ID and role
- content and creation time
- an immutable position in the local ordered timeline
- optional Hermes message ID, local run ID, and upstream run ID
- delivery state: local, submitting, streaming, completed, failed, or uncertain
- last applied stream event ID and content revision

Submitting a request creates two items in one transaction:

1. A user item with ID derived from the local run ID.
2. An empty assistant item with another ID derived from the same run ID.

The stream updates the assistant item in place. When Hermes history later contains the pair, Luna attaches the remote IDs to these existing items. It does not remove and recreate them.

## Persistence

Replace the whole-cache JSON rewrite with a small SQLite timeline store. SQLite is available on iOS without another service and supports the atomic transactions this flow needs.

Tables:

- `sessions`: locally cached session metadata
- `timeline_items`: stable messages and assistant placeholders
- `runs`: submission status, model selection, upstream ID, and errors
- `sync_state`: newest/oldest history cursors and last stream event ID per run

Use WAL mode and transactions. Keep credentials in Keychain as they are now.

Persist stream changes on a short debounce, such as 150 milliseconds or 1 KB of new text, and immediately on terminal events, backgrounding, or disconnection. The initial prompt, placeholder, and run admission must be persisted before the HTTP submission begins.

On first launch after this change, import the current cache and run journal into SQLite. Keep the old files until the import transaction succeeds, then mark the migration complete.

## Stream diffing

Normalize every connector event into one of these operations:

- `append(delta, eventID)`
- `snapshot(text, eventID)`
- `terminal(status, text?, eventID)`

Apply them with these rules:

1. Ignore an event whose ID was already applied.
2. Append a delta only once.
3. Accept a snapshot when it extends the current visible text.
4. Never shrink or replace visible text with a conflicting snapshot. Store the conflicting remote value for reconciliation and diagnostics.
5. Persist the new content and event ID in the same transaction.

Extend `HermesEvent` to retain the SSE event ID or cursor. Recovery can then resume after the last committed event when Hermes supports it. If it cannot resume, poll the authoritative snapshot and apply the same prefix rules rather than replaying deltas.

## History diffing

History fetches are merge operations and never assignments.

Match incoming messages in this order:

1. Hermes message ID
2. Local run ID or upstream run ID supplied by Hermes
3. A one-to-one fallback using role, normalized content, adjacent prompt/response pairing, and a bounded timestamp window

For a match, attach remote metadata to the existing local item. Preserve its local ID, position, and displayed content. Insert only unmatched remote messages. A partial history page can never delete local rows; deletion requires an explicit remote deletion signal.

Older pages prepend unseen rows while preserving the current visible anchor. Latest-page refreshes add unseen rows after the closest matched predecessor and do not reorder items already displayed.

## Scroll policy

Replace the current `onChange` calls with a session-scoped `ChatScrollController`.

- Track whether the viewport is within roughly 80 points of the bottom using iOS 18 scroll geometry APIs.
- Auto-follow a stream only while the user is already near the bottom.
- Always scroll to the new prompt once when the local user sends it.
- When the user scrolls up, keep the current visible item and offset stable while deltas arrive.
- When older history is prepended, restore the first visible item and its offset.
- Reconciliation does not request a scroll because it updates the same timeline IDs.
- Coalesce stream-follow requests to at most once per display frame and do not animate token updates.
- Use a bottom anchor only for the initial presentation. Remove the competing default anchors and the output-string-based scroll triggers.

Composer height, voice controls, notices, and keyboard changes should preserve the bottom position only when the controller is in follow mode.

## Delivery sequence

### 1. Stop destructive updates

- Remove both assignments from `run.history` into the displayed message array.
- Add a single projected timeline with stable IDs, initially backed by the existing files.
- Add the gated scroll controller.

This removes the blanking and most jumps before the storage migration is complete.

### 2. Add transactional storage

- Add the SQLite repository and JSON migration.
- Persist prompt, placeholder, and run admission atomically.
- Add debounced stream checkpoints and lifecycle flushes.

### 3. Reconcile in place

- Add remote ID correlation to connector responses where available.
- Implement the history matcher and metadata attachment.
- Remove `RunCard` as a second rendered message source.

### 4. Harden recovery

- Persist stream event cursors.
- Resume or poll without replaying content.
- Keep failed and uncertain items in the timeline with retry or review state.

## Required tests

State tests must cover:

- populated history followed by submit, empty/stale refresh, deltas, terminal status, and delayed server history
- two identical prompts or replies without cross-reconciliation
- duplicate, replayed, skipped, and out-of-order stream events
- termination and relaunch between any two stream events
- pagination during an active stream
- a conflicting terminal snapshot that must not rewrite displayed text

Viewport tests must verify:

- a user at the bottom follows the stream
- a user who scrolled up stays at the same item and offset
- loading older messages preserves the visible row
- local-to-remote reconciliation causes no movement
- rich code blocks growing during a stream remain pinned only in follow mode
- keyboard, voice, composer, rotation, and reconnect changes do not create unexpected jumps

The acceptance invariant is simple: once a timeline item appears, its ID and position remain stable, and its visible content can only grow until the run finishes.
