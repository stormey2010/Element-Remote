import Foundation
import Network
import Darwin
import UIKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct ConsoleProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var host: String
    var transport: String
    var consolePort: Int
    var receivePort: Int

    init(id: UUID = UUID(), name: String, host: String, transport: String = "tcp", consolePort: Int = 3032, receivePort: Int = 8001) {
        self.id = id
        self.name = name
        self.host = host
        self.transport = transport
        self.consolePort = consolePort
        self.receivePort = receivePort
    }
}

enum ConsoleProfileStore {
    private static let key = "element.console.profiles.v1"
    
    static func load() -> [ConsoleProfile] {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            if let config = UserDefaults.standard.dictionary(forKey: "element.console.settings.v1"),
               let parsed = try? NativeConsoleSettings.parse(config), !parsed.consoleHost.isEmpty {
                let migrated = [ConsoleProfile(name: parsed.displayName, host: parsed.consoleHost, transport: parsed.transport, consolePort: parsed.consolePort, receivePort: parsed.receivePort)]
                save(migrated); return migrated
            }
            return []
        }
        guard let list = try? JSONDecoder().decode([ConsoleProfile].self, from: data) else { return [] }
        return list
    }

    static func save(_ profiles: [ConsoleProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct DiscoveredConsole: Identifiable, Equatable {
    var id: String { "\(name)-\(host)-\(port)-\(transport)" }
    var name: String
    var host: String
    var port: Int
    var transport: String
}

@MainActor final class ConsoleDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceDelegate {
    @Published var isSearching = false
    @Published var discoveredConsoles: [DiscoveredConsole] = []
    @Published var statusMessage = "Search Wi-Fi for consoles"
    private var browsers: [NWBrowser] = []
    private var resolving: [String: NetService] = [:]
    private var transports: [String: String] = [:]
    private var timeout: DispatchWorkItem?
    private var generation = UUID()
    private var candidates: [String] = []
    private var probes: [String: NWConnection] = [:]
    private var probeDecoders: [String: OSCStreamDecoder] = [:]
    private var started = Date.distantPast

    func start() {
        stop(); discoveredConsoles = []; isSearching = true
        let token = generation
        started = Date()
        candidates = localCandidates()
        statusMessage = candidates.isEmpty ? "Searching advertised services…" : "Checking nearby OSC addresses…"
        pump(token)
        for (type, transport) in [("_osc._tcp", "tcp"), ("_osc._udp", "udp")] {
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    for result in results {
                        guard case let .service(name, type, domain, _) = result.endpoint else { continue }
                        let id = name + type + domain
                        guard self.resolving[id] == nil else { continue }
                        let service = NetService(domain: domain, type: type, name: name)
                        self.resolving[id] = service; self.transports[id] = transport
                        service.delegate = self; service.resolve(withTimeout: 6)
                    }
                }
            }
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if case .failed = state { self.statusMessage = "Search unavailable. Add the console by IP." }
                    if case .waiting(let error) = state, error.localizedDescription.lowercased().contains("policy") {
                        self.statusMessage = "Allow Local Network access in iOS Settings."
                    }
                }
            }
            browsers.append(browser); browser.start(queue: .main)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            let found = self.discoveredConsoles.count
            self.stop()
            self.statusMessage = found == 0 ? "No advertised consoles found. Add by IP." : "Found \(found) OSC service(s)"
        }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + (candidates.isEmpty && probes.isEmpty ? 8 : 60), execute: work)
    }
    func stop() {
        generation = UUID(); timeout?.cancel(); timeout = nil
        browsers.forEach { $0.cancel() }; browsers = []
        resolving.values.forEach { $0.delegate = nil; $0.stop() }; resolving = [:]; transports = [:]
        probes.values.forEach { $0.cancel() }; probes = [:]; probeDecoders = [:]; candidates = []
        isSearching = false
    }
    private func localCandidates() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard String(cString: item.pointee.ifa_name) == "en0", let address = item.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET), let mask = item.pointee.ifa_netmask else { continue }
            func numeric(_ address: UnsafePointer<sockaddr>) -> String? {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: buffer)
            }
            if let ip = numeric(address), let netmask = numeric(mask) { return EosDiscoveryHosts.candidates(ip: ip, mask: netmask) }
        }
        return []
    }
    private func pump(_ token: UUID) {
        guard generation == token, isSearching else { return }
        while probes.count < 12 && !candidates.isEmpty {
            let host = candidates.removeFirst()
            let connection = NWConnection(host: NWEndpoint.Host(host), port: 3032, using: .tcp)
            probes[host] = connection; probeDecoders[host] = OSCStreamDecoder(.packetLength)
            let nonce = "element-discovery-" + UUID().uuidString
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                Task { @MainActor in
                    guard let self, let connection, self.generation == token, self.probes[host] === connection else { return }
                    if case .ready = state {
                        guard let bytes = try? OSCCodec.encode(OSCMessage(address: "/eos/ping", parameters: [nonce])) else { self.finish(host, token); return }
                        connection.send(content: OSCStreamDecoder.frame(bytes, .packetLength), completion: .contentProcessed { _ in })
                        self.readProbe(connection, host, nonce, token)
                    } else if case .failed = state { self.finish(host, token) }
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.generation == token, self.probes[host] === connection else { return }
                self.finish(host, token)
            }
        }
        if candidates.isEmpty && probes.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, 8 - Date().timeIntervalSince(started))) { [weak self] in
                guard let self, self.generation == token, self.candidates.isEmpty, self.probes.isEmpty else { return }
                let count = self.discoveredConsoles.count; self.stop()
                self.statusMessage = count == 0 ? "No replies found. Add the console by IP." : "Found \(count) endpoint(s)"
            }
        }
    }
    private func readProbe(_ connection: NWConnection, _ host: String, _ nonce: String, _ token: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.generation == token, self.probes[host] === connection else { return }
                do {
                    if let data, let decoder = self.probeDecoders[host] {
                        for packet in try decoder.append(data) {
                            for message in try OSCCodec.decode(packet) where message.address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "eos/out/ping" && message.parameters.contains(where: { ($0 as? String) == nonce }) {
                                self.discoveredConsoles.append(DiscoveredConsole(name: "Eos · " + host, host: host, port: 3032, transport: "tcp"))
                                self.statusMessage = "Verified Eos reply from " + host
                                self.finish(host, token); return
                            }
                        }
                    }
                    if complete || error != nil { self.finish(host, token) }
                    else { self.readProbe(connection, host, nonce, token) }
                } catch { self.finish(host, token) }
            }
        }
    }
    private func finish(_ host: String, _ token: UUID) {
        guard generation == token else { return }
        probes.removeValue(forKey: host)?.cancel(); probeDecoders.removeValue(forKey: host)
        pump(token)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        let id = sender.name + sender.type + sender.domain
        guard resolving[id] === sender, let hostname = sender.hostName, sender.port > 0 else { return }
        let host = hostname.hasSuffix(".") ? String(hostname.dropLast()) : hostname
        let console = DiscoveredConsole(name: sender.name, host: host, port: sender.port, transport: transports[id] ?? "tcp")
        if !discoveredConsoles.contains(where: { $0.id == console.id }) { discoveredConsoles.append(console) }
        statusMessage = "Found \(discoveredConsoles.count) OSC service(s)"
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        if discoveredConsoles.isEmpty { statusMessage = "Couldn’t resolve a service. Add by IP." }
    }
}

private struct NativeConsoleSettings {
    var displayName = "Element"
    var consoleHost = ""
    var transport = "tcp"
    var consolePort = 3032
    var receivePort = 8001
    var dictionary: [String: Any] { ["displayName": displayName, "consoleHost": consoleHost, "transport": transport, "consolePort": consolePort, "receivePort": receivePort] }
    static func parse(_ value: [String: Any]) throws -> NativeConsoleSettings {
        var result = NativeConsoleSettings()
        result.displayName = String((value["displayName"] as? String ?? "Element").prefix(64))
        result.consoleHost = (value["consoleHost"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        result.transport = value["transport"] as? String ?? "tcp"
        guard ["tcp", "tcp-slip", "third-party", "udp"].contains(result.transport) else { throw OSCWireError.invalid("Choose a valid connection mode.") }
        guard result.consoleHost.isEmpty || IPv4Address(result.consoleHost) != nil || result.consoleHost.hasSuffix(".local") || result.consoleHost.range(of: "^[a-zA-Z0-9.-]+$", options: .regularExpression) != nil else { throw OSCWireError.invalid("Enter the console’s IPv4 address or hostname.") }
        if let first = result.consoleHost.split(separator: ".").first.flatMap({ Int($0) }), first == 0 || first == 127 || first >= 224 { throw OSCWireError.invalid("Enter a unicast console address, not loopback, broadcast or multicast.") }
        func port(_ key: String, fallback: Int) throws -> Int {
            let raw = value[key].map { String(describing: $0) } ?? String(fallback)
            guard let number = Int(raw), (1024...65535).contains(number) else { throw OSCWireError.invalid("Ports must be between 1024 and 65535.") }
            return number
        }
        result.consolePort = try port("consolePort", fallback: result.transport == "udp" ? 8000 : result.transport == "third-party" ? 3037 : 3032)
        result.receivePort = try port("receivePort", fallback: 8001)
        return result
    }
}

final class NativeOSCConnection {
    var onMessage: (([String: Any]) -> Void)?
    private let queue = DispatchQueue(label: "app.elementremote.osc", qos: .userInteractive)
    private let defaultsKey = "element.console.settings.v1"
    private var settings = NativeConsoleSettings()
    private var connection: NWConnection?
    private var listener: NWListener?
    private var incoming: [NWConnection] = []
    private var decoder = OSCStreamDecoder(.packetLength)
    private var generation = 0
    private var active = true
    private var connectionReady = false
    private var listenerReady = false
    private var retry: DispatchWorkItem?
    private var pingTimer: DispatchSourceTimer?
    private var pingToken = ""
    private var pingSent = -Double.infinity
    private var lastPong = -Double.infinity
    private var latency: Int?
    private var lastError = ""
    private var localNetworkDenied = false
    private var phase = "idle"
    private var connectedAt = -Double.infinity
    private var version = ""
    private var lastReceived = Date.distantPast
    private var receivedPackets = 0
    private var sentPackets = 0
    private var outbox = OSCOutboundBuffer()
    private var writing = false
    private var pendingReadouts: [String: [String: Any]] = [:]
    private var readoutFlush: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var explicitlyDisconnected = false
    private var observers: [NSObjectProtocol] = []
    private var keepAwake = false
    private var ready: Bool { connectionReady && (settings.transport != "udp" || listenerReady) }
    private var framing: OSCStreamDecoder.Framing { ["third-party", "tcp-slip"].contains(settings.transport) ? .slip : .packetLength }

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: defaultsKey), let parsed = try? NativeConsoleSettings.parse(saved) { settings = parsed }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.async { [weak self] in self?.suspend() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.async { [weak self] in guard let self else { return }; guard !self.explicitlyDisconnected else { return }; self.active = true; self.startConnection() }
            DispatchQueue.main.async { [weak self] in UIApplication.shared.isIdleTimerDisabled = self?.keepAwake ?? false }
        })
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in guard let self else { return }; if self.active {
            if self.ready && (ProcessInfo.processInfo.systemUptime - self.lastPong) > 25 && (ProcessInfo.processInfo.systemUptime - self.connectedAt) > 8 { self.phase = "awaitingReply"; self.lastError = "No verified OSC reply. Check console OSC RX/TX, TCP framing, IP address, and UDP return settings. Socket readiness alone does not confirm Eos control." }
            self.ping(); self.emitStatus()
        } }
        timer.resume(); pingTimer = timer
    }
    deinit { readoutFlush?.cancel(); timeout?.cancel(); retry?.cancel(); pingTimer?.cancel(); connection?.cancel(); listener?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    private func emit(_ message: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.onMessage?(message) }
    }
    private func emitStatus() {
        let verified = active && ready && (ProcessInfo.processInfo.systemUptime - lastPong) < 25
        emit(["type": "status", "bridge": true, "native": true, "configured": !settings.consoleHost.isEmpty,
              "consoleOnline": verified, "udpReady": ready && active, "error": lastError,
              "localNetworkDenied": localNetworkDenied,
              "localNetworkStatus": localNetworkDenied ? "Blocked by iOS" : verified ? "Verified by OSC round trip" : (ready && settings.transport != "udp") ? "TCP connection allowed; awaiting OSC reply" : "Not yet verified",
              "phase": phase, "sentPackets": sentPackets, "receivedPackets": receivedPackets,
              "version": version, "latencyMs": latency.map { $0 as Any } ?? NSNull(), "config": settings.dictionary])
    }
    func testConnection() { queue.async { if !self.active || !self.ready { self.explicitlyDisconnected = false; self.active = true; self.startConnection() } else { self.ping(); self.sendVersionRequest() } } }
    private func sendVersionRequest() { if let data = try? OSCCodec.encode(OSCMessage(address: "/eos/get/version", parameters: [])) { write(data) } }
    func start() { queue.async { self.explicitlyDisconnected = false; self.active = true; self.startConnection() } }
    func disconnect() { queue.async { self.explicitlyDisconnected = true; self.suspend() } }
    func config() -> [String: Any] { queue.sync { settings.dictionary } }
    func configure(_ value: [String: Any]) throws {
        let parsed = try NativeConsoleSettings.parse(value)
        queue.async { self.settings = parsed; UserDefaults.standard.set(parsed.dictionary, forKey: self.defaultsKey); self.explicitlyDisconnected = false; self.active = true; self.startConnection() }
    }
    func send(_ address: String, _ parameters: [Any] = []) { sendBatch([OSCMessage(address: address, parameters: parameters)]) }
    func sendBatch(_ messages: [OSCMessage]) {
        guard !messages.isEmpty, messages.count <= 64 else { return }
        let token = queue.sync { generation }
        queue.async {
            guard token == self.generation, self.active, self.ready else { self.emit(["type": "sendError", "message": "Console disconnected; command was not sent or queued."]); return }
            do {
                var next = self.outbox
                for message in messages { try next.enqueue(message, at: ProcessInfo.processInfo.systemUptime) }
                self.outbox = next; self.drain()
            } catch { self.emit(["type": "sendError", "message": error.localizedDescription]) }
        }
    }
    func press(_ name: String) {
        guard EosCommands.supportedKeys.contains(name) else { queue.async { self.emit(["type": "sendError", "message": "Unsupported Eos key: " + name]) }; return }
        pulse("/eos/key/" + name)
    }
    func pulse(_ address: String) {
        send(address)
    }
    func setKeepAwake(_ enabled: Bool) { keepAwake = enabled; UIApplication.shared.isIdleTimerDisabled = enabled }
    private func stop() {
        generation += 1; readoutFlush?.cancel(); readoutFlush = nil; pendingReadouts.removeAll(); outbox.clear(); writing = false; timeout?.cancel(); timeout = nil; retry?.cancel(); retry = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        incoming.forEach { $0.cancel() }; incoming.removeAll()
        connectionReady = false; listenerReady = false; lastPong = -Double.infinity; lastReceived = .distantPast; latency = nil
    }
    private func suspend() {
        active = false; phase = "disconnected"; emit(["type": "reset"]); emitStatus()
        let token = generation
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in guard let self, !self.active, token == self.generation else { return }; self.stop(); self.emitStatus() }
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func startConnection() {
        stop(); lastError = ""; localNetworkDenied = false; version = ""; phase = "connecting"; emit(["type": "reset"])
        guard active, !settings.consoleHost.isEmpty else { phase = settings.consoleHost.isEmpty ? "unconfigured" : "disconnected"; emitStatus(); return }
        let token = generation
        decoder = OSCStreamDecoder(framing)
        let host = NWEndpoint.Host(settings.consoleHost), port = NWEndpoint.Port(rawValue: UInt16(settings.consolePort))!
        let parameters: NWParameters
        if settings.transport == "udp" {
            parameters = .udp
            do {
                let params = NWParameters.udp; params.allowLocalEndpointReuse = true
                let receiving = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(settings.receivePort))!)
                listener = receiving
                receiving.stateUpdateHandler = { [weak self] state in
                    guard let self, token == self.generation else { return }
                    switch state { case .ready: self.listenerReady = true; self.becameReady(); case .failed(let error): self.fail(error.localizedDescription, token: token); default: break }
                }
                receiving.newConnectionHandler = { [weak self] peer in
                    guard let self, token == self.generation else { peer.cancel(); return }
                    guard case let .hostPort(remote, _) = peer.endpoint, remote == host, self.incoming.count < 8 else { peer.cancel(); return }
                    self.incoming.append(peer); peer.start(queue: self.queue); self.receiveDatagram(peer, token: token)
                }
                receiving.start(queue: queue)
            } catch { fail(error.localizedDescription, token: token); return }
        } else {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true; tcp.enableKeepalive = true
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        let outgoing = NWConnection(host: host, port: port, using: parameters); connection = outgoing
        outgoing.pathUpdateHandler = { [weak self, weak outgoing] path in
            guard let self, token == self.generation else { return }
            if path.unsatisfiedReason == .localNetworkDenied { self.localNetworkDenied = true; self.phase = "permissionDenied"; self.lastError = "Local Network access is blocked. Enable it in iOS Settings → Privacy & Security → Local Network → Element Remote, then retry."; self.emitStatus() }
            else if self.connectionReady { self.localNetworkDenied = false }
        }
        outgoing.stateUpdateHandler = { [weak self, weak outgoing] state in
            guard let self, let outgoing, token == self.generation else { return }
            switch state {
            case .ready:
                self.connectionReady = true; self.localNetworkDenied = false; self.lastError = ""; self.becameReady()
                if self.settings.transport != "udp" { self.receiveStream(outgoing, token: token) } else { self.receiveDatagram(outgoing, token: token) }
            case .failed(let error): self.fail(error.localizedDescription, token: token)
            case .waiting(let error):
                self.connectionReady = false
                self.localNetworkDenied = outgoing.currentPath?.unsatisfiedReason == .localNetworkDenied
                self.phase = self.localNetworkDenied ? "permissionDenied" : "waiting"
                self.lastError = self.localNetworkDenied ? "Local Network access is blocked. Open iOS Settings and allow Element Remote." : "Waiting for network. Check Wi-Fi and the console IP. \(error.localizedDescription)"
                self.emitStatus()
            default: break
            }
        }
        outgoing.start(queue: queue)
        let check = DispatchWorkItem { [weak self] in
            guard let self, token == self.generation, self.active, !self.ready, !self.localNetworkDenied else { return }
            self.phase = "waiting"; self.lastError = "Connection is still waiting. Check the console IP, TCP port, Wi-Fi routing, OSC network interface, and Local Network permission. Permission status is not yet confirmed."; self.emitStatus()
        }
        timeout = check; queue.asyncAfter(deadline: .now() + 10, execute: check)
        emitStatus()
    }
    private func becameReady() {
        guard active else { return }
        if ready {
            timeout?.cancel(); connectedAt = ProcessInfo.processInfo.systemUptime; phase = "awaitingReply"; sendVersionRequest(); ping()
            if let data = try? OSCCodec.encode(OSCMessage(address: "/eos/subscribe/param/intens/pan/tilt/edge/zoom/iris/focus/color_temp/tint/diffusn/gobo_rot", parameters: [1])) { write(data) }
            if let cueSub = try? OSCCodec.encode(OSCMessage(address: "/eos/subscribe/cue/1", parameters: [1])) { write(cueSub) }
        }
        emitStatus()
    }
    private func fail(_ reason: String, token: Int) {
        guard token == generation, active else { return }
        stop(); phase = "error"; lastError = reason; emit(["type": "reset"]); emitStatus()
        let work = DispatchWorkItem { [weak self] in guard let self, self.active else { return }; self.startConnection() }
        retry = work; queue.asyncAfter(deadline: .now() + 3, execute: work)
    }
    private func write(_ packet: Data) {
        guard active, ready else { return }
        do {
            for message in try OSCCodec.decode(packet) { try outbox.enqueue(message, at: ProcessInfo.processInfo.systemUptime) }
            drain()
        } catch { emit(["type": "sendError", "message": error.localizedDescription]) }
    }
    private func drain() {
        guard active, ready, !writing, let outgoing = connection else { return }
        let before = outbox.expiredActions
        let message = outbox.next(at: ProcessInfo.processInfo.systemUptime)
        if outbox.expiredActions > before {
            let reason = "Input was delayed; pending commands were cleared. Review the console command line and press Clear before continuing."
            emit(["type": "sendError", "message": reason]); fail(reason, token: generation); return
        }
        guard let message else { return }
        guard let packet = try? OSCCodec.encode(message) else { return }
        let data = settings.transport == "udp" ? packet : OSCStreamDecoder.frame(packet, framing)
        let token = generation
        writing = true; sentPackets += 1
        outgoing.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard token == self.generation else { return }
                self.writing = false
                if let error { self.fail(error.localizedDescription, token: token) } else { self.drain() }
            }
        })
    }
    private func receiveStream(_ socket: NWConnection, token: Int) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, token == self.generation else { return }
            if let data { do { for packet in try self.decoder.append(data) { self.process(packet) } } catch { self.fail(error.localizedDescription, token: token); return } }
            if let error { self.fail(error.localizedDescription, token: token) }
            else if complete { self.fail("Console closed the connection.", token: token) }
            else { self.receiveStream(socket, token: token) }
        }
    }
    private func receiveDatagram(_ peer: NWConnection, token: Int) {
        peer.receiveMessage { [weak self] data, _, _, error in
            guard let self, token == self.generation else { return }
            if let data { self.process(data) }
            if error == nil { self.receiveDatagram(peer, token: token) }
            else { peer.cancel(); self.incoming.removeAll { $0 === peer } }
        }
    }
    private func process(_ bytes: Data) {
        guard let messages = try? OSCCodec.decode(bytes) else { return }
        for message in messages where message.address.hasPrefix("/eos/") {
            receivedPackets += 1; lastReceived = Date(); localNetworkDenied = false
            if message.address == "/eos/out/get/version", version.isEmpty, let candidate = EosVersionReply.softwareCandidate(message.parameters.first) { version = candidate; emitStatus() }
            if message.address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "eos/out/ping", message.parameters.contains(where: { ($0 as? String) == pingToken }) {
                lastPong = ProcessInfo.processInfo.systemUptime; phase = "verified"; lastError = ""; latency = Int(max(0, lastPong - pingSent) * 1000); emitStatus(); continue
            }
            let safe = message.parameters.map { value -> Any in if let number = value as? NSNumber, !number.doubleValue.isFinite { return NSNull() }; return value }
            let event: [String: Any] = ["type": "osc", "address": message.address, "parameters": safe]
            if message.address.hasPrefix("/eos/out/param/") || message.address.range(of: "^/eos/(out/)?fader/[0-9]+/[0-9]+$", options: .regularExpression) != nil {
                pendingReadouts[message.address] = event
                if readoutFlush == nil {
                    let token = generation
                    let work = DispatchWorkItem { [weak self] in
                        guard let self, token == self.generation else { return }
                        let events = Array(self.pendingReadouts.values); self.pendingReadouts.removeAll(keepingCapacity: true); self.readoutFlush = nil
                        self.emit(["type": "oscBatch", "messages": events])
                    }
                    readoutFlush = work; queue.asyncAfter(deadline: .now()+0.016, execute: work)
                }
            } else { emit(event) }
        }
    }
    private func ping() {
        guard active, ready else { return }
        pingSent = ProcessInfo.processInfo.systemUptime; pingToken = "element-ios-\(UUID().uuidString)"
        if let data = try? OSCCodec.encode(OSCMessage(address: "/eos/ping", parameters: [pingToken])) { write(data) }
    }
}

