import SwiftUI

/// Shared text and microphone controls for Luna and agent conversations.
struct MessageComposer: View {
    @Binding var text: String
    let placeholder: String
    let messageLabel: String
    var sending = false
    var canSend = true
    var voiceIsActive = false
    var focus: FocusState<Bool>.Binding
    let onMicrophone: () -> Void
    let onSend: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6).font(.body).focused(focus).padding(.vertical, 12)
                .accessibilityLabel(messageLabel).accessibilityIdentifier("message-input")
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    focus.wrappedValue = false
                    onMicrophone()
                } label: {
                    Image(systemName: voiceIsActive ? "waveform" : "mic")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.onAccent)
                        .frame(width: 42, height: 42).background(Palette.button, in: Circle())
                }.accessibilityLabel(voiceIsActive ? "End voice" : "Start voice conversation")
                    .accessibilityIdentifier("composer-microphone")
            } else {
                Button(action: onSend) {
                    Group {
                        if sending { ProgressView().tint(Palette.onAccent) }
                        else { Image(systemName: "arrow.up").font(.system(size: 19, weight: .semibold)) }
                    }.foregroundStyle(Palette.onAccent).frame(width: 42, height: 42).background(Palette.button, in: Circle())
                }.disabled(!canSend || sending).accessibilityLabel("Send prompt").accessibilityIdentifier("composer-send")
            }
        }
        .padding(.leading, 17).padding(.trailing, 8).padding(.vertical, 7)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Palette.line, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.32), radius: 14, x: 0, y: 4)
    }
}
