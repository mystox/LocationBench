import Foundation
import IDevice
import Security

enum PairingStore {
    private static let maxBytes = 64 * 1024

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.locationbench.iphone",
         kSecAttrAccount as String: "remote-pairing"]
    }

    static func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return item as? Data
    }

    static func readFile(_ url: URL) throws -> Data {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try file.read(upToCount: maxBytes + 1) ?? Data()
    }

    static func save(_ data: Data) throws {
        guard (1...maxBytes).contains(data.count) else {
            throw LocationBenchError("配对文件大小无效。")
        }
        var pairing: OpaquePointer?
        let error = data.withUnsafeBytes { bytes in
            rp_pairing_file_from_bytes(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count), &pairing)
        }
        defer { rp_pairing_file_free(pairing) }
        try LocationBenchError.check(error, "读取 RPPairing 文件")

        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw LocationBenchError("无法访问配对凭据（\(status)）。") }
    }
}
