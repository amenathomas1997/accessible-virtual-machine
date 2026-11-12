// FromAVM.swift
// Guest House — accessible virtual machines
//
// The app was called AVM until 2026-11-12, the name of Allison Meloy's
// original, which this is a fork of; a reader of the release feed took a
// release for hers, and asked for a name of its own. With the name went
// the identifier (com.fullcircleat.AVM), and macOS keys an app's support
// folder, settings and keychain items to that. So a copy that updates
// from AVM would open with no machines. This brings them across, once,
// at the first launch, before anything reads them:
//   1. the app's own file: an update leaves it at AVM.app, so it is
//      renamed Guest House.app and opened again from there;
//   2. the support folder (machines, installers, logs, backups), moved,
//      with the paths inside its lists pointed at the new place;
//   3. the settings, copied;
//   4. the Windows apps kept in Applications, their folder renamed.
// Keychain items (Remote Desktop passwords, the Describe Screen key) come
// across when they are first asked for (KeychainFromAVM, in
// RemoteDesktopAddress.swift): macOS asks
// the user for each, since another app made them.
// Not brought across, because macOS doesn't let one app speak for
// another: the permissions (Input Monitoring, camera, microphone, local
// network), the USB helper's approval and Open at Login. Guest House
// asks for each as AVM did the first time.
// Nothing of AVM's is deleted: what isn't moved stays where it was.

import AppKit

enum FromAVM {

    nonisolated static let oldIdentifier = "com.fullcircleat.AVM"
    private nonisolated static let doneKey = "CameFromAVM"
    /// Said once the list is up (AVMApp), when machines came across.
    nonisolated(unsafe) static var toSay: String?
    /// True in the launch that brought things across: the Dock's tiles are
    /// pointed at the new names once the app is up.
    private nonisolated(unsafe) static var carriedNow = false
    /// For the log, which can't be written before the folder has moved.
    private nonisolated(unsafe) static var notes: [String] = []

    /// Only Guest House proper: not a test's copy (its identifier ends
    /// .test or .audit), not a run with arguments or a test's own folder.
    private static var applies: Bool {
        guard let id = Bundle.main.bundleIdentifier, id != oldIdentifier, id.hasSuffix(".GuestHouse") else { return false }
        return CommandLine.arguments.count == 1 && ProcessInfo.processInfo.environment["AVM_TEST_SUPPORT_DIR"] == nil
    }

    /// --test-from-avm <Library folder>: the folder move and the paths, on a
    /// made-up Library, so the test never touches the user's own. Prints
    /// what it did and exits.
    /// --test-from-avm-rename <file>: a copy named AVM.app renames itself and
    /// opens again, and the copy opened writes where it is to the file.
    private static func runTestIfAsked() {
        let args = CommandLine.arguments
        if let at = args.firstIndex(of: "--test-from-avm-renamed"), at + 1 < args.count {
            try? "reopened at \(Bundle.main.bundleURL.path)\n".write(toFile: args[at + 1], atomically: true, encoding: .utf8)
            exit(0)
        }
        if let at = args.firstIndex(of: "--test-from-avm-rename"), at + 1 < args.count {
            renameTheAppItself(FileManager.default, testReport: args[at + 1])
            for note in notes { print(note) }
            print("RESULT not renamed")
            exit(1)
        }
        guard let at = args.firstIndex(of: "--test-from-avm"), at + 1 < args.count else { return }
        let library = URL(fileURLWithPath: args[at + 1], isDirectory: true)
        let moved = moveSupportFolder(from: library.appendingPathComponent("Application Support/\(oldIdentifier)", isDirectory: true),
                                      to: library.appendingPathComponent("Application Support/com.fullcircleat.GuestHouse", isDirectory: true),
                                      FileManager.default)
        for note in notes { print(note) }
        print(moved ? "RESULT moved" : "RESULT not moved")
        exit(0)
    }

