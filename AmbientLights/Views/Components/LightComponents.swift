import AppKit
import SwiftUI

// MARK: - Colour helpers

enum LightPalette {
    /// 0 = warm (≈2700K), 1000 = cool (≈6500K).
    static func white(temperature: Int) -> Color {
        let t = Double(temperature.clamped(0...1000)) / 1000
        let warm = (r: 1.0, g: 0.70, b: 0.40)
        let cool = (r: 0.82, g: 0.90, b: 1.0)
        return Color(red: warm.r + (cool.r - warm.r) * t,
                     green: warm.g + (cool.g - warm.g) * t,
                     blue: warm.b + (cool.b - warm.b) * t)
    }

    static func colour(_ hsv: HSV) -> Color {
        Color(hue: Double(hsv.hue) / 360, saturation: Double(hsv.saturation) / 1000, brightness: 1)
    }

    /// What the light is emitting, ignoring brightness.
    static func emitted(_ state: LightState) -> Color {
        state.mode == .white ? white(temperature: state.temperature) : colour(state.colour)
    }

    static func level(_ state: LightState) -> Int {
        state.mode == .white ? state.brightness : state.colour.value
    }

    /// 10...1000 → 0...1
    static func fraction(_ level: Int) -> Double {
        Double(level.clamped(10...1000) - 10) / 990
    }

    static func level(fraction: Double) -> Int {
        Int((10 + fraction.clamped(0...1) * 990).rounded())
    }
}

extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

struct SectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

enum Haptics {
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: - SkyLight preview

/// The GoHigh SkyLight set as sold: two upright bars (black housing, frosted
/// front diffuser) on round disc bases, typically either side of a monitor.
struct SkyLightPreview: View {
    let colour: Color
    let intensity: Double   // 0...1
    let isOn: Bool

    var body: some View {
        let glow = isOn ? 0.3 + intensity * 0.7 : 0
        ZStack {
            // Light washing the wall behind the desk.
            HStack(spacing: 120) {
                ForEach(0..<2, id: \.self) { _ in
                    Ellipse()
                        .fill(colour.opacity(0.65 * glow))
                        .frame(width: 64, height: 96)
                        .blur(radius: 26)
                }
            }
            .offset(y: -8)

            // Monitor silhouette for context.
            VStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.black.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5))
                    .frame(width: 100, height: 58)
                Rectangle().fill(Color.black.opacity(0.25)).frame(width: 5, height: 9)
                Capsule().fill(Color.black.opacity(0.25)).frame(width: 34, height: 3)
            }
            .offset(y: 6)

            HStack(spacing: 150) {
                bar
                bar
            }
            .offset(y: 4)
        }
        .frame(height: 112)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.35), value: isOn)
        .animation(.easeOut(duration: 0.2), value: intensity)
    }

    private var bar: some View {
        VStack(spacing: 0) {
            // Housing with a frosted diffuser on the front.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(white: 0.06))
                .frame(width: 18, height: 82)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isOn
                              ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.9), colour, colour.opacity(0.85)],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color(white: 0.16)))
                        .opacity(isOn ? 0.55 + 0.45 * intensity : 1)
                        .padding(3)
                )
                .shadow(color: colour.opacity(isOn ? 0.9 * (0.3 + intensity * 0.7) : 0), radius: 8)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            // Neck and round disc base.
            Rectangle().fill(Color(white: 0.08)).frame(width: 6, height: 4)
            Ellipse()
                .fill(Color(white: 0.07))
                .overlay(Ellipse().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                .frame(width: 30, height: 7)
        }
    }
}

// MARK: - Big fill slider (Control Center style)

struct FillSlider<Fill: ShapeStyle>: View {
    /// 0...1
    let value: Double
    let fill: Fill
    let symbol: String
    let label: String
    var trackHeight: CGFloat = 38
    let onChange: (Double) -> Void

    @State private var dragValue: Double?
    @State private var dragStart: Double = 0

    var body: some View {
        let shown = dragValue ?? value
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(fill)
                    .frame(width: max(trackHeight, geo.size.width * shown))
                HStack(spacing: 0) {
                    // Centred in a square the size of the minimum fill, so it stays
                    // centred in the knob-shaped fill at low values.
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.6))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: trackHeight, height: trackHeight)
                    Spacer()
                    Text(label)
                        .font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(shown > 0.88 ? Color.black.opacity(0.6) : Color.secondary)
                        .padding(.trailing, 14)
                }
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragValue == nil { dragStart = value }
                        // Relative drag (like Control Center): grab anywhere, slide to adjust.
                        let delta = gesture.translation.width / max(1, geo.size.width)
                        let next = (dragStart + delta).clamped(0...1)
                        if (next == 0 || next == 1), next != dragValue { Haptics.tick() }
                        dragValue = next
                        onChange(next)
                    }
                    .onEnded { gesture in
                        // A tap (no movement) jumps to the tapped position.
                        if abs(gesture.translation.width) < 2 {
                            let tapped = (gesture.location.x / max(1, geo.size.width)).clamped(0...1)
                            onChange(tapped)
                        }
                        withAnimation(.easeOut(duration: 0.15)) { dragValue = nil }
                    }
            )
        }
        .frame(height: trackHeight)
        .accessibilityElement()
        .accessibilityLabel(symbol == "sun.max.fill" ? "Brightness" : "Warmth")
        .accessibilityValue(label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange((value + 0.05).clamped(0...1))
            case .decrement: onChange((value - 0.05).clamped(0...1))
            @unknown default: break
            }
        }
    }
}

