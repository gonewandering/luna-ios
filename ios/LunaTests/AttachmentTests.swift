import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
@testable import Luna

final class AttachmentTests: XCTestCase {
    @MainActor static func photo(_ color: UIColor = .systemOrange) throws -> DraftPhoto {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180), format: format).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
            UIColor.white.setFill(); context.fill(CGRect(x: 70, y: 40, width: 120, height: 70))
        }
        return try DraftPhoto.prepare(XCTUnwrap(image.pngData()))
    }

    @MainActor func testPhotosNormalizeOrientationStripLocationAndBoundPixels() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2400, height: 1200), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1200))
        }
        let raw = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(raw, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.5, kCGImagePropertyGPSLongitude: 122.4]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let prepared = try DraftPhoto.prepare(raw as Data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 800)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight as String] as? Int, 1600)
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertLessThanOrEqual(prepared.jpeg.count, ChatPhoto.maxBytes)
        XCTAssertThrowsError(try DraftPhoto.prepare(Data("not an image".utf8)))
    }

    @MainActor func testPhotoOnlyAdmissionRecoveryAndHistoryKeepExactImages() async throws {
        let scope = UUID().uuidString; defer { try? ChatPhoto.removeFiles(scope: scope) }
        let first = try ChatPhoto.save(Self.photo(), scope: scope)
        let second = try ChatPhoto.save(Self.photo(.systemBlue), scope: scope)
        let backend = FakeBackend()
        var journal: [String: AgentRun] = [:]
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities()) { journal = $0 }
        queue.resume(); defer { queue.pause() }
        _ = try await queue.admit(id: "photo-only", sessionID: "A", text: "", photos: [first])
        XCTAssertEqual(journal["photo-only"]?.photos, [first])
        XCTAssertTrue(backend.submitted.isEmpty, "Journal must precede any network submission")
        do { _ = try await queue.admit(id: "photo-only", sessionID: "A", text: "", photos: [second]); XCTFail("Photo identity binds idempotency") } catch { }
        let saved = try JSONEncoder().encode(journal)
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("base64"))
        var restored = try XCTUnwrap(JSONDecoder().decode([String: AgentRun].self, from: saved)["photo-only"])
        XCTAssertEqual(try restored.photos?.first?.data(), try first.data())
        restored.status = "completed"; restored.output = "A photo"
        var history = [ChatMessage(id: "user", role: "user", content: "", createdAt: restored.created, photos: [second]),
                       ChatMessage(id: "answer", role: "assistant", content: restored.output, createdAt: restored.created + 1)]
        XCTAssertTrue(ConversationHistory.reconciledRunIDs(runs: [restored], messages: history).isEmpty)
        history[0].photos = [first]
        XCTAssertEqual(ConversationHistory.reconciledRunIDs(runs: [restored], messages: history), [restored.id])
        try FileManager.default.removeItem(at: first.fileURL())
        do { _ = try await queue.admit(id: "missing", sessionID: "B", text: "", photos: [first]); XCTFail("Missing files must not be submitted") } catch { }
        XCTAssertNil(journal["missing"])
        XCTAssertThrowsError(try ChatPhoto(owner: "../bad", hash: first.hash).data())
    }

    @MainActor func testHermesMultimodalRequestRetryAndHistory() async throws {
        let scope = UUID().uuidString; defer { try? ChatPhoto.removeFiles(scope: scope); AttachmentHTTPStub.handler = nil }
        let draft = try Self.photo()
        let photo = try ChatPhoto.save(draft, scope: scope)
        var bodies: [JSONObject] = []
        AttachmentHTTPStub.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hermes-only")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "photos")
                bodies.append(Self.body(request))
                return (202, [:], Data(#"{"run_id":"remote-photos"}"#.utf8))
            }
            let result: JSONObject = ["data": .array([.object(["id": .string("history-user"), "role": .string("user"), "content": bodies[0]["input"]!.array![0].object!["content"]!])])]
            return (200, [:], try! JSONEncoder().encode(result))
        }
        let client = HermesClient(url: URL(string: "https://hermes.example.com")!, key: "hermes-only", configuration: Self.config(), photoScope: scope)
        var run = AgentRun(id: "photos", sessionID: "A", text: "What is this?", status: "submitting", output: "", created: 1)
        run.photos = [photo]; run.responseInstructions = HermesResponseFormat.instructions
        run.modelSelection = HermesModelSelection(provider: "test", model: "vision")
        _ = try await client.submit(run)
        _ = try await client.submit(JSONDecoder().decode(AgentRun.self, from: JSONEncoder().encode(run)))
        XCTAssertEqual(bodies[0], bodies[1])
        let parts = try XCTUnwrap(bodies[0]["input"]?.array?.first?.object?["content"]?.array)
        XCTAssertEqual(parts[0].object?["text"], .string(run.text))
        XCTAssertEqual(parts[1].object?["image_url"]?.object?["url"], .string("data:image/jpeg;base64," + draft.jpeg.base64EncodedString()))
        XCTAssertEqual(bodies[0]["model"], .string("vision"))
        let history = try await client.messages("A")
        XCTAssertEqual(history.messages.first?.photos, [photo])
        XCTAssertEqual(history.messages.first?.content, run.text)
        var photoOnly = AgentRun(id: run.id, sessionID: run.sessionID, text: "", status: "submitting", output: "", created: 1)
        photoOnly.photos = [photo]
        _ = try await client.submit(photoOnly)
        XCTAssertEqual(bodies.last?["input"]?.array?.first?.object?["content"]?.array?.count, 1)
    }

    @MainActor func testSendingClearsOnlyAdmittedSessionPhotosAndKeepsRejectedDraft() async throws {
        let backend = FakeBackend()
        let store = AppStore(loadSavedState: false)
        store.makeBackend = { backend }
        let profile = AgentProfile(name: "Test", kind: .hermes, address: "https://hermes.example.com")
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); try? ChatPhoto.removeFiles(scope: "profile:" + profile.id) }
        try store.configure(profile: profile, key: "test", openAIKey: "", voice: VoiceController(), cache: folder.appending(path: "cache.json"))
        await store.connect()
        let draft = try Self.photo()
        store.photoDrafts["A"] = [draft]; store.photoDrafts["B"] = [draft]
        await store.send("A")
        XCTAssertEqual(store.photoDrafts["A"], [])
        XCTAssertEqual(store.photoDrafts["B"], [draft])
        XCTAssertEqual(store.runs.values.first?.photos?.count, 1)
        store.photoDrafts["A"] = Array(repeating: draft, count: 5)
        await store.send("A")
        XCTAssertEqual(store.photoDrafts["A"]?.count, 5)
        XCTAssertNotNil(store.error)
        await store.disconnect()
    }

    func testTailnetURLsAndAttachmentParsingPreserveProseAndCode() {
        for value in ["https://host.example.com/a.png", "http://jetson.tail428f1f.ts.net:8000/a.pdf", "http://100.100.20.30:8000/video.mp4", "http://[fd7a:115c:a1e0::1]:8000/a.txt", "http://jetson:8000/a.jpg"] {
            XCTAssertNotNil(ReceivedAttachment.allowedURL(value), value)
        }
        for value in ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.com/a.png", "http://public.example.com/a.pdf", "http://100.foo.100.20.30/a.pdf", "http://100.128.0.1/a.pdf"] {
            XCTAssertNil(ReceivedAttachment.allowedURL(value), value)
        }
        let markdown = "Before ![Plot](<http://jetson:8000/plot.png>) between [Video: demo](https://example.com/download?id=1) then [File: archive](https://example.com/artifact?id=2) after. `https://example.com/code.pdf`"
        let blocks = MediaBlocks.parse(markdown)
        XCTAssertEqual(blocks.compactMap(\.attachment).map(\.kind), [.image, .video, .file])
        XCTAssertEqual(blocks.filter { $0.attachment == nil }.map(\.text).joined(), "Before  between  then  after. `https://example.com/code.pdf`")
        XCTAssertEqual(MediaBlocks.parse("https://example.com/report.pdf.").compactMap(\.attachment).first?.url.absoluteString, "https://example.com/report.pdf")
        XCTAssertTrue(MediaBlocks.parse("[Docs](https://example.com/guide) and [Page](https://example.com/index.html)").compactMap(\.attachment).isEmpty)
        XCTAssertTrue(MarkdownBlocks.parse("```text\nhttps://example.com/a.png\n```").allSatisfy { $0.kind != .markdown })
        XCTAssertNil(MediaBlocks.parse("![unfinished](https://example.com/a.png").first?.attachment)
    }

    @MainActor func testStructuredReceivedMediaAndLiveCompletion() async throws {
        let parts: JSONValue = .array([
            .object(["type": .string("text"), "text": .string("Results")]),
            .object(["type": .string("image_url"), "image_url": .object(["url": .string("http://jetson:8000/chart.png")])]),
            .object(["type": .string("video_url"), "video_url": .string("http://100.100.20.30:8000/movie.mp4")]),
            .object(["type": .string("file"), "file": .object(["url": .string("https://host.ts.net/download?id=1"), "filename": .string("report.pdf")])])
        ])
        let content = HermesClient.content(parts)
        XCTAssertEqual(MediaBlocks.parse(content).compactMap(\.attachment).map(\.kind), [.image, .video, .file])
        let backend = FakeBackend()
        let queue = RunCoordinator(backend: backend, features: try await backend.capabilities()) { _ in }
        queue.resume(); defer { queue.pause() }
        _ = try await queue.admit(id: "received", sessionID: "A", text: "Generate files")
        try queue.consume("received", HermesEvent(type: "run.completed", data: ["output": parts]))
        XCTAssertEqual(queue.records["received"]?.output, content)
    }

    func testDownloadedFileHasNoAgentCredentialsAndCanBeSaved() async throws {
        let data = Data("A downloaded tailnet report".utf8)
        AttachmentHTTPStub.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            return (200, ["Content-Type": "text/plain", "Content-Disposition": "attachment; filename=report.txt"], data)
        }
        defer { AttachmentHTTPStub.handler = nil }
        let attachment = try XCTUnwrap(ReceivedAttachment.make(url: "http://jetson:8000/report.txt"))
        let url = try await AttachmentDownload.fetch(attachment, configuration: Self.config())
        defer { AttachmentDownload.remove(url) }
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(url.lastPathComponent, "report.txt")
        AttachmentHTTPStub.handler = { _ in (404, [:], Data()) }
        do { _ = try await AttachmentDownload.fetch(attachment, configuration: Self.config()); XCTFail("Missing file must show failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("404")) }
    }

    func testOldMessageAndRunDecodeWithoutPhotos() throws {
        let message = Data(#"{"id":"old","role":"user","content":"hello","created_at":1}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: message).photos)
        let run = AgentRun(id: "old", sessionID: "A", text: "hello", status: "completed", output: "ok", created: 1)
        let data = try JSONEncoder().encode(run)
        XCTAssertNil(try JSONDecoder().decode(AgentRun.self, from: data).photos)
    }

    @MainActor func testAutoUsesPhotoCountAndExcludesTextOnlyModels() async throws {
        let catalog = HermesModelCatalog(providers: [HermesModelProvider(id: "provider", name: "Provider", authenticated: true,
            models: ["text-only", "multimodal"], capabilities: ["text-only": ["vision": .bool(false)], "multimodal": ["vision": .bool(true)]])], current: nil)
        XCTAssertEqual(AutoModelRouter.candidates(in: catalog).count, 2)
        AttachmentHTTPStub.handler = { request in
            let body = Self.body(request)
            let input = try! JSONDecoder().decode(JSONObject.self, from: Data(body["input"]!.string!.utf8))
            XCTAssertEqual(input["attached_photo_count"], .number(2))
            XCTAssertEqual(input["candidates"]?.array?.count, 1)
            XCTAssertEqual(input["candidates"]?.array?.first?.object?["model"], .string("multimodal"))
            XCTAssertFalse(body["input"]!.string!.contains("image_url"))
            return (200, [:], Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"{\"candidate_index\":0,\"complexity\":\"standard\",\"reason\":\"Supports photos.\"}"}]}]}"#.utf8))
        }
        defer { AttachmentHTTPStub.handler = nil }
        let choice = try await AutoModelRouter(key: "test", configuration: Self.config()).choose(prompt: "Compare these", history: [], catalog: catalog, photoCount: 2)
        XCTAssertEqual(choice.selection.model, "multimodal")
    }

    @MainActor func testReceivedImageDownloadAndOversizeFailure() async throws {
        let draft = try Self.photo()
        AttachmentHTTPStub.handler = { _ in (200, ["Content-Type": "image/jpeg"], draft.jpeg) }
        defer { AttachmentHTTPStub.handler = nil }
        let photo = try XCTUnwrap(ReceivedAttachment.make(url: "http://100.100.20.30:8000/photo.jpg"))
        let file = try await AttachmentDownload.fetch(photo, configuration: Self.config())
        defer { AttachmentDownload.remove(file) }
        XCTAssertNotNil(UIImage(contentsOfFile: file.path))
        AttachmentHTTPStub.handler = { _ in (200, ["Content-Length": "22020096"], Data(repeating: 0, count: 21 * 1024 * 1024)) }
        do { _ = try await AttachmentDownload.fetch(photo, configuration: Self.config()); XCTFail("Oversized images must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("20 MB"), error.localizedDescription) }
    }

    func testDownloadedVideoRemainsPlayable() async throws {
        let original = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: original); AttachmentHTTPStub.handler = nil }
        let writer = try AVAssetWriter(outputURL: original, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 255, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 30)); input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let data = try Data(contentsOf: original)
        AttachmentHTTPStub.handler = { _ in (200, ["Content-Type": "video/mp4"], data) }
        let attachment = try XCTUnwrap(ReceivedAttachment.make(url: "http://jetson:8000/demo.mp4"))
        XCTAssertEqual(attachment.kind, .video)
        let file = try await AttachmentDownload.fetch(attachment, configuration: Self.config())
        defer { AttachmentDownload.remove(file) }
        let playable = try await AVURLAsset(url: file).load(.isPlayable)
        XCTAssertTrue(playable)
    }

    private static func config() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AttachmentHTTPStub.self]; return config
    }
    private static func body(_ request: URLRequest) -> JSONObject {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, data.isEmpty {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return (try? JSONDecoder().decode(JSONObject.self, from: data)) ?? [:]
    }
}

private final class AttachmentHTTPStub: URLProtocol, @unchecked Sendable {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let (status, headers, body) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
