import XCTest
@testable import Luna

final class SessionComposerTests: XCTestCase {
    @MainActor private func makeStore() async throws -> (LunaStore, RecordingAgent, AgentProfile, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = TestVault(), backend = RecordingAgent(label: "A")
        let store = LunaStore(root: root, loadSavedState: false, backendFactory: { _, _ in backend }, readKey: vault.read, writeKey: vault.write)
        let profile = try await store.saveAgent(AgentProfile(name: "Jetson", kind: .hermes, address: "https://a.example"), key: "a-key")
        return (store, backend, profile, root)
    }
    @MainActor private func settle(_ store: LunaStore) async throws {
        for _ in 0..<400 { if !store.lunaText.sending { return }; try await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor func testComposerTextGoesThroughLunaToTheOpenSessionOnly() async throws {
        let (store, backend, profile, root) = try await makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try XCTUnwrap(store.runtimes[profile.id])
        var bodies: [JSONObject] = []
        store.makeTextRouter = { _ in LunaTextRouter { body in
            bodies.append(body)
            switch bodies.count {
            // Luna first tries to wander off to another session; the bound guard refuses.
            case 1: return TranscriptCaptureTests.completed([TranscriptCaptureTests.call("send_prompt", "c1",
                        ["agent_id": .string(profile.id), "session_id": .string("two"), "prompt": .string("Deploy")])])
            case 2: return TranscriptCaptureTests.completed([TranscriptCaptureTests.call("send_prompt", "c2",
                        ["agent_id": .string(profile.id), "session_id": .string("shared"), "prompt": .string("Deploy the site to staging")])])
            default: return TranscriptCaptureTests.answer("Sent to Jetson.")
            }
        } }
        runtime.drafts["shared"] = "deploy it to staging"
        await runtime.send("shared")
        try await settle(store)
        XCTAssertEqual(runtime.drafts["shared"], "", "the draft clears once Luna takes it")
        XCTAssertTrue(bodies[0]["instructions"]?.string?.contains("bound_destination") == true)
        let refusal = bodies[1]["input"]?.array?.compactMap(\.object).first { $0["type"]?.string == "function_call_output" }?["output"]?.string ?? ""
        XCTAssertTrue(refusal.contains("specific conversation"), "a send to another session is refused, not executed")
        XCTAssertEqual(runtime.runs.values.map(\.sessionID), ["shared"])
        XCTAssertEqual(runtime.runs.values.first?.text, "Deploy the site to staging", "Luna's interpretation is what the agent receives")
        let rows = try store.transcripts.entries(SessionAddress(agentID: profile.id, sessionID: "shared")).filter { $0.historyID == nil }
        XCTAssertEqual(rows.first?.kind, .userToLuna); XCTAssertEqual(rows.first?.text, "deploy it to staging")
        XCTAssertTrue(rows.contains { $0.kind == .lunaToAgent && $0.text == "Deploy the site to staging" })
        _ = backend
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }

    @MainActor func testTypedRunsGetASummaryThatPointsAtTheRawAnswer() async throws {
        let (store, _, profile, root) = try await makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        var summaryBody: JSONObject?
        store.makeTextRouter = { _ in LunaTextRouter { body in
            if body["tools"] == nil { summaryBody = body; return TranscriptCaptureTests.answer("Deployed to staging; two migrations ran.") }
            return TranscriptCaptureTests.answer("ok")
        } }
        let address = SessionAddress(agentID: profile.id, sessionID: "shared")
        try store.transcripts.upsert(TranscriptEntry(id: "turn-x", turnID: "turn-x", address: address, kind: .userToLuna, source: .typed, text: "deploy", createdAt: 1))
        var run = AgentRun(id: "r1", sessionID: "shared", text: "Deploy the site", status: "completed", output: String(repeating: "Migration log line.\n", count: 60), created: 2)
        run.turnID = "turn-x"
        store.runtimes[profile.id]?.recorder?.record(run, previous: nil)
        await store.summarizeTypedRun(run, agentID: profile.id)
        let summary = try XCTUnwrap(try store.transcripts.entry("summary-r1"))
        XCTAssertEqual(summary.kind, .lunaToUser); XCTAssertEqual(summary.summarizes, [TranscriptRecorder.outputID("r1")])
        XCTAssertEqual(summary.text, "Deployed to staging; two migrations ran.")
        XCTAssertTrue(summaryBody?["input"]?.array?.first?.object?["content"]?.string?.contains("Agent: Jetson") == true)
        XCTAssertGreaterThan(summary.createdAt, try XCTUnwrap(try store.transcripts.entry(TranscriptRecorder.outputID("r1"))).createdAt)
        // Idempotent, and spoken turns are left to Luna's voice.
        await store.summarizeTypedRun(run, agentID: profile.id)
        XCTAssertEqual(try store.transcripts.entries(turn: "turn-x").filter { $0.kind == .lunaToUser }.count, 1)
        try store.transcripts.upsert(TranscriptEntry(id: "turn-v", turnID: "turn-v", address: address, kind: .userToLuna, source: .spoken, text: "deploy", createdAt: 3))
        var spoken = run; spoken = AgentRun(id: "r2", sessionID: "shared", text: "x", status: "completed", output: run.output, created: 4); spoken.turnID = "turn-v"
        store.runtimes[profile.id]?.recorder?.record(spoken, previous: nil)
        await store.summarizeTypedRun(spoken, agentID: profile.id)
        XCTAssertNil(try store.transcripts.entry("summary-r2"))
        // Short answers are not summarized.
        var short = AgentRun(id: "r3", sessionID: "shared", text: "x", status: "completed", output: "Done.", created: 5); short.turnID = "turn-x"
        store.runtimes[profile.id]?.recorder?.record(short, previous: nil)
        await store.summarizeTypedRun(short, agentID: profile.id)
        XCTAssertNil(try store.transcripts.entry("summary-r3"))
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }

    @MainActor func testComposerRequiresLunaAndBoundGuardCoversEveryRoutingTool() async throws {
        let (store, _, profile, root) = try await makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try XCTUnwrap(store.runtimes[profile.id])
        XCTAssertFalse(runtime.lunaAvailable())
        runtime.drafts["shared"] = "hello"
        await runtime.send("shared")
        XCTAssertTrue(runtime.error?.contains("OpenAI API key") == true)
        XCTAssertEqual(runtime.drafts["shared"], "hello", "an unsent draft is kept")
        XCTAssertTrue(runtime.runs.isEmpty, "nothing goes straight to the agent")
        let bound = SessionAddress(agentID: "a", sessionID: "s")
        XCTAssertThrowsError(try LunaStore.checkBound("create_session", ["agent_id": .string("a")], to: bound))
        XCTAssertThrowsError(try LunaStore.checkBound("select_session", ["agent_id": .string("a"), "session_id": .string("s")], to: bound))
        XCTAssertThrowsError(try LunaStore.checkBound("stop_agent", ["agent_id": .string("a"), "session_id": .string("other")], to: bound))
        XCTAssertThrowsError(try LunaStore.checkBound("start_coding_task", ["agent_id": .string("b")], to: bound))
        XCTAssertNoThrow(try LunaStore.checkBound("send_prompt", ["agent_id": .string("a"), "session_id": .string("s")], to: bound))
        XCTAssertNoThrow(try LunaStore.checkBound("get_session_context", ["agent_id": .string("b"), "session_id": .string("x")], to: bound))
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }
}
