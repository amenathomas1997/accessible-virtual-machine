// TypeText.swift
// Guest House — accessible virtual machines
//
// Type the clipboard into the machine (2026-10-30, the user's request):
// sign-in screens, some installers and some web forms refuse paste, and a
// long password or product key is hard to type by ear. Virtual Machine >
// Type Clipboard into Windows types the Mac's clipboard text as key presses,
// through the machine's own virtual keyboard (QMP send-key), as Send
// Ctrl-Alt-Delete does, so it works before the guest's agents are up.
//
// The keys are the US layout's. Guest House's installs set that up until
// 2026-10-25 and follow the Mac's layout since, so a machine that says its
// keyboard is another one isn't typed into (keyboardLayoutIfNotUS). A character with no key there, such as
// an accented letter, is skipped and counted, and Guest House says how many. The
// text itself is never logged or spoken: it's often a password.

import Foundation

extension VMManager {

    /// The US-layout key for a character, and whether it needs Shift.
    nonisolated static func usKey(for character: Character) -> (qcode: String, shift: Bool)? {
        switch character {
        case "a"..."z": return (String(character), false)
        case "A"..."Z": return (character.lowercased(), true)
        case "0"..."9": return (String(character), false)
        case " ": return ("spc", false)
        case "\n", "\r", "\r\n": return ("ret", false)
        case "\t": return ("tab", false)
        default: break
        }
        let plain: [Character: String] = [
            "-": "minus", "=": "equal", "[": "bracket_left", "]": "bracket_right", "\\": "backslash",
            ";": "semicolon", "'": "apostrophe", "`": "grave_accent", ",": "comma", ".": "dot", "/": "slash",
        ]
        if let qcode = plain[character] { return (qcode, false) }
        let shifted: [Character: String] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
            "_": "minus", "+": "equal", "{": "bracket_left", "}": "bracket_right", "|": "backslash",
            ":": "semicolon", "\"": "apostrophe", "~": "grave_accent", "<": "comma", ">": "dot", "?": "slash",
        ]
        if let qcode = shifted[character] { return (qcode, true) }
        return nil
    }

    /// The machine's keyboard layout, when its agent can say and it isn't
    /// the US one (2026-11-10, audit of that day #10). Since 2026-10-25
    /// Guest House's installs follow the Mac's layout or the wizard's, and US key
    /// positions typed into a German or French machine come out as other
    /// characters: a wrong password, with "Typed N characters" said. Nil
    /// when it's US or can't be told (the agent is a service, so it answers
    /// at the sign-in screen too).
    func keyboardLayoutIfNotUS() async -> String? {
        isCheckingKeyboard = true
        defer { isCheckingKeyboard = false }
        if runningGuestOS == .windows {
            // The signed-in user's layout, or the sign-in screen's. Preload
            // names a language; its Substitutes entry, when there is one,
            // names the layout (its review): Canadian English with the US
            // keyboard is 00001009 there, and US International hides
            // behind 00000409. 00000409 itself is the US layout.
            guard let out = try? await agentRun("powershell.exe", ["-NoProfile", "-Command", #"""
                $h = 'Registry::HKEY_USERS\.DEFAULT'
                $u = (Get-CimInstance Win32_ComputerSystem).UserName
                if ($u) { try { $sid = (New-Object Security.Principal.NTAccount($u)).Translate([Security.Principal.SecurityIdentifier]).Value; if (Test-Path "Registry::HKEY_USERS\$sid\Keyboard Layout\Preload") { $h = "Registry::HKEY_USERS\$sid" } } catch {} }
                $p = (Get-ItemProperty "$h\Keyboard Layout\Preload").'1'
                $s = (Get-ItemProperty "$h\Keyboard Layout\Substitutes" -ErrorAction SilentlyContinue).$p
                if ($s) { $p = $s }
                $p
                """#], limit: .seconds(15)) else { return nil }
            return VMConfiguration.layoutIfNotUS(windowsPreload: out)
        }
        guard let out = try? await agentRun("/bin/sh", ["-c", "localectl status 2>/dev/null | sed -n 's/.*X11 Layout: *//p;s/.*X11 Variant: */variant /p'"], limit: .seconds(15)) else { return nil }
        return VMConfiguration.layoutIfNotUS(x11Layout: out)
    }

    /// Types `text` into the machine. Returns how many characters were
    /// typed, how many had no key, and whether it stopped before the end, or
    /// nil when it couldn't type at all. One at a time: two ran together,
    /// mixing their keys, and a stop or failure part way read as success
    /// (2026-11-01 audit).
    func typeText(_ text: String) async -> (typed: Int, skipped: Int, stopped: Bool)? {
        guard case .running = state, !isTypingText else { return nil }
        isTypingText = true
        typingStopAsked = false
        defer { isTypingText = false }
        var typed = 0
        var skipped = 0
        for character in text {
            guard case .running = state, !typingStopAsked else {
                AVMLog.write("Guest House: Type Clipboard — stopped after \(typed) characters")
                return (typed, skipped, true)
            }
            guard let key = Self.usKey(for: character) else {
                skipped += 1
                continue
            }
            var keys: [[String: String]] = []
            if key.shift { keys.append(["type": "qcode", "data": "shift"]) }
            keys.append(["type": "qcode", "data": key.qcode])
            do {
                try await sendQMPCommand("send-key", arguments: ["keys": keys, "hold-time": 15])
                typed += 1
            } catch {
                AVMLog.write("Guest House: Type Clipboard — stopped after \(typed) characters: \(error.localizedDescription)")
                return typed == 0 ? nil : (typed, skipped, true)
            }
            // A moment between keys, so a slow screen or a sign-in box
            // doesn't drop any.
            try? await Task.sleep(for: .milliseconds(15))
        }
        AVMLog.write("Guest House: Type Clipboard — typed \(typed) characters, \(skipped) without a key")
        return (typed, skipped, false)
    }
}
