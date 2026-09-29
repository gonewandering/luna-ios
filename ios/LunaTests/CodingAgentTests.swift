import XCTest
@testable import Luna

final class CodingAgentTests: XCTestCase {
    // MARK: Interchangeable backends

    @MainActor func testClaudeGrokAndCodexResolveFromTheCatalogWithoutHardCodingOne() throws {
        let catalog = Self.catalog()
        XCTAssertEqual(CodingAgentResolver.available(in: catalog), [.claude, .grok, .codex])
        // No request and nothing remembered: the server's current provider wins,
        // not a compiled-in favourite.
        XCTAssertEqual(try CodingAgentResolver.resolve(in: catalog).backend, .grok)
        for backend in CodingAgentBackend.allCases {
            let choice = try CodingAgentResolver.resolve(requested: backend, in: catalog)
            XCTAssertEqual(choice.backend, backend)
            XCTAssertTrue(backend.matches(choice.selection))
        }
        XCTAssertEqual(try CodingAgentResolver.resolve(requested: .claude, in: catalog).selection,
                       HermesModelSelection(provider: "anthropic", model: "claude-opus-5"),
                       "A lightweight model is a last resort for coding work")
        XCTAssertEqual(try CodingAgentResolver.resolve(requested: .codex, in: catalog).selection,
                       HermesModelSelection(provider: "openai", model: "gpt-5.1-codex"),
                       "Codex needs a Codex model, not any model that account can reach")
        XCTAssertEqual(try CodingAgentResolver.resolve(remembered: .claude, in: catalog).backend, .claude)
        // An explicit request always beats the remembered session.
        XCTAssertEqual(try CodingAgentResolver.resolve(requested: .codex, remembered: .claude, in: catalog).backend, .codex)
    }

    @MainActor func testUnavailableCodingAgentsAreReportedInsteadOfSubstituted() {
        let claudeOnly = HermesModelCatalog(providers: [
            HermesModelProvider(id: "anthropic", name: "Anthropic", authenticated: true, models: ["claude-opus-5"]),
            HermesModelProvider(id: "xai", name: "xAI", authenticated: false, models: ["grok-4"])
        ], current: nil)
        XCTAssertEqual(CodingAgentResolver.available(in: claudeOnly), [.claude])
        XCTAssertEqual(try? CodingAgentResolver.resolve(in: claudeOnly).backend, .claude)
        XCTAssertThrowsError(try CodingAgentResolver.resolve(requested: .grok, in: claudeOnly)) { error in
            let message = (error as? ServiceError)?.message ?? ""
            XCTAssertTrue(message.contains("Grok isn’t available") || message.contains("Grok isn't available"), message)
            XCTAssertTrue(message.contains("Claude"), "The available alternatives must be named: " + message)
        }
        let none = HermesModelCatalog(providers: [
            HermesModelProvider(id: "openai", name: "OpenAI", authenticated: true, models: ["gpt-5.6"])
        ], current: nil)
        XCTAssertTrue(CodingAgentResolver.available(in: none).isEmpty)
        XCTAssertThrowsError(try CodingAgentResolver.resolve(in: none))
        XCTAssertEqual(CodingAgentBackend.named("Codex"), .codex)
        XCTAssertEqual(CodingAgentBackend.named(" grok "), .grok)
        XCTAssertNil(CodingAgentBackend.named("gemini"))
        XCTAssertNil(CodingAgentBackend.named(nil))
    }

