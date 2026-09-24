import XCTest
@testable import Luna

final class LunaTests: XCTestCase {
    func testConversationHistoryRequiresTheMatchingPromptResponsePair() {
        var first = AgentRun(id: "first", sessionID: "A", text: "First prompt", status: "completed", output: "OK", created: 100)
        first.upstreamID = "remote-first"
        var second = AgentRun(id: "second", sessionID: "A", text: "Second prompt", status: "completed", output: "OK", created: 200)
        second.upstreamID = "remote-second"
        var history = [
            ChatMessage(id: "first-user", role: "user", content: "First prompt", createdAt: 100),
            ChatMessage(id: "first-assistant", role: "assistant", content: "OK", createdAt: 101),
            ChatMessage(id: "unrelated", role: "assistant", content: "OK", createdAt: 201)
        ]
        XCTAssertEqual(ConversationHistory.reconciledRunIDs(runs: [first, second], messages: history), ["first"])
        history += [
            ChatMessage(id: "second-user", role: "user", content: "Second prompt", createdAt: 200),
            ChatMessage(id: "second-assistant", role: "assistant", content: "OK", createdAt: 201)
        ]
        XCTAssertEqual(ConversationHistory.reconciledRunIDs(runs: [first, second], messages: history), ["first", "second"])
    }

    func testConversationHistoryRefreshPreservesOlderPagesAndShownContent() {
        let old = ChatMessage(id: "old", role: "user", content: "Earlier prompt", createdAt: 1)
        let shown = ChatMessage(id: "shown", role: "assistant", content: "Already shown", createdAt: 2)
        let rewritten = ChatMessage(id: "shown", role: "assistant", content: "Changed remotely", createdAt: 2)
        let latest = ChatMessage(id: "latest", role: "assistant", content: "New response", createdAt: 3)
        let merged = ConversationHistory.merge(existing: [old, shown], incoming: [rewritten, latest], older: false)
        XCTAssertEqual(merged, [old, shown, latest])
        let earlier = ChatMessage(id: "earlier", role: "user", content: "Oldest", createdAt: 0)
        XCTAssertEqual(ConversationHistory.merge(existing: merged, incoming: [earlier, old], older: true), [earlier, old, shown, latest])
    }

    @MainActor func testTerminalOutputCanExtendButNeverRewriteAStream() {
        XCTAssertEqual(RunCoordinator.stableOutput(current: "Streamed", incoming: "Streamed response"), "Streamed response")
        XCTAssertEqual(RunCoordinator.stableOutput(current: "Streamed response", incoming: "Streamed"), "Streamed response")
        XCTAssertEqual(RunCoordinator.stableOutput(current: "Streamed response", incoming: "Replacement"), "Streamed response")
        XCTAssertEqual(RunCoordinator.stableOutput(current: "Streamed response", incoming: ""), "Streamed response")
    }

    @MainActor func testCompletedAndFailedPromptsRemainVisibleUntilTheirHistoryPairArrives() {
        var completed = AgentRun(id: "completed", sessionID: "A", text: "Keep this prompt", status: "completed", output: "Answer", created: 1)
        var failed = AgentRun(id: "failed", sessionID: "A", text: "Keep failed prompt", status: "failed", output: "", created: 2)
        failed.upstreamID = "remote-failed"
        var records = [completed.id: completed, failed.id: failed]
        XCTAssertEqual(ChatView.visibleRuns(sessionID: "A", runs: records.values).map(\.id), ["completed", "failed"])
        completed.historyReconciled = true; records[completed.id] = completed
        XCTAssertEqual(ChatView.visibleRuns(sessionID: "A", runs: records.values).map(\.id), ["failed"])
    }

