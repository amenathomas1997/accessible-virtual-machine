// ReceiverServer.swift
// AVM — Accessible Virtual Machine
//
// The Mac's side of the AVM Receiver (2026-11-04): an iPhone or iPad lists
// the machines here, starts and stops them, and opens one: it hears the
// machine, types into it, and sees its screen. The machine stays here. It's
// the same session as at the Mac, so unlike Remote Desktop it needs no Windows
// Pro and no second account. Off until turned on in AVM's Settings, and only a
// device paired with a code from there gets in (ReceiverWire.swift).
//
// While a phone has a machine open its sound goes to the phone and not to the
// Mac's speakers: someone listening elsewhere shouldn't have their screen
// reader read aloud in an empty room. Keys go in as WindowsKeyboard's do,
// through QMP, so no window is needed. Nothing a phone sends is logged.

import AppKit
import Combine
import CryptoKit
import Foundation
import IOKit.pwr_mgt
import ImageIO
import Network
import UniformTypeIdentifiers

// MARK: - Paired devices

nonisolated struct ReceiverDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var key: Data
    var paired: Date
}

/// In the keychain. A Debug build, whose signature changes with every build
/// and would be asked about each one, keeps them in an owner-only file.
nonisolated enum ReceiverDeviceStore {
    private static let service = "AVM Receiver"
    private static let account = "devices"

    static func load() -> [ReceiverDevice] {
        guard let data = read() else { return [] }
        return (try? JSONDecoder().decode([ReceiverDevice].self, from: data)) ?? []
    }

    static func save(_ devices: [ReceiverDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        write(data)
    }

    #if DEBUG
    private static var file: URL? { try? AVMPaths.supportDirectory().appendingPathComponent("receiver-devices.json") }
    private static func read() -> Data? { file.flatMap { try? Data(contentsOf: $0) } }
    private static func write(_ data: Data) {
        guard let file else { return }
        try? data.write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }
    #else
    private static func read() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
    private static func write(_ data: Data) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { AVMLog.write("AVM: Receiver — couldn't save paired devices (\(status)).") }
    }
    #endif
}

// MARK: - The server

@MainActor
final class ReceiverServer: ObservableObject {
    static let shared = ReceiverServer()
    static let enabledKey = "receiverEnabled"
    /// A test run's ports come from the system, so it can run beside AVM.
    var usesFixedPorts = true

    @Published private(set) var devices: [ReceiverDevice] = []
    @Published private(set) var isListening = false
    @Published private(set) var problem: String?
    /// The code on show while pairing is open.
    @Published private(set) var pairingCode: String?
    /// Which machines a phone has open, for Settings and the sleep assertion.
    @Published private(set) var openMachines: Set<UUID> = []

    private(set) var mainPort: UInt16?
    private(set) var pairingPort: UInt16?
    private var listener: NWListener?
    private var pairingListener: NWListener?
    private var pairingEnd: Task<Void, Never>?
    private var clients: [ObjectIdentifier: ReceiverClient] = [:]
    private var attachments: [UUID: ReceiverAttachment] = [:]
    private var sleepAssertion: IOPMAssertionID = 0