    @MainActor func testTheRouterOffersAllThreeCodingAgentsAsOneOptionalArgument() throws {
        let tool = try XCTUnwrap(LunaVoiceTools.tools.first { $0["name"]?.string == "start_coding_task" })
        let properties = try XCTUnwrap(tool["parameters"]?.object?["properties"]?.object)
        XCTAssertEqual(Set(properties.keys), ["agent_id", "prompt", "coding_agent"])
        XCTAssertEqual(properties["coding_agent"]?.object?["type"]?.array?.compactMap(\.string), ["string", "null"])
        let description = tool["description"]?.string ?? ""
        for backend in CodingAgentBackend.allCases {
            XCTAssertTrue(description.contains(backend.rawValue), "\(backend.rawValue) must be offered: " + description)
        }
        XCTAssertTrue(LunaVoiceTools.tools.contains { $0["name"]?.string == "list_coding_agents" })
        XCTAssertTrue(LunaVoiceTools.instructions.contains("start_coding_task"))
    }

    // MARK: One reused Hermes session per coding agent

    @MainActor func testCodingWorkCreatesThenReusesAHermesCodingSession() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCodingVault(), remote = CodingHermes()
        let store = LunaStore(root: root, loadSavedState: false, backendFactory: { _, _ in remote }, readKey: vault.read, writeKey: vault.write)
        let agent = try await store.saveAgent(AgentProfile(name: "Jetson", kind: .hermes, address: "https://a.example"), key: "a-key")
        let runtime = try XCTUnwrap(store.runtimes[agent.id])

        let first = try await store.executeVoice("start_coding_task",
            arguments: ["agent_id": .string(agent.id), "prompt": .string("Add a retry to the uploader")], id: "code-1")
        XCTAssertEqual(first["coding_agent"], .string("grok"), "The server's current provider is preferred when the user names none")
        XCTAssertEqual(first["reused_session"], .bool(false))
        XCTAssertEqual(first["available_coding_agents"]?.array?.compactMap(\.string), ["claude", "grok", "codex"])
        let sid = try XCTUnwrap(first["session_id"]?.string)
        XCTAssertEqual(remote.created, ["Coding · Grok"])
        XCTAssertEqual(store.voiceTarget, SessionAddress(agentID: agent.id, sessionID: sid))
        await spin { remote.submitted.count == 1 }
        let submitted = try XCTUnwrap(remote.submitted.first)
        XCTAssertEqual(submitted.sessionID, sid)
        XCTAssertEqual(submitted.text, "Add a retry to the uploader")
        XCTAssertEqual(submitted.modelSelection, HermesModelSelection(provider: "xai", model: "grok-4"))
        XCTAssertNil(submitted.automaticModel, "Coding work carries an explicit model, not Auto")
        XCTAssertEqual(remote.locked[sid], HermesModelSelection(provider: "xai", model: "grok-4"))

        let second = try await store.executeVoice("start_coding_task",
            arguments: ["agent_id": .string(agent.id), "prompt": .string("Now add a test")], id: "code-2")
        XCTAssertEqual(second["session_id"]?.string, sid, "The same coding agent reuses its session")
        XCTAssertEqual(second["reused_session"], .bool(true))
        XCTAssertEqual(remote.created, ["Coding · Grok"])

        let claude = try await store.executeVoice("start_coding_task",
            arguments: ["agent_id": .string(agent.id), "prompt": .string("Review the retry"), "coding_agent": .string("claude")], id: "code-3")
        XCTAssertEqual(claude["coding_agent"], .string("claude"))
        XCTAssertNotEqual(claude["session_id"]?.string, sid)
        XCTAssertEqual(remote.created, ["Coding · Grok", "Coding · Claude"])

