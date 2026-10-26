// ScreenReaderInstallers.swift
// AVM — Accessible Virtual Machine
//
// Gets the installers for the screen readers a Windows VM should have from
// its first sign-in (2026-10-26): NVDA, free and GPL, from NV Access; JAWS
// for ARM, from Freedom Scientific (Vispero). AVM never ships either one:
// it downloads each from its maker when the VM's install media is built.
// JAWS's license doesn't allow redistribution, and downloading fresh means
// every new VM gets the current version.
//
// WHICH VERSION: the newest one in winget's public package manifests
// (github.com/microsoft/winget-pkgs), which list each release's download
// link and SHA-256. If the manifests can't be read, AVM falls back to the
// version pinned below. Either way:
//   - the link must be on the maker's own host (ScreenReader.vendorHost);
//     anything else is refused, so a bad manifest can't point elsewhere;
//   - the file must match the SHA-256 before it is used.
// Downloads are kept in Application Support, so a second VM reuses them.
//
// JAWS without a license runs in 40-minute demo mode; activation can't be
// scripted, so the user activates it inside Windows with their own license.

import Foundation
import CryptoKit

nonisolated struct ScreenReaderInstaller: Sendable, Equatable {
    let reader: ScreenReader
    let version: String
    let url: URL
    let sha256: String
}

nonisolated enum ScreenReaderInstallerError: LocalizedError, Sendable {
    case download(String)
    case checksum(String)

    var errorDescription: String? {
        switch self {
        case .download(let detail): return detail
        case .checksum(let name): return "The \(name) installer didn't match its published checksum, so AVM didn't use it."
        }
    }
}

