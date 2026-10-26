// MacGuest.swift
// AVM — Accessible Virtual Machine
//
// macOS virtual machines (2026-10-26). QEMU can't run macOS on Apple
// Silicon, so a macOS machine runs on Apple's own Virtualization framework
// (the com.apple.security.virtualization entitlement AVM already has), a
// second engine beside QEMU. It shares AVM's dashboard list, spoken status
// and settings store; the parts that differ are here:
//
//   MacGuestFiles  — a macOS machine's files in its VM folder: the disk
//                    (raw, sparse), auxiliary storage, hardware model and
//                    machine identifier.
//   MacInstaller   — gets macOS from Apple (the newest this Mac supports,
//                    VZMacOSRestoreImage) or from an IPSW the user has,
//                    and installs it, saying how far it has got.
//   MacGuestRunner — starts a machine in its own window (Apple's
//                    VZVirtualMachineView), with sound, the shared folder
//                    and a clean shutdown when the window closes.
//
// THE KEYBOARD (same model as Windows, 2026-10-26): Command-Shift-E
// (Virtual Machine > Enter macOS) brings the machine's window forward and
// gives macOS the keyboard; Control-Command-Escape gives it back to the
// Mac and the machine keeps running. Command-Tab still switches apps. The
// machine's screen is a picture VoiceOver can't read, so the window has a
// bar above it that it can: where the keyboard is, a button to give macOS
// the keyboard, and Shut Down. The
// Mac's VoiceOver keeps the VoiceOver keys (Control-Option), so to use
// VoiceOver inside the machine, turn the Mac's VoiceOver off with
// Command-F5 while working there, as with Windows and JAWS or NVDA.
// macOS Setup Assistant offers VoiceOver itself: press Escape when it
// speaks, or Command-F5 once the Mac's VoiceOver is off.

import AppKit
import Carbon.HIToolbox
import Combine
import Virtualization

// MARK: - Files