// MARK: - Gradient track with knob (for warmth)

struct GradientKnobSlider: View {
    /// 0...1
    let value: Double
    let colours: [Color]
    let label: String
    let accessibilityName: String
    let onChange: (Double) -> Void

    @State private var dragValue: Double?
    private let height: CGFloat = 24

    var body: some View {
        let shown = dragValue ?? value
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: accessibilityName, trailing: label)
            GeometryReader { geo in
                let inset = height / 2
                let x = inset + (geo.size.width - height) * shown
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(LinearGradient(colors: colours, startPoint: .leading, endPoint: .trailing))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    Circle()
                        .fill(.white)
                        .frame(width: dragValue == nil ? height - 6 : height, height: dragValue == nil ? height - 6 : height)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .position(x: x, y: height / 2)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragValue == nil)
                }
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { gesture in
                            let next = ((gesture.location.x - inset) / max(1, geo.size.width - height)).clamped(0...1)
                            if (next == 0 || next == 1), next != dragValue { Haptics.tick() }
                            dragValue = next
                            onChange(next)
                        }
                        .onEnded { _ in dragValue = nil }
                )
            }
            .frame(height: height)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(label)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange((value + 0.05).clamped(0...1))
            case .decrement: onChange((value - 0.05).clamped(0...1))
            @unknown default: break
            }
        }
    }
}

// MARK: - Colour wheel

/// Hue around the circle, saturation from centre (white) to edge.
struct ColourWheel: View {
    let hue: Int          // 0...360
    let saturation: Int   // 0...1000
    let onChange: (Int, Int) -> Void

    @State private var dragPoint: (hue: Int, saturation: Int)?
    private let size: CGFloat = 156

    var body: some View {
        let shownHue = dragPoint?.hue ?? hue
        let shownSat = dragPoint?.saturation ?? saturation
        let radius = size / 2
        let angle = Angle(degrees: Double(shownHue))
        let distance = radius * CGFloat(shownSat) / 1000
        let knob = CGPoint(x: radius + CGFloat(Foundation.cos(angle.radians)) * distance,
                           y: radius + CGFloat(Foundation.sin(angle.radians)) * distance)

        ZStack {
            Circle()
                .fill(AngularGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) },
                    center: .center))
            Circle()
                .fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
            Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)

            Circle()
                .fill(Color(hue: Double(shownHue) / 360, saturation: Double(shownSat) / 1000, brightness: 1))
                .frame(width: dragPoint == nil ? 24 : 30, height: dragPoint == nil ? 24 : 30)
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                .position(knob)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: dragPoint == nil)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { gesture in
                    let dx = gesture.location.x - radius
                    let dy = gesture.location.y - radius
                    var degrees = atan2(dy, dx) * 180 / .pi
                    if degrees < 0 { degrees += 360 }
                    let sat = Int((min(1, hypot(dx, dy) / radius) * 1000).rounded())
                    let value = (Int(degrees.rounded()) % 360, sat)
                    dragPoint = value
                    onChange(value.0, value.1)
                }
                .onEnded { _ in dragPoint = nil }
        )
        .accessibilityElement()
        .accessibilityLabel("Colour")
        .accessibilityValue("Hue \(hue) degrees, saturation \(saturation / 10) percent")
    }
}

// MARK: - Pill segmented control

struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String, symbol: String)]
    let selection: Value
    let onSelect: (Value) -> Void
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    onSelect(option.value)
                } label: {
                    Label(option.title, systemImage: option.symbol)
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
    }
}

// MARK: - Scene chips

struct SceneChip: View {
    let title: String
    let colour: Color
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Circle()
                    .fill(RadialGradient(colors: [.white.opacity(0.85), colour], center: .center, startRadius: 0, endRadius: 12))
                    .frame(width: 24, height: 24)
                    .shadow(color: colour.opacity(hovering || isActive ? 0.7 : 0.2), radius: hovering || isActive ? 7 : 2)
                    .overlay(Circle().strokeBorder(isActive ? Color.primary.opacity(0.8) : .clear, lineWidth: 2).padding(-3))
                    .scaleEffect(hovering ? 1.08 : 1)
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isActive ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .animation(.easeOut(duration: 0.2), value: isActive)
    }
}
