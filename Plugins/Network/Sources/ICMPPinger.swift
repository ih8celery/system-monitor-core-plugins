import Darwin
import Foundation

/// The ICMP echo message: building a request, and deciding whether a received packet is the
/// reply to it.
enum ICMPEcho {
    static let echoReply: UInt8 = 0
    static let echoRequest: UInt8 = 8
    static let destinationUnreachable: UInt8 = 3
    static let headerSize = 8
    static let payloadSize = 16
    private static let minimumIPv4HeaderSize = 20
    /// Where an IPv4 header keeps its protocol and its destination address.
    private static let protocolOffset = 9
    private static let destinationBytes = 16..<20
    private static let unreachableReasons: [UInt8: String] = [
        0: "network unreachable", 1: "host unreachable", 2: "protocol unreachable", 3: "port unreachable",
    ]

    static func request(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            echoRequest, 0, 0, 0,
            UInt8(identifier >> 8), UInt8(identifier & 0xFF),
            UInt8(sequence >> 8), UInt8(sequence & 0xFF),
        ]
        packet += (0..<payloadSize).map { UInt8($0) }
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    /// The Internet checksum: the ones' complement of the ones' complement sum of 16-bit words.
    /// A message that carries its own checksum sums to zero.
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var index = 0
        while index < bytes.count {
            let high = UInt32(bytes[index]) << 8
            let low = index + 1 < bytes.count ? UInt32(bytes[index + 1]) : 0
            sum += high | low
            index += 2
        }
        while sum >> 16 != 0 {
            sum = (sum & 0xFFFF) + (sum >> 16)
        }
        return ~UInt16(sum)
    }

    /// True only for an intact echo reply from the address pinged, carrying this pinger's
    /// identifier and this ping's sequence. Every other ICMP message the socket sees (another
    /// program's replies, a late reply to an earlier ping, an error) is not ours.
    static func isReply(_ packet: [UInt8], from source: String, expectedSource: String, identifier: UInt16, sequence: UInt16) -> Bool {
        guard source == expectedSource, let message = icmpMessage(in: packet), message.count >= headerSize else { return false }
        guard message[0] == echoReply, message[1] == 0, checksum(message) == 0 else { return false }
        return word(message, at: 4) == identifier && word(message, at: 6) == sequence
    }

    /// The reason, when the packet is a router's Destination Unreachable about this very ping: it
    /// quotes the IPv4 header and first eight bytes of the request it could not deliver, so the
    /// quoted destination, identifier and sequence must all be ours. Nil for anything else.
    static func unreachableReason(_ packet: [UInt8], expectedDestination: String, identifier: UInt16, sequence: UInt16) -> String? {
        guard let message = icmpMessage(in: packet), message.count >= headerSize + minimumIPv4HeaderSize + headerSize,
              message[0] == destinationUnreachable, checksum(message) == 0 else { return nil }
        let quoted = Array(message[headerSize...])
        guard quoted[0] >> 4 == 4 else { return nil }
        let quotedHeaderLength = Int(quoted[0] & 0x0F) * 4
        guard quotedHeaderLength >= minimumIPv4HeaderSize, quoted.count >= quotedHeaderLength + headerSize,
              quoted[protocolOffset] == UInt8(IPPROTO_ICMP),
              let destination = ipv4Bytes(expectedDestination), Array(quoted[destinationBytes]) == destination else { return nil }
        let request = Array(quoted[quotedHeaderLength...])
        guard request[0] == echoRequest, word(request, at: 4) == identifier, word(request, at: 6) == sequence else { return nil }
        return unreachableReasons[message[1]] ?? "unreachable (code \(message[1]))"
    }

    private static func ipv4Bytes(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    /// Darwin delivers the IPv4 header in front of the message on an ICMP datagram socket. An echo
    /// reply's first byte is its type, 0, so a first nibble of 4 is the header's version.
    private static func icmpMessage(in packet: [UInt8]) -> [UInt8]? {
        guard let first = packet.first else { return nil }
        guard first >> 4 == 4 else { return packet }
        let headerLength = Int(first & 0x0F) * 4
        guard headerLength >= minimumIPv4HeaderSize, packet.count >= headerLength else { return nil }
        return Array(packet[headerLength...])
    }

    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}

/// One ICMP echo over a datagram socket, which macOS lets an ordinary user open: no root and no
/// subprocess. Each ping opens its own socket, sends once, and waits for its own reply no longer
/// than its timeout. It blocks the calling thread for at most that long, so it runs on the
/// plugin's queue, never on main.
final class ICMPPinger: @unchecked Sendable {
    private static let receiveBufferSize = 1_500
    private static let nanosecondsPerMillisecond = 1_000_000.0

    private let identifier: UInt16
    private let lock = NSLock()
    private var nextSequence: UInt16 = 0

    init(identifier: UInt16 = .random(in: 1...UInt16.max)) {
        self.identifier = identifier
    }

    func ping(_ address: String, timeout: TimeInterval) -> PingOutcome {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { return .failed("not an IPv4 address") }

        let socketDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard socketDescriptor >= 0 else { return .failed(Self.errorText()) }
        defer { close(socketDescriptor) }

        let sequence = takeSequence()
        let packet = ICMPEcho.request(identifier: identifier, sequence: sequence)
        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started + UInt64(max(0, timeout) * 1_000_000_000)
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketDescriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == packet.count else { return .failed(Self.errorText()) }

        return awaitReply(on: socketDescriptor, from: address, sequence: sequence, started: started, deadline: deadline)
    }

    private func takeSequence() -> UInt16 {
        lock.withLock {
            nextSequence &+= 1
            return nextSequence
        }
    }

    /// Reads until the reply arrives, a router reports this ping undeliverable, or the deadline
    /// passes. `poll` waits only for what is left of the timeout, and the read never blocks, so no
    /// packet or its absence can hold the thread past the deadline.
    private func awaitReply(on socketDescriptor: Int32, from address: String, sequence: UInt16, started: UInt64, deadline: UInt64) -> PingOutcome {
        var buffer = [UInt8](repeating: 0, count: Self.receiveBufferSize)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timeout }
            let remainingMilliseconds = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
            var waiting = pollfd(fd: socketDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&waiting, 1, remainingMilliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return .failed(Self.errorText())
            }
            if ready == 0 { return .timeout }

            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketDescriptor, bytes.baseAddress, bytes.count, MSG_DONTWAIT, $0, &sourceLength)
                    }
                }
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .failed(Self.errorText())
            }
            let packet = Array(buffer.prefix(count))
            if ICMPEcho.isReply(packet, from: Self.text(source.sin_addr), expectedSource: address, identifier: identifier, sequence: sequence) {
                let elapsed = DispatchTime.now().uptimeNanoseconds - started
                return .reply(milliseconds: Double(elapsed) / Self.nanosecondsPerMillisecond)
            }
            if let reason = ICMPEcho.unreachableReason(packet, expectedDestination: address, identifier: identifier, sequence: sequence) {
                return .failed(reason)
            }
        }
    }

    private static func text(_ address: in_addr) -> String {
        var address = address
        var characters = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &characters, socklen_t(characters.count)) != nil else { return "" }
        return String(cString: characters)
    }

    private static func errorText() -> String {
        String(cString: strerror(errno))
    }
}
