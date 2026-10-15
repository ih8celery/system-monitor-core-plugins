import Darwin
import Foundation

/// The router: the gateway of the default IPv4 route, read from the kernel's routing table with
/// `sysctl`, in process and without a subprocess.
enum DefaultGateway {
    private static let headerSize = MemoryLayout<rt_msghdr>.size
    /// The kernel pads each address in a routing message to a multiple of this.
    private static let addressAlignment = MemoryLayout<UInt32>.size
    /// An IPv4 address sits at bytes 4 to 8 of a sockaddr_in.
    private static let ipv4Bytes = 4..<8

    static func current() -> String? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        // Room for a route or two added between the size query and the read.
        length += length / 2
        var table = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &table, &length, nil, 0) == 0 else { return nil }
        return parse(Array(table.prefix(length)))
    }

    /// The first default route that is up, goes through a gateway, and is not scoped to one
    /// interface. A message that claims to run past the end of the table ends the reading.
    static func parse(_ table: [UInt8]) -> String? {
        var offset = 0
        while offset + headerSize <= table.count {
            let header = table.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self) }
            let length = Int(header.rtm_msglen)
            guard length >= headerSize, offset + length <= table.count else { return nil }
            let body = Array(table[(offset + headerSize)..<(offset + length)])
            if let gateway = defaultGateway(header, body) { return gateway }
            offset += length
        }
        return nil
    }

    private static func defaultGateway(_ header: rt_msghdr, _ body: [UInt8]) -> String? {
        let flags = header.rtm_flags
        guard flags & RTF_UP != 0, flags & RTF_GATEWAY != 0, flags & RTF_IFSCOPE == 0 else { return nil }
        let addresses = socketAddresses(in: body, present: header.rtm_addrs)
        guard let destination = addresses[Int(RTAX_DST)], ipv4(destination, emptyMeansAny: true) == "0.0.0.0",
              let gateway = addresses[Int(RTAX_GATEWAY)] else { return nil }
        return ipv4(gateway, emptyMeansAny: false)
    }

    /// Each address the message says it carries, by its RTAX index, in order.
    private static func socketAddresses(in body: [UInt8], present: Int32) -> [Int: [UInt8]] {
        var addresses: [Int: [UInt8]] = [:]
        var offset = 0
        for index in 0..<Int(RTAX_MAX) where present & (1 << index) != 0 {
            guard offset < body.count else { break }
            let length = Int(body[offset])
            guard offset + length <= body.count else { break }
            addresses[index] = Array(body[offset..<(offset + length)])
            offset += length == 0 ? addressAlignment : (length + addressAlignment - 1) / addressAlignment * addressAlignment
        }
        return addresses
    }

    /// A sockaddr_in as dotted text. The kernel may shorten an address of zeros, down to no bytes
    /// at all, so a short one is read as zero-padded.
    private static func ipv4(_ address: [UInt8], emptyMeansAny: Bool) -> String? {
        if address.count < 2 { return emptyMeansAny ? "0.0.0.0" : nil }
        guard address[1] == UInt8(AF_INET) else { return nil }
        let padded = address + [UInt8](repeating: 0, count: max(0, ipv4Bytes.upperBound - address.count))
        return padded[ipv4Bytes].map(String.init).joined(separator: ".")
    }
}
