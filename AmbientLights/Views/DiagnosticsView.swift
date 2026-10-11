import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    @EnvironmentObject private var log: LogStore
    @State private var showDebug = true
    @State private var copiedLabel: String?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(copiedLabel == "sanitized" ? "Copied" : "Copy Sanitized Logs") {
                    copy(sanitized: true)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Peripheral IDs replaced with aliases; names of devices you never connected to are hidden.")
                Button(copiedLabel == "raw" ? "Copied" : "Copy Raw") {
                    copy(sanitized: false)
                }
                .controlSize(.small)
                Spacer()
                Toggle("Debug", isOn: $showDebug)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                Button {
                    log.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("Clear log")
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(visibleEntries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: log.entries.count) { _ in scrollToEnd(proxy) }
            }
        }
    }

    private var visibleEntries: [LogStore.Entry] {
        showDebug ? log.entries : log.entries.filter { $0.level != .debug }
    }

    private func row(_ entry: LogStore.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: entry.level.symbol)
                .font(.caption2)
                .foregroundStyle(color(for: entry.level))
            Text("[\(entry.category.rawValue)] \(LogStore.render(entry.rawMessage, sanitizer: nil))")
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func color(for level: LogStore.Level) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = visibleEntries.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private func copy(sanitized: Bool) {
        let text = log.export(sanitized: sanitized, header: bluetooth.diagnosticsHeader())
        BluetoothManager.copyToPasteboard(text)
        let label = sanitized ? "sanitized" : "raw"
        copiedLabel = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedLabel == label { copiedLabel = nil }
        }
    }
}
