import Foundation
import XCTest
@testable import OSCWire

final class ConsoleInsightsTests: XCTestCase {
    func testIndependentUserModeDoesNotIssueLightingCommands() {
        let own = EosCapabilities.userSelection(independent:true)
        XCTAssertEqual(own.address,"/eos/user/auto")
        XCTAssertTrue(own.parameters.isEmpty)
        let follow = EosCapabilities.userSelection(independent:false)
        XCTAssertEqual(follow.address,"/eos/user")
        XCTAssertEqual(follow.parameters.first as? Int,-1)
    }
    func testHealthVersionGateRequiresExactMinimum() {
        XCTAssertFalse(EosCapabilities.supportsHealthSubscriptions("3.3"))
        XCTAssertFalse(EosCapabilities.supportsHealthSubscriptions("3.3.4.1"))
        XCTAssertTrue(EosCapabilities.supportsHealthSubscriptions("3.3.5.1"))
        XCTAssertTrue(EosCapabilities.supportsHealthSubscriptions("3.4.0"))
        XCTAssertFalse(EosCapabilities.supportsHealthSubscriptions("Unknown"))
    }
    func testProcessorHealthDoesNotTreatMalformedOrUnknownAsHealthy() {
        XCTAssertNil(EosProcessorHealth.parse([1]))
        let row: [Any] = [7,-1,true,3,"Main","Element","Element Classic","10.101.1.1","1>2"]
        let parsed = EosProcessorHealth.parse(row)
        XCTAssertEqual(parsed?.statusText,"Critical")
        XCTAssertEqual(parsed?.ip,"10.101.1.1")
        var unknown = row; unknown[3] = 99
        XCTAssertEqual(EosProcessorHealth.parse(unknown)?.statusText,"Unknown")
    }
    func testComparisonsIncludeMissingParamsAndRanges() {
        let a = EosFixtureParameter.parse(["ETC","Spot","Pan",10,-270,270,"Zoom",30,5,50])
        let b = EosFixtureParameter.parse(["ETC","Wash","PAN",10,-270,270,"Zoom",30,10,60,"Red",50,0,100])
        let rows = EosParameterComparison.rows(a,b)
        XCTAssertEqual(rows.map(\.id),["pan","red","zoom"])
        XCTAssertFalse(rows[0].differs)
        XCTAssertTrue(rows[1].differs)
        XCTAssertTrue(rows[2].differs)
    }
    func testUsersParseTupleStrideWithoutInventingUsers() {
        XCTAssertEqual(EosConsoleUser.parse([3,1,"Element","Desk",2,"OSC","Phone"]).map(\.id),[1,2])
        XCTAssertTrue(EosConsoleUser.parse([4,1,"Element","Desk"]).isEmpty)
        XCTAssertTrue(EosConsoleUser.parse([3,1,"Element"]).isEmpty)
    }
    func testEffectPresetAndCuelistMetadataAccumulate() {
        var show = EosShowData()
        XCTAssertNotNil(show.receive(OSCMessage(address:"/eos/out/get/fx/901/list/0/3",parameters:[0,"uid","Circle"])))
        XCTAssertNotNil(show.receive(OSCMessage(address:"/eos/out/get/preset/5/channels/list/0/3",parameters:[0,"uid","1-5"])))
        XCTAssertEqual(show.records["fx/901"]?[2] as? String,"Circle")
    }
}
