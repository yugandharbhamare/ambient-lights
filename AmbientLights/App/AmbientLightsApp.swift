import SwiftUI

@main
struct AmbientLightsApp: App {
    @StateObject private var log: LogStore
    @StateObject private var bluetooth: BluetoothManager
    @StateObject private var light: LightController

    init() {
        let log = LogStore()
        let bluetooth = BluetoothManager(log: log)
        _log = StateObject(wrappedValue: log)
        _bluetooth = StateObject(wrappedValue: bluetooth)
        _light = StateObject(wrappedValue: LightController(log: log))
        bluetooth.start()
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environmentObject(bluetooth)
                .environmentObject(log)
                .environmentObject(light)
        } label: {
            Image(systemName: menuBarSymbol)
                .accessibilityLabel("Ambient Lights")
        }
        .menuBarExtraStyle(.window)

        Window("Bluetooth Tools", id: "bluetooth-tools") {
            BluetoothToolsView()
                .environmentObject(bluetooth)
                .environmentObject(log)
                .frame(minWidth: 420, minHeight: 560)
        }
        .defaultSize(width: 440, height: 620)
    }

    private var menuBarSymbol: String {
        light.hasState && light.state.isOn ? "lightbulb.fill" : "lightbulb"
    }
}
