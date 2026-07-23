# Security

This app is designed to be auditable in one sitting. The threat model:
a USB peripheral-control app must not become a vector for exfiltration,
privilege escalation, or bricked hardware.

## What the app does NOT do

- **No network access.** There is no networking code of any kind: no
  telemetry, no analytics, no update checks, no uploads or downloads. The
  sandbox has no network entitlement, so the OS enforces this.
- **No external binaries.** Nothing is downloaded or executed; there are no
  shell scripts and no modifications to system directories.
- **No elevated privileges.** No kernel extensions, no drivers, no root, no
  admin prompts, no `AuthorizationServices`.
- **No secrets.** There are no credentials, tokens, or hardcoded keys in the
  code or the binary.

## Sandbox and entitlements

The app runs fully sandboxed with exactly one entitlement beyond the sandbox
itself (`QuadCastControl/QuadCastControl.entitlements`):

| Entitlement | Why |
|---|---|
| `com.apple.security.app-sandbox` | Standard App Sandbox. |
| `com.apple.security.device.usb` | Required for `IOHIDDeviceOpen` on the microphone's HID controller from inside the sandbox. Without it the app can list devices but not send LED commands. |

No file, network, camera, or microphone-audio entitlements. (The app never
touches the audio side of the microphone; devices are opened with
`kIOHIDOptionsTypeNone` — shared, non-seizing — so audio is unaffected.)

## HID safety layers

Commands pass through four independent checks before reaching the device:

1. **Vendor filter** — discovery only inspects VIDs `0x0951` (Kingston) and
   `0x03F0` (HP).
2. **Strict allowlist** (`DeviceAllowlist`) — the transport refuses to open
   any VID/PID not explicitly listed as a known HyperX *LED controller*.
   Audio-side PIDs are recognized for display but cannot be opened.
3. **Report policy** (`HIDReportPolicy`) — every packet is validated against
   the protocol's allowed report IDs and maximum payload lengths in software
   before `IOHIDDeviceSetReport` is called.
4. **Verification flag** — `LightingService` refuses any packet whose encoder
   did not mark it as verified (with a cited source). Encoders for unknown
   protocols throw instead of guessing.

Additional policies:

- **Explicit opt-in:** nothing is ever transmitted until the user enables
  lighting control; the default is off.
- **Rate limiting:** slider input is debounced (80 ms) and the keep-alive
  loop runs at the documented device cadence, so the device is never flooded.
- **Arbitrary sends are DEBUG-only:** the manual report tool is compiled out
  of release builds (`#if DEBUG`), gated behind a developer-mode toggle, and
  requires a per-send confirmation. Captured commands are never replayed
  automatically.
- **Unknown commands:** the app never sends bytes whose structure is not
  documented in PROTOCOL.md with a credible source.

## Privacy

- Device **serial numbers are redacted at the source** (only the last four
  characters are ever read into app state, logs, or the UI).
- Raw packet hex is logged at *debug* level only; the in-app log lives in a
  bounded in-memory ring buffer and is never written to disk.
- Preferences (last color/brightness, opt-in flags) are stored in
  `UserDefaults` — no databases, no files, no iCloud.

## Reporting

If you find a security issue, open an issue in the project repository with
reproduction steps. Do not include device serial numbers in reports.
