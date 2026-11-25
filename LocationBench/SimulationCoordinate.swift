import Foundation

struct SimulationCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    init(latitude: String, longitude: String) throws {
        self.latitude = try Self.parse(latitude, limit: 90, name: "纬度")
        self.longitude = try Self.parse(longitude, limit: 180, name: "经度")
    }

    private static func parse(_ text: String, limit: Double, name: String) throws -> Double {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: ",", with: ".")
        guard normalized.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let value = Double(normalized), value.isFinite, abs(value) <= limit else {
            throw ValidationError(message: "\(name)应为 \(-Int(limit)) 到 \(Int(limit)) 的十进制度数。")
        }
        return value
    }

    private struct ValidationError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
