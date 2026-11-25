import Combine
import Foundation

@MainActor
final class SimulationModel: ObservableObject {
    @Published private(set) var paired = false
    @Published private(set) var busy = false
    @Published private(set) var hasSession = false
    @Published private(set) var message = ""
    @Published private(set) var error: String?
    private let device = DeviceConnection()
    private let settings = UserDefaults.standard
    private let restoreKey = "simulationMayBeActive"
    private var lastPort: UInt16?

    init() {
        refreshPairing()
        message = settings.bool(forKey: restoreKey)
            ? "上次会话未确认恢复，可重新连接后恢复真实定位。"
            : "等待连接。"
    }

    func storePairing(_ data: Data) {
        guard !busy, !hasSession else { return }
        do {
            try PairingStore.save(data)
            lastPort = nil
            paired = true
            error = nil
        } catch {
            show(error)
        }
    }

    func importPairing(_ result: Result<URL, Error>) {
        do { storePairing(try PairingStore.readFile(result.get())) }
        catch { show(error) }
    }

    func apply(latitude: String, longitude: String) async {
        guard !busy else { return }
        let point: SimulationCoordinate
        do { point = try SimulationCoordinate(latitude: latitude, longitude: longitude) }
        catch { show(error); return }

        await perform {
            try await openSession()
            // 发送后即使 App 被结束，下次启动也能提示恢复。
            settings.set(true, forKey: restoreKey)
            message = "正在设置模拟位置…"
            try await device.apply(point)
            message = "已发送模拟位置。可切到 Apple 地图查看。"
        }
    }

    func restore() async {
        await perform {
            try await openSession()
            message = "正在恢复定位…"
            try await device.restore()
            settings.removeObject(forKey: restoreKey)
            disconnect()
            message = "已发送恢复指令。可在地图确认真实定位。"
        }
    }

    func show(_ error: Error) { self.error = error.localizedDescription }
    func dismissError() { error = nil }

    private func refreshPairing() {
        do { paired = try PairingStore.load() != nil }
        catch { show(error) }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await action()
        } catch {
            disconnect()
            message = settings.bool(forKey: restoreKey)
                ? "定位状态未知。连接恢复后可再次执行恢复。"
                : "开发者服务未连接。"
            show(error)
        }
    }

    private func disconnect() {
        hasSession = false
        device.disconnect()
    }

    private func openSession() async throws {
        guard !hasSession else { return }
        guard let pairing = try PairingStore.load() else {
            throw LocationBenchError("请先完成本机配对或导入 RPPairing 文件。")
        }
        message = "正在连接本机开发者服务…"
        var ports = await PairingPort().discover()
        if let lastPort, !ports.contains(lastPort) { ports.insert(lastPort, at: 0) }
        if !ports.contains(PairingPort.fallback) { ports.append(PairingPort.fallback) }

        var lastError: Error?
        for port in ports {
            do {
                try await device.connect(pairing: pairing, port: port)
                lastPort = port
                lastError = nil
                break
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw LocationBenchError("\(lastError.localizedDescription) 请确认已连接 Wi-Fi 和 LocalDevVPN，并允许本地网络访问。")
        }

        let needsImage = try await device.needsDeveloperImage()
        if needsImage {
            message = "正在下载并校验开发者镜像…"
            let assets = try await DeveloperImage.prepare()
            message = "正在安装开发者镜像…"
            try await device.installDeveloperImage(from: assets)
        }
        try await device.openLocation()
        hasSession = true
    }
}