nonisolated enum ScreenReaderInstallers {

    /// Used when winget's manifests can't be read. Each from the maker's
    /// own server, with winget's published SHA-256, as of 2026-10-26.
    static let pinned: [ScreenReader: ScreenReaderInstaller] = [
        .nvda: ScreenReaderInstaller(
            reader: .nvda, version: "2026.2",
            url: URL(string: "https://download.nvaccess.org/releases/2026.2/nvda_2026.2.exe")!,
            sha256: "F3F8D29974A88D687B3C4809BE192219EC579C5BDABCDA5AAF53635288BCA824"),
        .jaws: ScreenReaderInstaller(
            reader: .jaws, version: "2026.2609.84.400",
            url: URL(string: "https://software.vfo.digital/JAWS/2026/2026.2609.84.400/6824AC12-A96A-43F1-A5C5-D33CFC10B790/J2026.2609.84.400-Offline-arm64.exe")!,
            sha256: "C73C2A2A5A057CF0383E8409EF6AE1B00E8FB8B78B58036E4457DAAE095C73D5"),
    ]

    // MARK: Finding the newest version

    private static let api = "https://api.github.com/repos/microsoft/winget-pkgs/contents/"
    private static let raw = "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/"

    /// The newest release winget lists, or the pinned one.
    static func latest(_ reader: ScreenReader) async -> ScreenReaderInstaller {
        do {
            let found = try await lookUp(reader)
            guard found.url.host == reader.vendorHost, found.url.scheme == "https" else {
                AVMLog.write("AVM: ScreenReaders — winget's \(reader.displayName) link isn't on \(reader.vendorHost); using the pinned version.")
                return pinned[reader]!
            }
            return found
        } catch {
            AVMLog.write("AVM: ScreenReaders — couldn't read winget's \(reader.displayName) manifest (\(error.localizedDescription)); using the pinned version.")
            return pinned[reader]!
        }
    }

    private static func lookUp(_ reader: ScreenReader) async throws -> ScreenReaderInstaller {
        switch reader {
        case .nvda:
            let base = "manifests/n/NVAccess/NVDA"
            let version = try await newestFolder(base)
            let yaml = try await text(raw + "\(base)/\(version)/NVAccess.NVDA.installer.yaml")
            return try installer(reader, version: version, yaml: yaml, architecture: "x86")
        case .jaws:
            let base = "manifests/f/FreedomScientific/JAWS"
            let year = try await newestFolder(base)
            let version = try await newestFolder("\(base)/\(year)")
            let yaml = try await text(raw + "\(base)/\(year)/\(version)/FreedomScientific.JAWS.\(year).installer.yaml")
            return try installer(reader, version: version, yaml: yaml, architecture: "arm64")
        }
    }

    /// The highest numbered release folder (release candidates skipped).
    private static func newestFolder(_ path: String) async throws -> String {
        let data = try await fetch(api + path)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ScreenReaderInstallerError.download("winget's listing for \(path) wasn't readable")
        }
        let versions = entries.compactMap { $0["type"] as? String == "dir" ? $0["name"] as? String : nil }
            .filter { $0.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil }
        guard let newest = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) else {
            throw ScreenReaderInstallerError.download("winget lists no release for \(path)")
        }
        return newest
    }

    /// InstallerUrl and InstallerSha256 of the entry for `architecture`.
    static func installer(_ reader: ScreenReader, version: String, yaml: String, architecture: String) throws -> ScreenReaderInstaller {
        var blocks: [[String: String]] = []
        for line in yaml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") {
                blocks.append([:])
            }
            let field = trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : trimmed
            guard !blocks.isEmpty, let colon = field.firstIndex(of: ":") else { continue }
            let key = field[..<colon].trimmingCharacters(in: .whitespaces)
            let value = field[field.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            blocks[blocks.count - 1][key] = value
        }
        guard let block = blocks.first(where: { $0["Architecture"] == architecture }),
              let link = block["InstallerUrl"].flatMap(URL.init(string:)),
              let sha = block["InstallerSha256"], sha.count == 64 else {
            throw ScreenReaderInstallerError.download("winget's \(reader.displayName) manifest has no \(architecture) installer")
        }
        return ScreenReaderInstaller(reader: reader, version: version, url: link, sha256: sha.uppercased())
    }

    // MARK: Downloading

    /// Downloads (or reuses) each installer into `cache`, checked against
    /// its SHA-256. `say` gets the spoken progress. Returns what it got; a
    /// screen reader that fails is left out and its failure spoken, so the
    /// install goes ahead with the others and Narrator.
    static func fetchAll(_ readers: [ScreenReader], into cache: URL,
                         say: @escaping @Sendable (String, Bool) async -> Void) async -> [ScreenReader: URL] {
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var got: [ScreenReader: URL] = [:]
        for reader in readers {
            let installer = await latest(reader)
            let file = cache.appendingPathComponent("\(reader.rawValue)-\(installer.version).exe")
            if let existing = try? sha256(of: file), existing == installer.sha256 {
                AVMLog.write("AVM: ScreenReaders — reusing \(reader.displayName) \(installer.version).")
                got[reader] = file
                continue
            }
            await say("Downloading \(reader.displayName) \(installer.version) from its maker.", false)
            do {
                try await download(installer, to: file, say: say)
                guard try sha256(of: file) == installer.sha256 else {
                    try? FileManager.default.removeItem(at: file)
                    throw ScreenReaderInstallerError.checksum(reader.displayName)
                }
                AVMLog.write("AVM: ScreenReaders — downloaded and checked \(reader.displayName) \(installer.version).")
                got[reader] = file
            } catch {
                AVMLog.write("AVM: ScreenReaders — \(reader.displayName) failed: \(error.localizedDescription)")
                await say("\(reader.displayName) couldn't be downloaded, so it won't be installed this time. Reason: \(error.localizedDescription) Windows still has Narrator.", true)
            }
        }
        return got
    }

    private static func download(_ installer: ScreenReaderInstaller, to file: URL,
                                 say: @escaping @Sendable (String, Bool) async -> Void) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(from: installer.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ScreenReaderInstallerError.download("the server answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let total = response.expectedContentLength
        let part = file.appendingPathExtension("part")
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var written: Int64 = 0
        var lastTenth = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // Large downloads (JAWS is 1.5 GB) say how far they've got.
                if total > 100_000_000 {
                    let tenth = Int(Double(written) / Double(total) * 10)
                    if tenth > lastTenth, tenth < 10 {
                        lastTenth = tenth
                        await say("\(installer.reader.displayName) download \(tenth * 10) percent.", false)
                    }
                }
            }
        }
        try handle.write(contentsOf: buffer)
        try handle.close()
        try? FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: part, to: file)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02X", $0) }.joined()
    }

    // MARK: Network

    private static func fetch(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw ScreenReaderInstallerError.download("bad address \(url)") }
        var request = URLRequest(url: u)
        request.setValue("AVM", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ScreenReaderInstallerError.download("\(u.host ?? "the server") answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    private static func text(_ url: String) async throws -> String {
        String(decoding: try await fetch(url), as: UTF8.self)
    }
}
