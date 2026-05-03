import SwiftUI
import R10Kit

@main
struct R10KitDemoApp: App {
    @State private var coordinator = R10DemoCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(coordinator)
                .task {
                    await coordinator.start()
                }
        }
    }
}

/// Owns the SDK actors for the lifetime of the app and bridges
/// their AsyncStream output into `@Observable` state the SwiftUI
/// views can read.
@MainActor
@Observable
final class R10DemoCoordinator {
    let connection = R10Connection()
    let device: R10Device

    var phase: R10Phase = .idle
    var deviceInfo = R10DeviceInfo()
    var batteryPercent: Int?
    var recentShots: [R10ShotEvent] = []
    var recentErrors: [R10ErrorInfo] = []

    private var bound = false

    init() {
        self.device = R10Device(connection: connection)
    }

    func start() async {
        guard !bound else { return }
        bound = true

        // Phase pipe — single-consumer per AsyncStream, so the
        // device gets a forwarded copy from us.
        Task { [connection, device] in
            for await phase in connection.phases {
                self.phase = phase
                await device.notifyPhaseChange(phase)
            }
        }
        Task { [connection] in
            for await info in connection.deviceInfoUpdates {
                self.deviceInfo = info
            }
        }
        Task { [connection] in
            for await pct in connection.batteryUpdates {
                self.batteryPercent = pct
            }
        }
        Task { [device] in
            for await shot in device.shotEvents {
                self.recentShots.insert(shot, at: 0)
                self.recentShots = Array(self.recentShots.prefix(20))
            }
        }
        Task { [device] in
            for await err in device.errors {
                self.recentErrors.insert(err, at: 0)
                self.recentErrors = Array(self.recentErrors.prefix(5))
            }
        }

        await device.start()
        await connection.start()
    }
}
