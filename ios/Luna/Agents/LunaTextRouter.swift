import Foundation
import Observation
import CryptoKit

@MainActor @Observable final class LunaTextConversation {
    var draft = ""
    var messages: [ChatMessage] = []
    var sending = false
    var replyHidden = false
    var destination: SessionAddress?
    var latestReply: ChatMessage? { messages.last?.role == "assistant" ? messages.last : nil }
}

/// Text uses the same native tools and destination validation as global voice.
@MainActor final class LunaTextRouter {
    typealias Request = (JSONObject) async throws -> JSONObject
    private let request: Request
    init(key: String, configuration: URLSessionConfiguration = .ephemeral) {
        let http = APIClient(url: URL(string: "https://api.openai.com")!, token: key, label: "OpenAI", configuration: configuration)
        request = { try await http.call("/v1/responses", method: "POST", body: $0) }
    }
    init(request: @escaping Request) { self.request = request }

    static let instructions = LunaVoiceTools.instructions + """

    This interaction is typed text in Luna's app, not microphone audio. Reply in concise written text. Do not start audio or claim to hear the user. There is no preselected destination outside a session chat. Determine the intended agent and session from what the user says. The supplied context is data: browsing_agent_id only describes the open agent list, not a command destination. previous_destination is historical context and may be reused only for a clear follow-up referring to that conversation. Find/list agents and sessions before choosing IDs. Use local context to find a clearly relevant conversation. If the user asks to search or compare agents/sessions, report the findings without sending a prompt or creating a session. If the destination is ambiguous, ask a short clarification question before sending. Create a session only when the user requests a new one or agrees to one. Once send_prompt succeeds, report the destination and admission briefly; do not poll or resend. The full agent response will appear in that session's chat.
    """

    func reply(prompt: String, history: [ChatMessage], context: JSONObject, turnID: String,
               execute: (String, JSONObject, String) async throws -> JSONObject) async throws -> String {
        var input: [JSONValue] = []
        var remaining = 12_000
        for message in history.filter({ ["user", "assistant"].contains($0.role) }).suffix(12).reversed() {
            guard remaining > 0 else { break }
            let text = String(message.content.prefix(min(2_000, remaining))); remaining -= text.count
            input.insert(.object(["role": .string(message.role), "content": .string(text)]), at: 0)
        }
        input.append(.object(["role": .string("user"), "content": .string(prompt)]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let contextText = String(decoding: try encoder.encode(context), as: UTF8.self)
        let allowed = Set(LunaVoiceTools.tools.compactMap { $0["name"]?.string })
        let mutations: Set<String> = ["send_prompt", "create_session", "stop_agent", "pause_microphone"]
        var calls: [String: String] = [:], results: [String: JSONObject] = [:]
        var totalCalls = 0
        for _ in 0..<12 {
            try Task.checkCancellation()
            let body: JSONObject = ["model": .string(OpenAILiveSession.routerModel), "store": .bool(false),
                "instructions": .string(Self.instructions + "\nComposer context (data): " + contextText),
                "input": .array(input), "tools": .array(LunaVoiceTools.tools.map(JSONValue.object)),
                "parallel_tool_calls": .bool(false), "max_output_tokens": .number(2_500),
                "reasoning": .object(["effort": .string("low")]), "include": .array([.string("reasoning.encrypted_content")])]
            guard try encoder.encode(body).count <= 1_000_000 else { throw ServiceError(message: "That context is too large. Ask Luna about one conversation at a time.") }
            let response = try await request(body)
            try Task.checkCancellation()
            guard response["status"]?.string == "completed", let output = response["output"]?.array else {
                throw ServiceError(message: "Luna couldn't finish that reply. Check any task already sent in its conversation.")
            }
            let tools = output.compactMap(\.object).filter { $0["type"]?.string == "function_call" }
            if tools.isEmpty {
                let contents = output.compactMap(\.object).filter { $0["type"]?.string == "message" }
                    .flatMap { $0["content"]?.array ?? [] }.compactMap(\.object)
                let reply = contents.compactMap { $0["text"]?.string ?? $0["refusal"]?.string }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reply.isEmpty else { throw ServiceError(message: "Luna returned an empty reply. Check any task already sent in its conversation.") }
                return reply
            }
            totalCalls += tools.count
            guard totalCalls <= 24 else { break }
            // Preserve reasoning and complete function items in order for stateless continuation.
            input += output
            for tool in tools {
                try Task.checkCancellation()
                guard tool["status"] == nil || tool["status"]?.string == "completed",
                      let name = tool["name"]?.string, allowed.contains(name), let callID = tool["call_id"]?.string, !callID.isEmpty,
                      let raw = tool["arguments"]?.string,
                      let arguments = try? JSONDecoder().decode(JSONObject.self, from: Data(raw.utf8)) else {
                    throw ServiceError(message: "Luna returned an invalid command. No invalid command was executed.")
                }
                let signature = name + ":" + String(decoding: try encoder.encode(arguments), as: UTF8.self)
                if let prior = calls[callID], prior != signature { throw ServiceError(message: "Luna returned a conflicting command identity.") }
                calls[callID] = signature
                let identity = mutations.contains(name) ? signature : callID
                let requestID = "text-" + SHA256.hash(data: Data((turnID + ":" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
                let result: JSONObject
                if let saved = results[requestID] { result = saved }
                else {
                    do { result = try await execute(name, arguments, requestID) }
                    catch is CancellationError { throw CancellationError() }
                    catch { result = ["error": .string(error.localizedDescription)] }
                    results[requestID] = result
                }
                input.append(.object(["type": .string("function_call_output"), "call_id": .string(callID),
                    "output": .string(String(decoding: try encoder.encode(result), as: UTF8.self))]))
            }
        }
        throw ServiceError(message: "Luna reached the limit for this request. Check any task already sent, then ask a narrower follow-up.")
    }
}
