import Foundation
import Observation

struct HomeSession: Identifiable {
    let address: SessionAddress
    let agentName: String
    let session: AgentSession
    let online: Bool
    let updatedAt: Double
    var active = false
    var unread = false
    var id: String { address.id }
}

@MainActor @Observable final class LunaStore {
    private(set) var profiles: [AgentProfile] = []
    private(set) var runtimes: [String: AppStore] = [:]
    var memory: LocalMemory
    let voice = VoiceController()
    let lunaText = LunaTextConversation()
    let notices = TransientNotices()
    var navigation: [LunaRoute] = []
    var voiceTarget: SessionAddress?
    var transcript = ""
    var openAIKey = ""
    var demo = false
    var error: String? {
        didSet { if error != nil { notices.show("error", duration: 12) } else { notices.dismiss("error") } }
    }
    private(set) var storageError: String?
    @ObservationIgnored let root: URL
    @ObservationIgnored private var started = false
    @ObservationIgnored private var backgrounded = false
    @ObservationIgnored var makeTextRouter: ((String) -> LunaTextRouter)?
    @ObservationIgnored private var textTask: Task<Void, Never>?
    @ObservationIgnored private let backendFactory: ((AgentProfile, String) throws -> any AgentBackend)?
    @ObservationIgnored private let readKey: (String) -> String
    @ObservationIgnored private let writeKey: (String, String) throws -> Void

