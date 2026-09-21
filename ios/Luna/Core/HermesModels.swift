import Foundation

/// Provider is part of the identity: the same model can use different accounts.
struct HermesModelSelection: Codable, Hashable, Sendable, Identifiable {
    let provider: String
    let model: String
    var id: String { provider + ":" + model }
}

struct HermesModelProvider: Identifiable, Sendable {
    let id: String
    let name: String
    let authenticated: Bool
    let models: [String]
    var capabilities: [String: JSONObject] = [:]
}

struct HermesModelCatalog: Sendable {
    let providers: [HermesModelProvider]
    let current: HermesModelSelection?

    var availableProviders: [HermesModelProvider] {
        providers.filter { $0.authenticated && !$0.models.isEmpty }
    }
    func contains(_ selection: HermesModelSelection) -> Bool {
        availableProviders.contains { $0.id == selection.provider && $0.models.contains(selection.model) }
    }
    func providerName(_ slug: String) -> String {
        providers.first { $0.id == slug }?.name ?? slug
    }

    static func parse(_ value: JSONObject) throws -> Self {
        guard let rows = value["providers"]?.array else {
            throw ServiceError(message: "Hermes returned an unreadable model list. Update Hermes and try again.")
        }
        var seenProviders = Set<String>()
        let providers = rows.compactMap { value -> HermesModelProvider? in
            guard let row = value.object, let slug = row["slug"]?.string, !slug.isEmpty,
                  seenProviders.insert(slug).inserted else { return nil }
            var seenModels = Set<String>()
            let models = (row["models"]?.array ?? []).compactMap { item -> String? in
                let model = item.string ?? item.object?["id"]?.string
                guard let model, !model.isEmpty, seenModels.insert(model).inserted else { return nil }
                return model
            }
            return HermesModelProvider(id: slug, name: row["name"]?.string ?? slug,
                authenticated: row["authenticated"]?.bool == true, models: models,
                capabilities: (row["capabilities"]?.object ?? [:]).compactMapValues { value in
                    value.object?.filter { ["reasoning", "tool_calling", "vision"].contains($0.key) && $0.value.bool != nil }
                })
        }
        let current: HermesModelSelection?
        if let model = value["model"]?.string, !model.isEmpty,
           let provider = value["provider"]?.string, !provider.isEmpty {
            current = HermesModelSelection(provider: provider, model: model)
        } else { current = nil }
        return Self(providers: providers, current: current)
    }
}

enum SessionModelPreference: Codable, Equatable, Sendable {
    case automatic
    case manual(HermesModelSelection)

    private enum CodingKeys: String, CodingKey { case mode }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let mode = try container.decodeIfPresent(String.self, forKey: .mode) {
            guard mode == "auto" else {
                throw DecodingError.dataCorruptedError(forKey: .mode, in: container, debugDescription: "Unknown model mode")
            }
            self = .automatic
        } else {
            // Manual entries retain the original on-disk provider/model shape.
            self = .manual(try HermesModelSelection(from: decoder))
        }
    }
    func encode(to encoder: Encoder) throws {
        switch self {
        case .automatic:
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("auto", forKey: .mode)
        case .manual(let selection): try selection.encode(to: encoder)
        }
    }
    var selection: HermesModelSelection? {
        if case .manual(let value) = self { return value }
        return nil
    }
}

enum SessionModelFile {
    static func location(for cache: URL) -> URL {
        cache.deletingPathExtension().appendingPathExtension("models.json")
    }
    static func read(_ file: URL) throws -> [String: SessionModelPreference] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: SessionModelPreference].self, from: Data(contentsOf: file))
    }
}
