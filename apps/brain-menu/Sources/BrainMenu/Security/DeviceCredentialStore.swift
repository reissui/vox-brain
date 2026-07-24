import Foundation
import Security

protocol DeviceCredentialStoring: Sendable {
    func save(_ token: String, for account: String) throws
    func load(for account: String) throws -> String?
    func delete(for account: String) throws
}

enum DeviceCredentialStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            "The device credential is invalid."
        case .keychain:
            "The device credential could not be accessed in Keychain."
        }
    }
}

struct DeviceCredentialStore: DeviceCredentialStoring, Sendable {
    static let defaultService = "app.voxbrain.device"

    let service: String
    private let accessGroup: String?

    init(service: String = DeviceCredentialStore.defaultService, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func save(_ token: String, for account: String) throws {
        guard !token.isEmpty, !account.isEmpty,
              let data = token.data(using: .utf8) else {
            throw DeviceCredentialStoreError.invalidValue
        }

        var query = baseQuery(account: account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query.merge(attributes) { _, new in new }
            query[kSecAttrLabel] = "Brain device credential"
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw DeviceCredentialStoreError.keychain(status)
        }
    }

    func load(for account: String) throws -> String? {
        guard !account.isEmpty else {
            throw DeviceCredentialStoreError.invalidValue
        }
        var query = baseQuery(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            if status == errSecSuccess {
                throw DeviceCredentialStoreError.invalidValue
            }
            throw DeviceCredentialStoreError.keychain(status)
        }
        return token
    }

    func delete(for account: String) throws {
        guard !account.isEmpty else {
            throw DeviceCredentialStoreError.invalidValue
        }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeviceCredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: false,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup] = accessGroup
        }
        return query
    }
}
