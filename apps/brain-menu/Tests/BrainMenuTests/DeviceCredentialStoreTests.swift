import Foundation
import Security
import Testing
@testable import BrainMenu

@Suite(.serialized)
struct DeviceCredentialStoreTests {
    @Test
    func savesLoadsUpdatesAndDeletesInAnIsolatedKeychainNamespace() throws {
        let service = "DeviceCredentialStoreTests.\(UUID().uuidString)"
        let account = "https://brain.example.test"
        let store = DeviceCredentialStore(service: service)
        defer { try? store.delete(for: account) }

        #expect(try store.load(for: account) == nil)
        try store.save("first-device-token", for: account)
        #expect(try store.load(for: account) == "first-device-token")

        try store.save("replacement-device-token", for: account)
        #expect(try store.load(for: account) == "replacement-device-token")

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var raw: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &raw) == errSecSuccess)
        let attributes = try #require(raw as? [String: Any])
        #expect(attributes[kSecAttrService as String] as? String == service)
        #expect(attributes[kSecAttrAccount as String] as? String == account)
        #expect(attributes.values.contains { String(describing: $0).contains("replacement-device-token") } == false)

        try store.delete(for: account)
        #expect(try store.load(for: account) == nil)
        try store.delete(for: account)
    }

    @Test
    func productionServiceIsFixedAndUserDefaultsNeverReceiveTheSecret() throws {
        #expect(DeviceCredentialStore.defaultService == "app.voxbrain.device")

        let suite = "DeviceCredentialStoreTests.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = "never-write-this-device-token-to-defaults"
        let metadata = BrainInstanceMetadata(
            baseURL: try #require(URL(string: "https://brain.example.test")),
            instanceID: "brain-owner",
            deviceID: "device-1",
            deviceName: "the owner Mac",
            scopes: [.capture, .read, .control]
        )
        defaults.set(try JSONEncoder().encode(metadata), forKey: BrainAPIClient.metadataDefaultsKey)

        let rendered = String(describing: defaults.dictionaryRepresentation())
        #expect(rendered.contains(token) == false)
        #expect(defaults.object(forKey: "token") == nil)
        #expect(defaults.object(forKey: "deviceToken") == nil)
        #expect(defaults.object(forKey: "bearer") == nil)
    }

    @Test
    func rejectsEmptyValuesWithoutReflectingCredentialsInErrors() {
        let store = DeviceCredentialStore(service: "DeviceCredentialStoreTests.invalid")
        #expect(throws: DeviceCredentialStoreError.invalidValue) {
            try store.save("", for: "account")
        }
        #expect(throws: DeviceCredentialStoreError.invalidValue) {
            try store.save("secret-token", for: "")
        }
        #expect(DeviceCredentialStoreError.invalidValue.localizedDescription.contains("secret-token") == false)
    }
}
