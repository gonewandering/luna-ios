import Foundation

enum HermesResponseFormat {
    static let instructions = """
    Response presentation for Luna: the chat supports Markdown and syntax-highlighted code. When returning source code, shell commands, configuration, or diffs, show the actual content in fenced Markdown code blocks with a language tag such as swift, python, javascript, typescript, json, bash, or diff. Preserve indentation and blank lines. Put filenames and explanations outside the fences. Use unified diff format inside diff fences for patches. Do not replace requested code with a spoken summary: the full result is displayed in chat. If the user requests another output format or an exact response, follow that request instead.
    To deliver photos, videos, or files, return absolute HTTP(S) URLs accessible from the user's phone, including a host's tailnet address and file-server port. Use ![description](<URL>) for photos, [Video: filename](<URL>) for videos, and [File: filename](<URL>) for other files. Local filesystem paths alone are not downloadable. Use an existing file server when available; do not claim a file is accessible unless it is served. Luna retrieves these URLs without the Hermes API key, so use tailnet-accessible or signed links. Videos and files download when tapped.
    """
}

@MainActor protocol AgentBackend: AnyObject {
    var isDemo: Bool { get }
    func capabilities() async throws -> JSONObject
    func sessions(offset: Int) async throws -> SessionPage
    func session(_ id: String) async throws -> AgentSession
    func create(_ title: String) async throws -> AgentSession
    func rename(_ id: String, title: String) async throws -> AgentSession
    func messages(_ id: String, offset: Int) async throws -> HistoryPage
    func submit(_ run: AgentRun) async throws -> String
    func status(_ id: String) async throws -> JSONObject
    func events(_ id: String) -> AsyncThrowingStream<HermesEvent, Error>
    func stop(_ id: String) async throws
    func approve(_ id: String, requestID: String, choice: String) async throws
    func tools() async throws -> JSONObject
    func skills() async throws -> JSONObject
    func models(refresh: Bool) async throws -> HermesModelCatalog
    func setModel(_ selection: HermesModelSelection, sessionID: String) async throws
    func shutdown() async
}

extension AgentBackend { func shutdown() async {} }

