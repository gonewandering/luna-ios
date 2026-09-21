import XCTest
@preconcurrency import WebRTC
@testable import Luna

/// Opt-in checks use a saved OpenAI key directly, with no helper and no
/// outgoing microphone track. The playback check enables local audio output.
final class LiveConnectionTests: XCTestCase {
    /// Actual Responses routing; all agent work stays in temporary on-device demos.
    @MainActor func testGlobalTextSearchThenRouteWithoutAudio() async throws {
        let key = Credentials.read("openai-api-key")
        guard !key.isEmpty else { throw XCTSkip("Save an OpenAI key before this opt-in check.") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LunaStore(root: root, loadSavedState: false)
        await store.startDemo(); store.openAIKey = key
        let research = try XCTUnwrap(store.profiles.first { $0.name == "Research demo" })
        let other = try XCTUnwrap(store.profiles.first { $0.id != research.id })
        for runtime in store.runtimes.values { for session in runtime.sessions { await runtime.loadMessages(session.id) }; runtime.saveNow() }
        let http = APIClient(url: URL(string: "https://api.openai.com")!, token: key, label: "OpenAI")
        var calls: [String] = []
        store.makeTextRouter = { _ in LunaTextRouter { body in
            let response: JSONObject = try await http.call("/v1/responses", method: "POST", body: body)
            calls += response["output"]?.array?.compactMap { $0.object?["name"]?.string } ?? []
            return response
        } }
        do {
            store.lunaText.draft = "Search my agents and locally remembered sessions for dark canvas. Tell me which agents and conversations match so I can choose one. Only search and report; do not select a session, create one, or send work."
            store.sendLunaText()
            for _ in 0..<90 { if !store.lunaText.sending { break }; try await Task.sleep(for: .seconds(1)) }
            XCTAssertFalse(store.lunaText.sending); XCTAssertNil(store.error)
            XCTAssertNotNil(store.lunaText.latestReply)
            XCTAssertTrue(calls.contains("search_local_context"))
            XCTAssertFalse(calls.contains("send_prompt")); XCTAssertFalse(calls.contains("create_session")); XCTAssertFalse(calls.contains("refresh_session"))
            XCTAssertTrue(store.navigation.isEmpty); XCTAssertTrue(store.runtimes.values.allSatisfy { $0.runs.isEmpty })
            store.lunaText.draft = "Use Research demo and its A quieter interface session. Send exactly this once: LUNA_TYPED_ROUTE_CHECK: say hello. Do not create a session."
            store.sendLunaText(agentID: other.id)
            for _ in 0..<90 { if !store.lunaText.sending { break }; try await Task.sleep(for: .seconds(1)) }
            XCTAssertFalse(store.lunaText.sending); XCTAssertNil(store.error)
            XCTAssertTrue(calls.contains("find_agents")); XCTAssertEqual(calls.filter { $0 == "send_prompt" }.count, 1)
            let runs = store.runtimes[research.id]?.runs.values.filter { $0.text.contains("LUNA_TYPED_ROUTE_CHECK") } ?? []
            XCTAssertEqual(runs.count, 1); XCTAssertEqual(runs.first?.sessionID, "demo-design")
            XCTAssertTrue(store.runtimes[other.id]?.runs.isEmpty == true)
            XCTAssertEqual(store.navigation.last, .session(SessionAddress(agentID: research.id, sessionID: "demo-design")))
            XCTAssertFalse(store.voice.isActive); XCTAssertEqual(store.lunaText.messages.count, 4)
            print("Global text check: search without submission, named agent routing despite another open list, one exact session admission, no audio")
        } catch {
            store.stopLunaText()
            for runtime in store.runtimes.values { await runtime.disconnect() }
            throw error
        }
        store.stopLunaText()
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }

    /// Real global GPT-Live delegation with demo agents and receive-only audio.
    /// No microphone track or external Hermes request is created by this check.
    @MainActor func testGlobalVoiceSearchRoutesAndPausesMicrophone() async throws {
        let key = Credentials.read("openai-api-key")
        guard !key.isEmpty else { throw XCTSkip("Save an OpenAI key before this opt-in check.") }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var keys: [String: String] = [:]
        let store = LunaStore(root: root, loadSavedState: false, backendFactory: { _, _ in DemoBackend() },
                              readKey: { keys[$0] ?? "" }, writeKey: { keys[$1] = $0 })
        let writing = try await store.saveAgent(AgentProfile(name: "Writing demo", kind: .hermes, address: "https://writing.invalid"), key: "demo")
        let research = try await store.saveAgent(AgentProfile(name: "Original researcher", kind: .hermes, address: "https://research.invalid"), key: "demo")
        try store.renameAgent(research.id, name: "Research demo")
        for runtime in store.runtimes.values { for session in runtime.sessions { await runtime.loadMessages(session.id) }; runtime.saveNow() }
        store.voice.state = .listening
        var calls: [String] = [], failures: [String] = []
        let live = OpenAILiveSession(key: key, sessionID: "home", title: "Luna", global: true) { name, args, id in
            calls.append(name)
            return try await store.executeVoice(name, arguments: args, id: id)
        }
        live.onFailure = { failures.append($0) }
        RTCInitializeSSL()
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        let factory = RTCPeerConnectionFactory(), configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let peer = try XCTUnwrap(factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil))
        defer { peer.close() }
        let transceiver = RTCRtpTransceiverInit(); transceiver.direction = .recvOnly
        peer.addTransceiver(of: .audio, init: transceiver)
        let channel = try XCTUnwrap(peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()))
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? ServiceError(message: "No SDP")) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
        for _ in 0..<100 { if peer.iceGatheringState == .complete { break }; try await Task.sleep(for: .milliseconds(100)) }
        do {
            let answer = try await live.start(sdp: XCTUnwrap(peer.localDescription?.sdp))
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer.sdp)) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            for _ in 0..<150 { if channel.readyState == .open { break }; try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertEqual(channel.readyState, .open)
            // Exercise the UI-destination update schema on a live session too.
            await live.updateDestination(["agent_id": .string(writing.id), "session_id": .string("demo-luna")])
            let request = "List my agents, find Research demo by its saved name, and list its sessions. Use its A quieter interface session. Search the local cache for dark canvas and read that session's local context. Select that session, send exactly this prompt once: LUNA_GLOBAL_ROUTE_CHECK: say hello. Finally pause your microphone. Do not refresh remote history or create sessions."
            let item: JSONObject = ["type": .string("response.item.create"), "event_id": .string(UUID().uuidString),
                "item": .object(["type": .string("message"), "role": .string("user"), "content": .array([.object(["type": .string("input_text"), "text": .string(request)])])])]
            try await live.send(item)
            try await live.send(["type": .string("response.create"), "event_id": .string(UUID().uuidString)])
            for _ in 0..<75 {
                if !failures.isEmpty { break }
                let done = store.runtimes[research.id]?.runs.values.contains { $0.text.contains("LUNA_GLOBAL_ROUTE_CHECK") && $0.status == "completed" } == true
                if done && store.voice.microphoneMuted { break }
                try await Task.sleep(for: .seconds(1))
            }
            XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
            for name in ["list_agents", "find_agents", "list_sessions", "search_local_context", "get_session_context", "select_session", "send_prompt", "pause_microphone"] {
                XCTAssertTrue(calls.contains(name), "Missing global tool: " + name)
            }
            XCTAssertEqual(calls.filter { $0 == "send_prompt" }.count, 1)
            XCTAssertFalse(calls.contains("refresh_session"))
            let matches = store.runtimes[research.id]?.runs.values.filter { $0.text.contains("LUNA_GLOBAL_ROUTE_CHECK") } ?? []
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches.first?.sessionID, "demo-design")
            XCTAssertEqual(matches.first?.status, "completed")
            XCTAssertTrue(store.runtimes[writing.id]?.runs.isEmpty == true)
            XCTAssertEqual(store.voiceTarget, SessionAddress(agentID: research.id, sessionID: "demo-design"))
            XCTAssertTrue(store.voice.microphoneMuted)
            XCTAssertFalse(RTCAudioSession.sharedInstance().isAudioEnabled)
            print("Global voice check: local search, explicit Research session routing, exactly one completed task, microphone pause")
        } catch {
            await live.close()
            for runtime in store.runtimes.values { await runtime.disconnect() }
            await store.voice.stop()
            throw error
        }
        await live.close()
        for runtime in store.runtimes.values { await runtime.disconnect() }
        await store.voice.stop()
    }

    @MainActor private func savedHermesConnection() -> (String, String) {
        if let data = try? Data(contentsOf: AgentFiles.root.appending(path: "profiles.json")),
           let registry = try? JSONDecoder().decode(AgentRegistry.self, from: data),
           let profile = registry.agents.first(where: { $0.kind == .hermes && !Credentials.read($0.keyAccount).isEmpty }) {
            return (profile.address, Credentials.read(profile.keyAccount))
        }
        let address = UserDefaults.standard.string(forKey: "hermesAddress") ?? ""
        return (address, Credentials.read(Credentials.hermesAccount(address)))
    }

    @MainActor func testAutoRunWithFullHermesCatalog() async throws {
        let (address, hermesKey) = savedHermesConnection()
        let key = Credentials.read("openai-api-key")
        guard !key.isEmpty, !hermesKey.isEmpty else { throw XCTSkip("Save Hermes and OpenAI keys first.") }
        let backend = HermesClient(url: try APIClient.validateURL(address), key: hermesKey)
        let router = AutoModelRouter(key: key)
        let before = try await backend.models()
        let session = try await backend.create("Luna Auto check")
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities(), selectModel: { run in
            let catalog = try await backend.models()
            return try await router.choose(prompt: run.text, history: run.history ?? [], catalog: catalog)
        }) { _ in }
        queue.resume(); defer { queue.pause() }
        let id = UUID().uuidString
        _ = try await queue.admit(id: id, sessionID: session.id,
            text: "Reply with exactly LUNA_AUTO_OK. Do not use tools or modify anything.", automaticModel: true)
        for _ in 0..<60 {
            if queue.records[id]?.isActive == false { break }
            try await Task.sleep(for: .seconds(1))
        }
        let run = try XCTUnwrap(queue.records[id])
        XCTAssertEqual(run.status, "completed", run.error ?? "Run did not finish")
        let choice = try XCTUnwrap(run.modelDecision)
        XCTAssertTrue(before.contains(choice.selection))
        XCTAssertEqual(choice.complexity, .simple)
        XCTAssertTrue(run.output.contains("LUNA_AUTO_OK"))
        let history = try await backend.messages(session.id)
        XCTAssertTrue(history.messages.contains { $0.role == "assistant" && $0.content.contains("LUNA_AUTO_OK") })
        let after = try await backend.models()
        XCTAssertEqual(before.current, after.current)
        print("Full catalog Auto check: \(choice.selection.provider)/\(choice.selection.model), session \(session.id)")
    }

    @MainActor func testLiveAutoChoosesLightweightAndPlanningModels() async throws {
        let (address, hermesKey) = savedHermesConnection()
        let key = Credentials.read("openai-api-key")
        guard !key.isEmpty, !hermesKey.isEmpty else { throw XCTSkip("Save Hermes and OpenAI keys first.") }
        let backend = HermesClient(url: try APIClient.validateURL(address), key: hermesKey)
        let liveCatalog = try await backend.models()
        let light = "claude-haiku-4-5-20251001", heavy = "claude-opus-5"
        let provider = try XCTUnwrap(liveCatalog.availableProviders.first { $0.id == "anthropic" })
        guard provider.models.contains(light), provider.models.contains(heavy) else {
            throw XCTSkip("The routing check requires configured lightweight and heavyweight Anthropic models.")
        }
        // A controlled pair from the real server makes the expected quality/cost
        // tradeoff explicit. Neither prompt is actually executed by Hermes.
        let catalog = HermesModelCatalog(providers: [HermesModelProvider(id: provider.id, name: provider.name, authenticated: true,
            models: [light, heavy], capabilities: provider.capabilities)], current: liveCatalog.current)
        let router = AutoModelRouter(key: key)
        let quick = try await router.choose(prompt: "What is 2 + 2?", history: [], catalog: catalog)
        XCTAssertEqual(quick.complexity, .simple)
        XCTAssertEqual(quick.selection.model, light)
        let plan = "Plan a zero-downtime migration of a multi-region distributed database. Analyze consistency, failure recovery, rollout stages, rollback triggers, and tradeoffs."
        let difficult = try await router.choose(prompt: plan, history: [], catalog: catalog)
        XCTAssertEqual(difficult.complexity, .complex)
        XCTAssertEqual(difficult.selection.model, heavy)
        let followUp = try await router.choose(prompt: "Implement that.", history: [
            ChatMessage(id: "plan", role: "user", content: plan, createdAt: 1),
            ChatMessage(id: "answer", role: "assistant", content: "The plan needs coordinated schema changes, replication, staged traffic shifts and rollback automation.", createdAt: 2)
        ], catalog: catalog)
        XCTAssertEqual(followUp.complexity, .complex)
        XCTAssertEqual(followUp.selection.model, heavy)
        print("Auto routing: simple → \(quick.selection.model); planning → \(difficult.selection.model); contextual follow-up → \(followUp.selection.model)")
    }

    @MainActor func testAutoModePersistsAndRoutesTypedAndVoiceRequests() async throws {
        let store = AppStore()
        await store.connect(useDemo: true)
        try await store.loadModels()
        await store.createSession(title: "Auto mode check")
        let a = try XCTUnwrap(store.selectedSessionID)
        await store.createSession(title: "Manual mode check")
        let b = try XCTUnwrap(store.selectedSessionID)
        let fixed = HermesModelSelection(provider: "demo", model: "demo-balanced")
        try await store.setSessionModel(fixed, sessionID: a)
        try await store.setSessionModel(fixed, sessionID: b)
        try store.setSessionAutoModel(a)
        XCTAssertNil(store.sessionModels[a])
        await store.connect(useDemo: true)
        XCTAssertTrue(store.usesAutoModel(a))
        XCTAssertFalse(store.usesAutoModel(b))
        XCTAssertEqual(store.sessionModels[b], fixed)
        await store.select(b)
        store.drafts[a] = "Hello"
        await store.send(a)
        let typed = try XCTUnwrap(store.runs.values.first { $0.sessionID == a }?.id)
        let voiceID = UUID().uuidString
        _ = try await store.executeVoice("send_prompt", arguments: ["prompt": .string("Plan a migration")], id: voiceID, boundSession: a)
        for _ in 0..<140 {
            if store.runs[voiceID]?.status == "completed" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.runs[typed]?.modelSelection?.model, "demo-fast")
        XCTAssertEqual(store.runs[voiceID]?.modelSelection?.model, "demo-balanced")
        XCTAssertEqual(store.runs[voiceID]?.status, "completed")
        XCTAssertEqual(store.selectedSessionID, b)
        XCTAssertEqual(store.sessionModels[b], fixed)
        try await store.loadModels()
        try await store.setSessionModel(fixed, sessionID: a)
        XCTAssertFalse(store.usesAutoModel(a), "Choosing a manual model exits Auto")
        XCTAssertEqual(store.sessionModels[a], fixed)
        await store.sceneChanged(background: true)
    }

    @MainActor func testTypedAndVoicePromptsUseTheirSessionModels() async throws {
        let store = AppStore()
        await store.connect(useDemo: true)
        try await store.loadModels()
        await store.createSession(title: "Model routing A")
        let a = try XCTUnwrap(store.selectedSessionID)
        await store.createSession(title: "Model routing B")
        let b = try XCTUnwrap(store.selectedSessionID)
        let first = HermesModelSelection(provider: "demo", model: "demo-balanced")
        let second = HermesModelSelection(provider: "demo", model: "demo-fast")
        try await store.setSessionModel(first, sessionID: a)
        try await store.setSessionModel(second, sessionID: b)
        await store.connect(useDemo: true)
        XCTAssertEqual(store.sessionModels[a], first)
        XCTAssertEqual(store.sessionModels[b], second)
        try await store.loadModels()
        store.drafts[a] = "Typed in A"
        await store.send(a)
        _ = try await store.executeVoice("send_prompt", arguments: ["prompt": .string("Spoken in B")], id: UUID().uuidString, boundSession: b)
        XCTAssertEqual(store.runs.values.first { $0.sessionID == a }?.modelSelection, first)
        XCTAssertEqual(store.runs.values.first { $0.sessionID == b }?.modelSelection, second)
        do { try await store.setSessionModel(second, sessionID: a); XCTFail("Do not change a busy session") } catch { }
        XCTAssertEqual(store.sessionModels[a], first)
        for _ in 0..<100 {
            if !store.runs.values.contains(where: { ($0.sessionID == a || $0.sessionID == b) && $0.isActive }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await store.sceneChanged(background: true)
    }

    @MainActor func testHermesSessionModelSelection() async throws {
        let (address, key) = savedHermesConnection()
        guard !key.isEmpty else { throw XCTSkip("Save a Hermes connection first.") }
        let backend = HermesClient(url: try APIClient.validateURL(address), key: key)
        let catalog = try await backend.models()
        XCTAssertFalse(catalog.availableProviders.isEmpty)
        let provider = try XCTUnwrap(catalog.availableProviders.first { $0.id == "anthropic" })
        let candidate = "claude-haiku-4-5-20251001"
        guard provider.models.contains(candidate), catalog.current?.model != candidate else {
            throw XCTSkip("This check requires a configured non-default Anthropic Haiku model.")
        }
        let choice = HermesModelSelection(provider: provider.id, model: candidate)
        let session = try await backend.create("Luna model selection check")
        try await backend.setModel(choice, sessionID: session.id)
        let saved = try await backend.session(session.id)
        XCTAssertEqual(saved.model, choice.model)
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities()) { _ in }
        queue.resume(); defer { queue.pause() }
        let id = UUID().uuidString.lowercased()
        _ = try await queue.admit(id: id, sessionID: session.id,
            text: "Reply with exactly LUNA_MODEL_OK. Do not use tools or modify anything.", model: choice)
        for _ in 0..<60 {
            if queue.records[id]?.isActive == false { break }
            try await Task.sleep(for: .seconds(1))
        }
        let run = try XCTUnwrap(queue.records[id])
        XCTAssertEqual(run.status, "completed", run.error ?? "Run did not finish")
        XCTAssertTrue(run.output.contains("LUNA_MODEL_OK"))
        let after = try await backend.session(session.id)
        XCTAssertEqual(after.model, choice.model)
        let history = try await backend.messages(session.id)
        XCTAssertTrue(history.messages.contains { $0.role == "assistant" && $0.content.contains("LUNA_MODEL_OK") })
        let freshCatalog = try await backend.models()
        XCTAssertEqual(freshCatalog.current, catalog.current, "A session choice must not change the global model")
        print("Model selection check session: " + session.id)
    }

    @MainActor func testLocalStreamingRoutesEventsToTheirOriginalSession() async throws {
        let store = AppStore()
        await store.connect(useDemo: true)
        XCTAssertTrue(store.connected)
        await store.select("demo-design")
        let original = store.messages["demo-design"]
        store.drafts["demo-luna"] = "Show a streaming code example."
        await store.send("demo-luna")
        let id = try XCTUnwrap(store.runs.values.first { $0.isActive }?.id)
        for _ in 0..<80 {
            if store.runs[id]?.status == "completed" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(store.runs[id]?.status, "completed")
        XCTAssertEqual(store.runs[id]?.sessionID, "demo-luna")
        XCTAssertEqual(store.selectedSessionID, "demo-design")
        XCTAssertEqual(store.messages["demo-design"], original)
        XCTAssertTrue(store.runs[id]?.output.contains("```swift") == true)
        await store.sceneChanged(background: true)
    }

    @MainActor func testDirectHermesReadConnection() async throws {
        let (address, key) = savedHermesConnection()
        guard !key.isEmpty else { throw XCTSkip("Save a Hermes connection first.") }
        let client = HermesClient(url: try APIClient.validateURL(address), key: key)
        let capabilities = try await client.capabilities()
        XCTAssertEqual(capabilities["run_submission"], .bool(true))
        let page = try await client.sessions(offset: 0)
        XCTAssertFalse(page.sessions.isEmpty)
        if let session = page.sessions.first {
            let history = try await client.messages(session.id)
            XCTAssertEqual(history.resolvedSessionID, session.id)
        }
        let tools = try await client.tools()
        XCTAssertFalse(tools.isEmpty)
    }

    @MainActor func testSilentWebRTCAndSidebandHandshake() async throws {
        try await checkLiveConnection(playback: false)
    }

    @MainActor func testDirectHermesRun() async throws {
        let (address, key) = savedHermesConnection()
        guard !key.isEmpty else { throw XCTSkip("Save a Hermes connection first.") }
        let backend = HermesClient(url: try APIClient.validateURL(address), key: key)
        let session = try await backend.create("Luna standalone check")
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities()) { _ in }
        queue.resume()
        defer { queue.pause() }
        let id = UUID().uuidString.lowercased()
        _ = try await queue.admit(id: id, sessionID: session.id, text: "Reply with exactly LUNA_DIRECT_OK. Do not use tools or modify anything.")
        for _ in 0..<60 {
            if queue.records[id]?.isActive == false { break }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertEqual(queue.records[id]?.status, "completed", queue.records[id]?.error ?? "Run did not finish")
        XCTAssertTrue(queue.records[id]?.output.contains("LUNA_DIRECT_OK") == true)
        XCTAssertEqual(queue.records[id]?.sessionID, session.id)
        let history = try await backend.messages(session.id)
        XCTAssertTrue(history.messages.contains { $0.role == "assistant" && $0.content.contains("LUNA_DIRECT_OK") })
    }

    @MainActor func testHermesReturnsCodeForRichChat() async throws {
        let (address, key) = savedHermesConnection()
        guard !key.isEmpty else { throw XCTSkip("Save a Hermes connection first.") }
        let backend = HermesClient(url: try APIClient.validateURL(address), key: key)
        let session = try await backend.create("Code in Luna")
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities()) { _ in }
        queue.resume()
        defer { queue.pause() }
        let id = UUID().uuidString.lowercased()
        _ = try await queue.admit(id: id, sessionID: session.id,
            text: "Show a short Swift greeting function and a JSON example. Do not run tools or change files.")
        for _ in 0..<60 {
            if queue.records[id]?.isActive == false { break }
            try await Task.sleep(for: .seconds(1))
        }
        let run = try XCTUnwrap(queue.records[id])
        XCTAssertEqual(run.status, "completed", run.error ?? "Run did not finish")
        let code = MarkdownBlocks.parse(run.output).compactMap { block -> CodeLanguage? in
            guard case .code(let info) = block.kind else { return nil }
            return CodeLanguage(info: info, source: block.content)
        }
        XCTAssertTrue(code.contains { $0.identifier == "swift" })
        XCTAssertTrue(code.contains { $0.identifier == "json" })
        let history = try await backend.messages(session.id)
        XCTAssertTrue(history.messages.contains { $0.role == "assistant" && $0.content == run.output })
        print("Rich code check session: " + session.id)
    }

    /// Exercises the same audio-session lifecycle as the app, with no outgoing
    /// microphone track. Run separately when diagnosing simulator audio drivers.
    @MainActor func testPlaybackAudioLifecycle() async throws {
        try await checkLiveConnection(playback: true)
    }

    @MainActor private func checkLiveConnection(playback: Bool) async throws {
        let key = Credentials.read("openai-api-key")
        guard !key.isEmpty else { throw XCTSkip("Save an OpenAI key in Luna before running this opt-in check.") }
        let backend = DemoBackend()
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities()) { _ in }
        queue.resume()
        defer { queue.pause() }
        let live = OpenAILiveSession(key: key, sessionID: "demo-luna", title: "Demo") { name, arguments, id in
            guard name == "send_prompt" else { return ["note": .string("Submit the requested demo task using send_prompt.")] }
            let run = try await queue.admit(id: id, sessionID: "demo-luna", text: arguments["prompt"]?.string ?? "")
            return ["status": .string(run.status), "request_id": .string(run.id)]
        }
        RTCInitializeSSL()
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        let audio = VoiceAudioSession()
        let audioStarted = playback ? expectation(description: "WebRTC begins playback") : nil
        let audioObserver = audioStarted.map(AudioStartObserver.init)
        if let audioObserver { RTCAudioSession.sharedInstance().add(audioObserver) }
        defer { if let audioObserver { RTCAudioSession.sharedInstance().remove(audioObserver) } }
        if playback { try audio.prepare() }
        defer { audio.stop() }
        let factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let peer = try XCTUnwrap(factory.peerConnection(with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil))
        defer { audio.stop(); peer.close() }
        let transceiver = RTCRtpTransceiverInit()
        transceiver.direction = .recvOnly
        peer.addTransceiver(of: .audio, init: transceiver)
        let channel = try XCTUnwrap(peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration()))
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? ServiceError(message: "No SDP")) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        for _ in 0..<100 {
            if peer.iceGatheringState == .complete { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(peer.iceGatheringState, .complete)
        let sdp = try XCTUnwrap(peer.localDescription?.sdp)
        print("Live check: creating direct OpenAI session")
        let answer = try await live.start(sdp: sdp)
        print("Live check: applying WebRTC answer")
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer.sdp)) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            for _ in 0..<150 {
                if channel.readyState == .open { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(channel.readyState, .open, "OpenAI WebRTC data channel should connect")
            print("Live check: data channel open")
            XCTAssertTrue([RTCIceConnectionState.connected, .completed].contains(peer.iceConnectionState))
            if playback {
                audio.enable()
                if let audioStarted { await fulfillment(of: [audioStarted], timeout: 15) }
                XCTAssertTrue(RTCAudioSession.sharedInstance().isAudioEnabled)
            }
            let marker = "luna-check-" + UUID().uuidString.lowercased()
            func send(_ payload: [String: Any]) throws {
                XCTAssertTrue(channel.sendData(RTCDataBuffer(data: try JSONSerialization.data(withJSONObject: payload), isBinary: false)))
            }
            try send(["type":"response.item.create", "event_id":"typed_check",
                      "item":["type":"message", "role":"user", "content":[["type":"input_text",
                        "text":"Send exactly this prompt to Hermes in the current session: Reply with a greeting and include \(marker)."]]]])
            try send(["type":"response.create", "event_id":"run_check"])
            var matched: [AgentRun] = []
            for _ in 0..<30 {
                matched = queue.records.values.filter { $0.text.contains(marker) }
                if matched.contains(where: { $0.status == "completed" }) { break }
                try await Task.sleep(for: .seconds(1))
            }
            XCTAssertEqual(matched.count, 1, "One structured voice-router command should start one demo run")
            XCTAssertEqual(matched.first?.sessionID, "demo-luna")
            XCTAssertEqual(matched.first?.status, "completed")
            print("Live check: delegated demo task completed")
        } catch {
            await live.close()
            throw error
        }
        await live.close()
        XCTAssertTrue(live.closed)
        // The begin-playback delegate reports intent even with manual audio
        // disabled. It is not a hardware-state signal for the silent check.
        if !playback { XCTAssertFalse(RTCAudioSession.sharedInstance().isAudioEnabled) }
    }
}

private final class AudioStartObserver: NSObject, RTCAudioSessionDelegate {
    let started: XCTestExpectation
    init(started: XCTestExpectation) { self.started = started }
    func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        started.fulfill()
    }
    func audioSession(_ session: RTCAudioSession, audioUnitStartFailedWithError error: Error) {
        XCTFail("Audio startup failed: \(error.localizedDescription)")
    }
}
