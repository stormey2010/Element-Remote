import Foundation
import Network
import Darwin
import UIKit

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
        connection.onMessage = { [weak self] message in
            guard let self else { return }
            switch message["type"] as? String {
            case "status":
                if !self.demoMode {
                    self.online = message["consoleOnline"] as? Bool ?? false
                    let nextReady = message["udpReady"] as? Bool ?? false
                    if self.ready != nextReady { self.session = UUID() }
                    self.ready = nextReady
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
        feedback = [:]; fixtures = [:]; selectedChannels = []; movementAvailable = false; colorAvailable = false
        practiceDesk = EosPracticeDesk()
        if enabled {
            connection.disconnect()
            try? practiceDesk.execute("Chan 1 Thru 12 At Full Enter")
            online = true
            ready = true
            softwareVersion = "2.9.3 (Test Mode)"
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
        if enabled { syncPracticeDesk() }
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
        if address == "/eos/out/cmd" || (address.hasPrefix("/eos/out/user/") && address.hasSuffix("/cmd")) {
            self.commandLine = values.first as? String ?? ""
            self.commandError = (values.dropFirst().first as? NSNumber)?.intValue == 1
        }
        if address == "/eos/out/active/chan" {
            activeChannels = values.map { String(describing: $0) }.joined(separator: " ")
            let next = EosSelectionContext.channels(from: activeChannels)
            if next != selectedChannels {
                selectedChannels = next; movementAvailable = false; colorAvailable = false; session = UUID()
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
        connection.sendBatch(messages)
    }

    func tap(_ address: String) {
        if demoMode {
            let parts = address.split(separator: "/").map(String.init)
            if parts.count == 4, parts[1] == "ds", parts[2] == "4", let n = Int(parts[3]), (1...32).contains(n) {
                practiceDesk.setColor([Double(n-1) / 32 * 360, 80]); syncPracticeDesk()
            }
            if parts.count == 4, parts[1] == "param" {
                practiceDesk.extreme(parts[2], maximum: parts[3] == "max")
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

    func goToCue(_ cue: String) {
        guard let message = try? EosCommands.goToCue(cue) else { error = "Enter a valid cue number"; return }
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

private let selectionKeys: [ConsoleKey] = [.init("Macro", "macro"), .init("Effect", "effect"), .init("Recall From", "recall_from"), .init("Park", "park"), .init("Select Last", "select_last"), .init("Select Man", "select_manual"), .init("Last", "last"), .init("Next", "next")]

private enum DeskPalette {
    static var nightVision: Bool { UserDefaults.standard.bool(forKey: "element.nightVision") }
    static var background: Color { nightVision ? Color(red: 0.05, green: 0.01, blue: 0.01) : Color(white: 0.055) }
    static var surface: Color { nightVision ? Color(red: 0.12, green: 0.02, blue: 0.02) : Color(white: 0.095) }
    static var raised: Color { nightVision ? Color(red: 0.20, green: 0.04, blue: 0.04) : Color(white: 0.155) }
    static var field: Color { nightVision ? Color(red: 0.08, green: 0.01, blue: 0.01) : Color(white: 0.075) }
    static var accent: Color { nightVision ? Color(red: 1.0, green: 0.25, blue: 0.25) : Color(red: 0.88, green: 0.76, blue: 0.53) }
    static var rule: Color { Color.white.opacity(0.09) }
}

private struct DeskButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var enabled
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
    private let radius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(accent == .gray ? Color.white.opacity(0.92) : tint)
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(configuration.isPressed ? DeskPalette.raised : DeskPalette.surface)
                if accent != .gray {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(tint.opacity(prominent ? 0.22 : reduceTransparency ? 0.10 : 0.07))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(accent == .gray ? DeskPalette.rule : tint.opacity(prominent ? 0.45 : 0.22), lineWidth: 1)
            }
            .opacity(enabled ? 1 : 0.38)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

extension View {
    @ViewBuilder func deskCard() -> some View {
        self.padding(16)
            .background(DeskPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(DeskPalette.rule, lineWidth: 1) }
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
                .preferredColorScheme(.dark)
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
        .padding(.top, horizontalSizeClass == .regular ? 56 : 0)
        .background(DeskPalette.background.ignoresSafeArea())
        .alert("Console", isPresented: Binding(get: { !model.error.isEmpty }, set: { if !$0 { model.error = "" } })) {
            Button("OK", role: .cancel) { model.error = "" }
        } message: { Text(model.error) }
    }
    private func screenHeader(_ title: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title).font(.system(size: 34, weight: .bold)).tracking(-1)
                Spacer()
                if title != "More" && title != "Console" {
                    Button { showSettings = true } label: {
                        Image(systemName: "link").font(.system(size: 20)).frame(width: 38, height: 38)
                            .background(.white.opacity(0.07), in: Circle())
                    }.accessibilityLabel("Connections")
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 23)).frame(width: 36, height: 38)
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
                        Text("Command").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.demoMode {
                            Text("TEST MODE").font(.system(size: 9, weight: .semibold)).tracking(0.8)
                                .foregroundStyle(DeskPalette.accent).padding(.horizontal, 7).padding(.vertical, 3)
                                .background(DeskPalette.accent.opacity(0.1), in: Capsule())
                        }
                    }.padding(.horizontal, 8)
                    NativeCommandReadout()
                        .padding(12)
                        .background(DeskPalette.raised.opacity(0.6), in: RoundedRectangle(cornerRadius: 13))
                        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(model.demoMode ? DeskPalette.accent.opacity(0.8) : DeskPalette.rule) }
                }.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
                .fixedSize(horizontal: false, vertical: true)
            }
        }.background(DeskPalette.background).fixedSize(horizontal: false, vertical: true)
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
    private let keys = ["7", "8", "9", "Thru", "4", "5", "6", "+", "1", "2", "3", "−", "Clear", "0", "⌫"]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("CHANNELS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(entry.isEmpty ? "Enter channel numbers" : entry).font(.system(size: 28, weight: .medium, design: .monospaced)).foregroundStyle(entry.isEmpty ? Color.secondary : Color.primary).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).accessibilityLabel("Channel selection: " + (entry.isEmpty ? "empty" : entry))
                    Text("e.g. 42 or 1 Thru 5 + 12").font(.caption).foregroundStyle(.secondary)
                }.deskCard()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 4), spacing: 7) {
                    ForEach(keys, id: \.self) { key in
                        Button { edit(key) } label: { Text(key).font(.system(size: 22, weight: .medium)).frame(maxWidth: .infinity, minHeight: 64) }.buttonStyle(DeskButtonStyle()).accessibilityLabel(key == "⌫" ? "Backspace" : key)
                    }
                }
                Button { enter() } label: { Text("Enter").font(.title3.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 62) }.buttonStyle(DeskButtonStyle(accent: .green, prominent: true)).disabled(entry.isEmpty)
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CHANNELS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(selection.expression).font(.title2.monospacedDigit().weight(.semibold))
                    Text("\(selection.channels.count) selected").font(.caption).foregroundStyle(.secondary)
                    if !model.ready { Text("Disconnected · connect to use quick actions").font(.subheadline).foregroundStyle(.orange) }
                }.deskCard()
                VStack(alignment: .leading, spacing: 14) {
                    HStack { Text("Brightness").font(.headline); Spacer(); Text(brightnessTouched ? "\(Int(brightness))%" : "Set a level").monospacedDigit().foregroundStyle(.secondary) }
                    Slider(value: Binding(get: { brightness }, set: { value in brightness = value; applyLevel() }), in: 0...100, step: 1, onEditingChanged: { editing in
                        if editing { levelSession = model.session }
                        else { applyLevel(force: true); levelSession = nil; model.haptic() }
                    }).accessibilityLabel("Brightness for channels " + selection.expression)
                    HStack(spacing: 7) {
                        ForEach([0,25,50,75,100], id: \.self) { value in
                            Button(value == 0 ? "Out" : value == 100 ? "Full" : "\(value)%") { brightness = Double(value); applyLevel(force: true); model.haptic() }.frame(maxWidth: .infinity)
                        }
                    }.buttonStyle(.bordered)
                    Text("Applies to all selected channels.").font(.caption).foregroundStyle(.secondary)
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
                HStack {
                    NavigationLink("Movement") { NativeWheelsView() }
                    Spacer()
                    NavigationLink("Color") { NativeColorView() }
                }.font(.subheadline).padding(.vertical, 8)
            }.padding()
        }.navigationTitle("Quick actions")
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
                                if !fixture.notes.isEmpty { Text(fixture.notes).font(.subheadline).foregroundStyle(.secondary) }
                            }.deskCard()
                        }
                    }
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
            ScrollView {
                VStack(spacing: 16) {
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
                            Label("Movement", systemImage: "move.3d").frame(maxWidth: .infinity, minHeight: 48)
                        }
                        NavigationLink(value: RemoteTool.color) {
                            Label("Color", systemImage: "paintpalette").frame(maxWidth: .infinity, minHeight: 48)
                        }
                    }.font(.subheadline).buttonStyle(DeskButtonStyle())
                    DisclosureGroup("More keys") {
                        grid(selectionKeys + [.init("Highlight", "highlight"), .init("Delay", "delay"), .init("Time", "time"), .init("Home", "home"), .init("Level", "level")], count: 3, height: 44)
                    }.font(.subheadline).foregroundStyle(.secondary).padding(.top, 36)
                }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 24)
            }
        }
    }
    private func grid(_ keys: [ConsoleKey], count: Int, height: Double) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: count), spacing: 5) {
            ForEach(keys) { key in deskKey(key, height: height) }
        }
    }
    private func deskKey(_ key: ConsoleKey, height: Double) -> some View {
        Button { model.key(key.address) } label: {
            Text(key.title).font(.system(size: Int(key.title) != nil ? 25 : 16, weight: .medium, design: .default)).minimumScaleFactor(0.7).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: height).padding(.horizontal, 2)
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
                grid
                DisclosureGroup("Adjust selected faders") { controls }
            }.padding(16)
        }
            .onAppear { if model.ready { model.send("/eos/fader/1/config/1/40") } }
            .onChange(of: model.ready) { ready in if ready { model.send("/eos/fader/1/config/1/40") } }
    }
    private var grid: some View {
        LazyVStack(spacing: 0) {
            ForEach((bank*10+1)...(bank*10+10), id: \.self) { n in
                VStack(spacing: 3) {
                    HStack(spacing: 12) {
                        Button {
                            model.haptic()
                            if model.selection.contains(n) { model.selection.remove(n) } else { model.selection.insert(n) }
                        } label: {
                            Text("\(n)").font(.system(size: 18)).frame(width: 32, height: 32)
                                .background(model.selection.contains(n) ? DeskPalette.accent.opacity(0.3) : Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).accessibilityLabel("Select fader \(n)").accessibilityAddTraits(model.selection.contains(n) ? .isSelected : [])
                        Text(model.text("/eos/out/fader/1/\(n)/name").isEmpty ? "Fader \(n)" : model.text("/eos/out/fader/1/\(n)/name")).font(.body).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(readout(n)).font(.body.monospacedDigit())
                        Button { bump([n]) } label: { Label("Bump", systemImage: "bolt.fill").font(.caption).padding(.horizontal, 12).frame(minHeight: 32) }
                            .buttonStyle(DeskButtonStyle()).disabled(!model.ready)
                    }
                    Slider(value: Binding(get: { faderValue(n) * 100 }, set: { value in setFader(n, value / 100) }), in: 0...100, step: 1, onEditingChanged: { editing in
                        if editing { individualSessions[n] = model.session }
                        else { individualSessions.removeValue(forKey: n) }
                    })
                        .accessibilityLabel("Fader \(n) level").disabled(!model.ready)
                }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
                if n != bank*10+10 { Divider().padding(.horizontal, 12) }
            }
        }.background(DeskPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(DeskPalette.rule) }
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
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "list.bullet")
                    Text("Cue List 1")
                    Spacer()
                }.frame(maxWidth: .infinity, alignment: .leading).deskCard()

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("NOW").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                        Spacer()
                        Text(model.isCueFading ? "Fading" : "Ready").font(.caption).foregroundStyle(DeskPalette.accent)
                    }
                    Text(model.activeCueText.isEmpty ? "No cue feedback yet" : model.activeCueText)
                        .font(.system(size: 24, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                    ProgressView(value: model.activeCuePercent).tint(DeskPalette.accent)
                    HStack {
                        Text("NEXT").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                        Text(model.pendingCueText).font(.subheadline).lineLimit(2)
                        Spacer()
                    }
                }.deskCard()
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
                            .padding(12).background(DeskPalette.field, in: RoundedRectangle(cornerRadius: 10))
                        Button("Go") { model.goToCue(cue); cue = "" }.buttonStyle(.bordered)
                            .disabled((try? EosCommands.goToCue(cue)) == nil || !model.ready)
                    }
                    Button("Go to cue 0 · Out") { model.goToCue("0") }.font(.subheadline).disabled(!model.ready)
                }.deskCard()
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
            }.padding(16)
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
                Toggle("Test Mode", isOn: Binding(get: { model.demoMode }, set: { discovery.stop(); model.toggleDemoMode($0); model.haptic() })).tint(.yellow)
            } footer: { Text("Practice with the sample show. No commands reach a console.") }
        }.navigationTitle("Settings")
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