@MainActor final class HermesClient: AgentBackend {
    let isDemo = false
    let http: APIClient
    private let photoScope: String
    init(url: URL, key: String, configuration: URLSessionConfiguration = .ephemeral, photoScope: String? = nil) {
        http = APIClient(url: url, token: key, configuration: configuration)
        self.photoScope = photoScope ?? url.absoluteString + "|" + key
    }
    func capabilities() async throws -> JSONObject {
        let value: JSONObject = try await http.call("/v1/capabilities")
        guard value["features"]?.object != nil else {
            throw ServiceError(message: "This address isn't a Hermes HTTP API. Enter your Hermes server address.")
        }
        return value["features"]!.object!
    }
    func sessions(offset: Int = 0) async throws -> SessionPage {
        let value: JSONObject = try await http.call("/api/sessions?offset=\(offset)&limit=50")
        return SessionPage(sessions: try rows(value).map(Self.normalizeSession), has_more: value["has_more"]?.bool ?? false)
    }
    func session(_ id: String) async throws -> AgentSession {
        let value: JSONObject = try await http.call("/api/sessions/\(APIClient.segment(id))")
        guard let row = value["session"]?.object else { throw malformed() }
        return try Self.normalizeSession(row)
    }
    func create(_ title: String) async throws -> AgentSession {
        let value: JSONObject = try await http.call("/api/sessions", method: "POST", body: ["title": .string(title), "source": .string("api_server")])
        guard let row = value["session"]?.object else { throw malformed() }
        return try Self.normalizeSession(row)
    }
    func rename(_ id: String, title: String) async throws -> AgentSession {
        let _: JSONObject = try await http.call("/api/sessions/\(APIClient.segment(id))", method: "PATCH", body: ["title": .string(title)])
        return try await session(id)
    }
    func messages(_ id: String, offset: Int = 0) async throws -> HistoryPage {
        let value: JSONObject = try await http.call("/api/sessions/\(APIClient.segment(id))/messages?offset=\(offset)&limit=100&order=latest")
        let raw = try rows(value)
        let messages = raw.enumerated().compactMap { index, row -> ChatMessage? in
            let role = row["role"]?.string ?? "assistant"
            guard ["user", "assistant", "tool"].contains(role) else { return nil }
            let messageID = row["id"]?.string ?? row["id"]?.number.map { String(Int($0)) } ?? "history-\(offset + index)"
            let photos = ChatPhoto.fromHistory(row["content"], scope: photoScope)
            return ChatMessage(id: messageID, role: role, content: Self.content(row["content"]),
                               createdAt: Self.timestamp(row["timestamp"] ?? row["created_at"]), toolName: row["tool_name"]?.string,
                               photos: photos.isEmpty ? nil : photos)
        }
        return HistoryPage(messages: messages, hasMore: value["has_more"]?.bool ?? (raw.count == 100), resolvedSessionID: value["session_id"]?.string ?? id)
    }
    func submit(_ run: AgentRun) async throws -> String {
        guard run.automaticModel != true || run.modelSelection != nil else {
            throw ServiceError(message: "Auto has not chosen a model for this request.", statusCode: 400)
        }
        // Persisted with admission so retries after an app update have exactly
        // the same payload, including older requests without instructions.
        var body: JSONObject = ["session_id": .string(run.sessionID), "input": .string(run.text)]
        if let photos = run.photos, !photos.isEmpty {
            guard photos.count <= ChatPhoto.maxCount else { throw ServiceError(message: "Attach up to four photos per message.", statusCode: 400) }
            var parts: [JSONValue] = run.text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(run.text)])]
            parts += try photos.map { try $0.contentPart() }
            body["input"] = .array([.object(["role": .string("user"), "content": .array(parts)])])
        }
        if let instructions = run.responseInstructions { body["instructions"] = .string(instructions) }
        if let selection = run.modelSelection {
            body["model"] = .string(selection.model)
            body["provider"] = .string(selection.provider)
        }
        let value: JSONObject = try await http.call("/v1/runs", method: "POST",
            body: body, headers: ["Idempotency-Key": run.id])
        guard let id = value["run_id"]?.string, !id.isEmpty else { throw malformed() }
        return id
    }
    func status(_ id: String) async throws -> JSONObject { try await http.call("/v1/runs/\(APIClient.segment(id))") }
    func events(_ id: String) -> AsyncThrowingStream<HermesEvent, Error> {
        let frames = http.stream("/v1/runs/\(APIClient.segment(id))/events")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in frames {
                        if frame.data == Data("[DONE]".utf8) { continue }
                        let value = try JSONDecoder().decode(JSONObject.self, from: frame.data)
                        continuation.yield(HermesEvent(type: value["type"]?.string ?? value["event"]?.string ?? frame.event, data: value))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func stop(_ id: String) async throws {
        let _: JSONObject = try await http.call("/v1/runs/\(APIClient.segment(id))/stop", method: "POST")
    }
    func approve(_ id: String, requestID: String, choice: String) async throws {
        guard ["once", "deny"].contains(choice) else { throw ServiceError(message: "Invalid approval choice.") }
        let _: JSONObject = try await http.call("/v1/runs/\(APIClient.segment(id))/approval", method: "POST",
            body: ["request_id": .string(requestID), "choice": .string(choice)])
    }
    func tools() async throws -> JSONObject {
        let value: JSONValue = try await http.call("/v1/toolsets")
        return ["toolsets": .array(Self.catalog(value).compactMap { row in
            guard let name = row["name"]?.string else { return nil }
            return .object(["name": .string(name), "description": .string(String((row["description"]?.string ?? "").prefix(500))),
                "enabled": .bool(row["enabled"]?.bool == true), "configured": .bool(row["configured"]?.bool == true),
                "tools": .array((row["tools"]?.array ?? []).filter { $0.string != nil })])
        })]
    }
    func skills() async throws -> JSONObject {
        let value: JSONValue = try await http.call("/v1/skills")
        return ["skills": .array(Self.catalog(value).compactMap { row in
            guard let name = row["name"]?.string else { return nil }
            return .object(["name": .string(name), "description": .string(String((row["description"]?.string ?? "").prefix(500))),
                            "category": .string(row["category"]?.string ?? "")])
        })]
    }
    func models(refresh: Bool = false) async throws -> HermesModelCatalog {
        let value: JSONObject = try await http.call("/api/model/options" + (refresh ? "?refresh=1" : ""))
        return try HermesModelCatalog.parse(value)
    }
    func setModel(_ selection: HermesModelSelection, sessionID: String) async throws {
        let value: JSONObject = try await http.call("/api/sessions/\(APIClient.segment(sessionID))/model", method: "POST",
            body: ["model": .string(selection.model), "provider": .string(selection.provider)])
        guard value["session_id"]?.string == sessionID,
              let runtime = value["runtime"]?.object,
              runtime["model_lock"]?.string == "accepted",
              runtime["model"]?.string == selection.model,
              runtime["provider"]?.string == selection.provider else {
            throw ServiceError(message: "Hermes did not confirm that model for this session. Refresh the model list and try again.")
        }
    }
    private static func catalog(_ value: JSONValue) -> [JSONObject] {
        (value.array ?? value.object?["data"]?.array ?? []).compactMap(\.object)
    }
    private func rows(_ value: JSONObject) throws -> [JSONObject] {
        guard let values = value["data"]?.array else { throw malformed() }
        return values.compactMap(\.object)
    }
    private func malformed() -> ServiceError { ServiceError(message: "Hermes returned an unexpected response. Check its API version.") }
    static func normalizeSession(_ row: JSONObject) throws -> AgentSession {
        guard let id = row["id"]?.string else { throw ServiceError(message: "Hermes returned a session without an ID.") }
        return AgentSession(id: id, title: row["title"]?.string ?? "Untitled session", preview: row["preview"]?.string ?? "",
                            source: row["source"]?.string ?? "Hermes", updatedAt: timestamp(row["last_active"] ?? row["started_at"]),
                            messageCount: Int(row["message_count"]?.number ?? 0), model: row["model"]?.string)
    }
    static func timestamp(_ value: JSONValue?) -> Double {
        if let number = value?.number ?? value?.string.flatMap(Double.init) {
            guard number.isFinite, number >= 0 else { return 0 }
            return number > 100_000_000_000 ? number / 1_000 : number
        }
        guard let text = value?.string else { return 0 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)?.timeIntervalSince1970 ?? 0
    }
    static func content(_ value: JSONValue?) -> String {
        if let text = value?.string { return text }
        if let parts = value?.array {
            return parts.compactMap { part -> String? in
                guard let row = part.object else { return nil }
                if ["text", "output_text", "input_text"].contains(row["type"]?.string ?? "") { return row["text"]?.string }
                return ReceivedAttachment.markdown(row)
            }.joined(separator: "\n\n")
        }
        guard let value, value != .null, let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
