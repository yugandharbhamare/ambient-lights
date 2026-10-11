import Foundation
import os

/// In-memory diagnostics log. Safe to call `add` from any thread; entries are
/// appended on the main thread for SwiftUI.
///
/// Messages may embed peripheral identifiers and device names as markers
/// (see `LogStore.peripheral(_:)` / `LogStore.name(_:for:)`). The UI renders them
/// in full; the sanitized export replaces them with stable aliases.
final class LogStore: ObservableObject, @unchecked Sendable {
    enum Level: String {
        case debug, info, warning, error

        var symbol: String {
            switch self {
            case .debug: return "ant"
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    enum Category: String {
        case system, scan, connection, gatt, read, light
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let category: Category
        let rawMessage: String
    }

    @Published private(set) var entries: [Entry] = []

    /// Devices the user connected to; their names survive sanitization because
    /// they are the lights we are trying to identify.
    @Published private(set) var trustedPeripherals: Set<UUID> = []

    private let maxEntries = 3000
    private let osLog = Logger(subsystem: "local.ambientlights", category: "bluetooth")

    func add(_ level: Level, _ category: Category, _ message: String) {
        let entry = Entry(date: Date(), level: level, category: category, rawMessage: message)
        let rendered = Self.render(message, sanitizer: nil)
        switch level {
        case .debug: osLog.debug("[\(category.rawValue)] \(rendered, privacy: .private)")
        case .info: osLog.info("[\(category.rawValue)] \(rendered, privacy: .private)")
        case .warning: osLog.warning("[\(category.rawValue)] \(rendered, privacy: .private)")
        case .error: osLog.error("[\(category.rawValue)] \(rendered, privacy: .private)")
        }
        DispatchQueue.main.async {
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    func debug(_ category: Category, _ message: String) { add(.debug, category, message) }
    func info(_ category: Category, _ message: String) { add(.info, category, message) }
    func warning(_ category: Category, _ message: String) { add(.warning, category, message) }
    func error(_ category: Category, _ message: String) { add(.error, category, message) }

    func markTrusted(_ id: UUID) {
        DispatchQueue.main.async { self.trustedPeripherals.insert(id) }
    }

    func clear() {
        DispatchQueue.main.async { self.entries.removeAll() }
    }

    // MARK: - Markers

    private static let open: Character = "\u{1}"
    private static let close: Character = "\u{2}"
    private static let separator: Character = "\u{1F}"

    /// Marker for a peripheral identifier.
    static func peripheral(_ id: UUID) -> String {
        "\(open)P\(separator)\(id.uuidString)\(close)"
    }

    /// Marker for a device name belonging to a peripheral.
    static func name(_ name: String?, for id: UUID) -> String {
        let cleaned = (name ?? "").filter { $0 != open && $0 != close && $0 != separator }
        return "\(open)N\(separator)\(id.uuidString)\(separator)\(cleaned)\(close)"
    }

    // MARK: - Rendering

    /// Assigns stable aliases while rendering one export.
    final class Sanitizer {
        private var peripheralAliases: [String: String] = [:]
        private var nameAliases: [String: String] = [:]
        private let trusted: Set<String>

        init(trusted: Set<UUID>) {
            self.trusted = Set(trusted.map(\.uuidString))
        }

        func peripheral(_ uuid: String) -> String {
            if let alias = peripheralAliases[uuid] { return alias }
            let alias = "peripheral-\(peripheralAliases.count + 1)"
            peripheralAliases[uuid] = alias
            return alias
        }

        func name(_ name: String, peripheral uuid: String) -> String {
            if name.isEmpty { return "(unnamed)" }
            if trusted.contains(uuid) { return "\"\(name)\"" }
            if let alias = nameAliases[uuid] { return alias }
            let alias = "<name-\(nameAliases.count + 1)>"
            nameAliases[uuid] = alias
            return alias
        }
    }

    static func render(_ raw: String, sanitizer: Sanitizer?) -> String {
        var output = ""
        var rest = Substring(raw)
        while let start = rest.firstIndex(of: open) {
            output += rest[..<start]
            guard let end = rest[start...].firstIndex(of: close) else {
                rest = rest[rest.index(after: start)...]
                continue
            }
            let body = rest[rest.index(after: start)..<end]
            let parts = body.split(separator: separator, omittingEmptySubsequences: false).map(String.init)
            output += resolve(parts, sanitizer: sanitizer)
            rest = rest[rest.index(after: end)...]
        }
        output += rest
        return output
    }

    private static func resolve(_ parts: [String], sanitizer: Sanitizer?) -> String {
        switch (parts.first, parts.count) {
        case ("P", 2):
            return sanitizer?.peripheral(parts[1]) ?? parts[1]
        case ("N", 3):
            if let sanitizer { return sanitizer.name(parts[2], peripheral: parts[1]) }
            return parts[2].isEmpty ? "(unnamed)" : "\"\(parts[2])\""
        default:
            return ""
        }
    }

    // MARK: - Export

    private static let exportFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Main thread only (reads published state).
    func export(sanitized: Bool, header: String) -> String {
        let sanitizer = sanitized ? Sanitizer(trusted: trustedPeripherals) : nil
        var lines = [header, ""]
        for entry in entries {
            let time = Self.exportFormatter.string(from: entry.date)
            let message = Self.render(entry.rawMessage, sanitizer: sanitizer)
            lines.append("\(time) \(entry.level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)) [\(entry.category.rawValue)] \(message)")
        }
        if sanitized {
            lines.append("")
            lines.append("Sanitized: peripheral identifiers replaced with aliases; names of devices you did not connect to replaced with <name-N>.")
        }
        return lines.joined(separator: "\n")
    }
}
