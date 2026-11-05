import Foundation
import CoreFoundation

public enum OSCWireError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case let .invalid(reason) = self { return reason }; return nil }
}

public struct OSCMessage {
    public let address: String
    public let parameters: [Any]
    public init(address: String, parameters: [Any]) { self.address = address; self.parameters = parameters }
}

public enum OSCCodec {
    private static func string(_ value: String) -> Data {
        var data = Data(value.utf8); data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }
    private static func uint32(_ value: UInt32) -> Data {
        Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
    }
    public static func encode(_ message: OSCMessage) throws -> Data {
        guard message.address.hasPrefix("/eos/"), message.address.count <= 256,
              !message.address.contains(where: { $0.isWhitespace || $0.asciiValue == 0 }), message.parameters.count <= 64 else {
            throw OSCWireError.invalid("Invalid OSC address or argument count")
        }
        var types = ",", payload = Data()
        for value in message.parameters {
            if let text = value as? String {
                guard text.utf8.count <= 8192, !text.utf8.contains(0) else { throw OSCWireError.invalid("Invalid OSC text") }
                types += "s"; payload.append(string(text))
            } else if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { types += number.boolValue ? "T" : "F" }
                else if ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)) {
                    let integer = number.int64Value
                    guard number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max), integer >= Int64(Int32.min), integer <= Int64(Int32.max) else { throw OSCWireError.invalid("OSC integer is outside Int32 range") }
                    types += "i"; payload.append(uint32(UInt32(bitPattern: Int32(integer))))
                } else {
                    let float = number.floatValue
                    guard float.isFinite else { throw OSCWireError.invalid("Invalid OSC number") }
                    types += "f"; payload.append(uint32(float.bitPattern))
                }
            } else { throw OSCWireError.invalid("Unsupported OSC argument") }
        }
        var data = string(message.address); data.append(string(types)); data.append(payload); return data
    }
    public static func decode(_ data: Data, depth: Int = 0) throws -> [OSCMessage] {
        guard depth <= 8, data.count <= 1_048_576, !data.isEmpty else { throw OSCWireError.invalid("Invalid OSC packet size") }
        let bytes = [UInt8](data); var cursor = 0
        func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, cursor <= bytes.count - count else { throw OSCWireError.invalid("Truncated OSC packet") }
            let result = Array(bytes[cursor ..< cursor + count]); cursor += count; return result
        }
        func read32() throws -> UInt32 { try take(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        func read64() throws -> UInt64 { try take(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
        func readString() throws -> String {
            guard cursor < bytes.count, let end = bytes[cursor...].firstIndex(of: 0), let result = String(bytes: bytes[cursor..<end], encoding: .utf8) else { throw OSCWireError.invalid("Invalid OSC string") }
            cursor = ((end + 4) / 4) * 4
            guard cursor <= bytes.count else { throw OSCWireError.invalid("Truncated OSC string") }
            return result
        }
        let address = try readString()
        if address == "#bundle" {
            _ = try take(8); var messages: [OSCMessage] = []
            while cursor < bytes.count {
                let size = Int(try read32()); let packet = Data(try take(size))
                messages += try decode(packet, depth: depth + 1)
                guard messages.count <= 256 else { throw OSCWireError.invalid("OSC bundle too large") }
            }
            return messages
        }
        guard address.hasPrefix("/"), address.utf8.count <= 1024 else { throw OSCWireError.invalid("Invalid OSC address") }
        let types = try readString(); guard types.first == ",", types.count <= 256 else { throw OSCWireError.invalid("Invalid OSC types") }
        var values: [Any] = []
        for type in types.dropFirst() {
            switch type {
            case "f": values.append(Float(bitPattern: try read32()))
            case "i": values.append(Int32(bitPattern: try read32()))
            case "h": values.append(Int64(bitPattern: try read64()))
            case "d": values.append(Double(bitPattern: try read64()))
            case "s", "S": values.append(try readString())
            case "T": values.append(true)
            case "F": values.append(false)
            case "N", "I": values.append(NSNull())
            case "b":
                let count = Int(try read32()); let blob = try take(count)
                _ = try take((4 - count % 4) % 4); values.append(Data(blob).base64EncodedString())
            case "r", "m", "c": values.append(try read32())
            case "t": values.append(String(try read64()))
            default: throw OSCWireError.invalid("Unsupported OSC type: \(type)")
            }
        }
        return [OSCMessage(address: address, parameters: values)]
    }
}

public final class OSCStreamDecoder {
    public enum Framing { case packetLength, slip }
    private let framing: Framing
    private var pending: [UInt8] = [], escaped = false
    public init(_ framing: Framing) { self.framing = framing }
    public static func frame(_ data: Data, _ framing: Framing) -> Data {
        if framing == .packetLength {
            let n = UInt32(data.count)
            var result = Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
            result.append(data); return result
        }
        var result = Data([0xc0])
        for byte in data { if byte == 0xc0 { result.append(contentsOf: [0xdb, 0xdc]) } else if byte == 0xdb { result.append(contentsOf: [0xdb, 0xdd]) } else { result.append(byte) } }
        result.append(0xc0); return result
    }
    public func append(_ data: Data) throws -> [Data] {
        var packets: [Data] = []
        if framing == .packetLength {
            guard data.count <= 4_194_320 else { throw OSCWireError.invalid("OSC input chunk too large") }
            pending.append(contentsOf: data)
            while pending.count >= 4 {
                let n = pending.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }; let size = Int(n)
                guard size > 0, size <= 1_048_576 else { throw OSCWireError.invalid("Invalid OSC frame length") }
                if pending.count < size + 4 { break }
                packets.append(Data(pending[4 ..< size + 4])); pending.removeFirst(size + 4)
            }
            guard pending.count <= 1_048_580 else { throw OSCWireError.invalid("OSC frame too large") }
        } else {
            for byte in data {
                if byte == 0xc0 { guard !escaped else { throw OSCWireError.invalid("Truncated SLIP escape") }; if !pending.isEmpty { packets.append(Data(pending)) }; pending.removeAll(keepingCapacity: true); escaped = false }
                else if escaped {
                    guard byte == 0xdc || byte == 0xdd else { throw OSCWireError.invalid("Invalid SLIP escape") }
                    pending.append(byte == 0xdc ? 0xc0 : 0xdb); escaped = false
                } else if byte == 0xdb { escaped = true } else { pending.append(byte) }
                guard pending.count <= 1_048_576 else { throw OSCWireError.invalid("OSC frame too large") }
            }
        }
        return packets
    }
}

/// Commands shared by the native UI and protocol tests, checked against Element 2.9.
public enum EosCommands {
    public static let supportedKeys: Set<String> = ["record", "cue", "sub", "go_to_cue", "chan", "group", "\\", "highlight", "sneak", "+", "thru", "-", "delay", "time", "rem_dim", "home", "level", "out", "@", "full", "clear_cmd", ".", "enter", "macro", "effect", "recall_from", "park", "select_last", "select_manual", "check", "last", "next", "go_0", "stop", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
    public static func keyTap(_ name: String, edges: Bool = true) throws -> [OSCMessage] {
        guard supportedKeys.contains(name) else { throw OSCWireError.invalid("Unverified Eos key: \(name)") }
        if !edges { return [OSCMessage(address: "/eos/key/" + name, parameters: [])] }
        return [1.0, 0.0].map { OSCMessage(address: "/eos/key/" + name, parameters: [$0]) }
    }
    public static func channelCheck(_ channel: Int) throws -> [OSCMessage] {
        guard (1...999999).contains(channel) else { throw OSCWireError.invalid("Enter a valid starting channel") }
        let keys = ["clear_cmd", "chan"] + String(channel).map { String($0) } + ["full", "check", "enter"]
        return try keys.flatMap { try keyTap($0, edges: false) }
    }
    public static func patchRequest(index: Int, version: String) throws -> OSCMessage {
        guard index >= 0, index <= 1_000_000 else { throw OSCWireError.invalid("Invalid patch index") }
        let major = version.split(separator: ".").first.flatMap { Int($0) } ?? 2
        // Original Element 2.9 manual pp. 494–495 uses the index in the address.
        return major < 3 ? OSCMessage(address: "/eos/get/patch/index/\(index)", parameters: []) : OSCMessage(address: "/eos/get/patch/index", parameters: [index])
    }
    public static func goToCue(_ cue: String, list: Int? = nil) throws -> OSCMessage {
        guard cue.range(of: "^[0-9]{1,6}(\\.[0-9]{1,3})?$", options: .regularExpression) != nil else { throw OSCWireError.invalid("Enter a valid cue number") }
        if let list, !(1...999999).contains(list) { throw OSCWireError.invalid("Enter a valid cue list") }
        let target = list.map { "\($0)/\(cue)" } ?? cue
        return OSCMessage(address: "/eos/newcmd", parameters: ["Go_To_Cue \(target) Enter"])
    }
    public static func faderLevel(_ number: Int, _ level: Double) throws -> OSCMessage {
        guard (1...40).contains(number), level.isFinite, (0...1).contains(level) else { throw OSCWireError.invalid("Invalid fader or level") }
        return OSCMessage(address: "/eos/fader/1/\(number)", parameters: [level])
    }
    public static func faderBump(_ number: Int) throws -> OSCMessage {
        guard (1...40).contains(number) else { throw OSCWireError.invalid("Invalid fader") }
        return OSCMessage(address: "/eos/fader/1/\(number)/fire", parameters: [])
    }
}

public struct EosChannelSelection: Equatable {
    public let expression: String
    public let channels: [Int]
    public init(_ input: String) throws {
        guard input.count <= 256 else { throw OSCWireError.invalid("Keep the selection under 256 characters") }
        let source = input.lowercased().replacingOccurrences(of: ",", with: "+")
        let regex = try NSRegularExpression(pattern: "[0-9]+|thru|[+\\-]")
        let tokens = regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { Range($0.range, in: source).map { String(source[$0]) } }
        guard !tokens.isEmpty, tokens.joined() == source.filter({ !$0.isWhitespace }) else { throw OSCWireError.invalid("Use channel numbers, Thru, + or −") }
        var position = 0, result: Set<Int> = [], canonical: [String] = [], subtract = false
        while position < tokens.count {
            guard let start = Int(tokens[position]), (1...999999).contains(start) else { throw OSCWireError.invalid("Enter a channel number from 1 to 999999") }
            position += 1; var end = start
            canonical.append(String(start))
            if position < tokens.count, tokens[position] == "thru" {
                position += 1
                guard position < tokens.count, let last = Int(tokens[position]), last >= start, last <= 999999 else { throw OSCWireError.invalid("Enter an ascending range after Thru") }
                end = last; position += 1; canonical += ["Thru", String(end)]
            }
            guard end-start < 512 else { throw OSCWireError.invalid("Select at most 512 channels at a time") }
            if subtract { result.subtract(start...end) } else { result.formUnion(start...end) }
            guard result.count <= 512 else { throw OSCWireError.invalid("Select at most 512 channels at a time") }
            if position < tokens.count {
                let operation = tokens[position]
                guard operation == "+" || operation == "-" else { throw OSCWireError.invalid("Separate channels with +, − or Thru") }
                subtract = operation == "-"; canonical.append(operation); position += 1
                guard position < tokens.count else { throw OSCWireError.invalid("Finish the channel selection before Enter") }
            }
        }
        guard !result.isEmpty else { throw OSCWireError.invalid("The selection contains no channels") }
        expression = canonical.joined(separator: " "); channels = result.sorted()
    }
    public func select() -> OSCMessage { OSCMessage(address: "/eos/newcmd", parameters: ["Chan \(expression) Enter"]) }
    public func brightness(_ percent: Int) throws -> OSCMessage {
        guard (0...100).contains(percent) else { throw OSCWireError.invalid("Brightness must be between 0 and 100") }
        return OSCMessage(address: "/eos/newcmd", parameters: ["Chan \(expression) At \(percent) Enter"])
    }
    public func remDim() -> OSCMessage { OSCMessage(address: "/eos/newcmd", parameters: ["Chan \(expression) Rem_Dim Enter"]) }
    public func highlight() -> OSCMessage { OSCMessage(address: "/eos/newcmd", parameters: ["Chan \(expression) High Enter"]) }
    public func sneak() -> OSCMessage { OSCMessage(address: "/eos/newcmd", parameters: ["Chan \(expression) Sneak Enter"]) }
}

public struct EosFixtureRecord: Equatable, Identifiable {
    public let channel: Int
    public let part: Int
    public let label: String
    public let manufacturer: String
    public let model: String
    public let address: Int?
    public let intensityAddress: Int?
    public let level: Double?
    public let gel: String
    public let notes: String
    public var endingAddress: Int? = nil
    public var textFields: [String] = []
    public var partCount: Int? = nil
    public var id: String { "\(channel)/\(part)" }
    /// Universe 1 is implicit; never infer a fixture footprint from a neighboring fixture.
    public var patchAddress: String {
        guard let address, address > 0 else { return address == 0 ? "Unpatched" : "Not received" }
        func formatted(_ value: Int, showUniverse: Bool) -> String {
            let universe = (value - 1) / 512 + 1, slot = (value - 1) % 512 + 1
            return universe == 1 && !showUniverse ? String(slot) : "\(universe)/\(slot)"
        }
        guard let end = endingAddress, end >= address else { return formatted(address, showUniverse: false) }
        let crossesUniverse = (address - 1) / 512 != (end - 1) / 512
        let first = formatted(address, showUniverse: crossesUniverse)
        return end == address ? first : first + " Thru " + formatted(end, showUniverse: crossesUniverse)
    }
    public var universeAddress: String {
        guard let address, address > 0 else { return address == 0 ? "Unpatched" : "Not received" }
        return "\((address-1)/512+1)/\((address-1)%512+1)"
    }
}

/// Reassembles ETC's chunked patch list without assuming one packet contains all fields.
public struct EosFixtureAccumulator {
    private var fields: [String: [Int: Any]] = [:]
    private var notes: [String: String] = [:]
    public init() {}
    public mutating func clear(channels: Set<Int>) {
        fields = fields.filter { !channels.contains(Int($0.key.split(separator: "/")[0]) ?? -1) }
        notes = notes.filter { !channels.contains(Int($0.key.split(separator: "/")[0]) ?? -1) }
    }
    public mutating func receive(_ message: OSCMessage) -> EosFixtureRecord? {
        let path = message.address.split(separator: "/").map(String.init)
        guard path.count >= 7, Array(path.prefix(4)) == ["eos", "out", "get", "patch"], let channel = Int(path[4]), let part = Int(path[5]), channel > 0, part > 0 else { return nil }
        let id = "\(channel)/\(part)"
        if path[6] == "notes", message.parameters.count >= 3 { notes[id] = message.parameters[2] as? String ?? "" }
        else {
            guard path.count == 9, path[6] == "list", let offset = Int(path[7]), let count = Int(path[8]), offset >= 0, count >= 0, offset+count <= 128, message.parameters.count == count else { return nil }
            if fields.count >= 512, fields[id] == nil, let first = fields.keys.first { fields.removeValue(forKey: first); notes.removeValue(forKey: first) }
            var data = fields[id] ?? [:]
            for (index, value) in message.parameters.enumerated() { data[offset+index] = value }
            fields[id] = data
        }
        guard let data = fields[id], data[4] != nil else { return nil }
        func text(_ index: Int) -> String { data[index] as? String ?? "" }
        func integer(_ index: Int) -> Int? { (data[index] as? NSNumber)?.intValue }
        return EosFixtureRecord(channel: channel, part: part, label: text(2), manufacturer: text(3), model: text(4), address: integer(5), intensityAddress: integer(6), level: (data[7] as? NSNumber)?.doubleValue, gel: text(8), notes: notes[id] ?? "", endingAddress: integer(20), textFields: (9...18).map(text), partCount: integer(19))
    }
}

/// Monotonic pulse cadence shared by haptic controls; independent of device hardware.
public struct HapticCadence {
    private var lastPulse = -Double.infinity
    public init() {}
    public mutating func allow(at time: Double, enabled: Bool, continuous: Bool = false) -> Bool {
        guard enabled, time.isFinite, time-lastPulse >= (continuous ? 0.18 : 0.035) else { return false }
        lastPulse = time
        return true
    }
}

/// A small pending queue: coalesce continuous controls, retain action order, expire stale input.
public struct OSCOutboundBuffer {
    private enum Kind: Equatable { case absolute(String), relative(String), action }
    private struct Entry { var message: OSCMessage; var time: Double; var kind: Kind }
    private var entries: [Entry] = []
    public let limit: Int
    public private(set) var expiredActions = 0
    public var count: Int { entries.count }
    public init(limit: Int = 128) { self.limit = max(1, limit) }
    public mutating func clear() { entries.removeAll(keepingCapacity: true); expiredActions = 0 }
    public mutating func enqueue(_ message: OSCMessage, at time: Double) throws {
        _ = try OSCCodec.encode(message)
        guard time.isFinite else { throw OSCWireError.invalid("Invalid command time") }
        let kind = classify(message)
        if kind != .action {
            for index in entries.indices.reversed() {
                if entries[index].kind == .action { break }
                if case .relative = kind, case .absolute = entries[index].kind { break }
                if case .absolute = kind, case .relative = entries[index].kind { break }
                if entries[index].kind == kind {
                    var replacement = message
                    if case .relative = kind {
                        let previous = (entries[index].message.parameters.first as? NSNumber)?.int64Value ?? 0
                        let next = (message.parameters.first as? NSNumber)?.int64Value ?? 0
                        let (sum, overflow) = previous.addingReportingOverflow(next)
                        guard !overflow, sum >= Int64(Int32.min), sum <= Int64(Int32.max) else { throw OSCWireError.invalid("Wheel input overflow") }
                        replacement = OSCMessage(address: message.address, parameters: [Int(sum)])
                    }
                    entries.remove(at: index)
                    entries.append(Entry(message: replacement, time: time, kind: kind))
                    return
                }
            }
        }
        guard entries.count < limit else { throw OSCWireError.invalid("Connection is busy; command was not queued. Release the control and retry.") }
        entries.append(Entry(message: message, time: time, kind: kind))
    }
    public mutating func next(at time: Double) -> OSCMessage? {
        while !entries.isEmpty {
            let item = entries.removeFirst()
            let ttl = item.kind == .action ? 1.0 : 0.30
            if time-item.time > ttl {
                if item.kind == .action {
                    // Do not let a later Enter execute after part of a key sequence expired.
                    expiredActions += 1 + entries.filter { $0.kind == .action }.count
                    entries.removeAll(keepingCapacity: true)
                    return nil
                }
                continue
            }
            return item.message
        }
        return nil
    }
    private func classify(_ message: OSCMessage) -> Kind {
        let address = message.address
        if address.range(of: "^/eos/fader/[0-9]+/[0-9]+$", options: .regularExpression) != nil { return .absolute(address) }
        if address == "/eos/color/hs" || address == "/eos/color/xy" { return .absolute("/eos/color") }
        if address.range(of: "^/eos/wheel/(fine|coarse)/[a-z_]+$", options: .regularExpression) != nil,
           message.parameters.count == 1, let value = message.parameters.first as? NSNumber, value.doubleValue.rounded() == value.doubleValue { return .relative(address) }
        if address == "/eos/newcmd", let text = message.parameters.first as? String, text.hasPrefix("Chan "), let range = text.range(of: " At ", options: .backwards), text.hasSuffix(" Enter"),
           let selection = try? EosChannelSelection(String(text[text.index(text.startIndex, offsetBy: 5)..<range.lowerBound])),
           Int(text[range.upperBound...].replacingOccurrences(of: " Enter", with: "")).map({ (0...100).contains($0) }) == true {
            return .absolute("level:" + selection.expression)
        }
        return .action
    }
}

public enum EosVersionReply {
    public static func softwareCandidate(_ value: Any?) -> String? {
        guard let text = value as? String, text.range(of: "^[0-9]+(?:\\.[0-9]+){1,7}$", options: .regularExpression) != nil else { return nil }
        return text
    }
}

/// Presents Eos's trailing command terminator without changing the underlying OSC text.
public struct EosCommandPresentation: Equatable {
    public let text: String
    public let isComplete: Bool

    public init(_ raw: String, isError: Bool = false, practiceComplete: Bool = false) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasHash = trimmed.hasSuffix("#")
        let hasEnter = trimmed.range(of: #"(?:^|\s)Enter$"#, options: [.regularExpression, .caseInsensitive]) != nil
        if hasHash {
            text = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        } else if hasEnter, let end = trimmed.range(of: #"(?:^|\s)Enter$"#, options: [.regularExpression, .caseInsensitive]) {
            text = String(trimmed[..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        } else {
            text = trimmed
        }
        isComplete = !isError && !text.isEmpty && (hasHash || hasEnter || practiceComplete)
    }
}

/// Fixture capabilities returned by Eos 3.2+ Get Params (Live values).
public struct EosFixtureParameter: Identifiable {
    public let name: String
    public let level: Double
    public let minimum: Double
    public let maximum: Double
    public var id: String { name }
    public var oscName: String { name.lowercased().replacingOccurrences(of: " ", with: "_") }
    public static func parse(_ values: [Any]) -> [EosFixtureParameter] {
        guard values.count >= 2, (values.count - 2) % 4 == 0 else { return [] }
        return stride(from: 2, to: values.count, by: 4).compactMap { i in
            guard let name = values[i] as? String, !name.isEmpty,
                  let level = values[i+1] as? NSNumber, let min = values[i+2] as? NSNumber,
                  let max = values[i+3] as? NSNumber,
                  level.doubleValue.isFinite, min.doubleValue.isFinite, max.doubleValue.isFinite,
                  min.doubleValue <= max.doubleValue else { return nil }
            return EosFixtureParameter(name: name, level: level.doubleValue, minimum: min.doubleValue, maximum: max.doubleValue)
        }
    }
}

/// Reassembles OSC list packets, including metadata arriving after a channel/FX packet.
public struct EosShowData {
    public private(set) var records: [String: [Int: Any]] = [:]
    public init() {}
    public mutating func clear(_ family: String) { records = records.filter { !$0.key.hasPrefix(family + "/") } }
    @discardableResult public mutating func receive(_ message: OSCMessage) -> String? {
        let p = message.address.split(separator: "/").map(String.init)
        guard p.count >= 8, Array(p.prefix(3)) == ["eos", "out", "get"],
              let marker = p.firstIndex(of: "list"), marker + 2 == p.count-1,
              let offset = Int(p[marker+1]), let count = Int(p[marker+2]),
              offset >= 0, count >= 0, offset + count <= 4096, count == message.parameters.count else { return nil }
        guard ["cue", "cuelist", "fp", "cp", "bp", "sub"].contains(p[3]) else { return nil }
        let key = p[3..<marker].joined(separator: "/")
        var fields = records[key] ?? [:]
        for (index, value) in message.parameters.enumerated() { fields[offset+index] = value }
        records[key] = fields
        return key
    }
}
