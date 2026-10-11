import SwiftUI

struct DeviceRowView: View {
    let device: DiscoveredDevice
    let isExpanded: Bool
    var isNew = false
    let connectionState: ConnectionState
    let onToggle: () -> Void
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.displayName)
                            .font(.system(.body, weight: device.name == nil ? .regular : .semibold))
                            .foregroundStyle(device.name == nil ? .secondary : .primary)
                            .lineLimit(1)
                        Text(device.id.uuidString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if isNew { Chip(text: "NEW", tint: .green) }
                    if isThisDevice { Chip(text: connectionShortLabel, tint: .accentColor) }
                    SignalBars(rssi: device.rssi)
                    Text(BLEFormat.signalDescription(device.rssi))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded { details }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isThisDevice ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04))
        )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailRow(label: "Identifier", value: device.id.uuidString)
            DetailRow(label: "Local name", value: device.localName ?? "—")
            if let gap = device.gapName, gap != device.localName {
                DetailRow(label: "GAP name", value: gap)
            }
            DetailRow(
                label: "Services",
                value: device.serviceUUIDs.isEmpty ? "None advertised" : device.serviceUUIDs.joined(separator: "\n")
            )
            if !device.overflowServiceUUIDs.isEmpty {
                DetailRow(label: "Overflow", value: device.overflowServiceUUIDs.joined(separator: "\n"))
            }
            DetailRow(
                label: "Manufacturer",
                value: device.manufacturerData.map(BLEFormat.manufacturerSummary) ?? "—"
            )
            ForEach(device.serviceData.keys.sorted(), id: \.self) { key in
                DetailRow(label: "Data \(key)", value: BLEFormat.hex(device.serviceData[key] ?? Data()))
            }
            if let tx = device.txPower { DetailRow(label: "TX power", value: "\(tx) dBm") }
            DetailRow(label: "Connectable", value: device.isConnectable.map { $0 ? "Yes" : "No" } ?? "Unknown")
            DetailRow(label: "Packets", value: "\(device.advertisementCount) · last \(device.lastSeen.formatted(date: .omitted, time: .standard))")

            HStack {
                Spacer()
                Button(isThisDevice && connectionState.isActive ? "Open Inspector" : "Connect", action: onConnect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(device.isConnectable == false)
                    .help(device.isConnectable == false ? "Device advertises as not connectable" : "Connect and discover GATT services (read-only)")
            }
            .padding(.top, 4)
        }
        .padding(.leading, 18)
    }

    private var isThisDevice: Bool { connectionState.peripheralID == device.id }

    private var connectionShortLabel: String {
        switch connectionState {
        case .connected: return "Connected"
        case .connecting, .discovering: return "Connecting"
        case .disconnecting: return "Disconnecting"
        case .failed: return "Failed"
        case .idle: return ""
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct SignalBars: View {
    let rssi: Int?

    var body: some View {
        let bars = BLEFormat.signalBars(rssi)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < bars ? Color.primary : Color.primary.opacity(0.18))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
        .accessibilityLabel("Signal \(bars) of 4")
    }
}