    @MainActor func testPeriodicHistoryRefreshKeepsPagesTheUserLoaded() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        backend.pageSize = 100
        backend.availableSessions = [AgentSession(id: "A", title: "Long chat", preview: "", source: "test", updatedAt: 1, messageCount: 150)]
        backend.history = (0..<150).map { ChatMessage(id: "m-\($0)", role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "Message \($0)", createdAt: Double($0 + 1)) }
        let store = AppStore(loadSavedState: false)
        let profile = AgentProfile(name: "Test", kind: .hermes, address: "https://test.example")
        try store.configure(profile: profile, key: "key", openAIKey: "", voice: VoiceController(), cache: root.appending(path: "cache.json"))
        store.makeBackend = { backend }
        await store.connect()
        await store.loadMessages("A")
        XCTAssertEqual(store.messages["A"]?.count, 100)
        await store.loadMessages("A", older: true)
        XCTAssertEqual(store.messages["A"]?.count, 150); XCTAssertEqual(store.historyHasMore["A"], false)
        backend.history.append(ChatMessage(id: "m-150", role: "assistant", content: "Message 150", createdAt: 151))
        await store.loadMessages("A")
        XCTAssertEqual(store.messages["A"]?.count, 151)
        XCTAssertEqual(store.messages["A"]?.first?.id, "m-0"); XCTAssertEqual(store.messages["A"]?.last?.id, "m-150")
        XCTAssertEqual(store.historyHasMore["A"], false)
        await store.disconnect()
    }

    // Regression: a streaming/active run must never shrink or blank a timeline the
    // user has already loaded (e.g. via "Load earlier messages"). run.history is a
    // bounded tail snapshot; applying it must merge, not replace.
    @MainActor func testActiveRunUpdateCannotShrinkOrBlankLoadedTimeline() {
        let store = AppStore(loadSavedState: false)
        let sid = "A"
        store.sessions = [AgentSession(id: sid, title: "Long chat", preview: "", source: "test", updatedAt: 1, messageCount: 200)]
        let loaded = (0..<150).map { ChatMessage(id: "m-\($0)", role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "Message \($0)", createdAt: Double($0)) }
        store.messages[sid] = loaded

        // An active run whose pre-submit snapshot only holds the latest 100 rows.
        var run = AgentRun(id: "r", sessionID: sid, text: "new prompt", status: "running", output: "", created: 200)
        run.history = Array(loaded.suffix(100))
        store.recordRunUpdate(run)
        XCTAssertEqual(store.messages[sid], loaded, "An active run's tail snapshot must not drop earlier loaded messages")

        // A subsequent update carrying an empty snapshot must not blank the timeline.
        run.output = "streaming…"; run.history = []
        store.recordRunUpdate(run)
        XCTAssertEqual(store.messages[sid], loaded, "An empty run snapshot must not blank the visible timeline")
    }

    // Regression: a refresh/reconnect while a run is active merges rather than
    // replaces, so paginated/cached rows survive.
    @MainActor func testRefreshWhileRunActiveMergesInsteadOfReplacing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = FakeBackend()
        backend.pageSize = 100
        backend.availableSessions = [AgentSession(id: "A", title: "Long chat", preview: "", source: "test", updatedAt: 1, messageCount: 150)]
        backend.history = (0..<150).map { ChatMessage(id: "m-\($0)", role: $0.isMultiple(of: 2) ? "user" : "assistant", content: "Message \($0)", createdAt: Double($0 + 1)) }
        let store = AppStore(loadSavedState: false)
        let profile = AgentProfile(name: "Test", kind: .hermes, address: "https://test.example")
        try store.configure(profile: profile, key: "key", openAIKey: "", voice: VoiceController(), cache: root.appending(path: "cache.json"))
        store.makeBackend = { backend }
        await store.connect()
        await store.loadMessages("A")
        await store.loadMessages("A", older: true)
        XCTAssertEqual(store.messages["A"]?.count, 150)
        // A run becomes active with a bounded tail snapshot; a refresh arrives.
        var run = AgentRun(id: "r", sessionID: "A", text: "new prompt", status: "running", output: "", created: 200)
        run.history = Array((store.messages["A"] ?? []).suffix(100))
        store.recordRunUpdate(run)
        await store.loadMessages("A")   // refresh path while run is active
        XCTAssertEqual(store.messages["A"]?.count, 150, "A refresh during an active run must not shrink the loaded timeline")
        XCTAssertEqual(store.messages["A"]?.first?.id, "m-0")
        await store.disconnect()
    }

    @MainActor func testNoticesExpireIndependentlyAndDismissImmediately() {
        let notices = TransientNotices()
        let now = Date().addingTimeInterval(60)
        notices.show("status", now: now)
        notices.show("error", duration: 12, now: now)
        notices.expire(at: now.addingTimeInterval(8))
        XCTAssertFalse(notices.contains("status"))
        XCTAssertTrue(notices.contains("error"))
        notices.dismiss("error")
        XCTAssertTrue(notices.deadlines.isEmpty)
        notices.show("error", duration: 12, now: now.addingTimeInterval(9))
        notices.expire(at: now.addingTimeInterval(12))
        XCTAssertTrue(notices.contains("error"), "An old deadline must not dismiss a newer error")
        notices.expire(at: now.addingTimeInterval(21))
        XCTAssertFalse(notices.contains("error"))
    }
    @MainActor func testNoticeTimerExpiresWithoutAViewOrNavigationEvent() async {
        let notices = TransientNotices()
        notices.show("short", duration: 0.02)
        notices.show("long", duration: 60)
        await spin { !notices.contains("short") }
        XCTAssertTrue(notices.contains("long"))
        notices.removeAll()
        XCTAssertTrue(notices.deadlines.isEmpty)
    }
    @MainActor func testDismissingTaskNoticesPreservesChatAndDoesNotReplayOldErrors() {
        let store = AppStore(loadSavedState: false)
        let message = ChatMessage(id: "history", role: "user", content: "Keep this prompt", createdAt: 1)
        store.messages = ["A": [message]]
        store.activity = ["A": [Activity(id: "tool", title: "Tool", detail: "Working", finished: false, failed: false, runID: "task")]]
        var run = AgentRun(id: "task", sessionID: "A", text: message.content, status: "running", output: "Partial answer", created: 1)
        store.recordRunUpdate(run)
        XCTAssertFalse(store.notices.contains(TransientNotices.run(run.id)))
        run.status = "waiting_for_approval"
        store.recordRunUpdate(run)
        XCTAssertFalse(store.notices.contains(TransientNotices.run(run.id)))
        run.status = "failed"; run.error = "Temporary failure"
        store.recordRunUpdate(run)
        XCTAssertTrue(store.notices.contains(TransientNotices.run(run.id)))
        XCTAssertTrue(store.activity["A"]?.allSatisfy(\.finished) == true)
        XCTAssertTrue(store.notices.contains(TransientNotices.activity("A")))
        store.notices.dismiss(TransientNotices.run(run.id))
        store.notices.dismiss(TransientNotices.activity("A"))
        store.recordRunUpdate(run)
        XCTAssertFalse(store.notices.contains(TransientNotices.run(run.id)))
        XCTAssertFalse(store.notices.contains(TransientNotices.activity("A")))
        XCTAssertEqual(store.runs[run.id], run)
        XCTAssertEqual(store.messages["A"], [message])
        XCTAssertNil(store.runs[run.id]?.historyReconciled)
        XCTAssertNil(store.runs[run.id]?.stopRequested)
        let next = AgentRun(id: "new-task", sessionID: "B", text: "Another request", status: "failed", output: "", error: "New failure", created: 2)
        store.recordRunUpdate(next)
        XCTAssertTrue(store.notices.contains(TransientNotices.run(next.id)))
        store.notices.expire(at: Date().addingTimeInterval(13))
        XCTAssertFalse(store.notices.contains(TransientNotices.run(next.id)))
        XCTAssertEqual(store.runs[next.id], next)
        store.reconnecting = true
        store.notices.dismiss("reconnecting")
        store.reconnecting = true
        XCTAssertFalse(store.notices.contains("reconnecting"), "Repeated refresh failures must not recreate a dismissed notice")
        store.reconnecting = false; store.reconnecting = true
        XCTAssertTrue(store.notices.contains("reconnecting"), "A new outage should get a new notice")
        store.notices.removeAll(); store.saveNow()
    }
    private var autoCatalog: HermesModelCatalog {
        HermesModelCatalog(providers: [
            HermesModelProvider(id: "anthropic", name: "Anthropic", authenticated: true, models: ["claude-haiku-4-5-20251001", "claude-opus-5"]),
            HermesModelProvider(id: "disabled", name: "Disabled", authenticated: false, models: ["cheap"]),
            HermesModelProvider(id: "media", name: "Media", authenticated: true, models: ["image-generator", "video-generator", "text-embedding", "chat-no-tools"], capabilities: ["chat-no-tools": ["tool_calling": .bool(false)]])
        ], current: HermesModelSelection(provider: "anthropic", model: "claude-opus-5"))
    }
    private func autoResponse(index: Int = 0, complexity: String = "simple", status: String = "completed") -> JSONObject {
        ["status": .string(status), "output": .array([.object(["type": .string("message"), "content": .array([
            .object(["type": .string("output_text"), "text": .string("{\"candidate_index\":\(index),\"complexity\":\"\(complexity)\",\"reason\":\"A lightweight model handles this short question.\"}")])])])])]
    }
    @MainActor func testAutoRouterUsesOpenAIAndOnlyCatalogCandidates() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionStub.self]
        let response = String(decoding: try JSONEncoder().encode(autoResponse()), as: UTF8.self)
        let prompt = "What is 2 + 2?"
        ConnectionStub.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openai-test")
            let body = Self.body(request)
            XCTAssertEqual(body["model"], .string(OpenAILiveSession.routerModel))
            XCTAssertEqual(body["store"], .bool(false))
            XCTAssertNil(body["tools"], "The selector cannot execute any task")
            XCTAssertEqual(body["text"]?.object?["format"]?.object?["strict"], .bool(true))
            let input = try! JSONDecoder().decode(JSONObject.self, from: Data(body["input"]!.string!.utf8))
            XCTAssertEqual(input["request"], .string(prompt))
            XCTAssertEqual(input["candidates"]?.array?.count, 2)
            let history = input["recent_conversation"]!.array!.compactMap(\.object)
            XCTAssertLessThanOrEqual(history.reduce(0) { $0 + ($1["text"]?.string?.count ?? 0) }, 6000)
            XCTAssertFalse(history.contains { $0["role"]?.string == "tool" })
            return (200, response)
        }
        defer { ConnectionStub.handler = nil }
        let history = (0..<20).map { ChatMessage(id: "\($0)", role: $0 == 19 ? "tool" : "user", content: String(repeating: "x", count: 2000), createdAt: 0) }
        let choice = try await AutoModelRouter(key: "openai-test", configuration: configuration).choose(prompt: prompt, history: history, catalog: autoCatalog)
        XCTAssertEqual(choice.selection, HermesModelSelection(provider: "anthropic", model: "claude-haiku-4-5-20251001"))
        XCTAssertEqual(choice.complexity, .simple)
    }
    @MainActor func testAutoRejectsUnknownChoicesRefusalsAndIncompleteResponses() throws {
        let candidates = AutoModelRouter.candidates(in: autoCatalog)
        XCTAssertEqual(candidates.count, 2)
        for response in [autoResponse(index: 20), autoResponse(index: -1), autoResponse(complexity: "made-up"), autoResponse(status: "incomplete"),
                         ["status": .string("completed"), "output": .array([.object(["type": .string("message"), "content": .array([.object(["type": .string("refusal")])])])])]] {
            XCTAssertThrowsError(try AutoModelRouter.parse(response, candidates: candidates))
        }
        XCTAssertThrowsError(try AutoModelRouter.parse(autoResponse(), candidates: []))
    }
    func testAutoPreferencesMigrateManualChoicesAndRoundTrip() throws {
        let old = Data(#"{"A":{"provider":"anthropic","model":"chosen"}}"#.utf8)
        var preferences = try JSONDecoder().decode([String: SessionModelPreference].self, from: old)
        XCTAssertEqual(preferences["A"]?.selection?.model, "chosen")
        preferences["A"] = .automatic
        preferences["B"] = .manual(HermesModelSelection(provider: "second", model: "manual"))
        let restored = try JSONDecoder().decode([String: SessionModelPreference].self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored, preferences)
        XCTAssertNil(restored["A"]?.selection)
        XCTAssertEqual(restored["B"]?.selection?.model, "manual")
        XCTAssertThrowsError(try JSONDecoder().decode([String: SessionModelPreference].self, from: Data(#"{"A":{"mode":"unknown"}}"#.utf8)))
    }
    @MainActor func testAutoReevaluatesEachQueuedRequestWithFreshSessionContext() async throws {
        let backend = FakeBackend()
        var calls: [String] = [], durable: [String: AgentRun] = [:]
        let light = HermesModelSelection(provider: "test", model: "light"), heavy = HermesModelSelection(provider: "test", model: "heavy")
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities(), selectModel: { run in
            calls.append(run.id)
            XCTAssertEqual(durable[run.id]?.status, "choosing_model", "Admission precedes selection")
            if run.id == "second" { XCTAssertEqual(run.history?.last?.content, "First answer") }
            return AutoModelDecision(selection: run.id == "first" ? light : heavy, complexity: run.id == "first" ? .simple : .complex, reason: "Test choice")
        }) { durable = $0 }
        queue.resume(); defer { queue.pause() }
        _ = try await queue.admit(id: "first", sessionID: "A", text: "Simple question", automaticModel: true)
        _ = try await queue.admit(id: "first", sessionID: "A", text: "Simple question", automaticModel: true)
        _ = try await queue.admit(id: "second", sessionID: "A", text: "Plan a migration", automaticModel: true)
        _ = try await queue.admit(id: "manual", sessionID: "B", text: "Manual", model: heavy)
        await spin { backend.submitted.count == 2 }
        XCTAssertEqual(calls, ["first"])
        XCTAssertEqual(durable["first"]?.modelDecision?.selection, light)
        backend.history = [ChatMessage(id: "response", role: "assistant", content: "First answer", createdAt: 1)]
        backend.complete("remote-first", output: "First answer")
        await spin { backend.submitted.count == 3 }
        XCTAssertEqual(calls, ["first", "second"])
        XCTAssertEqual(backend.submittedRuns.first { $0.id == "first" }?.modelSelection, light)
        XCTAssertEqual(backend.submittedRuns.first { $0.id == "second" }?.modelSelection, heavy)
        XCTAssertEqual(backend.submittedRuns.first { $0.id == "manual" }?.automaticModel, nil)
    }
    @MainActor func testAutoFailureNeverSubmitsWithAnImplicitDefault() async throws {
        let backend = FakeBackend()
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities(), selectModel: { _ in
            throw ServiceError(message: "Router unavailable")
        }) { _ in }
        queue.resume(); defer { queue.pause() }
        _ = try await queue.admit(id: "auto-failure", sessionID: "A", text: "Task", automaticModel: true)
        await spin { queue.records["auto-failure"]?.status == "failed" }
        XCTAssertTrue(backend.submitted.isEmpty)
        XCTAssertEqual(queue.records["auto-failure"]?.error, "Router unavailable")
    }
    @MainActor func testCancellingAutoSelectionDoesNotSubmitOrOverwriteCancellation() async throws {
        let backend = FakeBackend()
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities(), selectModel: { _ in
            try await Task.sleep(for: .seconds(30))
            return AutoModelRouter.demo(prompt: "hello")
        }) { _ in }
        queue.resume(); defer { queue.pause() }
        _ = try await queue.admit(id: "cancel-auto", sessionID: "A", text: "Task", automaticModel: true)
        await spin { queue.records["cancel-auto"]?.status == "choosing_model" }
        try await queue.stop("cancel-auto")
        await queue.suspend()
        XCTAssertEqual(queue.records["cancel-auto"]?.status, "cancelled")
        XCTAssertTrue(backend.submitted.isEmpty)
    }
    @MainActor func testAutoChoiceIsNotRecomputedAfterRecovery() async throws {
        let backend = FakeBackend()
        var run = AgentRun(id: "recover-auto", sessionID: "A", text: "Task", status: "submitting", output: "", created: Date().timeIntervalSince1970)
        run.automaticModel = true
        run.modelDecision = AutoModelRouter.demo(prompt: "plan")
        run.modelSelection = run.modelDecision?.selection
        let saved = try JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(run))
        var selections = 0
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities(), records: [run.id: saved], selectModel: { _ in
            selections += 1; return AutoModelRouter.demo(prompt: "hello")
        }) { _ in }
        queue.resume(); defer { queue.pause() }
        await spin { backend.submitted.count == 1 }
        XCTAssertEqual(selections, 0)
        XCTAssertEqual(backend.submittedRuns[0].modelSelection, saved.modelSelection)
        XCTAssertEqual(queue.records[run.id]?.modelDecision, saved.modelDecision)
    }
    @MainActor func testAutoChoiceMustBeSavedBeforeHermesSubmission() async throws {
        let backend = FakeBackend()
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities(), selectModel: { _ in AutoModelRouter.demo(prompt: "hello") }) { records in
            if records.values.contains(where: { $0.modelDecision != nil }) { throw ServiceError(message: "Disk full") }
        }
        queue.resume(); defer { queue.pause() }
        _ = try await queue.admit(id: "disk-auto", sessionID: "A", text: "Task", automaticModel: true)
        await spin { queue.records["disk-auto"]?.status == "failed" }
        XCTAssertTrue(backend.submitted.isEmpty)
    }
    @MainActor func testInterruptedSelectionCanResumeWithoutHermesIdempotency() async throws {
        let backend = FakeBackend()
        var run = AgentRun(id: "interrupted-selection", sessionID: "A", text: "Plan", status: "choosing_model", output: "", created: 1)
        run.automaticModel = true
        var selections = 0
        let queue = RunCoordinator(backend: backend, features: ["run_submission": .bool(true), "run_events_sse": .bool(true)], records: [run.id: run], selectModel: { _ in
            selections += 1; return AutoModelRouter.demo(prompt: "plan")
        }) { _ in }
        queue.resume(); defer { queue.pause() }
        await spin { backend.submitted.count == 1 }
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(backend.submittedRuns[0].modelSelection?.model, "demo-balanced")
    }
    func testModelCatalogKeepsProviderIdentityAndFiltersUnconfiguredProviders() throws {
        let json = #"{"provider":"anthropic","model":"shared-model","providers":[{"slug":"anthropic","name":"Anthropic","authenticated":true,"models":["shared-model","shared-model", "", {"id":"second"},42]},{"slug":"copilot","name":"GitHub Copilot","authenticated":true,"models":["shared-model"]},{"slug":"unconfigured","authenticated":false,"models":["hidden"]},{"slug":"unknown-auth","models":["hidden"]},{"slug":"anthropic","authenticated":true,"models":["duplicate"]}]}"#
        let catalog = try HermesModelCatalog.parse(JSONDecoder().decode(JSONObject.self, from: Data(json.utf8)))
        XCTAssertEqual(catalog.availableProviders.map(\.id), ["anthropic", "copilot"])
        XCTAssertEqual(catalog.providers[0].models, ["shared-model", "second"])
        XCTAssertEqual(catalog.current, HermesModelSelection(provider: "anthropic", model: "shared-model"))
        XCTAssertTrue(catalog.contains(HermesModelSelection(provider: "copilot", model: "shared-model")))
        XCTAssertFalse(catalog.contains(HermesModelSelection(provider: "unconfigured", model: "hidden")))
        XCTAssertNotEqual(catalog.current?.id, HermesModelSelection(provider: "copilot", model: "shared-model").id)
        XCTAssertThrowsError(try HermesModelCatalog.parse(["data": .array([])]))
    }
    @MainActor func testModelCatalogRefreshAndSessionAcknowledgement() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionStub.self]
        let client = HermesClient(url: URL(string: "https://hermes.example.com/p/work")!, key: "hermes-only", configuration: config)
        let choice = HermesModelSelection(provider: "anthropic", model: "chosen")
        var paths: [String] = []
        var acknowledge = true
        ConnectionStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hermes-only")
            paths.append(request.url!.path + (request.url?.query.map { "?" + $0 } ?? ""))
            if request.httpMethod == "GET" { return (200, #"{"providers":[],"model":"chosen","provider":"anthropic"}"#) }
            XCTAssertEqual(request.url?.path, "/p/work/api/sessions/session-A/model")
            XCTAssertEqual(Self.body(request), ["model": .string("chosen"), "provider": .string("anthropic")])
            return (200, acknowledge ? #"{"session_id":"session-A","runtime":{"provider":"anthropic","model":"chosen","model_lock":"accepted"}}"# : #"{"session_id":"session-B","runtime":{"provider":"anthropic","model":"chosen","model_lock":"accepted"}}"#)
        }
        defer { ConnectionStub.handler = nil }
        _ = try await client.models()
        _ = try await client.models(refresh: true)
        XCTAssertEqual(paths, ["/p/work/api/model/options", "/p/work/api/model/options?refresh=1"])
        try await client.setModel(choice, sessionID: "session-A")
        acknowledge = false
        do { try await client.setModel(choice, sessionID: "session-A"); XCTFail("Must confirm the exact session and model") } catch { }
    }
    @MainActor func testModelSelectionSurvivesJournalRecoveryAndDuplicateAdmission() async throws {
        let backend = FakeBackend()
        var journal: [String: AgentRun] = [:]
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities()) { journal = $0 }
        queue.resume(); defer { queue.pause() }
        let a = HermesModelSelection(provider: "provider-a", model: "shared")
        let b = HermesModelSelection(provider: "provider-b", model: "shared")
        _ = try await queue.admit(id: "model-a", sessionID: "A", text: "First", model: a)
        _ = try await queue.admit(id: "model-b", sessionID: "B", text: "Second", model: b)
        _ = try await queue.admit(id: "model-a", sessionID: "A", text: "First", model: b)
        let recovered = try JSONDecoder().decode([String: AgentRun].self, from: JSONEncoder().encode(journal))
        XCTAssertEqual(recovered["model-a"]?.modelSelection, a)
        XCTAssertEqual(recovered["model-b"]?.modelSelection, b)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionStub.self]
        var bodies: [JSONObject] = []
        ConnectionStub.handler = { request in bodies.append(Self.body(request)); return (202, #"{"run_id":"remote-a"}"#) }
        defer { ConnectionStub.handler = nil }
        let client = HermesClient(url: URL(string: "https://hermes.example.com")!, key: "test", configuration: config)
        _ = try await client.submit(try XCTUnwrap(recovered["model-a"]))
        _ = try await client.submit(try XCTUnwrap(recovered["model-a"]))
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(bodies[0]["provider"], .string(a.provider))
        XCTAssertEqual(bodies[0]["model"], .string(a.model))
        XCTAssertEqual(bodies[0]["session_id"], .string("A"))
        let old = try JSONDecoder().decode(AgentRun.self, from: Data(#"{"id":"old","session_id":"A","text":"Hello","status":"queued","output":"","created":1}"#.utf8))
        _ = try await client.submit(old)
        XCTAssertNil(bodies.last?["model"])
        XCTAssertNil(bodies.last?["provider"])
    }
    func testSessionModelPreferencesSurviveRelaunchAndAreConnectionScoped() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SessionModelFile.location(for: folder.appending(path: "connection.json"))
        XCTAssertEqual(try SessionModelFile.read(file), [:])
        let models = ["A": HermesModelSelection(provider: "one", model: "first"), "B": HermesModelSelection(provider: "two", model: "second")]
        try ProtectedFile.write(models, to: file)
        XCTAssertEqual(try SessionModelFile.read(file), models.mapValues(SessionModelPreference.manual))
        XCTAssertNotEqual(SessionModelFile.location(for: CacheFile.location(server: "https://a.example", token: "a")),
                          SessionModelFile.location(for: CacheFile.location(server: "https://a.example", token: "b")))
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try SessionModelFile.read(file), "Do not silently forget a selected model")
    }
    private static func body(_ request: URLRequest) -> JSONObject {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONDecoder().decode(JSONObject.self, from: data)) ?? [:]
    }
    @MainActor func testDirectHermesProfilePathAndAuthorization() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionStub.self]
        ConnectionStub.handler = { request in
            XCTAssertEqual(request.url?.host, "agent.example.com")
            XCTAssertEqual(request.url?.path, "/profiles/work/v1/capabilities")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hermes-test")
            return (200, #"{"features":{"run_submission":true,"run_events_sse":true}}"#)
        }
        defer { ConnectionStub.handler = nil }
        let client = HermesClient(url: URL(string: "https://agent.example.com/profiles/work/")!, key: "hermes-test", configuration: configuration)
        let features = try await client.capabilities()
        XCTAssertEqual(features["run_submission"], .bool(true))
        let openAI = APIClient(url: URL(string: "https://api.openai.com")!, token: "openai-test", label: "OpenAI")
        XCTAssertEqual(try openAI.request("/v1/live/sessions").value(forHTTPHeaderField: "Authorization"), "Bearer openai-test")
    }
    func testAuthenticationErrorsDoNotEchoSecrets() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionStub.self]
        ConnectionStub.handler = { _ in (401, #"{"error":"rejected secret-value"}"#) }
        defer { ConnectionStub.handler = nil }
        let api = APIClient(url: URL(string: "https://agent.example.com")!, token: "secret-value", configuration: configuration)
        do {
            let _: JSONObject = try await api.call("/v1/capabilities")
            XCTFail("Must reject invalid credentials")
        } catch let error as ServiceError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertTrue(error.message.contains("Hermes"))
            XCTAssertFalse(error.message.contains("secret-value"))
        }
    }
    func testSSEFrameBoundariesNamesAndUnicode() throws {
        for newline in ["\n", "\r\n", "\r"] {
            let lines = [": heartbeat", "", "event: message.delta", "id: 12", "data: {\"delta\":", "data: \"🌙\"}", "", "event: run.completed", "data: {}", "", ""]
            var decoder = SSEFrameDecoder(), frames: [SSEFrame] = []
            for byte in lines.joined(separator: newline).utf8 { if let frame = try decoder.accept(byte) { frames.append(frame) } }
            XCTAssertEqual(frames.count, 2)
            XCTAssertEqual(frames[0].event, "message.delta")
            XCTAssertEqual(frames[0].id, "12")
            XCTAssertEqual(try JSONDecoder().decode(JSONObject.self, from: frames[0].data)["delta"], .string("🌙"))
            XCTAssertEqual(frames[1].event, "run.completed")
        }
    }
    func testRemotePlaintextAndEmbeddedCredentialsAreRejected() {
        for url in ["http://example.com", "http://jetson.local", "https://user:secret@example.com", "https://example.com?key=secret", "https://example.com/#secret"] {
            XCTAssertThrowsError(try APIClient.validateURL(url))
        }
        XCTAssertNoThrow(try APIClient.validateURL("http://localhost:8642"))
        XCTAssertNoThrow(try APIClient.validateURL("https://agents.example.com/profile"))
    }
    func testKeychainIsolationUpdateAndRemoval() throws {
        let hermes = "test-hermes-" + UUID().uuidString, openai = "test-openai-" + UUID().uuidString
        defer { try? Credentials.save("", account: hermes); try? Credentials.save("", account: openai) }
        try Credentials.save("hermes-one", account: hermes)
        try Credentials.save("openai-one", account: openai)
        try Credentials.save("hermes-two", account: hermes)
        XCTAssertEqual(Credentials.read(hermes), "hermes-two")
        XCTAssertEqual(Credentials.read(openai), "openai-one")
        try Credentials.save("", account: hermes)
        XCTAssertEqual(Credentials.read(hermes), "")
        XCTAssertEqual(Credentials.read(openai), "openai-one")
        XCTAssertNotEqual(Credentials.hermesAccount("https://a.example"), Credentials.hermesAccount("https://b.example"))
    }
    func testCodeSourceAndIncompleteFence() {
        let code = "let path = \"a  b\"\n\nprint(path)\n"
        let blocks = MarkdownBlocks.parse("Before\n```swift\n" + code + "```\nAfter")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1].content, code)
        XCTAssertEqual(blocks[1].kind, .code("swift"))
        XCTAssertEqual(MarkdownBlocks.parse("```json\n{\"a\":").first?.content, "{\"a\":")
        XCTAssertEqual(MarkdownBlocks.parse("````text\na\n```\nb\n````")[0].content, "a\n```\nb\n")
    }
    func testCodeFencesPreserveWindowsLineEndingsAndStreamingPrefixes() {
        let source = "\tlet moon = \"🌙\"\r\n\r\n    print(moon)\r\n"
        let blocks = MarkdownBlocks.parse("Before\r\n~~~Swift file=Moon.swift\r\n" + source + "~~~~\r\nAfter")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1].content, source)
        XCTAssertEqual(blocks[2].content, "After")
        for partial in ["```swift", "```swift\n", "```swift\nlet message = \"🌙"] {
            let code = MarkdownBlocks.parse(partial)
            XCTAssertEqual(code.first?.kind, .code("swift"))
            XCTAssertEqual(code.count, 1)
        }
        XCTAssertEqual(MarkdownBlocks.parse("```swift\nlet a = 1\n```\n```json\n{}\n```").count, 2)
    }
    func testCodeLanguageLabelsAndConservativeInference() {
        for (info, expected) in [("Swift title=View.swift", "swift"), ("{.python}", "python"), ("language-JS", "javascript"), ("App.tsx", "tsx"), ("c++", "cpp"), ("shell", "bash"), ("patch", "diff")] {
            XCTAssertEqual(CodeLanguage(info: info, source: "").identifier, expected)
        }
        XCTAssertEqual(CodeLanguage(info: "", source: "{\"enabled\":true}").identifier, "json")
        XCTAssertEqual(CodeLanguage(info: "text", source: "{\"enabled\":true}").identifier, "plain")
        XCTAssertEqual(CodeLanguage(info: "", source: "diff --git a/file b/file\n-old\n+new").identifier, "diff")
        XCTAssertEqual(CodeLanguage(info: "", source: "Ordinary prose").identifier, "")
        XCTAssertEqual(CodeLanguage(info: "unrecognized", source: "source").identifier, "unrecognized")
    }
    func testCodeDisplayCannotCloseItsOwnFence() throws {
        let source = "# Example\n```swift\nlet greeting = \"Hello\"\n```\n\n````\n"
        let markdown = CodePresentation.markdown(source: source, language: "markdown")
        let parsed = try AttributedString(markdown: markdown)
        XCTAssertTrue(String(parsed.characters).contains("```swift"))
        XCTAssertTrue(String(parsed.characters).contains("````"))
        let code = MarkdownBlocks.parse(markdown)
        XCTAssertEqual(code.count, 1)
        XCTAssertEqual(code[0].content, source)
        XCTAssertEqual(CodePresentation.lineCount("a\r\n\r\nb\r\n"), 3)
        XCTAssertEqual(CodePresentation.lineCount(""), 0)
    }
    @MainActor func testHermesFormattingGuidancePreservesInputAndRetryPayload() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionStub.self]
        var bodies: [JSONObject] = []
        ConnectionStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/runs")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "format-check")
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            guard let body = try? JSONDecoder().decode(JSONObject.self, from: data) else {
                XCTFail("Missing JSON request body"); return (400, "{}")
            }
            bodies.append(body)
            return (202, #"{"run_id":"remote-format-check"}"#)
        }
        defer { ConnectionStub.handler = nil }
        let client = HermesClient(url: URL(string: "https://hermes.example.com")!, key: "test", configuration: config)
        var run = AgentRun(id: "format-check", sessionID: "original-session", text: "Show code exactly as written", status: "submitting", output: "", created: 1)
        _ = try await client.submit(run)
        XCTAssertNil(bodies.last?["instructions"], "Old admissions retain their original payload")
        run.responseInstructions = HermesResponseFormat.instructions
        let saved = try JSONEncoder().encode(run)
        let restored = try JSONDecoder().decode(AgentRun.self, from: saved)
        _ = try await client.submit(restored)
        _ = try await client.submit(restored)
        XCTAssertEqual(bodies[1], bodies[2])
        XCTAssertEqual(bodies[1]["input"], .string(run.text))
        XCTAssertEqual(bodies[1]["session_id"], .string(run.sessionID))
        XCTAssertTrue(bodies[1]["instructions"]?.string?.contains("fenced Markdown") == true)
    }
    @MainActor func testAdmissionPersistsBeforeNetworkAndQueuesPerSession() async throws {
        let backend = FakeBackend()
        var durable: [String: AgentRun] = [:]
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities()) { durable = $0 }
        queue.resume(); defer { queue.pause() }
        _ = try await queue.admit(id: "one", sessionID: "A", text: "First")
        XCTAssertEqual(durable["one"]?.status, "queued")
        XCTAssertEqual(durable["one"]?.responseInstructions, HermesResponseFormat.instructions)
        _ = try await queue.admit(id: "one", sessionID: "A", text: "First")
        _ = try await queue.admit(id: "two", sessionID: "A", text: "Second")
        _ = try await queue.admit(id: "other", sessionID: "B", text: "Other session")
        await spin { backend.submitted.count == 2 }
        XCTAssertEqual(Set(backend.submitted), ["one", "other"])
        do { _ = try await queue.admit(id: "one", sessionID: "B", text: "First"); XCTFail("ID must remain bound") } catch { }
        backend.complete("remote-one", output: "Result A")
        await spin { backend.submitted.count == 3 }
        XCTAssertEqual(queue.records["one"]?.output, "Result A")
        XCTAssertEqual(queue.records["one"]?.sessionID, "A")
        XCTAssertEqual(queue.records["other"]?.output, "")
    }
    @MainActor func testPersistenceFailurePreventsSubmission() async throws {
        let backend = FakeBackend()
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities()) { _ in throw ServiceError(message: "Disk unavailable") }
        queue.resume(); defer { queue.pause() }
        do { _ = try await queue.admit(id: "one", sessionID: "A", text: "Task"); XCTFail("Admission must fail") } catch { }
        XCTAssertTrue(backend.submitted.isEmpty)
        XCTAssertTrue(queue.records.isEmpty)
    }
    @MainActor func testRecoveryPollsKnownRunWithoutResubmittingOrRewritingShownText() async throws {
        let backend = FakeBackend()
        backend.snapshots["remote-existing"] = ["status": .string("completed"), "output": .string("Whole answer")]
        var run = AgentRun(id: "existing", sessionID: "A", text: "Task", status: "running", output: "Partial", created: 1)
        run.upstreamID = "remote-existing"
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities(), records: [run.id: run]) { _ in }
        queue.resume(); defer { queue.pause() }
        await spin { queue.records[run.id]?.status == "completed" }
        XCTAssertTrue(backend.submitted.isEmpty)
        XCTAssertTrue(backend.streamIDs.isEmpty)
        XCTAssertEqual(queue.records[run.id]?.output, "Partial")
    }
    @MainActor func testUnknownAdmissionBlocksQueuedFollowerUntilAcknowledged() async throws {
        let backend = FakeBackend()
        let first = AgentRun(id: "first", sessionID: "A", text: "First", status: "unknown", output: "", created: 1)
        let next = AgentRun(id: "next", sessionID: "A", text: "Next", status: "queued", output: "", created: 2)
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities(), records: [first.id: first, next.id: next]) { _ in }
        let store = AppStore(loadSavedState: false)
        store.recordRunUpdate(first)
        store.notices.dismiss(TransientNotices.run(first.id))
        XCTAssertNil(store.runs[first.id]?.historyReconciled)
        queue.resume(); defer { queue.pause() }
        await Task.yield()
        XCTAssertTrue(backend.submitted.isEmpty)
        XCTAssertNil(queue.records[first.id]?.historyReconciled, "Closing the notice does not acknowledge an uncertain outcome")
        queue.markReconciled([first.id])
        await spin { backend.submitted == ["next"] }
    }
    @MainActor func testQueuedStopNeverReachesHermes() async throws {
        let backend = FakeBackend()
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities()) { _ in }
        queue.resume(); defer { queue.pause() }
        _ = try await queue.admit(id: "cancel", sessionID: "A", text: "Task")
        try await queue.stop("cancel")
        await Task.yield()
        XCTAssertTrue(backend.submitted.isEmpty)
        XCTAssertEqual(queue.records["cancel"]?.status, "cancelled")
    }
    @MainActor func testLiveToolCorrelationAndDuplicateCompletionExecuteOnce() async throws {
        var calls: [String] = [], sent: [JSONObject] = []
        let live = OpenAILiveSession(key: "unused", sessionID: "A", title: "A") { name, arguments, id in
            calls.append(name)
            XCTAssertEqual(arguments["prompt"], .string("Keep it in A"))
            XCTAssertTrue(id.hasPrefix("voice-"))
            return ["status": .string("queued")]
        }
        live.sendOverride = { sent.append($0) }
        func event(_ value: JSONObject) -> JSONObject { ["type": .string("response.event"), "delegation_id": .string("delegate"), "event": .object(value)] }
        try await live.handle(event(["type": .string("response.created"), "response": .object(["id": .string("response-1")])]))
        try await live.handle(event(["type": .string("response.output_item.done"), "item": .object([
            "type": .string("function_call"), "call_id": .string("call-1"), "name": .string("send_prompt"), "arguments": .string(#"{"prompt":"Keep it in A"}"#)])]))
        XCTAssertTrue(calls.isEmpty, "Do not run partial tool calls")
        let completion = event(["type": .string("response.completed"), "response": .object(["id": .string("response-1")])])
        try await live.handle(completion); try await live.handle(completion)
        XCTAssertEqual(calls, ["send_prompt"])
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0]["item"]?.object?["call_id"], .string("call-1"))
    }
    @MainActor private func spin(until condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Asynchronous operation did not settle")
    }
}

@MainActor final class FakeBackend: AgentBackend {
    let isDemo = true
    var submitted: [String] = [], streamIDs: [String] = []
    var submittedRuns: [AgentRun] = []
    var history: [ChatMessage] = []
    var pageSize = Int.max
    var availableSessions: [AgentSession] = []
    var snapshots: [String: JSONObject] = [:]
    var streams: [String: AsyncThrowingStream<HermesEvent, Error>.Continuation] = [:]
    func capabilities() async throws -> JSONObject { ["run_submission": .bool(true), "run_events_sse": .bool(true), "runs_idempotency": .object(["durable": .bool(true), "retention_seconds": .number(86400)])] }
    func sessions(offset: Int) async throws -> SessionPage { SessionPage(sessions: Array(availableSessions.dropFirst(offset)), has_more: false) }
    func session(_ id: String) async throws -> AgentSession { AgentSession(id: id, title: id, preview: "", source: "test", updatedAt: 0, messageCount: 0) }
    func create(_ title: String) async throws -> AgentSession { try await session(title) }
    func rename(_ id: String, title: String) async throws -> AgentSession { try await session(id) }
    func messages(_ id: String, offset: Int) async throws -> HistoryPage {
        guard pageSize != Int.max else { return HistoryPage(messages: history, hasMore: false, resolvedSessionID: id) }
        let end = max(0, history.count - offset), start = max(0, end - pageSize)
        return HistoryPage(messages: Array(history[start..<end]), hasMore: start > 0, resolvedSessionID: id)
    }
    func submit(_ run: AgentRun) async throws -> String { submitted.append(run.id); submittedRuns.append(run); return "remote-" + run.id }
    func status(_ id: String) async throws -> JSONObject { snapshots[id] ?? ["status": .string("running")] }
    func events(_ id: String) -> AsyncThrowingStream<HermesEvent, Error> {
        streamIDs.append(id)
        return AsyncThrowingStream { streams[id] = $0 }
    }
    func complete(_ id: String, output: String) {
        let prefix = String(output.prefix(max(1, output.count / 2)))
        streams[id]?.yield(HermesEvent(type: "message.delta", data: ["delta": .string(prefix)]))
        streams[id]?.yield(HermesEvent(type: "run.completed", data: ["output": .string(output)])); streams[id]?.finish()
    }
    func stop(_ id: String) async throws { }
    func approve(_ id: String, requestID: String, choice: String) async throws { }
    func tools() async throws -> JSONObject { [:] }
    func skills() async throws -> JSONObject { [:] }
    func models(refresh: Bool) async throws -> HermesModelCatalog { HermesModelCatalog(providers: [], current: nil) }
    func setModel(_ selection: HermesModelSelection, sessionID: String) async throws { }
}
private final class ConnectionStub: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let (status, body) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
