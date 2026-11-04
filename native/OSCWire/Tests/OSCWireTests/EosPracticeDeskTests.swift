import XCTest
@testable import OSCWire

final class EosPracticeDeskTests: XCTestCase {
    func testNumbersDefaultToChanAndFreshEntryAfterEnter() throws {
        var desk = EosPracticeDesk()
        for key in ["4", "2"] { try desk.press(key) }
        XCTAssertEqual(desk.commandLine, "Chan 42")
        for key in ["@", "full", "enter"] { try desk.press(key) }
        XCTAssertEqual(desk.selection?.channels, [42])
        XCTAssertEqual(desk.parameters[42]?["intens"], 100)
        try desk.press("7")
        XCTAssertEqual(desk.commandLine, "Chan 7")
        XCTAssertEqual(desk.selection?.channels, [42], "Pending typing must not change the committed selection")
        try desk.press("enter")
        XCTAssertEqual(desk.selection?.channels, [7])
    }
    func testSelectionSurvivesIntensityThenMovementAndColor() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Chan 1 Thru 5 - 3 + 12 At Full Enter")
        let selected = [1, 2, 4, 5, 12]
        XCTAssertEqual(desk.selection?.channels, selected)
        desk.wheel("pan", ticks: 20, fine: false)
        desk.wheel("tilt", ticks: -5, fine: true)
        desk.setColor([210, 75])
        desk.setColor([0.2, 0.3], xy: true)
        XCTAssertEqual(desk.selection?.channels, selected)
        for channel in selected {
            XCTAssertEqual(desk.parameters[channel]?["intens"], 100)
            XCTAssertEqual(desk.parameters[channel]?["pan"], 20)
            XCTAssertEqual(desk.parameters[channel]?["tilt"], -0.5)
            XCTAssertEqual(desk.colors[channel], [210, 75])
            XCTAssertEqual(desk.coordinates[channel], [0.2, 0.3])
        }
        XCTAssertNil(desk.parameters[3])
        try desk.execute("Chan 9 Enter")
        desk.wheel("pan", ticks: 2, fine: false)
        desk.setColor([0, 100])
        XCTAssertEqual(desk.parameters[9]?["pan"], 2)
        XCTAssertEqual(desk.parameters[1]?["pan"], 20)
        XCTAssertEqual(desk.colors[1], [210, 75])
    }
    func testAtUsesExistingChannelsAndDoesNotInsertChanBeforeLevel() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Chan 42 Enter")
        for key in ["@", "5", "0"] { try desk.press(key) }
        XCTAssertEqual(desk.commandLine, "At 50")
        try desk.press("enter")
        XCTAssertEqual(desk.parameters[42]?["intens"], 50)
        for key in ["cue", "1", "2"] { try desk.press(key) }
        XCTAssertEqual(desk.commandLine, "Cue 12")
        try desk.press("enter")
        XCTAssertEqual(desk.selection?.channels, [42])
    }
    func testQuickActionsAndClearSelection() throws {
        var desk = EosPracticeDesk()
        let selection = try EosChannelSelection("10 Thru 12")
        try desk.execute(try XCTUnwrap(selection.select().parameters.first as? String))
        try desk.execute(try XCTUnwrap(selection.brightness(75).parameters.first as? String))
        desk.setColor([90, 50])
        XCTAssertEqual(desk.parameters[11]?["intens"], 75)
        try desk.press("8")
        try desk.press("clear_cmd")
        XCTAssertEqual(desk.selection?.channels, [10, 11, 12])
        try desk.press("clear_cmd")
        XCTAssertNil(desk.selection)
        desk.wheel("pan", ticks: 12, fine: false)
        XCTAssertNil(desk.parameters[11]?["pan"])
        desk.setColor([0, 0])
        XCTAssertEqual(desk.colors[11], [90, 50])
    }
    func testInvalidEntryCannotReplaceSelectionOrChangeLevels() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Chan 5 At 75 Enter")
        XCTAssertThrowsError(try desk.execute("Chan 2 Thru Enter"))
        XCTAssertThrowsError(try desk.execute("Chan 8 At 999 Enter"))
        XCTAssertEqual(desk.selection?.channels, [5])
        XCTAssertEqual(desk.parameters[5]?["intens"], 75)
        XCTAssertNil(desk.parameters[8])
        try desk.execute("+ 9 Enter")
        XCTAssertEqual(desk.selection?.channels, [5, 9])
    }
}

