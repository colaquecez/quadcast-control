import Testing
@testable import QuadCastKit

/// A fake encoder that produces *verified* packets, letting tests exercise the
/// full send path with a trivially inspectable one-packet-per-state format:
/// `[kind, brightness, R, G, B]`.
private struct FakeVerifiedEncoder: LightingProtocolEncoding {
    let model: HyperXModel = .quadCast2
    let capabilities: LightingCapabilities = [.onOff, .brightness, .staticColor]
    var refreshNeeded = false

    var reportPolicy: HIDReportPolicy {
        HIDReportPolicy(
            allowedReportIDs: [.feature: [0x01]],
            maxPayloadLength: [.feature: 8]
        )
    }

    func apply(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        let payload: [UInt8] = [
            state.isOn ? 0x01 : 0x00,
            state.brightness.deviceByte,
            state.color.red, state.color.green, state.color.blue,
        ]
        return [
            EncodedCommand(
                report: HIDReport(kind: .feature, reportID: 0x01, payload: payload),
                verification: .verified(source: "test fixture")
            )
        ]
    }

    var refreshInterval: Duration? { refreshNeeded ? .milliseconds(10) : nil }

    func refresh(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        try apply(state)
    }

    func save(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        throw .unsupportedByHardware(model: model, what: "save")
    }
}

/// An encoder that refuses everything, mirroring an unverified protocol.
private struct RefusingEncoder: LightingProtocolEncoding {
    let model: HyperXModel = .quadCast2
    let capabilities: LightingCapabilities = []
    var reportPolicy: HIDReportPolicy { .readOnly }
    func apply(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        throw .commandNotYetVerified(model: model)
    }
    var refreshInterval: Duration? { nil }
    func refresh(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        throw .commandNotYetVerified(model: model)
    }
    func save(_ state: LightingState) throws(ProtocolError) -> [EncodedCommand] {
        throw .commandNotYetVerified(model: model)
    }
}

/// An allowlisted mock (QuadCast 2 controller IDs).
private func makeAllowlistedMock() -> MockHIDTransport {
    MockHIDTransport(
        info: MockHIDTransport.makeInfo(
            vendorID: 0x03F0, productID: 0x09AF, name: "Mock QuadCast 2 Controller"
        )
    )
}

/// Service wired to a mock transport and the given encoder (bypassing
/// `ProtocolRegistry` so tests control encoder behavior), with control
/// already enabled.
private func makeService(
    encoder: any LightingProtocolEncoding,
    transport: MockHIDTransport,
    debounce: Duration = .milliseconds(20)
) async throws -> LightingService {
    let service = LightingService(debounceInterval: debounce, log: HIDLog())
    try await service.attach(transport: transport, onDisconnect: {})
    await service.overrideEncoderForTesting(encoder)
    await service.enableControl()
    return service
}

@Suite("Lighting service")
struct LightingServiceTests {
    @Test func connectionStateTracksAttachDetach() async throws {
        let mock = makeAllowlistedMock()
        let service = LightingService(log: HIDLog())
        #expect(await !service.isAttached)

        try await service.attach(transport: mock, onDisconnect: {})
        #expect(await service.isAttached)
        #expect(mock.isOpen)

        await service.detach()
        #expect(await !service.isAttached)
        #expect(!mock.isOpen)
    }

