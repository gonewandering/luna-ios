import XCTest
@testable import Luna

final class TranscriptViewTests: XCTestCase {
    private let address = SessionAddress(agentID: "a", sessionID: "s")
    private func entry(_ id: String, _ kind: TranscriptEntry.Kind, at time: Double, run: String? = nil, tool: String? = nil, summarizes: [String]? = nil) -> TranscriptEntry {
        TranscriptEntry(id: id, turnID: run ?? "t", address: address, kind: kind, text: id, tool: tool.map { .init(name: $0) }, runID: run, summarizes: summarizes, createdAt: time)
    }

    func testRowsGroupConsecutiveToolsPerRunAndHideSummarizedOutput() {
        let entries = [
            entry("u1", .userToLuna, at: 1),
            entry("l1", .lunaTool, at: 2, tool: "find_agents"),
            entry("l2", .lunaTool, at: 3, tool: "list_sessions"),
            entry("p1", .lunaToAgent, at: 4, run: "r1"),
            entry("t1", .agentTool, at: 5, run: "r1", tool: "terminal"),
            entry("t2", .agentTool, at: 6, run: "r1", tool: "web_search"),
            entry("o1", .agentFinal, at: 7, run: "r1"),
            entry("s1", .lunaToUser, at: 8, summarizes: ["o1"]),
            entry("p2", .lunaToAgent, at: 9, run: "r2"),
            entry("t3", .agentTool, at: 10, run: "r2", tool: "terminal"),
            entry("o2", .agentFinal, at: 11, run: "r2"),
        ]
        let rows = TranscriptView.rows(entries, summarized: ["o1"])
        XCTAssertEqual(rows.map(\.id), ["u1", "tools-l1", "p1", "tools-t1", "s1", "p2", "tools-t3", "o2"])
        guard case .tools(_, let lunaTools, let agent) = rows[1] else { return XCTFail() }
        XCTAssertEqual(lunaTools.map(\.id), ["l1", "l2"]); XCTAssertFalse(agent)
        guard case .tools(_, let agentTools, let isAgent) = rows[3] else { return XCTFail() }
        XCTAssertEqual(agentTools.map(\.id), ["t1", "t2"]); XCTAssertTrue(isAgent)
        XCTAssertFalse(rows.contains { $0.id == "o1" }, "summarized output renders under its summary, not on its own")
        XCTAssertTrue(rows.contains { $0.id == "o2" }, "unsummarized output stays visible")
    }

    func testToolsFromDifferentRunsDoNotMerge() {
        let entries = [entry("t1", .agentTool, at: 1, run: "r1", tool: "a"), entry("t2", .agentTool, at: 2, run: "r2", tool: "b")]
        XCTAssertEqual(TranscriptView.rows(entries, summarized: []).map(\.id), ["tools-t1", "tools-t2"])
    }

    func testLunaTimelineSectionsSplitOnDestination() {
        let luna = TranscriptEntry(id: "x", turnID: "t", address: nil, kind: .userToLuna, text: "x", createdAt: 1)
        let sections = LunaTimelineSection.split([luna, entry("u", .userToLuna, at: 2), entry("p", .lunaToAgent, at: 3), luna])
        XCTAssertEqual(sections.map { $0.address }, [nil, address, nil])
        XCTAssertEqual(sections.map { $0.entries.count }, [1, 2, 1])
    }
}
