import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One-time setup: device ID, IP and local key (stored in the Keychain).
struct LightSetupView: View {
    @EnvironmentObject private var light: LightController
    let onDone: () -> Void
    let canCancel: Bool

    @State private var name = ""
    @State private var deviceID = ""
    @State private var host = ""
    @State private var localKey = ""
    @State private var message: String?
    @State private var isFinding = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect your light").font(.headline)
                Text("Import the devices.json file from `tinytuya wizard`, or enter the values by hand. The local key is stored only in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    importDevicesJSON()
                } label: {
                    Label("Import devices.json…", systemImage: "square.and.arrow.down")
                }

                Divider()

                field("Name", text: $name, prompt: "GoHigh SkyLight Bar")
                field("Device ID", text: $deviceID, prompt: "22 characters", monospaced: true)
                HStack(alignment: .bottom) {
                    field("IP address", text: $host, prompt: "192.168.1.x", monospaced: true)
                    Button(isFinding ? "Searching…" : "Find") { find() }
                        .disabled(isFinding)
                        .help("Listen for the light's network broadcast (12 s)")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local key").font(.caption)
                    SecureField("16 characters", text: $localKey)
                        .textFieldStyle(.roundedBorder)
                    if !localKey.isEmpty, localKey.utf8.count != 16 {
                        Text("Must be exactly 16 characters (now \(localKey.utf8.count)).")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }

                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if canCancel {
                        Button("Forget Light", role: .destructive) {
                            light.forget()
                            onDone()
                        }
                    }
                    Spacer()
                    if canCancel { Button("Cancel", action: onDone) }
                    Button("Save & Connect", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.isComplete)
                }
            }
            .padding(12)
        }
        .onAppear(perform: loadExisting)
    }

    private var draft: LightCredentials {
        LightCredentials(
            deviceID: deviceID.trimmingCharacters(in: .whitespaces),
            host: host.trimmingCharacters(in: .whitespaces),
            localKey: localKey
        )
    }

    private func field(_ title: String, text: Binding<String>, prompt: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .font(monospaced ? .body.monospaced() : .body)
        }
    }

    private func loadExisting() {
        guard light.isConfigured else { return }
        name = light.name ?? ""
        deviceID = light.credentials.deviceID
        host = light.credentials.host
        localKey = light.credentials.localKey
    }

    private func save() {
        do {
            try light.save(draft, name: name.isEmpty ? nil : name)
            onDone()
        } catch {
            message = "Could not save: \(error.localizedDescription)"
        }
    }

    private func find() {
        isFinding = true
        message = "Listening for broadcasts from your light…"
        let id = draft.deviceID.isEmpty ? nil : draft.deviceID
        Task {
            let found = await TuyaDiscovery.find(deviceID: id, timeout: 12)
            isFinding = false
            if let found {
                host = found.ip
                if deviceID.isEmpty { deviceID = found.deviceID }
                message = "Found it (protocol \(found.version ?? "?"))."
            } else {
                message = "No broadcast heard. Check the light is powered and on the same Wi-Fi as this Mac."
            }
        }
    }

    private func importDevicesJSON() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose devices.json created by tinytuya wizard"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("tuya-keys")
        // The popover would close behind a modal panel; bring the app forward first.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let devices = try LightConfigStore.importTinyTuya(from: url)
            guard let device = devices.first else {
                message = "No device with a local key found in that file."
                return
            }
            name = device.name
            deviceID = device.deviceID
            localKey = device.localKey
            if let ip = device.host { host = ip }
            message = devices.count > 1
                ? "Imported \"\(device.name)\" (first of \(devices.count) devices)."
                : "Imported \"\(device.name)\"." + (device.host == nil ? " Press Find to get its IP." : "")
        } catch {
            message = "Could not read that file: \(error.localizedDescription)"
        }
    }
}
