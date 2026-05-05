import Foundation
import R10Kit

/// Pure projection of an `R10ShotEvent` into ordered, titled
/// sections of label/value rows. The view renders this mechanically;
/// all formatting + section-assembly logic lives here so it can be
/// unit-tested without SwiftUI.
///
/// Sections present (in order, when their inputs exist):
/// `Identity`, `Ball`, `Club`, `Swing timing`, `Derived`.
struct ShotDetailViewModel: Equatable {
    struct Section: Equatable {
        let title: String
        let rows: [Row]
    }

    /// One pair on the detail screen. `secondary` carries an
    /// alternate unit / cross-reference (e.g. m/s alongside mph
    /// or "may not be monotonic" alongside `endRecordingTime`).
    struct Row: Equatable {
        let label: String
        let primary: String
        let secondary: String?

        init(label: String, primary: String, secondary: String? = nil) {
            self.label = label
            self.primary = primary
            self.secondary = secondary
        }
    }

    let sections: [Section]

    init(shot: R10ShotEvent) {
        var built: [Section] = []
        built.append(Self.identitySection(shot: shot))
        if let ball = Self.ballSection(shot.metrics.ballMetrics)        { built.append(ball) }
        if let club = Self.clubSection(shot.metrics.clubMetrics)        { built.append(club) }
        if let swing = Self.swingSection(shot.metrics.swingMetrics)     { built.append(swing) }
        if let derived = Self.derivedSection(metrics: shot.metrics)     { built.append(derived) }
        self.sections = built
    }

    // MARK: - Identity

    private static func identitySection(shot: R10ShotEvent) -> Section {
        var rows: [Row] = []
        if let id = shot.metrics.shotId {
            rows.append(Row(label: "Shot ID", primary: "\(id)"))
        }
        rows.append(Row(label: "Shot type", primary: shotTypeLabel(shot.metrics.shotType)))
        rows.append(Row(
            label: "Impact",
            primary: shot.wallClockImpactAt.formatted(date: .abbreviated, time: .standard),
            secondary: shot.wallClockImpactAt.formatted(.relative(presentation: .named))
        ))
        rows.append(Row(
            label: "Impact (raw)",
            primary: String(format: "%.3f", shot.wallClockImpactAt.timeIntervalSince1970),
            secondary: "epoch seconds"
        ))
        return Section(title: "Identity", rows: rows)
    }

    private static func shotTypeLabel(_ type: R10ShotType?) -> String {
        switch type {
        case .normal:   return "Normal"
        case .practice: return "Practice"
        case .unknown:  return "Unknown"
        case nil:       return "—"
        }
    }

    // MARK: - Ball

    private static func ballSection(_ ball: R10BallMetrics?) -> Section? {
        guard let ball else { return nil }
        var rows: [Row] = []
        if let mps = ball.ballSpeed {
            rows.append(speedRow(label: "Ball speed", mps: mps))
        }
        if let v = ball.launchAngle {
            rows.append(Row(label: "Launch angle", primary: degrees(v, fractionDigits: 1)))
        }
        if let v = ball.launchDirection {
            rows.append(Row(label: "Launch direction", primary: degrees(v, fractionDigits: 1)))
        }
        if let v = ball.totalSpin {
            rows.append(Row(label: "Total spin", primary: "\(Int(v.rounded())) rpm"))
        }
        if let v = ball.spinAxis {
            rows.append(Row(label: "Spin axis", primary: degrees(v, fractionDigits: 1)))
        }
        if let provenance = ball.spinCalcType {
            rows.append(Row(label: "Spin calc type", primary: provenance.displayName))
        }
        if let ballType = ball.golfBallType {
            rows.append(Row(label: "Golf ball type", primary: ballType.displayName))
        }
        return rows.isEmpty ? nil : Section(title: "Ball", rows: rows)
    }

    // MARK: - Club

    private static func clubSection(_ club: R10ClubMetrics?) -> Section? {
        guard let club else { return nil }
        var rows: [Row] = []
        if let mps = club.clubHeadSpeed {
            rows.append(speedRow(label: "Club speed", mps: mps))
        }
        if let v = club.clubAngleFace {
            rows.append(Row(label: "Club face", primary: degrees(v, fractionDigits: 1)))
        }
        if let v = club.clubAnglePath {
            rows.append(Row(label: "Club path", primary: degrees(v, fractionDigits: 1)))
        }
        if let v = club.attackAngle {
            rows.append(Row(label: "Attack angle", primary: degrees(v, fractionDigits: 1)))
        }
        return rows.isEmpty ? nil : Section(title: "Club", rows: rows)
    }

