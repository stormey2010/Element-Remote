import Foundation
import XCTest
@testable import OSCWire

final class QuickParkTests: XCTestCase {
    func testParkLevelAlwaysTargetsExplicitSelection() throws {
        let selection = try EosChannelSelection("1 Thru 5 - 3 + 12")
        let command = try selection.parkIntensity(75)
        XCTAssertEqual(command.parameters.first as? String,"Chan 1 Thru 5 - 3 + 12 At 75 Park Enter")
        XCTAssertThrowsError(try selection.parkIntensity(101))
    }
    func testUnparkUsesParkDisplayAndNeverGlobalParkCommand() throws {
        let selection = try EosChannelSelection("28 + 30")
        let commands = selection.unpark()
        XCTAssertEqual(commands.first?.address,"/eos/key/open_park_blind")
        XCTAssertEqual(commands[2].parameters.first as? String,"Chan 28 + 30 At Enter Enter")
        XCTAssertEqual(commands.last?.address,"/eos/key/live")
        XCTAssertEqual(selection.unpark(restoreBlind:true).last?.address,"/eos/key/blind")
    }
    func testPracticeUnparkOnlyReleasesRequestedChannels() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Chan 1 + 2 At 75 Park Enter")
        desk.unpark([1])
        XCTAssertFalse(desk.parked.contains(1))
        XCTAssertTrue(desk.parked.contains(2))
        XCTAssertEqual(desk.parameters[2]?["intens"],75)
    }
}
