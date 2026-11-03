// AVMUpdater.swift
// AVM — Accessible Virtual Machine
//
// Sparkle updater ownership (ADDED 2026-08-16, Handoff 43 session).
//
// WHY SPARKLE, not a custom checker: the update prompt is standard AppKit
// UI — real windows, real buttons, native VoiceOver focus and re-reading at
// the user's own pace. That is the elegant VoiceOver path (settled
// 2026-08-16: self-voicing is only for moments with no UI to land focus on,
// like a QEMU crash mid-session; an update prompt is not one of those).
// Sparkle also gives atomic replace-and-relaunch, so testers never touch a
// DMG again after the first Sparkle-carrying build.
//
// CONFIGURATION OF RECORD (all three settled 2026-08-16):
//   - Feed: SUFeedURL in Info.plist → appcast.xml at the repo root on main,
//     served via raw.githubusercontent.com (repo is the host; a release is
//     a commit). raw caching means a new release can take ~5 minutes to
//     become visible. UpdatePoll looks at it every 15 minutes (2026-11-02).
//   - Signing: SUPublicEDKey in Info.plist. The private key lives in the
//     login Keychain with a file backup in iCloud Drive/AVM-keys. It NEVER
//     enters the repo.
//   - Consent: SUEnableAutomaticChecks is deliberately ABSENT from
//     Info.plist, so Sparkle shows its one-time "check automatically?"
//     consent dialog on first launch. Automatic DOWNLOAD stays off
//     (Sparkle default): launch checks are silent when current — no sound,
//     no dialog, nothing to narrate for a non-event — and only produce UI
//     when an update actually exists. The manual menu check DOES show
//     "you're up to date", because that time the user asked.
//
// startingUpdater: true — the updater starts with the app and owns the
// launch-time check schedule. There is no reason to defer: recovery paths
// that must precede user actions (Caps Lock) run in
// applicationDidFinishLaunching, and Sparkle's first consent dialog cannot
// fire before the run loop is up anyway.
//
// canCheckForUpdates is republished so the menu item can dim while a check
// or install is already in flight — reactive dimming is fine HERE (unlike
// the parked VM-state menu dimming) because Sparkle itself provides the
// observable; no new app-level state model is needed.
//
// SPOKEN POINTER (2026-10-26): when a check finds an update, AVM says so
// once, briefly, and says where the window is. The prompt stays Sparkle's
// own window, read at the user's pace, as above; the announcement exists
// because that window can open unnoticed, behind the dashboard or while
// Windows has the keyboard, and a background check has no other cue.
//
// import Combine is REQUIRED, not decorative: @Published, assign(to:), and
// ObservableObject are Combine symbols, and this file uses all three.
// Omitting it fails the build (proven 2026-08-16, first build of this file).
import Foundation
import SwiftUI
import Combine
import Sparkle

@MainActor
final class AVMUpdater: ObservableObject {
    /// The one Sparkle controller for the app. Standard user driver =
    /// standard AppKit alerts = native VoiceOver behavior.
    private let controller: SPUStandardUpdaterController

    /// Mirrors Sparkle's own gate for whether a user-initiated check can
    /// start now. Drives the menu item's disabled state.
    @Published var canCheckForUpdates = false

    /// Sparkle holds its delegate weakly, so the updater keeps it.
    private let announcer = UpdateAnnouncer()
    private var poll: UpdatePoll?

    /// `starting` false for the accessibility audit (2026-10-30), which
    /// shows AVM's Settings without checking for updates or asking to.
    /// Nor for any test run (2026-11-01): --test-update has its own updater,
    /// and the others have no business checking.
    init(starting: Bool = !CommandLine.arguments.contains { $0.hasPrefix("--test-") }) {
        controller = SPUStandardUpdaterController(
            startingUpdater: starting,
            updaterDelegate: announcer,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        guard starting, let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init) else { return }
        let updater = controller.updater
        let poll = UpdatePoll(feed: feed, every: UpdatePoll.interval, updater: updater)
        announcer.found = { build in poll.offered = max(poll.offered ?? 0, build) }
        self.poll = poll
    }