    func startIfEnabled() {
        devices = ReceiverDeviceStore.load()
        if UserDefaults.standard.bool(forKey: Self.enabledKey) { startListening() }
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            devices = ReceiverDeviceStore.load()
            startListening()
        } else {
            stopEverything()
        }
    }

    func stopEverything() {
        endPairing()
        listener?.cancel()
        listener = nil
        isListening = false
        problem = nil
        mainPort = nil
        for client in clients.values { client.end() }
    }

    func startListening(announced: Bool = true) {
        listener?.cancel()
        listener = nil
        problem = nil
        // With nothing paired there's nothing it could let in.
        guard !devices.isEmpty else { isListening = false; return }
        let keys = devices.map { (identity: $0.id, key: $0.key) }
        do {
            let parameters = ReceiverWire.parameters(keys: keys)
            parameters.allowLocalEndpointReuse = true
            let port: NWEndpoint.Port = usesFixedPorts ? NWEndpoint.Port(rawValue: ReceiverWire.port)! : .any
            let made = try NWListener(using: parameters, on: port)
            if announced { made.service = NWListener.Service(name: Host.current().localizedName, type: ReceiverWire.bonjourType) }
            made.stateUpdateHandler = { [weak self, weak made] state in
                Task { @MainActor in
                    guard let self, let made, self.listener === made else { return }
                    switch state {
                    case .ready: self.isListening = true; self.mainPort = made.port?.rawValue
                    case .failed(let error):
                        AVMLog.write("AVM: Receiver — listener failed: \(error)")
                        // Bonjour refusing (Local Network permission) takes
                        // the listener with it; an address still reaches it.
                        if announced, case .dns = error {
                            self.startListening(announced: false)
                            self.problem = Self.noBonjourNote
                        } else {
                            self.isListening = false
                            self.problem = "AVM couldn't listen for your devices: \(error.localizedDescription)"
                        }
                    default: break
                    }
                }
            }
            made.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, pairing: false) }
            }
            made.start(queue: .main)
            listener = made
        } catch {
            problem = "AVM couldn't listen for your devices: \(error.localizedDescription)"
        }
    }

    private static let noBonjourNote = "Your devices can't find this Mac by name, so enter its address in AVM Receiver. To fix that, allow AVM under Local Network in System Settings, Privacy & Security."

    private func accept(_ connection: NWConnection, pairing: Bool) {
        let client = ReceiverClient(connection: connection, pairing: pairing)
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    func clientEnded(_ client: ReceiverClient) {
        clients[ObjectIdentifier(client)] = nil
        for (id, attachment) in attachments where attachment.client === client { close(id) }
    }

    // MARK: Pairing

    /// Opens pairing for two minutes and gives the code to type on the device.
    func beginPairing() -> String? {
        endPairing()
        let code = ReceiverWire.makeCode()
        guard openPairingListener(code: code, announced: true) else { return nil }
        pairingCode = code
        pairingEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.endPairing()
        }
        return code
    }

    private func openPairingListener(code: String, announced: Bool) -> Bool {
        pairingListener?.cancel()
        pairingListener = nil
        do {
            let parameters = ReceiverWire.parameters(keys: [(ReceiverWire.pairingIdentity, ReceiverWire.pairingKey(code: code))])
            parameters.allowLocalEndpointReuse = true
            let port: NWEndpoint.Port = usesFixedPorts ? NWEndpoint.Port(rawValue: ReceiverWire.pairingPort)! : .any
            let made = try NWListener(using: parameters, on: port)
            if announced { made.service = NWListener.Service(name: Host.current().localizedName, type: ReceiverWire.pairingBonjourType) }
            made.stateUpdateHandler = { [weak self, weak made] state in
                Task { @MainActor in
                    guard let self, let made, self.pairingListener === made else { return }
                    if case .ready = state { self.pairingPort = made.port?.rawValue }
                    if case .failed(let error) = state {
                        AVMLog.write("AVM: Receiver — pairing listener failed: \(error)")
                        if announced, case .dns = error, self.openPairingListener(code: code, announced: false) {
                            self.problem = Self.noBonjourNote
                        } else {
                            self.problem = "AVM couldn't open pairing: \(error.localizedDescription)"
                            self.endPairing()
                        }
                    }
                }
            }
            made.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection, pairing: true) }
            }
            made.start(queue: .main)
            pairingListener = made
            return true
        } catch {
            problem = "AVM couldn't open pairing: \(error.localizedDescription)"
            return false
        }
    }

    func endPairing() {
        pairingEnd?.cancel()
        pairingEnd = nil
        pairingListener?.cancel()
        pairingListener = nil
        pairingPort = nil
        pairingCode = nil
    }

    /// The code worked (TLS let them in): one device, then pairing is over.
    func completePairing(name: String) -> ReceiverDevice? {
        guard pairingCode != nil else { return nil }
        let device = ReceiverDevice(id: UUID().uuidString, name: String(name.prefix(80)), key: ReceiverWire.newDeviceKey(), paired: Date())
        devices.append(device)
        ReceiverDeviceStore.save(devices)
        endPairing()
        AVMLog.write("AVM: Receiver — a device was paired.")
        Announcer.shared.announce("\(device.name) is paired with AVM.", tone: .success)
        startListening()
        return device
    }

    func forget(_ device: ReceiverDevice) {
        devices.removeAll { $0.id == device.id }
        ReceiverDeviceStore.save(devices)
        for client in clients.values where client.deviceID == device.id { client.end() }
        startListening()
    }

    func device(id: String, token: String) -> ReceiverDevice? {
        devices.first { $0.id == id && ReceiverWire.helloToken(key: $0.key) == token }
    }

    // MARK: Open machines

    func open(_ id: UUID, for client: ReceiverClient, picture: Bool) async -> [String: Any] {
        guard let session = MachineSessions.shared.session(for: id), session.vmState == .running else {
            return ["ok": false, "message": "That machine isn't running."]
        }
        // Another device had it: this one takes over, as a new window would.
        if let earlier = attachments[id] {
            earlier.client?.send(ReceiverWire.message(["event": "closed", "machine": id.uuidString, "message": "Another device opened this machine."]))
            close(id)
        }
        let attachment = ReceiverAttachment(machine: id, manager: session.manager, client: client, picture: picture)
        guard await attachment.start() else {
            return ["ok": false, "message": "AVM couldn't send this machine's sound to your device."]
        }
        attachments[id] = attachment
        openMachines.insert(id)
        holdAwake()
        return ["ok": true, "message": ""]
    }

    func close(_ id: UUID) {
        guard let attachment = attachments.removeValue(forKey: id) else { return }
        openMachines.remove(id)
        attachment.stop()
        holdAwake()
    }

    func attachment(_ id: UUID) -> ReceiverAttachment? { attachments[id] }

    /// A Mac that sleeps while someone is using its machine from elsewhere
    /// would cut them off with no way back.
    private func holdAwake() {
        if openMachines.isEmpty {
            if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion); sleepAssertion = 0 }
        } else if sleepAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "A device has a virtual machine open through AVM Receiver" as CFString, &sleepAssertion)
        }
    }

    // MARK: Where to reach this Mac

    /// A Tailscale address, if this Mac has one (100.64.0.0/10): the way in
    /// from away from home that needs no router changes.
    nonisolated static func tailscaleAddress() -> String? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return nil }
        defer { freeifaddrs(first) }
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if value >> 22 == (100 << 2 | 1) {
                return "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
            }
        }
        return nil
    }
}

