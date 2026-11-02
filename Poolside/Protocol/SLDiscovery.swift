import Foundation
import Darwin

/// Finds ScreenLogic gateways on the local network.
///
/// The gateway answers an 8-byte probe on UDP 1444. iOS only lets an app broadcast
/// if Apple has granted it the multicast entitlement, so after trying the broadcast
/// we also send the probe to every address on the WiFi subnet one at a time.
/// Unicast to the local network only needs the Local Network permission.
enum SLDiscovery {
    static let port: UInt16 = 1444

    static func search(timeout: TimeInterval = 2.5) async -> [LocalGateway] {
        await Task.detached(priority: .userInitiated) { run(timeout: timeout) }.value
    }

    private static func run(timeout: TimeInterval) -> [LocalGateway] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking: a send to an empty address can otherwise stall on ARP for seconds.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let deadline = Date().addingTimeInterval(timeout)
        let probe: [UInt8] = [1, 0, 0, 0, 0, 0, 0, 0]
        var targets: [UInt32] = [0xFFFF_FFFF]
        if let subnet = wifiSubnet() {
            targets.append(subnet.broadcast)
            targets.append(contentsOf: subnet.hosts)
        }
        // Spend at most half the timeout sending so replies have time to arrive.
        let sendDeadline = Date().addingTimeInterval(timeout / 2)
        for target in targets where Date() < sendDeadline {
            while !send(fd, probe, to: target), Date() < sendDeadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, 20)
            }
        }

        var found: [String: LocalGateway] = [:]
        let capacity = 512
        var buffer = [UInt8](repeating: 0, count: capacity)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(deadline.timeIntervalSinceNow * 1000, 1))
            guard poll(&pfd, 1, min(remaining, 200)) > 0 else { continue }
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(fd, &buffer, capacity, 0, address, &fromLength)
                }
            }
            guard count >= 40 else { continue }
            let bytes = Array(buffer[0..<count])
            let type = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            guard type == 2 else { continue }
            let port = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
            let nameBytes = bytes[12..<40].prefix { $0 != 0 }
            let name = String(decoding: nameBytes, as: UTF8.self)
            let host = dotted(UInt32(bigEndian: from.sin_addr.s_addr))
            found[host] = LocalGateway(host: host, port: port, name: name)
        }
        return Array(found.values).sorted { $0.host < $1.host }
    }

    /// False only when the socket buffer is full and the send is worth retrying.
    /// Other errors (no route, host down) mean that address is skipped.
    private static func send(_ fd: Int32, _ bytes: [UInt8], to address: UInt32) -> Bool {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        target.sin_addr = in_addr(s_addr: address.bigEndian)
        let sent = withUnsafePointer(to: &target) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                sendto(fd, bytes, bytes.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent >= 0 || (errno != EAGAIN && errno != ENOBUFS)
    }

    /// Broadcast address and host addresses (host byte order) of the WiFi interface.
    /// Subnets bigger than a /22 are narrowed to the /24 around this phone.
    private static func wifiSubnet() -> (broadcast: UInt32, hosts: [UInt32])? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }

        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let ifa = entry.pointee
            guard String(cString: ifa.ifa_name) == "en0",
                  let address = ifa.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  let netmask = ifa.ifa_netmask else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            var mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if mask < 0xFFFF_FC00 { mask = 0xFFFF_FF00 }
            let network = ip & mask
            let broadcast = network | ~mask
            var hosts: [UInt32] = []
            var host = network + 1
            while host < broadcast {
                if host != ip { hosts.append(host) }
                host += 1
            }
            return (broadcast, hosts)
        }
        return nil
    }

    static func dotted(_ address: UInt32) -> String {
        "\(address >> 24 & 0xFF).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }
}
