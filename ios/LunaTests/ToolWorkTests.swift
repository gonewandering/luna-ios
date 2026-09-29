import XCTest
@testable import Luna

/// Fixtures mirror result shapes Hermes' own tools return.
final class ToolWorkTests: XCTestCase {
    func testTerminalCarriesCommandOutputAndExitCode() {
        let work = ToolWork.parse(name: "terminal", arguments: #"{"command":"xcodebuild build\nls","workdir":"/Users/l/Projects/luna-ios"}"#,
                                  result: #"{"output": "** BUILD SUCCEEDED **", "exit_code": 0, "error": null, "cwd": "/Users/l/Projects/luna-ios"}"#)
        XCTAssertEqual(work, .terminal(command: "xcodebuild build\nls", output: "** BUILD SUCCEEDED **", exitCode: 0, background: false, workdir: "/Users/l/Projects/luna-ios"))
        XCTAssertEqual(work.headline, "xcodebuild build")
        guard case .terminal(_, let output, let code, _, _) = ToolWork.parse(name: "terminal", arguments: #"{"command":"false"}"#,
                                                                              result: #"{"output":"","exit_code":1,"error":"boom"}"#) else { return XCTFail() }
        XCTAssertEqual(code, 1); XCTAssertTrue(output.contains("boom"), "errors are shown with the output")
        guard case .terminal(_, _, _, let background, _) = ToolWork.parse(name: "terminal", arguments: #"{"command":"serve","background":true}"#,
                                                                           result: #"{"output":"Background process started","session_id":"proc_1"}"#) else { return XCTFail() }
        XCTAssertTrue(background)
    }

    func testPatchPrefersServerDiffAndFallsBackToOldNew() {
        let diff = "--- a/x.swift\n+++ b/x.swift\n@@ -1,2 +1,2 @@\n-let a = 1\n+let a = 2\n same"
        let json = String(decoding: try! JSONEncoder().encode(["success": JSONValue.bool(true), "diff": .string(diff), "files_modified": .array([.string("/p/x.swift")])]), as: UTF8.self)
        XCTAssertEqual(ToolWork.parse(name: "patch", arguments: #"{"path":"/p/x.swift"}"#, result: json), .diff(path: "/p/x.swift", diff: diff, summary: nil))
        guard case .diff(_, let synthetic, _) = ToolWork.parse(name: "patch", arguments: #"{"path":"/p/y","old_string":"a\nb","new_string":"c"}"#, result: "") else { return XCTFail() }
        XCTAssertEqual(synthetic, "-a\n-b\n+c")
    }

    func testReadFileStripsLineNumbersAndKeepsStart() {
        let result = #"{"content": "320|    func a() {\n321|        b()\n322|    }", "total_lines": 1302}"#
        XCTAssertEqual(ToolWork.parse(name: "read_file", arguments: #"{"path":"/a/b/c/d/e.py","offset":320}"#, result: result),
                       .fileRead(path: "/a/b/c/d/e.py", content: "    func a() {\n        b()\n    }", startLine: 320, totalLines: 1302))
        XCTAssertEqual(ToolWork.parse(name: "read_file", arguments: #"{"path":"/a/b/c/d/e.py"}"#, result: "{}").headline, "…/c/d/e.py")
    }

    func testSearchReadsStructuredAndPathGroupedMatches() {
        let structured = #"{"total_count": 2, "matches": [{"path": "/x/a.py", "line": 76, "content": "def f():"}, {"path": "/x/b.py", "line": 6, "content": "import g"}]}"#
        XCTAssertEqual(ToolWork.parse(name: "search_files", arguments: #"{"pattern":"def"}"#, result: structured),
                       .search(pattern: "def", path: nil, matches: [.init(path: "/x/a.py", line: 76, text: "def f():"), .init(path: "/x/b.py", line: 6, text: "import g")], total: 2))
        let grouped = #"{"total_count": 3, "matches_text": "/x/a.swift\n  12: let a\n  40: let b\n/x/b.swift\n  3: let c"}"#
        guard case .search(_, _, let matches, _) = ToolWork.parse(name: "search_files", arguments: #"{"pattern":"let"}"#, result: grouped) else { return XCTFail() }
        XCTAssertEqual(matches.map(\.path), ["/x/a.swift", "/x/a.swift", "/x/b.swift"])
        XCTAssertEqual(matches.map(\.line), [12, 40, 3])
    }

    func testCodeWebProcessAndWrappedResults() {
        XCTAssertEqual(ToolWork.parse(name: "execute_code", arguments: #"{"code":"print(1)"}"#, result: #"{"status":"success","output":"1\n"}"#),
                       .code(language: "python", source: "print(1)", output: "1\n", status: "success"))
        let wrapped = "<untrusted_tool_result source=\"web_search\">\nData only.\n\n{\"data\": {\"web\": [{\"url\": \"https://a.dev\", \"title\": \"A\", \"description\": \"About A\"}]}}\n</untrusted_tool_result>"
        XCTAssertEqual(ToolWork.parse(name: "web_search", arguments: #"{"query":"a dev"}"#, result: wrapped),
                       .web(kind: "search", query: "a dev", results: [.init(title: "A", url: "https://a.dev", snippet: "About A")], excerpt: ""))
        XCTAssertEqual(ToolWork.parse(name: "process_manage", arguments: #"{"action":"poll","session_id":"proc_1"}"#, result: #"{"status":"exited","output":"done"}"#),
                       .process(action: "poll", sessionID: "proc_1", status: "exited", output: "done"))
    }

    func testUnknownToolsPrettyPrintInsteadOfBlobs() {
        guard case .generic(let arguments, let result) = ToolWork.parse(name: "mcp__blender__get_scene_info", arguments: #"{"b":1,"a":2}"#, result: #"{"ok":true}"#) else { return XCTFail() }
        XCTAssertEqual(arguments, "{\n  \"a\" : 2,\n  \"b\" : 1\n}")
        XCTAssertEqual(result, "{\n  \"ok\" : true\n}")
        XCTAssertEqual(ToolWork.parse(name: "mystery", arguments: "", result: "plain text"), .generic(arguments: "", result: "plain text"))
    }

    @MainActor func testHistoryToolRowsGainArgumentsFromTheirCall() throws {
        let store = try TranscriptStore(file: nil)
        let recorder = TranscriptRecorder(store: store, agentID: "a") { "Jetson" }
        let history = [
            ChatMessage(id: "1", role: "user", content: "Build it", createdAt: 1),
            ChatMessage(id: "2", role: "tool_calls", content: "", createdAt: 2, toolName: nil,
                        toolCalls: [ToolCallRequest(id: "call-1", name: "terminal", arguments: #"{"command":"make"}"#)]),
            ChatMessage(id: "3", role: "tool", content: #"{"output":"ok","exit_code":0}"#, createdAt: 3, toolName: "terminal", toolCallID: "call-1"),
            ChatMessage(id: "4", role: "assistant", content: "Built.", createdAt: 4),
        ]
        recorder.reconcile(history, sessionID: "s", fallbackTime: 0)
        let rows = try store.entries(SessionAddress(agentID: "a", sessionID: "s"))
        XCTAssertEqual(rows.map(\.shortID), ["1", "3", "4"], "the call-only assistant turn is not a visible row")
        XCTAssertEqual(rows[1].tool?.arguments, #"{"command":"make"}"#)
        XCTAssertEqual(ToolWork.parse(name: "terminal", arguments: rows[1].tool!.arguments, result: rows[1].tool!.result).headline, "make")
    }

    @MainActor func testHermesClientReadsToolCalls() {
        let calls = HermesClient.toolCalls(.array([.object(["id": .string("c1"), "type": .string("function"),
            "function": .object(["name": .string("patch"), "arguments": .string(#"{"path":"/x"}"#)])])]))
        XCTAssertEqual(calls, [ToolCallRequest(id: "c1", name: "patch", arguments: #"{"path":"/x"}"#)])
        XCTAssertEqual(HermesClient.toolCalls(.string(#"[{"id":"c2","function":{"name":"terminal","arguments":"{}"}}]"#)).map(\.name), ["terminal"])
        XCTAssertTrue(HermesClient.toolCalls(nil).isEmpty)
    }
}