import SwiftUI

struct ChatView: View {
    @Bindable var store: AppStore
    let session: AgentSession
    @State private var sending = false
    @State private var showingModels = false
    @State private var showingTasks = false
    @State private var showingPhotoOptions = false
    @State private var importingPhotos = false
    @State private var followingLatest = true
    @State private var userScrolling = false
    @State private var bottomScrollRequest = 0
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @FocusState private var composerFocused: Bool
    private var sessionRuns: [AgentRun] {
        Self.visibleRuns(sessionID: session.id, runs: store.runs.values)
    }
    private var needsReview: Bool {
        store.runs.values.contains { $0.sessionID == session.id && $0.status == "unknown" && $0.historyReconciled != true }
    }
    static func visibleRuns(sessionID: String, runs: Dictionary<String, AgentRun>.Values) -> [AgentRun] {
        runs.filter { $0.sessionID == sessionID && $0.historyReconciled != true }
            .sorted { $0.created == $1.created ? $0.id < $1.id : $0.created < $1.created }
    }
    private var draft: Binding<String> { Binding(get: { store.drafts[session.id] ?? "" }, set: { store.drafts[session.id] = $0 }) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 7) {
                    Rectangle().fill(Palette.line).frame(height: 1)
                    Text(store.demo ? "DEMO CONVERSATION" : "AGENT SESSION")
                        .font(.system(size: 9, weight: .semibold)).tracking(1.5).fixedSize()
                    Rectangle().fill(Palette.line).frame(height: 1)
                }.foregroundStyle(Palette.muted).padding(.top, 10)
                if store.historyHasMore[session.id] == true {
                    Button("Load earlier messages") { Task { await store.loadMessages(session.id, older: true) } }
                        .font(.caption).frame(maxWidth: .infinity)
                }
                ForEach(store.messages[session.id] ?? []) { message in
                    MessageView(message: message, agentName: store.agentName).id(message.id)
                }
                ForEach(sessionRuns) { run in
                    RunCard(store: store, run: run)
                }
                if (store.messages[session.id] ?? []).isEmpty && sessionRuns.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        LunaMark(size: 56)
                        Text("What’s on your mind?").font(.system(size: 30, design: .serif))
                        Text("Write a prompt or start a voice conversation. Your agent’s work will appear here.")
                            .foregroundStyle(Palette.muted).font(.body)
                    }.padding(.vertical, 48)
                }
            }.padding(.horizontal, 22).padding(.bottom, 19)
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Let SwiftUI preserve the content edge through lazy measurement and
        // keyboard resizing; switching to top anchoring preserves a reader's offset.
        .defaultScrollAnchor(followingLatest && !userScrolling ? .bottom : .top, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.canvas)
        .onScrollPhaseChange { _, phase, context in
            userScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
            if userScrolling || phase == .idle {
                followingLatest = Self.isNearBottom(context.geometry)
            }
        }
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { old, new in
            let layoutChanged = old.contentSize != new.contentSize || old.containerSize != new.containerSize
                || old.contentInsets != new.contentInsets
            if userScrolling {
                followingLatest = Self.isNearBottom(new)
            } else if layoutChanged {
                // Rich text can finish measuring after the native resize adjustment.
                // Re-resolve the edge without treating that growth as a user scroll.
                if followingLatest, new.containerSize.height > 0 { bottomScrollRequest += 1 }
            } else if old.contentOffset != new.contentOffset {
                followingLatest = Self.isNearBottom(new)
            }
        }
        .onChange(of: followingLatest && !userScrolling) { _, follow in
            if follow { bottomScrollRequest += 1 }
        }
        .task(id: bottomScrollRequest) {
            guard bottomScrollRequest > 0 else { return }
            // Let lazy rows finish their current layout before resolving the edge.
            await Task.yield()
            guard !Task.isCancelled, followingLatest, !userScrolling else { return }
            scrollPosition.scrollTo(edge: .bottom)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .background(ChatPhotoControls(store: store, sessionID: session.id, showingOptions: $showingPhotoOptions, importing: $importingPhotos))
        .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Palette.canvas, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if needsReview {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingTasks = true } label: { Image(systemName: "exclamationmark.circle") }
                        .foregroundStyle(Palette.orange).accessibilityLabel("Review interrupted task")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Choose model", systemImage: "cpu") { showingModels = true }
                    if store.profile != nil {
                        Button("Use this session for Luna voice", systemImage: "waveform") { Task { await store.startVoice(session.id) } }
                    }
                    Button("Task history", systemImage: "clock.arrow.circlepath") { showingTasks = true }
                    Button("Refresh conversation", systemImage: "arrow.clockwise") { Task { await store.loadMessages(session.id) } }
                    Button("Copy session ID", systemImage: "doc.on.doc") { UIPasteboard.general.string = session.id }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Session actions")
            }
        }
        .task {
            await store.select(session.id)
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--show-models") { showingModels = true }
            #endif
        }
        .sheet(isPresented: $showingModels) { SessionModelPicker(store: store, sessionID: session.id) }
        .sheet(isPresented: $showingTasks) { TaskHistoryView(store: store, sessionID: session.id) }
    }

    private static func isNearBottom(_ geometry: ScrollGeometry) -> Bool {
        // visibleRect includes the bottom inset occupied by the composer/keyboard.
        geometry.visibleRect.maxY - geometry.contentInsets.bottom >= geometry.contentSize.height - 80
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if store.reconnecting && store.notices.contains("reconnecting") {
                NoticeCard(dismissLabel: "Dismiss connection status", dismiss: { store.notices.dismiss("reconnecting") }) {
                    Label("Reconnecting · your agent keeps working", systemImage: "wifi.slash")
                        .font(.caption).foregroundStyle(Palette.orange).padding(.vertical, 8)
                }
            }
            if store.profile == nil && store.voice.isActive && store.voice.sessionID == session.id { VoicePanel(store: store) }
            if !store.voice.isActive {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Button { composerFocused = false; showingModels = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: store.usesAutoModel(session.id) ? "sparkles" : "cpu")
                                Text(store.modelLabel(session.id)).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            }.font(.caption).foregroundStyle(Palette.forest)
                        }.accessibilityLabel("Choose agent model. " + store.modelLabel(session.id))
                        if store.usesAutoModel(session.id), let run = store.latestAutoRun(session.id), run.isActive {
                            if run.status == "choosing_model" {
                                Text("Choosing a model for this request…").font(.caption2).foregroundStyle(Palette.muted)
                            } else if let decision = run.modelDecision {
                                Text("Using " + decision.selection.model).font(.caption2).foregroundStyle(Palette.muted)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    if store.changingModels.contains(session.id) { ProgressView().controlSize(.mini) }
                }.padding(.horizontal, 5)
                let photos = store.photoDrafts[session.id] ?? []
                if !photos.isEmpty {
                    PhotoDraftStrip(photos: photos, disabled: sending || importingPhotos) { id in
                        store.photoDrafts[session.id]?.removeAll { $0.id == id }
                    }
                }
                if importingPhotos { ProgressView("Preparing photos…").font(.caption).foregroundStyle(Palette.muted) }
                MessageComposer(text: draft, placeholder: "Ask \(store.agentName)…", messageLabel: "Message to " + store.agentName,
                    sending: sending || importingPhotos, canSend: store.connected && !store.changingModels.contains(session.id),
                    voiceIsActive: false, hasAttachments: !photos.isEmpty, canAddPhoto: photos.count < ChatPhoto.maxCount,
                    onAddPhoto: store.canAttachPhotos ? { showingPhotoOptions = true } : nil, focus: $composerFocused,
                    onMicrophone: { Task { await store.startVoice(session.id) } },
                    onSend: {
                        // Only a send from this composer explicitly resumes following.
                        // Runs arriving through Luna voice/API preserve a reader's place.
                        followingLatest = true
                        bottomScrollRequest += 1
                        sending = true
                        Task { await store.send(session.id); sending = false }
                    })
                Text(store.demo ? "Demo connector · sample agent responses" : !store.connected ? "Cached conversation · reconnect the agent to send" : store.agentName + " · this conversation stays in its session")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }.padding(.horizontal, 18).padding(.top, 10)
            .background(Palette.canvas.opacity(0.3))
    }
}

