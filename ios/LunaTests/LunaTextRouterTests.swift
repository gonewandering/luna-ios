import XCTest
@testable import Luna

final class LunaTextRouterTests: XCTestCase {
    private func completed(_ output: [JSONValue]) -> JSONObject { ["status": .string("completed"), "output": .array(output)] }
    private func call(_ name: String, _ id: String, _ arguments: JSONObject = [:]) -> JSONValue {
        .object(["type": .string("function_call"), "name": .string(name), "call_id": .string(id),
                 "arguments": .string(String(decoding: try! JSONEncoder().encode(arguments), as: UTF8.self))])
    }
    private func answer(_ text: String) -> JSONObject {
        completed([.object(["type": .string("message"), "role": .string("assistant"),
                            "content": .array([.object(["type": .string("output_text"), "text": .string(text)])])])])
    }

    @MainActor func testStatelessToolContinuationPreservesReasoningAndDeduplicatesMutations() async throws {
        let reasoning: JSONValue = .object(["type": .string("reasoning"), "id": .string("reason"), "summary": .array([]), "encrypted_content": .string("opaque")])
        let args: JSONObject = ["agent_id": .string("B"), "session_id": .string("same"), "prompt": .string("Exactly this prompt")]
        var requests: [JSONObject] = [], executions: [String] = [], ids: [String] = []
        let responses = [completed([reasoning, call("list_agents", "read")]), completed([call("send_prompt", "first", args)]),
                         completed([call("send_prompt", "repeat", args)]), answer("Sent to Research.")]
        let router = LunaTextRouter { body in requests.append(body); return responses[requests.count - 1] }
        let history = (0..<40).map { ChatMessage(id: "\($0)", role: "user", content: String(repeating: "x", count: 4_000), createdAt: Double($0)) }
        let reply = try await router.reply(prompt: "Keep this unchanged", history: history, context: [:], turnID: "turn") { name, _, id in
            executions.append(name); ids.append(id); return ["status": .string("accepted")]
        }
        XCTAssertEqual(reply, "Sent to Research.")
        XCTAssertEqual(executions, ["list_agents", "send_prompt"])
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("text-") && $0.count == 69 })
        XCTAssertEqual(requests[0]["store"], .bool(false)); XCTAssertEqual(requests[0]["model"], .string(OpenAILiveSession.routerModel))
        XCTAssertEqual(requests[0]["parallel_tool_calls"], .bool(false))
        XCTAssertEqual(requests[0]["tools"]?.array?.count, LunaVoiceTools.tools.count)
        let input = try XCTUnwrap(requests[0]["input"]?.array)
        XCTAssertEqual(input.last?.object?["content"], .string("Keep this unchanged"))
        XCTAssertLessThanOrEqual(input.dropLast().compactMap { $0.object?["content"]?.string }.joined().count, 12_000)
        XCTAssertTrue(requests[1]["input"]?.array?.contains(reasoning) == true)
        let outputs = requests[3]["input"]?.array?.compactMap(\.object).filter { $0["type"]?.string == "function_call_output" } ?? []
        XCTAssertEqual(outputs.compactMap { $0["call_id"]?.string }, ["read", "first", "repeat"])
        XCTAssertEqual(outputs[1]["output"], outputs[2]["output"])
    }

    @MainActor func testIncompleteOrMalformedResponseCannotExecuteCommands() async {
        let invalid: [JSONObject] = [
            ["status": .string("incomplete"), "output": .array([call("pause_microphone", "c")])],
            completed([.object(["type": .string("function_call"), "status": .string("in_progress"), "name": .string("pause_microphone"), "call_id": .string("c"), "arguments": .string("{}")])]),
            completed([call("not_a_tool", "c")]),
            completed([.object(["type": .string("function_call"), "name": .string("send_prompt"), "call_id": .string("c"), "arguments": .string("invalid json")])])
        ]
        for response in invalid {
            var executions = 0
            let router = LunaTextRouter { _ in response }
            do { _ = try await router.reply(prompt: "Hello", history: [], context: [:], turnID: "test") { _, _, _ in executions += 1; return [:] }; XCTFail("Invalid output must fail") }
            catch { }
            XCTAssertEqual(executions, 0)
        }
    }

    @MainActor func testConflictingCallIdentityAndRunawayLoopsStop() async {
        var executions = 0, requests = 0
        let router = LunaTextRouter { _ in
            requests += 1
            return self.completed([self.call(requests == 1 ? "list_agents" : "pause_microphone", "reused")])
        }
        do { _ = try await router.reply(prompt: "Search", history: [], context: [:], turnID: "test") { _, _, _ in executions += 1; return [:] }; XCTFail("Conflict must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("conflicting")) }
        XCTAssertEqual(executions, 1)
        requests = 0; executions = 0
        let loop = LunaTextRouter { _ in requests += 1; return self.completed([self.call("list_agents", "read-\(requests)")]) }
        do { _ = try await loop.reply(prompt: "Search", history: [], context: [:], turnID: "test") { _, _, _ in executions += 1; return [:] }; XCTFail("Loop must be bounded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("limit")) }
        XCTAssertEqual(requests, 12); XCTAssertEqual(executions, 12)
    }

    @MainActor func testCancellationAfterNetworkResponsePreventsExecution() async throws {
        var started = false, executions = 0
        let router = LunaTextRouter { _ in
            started = true
            try? await Task.sleep(for: .seconds(10))
            return self.completed([self.call("pause_microphone", "c")])
        }
        let task = Task { try await router.reply(prompt: "Pause", history: [], context: [:], turnID: "cancel") { _, _, _ in executions += 1; return [:] } }
        for _ in 0..<100 { if started { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(started); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled reply must stop") } catch is CancellationError { } catch { XCTFail(error.localizedDescription) }
        XCTAssertEqual(executions, 0)
    }

    @MainActor func testMissingKeyKeepsDraftAndDoesNotStartVoice() {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LunaStore(root: root, loadSavedState: false)
        store.lunaText.draft = "Find my research session"
        store.sendLunaText()
        XCTAssertEqual(store.lunaText.draft, "Find my research session")
        XCTAssertTrue(store.lunaText.messages.isEmpty); XCTAssertFalse(store.lunaText.sending)
        XCTAssertTrue(store.error?.contains("OpenAI API key") == true); XCTAssertFalse(store.voice.isActive)
    }

    @MainActor func testClarificationThenExactRoutingAcrossAgentsWithSameSessionIDs() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LunaStore(root: root, loadSavedState: false)
        await store.startDemo()
        let first = try XCTUnwrap(store.profiles.first), second = try XCTUnwrap(store.profiles.last)
        store.lunaText.destination = SessionAddress(agentID: first.id, sessionID: "demo-luna")
        var requests = 0
        store.makeTextRouter = { _ in LunaTextRouter { body in
            requests += 1
            XCTAssertTrue(body["instructions"]?.string?.contains("browsing_agent_id") == true)
            return self.answer("Which agent and conversation should I use?")
        } }
        store.lunaText.draft = "Continue the plan"
        store.sendLunaText(agentID: first.id); store.sendLunaText(agentID: first.id)
        await settle(store)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(store.lunaText.messages.count, 2)
        XCTAssertTrue(store.runtimes.values.allSatisfy { $0.runs.isEmpty })
        XCTAssertTrue(store.navigation.isEmpty)

        requests = 0
        store.makeTextRouter = { _ in LunaTextRouter { body in
            requests += 1
            if requests == 1 {
                let input = body["input"]?.array?.compactMap(\.object) ?? []
                XCTAssertEqual(input.map { $0["role"]?.string ?? "" }, ["user", "assistant", "user"])
                return self.completed([self.call("send_prompt", "send", ["agent_id": .string(second.id), "session_id": .string("demo-design"), "prompt": .string("Keep the dark interface")])])
            }
            return self.answer("Sent to Research demo, A quieter interface.")
        } }
        store.lunaText.draft = "Use Research demo, A quieter interface: Keep the dark interface"
        store.sendLunaText(agentID: first.id)
        await settle(store)
        let target = SessionAddress(agentID: second.id, sessionID: "demo-design")
        XCTAssertNil(store.error); XCTAssertEqual(store.lunaText.destination, target)
        XCTAssertEqual(store.navigation.last, .session(target)); XCTAssertEqual(store.lunaText.messages.count, 4)
        XCTAssertEqual(store.runtimes[second.id]?.runs.values.first?.text, "Keep the dark interface")
        XCTAssertEqual(store.runtimes[second.id]?.runs.count, 1); XCTAssertTrue(store.runtimes[first.id]?.runs.isEmpty == true)
        XCTAssertFalse(store.voice.isActive)
        for runtime in store.runtimes.values { await runtime.disconnect() }
    }

    @MainActor func testBackgroundCancelsTextBeforeSendingToAgent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LunaStore(root: root, loadSavedState: false)
        var started = false
        store.makeTextRouter = { _ in LunaTextRouter { _ in
            started = true; try await Task.sleep(for: .seconds(10)); return self.answer("Should not arrive")
        } }
        store.lunaText.draft = "Search my sessions"; store.sendLunaText()
        for _ in 0..<100 { if started { break }; try await Task.sleep(for: .milliseconds(5)) }
        await store.sceneChanged(background: true)
        await settle(store)
        XCTAssertNil(store.lunaText.latestReply)
        XCTAssertTrue(store.error?.contains("Luna stopped") == true)
    }

    @MainActor private func settle(_ store: LunaStore) async {
        for _ in 0..<400 { if !store.lunaText.sending { return }; try? await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Typed Luna request did not finish")
    }
}
