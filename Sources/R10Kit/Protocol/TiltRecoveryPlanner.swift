import Foundation

/// Pure state machine that decides when to schedule a tilt-error
/// recovery probe. Watches `R10StateType` + `R10ErrorCode` events
/// and emits a single decision per observation.
///
/// **Why this exists.** The R10 firmware enters `.error` state
/// (and emits `R10ErrorCode.platformTilted`) when the device's
/// tilt sensor trips during active use — typically because the
/// user picked it up to move it. The status LED goes red. The
/// device stays in error until something prods it. There's an
/// existing recovery path for `.standby` (`WakeUp` is sent
/// automatically) but no equivalent for `.error`. Without one, a
/// user has to restart the app to get shots flowing again — the
/// restart re-runs the priming sequence, which kicks the
/// firmware back to `.waiting`.
///
/// The planner watches incoming alerts, tells `R10Device` to
/// schedule a settle-delay + `WakeUp + Tilt` probe on tilt entry,
/// and to retry until the device leaves `.error`. No side effects,
/// no time dependencies — schedulability decisions only. The
/// actor owns the actual `Task`.
struct TiltRecoveryPlanner: Equatable {
    enum Decision: Equatable {
        case noOp
        /// Schedule a recovery probe (or a retry of the in-flight
        /// probe). The actor handles the delay + send.
        case scheduleRecovery
        /// Caller had a probe scheduled but the device recovered
        /// on its own — cancel the in-flight Task to avoid a
        /// spurious wake-up after the user has resumed swinging.
        case cancelScheduled
    }

    /// True while the most recent state observation was `.error`,
    /// or while `platformTilted` has been observed without a
    /// subsequent non-error state.
    private(set) var inErrorState: Bool = false

    /// True while a probe is in flight (scheduled or running) and
    /// hasn't yet been confirmed cancelled or completed.
    private(set) var recoveryPending: Bool = false

    mutating func observed(state: R10StateType) -> Decision {
        if state == .error {
            inErrorState = true
            if recoveryPending { return .noOp }
            recoveryPending = true
            return .scheduleRecovery
        } else {
            // Any non-error state.
            let wasPending = recoveryPending
            inErrorState = false
            recoveryPending = false
            return wasPending ? .cancelScheduled : .noOp
        }
    }

    mutating func observed(error code: R10ErrorCode) -> Decision {
        // Only platformTilted is in scope. Overheating + radar
        // saturation + unknown aren't user-fixable in this loop;
        // probing them just spams the device with WakeUp.
        guard code == .platformTilted else { return .noOp }
        inErrorState = true
        if recoveryPending { return .noOp }
        recoveryPending = true
        return .scheduleRecovery
    }

    /// Caller's recovery probe (`WakeUp + Tilt`) has finished. If
    /// we're still observing error state, schedule another retry;
    /// otherwise clear the pending flag.
    mutating func recoveryProbeCompleted() -> Decision {
        if inErrorState {
            // Stay pending — caller will schedule another probe.
            return .scheduleRecovery
        }
        recoveryPending = false
        return .noOp
    }
}
