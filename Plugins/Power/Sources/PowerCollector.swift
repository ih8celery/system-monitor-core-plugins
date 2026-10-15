import Foundation
import SystemBarKit

/// Two pmset reads, one ioreg read of the battery driver, and the parsing of them. Pure apart
/// from `collect(using:)`.
enum PowerCollector {
    /// `previousExternal` is the last sample's charger state, nil for the first sample.
    static func collect(
        using host: HostServices,
        chargeLimitFile: URL = PowerCollector.chargeLimitFile,
        previousExternal: Bool? = nil
    ) -> PowerSnapshot {
        let battery = host.run(path: "/usr/bin/pmset", arguments: ["-g", "batt"])
        let driver = host.run(path: ioregPath, arguments: ioregArguments)
        let assertions = host.run(path: "/usr/bin/pmset", arguments: ["-g", "assertions"])
        let parsedBattery = parseBatteryStatus(battery.output)
        let driverEntry = driver.status == 0 ? batteryEntry(driver.output) : nil
        let isExternal = driverEntry?["ExternalConnected"] as? Bool
        let sourceJustChanged = previousExternal != nil && isExternal != nil && previousExternal != isExternal
        let parsedAssertions = assertions.status == 0 ? parseSleepAssertions(assertions.output) : []
        var status: [String] = []
        if battery.status != 0 { status.append("battery unavailable") }
        if driver.status != 0 { status.append("charge state unavailable") }
        if assertions.status != 0 { status.append("assertions unavailable") }

        return PowerSnapshot(
            powerSource: parsedBattery.powerSource,
            thermalState: thermalStateLabel(ProcessInfo.processInfo.thermalState),
            batteryPercent: parsedBattery.percent,
            chargeState: driverEntry.flatMap(chargeState(from:)),
            batteryDetail: driverEntry.flatMap(batteryDetail(from:)),
            chargeLimit: chargeLimit(fileAt: chargeLimitFile),
            powerDraw: powerDraw(from: driverEntry, sourceJustChanged: sourceJustChanged),
            hasDriverReading: driver.status == 0,
            isExternal: isExternal,
            sleepAssertions: parsedAssertions,
            status: status.isEmpty ? "Power sample OK" : status.joined(separator: ", "),
            health: SampleHealth(isOK: status.isEmpty)
        )
    }

    static func contributors(from rows: [ProcessSnapshot]) -> [PowerContributor] {
        rows.prefix(5).map { row in
            PowerContributor(
                name: row.name,
                evidence: "\(percentString(machineCPUPercent(row.cpu))) CPU, \(byteString(row.physical)) memory"
            )
        }
    }

    static func parseBatteryStatus(_ output: String) -> (powerSource: String, percent: Int?) {
        var powerSource = "Unknown power"
        var percent: Int?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Now drawing from") {
                powerSource = line
                    .replacingOccurrences(of: "Now drawing from", with: "")
                    .replacingOccurrences(of: "'", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.contains("%;") {
                let parts = line.components(separatedBy: ";").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let percentPart = parts.first,
                   let percentToken = percentPart.split(whereSeparator: \.isWhitespace).last {
                    percent = Int(percentToken.replacingOccurrences(of: "%", with: ""))
                }
            }
        }

        return (powerSource, percent)
    }

    static func parseSleepAssertions(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                let lower = line.lowercased()
                return lower.contains("prevent") && !lower.contains("= 0")
            }
            .prefix(8)
            .map { String($0) }
    }
}
