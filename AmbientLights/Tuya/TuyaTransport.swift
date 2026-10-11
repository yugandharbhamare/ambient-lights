import Foundation
import Network

/// One short-lived TCP connection to a light. Callbacks run on a private queue;
/// the async API resumes each continuation exactly once.
final class TuyaTransport: @unchecked Sendable {
    enum TransportError: LocalizedError {
        case timeout(String)
        case unreachable(String)
        case closed

        var errorDescription: String? {
            switch self {
            case .timeout(let phase): return "Timed out while \(phase)."
            case .unreachable(let detail): return "Light unreachable: \(detail)"
            case .closed: return "The light closed the connection."
            }
        }
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "local.ambientlights.tuya.tcp")

    init(host: String, port: UInt16 = 6668) {
        let parameters = NWParameters.tcp
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 4
        }
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 6668,
            using: parameters
        )
    }

    func open(timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate(continuation)
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    gate.resume(with: .success(()))
                case .failed(let error):
                    gate.resume(with: .failure(TransportError.unreachable(error.localizedDescription)))
                case .waiting(let error):
                    // .waiting means no route / refused; don't wait for the network to change.
                    gate.resume(with: .failure(TransportError.unreachable(error.localizedDescription)))
                    connection.cancel()
                case .cancelled:
                    gate.resume(with: .failure(TransportError.closed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [connection] in
                if gate.resume(with: .failure(TransportError.timeout("connecting"))) {
                    connection.cancel()
                }
            }
        }
        connection.stateUpdateHandler = nil
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: TransportError.unreachable(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Next chunk of bytes, or a timeout error.
    func receive(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let gate = ResumeGate(continuation)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                if let error {
                    gate.resume(with: .failure(TransportError.unreachable(error.localizedDescription)))
                } else if let data, !data.isEmpty {
                    gate.resume(with: .success(data))
                } else if isComplete {
                    gate.resume(with: .failure(TransportError.closed))
                } else {
                    gate.resume(with: .success(Data()))
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                gate.resume(with: .failure(TransportError.timeout("waiting for the light")))
            }
        }
    }

    func close() {
        connection.cancel()
    }
}

/// Resumes a continuation at most once, whichever callback gets there first.
private final class ResumeGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    /// Returns true if this call resumed the continuation.
    @discardableResult
    func resume(with result: Result<T, Error>) -> Bool {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        return continuation != nil
    }
}
