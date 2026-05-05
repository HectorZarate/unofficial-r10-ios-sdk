import Foundation
import os

public enum R10DeviceError: Error, Sendable {
    case requestInFlight
    case timeout
    case malformedResponse
    case notReady
}

/// Speed conversion: R10 reports club_head_speed in m/s.
/// 1 m/s = 2.2369362920544 mph.
public let mpsToMph: Double = 2.2369362920544

/// One de-duplicated shot from the R10, with the wall-clock impact
/// time computed via `R10TimeBase`. Emitted by `R10Device.shotEvents`.
public struct R10ShotEvent: Sendable {
    /// All parsed metric fields the device reported for this shot.
    public let metrics: R10Metrics
    /// UTC wall-clock instant of impact, derived from the device's
    /// internal millisecond timestamp via the time-base established
    /// at the first shot of this session.
    public let wallClockImpactAt: Date

    public init(metrics: R10Metrics, wallClockImpactAt: Date) {
        self.metrics = metrics
        self.wallClockImpactAt = wallClockImpactAt
    }
}

/// Higher-level R10 protocol actor. Wraps the BLE transport
/// (`R10Connection`) with the proto-level handshake, request /
/// response correlation, and the post-shot metric stream.
///
/// Typical use: see `R10Connection`'s docstring for the full
/// example.
public actor R10Device {
    private let connection: R10Connection

    private var counter: UInt32 = 0
    private var processedShotIds = Set<UInt32>()
    private var inFlightProto: CheckedContinuation<R10WrapperProto, Error>?
    private var inFlightCounter: UInt32 = 0
    private var consumerTasks: [Task<Void, Never>] = []
    private var primed: Bool = false

    private let shotEventsContinuation: AsyncStream<R10ShotEvent>.Continuation
    /// Stream of completed shots — the primary data signal of the SDK.
    public nonisolated let shotEvents: AsyncStream<R10ShotEvent>
    private let errorsContinuation: AsyncStream<R10ErrorInfo>.Continuation
    /// Stream of device-side error notifications (overheating,
    /// radar saturation, platform tilt, ...).
    public nonisolated let errors: AsyncStream<R10ErrorInfo>
    private let tiltContinuation: AsyncStream<R10CalibrationStatusType>.Continuation
    /// Stream of tilt-calibration status changes.
    public nonisolated let tiltCalibrationUpdates: AsyncStream<R10CalibrationStatusType>
    private let rejectedSwingsContinuation: AsyncStream<Date>.Continuation
    /// Fires when the R10 saw motion that didn't classify as a
    /// valid shot (state-cycle entered RECORDING but no metrics
    /// followed). Useful for "saw your swing — try faster" UX.
    public nonisolated let rejectedSwings: AsyncStream<Date>

    /// Established at the first observed shot of each session. Per
    /// R10TimeBase semantics — drift across the session is zero.
    /// Reset to nil on .disconnected so re-priming starts fresh.
    private var timeBase: R10TimeBase?

    /// Pure state machine flagging swings that completed without
    /// producing metrics (the L8-4 "saw your swing — try faster"
    /// signal).
    private var rejectionDetector = SwingRejectionDetector()

    public init(connection: R10Connection) {
        self.connection = connection
        let shotsPair = AsyncStream.makeStream(of: R10ShotEvent.self, bufferingPolicy: .bufferingNewest(32))
        self.shotEvents = shotsPair.stream
        self.shotEventsContinuation = shotsPair.continuation
        let errorsPair = AsyncStream.makeStream(of: R10ErrorInfo.self, bufferingPolicy: .bufferingNewest(8))
        self.errors = errorsPair.stream
        self.errorsContinuation = errorsPair.continuation
        let tiltPair = AsyncStream.makeStream(of: R10CalibrationStatusType.self, bufferingPolicy: .bufferingNewest(4))
        self.tiltCalibrationUpdates = tiltPair.stream
        self.tiltContinuation = tiltPair.continuation
        let rejectedPair = AsyncStream.makeStream(of: Date.self, bufferingPolicy: .bufferingNewest(4))
        self.rejectedSwings = rejectedPair.stream
        self.rejectedSwingsContinuation = rejectedPair.continuation
    }

    /// Begin consuming the connection's inbound stream. Phase
    /// changes are pushed in via `notifyPhaseChange(_:)` from the
    /// caller — we don't subscribe to `connection.phases` directly
    /// because `AsyncStream` is single-consumer and the caller is
    /// expected to own that subscription.
    public func start() {
        if !consumerTasks.isEmpty { return }

        let inboundTask = Task { [weak self] in
            guard let self else { return }
            for await payload in self.connection.inboundPayloads {
                await self.handleInbound(payload)
            }
        }
        consumerTasks = [inboundTask]
    }

    /// External entry point for phase changes. Call this when
    /// you observe a transition on `connection.phases` (the SDK
    /// requires the caller to own that subscription so it stays
    /// single-consumer).
    public func notifyPhaseChange(_ phase: R10Phase) async {
        await handlePhase(phase)
    }

    public func stop() {
        for t in consumerTasks { t.cancel() }
        consumerTasks.removeAll()
        cancelInFlight(with: R10DeviceError.notReady)
        primed = false
        processedShotIds.removeAll()
        counter = 0
    }

    // MARK: - Phase handling

    private func handlePhase(_ phase: R10Phase) async {
        switch phase {
        case .ready:
            guard !primed else { return }
            primed = true
            await runPrimeSequence()
        case .disconnected, .idle, .bluetoothOff, .bluetoothUnauthorized, .bluetoothUnsupported:
            cancelInFlight(with: R10DeviceError.notReady)
            primed = false
            counter = 0
            processedShotIds.removeAll()
            timeBase = nil  // re-establish on next session's first shot
        case .scanning, .connecting, .handshaking:
            break
        }
    }

    private func runPrimeSequence() async {
        do {
            R10Log.protocolLog.info("priming: WakeUp")
            _ = try await sendProtoRequest(R10Request.wakeUp())
            R10Log.protocolLog.info("priming: AlertSupport (capability fingerprint)")
            let supportResp = try await sendProtoRequest(R10Request.alertSupportQuery())
            if let support = supportResp.event?.supportResponse {
                let alerts = support.supportedAlerts.map { "\($0)" }.joined(separator: ", ")
                R10Log.protocolLog.info("firmware reports supported alerts: [\(alerts, privacy: .public)] version=\(support.versionNumber.map { "\($0)" } ?? "nil", privacy: .public)")
            } else {
                R10Log.protocolLog.notice("AlertSupport response had no support_response payload")
            }
            R10Log.protocolLog.info("priming: Status")
            _ = try await sendProtoRequest(R10Request.status())
            R10Log.protocolLog.info("priming: Tilt")
            _ = try await sendProtoRequest(R10Request.tilt())
            R10Log.protocolLog.info("priming: ShotConfig (default indoor, tee_range=6ft)")
            let configResp = try await sendProtoRequest(R10Request.shotConfig())
            if let success = configResp.service?.shotConfigResponse?.success {
                R10Log.protocolLog.info("ShotConfig accepted=\(success)")
            }
            R10Log.protocolLog.info("priming: Subscribe(activityStart, activityStop, launchMonitor)")
            _ = try await sendProtoRequest(R10Request.subscribe([.activityStart, .activityStop, .launchMonitor]))
            R10Log.protocolLog.info("priming complete — listening for shots")
        } catch {
            R10Log.protocolLog.error("priming failed: \(String(describing: error), privacy: .public)")
            // If priming fails (timeout, etc.), the connection layer will
            // tear down on its own and we'll retry on the next .ready.
            primed = false
        }
    }

    // MARK: - Outbound

    func sendProtoRequest(_ protoBytes: Data) async throws -> R10WrapperProto {
        if inFlightProto != nil { throw R10DeviceError.requestInFlight }
        let myCounter = counter
        counter &+= 1
        let payload = Framing.protoRequestPayload(counter: myCounter, protoBytes: protoBytes)

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.timeOutIfStillInFlight(counter: myCounter)
        }

        return try await withCheckedThrowingContinuation { cont in
            inFlightProto = cont
            inFlightCounter = myCounter
            Task { [connection] in
                await connection.send(payload: payload)
            }
            // Timeout task will cancel itself if response arrives first
            Task { [weak self] in
                _ = await timeoutTask.value
                _ = self  // keep reference until timeout fires or self goes away
            }
        }
    }

    private func timeOutIfStillInFlight(counter: UInt32) {
        guard let cont = inFlightProto, inFlightCounter == counter else { return }
        R10Log.protocolLog.error("proto request #\(counter) timed out")
        inFlightProto = nil
        cont.resume(throwing: R10DeviceError.timeout)
    }

    private func cancelInFlight(with error: Error) {
        if let cont = inFlightProto {
            inFlightProto = nil
            cont.resume(throwing: error)
        }
    }

    // MARK: - Inbound

    private func handleInbound(_ payload: Data) async {
        guard payload.count >= 16 else { return }
        let opcode: [UInt8] = [payload[payload.startIndex], payload[payload.startIndex + 1]]
        // Proto bytes start at offset 16 inside the payload (post-decodeOuter):
        // [opcode 2][counter 4][0x00 0x00][len 4][len 4][proto…]
        let protoStart = payload.startIndex + 16
        guard protoStart <= payload.endIndex else { return }
        let protoBytes = payload.subdata(in: protoStart..<payload.endIndex)

        let parsed = try? R10WrapperProto.parse(protoBytes)

        switch opcode {
        case R10Opcode.protoResponse:
            // B413 — response to one of our outgoing requests
            if let cont = inFlightProto, let parsed {
                inFlightProto = nil
                cont.resume(returning: parsed)
            }
        case R10Opcode.protoRequest:
            // B313 — server-initiated message (alert notification)
            R10Log.protocolLog.debug("B313 raw proto bytes (\(protoBytes.count)): \(protoBytes.map { String(format: "%02X", $0) }.joined(), privacy: .public)")
            if let parsed {
                handleAlert(parsed)
            }
        default:
            break
        }
    }

    private func handleAlert(_ wrapper: R10WrapperProto) {
        guard let notification = wrapper.event?.notification else { return }

        let typeStr = notification.type.map { "\($0)" } ?? "nil"
        if let details = notification.details {
            R10Log.protocolLog.debug("alert type=\(typeStr, privacy: .public) state=\(String(describing: details.state), privacy: .public) metrics=\(details.metrics != nil ? "yes" : "no", privacy: .public) err=\(details.error != nil ? "yes" : "no", privacy: .public) tilt=\(String(describing: details.calibrationStatus), privacy: .public)")
        } else {
            R10Log.protocolLog.debug("alert type=\(typeStr, privacy: .public) (no details)")
        }

        guard let details = notification.details else { return }

        // Rejection detection runs on every state transition. When it
        // returns true, the cycle just completed without metrics — fire
        // the UI hint stream.
        if let state = details.state {
            if rejectionDetector.observe(.state(state)) {
                R10Log.protocolLog.info("swing rejected — no metrics for completed cycle")
                rejectedSwingsContinuation.yield(Date())
            }
        }

        if let state = details.state, state == .standby {
            R10Log.protocolLog.notice("device in STANDBY — sending WakeUp")
            Task { [weak self] in
                _ = try? await self?.sendProtoRequest(R10Request.wakeUp())
            }
        }

        if let metrics = details.metrics, let shotId = metrics.shotId {
            if processedShotIds.contains(shotId) {
                R10Log.protocolLog.notice("duplicate shot id \(shotId), ignoring")
                return
            }
            processedShotIds.insert(shotId)
            // Tell the rejection detector this cycle DID produce metrics
            // before the cycle terminus arrives — prevents a false flag.
            _ = rejectionDetector.observe(.metricsArrived)
            let metricTypeStr = metrics.shotType.map { "\($0)" } ?? "nil"
            R10Log.protocolLog.info("METRICS shot id=\(shotId) type=\(metricTypeStr, privacy: .public)")
            if let cm = metrics.clubMetrics {
                R10Log.protocolLog.debug("  club: speed=\(cm.clubHeadSpeed.map { String(format: "%.2f m/s", $0) } ?? "nil", privacy: .public) face=\(cm.clubAngleFace.map { "\($0)" } ?? "nil", privacy: .public) path=\(cm.clubAnglePath.map { "\($0)" } ?? "nil", privacy: .public) attack=\(cm.attackAngle.map { "\($0)" } ?? "nil", privacy: .public)")
            } else {
                R10Log.protocolLog.debug("  club: <no club_metrics in payload>")
            }
            if let sm = metrics.swingMetrics {
                R10Log.protocolLog.debug("  swing: backStart=\(sm.backSwingStartTime.map { "\($0)" } ?? "nil", privacy: .public) downStart=\(sm.downSwingStartTime.map { "\($0)" } ?? "nil", privacy: .public) impact=\(sm.impactTime.map { "\($0)" } ?? "nil", privacy: .public)")
            } else {
                R10Log.protocolLog.debug("  swing: <no swing_metrics in payload>")
            }
            // Compute wall-clock impact time. Establish R10TimeBase on
            // the first shot of the session if not already set; thereafter
            // every shot uses the same boot epoch so inter-event timing
            // is consistent.
            let arrivedAt = Date()
            let impactMs = metrics.swingMetrics?.impactTime
            let wallClock: Date
            if let impactMs {
                // Establish the timebase on first observed swing,
                // then bind to a non-optional local for the wall-
                // clock conversion. Avoids the force-unwrap that
                // Swift can't statically prove is safe even though
                // the surrounding logic guarantees it.
                let base = timeBase ?? R10TimeBase.establish(
                    firstImpactMs: impactMs, arrivedAt: arrivedAt)
                if timeBase == nil { timeBase = base }
                wallClock = base.wallClock(forR10Ms: impactMs)
            } else {
                // No swing timing in this metrics — fall back to wall-clock
                // arrival minus radar latency.
                wallClock = arrivedAt.addingTimeInterval(-2.0)
            }

            if let mps = metrics.clubMetrics?.clubHeadSpeed {
                let mph = Double(mps) * mpsToMph
                R10Log.protocolLog.info("→ emitting shot event \(String(format: "%.1f", mph), privacy: .public) mph at \(wallClock, privacy: .public)")
            } else {
                R10Log.protocolLog.info("→ emitting shot event (no club speed) at \(wallClock, privacy: .public)")
            }
            shotEventsContinuation.yield(R10ShotEvent(metrics: metrics, wallClockImpactAt: wallClock))
        }

        if let error = details.error {
            errorsContinuation.yield(error)
        }

        if let tilt = details.calibrationStatus {
            tiltContinuation.yield(tilt)
        }
    }
}
