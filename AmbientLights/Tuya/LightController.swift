import Foundation

/// UI-facing state for the configured light. Writes are optimistic and coalesced:
/// while one request is in flight, newer values replace older pending ones, so
/// dragging a slider sends at most one command at a time.
@MainActor
final class LightController: ObservableObject {
    enum Status: Equatable {
        case notConfigured
        case idle
        case working
        case error(String)
    }

    @Published private(set) var credentials: LightCredentials
    @Published private(set) var name: String?
    @Published private(set) var state = LightState()
    @Published private(set) var hasState = false
    @Published private(set) var status: Status
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isDiscovering = false

    private let client: TuyaClient
    private let log: LogStore
    private var pending: [String: DPValue] = [:]
    private var worker: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(log: LogStore) {
        self.log = log
        let stored = LightConfigStore.load()
        self.client = TuyaClient(log: log, credentials: stored.credentials.isComplete ? stored.credentials : nil)
        credentials = stored.credentials
        name = stored.name
        status = stored.credentials.isComplete ? .idle : .notConfigured
    }

    var isConfigured: Bool { credentials.isComplete }

    #if DEBUG
    /// Snapshot rendering only: fixed state, no Keychain, no network.
    init(previewState: LightState, name: String, log: LogStore) {
        self.log = log
        self.client = TuyaClient(log: log)
        credentials = LightCredentials(deviceID: "preview", host: "127.0.0.1", localKey: "0123456789abcdef")
        self.name = name
        state = previewState
        hasState = true
        status = .idle
    }
    #endif

    // MARK: - Setup

    func save(_ credentials: LightCredentials, name: String?) throws {
        try LightConfigStore.save(credentials, name: name)
        self.credentials = credentials
        self.name = name
        hasState = false
        status = .idle
        log.info(.light, "Light settings saved (\(name ?? "unnamed"))")
        let client = self.client
        Task {
            await client.configure(credentials)
            self.refresh()
        }
    }

    func forget() {
        LightConfigStore.forget()
        credentials = LightCredentials(deviceID: "", host: "", localKey: "")
        name = nil
        hasState = false
        status = .notConfigured
        let client = self.client
        Task { await client.configure(nil) }
        log.info(.light, "Light settings removed")
    }

    /// Listens for the light's broadcast and updates the stored IP if it changed.
    func discover() {
        guard !isDiscovering else { return }
        isDiscovering = true
        let deviceID = credentials.deviceID.isEmpty ? nil : credentials.deviceID
        log.info(.light, "Listening for the light's network broadcast…")
        Task {
            let found = await TuyaDiscovery.find(deviceID: deviceID, timeout: 12)
            isDiscovering = false
            guard let found else {
                log.warning(.light, "No broadcast heard in 12 s. Is the light powered and on this Wi-Fi?")
                status = .error("Light not found on this network.")
                return
            }
            log.info(.light, "Light found on the network (protocol \(found.version ?? "?"))")
            if found.ip != credentials.host, credentials.isComplete {
                var updated = credentials
                updated.host = found.ip
                LightConfigStore.updateHost(found.ip)
                credentials = updated
                await client.configure(updated)
                log.info(.light, "Light IP address changed; updated")
            }
            refresh()
        }
    }

    // MARK: - Reading

    func refreshIfStale() {
        guard isConfigured else { return }
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 5 { return }
        refresh()
    }

    func refresh() {
        guard isConfigured, refreshTask == nil else { return }
        refreshTask = Task {
            defer { refreshTask = nil }
            if pending.isEmpty, worker == nil { status = .working }
            do {
                let dps = try await client.status()
                if pending.isEmpty {
                    state.apply(dps)
                    hasState = true
                }
                lastUpdated = Date()
                if worker == nil { status = .idle }
            } catch {
                report(error, action: "read status")
            }
        }
    }

    // MARK: - Writing

    func setPower(_ on: Bool) {
        state.isOn = on
        enqueue([SkyLightDP.power: .bool(on)])
    }

    func setMode(_ mode: LightMode) {
        state.mode = mode
        switch mode {
        case .white:
            enqueue([SkyLightDP.mode: .string("white")])
        case .colour:
            enqueue([SkyLightDP.mode: .string("colour"), SkyLightDP.colour: .string(state.colour.hex)])
        }
    }

    /// 10...1000. In colour mode this is the colour's value (V) channel.
    func setBrightness(_ level: Int) {
        let level = level.clamped(SkyLightDP.brightnessRange)
        switch state.mode {
        case .white:
            state.brightness = level
            enqueue([SkyLightDP.mode: .string("white"), SkyLightDP.brightness: .int(level)])
        case .colour:
            state.colour.value = level
            enqueue([SkyLightDP.mode: .string("colour"), SkyLightDP.colour: .string(state.colour.hex)])
        }
    }

    /// 0 (warm) ... 1000 (cool). White mode only.
    func setTemperature(_ value: Int) {
        let value = value.clamped(SkyLightDP.temperatureRange)
        state.temperature = value
        state.mode = .white
        enqueue([SkyLightDP.mode: .string("white"), SkyLightDP.temperature: .int(value)])
    }

    func setColour(hue: Int, saturation: Int) {
        state.mode = .colour
        state.colour.hue = hue.clamped(0...360)
        state.colour.saturation = saturation.clamped(0...1000)
        if state.colour.value < 10 { state.colour.value = 1000 }
        enqueue([SkyLightDP.mode: .string("colour"), SkyLightDP.colour: .string(state.colour.hex)])
    }

    /// White mode with both brightness and warmth in one command (used by scenes).
    func setWhite(brightness: Int, temperature: Int) {
        state.isOn = true
        state.mode = .white
        state.brightness = brightness.clamped(SkyLightDP.brightnessRange)
        state.temperature = temperature.clamped(SkyLightDP.temperatureRange)
        enqueue([SkyLightDP.power: .bool(true), SkyLightDP.mode: .string("white"),
                 SkyLightDP.brightness: .int(state.brightness), SkyLightDP.temperature: .int(state.temperature)])
    }

    /// Colour mode with a full HSV in one command (used by scenes).
    func setColour(_ hsv: HSV) {
        state.isOn = true
        state.mode = .colour
        state.colour = HSV(hue: hsv.hue.clamped(0...360), saturation: hsv.saturation.clamped(0...1000), value: hsv.value.clamped(10...1000))
        enqueue([SkyLightDP.power: .bool(true), SkyLightDP.mode: .string("colour"), SkyLightDP.colour: .string(state.colour.hex)])
    }

    private func enqueue(_ dps: [String: DPValue]) {
        guard isConfigured else { return }
        pending.merge(dps) { _, new in new }
        guard worker == nil else { return }
        status = .working
        worker = Task {
            while !pending.isEmpty {
                let batch = pending
                pending.removeAll()
                do {
                    let reported = try await client.set(batch)
                    // Don't let an older reply overwrite values the user changed meanwhile.
                    state.apply(reported.filter { pending[$0.key] == nil })
                    lastUpdated = Date()
                } catch {
                    pending.removeAll()
                    report(error, action: "send command")
                    worker = nil
                    return
                }
            }
            worker = nil
            status = .idle
        }
    }

    private func report(_ error: Error, action: String) {
        let message: String
        switch error {
        case TuyaTransport.TransportError.timeout(_), TuyaTransport.TransportError.unreachable(_):
            message = "Light didn't answer. It may be busy with the phone app, offline, or on a new IP. Try Find on Network, or power-cycle the light."
        default:
            message = error.localizedDescription
        }
        log.error(.light, "Could not \(action): \(error.localizedDescription)")
        status = .error(message)
    }
}