    /// Menu-invoked check. Shows Sparkle's standard UI in every outcome,
    /// including "you're up to date" — the user asked, so silence would be
    /// a bug. The log line records the invocation; Sparkle's own UI carries
    /// the outcome. Privacy check: names an AVM menu command only.
    func checkForUpdates() {
        AVMLog.write("AVM: Check for Updates menu — invoking Sparkle user-initiated check.")
        controller.checkForUpdates(nil)
    }

    /// Automatic checks, Sparkle's and UpdatePoll's, for AVM's Settings (2026-10-30). Sparkle
    /// keeps the choice in AVM's defaults.
    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
            AVMLog.write("AVM: Settings — check for updates automatically \(newValue ? "on" : "off")")
        }
    }
}

/// A new version within about 15 minutes (2026-11-02, the user's request).
/// Sparkle won't check more often than hourly, and a check that finds what the
/// user has already put off opens its window again, so AVM looks at the feed
/// itself, with the file's ETag so an unchanged feed costs almost nothing, and
/// asks Sparkle once per new version. Sparkle's own check still reminds daily.
/// A push isn't possible with a feed on GitHub, which also caches it for up to
/// 5 minutes. Off when automatic checks are off.
@MainActor
final class UpdatePoll {
    static let interval: TimeInterval = 15 * 60
    var offered: Int?
    private let feed: URL
    private let updater: SPUUpdater
    private var etag: String?
    private var task: Task<Void, Never>?

    init(feed: URL, every interval: TimeInterval, updater: SPUUpdater) {
        self.feed = feed
        self.updater = updater
        task = Task { [weak self] in
            // Soon after opening too: Sparkle's first check waits out its day.
            try? await Task.sleep(for: .seconds(min(interval, 60)))
            while !Task.isCancelled {
                await self?.look()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func look() async {
        guard updater.automaticallyChecksForUpdates, updater.canCheckForUpdates else { return }
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return }
        etag = http.value(forHTTPHeaderField: "ETag")
        let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init) ?? 0
        let newest = UpdateFeed.newestBuild(in: text, channels: UpdateChannels.allowed)
        guard UpdateFeed.shouldOffer(newest: newest, current: current, offered: offered),
              updater.canCheckForUpdates else { return }
        offered = newest
        AVMLog.write("AVM: Updates — the feed has build \(newest ?? 0); asking Sparkle.")
        updater.checkForUpdatesInBackground()
    }
}

/// Says that an update was found and where its window is (header).
final class UpdateAnnouncer: NSObject, SPUUpdaterDelegate {
    /// Testers get a release first (2026-11-02): one marked early in the feed is
    /// offered only to copies with this on, until Tools/promote-release.sh.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannels.allowed
    }

    /// The helper exits before the new AVM starts (2026-10-28, code
    /// review): it used to keep running for its idle grace period, and
    /// the new AVM talked to it.
    ///
    /// Only once AVM is really quitting (2026-10-28, fourth audit): Sparkle
    /// calls this before it asks AVM to quit, and stopping the helper here
    /// took every USB, Bluetooth and Windows-keyboard device out of the
    /// running machines before the question "Windows is still running.
    /// Quit AVM?" was even asked; Cancel left them without their devices.
    /// applicationWillTerminate asks the helper to exit, after the
    /// machines have been shut down or saved.
    nonisolated(unsafe) static var relaunchingForUpdate = false
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        NSLog("AVM: Updates — relaunching; the USB helper exits when AVM quits.")
        Self.relaunchingForUpdate = true
    }

    /// What was found, so UpdatePoll doesn't ask about it again.
    @MainActor var found: ((Int) -> Void)?

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let build = Int(item.versionString)
        Task { @MainActor in
            if let build { found?(build) }
            let inGuest = FocusLockManager.shared?.isLocked ?? false
            AVMLog.write("AVM: Updates — found version \(version).")
            Announcer.shared.announce(
                inGuest
                    ? "AVM \(version) is available. Leave \(FocusLockManager.shared?.guestName ?? "the machine") to read the update window."
                    : "AVM \(version) is available. The update window is open.",
                tone: .info
            )
        }
    }
}

