import Foundation
import XCTest
@testable import OSCWire
final class AddressKeyTests: XCTestCase {
    func testAddressKeyUsesTheVerifiedConsoleKey() throws {
        let messages = try EosCommands.keyTap("address")
        XCTAssertEqual(messages.map(\.address),["/eos/key/address","/eos/key/address"])
        XCTAssertEqual(messages.compactMap { $0.parameters.first as? Double },[1,0])
    }
    func testPracticeAddressEntryDoesNotBecomeAChannel() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Chan 28 At 50 Enter")
        for key in ["address","1","2","@","full","enter"] { try desk.press(key) }
        XCTAssertEqual(desk.addresses[12],100)
        XCTAssertEqual(desk.selection?.channels,[28])
        XCTAssertEqual(desk.parameters[28]?["intens"],50)
    }
}
