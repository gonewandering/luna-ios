import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// A prepared draft stays in memory until admission. Only the selected photo is read.
struct DraftPhoto: Identifiable, Equatable, Sendable {
    let jpeg: Data
    let id: String
    init(jpeg: Data) { self.jpeg = jpeg; self.id = ChatPhoto.digest(jpeg) }

    static func prepare(_ data: Data) throws -> DraftPhoto {
        guard data.count <= 40 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { throw ServiceError(message: "This photo couldn’t be opened. Choose another image.") }
        // Encode pixels only: normalize orientation and omit location/EXIF metadata.
        for quality in [0.85, 0.7, 0.5, 0.3] {
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { break }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), encoded.length <= ChatPhoto.maxBytes {
                return DraftPhoto(jpeg: encoded as Data)
            }
        }
        throw ServiceError(message: "This photo is too large to send. Try cropping it or choosing a smaller image.")
    }
}

/// Immutable file references keep image bytes out of the frequently rewritten run journal.
struct ChatPhoto: Codable, Equatable, Identifiable, Sendable {
    static let maxCount = 4
    static let maxBytes = 750_000
    let owner: String
    let hash: String
    var id: String { owner + ":" + hash }
    private static var root: URL { URL.applicationSupportDirectory.appending(path: "Luna/Photos") }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func owner(for scope: String) -> String { digest(Data(scope.utf8)) }
    static func save(_ draft: DraftPhoto, scope: String) throws -> ChatPhoto {
        guard !draft.jpeg.isEmpty, draft.jpeg.count <= maxBytes,
              CGImageSourceCreateWithData(draft.jpeg as CFData, nil) != nil else {
            throw ServiceError(message: "The photo is missing or too large. Attach it again.", statusCode: 400)
        }
        let photo = ChatPhoto(owner: owner(for: scope), hash: draft.id)
        if (try? photo.data()) != draft.jpeg { try ProtectedFile.writeData(draft.jpeg, to: photo.fileURL()) }
        return photo
    }
    func fileURL() throws -> URL {
        guard [owner, hash].allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) else {
            throw ServiceError(message: "The saved photo reference is invalid.", statusCode: 400)
        }
        return Self.root.appending(path: owner).appending(path: hash + ".jpg")
    }
    func data() throws -> Data {
        let url = try fileURL()
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxBytes,
              let data = try? Data(contentsOf: url), Self.digest(data) == hash else {
            throw ServiceError(message: "A saved photo is unavailable. Attach it again in a new message.", statusCode: 400)
        }
        return data
    }
    func contentPart() throws -> JSONValue {
        .object(["type": .string("image_url"), "image_url": .object(["url": .string("data:image/jpeg;base64," + (try data()).base64EncodedString())])])
    }
    static func removeFiles(scope: String) throws {
        let directory = root.appending(path: owner(for: scope))
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    static func fromHistory(_ content: JSONValue?, scope: String) -> [ChatPhoto] {
        (content?.array ?? []).compactMap { part in
            guard let row = part.object, ["image_url", "input_image"].contains(row["type"]?.string ?? ""),
                  let url = row["image_url"]?.string ?? row["image_url"]?.object?["url"]?.string,
                  url.hasPrefix("data:image/jpeg;base64,"), url.utf8.count <= maxBytes * 4 / 3 + 100,
                  let data = Data(base64Encoded: String(url.dropFirst("data:image/jpeg;base64,".count))) else { return nil }
            return try? save(DraftPhoto(jpeg: data), scope: scope)
        }
    }
}