// MARK: - What's New, after an update (2026-10-30)
//
// The user's request: easy-to-read release notes on the first launch after
// an update. A small window, "What's New in AVM 0.4.14", a heading per
// version and a few plain lines each, read by VoiceOver as it opens; OK (or
// Return) closes it. It covers every version since the one last run, and
// is in the Help menu too. Not while the keyboard is in a machine: it
// waits until the user is back on the Mac.
//
// Every release adds its entry at the top of ReleaseNotes.all;
// Tools/build-installer.sh refuses a version without one.

import AppKit
import SwiftUI

struct ReleaseNote {
    let version: String
    let changes: [String]
}

@MainActor
enum ReleaseNotes {
    /// Newest first.
    static let all: [ReleaseNote] = [
        ReleaseNote(version: "0.4.30", changes: [
            "The categories in the toolbar of a machine's Settings and AVM's Settings are now there as soon as the window opens. VoiceOver sometimes missed them before, and this should stop that. If it still happens, please report it.",
        ]),
        ReleaseNote(version: "0.4.29", changes: [
            "Install Apps, in the Virtual Machine menu: tick Chrome, Firefox, Thunderbird, LibreOffice, Zoom, VLC, Audacity, 7-Zip, Notepad++, Visual Studio Code, Git or Python, and they install in a running Windows machine one at a time, with no questions. AVM says each as it finishes, and you can keep working meanwhile.",
        ]),
        ReleaseNote(version: "0.4.28", changes: [
            "AVM no longer reads a machine's screen by itself. Press Command-Shift-O to hear it, including during Setup or a restart. The one exception: if Windows stops answering and shows a blue screen, AVM says so.",
            "AVM looks for a new version every 15 minutes, not once a day, so you hear about one soon after it comes out. It says so once for each version.",
            "Command-Shift-O and AVM's other keys that answer or act now work with your keyboard in the machine: Describe Screen, Speak Status, Speak Updates and Disk, Check This Machine, Type Clipboard and Send Ctrl-Alt-Delete. Before, they reached Windows as Windows key shortcuts.",
            "Control-Fn-Right now reaches the machine, so it goes to the end of a document, as do Control with the other arrows, Home, End, Page Up and Page Down. Before, the Mac's window tiling could take them.",
            "AVM keeps its last ten logs, not three, so a problem's log is still there after a few restarts.",
        ]),
        ReleaseNote(version: "0.4.27", changes: [
            "3D graphics in Windows is now clearly marked experimental. A machine with it on may freeze or stop, so don't turn it on for a machine you rely on.",
            "AVM now keeps an eye on the program that runs each machine, and warns you if it's running short of files or memory, or has reported a fault. Check This Machine says so too.",
            "When AVM says a machine looks stuck, it saves what the machine was doing, and Report a Problem sends that along. Please send one if it happens.",
            "Testers can get new versions early: turn on Get new versions early, as a tester, in AVM's Settings. Those versions have had less testing.",
            "Windows apps may now take up to 12 seconds to appear in Command-Tab when nothing has changed for a while, which keeps Windows' own log much quieter.",
        ]),
        ReleaseNote(version: "0.4.26", changes: [
            "A machine can now keep far more internet connections open at once. Each time a machine starts, AVM checks how many your Mac allows and uses that, instead of stopping new connections at about ten thousand.",
        ]),
        ReleaseNote(version: "0.4.25", changes: [
            "A machine with many internet connections open, as a speed test makes, could stop responding and need a force restart. AVM could only keep track of about a thousand open files and connections at once, and that limit is gone. If a Windows machine still freezes on a busy website, please send your log from the Help menu.",
        ]),
        ReleaseNote(version: "0.4.24", changes: [
            "Websites should open faster in Windows machines on a network without IPv6. Windows was waiting about a fifth of a second on every new connection. AVM now checks for IPv6 each time a Windows machine starts, and leaves it on where your network has it. If you change networks, shut the machine down and start it again.",
        ]),
        ReleaseNote(version: "0.4.23", changes: [
            "If Control-Left Arrow and Control-Right Arrow never reach Windows, your Mac is probably keeping them for moving between Spaces. AVM now tells you, once each time it opens, as a Windows machine starts, and Check This Machine says so too, with where to turn those shortcuts off.",
        ]),
        ReleaseNote(version: "0.4.22", changes: [
            "Put a machine's sound in one ear, so its screen reader and VoiceOver don't talk over each other, and set its own volume. It's in the machine's Settings, under Display and Sound, and it changes as soon as you save.",
            "If a machine stops answering and its screen stops changing for 10 minutes, AVM now says it looks stuck and what to do, and tells you when it's moving again.",
            "Check This Machine, Command-Option-Shift-C, tells you what's working in a machine and what isn't, with what to do: its screen reader, sound, clipboard and shared folder.",
            "Save Screen Reader Setup and Apply Saved Screen Reader Setup, in the Virtual Machine menu, carry your NVDA or Orca settings and add-ons to another machine. AVM can also put them in each new machine: turn that on in Settings, Watching Machines.",
            "Automatic backups: choose every day or every week, and a folder, in a machine's Settings under Startup and Recovery. A machine that's running waits until it's shut down. AVM keeps the newest three of each machine and permanently removes older ones.",
        ]),
        ReleaseNote(version: "0.4.21", changes: [
            "Experimental: DirectX 11 for Windows machines, for apps and games that won't start without it. Turn on 3D Graphics in the machine's Settings, under Display and Sound. AVM takes a restore point first and puts the driver in for you; the first restart after that can take several minutes. It's still unstable, so leave it off unless an app needs it. Read Screen and Describe Screen need the machine's window open while it's on.",
            "AVM's routine lines now wait only while your keyboard is in a machine and its screen reader is talking. Warnings and questions, such as another window taking the keyboard, are said at once. A machine's screen text is no longer written to the log that Report a Problem sends.",
            "Set up macOS for me now refuses a password it can't type, such as one with an accented letter, instead of leaving you locked out of the machine. That password also stays out of exported machines.",
            "Type Clipboard, Command-Shift-V, now tells you if it stopped part way, and pressing Command-Shift-V again stops it.",
            "Cancel now really stops a Windows or Linux download. A machine left running after AVM closed unexpectedly is now mentioned when AVM opens.",
            "If another program asks AVM to send a file from a private folder, such as Documents, AVM now asks you first. Sending from Finder works as before.",
        ]),
        ReleaseNote(version: "0.4.20", changes: [
            "When a Windows machine has its own keyboard, chosen in its Settings under Devices, it and its Windows apps stay out of Command-Tab, so the Mac's keyboard never lands in Windows by accident. Turn either back on in Settings, General.",
            "Rocky Linux has a shared folder now, and Remote Desktop works in AlmaLinux and Rocky Linux, with GNOME's own Remote Desktop.",
            "A Fedora, AlmaLinux, Rocky Linux or openSUSE machine installed by an older AVM can be repaired: choose Virtual Machine, Repair for AVM, while it's signed in, and type your password when it asks. Then Send File, the shared folder and Remote Desktop work in it.",
            "While your keyboard is in a machine and its screen reader is talking, AVM's routine updates wait, and AVM says them when you come back to the Mac. Problems are still said at once. Turn this off in Settings, Watching Machines.",
            "Describe Screen, Command-Option-Shift-O, says what a machine's screen looks like: its colour and its text by where it is, worked out on your Mac. For a fuller description, you can let AVM ask Anthropic's Claude, in Settings, Watching Machines, with your own API key; AVM asks before sending each machine's screen.",
            "Take the AVM Tour, in the Help menu, walks you through AVM in ten spoken steps.",
        ]),
        ReleaseNote(version: "0.4.19", changes: [
            "Download Linux now offers Kali Linux, AlmaLinux, Rocky Linux and openSUSE Tumbleweed as well as Ubuntu, Debian and Fedora. Each installs with no questions and starts with Orca on.",
            "On Fedora, AlmaLinux, Rocky Linux and openSUSE, Send File, the shared folder and Remote Desktop now work. A machine of these installed with an earlier AVM can't receive files: install it again.",
            "AlmaLinux and Rocky Linux have no Remote Desktop host to install, so their Settings don't offer Remote Desktop. Rocky Linux also has no shared folder service, so it has no shared folder setting.",
            "AVM watches running Windows and Linux machines: while no screen reader is running, such as during Setup or a restart, new text on the screen is read out. A screen reader that stops is started again. Each can be turned off in Settings, Watching Machines.",
            "AVM can take a restore point before Windows or Linux installs updates, so you can go back if an update breaks something. It's off until you turn it on in Settings, Watching Machines.",
            "Windows comes back after a restart that follows a restore point taken while it ran. Before, it could stop on a blank screen.",
            "A running machine's restore points are listed in its Settings. Before, the list was empty until the machine stopped.",
            "In Finder, Send to Virtual Machine in the right-click menu's Quick Actions sends the chosen files to Downloads in a running Windows or Linux machine.",
            "Set up macOS for me knows Apple's newer words for skipping the Apple Account, so it no longer goes round in circles on that screen.",
        ]),
        ReleaseNote(version: "0.4.18", changes: [
            "AVM speaks in VoiceOver again while you're in other apps. In 0.4.17 every line there failed and the system voice took over until AVM quit.",
            "The Permissions window now sees VoiceOver Utility's Allow VoiceOver to be controlled with AppleScript when it's on, and says whether that switch or AVM's Automation permission is the one still missing.",
            "Download Windows works in the setup wizard: the installer AVM makes from Microsoft's download is no longer called unreadable.",
        ]),
        ReleaseNote(version: "0.4.17", changes: [
            "New macOS machines can set themselves up: turn on Set up macOS for me in New macOS Virtual Machine, give your name and a password, and AVM goes through Setup Assistant, signs in, and turns on VoiceOver. If a screen stops it, AVM reads that screen to you.",
            "A Permissions window, in the AVM menu, lists everything macOS has to allow for AVM, what each is for, and a button to allow it. It opens by itself only when something you use isn't allowed.",
            "When AVM opens at login, only the machine that starts shows. AVM's own window stays away until you open AVM from the Dock or Applications.",
            "If no keyboard is chosen for Windows when a Windows machine starts, AVM offers the second keyboard it finds.",
            "Virtual Machine menu: Type Clipboard (Command-Shift-V) types what you copied into Windows, Read Screen (Command-Shift-O) reads out the text on a machine's screen, and Speak Updates and Disk (Command-Option-Shift-I) says the free disk space and pending updates in Windows or Linux.",
            "A machine's Sound settings can send its sound to any output device, such as headphones or a hearing aid, instead of the Mac's own.",
            "Report a Problem can email the whole log, and the AVM menu has Remove AVM, which takes AVM, its USB helper and its settings off your Mac.",
            "A saved macOS machine started while the Mac is locked now resumes when you unlock it, instead of starting afresh and losing where you were.",
        ]),
        ReleaseNote(version: "0.4.16", changes: [
            "Each virtual machine's name is a heading in the dashboard's table, so VO-Command-H goes from machine to machine. The table also says Memory and Disk in gigabytes.",
            "A machine's Settings come in five categories: General, Sharing, Devices, Display and Sound, and Startup and Recovery. Choose one in the Categories toolbar at the top, or with Command-1 to Command-5.",
            "The setup wizard can download Linux: Download Linux gets Ubuntu Desktop, Debian or Fedora, checks it, and chooses it as the installer.",
            "Each machine's Settings can leave it out of Command-Tab.",
            "AVM comes to the front whenever it starts a machine that takes your keyboard, so the keyboard goes in and AVM stays in Command-Tab.",
            "A new Ubuntu machine has the guest agent, so AVM can shut it down and send it files. Machines made earlier don't: install qemu-guest-agent in Ubuntu once.",
            "The setup wizard downloads Windows 11 for ARM itself, straight from Microsoft, in your Mac's language: no web page to use. It checks the download and makes it into the installer.",
            "Installing Windows no longer stops for good when an installer hangs during setup, as the one Microsoft's download gives did. Anything that didn't finish installs when you first sign in.",
            "When AVM opens at login and starts a machine, the list of machines opens too, behind it, so the other machines and AVM's settings are a window away.",
            "AVM has Settings of its own: Command-Comma from any AVM window. General has updates and What's New, Startup and Background has opening at login and running in the background, Keyboard has Caps Lock as the screen reader key, and Devices has Restart USB Helper. A machine's own Settings are now Command-Option-Comma.",
        ]),
        ReleaseNote(version: "0.4.15", changes: [
            "AVM no longer freezes for a moment when Windows apps or virtual machines are added to Command-Tab.",
            "The dashboard and the virtual machine window do less work in the background, so AVM stays quicker while machines run.",
        ]),
        ReleaseNote(version: "0.4.14", changes: [
            "The dashboard lists your virtual machines in a table: Name, Status, System, Cores, Memory, Disk and Drive. Choose one with the arrow keys. Return starts it, or enters it when it's running. VO-Shift-M opens its other actions, and its buttons are below the table.",
            "Each running virtual machine is in Command-Tab under its own name. Switch to it and your keyboard goes straight in. Control-Command-Escape brings you back.",
            "With AVM opening at login and a machine starting with it, AVM now comes to the front, so the machine gets your keyboard and AVM is in Command-Tab.",
            "After an update, this window says what's new. It's in the Help menu too.",
        ]),
        ReleaseNote(version: "0.4.13", changes: [
            "Windows apps you keep are in the Applications folder that Command-Shift-A opens, in AVM Windows Apps. Ones kept before move there by themselves.",
            "Opening two kept Windows apps at once works, and a slow app has 90 seconds to open.",
            "AVM Keyboard is gone from Windows: it didn't work. To swap Option and Command, use a remapping tool inside Windows, such as SharpKeys.",
        ]),
        ReleaseNote(version: "0.4.12", changes: [
            "Keep a Windows app in your Dock and Applications: Command-Tab to it and choose Keep in Dock and Applications. Opening it starts AVM and Windows if needed.",
            "Settings has Trackpad and Mouse: turn it off so a stray touch can't move or click in the machine.",
        ]),
    ]

