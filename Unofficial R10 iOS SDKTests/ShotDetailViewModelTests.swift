import Testing
import Foundation
import R10Kit
@testable import Unofficial_R10_iOS_SDK

/// RED: pure-logic tests for `ShotDetailViewModel`. The view-model
/// converts an `R10ShotEvent` into an ordered list of titled
/// sections of label/value rows. View renders mechanically from
/// this; all formatting + section assembly logic lives here so it
/// can be tested without SwiftUI.
struct ShotDetailViewModelTests {

    // MARK: - Identity section

    @Test func identitySectionIsAlwaysFirstAndCarriesShotIdAndShotType() {
        let shot = makeShot { $0.shotId = 4321; $0.shotType = .normal }
        let vm = ShotDetailViewModel(shot: shot)

        #expect(vm.sections.first?.title == "Identity")
        #expect(vm.identityRow(label: "Shot ID")?.primary == "4321")
        #expect(vm.identityRow(label: "Shot type")?.primary == "Normal")
    }

    @Test func identityShotTypeRendersPracticeAndUnknown() {
        let practice = makeShot { $0.shotType = .practice }
        let unknown = makeShot { $0.shotType = .unknown }
        #expect(ShotDetailViewModel(shot: practice).identityRow(label: "Shot type")?.primary == "Practice")
        #expect(ShotDetailViewModel(shot: unknown).identityRow(label: "Shot type")?.primary == "Unknown")
    }

    @Test func identityCarriesRawEpochSecondsForWallClockImpact() {
        // 2026-01-01T00:00:00Z → 1767225600.0
        let date = Date(timeIntervalSince1970: 1767225600)
        let shot = R10ShotEvent(metrics: R10Metrics(), wallClockImpactAt: date)
        let vm = ShotDetailViewModel(shot: shot)

        let rawRow = vm.identityRow(label: "Impact (raw)")
        #expect(rawRow != nil)
        #expect(rawRow?.primary.contains("1767225600") == true)
    }

    // MARK: - Ball section

