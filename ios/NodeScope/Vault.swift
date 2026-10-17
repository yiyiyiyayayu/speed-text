import CryptoKit
import Foundation
import Security

/// Subscription credentials stay in a locally encrypted, backup-excluded file.
/// The AES key uses a device-only Keychain item and never enters source control.
enum Vault {
    private static let service = "app.nodescope.vault.v1"
    private static let account = "local-key"
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NodeScope", isDirectory: true).appendingPathComponent("vault.aes")
    }

    private static func key(create: Bool) throws -> SymmetricKey {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecSuccess, let data = value as? Data { return SymmetricKey(data: data) }
        if status == errSecMissingEntitlement { throw VaultError.missingEntitlement }
        guard status == errSecItemNotFound, create else { throw VaultError.keyUnavailable }
        let newKey = SymmetricKey(size: .bits256)
        let data = newKey.withUnsafeBytes { Data($0) }
        let insert: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let insertStatus = SecItemAdd(insert as CFDictionary, nil)
        if insertStatus == errSecMissingEntitlement { throw VaultError.missingEntitlement }
        guard insertStatus == errSecSuccess else { throw VaultError.keyUnavailable }
        return newKey
    }

    static func load() throws -> VaultData {
        guard FileManager.default.fileExists(atPath: url.path) else { return VaultData() }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let data = try AES.GCM.open(box, using: key(create: false))
        return try JSONDecoder().decode(VaultData.self, from: data)
    }

    static func save(_ value: VaultData) throws {
        let data = try JSONEncoder().encode(value)
        let box = try AES.GCM.seal(data, using: key(create: true))
        guard let encrypted = box.combined else { throw VaultError.keyUnavailable }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryURL = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directoryURL.setResourceValues(resources)
        try encrypted.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    enum VaultError: LocalizedError {
        case keyUnavailable
        case missingEntitlement
        var errorDescription: String? {
            switch self {
            case .keyUnavailable: return "无法读取本机加密密钥，请解锁设备后重试"
            case .missingEntitlement: return "签名缺少钥匙串权限，请在全能签中使用有效证书与描述文件重新签名后安装"
            }
        }
    }
}
