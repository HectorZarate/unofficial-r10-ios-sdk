import Foundation
import os

/// Shared `os.Logger` instances for the SDK. Replaces the previous
/// `print(...)`-based logging which, on Debug builds with a noisy
/// BLE environment, emitted enough volume to trigger Apple's
/// "QUARANTINED DUE TO HIGH LOGGING VOLUME" rate limiter.
///
/// `os.Logger`:
/// - Auto-suppresses `.debug` messages in Release builds.
/// - Is rate-limited by the system (no quarantine).
/// - Streams into Console.app where the user can filter by
///   subsystem/category at runtime.
///
/// **Levels used in this SDK**
/// - `.error`   — failures the consumer should know about
/// - `.notice`  — anomalies that aren't fatal (duplicate shot,
///                STANDBY device, no support_response)
/// - `.info`    — one-shot state transitions (handshake done,
///                priming complete, shot emitted)
/// - `.debug`   — per-frame / per-byte / per-alert traces
///
/// Filter in Console.app:
///   subsystem:com.r10kit
///   subsystem:com.r10kit AND category:transport
enum R10Log {
    static let subsystem = "com.r10kit"
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let protocolLog = Logger(subsystem: subsystem, category: "protocol")
}
