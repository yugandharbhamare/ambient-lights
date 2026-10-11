import SwiftUI

struct ScannerView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    let onConnect: () -> Void

    @State private var filter = ""
    @State private var namedOnly = false
    @State private var hideApple = true
    @State private var sort: Sort = .signal
    @State private var expanded: Set<UUID> = []

    enum Sort: String, CaseIterable, Identifiable {
        case signal = "Signal"
        case name = "Name"
        case firstSeen = "First seen"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 8) {
            controls
            if let baseline = bluetooth.baseline { baselineSummary(baseline) }
            Divider()
            if visibleDevices.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(visibleDevices) { device in
                            DeviceRowView(
                                device: device,
                                isExpanded: expanded.contains(device.id),
                                isNew: !device.isApple && (bluetooth.baseline.map { $0[device.id] == nil } ?? false),
                                connectionState: bluetooth.connection,
                                onToggle: { toggle(device.id) },
                                onConnect: {
                                    bluetooth.connect(to: device.id)
                                    onConnect()
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(.top, 8)
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                if bluetooth.isScanning {
                    Button {
                        bluetooth.stopScan()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    ProgressView().controlSize(.small)
                    if let endsAt = bluetooth.scanEndsAt {
                        Text("until \(endsAt, style: .time)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        bluetooth.startScan()
                    } label: {
                        Label("Scan for Lights", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(bluetooth.adapterState != .poweredOn)
                }
                Spacer()
                if bluetooth.baseline == nil {
                    Button("Set Baseline") { bluetooth.setBaseline() }
                        .controlSize(.small)
                        .disabled(bluetooth.devices.isEmpty || bluetooth.isScanning)
                        .help("Remember the current devices, then unplug the lights and scan again to see what disappears.")
                } else {
                    Button("Clear Baseline") { bluetooth.clearBaseline() }
                        .controlSize(.small)
                }
                Text("\(visibleDevices.count) of \(bluetooth.devices.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Filter name, UUID, or service", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Toggle("Named", isOn: $namedOnly)
                    .toggleStyle(.checkbox)
                Toggle("Hide Apple", isOn: $hideApple)
                    .toggleStyle(.checkbox)
                    .help("Hide Apple devices (iPhones, AirPods, Macs). Their identifiers rotate and they are never lights.")
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 96)
            }
        }
        .padding(.horizontal, 12)
    }

    private func baselineSummary(_ baseline: [UUID: String]) -> some View {
        let current = Set(bluetooth.devices.map(\.id))
        let missing = baseline
            .filter { !current.contains($0.key) }
            .sorted { $0.value < $1.value }
        let newCount = bluetooth.devices.filter { baseline[$0.id] == nil && !$0.isApple }.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Chip(text: "Baseline: \(baseline.count)", tint: .blue)
                Chip(text: "New: \(newCount)", tint: .green)
                Chip(text: "Missing: \(missing.count)", tint: .orange)
                Spacer()
            }
            if !missing.isEmpty && !bluetooth.isScanning {
                Text("Missing since baseline:")
                    .font(.caption.weight(.medium))
                ForEach(missing.prefix(8), id: \.key) { id, name in
                    Text("\(name) · \(id.uuidString)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if bluetooth.isScanning {
                Text("Missing list appears when the scan finishes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(bluetooth.devices.isEmpty ? "No devices yet" : "No devices match the filter")
                .font(.headline)
            Text("Power on your lights, close the old GoHigh app and disconnect phones from them, then scan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var visibleDevices: [DiscoveredDevice] {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = bluetooth.devices.filter { device in
            if namedOnly && device.name == nil { return false }
            if hideApple && device.isApple { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([device.name ?? "", device.id.uuidString] + device.serviceUUIDs)
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(query)
        }
        switch sort {
        case .signal:
            return filtered.sorted { ($0.rssi ?? -999, $0.id.uuidString) > ($1.rssi ?? -999, $1.id.uuidString) }
        case .name:
            return filtered.sorted {
                ($0.name == nil ? 1 : 0, $0.displayName.lowercased(), $0.id.uuidString)
                    < ($1.name == nil ? 1 : 0, $1.displayName.lowercased(), $1.id.uuidString)
            }
        case .firstSeen:
            return filtered.sorted { $0.firstSeen < $1.firstSeen }
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
