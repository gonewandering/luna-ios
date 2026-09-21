import Foundation

/// Chat Completions supplies generation, not a remote session/run service.
/// Luna owns the transcript and never replays an interrupted network request.
@MainActor final class CompatibleAgentClient: AgentBackend {
    let isDemo = false
    private let http: APIClient
    private let prefix: String
    private let file: URL
    private let defaultModel: String
    private let name: String
    private var state: State
    private var streams: [String: Task<Void, Never>] = [:]
    private var modelIDs: [String] = []

    struct State: Codable {
        var sessions: [AgentSession] = []
        var messages: [String: [ChatMessage]] = [:]
        var requests: [String: AgentRun] = [:]
    }

    init(url: URL, key: String, name: String, defaultModel: String, file: URL, configuration: URLSessionConfiguration = .ephemeral) throws {
        http = APIClient(url: url, token: key, label: name, configuration: configuration)
        prefix = url.lastPathComponent == "v1" ? "" : "/v1"
        self.name = name; self.defaultModel = defaultModel; self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
        } else { state = State() }
        for id in state.requests.keys where state.requests[id]?.isActive == true {
            state.requests[id]?.status = "interrupted"
            state.requests[id]?.error = "The connection ended before the reply finished. This endpoint cannot resume a remote task."
        }
        try ProtectedFile.write(state, to: file)
    }
    func capabilities() async throws -> JSONObject {
        _ = try await models(refresh: true)
        return ["run_submission": .bool(true), "run_events_sse": .bool(true), "session_model_lock": .bool(true),
                "local_sessions": .bool(true), "runs_idempotency": .object(["durable": .bool(false), "retention_seconds": .number(0)])]
    }
    func sessions(offset: Int) async throws -> SessionPage {
        let rows = state.sessions.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        return SessionPage(sessions: Array(rows.dropFirst(offset).prefix(50)), has_more: offset + 50 < rows.count)
    }
    func session(_ id: String) async throws -> AgentSession {
        guard let row = state.sessions.first(where: { $0.id == id }) else { throw ServiceError(message: "This agent has no session with that ID.", statusCode: 404) }
        return row
    }
    func create(_ title: String) async throws -> AgentSession {
        let row = AgentSession(id: UUID().uuidString.lowercased(), title: title, preview: "", source: name,
                               updatedAt: Date().timeIntervalSince1970, messageCount: 0, model: defaultModel.isEmpty ? nil : defaultModel)
        try change { $0.sessions.append(row) }; return row
    }
    func rename(_ id: String, title: String) async throws -> AgentSession {
        _ = try await session(id)
        try change { state in if let index = state.sessions.firstIndex(where: { $0.id == id }) { state.sessions[index].title = title } }
        return try await session(id)
    }
    func messages(_ id: String, offset: Int) async throws -> HistoryPage {
        _ = try await session(id)
        let rows = state.messages[id] ?? [], end = max(0, (state.messages[id]?.count ?? 0) - offset)
        let start = max(0, end - 100)
        return HistoryPage(messages: Array(rows[start..<end]), hasMore: start > 0, resolvedSessionID: id)
    }
    func models(refresh: Bool) async throws -> HermesModelCatalog {
        if refresh || modelIDs.isEmpty {
            let result: JSONObject = try await http.call(prefix + "/models")
            guard let data = result["data"]?.array else { throw ServiceError(message: "The agent did not return a compatible model list.") }
            modelIDs = Array(Set(data.compactMap { $0.object?["id"]?.string }.filter { !$0.isEmpty })).sorted()
        }
        return HermesModelCatalog(providers: [HermesModelProvider(id: "compatible", name: name, authenticated: true, models: modelIDs)],
                                  current: defaultModel.isEmpty ? nil : HermesModelSelection(provider: "compatible", model: defaultModel))
    }
    func setModel(_ selection: HermesModelSelection, sessionID: String) async throws {
        guard selection.provider == "compatible", modelIDs.contains(selection.model) else { throw ServiceError(message: "Refresh the model list and choose an available model.") }
        _ = try await session(sessionID)
        try change { state in if let index = state.sessions.firstIndex(where: { $0.id == sessionID }) { state.sessions[index].model = selection.model } }
    }
    func submit(_ run: AgentRun) async throws -> String {
        if let previous = state.requests[run.id] {
            guard previous.sessionID == run.sessionID, previous.text == run.text else { throw ServiceError(message: "That request ID belongs to a different task.", statusCode: 409) }
            return run.id
        }
        let session = try await session(run.sessionID)
        let model = run.modelSelection?.model ?? session.model ?? defaultModel
        guard !model.isEmpty else { throw ServiceError(message: "Choose a model for this agent or session before sending a prompt.", statusCode: 400) }
        guard run.automaticModel != true || run.modelSelection != nil else { throw ServiceError(message: "Auto has not chosen a model.", statusCode: 400) }
        var request = run
        request.modelSelection = HermesModelSelection(provider: "compatible", model: model)
        request.status = "running"
        request.history = Array((run.history ?? []).filter { ["user", "assistant"].contains($0.role) }.suffix(24))
        try change { state in
            state.requests[run.id] = request
            Self.append(&state, sid: run.sessionID, message: ChatMessage(id: run.id + "-user", role: "user", content: run.text, createdAt: run.created))
        }
        return run.id
    }
    func status(_ id: String) async throws -> JSONObject {
        guard let run = state.requests[id] else { throw ServiceError(message: "This local task could not be found.", statusCode: 404) }
        return ["status": .string(run.status), "output": .string(run.output), "error": run.error.map(JSONValue.string) ?? .null]
    }
    func events(_ id: String) -> AsyncThrowingStream<HermesEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                defer { streams.removeValue(forKey: id) }
                do {
                    try Task.checkCancellation()
                    guard let run = state.requests[id] else { throw ServiceError(message: "The task is missing.") }
                    if !run.isActive {
                        continuation.yield(HermesEvent(type: "run." + run.status, data: try await status(id)))
                        continuation.finish(); return
                    }
                    let body = Self.requestBody(run)
                    var ended = false
                    for try await frame in http.stream(prefix + "/chat/completions", method: "POST", body: body) {
                        try Task.checkCancellation()
                        if frame.data == Data("[DONE]".utf8) { ended = true; break }
                        let value = try JSONDecoder().decode(JSONObject.self, from: frame.data)
                        guard value["error"] == nil else { throw ServiceError(message: "The agent returned a generation error. Check its configuration and try again.") }
                        guard let choice = value["choices"]?.array?.first?.object else { continue }
                        if let delta = choice["delta"]?.object?["content"]?.string, !delta.isEmpty {
                            state.requests[id]?.output += delta
                            continuation.yield(HermesEvent(type: "message.delta", data: ["delta": .string(delta)]))
                        }
                        if let reason = choice["finish_reason"]?.string {
                            guard reason == "stop" else {
                                throw ServiceError(message: reason == "length" ? "The reply reached the model’s output limit." :
                                    reason == "tool_calls" ? "This endpoint returned a tool call. It must execute its own agent tools before returning a chat response." : "The agent ended the reply without completing it.")
                            }
                            ended = true
                            break
                        }
                    }
                    try Task.checkCancellation()
                    guard ended else { throw ServiceError(message: "The stream ended before the agent confirmed completion.") }
                    try finish(id, status: "completed")
                } catch {
                    if state.requests[id]?.isActive == true {
                        do { try finish(id, status: error is CancellationError ? "interrupted" : "failed",
                            error: error is CancellationError ? "The stream was interrupted. Send a new prompt to continue." : error.localizedDescription) }
                        catch {
                            state.requests[id]?.status = "failed"
                            state.requests[id]?.error = "Luna couldn't save the reply on this device. Check available storage."
                            continuation.finish(throwing: error); return
                        }
                    }
                }
                if let run = state.requests[id] {
                    continuation.yield(HermesEvent(type: "run." + run.status, data: ["status": .string(run.status), "output": .string(run.output), "error": run.error.map(JSONValue.string) ?? .null]))
                }
                continuation.finish()
            }
            streams[id] = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    static func requestBody(_ run: AgentRun) -> JSONObject {
        var messages: [JSONValue] = []
        if let instructions = run.responseInstructions { messages.append(.object(["role": .string("system"), "content": .string(instructions)])) }
        var budget = 48_000
        let history = (run.history ?? []).reversed().compactMap { message -> ChatMessage? in
            guard ["user", "assistant"].contains(message.role), message.content.count <= budget else { return nil }
            budget -= message.content.count; return message
        }.reversed()
        messages += history.map { .object(["role": .string($0.role), "content": .string($0.content)]) }
        messages.append(.object(["role": .string("user"), "content": .string(run.text)]))
        return ["model": .string(run.modelSelection?.model ?? ""), "messages": .array(messages), "stream": .bool(true)]
    }
    func stop(_ id: String) async throws {
        guard state.requests[id]?.isActive == true else { return }
        try finish(id, status: "cancelled", error: "Reply stopped on this device. Check the agent if you need to confirm that remote work stopped.")
        streams[id]?.cancel()
    }
    func shutdown() async {
        let tasks = Array(streams.values)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
    }
    func approve(_ id: String, requestID: String, choice: String) async throws { throw ServiceError(message: "This connector does not support remote approvals.") }
    func tools() async throws -> JSONObject { ["tools": .array([]), "note": .string("Chat Completions does not expose a server tool catalog. Tool execution belongs to the endpoint.")] }
    func skills() async throws -> JSONObject { ["skills": .array([]), "note": .string("This connector has no skills catalog.")] }

    private func finish(_ id: String, status: String, error: String? = nil) throws {
        try change { state in
            guard var run = state.requests[id] else { return }
            run.status = status; run.error = error; run.history = nil
            state.requests[id] = run
            if status == "completed", !run.output.isEmpty {
                Self.append(&state, sid: run.sessionID, message: ChatMessage(id: run.id + "-assistant", role: "assistant", content: run.output, createdAt: Date().timeIntervalSince1970))
            }
        }
    }
    private func change(_ update: (inout State) -> Void) throws {
        var next = state; update(&next)
        try ProtectedFile.write(next, to: file); state = next
    }
    private static func append(_ state: inout State, sid: String, message: ChatMessage) {
        guard !(state.messages[sid] ?? []).contains(where: { $0.id == message.id }) else { return }
        state.messages[sid, default: []].append(message)
        if let index = state.sessions.firstIndex(where: { $0.id == sid }) {
            state.sessions[index].preview = String(message.content.prefix(140))
            state.sessions[index].updatedAt = message.createdAt
            state.sessions[index].messageCount = state.messages[sid]?.count ?? 0
        }
    }
}
