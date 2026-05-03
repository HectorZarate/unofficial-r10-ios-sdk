import Foundation

/// Converts the R10's device-relative `swing_metrics.impact_time`
/// (uint32 milliseconds since R10 boot) into wall-clock `Date`s.
///
/// Established once at the first observed shot of a session via
/// `establish(firstImpactMs:arrivedAt:radarLatency:)`. Subsequent
/// conversions reference the same boot epoch — drift across the
/// session is zero because we never recompute.
///
/// Cross-domain time conversions go through this utility — don't
/// translate timestamps inline in business code.
public struct R10TimeBase: Sendable {
    /// Wall-clock instant of R10 boot, inferred from the first
    /// observed shot's impact_time and arrival time.
    public let bootEpoch: Date

    public init(bootEpoch: Date) {
        self.bootEpoch = bootEpoch
    }

    /// Build a time base from the first observed shot. The R10's
    /// reported `impact_time` references that shot's impact,
    /// which we observed at wall-clock `arrivedAt`. Subtract the
    /// radar latency (R10 emits metrics ~2 s after impact) and
    /// back out the impact instant; further subtract the
    /// impact_time to land on boot epoch.
    ///
    /// `radarLatency` defaults to 2.0 s, calibrated empirically.
    /// Once established, the base is never recomputed for the
    /// rest of the session.
    public static func establish(firstImpactMs: UInt32,
                                 arrivedAt: Date,
                                 radarLatency: TimeInterval = 2.0) -> R10TimeBase {
        let impactInstant = arrivedAt.addingTimeInterval(-radarLatency)
        let bootEpoch = impactInstant.addingTimeInterval(-Double(firstImpactMs) / 1000.0)
        return R10TimeBase(bootEpoch: bootEpoch)
    }

    /// Convert an R10 ms-since-boot timestamp to wall clock.
    public func wallClock(forR10Ms r10Ms: UInt32) -> Date {
        bootEpoch.addingTimeInterval(Double(r10Ms) / 1000.0)
    }
}
