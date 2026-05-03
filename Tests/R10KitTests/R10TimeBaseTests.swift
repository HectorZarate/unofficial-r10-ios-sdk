import Testing
import Foundation
@testable import R10Kit

/// Phase A — RED then GREEN.
///
/// Per ARCHITECTURE_REVIEW L9-2 / X4: cross-domain timestamp
/// conversions go through dedicated utilities. R10's
/// `swing_metrics.impact_time` is uint32 ms-since-R10-boot — pure
/// device-relative. R10TimeBase establishes the wall-clock boot
/// epoch from the first observed shot and converts subsequent
/// shots deterministically.
struct R10TimeBaseTests {

    @Test func establishesBootEpochFromFirstShot() {
        let firstImpact: UInt32 = 5_539_854   // R10's reported impact_time
        let arrivedAt = Date(timeIntervalSince1970: 1_714_656_000)  // arbitrary wall clock

        let base = R10TimeBase.establish(firstImpactMs: firstImpact, arrivedAt: arrivedAt)

        // boot epoch = arrivedAt - radarLatency - (firstImpact / 1000)
        let radarLatency: TimeInterval = 2.0
        let expectedBoot = arrivedAt.addingTimeInterval(-radarLatency - Double(firstImpact) / 1000.0)
        #expect(abs(base.bootEpoch.timeIntervalSince(expectedBoot)) < 0.001)
    }

    @Test func convertsR10MillisToWallClockDeterministically() {
        let arrivedAt = Date(timeIntervalSince1970: 1_714_656_000)
        let base = R10TimeBase.establish(firstImpactMs: 1_000_000, arrivedAt: arrivedAt)

        // The first shot's impact wall-clock = arrivedAt - radarLatency.
        let firstShotWallClock = base.wallClock(forR10Ms: 1_000_000)
        #expect(abs(firstShotWallClock.timeIntervalSince(arrivedAt) - (-2.0)) < 0.001)

        // A subsequent shot 1 second later in R10 time → 1 second later
        // in wall clock.
        let secondShotWallClock = base.wallClock(forR10Ms: 1_001_000)
        #expect(abs(secondShotWallClock.timeIntervalSince(firstShotWallClock) - 1.0) < 0.001)
    }

    @Test func customRadarLatencyOverride() {
        let arrivedAt = Date(timeIntervalSince1970: 1_714_656_000)
        let base = R10TimeBase.establish(firstImpactMs: 0, arrivedAt: arrivedAt, radarLatency: 0.5)

        // Boot epoch = arrivedAt - 0.5 - 0 = arrivedAt - 0.5.
        // wallClock(forR10Ms: 0) = bootEpoch + 0 = arrivedAt - 0.5.
        let wc = base.wallClock(forR10Ms: 0)
        #expect(abs(wc.timeIntervalSince(arrivedAt) - (-0.5)) < 0.001)
    }

    @Test func multipleConversionsUseSameBootEpoch() {
        // Critical: drift across many calls must be ZERO. The base is
        // established once and never mutated.
        let arrivedAt = Date(timeIntervalSince1970: 1_714_656_000)
        let base = R10TimeBase.establish(firstImpactMs: 100_000, arrivedAt: arrivedAt)

        let t1 = base.wallClock(forR10Ms: 100_000)
        let t2 = base.wallClock(forR10Ms: 100_500)
        let t3 = base.wallClock(forR10Ms: 100_500)

        #expect(t2.timeIntervalSince(t1) == 0.5)
        #expect(t3 == t2)  // same input → same output
    }
}
