import XCTest
@testable import Luna

final class LunaContextTests: XCTestCase {
    @MainActor func testMicSwitchAndTypedTurnsCarryTheSessionTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestVault(), backend = RecordingAgent(label: "A")
        let store = LunaStore(root: root, loadSavedState: false, backendFactory: { _, _ in backend }, readKey: vault.read, writeKey: vault.write)
        let profile = try await store.saveAgent(AgentProfile(name: "Jetson", kind: .hermes, address: "https://a.example"), key: "a-key")
        let address = SessionAddress(agentID: profile.id, sessionID: "shared")
        try store.transcripts.upsert(TranscriptEntry(id: "u1", turnID: "t1", address: address, kind: .userToLuna, source: .spoken, text: "Deploy the site", createdAt: 1))
        try store.transcripts.upsert(TranscriptEntry(id: "a1", turnID: "t1", address: address, kind: .agentFinal, text: "Deployed to staging.", createdAt: 2))

        // Microphone: the voice session starts knowing the agent, session and history.
        let start = store.voiceStartContext(address)
        XCTAssertEqual(start["agent_id"], .string(profile.id)); XCTAssertEqual(start["session_id"], .string("shared"))
        XCTAssertEqual(start["agent_name"], .string("Jetson")); XCTAssertEqual(start["session_title"], .string("Shared conversation"))
        let entries = try XCTUnwrap(start["session_transcript"]?.object?["entries"]?.array?.compactMap(\.object))
        XCTAssertEqual(entries.compactMap { $0["text"]?.string }.suffix(2), ["Deploy the site", "Deployed to staging."])
        XCTAssertNil(store.voiceStartContext(nil)["session_transcript"], "global voice has no session context")

        // Switching destination sends the new session's context.
        XCTAssertEqual(store.destinationContext(address, entryLimit: 20, characterBudget: 5_000)["agent_name"], .string("Jetson"))

        // Typed: a follow-up to the previous destination includes its transcript.
        var bodies: [JSONObject] = []
        store.makeTextRouter = { _ in LunaTextRouter { body in bodies.append(body); return TranscriptCaptureTests.answer("It's on staging.") } }
        store.lunaText.destination = address
        store.lunaText.draft = "Where did that deploy go?"; store.sendLunaText()
        for _ in 0..<400 { if !store.lunaText.sending { break }; try await Task.sleep(for: .milliseconds(5)) }
        let instructions = try XCTUnwrap(bodies.first?["instructions"]?.string)
        XCTAssertTrue(instructions.contains("previous_destination_transcript"))
        XCTAssertTrue(instructions.contains("Deployed to staging."))
        XCTAssertTrue(LunaVoiceTools.instructions.contains("session_transcript"), "Luna is told what the transcript is")
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }
}
