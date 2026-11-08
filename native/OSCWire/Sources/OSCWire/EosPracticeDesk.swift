import Foundation

/// Local practice state only. Live selections and command lines come from Eos.
public struct EosPracticeDesk {
    public private(set) var entry = ""
    public private(set) var commandLine = ""
    public private(set) var selection: EosChannelSelection?
    public private(set) var parameters: [Int: [String: Double]] = [:]
    public private(set) var colors: [Int: [Double]] = [:]
    public private(set) var coordinates: [Int: [Double]] = [:]
    public private(set) var checking = false
    public private(set) var highlighted = false
    public private(set) var parked: Set<Int> = []
    public private(set) var addresses: [Int:Double] = [:]
    private struct StoredPalette {
        let values: [Int: [String: Double]]
        let colors: [Int: [Double]]
        let coordinates: [Int: [Double]]
    }
    private var palettes: [String: StoredPalette] = [:]
    public mutating func recordPalette(family: String, number: Int) throws {
        guard ["fp", "cp", "bp"].contains(family), (1...999999).contains(number), let selection else { throw OSCWireError.invalid("Choose fixtures and a palette") }
        let colorNames: Set<String> = ["red","green","blue","amber","lime","cyan","magenta","yellow","hue","sat","saturation","color_temp","tint"]
        var captured: [Int:[String:Double]] = [:]
        for channel in selection.channels {
            captured[channel] = (parameters[channel] ?? [:]).filter { name, _ in
                if family == "fp" { return ["pan","tilt"].contains(name) }
                if family == "cp" { return colorNames.contains(name) }
                return !["pan","tilt","intens","intensity"].contains(name) && !colorNames.contains(name)
            }
        }
        palettes["\(family)/\(number)"] = StoredPalette(values: captured, colors: family == "cp" ? colors.filter { selection.channels.contains($0.key) } : [:], coordinates: family == "cp" ? coordinates.filter { selection.channels.contains($0.key) } : [:])
    }
    @discardableResult public mutating func applyPalette(family: String, number: Int) -> Bool {
        guard let stored = palettes["\(family)/\(number)"], let selection else { return false }
        for channel in selection.channels {
            for (name, value) in stored.values[channel] ?? [:] { parameters[channel, default: [:]][name] = value }
            if let color = stored.colors[channel] { colors[channel] = color }
            if let xy = stored.coordinates[channel] { coordinates[channel] = xy }
        }
        return true
    }
    private var previousSelection: EosChannelSelection?
    private var remainderSnapshot: [Int: [String: Double]]?
    public static let groups: [Int: String] = [1: "1 Thru 4", 2: "5 Thru 8", 3: "9 Thru 12"]
    public init() {}

    public mutating func press(_ key: String) throws {
        if key == "clear_cmd" {
            // Clear a pending entry first; Clear after Enter deselects channels.
            if entry.isEmpty { previousSelection = selection; selection = nil; checking = false }
            entry = ""; commandLine = ""; return
        }
        if key == "next" || key == "last" {
            guard let old = selection?.channels.first else { return }
            let channel = min(max(old + (key == "next" ? 1 : -1), 1), 512)
            if checking { setParameter("intens", value: 0) }
            previousSelection = selection; selection = try EosChannelSelection(String(channel))
            if checking { setParameter("intens", value: 100) }
            commandLine = "Chan \(channel)"; entry = ""; return
        }
        if key == "select_last" {
            let old = selection; selection = previousSelection; previousSelection = old
            commandLine = selection.map { "Chan " + $0.expression } ?? ""; entry = ""; return
        }
        if entry.isEmpty && ["highlight", "rem_dim"].contains(key) { try execute(key == "highlight" ? "High" : "Rem_Dim"); return }
        if key == "enter" { try execute(entry); return }
        let labels = ["chan": "Chan", "@": "At", "full": "Full", "out": "Out", "level": "Level", "thru": "Thru", "cue": "Cue", "sub": "Sub", "group": "Group", "record": "Record", "go_to_cue": "Go_To_Cue", "rem_dim": "Rem_Dim", "highlight": "High", "sneak": "Sneak", "home": "Home", "check": "Check", "park": "Park", "address":"Address"]
        let digit = key.count == 1 && key.first?.isNumber == true
        if digit {
            if entry.isEmpty { entry = "Chan " }
            entry += key
        } else if key == "chan" {
            entry = "Chan "
        } else if key == "." {
            entry += "."
        } else {
            let label = labels[key] ?? key
            entry = entry.trimmingCharacters(in: .whitespaces) + (entry.isEmpty ? "" : " ") + label + " "
        }
        commandLine = entry.trimmingCharacters(in: .whitespaces)
    }