    // MARK: - Swing timing

    private static func swingSection(_ swing: R10SwingMetrics?) -> Section? {
        guard let swing else { return nil }
        var rows: [Row] = []
        if let v = swing.backSwingStartTime { rows.append(msRow("Back swing start", v)) }
        if let v = swing.downSwingStartTime { rows.append(msRow("Down swing start", v)) }
        if let v = swing.impactTime         { rows.append(msRow("Impact", v)) }
        if let v = swing.followThroughEndTime { rows.append(msRow("Follow-through end", v)) }
        if let v = swing.endRecordingTime {
            // Developer-demo: surface this even though firmware
            // sometimes emits it out-of-order vs. follow-through end.
            rows.append(Row(
                label: "End recording",
                primary: "\(v) ms",
                secondary: "raw — may not be monotonic with impact"
            ))
        }
        return rows.isEmpty ? nil : Section(title: "Swing timing", rows: rows)
    }

    private static func msRow(_ label: String, _ ms: UInt32) -> Row {
        Row(label: label, primary: "\(ms) ms")
    }

    // MARK: - Derived

    private static func derivedSection(metrics: R10Metrics) -> Section? {
        var rows: [Row] = []

        // Smash factor — ball÷club. Both speeds in the same unit
        // cancel out, so the ratio is dimensionless.
        if let ball = metrics.ballMetrics?.ballSpeed,
           let club = metrics.clubMetrics?.clubHeadSpeed,
           club > 0 {
            let smash = Double(ball) / Double(club)
            rows.append(Row(label: "Smash factor", primary: String(format: "%.2f", smash)))
        }

        // Face-to-path = face - path. Positive = face open relative
        // to path (slice tendency for a right-hander); negative = closed.
        if let face = metrics.clubMetrics?.clubAngleFace,
           let path = metrics.clubMetrics?.clubAnglePath {
            rows.append(Row(label: "Face-to-path", primary: degrees(face - path, fractionDigits: 1)))
        }

        // Swing-timing-derived durations. Each only emitted when its
        // raw inputs exist AND the resulting duration is strictly
        // positive (monotonicity guard — out-of-order timestamps
        // would otherwise surface as "-750 ms" rows).
        if let back = metrics.swingMetrics?.backSwingStartTime,
           let down = metrics.swingMetrics?.downSwingStartTime,
           down > back {
            rows.append(msRow("Backswing duration", down - back))
        }
        if let down = metrics.swingMetrics?.downSwingStartTime,
           let impact = metrics.swingMetrics?.impactTime,
           impact > down {
            rows.append(msRow("Downswing duration", impact - down))
        }
        if let impact = metrics.swingMetrics?.impactTime,
           let follow = metrics.swingMetrics?.followThroughEndTime,
           follow > impact {
            rows.append(msRow("Follow-through duration", follow - impact))
        }
        if let back = metrics.swingMetrics?.backSwingStartTime,
           let impact = metrics.swingMetrics?.impactTime,
           impact > back {
            rows.append(msRow("Total swing duration", impact - back))
        }

        // Tempo ratio — golf convention is backswing ÷ downswing.
        // PGA-tour benchmark: ~3:1.
        if let back = metrics.swingMetrics?.backSwingStartTime,
           let down = metrics.swingMetrics?.downSwingStartTime,
           let impact = metrics.swingMetrics?.impactTime,
           down > back, impact > down {
            let backDuration = Double(down - back)
            let downDuration = Double(impact - down)
            let ratio = backDuration / downDuration
            rows.append(Row(label: "Tempo ratio", primary: String(format: "%.2f", ratio)))
        }

        return rows.isEmpty ? nil : Section(title: "Derived", rows: rows)
    }

    // MARK: - Formatters

    private static func speedRow(label: String, mps: Float) -> Row {
        let mph = Double(mps) * mpsToMph
        return Row(
            label: label,
            primary: "\(Int(mph.rounded())) mph",
            secondary: String(format: "%.2f m/s", mps)
        )
    }

    private static func degrees(_ value: Float, fractionDigits: Int) -> String {
        String(format: "%.\(fractionDigits)f°", value)
    }
}
