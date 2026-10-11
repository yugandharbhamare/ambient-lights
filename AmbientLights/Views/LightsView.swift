import SwiftUI

struct LightsView: View {
    @EnvironmentObject private var light: LightController
    @Environment(\.openWindow) private var openWindow
    @State private var showSetup = false

    /// Both modes use the same height so the popover never needs to resize.
    private static let modeAreaHeight: CGFloat = 192

    var body: some View {
        Group {
            if !light.isConfigured || showSetup {
                LightSetupView(onDone: { withAnimation { showSetup = false } }, canCancel: light.isConfigured)
            } else {
                content
            }
        }
        .background(ambientBackground)
    }

    private var state: LightState { light.state }
    private var emitted: Color { LightPalette.emitted(state) }
    private var level: Int { LightPalette.level(state) }
    private var isLive: Bool { light.hasState && state.isOn }

    // MARK: - Layout

    private var content: some View {
        VStack(spacing: 12) {
            header
            if case .error(let message) = light.status {
                errorBanner(message)
            } else {
                hero
            }
            if light.hasState {
                controls
                    .disabled(!state.isOn)
                    .opacity(state.isOn ? 1 : 0.45)
                    .animation(.easeInOut(duration: 0.25), value: state.isOn)
            } else {
                loading
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var ambientBackground: some View {
        ZStack {
            Color.clear
            if isLive {
                RadialGradient(colors: [emitted.opacity(0.08 + 0.14 * LightPalette.fraction(level)), .clear],
                               center: UnitPoint(x: 0.5, y: 0.2), startRadius: 0, endRadius: 320)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: isLive)
        .animation(.easeOut(duration: 0.3), value: state.colour)
        .animation(.easeOut(duration: 0.3), value: state.temperature)
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(light.name ?? "Light")
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    statusDot
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Toggle("Power", isOn: Binding(get: { state.isOn }, set: { on in
                withAnimation(.easeInOut(duration: 0.3)) { light.setPower(on) }
            }))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!light.hasState)
            menu
        }
    }

    private var menu: some View {
        Menu {
            Button("Refresh") { light.refresh() }
            Button("Find on Network") { light.discover() }
            Button("Light Settings…") { withAnimation { showSetup = true } }
            Divider()
            Button("Bluetooth Tools & Logs…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "bluetooth-tools")
            }
            Divider()
            Button("Quit Ambient Lights") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.07)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var statusDot: some View {
        switch light.status {
        case .working:
            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 8, height: 8)
        case .error:
            Circle().fill(.orange).frame(width: 6, height: 6)
        case .idle, .notConfigured:
            Circle().fill(light.hasState ? Color.green : Color.secondary).frame(width: 6, height: 6)
        }
    }

    private var statusText: String {
        if light.isDiscovering { return "Searching the network…" }
        switch light.status {
        case .error: return "Not responding"
        case .working where !light.hasState: return "Connecting…"
        default: break
        }
        guard light.hasState else { return "Not connected" }
        guard state.isOn else { return "Off" }
        let mode = state.mode == .white ? "White" : "Colour"
        return "\(mode) · \(percent(level))"
    }

    private var hero: some View {
        SkyLightPreview(colour: emitted, intensity: LightPalette.fraction(level), isOn: isLive)
            .contentShape(Rectangle())
            .onTapGesture {
                guard light.hasState else { return }
                withAnimation(.easeInOut(duration: 0.3)) { light.setPower(!state.isOn) }
            }
            .help(state.isOn ? "Click to turn off" : "Click to turn on")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(state.isOn ? "Turn light off" : "Turn light on")
    }

    private var loading: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Reaching your light…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            Text(message).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry") { light.refresh() }.controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.12)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 14) {
            FillSlider(
                value: LightPalette.fraction(level),
                fill: LinearGradient(colors: [emitted.opacity(0.75), emitted], startPoint: .leading, endPoint: .trailing),
                symbol: "sun.max.fill",
                label: percent(level),
                onChange: { light.setBrightness(LightPalette.level(fraction: $0)) }
            )

            PillPicker(
                options: [(LightMode.white, "White", "sun.horizon"), (LightMode.colour, "Colour", "paintpalette")],
                selection: state.mode,
                onSelect: { mode in withAnimation(.easeInOut(duration: 0.25)) { light.setMode(mode) } }
            )

            ZStack(alignment: .top) {
                if state.mode == .white {
                    VStack(spacing: 20) {
                        GradientKnobSlider(
                            value: Double(state.temperature) / 1000,
                            colours: [LightPalette.white(temperature: 0), LightPalette.white(temperature: 500), LightPalette.white(temperature: 1000)],
                            label: warmthLabel,
                            accessibilityName: "Warmth",
                            onChange: { light.setTemperature(Int(($0 * 1000).rounded())) }
                        )
                        whitePresets
                    }
                    .padding(.top, 4)
                    .transition(.opacity)
                } else {
                    VStack(spacing: 12) {
                        ColourWheel(hue: state.colour.hue, saturation: state.colour.saturation) { hue, saturation in
                            light.setColour(hue: hue, saturation: saturation)
                        }
                        swatches
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .frame(height: Self.modeAreaHeight, alignment: .top)

            scenes
        }
    }

    private var whitePresets: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Whites")
            HStack(spacing: 0) {
                ForEach(Self.whites, id: \.temperature) { white in
                    SceneChip(title: white.name,
                              colour: LightPalette.white(temperature: white.temperature),
                              isActive: state.mode == .white && abs(state.temperature - white.temperature) < 15) {
                        withAnimation(.easeOut(duration: 0.2)) { light.setTemperature(white.temperature) }
                    }
                }
            }
        }
    }

    private static let whites: [(name: String, temperature: Int)] = [
        ("Candle", 0), ("Warm", 250), ("Soft", 500), ("Neutral", 750), ("Daylight", 1000),
    ]

    private var swatches: some View {
        HStack(spacing: 0) {
            ForEach(Self.swatchHues, id: \.self) { hue in
                let selected = abs(state.colour.hue - hue) < 6 && state.colour.saturation > 900
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { light.setColour(hue: hue, saturation: 1000) }
                } label: {
                    Circle()
                        .fill(Color(hue: Double(hue) / 360, saturation: 1, brightness: 1))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.9 : 0), lineWidth: 2).padding(-3))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var scenes: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Scenes")
            HStack(spacing: 0) {
                ForEach(Self.scenes) { scene in
                    SceneChip(title: scene.name, colour: scene.previewColour, isActive: scene.matches(state)) {
                        withAnimation(.easeInOut(duration: 0.3)) { scene.apply(to: light) }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var warmthLabel: String {
        switch state.temperature {
        case ..<250: return "Warm"
        case ..<600: return "Soft"
        case ..<850: return "Neutral"
        default: return "Cool"
        }
    }

    private func percent(_ level: Int) -> String {
        "\(Int((LightPalette.fraction(level) * 100).rounded()))%"
    }

    private static let swatchHues = [0, 25, 50, 120, 175, 210, 260, 300]

    private struct Scene: Identifiable {
        enum Setting { case white(brightness: Int, temperature: Int), colour(HSV) }
        let name: String
        let setting: Setting
        var id: String { name }

        var previewColour: Color {
            switch setting {
            case .white(_, let temperature): return LightPalette.white(temperature: temperature)
            case .colour(let hsv): return LightPalette.colour(hsv)
            }
        }

        func matches(_ state: LightState) -> Bool {
            guard state.isOn else { return false }
            switch setting {
            case .white(let brightness, let temperature):
                return state.mode == .white && abs(state.brightness - brightness) < 15 && abs(state.temperature - temperature) < 15
            case .colour(let hsv):
                return state.mode == .colour && abs(state.colour.hue - hsv.hue) < 3
                    && abs(state.colour.saturation - hsv.saturation) < 15 && abs(state.colour.value - hsv.value) < 15
            }
        }

        @MainActor func apply(to light: LightController) {
            switch setting {
            case .white(let brightness, let temperature): light.setWhite(brightness: brightness, temperature: temperature)
            case .colour(let hsv): light.setColour(hsv)
            }
        }
    }

    private static let scenes: [Scene] = [
        Scene(name: "Relax", setting: .white(brightness: 350, temperature: 0)),
        Scene(name: "Read", setting: .white(brightness: 1000, temperature: 450)),
        Scene(name: "Focus", setting: .white(brightness: 1000, temperature: 1000)),
        Scene(name: "Sunset", setting: .colour(HSV(hue: 18, saturation: 900, value: 800))),
        Scene(name: "Ocean", setting: .colour(HSV(hue: 205, saturation: 850, value: 900))),
        Scene(name: "Neon", setting: .colour(HSV(hue: 300, saturation: 1000, value: 1000))),
    ]
}
