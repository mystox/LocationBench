import MapKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@main
struct LocationBenchApp: App {
    var body: some Scene {
        WindowGroup { LocationView() }
    }
}

@MainActor
private struct LocationView: View {
    private enum Field: Hashable { case latitude, longitude }

    @StateObject private var model = SimulationModel()
    @StateObject private var pairing = LocalPairing()
    @StateObject private var currentLocation = CurrentLocation()
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var importing = false
    @State private var requestingNotifications = false
    @State private var picked: CLLocationCoordinate2D?
    @State private var mapPosition: MapCameraPosition = .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35, longitude: 105),
                           span: MKCoordinateSpan(latitudeDelta: 45, longitudeDelta: 45))
    )
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("设备配对", value: model.paired ? "已保存" : "未配对")
                    LabeledContent("定位会话", value: model.hasSession ? "已建立" : "未连接")
                    if pairing.running {
                        Text(pairing.instructions)
                            .foregroundStyle(.secondary)
                        if let pin = pairing.pin {
                            LabeledContent("配对验证码") {
                                Text(pin).font(.title2.monospacedDigit())
                            }
                        }
                        Button("取消配对", role: .cancel, action: pairing.cancel)
                    } else {
                        Button(model.paired ? "重新配对本机" : "配对本机", action: startPairing)
                            .disabled(model.busy || model.hasSession || requestingNotifications)
                        Button("导入 RPPairing 文件") { importing = true }
                            .disabled(model.busy || model.hasSession || requestingNotifications)
                    }
                } header: {
                    Text("连接")
                } footer: {
                    Text("使用定位前，打开开发者模式，连接 Wi-Fi 并在 LocalDevVPN 中开启隧道。")
                }

                Section {
                    MapReader { proxy in
                        Map(position: $mapPosition) {
                            if let picked {
                                Marker("模拟位置", coordinate: picked)
                            }
                        }
                        .onTapGesture { point in
                            guard let coordinate = proxy.convert(point, from: .local) else { return }
                            pick(coordinate)
                        }
                    }
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .listRowInsets(EdgeInsets())

                    Button(action: fetchCurrentLocation) {
                        if currentLocation.fetching {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在获取当前位置…")
                            }
                        } else {
                            Label("获取当前位置", systemImage: "location")
                        }
                    }
                    .disabled(currentLocation.fetching)

                    LabeledContent("纬度") {
                        coordinateField("-90 至 90", value: $latitude, label: "纬度", field: .latitude)
                    }
                    LabeledContent("经度") {
                        coordinateField("-180 至 180", value: $longitude, label: "经度", field: .longitude)
                    }
                    Button("应用模拟位置") {
                        focusedField = nil
                        Task { await model.apply(latitude: latitude, longitude: longitude) }
                    }
                    .disabled(!actionsAvailable || latitude.isEmpty || longitude.isEmpty)
                    Button("恢复真实定位") {
                        focusedField = nil
                        Task { await model.restore() }
                    }
                    .disabled(!actionsAvailable)
                } header: {
                    Text("目标位置")
                } footer: {
                    Text("模拟位置生效时，「获取当前位置」返回的也是模拟点。")
                }

                Section("状态") {
                    HStack(spacing: 12) {
                        if model.busy { ProgressView() }
                        Text(model.message)
                    }
                    if let error = model.error {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        Button("关闭错误提示", action: model.dismissError)
                    }
                    if let error = currentLocation.error {
                        Text(error)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("定位测试")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data], onCompletion: model.importPairing)
            .onReceive(currentLocation.$coordinate) { coordinate in
                guard let coordinate else { return }
                pick(coordinate)
                mapPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                ))
            }
        }
    }

    private var actionsAvailable: Bool {
        model.paired && !model.busy && !pairing.running && !requestingNotifications
    }

    private func fetchCurrentLocation() {
        focusedField = nil
        currentLocation.request()
    }

    private func pick(_ coordinate: CLLocationCoordinate2D) {
        focusedField = nil
        picked = coordinate
        latitude = String(format: "%.6f", coordinate.latitude)
        longitude = String(format: "%.6f", coordinate.longitude)
    }

    private func coordinateField(_ placeholder: String, value: Binding<String>, label: String, field: Field) -> some View {
        TextField(placeholder, text: value)
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .autocorrectionDisabled()
            .accessibilityLabel(label)
            .focused($focusedField, equals: field)
    }

    private func startPairing() {
        focusedField = nil
        requestingNotifications = true
        model.dismissError()
        Task {
            // 切到系统设置后，通过通知显示验证码。拒绝通知时仍可回 App 查看。
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            requestingNotifications = false
            pairing.start {
                switch $0 {
                case .success(let data): model.storePairing(data)
                case .failure(let error): model.show(error)
                }
            }
        }
    }
}
