import Testing
@testable import QuadCastKit

private let permissivePolicy = HIDReportPolicy(
    allowedReportIDs: [.feature: [0x00, 0x07], .output: [0x00]],
    maxPayloadLength: [.feature: 8, .output: 64]
)

@Suite("Report validation")
struct ReportValidationTests {
    @Test func acceptsAllowedReport() throws {
        let report = HIDReport(kind: .feature, reportID: 0x07, payload: [1, 2, 3])
        try permissivePolicy.validate(report)
    }

    @Test func rejectsUnsupportedReportID() {
        let report = HIDReport(kind: .feature, reportID: 0x99, payload: [1])
        #expect(throws: HIDTransportError.unsupportedReportID(0x99)) {
            try permissivePolicy.validate(report)
        }
    }

    @Test func rejectsOverlongPayload() {
        let report = HIDReport(kind: .feature, reportID: 0x00, payload: [UInt8](repeating: 0, count: 9))
        #expect(throws: HIDTransportError.invalidReportLength(expected: 8, actual: 9)) {
            try permissivePolicy.validate(report)
        }
    }

    @Test func rejectsEmptyPayload() {
        let report = HIDReport(kind: .output, reportID: 0x00, payload: [])
        #expect(throws: HIDTransportError.emptyPayload) {
            try permissivePolicy.validate(report)
        }
    }

    @Test func readOnlyPolicyRejectsEverything() {
        let report = HIDReport(kind: .feature, reportID: 0x00, payload: [0x01])
        #expect(throws: HIDTransportError.unsupportedReportID(0x00)) {
            try HIDReportPolicy.readOnly.validate(report)
        }
    }
}

@Suite("Device allowlist")
struct DeviceAllowlistTests {
    @Test func knownQuadCastSIsAllowlisted() {
        let known = DeviceAllowlist.lookup(vendorID: 0x0951, productID: 0x171F)
        #expect(known?.model == .quadCastS)
    }

    @Test func unknownProductIDIsRejected() {
        #expect(DeviceAllowlist.lookup(vendorID: 0x0951, productID: 0xDEAD) == nil)
        #expect(DeviceAllowlist.lookup(vendorID: 0x1234, productID: 0x171F) == nil)
    }

    @Test func candidateVendorsAreOnlyKingstonAndHP() {
        #expect(DeviceAllowlist.isCandidateVendor(0x0951))
        #expect(DeviceAllowlist.isCandidateVendor(0x03F0))
        #expect(!DeviceAllowlist.isCandidateVendor(0x046D))  // Logitech
    }

    @Test func transportRefusesToOpenUnsupportedDevice() {
        let mock = MockHIDTransport(info: MockHIDTransport.makeInfo(productID: 0xDEAD))
        #expect(throws: HIDTransportError.unsupportedDevice(vendorID: 0x03F0, productID: 0xDEAD)) {
            try mock.open()
        }
        #expect(!mock.isOpen)
    }

    @Test func transportRefusesToOpenNonLEDInterface() {
        // Audio-side PIDs are allowlisted for identification only; opening
        // them for I/O is refused at the transport level.
        let mock = MockHIDTransport(
            info: MockHIDTransport.makeInfo(vendorID: 0x03F0, productID: 0x07B4)
        )
        #expect(throws: HIDTransportError.unsupportedDevice(vendorID: 0x03F0, productID: 0x07B4)) {
            try mock.open()
        }
    }

    @Test func quadCast2ControllerIsAllowlisted() {
        let known = DeviceAllowlist.lookup(vendorID: 0x03F0, productID: 0x09AF)
        #expect(known?.model == .quadCast2)
        #expect(known?.supportsLEDControl == true)
        #expect(known?.role == .ledController)
    }

    @Test func quadCast2UsesControlTransferPath() {
        // Hardware-verified: the QuadCast 2 controller's HID descriptor
        // declares no writable reports, so commands must go via raw EP0
        // SET_REPORT to interface 0. Other devices keep the HID path.
        let qc2 = DeviceAllowlist.lookup(vendorID: 0x03F0, productID: 0x09AF)
        #expect(qc2?.sendPath == .controlTransfer(interface: 0))
        let qc2s = DeviceAllowlist.lookup(vendorID: 0x03F0, productID: 0x02B5)
        #expect(qc2s?.sendPath == .hidReports)
    }
}
