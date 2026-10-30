// main.swift
// AVMWindowsApp — one Windows app in the Mac's Command-Tab list
//
// (2026-10-29, the user's request.) AVM copies this small program into an
// app bundle of its own for each app open in a running Windows machine
// (AVM/WindowsApps.swift), named for it, "Microsoft Word (Amena-PC)", so
// Command-Tab lists it; AVM quits it when the app closes or the machine
// stops. It has one window, which VoiceOver reads on the way in, and one
// command: Command-Shift-E, as AVM's own Enter, which asks AVM, through
// its control socket, to bring the app forward in Windows and lock the
// keyboard into it. Control-Command-Escape comes back, as always.
//
// Everything it needs is in its Info.plist, written by AVM: AVMAppName,
// AVMAppKey (the Windows helper's key for the app), AVMMachineID,
// AVMMachineName, AVMControlSocket and AVMBundleID (AVM's own).

import AppKit

final class WindowsAppEntry: NSObject, NSApplicationDelegate {
    private let info = Bundle.main.infoDictionary ?? [:]
    private var appName: String { info["AVMAppName"] as? String ?? "Windows app" }
    private var machineName: String { info["AVMMachineName"] as? String ?? "Windows" }
    private var window: NSWindow?
    private var status: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let text = NSTextField(wrappingLabelWithString: "\(appName) in \(machineName). Press Command-Shift-E to type in it. Control-Command-Escape brings you back to the Mac.")
        text.setAccessibilityLabel(text.stringValue)
        // A button too, for VoiceOver's VO-Space; Command-Shift-E is the key.
        let enter = NSButton(title: "Type in \(appName)", target: self, action: #selector(enterApp(_:)))
        let stack = NSStackView(views: [text, enter])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 140),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(appName) in \(machineName)"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        status = text
        if !NSApp.isHidden { window.makeKeyAndOrderFront(nil) }
    }

    /// Back from Command-Tab: the window is what VoiceOver reads.
    func applicationDidBecomeActive(_ notification: Notification) {
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let machineItem = NSMenuItem()
        let machineMenu = NSMenu(title: machineName)
        let enter = NSMenuItem(title: "Type in \(appName)", action: #selector(enterApp(_:)), keyEquivalent: "e")
        enter.keyEquivalentModifierMask = [.command, .shift]
        enter.target = self
        machineMenu.addItem(enter)
        machineItem.submenu = machineMenu
        main.addItem(machineItem)
        NSApp.mainMenu = main
    }

    @objc func enterApp(_ sender: Any?) {
        // AVM takes the front next (macOS 14 lets an app activate only when
        // the active one yields).
        if #available(macOS 14.0, *), let avm = info["AVMBundleID"] as? String {
            NSApp.yieldActivation(toApplicationWithBundleIdentifier: avm)
        }
        let request: [String: Any] = ["command": "enter-app",
                                      "machine": info["AVMMachineID"] as? String ?? "",
                                      "app": info["AVMAppKey"] as? String ?? ""]
        let socketPath = info["AVMControlSocket"] as? String ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let reply = Self.send(request, to: socketPath)
            DispatchQueue.main.async {
                if reply?["ok"] as? Bool != true {
                    let message = reply?["message"] as? String ?? "AVM didn't answer. Open AVM, then try again."
                    self.status?.stringValue = message
                    NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                         userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
                }
            }
        }
    }

    /// One JSON line to AVM's control socket, one back (ControlServer).
    static func send(_ request: [String: Any], to path: String) -> [String: Any]? {
        guard let line = try? JSONSerialization.data(withJSONObject: request) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var limit = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        let out = line + Data([0x0A])
        _ = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !received.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            received.append(contentsOf: chunk[0..<n])
        }
        return try? JSONSerialization.jsonObject(with: received.prefix { $0 != 0x0A }) as? [String: Any]
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = WindowsAppEntry()
app.delegate = delegate
app.run()
