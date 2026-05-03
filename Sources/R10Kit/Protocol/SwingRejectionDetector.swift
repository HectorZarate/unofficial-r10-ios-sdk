import Foundation

/// Pure state machine that watches R10 state-cycle telemetry and flags
/// swings that completed without producing metrics. The R10 emits a
/// state cycle (RECORDING → PROCESSING → INTERFERENCE_TEST → WAITING)
/// for every detected motion; a successful swing ALSO emits a metrics
/// alert during the cycle. No metrics by the time we exit the cycle =
/// rejected swing (radar didn't see a ball or didn't classify the
/// motion as a valid shot).
///
/// This is the signal that drives the L8-4 "R10 saw your swing — try
/// faster" UX hint on TeeView.
struct SwingRejectionDetector {
    enum Input {
        case state(R10StateType)
        case metricsArrived
    }

    private var sawRecordingThisCycle = false
    private var sawMetricsThisCycle = false

    /// Feed in a state transition or a metrics-arrival. Returns `true`
    /// at the moment a state cycle completes without metrics — i.e. the
    /// instant a rejection becomes observable. Returns `false`
    /// otherwise.
    mutating func observe(_ input: Input) -> Bool {
        switch input {
        case .state(.recording):
            // Entering RECORDING starts a new cycle. Reset any prior
            // state — handles the edge case where a previous cycle
            // didn't terminate cleanly via WAITING.
            sawRecordingThisCycle = true
            sawMetricsThisCycle = false
            return false
        case .state(.waiting), .state(.standby):
            // Cycle terminus. Flag rejection if we saw a recording
            // start but never received metrics.
            let rejected = sawRecordingThisCycle && !sawMetricsThisCycle
            sawRecordingThisCycle = false
            sawMetricsThisCycle = false
            return rejected
        case .metricsArrived:
            sawMetricsThisCycle = true
            return false
        case .state:
            // PROCESSING / INTERFERENCE_TEST / ERROR — middle of cycle,
            // no observation yet.
            return false
        }
    }
}
