import Foundation

enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case hermes, openAICompatible
    var id: String { rawValue }
    var label: String { self == .hermes ? "Hermes" : "OpenAI compatible" }
}

struct AgentProfile: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString.lowercased()
    var name: String
    var kind: AgentKind
    var address: String
    var defaultModel: String = ""
    var keyAccount: String { "agent-" + id }
}

struct SessionAddress: Codable, Hashable, Identifiable {
    let agentID: String
    let sessionID: String
    var id: String { agentID + "::" + sessionID }
}

enum LunaRoute: Hashable {
    case agent(String)
    case session(SessionAddress)
}

struct AgentRegistry: Codable {
    var version = 1
    var agents: [AgentProfile]
}

enum AgentFiles {
    static let root = URL.applicationSupportDirectory.appending(path: "Luna/agents")
    static func directory(_ id: String, root: URL = root) -> URL { root.appending(path: id, directoryHint: .isDirectory) }
    static func cache(_ id: String, root: URL = root) -> URL { directory(id, root: root).appending(path: "cache.json") }

    @MainActor static func migrateLegacy(_ profile: AgentProfile, key: String, root: URL = root) throws {
        let old = CacheFile.location(server: profile.address, token: key)
        let destination = cache(profile.id, root: root)
        if !FileManager.default.fileExists(atPath: destination.path), let cache = CacheFile.read(old) {
            try ProtectedFile.write(cache, to: destination)
        }
        let oldRuns = old.deletingPathExtension().appendingPathExtension("runs.json")
        let newRuns = destination.deletingPathExtension().appendingPathExtension("runs.json")
        if !FileManager.default.fileExists(atPath: newRuns.path), FileManager.default.fileExists(atPath: oldRuns.path) {
            try ProtectedFile.write(RunCoordinator.readJournal(oldRuns), to: newRuns)
        }
        let oldModels = SessionModelFile.location(for: old), newModels = SessionModelFile.location(for: destination)
        if !FileManager.default.fileExists(atPath: newModels.path), FileManager.default.fileExists(atPath: oldModels.path) {
            try ProtectedFile.write(SessionModelFile.read(oldModels), to: newModels)
        }
    }
}
