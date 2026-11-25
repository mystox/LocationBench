import Darwin
import Foundation
import IDevice

struct LocationBenchError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }

    static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, _ step: String) throws {
        guard let error else { return }
        let code = error.pointee.code
        let subcode = error.pointee.sub_code
        idevice_error_free(error)
        throw LocationBenchError("\(step)失败（\(code)/\(subcode)）")
    }
}

enum LocalAddresses {
    static func name(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
            return nil
        }
        let host = String(cString: buffer).components(separatedBy: "%")[0]
        return host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
    }

    static func current() -> Set<String> {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let interfaces else { return [] }
        defer { freeifaddrs(interfaces) }

        var addresses: Set<String> = []
        var next: UnsafeMutablePointer<ifaddrs>? = interfaces
        while let interface = next {
            next = interface.pointee.ifa_next
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6,
                  let host = name(address, length: socklen_t(address.pointee.sa_len)) else { continue }
            addresses.insert(host)
        }
        return addresses
    }
}
