#include "include/qcusb.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>

struct qcusb_device {
    IOUSBDeviceInterface **dev;
    int opened_exclusive; // whether USBDeviceOpen succeeded (optional)
};

qcusb_device *qcusb_open(int32_t vid, int32_t pid) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) return NULL;
    CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &vid);
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), v);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), p);
    CFRelease(v);
    CFRelease(p);

    // Consumes one reference to `match`.
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, match);
    if (!service) return NULL;

    IOCFPlugInInterface **plug = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || plug == NULL) return NULL;

    IOUSBDeviceInterface **dev = NULL;
    (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                            (LPVOID *)&dev);
    IODestroyPlugInInterface(plug);
    if (dev == NULL) return NULL;

    qcusb_device *handle = calloc(1, sizeof(qcusb_device));
    if (!handle) {
        (*dev)->Release(dev);
        return NULL;
    }
    handle->dev = dev;
    handle->opened_exclusive = 0;
    return handle;
}

static int32_t qcusb_request(qcusb_device *handle, UInt8 bmRequestType,
                             UInt8 bRequest, uint16_t wValue, uint16_t wIndex,
                             void *data, uint16_t length, uint32_t *ioLength) {
    if (!handle || !handle->dev) return kIOReturnNotOpen;
    IOUSBDevRequest req;
    req.bmRequestType = bmRequestType;
    req.bRequest = bRequest;
    req.wValue = wValue;
    req.wIndex = wIndex;
    req.wLength = length;
    req.pData = data;
    req.wLenDone = 0;

    IOReturn kr = (*handle->dev)->DeviceRequest(handle->dev, &req);
    if (kr != kIOReturnSuccess && !handle->opened_exclusive) {
        // Some configurations require the device user client to be opened
        // first; try once and retry. kIOReturnExclusiveAccess still allows
        // EP0 requests on retry in practice.
        IOReturn okr = (*handle->dev)->USBDeviceOpen(handle->dev);
        if (okr == kIOReturnSuccess) handle->opened_exclusive = 1;
        kr = (*handle->dev)->DeviceRequest(handle->dev, &req);
    }
    if (ioLength) *ioLength = req.wLenDone;
    return kr;
}

int32_t qcusb_set_report(qcusb_device *dev, uint16_t wValue, uint16_t wIndex,
                         const uint8_t *data, uint16_t length) {
    // 0x21 = host-to-device | class | interface; 0x09 = SET_REPORT.
    return qcusb_request(dev, 0x21, 0x09, wValue, wIndex, (void *)data, length, NULL);
}

int32_t qcusb_get_report(qcusb_device *dev, uint16_t wValue, uint16_t wIndex,
                         uint8_t *data, uint16_t length, uint32_t *ioLength) {
    // 0xA1 = device-to-host | class | interface; 0x01 = GET_REPORT.
    return qcusb_request(dev, 0xA1, 0x01, wValue, wIndex, data, length, ioLength);
}

void qcusb_close(qcusb_device *handle) {
    if (!handle) return;
    if (handle->dev) {
        if (handle->opened_exclusive) {
            (*handle->dev)->USBDeviceClose(handle->dev);
        }
        (*handle->dev)->Release(handle->dev);
    }
    free(handle);
}
