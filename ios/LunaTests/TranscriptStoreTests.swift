import XCTest
import SQLite3
@testable import Luna

final class TranscriptStoreTests: XCTestCase {
    private let alpha = SessionAddress(agentID: "agent-a", sessionID: "s1")

    @MainActor func testEntriesAreChronologicalWithSeqBreakingTies() throws {
        let store = try TranscriptStore(file: nil)
        let base = 1_700_000_000.0
        try store.upsert(entry("later", .lunaToUser, "third", at: base + 5))
        try store.upsert(entry("first", .userToLuna, "first", at: base))
        try store.upsert(entry("tie-a", .lunaTool, "tie a", at: base + 1))
        try store.upsert(entry("tie-b", .lunaToAgent, "tie b", at: base + 1))
        XCTAssertEqual(try store.entries(alpha).map(\.id), ["first", "tie-a", "tie-b", "later"])
        XCTAssertEqual(try store.entries(alpha, limit: 2).map(\.id), ["tie-b", "later"], "limit keeps the newest rows in order")
        XCTAssertEqual(try store.entries(alpha, before: base + 1).map(\.id), ["first"])
        XCTAssertTrue(try store.entries(nil).isEmpty)
        XCTAssertTrue(try store.entries(SessionAddress(agentID: "agent-a", sessionID: "other")).isEmpty)
    }