    public mutating func execute(_ command: String) throws {
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.lowercased() != "enter" }
        guard !tokens.isEmpty else { return }
        if tokens[0].lowercased() == "address" {
            let split = tokens.dropFirst().firstIndex { Int($0) == nil && !["thru","+","-"].contains($0.lowercased()) } ?? tokens.endIndex
            let target = try EosChannelSelection(tokens[1..<split].joined(separator:" "))
            let action = tokens[split...].map { $0.lowercased() }.filter { $0 != "at" }
            if !action.isEmpty {
                let value: Double? = action == ["full"] ? 100 : action == ["out"] ? 0 : action.count == 1 ? Double(action[0]) : nil
                guard let value, (0...100).contains(value) else { throw OSCWireError.invalid("Enter an address level from 0 to 100") }
                for address in target.channels { addresses[address] = value }
            }
            entry = ""; commandLine = tokens.joined(separator:" "); return
        }
        var next = selection
        var rest = tokens
        if tokens[0].lowercased() == "group" {
            guard tokens.count >= 2, let number = Int(tokens[1]), let expression = Self.groups[number] else {
                throw OSCWireError.invalid("Sample show groups are 1 (LEDs), 2 (movers), and 3 (dimmers)")
            }
            next = try EosChannelSelection(expression); rest = Array(tokens.dropFirst(2))
        } else if tokens[0].lowercased() == "chan" {
            let split = tokens.dropFirst().firstIndex { Int($0) == nil && !["thru", "+", "-"].contains($0.lowercased()) } ?? tokens.endIndex
            next = try EosChannelSelection(tokens[1..<split].joined(separator: " "))
            rest = Array(tokens[split...])
        } else if ["+", "-"].contains(tokens[0]), let previous = selection {
            let split = tokens.firstIndex { Int($0) == nil && !["thru", "+", "-"].contains($0.lowercased()) } ?? tokens.endIndex
            next = try EosChannelSelection(previous.channels.map(String.init).joined(separator: " + ") + " " + tokens[..<split].joined(separator: " "))
            rest = Array(tokens[split...])
        } else if !["at", "full", "out", "level", "home", "high", "highlight", "rem_dim", "sneak", "check", "park"].contains(tokens[0].lowercased()) {
            // A cue/sub/record number is never a channel number.
            if ["cue", "sub"].contains(tokens[0].lowercased()) {
                entry = ""; commandLine = tokens.joined(separator: " "); return
            }
            throw OSCWireError.invalid("This command isn’t simulated in the practice show")
        }
        let allActions = rest.map { $0.lowercased() }.filter { $0 != "at" }
        let channelCheck = allActions.contains("check")
        let park = allActions.contains("park")
        let action = allActions.filter { $0 != "check" && $0 != "park" }
        var level: Double?
        if action == ["full"] { level = 100 }
        else if action == ["out"] { level = 0 }
        else if action == ["level"] { level = 80 }
        else if let first = action.first, let number = Double(first), action.count == 1 {
            guard number.isFinite, (0...100).contains(number) else { throw OSCWireError.invalid("Intensity must be between 0 and 100") }
            level = number
        } else if !action.isEmpty && !["home", "high", "highlight", "rem_dim", "sneak"].contains(action.joined(separator: " ")) {
            throw OSCWireError.invalid("Finish the channel command before Enter")
        }
        if !rest.isEmpty && next == nil { throw OSCWireError.invalid("Select channels first") }
        if next != selection { previousSelection = selection }
        selection = next
        if channelCheck { checking = true }
        if park { parked.formUnion(next?.channels ?? []) }
        if action == ["high"] || action == ["highlight"] { highlighted.toggle() }
        if action == ["rem_dim"] {
            if let snapshot = remainderSnapshot { parameters = snapshot; remainderSnapshot = nil }
            else {
                remainderSnapshot = parameters
                let chosen = Set(next?.channels ?? [])
                for channel in 1...512 where !chosen.contains(channel) { parameters[channel, default: [:]]["intens"] = 0 }
            }
        }
        if let level { setParameter("intens", value: level) }
        if action == ["home"] {
            for (name, value) in ["pan": 0.0, "tilt": 0.0, "zoom": 35.0, "edge": 50.0] { setParameter(name, value: value) }
        }
        entry = ""; commandLine = tokens.joined(separator: " ")
    }

    public mutating func completeExternalCommand(_ command: String) {
        entry = ""; commandLine = command
    }
    public mutating func unpark(_ channels:[Int]) { parked.subtract(channels) }
    public mutating func setChannelParameter(_ channel: Int, name: String, value: Double) {
        guard (1...999999).contains(channel), value.isFinite else { return }
        parameters[channel, default: [:]][name] = value
    }
    public mutating func setParameter(_ name: String, value: Double) {
        guard value.isFinite else { return }
        for channel in selection?.channels ?? [] { parameters[channel, default: [:]][name] = value }
    }
    public mutating func wheel(_ name: String, ticks: Double, fine: Bool) {
        guard ticks.isFinite else { return }
        let defaults = ["intens": 0.0, "pan": 0.0, "tilt": 0.0, "zoom": 35.0, "edge": 50.0, "iris": 100.0, "color_temp": 3200.0]
        let bounds: ClosedRange<Double> = name == "pan" ? -270...270 : name == "tilt" ? -135...135 : name == "color_temp" ? 1000...10000 : 0...100
        for channel in selection?.channels ?? [] {
            let old = parameters[channel]?[name] ?? defaults[name] ?? 0
            parameters[channel, default: [:]][name] = min(max(old + ticks * (fine ? 0.1 : 1), bounds.lowerBound), bounds.upperBound)
        }
    }
    public mutating func extreme(_ name: String, maximum: Bool) {
        let value: Double = name == "pan" ? (maximum ? 270 : -270) : name == "tilt" ? (maximum ? 135 : -135) : name == "color_temp" ? (maximum ? 10000 : 1000) : maximum ? 100 : 0
        setParameter(name, value: value)
    }
    public mutating func fadeCue(_ number: Int, from start: [Int: Double], progress: Double) {
        let p = min(max(progress, 0), 1)
        for channel in 1...12 where !parked.contains(channel) {
            let destination: Double = number == 0 || number == 4 ? 0 : number == 2 ? 50 : number == 3 ? 25 : 100
            parameters[channel, default: [:]]["intens"] = (start[channel] ?? 0) + (destination - (start[channel] ?? 0)) * p
        }
    }
    public mutating func setColor(_ values: [Double], xy: Bool = false) {
        guard values.count == 2, values.allSatisfy({ $0.isFinite }) else { return }
        for channel in selection?.channels ?? [] {
            if xy { coordinates[channel] = values } else { colors[channel] = values }
        }
    }
}

