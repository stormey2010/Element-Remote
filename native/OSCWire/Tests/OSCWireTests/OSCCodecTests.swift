import XCTest
@testable import OSCWire
final class OSCCodecTests: XCTestCase {
    func testColorArgumentsAndKeyEdges() throws {
        let bytes = try OSCCodec.encode(OSCMessage(address: "/eos/color/hs", parameters: [180.0, 75.0]))
        let result = try XCTUnwrap(OSCCodec.decode(bytes).first)
        XCTAssertEqual(result.address, "/eos/color/hs")
        XCTAssertEqual(result.parameters.compactMap { $0 as? Float }, [180, 75])
        for edge in [1.0, 0.0] {
            let key = try OSCCodec.encode(OSCMessage(address: "/eos/key/go_0", parameters: [edge]))
            XCTAssertEqual(try OSCCodec.decode(key).first?.parameters.first as? Float, Float(edge))
        }
    }
    func testUTF8AndBool() throws {
        let bytes = try OSCCodec.encode(OSCMessage(address: "/eos/cmd", parameters: ["Café 🎭", true, false]))
        let result = try XCTUnwrap(OSCCodec.decode(bytes).first)
        XCTAssertEqual(result.parameters[0] as? String, "Café 🎭")
        XCTAssertEqual(result.parameters[1] as? Bool, true)
        XCTAssertEqual(result.parameters[2] as? Bool, false)
    }
    func testFramingHandlesEveryByteSeparately() throws {
        let payload = Data([1, 0xc0, 0xdb, 2])
        for mode in [OSCStreamDecoder.Framing.packetLength, .slip] {
            let frame = OSCStreamDecoder.frame(payload, mode), decoder = OSCStreamDecoder(mode)
            var results: [Data] = []
            for byte in frame { results += try decoder.append(Data([byte])) }
            XCTAssertEqual(results, [payload])
            XCTAssertEqual(try decoder.append(frame + frame), [payload, payload])
        }
    }
    func testTruncatedAndOversizedFramesAreRejected() throws {
        XCTAssertThrowsError(try OSCCodec.decode(Data([47, 101, 111, 115])))
        XCTAssertThrowsError(try OSCStreamDecoder(.packetLength).append(Data([255, 255, 255, 255])))
        XCTAssertThrowsError(try OSCCodec.encode(OSCMessage(address: "bad", parameters: [])))
        XCTAssertThrowsError(try OSCCodec.encode(OSCMessage(address: "/eos/at", parameters: [Double.infinity])))
    }
    func testReferenceCuePacketFromOSCJS() throws {
        // Generated independently by the Node osc package with explicit OSC types.
        let hex = "2f656f732f6f75742f6375656c6973742f312f33000000002c73737373734669690000003132204576656e696e670000313200004576656e696e6700000000000000000000001388ffffffff"
        let chars = Array(hex); var bytes: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) { bytes.append(UInt8(String(chars[i...i+1]), radix: 16)!) }
        let message = try XCTUnwrap(OSCCodec.decode(Data(bytes)).first)
        XCTAssertEqual(message.address, "/eos/out/cuelist/1/3")
        XCTAssertEqual(message.parameters[1] as? String, "12")
        XCTAssertEqual(message.parameters[2] as? String, "Evening")
        XCTAssertEqual(message.parameters[5] as? Bool, false)
        XCTAssertEqual(message.parameters[6] as? Int32, 5000)
        XCTAssertEqual(message.parameters[7] as? Int32, -1)
    }
}

