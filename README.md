# R10Kit — Unofficial Garmin Approach R10 iOS SDK

A native Swift SDK for connecting to the Garmin Approach R10 launch monitor
over Bluetooth Low Energy. Pure Swift, no Garmin Mobile app required.

> **Disclaimer.** This is an **unofficial**, community-built SDK. It is not
> affiliated with, endorsed by, or supported by Garmin Ltd. The protocol
> layer is reverse-engineered from publicly available work
> ([mholow/gsp-r10-adapter](https://github.com/mholow/gsp-r10-adapter)).
> Use at your own risk.

## What you get

- **Direct BLE connection** to the R10 — no GarminConnect, no PC tethering.
- **Full proto parsing** for every shot the device emits: club speed, ball
  speed, launch angle/direction, spin rate + axis + provenance, attack
  angle, club face/path, swing-timing milliseconds, shot type
  (practice / normal), tilt-at-impact.
- **No-ball practice swings** — the R10 emits practice-mode metrics on a
  fraction of swings without a ball; this SDK exposes them. (Garmin's
  app does not.)
- **Connection state stream** with auto-reconnect to the most recently
  paired R10.
- **AsyncStream-first API** — modern Swift Concurrency, no delegates
  unless you want them.
- **iOS 17+ / watchOS 10+ / macOS 14+** — pure Swift Package, no
  CocoaPods, no Carthage.
- **58 unit tests** covering framing, COBS, CRC, proto parsing, time-base
  conversion, and the swing-rejection detector.

## Quickstart

### 1. Add R10Kit to your project

In Xcode:

1. **File → Add Package Dependencies…**
2. Paste this repo's URL.
3. Select **R10Kit** and add it to your app target.

Or with Swift Package Manager directly:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/<your-org>/unofficial-r10-ios-sdk", from: "0.1.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "R10Kit", package: "unofficial-r10-ios-sdk"),
        ]
    )
]
```

### 2. Add the Bluetooth permission string to your Info.plist

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>R10Kit needs Bluetooth to connect to your Approach R10.</string>
```

### 3. Connect and read shots

```swift
import R10Kit

let connection = R10Connection()
let device = R10Device(connection: connection)

// Phase pipe — your app forwards transport phases to the device
// because AsyncStream is single-consumer.
Task {
    for await phase in connection.phases {
        print("R10 phase: \(phase)")
        await device.notifyPhaseChange(phase)
    }
}

// Shot stream — the data signal you actually came for.
Task {
    for await shot in device.shotEvents {
        if let mps = shot.metrics.clubMetrics?.clubHeadSpeed {
            let mph = Double(mps) * mpsToMph
            print("Club speed: \(Int(mph.rounded())) mph")
        }
        if let ball = shot.metrics.ballMetrics?.ballSpeed {
            print("Ball speed: \(ball) m/s")
        }
    }
}

await device.start()
await connection.start()
```

### 4. Run the demo app

This repo includes a runnable iOS demo at the project root
(`Unofficial R10 iOS SDK.xcodeproj`). To use it:

1. Open the `.xcodeproj` in Xcode.
2. **File → Add Package Dependencies… → Add Local…**
3. Select the repo's root folder (the one containing `Package.swift`).
4. Add **R10Kit** to the **Unofficial R10 iOS SDK** target.
5. Build and run on a physical iPhone (Bluetooth doesn't work in the
   simulator).

You'll see the connection state, model / firmware / battery, and a
list of recent shots populated by the R10.

## Public API at a glance

```swift
public actor R10Connection {
    public init()
    public func start()
    public func shutdown()
    public func forgetDevice()

    public nonisolated let phases: AsyncStream<R10Phase>
    public nonisolated let inboundPayloads: AsyncStream<Data>
    public nonisolated let batteryUpdates: AsyncStream<Int>
    public nonisolated let deviceInfoUpdates: AsyncStream<R10DeviceInfo>
    public nonisolated let frameTimestamps: AsyncStream<Date>

    public nonisolated static var hasStoredDevice: Bool { get }
}

public actor R10Device {
    public init(connection: R10Connection)
    public func start()
    public func notifyPhaseChange(_ phase: R10Phase) async
    public func stop()

    public nonisolated let shotEvents: AsyncStream<R10ShotEvent>
    public nonisolated let errors: AsyncStream<R10ErrorInfo>
    public nonisolated let tiltCalibrationUpdates: AsyncStream<R10CalibrationStatusType>
    public nonisolated let rejectedSwings: AsyncStream<Date>
}

public struct R10ShotEvent: Sendable {
    public let metrics: R10Metrics
    public let wallClockImpactAt: Date
}

public struct R10Metrics: Sendable {
    public var shotId: UInt32?
    public var shotType: R10ShotType?
    public var ballMetrics: R10BallMetrics?
    public var clubMetrics: R10ClubMetrics?
    public var swingMetrics: R10SwingMetrics?
}
```

Every parsed proto field — including the Priority-2 provenance enums
(`R10SpinCalcType`, `R10GolfBallType`) — is exposed publicly. Inspect
the source under `Sources/R10Kit/Protocol/R10Proto/R10Messages.swift`
for the complete schema.

## Architecture

```
[ Your app ]
     │
     │  AsyncStream<R10ShotEvent>
     │  AsyncStream<R10Phase>
     │  AsyncStream<R10ErrorInfo>
     ▼
[ R10Device actor ]    ←  proto parsing, request/response correlation,
     │                    spin-decay-style rejection detection
     │  AsyncStream<Data> (inbound payloads)
     ▼
[ R10Connection actor ]  ←  CoreBluetooth, COBS framing, CRC-16,
                            session-byte handshake, reconnect
                            with stored peripheral UUID
```

Both actors are `Sendable` and execute on their own actor's executor.
Bridge to `MainActor` (e.g. via `Task { @MainActor in … }`) when
updating UI.

## What this SDK does NOT include

- A Garmin-style trajectory simulator (you have raw launch + spin —
  bring your own ballistics model).
- Visualization (charts, dispersion ellipses, history UI). The
  demo app shows the bare minimum.
- Real-time atmospheric correction (no WeatherKit integration).
- Watch app sensor integration.
- Cloud sync, accounts, leaderboards.

## Hardware testing

This SDK has been built and validated against:

- iPhone 16 Pro, iOS 18.4
- Garmin Approach R10, firmware 4.50

Real-byte regression fixtures from the device are committed under
`Tests/R10KitTests/Fixtures/` — they pin the parser against known
real-world R10 emissions so future SDK changes can't silently
break protocol compatibility.

## Contributing

Yes please. The protocol layer is well-tested but the surface is
narrow; pull requests for additional message types, edge cases,
and hardware quirks are welcome. See `CONTRIBUTING.md`.

## Acknowledgements

This SDK exists because of [mholow/gsp-r10-adapter](https://github.com/mholow/gsp-r10-adapter)
— the original C# Windows-side reverse engineering of the R10's
proprietary BLE service. The protocol-level types here mirror that
work, with credit and the same MIT license.

The Garmin Approach R10 is a product of Garmin Ltd. This SDK is
not affiliated with or endorsed by Garmin.

## License

[MIT](LICENSE).
