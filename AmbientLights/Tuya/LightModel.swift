import Foundation

/// Data points of the GoHigh SkyLight Bar (Tuya category `dd`, protocol 3.3).
/// Verified on the device on 2026-10-10; see docs/protocol-findings.md.
enum SkyLightDP {
    static let power = "20"        // bool
    static let mode = "21"         // "white" | "colour" | "scene" | "music"
    static let brightness = "22"   // 10...1000, white mode
    static let temperature = "23"  // 0...1000, white mode (warm → cool)
    static let colour = "24"       // "HHHHSSSSVVVV" hex

    static let brightnessRange = 10...1000
    static let temperatureRange = 0...1000
}

enum LightMode: String, CaseIterable, Identifiable {
    case white
    case colour

    var id: String { rawValue }
    var label: String { self == .white ? "White" : "Colour" }

    /// This firmware reports colour mode as "scene".
    init(reported: String?) {
        self = (reported == "colour" || reported == "scene") ? .colour : .white
    }
}

/// Hue 0–360, saturation and value 0–1000, as the device stores them.
struct HSV: Equatable {
    var hue: Int
    var saturation: Int
    var value: Int

    static let red = HSV(hue: 0, saturation: 1000, value: 1000)

    /// "HHHHSSSSVVVV", each field a 4-digit lowercase hex number.
    var hex: String {
        String(format: "%04x%04x%04x", hue.clamped(0...360), saturation.clamped(0...1000), value.clamped(0...1000))
    }

    init(hue: Int, saturation: Int, value: Int) {
        self.hue = hue
        self.saturation = saturation
        self.value = value
    }

    init?(hex: String) {
        guard hex.count == 12 else { return nil }
        let chars = Array(hex)
        let parts = stride(from: 0, to: 12, by: 4).compactMap { Int(String(chars[$0..<($0 + 4)]), radix: 16) }
        guard parts.count == 3 else { return nil }
        self.init(hue: parts[0], saturation: parts[1], value: parts[2])
    }
}

struct LightState: Equatable {
    var isOn = false
    var mode: LightMode = .white
    var brightness = 500
    var temperature = 500
    var colour = HSV.red

    mutating func apply(_ dps: [String: DPValue]) {
        if let on = dps[SkyLightDP.power]?.boolValue { isOn = on }
        if let mode = dps[SkyLightDP.mode]?.stringValue { self.mode = LightMode(reported: mode) }
        if let brightness = dps[SkyLightDP.brightness]?.intValue { self.brightness = brightness }
        if let temperature = dps[SkyLightDP.temperature]?.intValue { self.temperature = temperature }
        if let hex = dps[SkyLightDP.colour]?.stringValue, let colour = HSV(hex: hex) { self.colour = colour }
    }
}

extension Int {
    func clamped(_ range: ClosedRange<Int>) -> Int { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
