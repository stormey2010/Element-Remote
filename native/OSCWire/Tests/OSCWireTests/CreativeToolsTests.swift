import Foundation
import XCTest
@testable import OSCWire

final class CreativeToolsTests: XCTestCase {
    func testFanTargetsEverySelectedChannelInAscendingOrder() throws {
        let messages = try EosCreativeCommands.fan(channels:[9,1,5,5],parameter:"pan",start:-30,end:30)
        XCTAssertEqual(messages.map(\.address),["/eos/chan/1/param/pan","/eos/chan/5/param/pan","/eos/chan/9/param/pan"])
        XCTAssertEqual(messages.compactMap { $0.parameters.first as? Double },[-30,0,30])
        XCTAssertThrowsError(try EosCreativeCommands.fan(channels:[],parameter:"pan",start:0,end:1))
        XCTAssertThrowsError(try EosCreativeCommands.fan(channels:[1],parameter:"reset",start:0,end:1))
    }
    func testXYZRejectsInvalidValuesAndKeepsMeters() throws {
        let message = try EosCreativeCommands.xyz(x:1.25,y:-3,z:0)
        XCTAssertEqual(message.address,"/eos/xyz")
        XCTAssertEqual(message.parameters as? [Double],[1.25,-3,0])
        XCTAssertThrowsError(try EosCreativeCommands.xyz(x:.nan,y:0,z:0))
    }
    func testQRNeverExecutesArbitraryCommands() {
        XCTAssertEqual(EosCreativeCommands.channel(fromQR:"elementremote://channel/28"),28)
        XCTAssertEqual(EosCreativeCommands.channel(fromQR:"28"),28)
        XCTAssertNil(EosCreativeCommands.channel(fromQR:"https://example.com/channel/28"))
        XCTAssertNil(EosCreativeCommands.channel(fromQR:"elementremote://channel/28?cmd=go"))
        XCTAssertNil(EosCreativeCommands.channel(fromQR:"Chan 28 At Full Enter"))
    }
    func testTimelineRecognizesConsoleEventsAndRoundTrips() throws {
        XCTAssertEqual(EosRehearsalEvent.detail(address:"/eos/out/event/cue/1/2/fire",values:["Storm"]),"Cue 1/2 · fire · Storm")
        XCTAssertNil(EosRehearsalEvent.detail(address:"/eos/out/param/pan",values:[1]))
        let events = [EosRehearsalEvent(show:"Hamlet",detail:"Cue 1/2 fire")]
        XCTAssertEqual(try JSONDecoder().decode([EosRehearsalEvent].self,from:JSONEncoder().encode(events)).first?.detail,events.first?.detail)
    }
    func testLargeGetParamsReplyFitsCodec() throws {
        var args: [Any] = ["ETC","Fixture"]
        for index in 0..<90 { args += ["Parameter_\(index)",0.0,0.0,100.0] }
        func padded(_ text: String) -> Data { var data = Data(text.utf8); data.append(0); while data.count % 4 != 0 { data.append(0) }; return data }
        var data = padded("/eos/out/get/params/1") + padded(",ss" + String(repeating:"sfff",count:90))
        data += padded("ETC") + padded("Fixture")
        for index in 0..<90 {
            data += padded("Parameter_\(index)")
            for value: Float in [0,0,100] { let bits = value.bitPattern; data += Data([UInt8((bits >> 24)&255),UInt8((bits >> 16)&255),UInt8((bits >> 8)&255),UInt8(bits&255)]) }
        }
        let messages = try OSCCodec.decode(data)
        XCTAssertEqual(EosFixtureParameter.parse(messages[0].parameters).count,90)
    }
    func testQLabUsesExplicitExternalEncoderOptIn() throws {
        let message = OSCMessage(address:"/cue/12/start",parameters:[])
        XCTAssertThrowsError(try OSCCodec.encode(message))
        let encoded = try OSCCodec.encode(message,allowExternalAddress:true)
        XCTAssertEqual(try OSCCodec.decode(encoded).first?.address,"/cue/12/start")
    }
    func testPracticeFanDoesNotChangeOtherSelectedFixtures() {
        var desk = EosPracticeDesk()
        desk.setChannelParameter(1,name:"pan",value:-20)
        desk.setChannelParameter(3,name:"pan",value:20)
        XCTAssertEqual(desk.parameters[1]?["pan"],-20)
        XCTAssertEqual(desk.parameters[3]?["pan"],20)
    }
}
