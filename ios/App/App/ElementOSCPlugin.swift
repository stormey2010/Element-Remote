import Foundation
import Capacitor
import Network
import UIKit

private struct ConsoleSettings {
    var displayName = "Element"
    var consoleHost = ""
    var transport = "tcp"
    var consolePort = 3032
    var receivePort = 8001
    var dictionary: [String: Any] { ["displayName": displayName, "consoleHost": consoleHost, "transport": transport, "consolePort": consolePort, "receivePort": receivePort] }
    static func parse(_ value: [String: Any]) throws -> ConsoleSettings {
        var result = ConsoleSettings()
        result.displayName = String((value["displayName"] as? String ?? "Element").prefix(64))
        result.consoleHost = (value["consoleHost"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        result.transport = value["transport"] as? String ?? "tcp"
        guard ["tcp", "third-party", "udp"].contains(result.transport) else { throw OSCWireError.invalid("Choose a valid connection mode.") }
        guard result.consoleHost.isEmpty || IPv4Address(result.consoleHost) != nil else { throw OSCWireError.invalid("Enter the console’s IPv4 address.") }
        func port(_ key: String, fallback: Int) throws -> Int {
            let raw = value[key].map { String(describing: $0) } ?? String(fallback)
            guard let number = Int(raw), (1024...65535).contains(number) else { throw OSCWireError.invalid("Ports must be between 1024 and 65535.") }
            return number
        }
        result.consolePort = try port("consolePort", fallback: result.transport == "udp" ? 8000 : result.transport == "tcp" ? 3032 : 3037)
        result.receivePort = try port("receivePort", fallback: 8001)
        return result
    }
}

@objc(ElementOSCPlugin)
public class ElementOSCPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ElementOSCPlugin"
    public let jsName = "ElementOSC"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getConfig", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "configure", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "connect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disconnect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "send", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendBatch", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "haptic", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setKeepAwake", returnType: CAPPluginReturnPromise)
    ]
    private let queue = DispatchQueue(label: "app.elementremote.osc", qos: .userInteractive)
    private let defaultsKey = "element.console.settings.v1"
    private var settings = ConsoleSettings()
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
    private var pingSent = Date.distantPast
    private var lastPong = Date.distantPast
    private var latency: Int?
    private var lastError = ""
    private var observers: [NSObjectProtocol] = []
    private var held: Set<String> = []
    private var keepAwake = false
    private var ready: Bool { connectionReady && (settings.transport != "udp" || listenerReady) }
    private var framing: OSCStreamDecoder.Framing { settings.transport == "third-party" ? .slip : .packetLength }

    public override func load() {
        if let saved = UserDefaults.standard.dictionary(forKey: defaultsKey), let parsed = try? ConsoleSettings.parse(saved) { settings = parsed }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.async { [weak self] in self?.suspend() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.queue.async { [weak self] in guard let self else { return }; self.active = true; self.startConnection() }
            DispatchQueue.main.async { [weak self] in UIApplication.shared.isIdleTimerDisabled = self?.keepAwake ?? false }
        })
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in guard let self else { return }; if self.active { self.ping(); self.emitStatus() } }
        timer.resume(); pingTimer = timer
    }
    deinit { retry?.cancel(); pingTimer?.cancel(); connection?.cancel(); listener?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    private func emit(_ message: [String: Any]) {
        DispatchQueue.main.async { [weak self] in self?.notifyListeners("message", data: message) }
    }
    private func emitStatus() {
        emit(["type": "status", "bridge": true, "native": true, "configured": !settings.consoleHost.isEmpty,
              "consoleOnline": active && ready && Date().timeIntervalSince(lastPong) < 25,
              "udpReady": ready && active, "error": lastError, "latencyMs": latency.map { $0 as Any } ?? NSNull(), "config": settings.dictionary])
    }
    @objc func getConfig(_ call: CAPPluginCall) { queue.async { call.resolve(self.settings.dictionary) } }
    @objc func configure(_ call: CAPPluginCall) {
        guard let value = call.options["config"] as? [String: Any] else { call.reject("Missing console settings"); return }
        do {
            let parsed = try ConsoleSettings.parse(value)
            queue.async { self.releaseHeld(); self.settings = parsed; UserDefaults.standard.set(parsed.dictionary, forKey: self.defaultsKey); self.active = true; self.startConnection(); call.resolve(parsed.dictionary) }
        } catch { call.reject(error.localizedDescription) }
    }
    @objc func connect(_ call: CAPPluginCall) { queue.async { self.active = true; self.startConnection(); call.resolve() } }
    @objc func disconnect(_ call: CAPPluginCall) { queue.async { self.suspend(); call.resolve() } }
    @objc func send(_ call: CAPPluginCall) {
        guard let address = call.getString("address"), let parameters = call.options["parameters"] as? [Any] else { call.reject("Invalid OSC message"); return }
        do {
            let data = try OSCCodec.encode(OSCMessage(address: address, parameters: parameters))
            queue.async {
                guard self.active, self.ready else { call.reject("Console is disconnected. Commands are not queued."); return }
                if self.isMomentary(address), let edge = parameters.first as? NSNumber {
                    if edge.doubleValue == 1 { self.held.insert(address) } else if edge.doubleValue == 0 { self.held.remove(address) }
                }
                self.write(data); call.resolve(["sent": true])
            }
        } catch { call.reject(error.localizedDescription) }
    }
    @objc func sendBatch(_ call: CAPPluginCall) {
        guard let messages = call.options["messages"] as? [[String: Any]], !messages.isEmpty, messages.count <= 64 else { call.reject("Invalid OSC batch"); return }
        do {
            let packets: [(String, [Any], Data)] = try messages.map { value in
                guard let address = value["address"] as? String, let parameters = value["parameters"] as? [Any] else { throw OSCWireError.invalid("Invalid OSC batch message") }
                return (address, parameters, try OSCCodec.encode(OSCMessage(address: address, parameters: parameters)))
            }
            queue.async {
                guard self.active, self.ready else { call.reject("Console is disconnected. Commands are not queued."); return }
                for (address, parameters, data) in packets {
                    if self.isMomentary(address), let edge = parameters.first as? NSNumber {
                        if edge.doubleValue == 1 { self.held.insert(address) } else if edge.doubleValue == 0 { self.held.remove(address) }
                    }
                    self.write(data)
                }
                call.resolve(["sent": packets.count])
            }
        } catch { call.reject(error.localizedDescription) }
    }
    @objc func haptic(_ call: CAPPluginCall) { DispatchQueue.main.async { UISelectionFeedbackGenerator().selectionChanged(); call.resolve() } }
    @objc func setKeepAwake(_ call: CAPPluginCall) {
        let enabled = call.getBool("enabled") ?? false
        DispatchQueue.main.async { self.keepAwake = enabled; UIApplication.shared.isIdleTimerDisabled = enabled; call.resolve() }
    }
    private func isMomentary(_ address: String) -> Bool { address.hasPrefix("/eos/key/") || (address.hasPrefix("/eos/sub/") && address.hasSuffix("/fire")) }
    private func releaseHeld() {
        for address in held { if let data = try? OSCCodec.encode(OSCMessage(address: address, parameters: [0.0])) { write(data) } }
        held.removeAll()
    }
    private func stop() {
        generation += 1; retry?.cancel(); retry = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        incoming.forEach { $0.cancel() }; incoming.removeAll()
        connectionReady = false; listenerReady = false; lastPong = .distantPast; latency = nil
    }
    private func suspend() {
        releaseHeld(); active = false; emit(["type": "reset"]); emitStatus()
        let token = generation
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in guard let self, !self.active, token == self.generation else { return }; self.stop(); self.emitStatus() }
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
    }
    private func startConnection() {
        stop(); lastError = ""; emit(["type": "reset"])
        guard active, !settings.consoleHost.isEmpty else { emitStatus(); return }
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
        outgoing.stateUpdateHandler = { [weak self] state in
            guard let self, token == self.generation else { return }
            switch state {
            case .ready:
                self.connectionReady = true; self.lastError = ""; self.becameReady()
                if self.settings.transport != "udp" { self.receiveStream(outgoing, token: token) } else { self.receiveDatagram(outgoing, token: token) }
            case .failed(let error): self.fail(error.localizedDescription, token: token)
            case .waiting(let error): self.connectionReady = false; self.lastError = "Waiting for network. Check Wi-Fi and Local Network permission. \(error.localizedDescription)"; self.emitStatus()
            default: break
            }
        }
        outgoing.start(queue: queue); emitStatus()
    }
    private func becameReady() { if ready { releaseHeld() }; emitStatus(); if ready { ping() } }
    private func fail(_ reason: String, token: Int) {
        guard token == generation, active else { return }
        stop(); lastError = reason; emit(["type": "reset"]); emitStatus()
        let work = DispatchWorkItem { [weak self] in guard let self, self.active else { return }; self.startConnection() }
        retry = work; queue.asyncAfter(deadline: .now() + 3, execute: work)
    }
    private func write(_ packet: Data) {
        guard active, ready, let outgoing = connection else { return }
        let data = settings.transport == "udp" ? packet : OSCStreamDecoder.frame(packet, framing)
        let token = generation
        outgoing.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }; self.queue.async { self.fail(error.localizedDescription, token: token) }
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
            if message.address == "/eos/out/ping", message.parameters.contains(where: { ($0 as? String) == pingToken }) {
                lastPong = Date(); latency = Int(lastPong.timeIntervalSince(pingSent) * 1000); emitStatus(); continue
            }
            let safe = message.parameters.map { value -> Any in if let number = value as? NSNumber, !number.doubleValue.isFinite { return NSNull() }; return value }
            emit(["type": "osc", "address": message.address, "parameters": safe])
        }
    }
    private func ping() {
        guard active, ready else { return }
        pingSent = Date(); pingToken = "element-ios-\(UUID().uuidString)"
        if let data = try? OSCCodec.encode(OSCMessage(address: "/eos/ping", parameters: [pingToken])) { write(data) }
    }
}
