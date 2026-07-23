#ifndef QCUSB_H
#define QCUSB_H

#include <stdint.h>

/// Minimal, deliberately narrow wrapper around IOUSBLib for sending HID
/// SET_REPORT / GET_REPORT class requests as raw EP0 control transfers.
///
/// Why this exists: the QuadCast 2's LED controller accepts 64-byte feature
/// reports in firmware, but its HID report descriptor does not *declare* any
/// writable report, so macOS's HID stack (IOHIDDeviceSetReport) refuses to
/// send them. The community-verified protocol works by issuing the SET_REPORT
/// control transfer directly — which IOUSBLib permits from user space, no
/// kernel driver detach required (EP0 control transfers do not need exclusive
/// interface access on macOS).
///
/// The API is intentionally NOT a general control-transfer primitive: only
/// HID class SET_REPORT (0x21/0x09) and GET_REPORT (0xA1/0x01) are possible.

typedef struct qcusb_device qcusb_device;

/// Opens the first USB device matching vid/pid. Returns NULL if absent or
/// the user client cannot be created. Does not seize the device and does not
/// disturb kernel drivers (audio keeps working).
qcusb_device *qcusb_open(int32_t vid, int32_t pid);

/// HID SET_REPORT via EP0. wValue = (type << 8) | reportID with type
/// 2=output, 3=feature. Returns IOReturn (0 = success).
int32_t qcusb_set_report(qcusb_device *dev, uint16_t wValue, uint16_t wIndex,
                         const uint8_t *data, uint16_t length);

/// HID GET_REPORT via EP0. On success *ioLength holds the bytes received.
int32_t qcusb_get_report(qcusb_device *dev, uint16_t wValue, uint16_t wIndex,
                         uint8_t *data, uint16_t length, uint32_t *ioLength);

void qcusb_close(qcusb_device *dev);

#endif
