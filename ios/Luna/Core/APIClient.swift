import Foundation

struct ServiceError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

typealias JSONObject = [String: JSONValue]

struct SSEFrame: Sendable {
    let event: String
    let id: String?
    let data: Data
}

/// Preserves UTF-8, blank frame boundaries, and CR/LF across network chunks.
struct SSEFrameDecoder {
    private var line = Data()
    private var previousWasCR = false
    private var dataLines: [String] = []
    private var event = "message"
    private var id: String?
    private var size = 0
    mutating func accept(_ byte: UInt8) throws -> SSEFrame? {
        if byte == 10 && previousWasCR { previousWasCR = false; return nil }
        previousWasCR = byte == 13
        if byte == 10 || byte == 13 {
            guard let text = String(data: line, encoding: .utf8) else { throw ServiceError(message: "The stream contained invalid text.") }
            line.removeAll(keepingCapacity: true)
            if text.isEmpty {
                defer { dataLines = []; event = "message"; id = nil; size = 0 }
                guard !dataLines.isEmpty else { return nil }
                return SSEFrame(event: event, id: id, data: Data(dataLines.joined(separator: "\n").utf8))
            }
            if text.hasPrefix(":") { return nil }
            let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            var value = parts.count > 1 ? String(parts[1]) : ""
            if value.first == " " { value.removeFirst() }
            switch parts.first {
            case "data": dataLines.append(value)
            case "event": event = value
            case "id": id = value
            default: break
            }
            return nil
        }
        size += 1
        guard size <= 4 * 1024 * 1024 else { throw ServiceError(message: "A streamed event exceeded the size limit.") }
        line.append(byte)
        return nil
    }
}

final class APIClient: @unchecked Sendable {
    let baseURL: URL
    private let token: String
    private let label: String
    private let session: URLSession
    private let redirects = NoCredentialRedirects()

    init(url: URL, token: String, label: String = "Hermes", configuration: URLSessionConfiguration = .ephemeral) {
        baseURL = url; self.token = token; self.label = label
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }

    static func validateURL(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw ServiceError(message: "Use an HTTPS agent address, or localhost for development.")
        }
        return url
    }

    func request(_ path: String, method: String = "GET", body: JSONObject? = nil, headers: [String: String] = [:]) throws -> URLRequest {
        guard path.hasPrefix("/"), let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw ServiceError(message: "Invalid server address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    func call<T: Decodable>(_ path: String, method: String = "GET", body: JSONObject? = nil, headers: [String: String] = [:]) async throws -> T {
        do {
            let (data, response) = try await session.data(for: request(path, method: method, body: body, headers: headers))
            try check(response)
            do { return try JSONDecoder().decode(T.self, from: data) }
            catch { throw ServiceError(message: "\(label) returned an unexpected response. Check the server address and version.") }
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            let hint = baseURL.host?.hasSuffix(".ts.net") == true ? " Check Tailscale on this device and your agent's computer." : " Check your connection and server address."
            throw ServiceError(message: "Luna couldn't reach \(label)." + hint)
        }
    }

    func stream(_ path: String, method: String = "GET", body: JSONObject? = nil) -> AsyncThrowingStream<SSEFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    var request = try request(path, method: method, body: body)
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    try check(response)
                    var decoder = SSEFrameDecoder()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        if let frame = try decoder.accept(byte) { continuation.yield(frame) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func check(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message: String
            switch status {
            case 401, 403: message = "\(label) rejected its API key or denied access. Check Connection settings."
            case 404: message = "\(label) couldn't find this resource. Check the server address and API version."
            case 409: message = "\(label) rejected a conflicting request. Refresh the conversation."
            case 429: message = "\(label) is busy or has reached its usage limit. Try again shortly."
            case 300..<400: message = "\(label) redirected the request. Enter the final HTTPS address in Connection settings."
            default: message = "\(label) couldn't complete the request (HTTP \(status))."
            }
            // Never display arbitrary authentication responses containing credentials.
            throw ServiceError(message: message, statusCode: status)
        }
    }

    static func segment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }
}

private final class NoCredentialRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
