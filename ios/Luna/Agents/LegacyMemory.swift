import Foundation

// The pre-transcript `memory.json` snapshot (the latest 12 messages per
// session). It is read once per agent to seed the transcript and never
// written again; TranscriptStore is the only conversation store.

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
}

struct SessionMemory: Codable, Identifiable, Equatable {
    let address: SessionAddress
    var agentName: String
    var title: String
    var updatedAt: Double
    var fetchedAt: Double?
    var messages: [RememberedMessage]
    var id: String { address.id }
}

enum LegacyMemory {
    /// Sessions in a legacy snapshot; empty when the file is absent or unreadable
    /// (the transcript import then relies on the chat cache alone).
    static func sessions(at file: URL) -> [SessionMemory] {
        guard let data = try? Data(contentsOf: file),
              let sessions = try? JSONDecoder().decode([String: SessionMemory].self, from: data) else { return [] }
        return Array(sessions.values)
    }
}
