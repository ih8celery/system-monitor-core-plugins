import Darwin
import Foundation
import SystemBarKit

/// The Network tab's latency line: the ICMP echo packet and what counts as its reply, the default
/// router read from the routing table, the `pingAddress` setting, one probe of router and
/// internet through a fake pinger, the history and what it suggests, a real ping of loopback,
/// and the plugin pinging every 5 s while sampling traffic only while the tab shows.
@MainActor
enum NetworkLatencyTests {
    static func runAll() {
        testEchoRequestCarriesItsIdentityAndChecksum()
        testReplyMustMatchSourceIdentifierAndSequence()
        testReplyIsReadWithOrWithoutAnIPHeader()
        testDefaultGatewayFromTheRoutingTable()
        testPingAddressSetting()
        testProbeRecordsRepliesAndFailures()
        testProbeWithoutAnIPv4RoutePingsNothing()
        testProbePingsBothAtOnce()
        testNotesShowTheSettingProblemAndTheDiagnosis()
        testUnreachableIsReadFromTheRoutersError()
        testHistoryKeepsTheLastFiveMinutes()
        testDiagnosisNamesTheLikelyFault()
        testLatencyText()
        testRealPingOfLoopbackGetsAReply()
        testRealPingGivesUpAtItsTimeout()
        testPluginPingsEveryCollectButSamplesTrafficOnlyWhileShown()
        testPluginReportsABadPingAddress()
    }

    // MARK: - The packet

    private static func testEchoRequestCarriesItsIdentityAndChecksum() {
        let packet = ICMPEcho.request(identifier: 0xBEEF, sequence: 7)
        expect(packet.count == ICMPEcho.headerSize + ICMPEcho.payloadSize, "header plus payload, got \(packet.count) bytes")
        expect(packet[0] == ICMPEcho.echoRequest && packet[1] == 0, "type 8 code 0 is an echo request")
        expect(packet[4] == 0xBE && packet[5] == 0xEF && packet[6] == 0 && packet[7] == 7, "identifier and sequence in network order")
        expect(ICMPEcho.checksum(packet) == 0, "a packet carrying its checksum sums to zero")
    }