extension OSCCodecTests {
    func testIntegerWireTypesMatchIndependentOSCReference() throws {
        let packet = try OSCCodec.encode(OSCMessage(address: "/eos/get/patch/index", parameters: [Int(7)]))
        // OSC 1.0 string padding, explicit integer typetag, big-endian Int32.
        let expected = Data(Array("/eos/get/patch/index".utf8) + [0,0,0,0] + Array(",i".utf8) + [0,0,0,0,0,7])
        XCTAssertEqual(packet, expected)
        XCTAssertEqual(try OSCCodec.decode(packet).first?.parameters.first as? Int32, 7)
        let floating = try OSCCodec.encode(OSCMessage(address: "/eos/fader/1/1", parameters: [0.5]))
        XCTAssertEqual(try OSCCodec.decode(floating).first?.parameters.first as? Float, 0.5)
        XCTAssertThrowsError(try OSCCodec.encode(OSCMessage(address: "/eos/get/patch/index", parameters: [Int64.max])))
    }
    func testAllAppKeyNamesHaveBothEdges() throws {
        for name in EosCommands.supportedKeys {
            let edges = try EosCommands.keyTap(name)
            XCTAssertEqual(edges.map(\.address), ["/eos/key/" + name, "/eos/key/" + name])
            XCTAssertEqual(try edges.flatMap { try OSCCodec.decode(OSCCodec.encode($0)) }.compactMap { $0.parameters.first as? Float }, [1, 0])
        }
        let udpTap = try EosCommands.keyTap("go_0", edges: false)
        XCTAssertEqual(udpTap.count, 1)
        XCTAssertTrue(udpTap[0].parameters.isEmpty)
        XCTAssertThrowsError(try EosCommands.keyTap("unverified-key"))
    }
    func testOriginalElementAndModernPatchQueries() throws {
        for version in ["", "2.9.0.1.0.1"] {
            let message = try EosCommands.patchRequest(index: 24, version: version)
            XCTAssertEqual(message.address, "/eos/get/patch/index/24")
            XCTAssertTrue(message.parameters.isEmpty)
        }
        let modern = try EosCommands.patchRequest(index: 24, version: "3.3.0")
        XCTAssertEqual(modern.address, "/eos/get/patch/index")
        XCTAssertEqual(try OSCCodec.decode(OSCCodec.encode(modern)).first?.parameters.first as? Int32, 24)
        XCTAssertThrowsError(try EosCommands.patchRequest(index: -1, version: "2.9"))
    }
    func testFaderBumpsDoNotSetLevelsAndCueCommandsStartClean() throws {
        for n in 1...40 {
            let bump = try EosCommands.faderBump(n)
            XCTAssertEqual(bump.address, "/eos/fader/1/\(n)/fire")
            XCTAssertTrue(bump.parameters.isEmpty)
            XCTAssertEqual(try OSCCodec.decode(OSCCodec.encode(EosCommands.faderLevel(n, 0.75))).first?.parameters.first as? Float, 0.75)
        }
        XCTAssertThrowsError(try EosCommands.faderLevel(41, 0.5))
        XCTAssertThrowsError(try EosCommands.faderLevel(1, -.infinity))
        XCTAssertThrowsError(try EosCommands.faderLevel(1, 1.1))
        let cue = try EosCommands.goToCue("12.5")
        XCTAssertEqual(cue.address, "/eos/newcmd")
        XCTAssertEqual(cue.parameters.first as? String, "Go_To_Cue 12.5 Enter")
        XCTAssertThrowsError(try EosCommands.goToCue("1 Enter Record"))
        XCTAssertThrowsError(try EosCommands.goToCue("-1"))
    }
    func testVersionHandshakeAndParameterSubscriptionUseNoLightingCommands() throws {
        for message in [OSCMessage(address: "/eos/get/version", parameters: []), OSCMessage(address: "/eos/ping", parameters: ["round-trip-token"]), OSCMessage(address: "/eos/subscribe/param/intens/pan/tilt/edge/zoom", parameters: [1])] {
            let decoded = try XCTUnwrap(OSCCodec.decode(OSCCodec.encode(message)).first)
            XCTAssertEqual(decoded.address, message.address)
        }
        XCTAssertThrowsError(try OSCCodec.encode(OSCMessage(address: "/eosInvalid/key/go", parameters: [])))
    }
}

