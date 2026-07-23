import Testing
@testable import QuadCastKit

@Suite("QuadCast 2 protocol encoding")
struct QuadCast2ProtocolTests {
    let encoder = QuadCast2Protocol()

    @Test func brightnessPacketMatchesDocumentedFormat() throws {
        // quadcastrgb issue #21: `81 XX 00 00 81 XX 00 00` + 56 zero bytes.
        let state = LightingState(isOn: true, brightness: Brightness(percent: 100), color: .white)
        let packets = try encoder.apply(state)
        #expect(packets.count == 2)

        let brightness = packets[0].report
        #expect(brightness.kind == .feature)
        #expect(brightness.reportID == 0x00)
        #expect(brightness.payload.count == 64)
        #expect(Array(brightness.payload.prefix(8)) == [0x81, 0xF2, 0, 0, 0x81, 0xF2, 0, 0])
        #expect(brightness.payload.dropFirst(8).allSatisfy { $0 == 0 })
    }

    @Test func heartbeatCarriesBrightnessInByte1() throws {
        // The heartbeat's byte 1 must equal the brightness value, or the
        // hardware flickers (documented in the capture analysis).
        let state = LightingState(isOn: true, brightness: Brightness(percent: 50), color: .white)
        let packets = try encoder.apply(state)
        let heartbeat = packets[1].report
        let expectedLevel = QuadCast2Protocol.deviceBrightness(for: state)
        #expect(Array(heartbeat.payload.prefix(10)) ==
            [0x04, expectedLevel, 0, 0, 0, 0, 0, 0, 0x01, 0x00])
        #expect(heartbeat.payload.count == 64)
    }

    @Test func brightnessScaleTopsOutAt0xF2() {
        // Device range is 0x00...0xF2 — NOT 0...255.
        #expect(QuadCast2Protocol.deviceBrightness(
            for: LightingState(isOn: true, brightness: .full, color: .white)) == 0xF2)
        #expect(QuadCast2Protocol.deviceBrightness(
            for: LightingState(isOn: true, brightness: .off, color: .white)) == 0x00)
        #expect(QuadCast2Protocol.deviceBrightness(
            for: LightingState(isOn: false, brightness: .full, color: .white)) == 0x00)
    }

    @Test func packetsAreCommunityVerified() throws {
        let packets = try encoder.apply(LightingState())
        #expect(packets.allSatisfy { $0.isVerified })
    }

    @Test func colorIsNotACapability() {
        #expect(!encoder.capabilities.contains(.staticColor))
        #expect(encoder.capabilities.contains(.brightness))
    }

    @Test func saveIsRefusedAsUnsupported() {
        #expect(throws: ProtocolError.unsupportedByHardware(model: .quadCast2, what: "save-to-device")) {
            try encoder.save(LightingState())
        }
    }

    @Test func policyOnlyAllowsFeatureReportZero() {
        let policy = encoder.reportPolicy
        let good = HIDReport(kind: .feature, reportID: 0x00, payload: [UInt8](repeating: 0, count: 64))
        let badID = HIDReport(kind: .feature, reportID: 0x01, payload: [0x00])
        let badKind = HIDReport(kind: .output, reportID: 0x00, payload: [0x00])
        #expect((try? policy.validate(good)) != nil)
        #expect(throws: HIDTransportError.unsupportedReportID(0x01)) { try policy.validate(badID) }
        #expect(throws: HIDTransportError.unsupportedReportID(0x00)) { try policy.validate(badKind) }
    }
}

@Suite("QuadCast 2 S protocol encoding")
struct QuadCast2SProtocolTests {
    let encoder = QuadCast2SProtocol()

    @Test func directModeSequenceShape() throws {
        let state = LightingState(
            isOn: true,
            brightness: .full,
            color: RGBColor(red: 0xC9, green: 0x00, blue: 0x76)
        )
        let packets = try encoder.apply(state)
        // Header + 6 data packets.
        #expect(packets.count == 7)
        #expect(Array(packets[0].report.payload.prefix(4)) == [0x44, 0x01, 0x06, 0x00])

        // Verified against the public NGENUITY capture in quadcastrgb #18:
        // color #c90076 → `44 02 <idx> 00 c9 00 76 c9 00 76 ...`.
        let third = packets[3].report.payload
        #expect(Array(third.prefix(4)) == [0x44, 0x02, 0x02, 0x00])
        #expect(Array(third[4..<10]) == [0xC9, 0x00, 0x76, 0xC9, 0x00, 0x76])
        #expect(packets.allSatisfy { $0.report.payload.count == 64 })
        #expect(packets.allSatisfy { $0.isVerified })
    }