        // The remembered sessions survive a relaunch, so coding work continues
        // in the same conversations instead of opening new ones.
        for runtime in store.runtimes.values { await runtime.disconnect() }
        let reopened = LunaStore(root: root, backendFactory: { _, _ in remote }, readKey: vault.read, writeKey: vault.write)
        await reopened.start()
        let restored = try XCTUnwrap(reopened.runtimes[agent.id])
        XCTAssertEqual(restored.codingSessions[.grok]?.sessionID, sid)
        XCTAssertEqual(restored.codingSessions[.claude]?.sessionID, claude["session_id"]?.string)
        let again = try await reopened.executeVoice("start_coding_task",
            arguments: ["agent_id": .string(agent.id), "prompt": .string("Keep going"), "coding_agent": .string("grok")], id: "code-4")
        XCTAssertEqual(again["session_id"]?.string, sid)
        XCTAssertEqual(remote.created, ["Coding · Grok", "Coding · Claude"])
        _ = runtime
        for runtime in reopened.runtimes.values { await runtime.disconnect() }
    }

    @MainActor func testCodingWorkRejectsAnUnknownBackendAndANonHermesAgent() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCodingVault(), remote = CodingHermes()
        let store = LunaStore(root: root, loadSavedState: false, backendFactory: { _, _ in remote }, readKey: vault.read, writeKey: vault.write)
        let agent = try await store.saveAgent(AgentProfile(name: "Jetson", kind: .hermes, address: "https://a.example"), key: "a-key")
        let compatible = try await store.saveAgent(AgentProfile(name: "Endpoint", kind: .openAICompatible, address: "https://b.example/v1"), key: "")
        await XCTAssertThrowsErrorAsync(try await store.executeVoice("start_coding_task",
            arguments: ["agent_id": .string(compatible.id), "prompt": .string("work")], id: "compatible"))
        for invalid in ["gemini", "Claude Code", ""] {
            await XCTAssertThrowsErrorAsync(try await store.executeVoice("start_coding_task",
                arguments: ["agent_id": .string(agent.id), "prompt": .string("work"), "coding_agent": .string(invalid)], id: "bad-" + invalid))
        }
        await XCTAssertThrowsErrorAsync(try await store.executeVoice("start_coding_task",
            arguments: ["agent_id": .string(agent.id), "prompt": .string("   ")], id: "empty"))
        XCTAssertTrue(remote.created.isEmpty, "A rejected request must not open a Hermes session")
        XCTAssertTrue(remote.submitted.isEmpty)
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }

    // MARK: Progress at roughly one-minute intervals

    @MainActor func testProgressIsReportedEachIntervalUntilTheRunEnds() async throws {
        XCTAssertEqual(CodingProgressReporter.defaultInterval, 60, "The issue asks for roughly one-minute updates")
        var status = "running", step: String? = "Edit file", output = ""
        var clock = 1_060.0
        var updates: [CodingProgressUpdate] = []
        let reporter = CodingProgressReporter(requestID: "run-1", interval: 60,
            now: { Date(timeIntervalSince1970: clock) },
            read: {
                CodingProgressSnapshot(backend: .codex, agentName: "Jetson", sessionID: "s", sessionTitle: "Coding · Codex",
                    requestID: "run-1", status: status, statusLabel: "Working", error: nil, output: output,
                    latestStep: step, failedStep: nil, approval: nil, startedAt: 1_000)
            },
            report: { updates.append($0) })

        let first = try XCTUnwrap(reporter.tick())
        XCTAssertEqual(first.sequence, 1)
        XCTAssertFalse(first.isFinal)
        XCTAssertTrue(first.message.contains("Codex · Jetson · Coding · Codex"), first.message)
        XCTAssertTrue(first.message.contains("after 1 minute"), first.message)
        XCTAssertTrue(first.message.contains("Latest step: Edit file"), first.message)
        XCTAssertTrue(first.message.contains("No output yet"), first.message)

        clock = 1_120; output = "Patched the uploader."
        let second = try XCTUnwrap(reporter.tick())
        XCTAssertEqual(second.sequence, 2)
        XCTAssertTrue(second.message.contains("after 2 minutes"), second.message)
        XCTAssertTrue(second.message.contains("Patched the uploader."), second.message)

        clock = 1_180; status = "completed"; step = nil
        let last = try XCTUnwrap(reporter.tick())
        XCTAssertTrue(last.isFinal)
        XCTAssertTrue(last.message.contains("Finished"), last.message)
        XCTAssertNil(reporter.tick(), "A finished run stops reporting")
        XCTAssertTrue(updates.isEmpty, "tick reports nothing on its own")
    }

    @MainActor func testTheFirstReportWaitsOneIntervalAndUsesTheConfiguredCadence() async throws {
        var waits: [TimeInterval] = []
        var updates: [CodingProgressUpdate] = []
        let reporter = CodingProgressReporter(requestID: "run-1", interval: 42,
            wait: { seconds in waits.append(seconds); throw CancellationError() },
            read: {
                CodingProgressSnapshot(backend: .grok, agentName: "Jetson", sessionID: "s", sessionTitle: "Coding · Grok",
                    requestID: "run-1", status: "running", statusLabel: "Working", error: nil, output: "",
                    latestStep: nil, failedStep: nil, approval: nil, startedAt: 0)
            },
            report: { updates.append($0) })
        reporter.start()
        await spin { !waits.isEmpty }
        XCTAssertEqual(waits, [42])
        XCTAssertTrue(updates.isEmpty, "The first update comes after an interval, not at admission")
        reporter.stop()
    }

    @MainActor func testProgressNamesBlockersAndUnknownOutcomes() {
        func message(_ status: String, approval: String? = nil, error: String? = nil, failed: String? = nil) -> String {
            let snapshot = CodingProgressSnapshot(backend: .claude, agentName: "Jetson", sessionID: "s", sessionTitle: "Coding · Claude",
                requestID: "r", status: status, statusLabel: "Working", error: error, output: "", latestStep: nil,
                failedStep: failed, approval: approval, startedAt: 0)
            return CodingProgressUpdate.message(for: snapshot, elapsed: 130)
        }
        XCTAssertTrue(message("waiting_for_approval", approval: "rm -rf build").contains("needs your approval"))
        XCTAssertTrue(message("waiting_for_approval", approval: "rm -rf build").contains("rm -rf build"))
        XCTAssertTrue(message("unknown").contains("Outcome unknown"))
        XCTAssertTrue(message("queued").contains("hasn’t started"))
        XCTAssertTrue(message("failed", error: "The host refused the connection.").contains("The host refused the connection."))
        XCTAssertTrue(message("running", failed: "Run tests").contains("A step failed: Run tests"))
        XCTAssertEqual(CodingProgressUpdate.elapsedPhrase(10), "just now")
        XCTAssertEqual(CodingProgressUpdate.elapsedPhrase(60), "after 1 minute")
        XCTAssertEqual(CodingProgressUpdate.elapsedPhrase(150), "after 3 minutes")
        XCTAssertEqual(CodingProgressUpdate.elapsedPhrase(3_600), "after 1 hour")
        XCTAssertEqual(CodingProgressUpdate.elapsedPhrase(3_960), "after 1 hour 6 minutes")
    }

    @MainActor func testDelegatedCodingWorkKeepsReportingToTheUser() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestCodingVault(), remote = CodingHermes()
        let store = LunaStore(root: root, loadSavedState: false, backendFactory: { _, _ in remote }, readKey: vault.read, writeKey: vault.write)
        store.codingProgressInterval = 0.02
        let agent = try await store.saveAgent(AgentProfile(name: "Jetson", kind: .hermes, address: "https://a.example"), key: "a-key")
        _ = try await store.executeVoice("start_coding_task",
            arguments: ["agent_id": .string(agent.id), "prompt": .string("Add a retry")], id: "code-1")
        func reports() -> [TranscriptEntry] { ((try? store.transcripts.entries(run: "code-1")) ?? []).filter { $0.id.hasPrefix("coding-progress-code-1-") } }
        await spin { reports().count >= 2 }
        let reports = reports()
        XCTAssertTrue(reports.allSatisfy { $0.kind == .lunaToUser && $0.address?.agentID == agent.id }, "progress lands in the coding session's timeline")
        XCTAssertTrue(reports[0].text.contains("Grok"), reports[0].text)
        XCTAssertEqual(reports[0].id, "coding-progress-code-1-1")
        XCTAssertEqual(reports[1].id, "coding-progress-code-1-2")
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }

    // MARK: Helpers

    static func catalog() -> HermesModelCatalog {
        HermesModelCatalog(providers: [
            HermesModelProvider(id: "anthropic", name: "Anthropic", authenticated: true, models: ["claude-haiku-4-5-20251001", "claude-opus-5"]),
            HermesModelProvider(id: "xai", name: "xAI", authenticated: true, models: ["grok-4"]),
            HermesModelProvider(id: "openai", name: "OpenAI", authenticated: true, models: ["gpt-5.6", "gpt-5.1-codex", "text-embedding-3"]),
            HermesModelProvider(id: "unconfigured", name: "Nobody", authenticated: false, models: ["claude-secret"])
        ], current: HermesModelSelection(provider: "xai", model: "grok-4"))
    }
    private func temporary() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @MainActor private func spin(_ condition: () -> Bool) async {
        for _ in 0..<400 { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Operation did not settle")
    }
    @MainActor private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T,
                                              file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await expression(); XCTFail("Expected an error", file: file, line: line) }
        catch { }
    }
}

