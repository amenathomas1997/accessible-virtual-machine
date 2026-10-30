// WindowsApps.swift
// AVM — Accessible Virtual Machine
//
// Windows apps in the Mac's Command-Tab list (2026-10-29, the user's
// request): every app with a window open in a running Windows machine is
// in Command-Tab as an app of its own, "Microsoft Word (Amena-PC)", added
// when it opens and gone when it closes. Command-Tab to one, press
// Command-Shift-E, and the app comes forward in Windows and the keyboard
// locks into the machine, where NVDA, JAWS or Narrator read it as usual.
// Control-Command-Escape comes back to the Mac. (While locked, AVM keeps
// Command-Tab off, so switching is always from the Mac side.)
//
// Two halves:
//   - In Windows, AVMWindowsApps.exe (Resources/windows-apps), running in
//     the signed-in user's session from the scheduled task \AVM\Windows
//     Apps. The guest agent runs as SYSTEM in session 0 and can see none
//     of the user's windows, so the helper lists the apps open
//     (C:\ProgramData\AVM\apps\running.txt) and brings one forward when
//     asked (request.txt, reply.txt). AVM installs it, compiled in Windows
//     by .NET Framework's own compiler, and replaces it when its version
//     changes, through the agent, with no window or prompt in Windows.
//   - On the Mac, one small app per Windows app: a copy of
//     AVMWindowsApp (Contents/MacOS) in a bundle of its own, named for the
//     app and signed on this Mac, launched hidden so it's in Command-Tab
//     (and so in the Dock: macOS has no way to have one without the
//     other). It calls back through the control socket ("enter-app").
//
// Every few seconds, for each running Windows machine with the setting on
// (VMConfiguration.windowsAppsInCommandTab, on unless turned off).

import AppKit
import CryptoKit

@MainActor
final class WindowsApps {
    static let shared = WindowsApps()

    /// Bumped with every change to AVMWindowsApps.cs.
    static let helperVersion = "1"
    static let guestFolder = #"C:\ProgramData\AVM"#

    private struct Entry {
        let bundleID: String
        let name: String
    }
    /// The Mac apps launched, by machine, by the helper's key for the app.
    private var entries: [UUID: [String: Entry]] = [:]
    /// The machine run (its QEMU process) whose helper is known current.
    private var helperReady: [UUID: Int] = [:]
    private var installing: Set<UUID> = []
    private var timer: Timer?
    private var ticking = false
    private var built: Set<String> = []
    private var requestNumber = 0

    private var bundlePrefix: String { (Bundle.main.bundleIdentifier ?? "com.fullcircleat.AVM") + ".windowsapp." }

