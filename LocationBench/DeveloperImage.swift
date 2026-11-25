import CryptoKit
import Foundation

enum DeveloperImage {
    private static let revision = "d2d3e18b695e0e0bec3051f13e7ca6e0a50241e9"
    private static let files = [
        ("BuildManifest.plist", "27385d7582b03b36bb3104e22b520aee0c47d72fecb4e8ecfe12ef5d966c7012"),
        ("Image.dmg", "873097f695a8b9734e2abc54f795a8874d40ff6fd11208ecb01ef29534c7c176"),
        ("Image.dmg.trustcache", "f7f21986074eee03a215aca16ecfc78d6bf183600d8a0d2fb691f9896782e6f0"),
        ("Image.dmg.cryptex_info", "edf49aef55aacc063d4d7be05b713bb545ce2993b3f62bcc15eccd75e610ee6c"),
        ("Image.dmg.root_hash", "3543fad2805b88119695c417e12679380b3b5a2742994bbcc839c8e2de5d7302")
    ]

    static func prepare() async throws -> URL {
        let manager = FileManager.default
        let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let destination = caches.appendingPathComponent("DeveloperImage-\(revision)", isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        let base = URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/\(revision)/PersonalizedImages/Xcode_iOS_DDI_Cryptex")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 150
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        for (name, expectedHash) in files {
            let file = destination.appendingPathComponent(name)
            if matches(file, expectedHash) { continue }
            let (download, response) = try await session.download(from: base.appendingPathComponent(name))
            defer { try? manager.removeItem(at: download) }
            guard (response as? HTTPURLResponse)?.statusCode == 200, matches(download, expectedHash) else {
                throw LocationBenchError("开发者镜像下载或校验失败（\(name)）。")
            }
            if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
            try manager.moveItem(at: download, to: file)
        }
        return destination
    }

    private static func matches(_ url: URL, _ expectedHash: String) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return hash == expectedHash
    }
}
