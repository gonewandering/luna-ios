import Foundation
import Observation

@MainActor @Observable final class AppStore {
    var sessions: [AgentSession] = []
    var messages: [String: [ChatMessage]] = [:]
    var runs: [String: AgentRun] = [:]
    var activity: [String: [Activity]] = [:]
    var approvals: [String: PendingApproval] = [:]
    var selectedSessionID: String?
    var unread: Set<String> = []
    var drafts: [String: String] = [:]
    var photoDrafts: [String: [DraftPhoto]] = [:]
    var canAttachPhotos: Bool { profile?.kind != .openAICompatible }
    var photoScope: String { profile.map { "profile:" + $0.id } ?? serverAddress + "|" + hermesKey }
    var historyHasMore: [String: Bool] = [:]
    var sessionsHasMore = false
    var connected = false
    var connecting = false
    var reconnecting = false {
        didSet {
            guard reconnecting != oldValue else { return }
            if reconnecting { notices.show("reconnecting") }
            else { notices.dismiss("reconnecting") }
        }
    }
    var demo = false
    var error: String? {
        didSet {
            if error != nil { notices.show("error", duration: 12) }
            else { notices.dismiss("error") }
        }
    }
    let notices = TransientNotices()
    var serverAddress: String
    var hermesKey: String
    var openAIKey = ""
    var voiceAvailable: Bool { !openAIKey.isEmpty }
    var voiceTranscript = ""
    var voice = VoiceController()
    private(set) var profile: AgentProfile?
    var agentName: String { profile?.name ?? (demo ? "Demo" : "Hermes") }
    var voiceTargetsSession: Bool { profile == nil || voice.agentID == profile?.id }
    private(set) var historyFetchedAt: [String: Double] = [:]
    @ObservationIgnored var onVoiceRequest: ((String) async -> Void)?
    @ObservationIgnored var onRunFinished: ((AgentRun) async -> Void)?
    @ObservationIgnored var onLocalStateChanged: (() -> Void)?
    @ObservationIgnored var makeBackend: (() throws -> any AgentBackend)?
    @ObservationIgnored private var managedCacheURL: URL?
    @ObservationIgnored private var hydrationTask: Task<Void, Never>?
    private(set) var modelCatalog: HermesModelCatalog?
    private var modelPreferences: [String: SessionModelPreference] = [:]
    var sessionModels: [String: HermesModelSelection] { modelPreferences.compactMapValues(\.selection) }
    private(set) var changingModels: Set<String> = []
    private(set) var supportsSessionModels = false
    @ObservationIgnored private(set) var backend: (any AgentBackend)?
    @ObservationIgnored private(set) var coordinator: RunCoordinator?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var cacheURL: URL?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var sessionRevisions: [String: Int] = [:]
    @ObservationIgnored private var backgrounded = false

    init(loadSavedState: Bool = true) {
        let address = UserDefaults.standard.string(forKey: "hermesAddress") ?? "https://jetson.tail428f1f.ts.net:8443"
        serverAddress = address
        hermesKey = loadSavedState ? Credentials.read(Credentials.hermesAccount(address)) : ""
        if loadSavedState { openAIKey = Credentials.read("openai-api-key") }
        if !hermesKey.isEmpty {
            let file = CacheFile.location(server: address, token: hermesKey)
            cacheURL = file
            modelPreferences = (try? SessionModelFile.read(SessionModelFile.location(for: file))) ?? [:]
            if let cached = CacheFile.read(file) {
                sessions = cached.sessions; messages = cached.messages
                runs = cached.runs; unread = cached.unread
                historyFetchedAt = cached.fetchedAt ?? [:]
            }
        }
        voice.onStopped = { [weak self] in
            guard let self, backgrounded else { return }
            coordinator?.pause(); refreshTask?.cancel(); saveNow()
        }
    }
    var selectedSession: AgentSession? { sessions.first { $0.id == selectedSessionID } }
    var activeCount: Int { runs.values.filter(\.isActive).count }

