import XCTest
@testable import AVMLogic

final class ReceiverWireTests: XCTestCase {
    func testFramesSurviveAnySplit() {
        let first = ReceiverWire.frame(.sound, Data([1, 2, 3]))
        let second = ReceiverWire.frame(.picture, Data(repeating: 9, count: 5000))
        let all = first + second
        var reader = ReceiverWire.FrameReader()
        var got: [(kind: ReceiverWire.Kind, payload: Data)] = []
        for byte in all { got += reader.add(Data([byte])) }
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got[0].kind, .sound)
        XCTAssertEqual(got[0].payload, Data([1, 2, 3]))
        XCTAssertEqual(got[1].kind, .picture)
        XCTAssertEqual(got[1].payload.count, 5000)
        XCTAssertFalse(reader.failed)
    }

    func testImpossibleFramesFail() {
        var unknown = ReceiverWire.FrameReader()
        _ = unknown.add(Data([99, 0, 0, 0, 1, 0]))
        XCTAssertTrue(unknown.failed)
        var huge = ReceiverWire.FrameReader()
        _ = huge.add(Data([1, 0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertTrue(huge.failed)
    }

    func testKeys() {
        let key = ReceiverWire.readKey(ReceiverWire.keyPayload(usage: 0xE0, down: true))
        XCTAssertEqual(key?.usage, 0xE0)
        XCTAssertEqual(key?.down, true)
        XCTAssertNil(ReceiverWire.readKey(Data([1])))
    }

    func testCodes() {
        let code = ReceiverWire.makeCode()
        XCTAssertEqual(code.count, 14)
        XCTAssertEqual(ReceiverWire.normalized(code: code).count, 12)
        XCTAssertNotEqual(code, ReceiverWire.makeCode())
        XCTAssertEqual(ReceiverWire.pairingKey(code: code), ReceiverWire.pairingKey(code: code.lowercased().replacingOccurrences(of: "-", with: " ")))
        XCTAssertNotEqual(ReceiverWire.pairingKey(code: "AAAA-BBBB-CCCC"), ReceiverWire.pairingKey(code: "AAAA-BBBB-CCCD"))
    }
}
