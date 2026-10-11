import Darwin
import Foundation

/// Listens for the UDP broadcasts Tuya Wi-Fi devices send every few seconds
/// (ports 6666 plaintext / 6667 encrypted). Listen-only: nothing is transmitted.
enum TuyaDiscovery {
    struct Announcement: Equatable, Sendable {
        let deviceID: String
        let ip: String
        let version: String?
    }

    /// Returns the first announcement from `deviceID` (or any device when nil).
    static func find(deviceID: String?, timeout: TimeInterval) async -> Announcement? {
        await Task.detached(priority: .utility) {
            listen(deviceID: deviceID, timeout: timeout)
        }.value
    }

    private static func listen(deviceID: String?, timeout: TimeInterval) -> Announcement? {
        let sockets = [6666, 6667].compactMap(openSocket)
        defer { sockets.forEach { Darwin.close($0) } }
        guard !sockets.isEmpty else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            var fds = sockets.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            let waitMs = Int32(max(0, min(1000, deadline.timeIntervalSinceNow * 1000)))
            guard poll(&fds, nfds_t(fds.count), waitMs) > 0 else { continue }
            for fd in fds where fd.revents & Int16(POLLIN) != 0 {
                let count = recv(fd.fd, &buffer, buffer.count, 0)
                guard count > 0, let announcement = decode(Data(buffer[0..<count])) else { continue }
                if deviceID == nil || announcement.deviceID == deviceID { return announcement }
            }
        }
        return nil
    }

    private static func openSocket(port: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(fd)
            return nil
        }
        return fd
    }

    static func decode(_ datagram: Data) -> Announcement? {
        var buffer = datagram
        guard let frame = (try? TuyaCodec.extractFrames(from: &buffer))?.first else { return nil }
        let json: Data?
        if frame.payload.first == UInt8(ascii: "{") {
            json = frame.payload
        } else {
            json = try? TuyaCodec.aes(frame.payload, key: TuyaCodec.udpKey, encrypt: false)
        }
        guard let json,
              let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let id = object["gwId"] as? String,
              let ip = object["ip"] as? String else { return nil }
        return Announcement(deviceID: id, ip: ip, version: object["version"] as? String)
    }
}
