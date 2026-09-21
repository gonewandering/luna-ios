import SwiftUI

struct AgentsSettingsView: View {
    @Bindable var store: LunaStore
    @Environment(\.dismiss) private var dismiss
    @State private var voiceKey = ""
    @State private var editor: AgentProfile?
    @State private var saved = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Agents") {
                    ForEach(store.profiles) { profile in
                        Button { editor = profile } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(profile.name).foregroundStyle(Palette.ink)
                                    Text(profile.kind.label).font(.caption).foregroundStyle(Palette.muted)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                            }
                        }.disabled(store.demo)
                    }
                    if !store.demo {
                        Button("Add agent", systemImage: "plus") { editor = AgentProfile(name: "", kind: .hermes, address: "") }
                    }
                }.listRowBackground(Palette.card)
                Section {
                    SecureField("OpenAI API key", text: $voiceKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(saved ? "Saved" : "Save OpenAI key") {
                        do { try store.saveVoiceKey(voiceKey); saved = true } catch { store.error = error.localizedDescription }
                    }.disabled(saved)
                } header: { Text("Luna and Auto mode") } footer: {
                    Text("Luna uses this key for voice, Home and agent-list messages, and Auto model selection. Direct text in a session uses that agent’s connection. Changes apply to Luna’s next text request or voice connection.")
                }.listRowBackground(Palette.card)
                Section {
                    LabeledContent("Remembered sessions", value: String(store.memory.sessions.count))
                    Text("Luna keeps the latest 12 messages per session, organized by time. You can search them even when an agent is offline. Luna’s voice and text requests send retrieved context to OpenAI.")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Text("Keys stay in this device’s Keychain. Conversation memory is protected on this device. No Luna helper is required.")
                        .font(.caption).foregroundStyle(Palette.muted)
                } header: { Text("Local memory") }.listRowBackground(Palette.card)
                if store.demo { Text("These are temporary demo agents with sample conversations.").font(.caption).listRowBackground(Palette.card) }
            }
            .scrollContentBackground(.hidden).background(Palette.canvas).foregroundStyle(Palette.ink)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .safeAreaInset(edge: .bottom, spacing: 0) { LunaErrorNotice(store: store) }
            .onAppear { voiceKey = store.openAIKey }
            .onChange(of: voiceKey) { _, _ in saved = false }
            .sheet(item: $editor) { profile in AgentEditor(store: store, profile: profile) }
        }
    }
}

struct AgentEditor: View {
    @Bindable var store: LunaStore
    @State var profile: AgentProfile
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var savedKey = ""
    @State private var saving = false
    @State private var removing = false
    private var existing: Bool { store.profiles.contains { $0.id == profile.id } }
    private var localNameOnly: Bool {
        guard let saved = store.profiles.first(where: { $0.id == profile.id }) else { return false }
        return saved.kind == profile.kind && saved.address == profile.address && saved.defaultModel == profile.defaultModel && key == savedKey
    }
    private var unchangedName: Bool {
        store.profiles.first(where: { $0.id == profile.id })?.name == profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Agent name", text: $profile.name).accessibilityIdentifier("agent-name")
                } header: { Text("Name in Luna") } footer: {
                    Text("Saved on this device. Use this name when asking Luna to find or use the agent. Renaming works offline and keeps running tasks connected.")
                }.listRowBackground(Palette.card)
                Section {
                    Picker("Connector", selection: $profile.kind) { ForEach(AgentKind.allCases) { Text($0.label).tag($0) } }
                    TextField(profile.kind == .hermes ? "https://your-hermes-server" : "https://your-agent-server/v1", text: $profile.address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Agent address")
                    SecureField(profile.kind == .hermes ? "Agent API key" : "API key (if required)", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Connection") } footer: { Text("This key is sent only to this agent’s address. Use Tailscale on your phone for private Tailscale servers.") }
                    .listRowBackground(Palette.card)
                if profile.kind == .openAICompatible {
                    Section {
                        TextField("Default model ID (optional)", text: $profile.defaultModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } footer: {
                        Text("Requires a models API and streaming Chat Completions. Luna keeps these sessions on this device. You can choose a model in each conversation; remote tools and resumable tasks depend on the endpoint.")
                    }.listRowBackground(Palette.card)
                }
                Section {
                    Button {
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                if localNameOnly {
                                    profile = try store.renameAgent(profile.id, name: profile.name)
                                    dismiss()
                                } else {
                                    profile = try await store.saveAgent(profile, key: key)
                                    savedKey = key
                                    if store.runtimes[profile.id]?.connected == true { dismiss() }
                                }
                            } catch { store.error = error.localizedDescription }
                        }
                    } label: {
                        HStack { Text(localNameOnly ? "Save name" : "Save and connect"); Spacer(); if saving { ProgressView() } else { Image(systemName: "checkmark") } }
                    }.disabled(saving || profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (localNameOnly ? unchangedName : profile.address.isEmpty || (profile.kind == .hermes && key.isEmpty)))
                }.listRowBackground(Palette.card)
                if existing {
                    Section {
                        Button("Remove agent", role: .destructive) { removing = true }.disabled(saving)
                    } footer: { Text("Removes this agent’s key and local conversations from Luna. Remote sessions remain on the agent.") }
                        .listRowBackground(Palette.card)
                }
            }
            .scrollContentBackground(.hidden).background(Palette.canvas).foregroundStyle(Palette.ink)
            .navigationTitle(existing ? "Edit agent" : "Add agent").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.disabled(saving) } }
            .safeAreaInset(edge: .bottom, spacing: 0) { LunaErrorNotice(store: store) }
            .onAppear { savedKey = store.key(for: profile); key = savedKey }
            .interactiveDismissDisabled(saving)
            .confirmationDialog("Remove \(profile.name) and its local memory?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove agent", role: .destructive) {
                    Task { do { try await store.removeAgent(profile.id); dismiss() } catch { store.error = error.localizedDescription } }
                }
            }
        }
    }
}
