import Foundation

/// Owns local admission, per-session queues, and recovery. Closing the app never
/// sends a stop to Hermes. Persist each admission before any network side effect.
@MainActor final class RunCoordinator {
    private(set) var records: [String: AgentRun]
    private(set) var paused = true
    var onRun: ((AgentRun) -> Void)?
    var onEvent: ((String, String, HermesEvent) -> Void)?
    var onFinished: ((AgentRun) -> Void)?
    var onError: ((String) -> Void)?
    private let backend: any AgentBackend
    private let features: JSONObject
    private let selectModel: ((AgentRun) async throws -> AutoModelDecision)?
    private let persist: ([String: AgentRun]) throws -> Void
    private var tasks: [String: Task<Void, Never>] = [:]

    init(backend: any AgentBackend, features: JSONObject, records: [String: AgentRun] = [:],
         selectModel: ((AgentRun) async throws -> AutoModelDecision)? = nil, persist: @escaping ([String: AgentRun]) throws -> Void) {
        self.backend = backend; self.features = features; self.records = records; self.persist = persist; self.selectModel = selectModel
    }
    static func readJournal(_ file: URL) throws -> [String: AgentRun] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: AgentRun].self, from: Data(contentsOf: file))
    }
    func admit(id: String, sessionID: String, text: String, model: HermesModelSelection? = nil, automaticModel: Bool = false, photos: [ChatPhoto] = []) async throws -> AgentRun {
        if let record = records[id] {
            guard record.text == text && record.sessionID == sessionID && (record.photos ?? []) == photos else { throw ServiceError(message: "That request ID belongs to another prompt.", statusCode: 409) }
            return record
        }
        guard !paused else { throw ServiceError(message: "Reconnect Hermes before sending a prompt.") }
        guard !automaticModel || (model == nil && selectModel != nil) else {
            throw ServiceError(message: "Auto model selection isn't ready. Reconnect or choose a model manually.")
        }
        guard features["run_submission"]?.bool == true, features["run_events_sse"]?.bool == true else {
            throw ServiceError(message: "This Hermes version needs the Runs streaming API. Update Hermes before submitting work.")
        }
        guard !text.isEmpty || !photos.isEmpty, text.count <= 32000 else { throw ServiceError(message: "Enter a prompt of up to 32,000 characters or attach a photo.") }
        guard photos.count <= ChatPhoto.maxCount else { throw ServiceError(message: "Attach up to four photos per message.") }
        for photo in photos { _ = try photo.data() }
        guard records.values.filter(\.isActive).count < 30 else { throw ServiceError(message: "Wait for some queued tasks to finish.") }
        guard !records.values.contains(where: { $0.sessionID == sessionID && $0.status == "unknown" && $0.historyReconciled != true }) else {
            throw ServiceError(message: "A previous task has an unknown outcome. Check its conversation before sending more work.")
        }
        // Do not await between checking the ID and recording admission.
        var record = AgentRun(id: id, sessionID: sessionID, text: text, status: "queued", output: "", created: Date().timeIntervalSince1970)
        record.responseInstructions = HermesResponseFormat.instructions
        record.photos = photos.isEmpty ? nil : photos
        record.modelSelection = model
        record.automaticModel = automaticModel ? true : nil
        try commit(record)
        schedule()
        return record
    }
    func resume() { paused = false; schedule() }
    func pause() {
        paused = true
        tasks.values.forEach { $0.cancel() }
        // Keep task ownership until cancellation has unwound, so a rapid resume
        // cannot start another consumer for the same run.
    }
    func suspend() async {
        pause()
        let running = Array(tasks.values)
        for task in running { await task.value }
    }
    @discardableResult func markReconciled(_ ids: [String]) -> Bool {
        do {
            for id in ids {
                guard var run = records[id], !run.isActive else { continue }
                run.historyReconciled = true
                try commit(run)
            }
            schedule()
            return true
        } catch {
            onError?("Luna couldn't save conversation reconciliation. The local messages will remain visible.")
            return false
        }
    }
    func stop(_ id: String) async throws {
        guard var run = records[id], run.isActive else { return }
        run.stopRequested = true
        if ["queued", "choosing_model"].contains(run.status) { run.status = "cancelled" }
        try commit(run)
        if !run.isActive { tasks[id]?.cancel(); onFinished?(run) }
        if let remoteID = run.upstreamID {
            try await backend.stop(remoteID)
            if var current = records[id], current.isActive {
                current.status = "stopping"; try commit(current)
            }
        }
        schedule()
    }
    func approve(_ id: String, requestID: String, choice: String) async throws {
        guard let run = records[id], let remoteID = run.upstreamID, run.isActive else { throw ServiceError(message: "This run is no longer waiting for approval.") }
        try await backend.approve(remoteID, requestID: requestID, choice: choice)
    }
    private func commit(_ run: AgentRun, durable: Bool = true) throws {
        var next = records; next[run.id] = run
        if durable { try persist(next) }
        records = next; onRun?(run)
    }
    private func schedule() {
        guard !paused else { return }
        let busy = Set(tasks.keys.compactMap { records[$0]?.sessionID })
        let unresolved = Set(records.values.filter { $0.status == "unknown" && $0.historyReconciled != true }.map(\.sessionID))
        let sessions = Set(records.values.filter(\.isActive).map(\.sessionID)).subtracting(busy).subtracting(unresolved)
        for sid in sessions {
            guard let run = records.values.filter({ $0.sessionID == sid && $0.isActive }).sorted(by: { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }).first else { continue }
            tasks[run.id] = Task { [weak self] in
                guard let self else { return }
                await execute(run.id)
                tasks.removeValue(forKey: run.id)
                schedule()
            }
        }
    }
    private func execute(_ id: String) async {
        do {
            guard var run = records[id], run.isActive else { return }
            var freshStream = false
            if run.upstreamID == nil {
                if run.stopRequested == true { run.status = "cancelled"; try commit(run); onFinished?(run); return }
                if !["queued", "choosing_model"].contains(run.status) {
                    let policy = features["runs_idempotency"]?.object
                    let withinRetention = Date().timeIntervalSince1970 - run.created < (policy?["retention_seconds"]?.number ?? 0)
                    guard policy?["durable"]?.bool == true && withinRetention else {
                        throw ServiceError(message: "Submission outcome is unknown. Check Hermes before sending again.")
                    }
                }
                if run.history == nil {
                    run.history = try await backend.messages(run.sessionID, offset: 0).messages
                    try Task.checkCancellation()
                    if records[id]?.stopRequested == true { run.stopRequested = true; run.status = "cancelled"; try commit(run); onFinished?(run); return }
                }
                if run.automaticModel == true && run.modelSelection == nil {
                    guard let selectModel else { throw ServiceError(message: "Reconnect to choose a model for this Auto request.") }
                    run.status = "choosing_model"; try commit(run)
                    let decision = try await selectModel(run)
                    try Task.checkCancellation()
                    // Stop or suspend can arrive while model selection is in flight.
                    guard records[id]?.isActive == true else { return }
                    if records[id]?.stopRequested == true {
                        run.stopRequested = true; run.status = "cancelled"; try commit(run); onFinished?(run); return
                    }
                    run.modelSelection = decision.selection; run.modelDecision = decision
                    run.status = "queued"
                    // Save the choice before any Hermes submission. Recovered requests
                    // reuse it even if Auto or the available models have since changed.
                    try commit(run)
                }
                let wasQueued = run.status == "queued"
                run.status = "submitting"; try commit(run)
                let remoteID = try await backend.submit(run)
                // Save the remote ID even if cancellation arrived during the HTTP response.
                run = records[id] ?? run
                run.upstreamID = remoteID; run.status = "running"; try commit(run)
                freshStream = wasQueued
            }
            try Task.checkCancellation()
            guard let remoteID = records[id]?.upstreamID else { return }
            if records[id]?.stopRequested == true { try await backend.stop(remoteID) }
            if freshStream {
                do {
                    for try await event in backend.events(remoteID) {
                        try Task.checkCancellation()
                        if try consume(id, event) { return }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { /* Poll authoritative snapshots, never concatenate a replayed stream. */ }
            }
            try await poll(id, remoteID: remoteID)
        } catch is CancellationError { }
        catch {
            if Task.isCancelled { return }
            guard var run = records[id], run.isActive else { return }
            // A rejected 4xx admission is known not to have started. Transport
            // failures after submission retain the ID for a durable retry.
            let status = (error as? ServiceError)?.statusCode
            let uncertain = status == nil || (status ?? 0) >= 500 || status == 408
            if run.upstreamID == nil && run.status == "submitting" && uncertain {
                if !paused {
                    do { try await Task.sleep(for: .seconds(3)); try Task.checkCancellation() }
                    catch { return }
                    let policy = features["runs_idempotency"]?.object
                    if policy?["durable"]?.bool == true && Date().timeIntervalSince1970 - run.created < (policy?["retention_seconds"]?.number ?? 0) { return }
                }
            }
            run.status = run.upstreamID != nil || (run.status == "submitting" && uncertain) ? "unknown" : "failed"
            run.error = error.localizedDescription
            do { try commit(run); onFinished?(run) }
            catch { paused = true; onError?("Luna couldn't save task progress. Reopen the app before submitting more work.") }
        }
    }
    private func poll(_ id: String, remoteID: String) async throws {
        var failures = 0
        while records[id]?.isActive == true {
            try Task.checkCancellation()
            do {
                let status = try await backend.status(remoteID)
                try Task.checkCancellation()
                failures = 0
                let state = status["status"]?.string ?? "running"
                if ["completed", "failed", "cancelled", "interrupted"].contains(state) {
                    _ = try consume(id, HermesEvent(type: "run." + state, data: status)); return
                }
                if var run = records[id] {
                    if ["running", "stopping", "waiting_for_approval", "queued"].contains(state) { run.status = state }
                    if let output = status["output"], output != .null { run.output = Self.stableOutput(current: run.output, incoming: HermesClient.content(output)) }
                    try commit(run)
                    if let approval = status["approval"]?.object { _ = try consume(id, HermesEvent(type: "approval.request", data: approval)) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as ServiceError where [401, 403, 404].contains(error.statusCode ?? 0) { throw error }
            catch { failures += 1; if failures >= 12 { throw ServiceError(message: "Run status is unavailable. Check Hermes before retrying this task.") } }
            try await Task.sleep(for: .seconds(failures == 0 ? 2 : min(20, failures * 2)))
        }
    }
    @discardableResult func consume(_ id: String, _ event: HermesEvent) throws -> Bool {
        guard var run = records[id], run.isActive else { return true }
        if ["message.delta", "assistant.delta", "response.output_text.delta"].contains(event.type), let delta = event.data["delta"]?.string {
            run.output += delta; try commit(run, durable: false)
        } else if event.type.hasPrefix("run."), ["completed", "failed", "cancelled", "interrupted"].contains(String(event.type.dropFirst(4))) {
            run.status = String(event.type.dropFirst(4))
            if let output = event.data["output"], output != .null { run.output = Self.stableOutput(current: run.output, incoming: HermesClient.content(output)) }
            run.error = event.data["error"]?.string
            try commit(run); onFinished?(run); return true
        } else if event.type == "approval.request" {
            run.status = "waiting_for_approval"; try commit(run)
            onEvent?(run.sessionID, id, event)
        } else if event.type.hasPrefix("tool.") || event.type.hasPrefix("subagent.") {
            onEvent?(run.sessionID, id, event)
        }
        return false
    }

    /// Authoritative snapshots may extend a stream, but never shrink or rewrite
    /// text the user has already seen.
    static func stableOutput(current: String, incoming: String) -> String {
        guard !current.isEmpty else { return incoming }
        guard incoming.hasPrefix(current) else { return current }
        return incoming
    }
}