    func start() {
        guard timer == nil else { return }
        quitLeftovers()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated { WindowsApps.shared.tick() }
        }
    }

    /// AVM quitting: every Windows app's Mac app goes too.
    func quitAll() {
        for machine in entries.keys { quitEntries(of: machine) }
        quitLeftovers()
    }

    // MARK: Watching

    private func tick() {
        guard !ticking else { return }
        let machines = MachineSessions.shared.sessions.values.filter {
            $0.configuration.guestOS == .windows && $0.vmState == .running && $0.configuration.windowsAppsInCommandTab != false
        }
        let watched = Set(machines.map { $0.configuration.id })
        for machine in entries.keys where !watched.contains(machine) { quitEntries(of: machine) }
        for machine in helperReady.keys where !watched.contains(machine) { helperReady[machine] = nil }
        guard !machines.isEmpty else { return }
        ticking = true
        Task {
            defer { ticking = false }
            for session in machines {
                let manager = session.manager
                let id = session.configuration.id
                if helperReady[id] != manager.qemuPID {
                    guard await ensureHelper(manager, machine: id) else { continue }
                }
                guard let list = try? await Self.readGuestFile(manager, Self.guestFolder + #"\apps\running.txt"#) else { continue }
                sync(machine: id, machineName: session.configuration.name, list: list)
            }
        }
    }

    private func sync(machine: UUID, machineName: String, list: String) {
        var open: [String: String] = [:]
        for line in list.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            open[parts[0]] = parts[1]
        }
        var current = entries[machine] ?? [:]
        for (key, entry) in current where open[key] == nil {
            quit(entry.bundleID)
            current[key] = nil
            AVMLog.write("Windows apps: \(entry.name) closed in \(machineName); out of Command-Tab", category: "WindowsApps")
        }
        for (key, name) in open where current[key] == nil {
            guard let entry = launchEntry(machine: machine, machineName: machineName, key: key, name: name) else { continue }
            current[key] = entry
            AVMLog.write("Windows apps: \(name) open in \(machineName); in Command-Tab", category: "WindowsApps")
        }
        entries[machine] = current
    }

    // MARK: The Mac apps

    private func launchEntry(machine: UUID, machineName: String, key: String, name: String) -> Entry? {
        let digest = SHA256.hash(data: Data((machine.uuidString + "\n" + key).utf8))
        let bundleID = bundlePrefix + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        let title = "\(name) (\(machineName))"
        do {
            let url = try bundleURL(machine: machine, bundleID: bundleID, title: title)
            if !built.contains(bundleID) {
                try build(url, bundleID: bundleID, title: title, name: name, key: key, machine: machine, machineName: machineName)
                built.insert(bundleID)
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error {
                    AVMLog.write("Windows apps: \(title) didn't open: \(error.localizedDescription)", category: "WindowsApps")
                }
            }
            return Entry(bundleID: bundleID, name: name)
        } catch {
            AVMLog.write("Windows apps: couldn't make \(title): \(error.localizedDescription)", category: "WindowsApps")
            return nil
        }
    }

    /// AVM's folder for them, one per machine; the file name is the name
    /// Command-Tab shows.
    private func bundleURL(machine: UUID, bundleID: String, title: String) throws -> URL {
        let folder = try AVMPaths.supportDirectory()
            .appendingPathComponent("windows-apps", isDirectory: true)
            .appendingPathComponent(machine.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = String(title.map { "/:".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        return folder.appendingPathComponent((safe.isEmpty ? bundleID : safe) + ".app", isDirectory: true)
    }

    private func build(_ url: URL, bundleID: String, title: String, name: String, key: String,
                       machine: UUID, machineName: String) throws {
        let fm = FileManager.default
        guard let stub = Bundle.main.url(forAuxiliaryExecutable: "AVMWindowsApp") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "AVMWindowsApp isn't in AVM"])
        }
        try? fm.removeItem(at: url)
        let macOS = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.copyItem(at: stub, to: macOS.appendingPathComponent("AVMWindowsApp"))
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": title,
            "CFBundleDisplayName": title,
            "CFBundleExecutable": "AVMWindowsApp",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1",
            "CFBundleVersion": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            "LSMinimumSystemVersion": "13.0",
            "NSHighResolutionCapable": true,
            "AVMAppName": name,
            "AVMAppKey": key,
            "AVMMachineID": machine.uuidString,
            "AVMMachineName": machineName,
            "AVMControlSocket": ControlServer.socketURL?.path ?? "",
            "AVMBundleID": Bundle.main.bundleIdentifier ?? "",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
        // Signed for this Mac: the copy's signature is for AVM's bundle.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", url.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "codesign failed (\(sign.terminationStatus))"])
        }
    }

    private func quit(_ bundleID: String) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) { app.terminate() }
    }

    private func quitEntries(of machine: UUID) {
        for entry in (entries[machine] ?? [:]).values { quit(entry.bundleID) }
        entries[machine] = nil
    }

    /// From an AVM that didn't quit cleanly.
    private func quitLeftovers() {
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier?.hasPrefix(bundlePrefix) == true {
            app.terminate()
        }
    }

    // MARK: Command-Shift-E in one of them

    func enter(machine: UUID, appKey: String) async -> (ok: Bool, message: String) {
        guard let session = MachineSessions.shared.session(for: machine), session.vmState == .running else {
            return (false, "That machine isn't running.")
        }
        let manager = session.manager
        let name = entries[machine]?[appKey]?.name ?? "The app"
        requestNumber += 1
        let id = "\(requestNumber)-\(Int(Date().timeIntervalSince1970))"
        var problem: String?
        do {
            try await Self.writeGuestFile(manager, Self.guestFolder + #"\apps\request.txt"#, "\(id)\tfocus\t\(appKey)\n")
            problem = "Windows didn't answer"
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                guard let reply = try? await Self.readGuestFile(manager, Self.guestFolder + #"\apps\reply.txt"#) else { continue }
                let parts = reply.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.first == id else { continue }
                problem = parts.count > 1 && parts[1] == "ok" ? nil : (parts.count > 2 ? parts[2] : "it didn't come forward")
                break
            }
        } catch {
            problem = error.localizedDescription
        }
        if BackgroundMode.shared.inBackground { BackgroundMode.shared.comeForward(announce: false) }
        MachineSessions.shared.enter(machine)
        if let problem {
            AVMLog.write("Windows apps: \(name) didn't come forward in \(session.configuration.name): \(problem)", category: "WindowsApps")
            Announcer.shared.announce("\(name) didn't come forward in Windows: \(problem).", tone: .failure)
            return (true, "\(name) didn't come forward in Windows: \(problem).")
        }
        AVMLog.write("Windows apps: \(name) is in front in \(session.configuration.name); entering", category: "WindowsApps")
        return (true, "")
    }

    // MARK: The helper in Windows

    private func ensureHelper(_ manager: VMManager, machine: UUID) async -> Bool {
        guard !installing.contains(machine) else { return false }
        installing.insert(machine)
        defer { installing.remove(machine) }
        let version = try? await Self.readGuestFile(manager, Self.guestFolder + #"\bin\version.txt"#)
        if version?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.helperVersion {
            helperReady[machine] = manager.qemuPID
            return true
        }
        guard let source = Bundle.main.url(forResource: "AVMWindowsApps", withExtension: "cs"),
              let code = try? String(contentsOf: source, encoding: .utf8) else {
            AVMLog.write("Windows apps: AVMWindowsApps.cs isn't in AVM", category: "WindowsApps")
            return false
        }
        do {
            _ = try await manager.agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", Self.prepareScript], limit: .seconds(60))
            try await Self.writeGuestFile(manager, Self.guestFolder + #"\bin\AVMWindowsApps.cs"#, code)
            let output = try await manager.agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", Self.installScript(version: Self.helperVersion)], limit: .seconds(120))
            guard output.contains("AVM-INSTALLED") else {
                AVMLog.write("Windows apps: the helper didn't install: \(output.prefix(600))", category: "WindowsApps")
                return false
            }
            AVMLog.write("Windows apps: helper \(Self.helperVersion) installed in \(manager.machineName)", category: "WindowsApps")
            helperReady[machine] = manager.qemuPID
            return true
        } catch {
            // Most often the agent isn't up yet; the next look tries again.
            return false
        }
    }

    /// Folders, with the apps folder writable by the signed-in user, who
    /// writes the list and the replies; the old helper stopped.
    private static let prepareScript = #"""
        $ErrorActionPreference = 'Stop'
        New-Item -ItemType Directory -Force 'C:\ProgramData\AVM\bin','C:\ProgramData\AVM\apps' | Out-Null
        icacls 'C:\ProgramData\AVM\apps' /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
        Get-Process AVMWindowsApps -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 300
        """#

    /// Compiled with Windows' own .NET Framework compiler (Arm64 where
    /// there is one), then the task at sign-in, started now.
    private static func installScript(version: String) -> String {
        #"""
        $ErrorActionPreference = 'Stop'
        $csc = @('C:\Windows\Microsoft.NET\FrameworkArm64\v4.0.30319\csc.exe', 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $csc) { 'no C# compiler'; exit 1 }
        & $csc /nologo /target:winexe /platform:anycpu /optimize /out:C:\ProgramData\AVM\bin\AVMWindowsApps.exe C:\ProgramData\AVM\bin\AVMWindowsApps.cs
        if ($LASTEXITCODE -ne 0) { 'compile failed'; exit 1 }
        $action = New-ScheduledTaskAction -Execute 'C:\ProgramData\AVM\bin\AVMWindowsApps.exe'
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -Hidden
        Register-ScheduledTask -TaskPath '\AVM\' -TaskName 'Windows Apps' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Lets AVM on the Mac list the apps open in Windows and bring one forward.' -Force | Out-Null
        Start-ScheduledTask -TaskPath '\AVM\' -TaskName 'Windows Apps'
        Set-Content -Path 'C:\ProgramData\AVM\bin\version.txt' -Value '\#(version)' -Encoding ASCII
        'AVM-INSTALLED'
        """#
    }

    // MARK: Files in Windows, through the agent

    nonisolated static func readGuestFile(_ manager: VMManager, _ path: String) async throws -> String? {
        guard let handle = try await manager.agentCall(["execute": "guest-file-open", "arguments": ["path": path, "mode": "rb"]]) as? Int else { return nil }
        let read = try? await manager.agentCall(["execute": "guest-file-read", "arguments": ["handle": handle, "count": 262_144]]) as? [String: Any]
        _ = try? await manager.agentCall(["execute": "guest-file-close", "arguments": ["handle": handle]])
        guard let base64 = read?["buf-b64"] as? String, let data = Data(base64Encoded: base64) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func writeGuestFile(_ manager: VMManager, _ path: String, _ text: String) async throws {
        guard let handle = try await manager.agentCall(["execute": "guest-file-open", "arguments": ["path": path, "mode": "wb"]]) as? Int else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Windows couldn't make \(path)"])
        }
        _ = try await manager.agentCall(["execute": "guest-file-write", "arguments": ["handle": handle, "buf-b64": Data(text.utf8).base64EncodedString()]])
        _ = try await manager.agentCall(["execute": "guest-file-close", "arguments": ["handle": handle]])
    }
}
