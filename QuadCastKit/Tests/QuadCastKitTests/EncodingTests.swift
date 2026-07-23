import Testing
@testable import QuadCastKit

@Suite("RGB color encoding")
struct RGBColorTests {
    @Test func byteInitPassesThrough() {
        let c = RGBColor(red: 1, green: 2, blue: 3)
        #expect(c.rgbBytes == [1, 2, 3])
    }

    @Test func unitFloatConversionRoundsAndClamps() {
        #expect(RGBColor(unitRed: 1.0, unitGreen: 0.0, unitBlue: 0.5).rgbBytes == [255, 0, 128])
        // Out-of-range and non-finite inputs clamp instead of trapping.
        #expect(RGBColor(unitRed: 2.0, unitGreen: -1.0, unitBlue: 0.0).rgbBytes == [255, 0, 0])
        #expect(RGBColor(unitRed: .nan, unitGreen: .infinity, unitBlue: -.infinity).rgbBytes == [0, 255, 0])
    }

    @Test func hexRoundTrip() {
        let c = RGBColor(hexString: "#1A2B3C")
        #expect(c == RGBColor(red: 0x1A, green: 0x2B, blue: 0x3C))
        #expect(c?.hexString == "1A2B3C")
        #expect(RGBColor(hexString: "12345") == nil)
        #expect(RGBColor(hexString: "GGGGGG") == nil)
        #expect(RGBColor(hexString: "") == nil)
    }
}

@Suite("Brightness conversion")
struct BrightnessTests {
    @Test func percentClampsOnConstruction() {
        #expect(Brightness(percent: -5).percent == 0)
        #expect(Brightness(percent: 150).percent == 100)
        #expect(Brightness(percent: 42).percent == 42)
    }

    @Test func deviceByteScaling() {
        #expect(Brightness(percent: 0).deviceByte == 0)
        #expect(Brightness(percent: 100).deviceByte == 255)
        #expect(Brightness(percent: 50).deviceByte == 128)
    }

    @Test func deviceByteRoundTripIsStable() {
        for percent in [0, 1, 25, 50, 99, 100] {
            let b = Brightness(percent: percent)
            #expect(Brightness(deviceByte: b.deviceByte).percent == percent)
        }
    }
}

@Suite("HID packet construction")
struct PacketBuilderTests {
    @Test func padsToFixedLength() throws {
        let packet = try HIDPacketBuilder.fixedLength([0xAA, 0xBB], length: 8)
        #expect(packet == [0xAA, 0xBB, 0, 0, 0, 0, 0, 0])
    }

    @Test func exactLengthUnchanged() throws {
        let bytes: [UInt8] = [1, 2, 3, 4]
        #expect(try HIDPacketBuilder.fixedLength(bytes, length: 4) == bytes)
    }

    @Test func rejectsOversizedPayload() {
        #expect(throws: HIDPacketBuilder.BuildError.payloadTooLong(max: 4, actual: 5)) {
            try HIDPacketBuilder.fixedLength([1, 2, 3, 4, 5], length: 4)
        }
    }
}

@Suite("Hex parsing")
struct HexDumpTests {
    @Test func parsesSpacedAndPrefixedForms() {
        #expect(HexDump.parse("0A 1B 2C") == [0x0A, 0x1B, 0x2C])
        #expect(HexDump.parse("0x0a, 0x1b") == [0x0A, 0x1B])
        #expect(HexDump.parse("0a1b2c") == [0x0A, 0x1B, 0x2C])
    }

    @Test func rejectsMalformedInput() {
        #expect(HexDump.parse("zz") == nil)
        #expect(HexDump.parse("") == nil)
        #expect(HexDump.parse("0A 1") == [0x0A, 0x01])  // short token is a valid nibble
        #expect(HexDump.parse("123") == nil)  // odd-length contiguous run
    }
}
