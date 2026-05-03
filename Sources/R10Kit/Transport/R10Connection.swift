import Foundation
import CoreBluetooth

/// High-level transport state of the R10 connection. The
/// `R10Connection` actor publishes these via the `phases` stream;
/// consumers project them into UI state (typically with hysteresis
/// between `ready` ↔ `stale` based on inbound traffic — see the
/// example app).
public enum R10Phase: Equatable, Sendable {
    /// Initial state before `start()` has been called.
    case idle
    /// User has not granted Bluetooth permission.
    case bluetoothUnauthorized
    /// Bluetooth is powered off in iOS Settings or Control Center.
    case bluetoothOff
    /// Hardware doesn't support Bluetooth (rare; iOS simulator).
    case bluetoothUnsupported
    /// Actively scanning for an R10 advertisement.
    case scanning
    /// Connecting to a discovered R10 peripheral.
    case connecting
    /// Connected; running the post-connection handshake (priming
    /// the BLE characteristics + sending the WakeUp + AlertSupport
    /// + SubscribeMetrics dance).
    case handshaking
    /// Fully primed; the device will emit shot events as you swing.
    case ready
    /// Was connected, has now disconnected (link drop or explicit
    /// `shutdown()` / `forgetDevice()`).
    case disconnected
}

/// GATT-derived identity strings from the R10's `0x180A` Device
/// Information service. All optional — older firmware may omit
/// some fields.
public struct R10DeviceInfo: Sendable, Equatable {
    public var model: String?
    public var firmware: String?
    public var serial: String?

    public init(model: String? = nil, firmware: String? = nil, serial: String? = nil) {
        self.model = model
        self.firmware = firmware
        self.serial = serial
    }
}

