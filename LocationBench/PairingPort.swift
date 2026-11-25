import Darwin
import Foundation

// NetService 的事件由创建它的主运行循环处理。
@MainActor
final class PairingPort: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    static let fallback: UInt16 = 49152
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var ports: [UInt16] = []
    private var continuation: CheckedContinuation<[UInt16], Never>?

    func discover() async -> [UInt16] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.finish() }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 2)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let port = UInt16(exactly: sender.port), port > 0 else { return }
        let ownAddresses = LocalAddresses.current()
        let isLocal = sender.addresses?.contains { bytes in
            bytes.withUnsafeBytes { raw in
                guard raw.count >= MemoryLayout<sockaddr>.size,
                      let address = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self),
                      let host = LocalAddresses.name(address, length: socklen_t(raw.count)) else { return false }
                return ownAddresses.contains(host)
            }
        } ?? false
        if isLocal && !ports.contains(port) { ports.append(port) }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        browser.stop()
        for service in services { service.stop() }
        services.removeAll()
        continuation.resume(returning: ports)
    }
}