    @Test func attachRejectsNonAllowlistedDevice() async {
        let mock = MockHIDTransport(info: MockHIDTransport.makeInfo(productID: 0xDEAD))
        let service = LightingService(log: HIDLog())
        await #expect(throws: (any Error).self) {
            try await service.attach(transport: mock, onDisconnect: {})
        }
        #expect(await !service.isAttached)
    }

    @Test func attachRejectsAudioSidePID() async {
        // 0x07B4 is the QuadCast 2 *audio* device: allowlisted for
        // identification, but LED control must refuse to bind to it.
        let mock = MockHIDTransport(
            info: MockHIDTransport.makeInfo(vendorID: 0x03F0, productID: 0x07B4),
            bypassAllowlist: true
        )
        let service = LightingService(log: HIDLog())
        await #expect(throws: (any Error).self) {
            try await service.attach(transport: mock, onDisconnect: {})
        }
    }

    @Test func nothingIsSentBeforeUserOptIn() async throws {
        let mock = makeAllowlistedMock()
        let service = LightingService(debounceInterval: .milliseconds(5), log: HIDLog())
        try await service.attach(transport: mock, onDisconnect: {})
        await service.overrideEncoderForTesting(FakeVerifiedEncoder())

        await service.setPower(on: true)
        await service.setBrightness(Brightness(percent: 40))
        await service.settle()

        #expect(mock.sentReports.isEmpty)
        #expect(await service.lastError == .controlNotEnabled)
    }

    @Test func debouncedBrightnessSendsOnce() async throws {
        let mock = makeAllowlistedMock()
        let service = try await makeService(encoder: FakeVerifiedEncoder(), transport: mock)
        mock.clearSentReports()

        // Simulate a slider drag: many updates inside one debounce window.
        for percent in [10, 20, 30, 40, 50] {
            await service.setBrightness(Brightness(percent: percent))
        }
        await service.settle()

        // One flush → one packet, carrying the *last* value only.
        #expect(mock.sentReports.count == 1)
        #expect(mock.sentReports.first?.payload[1] == Brightness(percent: 50).deviceByte)
    }

    @Test func separateDebounceWindowsSendSeparately() async throws {
        let mock = makeAllowlistedMock()
        let service = try await makeService(
            encoder: FakeVerifiedEncoder(),
            transport: mock,
            debounce: .milliseconds(5)
        )
        mock.clearSentReports()

        await service.setBrightness(Brightness(percent: 25))
        await service.settle()
        await service.setBrightness(Brightness(percent: 75))
        await service.settle()

        #expect(mock.sentReports.count == 2)
    }

    @Test func colorChangeCarriesRGBBytes() async throws {
        let mock = makeAllowlistedMock()
        let service = try await makeService(encoder: FakeVerifiedEncoder(), transport: mock)
        mock.clearSentReports()

        await service.setColor(RGBColor(red: 0x11, green: 0x22, blue: 0x33))
        await service.settle()

        #expect(mock.sentReports.last?.payload.suffix(3) == [0x11, 0x22, 0x33])
    }

    @Test func unverifiedEncoderNeverSends() async throws {
        let mock = makeAllowlistedMock()
        let service = try await makeService(encoder: RefusingEncoder(), transport: mock)
        mock.clearSentReports()

        await service.setPower(on: true)
        await service.setBrightness(Brightness(percent: 30))
        await service.setColor(.white)
        await service.settle()

        #expect(mock.sentReports.isEmpty)
        #expect(await service.sendCount == 0)
        let lastError = await service.lastError
        #expect(lastError == .encoding(.commandNotYetVerified(model: .quadCast2)))
    }

    @Test func refreshLoopKeepsSending() async throws {
        let mock = makeAllowlistedMock()
        var encoder = FakeVerifiedEncoder()
        encoder.refreshNeeded = true
        let service = try await makeService(encoder: encoder, transport: mock)
        mock.clearSentReports()

        try await Task.sleep(for: .milliseconds(100))
        #expect(mock.sentReports.count >= 2) // several refresh ticks landed

        await service.disableControl()
        try await Task.sleep(for: .milliseconds(30))
        let countAfterStop = mock.sentReports.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(mock.sentReports.count == countAfterStop) // loop actually stopped
    }

    @Test func disconnectionIsHandledWithoutCrashing() async throws {
        let mock = makeAllowlistedMock()
        let service = try await makeService(encoder: FakeVerifiedEncoder(), transport: mock)

        mock.simulateDisconnect()
        // Give the actor hop inside the disconnect handler a chance to land.
        try await Task.sleep(for: .milliseconds(50))

        #expect(await !service.isAttached)

        // Further intents fail soft with a typed error, and nothing crashes.
        await service.setPower(on: true)
        #expect(await service.lastError == .noDeviceAttached)
    }

    @Test func restorePreviousReappliesAttachTimeState() async throws {
        let mock = makeAllowlistedMock()
        let service = try await makeService(encoder: FakeVerifiedEncoder(), transport: mock)
        let original = await service.state

        await service.setColor(RGBColor(red: 9, green: 9, blue: 9))
        await service.setBrightness(Brightness(percent: 1))
        await service.settle()
        await service.restorePrevious()

        #expect(await service.state == original)
    }

    @Test func mockTransportRoundTripsFeatureReports() throws {
        let mock = makeAllowlistedMock()
        try mock.open()
        mock.stubFeatureReport(id: 0x05, response: [0xDE, 0xAD])
        #expect(try mock.getFeatureReport(reportID: 0x05, maxLength: 8) == [0xDE, 0xAD])
        #expect(throws: HIDTransportError.unsupportedReportID(0x06)) {
            try mock.getFeatureReport(reportID: 0x06, maxLength: 8)
        }
    }
}
