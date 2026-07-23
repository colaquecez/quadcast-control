# HyperX QuadCast Family — HID Protocol Documentation

This file documents everything this project knows about the USB HID LED
protocols of HyperX microphones, with provenance for every byte. All
information comes from **public sources** (GitHub, GitLab/OpenRGB, usb.ids,
ors1mer.xyz). Research date: 2026-07-22.

Legend for the *Verified* column:

- **Community-verified** — confirmed working on real hardware of that exact
  model by multiple independent users in public projects; sources cited.
- **Hardware-verified (this project)** — additionally confirmed on hardware by
  a user of *this* app. None yet; update this file when you confirm.
- **Unverified** — hypothesis; the app will never send these bytes.

> ⚠️ Commands are **not** interchangeable between the QuadCast, QuadCast S,
> QuadCast 2, and QuadCast 2 S. Each model section below stands alone.
> (Sending QuadCast S `0x81 R G B` zone commands to a QuadCast 2 S is
> confirmed to do nothing — quadcastrgb issue #18.)

---

## 1. Device identification

HyperX microphones enumerate as **two USB devices**: an audio device and a
separate "Controller" device. **LED control always targets the controller
PID.** Kingston-era devices use VID `0x0951`; HP-era devices use `0x03F0`.

| Model | LED controller VID:PID | Audio VID:PID | Source |
|---|---|---|---|
| QuadCast (original) | — none (LEDs not controllable) | `0951:16DF`, HP rev `03F0:0491` | usb.ids; quadcastrgb issues #4, #13 |
| QuadCast S (Kingston) | `0951:171F` | `0951:171D` | quadcastrgb `devio.c`; OpenRGB |
| QuadCast S (HP revisions) | `03F0:0F8B`, `03F0:028C`, `03F0:048C`, `03F0:068C` | `03F0:0D8B`, `03F0:0294` | quadcastrgb issues #5, #8; OpenRGB |
| DuoCast | `03F0:098C` | `03F0:0A8C` | quadcastrgb issue #11; OpenRGB |
| **QuadCast 2** | **`03F0:09AF`** ("HyperX QuadCast 2 Controller") | `03F0:07B4` | quadcastrgb issues #21, #30; OpenRGB issue #5149 |
| **QuadCast 2 S** | **`03F0:02B5`** ("QuadCast 2 S Controller") | `03F0:0D84` | quadcastrgb issue #18; OpenRGB issue #5113 / MR !3039 |

These pairs form the app's strict allowlist
(`QuadCastKit/Sources/QuadCastKit/DeviceIdentity.swift`). Audio PIDs are
listed for *identification only*; the transport refuses to open them.

---

## 2. QuadCast 2 (non-S) — implemented in this app

- **Model:** HyperX QuadCast 2 · **VID** `0x03F0` · **PID** `0x09AF`
- **Source:** quadcastrgb issue #21
  (github.com/Ors1mer/QuadcastRGB/issues/21) — reverse-engineered from USB
  captures of NGENUITY 5.34 by user *serverside-is*; merged into quadcastrgb
  main; independently confirmed by other users (e.g. issue #30).
- **Verified:** **Hardware-verified (this project, 2026-07-22)** for the
  brightness + heartbeat commands and the macOS transport described below.
  Originally community-verified in quadcastrgb issue #21.
- **Hardware reality:** the LEDs are **red-only**. There is no color command.
  There is no working save-to-flash (NGENUITY's own save fails). The device
  reverts to 100 % brightness ≈1 s after host traffic stops.

### Transport — macOS specifics (hardware-verified finding)

On the wire the commands are HID class SET_REPORT control transfers:
`bmRequestType 0x21, bRequest 0x09, wValue 0x0300 (feature, report ID 0),
wIndex 0 (interface 0), wLength 64`. No checksum. No response expected.

**`IOHIDDeviceSetReport` does NOT work for this device.** Verified on real
hardware: the controller's HID report descriptor declares only a 7-byte vendor
*input* report (`MaxOutputReportSize = 1`, `MaxFeatureReportSize = 1` — no
writable reports at all), so macOS's HID stack refuses the undeclared 64-byte
feature report and the call fails with `0xE0005000` (pipe stall). The firmware
nevertheless accepts the raw control transfer — which is why the Linux tools
(libusb, kernel-driver detach) and NGENUITY work.

The working macOS path — implemented in `USBControlTransport` +
`CQuadCastUSB` — issues the SET_REPORT via IOUSBLib's
`IOUSBDeviceInterface::DeviceRequest` on endpoint 0. Verified detail: no
`USBDeviceOpen`, no kernel-driver detach, and no interface claim is needed;
EP0 class requests are accepted while Apple's HID/audio drivers stay attached
and audio keeps working.

Observed descriptors for reference (macOS, `ioreg`):
- Controller `09AF`: consumer page report 0x03 (16-bit input) + vendor page
  0xFFFF report 0x05 (7-byte input). Nothing writable.
- Audio `07B4`: audio/consumer collections plus a vendor page 0xFFC1
  collection, report ID 0x77, 63-byte input *and* output — likely NGENUITY's
  general command pipe; format unknown, untouched by this app.

### Commands

| Command | Report ID | Length | Bytes | Expected response |
|---|---|---|---|---|
| Set brightness | 0 (feature) | 64 | `81 XX 00 00 81 XX 00 00` + 56 × `00`, where `XX` = brightness `0x00…0xF2` (0xF2 = max) | none |
| Heartbeat / keep-alive | 0 (feature) | 64 | `04 XX 00 00 00 00 00 00 01 00` + 54 × `00`; **`XX` must equal the current brightness** or the LED flickers | none |

**Sequence:** brightness → ≈20 ms → heartbeat → ≈500 ms → repeat while control
is active. Implemented in `QuadCast2Protocol` + the `LightingService` refresh
loop. "LED off" is brightness `0x00`. "Return to device default" = stop
sending; the mic restores itself within about a second.

### Rejected alternative

A Codeberg kernel driver (`codeberg.org/dawn_ll/quadcast2-linux-driver`) claims
65-byte feature reports with brightness at offset 13 plus a GET_REPORT
readback. It is AI-generated, contradicts the capture-based findings above,
and has no independent confirmation. **Unverified — not used.**

### Audio settings (gain / monitor mix / mute) — NOT yet documented

NGENUITY's audio *processing* (AI Noise Reduction, EQ, compressor, limiter,
spatial audio) is host-side DSP on Windows — it does not exist in the mic and
has no USB protocol to find. The *hardware* audio settings (gain, monitor
mix, mute — what the multifunction knob controls) are device-level, but no
public documentation of their commands exists (checked quadcastrgb, OpenRGB,
GitHub at large — the community work covers lighting only).

What we know from this hardware's descriptors:

- The **controller** (`09AF`) exposes two *input* reports: `0x03` (consumer
  page, 16-bit) and `0x05` (vendor page 0xFFFF, 7 bytes) — likely knob/mute
  event telemetry.
- The **audio device** (`07B4`) exposes a vendor collection (usage page
  0xFFC1) with report ID `0x77`, 63 bytes in *and* out — the most plausible
  NGENUITY command pipe for audio settings.

The app ships a **read-only input monitor** (Diagnostics → "Live input
reports") that streams these events without ever sending: turn the knob or
tap mute and record which bytes change. To map the *write* commands, capture
NGENUITY on Windows (Wireshark + USBPcap) while changing one audio setting,
then compare with the Packet Diff tool. Add nothing to the encoders until
byte structures are verified.

---

## 3. QuadCast 2 S — implemented in this app

- **Model:** HyperX QuadCast 2 S · **VID** `0x03F0` · **PID** `0x02B5`
- **Sources:** quadcastrgb issue #18 (community RE thread with NGENUITY
  captures, confirmed working by multiple testers); OpenRGB
  `HyperXMicrophoneV2Controller` (merged to master 2025-10-29, MR !3039);
  interface layout from `j-muell/QuadcastRGB2S` (`quadcast2s_usb_dump.txt`).
- **Verified:** Community-verified on QuadCast 2 S hardware. Not yet
  hardware-verified by this project.

### Transport

64-byte packets on the controller's HID interface with **vendor usage page
`0xFF13`** (interrupt endpoints OUT `0x06` / IN `0x85`; hidapi projects use
plain `hid_write`/`hid_read`). The device **answers every packet** on its
interrupt-IN endpoint; quadcastrgb validates `rsp[0] == 0xFF`, OpenRGB checks
that `rsp[14..15]` echo the sent bytes 0–1. On macOS the HID stack drains the
IN endpoint automatically, so writes work without explicit reads.

> **TODO(hardware):** confirm whether this interface's report descriptor
> declares report IDs. This app assumes it does **not** (the `0x44` is data,
> report ID 0), which matches the raw wire captures. If sends fail, the first
> byte may need to be passed as the report ID instead
> (`QuadCast2SProtocol` is the single place to change).

### Commands (direct/streaming mode)

| Step | Length | Bytes | Expected response |
|---|---|---|---|
| Header | 64 | `44 01 06 00` + zeros (announce 6 data packets) | 64-byte echo response |
| Data ×6 | 64 | `44 02 <idx 0–5> 00` then **20 RGB triplets** `RR GG BB` from byte 4 | 64-byte echo response |

120 LED slots; the mic uses **108 LEDs as a 12 × 9 matrix** (OpenRGB
`MATRIX_WIDTH 12, MATRIX_HEIGHT 9`). Cross-checked against a public NGENUITY
capture: color `#C90076` appears as `44 02 02 00 C9 00 76 C9 00 76 …`.
The look is lost (mic reverts to onboard rainbow) when traffic stops, so this
app re-sends the sequence every 250 ms while control is active (quadcastrgb
streams continuously with ~700 µs packet spacing).

### Commands (save-to-flash, persistent)

| Step | Length | Bytes |
|---|---|---|
| Initiate save | 64 | `44 03 01 06` + zeros |
| Data ×6 | 64 | `44 04 <idx> 00` + 20 RGB triplets |
| "Framerate" | 64 | `42 02 00 00 00 E8 03` + zeros (0x03E8 = 1000, static look) |
| Commit | 64 | `40 01 00 00 FF` + zeros |

Sequence from OpenRGB `SaveColors`. Exposed in the app as "Save current look
to device" (used sparingly — flash wear).

This app currently sends the **same color to all 108 LEDs** (static color).
Per-LED effects are possible with the same packets and are a natural
extension.

### Brightness

The protocol has no separate brightness field; brightness is applied
host-side by scaling the RGB channels (same as OpenRGB). "Off" = all black.

---

## 4. QuadCast S / DuoCast — documented, NOT implemented in this app

Kept here for completeness; `ProtocolRegistry` returns no encoder for these
models, so the app stays read-only if one is connected.

- **Sources:** quadcastrgb `modules/devio.c` + `modules/rgbmodes.c`; OpenRGB
  `HyperXMicrophoneController` (merged Jan 2023, MR !1417). Battle-tested for
  years. Public NGENUITY captures:
  `https://ors1mer.xyz/downloads/quadcastrgb_and_ngenuity_captures.tgz`.
- **Transport:** 64-byte feature reports, report ID 0 (same SET_REPORT shape
  as the QuadCast 2). Vendor usage page `0xFF90`. No checksum.
- **Direct mode:** alternate every ≈55 ms:
  - header `04 F2 00 00 00 00 00 00 01 00` + zeros (byte 8 = packet count)
  - data packet with 4-byte commands `81 RR GG BB` — upper LED zone at offset
    0, lower zone at offset 4 (the mic has exactly 2 zones).
- **Save-to-flash:** `04 53 …` (byte 8 = frame-packet count) → N packets of 8
  frames `81 R G B` (top) `81 R G B` (bottom) → `04 02 …` → `04 23 …`
  (byte 8 = 0x01) → EOT packet with byte 1 = `0x08` and trailer
  `28 <frame_count> 00 AA 55` at payload offsets 0x3B–0x3F → `04 02 …`.
  Timing: 15 ms between reports (OpenRGB).

---

## 5. Original QuadCast — no LED control

The original QuadCast (`0951:16DF` / `03F0:0491`) has a fixed red LED with no
USB control interface. Confirmed in quadcastrgb issues #4 and #13. The app
recognizes it and shows it as read-only.

---

## 6. Public packet captures

| Capture | Device | Where |
|---|---|---|
| `quadcast_2s.pcapng` (`#2FACED`) | QuadCast 2 S | OpenRGB issue #5113 attachment |
| `C90076.zip` (Wireshark, `#C90076`) | QuadCast 2 S | quadcastrgb issue #18 attachment |
| NGENUITY + quadcastrgb save captures (4 files) | QuadCast S | ors1mer.xyz/downloads/quadcastrgb_and_ngenuity_captures.tgz |
| Working Python daemon (derived from captures; raw capture not posted) | QuadCast 2 | quadcastrgb issue #21 attachment |

To produce new captures: run NGENUITY inside a Windows VM (or a second
machine) with Wireshark + USBPcap, change exactly one setting, filter with
`usb.transfer_type == 1 && endpoint < 0x80 && data_len >= 60` (interrupt) or
the SET_REPORT control transfers, and compare payloads with the app's
**Developer → Packet diff** tool.

---

## 7. Verification workflow for this project

1. Connect the device; check **Diagnostics** for VID/PID/usage page and the
   report descriptor.
2. Confirm the interface matches the tables above; if a new PID appears, do
   not add it to the allowlist until its role is understood.
3. Enable lighting control (explicit opt-in) and test each command.
4. On success, update the *Verified* status here to "Hardware-verified (this
   project)" and, if behavior differs, correct the byte tables **and** the
   encoder + its unit tests together.
