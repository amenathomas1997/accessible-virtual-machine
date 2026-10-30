// MacKeyLayout.swift
// AVM — Accessible Virtual Machine
//
// Where a Mac keyboard's modifier keys land in Windows (2026-10-29, the
// user's request). A Mac's bottom row is Control, Option, Command, space,
// Command, Option; a PC's is Ctrl, Windows, Alt, space, Alt, Windows or
// Menu, Ctrl. As printed, Option is Alt and Command is Windows, so the key
// beside the space bar opens the Start menu, and Alt is two keys away. The
// user had swapped them in Windows itself (its Scancode Map: left Alt and
// Windows traded, right Alt to Insert, right Windows to Applications), so
// AVM offers the same, per machine, with no change inside Windows.
//
// One table for both paths: the machine's window (VMView's
// scancode(forVirtualKey:)) and the keyboard for Windows
// (WindowsKeyTranslator) send the same set 1 scancodes for these keys,
// extended ones with 0x100. A layout changes only modifiers, so Windows
// still applies its own keyboard layout to everything typed.
//
// Two PC orders, by keyboard:
//   - Without a number pad (a MacBook, the small Magic Keyboard): no
//     Insert key at all, so right Option is Insert, the screen readers'
//     desktop key; right Command is Applications, for context menus. The
//     user's own remap, exactly.
//   - With a number pad: number-pad 0 is Insert with Num Lock off, so the
//     right side follows a PC: right Command, beside the space bar, is
//     Right Alt (AltGr, for accented letters), and right Option is
//     Applications.

import Foundation

nonisolated enum MacKeyLayout: String, Codable, CaseIterable, Hashable, Sendable {
    case asPrinted
    case pcOrderNoNumberPad
    case pcOrderNumberPad

    /// For the picker in Settings.
    var title: String {
        switch self {
        case .asPrinted: return "As printed: Option is Alt, Command is Windows"
        case .pcOrderNoNumberPad: return "PC order, keyboard without a number pad"
        case .pcOrderNumberPad: return "PC order, keyboard with a number pad"
        }
    }

    /// What each key does, for the line under the picker.
    var keys: String {
        switch self {
        case .asPrinted:
            return "Option is Alt and Command is the Windows key, as printed on a Mac keyboard."
        case .pcOrderNoNumberPad:
            return "Option is the Windows key and Command is Alt, as on a PC. Right Option is Insert, for your screen reader, and right Command is the Applications key, for context menus."
        case .pcOrderNumberPad:
            return "Option is the Windows key and Command is Alt, as on a PC. Right Command is Right Alt and right Option is the Applications key; number-pad 0 is Insert with Num Lock off."
        }
    }

    static let leftAlt = 0x38, leftWindows = 0x100 | 0x5B
    static let rightAlt = 0x100 | 0x38, rightWindows = 0x100 | 0x5C
    static let insert = 0x100 | 0x52, applications = 0x100 | 0x5D

    private var table: [Int: Int] {
        switch self {
        case .asPrinted:
            return [:]
        case .pcOrderNoNumberPad:
            return [Self.leftAlt: Self.leftWindows, Self.leftWindows: Self.leftAlt,
                    Self.rightAlt: Self.insert, Self.rightWindows: Self.applications]
        case .pcOrderNumberPad:
            return [Self.leftAlt: Self.leftWindows, Self.leftWindows: Self.leftAlt,
                    Self.rightAlt: Self.applications, Self.rightWindows: Self.rightAlt]
        }
    }

    /// The scancode Windows gets for this one.
    func apply(_ scancode: Int) -> Int { table[scancode] ?? scancode }
}