// MARK: - One connected device

@MainActor
final class ReceiverClient {
    private let connection: NWConnection
    private let pairing: Bool
    private var reader = ReceiverWire.FrameReader()
    private var ended = false
    private(set) var deviceID: String?
    private var opened: Set<UUID> = []
    /// Sound waiting on the network; past this the oldest words are lost
    /// anyway, so new sound is dropped rather than arriving ever later.
    private let soundLock = NSLock()
    nonisolated(unsafe) private var soundWaiting = 0
    private static let mostSoundWaiting = 10

    init(connection: NWConnection, pairing: Bool) {
        self.connection = connection
        self.pairing = pairing
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .cancelled: self?.end()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
        // Someone who gets in but says nothing doesn't stay.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if let self, self.deviceID == nil, !self.pairing { self.end() }
        }
    }

    func end() {
        guard !ended else { return }
        ended = true
        connection.cancel()
        ReceiverServer.shared.clientEnded(self)
    }

    func send(_ data: Data) {
        guard !ended else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    /// From the sound queue, not the main thread.
    nonisolated func sendSound(_ packet: Data) {
        soundLock.lock()
        guard soundWaiting < Self.mostSoundWaiting else { soundLock.unlock(); return }
        soundWaiting += 1
        soundLock.unlock()
        connection.send(content: ReceiverWire.frame(.sound, packet), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.soundLock.lock()
            self.soundWaiting -= 1
            self.soundLock.unlock()
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.take(data) }
                if isComplete || error != nil { self.end() } else if !self.ended { self.receive() }
            }
        }
    }

    private func take(_ data: Data) {
        for frame in reader.add(data) {
            switch frame.kind {
            case .message:
                guard let object = (try? JSONSerialization.jsonObject(with: frame.payload)) as? [String: Any] else { end(); return }
                let id = object["id"]
                Task {
                    var reply = await self.handle(object)
                    reply["id"] = id
                    self.send(ReceiverWire.message(reply))
                }
            case .key:
                guard deviceID != nil, let key = ReceiverWire.readKey(frame.payload) else { continue }
                for machine in opened { ReceiverServer.shared.attachment(machine)?.key(usage: key.usage, down: key.down) }
            case .sound, .picture:
                end()   // Only the Mac sends these.
                return
            }
        }
        if reader.failed { end() }
    }

    private func handle(_ request: [String: Any]) async -> [String: Any] {
        let op = request["op"] as? String ?? ""
        let server = ReceiverServer.shared
        if pairing {
            guard op == "pair", let device = server.completePairing(name: request["name"] as? String ?? "A device") else {
                return ["ok": false, "message": "Pairing isn't open on the Mac any more."]
            }
            return ["ok": true, "device": device.id, "key": device.key.base64EncodedString(), "mac": Host.current().localizedName ?? "Mac"]
        }
        if op == "hello" {
            guard let device = server.device(id: request["device"] as? String ?? "", token: request["token"] as? String ?? "") else {
                Task { self.end() }
                return ["ok": false, "message": "This device isn't paired with this Mac."]
            }
            deviceID = device.id
            return ["ok": true, "mac": Host.current().localizedName ?? "Mac"]
        }
        guard deviceID != nil else { return ["ok": false, "message": "Say hello first."] }
        let machineText = request["machine"] as? String ?? ""
        let machine = UUID(uuidString: machineText)
        switch op {
        case "list":
            return await ControlServer.shared.handle(request: ["command": "list"])
        case "start":
            // The same refusals as the dashboard and avmctl. No window: the
            // phone is what's looking at it, and the Mac may have nobody at it.
            return await ControlServer.shared.handle(request: ["command": "start", "machine": machineText, "noWindow": true])
        case "stop", "save", "force-stop":
            if let machine { server.close(machine); opened.remove(machine) }
            return await ControlServer.shared.handle(request: ["command": op, "machine": machineText])
        case "open":
            guard let machine else { return ["ok": false, "message": "Which machine?"] }
            let reply = await server.open(machine, for: self, picture: request["picture"] as? Bool ?? true)
            if reply["ok"] as? Bool == true { opened.insert(machine) }
            return reply
        case "close":
            guard let machine else { return ["ok": false, "message": "Which machine?"] }
            if opened.remove(machine) != nil { server.close(machine) }
            return ["ok": true]
        case "picture":
            guard let machine, opened.contains(machine), let attachment = server.attachment(machine) else { return ["ok": false, "message": "That machine isn't open."] }
            attachment.wantsPicture = request["on"] as? Bool ?? false
            return ["ok": true]
        case "type":
            guard let machine, opened.contains(machine), let attachment = server.attachment(machine) else { return ["ok": false, "message": "That machine isn't open."] }
            let result = await attachment.manager.typeText(request["text"] as? String ?? "")
            return result == nil ? ["ok": false, "message": "The machine didn't take the typing."]
                : ["ok": true, "message": result!.skipped > 0 ? "\(result!.skipped) characters couldn't be typed." : ""]
        case "control-alt-delete":
            guard let machine, opened.contains(machine), let attachment = server.attachment(machine) else { return ["ok": false, "message": "That machine isn't open."] }
            return ["ok": await attachment.manager.sendCtrlAltDel()]
        case "read-screen":
            guard let machine, opened.contains(machine), let attachment = server.attachment(machine) else { return ["ok": false, "message": "That machine isn't open."] }
            guard let text = await attachment.readScreen() else { return ["ok": false, "message": "The screen couldn't be read."] }
            return ["ok": true, "message": text]
        default:
            return ["ok": false, "message": "AVM on the Mac doesn't know that request. Update AVM."]
        }
    }

    func machineEnded(_ id: UUID, message: String) {
        opened.remove(id)
        send(ReceiverWire.message(["event": "closed", "machine": id.uuidString, "message": message]))
    }
}