/// Selection feedback is a channel expression followed by a bracketed level, not a group ID.
public enum EosSelectionContext {
    public static func channels(from feedback: String) -> [Int] {
        var text = String(feedback.prefix(1024).split(separator: "[", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("chan ") { text = String(text.dropFirst(5)) }
        text = text.replacingOccurrences(of: "([0-9]+)[-–]([0-9]+)", with: "$1 Thru $2", options: .regularExpression)
        return (try? EosChannelSelection(text))?.channels ?? []
    }
}

/// Bound local discovery to at most the phone's current /24, within its actual subnet.
public enum EosDiscoveryHosts {
    public static func candidates(ip: String, mask: String) -> [String] {
        func number(_ text: String) -> UInt32? {
            let parts = text.split(separator: ".")
            guard parts.count == 4 else { return nil }
            var result: UInt32 = 0
            for part in parts { guard let byte = UInt32(part), byte <= 255 else { return nil }; result = result << 8 | byte }
            return result
        }
        guard let address = number(ip), let netmask = number(mask), address >> 24 > 0, address >> 24 != 127, address >> 24 < 224 else { return [] }
        let inverse = ~netmask
        guard inverse > 1, inverse & (inverse &+ 1) == 0 else { return [] }
        let network = address & netmask, broadcast = network | inverse
        let nearby = address & 0xffffff00
        let low = max(network + 1, nearby + 1), high = min(broadcast - 1, nearby + 254)
        guard low <= high else { return [] }
        return (low...high).filter { $0 != address }.map { value in
            [24, 16, 8, 0].map { String((value >> $0) & 255) }.joined(separator: ".")
        }
    }
}