private struct NativeMoreView: View {
    @EnvironmentObject var model: NativeRemoteModel
    @EnvironmentObject var discovery: ConsoleDiscovery
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Control") {
                    row("Quick Control", "Select channels and adjust levels", "bolt.fill") { NativeQuickControlView().navigationTitle("Quick Control") }
                    rule
                    row("Movement", "Wheels, pan & tilt", "move.3d") { toolPage { NativeWheelsView() } }
                    rule
                    row("Color", "Picker & palettes", "paintpalette") { toolPage { NativeColorView() } }
                    rule
                    row("Beam & Optics", "Zoom, edge, iris & fixture optics", "light.beacon.max") { toolPage { NativeWheelsView(beamOnly: true) } }
                }
                section("Utilities") {
                    row("Patch", "Fixture information", "point.3.connected.trianglepath.dotted") { NativePatchView() }

                }
            }.padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 20)
        }
    }
    private var rule: some View { Divider().padding(.leading, 44) }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium)).padding(.leading, 6)
            VStack(spacing: 0, content: content).padding(.horizontal, 14)
                .background(DeskPalette.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(DeskPalette.rule) }
        }
    }
    private func toolPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            NativeCommandReadout().padding(12)
                .background(DeskPalette.surface, in: RoundedRectangle(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(model.demoMode ? DeskPalette.accent : DeskPalette.rule) }
                .padding(.horizontal, 18).padding(.bottom, 8)
            content()
        }
    }

    private func row<Destination: View>(_ title: String, _ subtitle: String, _ icon: String, @ViewBuilder destination: () -> Destination) -> some View {
        NavigationLink(destination: destination().toolbar(.visible, for: .navigationBar)) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 20, weight: .regular))
                    .foregroundStyle(DeskPalette.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain).simultaneousGesture(TapGesture().onEnded { model.haptic() })
    }
}

