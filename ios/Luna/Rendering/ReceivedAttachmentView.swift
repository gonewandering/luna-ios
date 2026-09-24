import SwiftUI
import AVKit
import QuickLook
import ImageIO

struct ReceivedAttachmentView: View {
    let attachment: ReceivedAttachment
    @State private var download: TemporaryAttachment?
    @State private var image: UIImage?
    @State private var loading = false
    @State private var error: String?
    @State private var previewing = false
    @State private var request = 0
    private var localURL: URL? { download?.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let image {
                Button { previewing = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel("View " + attachment.name)
            }
            HStack(spacing: 12) {
                Image(systemName: attachment.kind == .image ? "photo" : attachment.kind == .video ? "play.rectangle" : "doc")
                    .font(.title3).foregroundStyle(Palette.forest)
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.name).font(.callout.weight(.medium)).lineLimit(2)
                    Text(attachment.url.host ?? "").font(.caption).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                if loading { ProgressView().controlSize(.small) }
                else if let localURL {
                    Button(attachment.kind == .video ? "Play" : "Preview") { previewing = true }
                    ShareLink(item: localURL) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Save or share " + attachment.name)
                } else {
                    Button(error == nil ? "Download" : "Retry") { request += 1 }
                }
            }.font(.caption).buttonStyle(.borderless)
            if let error { Text(error).font(.caption).foregroundStyle(Palette.orange) }
            Link("Open link", destination: attachment.url).font(.caption)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14))
        .task(id: request) {
            guard localURL == nil, attachment.kind == .image || request > 0 else { return }
            loading = true; error = nil
            defer { loading = false }
            do {
                let url = try await AttachmentDownload.fetch(attachment)
                if Task.isCancelled { AttachmentDownload.remove(url); return }
                download = TemporaryAttachment(url: url)
                if attachment.kind == .image {
                    let pixels = await Task.detached(priority: .userInitiated) {
                        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary)
                    }.value
                    if let pixels { image = UIImage(cgImage: pixels) }
                    else { error = "This image format can’t be shown here. Save it or open the link." }
                } else { previewing = true }
            } catch is CancellationError {}
            catch { self.error = error.localizedDescription }
        }
        .sheet(isPresented: $previewing) {
            if let localURL { AttachmentPreview(url: localURL, attachment: attachment) }
        }
    }
}

/// Keep the file alive through Quick Look and the share sheet, then discard it
/// when this chat card's state is released. A copied/shared file belongs to iOS.
private final class TemporaryAttachment {
    let url: URL
    init(url: URL) { self.url = url }
    deinit { AttachmentDownload.remove(url) }
}

private struct AttachmentPreview: View {
    let url: URL
    let attachment: ReceivedAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var playbackError = false
    var body: some View {
        NavigationStack {
            Group {
                if attachment.kind == .video {
                    VStack {
                        VideoPlayer(player: player)
                        if playbackError { Text("This video couldn’t play. Save it to open in another app.").font(.callout).padding() }
                    }
                    .task {
                        let item = AVPlayerItem(url: url)
                        player = AVPlayer(playerItem: item)
                        player?.play()
                        // Also surface unsupported codecs instead of an unexplained black player.
                        while !Task.isCancelled {
                            if item.status == .failed { playbackError = true; break }
                            do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
                        }
                    }
                    .onDisappear { player?.pause(); player = nil }
                } else { AttachmentQuickLook(url: url) }
            }
            .navigationTitle(attachment.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } }
            }
        }
    }
}

private struct AttachmentQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { url as NSURL }
    }
}