    @MainActor func testStreamingUpdatesKeepPositionAndCoalesceToDisk() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "transcript.sqlite")
        let store = try TranscriptStore(file: file)
        let base = 1_700_000_000.0
        try store.upsert(entry("prompt", .lunaToAgent, "Do the thing", at: base))
        var reply = entry("reply", .agentFinal, "Hel", at: base + 1, status: .streaming)
        reply.runID = "run-1"
        store.stage(reply)
        try store.upsert(entry("tool", .agentTool, "", at: base + 2))
        reply.text = "Hello"
        store.stage(reply)
        XCTAssertEqual(try store.entries(alpha).map(\.id), ["prompt", "reply", "tool"])
        XCTAssertEqual(try store.entry("reply")?.text, "Hello", "reads reflect staged text before any flush")
        XCTAssertTrue(store.hasStagedChanges)
        XCTAssertEqual(try TranscriptStore(file: file).entry("reply")?.text, nil, "staged deltas are not yet on disk")
        for _ in 0..<200 { if !store.hasStagedChanges { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.hasStagedChanges, "the coalescing flush lands on its own")
        let reopened = try TranscriptStore(file: file)
        XCTAssertEqual(try reopened.entry("reply")?.text, "Hello")
        XCTAssertEqual(try reopened.entries(alpha).map(\.id), ["prompt", "reply", "tool"], "seq survives streaming rewrites")
        let sequences = try reopened.entries(alpha).map(\.seq)
        XCTAssertEqual(sequences, sequences.sorted()); XCTAssertEqual(Set(sequences).count, 3)
        reply.text = "Hello, world"; reply.status = .final
        try reopened.upsert(reply)
        XCTAssertEqual(try reopened.entries(run: "run-1").map(\.text), ["Hello, world"])
        XCTAssertEqual(try reopened.entries(alpha).map(\.seq), sequences, "a final upsert keeps the row's seq")
    }

    @MainActor func testDatabaseIsProtectedAndExcludedFromBackup() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "nested/transcript.sqlite")
        let store = try TranscriptStore(file: file)
        try store.upsert(entry("one", .userToLuna, "hello", at: 1))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #if targetEnvironment(simulator)
        // The simulator's file system does not report data-protection classes.
        XCTAssertNotNil(attributes[.size])
        #else
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .completeUntilFirstUserAuthentication)
        #endif
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    @MainActor func testSearchMatchesTextAndToolNamesWithinFilters() throws {
        let store = try TranscriptStore(file: nil)
        let beta = SessionAddress(agentID: "agent-b", sessionID: "s9")
        try store.upsert(entry("u1", .userToLuna, "Book a café table in Lisbon", at: 10))
        try store.upsert(entry("t1", .agentTool, "", at: 11, tool: .init(name: "web_search", arguments: "lisbon cafés", result: "…")))
        var other = entry("u2", .userToLuna, "Lisbon weather tomorrow", at: 12); other.address = beta
        try store.upsert(other)
        var streamed = entry("s1", .agentFinal, "The Lisbon booking is confirmed", at: 13, status: .streaming)
        store.stage(streamed)
        XCTAssertEqual(try store.search("lisbon").map(\.id), ["s1", "u2", "t1", "u1"], "newest first; search flushes staged rows first")
        XCTAssertEqual(try store.search("CAFE").map(\.id), ["t1", "u1"], "case and diacritics are ignored; tool arguments are indexed")
        XCTAssertEqual(try store.search("web").map(\.id), ["t1"], "tool names are indexed")
        XCTAssertEqual(try store.search("lisbon", agentID: "agent-b").map(\.id), ["u2"])
        XCTAssertEqual(try store.search("lisbon", sessionID: "s1", after: 11, before: 13).map(\.id), ["s1", "t1"])
        XCTAssertEqual(try store.search("lisbon booking").map(\.id), ["s1"], "terms are AND-ed")
        XCTAssertTrue(try store.search("   ").isEmpty)
        XCTAssertTrue(try store.search("nothing-here").isEmpty)
        streamed.text = "Cancelled instead"; try store.upsert(streamed)
        XCTAssertFalse(try store.search("confirmed").contains { $0.id == "s1" }, "the index follows updates")
    }

    @MainActor func testContextIsBoundedOldestFirstAndFlagsTruncation() throws {
        let store = try TranscriptStore(file: nil)
        for index in 0..<50 {
            try store.upsert(entry("m\(index)", index % 2 == 0 ? .userToLuna : .agentFinal, String(repeating: "x", count: 500) + " #\(index)", at: Double(index)))
        }
        try store.upsert(entry("tool", .lunaTool, "", at: 100, tool: .init(name: "find_agents", status: "completed")))
        let context = try store.context(alpha, agentName: "Jetson", title: "Trip", entryLimit: 40, characterBudget: 3_000)
        XCTAssertEqual(context["agent_name"], .string("Jetson")); XCTAssertEqual(context["title"], .string("Trip"))
        XCTAssertEqual(context["agent_id"], .string("agent-a")); XCTAssertEqual(context["session_id"], .string("s1"))
        let rows = try XCTUnwrap(context["entries"]?.array?.compactMap(\.object))
        XCTAssertEqual(rows.last?["tool"], .string("find_agents"))
        XCTAssertNil(rows.last?["text"], "tool rows carry only name and status")
        let times = rows.compactMap { $0["timestamp"]?.number }
        XCTAssertEqual(times, times.sorted(), "oldest first")
        XCTAssertLessThan(rows.count, 40, "the character budget stops before the entry limit")
        XCTAssertEqual(context["truncated"], .bool(true))
        XCTAssertEqual(context["omitted_earlier"], .number(Double(51 - rows.count)))
        let total = rows.compactMap { $0["text"]?.string?.count }.reduce(0, +)
        XCTAssertLessThanOrEqual(total, 3_000)
        let small = try store.context(SessionAddress(agentID: "agent-a", sessionID: "empty"), agentName: "Jetson", title: "Empty")
        XCTAssertEqual(small["entries"], .array([])); XCTAssertEqual(small["truncated"], .bool(false))
    }

    @MainActor func testAttachTurnMovesLunaThreadRowsIntoTheChosenSession() throws {
        let store = try TranscriptStore(file: nil)
        var ask = entry("ask", .userToLuna, "Send Jetson a note", at: 1); ask.address = nil; ask = TranscriptEntry(id: ask.id, turnID: "turn-1", address: nil, kind: .userToLuna, text: ask.text, createdAt: 1)
        try store.upsert(ask)
        let lookup = TranscriptEntry(id: "lookup", turnID: "turn-1", address: nil, kind: .lunaTool, text: "", tool: .init(name: "find_agents"), createdAt: 2)
        store.stage(lookup)
        try store.upsert(TranscriptEntry(id: "unrelated", turnID: "turn-0", address: nil, kind: .userToLuna, text: "earlier", createdAt: 0))
        XCTAssertEqual(try store.entries(nil).map(\.id), ["unrelated", "ask", "lookup"])
        try store.attach(turn: "turn-1", to: alpha)
        XCTAssertEqual(try store.entries(nil).map(\.id), ["unrelated"])
        XCTAssertEqual(try store.entries(alpha).map(\.id), ["ask", "lookup"], "staged and stored rows both move")
        XCTAssertEqual(try store.entries(turn: "turn-1").compactMap(\.address), [alpha, alpha])
    }

    @MainActor func testRemovingAgentsDropsOnlyTheirRows() throws {
        let store = try TranscriptStore(file: nil)
        let beta = SessionAddress(agentID: "agent-b", sessionID: "s2")
        try store.upsert(entry("a", .userToLuna, "a", at: 1))
        var b = entry("b", .userToLuna, "b", at: 2); b.address = beta; try store.upsert(b)
        try store.upsert(TranscriptEntry(id: "luna", turnID: "t", address: nil, kind: .lunaToUser, text: "hi", createdAt: 3))
        try store.markMigrated("agent-a"); try store.markMigrated("agent-b")
        try store.removeAgent("agent-a")
        XCTAssertTrue(try store.entries(alpha).isEmpty); XCTAssertEqual(try store.entries(beta).count, 1)
        XCTAssertFalse(try store.isMigrated("agent-a")); XCTAssertTrue(try store.isMigrated("agent-b"))
        try store.retainAgents([])
        XCTAssertTrue(try store.entries(beta).isEmpty)
        XCTAssertEqual(try store.entries(nil).map(\.id), ["luna"], "the Luna-only thread is never tied to an agent")
        XCTAssertEqual(try store.sessionIDs(agentID: "agent-b"), [])
    }

    @MainActor func testMigrationImportsLegacyCacheOnceAndKeepsSourceOrder() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try TranscriptStore(file: root.appending(path: "transcript.sqlite"))
        let profile = AgentProfile(id: "agent-a", name: "Jetson", kind: .hermes, address: "https://a.example")
        var run = AgentRun(id: "run-1", sessionID: "s1", text: "Deploy it", status: "completed", output: "Deployed.", created: 30)
        run.upstreamID = "remote-1"
        let partial = AgentRun(id: "run-2", sessionID: "s1", text: "Then test", status: "failed", output: "Half", created: 40)
        let cache = ChatCache(sessions: [AgentSession(id: "s1", title: "Ops", preview: "", source: "Hermes", updatedAt: 50, messageCount: 4)],
            messages: ["s1": [ChatMessage(id: "h1", role: "user", content: "Hi", createdAt: 10),
                              ChatMessage(id: "h2", role: "assistant", content: "Hello", createdAt: 0),
                              ChatMessage(id: "h3", role: "tool", content: "ls output", createdAt: 20, toolName: "terminal"),
                              ChatMessage(id: "h4", role: "user", content: "Deploy it", createdAt: 30),
                              ChatMessage(id: "h5", role: "assistant", content: "Deployed.", createdAt: 31)]],
            runs: [run.id: run, partial.id: partial], cursor: 0, unread: [])
        var memory = SessionMemory(address: SessionAddress(agentID: "agent-a", sessionID: "s1"), agentName: "Jetson", title: "Ops", updatedAt: 50, fetchedAt: nil, messages: [])
        memory.messages = [RememberedMessage(ChatMessage(id: "h4", role: "user", content: "Deploy it", createdAt: 30), fallbackTime: 50),
                           RememberedMessage(ChatMessage(id: "m-old", role: "assistant", content: "Only remembered", createdAt: 5), fallbackTime: 50)]
        var other = SessionMemory(address: SessionAddress(agentID: "agent-a", sessionID: "s2"), agentName: "Jetson", title: "Side", updatedAt: 60, fetchedAt: nil, messages: [])
        other.messages = [RememberedMessage(ChatMessage(id: "m-side", role: "user", content: "Side question", createdAt: 60), fallbackTime: 60)]
        try TranscriptMigration.run(profile: profile, cache: cache, memory: [memory, other], into: store)
        let address = SessionAddress(agentID: "agent-a", sessionID: "s1")
        let rows = try store.entries(address)
        XCTAssertEqual(rows.map(\.id), ["m-old", "h1", "h2", "h3", "h4", "h5", "run-2-prompt", "run-2-output"])
        XCTAssertEqual(rows.map(\.kind), [.agentFinal, .userToLuna, .agentFinal, .agentTool, .userToLuna, .agentFinal, .userToLuna, .agentFinal])
        XCTAssertEqual(try store.entry("h4")?.runID, "run-1", "history that matches a journaled run keeps its run identity")
        XCTAssertEqual(try store.entry("h4")?.upstreamID, "remote-1")
        XCTAssertEqual(try store.entry("h3")?.tool, .init(name: "terminal", arguments: "", result: "ls output", status: "completed"))
        XCTAssertEqual(try store.entry("run-2-output")?.status, .failed)
        XCTAssertEqual(try store.entry("h2")?.createdAt, 10, "a missing timestamp inherits the previous row's time and keeps its place")
        XCTAssertEqual(rows.compactMap(\.agentName), Array(repeating: "Jetson", count: rows.count))
        XCTAssertEqual(try store.entries(SessionAddress(agentID: "agent-a", sessionID: "s2")).map(\.id), ["m-side"])
        XCTAssertEqual(try store.sessionIDs(agentID: "agent-a"), ["s2", "s1"])
        // A second migration, with a changed cache, must not rewrite or duplicate.
        var changed = cache; changed.messages["s1"]?.append(ChatMessage(id: "h9", role: "user", content: "New", createdAt: 90))
        try store.upsert(TranscriptEntry(id: "h1", turnID: "x", address: address, kind: .userToLuna, text: "Edited locally", createdAt: 10))
        try TranscriptMigration.run(profile: profile, cache: changed, memory: [], into: store)
        XCTAssertNil(try store.entry("h9"))
        XCTAssertEqual(try store.entry("h1")?.text, "Edited locally")
        XCTAssertTrue(try store.isMigrated("agent-a"))
    }

    @MainActor func testLunaStoreOpensTranscriptMigratesAndDeletesWithAgent() async throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = TestVault(), backend = RecordingAgent(label: "A")
        let store = LunaStore(root: root, loadSavedState: false, backendFactory: { _, _ in backend }, readKey: vault.read, writeKey: vault.write)
        let profile = try await store.saveAgent(AgentProfile(name: "Jetson", kind: .hermes, address: "https://a.example"), key: "a-key")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "transcript.sqlite").path))
        XCTAssertTrue(try store.transcripts.isMigrated(profile.id))
        let address = SessionAddress(agentID: profile.id, sessionID: "shared")
        try store.transcripts.upsert(TranscriptEntry(id: "row", turnID: "t", address: address, kind: .userToLuna, text: "hello", createdAt: 1))
        for runtime in store.runtimes.values { await runtime.disconnect() }
        try await store.removeAgent(profile.id)
        XCTAssertTrue(try store.transcripts.entries(address).isEmpty)
        XCTAssertFalse(try store.transcripts.isMigrated(profile.id))
    }

    @MainActor func testLunaStoreSurvivesUnopenableTranscript() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "transcript.sqlite"), withIntermediateDirectories: true)
        let store = LunaStore(root: root, loadSavedState: false)
        XCTAssertNil(store.transcripts.file)
        XCTAssertNotNil(store.storageError)
        try store.transcripts.upsert(TranscriptEntry(id: "x", turnID: "t", address: nil, kind: .userToLuna, text: "still works", createdAt: 1))
        XCTAssertEqual(try store.transcripts.entries(nil).count, 1)
    }

    @MainActor func testOlderSchemaIsUpgradedInPlace() throws {
        let root = temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "transcript.sqlite")
        // A version-1 file: no photos/history_id columns, one row.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(file.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
        CREATE TABLE entries (id TEXT PRIMARY KEY NOT NULL, turn_id TEXT NOT NULL, agent_id TEXT, session_id TEXT, kind TEXT NOT NULL, source TEXT,
            text TEXT NOT NULL, tool_name TEXT, tool_arguments TEXT, tool_result TEXT, tool_status TEXT, run_id TEXT, upstream_id TEXT, agent_name TEXT,
            summarizes TEXT, status TEXT NOT NULL, created_at REAL NOT NULL, seq INTEGER NOT NULL);
        INSERT INTO entries VALUES ('old', 't', 'agent-a', 's1', 'userToLuna', 'typed', 'from v1', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'final', 5, 1);
        PRAGMA user_version = 1;
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        let store = try TranscriptStore(file: file)
        XCTAssertEqual(try store.entry("old")?.text, "from v1")
        var upgraded = try XCTUnwrap(try store.entry("old")); upgraded.historyID = "h1"
        try store.upsert(upgraded)
        XCTAssertEqual(try TranscriptStore(file: file).entry("old")?.historyID, "h1")
    }

    private func entry(_ id: String, _ kind: TranscriptEntry.Kind, _ text: String, at time: Double,
                       status: TranscriptEntry.Status = .final, tool: TranscriptEntry.ToolCall? = nil) -> TranscriptEntry {
        TranscriptEntry(id: id, turnID: "turn-" + id, address: alpha, kind: kind, text: text, tool: tool, status: status, createdAt: time)
    }
    private func temporary() -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
