// A stand-in for the AVM Receiver app, for Tools/test-receiver.sh (2026-11-04):
// it speaks the same wire over the same encryption, with no phone.
//
//   receiver-client pair    --port P --code CODE --state FILE
//   receiver-client hello   --port P --state FILE
//   receiver-client session --port P --state FILE --machine NAME --until FILE --picture FILE
import Foundation
import Network

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
}
func die(_ text: String) -> Never { print("FAILED \(text)"); exit(1) }

final class Link {
    let c: NWConnection
    var reader = ReceiverWire.FrameReader()
    let q = DispatchQueue(label: "link")
    var next = 1
    var waiting: [Int: (([String: Any]) -> Void)] = [:]
    var onSound: ((Data) -> Void)?
    var onPicture: ((Data) -> Void)?
    var onEvent: (([String: Any]) -> Void)?
    init(port: UInt16, keys: [(identity: String, key: Data)]) {
        c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: ReceiverWire.parameters(keys: keys))
    }
    func open() {
        let s = DispatchSemaphore(value: 0)
        var problem: String?
        c.stateUpdateHandler = { state in
            switch state {
            case .ready: s.signal()
            case .failed(let e), .waiting(let e): problem = "\(e)"; s.signal()
            default: break
            }
        }
        c.start(queue: q)
        if s.wait(timeout: .now() + 10) == .timedOut { die("connect timed out") }
        if let problem { die("connect: \(problem)") }
        receive()
    }
    func receive() {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, done, e in
            if let d { for f in self.reader.add(d) { self.take(f.kind, f.payload) } }
            if done || e != nil { for w in self.waiting.values { w(["ok": false, "message": "connection ended"]) }; self.waiting = [:]; return }
            self.receive()
        }
    }
    func take(_ kind: ReceiverWire.Kind, _ payload: Data) {
        switch kind {
        case .sound: onSound?(payload)
        case .picture: onPicture?(payload)
        case .message:
            let o = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
            if let i = o["id"] as? Int, let w = waiting.removeValue(forKey: i) { w(o) } else { onEvent?(o) }
        case .key: break
        }
    }
    func ask(_ request: [String: Any], timeout: Double = 30) -> [String: Any] {
        let s = DispatchSemaphore(value: 0)
        var reply: [String: Any] = ["ok": false, "message": "no answer"]
        q.sync {
            let id = next; next += 1
            waiting[id] = { reply = $0; s.signal() }
            var r = request; r["id"] = id
            c.send(content: ReceiverWire.message(r), completion: .contentProcessed { _ in })
        }
        _ = s.wait(timeout: .now() + timeout)
        return reply
    }
    func key(_ usage: Int, _ down: Bool) {
        c.send(content: ReceiverWire.frame(.key, ReceiverWire.keyPayload(usage: usage, down: down)), completion: .contentProcessed { _ in })
    }
}

guard CommandLine.arguments.count > 1 else { die("usage") }
let command = CommandLine.arguments[1]
guard let port = arg("--port").flatMap(UInt16.init), let statePath = arg("--state") else { die("--port and --state") }
struct State: Codable { var device: String; var key: Data }

if command == "pair" {
    let link = Link(port: port, keys: [(ReceiverWire.pairingIdentity, ReceiverWire.pairingKey(code: arg("--code") ?? ""))])
    link.open()
    let r = link.ask(["op": "pair", "name": "Test Client"], timeout: 8)
    guard r["ok"] as? Bool == true, let device = r["device"] as? String, let key = (r["key"] as? String).flatMap({ Data(base64Encoded: $0) }) else { die("pair: \(r)") }
    try! JSONEncoder().encode(State(device: device, key: key)).write(to: URL(fileURLWithPath: statePath))
    print("OK paired with \(r["mac"] ?? "?")")
    exit(0)
}

guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)), let state = try? JSONDecoder().decode(State.self, from: data) else { die("no state") }
let link = Link(port: port, keys: [(state.device, state.key)])
link.open()
let hello = link.ask(["op": "hello", "device": state.device, "token": ReceiverWire.helloToken(key: state.key)], timeout: 8)
guard hello["ok"] as? Bool == true else { die("hello: \(hello)") }
print("OK hello from \(hello["mac"] ?? "?")")
if command == "hello" { exit(0) }

guard let wanted = arg("--machine"), let until = arg("--until") else { die("--machine and --until") }
func machine() -> [String: Any]? {
    ((link.ask(["op": "list"])["machines"] as? [[String: Any]]) ?? []).first { $0["name"] as? String == wanted }
}
guard let first = machine(), let id = first["id"] as? String else { die("not listed") }
print("LISTED \(first["name"] ?? "") \(first["kind"] ?? "") \(first["state"] ?? "")")
let started = link.ask(["op": "start", "machine": id])
print("START \(started)")
var running = false
for _ in 0..<240 {
    if machine()?["state"] as? String == "running" { running = true; break }
    Thread.sleep(forTimeInterval: 0.5)
}
guard running else { die("never running") }

let decoder = ReceiverSoundDecoder()!
var packets = 0, bytes = 0, decoded = 0, pictures = 0, pictureBytes = 0
var peak: Float = 0
var biggestPicture = 0
var firstLoud: Date?
var gaps: [Double] = []
var lastPacket: Date?
link.onSound = { p in
    packets += 1; bytes += p.count
    let now = Date()
    if let lastPacket { gaps.append(now.timeIntervalSince(lastPacket)) }
    lastPacket = now
    guard let b = decoder.decode(p), let ch = b.floatChannelData else { return }
    decoded += Int(b.frameLength)
    for i in 0..<Int(b.frameLength) { peak = max(peak, abs(ch[0][i])) }
    if peak > 0.02, firstLoud == nil { firstLoud = now }
}
link.onPicture = { d in
    pictures += 1; pictureBytes += d.count
    if let out = arg("--picture") {
        try? d.write(to: URL(fileURLWithPath: out))
        if d.count > biggestPicture { biggestPicture = d.count; try? d.write(to: URL(fileURLWithPath: out + ".biggest.jpg")) }
    }
}
var events: [String] = []
link.onEvent = { e in events.append("\(e)") }
let opened = link.ask(["op": "open", "machine": id, "picture": true])
print("OPEN \(opened)")
guard opened["ok"] as? Bool == true else { die("open") }
// Opened again straight away, as the phone does when someone opens it twice
// (2026-11-05): the first open's closing removed the second's sound socket.
let again = link.ask(["op": "open", "machine": id, "picture": true])
print("OPEN-AGAIN \(again)")
guard again["ok"] as? Bool == true else { die("open again") }
FileManager.default.createFile(atPath: until + ".opened", contents: nil)
var presses = 0
let deadline = Date().addingTimeInterval(900)
while !FileManager.default.fileExists(atPath: until), Date() < deadline {
    // Only once the machine is up: a key at its boot menu stops the countdown.
    if FileManager.default.fileExists(atPath: until + ".keys") {
        link.key(4, true); Thread.sleep(forTimeInterval: 0.05); link.key(4, false)   // the A key
        presses += 1
    }
    Thread.sleep(forTimeInterval: 1.5)
}

Thread.sleep(forTimeInterval: 0.2)
print("READ-SCREEN \(String(describing: link.ask(["op": "read-screen", "machine": id])["message"] ?? "").replacingOccurrences(of: "\n", with: " / ").prefix(200))")
print("CLOSE \(link.ask(["op": "close", "machine": id]))")
link.q.sync {}
let sorted = gaps.sorted()
print("RESULT packets=\(packets) bytes=\(bytes) decoded=\(decoded) peak=\(peak) pictures=\(pictures) pictureBytes=\(pictureBytes) presses=\(presses) gapMedianMs=\(sorted.isEmpty ? 0 : Int(sorted[sorted.count / 2] * 1000)) events=\(events)")
print("STOP \(link.ask(["op": "stop", "machine": id]))")