import SwiftUI
import Combine
@MainActor final class WiFiStatus: ObservableObject {
    @Published var label = "Checking Wi-Fi…"
    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var connected = false
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.connected = path.status == .satisfied; self?.refresh() }
        }
        monitor.start(queue: DispatchQueue(label: "element.wifi"))
    }
    deinit { monitor.cancel() }
    func refresh() { label = connected ? "On Wi-Fi" : "Not on Wi-Fi" }
}

struct CueHistoryItem: Identifiable, Equatable {
    let id = UUID()
    let cue: String
    let label: String
    let time: String
}

@MainActor final class NativeRemoteModel: ObservableObject {
    @Published var rehearsalEvents: [EosRehearsalEvent] = []
    @Published var recordRehearsal = UserDefaults.standard.bool(forKey: "element.recordRehearsal")
    private var rehearsalSave: DispatchWorkItem?
    @Published var online = false
    @Published var ready = false
    @Published var commandLine = "Connect to Element to begin"
    @Published var error = ""
    @Published var diagnostic = ""
    @Published var networkDenied = false
    @Published var networkStatus = "Not yet verified"
    @Published var phase = "idle"
    @Published var softwareVersion = ""
    @Published var latency: Int?
    @Published var sentPackets = 0
    @Published var receivedPackets = 0
    var commandPresentation: EosCommandPresentation {
        EosCommandPresentation(commandLine, isError: commandError,
            practiceComplete: demoMode && practiceDesk.entry.isEmpty)
    }
    @Published var commandError = false
    @Published var activeChannels = "No channel feedback yet"
    @Published var selectedChannels: [Int] = []
    @Published var movementAvailable = false
    @Published var colorAvailable = false
    @Published var feedback: [String: [Any]] = [:]
    @Published var session = UUID()
    @Published var selection: Set<Int> = []
    @Published var fixtures: [String: EosFixtureRecord] = [:]
    @Published var emitters: [Int: [EosFixtureParameter]] = [:]
    @Published var processors: [Int: EosProcessorHealth] = [:]
    @Published var healthReceivedAt: Date?
    @Published var processorCount: Int?
    private var pendingProcessorHealth: [Int:EosProcessorHealth]?
    @Published var independentUser = UserDefaults.standard.bool(forKey: "element.independentUser")
    @Published var oscUser: Int?
    @Published var fixtureParameters: [Int: [EosFixtureParameter]] = [:]
    @Published var showData = EosShowData()
    @Published var requestedFamilies: Set<String> = []
    @Published var showCounts: [String: Int] = [:]
    private var queryGeneration = UUID()
    private var familyGenerations: [String: UUID] = [:]
    private var refreshWork: [String: DispatchWorkItem] = [:]
    @Published var activeCueText = "No cue feedback yet"
    @Published var pendingCueText = "—"
    @Published var activeCuePercent: Double = 0.0
    @Published var isCueFading = false
    @Published var cueHistory: [CueHistoryItem] = []
    @Published var demoMode = UserDefaults.standard.bool(forKey: "element.demoMode")
    
    private var fixtureAccumulator = EosFixtureAccumulator()
    private let impactFeedback = UIImpactFeedbackGenerator(style: .soft)
    private var hapticCadence = HapticCadence()
    let connection = NativeOSCConnection()
    
    // Simulation state for Offline Demo Mode
    private var practiceDesk = EosPracticeDesk()
    private var demoGeneration = UUID()
    private var demoPlaybackID = UUID()
    private var demoFadeTimer: Timer?
    private var demoCueIndex = 0
    private let demoCues: [(cue: String, label: String, duration: Double)] = [
        ("1", "Opening Scene (Warm Wash)", 4.0),
        ("2", "Actor Crosses Stage Right", 3.0),
        ("3", "Dramatic Monologue (Blue Mood)", 5.0),
        ("4", "Blackout", 2.0)
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: "element.rehearsalEvents"), let events = try? JSONDecoder().decode([EosRehearsalEvent].self, from: data) { rehearsalEvents = Array(events.prefix(1000)) }
        connection.onMessage = { [weak self] message in
            guard let self else { return }
            switch message["type"] as? String {
            case "status":
                if !self.demoMode {
                    self.online = message["consoleOnline"] as? Bool ?? false
                    let nextReady = message["udpReady"] as? Bool ?? false
                    if self.ready != nextReady { self.session = UUID() }
                    let becameReady = !self.ready && nextReady
                    self.ready = nextReady
                    if becameReady { self.applyUserMode(); for family in self.requestedFamilies { self.requestShow(family) } }
                    self.diagnostic = message["error"] as? String ?? ""
                    let denied = message["localNetworkDenied"] as? Bool ?? false
                    if denied && !self.networkDenied { self.error = "iOS blocked Local Network access. Enable Element Remote in Settings → Privacy & Security → Local Network, then retry." }
                    self.networkDenied = denied
                    self.networkStatus = message["localNetworkStatus"] as? String ?? "Not yet verified"
                    self.phase = message["phase"] as? String ?? "idle"
                    self.softwareVersion = message["version"] as? String ?? ""
                    self.latency = message["latencyMs"] as? Int
                    self.sentPackets = message["sentPackets"] as? Int ?? 0
                    self.receivedPackets = message["receivedPackets"] as? Int ?? 0
                }
            case "reset":
                if !self.demoMode {
                    self.clearShowSession()
                    self.session = UUID(); self.feedback = [:]; self.fixtures = [:]; self.fixtureAccumulator = EosFixtureAccumulator(); self.selection = []; self.ready = false; self.commandError = false; self.activeChannels = "No channel feedback yet"; self.selectedChannels = []; self.movementAvailable = false; self.colorAvailable = false
                    self.commandLine = "Waiting for console…"
                }
            case "osc": self.receiveOSC(message)
            case "oscBatch": for event in message["messages"] as? [[String: Any]] ?? [] { self.receiveOSC(event) }
            case "sendError": if !self.demoMode { self.error = message["message"] as? String ?? "Command not sent" }
            default: break
            }
        }
        if demoMode {
            toggleDemoMode(true)
        } else {
            connection.start()
        }
    }

    func toggleDemoMode(_ enabled: Bool, reconnect: Bool = true) {
        UserDefaults.standard.set(enabled, forKey: "element.demoMode")
        UserDefaults.standard.set(enabled, forKey: "element.testMode")
        demoFadeTimer?.invalidate(); demoFadeTimer = nil
        demoGeneration = UUID(); demoPlaybackID = UUID()
        bumpTokens = [:]; bumpRestore = [:]
        session = UUID()
        demoMode = enabled
        clearShowSession()
        feedback = [:]; fixtures = [:]; selectedChannels = []; movementAvailable = false; colorAvailable = false
        practiceDesk = EosPracticeDesk()
        if enabled {
            connection.disconnect()
            try? practiceDesk.execute("Chan 1 Thru 12 At Full Enter")
            online = true
            ready = true
            softwareVersion = "3.3 (Test Mode)"
            phase = "Practice"; networkStatus = "Test Mode"; latency = nil; diagnostic = ""; networkDenied = false
            commandLine = practiceDesk.commandLine
            activeChannels = "1 Thru 12"
            demoCueIndex = 1
            activeCueText = "1 Opening Scene (Warm Wash) 4.0s"
            pendingCueText = "2 Actor Crosses Stage Right 3.0s"
            activeCuePercent = 1.0
            isCueFading = false
            feedback["/eos/out/param/intens"] = [100]
            feedback["/eos/out/param/pan"] = [0]
            feedback["/eos/out/param/tilt"] = [0]
            feedback["/eos/out/param/zoom"] = [35]
            feedback["/eos/out/param/edge"] = [50]
            feedback["/eos/out/param/iris"] = [100]
            feedback["/eos/out/param/focus"] = [50]
            feedback["/eos/out/param/color_temp"] = [3200]
            feedback["/eos/out/param/tint"] = [0]
            feedback["/eos/out/param/diffusn"] = [0]
            feedback["/eos/out/param/gobo_rot"] = [0]
            feedback["/eos/out/color/hs"] = [35.0, 80.0]
            feedback["/eos/out/color/xy"] = [0.313, 0.329]
            for i in 1...40 {
                let lvl = Double(i % 5) * 0.25
                feedback["/eos/out/fader/1/\(i)"] = [lvl]
                feedback["/eos/fader/1/\(i)"] = [lvl]
                feedback["/eos/out/fader/1/\(i)/name"] = ["Sub \(i)"]
            }
            if cueHistory.isEmpty {
                cueHistory = [
                    CueHistoryItem(cue: "1", label: "Opening Scene (Warm Wash)", time: "Ready"),
                    CueHistoryItem(cue: "0.5", label: "House Half", time: "Ready")
                ]
            }
        } else {
            demoFadeTimer?.invalidate()
            demoFadeTimer = nil
            online = false
            ready = false
            softwareVersion = ""
            commandLine = "Connect to Element to begin"
            activeChannels = "No channel feedback yet"
            activeCueText = "No cue feedback yet"
            pendingCueText = "—"
            activeCuePercent = 0.0
            isCueFading = false
            if reconnect { connection.testConnection() }
        }
        if enabled { syncPracticeDesk(); oscUser = independentUser ? 2 : 1 }
    }

    private var bumpTokens: [Int: UUID] = [:]
    private var bumpRestore: [Int: Double] = [:]
    func bumpFaderDemo(_ numbers: [Int]) {
        let token = UUID(), currentSession = demoGeneration
        for n in numbers {
            if bumpTokens[n] == nil { bumpRestore[n] = (feedback["/eos/out/fader/1/\(n)"]?.first as? NSNumber)?.doubleValue ?? 0 }
            bumpTokens[n] = token
        }
        for n in numbers {
            feedback["/eos/out/fader/1/\(n)"] = [1.0]
            feedback["/eos/fader/1/\(n)"] = [1.0]
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.demoMode, self.demoGeneration == currentSession else { return }
            for n in numbers where self.bumpTokens[n] == token {
                let restored = self.bumpRestore.removeValue(forKey: n) ?? 0
                self.bumpTokens.removeValue(forKey: n)
                self.feedback["/eos/out/fader/1/\(n)"] = [restored]
                self.feedback["/eos/fader/1/\(n)"] = [restored]
            }
        }
    }

    private func receiveOSC(_ message: [String: Any]) {
        guard !demoMode else { return }
        guard var address = message["address"] as? String, let values = message["parameters"] as? [Any] else { return }
        if address.lowercased().hasPrefix("/eos/out/param/") {
            let name = address.split(separator: "/").last.map { String($0).lowercased() } ?? ""
            address = "/eos/out/param/" + (name == "intensity" ? "intens" : name)
        }
        if self.feedback.count >= 4096, self.feedback[address] == nil, let oldest = self.feedback.keys.first { self.feedback.removeValue(forKey: oldest) }
        self.feedback[address] = values
        if let fixture = self.fixtureAccumulator.receive(OSCMessage(address: address, parameters: values)) {
            if self.fixtures.count >= 512, self.fixtures[fixture.id] == nil, let first = self.fixtures.keys.first { self.fixtures.removeValue(forKey: first) }
            self.fixtures[fixture.id] = fixture
        }
        if recordRehearsal, let detail = EosRehearsalEvent.detail(address: address, values: values) { logRehearsal(detail) }
        receiveShowData(address, values)
        if address == "/eos/out/cmd" || (address.hasPrefix("/eos/out/user/") && address.hasSuffix("/cmd")) {
            self.commandLine = values.first as? String ?? ""
            self.commandError = (values.dropFirst().first as? NSNumber)?.intValue == 1
        }
        if address == "/eos/out/get/chans", let selection = values.first as? String {
            activeChannels = selection
            if let context = try? EosChannelSelection(selection.replacingOccurrences(of:",",with:" + ").replacingOccurrences(of:"-",with:" Thru ")) { selectedChannels = context.channels }
        }
        if address == "/eos/out/active/chan" {
            activeChannels = values.map { String(describing: $0) }.joined(separator: " ")
            let next = EosSelectionContext.channels(from: activeChannels)
            if next != selectedChannels {
                selectedChannels = next; if let first = next.first { fixtureParameters[first] = nil; requestParameters(first) }; movementAvailable = false; colorAvailable = false; session = UUID()
                feedback = feedback.filter { !$0.key.hasPrefix("/eos/out/param/") && !$0.key.hasPrefix("/eos/out/active/wheel/") && !$0.key.hasPrefix("/eos/out/color/") }
            }
        }
        if !selectedChannels.isEmpty, let first = values.first, !(first is NSNull), String(describing: first) != "" {
            let label = (address + " " + (values.first as? String ?? "")).lowercased()
            if label.contains("/param/pan") || label.contains("/param/tilt") || (address.hasPrefix("/eos/out/active/wheel/") && (label.contains("pan") || label.contains("tilt"))) { movementAvailable = true }
            if address.hasPrefix("/eos/out/color/") || (address.hasPrefix("/eos/out/param/") && ["red", "green", "blue", "cyan", "magenta", "yellow", "hue", "saturation"].contains(address.components(separatedBy: "/").last ?? "")) || (address.hasPrefix("/eos/out/active/wheel/") && ["color", "colour", "hue", "red", "cyan"].contains(where: { label.contains($0) })) { colorAvailable = true }
        }
        if address == "/eos/out/active/cue/text" {
            let text = values.first as? String ?? ""
            self.activeCueText = text
            let timeString = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let parts = text.split(separator: " ", maxSplits: 1)
            let cueNum = parts.first.map(String.init) ?? text
            let cueLbl = parts.count > 1 ? String(parts[1]) : ""
            if !self.cueHistory.contains(where: { $0.cue == cueNum && $0.label == cueLbl }) {
                self.cueHistory.insert(CueHistoryItem(cue: cueNum, label: cueLbl, time: timeString), at: 0)
                if self.cueHistory.count > 30 { self.cueHistory.removeLast() }
            }
        }
        if address == "/eos/out/pending/cue/text" {
            self.pendingCueText = values.first as? String ?? "—"
        }
        if address == "/eos/out/active/cue" || (address.hasPrefix("/eos/out/active/cue/") && !address.hasSuffix("/text")) {
            if let percent = (values.first as? NSNumber)?.doubleValue {
                self.activeCuePercent = min(max(percent, 0.0), 1.0)
                self.isCueFading = percent > 0.0 && percent < 1.0
            }
        }
        if address.hasPrefix("/eos/out/param/"), self.feedback.count > 4096 { self.feedback = self.feedback.filter { !$0.key.hasPrefix("/eos/out/get/patch/") } }
    }

    func key(_ name: String) {
        if demoMode {
            haptic()
            simulateDemoKey(name)
            return
        }
        guard ready else { error = "Connect to the console first. Commands are not queued."; return }
        haptic()
        connection.press(name)
    }

    func send(_ address: String, _ values: [Any] = []) {
        if demoMode {
            let path = address.split(separator: "/").map(String.init)
            if path.count == 5, path[1] == "chan", let channel = Int(path[2]), path[3] == "param", let value = values.first as? NSNumber {
                practiceDesk.setChannelParameter(channel, name:path[4], value:value.doubleValue); syncPracticeDesk(); return
            }
            if address == "/eos/xyz" { feedback["/eos/out/xyz"] = values; return }
            if address.hasPrefix("/eos/snap/") { commandLine = "Practice workspace recalled"; return }
            if address == "/eos/key/stop_effect_button" { practiceDesk.completeExternalCommand("Stop Effect"); syncPracticeDesk(); return }
            if address.hasPrefix("/eos/fader/1/"), address.hasSuffix("/home"), path.count == 5 {
                feedback["/eos/out/fader/1/" + path[3]] = [0.5]; return
            }
            if address.hasPrefix("/eos/key/"), let key = address.split(separator: "/").last.map(String.init) {
                if values.isEmpty || (values.first as? NSNumber)?.doubleValue != 0 { simulateDemoKey(key) }
            } else if address == "/eos/newcmd" || address == "/eos/cmd", let text = values.first as? String {
                if text.lowercased().hasPrefix("go_to_cue ") {
                    demoPlaybackID = UUID(); demoFadeTimer?.invalidate(); demoFadeTimer = nil; isCueFading = false
                    let cue = text.split(separator: " ").dropFirst().first.map(String.init) ?? "0"
                    practiceDesk.completeExternalCommand(text)
                    practiceDesk.fadeCue(Int(Double(cue) ?? 0), from: [:], progress: 1)
                    demoCueIndex = max(0, (Int(Double(cue) ?? 0))) % demoCues.count
                    syncPracticeDesk()
                    activeCueText = cue == "0" ? "0 Out" : "\(cue) Practice cue"
                    pendingCueText = "—"; activeCuePercent = cue == "0" ? 0 : 1
                    commandLine = text
                    return
                }
                if text.contains("Palette"), let palette = text.split(separator: " ").dropLast().last.flatMap({ Int($0) }) {
                    if text.hasPrefix("Color") { practiceDesk.setColor([Double(palette * 60 % 360), 80]) }
                    if text.hasPrefix("Focus") { practiceDesk.setParameter("pan", value: Double(palette * 20)); practiceDesk.setParameter("tilt", value: Double(palette * 10)) }
                    if text.hasPrefix("Beam") { practiceDesk.setParameter("zoom", value: Double(palette * 8)) }
                    practiceDesk.completeExternalCommand(text); syncPracticeDesk(); return
                }
                if text.hasPrefix("Effect ") { practiceDesk.completeExternalCommand(text); syncPracticeDesk(); return }
                do { try practiceDesk.execute(text); syncPracticeDesk() }
                catch { self.error = error.localizedDescription }
            } else if address.hasPrefix("/eos/fader/1/"), address.hasSuffix("/fire"), let n = Int(address.split(separator: "/").dropLast().last ?? "") {
                bumpFaderDemo([n])
            } else if address == "/eos/ds/4/cp/32" {
                for n in 1...32 { feedback["/eos/out/ds/4/\(n)"] = ["Color \(n)"] }
            } else if address.hasPrefix("/eos/fader/1/") {
                if let n = Int(address.split(separator: "/").last ?? ""), bumpTokens[n] != nil, let value = values.first as? NSNumber { bumpRestore[n] = value.doubleValue }
                feedback[address] = values
                feedback[address.replacingOccurrences(of: "/eos/", with: "/eos/out/")] = values
            } else if address.hasPrefix("/eos/wheel/"), let ticks = values.first as? NSNumber {
                let param = address.split(separator: "/").last.map(String.init) ?? ""
                practiceDesk.wheel(param, ticks: ticks.doubleValue, fine: address.contains("/fine/"))
                syncPracticeDesk()
            } else if address == "/eos/color/hs" || address == "/eos/color/xy" {
                practiceDesk.setColor(values.compactMap { ($0 as? NSNumber)?.doubleValue }, xy: address.hasSuffix("/xy"))
                syncPracticeDesk()
            }
            return
        }
        guard ready else { error = "Connect to the console first."; return }
        connection.send(address, values)
    }

    func send(_ message: OSCMessage) { send(message.address, message.parameters) }
    func sendBatch(_ messages: [OSCMessage]) {
        if demoMode {
            for m in messages { send(m) }
            return
        }
        guard ready else { error = "Connect to the console first."; return }
        for offset in stride(from: 0, to: messages.count, by: 64) { connection.sendBatch(Array(messages.dropFirst(offset).prefix(64))) }
    }

    func tap(_ address: String) {
        if demoMode {
            let parts = address.split(separator: "/").map(String.init)
            if parts.count == 4, parts[1] == "ds", parts[2] == "4", let n = Int(parts[3]), (1...32).contains(n) {
                practiceDesk.setColor([Double(n-1) / 32 * 360, 80]); syncPracticeDesk()
            }
            if parts.count == 4, parts[1] == "param" {
                let name = parts[2]
                if parts[3] == "home" {
                    let homes = ["pan": 0.0, "tilt": 0.0, "zoom": 35.0, "edge": 50.0, "iris": 100.0]
                    practiceDesk.setParameter(name, value: homes[name] ?? 0)
                } else if let parameter = fixtureParameters[selectedChannels.first ?? 0]?.first(where: { $0.oscName == name }) {
                    practiceDesk.setParameter(name, value: parts[3] == "max" ? parameter.maximum : parameter.minimum)
                } else { practiceDesk.extreme(name, maximum: parts[3] == "max") }
                syncPracticeDesk()
            }
            return
        }
        guard ready else { error = "Connect to the console first."; return }
        connection.pulse(address)
    }

    private func simulateDemoKey(_ name: String) {
        if name == "enter", practiceDesk.entry.lowercased().hasPrefix("go_to_cue ") {
            let cue = practiceDesk.entry.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            goToCue(cue); return
        }
        switch name {
        case "go_0":
            simulateDemoGo()
        case "stop":
            if isCueFading {
                demoPlaybackID = UUID(); demoFadeTimer?.invalidate()
                demoFadeTimer = nil
                isCueFading = false
            } else {
                let previous = max(0, demoCueIndex - 2)
                let c = demoCues[previous % demoCues.count]
                practiceDesk.fadeCue(Int(c.cue) ?? 0, from: [:], progress: 1); syncPracticeDesk()
                demoCueIndex = previous + 1
                activeCueText = "\(c.cue) \(c.label) \(c.duration)s"
                pendingCueText = demoCues[demoCueIndex % demoCues.count].cue
                activeCuePercent = 1.0
            }
        default:
            do { try practiceDesk.press(name); syncPracticeDesk() }
            catch { commandError = true; self.error = error.localizedDescription }
        }
    }

    func goToCue(_ cue: String, list: Int? = nil) {
        guard let message = try? EosCommands.goToCue(cue, list: list) else { error = "Enter a valid cue number"; return }
        send(message)
    }
    func useConsole(_ profile: ConsoleProfile) {
        let config: [String: Any] = ["displayName": profile.name, "consoleHost": profile.host, "transport": profile.transport, "consolePort": profile.consolePort, "receivePort": profile.receivePort]
        do {
            _ = try NativeConsoleSettings.parse(config)
            if demoMode { toggleDemoMode(false, reconnect: false) }
            try connection.configure(config)
        } catch { self.error = error.localizedDescription }
    }

    private func syncPracticeDesk() {
        commandError = false
        commandLine = practiceDesk.commandLine
        let next = practiceDesk.selection?.channels ?? []
        if next != selectedChannels { session = UUID() }
        selectedChannels = next
        movementAvailable = next.contains { (5...8).contains($0) }
        colorAvailable = next.contains { (1...8).contains($0) }
        activeChannels = practiceDesk.selection?.expression ?? "No channels selected"
        // Readouts describe the first selected fixture, as Eos OSC feedback does.
        for key in Array(feedback.keys) where key.hasPrefix("/eos/out/param/") || key.hasPrefix("/eos/out/color/") {
            feedback.removeValue(forKey: key)
        }
        guard let first = practiceDesk.selection?.channels.first else { return }
        requestParameters(first)
        let defaults = ["intens": 0.0, "pan": 0.0, "tilt": 0.0, "zoom": 35.0, "edge": 50.0, "iris": 100.0, "focus": 50.0, "color_temp": 3200.0, "tint": 0.0, "diffusn": 0.0, "gobo_rot": 0.0]
        for (name, fallback) in defaults {
            feedback["/eos/out/param/" + name] = [practiceDesk.parameters[first]?[name] ?? fallback]
        }
        feedback["/eos/out/color/hs"] = practiceDesk.colors[first] ?? [35.0, 80.0]
        feedback["/eos/out/color/xy"] = practiceDesk.coordinates[first] ?? [0.313, 0.329]
    }

    private func simulateDemoGo() {
        demoFadeTimer?.invalidate()
        isCueFading = true
        activeCuePercent = 0.0
        let current = demoCues[demoCueIndex % demoCues.count]
        let next = demoCues[(demoCueIndex + 1) % demoCues.count]
        activeCueText = "\(current.cue) \(current.label) \(current.duration)s"
        pendingCueText = "\(next.cue) \(next.label) \(next.duration)s"
        let start = ProcessInfo.processInfo.systemUptime
        demoPlaybackID = UUID()
        let playSession = demoPlaybackID
        let duration = current.duration
        let startingLevels = Dictionary(uniqueKeysWithValues: (1...12).map { ($0, practiceDesk.parameters[$0]?["intens"] ?? 0) })
        demoFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor in
                guard timer.isValid, self.demoMode, self.demoPlaybackID == playSession else { timer.invalidate(); return }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let progress = min(elapsed / duration, 1.0)
                self.activeCuePercent = progress
                self.practiceDesk.fadeCue(Int(current.cue) ?? 0, from: startingLevels, progress: progress)
                self.syncPracticeDesk()
                if progress >= 1.0 {
                    timer.invalidate()
                    self.demoFadeTimer = nil
                    self.isCueFading = false
                    self.demoCueIndex += 1
                    let timeString = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                    self.cueHistory.insert(CueHistoryItem(cue: current.cue, label: current.label, time: timeString), at: 0)
                }
            }
        }
    }

    func requestFixtureDetails(_ channels: [Int]) {
        for channel in channels.prefix(12) { requestParameters(channel) }
        if demoMode {
            for ch in channels {
                let isLED = ch <= 4, isMover = (5...8).contains(ch)
                let fixture = EosFixtureRecord(
                    channel: ch,
                    part: 1,
                    label: "Stage Fixture \(ch)",
                    manufacturer: isLED ? "ETC" : isMover ? "High End Systems" : "Generic",
                    model: isLED ? "Source Four LED Lustr" : isMover ? "SolaFrame 750" : "Dimmer",
                    address: (ch - 1) * 7 + 1,
                    intensityAddress: (ch - 1) * 7 + 1,
                    level: practiceDesk.parameters[ch]?["intens"] ?? 0,
                    gel: ch % 2 == 0 ? "R80" : "L201",
                    notes: "Simulated desk fixture for offline test mode",
                    endingAddress: (ch - 1) * 7 + (isLED || isMover ? 7 : 1)
                )
                fixtures[fixture.id] = fixture
            }
            return
        }
        guard ready else { return }
        let selected = Set(channels.prefix(12))
        fixtureAccumulator.clear(channels: selected)
        fixtures = fixtures.filter { !selected.contains($0.value.channel) }
        for channel in selected.sorted() { send("/eos/get/patch/\(channel)") }
    }

    func logRehearsal(_ detail: String) {
        rehearsalEvents.insert(EosRehearsalEvent(show: text("/eos/out/show/name"), detail: detail), at: 0)
        rehearsalEvents = Array(rehearsalEvents.prefix(1000))
        saveRehearsal()
    }
    func saveRehearsal() {
        rehearsalSave?.cancel()
        // Persist after each event so background suspension does not lose the log.
        if let data = try? JSONEncoder().encode(rehearsalEvents) { UserDefaults.standard.set(data, forKey: "element.rehearsalEvents") }
    }
    func park(_ selection:EosChannelSelection, percent:Int) {
        guard ready, let message = try? selection.parkIntensity(percent) else { return }
        if demoMode { send(message); return }
        let blind = (feedback["/eos/out/event/state"]?.first as? NSNumber)?.intValue == 0
        var batch = [OSCMessage(address:"/eos/key/live",parameters:[1.0]),OSCMessage(address:"/eos/key/live",parameters:[0.0]),message]
        if blind { batch += [OSCMessage(address:"/eos/key/blind",parameters:[1.0]),OSCMessage(address:"/eos/key/blind",parameters:[0.0])] }
        sendBatch(batch)
    }
    func unpark(_ selection:EosChannelSelection) {
        guard ready else { return }
        if demoMode { practiceDesk.unpark(selection.channels); syncPracticeDesk(); return }
        let blind = (feedback["/eos/out/event/state"]?.first as? NSNumber)?.intValue == 0
        sendBatch(selection.unpark(restoreBlind:blind))
    }
    func patchNote(channel: Int, part: Int, label: String, note: String) {
        guard ready else { return }
        if demoMode {
            let id = "\(channel)/\(part)"
            if let old = fixtures[id] { fixtures[id] = EosFixtureRecord(channel: channel, part: part, label: label, manufacturer: old.manufacturer, model: old.model, address: old.address, intensityAddress: old.intensityAddress, level: old.level, gel: old.gel, notes: note, endingAddress: old.endingAddress, textFields: old.textFields, partCount: old.partCount) }
            return
        }
        send("/eos/set/patch/\(channel)/\(part)/label", [label])
        send("/eos/set/patch/\(channel)/\(part)/notes", [note])
        send("/eos/get/patch/\(channel)/\(part)")
    }

    private func clearShowSession() {
        queryGeneration = UUID(); familyGenerations = [:]
        refreshWork.values.forEach { $0.cancel() }; refreshWork = [:]
        showData = EosShowData(); showCounts = [:]; fixtureParameters = [:]; emitters = [:]; processors = [:]; healthReceivedAt = nil; processorCount = nil; pendingProcessorHealth = nil; oscUser = nil
    }

    func applyUserMode() {
        UserDefaults.standard.set(independentUser, forKey:"element.independentUser")
        session = UUID(); selectedChannels = []; activeChannels = "No channels selected"; commandLine = "Waiting for user feedback…"; commandError = false; movementAvailable = false; colorAvailable = false; fixtureParameters = [:]; emitters = [:]; oscUser = nil
        feedback = feedback.filter { !$0.key.hasPrefix("/eos/out/param/") && !$0.key.hasPrefix("/eos/out/active/") && !$0.key.hasPrefix("/eos/out/color/") && !$0.key.hasPrefix("/eos/out/softkey/") }
        if demoMode { oscUser = independentUser ? 2 : 1; return }
        guard ready else { return }
        send(EosCapabilities.userSelection(independent:independentUser))
        send("/eos/get/chans"); send("/eos/get/userlist")
    }
    func requestEmitters(_ channel: Int) {
        guard ready else { return }
        if demoMode {
            let names = ["Red","Green","Blue","Lime","Amber"]
            var values: [Any] = ["ETC","Lustr"]
            for name in names { values += [name,practiceDesk.parameters[channel]?[name.lowercased()] ?? 50,0,100] }
            emitters[channel] = EosFixtureParameter.parse(values); return
        }
        send("/eos/get/emitters/\(channel)")
    }
    func requestDiagnostics() {
        guard ready else { return }
        if demoMode {
            if let processor = EosProcessorHealth.parse([1,-1,true,0,"Practice Element","Element","Element Classic","192.168.1.100","1>2"]) { processors = [processor.id:processor] }
            healthReceivedAt = Date(); processorCount = 1; oscUser = independentUser ? 2 : 1
            feedback["/eos/out/get/userlist"] = [3,1,"Element","Practice desk"]; return
        }
        send("/eos/get/processors"); send("/eos/get/session"); send("/eos/get/userlist"); send("/eos/get/version")
    }

    func requestParameters(_ channel: Int) {
        guard channel > 0 else { return }
        if demoMode {
            fixtureParameters[channel] = EosFixtureParameter.parse(["High End Systems", "SolaFrame", "Intens", 75, 0, 100, "Pan", 0, -270, 270, "Tilt", 35, -135, 135, "Zoom", 30, 5, 50, "Edge", 50, 0, 100, "Gobo_Select", 0, 0, 255, "Gobo_Rotate", 0, -180, 180, "Iris", 100, 0, 100, "Shutter_Strobe", 0, 0, 255])
            if let data = practiceDesk.parameters[channel], let parameters = fixtureParameters[channel] {
                fixtureParameters[channel] = EosFixtureParameter.parse(["High End Systems", "SolaFrame"] + parameters.flatMap { p -> [Any] in [p.name, data[p.oscName] ?? p.level, p.minimum, p.maximum] })
            }
            return
        }
        guard ready else { return }
        send("/eos/get/params/\(channel)")
    }

    func requestShow(_ family: String, reset: Bool = true) {
        guard ["cuelist", "fp", "cp", "bp", "sub", "snap", "fx", "preset"].contains(family) || family.range(of: #"^cue/[0-9]+$"#, options: .regularExpression) != nil else { return }
        requestedFamilies.insert(family)
        if reset { showData.clear(family); showCounts[family] = nil }
        if demoMode {
            let count = family.hasPrefix("cue/") ? 6 : 4
            showCounts[family] = count
            for i in 1...count {
                let key = family.hasPrefix("cue/") ? "\(family)/\(i)/0" : "\(family)/\(i)"
                var fields: [Any] = [i-1, "demo-\(key)", family.hasPrefix("cue/") ? "Scene \(i)" : "\(family.uppercased()) \(i)"]
                if family.hasPrefix("cue/") { fields += [4000, 0, 3000, 0, 2000, 0, 2000, 0, 2000, 0, false, 0, 100, "", "", "", 0, 0, 0, false, 0, false, "", 0, "Practice cue", "", false, -1] }
                if family == "sub" { fields += ["Additive", "Proportional", true, false, true, false, "Normal", "3", "Hold", "3"] }
                showData.receive(OSCMessage(address: "/eos/out/get/\(key)/list/0/\(fields.count)", parameters: fields))
                if ["fp", "cp", "bp"].contains(family) {
                    showData.receive(OSCMessage(address: "/eos/out/get/\(key)/channels/list/0/3", parameters: [i-1, "demo", "1 Thru 12"]))
                }
            }
            return
        }
        guard ready else { return }
        send("/eos/subscribe", [1]); send("/eos/get/\(family)/count")
    }

    private func receiveShowData(_ address: String, _ values: [Any]) {
        let path = address.split(separator: "/").map(String.init)
        if address == "/eos/out/user" { oscUser = (values.first as? NSNumber)?.intValue }
        if address == "/eos/out/get/processors" {
            if values.count == 1, let count = values.first as? NSNumber, (0...512).contains(count.intValue) {
                processorCount = count.intValue; pendingProcessorHealth = [:]
                if count.intValue == 0 { processors = [:]; pendingProcessorHealth = nil; healthReceivedAt = Date() }
            }
            if let processor = EosProcessorHealth.parse(values) {
                if pendingProcessorHealth != nil {
                    pendingProcessorHealth?[processor.id] = processor
                    if pendingProcessorHealth?.count == processorCount { processors = pendingProcessorHealth ?? [:]; pendingProcessorHealth = nil; healthReceivedAt = Date() }
                } else { processors[processor.id] = processor; healthReceivedAt = Date() }
            }
        }
        if path.count == 5, Array(path.prefix(4)) == ["eos", "out", "get", "emitters"], let channel = Int(path[4]) { emitters[channel] = EosFixtureParameter.parse(values) }
        if path.count == 5, Array(path.prefix(4)) == ["eos", "out", "get", "params"], let channel = Int(path[4]) {
            fixtureParameters[channel] = EosFixtureParameter.parse(values)
        }
        showData.receive(OSCMessage(address: address, parameters: values))
        if address.hasPrefix("/eos/out/get/"), address.hasSuffix("/count"), let count = values.first as? NSNumber {
            let family = path.dropFirst(3).dropLast().joined(separator: "/")
            guard requestedFamilies.contains(family) else { return }
            let total = max(0, min(10000, count.intValue)); showCounts[family] = total
            let generation = queryGeneration
            let familyGeneration = UUID(); familyGenerations[family] = familyGeneration
            for index in 0..<total {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.025) { [weak self] in
                    guard let self, self.ready, !self.demoMode, generation == self.queryGeneration, self.familyGenerations[family] == familyGeneration else { return }
                    self.send("/eos/get/\(family)/index/\(index)")
                }
            }
        }
        if address.hasPrefix("/eos/out/notify/") {
            let candidates = requestedFamilies.filter { family in address.hasPrefix("/eos/out/notify/" + family + "/") }
            for family in candidates {
                refreshWork[family]?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.requestShow(family) }
                refreshWork[family] = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
        }
        if address == "/eos/out/event/show/loaded" || address == "/eos/out/event/show/cleared" {
            clearShowSession()
            for family in requestedFamilies { requestShow(family) }
        }
    }

    func haptic(continuous: Bool = false) {
        let enabled = UserDefaults.standard.object(forKey: "element.native.haptics") as? Bool ?? true
        guard hapticCadence.allow(at: ProcessInfo.processInfo.systemUptime, enabled: enabled, continuous: continuous) else { return }
        impactFeedback.impactOccurred(intensity: continuous ? 0.25 : 0.45)
        impactFeedback.prepare()
    }

    func text(_ address: String) -> String { feedback[address]?.map { String(describing: $0) }.joined(separator: " ") ?? "" }
}