nonisolated struct MacGuestFiles {
    let folder: URL
    var disk: URL { folder.appendingPathComponent("macos-disk.img") }
    var auxiliaryStorage: URL { folder.appendingPathComponent("AuxiliaryStorage") }
    var hardwareModel: URL { folder.appendingPathComponent("HardwareModel") }
    var machineIdentifier: URL { folder.appendingPathComponent("MachineIdentifier") }

    var isInstalled: Bool {
        [disk, auxiliaryStorage, hardwareModel, machineIdentifier].allSatisfy {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

nonisolated struct MacGuestError: LocalizedError, Sendable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Configuration

@MainActor
enum MacGuestConfiguration {

    /// The machine as Apple's framework runs it, from AVM's settings.
    static func make(_ config: VMConfiguration, files: MacGuestFiles,
                     hardwareModel: VZMacHardwareModel? = nil) throws -> VZVirtualMachineConfiguration {
        let model: VZMacHardwareModel
        if let hardwareModel {
            model = hardwareModel
        } else {
            guard let data = try? Data(contentsOf: files.hardwareModel),
                  let loaded = VZMacHardwareModel(dataRepresentation: data) else {
                throw MacGuestError("This macOS machine's hardware model is missing or damaged.")
            }
            model = loaded
        }
        guard model.isSupported else {
            throw MacGuestError("This Mac can't run the version of macOS installed in this machine.")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: files.auxiliaryStorage)
        guard let idData = try? Data(contentsOf: files.machineIdentifier),
              let identifier = VZMacMachineIdentifier(dataRepresentation: idData) else {
            throw MacGuestError("This macOS machine's identifier is missing or damaged.")
        }
        platform.machineIdentifier = identifier

        let vz = VZVirtualMachineConfiguration()
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()
        vz.cpuCount = max(VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                          min(config.cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        vz.memorySize = max(VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                            min(UInt64(config.ramSizeGB) << 30, VZVirtualMachineConfiguration.maximumAllowedMemorySize))

        let disk = try VZDiskImageStorageDeviceAttachment(url: files.disk, readOnly: false)
        vz.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        vz.networkDevices = [network]

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)]
        vz.graphicsDevices = [graphics]

        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Sound out only: VoiceOver's speech in the machine comes out of the
        // Mac. No microphone, so no microphone permission is asked.
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        vz.audioDevices = [sound]

        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // The shared folder appears in the machine's Finder by itself, as
        // "My Shared Files", in /Volumes.
        if let shared = config.sharedFolderURL {
            let share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: shared, readOnly: config.sharedFolderIsReadOnly))
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            fs.share = share
            vz.directorySharingDevices = [fs]
        }

        try vz.validate()
        return vz
    }
}

// MARK: - Installing

@MainActor
final class MacInstaller: NSObject, URLSessionDownloadDelegate {

    /// Says how far it has got; the wizard shows the same line.
    var onProgress: ((String) -> Void)?

    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var downloadDestination: URL?
    private var lastSpokenGB = 0
    private var installObservation: NSKeyValueObservation?

    /// Where downloaded macOS restore images are kept, so a second machine
    /// doesn't download one again.
    static var cacheFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent(AVMPaths.supportFolderName).appendingPathComponent("macos-restore-images")
    }

    /// Installs macOS into `config`'s folder: from `ipsw` if given, else
    /// the newest macOS this Mac supports, from Apple.
    func install(_ config: VMConfiguration, ipsw: URL?) async throws {
        let folder = try config.directoryURL()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = MacGuestFiles(folder: folder)

        let imageURL = try await restoreImage(ipsw)
        say("Checking the macOS installer.")
        let image = try await VZMacOSRestoreImage.image(from: imageURL)
        guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
            throw MacGuestError("This Mac can't run macOS \(image.operatingSystemVersion.description). Next: choose an older macOS installer.")
        }
        if config.cpuCount < requirements.minimumSupportedCPUCount || UInt64(config.ramSizeGB) << 30 < requirements.minimumSupportedMemorySize {
            throw MacGuestError("macOS \(image.operatingSystemVersion.description) needs at least \(requirements.minimumSupportedCPUCount) cores and \(requirements.minimumSupportedMemorySize >> 30) gigabytes of memory. Next: give the machine more, then try again.")
        }

        // The machine's own files.
        try requirements.hardwareModel.dataRepresentation.write(to: files.hardwareModel)
        try VZMacMachineIdentifier().dataRepresentation.write(to: files.machineIdentifier)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: files.auxiliaryStorage, hardwareModel: requirements.hardwareModel, options: [.allowOverwrite])
        FileManager.default.createFile(atPath: files.disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: files.disk)
        try handle.truncate(atOffset: UInt64(config.diskSizeGB) << 30)   // sparse: grows as used
        try handle.close()

        let vz = try MacGuestConfiguration.make(config, files: files, hardwareModel: requirements.hardwareModel)
        let machine = VZVirtualMachine(configuration: vz)
        let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: imageURL)
        say("Installing macOS \(image.operatingSystemVersion.description). This takes about 15 to 30 minutes.")
        var lastTenth = 0
        installObservation = installer.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let tenth = Int(progress.fractionCompleted * 10)
            DispatchQueue.main.async {
                guard tenth > lastTenth, tenth < 10 else { return }
                lastTenth = tenth
                self?.say("macOS install \(tenth * 10) percent.")
            }
        }
        defer { installObservation = nil }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            installer.install { result in
                switch result {
                case .success: cont.resume()
                case .failure(let error): cont.resume(throwing: error)
                }
            }
        }
        AVMLog.write("AVM: MacGuest — installed macOS \(image.operatingSystemVersion.description) in \(config.name).")
    }

    private func restoreImage(_ ipsw: URL?) async throws -> URL {
        if let ipsw { return ipsw }
        say("Asking Apple for the newest macOS this Mac can run.")
        let latest = try await VZMacOSRestoreImage.latestSupported
        let fm = FileManager.default
        try fm.createDirectory(at: Self.cacheFolder, withIntermediateDirectories: true)
        let cached = Self.cacheFolder.appendingPathComponent(latest.url.lastPathComponent)
        if fm.fileExists(atPath: cached.path) {
            say("Using the macOS \(latest.operatingSystemVersion.description) installer downloaded before.")
            return cached
        }
        // The size comes from the download itself (26 GB for macOS 27.0.1,
        // 2026-10-26), in the first progress line.
        say("Downloading macOS \(latest.operatingSystemVersion.description) from Apple. It's large, usually over 15 gigabytes; AVM says how far it has got every gigabyte.")
        lastSpokenGB = 0
        downloadDestination = cached
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        return try await withCheckedThrowingContinuation { cont in
            downloadContinuation = cont
            session.downloadTask(with: latest.url).resume()
        }
    }

    // URLSessionDownloadDelegate, on the main queue.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            let gb = Int(totalBytesWritten / 1_000_000_000)
            guard gb > lastSpokenGB else { return }
            lastSpokenGB = gb
            let total = totalBytesExpectedToWrite > 0 ? " of \(Int(totalBytesExpectedToWrite / 1_000_000_000))" : ""
            say("macOS download: \(gb)\(total) gigabytes.")
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        MainActor.assumeIsolated {
            guard let destination = downloadDestination else { return }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                downloadContinuation?.resume(returning: destination)
            } catch {
                downloadContinuation?.resume(throwing: error)
            }
            downloadContinuation = nil
            session.finishTasksAndInvalidate()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                downloadContinuation?.resume(throwing: MacGuestError("The macOS download stopped. Reason: \(error.localizedDescription)"))
                downloadContinuation = nil
            }
            session.finishTasksAndInvalidate()
        }
    }

    private func say(_ message: String) {
        onProgress?(message)
        Announcer.shared.announce(message, tone: .info)
        AVMLog.write("AVM: MacGuest — \(message)")
    }
}

