import Foundation
import Security
import CryptoKit

enum Credentials {
    static func hermesAccount(_ address: String) -> String {
        "hermes-" + SHA256.hash(data: Data(address.trimmingCharacters(in: CharacterSet(charactersIn: "/")).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func read(_ account: String = "access-token") -> String {
        var query = query(account)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, account: String = "access-token") throws {
        let query = query(account)
        if value.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw failure() }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            for (key, value) in attributes { item[key] = value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw failure() }
        } else if result != errSecSuccess { throw failure() }
    }
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.luna.connection", kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    private static func failure() -> ServiceError { ServiceError(message: "The credentials could not be saved in Keychain.") }
}

struct ChatCache: Codable {
    var sessions: [AgentSession]
    var messages: [String: [ChatMessage]]
    var runs: [String: AgentRun]
    var cursor: Int
    var unread: Set<String>
    var fetchedAt: [String: Double]? = nil
}

enum ProtectedFile {
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = url
        try mutable.setResourceValues(values)
    }
}

enum CacheFile {
    static func location(server: String, token: String) -> URL {
        let key = SHA256.hash(data: Data(("direct|" + server + "|" + token).utf8)).map { String(format: "%02x", $0) }.joined()
        return URL.applicationSupportDirectory.appending(path: "Luna/\(key).json")
    }
    static func read(_ url: URL) -> ChatCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChatCache.self, from: data)
    }
    static func write(_ cache: ChatCache, to url: URL) throws { try ProtectedFile.write(cache, to: url) }
}
