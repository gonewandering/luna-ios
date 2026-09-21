import Foundation

struct AgentSession: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var preview: String
    var source: String
    var updatedAt: Double
    var messageCount: Int
    var model: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, title, preview, source, model
        case updatedAt = "updated_at", messageCount = "message_count"
    }
}

struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let role: String
    var content: String
    var createdAt: Double
    var toolName: String?
    enum CodingKeys: String, CodingKey {
        case id, role, content
        case createdAt = "created_at", toolName = "tool_name"
    }
}

enum ConversationHistory {
    /// Add newly fetched messages without replacing content already shown to the
    /// user. Older pages prepend; refresh pages append only genuinely new IDs.
    static func merge(existing: [ChatMessage], incoming: [ChatMessage], older: Bool) -> [ChatMessage] {
        var seen = Set(existing.map(\.id))
        let additions = incoming.filter { seen.insert($0.id).inserted }
        return older ? additions + existing : existing + additions
    }

    /// Reconcile a local run only after history contains its prompt and response
    /// as one plausible pair. Response text by itself is not a run identity.
    static func reconciledRunIDs(runs: [AgentRun], messages: [ChatMessage]) -> [String] {
        var used = Set<Int>(), reconciled: [String] = []
        let candidates = runs.filter { $0.status == "completed" && $0.historyReconciled != true && !$0.output.isEmpty }
            .sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
        for run in candidates {
            var pair: (Int, Int)?
            for userIndex in messages.indices where !used.contains(userIndex) {
                let user = messages[userIndex]
                guard user.role == "user", user.content == run.text, plausible(user, for: run) else { continue }
                var responseIndex = messages.index(after: userIndex)
                while responseIndex < messages.endIndex, messages[responseIndex].role != "user" {
                    let response = messages[responseIndex]
                    if !used.contains(responseIndex), response.role == "assistant", response.content == run.output,
                       plausible(response, for: run) {
                        pair = (userIndex, responseIndex); break
                    }
                    responseIndex = messages.index(after: responseIndex)
                }
                if pair != nil { break }
            }
            if let pair {
                used.insert(pair.0); used.insert(pair.1); reconciled.append(run.id)
            }
        }
        return reconciled
    }

    private static func plausible(_ message: ChatMessage, for run: AgentRun) -> Bool {
        if message.id.contains(run.id) { return true }
        if let upstreamID = run.upstreamID, message.id.contains(upstreamID) { return true }
        guard message.createdAt > 0, run.created > 0 else { return false }
        return message.createdAt >= run.created - 10
    }
}

struct AgentRun: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let text: String
    var status: String
    var output: String
    var error: String?
    let created: Double
    var upstreamID: String? = nil
    var history: [ChatMessage]? = nil
    var stopRequested: Bool? = nil
    var historyReconciled: Bool? = nil
    var responseInstructions: String? = nil
    var modelSelection: HermesModelSelection? = nil
    var automaticModel: Bool? = nil
    var modelDecision: AutoModelDecision? = nil
    var isActive: Bool { !["completed", "cancelled", "failed", "interrupted", "unknown"].contains(status) }
    var hasUnsentPrompt: Bool { upstreamID == nil && ["failed", "cancelled"].contains(status) }
    var statusLabel: String {
        switch status {
        case "queued": "Queued"
        case "choosing_model": "Choosing model"
        case "submitting": "Sending"
        case "running": "Working"
        case "waiting_for_approval": "Needs your approval"
        case "stopping": "Stopping"
        case "completed": "Completed"
        case "cancelled": "Cancelled"
        case "unknown": "Outcome unknown"
        case "interrupted": "Interrupted"
        default: "Failed"
        }
    }
    enum CodingKeys: String, CodingKey {
        case id, text, status, output, error, created, upstreamID, history, stopRequested, historyReconciled, responseInstructions, modelSelection, automaticModel, modelDecision
        case sessionID = "session_id"
    }
}

struct SessionPage: Decodable { let sessions: [AgentSession]; let has_more: Bool }
struct MessagePage: Decodable {
    let messages: [ChatMessage]
    let runs: [AgentRun]
    let has_more: Bool
    let resolved_session_id: String
    let cursor: Int
}
struct RunPage: Decodable { let runs: [AgentRun]; let cursor: Int }
struct ServiceConfig: Decodable { let demo: Bool; let voice_available: Bool; let voice_model: String }
struct VoiceAnswer: Decodable { let voice_id: String; let session_id: String; let sdp: String }

enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    func decoded<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(type, from: JSONEncoder().encode(self)) }
}

struct StreamEvent: Codable, Sendable {
    let cursor: Int
    let type: String
    let sessionID: String?
    let requestID: String?
    let payload: [String: JSONValue]
    enum CodingKeys: String, CodingKey {
        case cursor, type, payload
        case sessionID = "session_id", requestID = "request_id"
    }
}

struct Activity: Identifiable, Equatable {
    let id: String
    let title: String
    var detail: String
    var finished: Bool
    var failed: Bool
    var runID: String? = nil
}

struct PendingApproval: Identifiable {
    let id: String
    let runID: String
    let sessionID: String
    let description: String
}


extension JSONValue {
    var object: JSONObject? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

struct HermesEvent: Sendable {
    let type: String
    let data: JSONObject
}
struct HistoryPage: Sendable {
    let messages: [ChatMessage]
    let hasMore: Bool
    let resolvedSessionID: String
}
