import Darwin
import Foundation
import IDevice

final class DeviceConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.locationbench.device", qos: .utility)
    private var adapter: OpaquePointer?
    private var discovery: OpaquePointer?
    private var server: OpaquePointer?
    private var location: OpaquePointer?

    deinit { close() }

    func connect(pairing: Data, port: UInt16) async throws {
        try await run("连接开发者服务", timeout: 12) {
            self.close()
            var record: OpaquePointer?
            defer { rp_pairing_file_free(record) }
            try LocationBenchError.check(pairing.withUnsafeBytes { bytes in
                rp_pairing_file_from_bytes(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(bytes.count), &record)
            }, "读取设备配对")

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            // 只通过 LocalDevVPN 访问这台 iPhone。
            _ = inet_pton(AF_INET, "10.7.0.1", &address.sin_addr)
            let error = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing($0, socklen_t(MemoryLayout<sockaddr_in>.size), "LocationBench",
                                            record, nil, nil, &self.adapter, &self.discovery)
                }
            }
            try LocationBenchError.check(error, "连接本机开发隧道")
        }
    }

    func needsDeveloperImage() async throws -> Bool {
        try await run("检查开发者镜像", timeout: 15) {
            let (adapter, discovery) = try self.tunnel()
            var image: UnsafeMutablePointer<InstalledCryptexC>?
            defer { if let image { cryptexd_free_installed_cryptex(image) } }
            try LocationBenchError.check(cryptexd_installed_ddi(adapter, discovery, &image), "检查开发者镜像")
            return image == nil
        }
    }

    func installDeveloperImage(from directory: URL) async throws {
        try await run("安装开发者镜像", timeout: 150) {
            let (adapter, discovery) = try self.tunnel()
            var assets: OpaquePointer?
            defer { cryptex1_assets_free(assets) }
            try LocationBenchError.check(cryptex1_assets_load(directory.path, &assets), "读取开发者镜像")
            try LocationBenchError.check(cryptexd_install_ddi(adapter, discovery, assets, nil), "安装开发者镜像")
        }
    }

    func openLocation() async throws {
        try await run("打开定位服务", timeout: 15) {
            let (adapter, discovery) = try self.tunnel()
            try LocationBenchError.check(remote_server_connect_rsd(adapter, discovery, &self.server), "连接 DVT")
            try LocationBenchError.check(location_simulation_new(self.server, &self.location), "打开定位服务")
            guard self.location != nil else { throw LocationBenchError("定位服务没有返回会话。") }
        }
    }

    func apply(_ point: SimulationCoordinate) async throws {
        try await run("应用模拟位置", timeout: 12) {
            guard let location = self.location else { throw LocationBenchError("定位会话已断开。") }
            try LocationBenchError.check(location_simulation_set(location, point.latitude, point.longitude), "应用模拟位置")
        }
    }

    func restore() async throws {
        try await run("恢复真实定位", timeout: 12) {
            guard let location = self.location else { throw LocationBenchError("定位会话已断开。") }
            try LocationBenchError.check(location_simulation_clear(location), "恢复真实定位")
        }
    }

    func disconnect() {
        queue.async { self.close() }
    }

    private func tunnel() throws -> (OpaquePointer, OpaquePointer) {
        guard let adapter, let discovery else { throw LocationBenchError("开发者隧道已断开。") }
        return (adapter, discovery)
    }

    private func close() {
        // 定位客户端借用了 DVT 服务，必须按创建的逆序释放。
        if let location { location_simulation_free(location) }
        if let server { remote_server_free(server) }
        if let discovery { rsd_handshake_free(discovery) }
        if let adapter { adapter_free(adapter) }
        location = nil
        server = nil
        discovery = nil
        adapter = nil
    }

    private func run<T: Sendable>(
        _ name: String, timeout: TimeInterval, _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let reply = NativeReply(continuation)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                timer.cancel()
                _ = reply.finish(.failure(LocationBenchError("\(name)超时。请检查 LocalDevVPN、Wi-Fi 和配对状态。")))
            }
            timer.resume()
            queue.async {
                guard reply.pending else { return }
                let result = Result { try operation() }
                timer.cancel()
                if !reply.finish(result) { self.close() }
            }
        }
    }
}

private final class NativeReply<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    var pending: Bool { lock.withLock { continuation != nil } }

    func finish(_ result: Result<T, Error>) -> Bool {
        let reply = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        reply?.resume(with: result)
        return reply != nil
    }
}