private struct ConsoleKey: Identifiable {
    var title: String; var address: String; var color: Color = .gray
    var id: String { address }
    init(_ title: String, _ address: String, _ color: Color = .gray) { self.title = title; self.address = address; self.color = color }
}

private let selectionKeys: [ConsoleKey] = [.init("Macro", "macro"), .init("Effect", "effect"), .init("Recall From", "recall_from"), .init("Park", "park"), .init("Address", "address"), .init("Select Last", "select_last"), .init("Select Man", "select_manual"), .init("Last", "last"), .init("Next", "next")]

private enum DeskPalette {
    static var nightVision: Bool { UserDefaults.standard.bool(forKey: "element.nightVision") }
    static var background: Color { nightVision ? Color(red: 0.05, green: 0.01, blue: 0.01) : Color(white: 0.045) }
    static var surface: Color { nightVision ? Color(red: 0.12, green: 0.02, blue: 0.02) : Color(white: 0.105) }
    static var raised: Color { nightVision ? Color(red: 0.20, green: 0.04, blue: 0.04) : Color(white: 0.145) }
    static var field: Color { nightVision ? Color(red: 0.08, green: 0.01, blue: 0.01) : Color(white: 0.065) }
    static var accent: Color { nightVision ? Color(red: 1.0, green: 0.25, blue: 0.25) : Color(red: 0.92, green: 0.81, blue: 0.62) }
    static var rule: Color { Color.white.opacity(0.075) }
    static var surfaceGradient: LinearGradient {
        LinearGradient(colors: [raised.opacity(0.8), surface], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var edgeGradient: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.035)], startPoint: .top, endPoint: .bottom)
    }
}

private struct DeskButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("element.nightVision") private var nightVision = false
    var accent: Color = .gray
    var prominent = false
    private var tint: Color {
        if nightVision { return .red }
        switch accent {
        case .blue: return Color(red: 0.64, green: 0.75, blue: 0.90)
        case .purple: return Color(red: 0.77, green: 0.69, blue: 0.89)
        case .red: return Color(red: 0.94, green: 0.57, blue: 0.53)
        case .orange: return Color(red: 0.91, green: 0.76, blue: 0.54)
        case .green: return Color(red: 0.64, green: 0.82, blue: 0.68)
        case .teal, .mint: return Color(red: 0.68, green: 0.83, blue: 0.78)
        default: return accent
        }
    }
    private let radius: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(accent == .gray && !nightVision ? Color(white: 0.94) : tint)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [configuration.isPressed ? DeskPalette.surface : DeskPalette.raised, DeskPalette.surface], startPoint: .top, endPoint: .bottom))
                if accent != .gray || nightVision {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(prominent ? 0.25 : 0.10), tint.opacity(prominent ? 0.15 : reduceTransparency ? 0.08 : 0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(accent == .gray ? DeskPalette.edgeGradient : LinearGradient(colors: [tint.opacity(prominent ? 0.45 : 0.25), tint.opacity(0.10)], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.22), radius: 4, x: 0, y: 2)
            .opacity(enabled ? 1 : 0.38)
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension View {
    func deskPanel(cornerRadius: CGFloat = 18) -> some View {
        self.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(DeskPalette.surfaceGradient)
        }.overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(DeskPalette.edgeGradient, lineWidth: 0.75)
        }.shadow(color: .black.opacity(0.16), radius: 10, x: 0, y: 4)
    }
    func deskCard() -> some View {
        self.padding(16).deskPanel()
    }
    @ViewBuilder func commandGlass() -> some View {
        if #available(iOS 26.0, *) {
            self.background(DeskPalette.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        } else {
            self.background(DeskPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(DeskPalette.rule) }
        }
    }
}

struct NativeRemoteView: View {
    @StateObject private var model = NativeRemoteModel()
    @StateObject private var wifi = WiFiStatus()
    @StateObject private var discovery = ConsoleDiscovery()
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var selectedTab = 0
    @State private var paths: [String: [RemoteTool]] = [:]

    init() {
        #if targetEnvironment(simulator)
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--capture-tab=") }),
           let tab = Int(argument.dropFirst("--capture-tab=".count)), (0...3).contains(tab) {
            _selectedTab = State(initialValue: tab)
        }
        #endif
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                screen("Console") { NativeConsoleView() }.tabItem { Label("Console", systemImage: "keyboard") }.tag(0)
                screen("Faders") { NativeFadersView() }.tabItem { Label("Faders", systemImage: "slider.vertical.3") }.tag(1)
                screen("Playback") { NativePlaybackView() }.tabItem { Label("Playback", systemImage: "play.fill") }.tag(2)
                screen("More") { NativeMoreView() }.tabItem { Label("More", systemImage: "ellipsis") }.tag(3)
            }
            .onChange(of: selectedTab) { _ in model.haptic() }
            .environmentObject(model)
            .environmentObject(wifi)
            .environmentObject(discovery)
            .tint(DeskPalette.accent)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { phase in if phase == .active { wifi.refresh() } }
            

        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                NativeConnectionView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } } }
            }.environmentObject(model).environmentObject(wifi).environmentObject(discovery)
                .preferredColorScheme(.dark).tint(DeskPalette.accent)
        }
    }

    private func screen<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(spacing: 0) {
            screenHeader(title)
            NavigationStack(path: Binding(get: { paths[title] ?? [] }, set: { paths[title] = $0 })) {
                VStack(spacing: 0) {
                    content().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
                }.background(DeskPalette.background)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: RemoteTool.self) { tool in
                VStack(spacing: 0) {
                    switch tool {
                    case .movement: NativeWheelsView()
                    case .color: NativeColorView()
                    }
                }.toolbar(.visible, for: .navigationBar)
            }
                    .scrollDismissesKeyboard(.interactively)
                    .submitLabel(.done)
                    .onSubmit { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer(); Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                        }
                    }
            }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .padding(.top, horizontalSizeClass == .regular ? 8 : 0)
        .background(DeskPalette.background.ignoresSafeArea())
        .alert("Console", isPresented: Binding(get: { !model.error.isEmpty }, set: { if !$0 { model.error = "" } })) {
            Button("OK", role: .cancel) { model.error = "" }
        } message: { Text(model.error) }
    }
    @ViewBuilder private func screenHeader(_ title: String) -> some View {
        if verticalSizeClass == .compact {
            HStack(spacing:14) {
                Text(title).font(.system(size:22,weight:.semibold)).tracking(-0.5).fixedSize()
                if title == "Console" || !(paths[title] ?? []).isEmpty {
                    NativeCommandReadout().padding(.horizontal,10).padding(.vertical,6).background(DeskPalette.surface,in:RoundedRectangle(cornerRadius:10)).frame(maxWidth:.infinity)
                } else { Spacer() }
                if model.demoMode { Text("TEST").font(.caption2.weight(.semibold)).foregroundStyle(DeskPalette.accent) }
                Button { showSettings = true } label: { Image(systemName:"gearshape").frame(width:44,height:44) }.buttonStyle(.plain).accessibilityLabel("Settings")
            }.padding(.horizontal,16).background(DeskPalette.background)
        } else {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 32, weight: .semibold)).tracking(-0.9)
                Spacer()
                if title != "More" && title != "Console" {
                    Button { showSettings = true } label: {
                        Image(systemName: "link").font(.system(size: 20)).frame(width: 38, height: 38)
                            .background(.white.opacity(0.07), in: Circle())
                    }.accessibilityLabel("Connections")
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 20, weight: .regular)).frame(width: 44, height: 44)
                        .background(DeskPalette.surface, in: Circle())
                        .overlay { Circle().strokeBorder(DeskPalette.rule, lineWidth: 0.75) }
                }.accessibilityLabel("Settings")
            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.9))
                .frame(height: 48).fixedSize(horizontal: false, vertical: true).layoutPriority(2)
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
            if !model.online && !model.demoMode {
            Button { showSettings = true } label: {
                HStack(spacing: 8) {
                    Circle().fill(model.online ? Color.green : Color.gray).frame(width: 8, height: 8)
                    Text(model.demoMode ? "Test Mode" : model.online ? "Connected" : model.ready ? "Awaiting reply" : "Offline")
                    if !model.ready { Text("·  Connect") }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }.font(.subheadline).padding(.horizontal, 14).frame(height: 40)
                    .background(DeskPalette.raised.opacity(0.65), in: RoundedRectangle(cornerRadius: 13))
            }.buttonStyle(.plain).frame(height: 40).fixedSize(horizontal: false, vertical: true).layoutPriority(2)
                .padding(.horizontal, 18).padding(.bottom, 12)
            }
            if title == "Console" || !(paths[title] ?? []).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Command").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        if model.demoMode {
                            Text("TEST MODE").font(.system(size: 9, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(DeskPalette.accent).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(DeskPalette.accent.opacity(0.08), in: Capsule())
                                .overlay { Capsule().strokeBorder(DeskPalette.accent.opacity(0.18), lineWidth: 0.5) }
                        }
                    }.padding(.horizontal, 8)
                    NativeCommandReadout()
                        .padding(12)
                        .background(DeskPalette.surfaceGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(model.demoMode ? DeskPalette.accent.opacity(0.55) : DeskPalette.rule, lineWidth: 0.75) }
                }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
            }
        }.background(DeskPalette.background).fixedSize(horizontal: false, vertical: true)
        }
    }

}

