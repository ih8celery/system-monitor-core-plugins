import AppKit
import Foundation
import SwiftUI
import SystemBarKit

/// The Disk panel's layout. The host gives a tab a fixed box under its tab bar and centres a
/// tab that insists on more, which pushes the tab bar off the top of the popover: so the
/// space column, the panel's one rigid part, must take the height it is offered and no more.
@MainActor
enum DiskPanelTests {
    static func runAll() {
        // ImageRenderer expects an application object, as the real app has.
        _ = NSApplication.shared
        testTheSpaceColumnNeverTakesMoreHeightThanItIsOffered()
    }

    static let now = Date(timeIntervalSince1970: 100 * 86_400)
    static let home = "/tmp/systembar-tests"

    /// A busy Mac: a purgeable share (so both notes show), eight map slices, three extra
    /// volumes and a long status line.
    static func busySnapshot() -> DiskSnapshot {
        var snapshot = DiskSnapshot()
        snapshot.volumes = [
            DiskVolume(name: "Macintosh HD", path: "/", total: 1_000_000_000_000, free: 350_000_000_000, purgeable: 25_000_000_000, isRoot: true),
            DiskVolume(name: "Time Machine", path: "/Volumes/Time Machine", total: 2_000_000_000_000, free: 400_000_000_000, isRoot: false),
            DiskVolume(name: "Media", path: "/Volumes/Media", total: 4_000_000_000_000, free: 1_000_000_000_000, isRoot: false),
            DiskVolume(name: "Scratch", path: "/Volumes/Scratch", total: 500_000_000_000, free: 20_000_000_000, isRoot: false),
        ]
        snapshot.localSnapshotCount = 3
        snapshot.biggest = (1...8).map { index in
            DiskRow(name: "folder\(index)", path: "\(home)/folder\(index)", bytes: UInt64(100 - index) * 1_000_000_000,
                    measuredAt: now, kind: .folder, simulator: nil)
        }
        snapshot.status = "Disk sample degraded: one volume could not be read, and its figures are from the last good sample"
        snapshot.health = .degraded
        return snapshot
    }

    static func testTheSpaceColumnNeverTakesMoreHeightThanItIsOffered() {
        let column = DiskSpaceColumn(snapshot: busySnapshot(), activity: DiskActivityHistory(), homeDirectory: home)
        // From a popover shorter than today's to one taller: the column fills what it gets.
        for offered in [400, 560, 623, 900] as [CGFloat] {
            let renderer = ImageRenderer(content: column)
            renderer.scale = 1
            renderer.proposedSize = ProposedViewSize(width: DiskSpaceColumn.width, height: offered)
            guard let image = renderer.cgImage else { return expect(false, "the column should draw at \(offered) points") }
            expect(CGFloat(image.height) <= offered,
                   "offered \(Int(offered)) points of height, the space column took \(image.height): a column taller than the popover pushes the host's tab bar off the top")
            expect(CGFloat(image.width) == DiskSpaceColumn.width, "the column keeps its width, got \(image.width)")
        }
    }
}