final class ConsoleWorkflowTests: XCTestCase {
    func testGroupSelectionUsesMembersAndRetainsThemForColorAndMovement() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Group 2 At Full Enter")
        XCTAssertEqual(desk.selection?.channels, [5, 6, 7, 8])
        desk.setColor([200, 70]); desk.wheel("pan", ticks: 5, fine: false)
        XCTAssertEqual(desk.colors[5], [200, 70])
        XCTAssertNil(desk.colors[2])
        XCTAssertEqual(desk.parameters[8]?["intens"], 100)
        XCTAssertEqual(desk.parameters[5]?["pan"], 5)
        XCTAssertThrowsError(try desk.execute("Group 999 Enter"))
        XCTAssertEqual(desk.selection?.channels, [5, 6, 7, 8])
    }
    func testChannelCheckLowersPreviousChannelAndStepsSelection() throws {
        var desk = EosPracticeDesk()
        for key in ["chan", "1", "full", "check", "enter"] { try desk.press(key) }
        XCTAssertTrue(desk.checking)
        try desk.press("next")
        XCTAssertEqual(desk.selection?.channels, [2])
        XCTAssertEqual(desk.parameters[1]?["intens"], 0)
        XCTAssertEqual(desk.parameters[2]?["intens"], 100)
        try desk.press("last")
        XCTAssertEqual(desk.selection?.channels, [1])
        XCTAssertEqual(desk.parameters[2]?["intens"], 0)
        try desk.press("clear_cmd")
        XCTAssertFalse(desk.checking)
    }
    func testRemDimRestoresOriginalLevelsAndHighlightToggles() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Chan 9 At 75 Enter")
        try desk.execute("Chan 1 At Full Enter")
        try desk.press("rem_dim")
        XCTAssertEqual(desk.parameters[9]?["intens"], 0)
        XCTAssertEqual(desk.parameters[1]?["intens"], 100)
        try desk.press("rem_dim")
        XCTAssertEqual(desk.parameters[9]?["intens"], 75)
        try desk.press("highlight")
        XCTAssertTrue(desk.highlighted)
        try desk.press("highlight")
        XCTAssertFalse(desk.highlighted)
    }
    func testPatchSelectionFeedbackDoesNotTreatLevelsAsChannels() {
        XCTAssertEqual(EosSelectionContext.channels(from: "1-3 [100]"), [1, 2, 3])
        XCTAssertEqual(EosSelectionContext.channels(from: "Chan 5, 8 [50]"), [5, 8])
        XCTAssertEqual(EosSelectionContext.channels(from: "1 Thru 5 - 3 [75]"), [1, 2, 4, 5])
        XCTAssertEqual(EosSelectionContext.channels(from: "No channel feedback yet"), [])
        XCTAssertEqual(EosSelectionContext.channels(from: "Group 12"), [])
        XCTAssertEqual(EosSelectionContext.channels(from: "1-999999 [100]"), [])
    }
    func testDiscoveryBoundsAndExcludesSelfNetworkAndBroadcast() {
        let hosts = EosDiscoveryHosts.candidates(ip: "192.168.4.65", mask: "255.255.255.0")
        XCTAssertEqual(hosts.count, 253)
        XCTAssertFalse(hosts.contains("192.168.4.65"))
        XCTAssertFalse(hosts.contains("192.168.4.0"))
        XCTAssertFalse(hosts.contains("192.168.4.255"))
        XCTAssertTrue(hosts.contains("192.168.4.10"))
        XCTAssertEqual(EosDiscoveryHosts.candidates(ip: "10.1.2.10", mask: "255.255.255.248"), ["10.1.2.9", "10.1.2.11", "10.1.2.12", "10.1.2.13", "10.1.2.14"])
        XCTAssertEqual(EosDiscoveryHosts.candidates(ip: "127.0.0.1", mask: "255.0.0.0"), [])
        XCTAssertEqual(EosDiscoveryHosts.candidates(ip: "10.1.2.10", mask: "255.0.255.0"), [])
    }
    func testLargeSubnetIsRestrictedToNearbyAddresses() {
        let hosts = EosDiscoveryHosts.candidates(ip: "10.101.20.30", mask: "255.255.0.0")
        XCTAssertEqual(hosts.count, 253)
        XCTAssertTrue(hosts.allSatisfy { $0.hasPrefix("10.101.20.") })
    }
    func testCueFadeDoesNotChangeSelectionAndRespectsPark() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Chan 3 At 80 Park Enter")
        try desk.execute("Group 2 Enter")
        desk.fadeCue(4, from: [3: 80, 5: 100], progress: 0.5)
        XCTAssertEqual(desk.selection?.channels, [5, 6, 7, 8])
        XCTAssertEqual(desk.parameters[3]?["intens"], 80)
        XCTAssertEqual(desk.parameters[5]?["intens"], 50)
        desk.fadeCue(4, from: [5: 100], progress: 1)
        XCTAssertEqual(desk.parameters[5]?["intens"], 0)
    }
}

final class ChannelCheckWireTests: XCTestCase {
    func testSharedChannelCheckSequenceHasNoCuePlaybackCommands() throws {
        let messages = try EosCommands.channelCheck(42)
        XCTAssertEqual(messages.map(\.address), ["clear_cmd", "chan", "4", "2", "full", "check", "enter"].map { "/eos/key/" + $0 })
        XCTAssertTrue(messages.allSatisfy { $0.parameters.isEmpty })
        XCTAssertThrowsError(try EosCommands.channelCheck(0))
        var desk = EosPracticeDesk()
        for message in messages { try desk.press(String(message.address.split(separator: "/").last!)) }
        XCTAssertEqual(desk.selection?.channels, [42])
        XCTAssertEqual(desk.parameters[42]?["intens"], 100)
        try desk.press("next")
        XCTAssertEqual(desk.selection?.channels, [43])
    }
}

final class ExternalPracticeCommandTests: XCTestCase {
    func testPlaybackCompletionClearsEntryAndPreservesChannelSelection() throws {
        var desk = EosPracticeDesk()
        try desk.execute("Chan 42 At Full Enter")
        for key in ["go_to_cue", "1", ".", "5"] { try desk.press(key) }
        XCTAssertEqual(desk.entry.trimmingCharacters(in: .whitespaces), "Go_To_Cue 1.5")
        desk.completeExternalCommand("Go_To_Cue 1.5 Enter")
        XCTAssertEqual(desk.selection?.channels, [42])
        XCTAssertEqual(desk.parameters[42]?["intens"], 100)
        try desk.press("7")
        XCTAssertEqual(desk.commandLine, "Chan 7")
    }
}
