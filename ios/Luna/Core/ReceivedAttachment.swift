import Foundation
import UniformTypeIdentifiers

struct ReceivedAttachment: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case image, video, file }
    let url: URL
    let name: String
    let kind: Kind
    var id: String { url.absoluteString }

    static func allowedURL(_ value: String) -> URL? {
        guard let url = URL(string: value), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil else { return nil }
        if url.scheme?.lowercased() == "https" { return url }
        guard url.scheme?.lowercased() == "http" else { return nil }
        // Plain HTTP is useful inside a tailnet. Keep Internet hosts on HTTPS.
        let components = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = components.compactMap { Int($0) }
        let tailIPv4 = components.count == 4 && octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1]) && octets.allSatisfy { (0...255).contains($0) }
        let tailIPv6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).hasPrefix("fd7a:115c:a1e0:")
        let localName = !host.contains(".") && !host.contains(":")
        guard tailIPv4 || tailIPv6 || host.hasSuffix(".ts.net") || host.hasSuffix(".local") || localName || ["127.0.0.1", "[::1]", "::1"].contains(host) else { return nil }
        return url
    }

    static func make(url value: String, label: String = "", image: Bool = false) -> ReceivedAttachment? {
        guard let url = allowedURL(value) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let prefix = label.lowercased()
        let kind: Kind
        if image || type?.conforms(to: .image) == true { kind = .image }
        else if prefix.hasPrefix("video:") || type?.conforms(to: .movie) == true { kind = .video }
        else if prefix.hasPrefix("file:") || (!url.pathExtension.isEmpty && !["html", "htm", "php", "asp", "aspx"].contains(url.pathExtension.lowercased())) { kind = .file }
        else { return nil }
        let name = label.isEmpty ? url.lastPathComponent : label
        return ReceivedAttachment(url: url, name: name.isEmpty ? kind.rawValue.capitalized : name, kind: kind)
    }

    static func markdown(_ row: JSONObject) -> String? {
        let type = row["type"]?.string ?? ""
        let kind: Kind
        let value: JSONValue?
        switch type {
        case "image_url", "input_image", "image": kind = .image; value = row["image_url"] ?? row["url"]
        case "video_url", "video": kind = .video; value = row["video_url"] ?? row["url"]
        case "file", "file_url", "output_file": kind = .file; value = row["file_url"] ?? row["url"] ?? row["file"]
        default: return nil
        }
        guard let raw = value?.string ?? value?.object?["url"]?.string,
              let url = allowedURL(raw) else { return nil }
        let name = row["filename"]?.string ?? row["name"]?.string ?? value?.object?["filename"]?.string ?? url.lastPathComponent
        let label = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "\n", with: " ")
        return (kind == .image ? "![" : "[" + kind.rawValue.capitalized + ": ") + label + "](<" + url.absoluteString + ">)"
    }
}

struct MediaBlock: Identifiable, Equatable {
    let id: Int
    let text: String
    let attachment: ReceivedAttachment?
}

enum MediaBlocks {
    // Fenced blocks are separated by MarkdownBlocks first; skip inline code too.
    private static let links = try! NSRegularExpression(pattern: #"(`+)[^`]*\1|(!?)\[((?:\\.|[^\]\\])*)\]\(\s*(?:<([^>\n]+)>|([^\s<>]+?))(?:\s+"[^"]*")?\s*\)|<(https?://[^>\s]+)>|https?://[^\s<>\[\]`]+"#)
    static func parse(_ text: String) -> [MediaBlock] {
        let source = text as NSString
        var blocks: [MediaBlock] = [], offset = 0
        func append(_ text: String, _ attachment: ReceivedAttachment? = nil) {
            if !text.isEmpty || attachment != nil { blocks.append(MediaBlock(id: blocks.count, text: text, attachment: attachment)) }
        }
        for match in links.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            if match.range(at: 1).location != NSNotFound { continue }
            func group(_ i: Int) -> String { match.range(at: i).location == NSNotFound ? "" : source.substring(with: match.range(at: i)) }
            let markdown = match.range(at: 2).location != NSNotFound
            if !markdown {
                let prefix = source.substring(to: match.range.location)
                if prefix.hasSuffix("](") || prefix.hasSuffix("](<") { continue }
            }
            var raw = markdown ? (group(4).isEmpty ? group(5) : group(4)) : (group(6).isEmpty ? source.substring(with: match.range) : group(6))
            var end = NSMaxRange(match.range)
            if !markdown && group(6).isEmpty {
                while let last = raw.last, ".,;!?)".contains(last) { raw.removeLast(); end -= 1 }
            }
            guard let attachment = ReceivedAttachment.make(url: raw, label: group(3), image: group(2) == "!") else { continue }
            append(source.substring(with: NSRange(location: offset, length: match.range.location - offset)))
            append("", attachment)
            offset = end
        }
        append(source.substring(from: offset))
        return blocks
    }
}

enum AttachmentDownload {
    static func fetch(_ attachment: ReceivedAttachment, configuration: URLSessionConfiguration = .ephemeral) async throws -> URL {
        guard ReceivedAttachment.allowedURL(attachment.url.absoluteString) != nil else { throw ServiceError(message: "Use an HTTPS or tailnet link for this attachment.") }
        let limit: Int64 = attachment.kind == .image ? 20 * 1024 * 1024 : 250 * 1024 * 1024
        let delegate = AttachmentDownloadDelegate(limit: limit)
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.httpAdditionalHeaders = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (temporary, response) = try await session.download(from: attachment.url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ServiceError(message: "The file server couldn’t provide this attachment (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= limit else { throw ServiceError(message: "This attachment exceeds the \(limit / 1024 / 1024) MB download limit.") }
            let folder = FileManager.default.temporaryDirectory.appending(path: "LunaAttachments/" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let suggested = (response.suggestedFilename ?? attachment.url.lastPathComponent) as NSString
            var name = suggested.lastPathComponent.replacingOccurrences(of: ":", with: "_")
            if name.isEmpty || name == "." || name == ".." { name = "Attachment" }
            if (name as NSString).pathExtension.isEmpty, let mime = response.mimeType, let ext = UTType(mimeType: mime)?.preferredFilenameExtension { name += "." + ext }
            let destination = folder.appending(path: name)
            do {
                try FileManager.default.moveItem(at: temporary, to: destination)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                return destination
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if delegate.exceededLimit { throw ServiceError(message: "This attachment exceeds the \(limit / 1024 / 1024) MB download limit.") }
            if error is ServiceError { throw error }
            throw ServiceError(message: "Couldn’t download this attachment. Check Tailscale, the file server, and that the link is still available.")
        }
    }
    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

private final class AttachmentDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let limit: Int64
    private let lock = NSLock()
    private var exceeded = false
    var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > limit {
            lock.lock(); exceeded = true; lock.unlock(); downloadTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, ReceivedAttachment.allowedURL(url.absoluteString) != nil else { completionHandler(nil); return }
        completionHandler(URLRequest(url: url))
    }
}
