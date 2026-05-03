import Testing
import Foundation
@testable import R10Kit

/// Phase A.5 — RED then GREEN.
///
/// SwingRejectionDetector watches the R10's state-cycle telemetry and
/// flags swings that completed without producing metrics. Pure
/// state-machine; no side effects, no time dependencies.
struct SwingRejectionDetectorTests {

    @Test func recordingThenWaitingWithoutMetricsIsRejected() {
        var d = SwingRejectionDetector()
        #expect(d.observe(.state(.recording)) == false)
        #expect(d.observe(.state(.processing)) == false)
        #expect(d.observe(.state(.interferenceTest)) == false)
        // The transition into WAITING completes the cycle. No metrics
        // arrived → rejection.
        #expect(d.observe(.state(.waiting)) == true)
    }

    @Test func recordingThenMetricsThenWaitingIsNotRejected() {
        var d = SwingRejectionDetector()
        _ = d.observe(.state(.recording))
        _ = d.observe(.state(.processing))
        #expect(d.observe(.metricsArrived) == false)
        #expect(d.observe(.state(.waiting)) == false)
    }

    @Test func waitingWithoutPriorRecordingIsNotRejected() {
        var d = SwingRejectionDetector()
        // Idle state cycle, never entered RECORDING — must not flag.
        #expect(d.observe(.state(.standby)) == false)
        #expect(d.observe(.state(.waiting)) == false)
    }

    @Test func detectorResetsBetweenCycles() {
        var d = SwingRejectionDetector()
        // First cycle: rejected
        _ = d.observe(.state(.recording))
        #expect(d.observe(.state(.waiting)) == true)
        // Next cycle: succeeded
        _ = d.observe(.state(.recording))
        _ = d.observe(.metricsArrived)
        #expect(d.observe(.state(.waiting)) == false)
    }

    @Test func multipleRecordingsBeforeMetricsTreatedAsRejection() {
        var d = SwingRejectionDetector()
        // Edge: device cycles RECORDING again without finishing the
        // first. Treat as a fresh cycle (the prior tracking resets on
        // each RECORDING entry, conservatively).
        _ = d.observe(.state(.recording))
        _ = d.observe(.state(.recording))     // re-enters; counts as new cycle
        #expect(d.observe(.state(.waiting)) == true)
    }

    @Test func standbyAfterRecordingTreatedAsRejection() {
        // Some cycles transition through STANDBY (device went to sleep
        // mid-cycle). Without metrics, that's a rejection too.
        var d = SwingRejectionDetector()
        _ = d.observe(.state(.recording))
        _ = d.observe(.state(.processing))
        #expect(d.observe(.state(.standby)) == true)
    }
}
