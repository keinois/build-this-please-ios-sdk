import Foundation
#if canImport(Security)
import Security
#endif

public protocol BuildThisPleaseCredentialStore: Sendable {
    func value(for key: String) async throws -> String?
    func set(_ value: String, for key: String) async throws
    func removeValue(for key: String) async throws
}

public final class KeychainBuildThisPleaseCredentialStore: BuildThisPleaseCredentialStore, @unchecked Sendable {
    private let service: String
    public init(service: String = "io.buildthisplease.credentials") { self.service = service }

    public func value(for key: String) async throws -> String? {
        #if canImport(Security)
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw BuildThisPleaseError.invalidResponse
        }
        return value
        #else
        return nil
        #endif
    }

    public func set(_ value: String, for key: String) async throws {
        #if canImport(Security)
        let data = Data(value.utf8)
        let query = baseQuery(key)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw BuildThisPleaseError.invalidResponse }
        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let inserted = SecItemAdd(insertion as CFDictionary, nil)
        // Another client may have inserted between update and add; update that
        // item without deleting either the old or new credential.
        if inserted == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else { throw BuildThisPleaseError.invalidResponse }
        } else if inserted != errSecSuccess { throw BuildThisPleaseError.invalidResponse }
        #endif
    }

    public func removeValue(for key: String) async throws {
        #if canImport(Security)
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BuildThisPleaseError.invalidResponse }
        #endif
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
}

public actor InMemoryBuildThisPleaseCredentialStore: BuildThisPleaseCredentialStore {
    private var values: [String: String] = [:]
    public init() {}
    public func value(for key: String) -> String? { values[key] }
    public func set(_ value: String, for key: String) { values[key] = value }
    public func removeValue(for key: String) { values[key] = nil }
}
