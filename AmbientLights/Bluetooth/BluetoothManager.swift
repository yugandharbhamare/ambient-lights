import AppKit
import Foundation
import CoreBluetooth

/// Owns every CoreBluetooth object.
///
/// Threading: CoreBluetooth delegate callbacks run on `queue`, a private serial
/// queue. All CB objects and the "queue state" below are touched only on that
/// queue. `@Published` properties are only mutated on the main thread.
///
/// Phase 1 is strictly read-only. This type never calls `writeValue`, never
/// writes descriptors, and never calls `setNotifyValue` (which writes the CCCD).
final class BluetoothManager: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: UI state (main thread)

    @Published private(set) var adapterState: CBManagerState = .unknown
    @Published private(set) var authorization: CBManagerAuthorization = CBManager.authorization
    @Published private(set) var isScanning = false
    @Published private(set) var scanEndsAt: Date?
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var connection: ConnectionState = .idle
    @Published private(set) var connectedName: String?
    @Published private(set) var services: [ServiceInfo] = []

    /// Devices captured by "Set Baseline" (id → display name), used to spot
    /// devices that appear or disappear when the lights are unplugged.
    @Published private(set) var baseline: [UUID: String]?

    let log: LogStore

    static let scanDuration: TimeInterval = 30
    static let connectTimeout: TimeInterval = 15
    static let readTimeout: TimeInterval = 10

    // MARK: Bluetooth-queue state

    private let queue = DispatchQueue(label: "local.ambientlights.bluetooth", qos: .userInitiated)
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var discovered: [UUID: DiscoveredDevice] = [:]
    private var devicePublishScheduled = false
    private var scanStopWork: DispatchWorkItem?

    private var activePeripheral: CBPeripheral?
    private var connectTimeoutWork: DispatchWorkItem?
    private var userRequestedDisconnect = false
    private var pendingCharacteristicDiscoveries = 0
    private var characteristicsByID: [Int: CBCharacteristic] = [:]
    private var readStates: [Int: ReadState] = [:]

    private struct ReadState {
        var isReading = false
        var lastReadAt: Date?
        var lastError: String?
        var timeoutWork: DispatchWorkItem?
    }

    init(log: LogStore) {
        self.log = log
        super.init()
    }

    // MARK: - Public API (call from main thread)

    /// Creates the central manager. This triggers the Bluetooth permission prompt
    /// on first launch.
    func start() {
        queue.async { [weak self] in
            guard let self, self.central == nil else { return }
            self.log.info(.system, "Starting Bluetooth (macOS \(ProcessInfo.processInfo.operatingSystemVersionString))")
            self.central = CBCentralManager(
                delegate: self,
                queue: self.queue,
                options: [CBCentralManagerOptionShowPowerAlertKey: true]
            )
        }
    }

    func startScan() {
        queue.async { [weak self] in self?.startScanOnQueue() }
    }

    func stopScan() {
        queue.async { [weak self] in self?.stopScanOnQueue(reason: "stopped by user") }
    }

    func connect(to id: UUID) {
        queue.async { [weak self] in self?.connectOnQueue(id) }
    }

    func disconnect() {
        queue.async { [weak self] in self?.disconnectOnQueue() }
    }

    func read(characteristicID: Int) {
        queue.async { [weak self] in self?.readOnQueue(characteristicID) }
    }

    func setBaseline() {
        // Apple devices rotate identifiers, so they would always look "missing".
        let snapshot = Dictionary(uniqueKeysWithValues: devices.filter { !$0.isApple }.map { ($0.id, $0.displayName) })
        baseline = snapshot
        log.info(.scan, "Baseline set with \(snapshot.count) non-Apple device(s)")
    }

    func clearBaseline() {
        baseline = nil
        log.info(.scan, "Baseline cleared")
    }

    func readAllReadable() {
        queue.async { [weak self] in
            guard let self else { return }
            let readable = self.characteristicsByID.filter { $0.value.properties.contains(.read) }
            self.log.info(.read, "Reading \(readable.count) readable characteristic(s)")
            for id in readable.keys.sorted() { self.readOnQueue(id) }
        }
    }

    // MARK: - Scanning

    private func startScanOnQueue() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            log.warning(.scan, "Cannot scan: Bluetooth is \(BLEFormat.describe(central.state))")
            return
        }
        guard !central.isScanning else { return }

        // Fresh list each scan; keep the connected peripheral object alive.
        discovered.removeAll()
        peripherals = peripherals.filter { $0.key == activePeripheral?.identifier }
        publishDevices()

        // No service filter: the lights' service UUID is unknown.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        log.info(.scan, "Scan started (all peripherals, auto-stop after \(Int(Self.scanDuration)) s)")

        scanStopWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.stopScanOnQueue(reason: "time limit reached")
        }
        scanStopWork = work
        queue.asyncAfter(deadline: .now() + Self.scanDuration, execute: work)

        let endsAt = Date().addingTimeInterval(Self.scanDuration)
        DispatchQueue.main.async {
            self.isScanning = true
            self.scanEndsAt = endsAt
        }
    }

    private func stopScanOnQueue(reason: String) {
        scanStopWork?.cancel()
        scanStopWork = nil
        if let central, central.state == .poweredOn, central.isScanning {
            central.stopScan()
            log.info(.scan, "Scan stopped (\(reason)); \(discovered.count) device(s) found")
        }
        DispatchQueue.main.async {
            self.isScanning = false
            self.scanEndsAt = nil
        }
    }

    /// Throttles list updates to ~2 Hz; advert callbacks can arrive hundreds of times a second.
    private func scheduleDevicePublish() {
        guard !devicePublishScheduled else { return }
        devicePublishScheduled = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.devicePublishScheduled = false
            self.publishDevices()
        }
    }

    private func publishDevices() {
        let snapshot = Array(discovered.values)
        DispatchQueue.main.async { self.devices = snapshot }
    }

    // MARK: - Connection

    private func connectOnQueue(_ id: UUID) {
        guard let central, central.state == .poweredOn else {
            log.warning(.connection, "Cannot connect: Bluetooth is not on")
            return
        }
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            log.error(.connection, "Peripheral \(LogStore.peripheral(id)) is no longer known; scan again")
            setConnection(.failed(id, "Device not found. Scan again."), name: nil)
            return
        }
        if let current = activePeripheral {
            if current.identifier == id, current.state != .disconnected { return }
            log.info(.connection, "Disconnecting \(LogStore.peripheral(current.identifier)) before switching device")
            userRequestedDisconnect = true
            central.cancelPeripheralConnection(current)
            resetActivePeripheral()
        }

        stopScanOnQueue(reason: "connecting")
        let name = discovered[id]?.name ?? peripheral.name
        activePeripheral = peripheral
        peripherals[id] = peripheral
        peripheral.delegate = self
        userRequestedDisconnect = false
        log.markTrusted(id)
        log.info(.connection, "Connecting to \(LogStore.name(name, for: id)) \(LogStore.peripheral(id))")
        setConnection(.connecting(id), name: name)
        central.connect(peripheral, options: nil)

        let work = DispatchWorkItem { [weak self] in
            guard let self, let active = self.activePeripheral, active.identifier == id,
                  active.state != .connected else { return }
            self.log.error(.connection, "Connection timed out after \(Int(Self.connectTimeout)) s")
            self.central?.cancelPeripheralConnection(active)
            self.resetActivePeripheral()
            self.setConnection(.failed(id, "Timed out. Move closer, and make sure the old app or a phone is not connected to the lights."), name: name)
        }
        connectTimeoutWork = work
        queue.asyncAfter(deadline: .now() + Self.connectTimeout, execute: work)
    }

    private func disconnectOnQueue() {
        guard let peripheral = activePeripheral else {
            setConnection(.idle, name: nil)
            return
        }
        userRequestedDisconnect = true
        log.info(.connection, "Disconnect requested")
        setConnection(.disconnecting(peripheral.identifier), name: currentName(for: peripheral))
        if peripheral.state == .disconnected {
            resetActivePeripheral()
            setConnection(.idle, name: nil)
        } else {
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func resetActivePeripheral() {
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        for state in readStates.values { state.timeoutWork?.cancel() }
        readStates.removeAll()
        characteristicsByID.removeAll()
        pendingCharacteristicDiscoveries = 0
        activePeripheral = nil
        DispatchQueue.main.async { self.services = [] }
    }

    private func setConnection(_ state: ConnectionState, name: String?) {
        DispatchQueue.main.async {
            self.connection = state
            self.connectedName = name
        }
    }

    private func currentName(for peripheral: CBPeripheral) -> String? {
        discovered[peripheral.identifier]?.name ?? peripheral.name
    }

    // MARK: - Reads

    private func readOnQueue(_ id: Int) {
        guard let peripheral = activePeripheral, peripheral.state == .connected,
              let characteristic = characteristicsByID[id] else {
            log.warning(.read, "Read skipped: not connected or characteristic unknown")
            return
        }
        // Safety: only characteristics that declare the read property.
        guard characteristic.properties.contains(.read) else {
            log.warning(.read, "Read skipped: \(characteristic.uuid.uuidString) is not readable")
            return
        }
        var state = readStates[id] ?? ReadState()
        guard !state.isReading else { return }
        state.isReading = true
        state.timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, var timedOut = self.readStates[id], timedOut.isReading else { return }
            timedOut.isReading = false
            timedOut.lastError = "No response within \(Int(Self.readTimeout)) s"
            self.readStates[id] = timedOut
            self.log.warning(.read, "Read of \(characteristic.uuid.uuidString) timed out")
            self.publishServices()
        }
        state.timeoutWork = work
        readStates[id] = state
        queue.asyncAfter(deadline: .now() + Self.readTimeout, execute: work)

        log.debug(.read, "Reading \(characteristic.uuid.uuidString)")
        peripheral.readValue(for: characteristic)
        publishServices()
    }

    // MARK: - GATT snapshot

    private static func key(_ object: AnyObject) -> Int {
        ObjectIdentifier(object).hashValue
    }

    private func publishServices() {
        let snapshot: [ServiceInfo] = (activePeripheral?.services ?? []).map { service in
            let characteristics = (service.characteristics ?? []).map { characteristic -> CharacteristicInfo in
                let id = Self.key(characteristic)
                let state = readStates[id]
                return CharacteristicInfo(
                    id: id,
                    uuid: characteristic.uuid.uuidString,
                    knownName: BLEFormat.knownName(for: characteristic.uuid),
                    properties: characteristic.properties,
                    value: state?.lastReadAt == nil ? nil : characteristic.value,
                    lastReadAt: state?.lastReadAt,
                    lastError: state?.lastError,
                    isReading: state?.isReading ?? false
                )
            }
            return ServiceInfo(
                id: Self.key(service),
                uuid: service.uuid.uuidString,
                knownName: BLEFormat.knownName(for: service.uuid),
                isPrimary: service.isPrimary,
                characteristicsDiscovered: service.characteristics != nil,
                characteristics: characteristics
            )
        }
        DispatchQueue.main.async { self.services = snapshot }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        let authorization = CBManager.authorization
        log.info(.system, "Adapter: \(BLEFormat.describe(state)); permission: \(BLEFormat.describe(authorization))")

        switch state {
        case .unauthorized:
            log.error(.system, "Bluetooth permission denied. Enable Ambient Lights in System Settings → Privacy & Security → Bluetooth.")
        case .poweredOff:
            log.warning(.system, "Bluetooth is off. Turn it on in Control Center or System Settings.")
        case .unsupported:
            log.error(.system, "This Mac does not support Bluetooth Low Energy.")
        default:
            break
        }

        if state != .poweredOn {
            // CoreBluetooth stops scans and invalidates connections when it leaves poweredOn.
            scanStopWork?.cancel()
            scanStopWork = nil
            if let peripheral = activePeripheral {
                log.warning(.connection, "Connection to \(LogStore.peripheral(peripheral.identifier)) lost: Bluetooth unavailable")
                let id = peripheral.identifier
                resetActivePeripheral()
                setConnection(.failed(id, "Bluetooth became unavailable"), name: nil)
            }
            DispatchQueue.main.async {
                self.isScanning = false
                self.scanEndsAt = nil
            }
        }

        DispatchQueue.main.async {
            self.adapterState = state
            self.authorization = authorization
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let now = Date()
        let existing = discovered[id]
        var device = existing ?? DiscoveredDevice(id: id, firstSeen: now)
        device.apply(advertisement: advertisementData, peripheralName: peripheral.name, rssi: RSSI.intValue, at: now)
        discovered[id] = device
        peripherals[id] = peripheral

        if existing == nil {
            var details = ["RSSI \(BLEFormat.signalDescription(device.rssi))"]
            if !device.serviceUUIDs.isEmpty { details.append("services [\(device.serviceUUIDs.joined(separator: ", "))]") }
            if let data = device.manufacturerData { details.append("mfr \(BLEFormat.manufacturerSummary(data))") }
            for key in device.serviceData.keys.sorted() {
                details.append("svcdata \(key): \(BLEFormat.hex(device.serviceData[key] ?? Data()))")
            }
            if let connectable = device.isConnectable { details.append(connectable ? "connectable" : "not connectable") }
            log.debug(.scan, "Found \(LogStore.name(device.name, for: id)) \(LogStore.peripheral(id)) · \(details.joined(separator: " · "))")
        } else if existing?.name == nil, let name = device.name {
            log.debug(.scan, "Name resolved for \(LogStore.peripheral(id)): \(LogStore.name(name, for: id))")
        }
        scheduleDevicePublish()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == activePeripheral?.identifier else {
            log.debug(.connection, "Ignoring stale connection to \(LogStore.peripheral(peripheral.identifier))")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectTimeoutWork?.cancel()
        connectTimeoutWork = nil
        log.info(.connection, "Connected to \(LogStore.peripheral(peripheral.identifier)); discovering services")
        setConnection(.discovering(peripheral.identifier), name: currentName(for: peripheral))
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == activePeripheral?.identifier else { return }
        let message = error.map(BLEFormat.describe) ?? "Unknown error"
        log.error(.connection, "Failed to connect to \(LogStore.peripheral(peripheral.identifier)): \(message)")
        let name = currentName(for: peripheral)
        resetActivePeripheral()
        setConnection(.failed(peripheral.identifier, message), name: name)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == activePeripheral?.identifier else {
            log.debug(.connection, "Disconnected \(LogStore.peripheral(peripheral.identifier)) (inactive)")
            return
        }
        let id = peripheral.identifier
        let name = currentName(for: peripheral)
        resetActivePeripheral()
        if userRequestedDisconnect || error == nil {
            log.info(.connection, "Disconnected from \(LogStore.peripheral(id))")
            setConnection(.idle, name: nil)
        } else {
            let message = error.map(BLEFormat.describe) ?? "Unknown error"
            log.warning(.connection, "Disconnected unexpectedly from \(LogStore.peripheral(id)): \(message)")
            setConnection(.failed(id, message), name: name)
        }
        userRequestedDisconnect = false
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === activePeripheral else { return }
        if let error {
            log.error(.gatt, "Service discovery failed: \(BLEFormat.describe(error))")
            setConnection(.connected(peripheral.identifier), name: currentName(for: peripheral))
            return
        }
        let services = peripheral.services ?? []
        log.info(.gatt, "Discovered \(services.count) service(s)")
        for service in services {
            let known = BLEFormat.knownName(for: service.uuid).map { " (\($0))" } ?? ""
            log.info(.gatt, "Service \(service.uuid.uuidString)\(known)\(service.isPrimary ? "" : " [secondary]")")
        }
        pendingCharacteristicDiscoveries = services.count
        publishServices()
        if services.isEmpty {
            setConnection(.connected(peripheral.identifier), name: currentName(for: peripheral))
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === activePeripheral else { return }
        if let error {
            log.error(.gatt, "Characteristic discovery failed for \(service.uuid.uuidString): \(BLEFormat.describe(error))")
        }
        for characteristic in service.characteristics ?? [] {
            characteristicsByID[Self.key(characteristic)] = characteristic
            let known = BLEFormat.knownName(for: characteristic.uuid).map { " (\($0))" } ?? ""
            let properties = BLEFormat.propertyNames(characteristic.properties).joined(separator: ", ")
            log.info(.gatt, "  \(service.uuid.uuidString) → \(characteristic.uuid.uuidString)\(known) [\(properties)]")
        }
        pendingCharacteristicDiscoveries = max(0, pendingCharacteristicDiscoveries - 1)
        publishServices()
        if pendingCharacteristicDiscoveries == 0 {
            log.info(.gatt, "GATT discovery complete: \(characteristicsByID.count) characteristic(s)")
            setConnection(.connected(peripheral.identifier), name: currentName(for: peripheral))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === activePeripheral else { return }
        let id = Self.key(characteristic)
        var state = readStates[id] ?? ReadState()
        let wasRequested = state.isReading
        state.timeoutWork?.cancel()
        state.timeoutWork = nil
        state.isReading = false
        state.lastReadAt = Date()
        if let error {
            state.lastError = BLEFormat.describe(error)
            log.error(.read, "Read \(characteristic.uuid.uuidString) failed: \(state.lastError ?? "")")
        } else {
            state.lastError = nil
            let data = characteristic.value ?? Data()
            let text = BLEFormat.textPreview(data).map { " \"\($0)\"" } ?? ""
            log.info(.read, "\(wasRequested ? "Read" : "Unsolicited update") \(characteristic.uuid.uuidString): \(data.count) byte(s) \(BLEFormat.hex(data))\(text)")
        }
        readStates[id] = state
        publishServices()
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral === activePeripheral else { return }
        log.warning(.gatt, "Device changed its services (\(invalidatedServices.count) invalidated); rediscovering")
        setConnection(.discovering(peripheral.identifier), name: currentName(for: peripheral))
        peripheral.discoverServices(nil)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        guard peripheral === activePeripheral, let name = peripheral.name else { return }
        log.info(.connection, "Device name updated: \(LogStore.name(name, for: peripheral.identifier))")
        DispatchQueue.main.async { self.connectedName = name }
    }
}

// MARK: - Reports (main thread)

extension BluetoothManager {
    func diagnosticsHeader() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return """
        Ambient Lights diagnostics
        App: \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Adapter: \(BLEFormat.describe(adapterState)); permission: \(BLEFormat.describe(authorization))
        Connection: \(connection.label)
        Devices in last scan: \(devices.count)
        """
    }

    /// Plain-text GATT table for the connected device, for protocol research.
    func gattReport() -> String {
        var lines = ["GATT report — \(connectedName ?? "Unnamed device")", "Generated: \(Date())", ""]
        for service in services {
            let name = service.knownName.map { " (\($0))" } ?? ""
            lines.append("Service \(service.uuid)\(name)\(service.isPrimary ? "" : " [secondary]")")
            for characteristic in service.characteristics {
                let name = characteristic.knownName.map { " (\($0))" } ?? ""
                lines.append("  Characteristic \(characteristic.uuid)\(name)")
                lines.append("    Properties: \(characteristic.propertyNames.joined(separator: ", "))")
                if let value = characteristic.value {
                    let text = BLEFormat.textPreview(value).map { " \"\($0)\"" } ?? ""
                    lines.append("    Value: \(BLEFormat.hex(value))\(text)")
                }
                if let error = characteristic.lastError {
                    lines.append("    Last read error: \(error)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