// MARK: - One machine open on a device

@MainActor
final class ReceiverAttachment {
    let machine: UUID
    let manager: VMManager
    weak var client: ReceiverClient?
    var wantsPicture: Bool

    private var soundSocket: Int32 = -1
    private var soundSource: DispatchSourceRead?
    private var soundPath: String?
    private var watch: Task<Void, Never>?
    private var translator = WindowsKeyTranslator()
    private var lastKey: Task<Void, Never>?
    private var stopped = false
    private static let hdaPath = "/machine/peripheral/avmhda"

    init(machine: UUID, manager: VMManager, client: ReceiverClient, picture: Bool) {
        self.machine = machine
        self.manager = manager
        self.client = client
        self.wantsPicture = picture
    }

    func start() async -> Bool {
        guard startSound() else { return false }
        watch = Task { [weak self] in await self?.watchMachine() }
        return true
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        watch?.cancel()
        let keys = translator.releaseAll()
        for code in keys { sendKey(["type": "number", "data": HIDKeyMap.qemuNumber(forScancode: Int(code))], down: false) }
        let manager = self.manager
        let previous = lastKey
        let source = soundSource
        let path = soundPath
        soundSource = nil
        Task { @MainActor in
            await previous?.value
            // The Mac's own output again, as the guest left it.
            _ = try? await manager.sendQMPCommand("qom-set", arguments: ["path": Self.hdaPath, "property": "avm-stream", "value": ""])
            source?.cancel()
            if let path { unlink(path) }
        }
    }

