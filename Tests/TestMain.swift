import Foundation

/// Every tab's suite, in one process: each tab's sources and tests compile into one module here,
/// the way they did inside SystemBar, so a failure stops at the first broken expectation.
@main
struct CorePluginTests {
    static func main() {
        MainActor.assumeIsolated {
            CPUTests.runAll()
            PowerTests.runAll()
            DiskTests.runAll()
            DiskLedgerTests.runAll()
            DiskRowsTests.runAll()
            DiskStoreTests.runAll()
            DiskScanTests.runAll()
            DiskActivityTests.runAll()
            MemoryTests.runAll()
            NetworkTests.runAll()
            NetworkWiFiTests.runAll()
            CapacityTests.runAll()
            DevPluginTests.runAll()
        }
        print("Core plugin tests passed")
    }
}
