import CommonCrypto
import CryptoKit
import Foundation

/// Tuya local protocol 3.3 framing and encryption.
///
/// Mirrors tinytuya 1.20 (`core/message_helper.py`, `core/XenonDevice.py`):
/// 55AA frames, CRC32, AES-128-ECB with PKCS7 padding keyed by the device's
/// local key, and a "3.3" + 12 zero-byte header on every command except queries.
/// Pure functions only; networking lives in `TuyaTransport`.
enum TuyaCodec {
    enum Command: UInt32 {
        case control = 0x07
        case status = 0x08
        case heartBeat = 0x09
        case dpQuery = 0x0A
        case controlNew = 0x0D
        case dpQueryNew = 0x10
    }

    enum CodecError: LocalizedError, Equatable {
        case invalidKey
        case crypto(Int32)
        case badFrame(String)
        case badPayload(String)

        var errorDescription: String? {
            switch self {
            case .invalidKey: return "Local key must be exactly 16 characters."
            case .crypto(let status): return "Encryption error (\(status))."
            case .badFrame(let detail): return "Malformed frame: \(detail)"
            case .badPayload(let detail): return "Unreadable payload: \(detail)"
            }
        }
    }

    static let prefix: UInt32 = 0x0000_55AA
    static let suffix: UInt32 = 0x0000_AA55
    static let headerLength = 16
    static let versionHeader = Data("3.3".utf8) + Data(count: 12)

    /// Key used for the devices' UDP discovery broadcasts.
    static let udpKey = Data(Insecure.MD5.hash(data: Data("yGAdlopoPVldABfn".utf8)))

    // MARK: - Payloads

    /// JSON for a status query. Field order and the absence of spaces match tinytuya;
    /// devices reject payloads containing spaces.
    static func queryPayload(deviceID: String, timestamp: Int) -> Data {
        Data(#"{"gwId":"\#(deviceID)","devId":"\#(deviceID)","uid":"\#(deviceID)","t":"\#(timestamp)"}"#.utf8)
    }

    static func controlPayload(deviceID: String, timestamp: Int, dps: [String: DPValue]) -> Data {
        Data(#"{"devId":"\#(deviceID)","uid":"\#(deviceID)","t":"\#(timestamp)","dps":\#(encode(dps))}"#.utf8)
    }

    /// Compact JSON object with keys sorted numerically.
    static func encode(_ dps: [String: DPValue]) -> String {
        let fields = dps.keys
            .sorted { (Int($0) ?? .max, $0) < (Int($1) ?? .max, $1) }
            .map { key in "\"\(key)\":\(dps[key]!.json)" }
        return "{\(fields.joined(separator: ","))}"
    }

    // MARK: - Frames

    static func encodeFrame(command: Command, sequence: UInt32, payload: Data, key: Data) throws -> Data {
        var body = try aes(payload, key: key, encrypt: true)
        if command != .dpQuery, command != .dpQueryNew, command != .heartBeat {
            body = versionHeader + body
        }
        var frame = Data()
        frame.appendBigEndian(prefix)
        frame.appendBigEndian(sequence)
        frame.appendBigEndian(command.rawValue)
        frame.appendBigEndian(UInt32(body.count + 8))
        frame.append(body)
        frame.appendBigEndian(crc32(frame))
        frame.appendBigEndian(suffix)
        return frame
    }

    struct Frame: Equatable {
        let sequence: UInt32
        let command: UInt32
        let returnCode: UInt32?
        /// Payload after the return code and before the CRC; still encrypted.
        let payload: Data
    }

    /// Removes and returns every complete frame at the start of `buffer`.
    /// Bytes before a valid prefix are discarded.
    static func extractFrames(from buffer: inout Data) throws -> [Frame] {
        var frames: [Frame] = []
        while true {
            guard let start = buffer.firstRange(of: Data([0x00, 0x00, 0x55, 0xAA])) else {
                // Keep a possible partial prefix.
                if buffer.count > 3 { buffer = buffer.suffix(3) }
                return frames
            }
            if start.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start.lowerBound) }
            guard buffer.count >= headerLength else { return frames }

            let bytes = [UInt8](buffer)
            let sequence = UInt32(bigEndianBytes: bytes[4..<8])
            let command = UInt32(bigEndianBytes: bytes[8..<12])
            let length = Int(UInt32(bigEndianBytes: bytes[12..<16]))
            guard length >= 8, length < 0x1_0000 else {
                throw CodecError.badFrame("length \(length)")
            }
            let total = headerLength + length
            guard bytes.count >= total else { return frames }

            let crcStart = total - 8
            let expectedCRC = UInt32(bigEndianBytes: bytes[crcStart..<(crcStart + 4)])
            let frameSuffix = UInt32(bigEndianBytes: bytes[(crcStart + 4)..<total])
            guard frameSuffix == suffix else { throw CodecError.badFrame("suffix") }
            guard crc32(Data(bytes[0..<crcStart])) == expectedCRC else { throw CodecError.badFrame("CRC mismatch") }

            var payload = Data(bytes[headerLength..<crcStart])
            var returnCode: UInt32?
            // Device-to-client frames start with a 4-byte return code (normally 0).
            if payload.count >= 4, payload.prefix(3) == Data([0, 0, 0]) {
                returnCode = UInt32(bigEndianBytes: [UInt8](payload.prefix(4))[0..<4])
                payload = payload.dropFirst(4)
            }
            frames.append(Frame(sequence: sequence, command: command, returnCode: returnCode, payload: Data(payload)))
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + total))
        }
    }

    /// Decrypts a received payload. Returns nil for empty acknowledgements.
    static func decodePayload(_ payload: Data, key: Data) throws -> Data? {
        var body = payload
        if body.starts(with: Data("3.3".utf8)) {
            body = body.dropFirst(versionHeader.count)
        }
        guard !body.isEmpty else { return nil }
        if body.first == UInt8(ascii: "{") { return Data(body) }
        guard body.count % 16 == 0 else { throw CodecError.badPayload("length \(body.count)") }
        return try aes(Data(body), key: key, encrypt: false)
    }

    /// Parses `{"dps": {...}}` from decrypted JSON.
    static func parseDPS(_ json: Data) throws -> [String: DPValue] {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw CodecError.badPayload("not a JSON object")
        }
        let dps = (object["dps"] as? [String: Any]) ?? ((object["data"] as? [String: Any])?["dps"] as? [String: Any]) ?? [:]
        return dps.compactMapValues(DPValue.init(any:))
    }

    // MARK: - Primitives

    static func aes(_ data: Data, key: Data, encrypt: Bool) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw CodecError.invalidKey }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                        keyBytes.baseAddress, key.count,
                        nil,
                        input.baseAddress, data.count,
                        out.baseAddress, outputCapacity,
                        &written
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CodecError.crypto(status) }
        return output.prefix(written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1) }
        return value
    }

    /// IEEE CRC-32, identical to Python's `binascii.crc32`.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

/// A Tuya data-point value. Lights only use these three JSON types.
enum DPValue: Equatable, Sendable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case string(String)

    init?(any: Any) {
        if let number = any as? NSNumber {
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .int(number.intValue)
        } else if let string = any as? String {
            self = .string(string)
        } else {
            return nil
        }
    }

    var json: String {
        switch self {
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .string(let value):
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
    }

    var description: String { json }

    var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
    var intValue: Int? { if case .int(let value) = self { return value }; return nil }
    var stringValue: String? { if case .string(let value) = self { return value }; return nil }
}

extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}

extension UInt32 {
    init(bigEndianBytes bytes: ArraySlice<UInt8>) {
        self = bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
