import SwiftUI

struct NoticeCard<Content: View>: View {
    let dismissLabel: String
    let dismiss: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            content().frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted).frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(dismissLabel)
        }
        .padding(.leading, 14).padding(.vertical, 8).padding(.trailing, 2)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line, lineWidth: 1))
        .transition(.opacity)
    }
}

struct ErrorNotice: View {
    @Bindable var store: AppStore
    var body: some View {
        if let error = store.error, store.notices.contains("error") {
            NoticeCard(dismissLabel: "Dismiss error", dismiss: { store.error = nil }) {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Palette.orange).textSelection(.enabled)
                    .padding(.vertical, 8)
            }.padding(.horizontal, 18).padding(.vertical, 8)
        }
    }
}