extension VZMacOSRestoreImage {
    @MainActor static func image(from url: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { cont in
            VZMacOSRestoreImage.load(from: url) { cont.resume(with: $0) }
        }
    }

    @MainActor static var latestSupported: VZMacOSRestoreImage {
        get async throws {
            try await withCheckedThrowingContinuation { cont in
                VZMacOSRestoreImage.fetchLatestSupported { cont.resume(with: $0) }
            }
        }
    }
}

extension OperatingSystemVersion {
    nonisolated var description: String {
        patchVersion == 0 ? "\(majorVersion).\(minorVersion)" : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}

// MARK: - Running

@MainActor
final class MacGuestRunner: NSObject, ObservableObject, VZVirtualMachineDelegate, NSWindowDelegate {
    static let shared = MacGuestRunner()

    @Published private(set) var runningID: UUID?
    @Published private(set) var keyboardInGuest = false
    private var machineView: VZVirtualMachineView?
    private var statusLabel: NSTextField?
    private weak var giveButton: NSButton?
    /// The first "Entering macOS" of a run adds the key back; later ones
    /// are just the two words.
    private var hintGiven = false
    /// Spoken as "Entering macOS" whatever the machine is called.
    private let guestName = "macOS"
    private var keyMonitor: Any?
    private var machine: VZVirtualMachine?
    private var window: NSWindow?
    private var name = "macOS"

    func start(_ config: VMConfiguration) {
        if runningID == config.id {
            window?.makeKeyAndOrderFront(nil)
            Announcer.shared.announce("\(config.name) is already running; its window is in front.", tone: .info)
            return
        }
        guard runningID == nil else {
            Announcer.shared.announce("Another macOS machine is running. Shut it down first.", tone: .failure)
            return
        }
        do {
            let files = MacGuestFiles(folder: try config.directoryURL())
            guard files.isInstalled else {
                throw MacGuestError("macOS isn't installed in \(config.name). Next: delete it and make it again with New macOS Virtual Machine.")
            }
            let vz = try MacGuestConfiguration.make(config, files: files)
            let machine = VZVirtualMachine(configuration: vz)
            machine.delegate = self
            self.machine = machine
            runningID = config.id
            name = config.name
            showWindow(for: machine, title: config.name)
            Announcer.shared.announce("Starting \(config.name).", tone: .info)
            machine.start { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    AVMLog.write("AVM: MacGuest — \(config.name) started.")
                    Announcer.shared.announce("\(config.name) is running.", tone: .success)
                    self.enter()
                case .failure(let error):
                    self.ended(spoken: "\(config.name) could not start. Reason: \(error.localizedDescription)", tone: .failure)
                }
            }
        } catch {
            Announcer.shared.announce("\(config.name) could not start. Reason: \(error.localizedDescription)", tone: .failure)
        }
    }

    /// Asks macOS in the machine to shut down, as its power button would.
    func shutDown() {
        guard let machine, machine.canRequestStop else { forceStop(); return }
        do {
            try machine.requestStop()
            Announcer.shared.announce("Asked \(name) to shut down.", tone: .info)
        } catch {
            forceStop()
        }
    }

    func forceStop() {
        guard let machine else { return }
        machine.stop { [weak self] _ in
            self?.ended(spoken: "\(self?.name ?? "macOS") was turned off.", tone: .info)
        }
    }

    // MARK: Keyboard

