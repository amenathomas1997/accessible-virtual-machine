// RemoveAVM.swift
// Guest House — accessible virtual machines
//
// Guest House > Remove Guest House… (2026-10-30, the user's request): taking Guest House off a Mac
// took a Terminal command with an administrator password, because the USB
// helper is a system service that only Guest House itself, or root, can remove;
// dragging the app to the Trash left it registered and failing to start.
// This does it all from Guest House, while Guest House can still unregister its own
// services:
//   1. the USB helper (SMAppService daemon) and the open-at-login item;
//   2. Guest House's caches, settings and the Guest House Windows Apps folders;
//   3. the virtual machines and Guest House's support folder, only when chosen;
//   4. the app itself, last, then Guest House quits.
// Everything goes to the Trash, so it can be put back until the Trash is
// emptied. Not with a machine running: its disk would go mid-write.

import AppKit
import ServiceManagement

@MainActor
enum RemoveAVM {

    static func ask() {
        if MachineSessions.shared.anyActive || MacGuestRunner.shared.runningID != nil {
            Announcer.shared.announce("Shut down every virtual machine first, then choose Remove Guest House again.", tone: .info)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove Guest House from this Mac?"
        alert.informativeText = "Guest House removes its USB helper and its login item, then moves its settings, caches and the Guest House Windows Apps folder to the Trash, then the app itself, and quits. Remove Guest House and Its Machines also moves every virtual machine on this Mac's disk, and the installers Guest House downloaded, to the Trash, and forgets their Remote Desktop passwords. Machines on external drives or in folders you chose stay where they are. Nothing else is gone until you empty the Trash."
        // Cancel first, as every other destructive question has it
        // (2026-11-09, third audit of the day #8): Return on what sounds like
        // an information dialog removed Guest House.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove Guest House, Keep Machines")
        alert.addButton(withTitle: "Remove Guest House and Its Machines")
        switch alert.runModal() {
        case .alertSecondButtonReturn: remove(machinesToo: false)
        case .alertThirdButtonReturn: remove(machinesToo: true)
        default: return
        }
    }

    private static func remove(machinesToo: Bool) {
        AVMLog.write("Guest House: Remove Guest House — starting (machines too: \(machinesToo)).")
        var problems: [String] = []
        let fm = FileManager.default

        // 1. The services, while Guest House can still unregister its own.
        USBHelperClient.shared.disconnect()
        do {
            try SMAppService.daemon(plistName: AVMUSBHelperNames.launchdPlistName).unregister()
        } catch {
            problems.append("the USB helper (\(error.localizedDescription))")
        }
        if SMAppService.mainApp.status != .notRegistered {
            do { try SMAppService.mainApp.unregister() } catch { problems.append("the login item (\(error.localizedDescription))") }
        }

        // 2 and 3. The files.
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let id = Bundle.main.bundleIdentifier ?? "com.fullcircleat.GuestHouse"
        // Read before the list goes to the Trash (2026-11-09, fourth audit #24).
        let machineIDs = VMStore.shared?.configurations.map(\.id) ?? []
        var items = [
            library.appendingPathComponent("Caches/\(id)"),
            library.appendingPathComponent("HTTPStorages/\(id)"),
            library.appendingPathComponent("Saved Application State/\(id).savedState"),
            WindowsApps.pinnedFolder,
            WindowsApps.homePinnedFolder,
        ]
        if machinesToo, let support = try? AVMPaths.supportDirectory() {
            items.append(support)
        }
        for item in items where fm.fileExists(atPath: item.path) {
            do { try fm.trashItem(at: item, resultingItemURL: nil) } catch {
                problems.append("\(item.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        // Remote Desktop passwords stayed in the keychain (fourth audit #24).
        // Only once the machine list really went to the Trash, so a failed
        // move doesn't leave machines that have lost their passwords.
        if machinesToo, let support = try? AVMPaths.supportDirectory(), !fm.fileExists(atPath: support.path) {
            for machine in machineIDs { RemoteDesktop.forgetPassword(for: machine) }
        }
        UserDefaults.standard.removePersistentDomain(forName: id)
        UserDefaults.standard.synchronize()

        // 4. The app, last.
        do {
            try fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        } catch {
            problems.append("the app (\(error.localizedDescription)); drag it to the Trash from Applications")
        }

        if problems.isEmpty {
            AVMLog.write("Guest House: Remove Guest House — done.")
            Announcer.shared.announce("Guest House is removed and in the Trash. It quits now.", tone: .success)
        } else {
            AVMLog.write("Guest House: Remove Guest House — done, except: \(problems.joined(separator: "; ")).")
            Announcer.shared.announce("Guest House is removed, except: \(problems.joined(separator: "; ")). It quits now.", tone: .info)
        }
        NSApp.terminate(nil)
    }
}
