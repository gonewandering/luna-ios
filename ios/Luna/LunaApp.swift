import SwiftUI
import AVFoundation

@main struct LunaApp: App {
    @State private var store = LunaApp.makeStore()
    @Environment(\.scenePhase) private var scenePhase

    @MainActor private static func makeStore() -> LunaStore {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--preview-notices") {
            return LunaStore(root: URL.applicationSupportDirectory.appending(path: "Luna/previews"), loadSavedState: false)
        }
        #endif
        return LunaStore()
    }
    var body: some Scene {
        WindowGroup {
            LunaRootView(store: store)
                .tint(Palette.forest).preferredColorScheme(.dark)
                .task {
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
                    #if DEBUG && targetEnvironment(simulator)
                    if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--preview-notices") {
                        await store.startDemo()
                        if ProcessInfo.processInfo.arguments.contains("--preview-notices"), let profile = store.profiles.first,
                           let runtime = store.runtimes[profile.id] {
                            runtime.previewNotices(); runtime.saveNow()
                            if let session = runtime.sessions.first { store.open(SessionAddress(agentID: profile.id, sessionID: session.id)) }
                        }
                        return
                    }
                    let environment = ProcessInfo.processInfo.environment
                    if let address = environment["LUNA_HERMES_URL"], let key = environment["LUNA_HERMES_KEY"], !key.isEmpty {
                        do {
                            if let voiceKey = environment["LUNA_OPENAI_KEY"] { try store.saveVoiceKey(voiceKey) }
                            let profile = store.profiles.first { $0.address == address } ?? AgentProfile(name: "Hermes", kind: .hermes, address: address)
                            try await store.saveAgent(profile, key: key)
                        } catch { store.error = error.localizedDescription }
                    }
                    #endif
                    await store.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { Task { await store.sceneChanged(background: true) } }
                    else if phase == .active { Task { await store.sceneChanged(background: false) } }
                }
                .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
                    if let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                       value == AVAudioSession.InterruptionType.began.rawValue { Task { await store.voice.stop() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { note in
                    if let value = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                       value == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { await store.voice.stop() } }
                }
                .onOpenURL { url in
                    guard url.scheme == "luna", url.host == "session" else { return }
                    let agentID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "agent" }?.value
                    let matches = store.allSessions.filter { $0.address.sessionID == url.lastPathComponent && (agentID == nil || $0.address.agentID == agentID) }
                    if matches.count == 1 { store.open(matches[0].address) }
                    else { store.error = "Choose the agent for this conversation from Home." }
                }
        }
    }
}
