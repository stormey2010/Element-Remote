import Foundation
import XCTest
@testable import OSCWire

final class PatchAddressTests: XCTestCase {
    private func fixture(start: Int, end: Int?) -> EosFixtureRecord {
        EosFixtureRecord(channel: 1, part: 1, label: "LED", manufacturer: "ETC", model: "LED", address: start, intensityAddress: start, level: 0, gel: "", notes: "", endingAddress: end)
    }

    func testUniverseOneIsImplicitAndRangesUseActualEnd() {
        XCTAssertEqual(fixture(start: 1, end: 5).patchAddress, "1 Thru 5")
        XCTAssertEqual(fixture(start: 9, end: 9).patchAddress, "9")
        XCTAssertEqual(fixture(start: 513, end: 517).patchAddress, "2/1 Thru 2/5")
        XCTAssertEqual(fixture(start: 511, end: 515).patchAddress, "1/511 Thru 2/3")
    }

    func testLegacyAndInvalidEndDoNotInventAFootprint() {
        XCTAssertEqual(fixture(start: 12, end: nil).patchAddress, "12")
        XCTAssertEqual(fixture(start: 12, end: 11).patchAddress, "12")
        XCTAssertEqual(fixture(start: 0, end: nil).patchAddress, "Unpatched")
    }

    func testEndingAddressArrivesInASeparateOSCPacket() {
        var accumulator = EosFixtureAccumulator()
        let legacy: [Any] = [0, "uid", "LED", "ETC", "LED_Mode", 1, 1, 0, "", "", "", "", "", "", "", "", "", "", "", 1]
        let initial = accumulator.receive(OSCMessage(address: "/eos/out/get/patch/1/1/list/0/20", parameters: legacy))
        XCTAssertNil(initial?.endingAddress)
        XCTAssertEqual(initial?.patchAddress, "1")
        let complete = accumulator.receive(OSCMessage(address: "/eos/out/get/patch/1/1/list/20/1", parameters: [5]))
        XCTAssertEqual(complete?.endingAddress, 5)
        XCTAssertEqual(complete?.patchAddress, "1 Thru 5")
    }
}
