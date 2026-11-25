import Foundation

enum DeveloperImage {
    private static let files = [
        "BuildManifest.plist",
        "Image.dmg",
        "Image.dmg.trustcache",
        "Image.dmg.cryptex_info",
        "Image.dmg.root_hash"
    ]

    static func prepare() throws -> URL {
        let manager = FileManager.default
        let caches = try manager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let destination = caches.appendingPathComponent("DeveloperImage", isDirectory: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in files {
            let source = Bundle.main.bundleURL.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path) else {
                throw LocationBenchError("内置开发者镜像缺少 \(name)。")
            }
            let target = destination.appendingPathComponent(name)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            try manager.copyItem(at: source, to: target)
        }
        return destination
    }
}