/// BLE transport actor for the Garmin Approach R10. Manages
/// scanning, connection, the post-connect handshake, and the
/// session-byte / COBS / CRC framing used by the device's
/// proprietary GATT service.
///
/// Typical use:
///
/// ```swift
/// let connection = R10Connection()
/// let device = R10Device(connection: connection)
///
/// Task {
///     for await event in await device.shotEvents {
///         print("Shot: \(event.metrics.clubMetrics?.clubHeadSpeed ?? 0)")
///     }
/// }
///
/// await device.start()
/// await connection.start()
/// ```
///
/// All callbacks are delivered on the actor's executor; bridge to
/// MainActor (e.g. via Task) when updating UI.
public actor R10Connection {
    static let deviceInterfaceServiceUUID = CBUUID(string: "6A4E2800-667B-11E3-949A-0800200C9A66")
    static let deviceInterfaceNotifierUUID = CBUUID(string: "6A4E2812-667B-11E3-949A-0800200C9A66")
    static let deviceInterfaceWriterUUID = CBUUID(string: "6A4E2822-667B-11E3-949A-0800200C9A66")
    static let deviceInfoServiceUUID = CBUUID(string: "180A")
    static let modelCharUUID = CBUUID(string: "2A24")
    static let firmwareCharUUID = CBUUID(string: "2A28")
    static let serialCharUUID = CBUUID(string: "2A25")
    static let batteryServiceUUID = CBUUID(string: "180F")
    static let batteryCharUUID = CBUUID(string: "2A19")

    static let storedUUIDKey = "R10.peripheralUUID"

    /// Whether a peripheral UUID has been stored from a prior pairing.
    /// Used by UI to decide whether to show a full-screen "Looking for R10"
    /// takeover (first run) or a quieter inline reconnect indicator.
    /// Whether a peripheral UUID has been stored from a prior
    /// pairing. Useful for UIs that show a "first-run" takeover
    /// vs. a quieter "reconnecting" indicator.
    public nonisolated static var hasStoredDevice: Bool {
        UserDefaults.standard.string(forKey: storedUUIDKey) != nil
    }

    private let adapter: Adapter
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writerChar: CBCharacteristic?
    private var notifierChar: CBCharacteristic?
    private var notifierSubscribed: Bool = false

    private var sessionByte: UInt8 = 0
    private var assembler = FrameAssembler()
    private var deviceInfoBuffer = R10DeviceInfo()
    private var reconnectTask: Task<Void, Never>?
    private var handshakeWatchdog: Task<Void, Never>?

    private(set) var phase: R10Phase = .idle
    private(set) var lastInboundAt: Date?

    private let phaseContinuation: AsyncStream<R10Phase>.Continuation
    /// The transport's high-level state stream. Subscribe to drive
    /// UI hysteresis (ready ↔ stale ↔ disconnected).
    public nonisolated let phases: AsyncStream<R10Phase>
    private let inboundContinuation: AsyncStream<Data>.Continuation
    /// Raw inbound payloads (after framing + COBS + CRC). The
    /// `R10Device` actor consumes this. Single-consumer — only one
    /// `for await` loop may iterate at a time.
    public nonisolated let inboundPayloads: AsyncStream<Data>
    private let batteryContinuation: AsyncStream<Int>.Continuation
    /// Battery percent (0-100) from the GATT Battery Service.
    public nonisolated let batteryUpdates: AsyncStream<Int>
    private let deviceInfoContinuation: AsyncStream<R10DeviceInfo>.Continuation
    /// Model / firmware / serial from the GATT Device Information
    /// Service.
    public nonisolated let deviceInfoUpdates: AsyncStream<R10DeviceInfo>
    /// Fires every time the transport layer receives a frame —
    /// handshake, proto response, alert, ack, anything. UIs use
    /// this as a heartbeat to distinguish "device silently dead"
    /// from "device streaming state but no completed shots yet."
    private let frameContinuation: AsyncStream<Date>.Continuation
    public nonisolated let frameTimestamps: AsyncStream<Date>

    public init() {
        let phasePair = AsyncStream.makeStream(of: R10Phase.self, bufferingPolicy: .bufferingNewest(8))
        self.phases = phasePair.stream
        self.phaseContinuation = phasePair.continuation
        let inboundPair = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(64))
        self.inboundPayloads = inboundPair.stream
        self.inboundContinuation = inboundPair.continuation
        let batteryPair = AsyncStream.makeStream(of: Int.self, bufferingPolicy: .bufferingNewest(8))
        self.batteryUpdates = batteryPair.stream
        self.batteryContinuation = batteryPair.continuation
        let infoPair = AsyncStream.makeStream(of: R10DeviceInfo.self, bufferingPolicy: .bufferingNewest(4))
        self.deviceInfoUpdates = infoPair.stream
        self.deviceInfoContinuation = infoPair.continuation
        let framePair = AsyncStream.makeStream(of: Date.self, bufferingPolicy: .bufferingNewest(8))
        self.frameTimestamps = framePair.stream
        self.frameContinuation = framePair.continuation
        self.adapter = Adapter()
        self.adapter.owner = self
    }

    /// Boots the central manager and begins connection attempts.
    /// Idempotent — safe to call on every scenePhase=.active
    /// transition or on app launch.
    public func start() {
        if central == nil {
            central = CBCentralManager(delegate: adapter, queue: .main, options: nil)
        } else if central?.state == .poweredOn, peripheral == nil {
            beginConnectionAttempt()
        }
    }

    /// Tears the connection down completely. Resets all session
    /// state so the next `start()` runs a clean handshake. Call
    /// from scenePhase != .active.
    public func shutdown() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil
        writerChar = nil
        sessionByte = 0
        assembler.reset()
        deviceInfoBuffer = R10DeviceInfo()
        update(phase: .idle)
    }

    /// User explicitly forgets the paired R10. Disconnects, clears
    /// the stored UUID, and drops to scanning the next time
    /// `start()` runs.
    public func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: Self.storedUUIDKey)
        shutdown()
    }

    /// Send a raw outer payload (e.g. an 8813 ack or a B313 proto request).
    /// Caller is responsible for opcode framing — this just wraps with
    /// length+CRC, COBS-encodes, and chunks for BLE writes.
    func send(payload: Data) {
        guard phase == .ready, let writer = writerChar, let p = peripheral else { return }
        let encoded = Framing.encodeOuter(payload)
        let chunks = Framing.chunk(encoded, header: sessionByte)
        for chunk in chunks {
            p.writeValue(chunk, for: writer, type: .withResponse)
        }
    }

    // MARK: - Internal handlers (called from Adapter)

    fileprivate func handleStateChange(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            beginConnectionAttempt()
        case .poweredOff:
            update(phase: .bluetoothOff)
            tearDownPeripheral()
        case .unauthorized:
            update(phase: .bluetoothUnauthorized)
        case .unsupported:
            update(phase: .bluetoothUnsupported)
        case .resetting, .unknown:
            update(phase: .disconnected)
        @unknown default:
            break
        }
    }

    fileprivate func handleDiscovered(_ p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        guard peripheral == nil, let central = central else { return }
        // The R10 doesn't advertise its proprietary service UUID, so we
        // scan broadly and filter on name. Garmin's advertised name is
        // typically "Approach R10 <serial>" but firmware variants exist —
        // accept anything containing "R10" or "Approach".
        let name = p.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? ""
        guard nameMatches(name) else {
            #if DEBUG
            print("[R10] skipping discovered peripheral name=\(name) rssi=\(rssi)")
            #endif
            return
        }
        #if DEBUG
        print("[R10] matched peripheral name=\(name) rssi=\(rssi) id=\(p.identifier)")
        #endif
        central.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.storedUUIDKey)
        peripheral = p
        p.delegate = adapter
        update(phase: .connecting)
        central.connect(p)
    }

    private func nameMatches(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("r10") || n.contains("approach")
    }

    fileprivate func handleConnected() {
        peripheral?.discoverServices([
            Self.deviceInterfaceServiceUUID,
            Self.deviceInfoServiceUUID,
            Self.batteryServiceUUID,
        ])
    }

    fileprivate func handleServicesDiscovered() {
        guard let p = peripheral else { return }
        for svc in p.services ?? [] {
            switch svc.uuid {
            case Self.deviceInterfaceServiceUUID:
                p.discoverCharacteristics([
                    Self.deviceInterfaceNotifierUUID,
                    Self.deviceInterfaceWriterUUID,
                ], for: svc)
            case Self.deviceInfoServiceUUID:
                p.discoverCharacteristics([
                    Self.modelCharUUID, Self.firmwareCharUUID, Self.serialCharUUID,
                ], for: svc)
            case Self.batteryServiceUUID:
                p.discoverCharacteristics([Self.batteryCharUUID], for: svc)
            default:
                break
            }
        }
    }

    fileprivate func handleCharacteristicsDiscovered(_ chars: [CBCharacteristic]) {
        guard let p = peripheral else { return }
        for c in chars {
            switch c.uuid {
            case Self.deviceInterfaceNotifierUUID:
                #if DEBUG
                print("[R10] subscribing to notifier (waiting for confirmation before handshake)")
                #endif
                notifierChar = c
                p.setNotifyValue(true, for: c)
            case Self.deviceInterfaceWriterUUID:
                #if DEBUG
                print("[R10] writer characteristic ready")
                #endif
                writerChar = c
                tryStartHandshake()
            case Self.batteryCharUUID:
                p.setNotifyValue(true, for: c)
                p.readValue(for: c)
            case Self.modelCharUUID, Self.firmwareCharUUID, Self.serialCharUUID:
                p.readValue(for: c)
            default:
                break
            }
        }
    }

    fileprivate func handleNotificationStateUpdate(uuid: CBUUID, isNotifying: Bool, error: Error?) {
        #if DEBUG
        print("[R10] notify state \(uuid) → isNotifying=\(isNotifying), err=\(error?.localizedDescription ?? "nil")")
        #endif
        if uuid == Self.deviceInterfaceNotifierUUID {
            notifierSubscribed = isNotifying && error == nil
            if notifierSubscribed {
                tryStartHandshake()
            }
        }
    }

    fileprivate func handleWriteCompletion(uuid: CBUUID, error: Error?) {
        #if DEBUG
        if let error {
            print("[R10] write to \(uuid) failed: \(error.localizedDescription)")
        }
        #endif
    }

    fileprivate func handleValueUpdate(uuid: CBUUID, value: Data) {
        switch uuid {
        case Self.deviceInterfaceNotifierUUID:
            handleNotification(value)
        case Self.batteryCharUUID:
            if let first = value.first {
                batteryContinuation.yield(Int(first))
            }
        case Self.modelCharUUID:
            deviceInfoBuffer.model = String(data: value, encoding: .ascii)
            deviceInfoContinuation.yield(deviceInfoBuffer)
        case Self.firmwareCharUUID:
            deviceInfoBuffer.firmware = String(data: value, encoding: .ascii)
            deviceInfoContinuation.yield(deviceInfoBuffer)
        case Self.serialCharUUID:
            deviceInfoBuffer.serial = String(data: value, encoding: .ascii)
            deviceInfoContinuation.yield(deviceInfoBuffer)
        default:
            break
        }
    }

    fileprivate func handleDisconnect() {
        tearDownPeripheral()
        update(phase: .disconnected)
        scheduleReconnect(after: .seconds(1))
    }

    fileprivate func handleConnectFailure() {
        tearDownPeripheral()
        update(phase: .disconnected)
        scheduleReconnect(after: .seconds(2))
    }

    // MARK: - Private

    private func beginConnectionAttempt() {
        guard let central = central, central.state == .poweredOn else { return }
        guard peripheral == nil else { return }
        if let stored = UserDefaults.standard.string(forKey: Self.storedUUIDKey),
           let uuid = UUID(uuidString: stored) {
            let cached = central.retrievePeripherals(withIdentifiers: [uuid])
            if let p = cached.first {
                #if DEBUG
                print("[R10] retrieved cached peripheral id=\(uuid)")
                #endif
                peripheral = p
                p.delegate = adapter
                update(phase: .connecting)
                central.connect(p)
                return
            } else {
                #if DEBUG
                print("[R10] stored UUID \(uuid) not retrievable; falling back to scan")
                #endif
            }
        }
        // Scan with no service filter — the R10 advertises only standard
        // services in its adv packet (battery / device info), not the
        // proprietary device interface service. We filter by name in
        // handleDiscovered.
        update(phase: .scanning)
        #if DEBUG
        print("[R10] starting broad scan for R10 / Approach name match")
        #endif
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    /// Start the handshake only when both the writer is known AND the
    /// notifier subscription has been confirmed by iOS. Otherwise the
    /// R10's response races a not-yet-active subscription and we hang.
    private func tryStartHandshake() {
        guard phase != .ready, phase != .handshaking else { return }
        guard let writer = writerChar, notifierSubscribed, let p = peripheral else {
            #if DEBUG
            print("[R10] tryStartHandshake gated: writer=\(writerChar != nil) subscribed=\(notifierSubscribed)")
            #endif
            return
        }
        update(phase: .handshaking)
        var chunk = Data()
        chunk.append(0)
        chunk.append(Framing.handshakeRequest)
        #if DEBUG
        print("[R10] sending handshake (\(chunk.count) bytes)")
        #endif
        p.writeValue(chunk, for: writer, type: .withResponse)
        startHandshakeWatchdog()
    }

    private func startHandshakeWatchdog() {
        handshakeWatchdog?.cancel()
        handshakeWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            await self.handshakeTimedOut()
        }
    }

    private func handshakeTimedOut() {
        guard phase == .handshaking else { return }
        #if DEBUG
        print("[R10] handshake watchdog fired — forcing disconnect to retry clean")
        #endif
        if let p = peripheral, let c = central {
            c.cancelPeripheralConnection(p)
        } else {
            tearDownPeripheral()
            update(phase: .disconnected)
            scheduleReconnect(after: .seconds(1))
        }
    }

    private func handleNotification(_ chunk: Data) {
        let outputs: [FrameAssembler.Output]
        do {
            outputs = try assembler.feed(chunk)
        } catch {
            #if DEBUG
            print("[R10] frame assembly error: \(error)")
            #endif
            return
        }
        for output in outputs {
            let now = Date()
            lastInboundAt = now
            frameContinuation.yield(now)
            switch output {
            case .handshake(let body):
                handleHandshakeChunk(body)
            case .payload(let payload):
                #if DEBUG
                let opcodeHex = payload.prefix(2).map { String(format: "%02X", $0) }.joined()
                print("[R10] inbound payload \(opcodeHex), \(payload.count) bytes")
                #endif
                let ack = Framing.ackPayload(for: payload)
                let encoded = Framing.encodeOuter(ack)
                let acks = Framing.chunk(encoded, header: sessionByte)
                if let writer = writerChar, let p = peripheral {
                    for c in acks { p.writeValue(c, for: writer, type: .withResponse) }
                }
                inboundContinuation.yield(payload)
            }
        }
    }

    private func handleHandshakeChunk(_ body: Data) {
        #if DEBUG
        print("[R10] handshake chunk in: \(body.map { String(format: "%02X", $0) }.joined())")
        #endif
        guard body.count >= 13,
              body.starts(with: Framing.handshakeResponsePrefix) else {
            #if DEBUG
            print("[R10] handshake chunk did not match expected prefix")
            #endif
            return
        }
        sessionByte = body[body.startIndex + 12]
        assembler.markHandshakeComplete()
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
        // Acknowledge the handshake with a single 0x00 byte (mholow line 211).
        if let writer = writerChar, let p = peripheral {
            p.writeValue(Data([0x00]), for: writer, type: .withResponse)
        }
        #if DEBUG
        print("[R10] handshake complete, sessionByte=\(String(format: "0x%02X", sessionByte))")
        #endif
        update(phase: .ready)
    }

    private func tearDownPeripheral() {
        peripheral = nil
        writerChar = nil
        notifierChar = nil
        notifierSubscribed = false
        sessionByte = 0
        assembler.reset()
        deviceInfoBuffer = R10DeviceInfo()
        handshakeWatchdog?.cancel()
        handshakeWatchdog = nil
    }

    private func scheduleReconnect(after delay: Duration) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.beginConnectionAttempt()
        }
    }

    private func update(phase: R10Phase) {
        guard self.phase != phase else { return }
        self.phase = phase
        phaseContinuation.yield(phase)
    }
}

private final class Adapter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var owner: R10Connection?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        if let owner { Task { await owner.handleStateChange(state) } }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        if let owner {
            Task { await owner.handleDiscovered(peripheral, advertisementData: advertisementData, rssi: RSSI) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if let owner { Task { await owner.handleConnected() } }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        if let owner { Task { await owner.handleConnectFailure() } }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if let owner { Task { await owner.handleDisconnect() } }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let owner { Task { await owner.handleServicesDiscovered() } }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let chars = service.characteristics ?? []
        if let owner { Task { await owner.handleCharacteristicsDiscovered(chars) } }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let value = characteristic.value else { return }
        let uuid = characteristic.uuid
        if let owner { Task { await owner.handleValueUpdate(uuid: uuid, value: value) } }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        let uuid = characteristic.uuid
        let notifying = characteristic.isNotifying
        if let owner {
            Task { await owner.handleNotificationStateUpdate(uuid: uuid, isNotifying: notifying, error: error) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        let uuid = characteristic.uuid
        if let owner { Task { await owner.handleWriteCompletion(uuid: uuid, error: error) } }
    }
}