private enum RemoteTool: Hashable { case movement, color }

private struct NativeCommandReadout: View {
    @EnvironmentObject var model: NativeRemoteModel
    var body: some View {
        let command = model.commandPresentation
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(DeskPalette.accent).frame(width: 1, height: 21)
            (Text(command.text.isEmpty ? (model.ready ? "Ready" : "Waiting for console…") : command.text)
                + Text(command.isComplete ? "  ◦" : "").foregroundColor(DeskPalette.accent))
                .foregroundStyle(model.commandError ? Color.red : command.text.isEmpty ? Color.secondary : Color.primary)
                .font(.system(size: 17)).frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .textSelection(.enabled).lineLimit(3)
                .accessibilityLabel("Console command: " + command.text)
                .accessibilityValue(command.isComplete ? "Command complete" : "Editing command")
        }
    }
}

private struct NativeQuickControlView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var entry = ""
    @State private var validation = ""
    @State private var chosen: EosChannelSelection?
    @State private var showActions = false
    @AppStorage("element.quick.recent") private var recentData = ""
    private var parsed: EosChannelSelection? { try? EosChannelSelection(entry) }
    private var recents: [String] { recentData.components(separatedBy:"|").filter { !$0.isEmpty } }
    private let keys = ["7", "8", "9", "Thru", "4", "5", "6", "+", "1", "2", "3", "−", "Clear", "0", "⌫"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CHANNELS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(entry.isEmpty ? "Enter channel numbers" : entry).font(.system(size: 28, weight: .medium, design: .monospaced)).foregroundStyle(entry.isEmpty ? Color.secondary : Color.primary).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).accessibilityLabel("Channel selection: " + (entry.isEmpty ? "empty" : entry))
                    if let parsed { Label("\(parsed.channels.count) channel\(parsed.channels.count == 1 ? "" : "s")",systemImage:"checkmark.circle").font(.caption).foregroundStyle(DeskPalette.accent) }
                    else { Text(entry.isEmpty ? "Try 42 or 1 Thru 5 + 12" : "Finish the channel list to continue").font(.caption).foregroundStyle(.secondary) }
                    if !model.selectedChannels.isEmpty {
                        Button("Use console selection") { entry = model.selectedChannels.map(String.init).joined(separator:" + "); validation = "" }.font(.subheadline)
                    }
                }.deskCard()
                if !recents.isEmpty {
                    ScrollView(.horizontal,showsIndicators:false) { HStack { ForEach(recents,id:\.self) { recent in Button(recent) { entry = recent; validation = "" }.buttonStyle(.bordered) } } }.accessibilityLabel("Recent channel selections")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                    ForEach(keys, id: \.self) { key in
                        Button { edit(key) } label: { Text(key).font(.system(size: 22, weight: .medium)).frame(maxWidth: .infinity, minHeight: 64) }.buttonStyle(DeskButtonStyle()).accessibilityLabel(key == "⌫" ? "Backspace" : key)
                    }
                }
                Button { enter() } label: { Text("Control channels").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 62) }.buttonStyle(DeskButtonStyle(accent: DeskPalette.accent, prominent: true)).disabled(parsed == nil)
                if !validation.isEmpty { Text(validation).font(.subheadline).foregroundStyle(.orange) }
            }.padding()
        }.navigationDestination(isPresented: $showActions) { if let chosen { NativeChannelActionsView(selection: chosen) } }
    }
    private func edit(_ key: String) {
        model.haptic(); validation = ""
        switch key {
        case "Clear": entry = ""
        case "⌫":
            entry = entry.trimmingCharacters(in: .whitespaces)
            if entry.hasSuffix("Thru") { entry.removeLast(4) } else if !entry.isEmpty { entry.removeLast() }
        case "Thru", "+", "−": entry += " " + (key == "−" ? "-" : key) + " "
        default: if entry.count < 256 { entry += key }
        }
    }
    private func enter() {
        do {
            let selection = try EosChannelSelection(entry)
            model.haptic(); chosen = selection; validation = ""
            recentData = ([selection.expression] + recents.filter { $0 != selection.expression }).prefix(6).joined(separator:"|")
            if model.ready { model.send(selection.select()) }
            showActions = true
        } catch { validation = error.localizedDescription }
    }
}

private struct NativeChannelActionsView: View {
    @EnvironmentObject var model: NativeRemoteModel
    let selection: EosChannelSelection
    @State private var brightness = 0.0
    @State private var lastSent = -Double.infinity
    @State private var levelSession: UUID?
    @State private var brightnessTouched = false
    @State private var details = false
    @State private var parkLevel = 100
    @State private var parkStatus = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CHANNELS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(selection.expression).font(.title2.monospacedDigit().weight(.semibold))
                    Text("\(selection.channels.count) channel\(selection.channels.count == 1 ? "" : "s") · actions target this list").font(.caption).foregroundStyle(.secondary)
                    if !model.ready { Text("Disconnected · connect to use quick actions").font(.subheadline).foregroundStyle(.orange) }
                }.deskCard()
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("Brightness").font(.headline); Spacer(); Text(brightnessTouched ? "\(Int(brightness))%" : "—").font(.system(size:34,weight:.medium,design:.rounded)).monospacedDigit().foregroundStyle(DeskPalette.accent) }
                    Slider(value: Binding(get: { brightness }, set: { value in brightness = value; applyLevel() }), in: 0...100, step: 1, onEditingChanged: { editing in
                        if editing { levelSession = model.session }
                        else { applyLevel(force: true); levelSession = nil; model.haptic() }
                    }).accessibilityLabel("Brightness for channels " + selection.expression)
                    HStack(spacing: 7) {
                        ForEach([0,25,50,75,100], id: \.self) { value in
                            Button(value == 0 ? "Out" : value == 100 ? "Full" : "\(value)%") { brightness = Double(value); applyLevel(force: true); model.haptic() }.frame(maxWidth: .infinity)
                        }
                    }.buttonStyle(.bordered)
                    Text("Sets intensity for the channel list shown above.").font(.caption).foregroundStyle(.secondary)
                }.deskCard().disabled(!model.ready)
                VStack(alignment:.leading,spacing:12) {
                    Text("Park").font(.headline)
                    Stepper("Intensity · \(parkLevel)%",value:$parkLevel,in:0...100,step:5)
                    HStack(spacing:10) {
                        Button("Park at \(parkLevel)%") { model.park(selection,percent:parkLevel); parkStatus = "Park command sent for channels " + selection.expression }.frame(maxWidth:.infinity,minHeight:48).buttonStyle(DeskButtonStyle(accent:DeskPalette.accent))
                        Button("Unpark") { model.unpark(selection); parkStatus = "Unpark command sent for channels " + selection.expression }.frame(maxWidth:.infinity,minHeight:48).buttonStyle(DeskButtonStyle())
                    }
                    Text("Park locks intensity until released, including against cue playback and blackout. Unpark releases parked parameters for this channel list. Verify the Park display on the console.").font(.caption).foregroundStyle(.secondary)
                    if !parkStatus.isEmpty { Text(parkStatus).font(.caption).foregroundStyle(DeskPalette.accent) }
                }.deskCard().disabled(!model.ready)
                HStack(spacing: 8) {
                    Button { model.haptic(); model.send(selection.remDim()) } label: { Label("Rem Dim", systemImage: "light.min").frame(maxWidth: .infinity, minHeight: 60) }.buttonStyle(DeskButtonStyle(accent: .purple))
                    Button { model.haptic(); model.key("rem_dim") } label: { Text("Restore").multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 60) }.buttonStyle(DeskButtonStyle())
                }.disabled(!model.ready)
                Text("Rem Dim lowers other lights. Restore toggles it off.").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { model.haptic(); model.send(selection.highlight()) } label: { Text("Highlight").frame(maxWidth: .infinity, minHeight: 50) }.buttonStyle(DeskButtonStyle())
                    Button { model.haptic(); model.send(selection.sneak()) } label: { Text("Sneak to cue").frame(maxWidth: .infinity, minHeight: 50) }.buttonStyle(DeskButtonStyle())
                }.disabled(!model.ready)
                Button { model.haptic(); details = true } label: { Label("Fixture details", systemImage: "info.circle").frame(maxWidth: .infinity, minHeight: 54) }.buttonStyle(DeskButtonStyle(accent: .blue))
                HStack(spacing:10) {
                    NavigationLink { NativeWheelsView() } label: { Label("Movement",systemImage:"move.3d").frame(maxWidth:.infinity,minHeight:48) }
                    NavigationLink { NativeColorView() } label: { Label("Color",systemImage:"paintpalette").frame(maxWidth:.infinity,minHeight:48) }
                }.buttonStyle(.bordered).simultaneousGesture(TapGesture().onEnded { if model.ready { model.send(selection.select()) } })
                NavigationLink("Beam & Optics") { NativeWheelsView(beamOnly:true) }.buttonStyle(.bordered).simultaneousGesture(TapGesture().onEnded { if model.ready { model.send(selection.select()) } })
            }.padding()
        }.navigationTitle("Channel control")
        .sheet(isPresented: $details) {
            NavigationStack {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.demoMode { Text("TEST MODE").font(.caption2.weight(.semibold)).foregroundStyle(.yellow).padding(6).background(Color.yellow.opacity(0.1), in: Capsule()) }
                        NativeCommandReadout()
                    }.padding(12).commandGlass()
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(model.demoMode ? Color.yellow : .clear, lineWidth: 1.5) }
                    .padding(12).fixedSize(horizontal: false, vertical: true)
                    NativeFixtureDetailsView(selection: selection)
                }
                .background(DeskPalette.background)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { details = false } } }
            }.environmentObject(model)
        }
        .onChange(of: model.ready) { ready in if !ready { brightnessTouched = false } }
    }
    private func applyLevel(force: Bool = false) {
        guard model.ready, levelSession == nil || levelSession == model.session, force || (ProcessInfo.processInfo.systemUptime - lastSent) >= 1.0/30 else { return }
        lastSent = ProcessInfo.processInfo.systemUptime; brightnessTouched = true; model.haptic(continuous: !force)
        if let message = try? selection.brightness(Int(brightness)) { model.send(message) }
    }
}

private struct NativeFixtureDetailsView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @Environment(\.dismiss) private var dismiss
    let selection: EosChannelSelection
    @State private var page = 0
    @State private var timedOut = false
    @State private var requestToken = UUID()
    private var channels: [Int] { Array(selection.channels.dropFirst(page*12).prefix(12)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("Channels " + selection.expression).font(.subheadline); Spacer(); Button("Refresh") { model.haptic(); load() }.disabled(!model.ready) }
                ForEach(channels, id: \.self) { channel in
                    let rows = model.fixtures.values.filter { $0.channel == channel }.sorted { $0.part < $1.part }
                    if rows.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Channel \(channel)").font(.headline)
                            Text(!model.ready ? "Connect to retrieve fixture details" : timedOut ? "No patch reply. This channel may be unpatched, or OSC feedback may be unavailable." : "Requesting fixture details…").font(.caption).foregroundStyle(.secondary)
                        }.deskCard()
                    } else {
                        ForEach(rows) { fixture in
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Channel \(fixture.channel) · Part \(fixture.part)").font(.headline)
                                if !fixture.label.isEmpty { Text(fixture.label).font(.title3) }
                                field("Fixture", fixture.model.replacingOccurrences(of: "_", with: " "))
                                field("Manufacturer", fixture.manufacturer.replacingOccurrences(of: "_", with: " "))
                                field("DMX address", fixture.patchAddress)
                                if fixture.endingAddress == nil { Text("End address not reported by console").font(.caption).foregroundStyle(.secondary) }
                                if let address = fixture.address, address > 0 { field("Absolute address", String(address)) }
                                if let level = fixture.level { field("Reported intensity", "\(Int(level))%") }
                                if !fixture.gel.isEmpty { field("Gel", fixture.gel) }
                                if let count = fixture.partCount { field("Channel parts", String(count)) }
                                ForEach(Array(fixture.textFields.enumerated()), id: \.offset) { index, text in
                                    if !text.isEmpty { field("Text \(index + 1)", text) }
                                }
                                if !fixture.notes.isEmpty { Text(fixture.notes).font(.subheadline).foregroundStyle(.secondary) }
                                NavigationLink("Edit label & notes") { NativePatchNotesView(fixture: fixture) }
                            }.deskCard()
                        }
                    }
                }
                ForEach(channels, id: \.self) { channel in
                    NativeParameterInspector(channel: channel)
                }
                if selection.channels.count > 12 {
                    HStack { Button("Previous") { page -= 1; load() }.disabled(page == 0); Spacer(); Text("Page \(page+1)").font(.caption); Spacer(); Button("Next") { page += 1; load() }.disabled((page+1)*12 >= selection.channels.count) }
                }
            }.padding()
        }.navigationTitle("Fixture details").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear { load() }.onChange(of: model.ready) { ready in if ready { load() } }
    }
    private func field(_ label: String, _ value: String) -> some View { HStack(alignment: .top) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value.isEmpty ? "Not received" : value).multilineTextAlignment(.trailing) }.font(.subheadline) }
    private func load() {
        let token = UUID(); requestToken = token; timedOut = false
        model.requestFixtureDetails(channels)
        DispatchQueue.main.asyncAfter(deadline: .now()+6) { if requestToken == token { timedOut = true } }
    }
}

private struct NativeConsoleView: View {
    @EnvironmentObject var model: NativeRemoteModel
    var body: some View {
        GeometryReader { geometry in
            let height = min(76.0, max(48.0, (geometry.size.height - 164) / 7.0))
            if geometry.size.width > geometry.size.height && geometry.size.width >= 600 {
                HStack(alignment:.top,spacing:16) {
                    ScrollView {
                        VStack(spacing:10) {
                            NativeSoftkeysView()
                            grid([.init("Record","record",.red),.init("Cue","cue",.blue),.init("Sub","sub",.green),.init("Chan","chan",.orange)],count:4,height:44)
                            grid([.init("Rem Dim","rem_dim"),.init("Go to Cue","go_to_cue"),.init("Group","group"),.init("Out","out")],count:4,height:44)
                            grid([.init("/","\\"),.init("+","+"),.init("−","-"),.init("Thru","thru")],count:4,height:44)
                            HStack(spacing:10) {
                                NavigationLink(value:RemoteTool.movement) { toolLabel("Movement","move.3d") }
                                NavigationLink(value:RemoteTool.color) { toolLabel("Color","paintpalette") }
                            }.buttonStyle(DeskButtonStyle())
                            DisclosureGroup("More keys") { grid(selectionKeys + [.init("Highlight","highlight"),.init("Home","home"),.init("Delay","delay"),.init("Time","time"),.init("Level","level")],count:4,height:44) }.font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.bottom,16)
                    }.frame(width:max(280,geometry.size.width*0.46))
                    ScrollView {
                        grid([.init("7","7"),.init("8","8"),.init("9","9"),.init("Full","full"),
                              .init("4","4"),.init("5","5"),.init("6","6"),.init("Sneak","sneak"),
                              .init("1","1"),.init("2","2"),.init("3","3"),.init("At","@"),
                              .init("Clear","clear_cmd"),.init("0","0"),.init(".","."),.init("Enter","enter",DeskPalette.accent)],count:4,height:max(44,min(62,(geometry.size.height-40)/4)))
                            .padding(.bottom,16)
                    }
                }.padding(.horizontal,16).padding(.top,8)
            } else {
            ScrollView {
                VStack(spacing: 16) {
                    NativeSoftkeysView()
                    grid([.init("Record", "record", .red), .init("Cue", "cue", .blue), .init("Sub", "sub", .green), .init("Chan", "chan", .orange)], count: 4, height: height)
                    VStack(spacing: 8) {
                        grid([.init("Rem Dim", "rem_dim"), .init("Go to Cue", "go_to_cue"), .init("Group", "group"), .init("Out", "out")], count: 4, height: height)
                        grid([.init("/", "\\"), .init("+", "+"), .init("−", "-"), .init("Thru", "thru")], count: 4, height: height)
                        grid([.init("7", "7"), .init("8", "8"), .init("9", "9"), .init("Full", "full")], count: 4, height: height)
                        grid([.init("4", "4"), .init("5", "5"), .init("6", "6"), .init("Sneak", "sneak")], count: 4, height: height)
                        grid([.init("1", "1"), .init("2", "2"), .init("3", "3"), .init("At", "@")], count: 4, height: height)
                        grid([.init("Clear", "clear_cmd"), .init("0", "0"), .init(".", "."), .init("Enter", "enter", DeskPalette.accent)], count: 4, height: height)
                    }
                    HStack(spacing: 10) {
                        NavigationLink(value: RemoteTool.movement) {
                            toolLabel("Movement", "move.3d")
                        }
                        NavigationLink(value: RemoteTool.color) {
                            toolLabel("Color", "paintpalette")
                        }
                    }.font(.subheadline).buttonStyle(DeskButtonStyle())
                    DisclosureGroup("More keys") {
                        grid(selectionKeys + [.init("Highlight", "highlight"), .init("Delay", "delay"), .init("Time", "time"), .init("Home", "home"), .init("Level", "level")], count: 3, height: 44)
                    }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 36)
                }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 24)
            }
            }
        }
    }
    private func toolLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium)).foregroundStyle(DeskPalette.accent)
            Text(title).font(.system(size: 14, weight: .medium))
        }.frame(maxWidth: .infinity, minHeight: 48)
    }
    private func grid(_ keys: [ConsoleKey], count: Int, height: Double) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: count), spacing: 8) {
            ForEach(keys) { key in deskKey(key, height: height) }
        }
    }
    private func deskKey(_ key: ConsoleKey, height: Double) -> some View {
        let isNumber = Int(key.title) != nil
        let isPrimary = ["Record", "Cue", "Sub", "Chan", "Enter"].contains(key.title)
        return Button { model.key(key.address) } label: {
            Text(key.title).font(.system(size: isNumber ? 28 : isPrimary ? 16 : 14, weight: isNumber ? .regular : .medium, design: .default)).minimumScaleFactor(0.7).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: height).padding(.horizontal, 2)
        }.buttonStyle(DeskButtonStyle(accent: key.color, prominent: key.address == "enter")).accessibilityLabel(key.title)
    }
}

private struct NativeFadersView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var level = 0.0
    @State private var lastSent = -Double.infinity
    @State private var levelSession: UUID?
    @State private var bank = 0
    @State private var individualSessions: [Int: UUID] = [:]
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Fader bank", selection: $bank) {
                    ForEach(0..<4) { index in Text("\(index*10+1)–\(index*10+10)").tag(index) }
                }.pickerStyle(.segmented)
                NavigationLink { NativeShowBrowser(family: "sub", title: "Submasters") } label: { Label("Submaster details", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading).deskCard() }
                grid
                DisclosureGroup("Adjust selected faders") { controls }
            }.padding(16)
        }
            .onAppear { if model.ready { model.send("/eos/fader/1/config/1/40") } }
            .onChange(of: model.ready) { ready in if ready { model.send("/eos/fader/1/config/1/40") } }
    }
    private var grid: some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:300),spacing:12)],spacing:12) {
            ForEach((bank*10+1)...(bank*10+10), id: \.self) { n in
                VStack(spacing: 3) {
                    HStack(spacing: 12) {
                        Button {
                            model.haptic()
                            if model.selection.contains(n) { model.selection.remove(n) } else { model.selection.insert(n) }
                        } label: {
                            Text("\(n)").font(.system(size: 16, weight: .medium)).frame(width: 32, height: 32)
                                .background(model.selection.contains(n) ? DeskPalette.accent.opacity(0.3) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityLabel("Select fader \(n)").accessibilityAddTraits(model.selection.contains(n) ? .isSelected : [])
                        Text(model.text("/eos/out/fader/1/\(n)/name").isEmpty ? "Fader \(n)" : model.text("/eos/out/fader/1/\(n)/name")).font(.body).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(readout(n)).font(.system(size: 15, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                        Button { bump([n]) } label: { Label("Bump", systemImage: "bolt.fill").font(.caption).padding(.horizontal, 12).frame(minHeight: 32) }
                            .buttonStyle(DeskButtonStyle()).disabled(!model.ready)
                    }
                    Slider(value: Binding(get: { faderValue(n) * 100 }, set: { value in setFader(n, value / 100) }), in: 0...100, step: 1, onEditingChanged: { editing in
                        if editing { individualSessions[n] = model.session }
                        else { individualSessions.removeValue(forKey: n) }
                    })
                        .accessibilityLabel("Fader \(n) level").disabled(!model.ready)
                }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8).deskPanel()
            }
        }
    }
    private func faderValue(_ number: Int) -> Double {
        let value = model.feedback["/eos/out/fader/1/\(number)"]?.first ?? model.feedback["/eos/fader/1/\(number)"]?.first
        return min(max((value as? NSNumber)?.doubleValue ?? 0, 0), 1)
    }
    private func setFader(_ number: Int, _ value: Double) {
        guard model.ready, individualSessions[number] == nil || individualSessions[number] == model.session, let message = try? EosCommands.faderLevel(number, value) else { return }
        model.send(message); model.haptic(continuous: true)
    }
    private func readout(_ n: Int) -> String {
        let value = model.feedback["/eos/out/fader/1/\(n)"]?.first ?? model.feedback["/eos/fader/1/\(n)"]?.first
        return (value as? NSNumber).map { "\(Int($0.doubleValue * 100))%" } ?? "—"
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("\(model.selection.count) selected", systemImage: "slider.vertical.3").font(.subheadline.weight(.semibold)); Spacer(); Button("All") { model.haptic(); model.selection = Set(1...40) }; Button("Clear") { model.haptic(); model.selection = [] } }
            HStack(alignment: .firstTextBaseline) { Text("Level").font(.headline); Spacer(); Text("\(Int(level))%").font(.system(size: 32, weight: .semibold, design: .default).monospacedDigit()) }
            Slider(value: Binding(get: { level }, set: { value in
                level = value
                if (ProcessInfo.processInfo.systemUptime - lastSent) >= 1.0/30 { model.haptic(continuous: true); apply() }
            }), in: 0...100, step: 1, onEditingChanged: { editing in
                if editing { levelSession = model.session }
                else { apply(); levelSession = nil; model.haptic() }
            }).accessibilityLabel("Selected faders level").disabled(model.selection.isEmpty || !model.ready)
            HStack { ForEach([0,25,50,75,100], id: \.self) { value in Button(value == 0 ? "Out" : value == 100 ? "Full" : "\(value)") { model.haptic(); level = Double(value); apply() } } }.buttonStyle(.bordered).disabled(model.selection.isEmpty || !model.ready)
            Button { bump(model.selection.sorted()) } label: { Label("Bump selected", systemImage: "bolt.fill").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 46) }.buttonStyle(DeskButtonStyle(accent: .mint)).disabled(model.selection.isEmpty || !model.ready)
            Text("Select faders, then adjust the level.").font(.caption).foregroundStyle(.secondary)
        }.deskCard()
    }
    private func bump(_ numbers: [Int]) {
        guard model.ready else { return }
        model.haptic()
        model.sendBatch(numbers.compactMap { try? EosCommands.faderBump($0) })
    }
    private func apply() {
        guard model.ready, !model.selection.isEmpty, levelSession == nil || levelSession == model.session else { return }
        lastSent = ProcessInfo.processInfo.systemUptime
        model.sendBatch(model.selection.sorted().compactMap { try? EosCommands.faderLevel($0, level/100) })
    }

}