    @Test func brightnessScalesColorChannelsHostSide() {
        let state = LightingState(
            isOn: true,
            brightness: Brightness(percent: 50),
            color: RGBColor(red: 200, green: 100, blue: 0)
        )
        let scaled = QuadCast2SProtocol.scaledColor(for: state)
        #expect(scaled == RGBColor(red: 100, green: 50, blue: 0))
    }

    @Test func offMeansBlack() {
        let state = LightingState(isOn: false, brightness: .full, color: .white)
        #expect(QuadCast2SProtocol.scaledColor(for: state) == .black)
    }

    @Test func saveSequenceEndsWithFramerateAndCommit() throws {
        let packets = try encoder.save(LightingState())
        #expect(packets.count == 9) // initiate + 6 data + framerate + commit
        #expect(Array(packets[0].report.payload.prefix(4)) == [0x44, 0x03, 0x01, 0x06])
        #expect(Array(packets[7].report.payload.prefix(7)) == [0x42, 0x02, 0x00, 0x00, 0x00, 0xE8, 0x03])
        #expect(Array(packets[8].report.payload.prefix(5)) == [0x40, 0x01, 0x00, 0x00, 0xFF])
    }
}

@Suite("Protocol registry")
struct ProtocolRegistryTests {
    @Test func quadCast2GetsBrightnessOnlyEncoder() throws {
        let known = try #require(DeviceAllowlist.lookup(vendorID: 0x03F0, productID: 0x09AF))
        let encoder = try #require(ProtocolRegistry.encoder(for: known))
        #expect(encoder.model == .quadCast2)
        #expect(!encoder.capabilities.contains(.staticColor))
    }

    @Test func quadCast2SGetsFullEncoder() throws {
        let known = try #require(DeviceAllowlist.lookup(vendorID: 0x03F0, productID: 0x02B5))
        let encoder = try #require(ProtocolRegistry.encoder(for: known))
        #expect(encoder.model == .quadCast2S)
        #expect(encoder.capabilities.contains(.staticColor))
    }

    @Test func audioPIDsGetNoEncoder() throws {
        let audio = try #require(DeviceAllowlist.lookup(vendorID: 0x03F0, productID: 0x07B4))
        #expect(ProtocolRegistry.encoder(for: audio) == nil)
    }

    @Test func quadCastSRecognizedButNotImplemented() throws {
        let known = try #require(DeviceAllowlist.lookup(vendorID: 0x0951, productID: 0x171F))
        #expect(known.model == .quadCastS)
        #expect(ProtocolRegistry.encoder(for: known) == nil)
    }
}

@Suite("Packet diff developer tool")
struct PacketDiffTests {
    @Test func highlightsChangedBytes() throws {
        let result = try PacketDiff.compare(
            beforeHex: "44 02 02 00 C9 00 76",
            afterHex: "44 02 02 00 2F AC ED"
        )
        #expect(result.diffs.map(\.offset) == [4, 5, 6])
        #expect(result.hypotheses.contains { $0.contains("RGB color triplet") })
    }

    @Test func identicalPacketsReportNoDiffs() throws {
        let result = try PacketDiff.compare(beforeHex: "01 02 03", afterHex: "01 02 03")
        #expect(result.isIdentical)
    }

    @Test func singleByteChangeSuggestsScalarField() throws {
        let result = try PacketDiff.compare(
            beforeHex: "81 40 00 00",
            afterHex: "81 F2 00 00"
        )
        #expect(result.diffs.count == 1)
        #expect(result.hypotheses.contains { $0.contains("scalar field") })
    }

    @Test func malformedHexIsATypedError() {
        #expect(throws: PacketDiff.ParseError.invalidHex(which: "after")) {
            try PacketDiff.compare(beforeHex: "01", afterHex: "zz")
        }
    }
}