    @Test func ballSectionContainsAllPopulatedFieldsInOrder() {
        let shot = makeShot {
            $0.ballMetrics = R10BallMetrics(
                launchAngle: 12.3,
                launchDirection: -1.5,
                ballSpeed: 60.0,
                spinAxis: 4.5,
                totalSpin: 5500,
                spinCalcType: .measured,
                golfBallType: .conventional
            )
        }
        let vm = ShotDetailViewModel(shot: shot)
        let ball = vm.section(titled: "Ball")
        #expect(ball != nil)
        let labels = ball?.rows.map(\.label)
        #expect(labels == [
            "Ball speed",
            "Launch angle",
            "Launch direction",
            "Total spin",
            "Spin axis",
            "Spin calc type",
            "Golf ball type",
        ])
    }

    @Test func ballSectionOmittedWhenBallMetricsNil() {
        let shot = makeShot { $0.ballMetrics = nil }
        let vm = ShotDetailViewModel(shot: shot)
        #expect(vm.section(titled: "Ball") == nil)
    }

    @Test func ballSpeedShowsBothMphAndMps() {
        let shot = makeShot {
            $0.ballMetrics = R10BallMetrics(ballSpeed: 60.0)
        }
        let vm = ShotDetailViewModel(shot: shot)
        let row = vm.row(in: "Ball", label: "Ball speed")
        #expect(row?.primary.contains("mph") == true)
        #expect(row?.secondary?.contains("m/s") == true)
        // 60 m/s = 134.216… mph, rounded → "134 mph"
        #expect(row?.primary == "134 mph")
        #expect(row?.secondary == "60.00 m/s")
    }

    @Test func provenanceEnumsRenderViaDisplayName() {
        let shot = makeShot {
            $0.ballMetrics = R10BallMetrics(
                spinCalcType: .ratio,
                golfBallType: .marked
            )
        }
        let vm = ShotDetailViewModel(shot: shot)
        #expect(vm.row(in: "Ball", label: "Spin calc type")?.primary == "Ratio (inferred)")
        #expect(vm.row(in: "Ball", label: "Golf ball type")?.primary == "Marked")
    }

    // MARK: - Club section

    @Test func clubSectionShowsSpeedInBothMpsAndMph() {
        let shot = makeShot {
            $0.clubMetrics = R10ClubMetrics(
                clubHeadSpeed: 43.83,
                clubAngleFace: 1.2,
                clubAnglePath: -2.5,
                attackAngle: 0.5
            )
        }
        let vm = ShotDetailViewModel(shot: shot)
        let row = vm.row(in: "Club", label: "Club speed")
        // 43.83 m/s ≈ 98.04 mph
        #expect(row?.primary == "98 mph")
        #expect(row?.secondary == "43.83 m/s")
    }

    @Test func clubSectionOmittedWhenClubMetricsNil() {
        let shot = makeShot { $0.clubMetrics = nil }
        let vm = ShotDetailViewModel(shot: shot)
        #expect(vm.section(titled: "Club") == nil)
    }

    // MARK: - Swing timing section

    @Test func swingTimingShowsAllFiveRawTimestampsAsMs() {
        let shot = makeShot {
            $0.swingMetrics = R10SwingMetrics(
                backSwingStartTime: 1000,
                downSwingStartTime: 1750,
                impactTime: 2000,
                followThroughEndTime: 2500,
                endRecordingTime: 2600
            )
        }
        let vm = ShotDetailViewModel(shot: shot)
        let timing = vm.section(titled: "Swing timing")
        let labels = timing?.rows.map(\.label)
        #expect(labels == [
            "Back swing start",
            "Down swing start",
            "Impact",
            "Follow-through end",
            "End recording",
        ])
        #expect(vm.row(in: "Swing timing", label: "Impact")?.primary == "2000 ms")
        // End recording is anomalous per protocol notes — show the
        // raw value but flag it in secondary so devs aren't misled.
        let endRow = vm.row(in: "Swing timing", label: "End recording")
        #expect(endRow?.primary == "2600 ms")
        #expect(endRow?.secondary?.lowercased().contains("anomalous") == true
                || endRow?.secondary?.lowercased().contains("monotonic") == true)
    }

    // MARK: - Derived section

    @Test func derivedComputesSmashFactorWhenBothSpeedsPresent() {
        let shot = makeShot {
            $0.ballMetrics = R10BallMetrics(ballSpeed: 60.0)
            $0.clubMetrics = R10ClubMetrics(clubHeadSpeed: 43.83)
        }
        let vm = ShotDetailViewModel(shot: shot)
        let row = vm.row(in: "Derived", label: "Smash factor")
        #expect(row != nil)
        // 60 / 43.83 ≈ 1.369 → "1.37"
        #expect(row?.primary == "1.37")
    }

    @Test func derivedOmitsSmashFactorWhenBallSpeedAbsent() {
        let shot = makeShot {
            $0.clubMetrics = R10ClubMetrics(clubHeadSpeed: 43.83)
        }
        let vm = ShotDetailViewModel(shot: shot)
        #expect(vm.row(in: "Derived", label: "Smash factor") == nil)
    }

    @Test func derivedComputesFaceToPath() {
        let shot = makeShot {
            $0.clubMetrics = R10ClubMetrics(clubAngleFace: 2.0, clubAnglePath: 5.0)
        }
        let vm = ShotDetailViewModel(shot: shot)
        // face - path = 2 - 5 = -3
        #expect(vm.row(in: "Derived", label: "Face-to-path")?.primary == "-3.0°")
    }

    @Test func derivedComputesAllSwingDurations() {
        // 1000 → 1750 → 2000 → 2500
        // backswing  = 1750 - 1000 = 750
        // downswing  = 2000 - 1750 = 250
        // follow-thru= 2500 - 2000 = 500
        // total swing= 2000 - 1000 = 1000
        let shot = makeShot {
            $0.swingMetrics = R10SwingMetrics(
                backSwingStartTime: 1000,
                downSwingStartTime: 1750,
                impactTime: 2000,
                followThroughEndTime: 2500
            )
        }
        let vm = ShotDetailViewModel(shot: shot)
        #expect(vm.row(in: "Derived", label: "Backswing duration")?.primary == "750 ms")
        #expect(vm.row(in: "Derived", label: "Downswing duration")?.primary == "250 ms")
        #expect(vm.row(in: "Derived", label: "Follow-through duration")?.primary == "500 ms")
        #expect(vm.row(in: "Derived", label: "Total swing duration")?.primary == "1000 ms")
    }

    @Test func derivedTempoRatioMatchesGolfConvention3To1() {
        // Golf convention: tempo = backswing / downswing.
        // 750 / 250 = 3.0 — the PGA-tour-canonical 3:1 ratio.
        let shot = makeShot {
            $0.swingMetrics = R10SwingMetrics(
                backSwingStartTime: 1000,
                downSwingStartTime: 1750,
                impactTime: 2000
            )
        }
        let vm = ShotDetailViewModel(shot: shot)
        #expect(vm.row(in: "Derived", label: "Tempo ratio")?.primary == "3.00")
    }

    @Test func derivedOmitsNegativeOrZeroDurations() {
        // Out-of-order timestamps shouldn't produce negative or
        // zero duration rows. impact < backStart is the canonical
        // monotonicity violation.
        let shot = makeShot {
            $0.swingMetrics = R10SwingMetrics(
                backSwingStartTime: 2000,
                downSwingStartTime: 1750,
                impactTime: 1000
            )
        }
        let vm = ShotDetailViewModel(shot: shot)
        // None of the negative durations should be presented.
        #expect(vm.row(in: "Derived", label: "Backswing duration") == nil)
        #expect(vm.row(in: "Derived", label: "Downswing duration") == nil)
        #expect(vm.row(in: "Derived", label: "Total swing duration") == nil)
    }

    @Test func derivedSectionOmittedEntirelyWhenNoComputableValues() {
        let shot = makeShot { _ in }  // nothing populated
        let vm = ShotDetailViewModel(shot: shot)
        #expect(vm.section(titled: "Derived") == nil)
    }

    // MARK: - Ordering + edge cases

    @Test func sectionsAreOrderedIdentityBallClubSwingDerived() {
        let shot = makeShot {
            $0.shotId = 1
            $0.ballMetrics = R10BallMetrics(ballSpeed: 60)
            $0.clubMetrics = R10ClubMetrics(clubHeadSpeed: 43)
            $0.swingMetrics = R10SwingMetrics(
                backSwingStartTime: 1000,
                downSwingStartTime: 1750,
                impactTime: 2000
            )
        }
        let vm = ShotDetailViewModel(shot: shot)
        #expect(vm.sections.map(\.title) == ["Identity", "Ball", "Club", "Swing timing", "Derived"])
    }

    @Test func nilSpinCalcTypeDoesNotCrashRowBuilder() {
        let shot = makeShot {
            $0.ballMetrics = R10BallMetrics(ballSpeed: 60.0, spinCalcType: nil, golfBallType: nil)
        }
        let vm = ShotDetailViewModel(shot: shot)
        // The two enum rows should be absent; ball speed should still be there.
        let labels = vm.section(titled: "Ball")?.rows.map(\.label) ?? []
        #expect(labels.contains("Ball speed"))
        #expect(!labels.contains("Spin calc type"))
        #expect(!labels.contains("Golf ball type"))
    }

    // MARK: - Test helpers

    private func makeShot(
        timestamp: Date = Date(timeIntervalSince1970: 1767225600),
        _ mutate: (inout R10Metrics) -> Void
    ) -> R10ShotEvent {
        var metrics = R10Metrics()
        mutate(&metrics)
        return R10ShotEvent(metrics: metrics, wallClockImpactAt: timestamp)
    }
}

// MARK: - Test-only convenience accessors on the view-model

extension ShotDetailViewModel {
    func section(titled title: String) -> ShotDetailViewModel.Section? {
        sections.first { $0.title == title }
    }

    func row(in sectionTitle: String, label: String) -> ShotDetailViewModel.Row? {
        section(titled: sectionTitle)?.rows.first { $0.label == label }
    }

    func identityRow(label: String) -> ShotDetailViewModel.Row? {
        row(in: "Identity", label: label)
    }
}