private struct NativePlaybackView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var cue = ""
    var body: some View {
        GeometryReader { geometry in
            let layout:AnyLayout = geometry.size.width > 650 ? AnyLayout(HStackLayout(alignment:.top,spacing:16)) : AnyLayout(VStackLayout(spacing:16))
        ScrollView {
            layout {
            VStack(spacing:16) {
                NavigationLink { NativeCueListsView() } label: {
                    HStack { Label("Browse all cues", systemImage: "list.bullet"); Spacer(); Image(systemName: "chevron.right") }.deskCard()
                }.buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("NOW").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                        Spacer()
                        Text(model.isCueFading ? "Fading" : "Ready").font(.caption).foregroundStyle(DeskPalette.accent)
                    }
                    Text(model.activeCueText.isEmpty ? "No cue feedback yet" : model.activeCueText)
                        .font(.system(size: 26, weight: .semibold)).tracking(-0.4).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                    ProgressView(value: model.activeCuePercent).tint(DeskPalette.accent)
                    HStack {
                        Text("NEXT").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                        Text(model.pendingCueText).font(.subheadline).lineLimit(2)
                        Spacer()
                    }
                }.deskCard()
            }.frame(maxWidth:.infinity)
            VStack(spacing:16) {
                HStack(spacing: 12) {
                    Button { model.key("stop") } label: { Label("Stop / Back", systemImage: "pause").frame(maxWidth: .infinity, minHeight: 64) }
                        .buttonStyle(DeskButtonStyle(accent: .red))
                    Button { model.key("go_0") } label: { Label("Go", systemImage: "play.fill").frame(maxWidth: .infinity, minHeight: 64) }
                        .buttonStyle(DeskButtonStyle(accent: .green, prominent: true))
                }.font(.headline).disabled(!model.ready)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Go to cue").font(.headline)
                    HStack {
                        TextField("Cue number", text: $cue).keyboardType(.decimalPad)
                            .padding(12).background(DeskPalette.field, in: RoundedRectangle(cornerRadius: 12))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(DeskPalette.rule, lineWidth: 0.75) }
                        Button("Go") { model.goToCue(cue); cue = "" }.buttonStyle(.bordered)
                            .disabled((try? EosCommands.goToCue(cue)) == nil || !model.ready)
                    }
                    Button("Go to cue 0 · Out") { model.goToCue("0") }.font(.subheadline).disabled(!model.ready)
                }.deskCard()
                HStack(spacing:12) {
                    NavigationLink { NativeCueMonitorView() } label: { Label("Cue Monitor",systemImage:"eye").frame(maxWidth:.infinity,minHeight:48) }
                    NavigationLink { NativeRehearsalView() } label: { Label("Rehearsal",systemImage:"clock.arrow.circlepath").frame(maxWidth:.infinity,minHeight:48) }
                }.buttonStyle(.bordered)
                if !model.cueHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        DisclosureGroup("Recent cues") {
                            ForEach(model.cueHistory.prefix(20)) { item in
                                HStack {
                                    Text(item.cue).monospacedDigit().frame(width: 46, alignment: .leading)
                                    Text(item.label).lineLimit(2)
                                    Spacer()
                                    Text(item.time).font(.caption2).foregroundStyle(.secondary)
                                }.font(.subheadline).padding(.vertical, 8)
                                Divider()
                            }
                        }
                    }.deskCard()
                }
            }.frame(maxWidth:.infinity)
            }.padding(16)
        }
        }
    }
}

private struct NativeConnectionView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @EnvironmentObject var wifi: WiFiStatus
    @EnvironmentObject var discovery: ConsoleDiscovery
    @AppStorage("element.native.keepAwake") private var keepAwake = false
    @AppStorage("element.native.haptics") private var haptics = true
    @AppStorage("element.nightVision") private var nightVision = false
    @State private var profiles: [ConsoleProfile] = []
    @State private var editing: ConsoleProfile?

    var body: some View {
        Form {
            Section {
                if profiles.isEmpty { Text("Add your console to get started.").foregroundStyle(.secondary) }
                ForEach(profiles) { profile in
                    HStack(spacing: 12) {
                        Button { model.useConsole(profile); model.haptic() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name).foregroundStyle(.primary)
                                Text(profile.host + " · " + profile.transport.uppercased()).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityHint("Use this console")
                        Button { editing = profile } label: { Image(systemName: "pencil").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel("Edit " + profile.name)
                    }
                }.onDelete { offsets in profiles.remove(atOffsets: offsets); ConsoleProfileStore.save(profiles) }
                Button { editing = ConsoleProfile(name: "Element", host: "") } label: { Label("Add console", systemImage: "plus") }
            } header: { Text("Saved consoles") } footer: { Text("Tap a saved console to use it. Swipe to delete.") }
            Section {
                ForEach(discovery.discoveredConsoles) { console in
                    Button {
                        editing = ConsoleProfile(name: console.name, host: console.host, transport: console.transport, consolePort: console.port)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(console.name)
                            Text("\(console.host):\(console.port)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack { Text(discovery.statusMessage).font(.caption).foregroundStyle(.secondary); if discovery.isSearching { ProgressView() } }
                Button(discovery.isSearching ? "Stop search" : "Search nearby") {
                    if discovery.isSearching { discovery.stop(); discovery.statusMessage = "Search stopped" }
                    else { discovery.start() }
                }.disabled(model.demoMode)
            } header: { Text("Nearby consoles") } footer: { Text("Checks nearby Wi-Fi addresses on TCP 3032 and advertised OSC services. Other subnets or ports may need Add console.") }
            Section {
                Toggle("Separate app user", isOn: Binding(get:{ model.independentUser },set:{ model.independentUser = $0; model.applyUserMode() }))
                if let user = model.oscUser { LabeledContent("OSC user",value:String(user)) }
                NavigationLink("Console health & diagnostics") { NativeConsoleHealthView() }
            } header: { Text("Console user") } footer: { Text("Use a separate Eos user so channel selection and command entry stay independent from the board operator. Live output is still shared. Changing this clears the app’s selection.") }
            Section("Display & controls") {
                Toggle("Night vision", isOn: $nightVision)
                Toggle("Haptics", isOn: $haptics)
                Toggle("Keep screen awake", isOn: $keepAwake).onChange(of: keepAwake) { model.connection.setKeepAwake($0) }
            }
            Section {
                DisclosureGroup("Connection details") {
                    LabeledContent("Network", value: model.networkStatus)
                    LabeledContent("Status", value: model.phase)
                    LabeledContent("Eos", value: model.softwareVersion.isEmpty ? "Unknown" : model.softwareVersion)
                    if let latency = model.latency { LabeledContent("Round trip", value: "\(latency) ms") }
                    if !model.diagnostic.isEmpty { Text(model.diagnostic).font(.caption).foregroundStyle(.orange) }
                    Button("Check connection") { model.connection.testConnection() }.disabled(model.demoMode)
                    Button("Disconnect", role: .destructive) { model.connection.disconnect() }.disabled(model.demoMode || !model.ready)
                    Button("Open app permissions") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
                DisclosureGroup("Console setup") {
                    Text("Join the console’s network. Enable OSC RX and OSC TX on the console. Start with TCP port 3032 and Packet Length framing.").font(.subheadline)
                }
            }
            Section("About") {
                Link("Privacy policy", destination: URL(string: "https://elementremote.xyz/privacy")!)
                Link("Support", destination: URL(string: "https://elementremote.xyz/support")!)
                NavigationLink("Privacy & licenses") { NativeLegalView() }
            }
            Section {
                Toggle("Test Mode", isOn: Binding(get: { model.demoMode }, set: { discovery.stop(); model.toggleDemoMode($0); model.haptic() })).tint(DeskPalette.accent)
            } footer: { Text("Practice with the sample show. No commands reach a console.") }
        }.scrollContentBackground(.hidden).background(DeskPalette.background).navigationTitle("Settings")
        .onAppear { profiles = ConsoleProfileStore.load(); model.connection.setKeepAwake(keepAwake) }
        .onDisappear { discovery.stop() }
        .sheet(item: $editing) { profile in
            NativeConsoleEditor(profile: profile) { updated in
                if let index = profiles.firstIndex(where: { $0.id == updated.id }) { profiles[index] = updated }
                else { profiles.append(updated) }
                ConsoleProfileStore.save(profiles)
                model.useConsole(updated)
            }
        }
    }
}

private struct NativeConsoleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: ConsoleProfile
    let saved: (ConsoleProfile) -> Void
    @State private var port = ""
    @State private var receive = ""
    @State private var validation = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Console") {
                    TextField("Name", text: $profile.name)
                    TextField("IP address or hostname", text: $profile.host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                }
                Section("Connection") {
                    Picker("Protocol", selection: $profile.transport) {
                        Text("TCP · Packet Length").tag("tcp")
                        Text("TCP · SLIP").tag("tcp-slip")
                        Text("UDP").tag("udp")
                        Text("Third Party TCP · Eos 3.1+").tag("third-party")
                    }.onChange(of: profile.transport) { value in port = value == "udp" ? "8000" : value == "third-party" ? "3037" : "3032" }
                    TextField("Console port", text: $port).keyboardType(.numberPad)
                    if profile.transport == "udp" { TextField("Receive port", text: $receive).keyboardType(.numberPad) }
                }
                if !validation.isEmpty { Text(validation).foregroundStyle(.red) }
            }.navigationTitle("Console details").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save & use") { save() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
        }.onAppear { port = String(profile.consolePort); receive = String(profile.receivePort) }
    }
    private func save() {
        do {
            let config = try NativeConsoleSettings.parse(["displayName": profile.name, "consoleHost": profile.host, "transport": profile.transport, "consolePort": port, "receivePort": receive])
            guard !config.consoleHost.isEmpty else { validation = "Enter the console IP address."; return }
            guard !config.displayName.trimmingCharacters(in: .whitespaces).isEmpty else { validation = "Give the console a name."; return }
            profile.name = config.displayName; profile.host = config.consoleHost
            profile.consolePort = config.consolePort; profile.receivePort = config.receivePort
            saved(profile); dismiss()
        } catch { validation = error.localizedDescription }
    }
}

private enum AppTool: String, CaseIterable, Identifiable {
    case quick, movement, color, emitters, beam, spread, effects, stage, presets, monitor, timeline, qlab, workspaces, patch, compare, qr, health, magic
    var id: String { rawValue }
    private var info: (String,String,String,String,String) {
        switch self {
        case .magic: return ("Show & playback","Magic Sheets","Import and view a console-exported sheet image","square.grid.3x3","layout stage plot viewer")
        case .quick: return ("Fixtures","Quick Control","Levels, park and common channel actions","bolt.fill","intensity brightness unpark")
        case .movement: return ("Fixtures","Movement","Pan, tilt and fine adjustment","move.3d","position focus wheels")
        case .color: return ("Fixtures","Color","Color picker and named palettes","paintpalette","hue saturation gel")
        case .emitters: return ("Fixtures","LED Color Mixing","Individual red, lime, amber and other emitters","slider.horizontal.3","rgb led emitter")
        case .beam: return ("Fixtures","Beam & Gobos","Zoom, edge, iris and supported optics","light.beacon.max","prism shutter strobe frost optics")
        case .patch: return ("Fixtures","Patch & Fixture Info","Addresses, fixture types, labels and notes","point.3.connected.trianglepath.dotted","dmx universe edit notes")
        case .compare: return ("Fixtures","Compare Fixtures","Read-only differences between two channels","rectangle.split.2x1","parameters differences ranges")
        case .qr: return ("Fixtures","Fixture QR Labels","Scan a label or create one to share","qrcode.viewfinder","camera scan inspect")
        case .spread: return ("Looks & movement","Spread Fixtures","Fan pan, tilt or intensity across channels","arrow.left.and.right","fan spread")
        case .effects: return ("Looks & movement","Effects","Browse effects and adjust mapped controls","waveform.path","circle sweep chase rate size")
        case .stage: return ("Looks & movement","Stage Map Focus","Advanced focus with calibrated Augment3d","scope","xyz position meters followspot")
        case .presets: return ("Looks & movement","Presets","Browse and apply stored looks","square.stack","look recall preset")
        case .monitor: return ("Show & playback","Cue Monitor","Large current and next cue display","eye","read only stage manager")
        case .timeline: return ("Show & playback","Rehearsal Timeline","Record cue events and add your notes","clock.arrow.circlepath","history log export")
        case .qlab: return ("Show & playback","QLab Sound & Video","Start QLab cues or link lighting and sound","play.rectangle","show control mac audio")
        case .workspaces: return ("Show & playback","Console Layouts","Recall display snapshots on the board","rectangle.3.group","snapshot workspace screen")
        case .health: return ("Diagnostics","Console Health","Connection, processor reports and users","heart.text.square","network latency errors diagnostics")
        }
    }
    var group: String { info.0 }
    var title: String { info.1 }
    var subtitle: String { info.2 }
    var symbol: String { info.3 }
    func matches(_ query:String) -> Bool { query.isEmpty || (title + " " + subtitle + " " + info.4).localizedCaseInsensitiveContains(query) }
}

private struct NativeMoreView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var search = ""
    @AppStorage("element.tools.favorites") private var favorites = "quick,movement,color,patch"
    @AppStorage("element.tools.recent") private var recent = ""
    private let groups = ["Fixtures","Looks & movement","Show & playback","Diagnostics"]
    private var query: String { search.trimmingCharacters(in:.whitespacesAndNewlines) }
    private var pinned: [AppTool] { favorites.split(separator:",").compactMap { AppTool(rawValue:String($0)) } }
    private var matching: [AppTool] { AppTool.allCases.filter { $0.matches(query) } }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack(spacing:10) {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a tool, e.g. park or gobos",text:$search).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Search tools")
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear search") }
                }.padding(13).background(DeskPalette.field,in:RoundedRectangle(cornerRadius:13))
                if query.isEmpty {
                    if !model.selectedChannels.isEmpty {
                        HStack(spacing:12) {
                            Image(systemName:"lightbulb.fill").foregroundStyle(DeskPalette.accent)
                            VStack(alignment:.leading,spacing:4) {
                                Text("\(model.selectedChannels.count) channel\(model.selectedChannels.count == 1 ? "" : "s") selected").font(.subheadline.weight(.semibold))
                                Text(model.independentUser ? "Your app selection" : "Following the console user").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.deskCard()
                    }
                    if !pinned.isEmpty { toolSection("Favorites",tools:pinned) }
                    let recentTools = recent.split(separator:",").compactMap { AppTool(rawValue:String($0)) }.filter { !pinned.contains($0) }.prefix(3)
                    if !recentTools.isEmpty {
                        VStack(alignment:.leading,spacing:8) {
                            sectionLabel("Recently used")
                            ScrollView(.horizontal,showsIndicators:false) {
                                HStack { ForEach(Array(recentTools)) { tool in NavigationLink { destination(tool) } label: { Label(tool.title,systemImage:tool.symbol).font(.caption).padding(.horizontal,12).padding(.vertical,10).background(DeskPalette.surface,in:Capsule()) }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { remember(tool) }) } }
                            }
                        }
                    }
                }
                if !query.isEmpty && matching.isEmpty { ContentUnavailableViewCompat(title:"No matching tools",text:"Try a task such as color, notes, effects or network.",symbol:"magnifyingglass") }
                ForEach(groups,id:\.self) { group in
                    let tools = matching.filter { $0.group == group && (!query.isEmpty || !pinned.contains($0)) }
                    if !tools.isEmpty { toolSection(group,tools:tools) }
                }
                if query.isEmpty { Text("Tap a star to keep a tool in Favorites. Independent app selection is in Settings.").font(.caption).foregroundStyle(.secondary).padding(.horizontal,6) }
            }.padding(.horizontal,18).padding(.top,6).padding(.bottom,24)
        }.scrollDismissesKeyboard(.interactively)
    }
    private func sectionLabel(_ title:String)->some View { Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary).padding(.leading,6) }
    private func toolSection(_ title:String,tools:[AppTool])->some View {
        VStack(alignment:.leading,spacing:8) {
            sectionLabel(title)
            VStack(spacing:0) {
                ForEach(tools) { tool in
                    HStack(spacing:4) {
                        NavigationLink { destination(tool) } label: {
                            HStack(spacing:13) {
                                Image(systemName:tool.symbol).font(.system(size:20)).foregroundStyle(DeskPalette.accent).frame(width:28)
                                VStack(alignment:.leading,spacing:4) { Text(tool.title).font(.system(size:16,weight:.medium)).foregroundStyle(.primary); Text(tool.subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                                Spacer(minLength:4)
                                Image(systemName:"chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            }.padding(.vertical,14).contentShape(Rectangle())
                        }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { remember(tool) })
                        Button { toggle(tool) } label: { Image(systemName:pinned.contains(tool) ? "star.fill" : "star").font(.system(size:15)).foregroundStyle(pinned.contains(tool) ? DeskPalette.accent : Color.secondary).frame(width:44,height:48) }.buttonStyle(.plain).accessibilityLabel((pinned.contains(tool) ? "Remove " : "Favorite ") + tool.title).accessibilityHint("Changes your Favorites list")
                    }
                    if tool != tools.last { Divider().padding(.leading,41) }
                }
            }.padding(.leading,14).padding(.trailing,4).deskPanel()
        }
    }
    private func remember(_ tool:AppTool) { model.haptic(); recent = ([tool.rawValue] + recent.split(separator:",").map(String.init).filter { $0 != tool.rawValue }).prefix(5).joined(separator:",") }
    private func toggle(_ tool:AppTool) { model.haptic(); var items = pinned; if items.contains(tool) { items.removeAll { $0 == tool } } else { items.append(tool) }; favorites = items.map(\.rawValue).joined(separator:",") }
    @ViewBuilder private func destination(_ tool:AppTool)->some View {
        switch tool {
        case .magic: NativeMagicSheetView()
        case .quick: NativeQuickControlView().navigationTitle("Quick Control")
        case .movement: NativeCommandTool { NativeWheelsView() }
        case .color: NativeCommandTool { NativeColorView() }
        case .emitters: NativeEmitterView()
        case .beam: NativeCommandTool { NativeWheelsView(beamOnly:true) }
        case .spread: NativeCreativeView(initialTab:0)
        case .effects: NativeCreativeView(initialTab:1)
        case .stage: NativeStageFocusView()
        case .presets: NativeShowBrowser(family:"preset",title:"Presets")
        case .monitor: NativeCueMonitorView()
        case .timeline: NativeRehearsalView()
        case .qlab: NativeShowControlView()
        case .workspaces: NativeShowBrowser(family:"snap",title:"Console layouts")
        case .patch: NativePatchView()
        case .compare: NativeFixtureCompareView()
        case .qr: NativeFixtureQRView()
        case .health: NativeConsoleHealthView()
        }
    }
}

private struct NativeCommandTool<Content:View>: View {
    @EnvironmentObject var model:NativeRemoteModel
    private let content:Content
    init(@ViewBuilder content:()->Content) { self.content = content() }
    var body: some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:8) {
                HStack {
                    Text(model.selectedChannels.isEmpty ? "Choose channels to begin" : "\(model.selectedChannels.count) selected · " + (model.independentUser ? "app user" : "console user")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    NavigationLink(model.selectedChannels.isEmpty ? "Select" : "Change") { NativeQuickControlView().navigationTitle("Quick Control") }.font(.caption.weight(.semibold)).accessibilityLabel("Change controlled channels")
                }
                NativeCommandReadout()
            }.padding(12).background(DeskPalette.surface,in:RoundedRectangle(cornerRadius:14)).overlay { RoundedRectangle(cornerRadius:14).strokeBorder(model.demoMode ? DeskPalette.accent : DeskPalette.rule) }.padding(.horizontal,16).padding(.bottom,6)
            content
        }
    }
}

private enum WheelCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case position = "Position"
    case beam = "Beam"
    case optics = "Gobos & optics"
    var id: String { rawValue }
}

