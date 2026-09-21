import Foundation
import Observation

struct RememberedMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: String
    let content: String
    let createdAt: Double
    var approximateTime = false
    var truncated = false
    var partial = false

    init(_ message: ChatMessage, fallbackTime: Double, partial: Bool = false) {
        id = message.id; role = message.role
        content = String(message.content.prefix(6_000))
        truncated = message.content.count > 6_000
        approximateTime = message.createdAt <= 0
        createdAt = message.createdAt > 0 ? message.createdAt : fallbackTime
        self.partial = partial
    }
    var json: JSONObject {
        ["message_id": .string(id), "role": .string(role), "content": .string(content), "timestamp": .number(createdAt),
         "approximate_time": .bool(approximateTime), "truncated": .bool(truncated), "partial": .bool(partial)]
    }
}

struct SessionMemory: Codable, Identifiable, Equatable {
    let address: SessionAddress
    var agentName: String
    var title: String
    var updatedAt: Double
    var fetchedAt: Double?
    var messages: [RememberedMessage]
    var id: String { address.id }
    var json: JSONObject {
        ["agent_id": .string(address.agentID), "agent_name": .string(agentName), "session_id": .string(address.sessionID),
         "title": .string(title), "updated_at": .number(updatedAt), "last_fetched_at": fetchedAt.map(JSONValue.number) ?? .null,
         "source": .string("local_cache"), "messages": .array(messages.map { .object($0.json) }),
         "note": .string("Recent local snapshot; not a complete or live server history. No agent was contacted.")]
    }
}

struct MemoryHit: Identifiable {
    let session: SessionMemory
    let message: RememberedMessage
    var id: String { session.id + "::" + message.id }
    var json: JSONObject {
        var value = message.json
        value["agent_id"] = .string(session.address.agentID)
        value["agent_name"] = .string(session.agentName)
        value["session_id"] = .string(session.address.sessionID)
        value["session_title"] = .string(session.title)
        return value
    }
}

/// Retrieval has no backend dependency. Only explicit sync operations populate it.
@MainActor @Observable final class LocalMemory {
    static let messagesPerSession = 12
    private(set) var sessions: [String: SessionMemory] = [:]
    @ObservationIgnored private let file: URL?

    init(file: URL? = nil) throws {
        self.file = file
        if let file, FileManager.default.fileExists(atPath: file.path) {
            sessions = try JSONDecoder().decode([String: SessionMemory].self, from: Data(contentsOf: file))
        }
    }
    func context(_ address: SessionAddress) -> SessionMemory? { sessions[address.id] }

    func renameAgent(_ id: String, name: String) {
        for key in Array(sessions.keys) where sessions[key]?.address.agentID == id {
            sessions[key]?.agentName = name
        }
    }

    func update(profile: AgentProfile, session: AgentSession, messages: [ChatMessage]?, runs: [AgentRun], fetchedAt: Double?) {
        let address = SessionAddress(agentID: profile.id, sessionID: session.id)
        let old = sessions[address.id]
        var recent = messages.map { rows in
            rows.filter { ["user", "assistant"].contains($0.role) }.map { RememberedMessage($0, fallbackTime: session.updatedAt) }
        } ?? old?.messages ?? []
        for run in runs.sorted(by: { $0.created < $1.created }) {
            if let oldest = recent.first, recent.count >= Self.messagesPerSession && run.created < oldest.createdAt { continue }
            if !recent.contains(where: { $0.role == "user" && $0.content == String(run.text.prefix(6_000)) && ($0.approximateTime || abs($0.createdAt - run.created) < 60) }) {
                recent.append(RememberedMessage(ChatMessage(id: run.id + "-user", role: "user", content: run.text, createdAt: run.created), fallbackTime: run.created))
            }
            if !run.output.isEmpty && !recent.contains(where: { $0.role == "assistant" && $0.content == String(run.output.prefix(6_000)) && ($0.approximateTime || $0.createdAt >= run.created) }) {
                recent.removeAll { $0.id == run.id + "-assistant" }
                recent.append(RememberedMessage(ChatMessage(id: run.id + "-assistant", role: "assistant", content: run.output, createdAt: run.created + 0.001), fallbackTime: run.created,
                                                partial: run.status != "completed"))
            }
        }
        // Keep the source ordering when timestamps are equal or unavailable.
        let ordered = recent.enumerated().sorted {
            $0.element.createdAt == $1.element.createdAt ? $0.offset < $1.offset : $0.element.createdAt < $1.element.createdAt
        }.map(\.element)
        var seen = Set<String>()
        let unique = ordered.reversed().filter { seen.insert($0.id).inserted }.reversed()
        sessions[address.id] = SessionMemory(address: address, agentName: profile.name, title: session.title,
            updatedAt: max(session.updatedAt, runs.map(\.created).max() ?? 0), fetchedAt: fetchedAt ?? old?.fetchedAt,
            messages: Array(unique.suffix(Self.messagesPerSession)))
    }

    func search(_ query: String, agentID: String? = nil, sessionID: String? = nil, after: Double? = nil, before: Double? = nil, limit: Int = 20) -> [MemoryHit] {
        let terms = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        var matches: [MemoryHit] = []
        for session in sessions.values {
            if let agentID, session.address.agentID != agentID { continue }
            if let sessionID, session.address.sessionID != sessionID { continue }
            for message in session.messages {
                if let after, message.createdAt < after { continue }
                if let before, message.createdAt > before { continue }
                let text = Self.fold(session.title + " " + message.content)
                if terms.allSatisfy({ text.contains($0) }) { matches.append(MemoryHit(session: session, message: message)) }
            }
        }
        matches.sort {
            $0.message.createdAt == $1.message.createdAt ? $0.id < $1.id : $0.message.createdAt > $1.message.createdAt
        }
        return Array(matches.prefix(max(1, min(limit, 20))))
    }
    func removeAgent(_ id: String) throws {
        let next = sessions.filter { $0.value.address.agentID != id }
        if let file { try ProtectedFile.write(next, to: file) }
        sessions = next
    }
    func retainAgents(_ ids: Set<String>) { sessions = sessions.filter { ids.contains($0.value.address.agentID) } }
    func save() throws { if let file { try ProtectedFile.write(sessions, to: file) } }
    private static func fold(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
}
