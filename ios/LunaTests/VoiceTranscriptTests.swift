import XCTest
@testable import Luna

final class VoiceTranscriptTests: XCTestCase {
    @MainActor func testSegmenterGroupsFragmentsBySpeakerGapAndDelegation() {
        let segmenter = VoiceTurnSegmenter(prefix: "v", gap: 1_000)
        var turns: [VoiceTurnSegmenter.Turn] = []
        segmenter.onTurn = { turns.append($0) }
        segmenter.delta(role: "user", text: "Ask Jetson ", startMs: 0, endMs: 400)
        segmenter.delta(role: "user", text: "to deploy", startMs: 400, endMs: 900)
        XCTAssertEqual(segmenter.open?.text, "Ask Jetson to deploy")
        XCTAssertEqual(segmenter.delegationStarted()?.id, "v-user-1", "delegation closes the user's turn")
        XCTAssertNil(segmenter.open)
        XCTAssertEqual(segmenter.currentUserTurnID, "v-user-1", "backend work still maps to the closed turn")
        segmenter.delta(role: "assistant", text: "Sending it ", startMs: 1_200, endMs: 1_500)
        segmenter.delta(role: "assistant", text: "now.", startMs: 1_500, endMs: 1_700)
        segmenter.delta(role: "user", text: "Thanks", startMs: 1_800, endMs: 2_000)
        XCTAssertEqual(turns.filter(\.closed).map(\.id), ["v-user-1", "v-assistant-2"], "a speaker change closes the previous turn")
        segmenter.delta(role: "user", text: "and one more thing", startMs: 5_000, endMs: 5_500)
        XCTAssertEqual(turns.filter(\.closed).map(\.id), ["v-user-1", "v-assistant-2", "v-user-3"], "a long pause starts a new turn")
        XCTAssertEqual(segmenter.open?.id, "v-user-4")
        segmenter.close()
        XCTAssertEqual(turns.last?.closed, true); XCTAssertEqual(turns.last?.text, "and one more thing")
        XCTAssertEqual(turns.filter { $0.id == "v-user-1" }.map(\.text), ["Ask Jetson ", "Ask Jetson to deploy", "Ask Jetson to deploy"], "every growth step is reported")
    }

    @MainActor func testLiveSessionFeedsSegmenterAndCurrentTurnFromEvents() async throws {
        let live = OpenAILiveSession(key: "k", sessionID: "luna-home", title: "Luna", global: true) { _, _, _ in [:] }
        var closed: [VoiceTurnSegmenter.Turn] = []
        live.onTurn = { if $0.closed { closed.append($0) } }
        try await live.handle(["type": .string("session.input_transcript.delta"), "delta": .string("Deploy "), "start_ms": .number(0), "end_ms": .number(300)])
        try await live.handle(["type": .string("session.input_transcript.delta"), "delta": .string("the site"), "start_ms": .number(300), "end_ms": .number(700)])
        XCTAssertNotNil(live.currentTurnID)
        try await live.handle(["type": .string("session.delegation.created"), "delegation": .object(["id": .string("d1"), "target": .string("responses")])])
        XCTAssertEqual(closed.map(\.text), ["Deploy the site"])
        let turn = try XCTUnwrap(live.currentTurnID)
        try await live.handle(["type": .string("session.output_transcript.delta"), "delta": .string("On it."), "start_ms": .number(900), "end_ms": .number(1_100)])
        XCTAssertEqual(live.currentTurnID, turn, "Luna speaking does not change the user turn that work belongs to")
        try await live.handle(["type": .string("session.closed")])
        XCTAssertEqual(closed.map(\.role), ["user", "assistant"], "closing the session flushes the open turn")
    }

    @MainActor func testSpokenTurnsLandInTheTranscriptAndFollowRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestVault(), backend = RecordingAgent(label: "A")
        let store = LunaStore(root: root, loadSavedState: false, backendFactory: { _, _ in backend }, readKey: vault.read, writeKey: vault.write)
        let profile = try await store.saveAgent(AgentProfile(name: "Jetson", kind: .hermes, address: "https://a.example"), key: "a-key")
        let segmenter = VoiceTurnSegmenter(prefix: "v")
        segmenter.onTurn = { store.recordSpokenTurn($0) }
        segmenter.delta(role: "user", text: "Ask Jetson ", startMs: 0, endMs: 300)
        XCTAssertEqual(try store.transcripts.entry("v-user-1")?.status, .streaming)
        XCTAssertNil(try store.transcripts.entry("v-user-1")?.address)
        segmenter.delta(role: "user", text: "to deploy", startMs: 300, endMs: 600)
        let turn = try XCTUnwrap(segmenter.delegationStarted())
        XCTAssertEqual(try store.transcripts.entry(turn.id)?.status, .final)
        XCTAssertEqual(try store.transcripts.entry(turn.id)?.source, .spoken)
        _ = try await store.executeVoice("send_prompt", arguments: ["agent_id": .string(profile.id), "session_id": .string("shared"), "prompt": .string("Deploy the site")], id: "req-1", turnID: turn.id)
        let address = SessionAddress(agentID: profile.id, sessionID: "shared")
        XCTAssertEqual(try store.transcripts.entry(turn.id)?.address, address, "the spoken request moves into the session Luna chose")
        XCTAssertEqual(try store.transcripts.entries(turn: turn.id).map(\.kind), [.userToLuna, .lunaToAgent])
        // Luna's spoken reply belongs to that turn and session.
        var reply = VoiceTurnSegmenter.Turn(id: "v-assistant-2", role: "assistant", text: "Sent to Jetson.", startMs: 700, endMs: 900)
        store.voice.onTurn = nil
        store.recordSpokenTurn(reply)
        reply.closed = true; store.recordSpokenTurn(reply)
        let luna = try XCTUnwrap(try store.transcripts.entry("v-assistant-2"))
        XCTAssertEqual(luna.kind, .lunaToUser); XCTAssertEqual(luna.source, .spoken)
        XCTAssertEqual(luna.status, .final)
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }
}