private struct NativeWheelsView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var fine = false
    @State private var category: WheelCategory = .all
    private let beamOnly: Bool

    init(beamOnly: Bool = false) {
        self.beamOnly = beamOnly
        _category = State(initialValue: beamOnly ? .beam : .all)
    }

    private var parameters: [EosFixtureParameter] { model.fixtureParameters[model.selectedChannels.first ?? 0] ?? [] }
    private var paramsForCategory: [String] {
        let names = parameters.map(\.oscName)
        let wheelNames = model.feedback.filter { $0.key.hasPrefix("/eos/out/active/wheel/") }.values.compactMap { ($0.first as? String)?.lowercased().replacingOccurrences(of: " ", with: "_") }
        let available = names.isEmpty ? wheelNames + model.feedback.keys.filter { $0.hasPrefix("/eos/out/param/") }.compactMap { $0.split(separator: "/").last.map(String.init) } : names
        return Array(Set(available)).sorted().filter { name in
            switch category {
            case .all: return true
            case .position: return name == "pan" || name == "tilt"
            case .beam: return !["pan", "tilt", "intens", "intensity"].contains(name) && !["red", "green", "blue", "cyan", "magenta", "yellow", "hue", "sat"].contains(name)
            case .optics: return ["gobo", "prism", "shutter", "strobe", "frame", "blade", "thrust", "frost", "diffus"].contains(where: name.contains)
            }
        }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Category", selection: $category) {
                    ForEach(beamOnly ? [.beam, .optics] : WheelCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .pickerStyle(.segmented)
                
                HStack {
                    Text("Wheels").font(.headline)
                    Spacer()
                    Picker("Resolution", selection: $fine) {
                        Text("Coarse").tag(false)
                        Text("Fine").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
                
                if let channel = model.selectedChannels.first {
                    HStack { Text("Channel \(channel) · Live").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Refresh") { model.requestParameters(channel) } }
                    if model.selectedChannels.count > 1 { Text("Values show channel \(channel). Wheels adjust the console selection.").font(.caption).foregroundStyle(.secondary) }
                }
                if paramsForCategory.isEmpty { Text("Choose a fixture in Quick Control to see its supported controls.").font(.subheadline).foregroundStyle(.secondary).deskCard() }
                ForEach(paramsForCategory, id: \.self) { param in
                    DeskWheel(param: param, fine: fine)
                }
                NavigationLink { NativeShowBrowser(family: beamOnly ? "bp" : "fp", title: beamOnly ? "Beam palettes" : "Focus palettes") } label: { Label(beamOnly ? "Beam palettes" : "Focus palettes", systemImage: "square.grid.2x2").frame(maxWidth: .infinity, alignment: .leading).deskCard() }
                
                if category == .all || category == .position {
                    HStack {
                        Text("Focus").font(.headline)
                        Spacer()
                        Text("Pan / tilt").font(.caption).foregroundStyle(.secondary)
                    }
                    DeskFocusPad(fine: fine)
                }
                
                HStack {
                    ForEach([ConsoleKey("Home", "home"), ConsoleKey("Highlight", "highlight"), ConsoleKey("Sneak", "sneak")]) { key in
                        Button { model.key(key.address) } label: {
                            Text(key.title).font(.subheadline).frame(maxWidth: .infinity, minHeight: 48)
                        }.buttonStyle(DeskButtonStyle())
                    }
                }
                if !beamOnly {
                    DisclosureGroup("More movement tools") {
                        VStack(alignment:.leading,spacing:14) {
                            NavigationLink("Spread selected fixtures") { NativeCreativeView(initialTab:0) }
                            NavigationLink("Stage map focus · advanced") { NativeStageFocusView() }
                        }.font(.subheadline).padding(.top,12)
                    }.deskCard()
                }
            }.padding()
        }
        .navigationTitle(beamOnly ? "Beam & Gobos" : "Movement")
        .onAppear { if let channel = model.selectedChannels.first { model.requestParameters(channel) } }
        .onChange(of: model.selectedChannels) { channels in if let channel = channels.first { model.requestParameters(channel) } }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in if model.ready, let channel = model.selectedChannels.first { model.requestParameters(channel) } }
        .onChange(of: fine) { _ in model.haptic() }
        .onChange(of: category) { _ in model.haptic() }
    }
}

private struct DeskWheel: View {
    @EnvironmentObject var model: NativeRemoteModel
    let param: String
    let fine: Bool
    @State private var previous = 0.0
    @State private var residual = 0.0
    @State private var lastSent = -Double.infinity
    @State private var gestureSession: UUID?
    
    private var capability: EosFixtureParameter? { model.fixtureParameters[model.selectedChannels.first ?? 0]?.first { $0.oscName == param } }
    private var readout: String { model.feedback["/eos/out/param/" + param]?.first.map { String(describing: $0) } ?? capability.map { String(format: "%.2f", $0.level) } ?? "Waiting for feedback" }
    private var title: String {
        switch param {
        case "intens": return "Intensity"
        case "pan": return "Pan"
        case "tilt": return "Tilt"
        case "edge": return "Edge"
        case "zoom": return "Zoom"
        case "iris": return "Iris"
        case "focus": return "Focus"
        case "color_temp": return "Color Temp"
        case "tint": return "Tint"
        case "diffusn": return "Diffusion"
        case "gobo_rot": return "Gobo Rot"
        default: return param.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Min") { tap("/eos/param/\(param)/min") }
                Spacer()
                VStack(spacing: 2) { Text(title).font(.subheadline.weight(.medium)); Text(readout).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Spacer()
                Button("Max") { tap("/eos/param/\(param)/max") }
            }.font(.caption).tint(Color.gray)
            HStack {
                if let capability { Text(String(format: "Range %.2f to %.2f", capability.minimum, capability.maximum)).font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                Button("Home") { tap("/eos/param/\(param)/home") }.font(.caption)
            }
            HStack(spacing: 0) {
                Button { adjust(-1) } label: { Image(systemName: "chevron.left").frame(width: 38, height: 52) }.accessibilityLabel("Decrease " + title)
                GeometryReader { geometry in
                    ZStack {
                        DeskPalette.field
                        Path { path in
                            for x in stride(from: 0.0, through: geometry.size.width, by: 16) { path.move(to: CGPoint(x: x, y: 10)); path.addLine(to: CGPoint(x: x, y: 42)) }
                        }.stroke(Color.white.opacity(0.13), lineWidth: 1)
                        Rectangle().fill(Color.white.opacity(0.5)).frame(width: 2, height: 32)
                    }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if gestureSession == nil { gestureSession = model.session }
                            guard gestureSession == model.session else { return }
                            residual += value.translation.width - previous; previous = value.translation.width; flush()
                        }.onEnded { _ in if gestureSession == model.session { flush(force: true) }; gestureSession = nil; previous = 0; residual = 0; model.haptic() })
                    .accessibilityElement().accessibilityLabel(title + " wheel").accessibilityValue(model.text("/eos/out/param/" + param))
                    .accessibilityAdjustableAction { direction in adjust(direction == .increment ? 1 : -1) }
                }.frame(height: 52)
                Button { adjust(1) } label: { Image(systemName: "chevron.right").frame(width: 38, height: 52) }.accessibilityLabel("Increase " + title)
            }.buttonStyle(.plain).foregroundStyle(.secondary).background(DeskPalette.field, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08)) }
        }.padding(12).deskPanel(cornerRadius: 16)
        .disabled(!model.ready || model.selectedChannels.isEmpty)
        .onAppear { if !model.demoMode { model.send("/eos/subscribe/param/\(param)", [1]) } }
        .onChange(of: model.ready) { _ in previous = 0; residual = 0 }
    }
    private func adjust(_ value: Int, continuous: Bool = false) {
        model.haptic(continuous: continuous)
        let wheel = model.feedback.first { entry in
            entry.key.hasPrefix("/eos/out/active/wheel/") && (entry.value.first as? String)?.lowercased().replacingOccurrences(of: " ", with: "_") == param
        }?.key.split(separator: "/").last.map(String.init)
        if let wheel { model.send("/eos/active/wheel/\(fine ? "fine" : "coarse")/\(wheel)", [value]) }
        else { model.send("/eos/wheel/\(fine ? "fine" : "coarse")/\(param)", [value]) }
    }
    private func tap(_ address: String) { model.haptic(); model.tap(address) }
    private func flush(force: Bool = false) {
        guard model.ready, gestureSession == nil || gestureSession == model.session else { residual = 0; return }
        guard force || (ProcessInfo.processInfo.systemUptime - lastSent) >= 1.0/30 else { return }
        let ticks = Int(residual / 5)
        if ticks != 0 { adjust(ticks, continuous: true); residual -= Double(ticks) * 5; lastSent = ProcessInfo.processInfo.systemUptime }
    }
}

private struct DeskFocusPad: View {
    @EnvironmentObject var model: NativeRemoteModel
    let fine: Bool
    @AppStorage("element.focus.invertPan") private var invertPan = false
    @AppStorage("element.focus.invertTilt") private var invertTilt = false
    @AppStorage("element.focus.sensitivity") private var sensitivity = 1.0
    @State private var previous = CGSize.zero
    @State private var residual = CGSize.zero
    @State private var cursor: CGPoint?
    @State private var lastSent = -Double.infinity
    @State private var gestureSession: UUID?
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    invertPan.toggle()
                    model.haptic()
                } label: {
                    Text("Invert X: \(invertPan ? "ON" : "OFF")")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(invertPan ? Color.orange.opacity(0.25) : Color.white.opacity(0.08), in: Capsule())
                }.buttonStyle(.plain)
                
                Button {
                    invertTilt.toggle()
                    model.haptic()
                } label: {
                    Text("Invert Y: \(invertTilt ? "ON" : "OFF")")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(invertTilt ? Color.orange.opacity(0.25) : Color.white.opacity(0.08), in: Capsule())
                }.buttonStyle(.plain)
                
                Spacer()
                
                Button {
                    model.haptic()
                    cursor = nil
                    residual = .zero
                    previous = .zero
                } label: {
                    Label("Center", systemImage: "scope")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }.buttonStyle(.plain)
            }
            
            GeometryReader { geometry in
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                ZStack {
                    DeskPalette.field
                    
                    Path { path in
                        path.move(to: CGPoint(x: center.x, y: 0))
                        path.addLine(to: CGPoint(x: center.x, y: geometry.size.height))
                        path.move(to: CGPoint(x: 0, y: center.y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: center.y))
                    }.stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    
                    Circle().strokeBorder(Color.white.opacity(0.06), lineWidth: 1).frame(width: 80, height: 80)
                    Circle().strokeBorder(Color.white.opacity(0.04), lineWidth: 1).frame(width: 160, height: 160)
                    
                    VStack(spacing: 6) {
                        Image(systemName: "move.3d").font(.title2)
                        Text("Drag to move").font(.subheadline)
                        Text("Fine touch · Pan \(invertPan ? "⇄ [Inv]" : "↔")   Tilt \(invertTilt ? "⇅ [Inv]" : "↕")")
                            .font(.caption2)
                    }.foregroundStyle(Color.white.opacity(0.35))
                    
                    if let cursor {
                        Circle().strokeBorder(Color.mint, lineWidth: 2)
                            .background(Circle().fill(Color.mint.opacity(0.2)))
                            .frame(width: 32, height: 32)
                            .position(cursor)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if gestureSession == nil { gestureSession = model.session }
                        guard gestureSession == model.session else { return }
                        residual.width += (value.translation.width - previous.width) * sensitivity
                        residual.height += (value.translation.height - previous.height) * sensitivity
                        previous = value.translation
                        cursor = CGPoint(
                            x: min(max(value.location.x, 16), geometry.size.width - 16),
                            y: min(max(value.location.y, 16), geometry.size.height - 16)
                        )
                        flush()
                    }
                    .onEnded { _ in
                        if gestureSession == model.session { flush(force: true) }
                        gestureSession = nil; previous = .zero; residual = .zero; cursor = nil; model.haptic()
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.08)) }
            }.frame(height: 260)
        }
        .onChange(of: model.ready) { _ in previous = .zero; residual = .zero; cursor = nil }
    }
    
    private func flush(force: Bool = false) {
        guard model.ready, gestureSession == nil || gestureSession == model.session else { residual = .zero; return }
        guard force || (ProcessInfo.processInfo.systemUptime - lastSent) >= 1.0/30 else { return }
        var pan = Int(residual.width / 5)
        var tilt = Int(-residual.height / 5)
        if invertPan { pan = -pan }
        if invertTilt { tilt = -tilt }
        let mode = fine ? "fine" : "coarse"
        if pan != 0 {
            model.send("/eos/wheel/\(mode)/pan", [pan])
            residual.width -= Double(pan * (invertPan ? -1 : 1)) * 5
        }
        if tilt != 0 {
            model.send("/eos/wheel/\(mode)/tilt", [tilt])
            residual.height += Double(tilt * (invertTilt ? -1 : 1)) * 5
        }
        if pan != 0 || tilt != 0 {
            model.haptic(continuous: true)
            lastSent = ProcessInfo.processInfo.systemUptime
        }
    }
}

private struct NativeColorView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var hue = 0.0
    @State private var saturation = 100.0
    @State private var xy = CGPoint(x: 0.313, y: 0.329)
    @State private var filter = ""
    @State private var lastSent = -Double.infinity
    @State private var colorSession: UUID?
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 16) {
                    ColorStrip(title: "Hue", value: $hue, maximum: 360, colors: stride(from: 0.0, through: 1.0, by: 1.0/12).map { Color(hue: $0, saturation: 1, brightness: 1) }) { force in sendHS(force) }
                    ColorStrip(title: "Saturation", value: $saturation, maximum: 100, colors: [.white, Color(hue: hue/360, saturation: 1, brightness: 1)]) { force in sendHS(force) }
                }.deskCard()
                GeometryReader { geometry in
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: CIEChart.image).resizable().interpolation(.high)
                        Circle().fill(.white).frame(width: 14, height: 14).overlay(Circle().stroke(.black, lineWidth: 2))
                            .position(x: xy.x/0.8*geometry.size.width, y: (1-xy.y/0.9)*geometry.size.height)
                    }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in if colorSession == nil { colorSession = model.session }; guard colorSession == model.session else { return }; pick(value.location, geometry.size) }
                        .onEnded { value in if colorSession == model.session { pick(value.location, geometry.size, force: true) }; colorSession = nil; model.haptic() }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("CIE color diagram").accessibilityHint("Use Hue and Saturation controls above for accessible color adjustment")
                }.aspectRatio(0.8/0.9, contentMode: .fit)
                Text(String(format: "CIE x %.3f · y %.3f", Double(xy.x), Double(xy.y))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                NavigationLink { NativeEmitterView() } label: { Label("Individual LED emitters",systemImage:"slider.horizontal.3").frame(maxWidth:.infinity,alignment:.leading).deskCard() }
                NavigationLink { NativeShowBrowser(family: "cp", title: "Color palettes") } label: { Label("Color palettes", systemImage: "paintpalette").frame(maxWidth: .infinity, alignment: .leading).deskCard() }

            }.padding()
        }.navigationTitle("Color").onAppear {
            syncColorReadouts()
            if model.ready { model.send("/eos/ds/4/cp/32") }
        }
        .onChange(of: model.ready) { ready in if ready { model.send("/eos/ds/4/cp/32") } }
        .onChange(of: model.activeChannels) { _ in syncColorReadouts() }
        .onChange(of: model.text("/eos/out/color/hs")) { _ in syncColorReadouts() }
        .onChange(of: model.text("/eos/out/color/xy")) { _ in syncColorReadouts() }
    }
    private func syncColorReadouts() {
        if let values = model.feedback["/eos/out/color/hs"], values.count >= 2,
           let h = values[0] as? NSNumber, let sat = values[1] as? NSNumber {
            hue = min(max(h.doubleValue, 0), 360); saturation = min(max(sat.doubleValue, 0), 100)
        }
        if let values = model.feedback["/eos/out/color/xy"], values.count >= 2,
           let x = values[0] as? NSNumber, let y = values[1] as? NSNumber {
            xy = CGPoint(x: x.doubleValue, y: y.doubleValue)
        }
    }
    private func sendHS(_ force: Bool) {
        guard model.ready else { return }
        guard force || (ProcessInfo.processInfo.systemUptime - lastSent) >= 1.0/30 else { return }; lastSent = ProcessInfo.processInfo.systemUptime
        model.haptic(continuous: !force)
        model.send("/eos/color/hs", [hue, saturation])
    }
    private func pick(_ point: CGPoint, _ size: CGSize, force: Bool = false) {
        guard model.ready, size.width > 0, size.height > 0 else { return }
        let next = CGPoint(x: min(max(point.x/size.width*0.8, 0), 0.8), y: min(max((1-point.y/size.height)*0.9, 0.001), 0.9))
        guard CIEChart.contains(next) else { return }; xy = next
        guard force || (ProcessInfo.processInfo.systemUptime - lastSent) >= 1.0/30 else { return }; lastSent = ProcessInfo.processInfo.systemUptime
        model.haptic(continuous: !force)
        model.send("/eos/color/xy", [Double(next.x), Double(next.y)])
    }
}

private struct ColorStrip: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var dragSession: UUID?
    let title: String
    @Binding var value: Double
    let maximum: Double
    let colors: [Color]
    var changed: (Bool) -> Void
    var body: some View {
        VStack(spacing: 8) {
            HStack { Text(title); Spacer(); Text("\(Int(value))").monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    Circle().fill(.white).frame(width: 30, height: 30).shadow(color: .black.opacity(0.4), radius: 3).overlay(Circle().stroke(.black.opacity(0.2)))
                        .offset(x: value/maximum * max(geometry.size.width-30, 1))
                }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                    .onChanged { gesture in if dragSession == nil { dragSession = model.session }; guard dragSession == model.session else { return }; value = min(max((gesture.location.x-15)/max(geometry.size.width-30, 1)*maximum, 0), maximum); changed(false) }
                    .onEnded { _ in if dragSession == model.session { changed(true) }; dragSession = nil; model.haptic() })
                .accessibilityElement().accessibilityLabel(title).accessibilityValue("\(Int(value))")
                .accessibilityAdjustableAction { direction in value = min(max(value + (direction == .increment ? 1 : -1), 0), maximum); changed(true); model.haptic() }
            }.frame(height: 30)
        }
    }
}

private enum CIEChart {
    static let locus: [CGPoint] = [CGPoint(x: 0.174, y: 0.005), CGPoint(x: 0.168, y: 0.005), CGPoint(x: 0.157, y: 0.018), CGPoint(x: 0.144, y: 0.03), CGPoint(x: 0.124, y: 0.058), CGPoint(x: 0.091, y: 0.133), CGPoint(x: 0.046, y: 0.295), CGPoint(x: 0.008, y: 0.538), CGPoint(x: 0.014, y: 0.75), CGPoint(x: 0.074, y: 0.834), CGPoint(x: 0.155, y: 0.806), CGPoint(x: 0.23, y: 0.754), CGPoint(x: 0.302, y: 0.692), CGPoint(x: 0.374, y: 0.624), CGPoint(x: 0.444, y: 0.555), CGPoint(x: 0.512, y: 0.487), CGPoint(x: 0.575, y: 0.424), CGPoint(x: 0.627, y: 0.373), CGPoint(x: 0.665, y: 0.335), CGPoint(x: 0.692, y: 0.308), CGPoint(x: 0.708, y: 0.292), CGPoint(x: 0.719, y: 0.281), CGPoint(x: 0.728, y: 0.272), CGPoint(x: 0.735, y: 0.265)]
    static func contains(_ point: CGPoint) -> Bool {
        var inside = false; var j = locus.count-1
        for i in locus.indices {
            let a = locus[i], b = locus[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
            j = i
        }
        return inside
    }
    static let image: UIImage = {
        let width = 320, height = 360
        var bytes = [UInt8](repeating: 255, count: width*height*4)
        for py in 0..<height { for px in 0..<width {
            let x = Double(px)/Double(width)*0.8, y = (1-Double(py)/Double(height))*0.9
            let X = x/max(y, 0.001), Z = (1-x-y)/max(y, 0.001)
            let linear = [max(0,3.2406*X-1.5372-0.4986*Z), max(0,-0.9689*X+1.8758+0.0415*Z), max(0,0.0557*X-0.204+1.057*Z)]
            let peak = max(linear.max() ?? 1, 1), factor = contains(CGPoint(x: x,y: y)) ? 1.0 : 0.12
            for channel in 0..<3 {
                let n = linear[channel]/peak
                let gamma = n <= 0.0031308 ? 12.92*n : 1.055*pow(n,1/2.4)-0.055
                bytes[(py*width+px)*4+channel] = UInt8(min(max(gamma*255*factor, 0), 255))
            }
        } }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data), let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return UIImage() }
        return UIImage(cgImage: cg)
    }()
}

private struct NativePatchView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var offset = 0
    @State private var query = ""
    @State private var timedOut = false
    @State private var token = UUID()
    private var rows: [EosFixtureRecord] {
        model.fixtures.values.filter { query.isEmpty || "\($0.channel) \($0.label) \($0.model) \($0.universeAddress)".localizedCaseInsensitiveContains(query) }
            .sorted { $0.channel == $1.channel ? $0.part < $1.part : $0.channel < $1.channel }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NavigationLink { NativeFixtureQRView() } label: { Label("Scan QR label",systemImage:"qrcode.viewfinder") }
                Spacer()
                NavigationLink("Compare fixtures") { NativeFixtureCompareView() }
            }.font(.subheadline).padding(.horizontal,16).padding(.bottom,8)
            HStack {
                TextField("Find channel, type or address", text: $query).textFieldStyle(.roundedBorder)
                Button { load() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.disabled(!model.ready)
            }.padding(.horizontal, 16)
            List {
                Section {
                    ForEach(rows) { fixture in
                        NavigationLink {
                            if let selected = try? EosChannelSelection(String(fixture.channel)) { NativeFixtureDetailsView(selection: selected) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(String(fixture.channel)).font(.headline.monospacedDigit())
                                    if fixture.part > 1 { Text("Part \(fixture.part)").font(.caption2).foregroundStyle(.secondary) }
                                }.frame(width: 48, alignment: .leading)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(fixture.patchAddress).font(.subheadline.monospacedDigit()).foregroundStyle(DeskPalette.accent)
                                    if fixture.endingAddress == nil, (fixture.address ?? 0) > 0 { Text("Start only").font(.caption2).foregroundStyle(.secondary) }
                                }.frame(width: 92, alignment: .leading)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(fixture.label.isEmpty ? "Fixture \(fixture.channel)" : fixture.label).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Text(fixture.model.isEmpty ? "Type pending" : fixture.model.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    Text(fixture.level.map { "\(Int($0))%" } ?? "Level unavailable")
                                        .font(.caption.monospacedDigit()).foregroundStyle(DeskPalette.accent)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.vertical, 8)
                            .accessibilityElement(children: .combine)
                        }.listRowBackground(DeskPalette.surface).listRowSeparatorTint(DeskPalette.rule)
                    }
                    if rows.isEmpty { Text(timedOut ? "No patch data received. Check OSC TX and the connection." : "Waiting for patch…").font(.subheadline).foregroundStyle(.secondary) }
                } header: {
                    HStack(spacing: 12) {
                        Text("Channel").frame(width: 48, alignment: .leading)
                        Text("Address").frame(width: 92, alignment: .leading)
                        Text("Fixture / Level").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.caption2)
                }
                HStack {
                    Button("Previous") { offset = max(0, offset - 25); load() }.disabled(offset == 0 || model.demoMode)
                    Spacer()
                    Text("Page \(offset / 25 + 1)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Next") { offset += 25; load() }.disabled(model.demoMode || !model.ready)
                }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
        }.navigationTitle("Patch")
        .onAppear { load() }
        .onChange(of: model.ready) { ready in if ready { load() } }
        .onChange(of: model.softwareVersion) { _ in if model.ready { load() } }
    }
    private func load() {
        let current = UUID(); token = current; timedOut = false
        guard model.ready else { timedOut = true; return }
        model.fixtures = [:]
        if model.demoMode { model.requestFixtureDetails(Array(1...12)); return }
        model.send("/eos/get/patch/count")
        for index in offset..<(offset + 25) { if let request = try? EosCommands.patchRequest(index: index, version: model.softwareVersion) { model.send(request) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if token == current { timedOut = true } }
    }
}