    /// From AVMApp.init, before the machine list, the log or the updater exist.
    static func carryOver() {
        runTestIfAsked()
        guard applies else { return }
        let fm = FileManager.default
        renameTheAppItself(fm)
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: doneKey) == nil else { return }
        guard let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first, let id = Bundle.main.bundleIdentifier else { return }
        let old = library.appendingPathComponent("Application Support/\(oldIdentifier)", isDirectory: true)
        let new = library.appendingPathComponent("Application Support/\(id)", isDirectory: true)
        let hadAVM = fm.fileExists(atPath: old.path) || defaults.persistentDomain(forName: oldIdentifier) != nil
        guard hadAVM else {
            defaults.set("no AVM here", forKey: doneKey)
            return
        }
        // AVM still open (both installed): its machines may be running, and
        // it writes its list back. Tried again at the next launch.
        if !NSRunningApplication.runningApplications(withBundleIdentifier: oldIdentifier).isEmpty {
            toSay = "AVM is open, so Guest House hasn't brought your machines across from it. Next: quit AVM, then quit and reopen Guest House."
            notes.append("AVM is running; nothing brought across this time")
            return
        }
        copySettings(defaults)
        let moved = moveSupportFolder(from: old, to: new, fm)
        renameWindowsAppsFolders(fm)
        defaults.set(ISO8601DateFormatter().string(from: Date()), forKey: doneKey)
        carriedNow = true
        if moved {
            toSay = "AVM is now called Guest House. Your machines and settings came across. macOS will ask again for the permissions AVM had, and for the USB helper in Login Items."
        }
    }

    /// The notes above, once the log can be written, and the spoken line.
    @MainActor static func report() {
        for note in notes { AVMLog.write("Guest House: from AVM — \(note)") }
        notes = []
        if carriedNow {
            carriedNow = false
            WindowsApps.repointDockAfterRename(from: oldIdentifier)
        }
        guard let line = toSay else { return }
        toSay = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            Announcer.shared.announce(line, tone: .info)
        }
    }

    // MARK: 1. The app's file

    /// An update replaces the app where it is, so it is still AVM.app in
    /// Finder, the Dock and Command-Tab's path. Renamed beside itself and
    /// opened again; left alone when the name is taken or the folder can't
    /// be written.
    private static func renameTheAppItself(_ fm: FileManager, testReport: String? = nil) {
        let here = Bundle.main.bundleURL
        guard here.lastPathComponent == "AVM.app" else { return }
        let there = here.deletingLastPathComponent().appendingPathComponent("Guest House.app", isDirectory: true)
        guard !fm.fileExists(atPath: there.path) else {
            notes.append("the app is still at \(here.path): \(there.lastPathComponent) is already beside it")
            return
        }
        do {
            try fm.moveItem(at: here, to: there)
        } catch {
            notes.append("the app is still at \(here.path): \(error.localizedDescription)")
            return
        }
        // Opened once this process has gone (2026-11-12): opened at once, the
        // new one found this one still listed, took it for a second copy
        // (AVMAppDelegate's one-at-a-time check) and quit, and nothing was open.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/bin/sh")
        let extra = testReport.map { ["--args", "--test-from-avm-renamed", $0] } ?? []
        open.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open -n \"$@\"",
                          "\(ProcessInfo.processInfo.processIdentifier)", there.path] + extra
        do {
            try open.run()
            exit(0)
        } catch {
            // Carry on from the moved bundle: it runs, and the next launch
            // is from the new name.
            notes.append("renamed to \(there.path), but couldn't be opened again from there: \(error.localizedDescription)")
        }
    }

    // MARK: 2. The support folder

    /// True when AVM's folder, or what was in it, is now Guest House's.
    private static func moveSupportFolder(from old: URL, to new: URL, _ fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: old.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if !fm.fileExists(atPath: new.path) {
            do {
                try fm.moveItem(at: old, to: new)
                notes.append("moved \(old.path) to \(new.path)")
            } catch {
                notes.append("couldn't move \(old.path): \(error.localizedDescription)")
                toSay = "Guest House couldn't bring your machines across from AVM: \(error.localizedDescription) They are still in AVM's folder, untouched."
                return false
            }
        } else if !fm.fileExists(atPath: new.appendingPathComponent("configurations.json").path) {
            // Guest House's folder is there but has no machine list (a log
            // written early, say): AVM's things go in beside what it has.
            var left = 0
            for item in (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? [] {
                let target = new.appendingPathComponent(item.lastPathComponent)
                if fm.fileExists(atPath: target.path) { left += 1; continue }
                do { try fm.moveItem(at: item, to: target) } catch { left += 1 }
            }
            notes.append("moved what was in \(old.path) into \(new.path); \(left) item(s) stayed behind")
        } else {
            notes.append("\(new.path) already has a machine list; \(old.path) left as it is")
            return false
        }
        repoint(in: new, from: old, fm)
        return true
    }

    /// The machine list and the small files beside each machine hold whole
    /// paths (a disk, an installer). JSONEncoder writes "/" as "\/".
    private static func repoint(in new: URL, from old: URL, _ fm: FileManager) {
        var files = (try? fm.contentsOfDirectory(at: new, includingPropertiesForKeys: nil)) ?? []
        for machine in (try? fm.contentsOfDirectory(at: new.appendingPathComponent("VMs"), includingPropertiesForKeys: nil)) ?? [] {
            files += (try? fm.contentsOfDirectory(at: machine, includingPropertiesForKeys: nil)) ?? []
        }
        let pairs = [(old.path + "/", new.path + "/"), (old.path + "\"", new.path + "\"")]
        var changed = 0
        for file in files where ["json", "plist", "txt"].contains(file.pathExtension.lowercased()) {
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 8 * 1024 * 1024,
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var out = text
            for (from, to) in pairs {
                out = out.replacingOccurrences(of: from, with: to)
                out = out.replacingOccurrences(of: from.replacingOccurrences(of: "/", with: "\\/"),
                                               with: to.replacingOccurrences(of: "/", with: "\\/"))
            }
            guard out != text else { continue }
            do {
                try out.write(to: file, atomically: true, encoding: .utf8)
                changed += 1
            } catch {
                notes.append("couldn't point \(file.lastPathComponent) at the new folder: \(error.localizedDescription)")
            }
        }
        notes.append("\(changed) file(s) pointed at the new folder")
    }

    // MARK: 3. The settings

    private static func copySettings(_ defaults: UserDefaults) {
        guard let old = defaults.persistentDomain(forName: oldIdentifier), let id = Bundle.main.bundleIdentifier else { return }
        let mine = defaults.persistentDomain(forName: id) ?? [:]
        var copied = 0
        for (key, value) in old where mine[key] == nil {
            defaults.set(value, forKey: key)
            copied += 1
        }
        notes.append("\(copied) setting(s) copied")
    }

    // MARK: 4. Windows apps kept in Applications

    /// The apps inside are found by what their Info.plist says, not by
    /// their identifier (WindowsApps.pinnedBundles), so they carry on.
    private static func renameWindowsAppsFolders(_ fm: FileManager) {
        for new in [WindowsApps.pinnedFolder, WindowsApps.homePinnedFolder] {
            let old = new.deletingLastPathComponent().appendingPathComponent("AVM Windows Apps", isDirectory: true)
            guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { continue }
            do {
                try fm.moveItem(at: old, to: new)
                notes.append("renamed \(old.path)")
            } catch {
                notes.append("couldn't rename \(old.path): \(error.localizedDescription)")
            }
        }
    }
}
