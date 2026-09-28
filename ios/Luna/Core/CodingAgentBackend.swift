import Foundation

/// Claude, Grok and Codex are interchangeable alternatives for coding work.
/// None of them is compiled in as the choice: each is matched against the
/// providers Hermes reports as authenticated, and the caller's request or the
/// session's own history decides which available one runs.
enum CodingAgentBackend: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, grok, codex
    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: "Claude"
        case .grok: "Grok"
        case .codex: "Codex"
        }
    }
    var sessionTitle: String { "Coding · " + label }

    /// Model-name fragments that identify this backend's models.
    private var modelHints: [String] {
        switch self {
        case .claude: ["claude"]
        case .grok: ["grok"]
        case .codex: ["codex"]
        }
    }
    /// Providers that serve only this family, so an unfamiliar model name still
    /// belongs to it. A shared provider such as `openai` is deliberately absent:
    /// Codex needs a Codex model, not any model that account can reach.
    private var dedicatedProviders: [String] {
        switch self {
        case .claude: ["anthropic", "claude", "claude-code"]
        case .grok: ["xai", "x-ai", "grok"]
        case .codex: ["codex"]
        }
    }
    private static let lightweightHints = ["mini", "nano", "haiku", "flash", "lite", "small", "fast"]

    func matches(_ selection: HermesModelSelection) -> Bool {
        let model = selection.model.lowercased(), provider = selection.provider.lowercased()
        if modelHints.contains(where: model.contains) { return true }
        return dedicatedProviders.contains(provider)
    }

    /// Hints only; Luna never claims a price or a guaranteed capability.
    static func lightweight(_ model: String) -> Bool {
        let name = model.lowercased()
        return lightweightHints.contains(where: name.contains)
    }

    static func named(_ value: String?) -> Self? {
        guard let value, !value.isEmpty else { return nil }
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.first { $0.rawValue == name || $0.label.lowercased() == name }
    }
}

/// A resolved coding backend and the exact provider/model it will run as.
struct CodingAgentChoice: Equatable, Sendable {
    let backend: CodingAgentBackend
    let selection: HermesModelSelection
}

@MainActor enum CodingAgentResolver {
    /// Every coding backend Hermes can currently run, in a stable preference
    /// order within each backend. Providers that are not authenticated, and
    /// models that cannot call tools, never appear.
    static func alternatives(in catalog: HermesModelCatalog) -> [CodingAgentBackend: [HermesModelSelection]] {
        let candidates = AutoModelRouter.candidates(in: catalog)
        var result: [CodingAgentBackend: [HermesModelSelection]] = [:]
        for backend in CodingAgentBackend.allCases {
            let matches = candidates.filter(backend.matches).sorted { first, second in
                let rank = (order(first, in: catalog), order(second, in: catalog))
                return rank.0 == rank.1 ? first.id < second.id : rank.0 < rank.1
            }
            if !matches.isEmpty { result[backend] = matches }
        }
        return result
    }
    private static func order(_ selection: HermesModelSelection, in catalog: HermesModelCatalog) -> Int {
        if catalog.current == selection { return 0 }
        let model = selection.model.lowercased()
        return CodingAgentBackend.lightweight(model) ? 2 : 1
    }

    static func available(in catalog: HermesModelCatalog) -> [CodingAgentBackend] {
        let alternatives = alternatives(in: catalog)
        return CodingAgentBackend.allCases.filter { alternatives[$0] != nil }
    }

    /// Resolve which of the three runs this request. An explicit request wins; a
    /// session that already has a coding backend keeps it; otherwise Luna prefers
    /// the server's current provider and then the declared order. Selection is
    /// never hard-coded to one backend.
    static func resolve(requested: CodingAgentBackend? = nil, remembered: CodingAgentBackend? = nil,
                        in catalog: HermesModelCatalog) throws -> CodingAgentChoice {
        let alternatives = alternatives(in: catalog)
        let available = CodingAgentBackend.allCases.filter { alternatives[$0] != nil }
        guard !available.isEmpty else {
            throw ServiceError(message: "This agent reports no Claude, Grok, or Codex model. Authenticate one of those providers in Hermes, refresh the model list, and try again.")
        }
        if let requested {
            guard let models = alternatives[requested], let selection = models.first else {
                throw ServiceError(message: "\(requested.label) isn’t available on this agent. Available coding agents: " + available.map(\.label).joined(separator: ", ") + ".")
            }
            return CodingAgentChoice(backend: requested, selection: selection)
        }
        if let remembered, let selection = alternatives[remembered]?.first {
            return CodingAgentChoice(backend: remembered, selection: selection)
        }
        if let provider = catalog.current?.provider {
            for backend in available {
                if let selection = alternatives[backend]?.first(where: { $0.provider == provider }) {
                    return CodingAgentChoice(backend: backend, selection: selection)
                }
            }
        }
        let backend = available[0]
        return CodingAgentChoice(backend: backend, selection: alternatives[backend]![0])
    }
}

/// One remembered Hermes session per agent and backend, so coding work reuses a
/// conversation instead of opening a new one for every request.
struct CodingSessionRecord: Codable, Equatable, Sendable {
    let backend: CodingAgentBackend
    var sessionID: String
    var selection: HermesModelSelection
    var createdAt: Double
    var lastUsedAt: Double
}

struct CodingSessionRegistry: Codable, Equatable, Sendable {
    var version = 1
    /// Keyed by `CodingAgentBackend.rawValue`.
    var sessions: [String: CodingSessionRecord] = [:]

    subscript(backend: CodingAgentBackend) -> CodingSessionRecord? {
        get { sessions[backend.rawValue] }
        set { sessions[backend.rawValue] = newValue }
    }
}

enum CodingSessionFile {
    static func location(for cache: URL) -> URL {
        cache.deletingPathExtension().appendingPathExtension("coding.json")
    }
    static func read(_ file: URL) throws -> CodingSessionRegistry {
        guard FileManager.default.fileExists(atPath: file.path) else { return CodingSessionRegistry() }
        let registry = try JSONDecoder().decode(CodingSessionRegistry.self, from: Data(contentsOf: file))
        guard registry.version == 1 else { throw ServiceError(message: "Unsupported coding session file.") }
        // Drop rows whose key no longer names its backend, so a renamed or
        // hand-edited file cannot route work to the wrong coding agent.
        var checked = registry
        checked.sessions = registry.sessions.filter { $0.key == $0.value.backend.rawValue && !$0.value.sessionID.isEmpty }
        return checked
    }
}

/// The result of delegating coding work: which of the three backends runs it,
/// the Hermes session it reused or created, and the admitted request.
struct CodingTaskStart: Sendable {
    let run: AgentRun
    let choice: CodingAgentChoice
    let sessionID: String
    let reusedSession: Bool
    let available: [CodingAgentBackend]
    let modelLockNote: String?
}
