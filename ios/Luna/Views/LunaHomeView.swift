import SwiftUI

struct LunaRootView: View {
    @Bindable var store: LunaStore
    @State private var settings = false
    @State private var lunaConversation = false
    private var browsingAgentID: String? { if case .agent(let id) = store.navigation.last { return id }; return nil }
    var body: some View {
        NavigationStack(path: $store.navigation) {
            LunaHomeView(store: store, settings: $settings)
                .safeAreaInset(edge: .bottom, spacing: 0) { dock(showComposer: true) }
                .navigationDestination(for: LunaRoute.self) { route in
                    switch route {
                    case .agent(let id):
                        if let profile = store.profiles.first(where: { $0.id == id }), let runtime = store.runtimes[id] {
                            AgentSessionsView(store: store, profile: profile, runtime: runtime)
                                .safeAreaInset(edge: .bottom, spacing: 0) { dock(showComposer: true, agentID: id) }
                        }
                    case .session(let address):
                        if let session = store.session(address), let runtime = store.runtimes[address.agentID] {
                            ChatView(store: runtime, session: session)
                                .safeAreaInset(edge: .top, spacing: 0) {
                                    HStack {
                                        Text(runtime.agentName).font(.caption.weight(.medium))
                                        Spacer()
                                        if !runtime.connected { Text("Cached on this device").font(.caption2) }
                                    }.foregroundStyle(Palette.muted).padding(.horizontal, 22).padding(.vertical, 6).background(Palette.canvas)
                                }
                                .safeAreaInset(edge: .bottom, spacing: 0) { ErrorNotice(store: runtime) }
                                .safeAreaInset(edge: .bottom, spacing: 0) { dock(showComposer: false) }
                        }
                    }
                }
        }
        .foregroundStyle(Palette.ink).background(Palette.canvas)
        .sheet(isPresented: $settings) { AgentsSettingsView(store: store) }
        .sheet(isPresented: $lunaConversation) { LunaConversationView(store: store, conversation: store.lunaText, agentID: browsingAgentID) }
        .onChange(of: store.navigation) { _, _ in lunaConversation = false }
        .onChange(of: store.voice.failure) { _, failure in if let failure { store.error = failure } }
    }

    private func dock(showComposer: Bool, agentID: String? = nil) -> some View {
        VStack(spacing: 0) {
            LunaErrorNotice(store: store)
            LunaTextPreview(store: store, showConversation: { lunaConversation = true })
            if store.voice.isActive { LunaVoiceDock(store: store) }
            if showComposer {
                LunaComposer(store: store, conversation: store.lunaText, agentID: agentID,
                             showConversation: { lunaConversation = true })
            }
        }
    }
}

struct LunaHomeView: View {
    @Bindable var store: LunaStore
    @Binding var settings: Bool
    var body: some View {
        List {
            Section {
                    ForEach(store.profiles) { profile in
                        if let runtime = store.runtimes[profile.id] {
                            NavigationLink(value: LunaRoute.agent(profile.id)) {
                                HStack(spacing: 14) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(profile.name).font(.headline)
                                        Text(runtime.connecting ? "Connecting…" : runtime.connected && !runtime.reconnecting ? profile.kind.label : "Offline · local context available")
                                            .font(.caption).foregroundStyle(Palette.muted)
                                    }
                                    Spacer()
                                    Circle().fill(runtime.connected && !runtime.reconnecting ? Color.green : Color.gray).frame(width: 8, height: 8)
                                        .accessibilityLabel(runtime.connected && !runtime.reconnecting ? "Connected" : "Offline")
                                }.padding(.vertical, 8)
                            }.listRowBackground(Palette.card)
                        }
                    }
                    if store.profiles.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("A place for your agents").font(.system(size: 26, design: .serif))
                            Text("Connect an agent, then ask Luna to pick up the conversation.").foregroundStyle(Palette.muted)
                            Button("Add an agent", systemImage: "plus") { settings = true }.buttonStyle(.borderedProminent).foregroundStyle(Palette.onAccent)
                            Button("Try the local demo") { Task { await store.startDemo() } }.font(.caption)
                        }.padding(.vertical, 12).listRowBackground(Palette.card)
                    }
            } header: { homeSectionLabel("AGENTS") }
            Section {
                ForEach(store.recentSessions) { row in
                    NavigationLink(value: LunaRoute.session(row.address)) {
                        HomeSessionRow(row: row)
                    }.listRowBackground(Palette.card)
                }
                if store.recentSessions.isEmpty && !store.profiles.isEmpty {
                    Text("Open an agent to start a conversation. Your latest five sessions will appear here.")
                        .font(.callout).foregroundStyle(Palette.muted).listRowBackground(Color.clear)
                }
            } header: { homeSectionLabel("SESSIONS") }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Palette.canvas)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .toolbarBackground(Palette.canvas, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                HStack(spacing: 8) { LunaMark(size: 28); Text("luna").font(.system(size: 27, weight: .medium, design: .serif)) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Agent and voice settings")
            }
        }
        .refreshable {
            await withTaskGroup(of: Void.self) { group in
                for profile in store.profiles {
                    group.addTask {
                        if await store.runtimes[profile.id]?.connected == true { await store.runtimes[profile.id]?.refreshSessions() }
                        else { await store.connectAgent(profile.id) }
                    }
                }
            }
        }
    }

    private func homeSectionLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.2)
            .foregroundStyle(Palette.sectionLabel).textCase(nil)
    }
}

