import XCTest
@testable import OSCWire

final class CommandPresentationTests: XCTestCase {
    func testConsoleTerminatorBecomesCompletionState() {
        let command = EosCommandPresentation("LIVE: Cue 1 : Chan 28 #")
        XCTAssertEqual(command.text, "LIVE: Cue 1 : Chan 28")
        XCTAssertTrue(command.isComplete)
    }
    func testEditingAndErrorsAreNotCompletedCommands() {
        XCTAssertFalse(EosCommandPresentation("Chan 28 At").isComplete)
        XCTAssertFalse(EosCommandPresentation("Chan 28 #", isError: true).isComplete)
        XCTAssertFalse(EosCommandPresentation("#").isComplete)
    }
    func testPracticeCommandsShareThePresentation() {
        XCTAssertEqual(EosCommandPresentation("Cue 2 Enter").text, "Cue 2")
        XCTAssertTrue(EosCommandPresentation("Cue 2 Enter").isComplete)
        XCTAssertTrue(EosCommandPresentation("Chan 28", practiceComplete: true).isComplete)
        XCTAssertFalse(EosCommandPresentation("", practiceComplete: true).isComplete)
        XCTAssertEqual(EosCommandPresentation("Record Cue 2 Label Enter House").text, "Record Cue 2 Label Enter House")
    }
    func testNewPracticeEntryRemovesCompletionAndRetainsSelection() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Chan 28 Enter")
        XCTAssertTrue(EosCommandPresentation(desk.commandLine, practiceComplete: desk.entry.isEmpty).isComplete)
        try desk.press("@")
        XCTAssertFalse(EosCommandPresentation(desk.commandLine, practiceComplete: desk.entry.isEmpty).isComplete)
        XCTAssertEqual(desk.selection?.channels, [28])
    }
}
