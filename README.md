# Ambient Lights

Native macOS menu bar app to replace the discontinued GoHigh Lights app.

**Phase 2: local Wi-Fi control.** The app controls the GoHigh SkyLight Bar (a Tuya Wi-Fi + BLE light, protocol 3.3) directly on your home network, without the cloud: power, brightness, white warmth and colour. The Phase 1 Bluetooth tools are still there and remain read-only. Protocol evidence is in [docs/protocol-findings.md](docs/protocol-findings.md).

## Requirements

| | Tested with |
|---|---|
| macOS | 26.6 (arm64). Deployment target is macOS 13.0, the first version with `MenuBarExtra`. |
| Toolchain | Command Line Tools, Swift 6.1, macOS SDK 15.4. Builds in Swift 5 language mode. |
| Xcode | Optional. `AmbientLights.xcodeproj` is included for when you install it. |

## Build and run

### Option A: Command Line Tools only (works now)

```bash
scripts/build.sh            # release build
scripts/build.sh debug      # debug build
open build/AmbientLights.app
```

The script compiles with `swiftc`, assembles `build/AmbientLights.app`, and signs it ad-hoc with the sandbox and Bluetooth entitlements.

### Option B: Xcode

1. Install Xcode from the App Store, then run `sudo xcode-select -s /Applications/Xcode.app`.
2. Open `AmbientLights.xcodeproj` and press ⌘R. Signing is set to "Sign to Run Locally", so you don't need a team. To use your Apple ID instead, pick a team under Signing & Capabilities.

From the terminal: `xcodebuild -project AmbientLights.xcodeproj -scheme AmbientLights -configuration Debug build`

## Using it

1. Click the 💡 icon in the menu bar. There is no Dock icon (`LSUIElement`). Quit from the popover footer or with ⌘Q while it's open.
2. On first launch, macOS asks for Bluetooth permission. Choose **Allow**.
3. **Scan** tab: power on the lights, close the GoHigh app on any phone, then press **Scan for Lights**. Scans stop on their own after 30 s, or when you connect. Click a row to see its identifier, RSSI, advertised services, manufacturer data, service data, TX power and whether it's connectable. Press **Connect** to open it.
4. **Device** tab: shows services and characteristics with their properties (read, write, write w/o response, notify, indicate…). **Read** reads one characteristic. **Read All Readable** reads every readable one. **Copy GATT Report** copies the full table as text.
5. **Diagnostics** tab: a timestamped log. **Copy Sanitized Logs** replaces peripheral identifiers with `peripheral-N` and hides the names of devices you never connected to. **Copy Raw** copies everything as-is.

## Light setup (Phase 2)

1. Run `tinytuya wizard` once (see docs/protocol-findings.md) to create `~/tuya-keys/devices.json`.
2. Open the menu bar app → **Lights** → **Import devices.json…**, then press **Find** to get the light's IP, then **Save & Connect**.
3. Allow **Local Network** access when macOS asks. Allow Keychain access if asked (ad-hoc rebuilds can ask again).

The local key is stored only in the macOS Keychain (`local.ambientlights.light`). Device ID and IP live in the app's preferences. **⋯ → Light Settings… → Forget Light** removes all three.

How it works: each command opens a TCP connection to port 6668, sends one AES-encrypted Tuya 3.3 frame, reads the reply and closes the connection. Slider drags are coalesced so only one command is ever in flight. The Swift encoder was checked byte-for-byte against tinytuya.

| Control | Data points |
|---|---|
| Power | `20` bool |
| White brightness / warmth | `21="white"`, `22` 10–1000, `23` 0–1000 |
| Colour | `21="colour"`, `24="HHHHSSSSVVVV"` (hex hue/sat/value). The light reports this mode as `scene` |

## Safety (Bluetooth tools)

