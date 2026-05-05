import SwiftUI
import R10Kit

/// Detail screen pushed when a row in `ContentView`'s shot list
/// is tapped. Renders every field the SDK exposes for the shot,
/// grouped by source. Mechanically driven by `ShotDetailViewModel`
/// — this view has no formatting logic, it just renders rows.
struct ShotDetailView: View {
    let shot: R10ShotEvent

    private var viewModel: ShotDetailViewModel {
        ShotDetailViewModel(shot: shot)
    }

    var body: some View {
        Form {
            ForEach(viewModel.sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.rows, id: \.label) { row in
                        DetailRow(row: row)
                    }
                }
            }
        }
        .navigationTitle(headerTitle)
        .navigationBarTitleDisplayMode(.inline)
        // .textSelection on the Form lets the user long-press any
        // value to copy — covers the "developer wants to grab a
        // number" case without a custom gesture per row.
        .textSelection(.enabled)
    }

    private var headerTitle: String {
        if let id = shot.metrics.shotId { return "Shot \(id)" }
        return "Shot"
    }
}

/// One row in the detail Form. Label on the leading edge,
/// primary value trailing in monospaced numerals, optional
/// secondary value below the primary in `.footnote`.
private struct DetailRow: View {
    let row: ShotDetailViewModel.Row

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let secondary = row.secondary {
                    Text(secondary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        } label: {
            Text(row.label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Compose label + primary + secondary into one VO string so
    /// the row reads as "Club speed, 98 miles per hour, 43.83 meters
    /// per second." rather than three separate elements. Unit
    /// abbreviations are left as-is — VO handles "mph"/"m/s"
    /// reasonably; long-form expansion isn't worth the table here
    /// for a developer demo.
    private var accessibilityText: String {
        var parts = [row.label, row.primary]
        if let secondary = row.secondary { parts.append(secondary) }
        return parts.joined(separator: ", ")
    }
}

#Preview {
    NavigationStack {
        ShotDetailView(shot: R10ShotEvent(
            metrics: R10Metrics(
                shotId: 4321,
                shotType: .normal,
                ballMetrics: R10BallMetrics(
                    launchAngle: 12.3,
                    launchDirection: -1.5,
                    ballSpeed: 60,
                    spinAxis: 4.5,
                    totalSpin: 5500,
                    spinCalcType: .measured,
                    golfBallType: .conventional
                ),
                clubMetrics: R10ClubMetrics(
                    clubHeadSpeed: 43.83,
                    clubAngleFace: 1.2,
                    clubAnglePath: -2.5,
                    attackAngle: 0.5
                ),
                swingMetrics: R10SwingMetrics(
                    backSwingStartTime: 1000,
                    downSwingStartTime: 1750,
                    impactTime: 2000,
                    followThroughEndTime: 2500,
                    endRecordingTime: 2600
                )
            ),
            wallClockImpactAt: Date()
        ))
    }
}
