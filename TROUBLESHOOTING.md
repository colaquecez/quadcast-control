# Troubleshooting

## The app doesn't see the microphone at all

- **Check the cable.** The mic must be connected with a USB **data** cable to
  the Mac (or a hub that passes data). Charging-only cables and some monitor
  USB ports enumerate nothing.
- **Check System Information** (: menu → About This Mac → More Info → System
  Report → USB). You should see two HyperX/HP entries — an audio device and a
  "Controller". If macOS itself doesn't list them, the app can't either.
- The app only watches vendor IDs `0x0951` (Kingston) and `0x03F0` (HP). A
  device showing under a different VID is not a QuadCast.

## The device shows up but as "Unrecognized (read-only)"

Your unit has a product ID that is not in the allowlist yet (HyperX ships new
hardware revisions with new PIDs). Open **Diagnostics**, note the PID, and
compare with the table in [PROTOCOL.md](PROTOCOL.md). If it is a new revision:

1. Search the quadcastrgb / OpenRGB issue trackers for that PID.
2. If credible sources identify it, add an entry to `DeviceAllowlist`
   (`QuadCastKit/Sources/QuadCastKit/DeviceIdentity.swift`) with the source,
   and rebuild.

Do **not** add a PID speculatively — the allowlist is the safety boundary.

## Connected, but LED controls are grayed out

- **Lighting control is off.** It's off by default; enable the toggle in the
  Lighting screen or the menu bar. Nothing is sent until you do.
- **The model has no implemented protocol** (QuadCast S, DuoCast, original
  QuadCast). The status screen tells you; PROTOCOL.md has the details.
- **You have a QuadCast 2 (non-S) and expected a color picker.** The
  QuadCast 2's LEDs are red-only in hardware; only brightness exists. This is
  a device limitation, not an app limitation.

## Commands are sent but the LED doesn't change

- Check the **Diagnostics log** for `Send failed` entries.
  - `ioError(code: -536850432)` (`0xE0005000`, pipe stall) on a QuadCast 2:
    the send went through the HID report API, which this device rejects —
    its descriptor declares no writable reports. The app routes the
    QuadCast 2 through raw EP0 control transfers (`USBControlTransport`)
    precisely for this; if you see this error, the allowlist entry for your
    PID is probably missing `sendPath: .controlTransfer(interface: 0)`.
    See PROTOCOL.md §2 "Transport — macOS specifics".
  - `openFailed` / privilege errors: the build may be missing the
    `com.apple.security.device.usb` entitlement — rebuild from the included
    project, which sets it.
  - Other `ioError`: the interface bound may be wrong for your hardware
    revision, or the report descriptor uses report IDs unexpectedly (see the
    TODO in `QuadCast2SProtocol` about report-ID handling). Capture the
    report descriptor from Diagnostics and open an issue.
- NGENUITY running in a VM, or another RGB tool, may be holding the device in
  a different state — quit them and replug.

## LED flickers between dim and bright (QuadCast 2)

The heartbeat packet's second byte must equal the current brightness; a
mismatch causes exactly this flicker. This app keeps them in sync, but another
tool driving the device at the same time will fight it. Use one controller at
a time.

## Brightness resets to 100 % when I quit the app (QuadCast 2)

Expected hardware behavior: the QuadCast 2 reverts about a second after
keep-alive traffic stops, and it has no working save-to-flash (NGENUITY's own
save fails on this device). Keep the app running in the menu bar to hold a
brightness level.

## Color reverts to rainbow when the app quits (QuadCast 2 S)

Direct-mode colors are not persistent. Use **Lighting → Save current look to
device** to write the color to the microphone's flash so it survives with no
app running (use sparingly; flash has limited write cycles).

## The mic's audio stopped working / weird audio behavior

The app never opens the audio device and opens the LED controller in shared
(non-seizing) mode, so it cannot affect audio. Unplug/replug the mic and check
System Settings → Sound. If audio problems correlate with the app, please
report it with the Diagnostics log.

## "Device disconnected" errors while sending

Normal if the cable was unplugged mid-command; the app recovers on replug
automatically. If it happens with the cable in place, try a different port —
some hubs power-cycle ports under load.

## Getting more detail

The app logs to the unified system log (`subsystem: QuadCastControl`):

```sh
log stream --predicate 'subsystem == "QuadCastControl"' --level debug
```

Raw packet hex appears at debug level only.
