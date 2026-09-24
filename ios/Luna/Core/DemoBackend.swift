import Foundation

/// Entirely on-device sample data. No helper, credentials, or real tools.
@MainActor final class DemoBackend: AgentBackend {
    let isDemo = true
    private var state: State
    private let file: URL?
    private var runs: [String: JSONObject] = [:]
    private var runSessions: [String: String] = [:]
    struct State: Codable { var sessions: [AgentSession]; var messages: [String: [ChatMessage]] }
    static let sample = """
    Every request stays with its original session, even when you switch conversations.

    ### The implementation

    ```swift
    struct AgentRequest: Codable {
        let sessionID: String
        let prompt: String
        let requestID: UUID
    }
    ```

    | Component | Responsibility |
    | --- | --- |
    | Luna | Voice, routing, and rich chat |
    | Keychain | Your API keys |
    | Hermes | Agent execution |

    > This is sample content. Connect Hermes to run real tasks.
    """
    init(file: URL? = nil) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(State.self, from: data) {
            state = cached
        } else {
            let now = Date().timeIntervalSince1970
            state = State(sessions: [
                AgentSession(id: "demo-luna", title: "Building Luna", preview: "Voice, sessions, and a place to think.", source: "Demo", updatedAt: now, messageCount: 2),
                AgentSession(id: "demo-design", title: "A quieter interface", preview: "A dark canvas and room for the conversation.", source: "Demo", updatedAt: now-1, messageCount: 1),
                AgentSession(id: "demo-research", title: "Weekend reading", preview: "", source: "Demo", updatedAt: now-2, messageCount: 0)
            ], messages: [
                "demo-luna": [ChatMessage(id: "demo-user", role: "user", content: "How should we connect voice to Hermes?", createdAt: now), ChatMessage(id: "demo-answer", role: "assistant", content: Self.sample, createdAt: now)],
                "demo-design": [ChatMessage(id: "demo-design-answer", role: "assistant", content: "A dark canvas, clear typography, and room to think.\n\n- Keep the conversation in focus\n- Make voice a natural part of chat\n- Keep every task in its own session", createdAt: now)]])
        }
    }
    func capabilities() async throws -> JSONObject {
        ["run_submission": .bool(true), "run_events_sse": .bool(true), "model_options": .bool(true), "session_model_lock": .bool(true), "runs_idempotency": .object(["durable": .bool(false), "retention_seconds": .number(86400)])]
    }
    func sessions(offset: Int) async throws -> SessionPage { SessionPage(sessions: Array(state.sessions.sorted { $0.updatedAt > $1.updatedAt }.dropFirst(offset).prefix(50)), has_more: false) }
    func session(_ id: String) async throws -> AgentSession {
        guard let row = state.sessions.first(where: { $0.id == id }) else { throw ServiceError(message: "Demo session not found.", statusCode: 404) }
        return row
    }
    func create(_ title: String) async throws -> AgentSession {
        let row = AgentSession(id: "demo-" + UUID().uuidString, title: title, preview: "", source: "Demo", updatedAt: Date().timeIntervalSince1970, messageCount: 0)
        state.sessions.insert(row, at: 0); persist(); return row
    }
    func rename(_ id: String, title: String) async throws -> AgentSession {
        _ = try await session(id)
        let index = state.sessions.firstIndex { $0.id == id }!
        state.sessions[index].title = title; persist(); return state.sessions[index]
    }
    func messages(_ id: String, offset: Int) async throws -> HistoryPage {
        let all = state.messages[id] ?? []
        let end = max(0, all.count - offset), start = max(0, end-100)
        return HistoryPage(messages: Array(all[start..<end]), hasMore: start > 0, resolvedSessionID: id)
    }
    func submit(_ run: AgentRun) async throws -> String {
        let id = "demo-run-" + run.id
        guard runs[id] == nil else { return id }
        _ = try await session(run.sessionID)
        runs[id] = ["status": .string("running"), "output": .string("")]
        runSessions[id] = run.sessionID
        append(run.sessionID, role: "user", text: run.text, id: run.id + "-user", photos: run.photos)
        return id
    }
    func status(_ id: String) async throws -> JSONObject { runs[id] ?? ["status": .string("interrupted"), "error": .string("The on-device demo restarted.")] }
    func events(_ id: String) -> AsyncThrowingStream<HermesEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    continuation.yield(HermesEvent(type: "tool.started", data: ["tool": .string("Demo preview"), "preview": .string("Preparing sample content")]))
                    let output = "Here is a **streaming demo response**. Your prompt stayed in this session.\n\n" + Self.sample
                    var remainder = output[...]
                    while !remainder.isEmpty {
                        try await Task.sleep(for: .milliseconds(50))
                        if runs[id]?["status"]?.string == "cancelled" {
                            continuation.yield(HermesEvent(type: "run.cancelled", data: ["status": .string("cancelled")])); continuation.finish(); return
                        }
                        let chunk = String(remainder.prefix(22)); remainder = remainder.dropFirst(chunk.count)
                        let accumulated = (runs[id]?["output"]?.string ?? "") + chunk
                        runs[id]?["output"] = .string(accumulated)
                        continuation.yield(HermesEvent(type: "message.delta", data: ["delta": .string(chunk)]))
                    }
                    if let sid = runSessions[id] { append(sid, role: "assistant", text: output, id: id + "-answer") }
                    runs[id] = ["status": .string("completed"), "output": .string(output)]
                    continuation.yield(HermesEvent(type: "tool.completed", data: ["tool": .string("Demo preview"), "preview": .string("Sample ready")]))
                    continuation.yield(HermesEvent(type: "run.completed", data: runs[id]!)); continuation.finish()
                } catch {
                    if runs[id]?["status"]?.string == "running" {
                        runs[id]?["status"] = .string("interrupted")
                        runs[id]?["error"] = .string("The on-device demo paused. Real Hermes tasks continue on their host.")
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func stop(_ id: String) async throws { runs[id]?["status"] = .string("cancelled") }
    func approve(_ id: String, requestID: String, choice: String) async throws { throw ServiceError(message: "The demo does not request approvals.") }
    func tools() async throws -> JSONObject { ["toolsets": .array([]), "note": .string("On-device demo only; no real tools execute.")] }
    func skills() async throws -> JSONObject { ["skills": .array([])] }
    func models(refresh: Bool) async throws -> HermesModelCatalog {
        HermesModelCatalog(providers: [HermesModelProvider(id: "demo", name: "On-device demo", authenticated: true,
            models: ["demo-balanced", "demo-fast"])], current: HermesModelSelection(provider: "demo", model: "demo-balanced"))
    }
    func setModel(_ selection: HermesModelSelection, sessionID: String) async throws {
        _ = try await session(sessionID)
        guard let index = state.sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        state.sessions[index].model = selection.model
        if let file { try ProtectedFile.write(state, to: file) }
    }
    private func append(_ sid: String, role: String, text: String, id: String, photos: [ChatPhoto]? = nil) {
        guard !(state.messages[sid] ?? []).contains(where: { $0.id == id }) else { return }
        state.messages[sid, default: []].append(ChatMessage(id: id, role: role, content: text, createdAt: Date().timeIntervalSince1970, photos: photos))
        if let index = state.sessions.firstIndex(where: { $0.id == sid }) {
            state.sessions[index].preview = String(text.prefix(140)); state.sessions[index].updatedAt = Date().timeIntervalSince1970
            state.sessions[index].messageCount = state.messages[sid]?.count ?? 0
        }
        persist()
    }
    private func persist() { if let file { try? ProtectedFile.write(state, to: file) } }
}
