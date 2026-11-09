// ScreenReaderSetup.swift
// AVM — Accessible Virtual Machine
//
// A person's screen reader setup, carried between machines (2026-11-01, the
// user's request): every new machine started from NVDA's or Orca's defaults,
// to be set up again by ear. Virtual Machine > Save Screen Reader Setup keeps a
// copy on the Mac of NVDA's settings folder, add-ons included, or Orca's;
// Apply puts it in another machine, keeping what was there beside it. AVM can
// also put it in each machine it installs (Settings, Watching Machines).
//
// The copy is a guest's archive: it's only ever unpacked in a guest, never on
// the Mac, and on Linux as the signed-in user. JAWS isn't carried: its
// settings are tied to its licence and version.

import Foundation

extension VMManager {

    /// Where saved setups live, one per screen reader.
    nonisolated static func screenReaderSetupFile(windows: Bool) throws -> URL {
        let folder = try AVMPaths.supportDirectory().appendingPathComponent("screen-reader-setups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(windows ? "nvda.zip" : "orca.tgz")
    }

    /// The largest setup kept: a settings folder, not a machine's files.
    nonisolated private static let largestSetup = 200 * 1024 * 1024

    /// A file from the guest onto the Mac, through its agent, up to `limit`.
    func copyFromGuest(_ path: String, to file: URL, limit: Int) async throws {
        guard let handle = try await openGuestFile(path, mode: "rb") else {
            throw AVMError.qmpCommandFailed("couldn't open \(path)")
        }
        var data = Data()
        do {
            while true {
                // An answer that isn't one is a failure, not the end of the
                // file (2026-11-09, fifth audit #34): half a setup was kept.
                guard let reply = try await agentCall(["execute": "guest-file-read", "arguments": ["handle": handle, "count": 1 << 20]]) as? [String: Any],
                      let chunk = (reply["buf-b64"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                    throw AVMError.refused("The machine stopped answering partway through the copy.")
                }
                data.append(chunk)
                guard data.count <= limit else { throw AVMError.refused("It's larger than AVM keeps.") }
                if reply["eof"] as? Bool == true { break }
            }
        } catch {
            try? await closeGuestFile(handle)
            throw error
        }
        try await closeGuestFile(handle)
        try data.write(to: file, options: .atomic)
    }

    /// Sets $u to the account signed in at Windows' own screen, or prints
    /// AVM-NOUSER and ends the script (2026-11-09, fourth audit #12): at the
    /// sign-in screen, or for someone signed in only over Remote Desktop,
    /// the name is empty and the path became C:\Users\AppData\Roaming.
    private var signedInUser: String {
        #"$u = (Get-CimInstance Win32_ComputerSystem).UserName; if ($u) { $u = $u.Split('\')[-1] }; if (-not $u) { 'AVM-NOUSER'; return }"#
    }

    /// Sets U and D to the desktop's user and their .local/share, in a
    /// Linux guest (2026-11-09, fifth audit #35): the session at the screen,
    /// not whoever has UID 1000. UID 1000 only when no one is at the screen,
    /// or it's the greeter's own account.
    private var linuxSignedInUser: String {
        #"""
        U=; S=$(loginctl show-seat seat0 -p ActiveSession --value 2>/dev/null)
        [ -n "$S" ] && U=$(loginctl show-session "$S" -p Name --value 2>/dev/null)
        [ -n "$U" ] && [ "$(id -u "$U" 2>/dev/null || echo 0)" -ge 1000 ] || U=$(getent passwd 1000 | cut -d: -f1)
        H=$(getent passwd "$U" | cut -d: -f6); D=$H/.local/share
        """#
    }

    /// Virtual Machine > Save Screen Reader Setup.
    func saveScreenReaderSetup() async {
        let machine = machineName
        let windows = runningGuestOS == .windows
        let name = windows ? "NVDA" : "Orca"
        do {
            let inGuest = windows ? #"C:\ProgramData\AVM\sr-setup.zip"# : "/tmp/avm-sr-setup.tgz"
            // As Apply does, before SYSTEM works there (2026-11-09, fifth
            // audit #36): on a machine that never had the Windows Apps helper
            // a standard user could have made the folder, or a link there,
            // first. The working copy's name can't be guessed either.
            if windows {
                _ = try await agentRun("powershell.exe", ["-NoProfile", "-Command", WindowsApps.lockDownScript], limit: .seconds(60))
            }
            // The earlier zip goes first and errors stop the script
            // (2026-11-09, fifth audit #34): a failed Compress-Archive left it
            // there, still said AVM-OK, and the old setup was saved as new.
            let out = windows
                ? try await agentRun("powershell.exe", ["-NoProfile", "-Command", """
                    $ErrorActionPreference = 'Stop'
                    try {
                      \(signedInUser)
                      $d = "C:\\Users\\$u\\AppData\\Roaming\\nvda"
                      Remove-Item -Force '\(inGuest)' -ErrorAction SilentlyContinue
                      if (Test-Path "$d\\nvda.ini") {
                        $t = "C:\\ProgramData\\AVM\\sr-copy-" + [guid]::NewGuid().ToString('N')
                        try {
                          robocopy $d $t /E /XF *.log /XD updates | Out-Null
                          if ($LASTEXITCODE -ge 8) { throw "robocopy stopped with $LASTEXITCODE" }
                          Compress-Archive -Force -Path "$t\\*" -DestinationPath '\(inGuest)'
                          'AVM-OK'
                        } finally { Remove-Item -Recurse -Force $t -ErrorAction SilentlyContinue }
                      } else { 'AVM-NONE' }
                    } catch { "AVM-FAILED $($_.Exception.Message)" }
                    """], limit: .seconds(180))
                : try await agentRun("/bin/sh", ["-c", """
                    \(linuxSignedInUser)
                    rm -f \(inGuest)
                    if [ -d "$D/orca" ]; then tar czf \(inGuest) -C "$D" orca && echo AVM-OK; else echo AVM-NONE; fi
                    """], limit: .seconds(120))
            if out.contains("AVM-NOUSER") {
                Announcer.shared.announce("\(name)'s setup couldn't be saved from \(machine). Reason: no one is signed in at its own screen. Next: sign in to \(machine) in its window, then try again.", tone: .failure)
                return
            }
            if out.contains("AVM-NONE") {
                Announcer.shared.announce("\(machine) has no \(name) settings to save. Next: sign in to \(machine), change a \(name) setting, then try again.", tone: .failure)
                return
            }
            guard out.contains("AVM-OK") else {
                AVMLog.write("AVM: Screen reader setup — the copy in the guest failed: \(out.prefix(300))")
                throw AVMError.refused("The copy inside the machine didn't finish.")
            }
            let file = try Self.screenReaderSetupFile(windows: windows)
            // The guest's copy goes either way (2026-11-09, fifth audit #35).
            var copyError: Error?
            do { try await copyFromGuest(inGuest, to: file, limit: Self.largestSetup) } catch { copyError = error }
            _ = windows
                ? try? await agentRun("powershell.exe", ["-NoProfile", "-Command", "Remove-Item -Force '\(inGuest)' -ErrorAction SilentlyContinue"], limit: .seconds(30))
                : try? await agentRun("/bin/rm", ["-f", inGuest], limit: .seconds(30))
            if let copyError { throw copyError }
            AVMLog.write("AVM: Screen reader setup — \(name)'s saved from \(machine)")
            Announcer.shared.announce("\(name)'s setup is saved from \(machine). Next: in another machine, choose Virtual Machine, Apply Saved Screen Reader Setup.", tone: .success)
        } catch {
            AVMLog.write("AVM: Screen reader setup — not saved: \(error.localizedDescription)")
            Announcer.shared.announce("\(name)'s setup couldn't be saved from \(machine). Reason: \(error.localizedDescription) Next: make sure \(machine) has finished starting, then try again.", tone: .failure)
        }
    }

    /// Whether there's a saved setup for this kind of machine.
    var hasSavedScreenReaderSetup: Bool {
        guard runningGuestOS != .macOS, let file = try? Self.screenReaderSetupFile(windows: runningGuestOS == .windows) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
    }

    /// Virtual Machine > Apply Saved Screen Reader Setup, and each new machine
    /// when that's chosen. What was there stays beside it, as nvda-before-avm
    /// or orca-before-avm. The running reader stops first, or it would write
    /// its old settings over these as it quits; GuestWatch then starts it.
    /// Unpacked and checked beside the settings, then swapped (2026-11-09,
    /// fifth audit #5): a failed unpack used to leave defaults or half a
    /// setup. The true original is never replaced: a later Apply keeps what
    /// it replaces in -before-avm-last.
    @discardableResult
    func applyScreenReaderSetup() async -> Bool {
        let machine = machineName
        let windows = runningGuestOS == .windows
        let name = windows ? "NVDA" : "Orca"
        do {
            let file = try Self.screenReaderSetupFile(windows: windows)
            guard FileManager.default.fileExists(atPath: file.path) else {
                Announcer.shared.announce("No \(name) setup is saved yet. Next: in a machine set up as you like it, choose Virtual Machine, Save Screen Reader Setup.", tone: .failure)
                return false
            }
            let inGuest = windows ? #"C:\ProgramData\AVM\sr-setup.zip"# : "/tmp/avm-sr-setup.tgz"
            if windows {
                _ = try await agentRun("powershell.exe", ["-NoProfile", "-Command", WindowsApps.lockDownScript], limit: .seconds(60))
            }
            try await copyToGuest(file, to: inGuest)
            let out = windows
                ? try await agentRun("powershell.exe", ["-NoProfile", "-Command", """
                    $ErrorActionPreference = 'Stop'
                    try {
                      \(signedInUser)
                      $d = "C:\\Users\\$u\\AppData\\Roaming\\nvda"; $n = "$d-avm-new"
                      Stop-Process -Name nvda -Force -ErrorAction SilentlyContinue; Start-Sleep 2
                      if (Test-Path $n) { Remove-Item -Recurse -Force $n }
                      Add-Type -AssemblyName System.IO.Compression.FileSystem
                      $z = [IO.Compression.ZipFile]::OpenRead('\(inGuest)')
                      try {
                        foreach ($e in $z.Entries) {
                          if ($e.FullName -match '^[\\\\/]|\\.\\.[\\\\/]|^[A-Za-z]:|\\.\\.$') { throw "unsafe entry $($e.FullName)" }
                          $t = Join-Path $n $e.FullName
                          if ($e.FullName -match '[\\\\/]$') { New-Item -ItemType Directory -Force $t | Out-Null; continue }
                          New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null
                          [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $t, $true)
                        }
                      } finally { $z.Dispose() }
                      if (-not (Test-Path "$n\\nvda.ini")) { throw 'the setup has no nvda.ini' }
                      $moved = $null
                      if (Test-Path $d) {
                        $moved = "$d-before-avm"
                        if (Test-Path $moved) {
                          $moved = "$d-before-avm-last"
                          if (Test-Path $moved) { Remove-Item -Recurse -Force $moved }
                        }
                        Move-Item $d $moved
                      }
                      try { Move-Item $n $d } catch { if ($moved) { Move-Item $moved $d }; throw }
                      'AVM-OK'
                    } finally {
                      Remove-Item -Force '\(inGuest)' -ErrorAction SilentlyContinue
                      if ($n -and (Test-Path $n)) { Remove-Item -Recurse -Force $n -ErrorAction SilentlyContinue }
                    }
                    """], limit: .seconds(180))
                : try await agentRun("/bin/sh", ["-c", """
                    \(linuxSignedInUser)
                    N="$D/.avm-orca-new"
                    pkill -x orca; sleep 2
                    chown "$U" \(inGuest); chmod 600 \(inGuest)
                    runuser -u "$U" -- sh -c "mkdir -p '$D' && rm -rf '$N' && mkdir '$N' && tar xzf \(inGuest) -C '$N' --no-same-owner && [ -d '$N/orca' ] && { M=; if [ -d '$D/orca' ]; then M='$D/orca-before-avm'; if [ -d \\"\\$M\\" ]; then M='$D/orca-before-avm-last'; rm -rf \\"\\$M\\"; fi; mv '$D/orca' \\"\\$M\\" || exit 1; fi; if mv '$N/orca' '$D/orca'; then echo AVM-OK; elif [ -n \\"\\$M\\" ]; then mv \\"\\$M\\" '$D/orca'; fi; }; rm -rf '$N'"
                    rm -f \(inGuest)
                    """], limit: .seconds(120))
            guard !out.contains("AVM-NOUSER") else { throw AVMError.refused("No one is signed in at its own screen.") }
            guard out.contains("AVM-OK") else { throw AVMError.qmpCommandFailed("it didn't unpack") }
            AVMLog.write("AVM: Screen reader setup — \(name)'s applied in \(machine)")
            Announcer.shared.announce("Your \(name) setup is in \(machine) now, and AVM is starting \(name) again.", tone: .success)
            return true
        } catch {
            AVMLog.write("AVM: Screen reader setup — not applied: \(error.localizedDescription)")
            Announcer.shared.announce("Your \(name) setup couldn't be put in \(machine). Reason: \(error.localizedDescription) Next: make sure someone is signed in to \(machine), then try again.", tone: .failure)
            return false
        }
    }
}