@MainActor private final class TestCodingVault {
    var values: [String: String] = [:]
    func read(_ id: String) -> String { values[id] ?? "" }
    func write(_ key: String, _ id: String) { if key.isEmpty { values.removeValue(forKey: id) } else { values[id] = key } }
}

/// A Hermes stand-in that only knows sessions it actually created, so reuse is
/// verified against the server rather than against Luna's own file.
@MainActor private final class CodingHermes: AgentBackend {
    let isDemo = false
    var created: [String] = []
    var submitted: [AgentRun] = []
    var locked: [String: HermesModelSelection] = [:]
    private var rows: [String: AgentSession] = [:]
    private var counter = 0

    func capabilities() async throws -> JSONObject {
        ["run_submission": .bool(true), "run_events_sse": .bool(true), "session_model_lock": .bool(true),
         "runs_idempotency": .object(["durable": .bool(true), "retention_seconds": .number(86_400)])]
    }
    func sessions(offset: Int) async throws -> SessionPage {
        SessionPage(sessions: Array(rows.values.sorted { $0.id < $1.id }.dropFirst(offset)), has_more: false)
    }
    func session(_ id: String) async throws -> AgentSession {
        guard let row = rows[id] else { throw ServiceError(message: "No such session.", statusCode: 404) }
        return row
    }
    func create(_ title: String) async throws -> AgentSession {
        created.append(title); counter += 1
        let row = AgentSession(id: "session-\(counter)", title: title, preview: "", source: "Hermes",
                               updatedAt: Double(counter), messageCount: 0)
        rows[row.id] = row
        return row
    }
    func rename(_ id: String, title: String) async throws -> AgentSession { try await session(id) }
    func messages(_ id: String, offset: Int) async throws -> HistoryPage {
        HistoryPage(messages: [], hasMore: false, resolvedSessionID: id)
    }
    func submit(_ run: AgentRun) async throws -> String { submitted.append(run); return "remote-" + run.id }
    func status(_ id: String) async throws -> JSONObject { ["status": .string("running")] }
    func events(_ id: String) -> AsyncThrowingStream<HermesEvent, Error> { AsyncThrowingStream { _ in } }
    func stop(_ id: String) async throws { }
    func approve(_ id: String, requestID: String, choice: String) async throws { }
    func tools() async throws -> JSONObject { [:] }
    func skills() async throws -> JSONObject { [:] }
    func models(refresh: Bool) async throws -> HermesModelCatalog { CodingAgentTests.catalog() }
    func setModel(_ selection: HermesModelSelection, sessionID: String) async throws {
        _ = try await session(sessionID)
        locked[sessionID] = selection
    }
}
