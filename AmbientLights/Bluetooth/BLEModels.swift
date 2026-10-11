import Foundation
import CoreBluetooth

/// Snapshot of one advertising peripheral, built from scan results.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var localName: String?
    var gapName: String?
    var rssi: Int?
    var serviceUUIDs: [String] = []
    var overflowServiceUUIDs: [String] = []
    var manufacturerData: Data?
    var serviceData: [String: Data] = [:]
    var txPower: Int?
    var isConnectable: Bool?
    let firstSeen: Date
    var lastSeen: Date
    var advertisementCount = 0

    init(id: UUID, firstSeen: Date) {
        self.id = id
        self.firstSeen = firstSeen
        self.lastSeen = firstSeen
    }

    /// Advertised local name first, then the GAP name CoreBluetooth cached.
    var name: String? { localName ?? gapName }
    var displayName: String { name ?? "Unnamed device" }

    /// Apple Continuity adverts (company 0x004C) rotate identifiers and are never lights.
    var isApple: Bool { manufacturerData.flatMap(BLEFormat.companyID) == 0x004C }

    /// Merges one advertisement / scan-response packet. Keys absent from this packet
    /// keep their previous value, because adverts and scan responses alternate.
    mutating func apply(advertisement ad: [String: Any], peripheralName: String?, rssi: Int, at date: Date) {
        if let local = ad[CBAdvertisementDataLocalNameKey] as? String, !local.isEmpty {
            localName = local
        }
        if let name = peripheralName, !name.isEmpty {
            gapName = name
        }
        if let uuids = ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            serviceUUIDs = Self.merged(serviceUUIDs, uuids.map(\.uuidString))
        }
        if let uuids = ad[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] {
            overflowServiceUUIDs = Self.merged(overflowServiceUUIDs, uuids.map(\.uuidString))
        }
        if let data = ad[CBAdvertisementDataManufacturerDataKey] as? Data {
            manufacturerData = data
        }
        if let serviceData = ad[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, data) in serviceData { self.serviceData[uuid.uuidString] = data }
        }
        if let tx = ad[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
            txPower = tx.intValue
        }
        if let connectable = ad[CBAdvertisementDataIsConnectable] as? NSNumber {
            isConnectable = connectable.boolValue
        }
        // 127 means "RSSI unavailable".
        if rssi != 127 { self.rssi = rssi }
        lastSeen = date
        advertisementCount += 1
    }

    private static func merged(_ existing: [String], _ new: [String]) -> [String] {
        var result = existing
        for uuid in new where !result.contains(uuid) { result.append(uuid) }
        return result
    }
}

enum ConnectionState: Equatable {
    case idle
    case connecting(UUID)
    case discovering(UUID)
    case connected(UUID)
    case disconnecting(UUID)
    case failed(UUID?, String)

    var peripheralID: UUID? {
        switch self {
        case .idle: return nil
        case .connecting(let id), .discovering(let id), .connected(let id), .disconnecting(let id): return id
        case .failed(let id, _): return id
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .discovering, .connected, .disconnecting: return true
        case .idle, .failed: return false
        }
    }

    var label: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .discovering: return "Discovering services…"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting…"
        case .failed(_, let message): return "Failed: \(message)"
        }
    }
}

struct CharacteristicInfo: Identifiable, Equatable {
    let id: Int
    let uuid: String
    let knownName: String?
    let properties: CBCharacteristicProperties
    var value: Data?
    var lastReadAt: Date?
    var lastError: String?
    var isReading = false

    var isReadable: Bool { properties.contains(.read) }
    var propertyNames: [String] { BLEFormat.propertyNames(properties) }
}

struct ServiceInfo: Identifiable, Equatable {
    let id: Int
    let uuid: String
    let knownName: String?
    let isPrimary: Bool
    var characteristicsDiscovered: Bool
    var characteristics: [CharacteristicInfo]
}