extension OSCCodecTests {
    func testQuickChannelSelectionGrammarAndBounds() throws {
        let selection = try EosChannelSelection("1 Thru 5 + 12 - 3")
        XCTAssertEqual(selection.expression, "1 Thru 5 + 12 - 3")
        XCTAssertEqual(selection.channels, [1,2,4,5,12])
        XCTAssertEqual(try EosChannelSelection("0042, 43").expression, "42 + 43")
        XCTAssertEqual(try EosChannelSelection("1 Thru 512").channels.count, 512)
        for invalid in ["", "0", "-1", "1+", "1 Thru", "5 Thru 1", "1 Enter Record", "1;2", "1 Thru 513", "1 - 1", "1000000"] {
            XCTAssertThrowsError(try EosChannelSelection(invalid), invalid)
        }
    }
    func testQuickActionsTargetTheEnteredChannels() throws {
        let selection = try EosChannelSelection("42 + 44")
        XCTAssertEqual(selection.select().parameters.first as? String, "Chan 42 + 44 Enter")
        XCTAssertEqual(try selection.brightness(50).parameters.first as? String, "Chan 42 + 44 At 50 Enter")
        XCTAssertEqual(selection.remDim().parameters.first as? String, "Chan 42 + 44 Rem_Dim Enter")
        XCTAssertEqual(selection.highlight().parameters.first as? String, "Chan 42 + 44 High Enter")
        XCTAssertEqual(selection.sneak().parameters.first as? String, "Chan 42 + 44 Sneak Enter")
        for message in [selection.select(), selection.remDim(), try selection.brightness(0), try selection.brightness(100)] {
            XCTAssertEqual(message.address, "/eos/newcmd")
            XCTAssertEqual(try OSCCodec.decode(OSCCodec.encode(message)).first?.parameters.first as? String, message.parameters.first as? String)
        }
        XCTAssertThrowsError(try selection.brightness(101))
        XCTAssertThrowsError(try selection.brightness(-1))
    }
    func testFixtureDetailsReassembleOutOfOrderPartsAndNotes() throws {
        var accumulator = EosFixtureAccumulator()
        // ETC's documented patch list order: index, UID, label, manufacturer, model,
        // address, intensity address, level, gel. Chunks can arrive independently.
        XCTAssertNil(accumulator.receive(OSCMessage(address: "/eos/out/get/patch/42/1/notes", parameters: [0,"uid","Cove left"])))
        XCTAssertNil(accumulator.receive(OSCMessage(address: "/eos/out/get/patch/42/1/list/5/4", parameters: [513,513,75,"R80"])))
        let record = try XCTUnwrap(accumulator.receive(OSCMessage(address: "/eos/out/get/patch/42/1/list/0/5", parameters: [0,"uid","Cove","ETC_Fixtures","S4_LED"])))
        XCTAssertEqual(record.channel, 42)
        XCTAssertEqual(record.label, "Cove")
        XCTAssertEqual(record.model, "S4_LED")
        XCTAssertEqual(record.universeAddress, "2/1")
        XCTAssertEqual(record.level, 75)
        XCTAssertEqual(record.notes, "Cove left")
        let part2 = try XCTUnwrap(accumulator.receive(OSCMessage(address: "/eos/out/get/patch/42/2/list/0/6", parameters: [1,"uid2","Second part","ETC","Dimmer",0])))
        XCTAssertEqual(part2.id, "42/2")
        XCTAssertEqual(part2.universeAddress, "Unpatched")
        accumulator.clear(channels: [42])
        XCTAssertNil(accumulator.receive(OSCMessage(address: "/eos/out/get/patch/42/1/notes", parameters: [0,"uid","new notes"])))
        XCTAssertNil(accumulator.receive(OSCMessage(address: "/eos/out/get/patch/43/1/list/129/1", parameters: ["oversize"])))
        XCTAssertNil(accumulator.receive(OSCMessage(address: "/eos/out/get/patch/43/1/list/0/4", parameters: ["wrong count"])))
    }
}

extension OSCCodecTests {
    func testHapticCadenceRespectsPreferenceAndLimitsContinuousPulses() {
        var gate = HapticCadence()
        XCTAssertFalse(gate.allow(at: 0, enabled: false))
        XCTAssertTrue(gate.allow(at: 0, enabled: true))
        XCTAssertFalse(gate.allow(at: 0.01, enabled: true))
        XCTAssertTrue(gate.allow(at: 0.04, enabled: true))
        XCTAssertFalse(gate.allow(at: 0.10, enabled: true, continuous: true))
        XCTAssertTrue(gate.allow(at: 0.23, enabled: true, continuous: true))
        XCTAssertFalse(gate.allow(at: 0.24, enabled: true, continuous: true))
        XCTAssertFalse(gate.allow(at: 0.50, enabled: false, continuous: true))
        XCTAssertTrue(gate.allow(at: 0.51, enabled: true, continuous: true))
        XCTAssertFalse(gate.allow(at: .nan, enabled: true))
        XCTAssertFalse(gate.allow(at: .infinity, enabled: true))
    }
}