private enum WheelCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case position = "Position"
    case beam = "Beam"
    case optics = "Optics"
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

    private var paramsForCategory: [String] {
        switch category {
        case .all:
            return ["intens", "pan", "tilt", "zoom", "edge", "iris", "focus", "color_temp", "diffusn"]
        case .position:
            return ["pan", "tilt"]
        case .beam:
            return ["zoom", "edge", "iris", "focus"]
        case .optics:
            return ["color_temp", "tint", "diffusn", "gobo_rot"]
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
                
                ForEach(paramsForCategory, id: \.self) { param in
                    DeskWheel(param: param, fine: fine)
                }
                
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
            }.padding()
        }
        .navigationTitle(beamOnly ? "Beam & Optics" : "Movement")
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
        default: return param.capitalized
        }
    }
    
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Min") { tap("/eos/param/\(param)/min") }
                Spacer()
                VStack(spacing: 2) { Text(title).font(.subheadline.weight(.medium)); Text(model.feedback["/eos/out/param/" + param]?.first.map { String(describing: $0) } ?? "No parameter feedback").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Spacer()
                Button("Max") { tap("/eos/param/\(param)/max") }
            }.font(.caption).tint(Color.gray)
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
        }.padding(12).background(DeskPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: model.ready) { _ in previous = 0; residual = 0 }
    }
    private func adjust(_ value: Int, continuous: Bool = false) { model.haptic(continuous: continuous); model.send("/eos/wheel/\(fine ? "fine" : "coarse")/\(param)", [value]) }
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Color library").font(.headline)
                    TextField("Search color palettes", text: $filter).padding(12).background(DeskPalette.field, in: RoundedRectangle(cornerRadius: 10))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                        ForEach(1...32, id: \.self) { n in
                            let label = model.text("/eos/out/ds/4/\(n)").isEmpty ? "Color \(n)" : model.text("/eos/out/ds/4/\(n)")
                            if filter.isEmpty || label.localizedCaseInsensitiveContains(filter) {
                                Button { model.haptic(); model.tap("/eos/ds/4/\(n)") } label: { Text(label).font(.caption).lineLimit(2).frame(maxWidth: .infinity, minHeight: 48) }.buttonStyle(DeskButtonStyle())
                            }
                        }
                    }
                }.deskCard()
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
                        }
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
