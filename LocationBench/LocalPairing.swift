import Combine
import Darwin
import Foundation
import IDevice
import UIKit
import UserNotifications

@MainActor
final class LocalPairing: NSObject, ObservableObject, @preconcurrency NetServiceDelegate {
    @Published private(set) var running = false
    @Published private(set) var pin: String?
    @Published private(set) var instructions = ""
    private var advertisement: NetService?
    private var listener: DispatchSourceRead?
    private var peer: PairingPeer?
    private var expiry: Task<Void, Never>?
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var completion: ((Result<Data, Error>) -> Void)?
    private let notificationID = "local-pairing-code"

    func start(completion: @escaping (Result<Data, Error>) -> Void) {
        guard !running else { return }
        do {
            let identity = try PairingIdentity()
            let (socket, port) = try Self.openListener()
            let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: .main)
            source.setCancelHandler { _ = Darwin.close(socket) }
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.accept(on: socket, identity: identity)
                }
            }
            listener = source
            source.resume()

            self.completion = completion
            running = true
            instructions = "打开「设置 → 隐私与安全性 → 开发者模式」，选择「与 LocationBench 配对」。"
            background = UIApplication.shared.beginBackgroundTask(withName: "本机配对") { [weak self] in
                Task { @MainActor in
                    self?.finish(.failure(LocationBenchError("配对后台时间已用完。请重新配对。")))
                }
            }
            expiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(75)) } catch { return }
                self?.finish(.failure(LocationBenchError("本机配对超时。请重新配对。")))
            }

            let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.",
                                     name: identity.serviceName, port: Int32(port))
            service.delegate = self
            service.setTXTRecord(NetService.data(fromTXTRecord: identity.txt))
            advertisement = service
            service.publish(options: .noAutoRename)
        } catch {
            completion(.failure(error))
        }
    }

    func cancel() { finish(nil) }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === advertisement else { return }
        finish(.failure(LocationBenchError("无法发布配对服务。请检查本地网络权限和 Wi-Fi。")))
    }

    private func accept(on socket: Int32, identity: PairingIdentity) {
        guard running, peer == nil else { return }
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let (fd, host) = withUnsafeMutablePointer(to: &address) { storage in
            storage.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                let fd = Darwin.accept(socket, address, &length)
                return (fd, fd >= 0 ? LocalAddresses.name(address, length: length) : nil)
            }
        }
        guard fd >= 0 else { return }
        // 只接受本机的设置 App 发起的配对连接。
        guard let host, LocalAddresses.current().contains(host) else {
            Darwin.close(fd)
            return
        }

        stopListening()
        let connection = PairingPeer(fd: fd) { [weak self] connection, code in
            Task { @MainActor in
                guard let self, self.peer === connection else { return }
                self.show(code: code)
            }
        }
        peer = connection
        instructions = "在系统配对窗口输入六位验证码。"
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try identity.pair(with: connection) }
            Task { @MainActor [weak self] in
                guard let self, self.peer === connection else { return }
                self.finish(result)
            }
        }
    }

    private func show(code: String) {
        pin = code
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "LocationBench 配对验证码"
        content.body = code
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notificationID, content: content, trigger: nil),
            withCompletionHandler: nil
        )
    }

    private func stopListening() {
        advertisement?.stop()
        advertisement = nil
        listener?.cancel()
        listener = nil
    }

    private func finish(_ result: Result<Data, Error>?) {
        guard running else { return }
        let callback = completion
        completion = nil
        running = false
        pin = nil
        instructions = ""
        expiry?.cancel()
        expiry = nil
        stopListening()
        peer?.stop()
        peer = nil
        let notifications = UNUserNotificationCenter.current()
        notifications.removePendingNotificationRequests(withIdentifiers: [notificationID])
        notifications.removeDeliveredNotifications(withIdentifiers: [notificationID])
        if let result { callback?(result) }
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
    }

    private static func openListener() throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw LocationBenchError("无法创建配对监听。") }
        var ready = false
        defer { if !ready { Darwin.close(fd) } }
        var ipv6Only: Int32 = 0
        guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &ipv6Only, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw LocationBenchError("无法配置配对监听。")
        }

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let status = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                guard bind(fd, address, length) == 0, listen(fd, 4) == 0 else { return Int32(-1) }
                return getsockname(fd, address, &length)
            }
        }
        guard status == 0 else { throw LocationBenchError("无法启动配对监听。") }
        ready = true
        return (fd, UInt16(bigEndian: address.sin6_port))
    }
}

private final class PairingPeer: @unchecked Sendable {
    let fd: Int32
    let showPIN: @Sendable (PairingPeer, String) -> Void

    init(fd: Int32, showPIN: @escaping @Sendable (PairingPeer, String) -> Void) {
        self.fd = fd
        self.showPIN = showPIN
    }

    func stop() { _ = shutdown(fd, SHUT_RDWR) }
    deinit { Darwin.close(fd) }
}

private final class PairingIdentity: @unchecked Sendable {
    let serviceName: String
    let txt: [String: Data]
    private let handle: OpaquePointer

    init() throws {
        var handle: OpaquePointer?
        var name: UnsafeMutablePointer<CChar>?
        var bytes: UnsafeMutablePointer<UInt8>?
        var size: UInt = 0
        defer {
            idevice_string_free(name)
            idevice_data_free(bytes, size)
        }
        let error = pairable_host_prepare("LocationBench", nil, false, &handle, &name, &bytes, &size, nil)
        do {
            try LocationBenchError.check(error, "准备本机配对")
            guard let handle, let name, let bytes else { throw LocationBenchError("配对服务准备不完整。") }
            let data = Data(bytes: bytes, count: Int(size))
            guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
                throw LocationBenchError("无法读取配对服务信息。")
            }
            serviceName = String(cString: name)
            txt = values.mapValues { Data($0.utf8) }
            self.handle = handle
        } catch {
            pairable_host_free(handle)
            throw error
        }
    }

    deinit { pairable_host_free(handle) }

    func pair(with peer: PairingPeer) throws -> Data {
        let callback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { pin, context in
            guard let pin, let context else { return }
            let peer = Unmanaged<PairingPeer>.fromOpaque(context).takeUnretainedValue()
            peer.showPIN(peer, String(cString: pin))
        }
        var record: OpaquePointer?
        defer { rp_pairing_file_free(record) }
        let error = withExtendedLifetime(peer) {
            pairable_host_accept_fd(handle, peer.fd, callback, Unmanaged.passUnretained(peer).toOpaque(), nil, &record)
        }
        try LocationBenchError.check(error, "配对")
        var bytes: UnsafeMutablePointer<UInt8>?
        var size: UInt = 0
        try LocationBenchError.check(rp_pairing_file_to_bytes(record, &bytes, &size), "保存配对凭据")
        guard let bytes else { throw LocationBenchError("配对凭据为空。") }
        defer { idevice_data_free(bytes, size) }
        return Data(bytes: bytes, count: Int(size))
    }
}
