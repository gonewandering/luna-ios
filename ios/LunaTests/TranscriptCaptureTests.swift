import XCTest
@testable import Luna

final class TranscriptCaptureTests: XCTestCase {
    @MainActor func testRunLifecycleProducesPromptToolsAndOutputRows() throws {
        let store = try TranscriptStore(file: nil)
        let recorder = TranscriptRecorder(store: store, agentID: "agent-a") { "Jetson" }
        var run = AgentRun(id: "r1", sessionID: "s1", text: "Deploy", status: "queued", output: "", created: 100)
        run.turnID = "turn-1"
        try store.upsert(TranscriptEntry(id: "turn-1", turnID: "turn-1", address: nil, kind: .userToLuna, source: .typed, text: "please deploy", createdAt: 99))
        recorder.record(run, previous: nil)
        let address = SessionAddress(agentID: "agent-a", sessionID: "s1")
        XCTAssertEqual(try store.entries(address).map(\.id), ["turn-1", "r1-prompt"], "the Luna-only user row moves into the chosen session")
        XCTAssertEqual(try store.entry("r1-prompt")?.kind, .lunaToAgent)
        XCTAssertEqual(try store.entry("r1-prompt")?.agentName, "Jetson")

        var running = run; running.status = "running"; running.upstreamID = "remote-1"
        recorder.record(running, previous: run)
        XCTAssertEqual(try store.entry("r1-prompt")?.upstreamID, "remote-1")
        XCTAssertNil(try store.entry("r1-output"), "no output row until there is output")

        recorder.record(event: HermesEvent(type: "tool.started", data: ["tool": .string("terminal"), "preview": .string("ls"), "arguments": .object(["cmd": .string("ls")])]), runID: "r1", sessionID: "s1")
        recorder.record(event: HermesEvent(type: "tool.started", data: ["tool": .string("web_search"), "preview": .string("swift")]), runID: "r1", sessionID: "s1")
        recorder.record(event: HermesEvent(type: "tool.completed", data: ["tool": .string("web_search"), "preview": .string("3 results")]), runID: "r1", sessionID: "s1")
        recorder.record(event: HermesEvent(type: "tool.failed", data: ["tool": .string("terminal"), "preview": .string("exit 1"), "error": .bool(true)]), runID: "r1", sessionID: "s1")
        recorder.record(event: HermesEvent(type: "tool.started", data: ["tool": .string("terminal"), "preview": .string("ls -la")]), runID: "r1", sessionID: "s1")
        recorder.record(event: HermesEvent(type: "message.delta", data: ["delta": .string("x")]), runID: "r1", sessionID: "s1")
        let tools = try store.entries(run: "r1").filter { $0.kind == .agentTool }
        XCTAssertEqual(tools.map { $0.tool?.name }, ["terminal", "web_search", "terminal"], "the same tool twice is two rows")
        XCTAssertEqual(tools.map { $0.tool?.status }, ["failed", "completed", "running"])
        XCTAssertEqual(tools[0].tool?.arguments, #"{"cmd":"ls"}"#)
        XCTAssertEqual(tools[0].tool?.result, "exit 1"); XCTAssertEqual(tools[1].tool?.result, "3 results")
        XCTAssertEqual(tools.map(\.turnID), ["turn-1", "turn-1", "turn-1"])

        var streaming = running; streaming.output = "Deploy"
        recorder.record(streaming, previous: running)
        XCTAssertEqual(try store.entry("r1-output")?.status, .streaming)
        XCTAssertTrue(store.hasStagedChanges, "streaming output is staged, not written per delta")
        var done = streaming; done.status = "completed"; done.output = "Deployed."
        recorder.record(done, previous: streaming)
        XCTAssertFalse(store.hasStagedChanges)
        XCTAssertEqual(try store.entry("r1-output")?.text, "Deployed."); XCTAssertEqual(try store.entry("r1-output")?.status, .final)
        XCTAssertEqual(try store.entries(run: "r1").filter { $0.kind == .agentTool }.last?.tool?.status, "completed", "open tools close with the run")
        XCTAssertEqual(try store.entries(address).map(\.kind), [.userToLuna, .lunaToAgent, .agentTool, .agentTool, .agentTool, .agentFinal])

        var failed = AgentRun(id: "r2", sessionID: "s1", text: "Break", status: "failed", output: "", created: 200)
        failed.error = "Boom"
        recorder.record(failed, previous: nil)
        XCTAssertEqual(try store.entry("r2-output")?.text, "Boom"); XCTAssertEqual(try store.entry("r2-output")?.status, .failed)
        XCTAssertEqual(try store.entry("r2-prompt")?.turnID, "run-r2", "runs without a Luna turn get their own")
    }

    @MainActor func testHistoryReconciliationMatchesLiveRowsAndImportsForeignOnes() throws {
        let store = try TranscriptStore(file: nil)
        let address = SessionAddress(agentID: "agent-a", sessionID: "s1")
        let recorder = TranscriptRecorder(store: store, agentID: "agent-a") { "Jetson" }
        var run = AgentRun(id: "r1", sessionID: "s1", text: "Deploy", status: "completed", output: "Deployed.", created: 100)
        run.turnID = "turn-1"
        recorder.record(run, previous: nil)
        recorder.record(event: HermesEvent(type: "tool.started", data: ["tool": .string("terminal"), "preview": .string("ls")]), runID: "r1", sessionID: "s1")
        recorder.record(event: HermesEvent(type: "tool.completed", data: ["tool": .string("terminal"), "preview": .string("ls")]), runID: "r1", sessionID: "s1")
        let history = [
            ChatMessage(id: "h0", role: "user", content: "Earlier from the desktop", createdAt: 50),
            ChatMessage(id: "h0a", role: "assistant", content: "Desktop answer", createdAt: 0),
            ChatMessage(id: "h1", role: "user", content: "Deploy", createdAt: 100),
            ChatMessage(id: "h2", role: "tool", content: "file.txt\nother.txt", createdAt: 101, toolName: "terminal"),
            ChatMessage(id: "h3", role: "assistant", content: "Deployed.", createdAt: 102),
            ChatMessage(id: "h4", role: "user", content: "Deploy", createdAt: 300),
        ]
        recorder.reconcile(history, sessionID: "s1", fallbackTime: 40)
        let rows = try store.entries(address)
        XCTAssertEqual(rows.map(\.shortID), ["h0", "h0a", "r1-prompt", "r1-tool-1", "r1-output", "h4"])
        XCTAssertEqual(rows.map(\.kind), [.userToLuna, .agentFinal, .lunaToAgent, .agentTool, .agentFinal, .userToLuna])
        XCTAssertEqual(try store.entry("r1-prompt")?.historyID, "h1")
        XCTAssertEqual(try store.entry("r1-output")?.historyID, "h3")
        XCTAssertEqual(try store.entry("r1-tool-1")?.tool?.result, "file.txt\nother.txt", "the server's full tool result replaces the preview")
        XCTAssertEqual(try store.entry(TranscriptEntry.historyEntryID(address, "h0a"))?.createdAt, 50, "a missing timestamp follows the previous row")
        XCTAssertEqual(try store.entry(TranscriptEntry.historyEntryID(address, "h0a"))?.turnID, "history-h0")
        XCTAssertEqual(try store.entry(TranscriptEntry.historyEntryID(address, "h4"))?.historyID, "h4", "a second identical prompt is a new row, not a re-match")
        // Re-running the same page changes nothing.
        let revision = store.revision
        recorder.reconcile(history, sessionID: "s1", fallbackTime: 40)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(try store.entries(address).map(\.shortID), ["h0", "h0a", "r1-prompt", "r1-tool-1", "r1-output", "h4"])
    }

    @MainActor func testReconciliationKeepsTurnOrderWhenServerClockIsLater() throws {
        let store = try TranscriptStore(file: nil)
        let address = SessionAddress(agentID: "agent-a", sessionID: "s1")
        let recorder = TranscriptRecorder(store: store, agentID: "agent-a") { "Jetson" }
        try store.upsert(TranscriptEntry(id: "turn-1", turnID: "turn-1", address: address, kind: .userToLuna, text: "ask", createdAt: 100))
        var run = AgentRun(id: "r1", sessionID: "s1", text: "Deploy", status: "completed", output: "Done", created: 100.5)
        run.turnID = "turn-1"
        recorder.record(run, previous: nil)
        // Luna replied before Hermes stamped the user message.
        try store.upsert(TranscriptEntry(id: "turn-1-reply", turnID: "turn-1", address: address, kind: .lunaToUser, text: "Asked.", createdAt: 100.7))
        recorder.reconcile([ChatMessage(id: "h1", role: "user", content: "Deploy", createdAt: 103), ChatMessage(id: "h2", role: "assistant", content: "Done", createdAt: 104)],
                           sessionID: "s1", fallbackTime: 0)
        XCTAssertEqual(try store.entries(address).map(\.id), ["turn-1", "r1-prompt", "turn-1-reply", "r1-output"])
        XCTAssertEqual(try store.entry("r1-prompt")?.createdAt, 103)
        XCTAssertGreaterThan(try XCTUnwrap(try store.entry("turn-1-reply")?.createdAt), 103)
    }

    @MainActor func testTypedLunaTurnRecordsUserToolsHandoffAndReply() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestVault(), backend = RecordingAgent(label: "A")
        let store = LunaStore(root: root, loadSavedState: false, backendFactory: { _, _ in backend }, readKey: vault.read, writeKey: vault.write)
        let profile = try await store.saveAgent(AgentProfile(name: "Jetson", kind: .hermes, address: "https://a.example"), key: "a-key")
        var requests = 0
        store.makeTextRouter = { _ in LunaTextRouter { body in
            requests += 1
            switch requests {
            case 1: return Self.completed([Self.call("find_agents", "c1", ["name": .string("jetson")])])
            case 2: return Self.completed([Self.call("send_prompt", "c2", ["agent_id": .string(profile.id), "session_id": .string("shared"), "prompt": .string("Deploy the site")])])
            default: return Self.answer("Sent to Jetson.")
            }
        } }
        store.lunaText.draft = "Ask Jetson to deploy the site"
        store.sendLunaText()
        for _ in 0..<400 { if !store.lunaText.sending { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.lunaText.sending)
        let address = SessionAddress(agentID: profile.id, sessionID: "shared")
        let history = try store.transcripts.entries(address).filter { $0.historyID != nil }
        XCTAssertEqual(history.map(\.text), ["A remembered answer"], "the agent's existing history is imported alongside")
        let rows = try store.transcripts.entries(address).filter { $0.historyID == nil }
        XCTAssertEqual(rows.map(\.kind), [.userToLuna, .lunaTool, .lunaToAgent, .lunaToUser], "every leg of the turn lands in the session, in order")
        XCTAssertEqual(rows[0].source, .typed); XCTAssertEqual(rows[0].text, "Ask Jetson to deploy the site")
        XCTAssertEqual(rows[1].tool?.name, "find_agents"); XCTAssertTrue(rows[1].tool?.result.contains(profile.id) == true)
        XCTAssertEqual(rows[2].text, "Deploy the site"); XCTAssertEqual(rows[2].agentName, "Jetson")
        XCTAssertEqual(rows[3].text, "Sent to Jetson.")
        XCTAssertEqual(Set(rows.map(\.turnID)).count, 1)
        XCTAssertTrue(try store.transcripts.entries(nil).isEmpty, "nothing is left in the Luna-only thread once a destination is chosen")
        XCTAssertEqual(store.runtimes[profile.id]?.runs.values.first?.turnID, rows[0].turnID)
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }

    @MainActor func testUnroutedTurnStaysInLunaThread() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LunaStore(root: root, loadSavedState: false)
        store.makeTextRouter = { _ in LunaTextRouter { _ in
            Self.completed([Self.call("list_agents", "c1")]).merging(["status": .string("completed")]) { $1 }
        } }
        var calls = 0
        store.makeTextRouter = { _ in LunaTextRouter { _ in
            calls += 1
            return calls == 1 ? Self.completed([Self.call("list_agents", "c1")]) : Self.answer("You have no agents yet.")
        } }
        store.lunaText.draft = "Which agents do I have?"; store.sendLunaText()
        for _ in 0..<400 { if !store.lunaText.sending { break }; try await Task.sleep(for: .milliseconds(5)) }
        let rows = try store.transcripts.entries(nil)
        XCTAssertEqual(rows.map(\.kind), [.userToLuna, .lunaTool, .lunaToUser])
        XCTAssertEqual(rows[1].tool?.name, "list_agents")
        XCTAssertTrue(rows.allSatisfy { $0.address == nil })
    }

    static func completed(_ output: [JSONValue]) -> JSONObject { ["status": .string("completed"), "output": .array(output)] }
    static func call(_ name: String, _ id: String, _ arguments: JSONObject = [:]) -> JSONValue {
        .object(["type": .string("function_call"), "name": .string(name), "call_id": .string(id),
                 "arguments": .string(String(decoding: try! JSONEncoder().encode(arguments), as: UTF8.self))])
    }
    static func answer(_ text: String) -> JSONObject {
        completed([.object(["type": .string("message"), "role": .string("assistant"),
                            "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])])
    }
    private func temporary() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

extension TranscriptEntry {
    /// Test shorthand: the server message ID when this row came from history, else the local ID.
    var shortID: String { historyID.map { id.hasPrefix("h:") ? $0 : id } ?? id }
}
