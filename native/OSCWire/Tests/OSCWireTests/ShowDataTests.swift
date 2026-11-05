import Foundation
import XCTest
@testable import OSCWire

final class ShowDataTests: XCTestCase {
    func testFixtureParametersPreservePhysicalRangesAndRejectMalformedPackets() {
        let params = EosFixtureParameter.parse(["ETC", "Spot", "Pan", -12.5, -270, 270, "Gobo_Select", 3, 0, 255])
        XCTAssertEqual(params.count, 2)
        XCTAssertEqual(params[0].minimum, -270)
        XCTAssertEqual(params[0].level, -12.5)
        XCTAssertEqual(params[1].oscName, "gobo_select")
        XCTAssertTrue(EosFixtureParameter.parse(["ETC", "Spot", "Pan", 5]).isEmpty)
        XCTAssertTrue(EosFixtureParameter.parse(["ETC", "Spot", "Pan", 0, 20, -20]).isEmpty)
    }

    func testOutOfOrderCueChunksAndPartsStaySeparate() {
        var data = EosShowData()
        data.receive(OSCMessage(address: "/eos/out/get/cue/1/2/0/list/26/2", parameters: [2, "Cue notes"]))
        data.receive(OSCMessage(address: "/eos/out/get/cue/1/2/0/list/0/4", parameters: [1, "uid", "Opening", 4000]))
        data.receive(OSCMessage(address: "/eos/out/get/cue/1/2/1/list/0/3", parameters: [2, "part", "Moving lights"]))
        XCTAssertEqual(data.records["cue/1/2/0"]?[27] as? String, "Cue notes")
        XCTAssertEqual(data.records["cue/1/2/0"]?[2] as? String, "Opening")
        XCTAssertEqual(data.records["cue/1/2/1"]?[2] as? String, "Moving lights")
        XCTAssertNil(data.receive(OSCMessage(address: "/eos/out/get/cue/1/2/0/list/0/5", parameters: [1])))
    }

    func testPaletteChannelsAndSubmasterEffectsAreIndependentAndClearable() {
        var data = EosShowData()
        data.receive(OSCMessage(address: "/eos/out/get/cp/2/channels/list/2/2", parameters: [1, "3-8"]))
        data.receive(OSCMessage(address: "/eos/out/get/cp/2/list/0/3", parameters: [0, "uid", "Blue"]))
        data.receive(OSCMessage(address: "/eos/out/get/sub/1/fx/list/0/3", parameters: [0, "uid", "901"]))
        XCTAssertEqual(data.records["cp/2/channels"]?[3] as? String, "3-8")
        data.clear("cp")
        XCTAssertNil(data.records["cp/2"])
        XCTAssertNotNil(data.records["sub/1/fx"])
    }

    func testPatchTextFieldsAndPartsSurviveSplitPackets() {
        var data = EosFixtureAccumulator()
        _ = data.receive(OSCMessage(address: "/eos/out/get/patch/28/1/list/9/2", parameters: ["Stage left", "Electric 2"]))
        let fixture = data.receive(OSCMessage(address: "/eos/out/get/patch/28/1/list/0/9", parameters: [0, "uid", "Mover", "ETC", "Spot", 1, 1, 80, "R80"]))
        XCTAssertEqual(fixture?.textFields.first, "Stage left")
    }
}

final class CueListTargetTests: XCTestCase {
    func testQualifiedCueTargetAndInvalidLists() throws {
        let message = try EosCommands.goToCue("2.5", list: 3)
        XCTAssertEqual(message.parameters.first as? String, "Go_To_Cue 3/2.5 Enter")
        XCTAssertThrowsError(try EosCommands.goToCue("2", list: -1))
        XCTAssertThrowsError(try EosCommands.goToCue("2 Enter Go", list: 1))
    }
}
