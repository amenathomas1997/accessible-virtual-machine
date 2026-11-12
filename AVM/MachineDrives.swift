// MachineDrives.swift
// Guest House — accessible virtual machines
//
// More disk (2026-11-03, the user's request, "sorta like upgrading your pc").
//   - How full: the dashboard shows what the disk watch last heard from the guest
//     agent, kept in the machine's folder so a stopped machine still has a figure.
//   - Growing: Settings makes the disk larger, and the next Start gives Windows'
//     drive C the new space. A Linux machine's layout differs by distribution, so
//     that stays a step for the user.
//   - A second drive: its own qcow2 in the machine's folder, on the same kind of
//     connection as the first, made ready by the guest at the next Start. Restore
//     points and saves name both disks, so they go back together. Copies and exports
//     take everything in the folder, so it goes with them.
//   There's no removing a second drive yet, as a disk can't shrink either.

import AppKit
import Combine
import Foundation

/// What a machine kept in a folder of the user's choosing looks like right now.
nonisolated struct StorageStatus: Equatable, Sendable {
    let missing: Bool
    let onMacBytes: Int64?
    let availableBytes: Int?
    var hasMacSavedState = false
    /// A Windows or Linux machine's saved-session hint (2026-11-10, fourth
    /// audit of 2026-11-09 #12).
    var hasQEMUSavedHint = false
}

/// Checks on machines kept outside Guest House's own folder, off the main thread
/// (2026-11-09, fifth audit #17). SwiftUI bodies asked the file system on every
/// redraw, and on a share gone away without unmounting, or a drive spinning up,
/// that held the main thread for the mount's timeout: the dashboard stopped
/// answering VoiceOver and running machines' menu commands waited. Views read
/// the last answer here. Start, Delete and the other actions still ask the disk
/// themselves, so an old answer can't let one through.
@MainActor
final class StorageWatch: ObservableObject {
    static let shared = StorageWatch()
    @Published private var statuses: [UUID: StorageStatus] = [:]

    nonisolated private struct Entry: Equatable, Sendable {
        let folder: String
        let volumeUUID: String?
        let disk: String
    }
    private var entries: [UUID: Entry] = [:]
    private var checking = false
    private var checkAgain = false
    private var lastCheck = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
    }

    /// The last answer; nil for a machine in Guest House's own folder or not yet checked.
    /// Safe in a body: the check starts on a later turn and publishes when done.
    func status(of configuration: VMConfiguration) -> StorageStatus? {
        guard let folder = configuration.storageFolderPath else { return nil }
        let entry = Entry(folder: folder, volumeUUID: configuration.storageVolumeUUID, disk: configuration.diskImagePath)
        let isNew = entries[configuration.id] != entry
        if isNew { entries[configuration.id] = entry }
        // A folder can go without an unmount, so answers also age out.
        if isNew || Date().timeIntervalSince(lastCheck) > 15 {
            lastCheck = Date()
            DispatchQueue.main.async { [weak self] in self?.check() }
        }
        return statuses[configuration.id]
    }

    /// For the dashboard (2026-11-10, fourth audit of 2026-11-09 #12): a
    /// machine in a folder of the user's choosing is answered from the last
    /// check, so a sleeping or gone drive doesn't stall every redraw. One in
    /// Guest House's own folder is read at once, as before.
    func looksSaved(_ configuration: VMConfiguration) -> Bool {
        guard configuration.storageFolderPath != nil else { return QEMUSavedState.looksSaved(configuration) }
        return status(of: configuration)?.hasQEMUSavedHint ?? false
    }

    /// Looks again now: a machine stopped or was saved (review of the fourth
    /// audit of 2026-11-09 #12), so "Saved" isn't stale until a redraw.
    func refresh() { check() }

    /// False until known otherwise: Start refuses by its own check anyway.
    func isMissing(_ configuration: VMConfiguration) -> Bool {
        status(of: configuration)?.missing ?? false
    }

    private func check() {
        guard !checking else { checkAgain = true; return }
        if let store = VMStore.shared {
            let live = Set(store.configurations.map(\.id))
            entries = entries.filter { live.contains($0.key) }
        }
        checking = true
        lastCheck = Date()
        let snapshot = entries
        Task.detached(priority: .utility) { [weak self] in
            let answers = snapshot.mapValues { StorageWatch.measure($0) }
            await MainActor.run {
                guard let self else { return }
                self.checking = false
                if self.statuses != answers { self.statuses = answers }
                if self.checkAgain {
                    self.checkAgain = false
                    self.check()
                }
            }
        }
    }

    nonisolated private static func measure(_ entry: Entry) -> StorageStatus {
        let resolved = VMConfiguration.resolvedStoragePath(entry.folder, volumeUUID: entry.volumeUUID)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue else {
            return StorageStatus(missing: true, onMacBytes: nil, availableBytes: nil)
        }
        let folder = URL(fileURLWithPath: resolved, isDirectory: true)
        func allocated(_ url: URL) -> Int64? {
            (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize.map(Int64.init)
        }
        var bytes: Int64?
        if !entry.disk.isEmpty, let disk = allocated(URL(fileURLWithPath: VMConfiguration.resolvedDiskPath(entry.disk, inFolder: folder))) {
            bytes = disk + (allocated(folder.appendingPathComponent(VMConfiguration.secondDriveFileName)) ?? 0)
        }
        let available = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
        return StorageStatus(missing: false, onMacBytes: bytes, availableBytes: available,
                             hasMacSavedState: FileManager.default.fileExists(atPath: MacGuestFiles(folder: folder).savedState.path),
                             hasQEMUSavedHint: FileManager.default.fileExists(atPath: QEMUSavedState.hint(in: folder).path))
    }
}