extension OSCCodecTests {
    func testOutboundBufferCoalescesFortyLevelsAndPreservesLatestOrder() throws {
        var queue = OSCOutboundBuffer()
        for n in 1...40 { try queue.enqueue(EosCommands.faderLevel(n, 0.25), at: 0) }
        for n in 1...40 { try queue.enqueue(EosCommands.faderLevel(n, 0.75), at: 0.1) }
        XCTAssertEqual(queue.count, 40)
        for n in 1...40 {
            let message = try XCTUnwrap(queue.next(at: 0.2))
            XCTAssertEqual(message.address, "/eos/fader/1/\(n)")
            XCTAssertEqual(message.parameters.first as? Double, 0.75)
        }
        XCTAssertNil(queue.next(at: 0.2))
    }
    func testOutboundBufferKeepsDiscreteActionBarriers() throws {
        var queue = OSCOutboundBuffer()
        try queue.enqueue(EosCommands.faderLevel(1, 0.1), at: 0)
        try queue.enqueue(EosCommands.faderBump(1), at: 0.01)
        try queue.enqueue(EosCommands.faderLevel(1, 0.9), at: 0.02)
        XCTAssertEqual(queue.count, 3)
        XCTAssertEqual(queue.next(at: 0.1)?.parameters.first as? Double, 0.1)
        XCTAssertEqual(queue.next(at: 0.1)?.address, "/eos/fader/1/1/fire")
        XCTAssertEqual(queue.next(at: 0.1)?.parameters.first as? Double, 0.9)
    }
    func testOutboundBufferAccumulatesWheelTicksWithoutCrossingLevelChange() throws {
        var queue = OSCOutboundBuffer()
        try queue.enqueue(OSCMessage(address: "/eos/wheel/fine/pan", parameters: [2]), at: 0)
        try queue.enqueue(OSCMessage(address: "/eos/wheel/fine/pan", parameters: [-1]), at: 0.01)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.next(at: 0.1)?.parameters.first as? Int, 1)
        try queue.enqueue(OSCMessage(address: "/eos/wheel/coarse/intens", parameters: [2]), at: 0)
        try queue.enqueue(EosCommands.faderLevel(1, 0.5), at: 0.01)
        try queue.enqueue(OSCMessage(address: "/eos/wheel/coarse/intens", parameters: [1]), at: 0.02)
        XCTAssertEqual(queue.count, 3)
    }
    func testExpiredActionsClearFollowingEnterAndNeverReplay() throws {
        var queue = OSCOutboundBuffer()
        try queue.enqueue(OSCMessage(address: "/eos/key/record", parameters: []), at: 0)
        try queue.enqueue(OSCMessage(address: "/eos/key/enter", parameters: []), at: 0.9)
        XCTAssertNil(queue.next(at: 1.1))
        XCTAssertEqual(queue.count, 0)
        XCTAssertEqual(queue.expiredActions, 2)
        queue.clear()
        XCTAssertEqual(queue.expiredActions, 0)
        try queue.enqueue(EosCommands.faderLevel(1, 1), at: 0)
        XCTAssertNil(queue.next(at: 0.31))
    }
    func testBufferCapacityAndColorSpaceChanges() throws {
        var queue = OSCOutboundBuffer(limit: 2)
        try queue.enqueue(OSCMessage(address: "/eos/color/hs", parameters: [180.0, 50.0]), at: 0)
        try queue.enqueue(OSCMessage(address: "/eos/color/xy", parameters: [0.3, 0.4]), at: 0.01)
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.next(at: 0.1)?.address, "/eos/color/xy")
        for name in ["7", "8"] { try queue.enqueue(OSCMessage(address: "/eos/key/" + name, parameters: []), at: 0) }
        XCTAssertThrowsError(try queue.enqueue(OSCMessage(address: "/eos/key/9", parameters: []), at: 0))
        XCTAssertEqual(queue.count, 2)
    }
    func testVersionReplyIgnoresBooleanAndNonVersionMetadata() {
        XCTAssertEqual(EosVersionReply.softwareCandidate("3.3.10"), "3.3.10")
        XCTAssertEqual(EosVersionReply.softwareCandidate("2.9.3.1.0.1"), "2.9.3.1.0.1")
        XCTAssertNil(EosVersionReply.softwareCandidate(true))
        XCTAssertNil(EosVersionReply.softwareCandidate(1))
        XCTAssertNil(EosVersionReply.softwareCandidate("fixture library"))
    }
    func testUnsignedIntegerCannotWrapAndMalformedSLIPIsRejected() throws {
        XCTAssertThrowsError(try OSCCodec.encode(OSCMessage(address: "/eos/get/patch/index", parameters: [UInt64.max])))
        XCTAssertThrowsError(try OSCStreamDecoder(.slip).append(Data([0xc0,1,0xdb,0xc0])))
    }
    func testMaxSizeTCPFrameCanShareReadWithNextPacket() throws {
        let first = Data(repeating: 7, count: 1_048_576), second = Data([1,2,3])
        let decoder = OSCStreamDecoder(.packetLength)
        let results = try decoder.append(OSCStreamDecoder.frame(first, .packetLength) + OSCStreamDecoder.frame(second, .packetLength))
        XCTAssertEqual(results, [first, second])
    }
    func testOverlappingQuickLevelsKeepTheLatestTargetOrder() throws {
        var queue = OSCOutboundBuffer()
        let one = try EosChannelSelection("1"), both = try EosChannelSelection("1 + 2")
        try queue.enqueue(one.brightness(10), at: 0)
        try queue.enqueue(both.brightness(50), at: 0.01)
        try queue.enqueue(one.brightness(20), at: 0.02)
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.next(at: 0.1)?.parameters.first as? String, "Chan 1 + 2 At 50 Enter")
        XCTAssertEqual(queue.next(at: 0.1)?.parameters.first as? String, "Chan 1 At 20 Enter")
    }
}
