import Testing
import Foundation
@testable import R10Kit

/// RED — `TiltRecoveryPlanner` decides when to schedule a tilt-error
/// recovery probe. Pure state machine; no side effects, no time
/// dependencies. Mirrors `SwingRejectionDetector`'s shape.
///
/// Bug being fixed: when the R10 detects platform tilt during use
/// (user picks up + moves the device), firmware emits `state = .error`
/// and `error.code = .platformTilted`, the LED turns red, and the
/// device sits in error indefinitely because nothing kicks it. The
/// planner detects this and tells the actor to schedule a `WakeUp +
/// Tilt` recovery probe on a settle delay.
struct TiltRecoveryPlannerTests {

    @Test func freshPlannerWithNonErrorStateIsNoOp() {
        var p = TiltRecoveryPlanner()
        #expect(p.observed(state: .waiting) == .noOp)
        #expect(p.observed(state: .recording) == .noOp)
        #expect(p.observed(state: .processing) == .noOp)
        #expect(p.recoveryPending == false)
    }

    @Test func errorStateSchedulesRecovery() {
        var p = TiltRecoveryPlanner()
        #expect(p.observed(state: .error) == .scheduleRecovery)
        #expect(p.recoveryPending == true)
        #expect(p.inErrorState == true)
    }

    @Test func repeatedErrorStateDoesNotDoubleSchedule() {
        var p = TiltRecoveryPlanner()
        _ = p.observed(state: .error)
        // A second .error alert (firmware re-asserts) must not enqueue
        // a parallel probe — the in-flight probe handles it.
        #expect(p.observed(state: .error) == .noOp)
        #expect(p.recoveryPending == true)
    }

    @Test func nonErrorStateAfterErrorReturnsCancelScheduled() {
        var p = TiltRecoveryPlanner()
        _ = p.observed(state: .error)
        // Device recovered on its own (e.g., user put it back level
        // and the firmware cleared error before the probe fired).
        // The actor needs to cancel the pending probe Task.
        #expect(p.observed(state: .waiting) == .cancelScheduled)
        #expect(p.recoveryPending == false)
        #expect(p.inErrorState == false)
    }

    @Test func nonErrorStateWhenIdleIsNoOp() {
        var p = TiltRecoveryPlanner()
        // No prior error — nothing to cancel. Returning .cancelScheduled
        // here would be a spurious actor wake-up.
        #expect(p.observed(state: .waiting) == .noOp)
    }

    @Test func platformTiltedErrorCodeSchedulesRecovery() {
        var p = TiltRecoveryPlanner()
        // Some firmware emits the platformTilted error in the same
        // alert that carries state = .error; others may emit it on
        // the err pipe alone. Either path must trigger recovery.
        #expect(p.observed(error: .platformTilted) == .scheduleRecovery)
        #expect(p.recoveryPending == true)
        #expect(p.inErrorState == true)
    }

    @Test func nonPlatformTiltedErrorsAreNoOp() {
        var p = TiltRecoveryPlanner()
        // Overheating + radar saturation aren't recoverable by a
        // wake-up probe (overheating: device must cool; saturation:
        // radar conditions). Don't try.
        #expect(p.observed(error: .overheating) == .noOp)
        #expect(p.observed(error: .radarSaturation) == .noOp)
        #expect(p.observed(error: .unknown) == .noOp)
        #expect(p.recoveryPending == false)
    }

    @Test func errorStateAndPlatformTiltedInSameAlertOnlyTriggersOnce() {
        // handleAlert observes BOTH state and error from the same
        // notification. Planner must dedup so only the first schedules.
        var p = TiltRecoveryPlanner()
        #expect(p.observed(state: .error) == .scheduleRecovery)
        #expect(p.observed(error: .platformTilted) == .noOp)
    }

    @Test func recoveryProbeCompletedWhileStillInErrorReschedulesProbe() {
        var p = TiltRecoveryPlanner()
        _ = p.observed(state: .error)
        // The probe ran but the device is still in .error (next state
        // alert hasn't transitioned out yet). Caller schedules a retry.
        #expect(p.recoveryProbeCompleted() == .scheduleRecovery)
        #expect(p.recoveryPending == true)
    }

    @Test func recoveryProbeCompletedAfterStateClearedIsNoOp() {
        var p = TiltRecoveryPlanner()
        _ = p.observed(state: .error)
        _ = p.observed(state: .waiting)  // cleared
        #expect(p.recoveryProbeCompleted() == .noOp)
        #expect(p.recoveryPending == false)
    }

    @Test func errorThenWaitingThenErrorAgainSchedulesFreshRecovery() {
        // Full cycle. User picks up R10 → moves it → puts it down,
        // R10 recovers → user picks it up again later. Each error
        // entry needs a fresh probe.
        var p = TiltRecoveryPlanner()
        #expect(p.observed(state: .error) == .scheduleRecovery)
        #expect(p.observed(state: .waiting) == .cancelScheduled)
        #expect(p.observed(state: .error) == .scheduleRecovery)
    }

    @Test func plannerEquatableConformsToValueSemantics() {
        // Two planners observing identical sequences are equal —
        // helps with snapshot-style assertions if the actor wiring
        // ever needs to compare state.
        var a = TiltRecoveryPlanner()
        var b = TiltRecoveryPlanner()
        _ = a.observed(state: .error)
        _ = b.observed(state: .error)
        #expect(a == b)
    }
}
