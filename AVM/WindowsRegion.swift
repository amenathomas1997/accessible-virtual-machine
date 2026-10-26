// WindowsRegion.swift
// AVM — Accessible Virtual Machine
//
// The Mac's region and keyboard, told to Windows Setup (2026-10-26), so
// OOBE skips its "Is this the right country or region?" and keyboard
// layout pages: two fewer screens to get through with Narrator alone.
// They go into the answer file's oobeSystem pass as the International-Core
// component (UserLocale, SystemLocale, InputLocale).
//
// Only what AVM is sure of is sent. A region that isn't a plain
// language-COUNTRY pair, or a keyboard missing from the table below,
// leaves that setting out, and Windows asks on that page as before;
// a wrong keyboard would be worse than one more question. The display
// language is never set here: it must be one the Windows ISO contains.

import Foundation
import Carbon

nonisolated struct WindowsRegion: Sendable, Equatable {
    /// "en-GB": the Mac's region, for UserLocale and SystemLocale.
    var locale: String?
    /// "0809:00000809": Windows' language:layout pair for the Mac keyboard.
    var inputLocale: String?

    /// Windows keyboard IDs for macOS keyboard layouts. Mac layouts that
    /// Windows has no Mac twin for map to the PC layout of the same name,
    /// as Windows' own Boot Camp does.
    static let keyboards: [String: String] = [
        "com.apple.keylayout.US": "0409:00000409",
        "com.apple.keylayout.ABC": "0409:00000409",
        "com.apple.keylayout.USExtended": "0409:00000409",
        "com.apple.keylayout.USInternational-PC": "0409:00020409",
        "com.apple.keylayout.Dvorak": "0409:00010409",
        "com.apple.keylayout.British": "0809:00000809",
        "com.apple.keylayout.British-PC": "0809:00000809",
        "com.apple.keylayout.Irish": "1809:00001809",
        "com.apple.keylayout.Canadian": "1009:00000409",
        "com.apple.keylayout.Canadian-CSA": "0c0c:00011009",
        "com.apple.keylayout.French": "040c:0000040c",
        "com.apple.keylayout.French-PC": "040c:0000040c",
        "com.apple.keylayout.Belgian": "080c:0000080c",
        "com.apple.keylayout.German": "0407:00000407",
        "com.apple.keylayout.SwissGerman": "0807:00000807",
        "com.apple.keylayout.SwissFrench": "100c:0000100c",
        "com.apple.keylayout.Austrian": "0c07:00000407",
        "com.apple.keylayout.Spanish": "0c0a:0000040a",
        "com.apple.keylayout.Spanish-ISO": "0c0a:0000040a",
        "com.apple.keylayout.LatinAmerican": "080a:0000080a",
        "com.apple.keylayout.Italian": "0410:00000410",
        "com.apple.keylayout.Italian-Pro": "0410:00000410",
        "com.apple.keylayout.Portuguese": "0816:00000816",
        "com.apple.keylayout.Brazilian": "0416:00000416",
        "com.apple.keylayout.Brazilian-ABNT2": "0416:00000416",
        "com.apple.keylayout.Dutch": "0413:00020409",
        "com.apple.keylayout.Danish": "0406:00000406",
        "com.apple.keylayout.Swedish": "041d:0000041d",
        "com.apple.keylayout.Swedish-Pro": "041d:0000041d",
        "com.apple.keylayout.Norwegian": "0414:00000414",
        "com.apple.keylayout.Finnish": "040b:0000041d",
    ]

    /// "en_US" or "en-US" to "en-US"; anything else to nil.
    static func windowsLocale(fromMac identifier: String) -> String? {
        // "en_GB@rg=gbzzzz": keywords after "@" (region override, calendar)
        // are macOS's own and not part of the locale's name.
        let base = identifier.split(separator: "@", maxSplits: 1).first.map(String.init) ?? identifier
        let parts = base.split(whereSeparator: { $0 == "_" || $0 == "-" }).map(String.init)
        guard parts.count >= 2,
              parts[0].range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil,
              parts[1].range(of: "^[A-Z]{2}$", options: .regularExpression) != nil else { return nil }
        return "\(parts[0])-\(parts[1])"
    }

    /// The Mac's own region and keyboard. Main actor: Text Input Sources.
    @MainActor
    static func current() -> WindowsRegion {
        var region = WindowsRegion()
        region.locale = windowsLocale(fromMac: Locale.current.identifier)
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            region.inputLocale = keyboards[id]
        }
        return region
    }

    /// The oobeSystem International-Core component, or "" when there is
    /// nothing certain to say.
    var answerFileComponent: String {
        guard locale != nil || inputLocale != nil else { return "" }
        var lines = [#"<component name="Microsoft-Windows-International-Core" processorArchitecture="arm64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#]
        if let inputLocale { lines.append("  <InputLocale>\(inputLocale)</InputLocale>") }
        if let locale {
            lines.append("  <SystemLocale>\(locale)</SystemLocale>")
            lines.append("  <UserLocale>\(locale)</UserLocale>")
        }
        lines.append("</component>")
        return lines.joined(separator: "\n    ")
    }
}