    /// Gives macOS the keyboard: its window in front, its screen first
    /// responder. Command-Shift-E.
    func enter(spoken: String? = nil) {
        guard let window, let machineView else {
            NSSound.beep()
            return
        }
        // Set before the window becomes key, so windowDidBecomeKey leaves
        // the screen as first responder.
        setKeyboard(inGuest: true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(machineView)
        // NEVER capturesSystemKeys = true here (2026-10-26, a user stuck in
        // macOS): Apple's capture takes the keyboard below AVM's key monitor
        // AND its system-wide hotkey, so Control-Command-Escape stopped
        // working and only quitting AVM got the keyboard back. Command-Tab
        // and Command-F5 stay the Mac's; Command-Shift-Option-V (or the
        // button) turns VoiceOver in macOS on and off. The hotkey stays as a
        // second way out.
        registerEscapeHotKey()
        // "Entering macOS", the same words every time, as for Windows; the
        // keys to know are added the first time only.
        Announcer.shared.announce(hintGiven ? "Entering \(guestName)" : "Entering \(guestName). Control-Command-Escape returns to your Mac.", tone: .info)
        hintGiven = true
        AVMLog.write("AVM: MacGuest — keyboard to macOS.")
    }

    /// Gives the keyboard back to the Mac; the machine keeps running.
    /// Control-Command-Escape.
    func leave() {
        guard window != nil, keyboardInGuest else { return }
        // Off first, so windowDidResignKey doesn't announce it again.
        releaseFullControl()
        setKeyboard(inGuest: false)
        window?.makeFirstResponder(giveButton)
        if let main = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.canBecomeMain }) {
            main.makeKeyAndOrderFront(nil)
        }
        Announcer.shared.announce("Entering Mac", tone: .info)
        AVMLog.write("AVM: MacGuest — keyboard to the Mac.")
    }

    /// Command-F5 into macOS, handed straight to the machine's screen so
    /// the Mac can't take it: turns VoiceOver in macOS on or off, whether
    /// or not the Mac's own VoiceOver is on (2026-10-26: the Mac caught
    /// Command-F5 typed into the window).
    func toggleGuestVoiceOver() {
        guard let window, let machineView else { NSSound.beep(); return }
        // The whole chord, as fingers make it: Command down, F5 down and
        // up, Command up. F5 tagged "with Command" alone reached macOS only
        // sometimes ("VoiceOver is fidgety starting", 2026-10-26): the
        // machine presses keys it is told about, and Command was never
        // pressed.
        let f5: UInt16 = 96, command: UInt16 = 55
        func modifier(_ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: command)
        }
        func key(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command,
                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: f5)
        }
        if let down = modifier(.command) { machineView.flagsChanged(with: down) }
        if let press = key(.keyDown) { machineView.keyDown(with: press) }
        if let lift = key(.keyUp) { machineView.keyUp(with: lift) }
        if let up = modifier([]) { machineView.flagsChanged(with: up) }
        AVMLog.write("AVM: MacGuest — sent Command-F5 to macOS.")
        Announcer.shared.announce("Sent Command-F5 to \(name), which turns its VoiceOver on or off.", tone: .info)
    }

    // MARK: Full control's way out

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    /// "AVMm": not FocusLockManager's id, so neither handler acts on the
    /// other's hotkey (only one is ever registered at a time anyway).
    private static let escapeHotKeyID = EventHotKeyID(signature: OSType(0x4156_4D6D), id: 2)

    /// Control-Command-Escape as a system-wide hotkey while macOS has full
    /// control, the mechanism Windows' focus lock relies on, so the way
    /// back works even when the machine has captured the keyboard.
    private func registerEscapeHotKey() {
        guard hotKeyRef == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == MacGuestRunner.escapeHotKeyID.signature, id.id == MacGuestRunner.escapeHotKeyID.id else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { MacGuestRunner.shared.leave() } }
            return noErr
        }, 1, &type, nil, &hotKeyHandler)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(controlKey | cmdKey), Self.escapeHotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        AVMLog.write("AVM: MacGuest — Control-Command-Escape hotkey \(status == noErr ? "registered" : "not registered (\(status))").")
    }

    /// Back to the Mac's own shortcuts, and the hotkey off.
    private func releaseFullControl() {
        machineView?.capturesSystemKeys = false
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyHandler = nil
    }

    private func setKeyboard(inGuest: Bool) {
        keyboardInGuest = inGuest
        statusLabel?.stringValue = inGuest
            ? "Keyboard: \(name). Every key goes to \(name) except Command-Tab and Command-F5, which stay your Mac's. Control-Command-Escape returns to your Mac; Command-Shift-Option-V turns VoiceOver in \(name) on or off."
            : "Keyboard: your Mac. Command-Shift-E, or the button, gives it to \(name)."
    }

    private func showWindow(for machine: VZVirtualMachine, title: String) {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = false        // Command-Tab stays the Mac's
        if #available(macOS 14.0, *) { view.automaticallyReconfiguresDisplay = true }
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.group)
        view.setAccessibilityLabel("\(title) screen")
        view.setAccessibilityHelp("macOS's screen. When it has the keyboard, keys go to macOS; Control-Command-Escape returns to your Mac.")
        view.translatesAutoresizingMaskIntoConstraints = false

        // The bar VoiceOver can read, above the screen.
        let status = NSTextField(labelWithString: "")
        status.setAccessibilityLabel("Keyboard status")
        let give = NSButton(title: "Give \(title) the Keyboard", target: self, action: #selector(giveKeyboard))
        giveButton = give
        let voiceOver = NSButton(title: "Turn VoiceOver On or Off in \(title)", target: self, action: #selector(voiceOverPressed))
        voiceOver.setAccessibilityHelp("Sends Command-F5 into \(title), so its own VoiceOver starts or stops. Your Mac doesn't catch it.")
        let shut = NSButton(title: "Shut Down", target: self, action: #selector(shutDownPressed))
        let bar = NSStackView(views: [status, NSView(), give, voiceOver, shut])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.group)
        bar.setAccessibilityLabel("\(title) controls")
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(bar)
        content.addSubview(view)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: bar.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setAccessibilityLabel("\(title), macOS virtual machine")
        window.center()
        self.window = window
        self.machineView = view
        self.statusLabel = status
        setKeyboard(inGuest: false)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(give)

        // THE ONE KEYBOARD RULE (2026-10-26, after "switching is unclear and
        // keystrokes don't work consistently"): keys reach macOS only after
        // Enter (Command-Shift-E or the button), and then every key does,
        // Command shortcuts included, so AVM's menus can't take Command-Q or
        // Command-W from macOS. Two chords are AVM's: Control-Command-Escape
        // (back to the Mac) and Command-Shift-Option-V (VoiceOver in macOS).
        // Command-F5 and Command-Tab are the Mac's own: macOS lets no app see
        // them without capturing the keyboard, and capturing it disables the
        // way out (see enter()).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.window === self.window, self.keyboardInGuest, let screen = self.machineView else { return event }
            let mods = event.modifierFlags.intersection([.control, .command, .option, .shift])
            if event.type == .keyDown, event.keyCode == 53, mods == [.control, .command] {
                self.leave()
                return nil
            }
            if event.type == .keyDown, event.keyCode == 9, mods == [.command, .shift, .option] {   // V
                self.toggleGuestVoiceOver()
                return nil
            }
            if mods.contains(.command) {
                // Straight to macOS, past AVM's menus.
                if event.type == .keyDown { screen.keyDown(with: event) } else { screen.keyUp(with: event) }
                return nil
            }
            return event
        }
    }

    @objc private func giveKeyboard() { enter() }
    @objc private func voiceOverPressed() { toggleGuestVoiceOver() }
    @objc private func shutDownPressed() { shutDown() }

    /// Leaving the window by any other way (Command-Tab, a click on the
    /// dashboard) gives the keyboard back to the Mac, and says so.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard keyboardInGuest else { return }
            releaseFullControl()
            setKeyboard(inGuest: false)
            window?.makeFirstResponder(giveButton)
            Announcer.shared.announce("Entering Mac", tone: .info)
            AVMLog.write("AVM: MacGuest — keyboard to the Mac (window left).")
        }
    }

    /// Arriving at the window (Command-backquote, a click, VoiceOver) does
    /// not give macOS the keyboard: only Enter does. Focus rests on the
    /// bar's button, so keys typed here go nowhere unexpected.
    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !keyboardInGuest else { return }
            window?.makeFirstResponder(giveButton)
        }
    }

    // Closing the window shuts the machine down, asking first.
    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard machine != nil else { return true }
            let alert = NSAlert()
            alert.messageText = "Shut down \(name)?"
            alert.informativeText = "macOS in the machine shuts down as it would on a Mac; unsaved work there may be lost."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Shut Down")
            alert.addButton(withTitle: "Force Stop")
            switch alert.runModal() {
            case .alertSecondButtonReturn: shutDown()
            case .alertThirdButtonReturn: forceStop()
            default: break
            }
            return false
        }
    }

    // VZVirtualMachineDelegate
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { ended(spoken: "\(name) shut down.", tone: .info) }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated { ended(spoken: "\(name) stopped unexpectedly. Reason: \(error.localizedDescription)", tone: .failure) }
    }

    private func ended(spoken: String, tone: Announcer.Tone) {
        AVMLog.write("AVM: MacGuest — \(spoken)")
        releaseFullControl()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.delegate = nil
        window?.close()
        window = nil
        machine = nil
        machineView = nil
        statusLabel = nil
        keyboardInGuest = false
        hintGiven = false
        runningID = nil
        Announcer.shared.announce(spoken, tone: tone)
    }
}