- The app only calls `readValue(for:)`, and only on characteristics that declare `.read`.
- It never calls `writeValue`, never writes descriptors, and never calls `setNotifyValue`. Turning on notifications writes the CCCD descriptor, so that is off too.
- It sends no test commands and does not guess the protocol.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Permission denied" banner | System Settings → Privacy & Security → Bluetooth → enable Ambient Lights, then relaunch. Ad-hoc builds change signature every time you rebuild, so macOS may ask again or list the app twice. Remove stale entries. |
| Permission state is stuck | `tccutil reset BluetoothAlways local.ambientlights.AmbientLights`, then relaunch. |
| "Bluetooth Off" | Turn Bluetooth on in Control Center. |
| Lights don't appear | Many LED controllers accept only one connection and stop advertising once connected. Force-quit the GoHigh/phone app, turn phone Bluetooth off, and power-cycle the lights. Try the **Named** filter or sort by **Signal** and bring the Mac close. |
| Connect times out (15 s) | Same as above: something else is probably connected. Also check the device shows **Connectable: Yes**. |
| "Pairing info mismatch" | Remove the device in System Settings → Bluetooth and retry. |
| Read fails with auth/encryption error | The characteristic requires pairing. That's normal for some. Note it in the log. |
| `xcodebuild` says "requires Xcode" | Only the Command Line Tools are active. Use `scripts/build.sh`, or install Xcode and `xcode-select` it. |
| Menu bar icon missing | Crowded menu bar (notch). Hold ⌘ and drag other icons away, or use a menu bar manager. |
| Lights tab: "Light didn't answer" | The light accepts one local connection. Close Smart Life fully. If that doesn't help, unplug the light for 10 s; its local service sometimes locks up after phone-app use. Then **⋯ → Find on Network** in case its IP changed. |
| Lights tab: "Network is down" / nothing happens | Allow Ambient Lights in System Settings → Privacy & Security → **Local Network**. |
| Warmth slider has no effect | DP 23 is in the light's cloud model but wasn't write-tested during protocol discovery. Check Diagnostics for the light's reply. |
| Live system logs | `log stream --predicate 'subsystem == "local.ambientlights"' --level debug` |

## Project layout

```
AmbientLights/
  App/AmbientLightsApp.swift        MenuBarExtra (.window style) entry point
  Bluetooth/BluetoothManager.swift  CoreBluetooth on a private serial queue; publishes to main
  Bluetooth/BLEModels.swift         Device / service / characteristic snapshots
  Bluetooth/BLEFormat.swift         Hex, property names, company IDs, error hints
  Diagnostics/LogStore.swift        Timestamped log + sanitized export
  Views/                            Root, Scanner, DeviceRow, Inspector, Diagnostics
  Info.plist                        LSUIElement, NSBluetoothAlwaysUsageDescription
  AmbientLights.entitlements        app-sandbox, device.bluetooth
AmbientLights.xcodeproj/            Xcode project (same sources)
scripts/build.sh                    swiftc build without Xcode
```

## Next: identifying the protocol

Connect to the lights, press **Read All Readable**, then **Copy GATT Report** and **Copy Sanitized Logs**. Write-capable characteristics (orange chips) on a custom service (commonly `FFE0`/`FFE5`/`FFF0`-style UUIDs on cheap controllers) are the likely control channel. Confirm the exact command format from a packet capture of the official app before Phase 2 sends anything.

## Secrets and privacy

This repo contains no credentials. Everything device-specific stays on your Mac:

- **Local key.** Stored only in the macOS Keychain (service `local.ambientlights.light`).
- **Device ID and IP.** Stored in the app's preferences.
- **tinytuya output** (`devices.json`, `tinytuya.json`, `tuya-raw.json`, `snapshot.json`). Keep it outside the repo (for example `~/tuya-keys`, `chmod 600`). These names are also in `.gitignore`.
- **Bluetooth logs.** **Copy Sanitized Logs** replaces peripheral identifiers and the names of devices you never connected to.

The Tuya product ID and model in `docs/protocol-findings.md` identify the SkyLight product line, not your unit.
