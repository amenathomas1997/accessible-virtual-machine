// CommandTabTap.swift
// AVM — Accessible Virtual Machine
//
// Command-Tab for Windows while the keyboard is in a machine (2026-10-29,
// the user's report: "alt+tab doesn't work" with Option and Command in a
// PC's order, where Command is Alt). macOS keeps Command-Tab for its app
// switcher even with process switching turned off, as the lock does: a
// test app with the lock's presentation options saw Command come up and
// nothing else, so the Tab never reached AVM's window and Windows got Alt
// alone. (As printed, Command-Tab is Win-Tab, and that never arrived
// either.)
//
// So while locked, a listen-only event tap at the HID level, below the
// switcher, watches for Tab with Command held and hands each press and
// release to the machine's window, which sends it to Windows with
// whatever modifiers are down there: Alt-Tab, Alt-Shift-Tab, held Tab
// cycling as on a PC. Listen-only: the event still goes to macOS, whose
// switcher is off while locked, and nothing changes for any other app.
// It needs Input Monitoring, the permission AVM asks for its helper's
// devices with keys (InputMonitoring.swift); without it there's no tap and
// Command-Tab stays the Mac's, as before.

import AppKit
import CoreGraphics

final class CommandTabTap {
    /// Tab, as a Mac virtual key code (kVK_Tab).
    static let tabKey: Int64 = 48

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// down: true for a press (repeats included), false for the release.
    private let handler: (_ down: Bool) -> Void

    init(handler: @escaping (_ down: Bool) -> Void) {
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }

    /// False without Input Monitoring.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            // On the main run loop (the source is added there below).
            MainActor.assumeIsolated {
                let me = Unmanaged<CommandTabTap>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if type == .keyDown || type == .keyUp,
                          event.getIntegerValueField(.keyboardEventKeycode) == CommandTabTap.tabKey,
                          event.flags.contains(.maskCommand) || type == .keyUp {
                    me.handler(type == .keyDown)
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else {
            return false
        }
        tap = port
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        source = runLoopSource
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil
        tap = nil
    }

    deinit { stop() }
}