    func configure(profile: AgentProfile, key: String, openAIKey: String, voice: VoiceController, cache: URL) throws {
        self.profile = profile; serverAddress = profile.address; hermesKey = key
        self.openAIKey = openAIKey; self.voice = voice
        managedCacheURL = cache; cacheURL = cache
        if let saved = CacheFile.read(cache) {
            sessions = saved.sessions; messages = saved.messages; runs = saved.runs; unread = saved.unread
            historyFetchedAt = saved.fetchedAt ?? [:]
        }
        modelPreferences = try SessionModelFile.read(SessionModelFile.location(for: cache))
    }

    func renameLocally(_ name: String) { profile?.name = name }

    func disconnect() async {
        hydrationTask?.cancel(); refreshTask?.cancel()
        await coordinator?.suspend(); await backend?.shutdown(); saveNow()
        generation = UUID(); connected = false; connecting = false; reconnecting = false
        coordinator = nil; backend = nil
    }

    func connect(useDemo: Bool = false) async {
        guard !connecting else { return }
        connecting = true
        defer { connecting = false }
        hydrationTask?.cancel()
        await coordinator?.suspend(); await backend?.shutdown(); refreshTask?.cancel(); saveNow()
        if profile == nil { await voice.stop() }
        generation = UUID()
        notices.removeAll()
        error = nil; reconnecting = false
        let current = generation
        connected = false
        modelCatalog = nil; supportsSessionModels = false; changingModels = []
        do {
            let next: any AgentBackend
            let file: URL
            if let makeBackend {
                next = try makeBackend()
                file = managedCacheURL ?? CacheFile.location(server: serverAddress, token: hermesKey)
            } else if useDemo {
                next = DemoBackend(file: managedCacheURL?.deletingLastPathComponent().appending(path: "demo-data.json") ?? URL.applicationSupportDirectory.appending(path: "Luna/demo-data.json"))
                file = managedCacheURL ?? CacheFile.location(server: "on-device-demo", token: "")
            } else {
                let url = try APIClient.validateURL(serverAddress)
                guard profile?.kind == .openAICompatible || !hermesKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError(message: "Enter your Hermes API key.") }
                file = managedCacheURL ?? CacheFile.location(server: url.absoluteString, token: hermesKey)
                if let profile, profile.kind == .openAICompatible {
                    next = try CompatibleAgentClient(url: url, key: hermesKey, name: profile.name, defaultModel: profile.defaultModel,
                                                     file: file.deletingLastPathComponent().appending(path: "conversations.json"))
                } else { next = HermesClient(url: url, key: hermesKey, photoScope: photoScope) }
            }
            let features = try await next.capabilities()
            let page = try await next.sessions(offset: 0)
            let journal = file.deletingPathExtension().appendingPathExtension("runs.json")
            let records = try RunCoordinator.readJournal(journal)
            let savedModels = try SessionModelFile.read(SessionModelFile.location(for: file))
            if !useDemo && profile == nil {
                try Credentials.save(hermesKey, account: Credentials.hermesAccount(serverAddress))
                try Credentials.save(openAIKey, account: "openai-api-key")
                UserDefaults.standard.set(serverAddress, forKey: "hermesAddress")
            }
            if file != cacheURL {
                messages = [:]; unread = []; selectedSessionID = nil; drafts = [:]; photoDrafts = [:]; historyFetchedAt = [:]
                if let cached = CacheFile.read(file) { messages = cached.messages; unread = cached.unread; historyFetchedAt = cached.fetchedAt ?? [:] }
            }
            cacheURL = file; backend = next
            modelPreferences = savedModels
            supportsSessionModels = features["session_model_lock"]?.bool == true
            let listed = Set(page.sessions.map(\.id))
            sessions = page.sessions + sessions.filter { !listed.contains($0.id) }; sessionsHasMore = page.has_more
            runs = records; activity = [:]; approvals = [:]; sessionRevisions = [:]
            let queue = RunCoordinator(backend: next, features: features, records: records, selectModel: { [weak self] run in
                if next.isDemo { return AutoModelRouter.demo(prompt: run.text) }
                let routingKey = self?.openAIKey ?? ""
                guard !routingKey.isEmpty else { throw ServiceError(message: "Add your OpenAI API key in Settings to use Auto, or choose a model manually.") }
                let catalog = try await next.models(refresh: false)
                try Task.checkCancellation()
                return try await AutoModelRouter(key: routingKey).choose(prompt: run.text, history: run.history ?? [], catalog: catalog, photoCount: run.photos?.count ?? 0)
            }) { try ProtectedFile.write($0, to: journal) }
            coordinator = queue
            queue.onRun = { [weak self] run in
                guard let self, generation == current else { return }
                recordRunUpdate(run)
            }
            queue.onEvent = { [weak self] sid, id, event in
                guard let self, generation == current else { return }
                apply(sid, runID: id, event: event)
            }
            queue.onFinished = { [weak self] run in
                guard let self, generation == current else { return }
                approvals = approvals.filter { $0.value.runID != run.id }
                Task {
                    guard self.generation == current else { return }
                    if let onRunFinished = self.onRunFinished { await onRunFinished(run) }
                    else { await self.voice.finished(run) }
                    await self.loadMessages(run.sessionID, quietly: true)
                    await self.refreshSessions()
                }
            }
            queue.onError = { [weak self] message in
                guard let self, generation == current else { return }
                error = message
            }
            demo = next.isDemo; connected = true; reconnecting = false; error = nil
            queue.resume(); startRefreshing()
            if ProcessInfo.processInfo.arguments.contains("--show-chat"), let first = sessions.first { selectedSessionID = first.id }
            if let sid = selectedSessionID { await loadMessages(sid) }
            saveSoon()
            prefetchContext()
        } catch { self.error = error.localizedDescription }
    }

    func recordRunUpdate(_ run: AgentRun) {
        let previous = runs[run.id]
        runs[run.id] = run
        sessionRevisions[run.sessionID, default: 0] += 1
        // Keep the timeline stable while the streaming answer is visible, but
        // never shrink or blank it: merge the pre-run snapshot into what is
        // already shown (paginated or cached rows must survive). run.history is a
        // tail subset of the displayed rows, so this adds nothing during normal
        // streaming and only backfills when the timeline is still empty.
        if let history = run.history, run.isActive {
            messages[run.sessionID] = ConversationHistory.merge(existing: messages[run.sessionID] ?? [], incoming: history, older: false)
        }
        if run.isActive { notices.dismiss(TransientNotices.run(run.id)) }
        else if previous?.isActive != false && run.historyReconciled != true {
            notices.show(TransientNotices.run(run.id), duration: run.status == "completed" ? 8 : 12)
            if var rows = activity[run.sessionID] {
                for index in rows.indices where rows[index].runID == run.id { rows[index].finished = true }
                activity[run.sessionID] = rows
                if rows.allSatisfy(\.finished) { notices.show(TransientNotices.activity(run.sessionID)) }
            }
        }
        if run.sessionID != selectedSessionID { unread.insert(run.sessionID) }
        saveSoon()
    }

    private func apply(_ sid: String, runID: String, event: HermesEvent) {
        if event.type.hasPrefix("tool.") || event.type.hasPrefix("subagent.") {
            let title = event.data["tool"]?.string ?? event.data["name"]?.string ?? "Agent tool"
            var rows = (activity[sid] ?? []).filter { !$0.finished || $0.runID == runID }
            let finished = !event.type.hasSuffix("started")
            if let index = rows.lastIndex(where: { $0.runID == runID && $0.title == title && !$0.finished }) {
                rows[index].detail = event.data["preview"]?.string ?? rows[index].detail
                rows[index].finished = finished
                rows[index].failed = event.type.hasSuffix("failed") || event.data["error"]?.bool == true
            } else {
                rows.append(Activity(id: UUID().uuidString, title: title, detail: event.data["preview"]?.string ?? "", finished: finished, failed: event.type.hasSuffix("failed"), runID: runID))
            }
            activity[sid] = Array(rows.suffix(30))
            if rows.allSatisfy(\.finished) { notices.show(TransientNotices.activity(sid)) }
            else { notices.dismiss(TransientNotices.activity(sid)) }
        } else if event.type == "approval.request", let aid = event.data["approval_id"]?.string ?? event.data["request_id"]?.string {
            approvals[aid] = PendingApproval(id: aid, runID: runID, sessionID: sid,
                description: event.data["command"]?.string ?? event.data["description"]?.string ?? "Hermes needs your approval.")
        }
    }
    func select(_ sid: String) async {
        selectedSessionID = sid
        if profile == nil && voice.sessionID != nil && voice.sessionID != sid { await voice.stop() }
        guard selectedSessionID == sid else { return }
        unread.remove(sid); await loadMessages(sid)
    }
    func refreshSessions(more: Bool = false) async {
        guard connected, let backend else { return }
        let current = generation
        do {
            let page = try await backend.sessions(offset: more ? sessions.count : 0)
            guard generation == current else { return }
            if more {
                let ids = Set(sessions.map(\.id)); sessions += page.sessions.filter { !ids.contains($0.id) }
            } else {
                let ids = Set(page.sessions.map(\.id)); sessions = page.sessions + sessions.filter { !ids.contains($0.id) }
            }
            sessionsHasMore = page.has_more; reconnecting = false; saveSoon()
            prefetchContext()
        } catch { reconnecting = true; if more { self.error = error.localizedDescription } }
    }
    func loadMessages(_ sid: String, older: Bool = false, quietly: Bool = false) async {
        guard connected, let backend else { return }
        if !older, let run = runs.values.filter({ $0.sessionID == sid && $0.isActive && $0.history != nil }).min(by: { $0.created < $1.created }) {
            // While a run is streaming, do not fetch fresh (pre-response) history,
            // but never replace the visible timeline with the snapshot: merge so
            // paginated and cached rows survive a refresh/reconnect.
            messages[sid] = ConversationHistory.merge(existing: messages[sid] ?? [], incoming: run.history ?? [], older: false)
            return
        }
        let current = generation, revision = sessionRevisions[sid, default: 0]
        do {
            let page = try await backend.messages(sid, offset: older ? (messages[sid]?.count ?? 0) : 0)
            guard generation == current, sessionRevisions[sid, default: 0] == revision else { return }
            let existing = messages[sid] ?? []
            messages[sid] = ConversationHistory.merge(existing: existing, incoming: page.messages, older: older)
            if !older { historyFetchedAt[sid] = Date().timeIntervalSince1970 }
            if older || existing.count <= page.messages.count { historyHasMore[sid] = page.hasMore }
            if !older {
                let sessionRuns = runs.values.filter { $0.sessionID == sid }
                let reconciled = ConversationHistory.reconciledRunIDs(runs: Array(sessionRuns), messages: messages[sid] ?? [])
                if !reconciled.isEmpty, saveNow() {
                    _ = coordinator?.markReconciled(reconciled)
                    _ = saveNow()
                } else { saveSoon() }
            } else { saveSoon() }
        } catch { if !quietly { self.error = error.localizedDescription } }
    }
    func send(_ sid: String) async {
        guard connected, let coordinator else { return }
        let text = (drafts[sid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedPhotos = photoDrafts[sid] ?? []
        guard !text.isEmpty || !selectedPhotos.isEmpty else { return }
        do {
            guard selectedPhotos.isEmpty || canAttachPhotos else { throw ServiceError(message: "Photo attachments are available in Hermes chats.") }
            guard selectedPhotos.count <= ChatPhoto.maxCount else { throw ServiceError(message: "Attach up to four photos per message.") }
            try checkModelReady(sid)
            let photos = try selectedPhotos.map { try ChatPhoto.save($0, scope: photoScope) }
            _ = try await coordinator.admit(id: UUID().uuidString.lowercased(), sessionID: sid, text: text,
                                           model: sessionModels[sid], automaticModel: usesAutoModel(sid), photos: photos)
            if drafts[sid]?.trimmingCharacters(in: .whitespacesAndNewlines) == text { drafts[sid] = "" }
            if photoDrafts[sid]?.map(\.id) == selectedPhotos.map(\.id) { photoDrafts[sid] = [] }
        } catch { self.error = error.localizedDescription }
    }
    func createSession(title: String) async {
        guard connected, let backend else { return }
        let current = generation
        do {
            let session = try await backend.create(title)
            guard generation == current else { return }
            sessions.insert(session, at: 0); await select(session.id)
        } catch { self.error = error.localizedDescription }
    }
    func renameSession(_ sid: String, title: String) async {
        guard connected, let backend else { return }
        let current = generation
        do {
            let session = try await backend.rename(sid, title: title)
            guard generation == current else { return }
            if let index = sessions.firstIndex(where: { $0.id == sid }) { sessions[index] = session }
            saveSoon()
        } catch { self.error = error.localizedDescription }
    }
    func stopRun(_ id: String) async {
        do { try await coordinator?.stop(id) } catch { self.error = error.localizedDescription }
    }
    func resolve(_ approval: PendingApproval, choice: String) async {
        do { try await coordinator?.approve(approval.runID, requestID: approval.id, choice: choice); approvals.removeValue(forKey: approval.id) }
        catch { self.error = error.localizedDescription }
    }
    func acknowledgeUnknown(_ id: String) { coordinator?.markReconciled([id]) }

    func modelLabel(_ sid: String) -> String {
        // A session's reported model may be historical. Only a choice made in
        // Luna is explicitly attached to every Runs request.
        if usesAutoModel(sid) { return "Auto" }
        if let model = sessionModels[sid]?.model { return model }
        if let profile, profile.kind == .openAICompatible {
            return sessions.first(where: { $0.id == sid })?.model ?? (profile.defaultModel.isEmpty ? "Choose a model" : profile.defaultModel)
        }
        return "Hermes settings"
    }
    func usesAutoModel(_ sid: String) -> Bool { modelPreferences[sid] == .automatic }
    func latestAutoRun(_ sid: String) -> AgentRun? {
        runs.values.filter { $0.sessionID == sid && $0.automaticModel == true }.max { $0.created < $1.created }
    }
    func modelChangeBlocked(_ sid: String) -> Bool {
        runs.values.contains { $0.sessionID == sid && ($0.isActive || ($0.status == "unknown" && $0.historyReconciled != true)) }
    }
    func loadModels(refresh: Bool = false) async throws {
        guard connected, let backend else { throw ServiceError(message: "Reconnect the agent to load models.") }
        let current = generation
        let catalog = try await backend.models(refresh: refresh)
        guard generation == current, connected else { throw CancellationError() }
        modelCatalog = catalog
    }
    func setSessionModel(_ selection: HermesModelSelection, sessionID sid: String) async throws {
        guard connected, let backend, let file = cacheURL else { throw ServiceError(message: "Reconnect the agent to choose a model.") }
        guard supportsSessionModels else { throw ServiceError(message: "Update Hermes to enable session model selection.") }
        guard modelCatalog?.contains(selection) == true else { throw ServiceError(message: "This model is no longer available. Refresh the list and choose again.") }
        guard !modelChangeBlocked(sid) else { throw ServiceError(message: "Wait for this session’s tasks to finish before changing its model.") }
        try checkModelReady(sid, requireAutoKey: false)
        let current = generation
        changingModels.insert(sid)
        defer { if generation == current { changingModels.remove(sid) } }
        try await backend.setModel(selection, sessionID: sid)
        guard generation == current, connected else { throw CancellationError() }
        modelPreferences[sid] = .manual(selection)
        if let index = sessions.firstIndex(where: { $0.id == sid }) { sessions[index].model = selection.model }
        // Hermes has acknowledged persistence. Keep the acknowledged selection in
        // memory even if this device's protected preferences cannot be written.
        do { try ProtectedFile.write(modelPreferences, to: SessionModelFile.location(for: file)) }
        catch { throw ServiceError(message: "Hermes saved the model, but Luna could not save it on this device. Free some storage and select it again before closing the app.") }
        saveSoon()
    }
    func setSessionAutoModel(_ sid: String) throws {
        guard connected, let file = cacheURL else { throw ServiceError(message: "Reconnect the agent to choose Auto.") }
        guard supportsSessionModels else { throw ServiceError(message: "Update Hermes to enable session model selection.") }
        guard demo || !openAIKey.isEmpty else { throw ServiceError(message: "Add your OpenAI API key in Settings to use Auto.") }
        guard !modelChangeBlocked(sid), !changingModels.contains(sid) else {
            throw ServiceError(message: "Wait for this session’s tasks to finish before changing its model.")
        }
        guard let catalog = modelCatalog, !AutoModelRouter.candidates(in: catalog).isEmpty else {
            throw ServiceError(message: "Load the model list before choosing Auto.")
        }
        var next = modelPreferences; next[sid] = .automatic
        try ProtectedFile.write(next, to: SessionModelFile.location(for: file))
        modelPreferences = next
    }
    private func checkModelReady(_ sid: String, requireAutoKey: Bool = true) throws {
        guard !changingModels.contains(sid) else { throw ServiceError(message: "Wait for the model selection to finish saving.") }
        guard !requireAutoKey || !usesAutoModel(sid) || demo || !openAIKey.isEmpty else {
            throw ServiceError(message: "Add your OpenAI API key in Settings to use Auto, or choose a model manually.")
        }
    }

    func startVoice(_ sid: String) async {
        if let onVoiceRequest { await onVoiceRequest(sid); return }
        guard connected else { error = "Connect Hermes first."; return }
        guard voiceAvailable else { error = "Add your OpenAI API key in Settings to enable voice."; return }
        voiceTranscript = ""
        let current = generation
        do {
            try await voice.start(key: openAIKey, sessionID: sid, title: sessions.first { $0.id == sid }?.title ?? "Hermes",
                execute: { [weak self] name, arguments, id in
                    guard let self, generation == current else { throw CancellationError() }
                    return try await executeVoice(name, arguments: arguments, id: id, boundSession: sid)
                }, transcript: { [weak self] role, delta in
                    guard let self, generation == current, role == "user" else { return }
                    voiceTranscript = String((voiceTranscript + delta).suffix(600))
                }, switchSession: { [weak self] target in
                    Task { @MainActor in
                        guard let self, self.generation == current else { return }
                        await self.voice.stop(); await self.select(target); await self.startVoice(target)
                    }
                })
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    func executeVoice(_ name: String, arguments: JSONObject, id: String, boundSession sid: String) async throws -> JSONObject {
        guard connected, let backend, let coordinator else { throw ServiceError(message: "Reconnect Hermes first.") }
        switch name {
        case "send_prompt":
            try checkModelReady(sid)
            let run = try await coordinator.admit(id: id, sessionID: sid, text: arguments["prompt"]?.string ?? "",
                model: sessionModels[sid], automaticModel: usesAutoModel(sid))
            return ["request_id": .string(run.id), "session_id": .string(sid), "status": .string(run.status),
                "model_mode": .string(run.automaticModel == true ? "auto" : "manual_or_hermes_settings"),
                "note": .string("Accepted locally; Auto requests choose a model before execution. The result will appear in this session. Do not resend.")]
        case "get_hermes_tools": return try await backend.tools()
        case "get_hermes_skills": return try await backend.skills()
        case "list_sessions":
            let page = try await backend.sessions(offset: 0)
            return ["sessions": try .encoded(page.sessions), "has_more": .bool(page.has_more)]
        case "open_session":
            guard let target = arguments["session_id"]?.string else { throw ServiceError(message: "Choose an exact session ID.") }
            let session = try await backend.session(target)
            if !sessions.contains(where: { $0.id == target }) { sessions.append(session) }
            return ["target_session_id": .string(target), "status": .string("switching")]
        case "get_response_details":
            let history = try await backend.messages(sid, offset: 0)
            let details: [JSONValue] = coordinator.records.values.filter { $0.sessionID == sid }.sorted { $0.created > $1.created }.prefix(5).map {
                .object(["request_id": .string($0.id), "status": .string($0.status), "output": .string($0.output), "error": $0.error.map(JSONValue.string) ?? .null,
                    "requested_model": $0.modelSelection.map { .string($0.model) } ?? .null,
                    "model_reason": $0.modelDecision.map { .string($0.reason) } ?? .null])
            }
            return ["session_id": .string(sid), "messages": try .encoded(Array(history.messages.suffix(12))), "runs": .array(details)]
        case "stop_agent":
            guard let run = coordinator.records.values.filter({ $0.sessionID == sid && $0.isActive }).min(by: { $0.created < $1.created }) else { return ["status": .string("No active task in this session.")] }
            try await coordinator.stop(run.id)
            return ["request_id": .string(run.id), "status": .string("Stop requested")]
        default: throw ServiceError(message: "Unknown voice command.")
        }
    }
    func sceneChanged(background: Bool) async {
        notices.expire()
        backgrounded = background
        if background {
            hydrationTask?.cancel(); hydrationTask = nil
            if !voice.isActive { coordinator?.pause(); refreshTask?.cancel() }
            saveNow()
        } else if connected {
            coordinator?.resume(); startRefreshing(); await refreshSessions()
            if let sid = selectedSessionID { await loadMessages(sid, quietly: true) }
        }
    }
    private func startRefreshing() {
        refreshTask?.cancel()
        let current = generation
        refreshTask = Task {
            while !Task.isCancelled, generation == current {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                await refreshSessions()
                if let sid = selectedSessionID { await loadMessages(sid, quietly: true) }
            }
        }
    }
    private func prefetchContext() {
        guard profile != nil, hydrationTask == nil, !backgrounded else { return }
        let current = generation
        hydrationTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == current { hydrationTask = nil } }
            for session in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                guard !Task.isCancelled, generation == current else { return }
                if runs.values.contains(where: { $0.sessionID == session.id && $0.isActive }) { continue }
                if messages[session.id] == nil || (historyFetchedAt[session.id] ?? 0) < session.updatedAt {
                    await loadMessages(session.id, quietly: true)
                }
            }
        }
    }
    func forgetCredentials() async {
        await coordinator?.suspend(); refreshTask?.cancel(); await voice.stop(); saveNow()
        do {
            try Credentials.save("", account: Credentials.hermesAccount(serverAddress))
            try Credentials.save("", account: "openai-api-key")
            hermesKey = ""; openAIKey = ""; connected = false; backend = nil; coordinator = nil
            generation = UUID(); sessions = []; messages = [:]; runs = [:]; cacheURL = nil
            drafts = [:]; photoDrafts = [:]
            notices.removeAll(); error = nil; reconnecting = false
            modelPreferences = [:]; modelCatalog = nil; changingModels = []; supportsSessionModels = false
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult func saveNow() -> Bool {
        saveTask?.cancel(); saveTask = nil
        var saved = true
        if let file = cacheURL {
            do { try CacheFile.write(ChatCache(sessions: sessions, messages: messages, runs: runs, cursor: 0, unread: unread, fetchedAt: historyFetchedAt), to: file) }
            catch {
                saved = false
                if self.error == nil { self.error = "Luna couldn't save this conversation on the device. Check available storage." }
            }
        }
        onLocalStateChanged?()
        return saved
    }
    func saveSoon() {
        guard saveTask == nil else { return }
        saveTask = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            saveNow()
        }
    }

    #if DEBUG && targetEnvironment(simulator)
    func previewNotices() {
        // Isolated UI fixture: no connection, journal writes, or saved credentials.
        cacheURL = nil; backend = nil; coordinator = nil
        connected = true; demo = true
        let sid = "notice-preview", now = Date().timeIntervalSince1970
        sessions = [AgentSession(id: sid, title: "A quieter conversation", preview: "", source: "Demo", updatedAt: now, messageCount: 1)]
        selectedSessionID = sid
        messages = [sid: [ChatMessage(id: "preview-prompt", role: "user", content: "Show a short greeting.", createdAt: now)]]
        runs = [:]; activity = [:]; approvals = [:]; notices.removeAll()
        var run = AgentRun(id: "preview-run", sessionID: sid, text: "Show a short greeting.", status: "failed",
                           output: "Hello from Hermes.", error: "The connection was interrupted. Please try again.", created: now)
        run.upstreamID = "preview-remote"
        recordRunUpdate(run)
        reconnecting = true
    }
    #endif
}