struct HomeSessionRow: View {
    let row: HomeSession
    var preview: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.session.title).font(.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if row.unread { Circle().fill(Palette.orange).frame(width: 6, height: 6).accessibilityLabel("Unread response") }
            }
            Text((preview ?? row.session.preview).replacingOccurrences(of: "\n", with: " "))
                .font(.subheadline).foregroundStyle(Palette.muted).lineLimit(2)
            HStack {
                Text(row.agentName + (row.active ? " · working" : row.online ? "" : " · cached"))
                Spacer()
                Text(Date(timeIntervalSince1970: row.updatedAt), style: .relative)
            }.font(.caption2).foregroundStyle(Palette.muted)
        }.padding(.vertical, 7)
    }
}

struct AgentSessionsView: View {
    @Bindable var store: LunaStore
    let profile: AgentProfile
    @Bindable var runtime: AppStore
    @State private var search = ""
    @State private var creating = false
    @State private var title = ""
    @State private var editing = false
    @State private var renaming: AgentSession?
    @State private var renameTitle = ""
    var body: some View {
        List {
            if !runtime.connected || runtime.reconnecting {
                Button { Task { await store.connectAgent(profile.id) } } label: {
                    HStack { Text(runtime.connecting ? "Connecting…" : "Reconnect " + profile.name); Spacer(); if runtime.connecting { ProgressView() } }
                }.disabled(runtime.connecting).listRowBackground(Palette.card)
                ErrorNotice(store: runtime).listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            ForEach(store.allSessions.filter { $0.address.agentID == profile.id && (search.isEmpty || $0.session.title.localizedCaseInsensitiveContains(search)) }) { row in
                NavigationLink(value: LunaRoute.session(row.address)) { HomeSessionRow(row: row) }.listRowBackground(Palette.card)
                    .contextMenu { Button("Rename", systemImage: "pencil") { renaming = row.session; renameTitle = row.session.title }.disabled(!runtime.connected) }
            }
            if runtime.sessionsHasMore { Button("Load more sessions") { Task { await runtime.refreshSessions(more: true) } } }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Palette.canvas)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .searchable(text: $search, prompt: "Find a conversation")
        .navigationTitle(profile.name).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { title = ""; creating = true } label: { Image(systemName: "plus") }
                    .disabled(!runtime.connected).accessibilityLabel("New session")
            }
            if !store.demo {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Edit agent")
                }
            }
        }
        .refreshable { await runtime.refreshSessions() }
        .sheet(isPresented: $editing) { AgentEditor(store: store, profile: profile) }
        .alert("New session", isPresented: $creating) {
            TextField("Session title", text: $title)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                Task { do { store.open(try await store.createSession(agentID: profile.id, title: title)) } catch { store.error = error.localizedDescription } }
            }
        }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Session title", text: $renameTitle)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let sid = renaming?.id { Task { await runtime.renameSession(sid, title: renameTitle) } }
                renaming = nil
            }
        }
    }
}

struct LunaVoiceDock: View {
    @Bindable var store: LunaStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.voice.isActive {
                HStack(spacing: 12) {
                    Image(systemName: store.voice.microphoneMuted ? "mic.slash" : "waveform").foregroundStyle(Palette.forest)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.voice.microphoneMuted ? "Microphone paused" : store.voice.state.rawValue).font(.subheadline.weight(.semibold))
                        Text(store.voiceTargetLabel).font(.caption2).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { store.voice.toggleSpeaker() } label: { Image(systemName: store.voice.speakerMuted ? "speaker.slash" : "speaker.wave.2").frame(width: 36, height: 44) }
                        .accessibilityLabel(store.voice.speakerMuted ? "Hear replies" : "Mute replies")
                    Button { Task { await store.voice.stop() } } label: { Image(systemName: "xmark").frame(width: 36, height: 44) }.accessibilityLabel("End Luna voice")
                }
                Button { store.voice.toggleMicrophone() } label: {
                    Label(store.voice.microphoneMuted ? "Resume microphone" : "Pause microphone", systemImage: store.voice.microphoneMuted ? "mic" : "mic.slash")
                        .font(.caption.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 9)
                }.buttonStyle(.bordered).disabled(store.voice.state == .connecting)
            }
        }.padding(.horizontal, 18).padding(.vertical, 10).background(Palette.canvas)
    }
}

struct LunaErrorNotice: View {
    @Bindable var store: LunaStore
    var body: some View {
        if let error = store.error, store.notices.contains("error") {
            NoticeCard(dismissLabel: "Dismiss error", dismiss: { store.error = nil }) {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Palette.orange).padding(.vertical, 8)
            }.padding(.horizontal, 18).padding(.vertical, 8)
        }
    }
}