    private func startSound() -> Bool {
        guard let folder = try? VMManager.privateSocketDirectory(for: machine),
              let encoder = ReceiverSoundEncoder() else { return false }
        let path = folder.appendingPathComponent("rx.sock").path
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in bytes.withUnsafeBytes { raw.copyMemory(from: $0) } }
        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); return false }
        chmod(path, 0o600)
        var size: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "AVM receiver sound", qos: .userInteractive))
        let target = client
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 2100)
            while true {
                let count = recv(fd, &buffer, buffer.count, MSG_DONTWAIT)
                guard count > 4 else { return }
                let rate = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
                let packets = buffer.withUnsafeBytes { encoder.add(samples: UnsafeRawBufferPointer(rebasing: $0[4..<count]), rate: rate) }
                for packet in packets { target?.sendSound(packet) }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        soundSource = source
        soundSocket = fd
        soundPath = path
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.manager.sendQMPCommand("qom-set", arguments: ["path": Self.hdaPath, "property": "avm-stream", "value": path])
            } catch {
                AVMLog.write("AVM: Receiver — the machine's sound couldn't be streamed: \(error)")
                self.client?.send(ReceiverWire.message(["event": "problem", "machine": self.machine.uuidString, "message": "This machine's sound can't reach your device."]))
            }
        }
        return true
    }

    // MARK: Keys

    func key(usage: Int, down: Bool) {
        guard !stopped, let output = translator.translate(usage: usage, pressed: down) else { return }
        switch output {
        case .key(let code, let isDown):
            sendKey(["type": "number", "data": HIDKeyMap.qemuNumber(forScancode: Int(code))], down: isDown)
        case .pause(let isDown):
            sendKey(["type": "qcode", "data": "pause"], down: isDown)
        }
    }

    /// One after another, so a release can't overtake its press.
    private func sendKey(_ key: [String: Any], down: Bool) {
        let previous = lastKey
        let manager = self.manager
        let event: [String: Any] = ["type": "key", "data": ["down": down, "key": key]]
        lastKey = Task { @MainActor in
            await previous?.value
            _ = try? await manager.sendQMPCommand("input-send-event", arguments: ["events": [event]])
        }
    }

    // MARK: The picture, and the machine going away

    /// A few pictures a second, only when the screen changed: enough for
    /// someone helping to see where things are, and little on the network
    /// while nothing moves.
    private func watchMachine() async {
        var lastPicture: Data?
        guard let folder = try? VMManager.privateSocketDirectory(for: machine) else { return }
        let path = folder.appendingPathComponent("rx-screen.ppm").path
        defer { unlink(path) }
        while !Task.isCancelled {
            guard let session = MachineSessions.shared.session(for: machine), session.isRunningOrPaused else {
                client?.machineEnded(machine, message: "The machine has stopped.")
                ReceiverServer.shared.close(machine)
                return
            }
            if wantsPicture, session.vmState == .running, await takePicture(to: path) {
                let jpeg = await Task.detached(priority: .utility) { Self.jpeg(ofFile: path) }.value
                if let jpeg, jpeg != lastPicture {
                    lastPicture = jpeg
                    client?.send(ReceiverWire.frame(.picture, jpeg))
                }
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

    /// The text on the screen, from the same picture a device sees.
    func readScreen() async -> String? {
        guard let folder = try? VMManager.privateSocketDirectory(for: machine) else { return nil }
        let path = folder.appendingPathComponent("rx-read.ppm").path
        defer { unlink(path) }
        guard await takePicture(to: path) else { return nil }
        return await Task.detached(priority: .userInitiated) { VMManager.recognizeText(inPicture: URL(fileURLWithPath: path)) }.value
    }

    /// Linux draws on the virtual GPU, and QEMU's first display, which a plain
    /// screendump reads, is the boot-time one, black once Linux has started
    /// (2026-11-04, the iOS app's first run). Windows' test machine shows on the
    /// plain one, measured the same day.
    private func takePicture(to path: String) async -> Bool {
        if !manager.drawsOnGPU, VMStore.shared?.configurations.first(where: { $0.id == machine })?.guestOS != .windows,
           (try? await manager.sendQMPCommand("screendump", arguments: ["filename": path, "format": "ppm", "device": "gpu0"])) != nil {
            return true
        }
        return await manager.screenPicture(to: path)
    }

    nonisolated private static func jpeg(ofFile path: String) -> Data? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1280,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