/// What each machine's drives last said.
@MainActor
final class DiskUsage: ObservableObject {
    static let shared = DiskUsage()
    @Published private var known: [UUID: [DiskWatch.Drive]] = [:]
    private var loading = Set<UUID>()

    nonisolated private struct Saved: Codable {
        let name: String
        let used: Int64
        let total: Int64
    }

    func drives(of configuration: VMConfiguration) -> [DiskWatch.Drive] {
        if let drives = known[configuration.id] { return drives }
        // Read once, off the main thread (2026-11-09, third audit of the day
        // #10): the dashboard's body asked at every redraw, and resolving the
        // folder and reading the file on a gone network share or a drive
        // spinning up stalled the dashboard, its menus and speech.
        let id = configuration.id
        guard !loading.contains(id) else { return [] }
        loading.insert(id)
        // The folder once, here (review): directoryURL is main-actor code.
        let file = (try? configuration.directoryURL())?.appendingPathComponent(DiskWatch.usageFileName)
        Task.detached(priority: .utility) {
            let read: [DiskWatch.Drive]
            if let file,
               let data = try? Data(contentsOf: file),
               let saved = try? JSONDecoder().decode([Saved].self, from: data) {
                read = saved.map { DiskWatch.Drive(name: $0.name, used: $0.used, total: $0.total) }
            } else {
                read = []
            }
            await MainActor.run {
                let usage = DiskUsage.shared
                usage.loading.remove(id)
                if usage.known[id] == nil { usage.known[id] = read }
            }
        }
        return []
    }

    func note(_ drives: [DiskWatch.Drive], machine: UUID, folder: URL) {
        guard known[machine] != drives else { return }
        known[machine] = drives
        if let data = try? JSONEncoder().encode(drives.map { Saved(name: $0.name, used: $0.used, total: $0.total) }) {
            try? data.write(to: folder.appendingPathComponent(DiskWatch.usageFileName), options: .atomic)
        }
    }

    /// What a machine's disks take on the Mac: only what has been written, as they
    /// grow as they're used. Nil when they can't be read, such as on a drive that
    /// isn't connected.
    func onMacBytes(of configuration: VMConfiguration) -> Int64? {
        // Off the main thread for a chosen folder (2026-11-09, fifth audit
        // #17), and on the disk's current path (#12): the dashboard's body
        // calls this. Guest House's own folder is on the Mac's disk and answers at once.
        if configuration.isStoredElsewhere { return StorageWatch.shared.status(of: configuration)?.onMacBytes }
        func allocated(_ url: URL) -> Int64? {
            (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize.map(Int64.init)
        }
        guard !configuration.diskImagePath.isEmpty,
              let disk = allocated(URL(fileURLWithPath: configuration.diskImagePath)) else { return nil }
        let second = (try? configuration.directoryURL()).flatMap(RestorePoints.secondDrive).flatMap(allocated) ?? 0
        return disk + second
    }

    /// The disk changed size, so the figures are old.
    func forget(machine: UUID, folder: URL) {
        known[machine] = []
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(DiskWatch.usageFileName))
    }
}

extension VMManager {
    /// The second drive, on the same kind of connection as the first: a machine
    /// on NVMe may have no virtio driver.
    func secondDriveArguments(configuration: VMConfiguration) -> [String] {
        guard configuration.secondDriveGB != nil, let folder = try? configuration.directoryURL(),
              let file = RestorePoints.secondDrive(folder) else { return [] }
        let device = configuration.usesVirtioDisk ? "virtio-blk-pci,drive=disk1,serial=avmdisk1" : "nvme,drive=disk1,serial=avmdisk1"
        return ["-drive", "if=none,id=disk1,file=\(Self.qemuOptionValue(file.path)),format=qcow2,cache=writeback,discard=unmap,detect-zeroes=unmap,werror=stop,rerror=stop",
                "-device", device]
    }

