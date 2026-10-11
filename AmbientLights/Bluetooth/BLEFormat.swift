import Foundation
import CoreBluetooth

/// Pure formatting helpers. No Bluetooth side effects.
enum BLEFormat {
    static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "Unknown"
        case .resetting: return "Resetting"
        case .unsupported: return "Unsupported"
        case .unauthorized: return "Permission denied"
        case .poweredOff: return "Off"
        case .poweredOn: return "On"
        @unknown default: return "Unrecognised (\(state.rawValue))"
        }
    }

    static func describe(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .notDetermined: return "Not determined"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .allowedAlways: return "Allowed"
        @unknown default: return "Unrecognised (\(authorization.rawValue))"
        }
    }

    /// Name CoreBluetooth knows for a standard UUID (e.g. "Battery Level"), else nil.
    static func knownName(for uuid: CBUUID) -> String? {
        let description = uuid.description
        return description == uuid.uuidString ? nil : description
    }

    static func propertyNames(_ properties: CBCharacteristicProperties) -> [String] {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("write w/o response") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { names.append("signed write") }
        if properties.contains(.extendedProperties) { names.append("extended") }
        if properties.contains(.notifyEncryptionRequired) { names.append("notify (encrypted)") }
        if properties.contains(.indicateEncryptionRequired) { names.append("indicate (encrypted)") }
        return names
    }

    static func hex(_ data: Data, limit: Int = 128) -> String {
        guard !data.isEmpty else { return "(empty)" }
        let bytes = data.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > limit ? bytes + " … (+\(data.count - limit) bytes)" : bytes
    }

    /// UTF-8 text if the bytes look like printable text, else nil.
    static func textPreview(_ data: Data) -> String? {
        guard !data.isEmpty, let string = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard !trimmed.isEmpty else { return nil }
        let printable = trimmed.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\t"
        }
        return printable ? trimmed : nil
    }

    /// Bluetooth SIG company identifiers commonly seen nearby. Unknown IDs are shown
    /// raw; cheap LED controllers often use unregistered values.
    private static let companies: [UInt16: String] = [
        0x0006: "Microsoft",
        0x000D: "Texas Instruments",
        0x004C: "Apple",
        0x0059: "Nordic Semiconductor",
        0x0075: "Samsung",
        0x0087: "Garmin",
        0x00E0: "Google",
        0x0171: "Amazon",
        0x02E5: "Espressif",
    ]

    static func companyID(of manufacturerData: Data) -> UInt16? {
        guard manufacturerData.count >= 2 else { return nil }
        let bytes = [UInt8](manufacturerData.prefix(2))
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    static func manufacturerSummary(_ data: Data) -> String {
        guard let id = companyID(of: data) else { return hex(data) }
        let company = companies[id].map { " \($0)" } ?? ""
        return String(format: "Company 0x%04X%@ · ", id, company) + hex(data)
    }

    static func signalDescription(_ rssi: Int?) -> String {
        guard let rssi else { return "—" }
        return "\(rssi) dBm"
    }

    /// 0–4 bars.
    static func signalBars(_ rssi: Int?) -> Int {
        guard let rssi else { return 0 }
        if rssi >= -60 { return 4 }
        if rssi >= -70 { return 3 }
        if rssi >= -80 { return 2 }
        if rssi >= -90 { return 1 }
        return 0
    }

    static func hint(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == CBErrorDomain, let code = CBError.Code(rawValue: nsError.code) {
            switch code {
            case .connectionTimeout:
                return "Device did not respond. Move closer and make sure no phone or other app is connected to it."
            case .peerRemovedPairingInformation:
                return "Pairing info mismatch. Remove the device in System Settings → Bluetooth and retry."
            case .encryptionTimedOut:
                return "Encryption timed out. The device may require pairing."
            case .connectionLimitReached:
                return "Device accepts no more connections. Disconnect it from other phones/apps."
            case .peripheralDisconnected:
                return "Device closed the connection."
            default:
                break
            }
        }
        if nsError.domain == CBATTErrorDomain, let code = CBATTError.Code(rawValue: nsError.code) {
            switch code {
            case .readNotPermitted: return "Device does not allow reading this characteristic."
            case .insufficientAuthentication, .insufficientEncryption:
                return "Characteristic requires pairing/encryption."
            default: break
            }
        }
        return ""
    }

    static func describe(_ error: Error) -> String {
        let hint = hint(for: error)
        let nsError = error as NSError
        let base = "\(error.localizedDescription) [\(nsError.domain) \(nsError.code)]"
        return hint.isEmpty ? base : "\(base) — \(hint)"
    }
}
