# QuadCast Control

A lightweight, native macOS app for controlling the LED lighting of the
**HyperX QuadCast 2** and **QuadCast 2 S** microphones — a local, secure
alternative to HyperX NGENUITY (which is Windows-only).

- Native SwiftUI + `IOHIDManager` (no kernel extensions, no drivers, no admin
  privileges, no network access)
- Runs sandboxed on Apple Silicon (M1 and newer), macOS 13+
- Menu bar controls, so the main window never needs to stay open
- Strict device allowlist and a "nothing is sent until you opt in" model

## Supported devices

| Device | LED control | Notes |
|---|---|---|
| QuadCast 2 (`03F0:09AF`) | On/off, brightness | LEDs are red-only in hardware — there is no color to control; no persistence (the mic reverts ~1 s after the app stops, so the app keeps a small keep-alive running) |
| QuadCast 2 S (`03F0:02B5`) | On/off, brightness, static color, save-to-flash | 108 RGB LEDs, all set to one color |
| QuadCast S / DuoCast | Detected, read-only | Protocol documented in [PROTOCOL.md](PROTOCOL.md), not implemented yet |
| QuadCast (original) | Detected, read-only | Fixed red LED; no LED control exists in the hardware |

All protocol bytes come from community-verified public sources (quadcastrgb,
OpenRGB) — see [PROTOCOL.md](PROTOCOL.md) for every command with provenance.

## Project layout

```
hyperx/
├── QuadCastControl.xcodeproj      # Xcode project (app target)
├── QuadCastControl/               # SwiftUI app (UI layer only)
│   ├── QuadCastControlApp.swift   # Entry point: window + menu bar extra
│   ├── AppState.swift             # Main-actor view model
│   ├── QuadCastControl.entitlements
│   └── Views/                     # Status, Lighting, Diagnostics, Developer, MenuBar, Settings
├── QuadCastKit/                   # Swift package: all device logic (no UI)
│   ├── Sources/QuadCastKit/
│   │   ├── HyperXDeviceManager.swift  # IOHIDManager discovery + hot-plug
│   │   ├── HIDTransport.swift         # Transport protocol + device info
│   │   ├── IOKitHIDTransport.swift    # Real IOKit transport
│   │   ├── MockHIDTransport.swift     # In-memory transport for tests
│   │   ├── QuadCast2Protocol.swift    # QuadCast 2 + 2 S encoders
│   │   ├── LightingService.swift      # State, debounce, keep-alive loop
│   │   ├── DeviceIdentity.swift       # Strict VID/PID allowlist
│   │   ├── HIDReport.swift            # Report types + validation policy
│   │   ├── PacketDiff.swift           # RE helper (text-only)
│   │   └── …
│   └── Tests/QuadCastKitTests/    # 53 unit tests, no hardware needed
├── PROTOCOL.md                    # Verified + unverified HID commands
├── SECURITY.md
└── TROUBLESHOOTING.md
```

Architecture rules: the UI never touches IOKit; `AppState` talks to
`HyperXDeviceManager` (discovery) and `LightingService` (an actor owning
lighting state, debouncing, and the keep-alive refresh loop); the service
talks to a `HIDTransport` (real or mock) through a model-specific
`LightingProtocolEncoding`. Every outgoing report is validated against a
per-protocol `HIDReportPolicy` (allowed report IDs + max lengths) before it
reaches IOKit.

## Building and running (Apple Silicon)

Requirements: macOS 13+ (Apple Silicon, M1 or newer) and Xcode 16 or newer.

**With Xcode:** open `QuadCastControl.xcodeproj`, select the *QuadCastControl*
scheme, press ⌘R. The project is configured to "Sign to Run Locally" — no
Apple Developer account needed. (To distribute, set your own team and bundle
identifier in the target's Signing settings.)

**From the command line:**

```sh
# Build the app
xcodebuild -project QuadCastControl.xcodeproj \
  -scheme QuadCastControl -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build

# Run the unit tests (no microphone required)
cd QuadCastKit && swift test
```

## First run

1. Launch the app and plug in the microphone (USB-C data cable, not just
   power). The **Status** screen shows the detected model, vendor/product IDs,
   and connection state; **Diagnostics** lists every HyperX HID interface and
   its report descriptor.
2. LED control is **off by default** — the app sends nothing over USB until
   you flip **Lighting control** on (in the Lighting screen, menu bar, or
   Settings). The choice is remembered.
3. Use the LED toggle, brightness slider, and (QuadCast 2 S) color picker.
   Slider updates are debounced (~80 ms) so the device is never flooded.
4. Close the main window freely — the menu bar icon keeps the controls and
   the device keep-alive running. **Return to device default** stops the app's
   traffic so the mic falls back to its own onboard lighting.

## Developer tools

- **Diagnostics** — read-only: HyperX interfaces, usage pages, max report
  sizes, raw report descriptors, and an in-app hex log of every sent command.
- **Developer → Packet diff** — paste two sanitized hex captures (before /
  after changing one setting in NGENUITY); the tool highlights changed bytes
  and suggests field interpretations. It never sends anything.
- **Developer → Manual send** — DEBUG builds only, gated behind a developer
  mode toggle *and* a per-send confirmation dialog. Compiled out of release
  builds entirely.

## Contributing protocol knowledge

If you verify a command on real hardware (or find a discrepancy), update
[PROTOCOL.md](PROTOCOL.md) — the workflow is described in its last section.
The QuadCast S / DuoCast protocol is fully documented there and would be a
straightforward encoder to add (`QuadCastSProtocol` + registry entry + tests).

## License / provenance

Protocol information is derived from public open-source research by the
[quadcastrgb](https://github.com/Ors1mer/QuadcastRGB) and
[OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB) communities. This
project contains no HyperX/HP proprietary code.