    private static let seenKey = "AVMLastVersionSeen"
    private static var window: NSWindow?

    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The notes after `old` (all of them for nil), up to this version.
    static func since(_ old: String?) -> [ReleaseNote] {
        all.filter { note in
            (old.map { note.version.compare($0, options: .numeric) == .orderedDescending } ?? true)
                && note.version.compare(current, options: .numeric) != .orderedDescending
        }
    }

    /// At launch: once after an update, the notes since the version last
    /// run. Nothing after a first install. A copy updated from a version
    /// before this window, which stored no version, gets this version's
    /// notes when it has machines set up.
    static func showIfUpdated() {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: seenKey)
        guard last != current else { return }
        // A moment for the machine list to load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let notes: [ReleaseNote]
            if let last {
                notes = since(last)
            } else if VMStore.shared?.configurations.isEmpty == false {
                notes = all.filter { $0.version == current }
            } else {
                notes = []
            }
            guard !notes.isEmpty else {
                defaults.set(current, forKey: seenKey)
                return
            }
            AVMLog.write("AVM: updated from \(last ?? "an earlier version") to \(current); showing what's new")
            showWhenOnTheMac(notes)
        }
    }

    /// This version's notes and the two before, for the Help menu and the
    /// accessibility audit.
    static var recent: [ReleaseNote] { Array(since(nil).prefix(3)) }

    static func showRecent() { show(recent) }

    private static func showWhenOnTheMac(_ notes: [ReleaseNote]) {
        guard FocusLockManager.shared?.isLocked != true else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showWhenOnTheMac(notes) }
            return
        }
        // Seen once shown (2026-11-01 audit): marked earlier, quitting with
        // the keyboard in a machine lost them.
        UserDefaults.standard.set(current, forKey: seenKey)
        show(notes)
    }

    static func show(_ notes: [ReleaseNote]) {
        guard !notes.isEmpty else { return }
        window?.close()
        let title = notes.count == 1 ? "What's New in AVM \(notes[0].version)" : "What's New in AVM"
        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: WhatsNewView.size),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: WhatsNewView(title: title, notes: notes) { window?.close() })
        panel.center()
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

/// The notes: a heading per version, a line per change, and OK.
struct WhatsNewView: View {
    static let size = NSSize(width: 540, height: 460)
    let title: String
    let notes: [ReleaseNote]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(notes, id: \.version) { note in
                        VStack(alignment: .leading, spacing: 10) {
                            if notes.count > 1 {
                                Text("AVM \(note.version)")
                                    .font(.title3.bold())
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(note.changes, id: \.self) { change in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").accessibilityHidden(true)
                                    Text(change).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("OK", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height)
    }
}