private struct NativeLegalView: View {
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            Text("Privacy").font(.headline)
            Text("Element Remote Privacy Policy\nEffective November 4, 2026\n\nElement Remote stores console profiles, preferences, and practice settings on your device. The app does not require an account and does not include advertising, tracking, or third-party analytics.\n\nLive control sends OSC commands directly to your chosen lighting console and receives console feedback over the local network. Nearby search resolves advertised OSC services and checks nearby Wi-Fi addresses on TCP port 3032 using OSC pings. These communications support app functionality; they are not used for advertising or profiling. Test Mode uses a local sample show.\n\nLocal Network permission is needed to reach your console. The app does not request or store location coordinates. Console addresses and preferences remain in app storage. Removing a saved console deletes that profile. Uninstalling the app removes its local app data, subject to your device backup settings.\n\nApple may process diagnostics and App Store or TestFlight information under Apple’s own settings and policies. If you email support, we use the information you provide to respond to your request. We do not sell that information. Contact support to request deletion of correspondence.\n\nPrivacy and support contact: support@elementremote.xyz\nDeveloper: Element Remote\n").font(.subheadline)
            Text("Open-source license").font(.headline)
            Text("MIT License\n\nCopyright (c) 2017 Dave Thwaites\n\nPermission is hereby granted, free of charge, to any person obtaining a copy\nof this software and associated documentation files (the \"Software\"), to deal\nin the Software without restriction, including without limitation the rights\nto use, copy, modify, merge, publish, distribute, sublicense, and/or sell\ncopies of the Software, and to permit persons to whom the Software is\nfurnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all\ncopies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR\nIMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,\nFITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE\nAUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER\nLIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,\nOUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE\nSOFTWARE.\n").font(.caption)
        }.padding() }.navigationTitle("Privacy & licenses")
    }
}

private struct NativeParameterInspector: View {
    @EnvironmentObject var model: NativeRemoteModel
    let channel: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Channel \(channel) · Live parameters").font(.headline); Spacer(); Button { model.requestParameters(channel) } label: { Image(systemName: "arrow.clockwise") } }
            if let parameters = model.fixtureParameters[channel], !parameters.isEmpty {
                ForEach(parameters) { parameter in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(parameter.name.replacingOccurrences(of: "_", with: " "))
                            Text(String(format: "%.2f to %.2f", parameter.minimum, parameter.maximum)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.2f", parameter.level)).monospacedDigit()
                    }.font(.subheadline)
                    Divider()
                }
            } else { Text("Waiting for Get Params feedback. Requires Eos 3.2 or later.").font(.caption).foregroundStyle(.secondary) }
        }.deskCard()
        .onAppear { model.requestParameters(channel) }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in if model.ready { model.requestParameters(channel) } }
    }
}

private struct NativeCueListsView: View {
    @EnvironmentObject var model: NativeRemoteModel
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                NavigationLink("Cue List 1") { NativeShowBrowser(family: "cue/1", title: "Cue List 1") }.deskCard()
                ForEach(model.showData.records.keys.filter { $0.hasPrefix("cuelist/") && $0.split(separator: "/").count == 2 && $0 != "cuelist/1" }.sorted(), id: \.self) { key in
                    let number = String(key.split(separator: "/").last ?? "1")
                    NavigationLink { NativeShowBrowser(family: "cue/" + number, title: "Cue List " + number) } label: {
                        Text("Cue List " + number + " · " + ((model.showData.records[key]?[2] as? String) ?? ""))
                    }.deskCard()
                }
                Button("Refresh cue lists") { model.requestShow("cuelist") }
            }.padding()
        }.navigationTitle("Cue lists").onAppear { model.requestShow("cuelist") }
    }
}

private struct NativeShowBrowser: View {
    @EnvironmentObject var model: NativeRemoteModel
    let family: String
    let title: String
    @State private var search = ""
    private var keys: [String] {
        let length = family.split(separator: "/").count + (family.hasPrefix("cue/") ? 2 : 1)
        return model.showData.records.keys.filter { key in
            key.hasPrefix(family + "/") && key.split(separator: "/").count == length &&
            (search.isEmpty || (key + " " + ((model.showData.records[key]?[2] as? String) ?? "")).localizedCaseInsensitiveContains(search))
        }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                TextField("Search number or label", text: $search).padding(12).background(DeskPalette.field, in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Text(search.isEmpty ? (model.showCounts[family].map { "\(keys.count) of \($0) loaded" } ?? "Loading show library…") : "\(keys.count) results").font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button("Refresh") { model.requestShow(family) }.disabled(!model.ready)
                }
                if family.hasPrefix("cue/"), let list = family.split(separator:"/").last,
                   let fields = model.showData.records["cuelist/" + list] {
                    DisclosureGroup("Cue list configuration") {
                        VStack(alignment:.leading,spacing:8) {
                            Text("Playback: " + ((fields[3] as? String) ?? "Not reported"))
                            Text("Fader mode: " + ((fields[4] as? String) ?? "Not reported"))
                            ForEach([5,6,7,8,9,10,12],id:\.self) { index in
                                if let flag = fields[index] as? NSNumber { Text(([5:"Independent",6:"HTP",7:"Assert",8:"Block",9:"Background",10:"Solo",12:"Out-of-sequence sync"][index] ?? "") + ": " + (flag.boolValue ? "On" : "Off")) }
                            }
                            if let links = model.showData.records["cuelist/" + list + "/links"] { Text("Linked lists: " + links.keys.sorted().filter { $0 >= 2 }.compactMap { links[$0].map { String(describing:$0) } }.joined(separator:", ")) }
                        }.font(.caption).foregroundStyle(.secondary).padding(.top,8)
                    }.deskCard()
                }
                if keys.isEmpty {
                    ContentUnavailableViewCompat(title:!search.isEmpty ? "No matches" : !model.ready ? "Connect to your console" : model.showCounts[family] == 0 ? "Nothing stored yet" : "Waiting for console data",text:!search.isEmpty ? "Try another name or number." : !model.ready ? "Connect in Settings, or enable Test Mode to explore the sample show." : "Use Refresh to request the latest show data.",symbol:!search.isEmpty ? "magnifyingglass" : "list.bullet")
                }
                ForEach(keys, id: \.self) { key in
                    NavigationLink { NativeShowItemDetails(key: key) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(displayNumber(key)).font(.caption).foregroundStyle(DeskPalette.accent)
                                Text((model.showData.records[key]?[2] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Unlabeled").font(.headline)
                                if family.hasPrefix("cue/") {
                                    Text("Up " + duration(key, 3) + " · Down " + duration(key, 5)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.deskCard()
                    }.buttonStyle(.plain)
                }
            }.padding()
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .onAppear { if model.showCounts[family] == nil { model.requestShow(family) } }
        .onChange(of: model.ready) { ready in if ready { model.requestShow(family) } }
    }
    private func displayNumber(_ key: String) -> String {
        let p = key.split(separator: "/")
        if family.hasPrefix("cue/"), p.count == 4 { return "Cue \(p[2])" + (p[3] == "0" ? "" : " · Part \(p[3])") }
        return "\(title) · \(p.last ?? "")"
    }
    private func duration(_ key: String, _ index: Int) -> String { (model.showData.records[key]?[index] as? NSNumber).map { String(format: "%.1fs", $0.doubleValue / 1000) } ?? "—" }
}

private struct NativeShowItemDetails: View {
    @EnvironmentObject var model: NativeRemoteModel
    let key: String
    private var fields: [Int: Any] { model.showData.records[key] ?? [:] }
    private var family: String { String(key.split(separator: "/").first ?? "") }
    private var number: String { String(key.split(separator: "/").dropFirst().first ?? "") }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(value(2).isEmpty ? "Unlabeled" : value(2)).font(.title2.weight(.semibold))
                Text(key.replacingOccurrences(of: "/", with: " · ")).font(.subheadline).foregroundStyle(.secondary)
                if family == "cue" {
                    VStack(spacing: 12) {
                        ForEach([3, 5, 7, 9, 11], id: \.self) { index in
                            detail([3: "Up", 5: "Down", 7: "Focus", 9: "Color", 11: "Beam"][index] ?? "", milliseconds(index) + " · delay " + milliseconds(index + 1))
                        }
                        detail("Parts", value(26)); detail("Notes", value(27)); detail("Scene", value(28))
                        detail("Mark", value(16)); detail("Block", value(17)); detail("Assert", value(18))
                        detail("Follow", milliseconds(20)); detail("Hang", milliseconds(21))
                    }.deskCard()
                    Button("Go to this cue") {
                        let parts = key.split(separator: "/")
                        if parts.count == 4 { model.goToCue(String(parts[2]), list: Int(parts[1])) }
                    }.buttonStyle(.bordered).disabled(!model.ready)
                } else if family == "fx" {
                    Text("Applies this stored effect to the selected channels.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Apply effect") { model.send("/eos/newcmd",["Effect \(number) Enter"]) }.buttonStyle(.borderedProminent).disabled(!model.ready || model.selectedChannels.isEmpty)
                } else if family == "snap" {
                    Text("Restores the console’s display layout. This does not restore a lighting look.").font(.subheadline).foregroundStyle(.secondary)
                    Button("Recall console workspace") { model.send("/eos/snap/\(number)/fire") }.buttonStyle(.borderedProminent).disabled(!model.ready)
                } else if family == "sub" {
                    VStack(spacing: 12) {
                        detail("Mode", value(3)); detail("Fader mode", value(4)); detail("HTP", boolean(5))
                        detail("Exclusive", boolean(6)); detail("Background", boolean(7)); detail("Restore", boolean(8))
                        detail("Priority", value(9)); detail("Up", value(10)); detail("Dwell", value(11)); detail("Down", value(12))
                    }.deskCard()
                } else {
                    detail("Absolute", boolean(3)); detail("Locked", boolean(4))
                    Button("Apply to selected channels") {
                        let command = ["fp": "Focus Palette", "cp": "Color Palette", "bp": "Beam Palette", "preset":"Preset"][family] ?? ""
                        guard !command.isEmpty else { return }
                        model.send("/eos/newcmd", ["\(command) \(number) Enter"])
                    }.buttonStyle(.bordered).disabled(!model.ready || model.selectedChannels.isEmpty)
                }
                ForEach(["channels", "byType", "fx"], id: \.self) { suffix in
                    let list = model.showData.records[key + "/" + suffix] ?? [:]
                    if !list.isEmpty {
                        detail(suffix == "byType" ? "By type channels" : suffix.capitalized, list.keys.sorted().filter { $0 >= 2 }.map { String(describing: list[$0]!) }.joined(separator: ", "))
                    }
                }
            }.padding()
        }.navigationTitle("Details").navigationBarTitleDisplayMode(.inline)
    }
    private func value(_ index: Int) -> String { fields[index].map { String(describing: $0) } ?? "" }
    private func boolean(_ index: Int) -> String { (fields[index] as? NSNumber).map { $0.boolValue ? "Yes" : "No" } ?? "Not reported" }
    private func milliseconds(_ index: Int) -> String { (fields[index] as? NSNumber).map { String(format: "%.1fs", $0.doubleValue / 1000) } ?? "Not reported" }
    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(label).foregroundStyle(.secondary); Spacer(); Text(value.isEmpty ? "—" : value).multilineTextAlignment(.trailing) }.font(.subheadline)
    }
}

private struct NativeCreativeView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var tab: Int
    init(initialTab:Int = 0) { _tab = State(initialValue:initialTab) }
    @State private var parameter = "pan"
    @State private var start = -30.0
    @State private var end = 30.0
    @State private var effect = "901"
    @State private var rateFader = 1
    @State private var sizeFader = 2
    @State private var rate = 0.5
    @State private var size = 0.5
    private var channels: [Int] { model.selectedChannels.sorted() }
    var body: some View {
        Form {
            Section { Picker("Tool",selection:$tab) { Text("Spread").tag(0); Text("Effects").tag(1) }.pickerStyle(.segmented) }
            if tab == 0 {
            Section("Spread selected fixtures") {
                Text(channels.isEmpty ? "Choose channels in Quick Control first." : "Channels " + channels.map(String.init).joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary)
                Picker("Parameter", selection: $parameter) { Text("Pan").tag("pan"); Text("Tilt").tag("tilt"); Text("Intensity").tag("intens") }
                numeric("First channel", value: $start)
                numeric("Last channel", value: $end)
                Text("Applies a linear spread to up to 64 channels in ascending channel order. Values are degrees for pan/tilt and percent for intensity.").font(.caption).foregroundStyle(.secondary)
                Button("Apply spread") {
                    do { model.sendBatch(try EosCreativeCommands.fan(channels: channels, parameter: parameter, start: start, end: end)) }
                    catch { model.error = error.localizedDescription }
                }.disabled(!model.ready || channels.isEmpty || (parameter == "intens" && (![start,end].allSatisfy { (0...100).contains($0) })))
            }
            }
            if tab == 1 {
            Section("Stored effects") {
                NavigationLink("Browse named effects") { NativeShowBrowser(family:"fx",title:"Effects") }
                NavigationLink("Browse presets") { NativeShowBrowser(family:"preset",title:"Presets") }
                TextField("Effect number", text: $effect).keyboardType(.numberPad)
                Button("Apply effect to selection") { model.send("/eos/newcmd", ["Effect \(effect) Enter"]) }
                    .disabled(!model.ready || channels.isEmpty || (Int(effect).map { !(1...999999).contains($0) } ?? true))
                Button("Stop effects on selection") { model.sendBatch([OSCMessage(address: "/eos/key/stop_effect_button", parameters: [1.0]), OSCMessage(address: "/eos/key/stop_effect_button", parameters: [0.0]), OSCMessage(address: "/eos/key/enter", parameters: [1.0]), OSCMessage(address: "/eos/key/enter", parameters: [0.0])]) }.disabled(!model.ready || channels.isEmpty)
            }
            Section {
                DisclosureGroup("Advanced · mapped rate & size faders") {
                Text("In console Fader Config, assign Effect Rate and Effect Size to the faders below. These sliders drive those mapped faders; they do not edit the base effect.").font(.caption).foregroundStyle(.secondary)
                Stepper("Rate · fader \(rateFader)", value: $rateFader, in: 1...40)
                Slider(value: $rate, in: 0...1, onEditingChanged: { editing in if !editing { model.send("/eos/fader/1/\(rateFader)", [rate]) } }).accessibilityLabel("Mapped effect rate")
                Button("Home rate fader") { model.send("/eos/fader/1/\(rateFader)/home") }
                Stepper("Size · fader \(sizeFader)", value: $sizeFader, in: 1...40)
                Slider(value: $size, in: 0...1, onEditingChanged: { editing in if !editing { model.send("/eos/fader/1/\(sizeFader)", [size]) } }).accessibilityLabel("Mapped effect size")
                Button("Home size fader") { model.send("/eos/fader/1/\(sizeFader)/home") }
                }
            }.disabled(!model.ready)
            }
        }.scrollContentBackground(.hidden).background(DeskPalette.background).navigationTitle(tab == 0 ? "Spread Fixtures" : "Effects")
        .onAppear { if model.ready && tab == 1 { model.send("/eos/fader/1/config/1/40") } }
        .onChange(of:tab) { value in if model.ready && value == 1 { model.send("/eos/fader/1/config/1/40") } }
    }
    private func numeric(_ title: String, value: Binding<Double>) -> some View { HStack { Text(title); Spacer(); TextField(title, value: value, format: .number).multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation).frame(width: 100) } }
}

private struct NativeStageFocusView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var calibrated = false
    @State private var width = 12.0
    @State private var depth = 8.0
    @State private var x = 0.0
    @State private var y = 0.0
    @State private var z = 0.0
    @State private var follow = false
    @State private var lastSent = -Double.infinity
    @State private var dragSession: UUID?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Stage coordinates").font(.headline)
                    Text("Requires calibrated fixture positions in Augment3d. Coordinates are meters, with the same origin and axes as your console model.").font(.subheadline).foregroundStyle(.secondary)
                    Toggle("My fixtures are calibrated", isOn: $calibrated)
                    HStack { dimension("Map width", value: $width); dimension("Map depth", value: $depth) }
                    HStack { dimension("X", value: $x); dimension("Y", value: $y); dimension("Z", value: $z) }
                    Toggle("Follow finger while dragging", isOn: $follow)
                }.deskCard()
                GeometryReader { geometry in
                    ZStack {
                        RoundedRectangle(cornerRadius: 18).fill(DeskPalette.field)
                        Path { path in
                            path.move(to: CGPoint(x: geometry.size.width/2,y:0)); path.addLine(to: CGPoint(x:geometry.size.width/2,y:geometry.size.height))
                            path.move(to: CGPoint(x:0,y:geometry.size.height/2)); path.addLine(to: CGPoint(x:geometry.size.width,y:geometry.size.height/2))
                        }.stroke(DeskPalette.rule)
                        Image(systemName: "scope").font(.system(size: 34)).foregroundStyle(DeskPalette.accent)
                            .position(x: (x/max(width,1)+0.5)*geometry.size.width, y:(0.5-y/max(depth,1))*geometry.size.height)
                        VStack { Text("+Y"); Spacer(); Text("−Y") }.font(.caption2).foregroundStyle(.secondary).padding(8)
                    }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if dragSession == nil { dragSession = model.session }
                        guard dragSession == model.session else { return }
                        x = (min(max(value.location.x/geometry.size.width,0),1)-0.5)*max(width,1)
                        y = (0.5-min(max(value.location.y/geometry.size.height,0),1))*max(depth,1)
                        if follow { apply() }
                    }.onEnded { _ in if follow, dragSession == model.session { apply(force:true) }; dragSession = nil })
                }.frame(height: 260).disabled(!calibrated || !model.ready || model.selectedChannels.isEmpty)
                Button("Focus selection here") { apply(force:true) }.buttonStyle(.borderedProminent).disabled(!calibrated || !model.ready || model.selectedChannels.isEmpty)
                Text("Manual position control; it does not track actors. The console computes fixture movement.").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }.navigationTitle("Stage Map Focus")
    }
    private func dimension(_ title: String, value: Binding<Double>) -> some View { VStack(alignment:.leading) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title,value:value,format:.number).keyboardType(.numbersAndPunctuation).textFieldStyle(.roundedBorder) } }
    private func apply(force: Bool = false) {
        guard calibrated, model.ready, !model.selectedChannels.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now-lastSent >= 0.1 else { return }; lastSent = now
        do { model.send(try EosCreativeCommands.xyz(x:x,y:y,z:z)) } catch { model.error = error.localizedDescription }
    }
}

private struct NativeRehearsalView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var note = ""
    @State private var confirmClear = false
    var body: some View {
        List {
            Section {
                Toggle("Record console events", isOn: $model.recordRehearsal).onChange(of:model.recordRehearsal) { UserDefaults.standard.set($0, forKey:"element.recordRehearsal") }
                Text("Records received cue and show-file events while connected in the foreground. Stores up to 1,000 entries on this device.").font(.caption).foregroundStyle(.secondary)
                HStack { TextField("Rehearsal note",text:$note); Button("Add") { model.logRehearsal(note); note = "" }.disabled(note.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
                ShareLink(item:model.rehearsalEvents.reversed().map { "\($0.date.formatted()) | \($0.show) | \($0.detail)" }.joined(separator:"\n")) { Label("Share timeline",systemImage:"square.and.arrow.up") }.disabled(model.rehearsalEvents.isEmpty)
            }
            Section("Timeline") {
                if model.rehearsalEvents.isEmpty { Text("No events recorded yet.").foregroundStyle(.secondary) }
                ForEach(model.rehearsalEvents) { event in VStack(alignment:.leading,spacing:5) { Text(event.detail); Text(event.date,style:.time).font(.caption).foregroundStyle(.secondary); if !event.show.isEmpty { Text(event.show).font(.caption2).foregroundStyle(.secondary) } } }
            }
            Section { Button("Clear timeline",role:.destructive) { confirmClear = true } }
        }.scrollContentBackground(.hidden).background(DeskPalette.background).navigationTitle("Rehearsal")
        .confirmationDialog("Clear recorded events?",isPresented:$confirmClear,titleVisibility:.visible) { Button("Clear",role:.destructive) { model.rehearsalEvents = []; model.saveRehearsal() } }
    }
}

private struct NativeCueMonitorView: View {
    @EnvironmentObject var model: NativeRemoteModel
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:28) {
                Label(model.online ? "Live console feedback" : "Disconnected · values may be stale",systemImage:model.online ? "dot.radiowaves.left.and.right" : "wifi.slash").font(.caption).foregroundStyle(.secondary)
                VStack(alignment:.leading,spacing:18) { Text("NOW").font(.caption.weight(.semibold)).foregroundStyle(DeskPalette.accent); Text(model.activeCueText).font(.system(size:42,weight:.semibold)); ProgressView(value:model.activeCuePercent).tint(DeskPalette.accent) }.deskCard()
                VStack(alignment:.leading,spacing:18) { Text("NEXT").font(.caption.weight(.semibold)).foregroundStyle(DeskPalette.accent); Text(model.pendingCueText).font(.system(size:32,weight:.medium)) }.deskCard()
                Text("Read-only display · no playback buttons").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }.navigationTitle("Cue Monitor")
    }
}

private struct NativePatchNotesView: View {
    @EnvironmentObject var model: NativeRemoteModel
    let fixture: EosFixtureRecord
    @State private var label = ""
    @State private var note = ""
    @State private var sent = false
    var body: some View {
        Form {
            Section("Channel \(fixture.channel) · Part \(fixture.part)") {
                TextField("Fixture label",text:$label)
                TextEditor(text:$note).frame(minHeight:180).accessibilityLabel("Fixture notes")
                Button("Send label & notes to console") { model.patchNote(channel:fixture.channel,part:fixture.part,label:label,note:note); sent = true }.disabled(!model.ready || label.utf8.count > 512 || note.utf8.count > 4096)
                if sent { Text(model.demoMode ? "Updated practice fixture." : "Sent. Reported console values appear below; OSC does not provide a save acknowledgement.").font(.caption).foregroundStyle(.secondary) }
            }
            if let reported = model.fixtures[fixture.id] { Section("Reported by console") { LabeledContent("Label",value:reported.label); Text(reported.notes.isEmpty ? "No notes reported" : reported.notes) } }
            Text("Changes edit show data on the console. Save the show on Element to keep them in its show file.").font(.caption).foregroundStyle(.secondary)
        }.scrollContentBackground(.hidden).background(DeskPalette.background).navigationTitle("Fixture notes")
        .onAppear { label = fixture.label; note = fixture.notes }
    }
}

