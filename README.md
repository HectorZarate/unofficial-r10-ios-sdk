# R10Kit — Unofficial R10 iOS SDK

A native Swift SDK for connecting to the R10 launch monitor over
Bluetooth Low Energy. Pure Swift, no first-party app required.

> **Disclaimer.** This is an unofficial SDK. The
> protocol layer is reverse-engineered from publicly available work
> ([mholow/gsp-r10-adapter](https://github.com/mholow/gsp-r10-adapter)).

## Screenshots

| Connection + recent shots | Shot detail | Derived metrics + tempo |
|:---:|:---:|:---:|
| ![R10Kit demo — connection state, device info, list of recent shots](docs/screenshots/01-shot-list.png) | ![Shot detail — Identity (Shot ID, Practice type, raw epoch) and Club metrics; Ball section absent on a no-ball swing](docs/screenshots/02-shot-detail-identity.png) | ![Shot detail scrolled — full Swing timing with end-recording annotation, Derived backswing/downswing/follow-through/total durations and tempo ratio](docs/screenshots/03-shot-detail-derived.png) |

## Features

- Direct BLE connection to the R10. No first-party app, no PC tether.
- Full proto parsing for every shot the device emits: club speed,
  ball speed, launch angle/direction, spin rate + axis + provenance,
  attack angle, club face/path, swing-timing milliseconds, shot type
  (practice / normal), tilt-at-impact.
- No-ball practice swings — the R10 emits metrics on a
  full swing without a ball; this SDK exposes them.
- Connection state stream with auto-reconnect to the most recently
  paired R10.
- AsyncStream-first API. Modern Swift Concurrency, no delegates.
- iOS 17+ / watchOS 10+ / macOS 14+. Pure Swift Package.
- 70 unit tests covering framing, COBS, CRC, proto parsing,
  time-base conversion, the swing-rejection detector, and tilt-error
  recovery.

## Per-shot data

The R10 only populates `BallMetrics` (and `clubAngleFace`) when its
radar sees a ball departure. On a practice swing without a ball,
`Club` (minus face), `Swing timing`, identity, and the SDK's
swing-derived metrics still populate — every field below tagged
**No** is available without a ball. That's the practice-mode unlock
the SDK is built around.

### Raw fields exposed by R10Kit

| Field | Source struct | Unit | Ball required |
|---|---|---|:---:|
| `shotId` | `R10Metrics` | `UInt32` | No |
| `shotType` | `R10Metrics` | `.practice` / `.normal` / `.unknown` | No |
| `wallClockImpactAt` | `R10ShotEvent` | `Date` (UTC, derived from `R10TimeBase`) | No |
| `clubHeadSpeed` | `R10ClubMetrics` | m/s | No |
| `clubAnglePath` | `R10ClubMetrics` | degrees | No |
| `attackAngle` | `R10ClubMetrics` | degrees | No |
| `backSwingStartTime` | `R10SwingMetrics` | ms since R10 boot | No |
| `downSwingStartTime` | `R10SwingMetrics` | ms since R10 boot | No |
| `impactTime` | `R10SwingMetrics` | ms since R10 boot | No |
| `followThroughEndTime` | `R10SwingMetrics` | ms since R10 boot | No |
| `endRecordingTime` | `R10SwingMetrics` | ms since R10 boot (may be < `followThroughEndTime` in some emissions; suspected different reference clock) | No |
| `clubAngleFace` | `R10ClubMetrics` | degrees | **Yes** |
| `ballSpeed` | `R10BallMetrics` | m/s | **Yes** |
| `launchAngle` | `R10BallMetrics` | degrees | **Yes** |
| `launchDirection` | `R10BallMetrics` | degrees | **Yes** |
| `totalSpin` | `R10BallMetrics` | rpm | **Yes** |
| `spinAxis` | `R10BallMetrics` | degrees | **Yes** |
| `spinCalcType` | `R10BallMetrics` | `.ratio` / `.ballFlight` / `.other` / `.measured` | **Yes** |
| `golfBallType` | `R10BallMetrics` | `.unknown` / `.conventional` / `.marked` | **Yes** |

### Derived metrics (computed by the demo app's `ShotDetailViewModel`)

These aren't on the SDK type — they live next to consuming code so the
SDK stays unit-pure. `R10Kit` exposes the inputs; you compute the rest.

| Metric | Formula | Ball required |
|---|---|:---:|
| Backswing duration | `downSwingStartTime − backSwingStartTime` | No |
| Downswing duration | `impactTime − downSwingStartTime` | No |
| Follow-through duration | `followThroughEndTime − impactTime` | No |
| Total swing duration | `impactTime − backSwingStartTime` | No |
| Tempo ratio | backswing ÷ downswing (golf 3:1 convention) | No |
| Smash factor | `ballSpeed ÷ clubHeadSpeed` | **Yes** |
| Face-to-path | `clubAngleFace − clubAnglePath` | **Yes** |

## Quickstart

### 1. Run the demo app

A runnable iOS demo lives at the repo root
(`Unofficial R10 iOS SDK.xcodeproj`). The local `R10Kit` package is
already wired into the demo target, so no manual "Add Package…"
step is needed.

1. Clone the repo and open `Unofficial R10 iOS SDK.xcodeproj` in Xcode.
2. Build and run on a physical iPhone. Bluetooth doesn't work in
   the simulator.

The demo shows connection state, model / firmware / battery, and a
list of recent shots — tap any shot to see every field the SDK
exposes.

### 2. Add R10Kit to your own project

In Xcode:

1. File → Add Package Dependencies…
2. Paste this repo's URL.
3. Select R10Kit and add it to your app target.

Or via `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/HectorZarate/unofficial-r10-ios-sdk", from: "0.1.0"),
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

### 3. Add the Bluetooth permission string to Info.plist

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>R10Kit needs Bluetooth to connect to your R10.</string>
```

### 4. Connect and read shots

```swift
import R10Kit

let connection = R10Connection()
let device = R10Device(connection: connection)

// Phase pipe — the app forwards transport phases to the device
// because AsyncStream is single-consumer.
Task {
    for await phase in connection.phases {
        print("R10 phase: \(phase)")
        await device.notifyPhaseChange(phase)
    }
}

// Shot stream.
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

## Hardware tested

- iPhone 16 Pro, iOS 18.4
- R10, firmware 4.50

Real-byte regression fixtures from the device are committed under
`Tests/R10KitTests/Fixtures/`. They pin the parser against known
real-world R10 emissions so future SDK changes can't silently break
protocol compatibility.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Acknowledgements

This SDK builds on
[mholow/gsp-r10-adapter](https://github.com/mholow/gsp-r10-adapter) —
C# Windows-side reverse engineering of the R10's proprietary BLE
service. The protocol-level types here mirror that work, under the
same MIT license.

## License

[MIT](LICENSE).
