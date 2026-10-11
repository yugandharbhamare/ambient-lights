import SwiftUI

/// GATT inspector for the connected peripheral. Read-only by design.
struct InspectorView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    @State private var copied = false

    var body: some View {
        if let id = bluetooth.connection.peripheralID {
            VStack(spacing: 0) {
                statusBar(id: id)
                Divider()
                if bluetooth.services.isEmpty {
                    placeholder
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(bluetooth.services) { service in
                                ServiceSection(service: service) { bluetooth.read(characteristicID: $0) }
                            }
                        }
                        .padding(12)
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "cable.connector.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("No device connected").font(.headline)
                Text("Scan, expand a device, and choose Connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func statusBar(id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bluetooth.connectedName ?? "Unnamed device").font(.headline)
                    Text(id.uuidString)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if bluetooth.connection.isActive {
                    Button("Disconnect") { bluetooth.disconnect() }
                        .controlSize(.small)
                } else {
                    Button("Retry") { bluetooth.connect(to: id) }
                        .controlSize(.small)
                        .disabled(bluetooth.adapterState != .poweredOn)
                }
            }
            HStack(spacing: 6) {
                if case .connecting = bluetooth.connection { ProgressView().controlSize(.small) }
                if case .discovering = bluetooth.connection { ProgressView().controlSize(.small) }
                Text(bluetooth.connection.label)
                    .font(.caption)
                    .foregroundStyle(isFailed ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .connected = bluetooth.connection {
                HStack {
                    Button("Read All Readable") { bluetooth.readAllReadable() }
                        .controlSize(.small)
                    Button(copied ? "Copied" : "Copy GATT Report") {
                        BluetoothManager.copyToPasteboard(bluetooth.gattReport())
                        flashCopied()
                    }
                    .controlSize(.small)
                    Spacer()
                    Chip(text: "Read-only", tint: .green)
                        .help("Phase 1 never writes values or enables notifications.")
                }
            }
        }
        .padding(12)
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Spacer()
            if bluetooth.connection.isActive {
                ProgressView()
                Text("Waiting for GATT services…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No services discovered.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var isFailed: Bool {
        if case .failed = bluetooth.connection { return true }
        return false
    }

    private func flashCopied() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

private struct ServiceSection: View {
    let service: ServiceInfo
    let onRead: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(service.knownName ?? "Custom service")
                        .font(.subheadline.weight(.semibold))
                    Text(service.uuid)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if !service.isPrimary { Chip(text: "secondary") }
            }
            if !service.characteristicsDiscovered {
                Text("Discovering characteristics…").font(.caption).foregroundStyle(.secondary)
            } else if service.characteristics.isEmpty {
                Text("No characteristics").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(service.characteristics) { characteristic in
                CharacteristicRow(characteristic: characteristic) { onRead(characteristic.id) }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct CharacteristicRow: View {
    let characteristic: CharacteristicInfo
    let onRead: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(characteristic.knownName ?? "Characteristic")
                        .font(.caption.weight(.medium))
                    Text(characteristic.uuid)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if characteristic.isReadable {
                    if characteristic.isReading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Read", action: onRead).controlSize(.mini)
                    }
                }
            }
            FlowChips(names: characteristic.propertyNames)
            if let value = characteristic.value {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(value.count) byte(s): \(BLEFormat.hex(value))")
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                    if let text = BLEFormat.textPreview(value) {
                        Text("UTF-8: \"\(text)\"")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            if let error = characteristic.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let date = characteristic.lastReadAt {
                Text("Read at \(date.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Property chips; wraps onto two rows when there are many.
private struct FlowChips: View {
    let names: [String]

    var body: some View {
        let rows = names.count > 4 ? [Array(names.prefix(4)), Array(names.dropFirst(4))] : [names]
        VStack(alignment: .leading, spacing: 3) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: 4) {
                    ForEach(rows[index], id: \.self) { name in
                        Chip(text: name, tint: tint(for: name))
                    }
                }
            }
        }
    }

    private func tint(for name: String) -> Color {
        if name.hasPrefix("read") { return .green }
        if name.contains("write") { return .orange }
        if name.hasPrefix("notify") || name.hasPrefix("indicate") { return .blue }
        return .secondary
    }
}
