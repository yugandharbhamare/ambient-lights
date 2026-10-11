# Protocol findings

Status as of 2026-10-10. Nothing has been written to the device yet.

## Device identification (confirmed)

| | |
|---|---|
| Advertised name | `TY` |
| macOS peripheral ID | `<redacted>` (a per-Mac identifier; yours will differ) |
| How confirmed | Disappeared from the scan when the lights were unplugged at the wall |
| Manufacturer data | Company `0x07D0` (Tuya). Bytes after the company ID: `01 03 00 00 0C 00` + 16 encrypted bytes |
| Advertised service | `A201` |
| GATT | Service `1910`: `2B11` write / write w/o response (commands), `2B10` notify (responses) |

Other nearby devices are not the light: `Hi-LIGHT-19B7EBASE01` (an unprovisioned Bluetooth Mesh node, still present when the lights were unplugged), `LIVSMT-RO-6044` (probably a Livpure water purifier), and Apple devices.

## Protocol: Tuya BLE

**Verified** against the open-source integration [PlusPlus-ua/ha_tuya_ble](https://github.com/PlusPlus-ua/ha_tuya_ble) (`tuya_ble/const.py`, `tuya_ble/tuya_ble.py`):

- The advertisement signature (`0x07D0` plus `A201`) and the GATT layout (`1910` / `2B11` / `2B10`) match exactly.
- Manufacturer byte `[1]` = `0x03` means protocol version 3.
- Every packet is AES-128-CBC encrypted. The login key is `md5(local_key[:6])`. The session key is `md5(local_key[:6] + srand)`, where `srand` comes from the device-info response.
- `local_key` (plus the device ID and UUID) comes from the Tuya cloud and exists only once the device is paired to an account.
- Command codes:
  - `0x0000` device info (session handshake, no state change)
  - `0x0002` send settings (v3)
  - `0x0027` send settings (v4)
  - `0x8001` and the rest are device reports
- The packet MTU is 20 bytes, so packets are split.

**Hypotheses (not verified yet):**

- Manufacturer byte `[0]` = `0x01` has the bound bit (`0x80`) clear, so the device is probably not paired to any account.
- Standard Tuya light settings: 20 on/off (bool), 21 mode (enum), 22 brightness (10–1000), 24 colour (HSV: h 0–360, s/v 0–1000). Must be confirmed from the device's cloud data model.
- GoHigh products are rebranded Tuya hardware.

**Never send:** `0x0005` unbind, `0x0006` device reset, `0x000C`–`0x0010` firmware update.

## Still needed

1. The product ID from the `A201` service data (shown in the Scan details as `Data A201`), to learn the device category.
2. `local_key`, device ID and UUID: pair the light in the Smart Life app, link that account at iot.tuya.com, and run `tinytuya wizard`. Store these in the Keychain, never in logs or chat.
3. A session-login test (`0x0000`) with the user's approval, then one on/off command with separate approval.

## Update: advertisement after power cycle (2026-10-10, 15:05)

- Manufacturer bytes after the company ID: `81 03 00 00 0C 00` + 16 encrypted device-ID bytes (redacted). The flag byte changed from `01` to `81`, so the bound bit is now set (open-source interpretation, unverified). The encrypted ID bytes changed as well.
- `A201` service data: `01` + 16 bytes (redacted). Type `0x01` is a product key; ha_tuya_ble does not decode it. The product ID is not in plaintext, so it must come from the cloud (tinytuya wizard).
- The Mac's connection attempt failed. One likely cause is another central (a phone app) holding the single connection. Awaiting the error from the diagnostics log.

## Update: Tuya cloud data model (2026-10-10, 19:24) — confirmed

Fetched read-only with `tinytuya wizard`. Secrets live only in `~/tuya-keys` (chmod 600).

| Field | Value |
|---|---|
| Name / product | GoHigh SkyLight Bar |
| Model | GOSKY5V2A |
| Category | `dd` (light strip) |
| Product ID | `i0jegrca3q4f1vue` |
| Cloud online | yes |
| Local protocol | **3.3**, found by a **Wi-Fi LAN UDP broadcast** (snapshot `origin: broadcast`), so this is a Wi-Fi + BLE combo module |

Data points (the device's settings; IDs and codes from the cloud model):

| DP | Code | Type | Range |
|---|---|---|---|
| 20 | `switch_led` | bool | |
| 21 | `work_mode` | enum | white, colour, scene, music |
| 22 | `bright_value` | int | 10–1000 |
| 23 | `temp_value` | int | 0–1000 |
| 24 | `colour_data` | json | h 0–360, s 0–1000, v 0–1000 |
| 26 | `countdown` | int | 0–86400 s |
| 27 | `music_data` | json | |
| 28 | `control_data` | json | |

Note: the codes are the v1 names (`bright_value`, `colour_data`), not `_v2`. The `colour_data` wire format (hex string vs JSON) must be confirmed from a status read before any write.

### Control path options

1. **Tuya local LAN, v3.3** (TCP 6668, AES-128-ECB with local_key; implemented by tinytuya). Well documented, and a status read is the obvious first test.
2. **Tuya BLE** (`1910`/`2B11`). Documented for BLE-only devices. Unverified for Wi-Fi combo modules, whose BLE link may accept only provisioning.

## Verified: local LAN status read (2026-10-10) — user approved

One read-only `status()` call (tinytuya `Device`, version 3.3, timeout 5 s) succeeded, so the local_key, the LAN address and protocol 3.3 are all confirmed working. Response:

```json
{"20": true, "21": "white", "22": 87, "23": 250, "26": 0}
```

DP 24 `colour_data` is absent in white mode, so its wire format is still unconfirmed. Next step: the user switches the light to colour mode in Smart Life, then a second status read shows the DP 24 format.

The chosen Phase 2 path is the **Wi-Fi local protocol (3.3)** (user decision, 2026-10-10).

## Observation: local connection contention (2026-10-10)

- After the user switched modes in Smart Life, status reads returned `work_mode: scene` twice, and setting 24 (`colour_data`) never appeared. This panel may produce colours through scenes or `control_data` (DP 28). Not confirmed.
- Later status reads failed with tinytuya `905 Device Unreachable`. The light was still sending UDP broadcasts (v3.3) from the same IP. The likely cause is the device's single local TCP connection being held by the Smart Life app. Not confirmed yet.
- Design consequence for Phase 2: connect per command with short timeouts and close straight away. Don't hold a persistent socket. Surface "light busy (phone app connected?)" errors in the UI.
- Resolved by a power cycle. The control port (6668) reopened at the same IP, and the status read succeeded: `{"20": true, "21": "white", "22": 10, "23": 250, "26": 0}`. Confirmed: the light's local TCP service can lock up after phone-app use, and a power cycle restores it. The Mac could reach other LAN hosts throughout, so the Mac side was fine.

## Verified: test 2, power on/off (2026-10-10) — user approved

tinytuya `set_value(20, False)`, then 3 s later `set_value(20, True)`, then `status()`:

```
set 20=false → {"20": false}
set 20=true  → {"20": true}
status       → {"20": true, "21": "white", "22": 10, "23": 250, "26": 0}
```

The device echoes each written setting in its reply, and the other settings were unchanged. **DP 20 (switch_led) write: confirmed.**

## Verified: test 3, brightness (2026-10-10) — user approved

`set_value(22, 500)`, then 3 s later `set_value(22, 10)`, then `status()`. The device echoed `{"22": 500}` and `{"22": 10}`, and the final status matched the starting state. **DP 22 (bright_value, 10–1000, in white mode) write: confirmed.** The user visually confirmed the test 2 blink.

## Test 4a, colour mode discovery (2026-10-10) — user approved

- Local `set_value(21, "colour")` returned `{"21": "scene"}`. The firmware remaps colour mode to scene. Status: `{"20": true, "21": "scene", "22": 10, "23": 250, "26": 0}`. DP 24 is still not reported locally.
- Read-only cloud reads (`getstatus`, `getfunctions`):
  - Cloud status includes `colour_data = {"h":240,"s":1000,"v":1000}` (blue), in the cloud's translated JSON form. The local wire format is still unknown.
  - Writable functions: switch_led, work_mode, bright_value, temp_value, colour_data (h 0–360, s/v 0–1000), countdown, music_data, control_data. There is no scene_data DP (25) in the model.
- Next evidence step (needs approval): send `work_mode=colour` plus `colour_data` through the **cloud** API, which uses the documented standard instruction set and translates to the device's format. Then read local status to see the native DP 24 encoding.

## Verified: test 4b, colour (2026-10-10) — user approved

1. Cloud `sendcommand`: `work_mode=colour` plus `colour_data={"h":0,"s":1000,"v":1000}` (red). Success.
2. Local status: `{"20": true, "21": "scene", "22": 10, "23": 250, "24": "000003e803e8", "26": 0}`.
3. Restored locally with `set_value(21, "white")`, which echoed `{"21": "white"}`. The final status was white with brightness 10.

**DP 24 local wire format: confirmed.** It is a 12-character lowercase hex string, `HHHHSSSSVVVV`, with each field a 4-hex-digit big-endian integer: h 0–360, s 0–1000, v 0–1000. Red `h0 s1000 v1000` is `"000003e803e8"`.

Note: in colour mode the firmware reports `work_mode` as `"scene"`, even after the cloud set it to `"colour"`. Treat `"scene"` and `"colour"` as equivalent when reading the mode, and for local colour writes send 21=`"colour"` together with 24. A local colour write is not yet verified (pending the user seeing red, then test 4c).

## Verified: test 4c, local colour write (2026-10-10) — user approved

The user saw red in test 4b. Local `set_multiple_values({"21": "colour", "24": "00f003e803e8"})` echoed `{"21": "scene"}`, and status then showed `"24": "00f003e803e8"`. Restored with `21="white"`; final status was white with brightness 10. The user's visual confirmation of blue is pending.

### Protocol summary (local LAN, Tuya 3.3)

| Action | DPs |
|---|---|
| On / off | `{"20": true/false}` |
| White brightness | `{"21": "white", "22": 10..1000}` |
| White temperature | `{"23": 0..1000}` |
| Colour | `{"21": "colour", "24": "HHHHSSSSVVVV"}` (hex; h 0–360, s/v 0–1000); the mode reads back as `"scene"` |
| Read state | DP query (`status()`) |

Connect per command and close straight away. If the light stops accepting connections after phone-app use, power-cycle it.
