import Foundation
import SwiftUI
import SystemBarKit

/// The panel's left column: the headline, the quick facts, the read/write graph, the capacity
/// bar and the map of where the space is, with the other volumes and the status line below.
struct DiskSpaceColumn: View {
    static let width: CGFloat = 430

    let snapshot: DiskSnapshot
    let activity: DiskActivityHistory
    let homeDirectory: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Everything but the status line scrolls. The host gives a tab a fixed box under
            // its tab bar and centres a tab that insists on more, which pushes the tab bar off
            // the top of the popover: so the column takes the height it is offered, and a Mac
            // with more volumes than fit scrolls to the rest.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    headline
                    quickFacts
                    activitySection
                    capacityAndMap
                    otherVolumes
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text(snapshot.status)
                .font(.caption)
                .foregroundStyle(snapshot.health == .ok ? .secondary : Palette.warning)
        }
        .padding(18)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var headline: some View {
        VStack(alignment: .leading, spacing: 2) {
                Text(headlineText)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(headlineColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let note = snapshot.boot?.purgeableNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
    }

    private var quickFacts: some View {
        HStack(spacing: 10) {
            StatPill(label: "Snapshots", value: "\(snapshot.localSnapshotCount)")
            if let boot = snapshot.boot {
                StatPill(label: "Used", value: fileByteString(boot.finderUsed))
                StatPill(label: "Capacity", value: fileByteString(boot.total))
            }
        }
    }

    @ViewBuilder
    private var capacityAndMap: some View {
            if let boot = snapshot.boot {
                SegmentedBar(segments: capacityRows(for: boot).filter { $0.value > 0 }, total: boot.total)
                    .frame(height: 34)
                SegmentedLegend(rows: capacityRows(for: boot), format: DiskPanel.sizeFormat)

                SectionTitle("Where the space is")
                let distribution = DiskRows.distribution(biggest: snapshot.biggest, volume: boot, homeDirectory: homeDirectory)
                SegmentedBar(segments: distribution.filter { $0.value > 0 }, total: boot.total)
                    .frame(height: 20)
                SegmentedLegend(rows: distribution, format: DiskPanel.sizeFormat)
                if boot.purgeableNote != nil {
                    Text("This map counts purgeable space as used, because it is on the disk, so its total reads higher than Used above.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
    }

    @ViewBuilder
    private var otherVolumes: some View {
        if !snapshot.otherVolumes.isEmpty {
            SectionTitle("Other Volumes")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snapshot.otherVolumes) { volume in
                    EvidenceRow(
                        label: volume.name,
                        value: volume.freeText,
                        detail: volume.usageDetail
                    )
                }
            }
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RateCard(title: "Read", value: DiskActivity.rateText(activity.currentReadRate), color: Palette.blue)
                RateCard(title: "Write", value: DiskActivity.rateText(activity.currentWriteRate), color: Palette.tangerine)
            }
            if let problem = activity.problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(Palette.warning)
            } else {
                HStack(spacing: 12) {
                    LegendLabel(text: "Read", color: Palette.blue)
                    LegendLabel(text: "Write", color: Palette.tangerine)
                    Spacer()
                    ChartUnitLabel("B/s - last 2 min")
                }
                DualSparkline(
                    first: activity.readRates,
                    second: activity.writeRates,
                    firstColor: Palette.blue,
                    secondColor: Palette.tangerine
                )
                .frame(height: 56)
            }
        }
    }

    private var headlineText: String {
        guard let boot = snapshot.boot else { return "Reading volumes" }
        return boot.headline
    }

    private var headlineColor: Color {
        guard let boot = snapshot.boot else { return .secondary }
        switch boot.freeSpaceLevel {
        case .good: return Palette.good
        case .caution: return Palette.caution
        case .critical: return Palette.critical
        }
    }
}
