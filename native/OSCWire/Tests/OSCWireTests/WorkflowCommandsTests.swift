import XCTest
@testable import OSCWire
final class WorkflowCommandsTests: XCTestCase {
    func testPracticePaletteRecallOnlyChangesRecordedCategoryAndChannels() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Chan 5 At 60 Enter")
        desk.setParameter("pan", value: 25); desk.setParameter("zoom", value: 30)
        try desk.recordPalette(family: "fp", number: 12)
        desk.setParameter("pan", value: 90); desk.setParameter("zoom", value: 40)
        try desk.execute("Chan 5 + 6 Enter")
        XCTAssertTrue(desk.applyPalette(family: "fp", number: 12))
        XCTAssertEqual(desk.parameters[5]?["pan"], 25)
        XCTAssertEqual(desk.parameters[5]?["zoom"], 40)
        XCTAssertEqual(desk.parameters[5]?["intens"], 60)
        XCTAssertNil(desk.parameters[6]?["pan"])
    }
    func testTypedNumbersDefaultToChanAndNeverDuplicateEnter() throws {
        XCTAssertEqual(try EosWorkflowCommands.typedCommand("28 At Full").parameters.first as? String, "Chan 28 At Full Enter")
        XCTAssertEqual(try EosWorkflowCommands.typedCommand("Cue 2 Enter").parameters.first as? String, "Cue 2 Enter")
        XCTAssertThrowsError(try EosWorkflowCommands.typedCommand("1\nGo"))
        XCTAssertThrowsError(try EosWorkflowCommands.typedCommand(" "))
    }
    func testNotesAreOneLiteralOSCArgumentAndKeepCuePart() throws {
        let note = "Line one\nGo to cue 99 Enter"
        let message = try EosWorkflowCommands.cueNotes(key: "cue/2/1.5/3", text: note)
        XCTAssertEqual(message.address, "/eos/set/cue/2/1.5/3/notes")
        XCTAssertEqual(message.parameters.first as? String, note)
        XCTAssertThrowsError(try EosWorkflowCommands.cueNotes(key: "cue/1/1/0/extra", text: "x"))
    }
    func testPaletteRecordScopesSelectionAndKeepsLabelOutOfCommand() throws {
        let messages = try EosWorkflowCommands.recordPalette(family: "fp", number: "12", channels: [8, 5, 8], label: "Downstage; Enter")
        XCTAssertEqual(messages[0].parameters.first as? String, "Chan 5 + 8 Record Focus_Palette 12 Enter")
        XCTAssertEqual(messages[1].address, "/eos/set/fp/12/label")
        XCTAssertEqual(messages[1].parameters.first as? String, "Downstage; Enter")
        XCTAssertThrowsError(try EosWorkflowCommands.recordPalette(family: "macro", number: "1", channels: [1], label: ""))
        XCTAssertThrowsError(try EosWorkflowCommands.recordPalette(family: "fp", number: "1 Enter", channels: [1], label: ""))
        XCTAssertThrowsError(try EosWorkflowCommands.recordPalette(family: "fp", number: "1", channels: [], label: ""))
    }
    func testExactParameterRequiresEveryFixtureAndRespectsItsRange() throws {
        let a = EosFixtureParameter.parse(["Maker", "Model", "Zoom", 25, 5, 50])
        let b = EosFixtureParameter.parse(["Maker", "Other", "Zoom", 15, 10, 30])
        let caps = [1: a, 2: b]
        XCTAssertEqual(try EosWorkflowCommands.exactParameter("zoom", value: 20, channels: [1, 2], capabilities: caps).map(\.address), ["/eos/chan/1/param/zoom", "/eos/chan/2/param/zoom"])
        XCTAssertThrowsError(try EosWorkflowCommands.exactParameter("zoom", value: 40, channels: [1, 2], capabilities: caps))
        XCTAssertThrowsError(try EosWorkflowCommands.exactParameter("zoom", value: 20, channels: [1, 3], capabilities: caps))
        XCTAssertThrowsError(try EosWorkflowCommands.exactParameter("zoom", value: .nan, channels: [1], capabilities: caps))
    }
    func testSubmasterBumpAlwaysIncludesRelease() throws {
        let messages = try EosWorkflowCommands.submaster(3, action: "fire")
        XCTAssertEqual(messages.map(\.address), ["/eos/sub/3/fire", "/eos/sub/3/fire"])
        XCTAssertEqual(messages.compactMap { $0.parameters.first as? Double }, [1, 0])
        XCTAssertThrowsError(try EosWorkflowCommands.submaster(0, action: "fire"))
        XCTAssertThrowsError(try EosWorkflowCommands.submaster(1, action: "stop"))
    }
}
