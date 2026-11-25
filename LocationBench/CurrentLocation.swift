import CoreLocation
import Foundation

final class CurrentLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var error: String?
    @Published private(set) var fetching = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() {
        error = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            fetching = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            error = "定位权限不可用，请到系统设置中允许「定位测试」访问位置。"
        default:
            fetching = true
            coordinate = nil
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            guard fetching else { return }
            coordinate = nil
            manager.requestLocation()
        case .denied, .restricted:
            guard fetching else { return }
            fetching = false
            error = "定位权限不可用，请到系统设置中允许「定位测试」访问位置。"
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        fetching = false
        coordinate = locations.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        fetching = false
        self.error = "获取当前位置失败：\(error.localizedDescription)"
    }
}