private struct RunCard: View {
    @Bindable var store: AppStore
    let run: AgentRun
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            MessageView(message: ChatMessage(id: run.id + "-user", role: "user", content: run.text, createdAt: run.created, photos: run.photos))
            if run.isActive {
                HStack {
                    ProgressView().controlSize(.mini)
                    Text(run.statusLabel).font(.caption.weight(.medium))
                    Spacer()
                    Button(store.profile?.kind == .openAICompatible ? "Stop reply" : "Stop agent", role: .destructive) { Task { await store.stopRun(run.id) } }
                        .font(.caption).disabled(run.status == "stopping")
                }.foregroundStyle(Palette.muted)
                modelDecision
            } else if store.notices.contains(TransientNotices.run(run.id)) {
                NoticeCard(dismissLabel: "Dismiss task status", dismiss: { store.notices.dismiss(TransientNotices.run(run.id)) }) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(run.statusLabel, systemImage: run.status == "completed" ? "checkmark.circle" : "exclamationmark.circle")
                            .font(.caption.weight(.medium)).foregroundStyle(Palette.muted)
                        if let error = run.error { Text(error).font(.callout).foregroundStyle(Palette.orange).textSelection(.enabled) }
                        modelDecision
                    }.padding(.vertical, 8)
                }
            }
            let activities = (store.activity[run.sessionID] ?? []).filter { $0.runID == run.id }
            if !activities.isEmpty {
                if activities.contains(where: { !$0.finished }) {
                    ToolActivityView(activities: activities)
                } else if store.notices.contains(TransientNotices.activity(run.sessionID)) {
                    NoticeCard(dismissLabel: "Dismiss finished activity", dismiss: { store.notices.dismiss(TransientNotices.activity(run.sessionID)) }) {
                        ToolActivityView(activities: activities)
                    }
                }
            }
            ForEach(store.approvals.values.filter { $0.sessionID == run.sessionID && $0.runID == run.id }.sorted { $0.id < $1.id }) { approval in
                VStack(alignment: .leading, spacing: 12) {
                    Label("Hermes needs your approval", systemImage: "hand.raised").font(.headline)
                    Text(approval.description).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Deny") { Task { await store.resolve(approval, choice: "deny") } }.buttonStyle(.bordered)
                        Button("Allow once") { Task { await store.resolve(approval, choice: "once") } }.buttonStyle(.borderedProminent)
                            .foregroundStyle(Palette.onAccent)
                    }
                }.padding(16).background(Palette.userBubble, in: RoundedRectangle(cornerRadius: 16))
            }
            if !run.output.isEmpty {
                MessageView(message: ChatMessage(id: run.id + "-assistant", role: "assistant", content: run.output, createdAt: run.created), agentName: store.agentName)
            }
        }.id(run.id)
    }
    @ViewBuilder private var modelDecision: some View {
        if let decision = run.modelDecision {
            VStack(alignment: .leading, spacing: 5) {
                Label("Auto requested " + decision.selection.model, systemImage: "sparkles")
                    .font(.caption.weight(.medium)).foregroundStyle(Palette.forest)
                Text(decision.reason).font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
}

struct MessageView: View {
    let message: ChatMessage
    var agentName: String = "Hermes"
    var body: some View {
        if message.role == "user" {
            VStack(alignment: .trailing, spacing: 7) {
                Text("YOU").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(Palette.muted)
                ForEach(message.photos ?? []) { photo in ChatPhotoView(photo: photo) }
                if !message.content.isEmpty {
                    Text(message.content).font(.body).textSelection(.enabled).padding(16)
                        .background(Palette.userBubble, in: RoundedRectangle(cornerRadius: 19))
                }
            }.frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 30)
        } else if message.role == "tool" {
            DisclosureGroup {
                Text(message.content).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } label: { Label(message.toolName ?? "Tool result", systemImage: "wrench.and.screwdriver").font(.caption) }
                .foregroundStyle(Palette.muted)
        } else {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 7) {
                    LunaMark(size: 22)
                    Text(agentName.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1.4).lineLimit(1)
                    Spacer()
                    Button { UIPasteboard.general.string = message.content } label: { Image(systemName: "doc.on.doc").font(.caption) }
                        .foregroundStyle(Palette.muted).accessibilityLabel("Copy response")
                }.foregroundStyle(Palette.forest)
                RichMessage(text: message.content).equatable()
                ForEach(message.photos ?? []) { photo in ChatPhotoView(photo: photo) }
            }
        }
    }
}