    private static func reply(identifier: UInt16 = 0xBEEF, sequence: UInt16 = 7, type: UInt8 = ICMPEcho.echoReply) -> [UInt8] {
        var packet = ICMPEcho.request(identifier: identifier, sequence: sequence)
        packet[0] = type
        packet[2] = 0
        packet[3] = 0
        let sum = ICMPEcho.checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)
        return packet
    }

    private static func isOurs(_ packet: [UInt8], from source: String = "1.1.1.1") -> Bool {
        ICMPEcho.isReply(packet, from: source, expectedSource: "1.1.1.1", identifier: 0xBEEF, sequence: 7)
    }

    private static func testReplyMustMatchSourceIdentifierAndSequence() {
        expect(isOurs(reply()), "a reply from the address pinged, with our identifier and sequence, is ours")
        expect(!isOurs(reply(), from: "8.8.8.8"), "a reply from another address is not")
        expect(!isOurs(reply(identifier: 0xBEEE)), "another program's identifier is not")
        expect(!isOurs(reply(sequence: 6)), "a late reply to an earlier ping is not")
        expect(!isOurs(reply(type: ICMPEcho.echoRequest)), "an echo request is not a reply")
        var corrupt = reply()
        corrupt[ICMPEcho.headerSize] ^= 0xFF
        expect(!isOurs(corrupt), "a packet whose checksum does not add up is not")
        expect(!isOurs(Array(reply().prefix(6))), "a truncated packet is not")
        expect(!isOurs([]), "nothing is not")
    }

    /// Darwin hands an ICMP datagram socket the IPv4 header in front of the message.
    private static func testReplyIsReadWithOrWithoutAnIPHeader() {
        var header = [UInt8](repeating: 0, count: 20)
        header[0] = 0x45
        expect(isOurs(header + reply()), "a reply behind a 20-byte IPv4 header is found")
        var withOptions = [UInt8](repeating: 0, count: 24)
        withOptions[0] = 0x46
        expect(isOurs(withOptions + reply()), "the header length is read, not assumed")
        expect(!isOurs(Array(header.prefix(10))), "a header cut short is not a reply")
    }

    // MARK: - The router

    /// One routing message as the kernel lays it out: the header, then each address it carries,
    /// rounded up to four bytes.
    private static func route(destination: String, gateway: String, flags: Int32 = RTF_UP | RTF_GATEWAY) -> [UInt8] {
        func address(_ text: String) -> [UInt8] {
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, text, &socketAddress.sin_addr)
            return withUnsafeBytes(of: socketAddress) { Array($0) }
        }
        let emptyNetmask: [UInt8] = [0, 0, 0, 0]
        let body = address(destination) + address(gateway) + emptyNetmask
        var header = rt_msghdr()
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_type = UInt8(RTM_GET)
        header.rtm_flags = flags
        header.rtm_addrs = RTA_DST | RTA_GATEWAY | RTA_NETMASK
        return withUnsafeBytes(of: header) { Array($0) } + body
    }

    private static func testDefaultGatewayFromTheRoutingTable() {
        let scoped = route(destination: "0.0.0.0", gateway: "10.0.0.1", flags: RTF_UP | RTF_GATEWAY | RTF_IFSCOPE)
        let subnet = route(destination: "192.168.1.0", gateway: "192.168.1.254")
        let main = route(destination: "0.0.0.0", gateway: "192.168.1.1")
        expect(DefaultGateway.parse(scoped + subnet + main) == "192.168.1.1", "the unscoped default route names the router, got \(String(describing: DefaultGateway.parse(scoped + subnet + main)))")
        expect(DefaultGateway.parse(subnet) == nil, "no default route, no router")
        expect(DefaultGateway.parse([]) == nil, "an empty table has no router")
        expect(DefaultGateway.parse(Array(main.prefix(40))) == nil, "a message cut short is skipped, not read past its end")
        let down = route(destination: "0.0.0.0", gateway: "192.168.1.1", flags: RTF_GATEWAY)
        expect(DefaultGateway.parse(down) == nil, "a route that is not up names no router")
    }

    // MARK: - The setting

    private static func testPingAddressSetting() {
        let absent = LatencySettings.internetAddress(.empty)
        expect(absent.address == "1.1.1.1" && absent.problem == nil, "no setting pings 1.1.1.1")
        let chosen = LatencySettings.internetAddress(PluginSettings(values: ["pingAddress": .string("9.9.9.9")]))
        expect(chosen.address == "9.9.9.9" && chosen.problem == nil, "an IPv4 address is used as given")
        for bad: PluginSettings.Value in [.string("one.one.one.one"), .string("2606:4700::1111"), .string("1.1.1"), .number(1), .bool(true)] {
            let result = LatencySettings.internetAddress(PluginSettings(values: ["pingAddress": bad]))
            expect(result.address == "1.1.1.1", "\(bad) keeps the default, got \(result.address)")
            expect(result.problem == "settings: \"pingAddress\" must be an IPv4 address such as 1.1.1.1; pinging 1.1.1.1", "and says so, got \(String(describing: result.problem))")
        }
    }

    // MARK: - One probe

    private static func testProbeRecordsRepliesAndFailures() {
        let at = Date(timeIntervalSince1970: 100)
        let answers: [String: PingOutcome] = ["192.168.1.1": .reply(milliseconds: 3), "1.1.1.1": .timeout]
        let sample = LatencyProbe.measure(router: "192.168.1.1", internet: "1.1.1.1", at: at) { address, _ in answers[address] ?? .failed("unexpected \(address)") }
        expect(sample == LatencySample(at: at, router: .reply(3), internet: .failed("timed out")), "a reply and a timeout, got \(sample)")

        let refused = LatencyProbe.measure(router: "192.168.1.1", internet: "1.1.1.1", at: at) { _, _ in .failed("No route to host") }
        expect(refused.router == .failed("No route to host") && refused.internet == .failed("No route to host"), "a send that fails says why, got \(refused)")
    }

    /// An IPv6-only network, or none at all: with no IPv4 default route a ping to 1.1.1.1 can only
    /// fail at once, which would read as an outage on a connection that works.
    private static func testProbeWithoutAnIPv4RoutePingsNothing() {
        let asked = LogRecorder()
        let sample = LatencyProbe.measure(router: nil, internet: "1.1.1.1", at: Date()) { address, _ in
            asked.record(address)
            return .failed("Network is unreachable")
        }
        expect(asked.messages.isEmpty, "with no IPv4 default route nothing is pinged, got \(asked.messages)")
        expect(sample.router == .unknown && sample.internet == .unknown, "and both lines are unknown, not failed, got \(sample)")
        let history = LatencyHistory().appending(sample)
        expect(history.diagnosis == nil, "no false alarm about the Wi-Fi or local network")
        expect(LatencyState(internetAddress: "1.1.1.1", settingsProblem: nil).recording(sample).notes == [LatencyHistory.noRouteNote], "the tab says why there is no line")
    }

    /// Both targets silent costs one timeout, not two.
    private static func testProbePingsBothAtOnce() {
        let started = Date()
        let sample = LatencyProbe.measure(router: "192.168.1.1", internet: "1.1.1.1", at: started, timeout: 0.4) { _, timeout in
            Thread.sleep(forTimeInterval: timeout)
            return .timeout
        }
        let waited = Date().timeIntervalSince(started)
        expect(sample.router == .failed("timed out") && sample.internet == .failed("timed out"), "both time out, got \(sample)")
        expect(waited < 0.7, "the two pings wait together, waited \(waited) s")
    }

    // MARK: - History and diagnosis

    private static func sample(_ seconds: TimeInterval, router: LatencyPoint = .reply(2), internet: LatencyPoint = .reply(15)) -> LatencySample {
        LatencySample(at: Date(timeIntervalSince1970: seconds), router: router, internet: internet)
    }

    private static func testHistoryKeepsTheLastFiveMinutes() {
        var history = LatencyHistory()
        for second in 0..<(LatencyHistory.capacity + 5) {
            history = history.appending(sample(TimeInterval(second * 5)))
        }
        expect(LatencyHistory.capacity == 60, "five minutes of 5-second pings")
        expect(history.samples.count == LatencyHistory.capacity, "the oldest fall off, got \(history.samples.count)")
        expect(history.samples.first?.at == Date(timeIntervalSince1970: 25), "the newest are kept, got \(String(describing: history.samples.first?.at))")
    }

    private static func testDiagnosisNamesTheLikelyFault() {
        let fine = LatencyHistory().appending(sample(0))
        expect(fine.diagnosis == nil, "both answering needs no explanation")
        let isp = LatencyHistory().appending(sample(0, internet: .failed("timed out")))
        expect(isp.diagnosis == .internet, "router fine, internet failing points past the router")
        expect(isp.diagnosis?.text == "The router answers but the internet does not: likely your internet provider", "got \(String(describing: isp.diagnosis?.text))")
        let local = LatencyHistory().appending(sample(0, router: .failed("timed out"), internet: .failed("timed out")))
        expect(local.diagnosis == .localNetwork, "both failing points at the Wi-Fi or local network")
        let noRouter = LatencyHistory().appending(sample(0, router: .unknown, internet: .failed("No route to host")))
        expect(noRouter.diagnosis == .localNetwork, "no router and no internet is the local network too")
        expect(LatencyHistory().diagnosis == nil, "no sample, nothing to say")
    }

    private static func testNotesShowTheSettingProblemAndTheDiagnosis() {
        let failing = LatencySample(at: Date(), router: .reply(2), internet: .failed("timed out"))
        let state = LatencyState(internetAddress: "1.1.1.1", settingsProblem: "settings problem").recording(failing)
        expect(state.notes == ["settings problem", LatencyDiagnosis.internet.text], "a settings typo does not hide the diagnosis, got \(state.notes)")
        expect(LatencyState(internetAddress: "1.1.1.1", settingsProblem: nil).notes.isEmpty, "nothing to say, no notes")
    }

    /// What a router sends back when it cannot deliver our echo: type 3, then the IPv4 header and
    /// first eight bytes of the request it is answering.
    private static func unreachable(code: UInt8 = 1, to destination: [UInt8] = [1, 1, 1, 1], identifier: UInt16 = 0xBEEF, sequence: UInt16 = 7) -> [UInt8] {
        var original = [UInt8](repeating: 0, count: 20)
        original[0] = 0x45
        original[9] = UInt8(IPPROTO_ICMP)
        original.replaceSubrange(16..<20, with: destination)
        let request = Array(ICMPEcho.request(identifier: identifier, sequence: sequence).prefix(8))
        var message: [UInt8] = [3, code, 0, 0, 0, 0, 0, 0] + original + request
        let sum = ICMPEcho.checksum(message)
        message[2] = UInt8(sum >> 8)
        message[3] = UInt8(sum & 0xFF)
        return message
    }

    private static func testUnreachableIsReadFromTheRoutersError() {
        func reason(_ packet: [UInt8]) -> String? {
            ICMPEcho.unreachableReason(packet, expectedDestination: "1.1.1.1", identifier: 0xBEEF, sequence: 7)
        }
        expect(reason(unreachable(code: 1)) == "host unreachable", "the router's error for our ping is read, got \(String(describing: reason(unreachable(code: 1))))")
        expect(reason(unreachable(code: 0)) == "network unreachable", "with its reason")
        expect(reason(unreachable(code: 13)) == "unreachable (code 13)", "an unnamed code still says unreachable")
        var header = [UInt8](repeating: 0, count: 20)
        header[0] = 0x45
        expect(reason(header + unreachable()) == "host unreachable", "behind the IPv4 header Darwin adds")
        expect(reason(unreachable(to: [8, 8, 8, 8])) == nil, "an error about a ping to elsewhere is not ours")
        expect(reason(unreachable(sequence: 6)) == nil, "nor one about an earlier ping")
        expect(reason(unreachable(identifier: 1)) == nil, "nor another program's")
        expect(reason(Array(unreachable().prefix(30))) == nil, "a cut-short error is not read")
        expect(reason(reply()) == nil, "a reply is not an error")
    }

    private static func testLatencyText() {
        expect(latencyText(.reply(3.24)) == "3.2 ms" && latencyText(.reply(18.4)) == "18 ms", "under 10 ms keeps a decimal")
        expect(latencyText(.failed("timed out")) == "failed" && latencyText(.unknown) == "no route" && latencyText(nil) == "-- ms", "and the rest say what happened")
    }

    // MARK: - The real socket

    private static func testRealPingOfLoopbackGetsAReply() {
        let outcome = ICMPPinger().ping("127.0.0.1", timeout: 1)
        guard case .reply(let milliseconds) = outcome else {
            expect(false, "loopback answers an ICMP datagram socket without root, got \(outcome)")
            return
        }
        expect(milliseconds >= 0 && milliseconds < 1_000, "and the round trip is timed, got \(milliseconds) ms")
    }

    /// 127.255.255.254 is loopback, so the ping never leaves the Mac, and nothing answers it unless
    /// someone has aliased that address onto lo0.
    private static func testRealPingGivesUpAtItsTimeout() {
        let started = Date()
        let outcome = ICMPPinger().ping("127.255.255.254", timeout: 0.3)
        let waited = Date().timeIntervalSince(started)
        if case .reply = outcome { expect(false, "an unassigned loopback address never answers") }
        expect(waited < 1, "every wait is bounded by the timeout, waited \(waited) s")
        expect(ICMPPinger().ping("not an address", timeout: 0.3) == .failed("not an IPv4 address"), "a bad address fails at once")
    }

    // MARK: - The plugin

    private static let nettopCommand = "/usr/bin/nettop -d -P -L 2 -s 1 -x -n -J bytes_in,bytes_out"
    private static let lsofCommand = "/usr/sbin/lsof -n -P -iTCP"

    private static func testPluginPingsEveryCollectButSamplesTrafficOnlyWhileShown() {
        let commands = LogRecorder()
        let wifiReads = LogRecorder()
        let clock = LockedClock(Date(timeIntervalSince1970: 1_000))
        let probes = NetworkProbes(
            readWiFi: { wifiReads.record("read"); return nil },
            ping: { address, _ in address == "192.168.1.1" ? .reply(milliseconds: 2) : .reply(milliseconds: 18) },
            gateway: { "192.168.1.1" },
            now: { clock.now }
        )
        let host = makeHost(runner: recordingRunner(commands, answers: [nettopCommand: "", lsofCommand: ""]))
        let plugin = NetworkPlugin(host: host, probes: probes)
        expect(plugin.refreshInterval == 5 && plugin.backgroundInterval == 5, "it is called every 5 s, shown or hidden")

        plugin.collect()
        waitUntil { plugin.latency.history.samples.count == 1 }
        expect(plugin.latency.history.samples.last == LatencySample(at: clock.now, router: .reply(2), internet: .reply(18)), "a hidden collect pings, got \(plugin.latency.history.samples)")
        expect(commands.count == 0 && wifiReads.count == 0, "but runs no nettop or lsof and reads no Wi-Fi, got \(commands.messages)")

        plugin.visibilityChanged(isVisible: true)
        plugin.collect()
        waitUntil { plugin.latency.history.samples.count == 2 }
        expect(commands.count == 2 && wifiReads.count == 1, "the first collect once shown samples traffic and Wi-Fi, got \(commands.messages)")

        clock.advance(NetworkSampling.pingInterval)
        plugin.collect()
        waitUntil { plugin.latency.history.samples.count == 3 }
        expect(commands.count == 2, "nettop and lsof wait for their own 30 s, got \(commands.messages)")
        expect(wifiReads.count == 2, "the Wi-Fi card follows every shown collect")

        clock.advance(NetworkSampling.trafficInterval)
        plugin.collect()
        waitUntil { plugin.latency.history.samples.count == 4 }
        expect(commands.count == 4, "and run again once it has passed, got \(commands.messages)")

        plugin.visibilityChanged(isVisible: false)
        plugin.visibilityChanged(isVisible: true)
        plugin.collect()
        waitUntil { plugin.latency.history.samples.count == 5 }
        expect(commands.count == 6, "showing the tab again samples traffic at once, got \(commands.messages)")
    }

    private static func testPluginReportsABadPingAddress() {
        let host = makeHost(settings: PluginSettings(values: ["pingAddress": .string("cloudflare")]))
        let plugin = NetworkPlugin(host: host, probes: .fake())
        expect(plugin.latency.internetAddress == "1.1.1.1", "a bad setting pings the default")
        expect(plugin.latency.settingsProblem?.contains("pingAddress") == true, "and the tab says what is wrong, got \(String(describing: plugin.latency.settingsProblem))")
    }
}

/// A clock a test moves by hand, read from the plugin's queue.
final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

extension NetworkProbes {
    /// No Wi-Fi, a router that is never found, and an internet that always answers in 10 ms.
    static func fake(readWiFi: @escaping @Sendable () -> WiFiSignal? = { nil }) -> NetworkProbes {
        NetworkProbes(readWiFi: readWiFi, ping: { _, _ in .reply(milliseconds: 10) }, gateway: { nil }, now: { Date() })
    }
}
