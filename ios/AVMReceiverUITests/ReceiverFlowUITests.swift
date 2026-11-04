// ReceiverFlowUITests.swift
// AVM Receiver
//
// The app from pairing to a machine open (2026-11-04), against AVM's
// --serve-receiver on this Mac: the code comes from /tmp/avm-receiver-code.txt.
// Prints what the accessibility system sees of each screen, since that is what
// VoiceOver reads. Finds everything by its spoken name, so a button VoiceOver
// couldn't name fails here too. Run by Tools/test-receiver-app.sh.

import XCTest

final class ReceiverFlowUITests: XCTestCase {
    private func dump(_ app: XCUIApplication, _ name: String) {
        print("=== SCREEN \(name)\n\(app.debugDescription)\n=== END")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/rx-app-\(name).png"))
    }

    func testPairStartOpenTypeClose() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let pair = app.navigationBars["Pair with Your Mac"]
        if pair.waitForExistence(timeout: 8) {
            dump(app, "pair")
            let code = try String(contentsOfFile: "/tmp/avm-receiver-code.txt", encoding: .utf8)
            let address = app.textFields["Or its address"]
            address.tap()
            address.typeText("127.0.0.1")
            let codeField = app.textFields["Code from your Mac"]
            codeField.tap()
            codeField.typeText("WRONG-CODES-12")
            app.buttons["Pair"].tap()
            XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'That didn'")).firstMatch.waitForExistence(timeout: 20), "a wrong code says so")
            dump(app, "wrong-code")
            codeField.tap()
            codeField.press(forDuration: 1.2)
            if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
            codeField.typeText(XCUIKeyboardKey.delete.rawValue)
            codeField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 14))
            codeField.typeText(code)
            app.buttons["Pair"].tap()
        }

        let machine = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Test Debian'")).firstMatch
        XCTAssertTrue(machine.waitForExistence(timeout: 30), "the machine is listed")
        dump(app, "machines")
        let start = app.buttons["Start Test Debian"]
        if start.waitForExistence(timeout: 5) { start.tap() }
        let open = app.buttons["Open Test Debian"]
        XCTAssertTrue(open.waitForExistence(timeout: 120), "it can be opened once it's running")
        dump(app, "running")
        open.tap()
        XCTAssertTrue(app.buttons["Close Machine"].waitForExistence(timeout: 20), "the machine's page opens")
        // Let it boot, so its keyboard is live and the screen has something on it.
        let booted = expectation(description: "/tmp/avm-receiver-go exists")
        DispatchQueue.global().async {
            for _ in 0..<240 {
                if FileManager.default.fileExists(atPath: "/tmp/avm-receiver-go") { booted.fulfill(); return }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        wait(for: [booted], timeout: 245)
        dump(app, "open")
        // A hardware keyboard's keys, to the page's first responder.
        for _ in 0..<5 { app.typeKey("a", modifierFlags: []); Thread.sleep(forTimeInterval: 0.4) }
        app.typeKey("a", modifierFlags: .shift)
        FileManager.default.createFile(atPath: "/tmp/avm-receiver-typed", contents: nil)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.images["Test Debian's screen"].waitForExistence(timeout: 15), "the screen shows, with a name")
        app.buttons["Read Screen"].tap()
        Thread.sleep(forTimeInterval: 3)
        dump(app, "screen")
        app.buttons["Close Machine"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 15), "closing goes back to the list")
        dump(app, "closed")
    }
}
