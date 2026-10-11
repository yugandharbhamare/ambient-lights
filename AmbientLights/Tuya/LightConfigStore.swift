import Foundation
import Security

/// Device ID and IP live in UserDefaults; the local key lives only in the Keychain.
enum LightConfigStore {
    private static let service = "local.ambientlights.light"
    private static let deviceIDKey = "light.deviceID"
    private static let hostKey = "light.host"
    private static let nameKey = "light.name"

    static func load() -> (credentials: LightCredentials, name: String?) {
        let defaults = UserDefaults.standard
        let deviceID = defaults.string(forKey: deviceIDKey) ?? ""
        let credentials = LightCredentials(
            deviceID: deviceID,
            host: defaults.string(forKey: hostKey) ?? "",
            localKey: deviceID.isEmpty ? "" : (readKey(account: deviceID) ?? "")
        )
        return (credentials, defaults.string(forKey: nameKey))
    }

    static func save(_ credentials: LightCredentials, name: String?) throws {
        let defaults = UserDefaults.standard
        if let previous = defaults.string(forKey: deviceIDKey), previous != credentials.deviceID {
            deleteKey(account: previous)
        }
        defaults.set(credentials.deviceID, forKey: deviceIDKey)
        defaults.set(credentials.host, forKey: hostKey)
        defaults.set(name, forKey: nameKey)
        try writeKey(credentials.localKey, account: credentials.deviceID)
    }

    static func updateHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: hostKey)
    }

    static func forget() {
        let defaults = UserDefaults.standard
        if let deviceID = defaults.string(forKey: deviceIDKey) { deleteKey(account: deviceID) }
        [deviceIDKey, hostKey, nameKey].forEach(defaults.removeObject)
    }

    // MARK: - tinytuya import

    struct ImportedDevice {
        let name: String
        let deviceID: String
        let localKey: String
        let host: String?
    }

    /// Reads tinytuya's `devices.json` (a JSON array of devices with id/key/ip/name).
    static func importTinyTuya(from url: URL) throws -> [ImportedDevice] {
        let data = try Data(contentsOf: url)
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return array.compactMap { entry in
            guard let id = entry["id"] as? String, let key = entry["key"] as? String, !key.isEmpty else { return nil }
            let ip = (entry["ip"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ImportedDevice(name: entry["name"] as? String ?? id, deviceID: id, localKey: key, host: ip)
        }
    }

    // MARK: - Keychain

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func readKey(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKey(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let update = SecItemUpdate(baseQuery(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        var add = baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Ambient Lights local key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"])
        }
    }

    private static func deleteKey(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
