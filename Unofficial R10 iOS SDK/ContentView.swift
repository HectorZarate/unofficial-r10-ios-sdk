import SwiftUI
import R10Kit

struct ContentView: View {
    @Environment(R10DemoCoordinator.self) private var coordinator

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    LabeledContent("Phase", value: phaseLabel)
                        .foregroundStyle(phaseColor)
                    LabeledContent("Model", value: coordinator.deviceInfo.model ?? "—")
                    LabeledContent("Firmware", value: coordinator.deviceInfo.firmware ?? "—")
                    LabeledContent("Serial", value: coordinator.deviceInfo.serial ?? "—")
                    if let battery = coordinator.batteryPercent {
                        LabeledContent("Battery", value: "\(battery)%")
                    }
                }

                Section("Recent shots (\(coordinator.recentShots.count))") {
                    if coordinator.recentShots.isEmpty {
                        ContentUnavailableView(
                            "No shots yet",
                            systemImage: "figure.golf",
                            description: Text("Take a swing on the R10 to see metrics here.")
                        )
                    } else {
                        // Identity by impact timestamp, NOT row offset:
                        // shots prepend to the array, so an offset id
                        // would re-bind every existing row's destination
                        // to a different shot mid-tap.
                        ForEach(coordinator.recentShots, id: \.wallClockImpactAt) { shot in
                            // Closure-based NavigationLink (vs. value-based
                            // navigationDestination(for:)) keeps R10ShotEvent
                            // out of any Hashable conformance burden — the
                            // SDK's value type stays unbothered.
                            NavigationLink {
                                ShotDetailView(shot: shot)
                            } label: {
                                ShotRow(shot: shot)
                            }
                        }
                    }
                }
            }
            .navigationTitle("R10Kit Demo")
        }
    }

    private var phaseLabel: String {
        switch coordinator.phase {
        case .idle:                    return "Idle"
        case .bluetoothUnauthorized:   return "Bluetooth not allowed"
        case .bluetoothOff:            return "Bluetooth off"
        case .bluetoothUnsupported:    return "Bluetooth unsupported"
        case .scanning:                return "Scanning…"
        case .connecting:              return "Connecting…"
        case .handshaking:             return "Handshaking…"
        case .ready:                   return "Ready"
        case .disconnected:            return "Disconnected"
        }
    }

    private var phaseColor: Color {
        switch coordinator.phase {
        case .ready:    return .green
        case .scanning, .connecting, .handshaking: return .secondary
        default:        return .red
        }
    }
}

private struct ShotRow: View {
    let shot: R10ShotEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let mps = shot.metrics.clubMetrics?.clubHeadSpeed {
                    Text("\(Int((Double(mps) * mpsToMph).rounded())) mph club")
                        .font(.system(size: 24, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(.yellow)
                } else {
                    Text("—")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(shot.wallClockImpactAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                if let mps = shot.metrics.ballMetrics?.ballSpeed {
                    Text("\(Int((Double(mps) * mpsToMph).rounded())) mph ball")
                }
                if let launch = shot.metrics.ballMetrics?.launchAngle {
                    Text(String(format: "%.1f° launch", launch))
                }
                if let spin = shot.metrics.ballMetrics?.totalSpin {
                    Text("\(Int(spin)) rpm")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
        .environment(R10DemoCoordinator())
}
