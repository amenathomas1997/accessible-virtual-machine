// ReceiverLink.swift
// AVM Receiver
//
// The connection to AVM on the Mac (2026-11-04): pairing, the list of
// machines, one machine open, its sound and picture coming in, keys going out.
// The wire is ReceiverWire.swift, shared with the Mac.

import Combine
import Foundation
import Network
import Security
import UIKit

struct ReceiverMachine: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: String
    let state: String

    var isRunning: Bool { state == "running" }
    var isMac: Bool { kind.lowercased().contains("macos") }
}

/// What pairing leaves: in the keychain, this device only, readable while the
/// screen is locked so a machine's sound carries on and can reconnect.
struct ReceiverPairing: Codable, Equatable {
    var device: String
    var key: Data
    var macName: String
    /// Bonjour's name, for at home; this is the Mac's own name.
    var serviceName: String?
    /// What to try by address: a Tailscale address or a .local name.
    var address: String?

    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "AVM Receiver",
                                               kSecAttrAccount as String: "pairing"]

    static func load() -> ReceiverPairing? {
        var request = query
        request[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ReceiverPairing.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        SecItemDelete(Self.query as CFDictionary)
        var add = Self.query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func forget() { SecItemDelete(query as CFDictionary) }
}

/// A Mac showing a pairing code on this network.
struct ReceiverFoundMac: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

@MainActor
final class ReceiverLink: ObservableObject {
    enum Status: Equatable {
        case notPaired, connecting, connected, offline(String)
    }

    @Published private(set) var status: Status
    @Published private(set) var pairing: ReceiverPairing?
    @Published private(set) var machines: [ReceiverMachine] = []
    @Published private(set) var openMachineID: String?
    @Published private(set) var picture: UIImage?
    @Published var showsPicture = true
    @Published private(set) var foundMacs: [ReceiverFoundMac] = []

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "AVM Receiver link", qos: .userInteractive)
    private var pending: [Int: CheckedContinuation<[String: Any], Never>] = [:]
    private var nextID = 1
    private var attempt = 0
    private var retry: Task<Void, Never>?
    private var listRefresh: Task<Void, Never>?
    private var browser: NWBrowser?
    private let sound = ReceiverSoundPlayer()
    private var isActive = true

    init() {
        let saved = ReceiverPairing.load()
        pairing = saved
        status = saved == nil ? .notPaired : .connecting
        if saved != nil { connect() }
    }

    var openMachine: ReceiverMachine? { machines.first { $0.id == openMachineID } }

    private static func say(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: Finding a Mac to pair with

    func startLookingForMacs() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let made = NWBrowser(for: .bonjour(type: ReceiverWire.pairingBonjourType, domain: nil), using: parameters)
        made.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> ReceiverFoundMac? in
                if case .service(let name, _, _, _) = result.endpoint { return ReceiverFoundMac(name: name, endpoint: result.endpoint) }
                return nil
            }
            Task { @MainActor in self?.foundMacs = found.sorted { $0.name < $1.name } }
        }
        made.start(queue: .main)
        browser = made
    }

    func stopLookingForMacs() {
        browser?.cancel()
        browser = nil
        foundMacs = []
    }

    // MARK: Pairing

    /// nil on success, otherwise what to tell the person.
    func pair(endpoint: NWEndpoint, address: String?, serviceName: String?, code: String) async -> String? {
        guard ReceiverWire.normalized(code: code).count == 12 else {
            return "The code has twelve letters and numbers. AVM on your Mac shows it in Settings, under iPhone Receiver."
        }
        // PBKDF2 takes a moment on purpose: not on the main thread.
        let key = await Task.detached { ReceiverWire.pairingKey(code: code) }.value
        let parameters = ReceiverWire.parameters(keys: [(ReceiverWire.pairingIdentity, key)])
        let made = NWConnection(to: endpoint, using: parameters)
        let reply = await Self.oneRequest(on: made, ["op": "pair", "name": UIDevice.current.name])
        guard reply["ok"] as? Bool == true, let device = reply["device"] as? String,
              let deviceKey = (reply["key"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            return reply["message"] as? String ?? "That didn't work. Check the code, and that pairing is still open on your Mac."
        }
        let macName = reply["mac"] as? String ?? "Mac"
        let saved = ReceiverPairing(device: device, key: deviceKey, macName: macName, serviceName: serviceName ?? macName, address: address)
        saved.save()
        pairing = saved
        stopLookingForMacs()
        Self.say("Paired with \(macName).")
        connect()
        return nil
    }

    private static func oneRequest(on connection: NWConnection, _ request: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { (done: CheckedContinuation<[String: Any], Never>) in
            let queue = DispatchQueue(label: "AVM Receiver pairing")
            var finished = false
            func finish(_ reply: [String: Any]) {
                guard !finished else { return }
                finished = true
                connection.cancel()
                done.resume(returning: reply)
            }
            let failure: [String: Any] = ["ok": false, "message": "That didn't work. Check the code, and that pairing is still open on your Mac."]
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var ask = request
                    ask["id"] = 1
                    connection.send(content: ReceiverWire.message(ask), completion: .contentProcessed { _ in })
                    var reader = ReceiverWire.FrameReader()
                    func receive() {
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                            if let data {
                                for frame in reader.add(data) where frame.kind == .message {
                                    finish((try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any] ?? failure)
                                }
                            }
                            if isComplete || error != nil { finish(failure) } else if !finished { receive() }
                        }
                    }
                    receive()
                case .failed, .waiting: finish(failure)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { finish(failure) }
        }
    }

    func unpair() {
        disconnect()
        ReceiverPairing.forget()
        pairing = nil
        machines = []
        status = .notPaired
    }

    func setAddress(_ address: String) {
        guard var saved = pairing else { return }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.address = trimmed.isEmpty ? nil : trimmed
        saved.save()
        pairing = saved
        connect()
    }

    // MARK: Connecting

    /// At home by Bonjour's name; if that doesn't answer soon, by address.
    func connect() {
        guard let pairing else { return }
        disconnect()
        status = .connecting
        attempt += 1
        let thisAttempt = attempt
        var places: [NWEndpoint] = []
        if let name = pairing.serviceName {
            places.append(.service(name: name, type: ReceiverWire.bonjourType, domain: "local.", interface: nil))
        }
        if let address = pairing.address {
            places.append(.hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: ReceiverWire.port)!))
        }
        retry = Task { [weak self] in
            for place in places {
                guard let self, !Task.isCancelled, thisAttempt == self.attempt else { return }
                if await self.tryConnecting(to: place, pairing: pairing, attempt: thisAttempt) { return }
            }
            guard let self, !Task.isCancelled, thisAttempt == self.attempt else { return }
            let text = pairing.address == nil
                ? "Can't reach \(pairing.macName). AVM has to be open on it, with this device on the same network. Away from home, add its address."
                : "Can't reach \(pairing.macName). AVM has to be open on it and the Mac awake."
            self.setOffline(text)
            try? await Task.sleep(for: .seconds(8))
            if !Task.isCancelled, thisAttempt == self.attempt, self.isActive { self.connect() }
        }
    }

    private func tryConnecting(to place: NWEndpoint, pairing: ReceiverPairing, attempt thisAttempt: Int) async -> Bool {
        let made = NWConnection(to: place, using: ReceiverWire.parameters(keys: [(pairing.device, pairing.key)]))
        let ready: Bool = await withCheckedContinuation { done in
            var finished = false
            let finish: (Bool) -> Void = { value in
                guard !finished else { return }
                finished = true
                done.resume(returning: value)
            }
            made.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                case .waiting: finish(false)
                default: break
                }
            }
            made.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) { finish(false) }
        }
        guard ready, thisAttempt == attempt else { made.cancel(); return false }
        made.stateUpdateHandler = { [weak self, weak made] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    guard let self, let made, self.connection === made else { return }
                    self.connectionLost()
                }
            default: break
            }
        }
        connection = made
        receive(on: made, reader: ReceiverWire.FrameReader())
        let hello = await ask(["op": "hello", "device": pairing.device, "token": ReceiverWire.helloToken(key: pairing.key)])
        guard hello["ok"] as? Bool == true else {
            connection = nil
            made.cancel()
            return false
        }
        status = .connected
        startListRefresh()
        return true
    }

    func disconnect() {
        attempt += 1
        retry?.cancel()
        listRefresh?.cancel()
        let was = connection
        connection = nil
        was?.cancel()
        finishPending()
        sound.stop()
        openMachineID = nil
        picture = nil
    }

    private func setOffline(_ text: String) {
        if status != .offline(text) { Self.say(text) }
        status = .offline(text)
    }

    private func connectionLost() {
        connection = nil
        finishPending()
        sound.stop()
        listRefresh?.cancel()
        let hadOpen = openMachineID != nil
        openMachineID = nil
        picture = nil
        Self.say(hadOpen ? "Connection to your Mac lost. Trying again. The machine keeps running." : "Connection to your Mac lost. Trying again.")
        connect()
    }

    private func finishPending() {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values { continuation.resume(returning: ["ok": false, "message": "The connection to your Mac ended."]) }
    }

    func becameActive() {
        isActive = true
        if pairing != nil, connection == nil { connect() }
    }

    // MARK: Requests

    func ask(_ request: [String: Any]) async -> [String: Any] {
        guard let connection else { return ["ok": false, "message": "Not connected to your Mac."] }
        let id = nextID
        nextID += 1
        var message = request
        message["id"] = id
        return await withCheckedContinuation { done in
            pending[id] = done
            connection.send(content: ReceiverWire.message(message), completion: .contentProcessed { _ in })
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                if let self, let late = self.pending.removeValue(forKey: id) {
                    late.resume(returning: ["ok": false, "message": "Your Mac didn't answer."])
                }
            }
        }
    }

    private nonisolated func receive(on made: NWConnection, reader: ReceiverWire.FrameReader) {
        made.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var reader = reader
            if let data {
                for frame in reader.add(data) {
                    switch frame.kind {
                    case .sound:
                        // Straight to the player, on this queue: not waiting on the main thread.
                        self.sound.take(packet: frame.payload)
                    case .picture:
                        let image = UIImage(data: frame.payload)
                        Task { @MainActor in if self.openMachineID != nil, self.showsPicture { self.picture = image } }
                    case .message:
                        let object = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any] ?? [:]
                        Task { @MainActor in self.take(message: object) }
                    case .key:
                        break
                    }
                }
            }
            if reader.failed { made.cancel(); return }
            if !isComplete, error == nil { self.receive(on: made, reader: reader) } else { made.cancel() }
        }
    }

    private func take(message: [String: Any]) {
        if let id = message["id"] as? Int, let waiting = pending.removeValue(forKey: id) {
            waiting.resume(returning: message)
            return
        }
        guard let event = message["event"] as? String else { return }
        let text = message["message"] as? String ?? ""
        if event == "closed", message["machine"] as? String == openMachineID {
            sound.stop()
            openMachineID = nil
            picture = nil
            if !text.isEmpty { Self.say(text) }
        } else if event == "problem", !text.isEmpty {
            Self.say(text)
        }
    }

    // MARK: Machines

    private func startListRefresh() {
        listRefresh?.cancel()
        listRefresh = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshList()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func refreshList() async {
        let reply = await ask(["op": "list"])
        guard reply["ok"] as? Bool == true, let list = reply["machines"] as? [[String: Any]] else { return }
        let next = list.compactMap { row -> ReceiverMachine? in
            guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
            return ReceiverMachine(id: id, name: name, kind: row["kind"] as? String ?? "", state: row["state"] as? String ?? "")
        }
        // A machine that finished starting or stopping is worth saying; the
        // rest of the three-second refresh shouldn't talk.
        for machine in next {
            if let before = machines.first(where: { $0.id == machine.id }), before.state != machine.state,
               machine.state == "running" || machine.state == "shut down" || machine.state == "saved" {
                Self.say("\(machine.name) is \(machine.state).")
            }
        }
        if next != machines { machines = next }
    }

    /// The Mac's words for the result, to say.
    func command(_ op: String, _ machine: ReceiverMachine) async {
        let reply = await ask(["op": op, "machine": machine.id])
        if let text = reply["message"] as? String, !text.isEmpty { Self.say(text) }
        await refreshList()
    }

    func open(_ machine: ReceiverMachine) async {
        sound.start()
        let reply = await ask(["op": "open", "machine": machine.id, "picture": showsPicture])
        if reply["ok"] as? Bool == true {
            openMachineID = machine.id
            Self.say("\(machine.name) is open. Its sound is on this device, and your keyboard types into it.")
        } else {
            sound.stop()
            Self.say(reply["message"] as? String ?? "\(machine.name) didn't open.")
        }
    }

    func closeMachine() async {
        guard let id = openMachineID else { return }
        openMachineID = nil
        picture = nil
        sound.stop()
        _ = await ask(["op": "close", "machine": id])
    }

    func setShowsPicture(_ on: Bool) async {
        showsPicture = on
        if !on { picture = nil }
        guard let id = openMachineID else { return }
        _ = await ask(["op": "picture", "machine": id, "on": on])
    }

    func send(key usage: Int, down: Bool) {
        connection?.send(content: ReceiverWire.frame(.key, ReceiverWire.keyPayload(usage: usage, down: down)), completion: .contentProcessed { _ in })
    }

    func type(_ text: String) async {
        guard let id = openMachineID else { return }
        let reply = await ask(["op": "type", "machine": id, "text": text])
        if let said = reply["message"] as? String, !said.isEmpty { Self.say(said) }
    }

    func controlAltDelete() async {
        guard let id = openMachineID else { return }
        _ = await ask(["op": "control-alt-delete", "machine": id])
    }

    func readScreen() async {
        guard let id = openMachineID else { return }
        let reply = await ask(["op": "read-screen", "machine": id])
        let text = reply["message"] as? String ?? ""
        Self.say(text.isEmpty ? "There's no text on the screen that AVM can read." : text)
    }
}
