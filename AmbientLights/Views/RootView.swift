import SwiftUI
import CoreBluetooth

struct RootView: View {
    @EnvironmentObject private var light: LightController

    /// Fixed so the menu bar panel never resizes; macOS then keeps it aligned
    /// under the menu bar with its native rounded corners.
    static let popoverSize = CGSize(width: 340, height: 582)

    var body: some View {
        LightsView()
            .frame(width: Self.popoverSize.width, height: Self.popoverSize.height, alignment: .top)
            .onAppear { light.refreshIfStale() }
    }
}

/// Phase 1 Bluetooth discovery tools, kept for diagnostics.
struct BluetoothToolsView: View {
    @State private var tab: Tab = .scanner

    enum Tab: String, CaseIterable, Identifiable {
        case scanner = "Scan"
        case device = "Device"
        case diagnostics = "Logs"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Picker("View", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch tab {
                case .scanner: ScannerView(onConnect: { tab = .device })
                case .device: InspectorView()
                case .diagnostics: DiagnosticsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            FooterView()
        }
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Bluetooth Tools", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                StatusPill(text: "Bluetooth \(BLEFormat.describe(bluetooth.adapterState))", color: adapterColor)
            }
            if let problem = permissionProblem {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(problem).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if bluetooth.adapterState == .unauthorized {
                        Button("Open Settings") { openBluetoothPrivacySettings() }
                            .controlSize(.small)
                    }
                }
                .padding(8)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var adapterColor: Color {
        switch bluetooth.adapterState {
        case .poweredOn: return .green
        case .poweredOff: return .secondary
        case .unauthorized, .unsupported: return .red
        default: return .orange
        }
    }

    private var permissionProblem: String? {
        switch bluetooth.adapterState {
        case .unauthorized:
            return "Bluetooth permission denied. Allow Ambient Lights in Privacy & Security → Bluetooth, then relaunch."
        case .poweredOff:
            return "Bluetooth is off. Turn it on in Control Center."
        case .unsupported:
            return "This Mac does not support Bluetooth Low Energy."
        case .resetting:
            return "Bluetooth is resetting…"
        default:
            return nil
        }
    }

    private func openBluetoothPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct FooterView: View {
    var body: some View {
        HStack {
            Text("Read-only Bluetooth diagnostics")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
    }
}

/// Small rounded label used for characteristic properties and advert flags.
struct Chip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