    init(root: URL = AgentFiles.root, loadSavedState: Bool = true,
         backendFactory: ((AgentProfile, String) throws -> any AgentBackend)? = nil,
         readKey: @escaping (String) -> String = { Credentials.read($0) },
         writeKey: @escaping (String, String) throws -> Void = { try Credentials.save($0, account: $1) }) {
        self.root = root; self.backendFactory = backendFactory; self.readKey = readKey; self.writeKey = writeKey
        do { memory = try LocalMemory(file: loadSavedState ? root.appending(path: "memory.json") : nil) }
        catch { memory = try! LocalMemory(); storageError = "Luna could not read its local memory. Your saved file has been left intact." }
        if loadSavedState {
            openAIKey = readKey("openai-api-key")
            do {
                let registry = root.appending(path: "profiles.json")
                if FileManager.default.fileExists(atPath: registry.path) {
                    let saved = try JSONDecoder().decode(AgentRegistry.self, from: Data(contentsOf: registry))
                    guard saved.version == 1, Set(saved.agents.map(\.id)).count == saved.agents.count,
                          saved.agents.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw ServiceError(message: "Unsupported agent settings.") }
                    profiles = saved.agents
                } else {
                    let address = UserDefaults.standard.string(forKey: "hermesAddress") ?? "https://jetson.tail428f1f.ts.net:8443"
                    let key = readKey(Credentials.hermesAccount(address))
                    if !key.isEmpty {
                        let profile = AgentProfile(name: "Hermes", kind: .hermes, address: address)
                        try writeKey(key, profile.keyAccount)
                        try AgentFiles.migrateLegacy(profile, key: key, root: root)
                        try ProtectedFile.write(AgentRegistry(agents: [profile]), to: registry)
                        profiles = [profile]
                    }
                }
                for profile in profiles { try attach(profile, key: readKey(profile.keyAccount)) }
                memory.retainAgents(Set(profiles.map(\.id)))
            } catch { storageError = "Luna could not load its saved agents. Existing files have been left intact." }
        } else {
            // Tests and previews can still exercise durable local files in an isolated directory.
            do { memory = try LocalMemory(file: root.appending(path: "memory.json")) }
            catch { storageError = "Luna could not read local memory." }
        }
        voice.onStopped = { [weak self] in
            guard let self, backgrounded else { return }
            Task { for runtime in self.runtimes.values { await runtime.sceneChanged(background: true) } }
        }
    }

    var allSessions: [HomeSession] {
        profiles.flatMap { profile -> [HomeSession] in
            guard let runtime = runtimes[profile.id] else { return [] }
            return runtime.sessions.map { session in
                HomeSession(address: SessionAddress(agentID: profile.id, sessionID: session.id), agentName: profile.name,
                    session: session, online: runtime.connected && !runtime.reconnecting,
                    updatedAt: max(session.updatedAt, runtime.runs.values.filter { $0.sessionID == session.id }.map(\.created).max() ?? 0),
                    active: runtime.runs.values.contains { $0.sessionID == session.id && $0.isActive }, unread: runtime.unread.contains(session.id))
            }
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }
    var recentSessions: [HomeSession] { Array(allSessions.prefix(5)) }
    var voiceTargetLabel: String {
        guard let address = voiceTarget, let profile = profiles.first(where: { $0.id == address.agentID }) else { return "Luna · all your agents" }
        return profile.name + " · " + (session(address)?.title ?? "Session")
    }
    func session(_ address: SessionAddress) -> AgentSession? { runtimes[address.agentID]?.sessions.first { $0.id == address.sessionID } }
    func key(for profile: AgentProfile) -> String { readKey(profile.keyAccount) }

    func sendLunaText(agentID: String? = nil) {
        let prompt = lunaText.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lunaText.sending, !prompt.isEmpty else { return }
        guard prompt.count <= 32_000 else { error = "Please keep Luna’s message under 32,000 characters."; return }
        guard !openAIKey.isEmpty || makeTextRouter != nil else { error = "Add Luna’s OpenAI API key in Settings to send messages to Luna. You can still type directly in an agent’s chat."; return }
        if let agentID, !profiles.contains(where: { $0.id == agentID }) { error = "Choose an available agent."; return }
        let history = lunaText.messages
        let turnID = UUID().uuidString.lowercased()
        lunaText.draft = ""; lunaText.sending = true; lunaText.replyHidden = false
        lunaText.messages.append(ChatMessage(id: turnID, role: "user", content: prompt, createdAt: Date().timeIntervalSince1970))
        lunaText.messages = Array(lunaText.messages.suffix(24))
        var context: JSONObject = ["current_time": .number(Date().timeIntervalSince1970), "time_zone": .string(TimeZone.current.identifier),
                                  "browsing_agent_id": agentID.map(JSONValue.string) ?? .null]
        if let target = lunaText.destination, session(target) != nil {
            context["previous_destination"] = .object(["agent_id": .string(target.agentID), "session_id": .string(target.sessionID)])
        }
        let router = makeTextRouter?(openAIKey) ?? LunaTextRouter(key: openAIKey)
        textTask = Task { [weak self] in
            guard let self else { return }
            defer { lunaText.sending = false; textTask = nil }
            do {
                let reply = try await router.reply(prompt: prompt, history: history, context: context, turnID: turnID) { [weak self] name, args, id in
                    guard let self else { throw CancellationError() }
                    try Task.checkCancellation()
                    let result = try await executeVoice(name, arguments: args, id: id)
                    if ["select_session", "create_session", "send_prompt"].contains(name),
                       let agent = result["agent_id"]?.string, let session = result["session_id"]?.string {
                        lunaText.destination = SessionAddress(agentID: agent, sessionID: session)
                    }
                    return result
                }
                lunaText.messages.append(ChatMessage(id: turnID + "-reply", role: "assistant", content: reply, createdAt: Date().timeIntervalSince1970))
                lunaText.messages = Array(lunaText.messages.suffix(24))
            } catch is CancellationError {
                error = "Luna stopped. Any task already sent is still available in its conversation."
            } catch { self.error = error.localizedDescription }
        }
    }
    func stopLunaText() { textTask?.cancel() }

    @discardableResult func renameAgent(_ id: String, name: String) throws -> AgentProfile {
        guard storageError == nil else { throw ServiceError(message: storageError!) }
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { throw ServiceError(message: "That agent is no longer saved in Luna.") }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw ServiceError(message: "Enter a name for this agent.") }
        var next = profiles
        next[index].name = clean
        // Names belong to Luna, so renaming never reconnects or interrupts agent work.
        try ProtectedFile.write(AgentRegistry(agents: next), to: root.appending(path: "profiles.json"))
        profiles = next
        runtimes[id]?.renameLocally(clean)
        memory.renameAgent(id, name: clean)
        do { try memory.save() }
        catch { self.error = "The agent’s name was saved, but Luna could not update its cached conversation labels." }
        return next[index]
    }

    func findAgents(named name: String) -> [AgentProfile] {
        func normalized(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let query = normalized(name)
        guard !query.isEmpty else { return [] }
        let exact = profiles.filter { normalized($0.name) == query }
        if !exact.isEmpty { return exact }
        let terms = query.split(separator: " ")
        return profiles.filter { profile in terms.allSatisfy { normalized(profile.name).contains($0) } }
    }

    private func agentDetails(_ profile: AgentProfile) -> JSONObject {
        ["agent_id": .string(profile.id), "name": .string(profile.name), "connector": .string(profile.kind.rawValue),
         "host": .string(URL(string: profile.address)?.host ?? ""),
         "connected": .bool(runtimes[profile.id]?.connected == true && runtimes[profile.id]?.reconnecting == false)]
    }

    func start() async {
        guard !started else { return }; started = true
        if let storageError { error = storageError; return }
        await withTaskGroup(of: Void.self) { group in
            for profile in profiles { group.addTask { await self.connectAgent(profile.id) } }
        }
        if ProcessInfo.processInfo.arguments.contains("--show-chat"), let first = recentSessions.first { open(first.address) }
    }
    func connectAgent(_ id: String) async {
        guard let runtime = runtimes[id] else { return }
        await runtime.connect(useDemo: demo)
        syncMemory(id)
    }
    func saveVoiceKey(_ key: String) throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try writeKey(clean, "openai-api-key")
        openAIKey = clean
        for runtime in runtimes.values { runtime.openAIKey = clean }
    }
    @discardableResult func saveAgent(_ proposed: AgentProfile, key: String) async throws -> AgentProfile {
        guard storageError == nil else { throw ServiceError(message: storageError!) }
        let url = try APIClient.validateURL(proposed.address)
        var profile = proposed
        profile.name = proposed.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.address = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        profile.defaultModel = proposed.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty, profile.kind == .openAICompatible || !cleanKey.isEmpty else { throw ServiceError(message: "Enter an agent name and API key.") }
        guard UUID(uuidString: profile.id) != nil else { throw ServiceError(message: "Invalid agent identity.") }
        let previous = profiles.first { $0.id == profile.id }
        if let previous, previous.address == profile.address, previous.kind == profile.kind,
           previous.defaultModel == profile.defaultModel, readKey(previous.keyAccount) == cleanKey, previous.name != profile.name {
            return try renameAgent(previous.id, name: profile.name)
        }
        if let previous { try requireIdle(previous.id) }
        // A different endpoint/account gets a fresh identity; old context never crosses accounts.
        if let previous, previous.address != profile.address || previous.kind != profile.kind || readKey(previous.keyAccount) != cleanKey {
            profile.id = UUID().uuidString.lowercased()
        }
        var next = profiles
        if let previous, let index = next.firstIndex(where: { $0.id == previous.id }) { next[index] = profile }
        else { next.append(profile) }
        let oldKey = readKey(profile.keyAccount)
        try writeKey(cleanKey, profile.keyAccount)
        do { try ProtectedFile.write(AgentRegistry(agents: next), to: root.appending(path: "profiles.json")) }
        catch { try? writeKey(oldKey, profile.keyAccount); throw error }
        if let previous {
            await runtimes[previous.id]?.disconnect()
            runtimes.removeValue(forKey: previous.id)
            if previous.id != profile.id {
                try? memory.removeAgent(previous.id)
                try? removeLegacyCopy(previous)
                try? writeKey("", previous.keyAccount)
                try? FileManager.default.removeItem(at: AgentFiles.directory(previous.id, root: root))
                if voiceTarget?.agentID == previous.id { setVoiceTarget(nil) }
                navigation = []
            }
        }
        profiles = next
        try attach(profile, key: cleanKey)
        await connectAgent(profile.id)
        if let failure = runtimes[profile.id]?.error { error = profile.name + ": " + failure }
        return profile
    }
    func removeAgent(_ id: String) async throws {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        try requireIdle(id)
        let next = profiles.filter { $0.id != id }
        try ProtectedFile.write(AgentRegistry(agents: next), to: root.appending(path: "profiles.json"))
        await runtimes[id]?.disconnect()
        profiles = next; runtimes.removeValue(forKey: id); navigation = []
        if voiceTarget?.agentID == id { setVoiceTarget(nil) }
        try memory.removeAgent(id)
        try removeLegacyCopy(profile)
        try writeKey("", profile.keyAccount)
        try ChatPhoto.removeFiles(scope: "profile:" + profile.id)
        let directory = AgentFiles.directory(id, root: root)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    private func requireIdle(_ id: String) throws {
        guard let runtime = runtimes[id] else { return }
        guard !runtime.connecting, !runtime.runs.values.contains(where: { $0.isActive || ($0.status == "unknown" && $0.historyReconciled != true) }) else {
            throw ServiceError(message: "Wait for this agent’s tasks or connection to finish, and review any uncertain task before changing or removing it.")
        }
    }
    private func attach(_ profile: AgentProfile, key: String) throws {
        let runtime = AppStore(loadSavedState: false)
        do { try runtime.configure(profile: profile, key: key, openAIKey: openAIKey, voice: voice, cache: AgentFiles.cache(profile.id, root: root)) }
        catch { runtime.error = "Luna could not load this agent’s saved model preferences. Existing files have been left intact." }
        if let backendFactory { runtime.makeBackend = { try backendFactory(profile, key) } }
        runtime.onVoiceRequest = { [weak self] sid in await self?.startVoice(target: SessionAddress(agentID: profile.id, sessionID: sid)) }
        runtime.onLocalStateChanged = { [weak self] in self?.syncMemory(profile.id) }
        runtime.onRunFinished = { [weak self] run in
            guard let self else { return }
            syncMemory(profile.id)
            await voice.finished(run, agentID: profile.id, agentName: self.profiles.first(where: { $0.id == profile.id })?.name ?? profile.name)
        }
        runtimes[profile.id] = runtime
        syncMemory(profile.id)
    }
    private func removeLegacyCopy(_ profile: AgentProfile) throws {
        let legacyAccount = Credentials.hermesAccount(profile.address)
        let key = readKey(profile.keyAccount)
        guard !key.isEmpty, readKey(legacyAccount) == key else { return }
        let old = CacheFile.location(server: profile.address, token: key)
        for file in [old, old.deletingPathExtension().appendingPathExtension("runs.json"), SessionModelFile.location(for: old)] {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
        try writeKey("", legacyAccount)
    }
    func syncMemory(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }), let runtime = runtimes[id] else { return }
        for session in runtime.sessions {
            memory.update(profile: profile, session: session, messages: runtime.messages[session.id],
                          runs: runtime.runs.values.filter { $0.sessionID == session.id }, fetchedAt: runtime.historyFetchedAt[session.id])
        }
        do { try memory.save() }
        catch { if self.error == nil { self.error = "Luna couldn't save its recent conversation memory. Check available storage." } }
    }
    func open(_ address: SessionAddress) {
        guard session(address) != nil else { error = "This saved conversation is no longer available."; return }
        runtimes[address.agentID]?.selectedSessionID = address.sessionID
        navigation = [.session(address)]
        // UI navigation never silently changes the destination of a voice request.
    }
    func createSession(agentID: String, title: String) async throws -> SessionAddress {
        guard let runtime = runtimes[agentID], runtime.connected, let backend = runtime.backend else { throw ServiceError(message: "Reconnect that agent before creating a session.") }
        let session = try await backend.create(title.isEmpty ? "New session" : title)
        runtime.sessions.insert(session, at: 0); runtime.saveNow()
        return SessionAddress(agentID: agentID, sessionID: session.id)
    }
    func setVoiceTarget(_ address: SessionAddress?) {
        voiceTarget = address
        voice.agentID = address?.agentID; voice.sessionID = address?.sessionID
        if voice.isActive { Task { await voice.updateDestination(address) } }
    }
    func startVoice(target: SessionAddress? = nil) async {
        if let target, session(target) == nil { error = "Choose an available agent and session."; return }
        if voice.isActive {
            guard voice.state != .connecting else { error = "Wait for Luna’s voice connection before choosing another destination."; return }
            setVoiceTarget(target); return
        }
        guard !openAIKey.isEmpty else { error = "Add Luna’s OpenAI API key in Settings to use voice."; return }
        setVoiceTarget(target); transcript = ""
        var context: JSONObject = ["current_time": .number(Date().timeIntervalSince1970), "time_zone": .string(TimeZone.current.identifier)]
        if let target { context["agent_id"] = .string(target.agentID); context["session_id"] = .string(target.sessionID) }
        do {
            try await voice.start(key: openAIKey, sessionID: "luna-home", title: "Luna", global: true,
                initialContext: context,
                execute: { [weak self] name, args, id in
                    guard let self else { throw CancellationError() }
                    return try await executeVoice(name, arguments: args, id: id)
                }, transcript: { [weak self] role, delta in
                    guard role == "user" else { return }
                    self?.transcript = String(((self?.transcript ?? "") + delta).suffix(600))
                }, switchSession: { _ in })
            setVoiceTarget(voiceTarget)
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    func executeVoice(_ name: String, arguments args: JSONObject, id: String) async throws -> JSONObject {
        switch name {
        case "pause_microphone":
            voice.setMicrophoneMuted(true)
            return ["microphone_paused": .bool(true), "note": .string("Microphone transmission is paused. The user must tap Resume microphone to speak again. Agent work and playback continue.")]
        case "list_agents":
            return ["agents": .array(profiles.map { .object(agentDetails($0)) }),
                "source": .string("local_state"), "current_time": .number(Date().timeIntervalSince1970), "time_zone": .string(TimeZone.current.identifier)]
        case "find_agents":
            let matches = findAgents(named: args["name"]?.string ?? "")
            return ["agents": .array(matches.map { .object(agentDetails($0)) }), "source": .string("local_state"),
                    "ambiguous": .bool(matches.count > 1),
                    "note": .string(matches.isEmpty ? "No saved agent matches that name. Ask which agent the user means or list available agents." : matches.count > 1 ? "Multiple saved agents match. Ask the user which one; never choose the first automatically." : "Use this agent_id for the requested agent. No agent was contacted.")]
        case "list_sessions":
            let agent = args["agent_id"]?.string
            if let agent { _ = try runtime(agent) }
            let offset = Self.boundedInteger(args["offset"], default: 0, maximum: 1_000_000)
            let rows = allSessions.filter { agent == nil || $0.address.agentID == agent }
            return ["sessions": .array(rows.dropFirst(offset).prefix(50).map { .object([
                "agent_id": .string($0.address.agentID), "agent_name": .string($0.agentName), "session_id": .string($0.address.sessionID),
                "title": .string($0.session.title), "updated_at": .number($0.updatedAt), "connected": .bool($0.online)]) }),
                "has_more": .bool(offset + 50 < rows.count), "source": .string("local_cache")]
        case "search_local_context":
            let hits = memory.search(args["query"]?.string ?? "", agentID: args["agent_id"]?.string, sessionID: args["session_id"]?.string,
                                     after: args["after"]?.number, before: args["before"]?.number, limit: Self.boundedInteger(args["limit"], default: 10, maximum: 20))
            return ["matches": .array(hits.map { .object($0.json) }), "source": .string("local_cache"),
                    "note": .string("Search only covers recent messages retained on this device. No external agent was contacted.")]
        case "get_session_context", "get_response_details":
            let (address, runtime) = try target(args)
            syncMemory(address.agentID)
            var context = memory.context(address)?.json ?? ["messages": .array([]), "source": .string("local_cache"), "note": .string("This session has not been cached yet.")]
            if name == "get_response_details" {
                context["runs"] = .array(runtime.runs.values.filter { $0.sessionID == address.sessionID }.sorted { $0.created > $1.created }.prefix(5).map {
                    .object(["request_id": .string($0.id), "status": .string($0.status), "output": .string(String($0.output.prefix(6_000))), "error": $0.error.map(JSONValue.string) ?? .null])
                })
            }
            return context
        case "select_session":
            let (address, _) = try target(args)
            setVoiceTarget(address); open(address)
            return ["agent_id": .string(address.agentID), "session_id": .string(address.sessionID), "status": .string("selected"),
                    "note": .string("Voice remains connected. Continue using these explicit IDs for requests.")]
        case "create_session":
            guard let agent = args["agent_id"]?.string else { throw ServiceError(message: "Choose an exact agent ID first.") }
            let address = try await createSession(agentID: agent, title: args["title"]?.string ?? "New session")
            setVoiceTarget(address); open(address)
            return ["agent_id": .string(agent), "session_id": .string(address.sessionID), "status": .string("created")]
        case "refresh_session":
            let (address, runtime) = try target(args)
            guard runtime.connected else { throw ServiceError(message: "That agent is offline. Cached context is still available.") }
            let before = runtime.historyFetchedAt[address.sessionID]
            await runtime.loadMessages(address.sessionID)
            syncMemory(address.agentID)
            return ["refreshed": .bool(runtime.historyFetchedAt[address.sessionID] != before), "context": .object(memory.context(address)?.json ?? [:])]
        case "send_prompt", "stop_agent":
            let (address, runtime) = try target(args)
            for (otherID, other) in runtimes {
                if let existing = other.coordinator?.records[id], otherID != address.agentID || existing.sessionID != address.sessionID {
                    throw ServiceError(message: "That voice request already belongs to a different destination.", statusCode: 409)
                }
            }
            var result = try await runtime.executeVoice(name, arguments: args, id: id, boundSession: address.sessionID)
            if name == "stop_agent", runtime.profile?.kind == .openAICompatible {
                result["note"] = .string("The local reply stream was stopped. This connector cannot confirm cancellation of work on the remote agent.")
            }
            if name == "send_prompt" { setVoiceTarget(address); open(address); runtime.saveNow() }
            return result.merging(["agent_id": .string(address.agentID), "session_id": .string(address.sessionID)]) { _, new in new }
        case "get_agent_tools", "get_agent_skills":
            guard let agent = args["agent_id"]?.string else { throw ServiceError(message: "Choose an exact agent ID first.") }
            let runtime = try runtime(agent)
            guard runtime.connected, let backend = runtime.backend else { throw ServiceError(message: "Reconnect that agent to read its capabilities.") }
            return try await (name == "get_agent_tools" ? backend.tools() : backend.skills())
        default: throw ServiceError(message: "Unknown Luna voice command.")
        }
    }
    private func runtime(_ id: String) throws -> AppStore {
        guard profiles.contains(where: { $0.id == id }), let runtime = runtimes[id] else { throw ServiceError(message: "Choose an exact agent ID from list_agents.") }
        return runtime
    }
    private static func boundedInteger(_ value: JSONValue?, default fallback: Int, maximum: Int) -> Int {
        guard let number = value?.number, number.isFinite else { return fallback }
        return Int(min(Double(maximum), max(0, number)))
    }
    private func target(_ args: JSONObject) throws -> (SessionAddress, AppStore) {
        guard let agent = args["agent_id"]?.string, let sid = args["session_id"]?.string else { throw ServiceError(message: "Specify both agent_id and session_id; never infer a destination from the screen.") }
        let runtime = try runtime(agent)
        guard runtime.sessions.contains(where: { $0.id == sid }) else { throw ServiceError(message: "That session does not belong to the selected agent. List its sessions first.") }
        return (SessionAddress(agentID: agent, sessionID: sid), runtime)
    }
    func sceneChanged(background: Bool) async {
        backgrounded = background; notices.expire()
        if background && !voice.isActive { textTask?.cancel() }
        await withTaskGroup(of: Void.self) { group in
            for runtime in runtimes.values { group.addTask { await runtime.sceneChanged(background: background) } }
        }
        try? memory.save()
    }
    func startDemo() async {
        demo = true; started = true
        for runtime in runtimes.values { await runtime.disconnect() }
        profiles = []; runtimes = [:]; navigation = []; memory = try! LocalMemory()
        for name in ["Hermes demo", "Research demo"] {
            let profile = AgentProfile(name: name, kind: .hermes, address: "https://demo.invalid")
            profiles.append(profile)
            do { try attach(profile, key: "demo"); await connectAgent(profile.id) }
            catch { self.error = error.localizedDescription }
        }
        if ProcessInfo.processInfo.arguments.contains("--show-chat"), let first = recentSessions.first { open(first.address) }
    }
}