    /// What a snapshot names: the first disk's node and the second's. With only
    /// the first, carrying on from a restore point would put memory back over a
    /// second drive that had moved on, which ruins its file system.
    func snapshotDevices(_ node: String) async throws -> [String] {
        let blocks = try await sendQMPCommand("query-block", arguments: nil) as? [[String: Any]] ?? []
        guard let second = blocks.first(where: { $0["device"] as? String == "disk1" }),
              let inserted = second["inserted"] as? [String: Any],
              let name = inserted["node-name"] as? String else { return [node] }
        return [node, name]
    }

    /// Once the guest agent answers: drive C takes the new space, and a new second
    /// drive is made ready. Each is noted as done only when the guest has said how
    /// it went, so one that couldn't be asked is tried again at the next Start.
    func finishDiskChanges(configuration: VMConfiguration) async {
        guard await waitForGuestAgent(limit: .seconds(600)) else {
            AVMLog.write("Guest House: finishDiskChanges - the guest agent didn't answer; trying again at the next Start")
            return
        }
        let machine = configuration.name
        if configuration.extendDriveC == true, configuration.guestOS == .windows,
           let output = try? await agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "-"],
                                            limit: .seconds(180), input: DiskWatch.extendDriveCScript + "\n") {
            let answer = DiskWatch.answer(output)
            AVMLog.write("Guest House: finishDiskChanges - drive C: \(answer?.word ?? "no answer")")
            switch answer?.word {
            case "extended":
                Announcer.shared.announce("\(machine)'s drive C is now \(answer?.detail ?? "") gigabytes.", tone: .success)
            // Already all of it (2026-11-09, third audit of the day #18): a
            // restore point from after the disk was grown and extended put
            // the partition back whole, and "a partition is in the way" was
            // said of it.
            case "same":
                break
            case "blocked":
                Announcer.shared.announce("\(machine)'s drive C couldn't take the new space: a partition after it is in the way. The README's section on making a disk larger says what to do next.", tone: .failure)
            default:
                Announcer.shared.announce("\(machine)'s drive C couldn't take the new space. A partition may be in the way. The README's section on making a disk larger says what to do next.", tone: .failure)
            }
            storeDiskChange(configuration) { $0.extendDriveC = nil }
        }
        let needsFormat = configuration.secondDriveNeedsFormat == true
        if needsFormat || configuration.guestOS.isLinux, let size = configuration.secondDriveGB {
            let output = configuration.guestOS == .windows
                ? try? await agentRun("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", "-"],
                                      limit: .seconds(180), input: DiskWatch.formatWindowsDriveScript(sizeGB: size) + "\n")
                : try? await agentRun("/bin/sh", ["-c", DiskWatch.linuxDriveScript(format: needsFormat)], limit: .seconds(180))
            guard let output else { return }
            let answer = DiskWatch.answer(output)
            AVMLog.write("Guest House: finishDiskChanges - second drive: \(answer?.word ?? "no answer")")
            switch answer?.word {
            case "ready":
                let place = configuration.guestOS == .windows ? "drive \(answer?.detail ?? "")" : "the folder \(answer?.detail ?? "")"
                Announcer.shared.announce("\(machine)'s second drive is ready, as \(place), with \(size) gigabytes.", tone: .success)
                storeDiskChange(configuration) { $0.secondDriveNeedsFormat = nil }
            case "already":
                if needsFormat { storeDiskChange(configuration) { $0.secondDriveNeedsFormat = nil } }
            // No file system any more (2026-11-09, third audit of the day
            // #22): "Guest House tries again at its next Start" was a promise it
            // couldn't keep, since it never formats a drive that had data.
            // Partitioned in the machine (fourth audit of 2026-11-09 #27).
            case "partitioned":
                // Once per machine (review): the script runs at every Start.
                let saidKey = "AVMSecondDrivePartitionedSaid-\(configuration.id.uuidString)"
                if needsFormat { storeDiskChange(configuration) { $0.secondDriveNeedsFormat = nil } }
                guard !UserDefaults.standard.bool(forKey: saidKey) else { break }
                UserDefaults.standard.set(true, forKey: saidKey)
                Announcer.shared.announce("\(machine)'s second drive has partitions of its own, so Guest House leaves it as it is and doesn't mount it. Next: mount it in \(machine) yourself.", tone: .info)
            case "lostfs":
                Announcer.shared.announce("\(machine)'s second drive has no file system any more, so it can't be mounted. Guest House doesn't format a drive that had one. Next: go back to a restore point from before, or format it in \(machine) yourself.", tone: .failure)
            default:
                Announcer.shared.announce("\(machine)'s second drive couldn't be made ready. Guest House tries again at its next Start.", tone: .failure)
            }
        }
    }

}
