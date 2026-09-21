import SwiftUI

struct SessionModelPicker: View {
    @Bindable var store: AppStore
    let sessionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var loading = false
    @State private var saving: HermesModelSelection?
    @State private var error: String?

    private var providers: [HermesModelProvider] {
        (store.modelCatalog?.availableProviders ?? []).sorted {
            let current = store.modelCatalog?.current?.provider
            if ($0.id == current) != ($1.id == current) { return $0.id == current }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    private func models(in provider: HermesModelProvider) -> [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return provider.models.filter { query.isEmpty || $0.localizedStandardContains(query) || provider.name.localizedStandardContains(query) }
    }
    private var canSelect: Bool {
        store.connected && store.supportsSessionModels && !store.modelChangeBlocked(sessionID) && saving == nil && !loading
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(store.modelLabel(sessionID)).font(.headline).textSelection(.enabled)
                        if store.usesAutoModel(sessionID) {
                            if let decision = store.latestAutoRun(sessionID)?.modelDecision {
                                Text("Last choice: " + decision.selection.model).font(.subheadline).foregroundStyle(Palette.forest)
                                Text(decision.reason).font(.caption).foregroundStyle(Palette.muted)
                            }
                        } else if let selected = store.sessionModels[sessionID] {
                            Text(store.modelCatalog?.providerName(selected.provider) ?? selected.provider)
                                .font(.subheadline).foregroundStyle(Palette.forest)
                        } else if let reported = store.sessions.first(where: { $0.id == sessionID })?.model {
                            Text("Last reported: " + reported).font(.caption).foregroundStyle(Palette.muted)
                        }
                        Text("Choose the model requested for typed and voice prompts in this conversation. Other sessions keep their own model.")
                            .font(.caption).foregroundStyle(Palette.muted)
                    }.padding(.vertical, 5)
                } header: { Text("This session") }
                .listRowBackground(Palette.card)

                Section {
                    Button {
                        do { try store.setSessionAutoModel(sessionID); dismiss() }
                        catch { self.error = error.localizedDescription }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "sparkles").foregroundStyle(Palette.forest).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Auto").font(.headline).foregroundStyle(Palette.ink)
                                Text("Lightweight models for quick questions. Stronger models for planning and difficult work.")
                                    .font(.caption).foregroundStyle(Palette.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if store.usesAutoModel(sessionID) { Image(systemName: "checkmark").foregroundStyle(Palette.forest) }
                        }.padding(.vertical, 6).contentShape(Rectangle())
                    }.disabled(!canSelect || (!store.demo && !store.voiceAvailable))
                    .accessibilityAddTraits(store.usesAutoModel(sessionID) ? [.isSelected] : [])
                } footer: {
                    Text(store.demo ? "The demo uses sample model choices and makes no OpenAI requests." :
                        store.voiceAvailable ? "Luna reviews each request and recent chat using your OpenAI key. Works with text and voice and adds a small OpenAI routing request." :
                        "Add your OpenAI API key in Settings to enable Auto.")
                }.listRowBackground(Palette.card)

                if !store.supportsSessionModels {
                    notice("This agent does not support model selection for individual sessions.")
                } else if store.modelChangeBlocked(sessionID) {
                    notice("You can change models after this session’s tasks finish. Check any task with an unknown outcome first.")
                }
                if let error {
                    Section {
                        Text(error).font(.callout).foregroundStyle(Palette.orange)
                        Button("Try again") { Task { await load(refresh: true) } }.disabled(loading || saving != nil)
                    }.listRowBackground(Palette.card)
                }
                if loading {
                    HStack(spacing: 12) { ProgressView(); Text("Loading models…").foregroundStyle(Palette.muted) }
                        .listRowBackground(Palette.card)
                }
                if !loading, error == nil, providers.allSatisfy({ models(in: $0).isEmpty }) {
                    notice(search.isEmpty ? "No available models were returned. Configure models on the agent, then refresh." : "No models match your search.")
                }
                ForEach(providers) { provider in
                    let models = models(in: provider)
                    if !models.isEmpty {
                        Section {
                            ForEach(models, id: \.self) { model in
                                modelRow(HermesModelSelection(provider: provider.id, model: model))
                            }
                        } header: { Text(provider.name) }
                        .listRowBackground(Palette.card)
                    }
                }
                Section {
                    Text(store.profile?.kind == .openAICompatible ? "Models come from this agent’s models API. Luna sends the chosen model with each request." : "Models come from providers configured on your Hermes server. Hermes’ existing session overrides and fallback rules still apply.")
                        .font(.caption).foregroundStyle(Palette.muted)
                }.listRowBackground(Palette.card)
            }
            .scrollContentBackground(.hidden).background(Palette.canvas)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models or providers")
            .navigationTitle("Session model").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(saving != nil)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh models", systemImage: "arrow.clockwise") { Task { await load(refresh: true) } }
                        .disabled(loading || saving != nil)
                }
            }
            .task { await load(refresh: false) }
            .interactiveDismissDisabled(saving != nil)
        }.tint(Palette.forest)
    }
    private func notice(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Palette.muted).listRowBackground(Palette.card)
    }
    private func modelRow(_ selection: HermesModelSelection) -> some View {
        Button {
            saving = selection; error = nil
            Task {
                do { try await store.setSessionModel(selection, sessionID: sessionID); dismiss() }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
                saving = nil
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selection.model).font(.subheadline).foregroundStyle(Palette.ink)
                    if selection == store.modelCatalog?.current {
                        Text("Server default").font(.caption2).foregroundStyle(Palette.muted)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if saving == selection { ProgressView() }
                else if store.sessionModels[sessionID] == selection { Image(systemName: "checkmark").foregroundStyle(Palette.forest) }
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.disabled(!canSelect)
        .accessibilityLabel(selection.model + ", " + (store.modelCatalog?.providerName(selection.provider) ?? selection.provider))
        .accessibilityAddTraits(store.sessionModels[sessionID] == selection ? [.isSelected] : [])
    }
    private func load(refresh: Bool) async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do { try await store.loadModels(refresh: refresh) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