private struct NativeFixtureQRView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var channel = "1"
    @State private var scanning = false
    @State private var inspected: EosChannelSelection?
    @State private var pendingScan: String?
    @State private var validation = ""
    private var number: Int? { Int(channel).flatMap { (1...999999).contains($0) ? $0 : nil } }
    private var qr: UIImage? {
        guard let number else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data("elementremote://channel/\(number)".utf8)
        guard let output = filter.outputImage?.transformed(by:CGAffineTransform(scaleX:10,y:10)), let image = CIContext().createCGImage(output,from:output.extent) else { return nil }
        return UIImage(cgImage:image)
    }
    var body: some View {
        ScrollView {
            VStack(spacing:18) {
                Button { scanning = true } label: { Label("Scan fixture label",systemImage:"qrcode.viewfinder").frame(maxWidth:.infinity,minHeight:52) }.buttonStyle(.borderedProminent)
                VStack(alignment:.leading,spacing:12) {
                    Text("Create a channel label").font(.headline)
                    TextField("Channel",text:$channel).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                    if let qr, let number {
                        Image(uiImage:qr).interpolation(.none).resizable().scaledToFit().padding(20).background(.white,in:RoundedRectangle(cornerRadius:16)).frame(maxWidth:260).frame(maxWidth:.infinity)
                        Text("Channel \(number)").font(.title2.weight(.semibold)).frame(maxWidth:.infinity)
                        ShareLink(item:Image(uiImage:qr),preview:SharePreview("Channel \(number)",image:Image(uiImage:qr))) { Label("Share QR label",systemImage:"square.and.arrow.up") }
                        Button("Inspect channel") { open(String(number)) }
                    }
                    Text("Scan with Element Remote. Labels identify channel numbers; replace them if the show’s channel assignments change.").font(.caption).foregroundStyle(.secondary)
                    if !validation.isEmpty { Text(validation).foregroundStyle(.orange) }
                }.deskCard()
            }.padding()
        }.navigationTitle("Fixture QR")
        .sheet(isPresented:$scanning,onDismiss: { if let result = pendingScan { pendingScan = nil; open(result) } }) { NativeQRScanner { result in pendingScan = result; scanning = false } }
        .sheet(isPresented:Binding(get:{ inspected != nil },set:{ if !$0 { inspected = nil } })) { if let selection = inspected { NavigationStack { NativeFixtureDetailsView(selection:selection) }.environmentObject(model) } }
    }
    private func open(_ text: String) {
        guard let number = EosCreativeCommands.channel(fromQR:text) else { validation = "This is not an Element Remote channel label."; return }
        channel = String(number); validation = ""; inspected = try? EosChannelSelection(String(number))
    }
}

private struct NativeQRScanner: UIViewControllerRepresentable {
    let found: (String)->Void
    func makeUIViewController(context:Context)->QRScanController { let controller = QRScanController(); controller.found = found; return controller }
    func updateUIViewController(_ controller:QRScanController,context:Context) {}
    static func dismantleUIViewController(_ controller:QRScanController,coordinator:()) { controller.stop() }
}
private final class QRScanController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var found: ((String)->Void)?
    private let capture = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label:"element.qr.camera")
    private var preview: AVCaptureVideoPreviewLayer?
    private var completed = false
    private var active = true
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for:.video) { [weak self] granted in DispatchQueue.main.async { if granted { self?.setup() } else { self?.message("Camera access is off. Enable it in iOS Settings to scan labels.") } } }
    }
    private func setup() {
        guard active else { return }
        guard let camera = AVCaptureDevice.default(for:.video), let input = try? AVCaptureDeviceInput(device:camera), capture.canAddInput(input) else { message("No camera available. You can enter a channel manually."); return }
        capture.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard capture.canAddOutput(output) else { message("QR scanning is unavailable."); return }
        capture.addOutput(output); output.setMetadataObjectsDelegate(self,queue:.main); output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session:capture); layer.videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); preview = layer; layer.frame = view.bounds
        let session = capture; cameraQueue.async { session.startRunning() }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    func stop() { active = false; let session = capture; cameraQueue.async { session.stopRunning() } }
    func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput objects:[AVMetadataObject],from connection:AVCaptureConnection) {
        guard !completed, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }; completed = true; stop(); found?(value)
    }
    private func message(_ text:String) { let label = UILabel(); label.text = text; label.textColor = .white; label.numberOfLines = 0; label.textAlignment = .center; label.frame = view.bounds.insetBy(dx:24,dy:60); label.autoresizingMask = [.flexibleWidth,.flexibleHeight]; view.addSubview(label) }
}

private struct NativeShowControlView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @AppStorage("element.qlab.host") private var host = ""
    @AppStorage("element.qlab.port") private var port = "53000"
    @State private var soundCue = "1"
    @State private var lightingCue = "1"
    @State private var status = ""
    @State private var link: NWConnection?
    @State private var sending = false
    private var valid: Bool { IPv4Address(host) != nil && UInt16(port).map { $0 > 0 } == true && soundCue.range(of:#"^[A-Za-z0-9_.-]{1,64}$"#,options:.regularExpression) != nil }
    var body: some View {
        Form {
            Section("QLab Mac") {
                TextField("Mac IPv4 address",text:$host).keyboardType(.decimalPad)
                TextField("OSC port",text:$port).keyboardType(.numberPad)
                TextField("QLab cue number",text:$soundCue).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("Enable OSC Control without a passcode for this connection in QLab, on a trusted local network. QLab must be running on its Mac.").font(.caption).foregroundStyle(.secondary)
                Button("Start QLab cue") { start(linked:false) }.disabled(!valid || sending)
            }
            Section("Linked lighting & sound") {
                TextField("Element cue",text:$lightingCue).keyboardType(.decimalPad)
                Button("Run linked cues") { start(linked:true) }.disabled(!valid || sending || !model.ready || (try? EosCommands.goToCue(lightingCue)) == nil)
                Text("Sends separate lighting and sound commands. This is not frame-synchronized playback. Rehearse the timing before using it in a show.").font(.caption).foregroundStyle(.secondary)
            }
            if !status.isEmpty { Section("Status") { Text(status) } }
        }.scrollContentBackground(.hidden).background(DeskPalette.background).navigationTitle("QLab Sound & Video")
        .onDisappear { link?.cancel(); link = nil; sending = false }
    }
    private func start(linked:Bool) {
        guard valid else { return }
        if model.demoMode { status = "Practice: QLab cue \(soundCue)"; if linked { model.goToCue(lightingCue) }; return }
        guard let endpoint = NWEndpoint.Port(port), let bytes = try? OSCCodec.encode(OSCMessage(address:"/cue/\(soundCue)/start",parameters:[]), allowExternalAddress:true) else { return }
        link?.cancel(); sending = true; status = "Sending…"
        let targetCue = lightingCue
        let connection = NWConnection(host:NWEndpoint.Host(host),port:endpoint,using:.udp); link = connection
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                connection.send(content:bytes,completion:.contentProcessed { error in DispatchQueue.main.async {
                    sending = false; status = error.map { $0.localizedDescription } ?? "QLab command sent; delivery is not acknowledged."
                    if error == nil && linked { model.goToCue(targetCue) }
                    connection.cancel()
                } })
            case .failed(let error), .waiting(let error):
                connection.stateUpdateHandler = nil
                DispatchQueue.main.async { sending = false; status = error.localizedDescription; connection.cancel() }
            default: break
            }
        }
        connection.start(queue:.global(qos:.userInitiated))
        DispatchQueue.main.asyncAfter(deadline:.now()+5) {
            guard link === connection, sending else { return }
            connection.stateUpdateHandler = nil; connection.cancel(); sending = false; status = "QLab connection timed out. No linked lighting cue was sent."
        }
    }
}

private struct NativeFixtureCompareView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @State private var left = "1"
    @State private var right = "2"
    @State private var onlyDifferences = true
    private var a: Int? { valid(left) }
    private var b: Int? { valid(right) }
    private var rows: [EosParameterComparison] {
        guard let a, let b, let first = model.fixtureParameters[a], let second = model.fixtureParameters[b] else { return [] }
        return EosParameterComparison.rows(first,second).filter { !onlyDifferences || $0.differs }
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                VStack(alignment:.leading,spacing:12) {
                    Text("Compare live parameters").font(.headline)
                    HStack { channelField("Channel A",value:$left); Image(systemName:"arrow.left.arrow.right").foregroundStyle(DeskPalette.accent); channelField("Channel B",value:$right) }
                    Toggle("Only differences",isOn:$onlyDifferences)
                    Button("Refresh comparison") { refresh() }.disabled(!model.ready || a == nil || b == nil)
                    Text("Read-only. This does not select channels or change output. Different fixture profiles may have different parameter ranges.").font(.caption).foregroundStyle(.secondary)
                }.deskCard()
                if !model.ready { Label("Disconnected · cached values may be stale",systemImage:"wifi.slash").font(.caption).foregroundStyle(.orange) }
                if let a, let b, model.fixtureParameters[a] != nil, model.fixtureParameters[b] != nil {
                    if rows.isEmpty { Text(onlyDifferences ? "No differences in the reported parameters." : "No parameters reported.").foregroundStyle(.secondary).deskCard() }
                    ForEach(rows) { row in
                        VStack(alignment:.leading,spacing:10) {
                            HStack { Text((row.left?.name ?? row.right?.name ?? row.id).replacingOccurrences(of:"_",with:" ")).font(.headline); Spacer(); if row.differs { Image(systemName:"circle.lefthalf.filled").foregroundStyle(DeskPalette.accent) } }
                            HStack(alignment:.top) { reading(row.left,channel:a); Spacer(); reading(row.right,channel:b) }
                        }.deskCard()
                    }
                } else { Text(a == nil || b == nil ? "Enter two valid channel numbers." : "Waiting for fixture replies. Get Params requires Eos 3.2 or later.").font(.subheadline).foregroundStyle(.secondary).deskCard() }
            }.padding()
        }.navigationTitle("Compare Fixtures")
        .onAppear { if let first = model.selectedChannels.first { left = String(first) }; if model.selectedChannels.count > 1 { right = String(model.selectedChannels[1]) }; refresh() }
        .onChange(of:left) { _ in refresh() }.onChange(of:right) { _ in refresh() }
        .onReceive(Timer.publish(every:3,on:.main,in:.common).autoconnect()) { _ in refresh() }
    }
    private func valid(_ text:String)->Int? { Int(text).flatMap { (1...999999).contains($0) ? $0 : nil } }
    private func refresh() { guard model.ready, let a, let b else { return }; model.requestParameters(a); if b != a { model.requestParameters(b) } }
    private func channelField(_ title:String,value:Binding<String>)->some View { VStack(alignment:.leading) { Text(title).font(.caption).foregroundStyle(.secondary); TextField(title,text:value).keyboardType(.numberPad).textFieldStyle(.roundedBorder) } }
    private func reading(_ parameter:EosFixtureParameter?,channel:Int)->some View {
        VStack(alignment:.leading,spacing:4) {
            Text("Channel \(channel)").font(.caption).foregroundStyle(.secondary)
            if let parameter { Text(String(format:"%.2f",parameter.level)).font(.title3.monospacedDigit()); Text(String(format:"Range %.2f to %.2f",parameter.minimum,parameter.maximum)).font(.caption2).foregroundStyle(.secondary) }
            else { Text("Not supported").font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

private struct NativeEmitterView: View {
    @EnvironmentObject var model: NativeRemoteModel
    private var channel: Int? { model.selectedChannels.first }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                if let channel {
                    HStack { Text("Channel \(channel)").font(.title2.weight(.semibold)); Spacer(); Button("Refresh") { model.requestEmitters(channel) }.disabled(!model.ready) }
                    Text("Adjusts this channel only. Levels and ranges come from the fixture’s emitter list.").font(.caption).foregroundStyle(.secondary)
                    if !model.ready { Label("Disconnected · values may be stale",systemImage:"wifi.slash").font(.caption).foregroundStyle(.orange) }
                    if let parameters = model.emitters[channel], !parameters.isEmpty {
                        ForEach(parameters) { parameter in NativeEmitterSlider(channel:channel,parameter:parameter).id("\(channel)/\(parameter.name)") }
                    } else { Text("No emitter data received. Select an LED fixture and refresh. Requires Eos 3.2 or later.").font(.subheadline).foregroundStyle(.secondary).deskCard() }
                } else { ContentUnavailableViewCompat(title:"Select an LED fixture",text:"Choose a channel on the console or in Quick Control to see its individual emitters.",symbol:"lightbulb") }
            }.padding()
        }.navigationTitle("LED Emitters")
        .onAppear { refresh() }.onChange(of:channel) { _ in refresh() }
        .onReceive(Timer.publish(every:3,on:.main,in:.common).autoconnect()) { _ in refresh() }
    }
    private func refresh() { if model.ready, let channel { model.requestEmitters(channel) } }
}

private struct NativeEmitterSlider: View {
    @EnvironmentObject var model: NativeRemoteModel
    let channel: Int
    let parameter: EosFixtureParameter
    @State private var value: Double
    @State private var dirty = false
    @State private var editing = false
    @State private var context: UUID?
    init(channel:Int,parameter:EosFixtureParameter) { self.channel = channel; self.parameter = parameter; _value = State(initialValue:parameter.level) }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(parameter.name.replacingOccurrences(of:"_",with:" ")).font(.headline); Spacer(); Text(String(format:"%.2f",value)).monospacedDigit().foregroundStyle(DeskPalette.accent) }
            if parameter.minimum < parameter.maximum {
                Slider(value:Binding(get:{ min(max(value,parameter.minimum),parameter.maximum) },set:{ value = $0; dirty = true; if context == nil { context = model.session } }),in:parameter.minimum...parameter.maximum,onEditingChanged:{ editing = $0; if $0 { context = model.session } else { apply() } }).accessibilityLabel(parameter.name)
            }
            HStack { Text(String(format:"Range %.2f to %.2f",parameter.minimum,parameter.maximum)).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Set") { apply() }.disabled(!dirty) }
            Text(String(format:"Reported %.2f",parameter.level)).font(.caption2).foregroundStyle(.secondary)
        }.deskCard().disabled(!model.ready || model.selectedChannels.first != channel)
        .onChange(of:parameter.level) { level in if !editing && !dirty { value = level } }
        .onChange(of:model.session) { _ in dirty = false; editing = false; context = nil; value = parameter.level }
    }
    private func apply() {
        guard dirty, model.ready, model.selectedChannels.first == channel, context == model.session else { return }
        model.send("/eos/chan/\(channel)/param/\(parameter.oscName)",[value]); dirty = false; context = nil
    }
}

private struct ContentUnavailableViewCompat: View {
    let title:String
    let text:String
    let symbol:String
    var body: some View { VStack(spacing:12) { Image(systemName:symbol).font(.system(size:32)).foregroundStyle(DeskPalette.accent); Text(title).font(.headline); Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth:.infinity).padding(.vertical,30).deskCard() }
}

private struct NativeConsoleHealthView: View {
    @EnvironmentObject var model: NativeRemoteModel
    private var users: [EosConsoleUser] { EosConsoleUser.parse(model.feedback["/eos/out/get/userlist"] ?? []) }
    private var healthFresh: Bool { model.online && model.healthReceivedAt.map { Date().timeIntervalSince($0) < 15 } == true }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                HStack { Label(model.online ? "Console responding" : "Console not verified",systemImage:model.online ? "checkmark.circle" : "wifi.slash").foregroundStyle(model.online ? Color.green : Color.orange); Spacer(); Button("Refresh") { model.requestDiagnostics() }.disabled(!model.ready) }
                VStack(spacing:12) {
                    field("Eos",model.softwareVersion.isEmpty ? "Not reported" : model.softwareVersion)
                    field("Round trip",model.latency.map { "\($0) ms" } ?? "Not measured")
                    field("OSC user",model.oscUser.map(String.init) ?? "Not reported")
                    field("Selection",model.independentUser ? "Independent app user" : "Follow console user")
                    if let date = model.healthReceivedAt { HStack { Text("Processor report").foregroundStyle(.secondary); Spacer(); Text(date,style:.time) }.font(.subheadline) }
                }.deskCard()
                VStack(alignment:.leading,spacing:8) {
                    Text("Processor health").font(.headline)
                    Text("Shows the console’s reported summary, not fixture temperatures or physical lamp feedback. Refreshes every five seconds while this page is open.").font(.caption).foregroundStyle(.secondary)
                    Text(EosCapabilities.supportsHealthSubscriptions(model.softwareVersion) ? "Eos 3.3.5+ detected. This page uses documented processor queries for its health summary." : "Enhanced health subscriptions require Eos 3.3.5+. Available processor summaries are shown below.").font(.caption).foregroundStyle(.secondary)
                    if model.processors.isEmpty { Text(model.processorCount == 0 ? "No processors reported." : "No health reply yet. This console or version may not expose processor status.").font(.subheadline).padding(.top,6) }
                }.deskCard()
                ForEach(model.processors.values.sorted { $0.id < $1.id }) { processor in
                    VStack(alignment:.leading,spacing:12) {
                        HStack { Text(processor.label.isEmpty ? processor.name : processor.label).font(.headline); Spacer(); Text(healthFresh ? processor.statusText : "Stale").font(.caption.weight(.semibold)).foregroundStyle(processor.status == 0 && healthFresh ? Color.green : Color.orange) }
                        field("Device",processor.model); field("IP",processor.ip); field("Universes",processor.universes)
                        field("Role",processor.host ? "Host" : "Processor")
                        if processor.backup >= 0 { field("Backup ID",String(processor.backup)) }
                    }.deskCard()
                }
                VStack(alignment:.leading,spacing:12) {
                    Text("Connected users").font(.headline)
                    if users.isEmpty { Text("No user list received.").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(users) { user in HStack { Text("User \(user.id)").monospacedDigit(); Spacer(); VStack(alignment:.trailing) { Text(user.name); Text(user.console).font(.caption).foregroundStyle(.secondary) } }.font(.subheadline) }
                    if !model.text("/eos/out/get/session").isEmpty { Divider(); Text("Reported session").font(.caption).foregroundStyle(.secondary); Text(model.text("/eos/out/get/session")).font(.caption.monospaced()).textSelection(.enabled) }
                }.deskCard()
            }.padding()
        }.navigationTitle("Console Health")
        .onAppear { model.requestDiagnostics() }
        .onChange(of:model.ready) { ready in if ready { model.requestDiagnostics() } }
        .onReceive(Timer.publish(every:5,on:.main,in:.common).autoconnect()) { _ in if model.ready { model.requestDiagnostics() } }
    }
    private func field(_ title:String,_ value:String)->some View { HStack(alignment:.top) { Text(title).foregroundStyle(.secondary); Spacer(); Text(value.isEmpty ? "Not reported" : value).multilineTextAlignment(.trailing) }.font(.subheadline) }
}


// Labels always come from the active OSC user; no guessed function mapping.
private struct NativeSoftkeysView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @Environment(\.verticalSizeClass) private var sizeClass
    @State private var page = 0
    private func label(_ index: Int) -> String { model.text("/eos/out/softkey/\(index)").trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Softkeys").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(page == 0 ? "1–6 ›" : "7–12 ›") { page = 1 - page }
                    .font(.caption).accessibilityLabel("Switch softkey page")
            }
            if (1...12).allSatisfy({ label($0).isEmpty }) {
                Text(model.demoMode ? "Softkeys require live console context" : "Waiting for console softkeys")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 44)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: sizeClass == .compact ? 6 : 3), spacing: 6) {
                    ForEach((page * 6 + 1)...(page * 6 + 6), id: \.self) { index in
                        Button {
                            guard model.ready, !model.demoMode, !label(index).isEmpty else { return }
                            model.send("/eos/softkey/\(index)", [Float(1)])
                            model.send("/eos/softkey/\(index)", [Float(0)])
                        } label: {
                            Text(label(index).isEmpty ? "—" : label(index)).font(.system(size: 12, weight: .medium))
                                .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(DeskButtonStyle()).disabled(!model.ready || model.demoMode || label(index).isEmpty)
                    }
                }
            }
        }.onChange(of: model.session) { _ in page = 0 }
    }
}

private struct NativeMagicSheetView: View {
    @State private var importing = false
    @State private var image: UIImage?
    @State private var error: String?
    @AppStorage("element.magicSheet.name") private var name = "Magic Sheet"
    private var imageURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("magic-sheet.png") }
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.headline).lineLimit(1)
                    Text("Imported image · read-only").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Import image") { importing = true }.buttonStyle(.bordered)
            }.padding(.horizontal)
            if let image {
                MagicSheetZoomView(image: image).accessibilityLabel("Magic Sheet image. Pinch to zoom and drag to pan.")
                Text("Pinch to zoom · drag to pan · double-tap to fit").font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer()
                Image(systemName: "square.grid.3x3").font(.system(size: 48)).foregroundStyle(DeskPalette.accent)
                Text("Bring your Magic Sheet with you").font(.headline)
                Text("On Element, open the Magic Sheet editor’s import/export menu and save the sheet as an image. Transfer it to Files, then import it here.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
                Spacer()
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal) }
            Text("Image contents do not update live. Import again after changing the console layout.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom)
        }.navigationTitle("Magic Sheets")
        .onAppear { image = UIImage(contentsOfFile: imageURL.path) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.png, .jpeg], allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let resource = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (resource.fileSize ?? 0) <= 25_000_000 else { throw SheetImportError.tooLarge }
                let data = try Data(contentsOf: url)
                guard let imported = UIImage(data: data), imported.size.width * imported.size.height <= 40_000_000,
                      let png = imported.pngData() else { throw SheetImportError.invalid }
                try png.write(to: imageURL, options: .atomic)
                image = imported; name = url.deletingPathExtension().lastPathComponent; error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    private enum SheetImportError: LocalizedError {
        case tooLarge, invalid
        var errorDescription: String? { self == .tooLarge ? "Choose an image smaller than 25 MB." : "Choose a valid PNG or JPEG image up to 40 megapixels." }
    }
}

private struct MagicSheetZoomView: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 8
        scroll.delegate = context.coordinator
        let picture = UIImageView(); picture.contentMode = .scaleAspectFit
        scroll.addSubview(picture); context.coordinator.picture = picture
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.fit(_:)))
        tap.numberOfTapsRequired = 2; scroll.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let picture = context.coordinator.picture else { return }
        if picture.image !== image { scroll.setZoomScale(1, animated: false); picture.image = image }
        DispatchQueue.main.async {
            if scroll.zoomScale == 1 { picture.frame = scroll.bounds; scroll.contentSize = scroll.bounds.size }
        }
    }
    class Coordinator: NSObject, UIScrollViewDelegate {
        weak var picture: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
        @objc func fit(_ gesture: UITapGestureRecognizer) { (gesture.view as? UIScrollView)?.setZoomScale(1, animated: true) }
    }
}