struct ToolActivityView: View {
    let activities: [Activity]
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(activities) { activity in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: activity.failed ? "exclamationmark.circle" : activity.finished ? "checkmark.circle" : "circle.dotted")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activity.title).font(.caption.weight(.medium))
                            Text(activity.detail).font(.caption).foregroundStyle(Palette.muted).lineLimit(6)
                        }
                    }
                }
            }.padding(.top, 10)
        } label: {
            Label("Agent activity · \(activities.count)", systemImage: "sparkle").font(.caption.weight(.medium))
        }.padding(14).foregroundStyle(Palette.forest).background(Palette.userBubble.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct VoicePanel: View {
    @Bindable var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title3).foregroundStyle(Palette.forest)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.voice.state.rawValue).font(.subheadline.weight(.semibold))
                    Text("Voice with this session").font(.caption2).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button { store.voice.toggleMicrophone() } label: {
                    Image(systemName: store.voice.microphoneMuted ? "mic.slash" : "mic")
                }.disabled(store.voice.state == .connecting).accessibilityLabel(store.voice.microphoneMuted ? "Unmute microphone" : "Mute microphone")
                Button { store.voice.toggleSpeaker() } label: {
                    Image(systemName: store.voice.speakerMuted ? "speaker.slash" : "speaker.wave.2")
                }.accessibilityLabel(store.voice.speakerMuted ? "Hear replies" : "Stop speaking")
                Button { Task { await store.voice.stop() } } label: { Image(systemName: "xmark.circle.fill") }
                    .accessibilityLabel("End voice, keep agent working")
            }.buttonStyle(.borderless)
            if !store.voiceTranscript.isEmpty {
                Text(String(store.voiceTranscript.suffix(180))).font(.caption).foregroundStyle(Palette.muted).lineLimit(3)
            }
        }.padding(14).background(Palette.userBubble, in: RoundedRectangle(cornerRadius: 18))
    }
}
