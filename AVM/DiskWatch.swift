// DiskWatch.swift
// Guest House — accessible virtual machines
//
// DISK SPACE, SPOKEN (2026-10-27), as Hyper-V and VMware warn: while a
// machine runs, Guest House checks once a minute (VMManager.startDiskWatch):
//   - the Mac's disk where the machine lives, which its disk grows into:
//     said once at each of 20, 10 and 5 GB free, again only after it has
//     had more than 25 GB free;
//   - whether QEMU has paused it because that disk is full (QEMU stops a
//     machine whose disk write fails for lack of space, and says only
//     "io-error" when asked): said, and the machine is shown as paused,
//     so Resume is there once space is free;
//   - every five minutes, through the guest agent, the machine's own
//     drives (C:, /): said once when one passes 90% full, again only
//     after it has dropped below 85%.
// The decisions are here, plain, so the tests can check them.

import Foundation

nonisolated enum DiskWatch {
    static let gigabyte: Int64 = 1_073_741_824
    /// Free space on the Mac at which Guest House speaks, largest first.
    static let hostThresholds: [Int64] = [20, 10, 5].map { $0 * gigabyte }
    /// More free than this, and the warnings start over.
    static let hostReset: Int64 = 25 * gigabyte

    /// The threshold to speak now, if any: the smallest one `free` is
    /// below that hasn't been spoken (`lastSpoken` is the smallest spoken
    /// so far). Returns the new lastSpoken too.
    static func hostWarning(free: Int64, lastSpoken: Int64?) -> (speak: Int64?, lastSpoken: Int64?) {
        if free > hostReset { return (nil, nil) }
        guard let crossed = hostThresholds.last(where: { free < $0 }) else { return (nil, lastSpoken) }
        if let lastSpoken, crossed >= lastSpoken { return (nil, lastSpoken) }
        return (crossed, crossed)
    }

    /// `drive` is the external drive the machine is kept on, or nil for
    /// the Mac's own disk (2026-10-29, sixth audit: a drive's free space
    /// was said as the Mac's, and the user sent to free the wrong disk).
    static func hostWords(machine: String, free: Int64, drive: String? = nil) -> String {
        let gb = max(0, free / gigabyte)
        if let drive {
            return "The drive \(drive) has \(gb) gigabytes free, and \(machine)'s disk, kept on it, grows as it's used. When the drive is full, \(machine) pauses. Next: free some space on \(drive)."
        }
        return "Your Mac has \(gb) gigabytes free, and \(machine)'s disk grows as it's used. When the Mac's disk is full, \(machine) pauses. Next: free some space on your Mac."
    }

    /// One of the machine's drives, from the guest agent's guest-get-fsinfo.
    struct Drive: Equatable {
        let name: String     // "C:" or "/"
        let used: Int64
        let total: Int64
        var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
    }

    /// The drives worth watching: Windows' lettered drives and Linux's
    /// root, over a gigabyte; not the install media, swap or memory.
    static func drives(fromFsinfo reply: Any?) -> [Drive] {
        guard let list = reply as? [[String: Any]] else { return [] }
        return list.compactMap { fs in
            guard let mount = fs["mountpoint"] as? String,
                  let total = (fs["total-bytes"] as? NSNumber)?.int64Value,
                  let used = (fs["used-bytes"] as? NSNumber)?.int64Value,
                  total > gigabyte else { return nil }
            let type = (fs["type"] as? String ?? "").lowercased()
            if ["cdfs", "udf", "iso9660", "tmpfs", "squashfs", "vfat"].contains(type) { return nil }
            if mount == "/" { return Drive(name: "/", used: used, total: total) }
            if mount == linuxSecondDrive { return Drive(name: mount, used: used, total: total) }
            // "C:\\" on Windows.
            if mount.count <= 3, mount.dropFirst().hasPrefix(":") {
                return Drive(name: String(mount.prefix(2)).uppercased(), used: used, total: total)
            }
            return nil
        }
    }

    /// Which drives to speak about now: past 90% and not yet spoken, and
    /// the new set of spoken drives (one below 85% may warn again).
    static func guestWarnings(_ drives: [Drive], spoken: Set<String>) -> (speak: [Drive], spoken: Set<String>) {
        var spoken = spoken
        var speak: [Drive] = []
        for drive in drives {
            if drive.fraction >= 0.90, !spoken.contains(drive.name) {
                speak.append(drive)
                spoken.insert(drive.name)
            } else if drive.fraction < 0.85 {
                spoken.remove(drive.name)
            }
        }
        return (speak, spoken)
    }

    static func guestWords(machine: String, drive: Drive) -> String {
        let percent = Int((drive.fraction * 100).rounded())
        let left = max(0, (drive.total - drive.used) / gigabyte)
        let which = drive.name == "/" ? "\(machine)'s disk"
            : drive.name == linuxSecondDrive ? "\(machine)'s second drive" : "\(machine)'s \(drive.name) drive"
        return "\(which) is \(percent) percent full, with \(left) gigabytes left. Next: delete files in \(machine), or make its disk larger in Settings while it's shut down."
    }

    // MARK: How full, on the dashboard (2026-11-03, the user's request)

    /// Where those figures are kept, in the machine's folder.
    static let usageFileName = "disk-usage.json"
    /// Where a Linux machine's second drive is mounted.
    static let linuxSecondDrive = "/mnt/avm-data"

    /// The Disk column: what's used when Guest House has heard, or the size it was given.
    /// A stopped machine's figures are from when it last ran, and say so. A machine
    /// that has never said (a macOS machine can't; 2026-11-03, the user's request)
    /// shows what its disk takes on the Mac, which holds restore points too and
    /// doesn't shrink when files are deleted, so it isn't called used.
    static func tableCell(drives: [Drive], sizeGB: Int, secondDriveGB: Int?, running: Bool, onMacBytes: Int64? = nil) -> (shown: String, spoken: String) {
        func gb(_ bytes: Int64) -> Int64 { (bytes + gigabyte / 2) / gigabyte }
        func second(_ drive: Drive) -> String { drive.name == linuxSecondDrive ? "second drive" : drive.name }
        var shown: [String] = []
        var spoken: [String] = []
        // The one the machine starts from first: Windows may name D: before C:.
        func isFirst(_ drive: Drive) -> Bool { drive.name == "/" || drive.name == "C:" }
        for drive in drives.filter(isFirst) + drives.filter({ !isFirst($0) }) {
            let first = isFirst(drive)
            shown.append("\(first ? "" : "\(second(drive)) ")\(gb(drive.used)) of \(gb(drive.total)) GB\(first ? " used" : "")")
            spoken.append("\(first ? "" : "\(second(drive)), ")\(gb(drive.used)) of \(gb(drive.total)) gigabytes\(first ? " used" : "")")
        }
        if shown.isEmpty {
            if let onMacBytes, gb(onMacBytes) > 0 {
                shown.append("\(gb(onMacBytes)) GB on this Mac, of \(sizeGB) GB")
                spoken.append("\(gb(onMacBytes)) gigabytes on this Mac, of \(sizeGB) gigabytes")
            } else {
                shown.append("\(sizeGB) GB")
                spoken.append("\(sizeGB) gigabytes")
            }
        }
        // A drive the guest hasn't reported yet.
        if let secondDriveGB, drives.count < 2 {
            shown.append("second drive \(secondDriveGB) GB")
            spoken.append("second drive, \(secondDriveGB) gigabytes")
        }
        let old = !running && !drives.isEmpty
        return (shown.joined(separator: ", ") + (old ? " (last run)" : ""),
                spoken.joined(separator: ", ") + (old ? ", when it last ran" : ""))
    }

    // MARK: Growing and adding, inside the guest

    /// Drive C takes all the space after it. It says "extended", "same" when
    /// there's nothing to take, or "blocked" when the disk has free space C
    /// can't reach, then the size in gigabytes. "blocked" (2026-11-10, fourth
    /// audit of 2026-11-09 #28): a recovery partition after C made SizeMax
    /// C's own size, and since "same" is quiet the grown disk went unused
    /// with nothing said.
    static let extendDriveCScript = """
    $ErrorActionPreference = 'Stop'
    $n = (Get-Partition -DriveLetter C).DiskNumber
    Update-Disk -Number $n
    $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
    $now = (Get-Partition -DriveLetter C).Size
    $free = (Get-Disk -Number $n).Size - (Get-Partition -DiskNumber $n | Measure-Object -Property Size -Sum).Sum
    if ($max -gt $now + 16MB) { Resize-Partition -DriveLetter C -Size $max; $word = 'extended' } elseif ($free -gt 1GB) { $word = 'blocked' } else { $word = 'same' }
    "$word|$([math]::Round((Get-Partition -DriveLetter C).Size / 1GB))"
    """

    /// Only ever an empty disk of exactly this size, that isn't the one Windows
    /// started from. Formatted before it gets a letter, so Windows doesn't offer
    /// to format it. It says "ready" and the letter, "already" for a drive that
    /// has been made ready, or "nodisk". Never a USB disk (2026-11-09, fourth
    /// audit #21): a new stick passed through to Windows is RAW too, and one
    /// of the right size would have been formatted.
    static func formatWindowsDriveScript(sizeGB: Int) -> String {
        """
        $ErrorActionPreference = 'Stop'
        $disks = @(Get-Disk | Where-Object { $_.SerialNumber -eq 'avmdisk1' -and -not $_.IsBoot -and -not $_.IsSystem })
        if ($disks.Count -eq 0) { $size = \(Int64(sizeGB) * gigabyte); $disks = @(Get-Disk | Where-Object { $_.Size -eq $size -and $_.BusType -ne 'USB' -and -not $_.IsBoot -and -not $_.IsSystem }) }
        $empty = @($disks | Where-Object { $_.PartitionStyle -eq 'RAW' })
        if ($empty.Count -ne 1) { if ($disks.Count -ge 1) { 'already' } else { 'nodisk' }; exit }
        $disk = $empty[0]
        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
        if ($disk.IsReadOnly) { Set-Disk -Number $disk.Number -IsReadOnly $false }
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT
        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize
        $null = Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel 'Second Drive' -Confirm:$false
        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -AssignDriveLetter
        "ready|$((Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber).DriveLetter)"
        """
    }

    /// The disk QEMU named. Formatted only when Guest House hasn't made it ready yet, and
    /// only if nothing is on it. Mounted at every Start: a restore point from before
    /// the drive puts back an /etc/fstab that doesn't name it (Windows finds it by
    /// itself). Everyone may use it, as the account in the machine isn't known here.
    static func linuxDriveScript(format: Bool) -> String {
        """
        d=$(ls /dev/disk/by-id/virtio-avmdisk1 /dev/disk/by-id/nvme-*avmdisk1 2>/dev/null | head -1)
        [ -n "$d" ] || { echo nodisk; exit 0; }
        word=already
        if ! blkid "$d" >/dev/null 2>&1; then
            \(format ? #"mkfs.ext4 -q -L AVMData "$d" || { echo failed; exit 0; }; word=ready"# : "echo lostfs; exit 0")
        fi
        # A file system on the whole disk, or it's left alone (2026-11-10,
        # fourth audit of 2026-11-09 #27): partitioned in the machine, the
        # disk has no UUID of its own, and "UUID=" went into fstab.
        # Only a file system that mounts (review): LVM, LUKS or swap on the
        # whole disk has a UUID and a type too, and its line failed at every Start.
        uuid=$(blkid -s UUID -o value "$d"); type=$(blkid -s TYPE -o value "$d")
        case "$type" in ext2|ext3|ext4|xfs|btrfs|vfat|exfat|ntfs|ntfs3) ;; *) type=; esac
        [ -n "$uuid" ] && [ -n "$type" ] || { sed -i '\\|^UUID= \(linuxSecondDrive) |d' /etc/fstab; echo partitioned; exit 0; }
        mkdir -p \(linuxSecondDrive)
        # Guest House's line names this file system: one made again has a new UUID.
        # Only Guest House's own form goes (audit of 2026-11-10 #24): any line naming
        # the folder was deleted, a user's LABEL= line or one commented out
        # among them, at every Start. A line of the user's is left to rule.
        grep -q "^UUID=$uuid \(linuxSecondDrive) " /etc/fstab || { sed -i '\\|^UUID=[^ ]* \(linuxSecondDrive) |d' /etc/fstab; grep -qE '^[^#]*[[:space:]]\(linuxSecondDrive)[[:space:]]' /etc/fstab || echo "UUID=$uuid \(linuxSecondDrive) $type defaults,nofail 0 2" >> /etc/fstab; }
        grep -q ' \(linuxSecondDrive) ' /proc/mounts || mount \(linuxSecondDrive) || { echo failed; exit 0; }
        chmod 1777 \(linuxSecondDrive)
        command -v restorecon >/dev/null && restorecon -R \(linuxSecondDrive)
        echo "$word|\(linuxSecondDrive)"
        """
    }

    /// The most a machine's firmware-serial.log may hold while it runs
    /// (2026-11-09, fourth audit of the day #8): a guest writing to its
    /// serial port without end filled the Mac's disk.
    static let serialLogLimit = 32 << 20
    /// What is kept of it when it's trimmed: its end.
    static let serialLogKept = 4 << 20

    /// Cuts the serial log to its last serialLogKept bytes once it passes
    /// serialLogLimit. QEMU appends (append=on), so its next write lands
    /// at the new end.
    static func trimSerialLog(_ url: URL, limit: Int = serialLogLimit, keep: Int = serialLogKept) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue > limit,
              let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        let kept = (try? handle.seek(toOffset: UInt64(max(0, size.intValue - keep)))).flatMap { _ in try? handle.read(upToCount: keep) } ?? Data()
        let note = Data("\n[Guest House: the log passed \(limit >> 20) MB and was cut to its last \(keep >> 20) MB]\n".utf8)
        try? handle.truncate(atOffset: 0)
        try? handle.write(contentsOf: note + kept)
    }

    /// The last `bytes` of a file, or all of it when it's smaller.
    static func tail(of url: URL, bytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        return try handle.read(upToCount: bytes) ?? Data()
    }

    /// A script's last line that says something, split at the bar.
    static func answer(_ output: String) -> (word: String, detail: String)? {
        // lostfs too (2026-11-09, fourth audit of the day #5): the script
        // said it from 0.4.42, but unlisted it read as no answer, and the
        // promise to try again that #22 removed was still spoken.
        let words = ["extended", "same", "blocked", "ready", "already", "nodisk", "failed", "lostfs", "partitioned"]
        guard let line = output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { line in words.contains { line == $0 || line.hasPrefix($0 + "|") } }) else { return nil }
        let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : "")
    }
}
