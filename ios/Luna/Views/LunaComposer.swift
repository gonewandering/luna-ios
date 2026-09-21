import SwiftUI

struct LunaComposer: View {
    @Bindable var store: LunaStore
    @Bindable var conversation: LunaTextConversation
    var agentID: String?
    var showConversation: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        if !store.voice.isActive {
            VStack(spacing: 10) {
                if !conversation.messages.isEmpty, let showConversation {
                    HStack {
                        Spacer()
                        Button(action: showConversation) { Image(systemName: "bubble.left.and.bubble.right") }
                            .font(.caption).accessibilityLabel("Conversation with Luna")
                    }.padding(.horizontal, 5)
                }
                MessageComposer(text: $conversation.draft, placeholder: "Ask Luna…", messageLabel: "Message to Luna",
                    sending: conversation.sending, voiceIsActive: false, focus: $focused,
                    onMicrophone: { Task { await store.startVoice() } },
                    onSend: { focused = false; store.sendLunaText(agentID: agentID) })
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 8)
            .background(Palette.canvas.opacity(0.3))
        }
    }
}

struct LunaTextPreview: View {
    @Bindable var store: LunaStore
    let showConversation: () -> Void
    var body: some View {
        if store.lunaText.sending || (!store.lunaText.replyHidden && store.lunaText.latestReply != nil) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: showConversation) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.lunaText.sending ? "Luna is thinking…" : "Luna").font(.caption.weight(.semibold)).foregroundStyle(Palette.forest)
                        if !store.lunaText.sending, let reply = store.lunaText.latestReply {
                            Text(reply.content).font(.callout).foregroundStyle(Palette.ink).lineLimit(4).multilineTextAlignment(.leading)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Opens your conversation with Luna")
                if store.lunaText.sending {
                    Button("Stop") { store.stopLunaText() }.font(.caption).padding(.vertical, 6)
                        .accessibilityLabel("Stop Luna's reply")
                } else {
                    Button { store.lunaText.replyHidden = true } label: {
                        Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 28, height: 28)
                    }.accessibilityLabel("Dismiss Luna's reply")
                }
            }.padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 4)
        }
    }
}

struct LunaConversationView: View {
    @Bindable var store: LunaStore
    @Bindable var conversation: LunaTextConversation
    var agentID: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        ForEach(conversation.messages) { MessageView(message: $0, agentName: "Luna") }
                        if conversation.sending { ProgressView("Luna is thinking…").font(.callout).tint(Palette.forest) }
                        Color.clear.frame(height: 12).id("latest")
                    }.padding(22)
                }.defaultScrollAnchor(.bottom).defaultScrollAnchor(.top, for: .alignment)
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: conversation.messages.last, initial: true) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            LunaErrorNotice(store: store)
                            if conversation.sending { Button("Stop Luna's reply") { store.stopLunaText() }.font(.caption).padding(.top, 8) }
                            if store.voice.isActive { LunaVoiceDock(store: store) }
                            LunaComposer(store: store, conversation: conversation, agentID: agentID)
                        }.background(Palette.canvas)
                    }
            }.background(Palette.canvas).navigationTitle("Luna").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.foregroundStyle(Palette.ink).preferredColorScheme(.dark)
    }
}
