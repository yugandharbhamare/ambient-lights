import Foundation

struct LightCredentials: Equatable, Sendable {
    var deviceID: String
    var host: String
    var localKey: String

    var isComplete: Bool {
        !deviceID.isEmpty && !host.isEmpty && localKey.utf8.count == 16
    }
}

/// Talks to one light with Tuya protocol 3.3. Opens a connection for each request
/// and closes it straight away: these lights accept a single local connection,
/// and holding it locks out the phone app (and can wedge the light's TCP service).
/// The actor serialises requests so only one connection is ever open.
actor TuyaClient {
    enum ClientError: LocalizedError {
        case notConfigured
        case deviceRejected(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Light not set up. Add the device ID, IP and local key."
            case .deviceRejected(let message): return "Light rejected the request: \(message)"
            }
        }
    }

    private var credentials: LightCredentials?
    private var sequence: UInt32 = 1
    private let log: LogStore

    static let connectTimeout: TimeInterval = 4
    static let replyTimeout: TimeInterval = 3

    init(log: LogStore, credentials: LightCredentials? = nil) {
        self.log = log
        self.credentials = credentials
    }

    func configure(_ credentials: LightCredentials?) {
        self.credentials = credentials
    }

    /// Reads every data point (DP_QUERY). Changes nothing on the light.
    func status() async throws -> [String: DPValue] {
        let credentials = try requireCredentials()
        let payload = TuyaCodec.queryPayload(deviceID: credentials.deviceID, timestamp: Self.now())
        return try await exchange(.dpQuery, payload: payload, credentials: credentials, requireDPS: true)
    }

    /// Writes data points (CONTROL) and returns the DPs the light reports back.
    func set(_ dps: [String: DPValue]) async throws -> [String: DPValue] {
        let credentials = try requireCredentials()
        let payload = TuyaCodec.controlPayload(deviceID: credentials.deviceID, timestamp: Self.now(), dps: dps)
        return try await exchange(.control, payload: payload, credentials: credentials, requireDPS: false)
    }

    // MARK: - Private

    private func requireCredentials() throws -> LightCredentials {
        guard let credentials, credentials.isComplete else { throw ClientError.notConfigured }
        return credentials
    }

    private static func now() -> Int { Int(Date().timeIntervalSince1970) }

    private func exchange(
        _ command: TuyaCodec.Command,
        payload: Data,
        credentials: LightCredentials,
        requireDPS: Bool
    ) async throws -> [String: DPValue] {
        let key = Data(credentials.localKey.utf8)
        let sequence = nextSequence()
        let frame = try TuyaCodec.encodeFrame(command: command, sequence: sequence, payload: payload, key: key)
        let transport = TuyaTransport(host: credentials.host)
        defer { transport.close() }

        let started = Date()
        try await transport.open(timeout: Self.connectTimeout)
        try await transport.send(frame)

        var buffer = Data()
        var acknowledged = false
        var result: [String: DPValue] = [:]
        var deadline = Date().addingTimeInterval(Self.replyTimeout)

        // A CONTROL is answered by an empty ack (cmd 7) and then a status push (cmd 8)
        // with the changed DPs; a DP_QUERY by one frame carrying all DPs.
        while Date() < deadline {
            let chunk: Data
            do {
                chunk = try await transport.receive(timeout: max(0.1, deadline.timeIntervalSinceNow))
            } catch TuyaTransport.TransportError.timeout(_) where acknowledged || !result.isEmpty {
                break
            }
            buffer.append(chunk)
            for reply in try TuyaCodec.extractFrames(from: &buffer) {
                if let code = reply.returnCode, code != 0 {
                    throw ClientError.deviceRejected("return code \(code)")
                }
                guard let json = try TuyaCodec.decodePayload(reply.payload, key: key) else {
                    // Empty ack: give the status push a short grace period, not the full timeout.
                    if !acknowledged { deadline = min(deadline, Date().addingTimeInterval(1)) }
                    acknowledged = true
                    continue
                }
                if let text = String(data: json, encoding: .utf8), text.contains("data unvalid") {
                    throw ClientError.deviceRejected("data unvalid (unsupported request format)")
                }
                result.merge(try TuyaCodec.parseDPS(json)) { _, new in new }
                acknowledged = true
            }
            if !result.isEmpty, !requireDPS || command == .dpQuery { break }
        }

        guard acknowledged || !result.isEmpty else {
            throw TuyaTransport.TransportError.timeout("waiting for the light")
        }
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        log.debug(.light, "\(command == .dpQuery ? "Status" : "Set") ok in \(elapsed) ms → \(TuyaCodec.encode(result))")
        return result
    }

    private func nextSequence() -> UInt32 {
        defer { sequence &+= 1 }
        return sequence
    }
}
