// AVMUpdater.swift
// Guest House — accessible virtual machines
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
// SPOKEN POINTER (2026-10-26): when a check finds an update, Guest House says so
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
    /// shows Guest House's Settings without checking for updates or asking to.
    /// Nor for any test run (2026-11-01): --test-update has its own updater,
    /// and the others have no business checking.
    init(starting: Bool = !CommandLine.arguments.contains { $0.hasPrefix("--test-") }) {
        controller = SPUStandardUpdaterController(
            startingUpdater: starting,
            updaterDelegate: announcer,
            userDriverDelegate: announcer
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        guard starting, let feed = (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String).flatMap(URL.init) else { return }
        let updater = controller.updater
        let poll = UpdatePoll(feed: feed, every: UpdatePoll.interval, updater: updater)
        announcer.found = { build in poll.offered = max(poll.offered ?? 0, build) }
        self.poll = poll
        // A window held while the keyboard was in a machine comes up when
        // the user is back in Guest House (2026-11-09, fifth audit #10).
        for name in [FocusLockManager.didUnlock, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showHeldUpdate() }
            }
        }
    }

    private func showHeldUpdate() {
        guard announcer.held, NSApp.isActive, !machineHasKeyboard else { return }
        announcer.held = false
        AVMLog.write("Guest House: Updates — showing the window held while the keyboard was in a machine.")
        controller.checkForUpdates(nil)
    }

    /// Menu-invoked check. Shows Sparkle's standard UI in every outcome,
    /// including "you're up to date" — the user asked, so silence would be
    /// a bug. The log line records the invocation; Sparkle's own UI carries
    /// the outcome. Privacy check: names a Guest House menu command only.
    func checkForUpdates() {
        AVMLog.write("Guest House: Check for Updates menu — invoking Sparkle user-initiated check.")
        controller.checkForUpdates(nil)
    }

    /// Automatic checks, Sparkle's and UpdatePoll's, for Guest House's Settings (2026-10-30). Sparkle
    /// keeps the choice in Guest House's defaults.
    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
            AVMLog.write("Guest House: Settings — check for updates automatically \(newValue ? "on" : "off")")
        }
    }
}

/// A new version within about 15 minutes (2026-11-02, the user's request).
/// Sparkle won't check more often than hourly, and a check that finds what the
/// user has already put off opens its window again, so Guest House looks at the feed
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
        AVMLog.write("Guest House: Updates — the feed has build \(newest ?? 0); asking Sparkle.")
        updater.checkForUpdatesInBackground()
    }
}

/// Says that an update was found and where its window is (header).
final class UpdateAnnouncer: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// An update found while the keyboard was in a machine, not shown yet.
    var held = false

    // While a machine has the keyboard, Sparkle's window waits (2026-11-09,
    // fifth audit #10): after a long idle it came up in front, with Install
    // focused, taking the keyboard from the machine.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated { !machineHasKeyboard }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        MainActor.assumeIsolated { held = true }
    }

    /// Testers get a release first (2026-11-02): one marked early in the feed is
    /// offered only to copies with this on, until Tools/promote-release.sh.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannels.allowed
    }

    /// The helper exits before the new Guest House starts (2026-10-28, code
    /// review): it used to keep running for its idle grace period, and
    /// the new Guest House talked to it.
    ///
    /// Only once Guest House is really quitting (2026-10-28, fourth audit): Sparkle
    /// calls this before it asks Guest House to quit, and stopping the helper here
    /// took every USB, Bluetooth and Windows-keyboard device out of the
    /// running machines before the question "Windows is still running.
    /// Quit Guest House?" was even asked; Cancel left them without their devices.
    /// applicationWillTerminate asks the helper to exit, after the
    /// machines have been shut down or saved.
    nonisolated(unsafe) static var relaunchingForUpdate = false
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        NSLog("Guest House: Updates — relaunching; the USB helper exits when Guest House quits.")
        Self.relaunchingForUpdate = true
    }

    /// What was found, so UpdatePoll doesn't ask about it again.
    @MainActor var found: ((Int) -> Void)?

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        let build = Int(item.versionString)
        Task { @MainActor in
            if let build { found?(build) }
            let inGuest = machineHasKeyboard
            AVMLog.write("Guest House: Updates — found version \(version).")
            Announcer.shared.announce(
                inGuest
                    ? "Guest House \(version) is available. Its window opens when you leave \(FocusLockManager.shared?.guestName ?? MacGuestRunner.shared.nameWithKeyboard ?? "the machine")."
                    : "Guest House \(version) is available. Its window is in Guest House, or opens when you switch to Guest House.",
                tone: .info
            )
        }
    }
}

/// Either way a machine can have the keyboard (2026-11-09, audit of 0.4.41
/// #9): a macOS guest doesn't use FocusLockManager, and Sparkle's window could
/// take its keys.
@MainActor private var machineHasKeyboard: Bool {
    FocusLockManager.shared?.isLocked == true || MacGuestRunner.shared.keyboardInGuest
}

// MARK: - What's New, after an update (2026-10-30)
//
// The user's request: easy-to-read release notes on the first launch after
// an update. A small window, "What's New in Guest House 0.4.14", a heading per
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
        ReleaseNote(version: "0.4.47", changes: [
            "This app has a new name: Guest House. Until now it was released as AVM, which is the name of Allison Meloy's original app, and people were taking one for the other. Guest House is this fork's own name; it is still built on Allison's work, under the same license. Nothing else about how it works has changed.",
            "Your machines, their saved sessions and restore points, your settings and the Windows apps you kept in the Dock all came across by themselves. In Finder, the Dock and Command-Tab the app is now Guest House, and the Windows apps folder in Applications is now Guest House Windows Apps.",
            "macOS treats Guest House as a new app, so it asks again for what AVM was allowed: Input Monitoring, the microphone, the camera, the local network, and the USB helper under Login Items in System Settings. Guest House asks for each the first time it needs it, and says what to do. If you had Open at Login turned on, turn it on again in Guest House's Settings. The first time Guest House needs a Remote Desktop password or your Describe Screen key, macOS asks for your Mac's password, because AVM stored them: choose Always Allow.",
            "System Settings may still list AVM under Privacy and Security and under Login Items. Those entries do nothing now and can be turned off or removed.",
        ]),
        ReleaseNote(version: "0.4.46", changes: [
            "Starting a machine no longer hangs when the Mac's sound output isn't answering, for example wireless headphones that are turned off while their USB receiver is still plugged in. Before, the machine took minutes to fail with \"Timed out waiting for a QMP response\". Now Guest House checks the sound output first and, within a few seconds, tells you which device isn't answering and what to do: turn it on, or choose another output in the Mac's Sound settings.",
        ]),
        ReleaseNote(version: "0.4.45", changes: [
            "Privacy: 0.4.43 stopped machines reaching services that run only on your Mac, but a machine could still get to them by another address; that way is closed now. A machine can read the Mac's clipboard only as it was when you last entered a machine or came back to Guest House, and can change it only while you're using that machine.",
            "Installing Windows: discs in French and other languages that translate Windows' edition names now install; before, Guest House refused them. If Windows Setup is stopped part way through its longest step, Guest House starts the install again and says so, instead of saying Setup was carrying on.",
            "Saved sessions: if a macOS machine can't resume and its question is closed by something else, the saved session is kept; only Start Fresh discards it.",
            "Screen readers: on GNOME, Guest House no longer restarts an Orca you turned off. Guest House says the right machine's name when two start together, and renaming a running machine no longer lets Guest House's updates talk over its screen reader. A saved NVDA or Orca setup now carries settings only.",
            "Downloads of Windows, Linux and macOS carry on from where they stopped when the connection drops, and the Mac stays awake through installs and downloads.",
            "Smaller fixes from a code review: Type Clipboard won't type into a machine whose keyboard isn't a US one, since the characters would come out wrong; a machine that finishes starting no longer takes the keyboard from a window you're typing in; Linux installs get the right time zone on Macs in India and some other regions; Speak Status says where the keyboard is once.",
        ]),
        ReleaseNote(version: "0.4.44", changes: [
            "Saving: if a machine is turned off just as its save ends, Guest House now checks whether the save landed and keeps it when it did, instead of guessing. Restore points are taken only once a machine has really started, and a session that loads late is carried on rather than thrown away.",
            "Renaming a machine now updates its window title and what VoiceOver says when you enter it, straight away.",
            "Drives: a Linux second drive that was reformatted or partitioned is found again by its new identity, and Guest House tells you once if it can't use it. If drive C can't be extended because something blocks it, Guest House says so.",
            "Screen readers: saving an NVDA or Orca setup no longer copies add-ons, scripts or update files, so setups are smaller and safer to apply. Saving a large setup from Windows no longer stops with no answer. On Cinnamon, Guest House can now start Orca again when it stops.",
            "Smaller fixes from a code review: Guest House recognises any Bluetooth keyboard when it offers to share one, download wording says whether your browser or Guest House is downloading, NVDA on Arm is found, and spoken errors are clearer.",
        ]),
        ReleaseNote(version: "0.4.43", changes: [
            "Privacy: passwords you copy from Passwords, 1Password or another password manager now stay on the Mac for Windows and Linux machines too, as they already did for macOS. Machines can no longer reach services that run only on your Mac, such as another machine's Remote Desktop set to This Mac only; the Internet works as before.",
            "Keyboard: the keyboard now stays tied to the machine you entered. Sending a device to another machine from Guest House's list can no longer leave the menu bar and Dock hidden, or send your typing to the wrong machine.",
            "Safer starts: if a saved session can't be carried on and another question closes Guest House's, the session is now kept, not discarded. A machine whose firmware settings file was damaged by a full disk starts again, and Guest House says so if it can't. Guest House notices within ten seconds when a full disk pauses a machine.",
            "Windows setup: Guest House says JAWS is talking only when JAWS really installed, and if a newer NVDA or JAWS won't download, the copy already on your Mac is installed instead of none. Saving and applying an NVDA setup is safer in machines with more than one account.",
            "Smaller fixes from a code review: a Linux second drive that lost its file system is described truthfully, and a machine's console log can no longer fill your Mac's disk.",
        ]),
        ReleaseNote(version: "0.4.42", changes: [
            "If a saved session can't be carried on, Guest House now asks whether to keep it or start fresh, and the session is kept safely even if you quit or the Mac restarts while it asks. A Save that's refused for lack of room no longer moves your devices. Settings no longer change the memory or cores of a machine that started while they were open.",
            "Screen readers in Linux: when Orca stops, Guest House starts it again the right way on GNOME, and now on KDE, XFCE and MATE as well. Applying a saved Orca or NVDA setup restarts the reader on every desktop.",
            "Keyboards: when your Mac's own keyboard sleeps, only the keyboard for Windows goes back to the Mac, not a Bluetooth keyboard or braille display too, and a Bluetooth device that did go back returns to its machine once the Mac has a keyboard again.",
            "Dialogs: Remove Guest House's first button is now Cancel, the Setup Wizard asks before stopping a download, and the question when you close a machine's window is spoken even while the machine has the keyboard. The avmctl command no longer waits for ever on a Guest House that's stuck.",
            "Many smaller fixes from two code reviews: the dashboard no longer pauses reading a machine's folder, Reinstall Windows clears the old disk's figures, Guest House's own tests leave your settings alone, and the Windows helper for Command-Tab opens programs only from where they're installed.",
        ]),
        ReleaseNote(version: "0.4.41", changes: [
            "Safer when something goes wrong: if a machine stops answering, Guest House itself no longer freezes. If Guest House ever hangs while a machine has the keyboard, Force Quit now works. A save that fails can no longer be loaded later over newer work, and your USB and Bluetooth devices go back into the machine.",
            "Restore points: a restore that can't finish now leaves both drives as they were, and a saved session is only let go once the restore has worked. If a restore point before updates can't be taken, Guest House says so.",
            "Applying a saved screen reader setup now checks it first, so a bad copy can't leave NVDA or Orca without your settings, and your original settings are always kept.",
            "A macOS machine that can't resume now asks whether to try again or start fresh, instead of discarding the session. Guest House no longer says a healthy machine looks stuck because its guest tools aren't answering. The update window now waits until you've left the machine, instead of taking the keyboard.",
            "Windows apps in Command-Tab: Windows only opens programs Guest House asks for, and other accounts can't ask for them. USB devices are returned to the Mac when Guest House's helper stops, and many smaller fixes from two code reviews.",
        ]),
        ReleaseNote(version: "0.4.40", changes: [
            "Fixed: 0.4.39 stopped responding, and took more and more memory, a second after a Windows machine came up, until it had to be force-quit. A mistake in yesterday's fix made Guest House call one of its own steps over and over. If Guest House 0.4.39 is open and stuck, force-quit it (Command-Option-Escape), then install this update. A machine left running by that Guest House is stopped when you start it again, as if its power had been cut.",
        ]),
        ReleaseNote(version: "0.4.39", changes: [
            "Fixed: the Windows apps in Command-Tab could stop changing, so apps you opened or closed in Windows were not added or removed, while opening one from Command-Tab still worked. A file Guest House had left open in Windows was keeping its helper from updating the list; Guest House now closes it, and the helper tells Guest House when it can't update the list so Guest House can use the latest one anyway. Every Windows machine gets the new helper when it next starts.",
            "Fixed: applying a saved screen reader setup, or reinstalling the Command-Tab helper, could leave that list unable to update for the same reason.",
        ]),
        ReleaseNote(version: "0.4.38", changes: [
            "Guest House no longer keeps a machine in a folder iCloud syncs, and won't start a machine whose disk iCloud has moved off your Mac: before, that could reinstall Windows over it. If a drive is disconnected while a machine runs, the machine pauses and Guest House says so; a new Check the Disk button in Settings, Startup and Recovery, checks a machine's disk and offers to repair it.",
            "A drive that connects under a different name, such as its name and a 1, is found again. A second drive left half-made keeps its real size, and Windows finds it. If Guest House can't read your list of machines, Help, Restore the Machine List from a Copy puts back the copy it kept.",
            "Restore points: one made while a machine is stopped is now written safely; one missing its firmware copy is listed as incomplete and can't be restored. Guest House checks for free space before saving a machine's memory, and Restore waits for a save that began meanwhile.",
            "Fixed: a time limit could run out while your Mac slept, so Guest House said a disk change or an app install had failed when it hadn't. A stuck USB helper could hold Save, Shut Down and Quit for good. Deleting a machine or old backups on a drive with no Trash now works.",
            "Inside Windows, Guest House's folder is now owned by the system, and exporting a machine that is still being set up is refused, because its setup answers hold the account password. Choosing NVDA or JAWS at setup now turns the other off: installed together, both talked at sign-in. A Bluetooth braille display's capabilities can now be read by Windows.",
        ]),
        ReleaseNote(version: "0.4.37", changes: [
            "Restore points can be undone: before going back, Guest House saves the machine as it is now, as Before going back to and the point's name, so you can return. Untick the box in the question to skip it. Guest House keeps the two newest of these.",
            "Restore points work while a Windows or Linux machine runs: save one with open apps, delete one, or restore, which turns the machine off, puts it back and starts it again. Each restore point can also be renamed.",
            "Fixed: with two machines whose names began alike, such as Ubuntu and Ubuntu backup, automatic backups could delete the other machine's backups. Old backups now go to the Trash, and only a machine's own.",
            "The question about using a second keyboard for Windows, and Describe Screen's question about Claude, no longer come up unheard while you're in a machine. Return now chooses Not Now and Use the Mac Only.",
            "A machine's files can only be opened by your account on this Mac, also in a folder you chose. Before, other accounts could read them there.",
        ]),
        ReleaseNote(version: "0.4.36", changes: [
            "AVM Receiver and Settings, iPhone Receiver, have been removed: they weren't working well enough. Guest House forgets any iPhone or iPad you paired, and you can delete the AVM Receiver app from your device. Nothing else changes.",
        ]),
        ReleaseNote(version: "0.4.35", changes: [
            "Fixed for AVM Receiver: opening a machine again from your iPhone or iPad lost its sound, and the device said the sound couldn't reach it. Opening a machine the device already had open also closed it there.",
            "A machine with 3D graphics on only has a picture while its window is open on the Mac. The device now says so once, instead of just showing no picture. Sound and keys work either way.",
        ]),
        ReleaseNote(version: "0.4.34", changes: [
            "Fixed: with VoiceOver on, choosing Pair a Device in Settings, iPhone Receiver, made Guest House quit as soon as the code appeared. The code can no longer be selected with the mouse; VoiceOver still reads it letter by letter, and Copy Code copies it.",
        ]),
        ReleaseNote(version: "0.4.33", changes: [
            "New in Guest House's Settings: iPhone Receiver, off until you turn it on. With the AVM Receiver app on an iPhone or iPad, you can list your machines, start and stop them, and open a Windows or Linux one: you hear it on the device, type on a Bluetooth keyboard, and see its screen. While a device has a machine open, its sound goes there and not to the Mac.",
            "You pair each device with a code from Settings, and you can remove a device there. The app is still being tested: it has run in Apple's simulator but not yet on a real iPhone or with VoiceOver on, so expect rough edges. It can't open macOS machines yet, and has no microphone, mouse or braille.",
        ]),
        ReleaseNote(version: "0.4.32", changes: [
            "The dashboard's Disk column now has a figure for a machine that hasn't reported how full it is yet, even when it's off, and for macOS machines: how much room its disk takes on your Mac, such as 84 GB on this Mac, of 514 GB. That figure also holds restore points, and doesn't shrink when you delete files in the machine. Once a Windows or Linux machine has run for a couple of minutes, the column says how much is used inside it instead.",
        ]),
        ReleaseNote(version: "0.4.31", changes: [
            "The dashboard's Disk column now says how full each machine is, such as 120 of 404 GB used. A machine that's shut down shows what it last reported, and says so. This is for Windows and Linux machines.",
            "When you make a Windows machine's disk larger in Settings, Guest House gives drive C the new space the next time Windows starts, and tells you its new size. There's no command to type any more.",
            "You can add a second drive to a Windows or Linux machine in Settings, like putting another drive in a PC. Windows shows it as a new drive such as D, and Linux at /mnt/avm-data. Restore points put it back along with the rest of the machine. It can't be removed yet, except by deleting the machine.",
        ]),
        ReleaseNote(version: "0.4.30", changes: [
            "The categories in the toolbar of a machine's Settings and Guest House's Settings are now there as soon as the window opens. VoiceOver sometimes missed them before, and this should stop that. If it still happens, please report it.",
        ]),
        ReleaseNote(version: "0.4.29", changes: [
            "Install Apps, in the Virtual Machine menu: tick Chrome, Firefox, Thunderbird, LibreOffice, Zoom, VLC, Audacity, 7-Zip, Notepad++, Visual Studio Code, Git or Python, and they install in a running Windows machine one at a time, with no questions. Guest House says each as it finishes, and you can keep working meanwhile.",
        ]),
        ReleaseNote(version: "0.4.28", changes: [
            "Guest House no longer reads a machine's screen by itself. Press Command-Shift-O to hear it, including during Setup or a restart. The one exception: if Windows stops answering and shows a blue screen, Guest House says so.",
            "Guest House looks for a new version every 15 minutes, not once a day, so you hear about one soon after it comes out. It says so once for each version.",
            "Command-Shift-O and Guest House's other keys that answer or act now work with your keyboard in the machine: Describe Screen, Speak Status, Speak Updates and Disk, Check This Machine, Type Clipboard and Send Ctrl-Alt-Delete. Before, they reached Windows as Windows key shortcuts.",
            "Control-Fn-Right now reaches the machine, so it goes to the end of a document, as do Control with the other arrows, Home, End, Page Up and Page Down. Before, the Mac's window tiling could take them.",
            "Guest House keeps its last ten logs, not three, so a problem's log is still there after a few restarts.",
        ]),
        ReleaseNote(version: "0.4.27", changes: [
            "3D graphics in Windows is now clearly marked experimental. A machine with it on may freeze or stop, so don't turn it on for a machine you rely on.",
            "Guest House now keeps an eye on the program that runs each machine, and warns you if it's running short of files or memory, or has reported a fault. Check This Machine says so too.",
            "When Guest House says a machine looks stuck, it saves what the machine was doing, and Report a Problem sends that along. Please send one if it happens.",
            "Testers can get new versions early: turn on Get new versions early, as a tester, in Guest House's Settings. Those versions have had less testing.",
            "Windows apps may now take up to 12 seconds to appear in Command-Tab when nothing has changed for a while, which keeps Windows' own log much quieter.",
        ]),
        ReleaseNote(version: "0.4.26", changes: [
            "A machine can now keep far more internet connections open at once. Each time a machine starts, Guest House checks how many your Mac allows and uses that, instead of stopping new connections at about ten thousand.",
        ]),
        ReleaseNote(version: "0.4.25", changes: [
            "A machine with many internet connections open, as a speed test makes, could stop responding and need a force restart. Guest House could only keep track of about a thousand open files and connections at once, and that limit is gone. If a Windows machine still freezes on a busy website, please send your log from the Help menu.",
        ]),
        ReleaseNote(version: "0.4.24", changes: [
            "Websites should open faster in Windows machines on a network without IPv6. Windows was waiting about a fifth of a second on every new connection. Guest House now checks for IPv6 each time a Windows machine starts, and leaves it on where your network has it. If you change networks, shut the machine down and start it again.",
        ]),
        ReleaseNote(version: "0.4.23", changes: [
            "If Control-Left Arrow and Control-Right Arrow never reach Windows, your Mac is probably keeping them for moving between Spaces. Guest House now tells you, once each time it opens, as a Windows machine starts, and Check This Machine says so too, with where to turn those shortcuts off.",
        ]),
        ReleaseNote(version: "0.4.22", changes: [
            "Put a machine's sound in one ear, so its screen reader and VoiceOver don't talk over each other, and set its own volume. It's in the machine's Settings, under Display and Sound, and it changes as soon as you save.",
            "If a machine stops answering and its screen stops changing for 10 minutes, Guest House now says it looks stuck and what to do, and tells you when it's moving again.",
            "Check This Machine, Command-Option-Shift-C, tells you what's working in a machine and what isn't, with what to do: its screen reader, sound, clipboard and shared folder.",
            "Save Screen Reader Setup and Apply Saved Screen Reader Setup, in the Virtual Machine menu, carry your NVDA or Orca settings and add-ons to another machine. Guest House can also put them in each new machine: turn that on in Settings, Watching Machines.",
            "Automatic backups: choose every day or every week, and a folder, in a machine's Settings under Startup and Recovery. A machine that's running waits until it's shut down. Guest House keeps the newest three of each machine and permanently removes older ones.",
        ]),
        ReleaseNote(version: "0.4.21", changes: [
            "Experimental: DirectX 11 for Windows machines, for apps and games that won't start without it. Turn on 3D Graphics in the machine's Settings, under Display and Sound. Guest House takes a restore point first and puts the driver in for you; the first restart after that can take several minutes. It's still unstable, so leave it off unless an app needs it. Read Screen and Describe Screen need the machine's window open while it's on.",
            "Guest House's routine lines now wait only while your keyboard is in a machine and its screen reader is talking. Warnings and questions, such as another window taking the keyboard, are said at once. A machine's screen text is no longer written to the log that Report a Problem sends.",
            "Set up macOS for me now refuses a password it can't type, such as one with an accented letter, instead of leaving you locked out of the machine. That password also stays out of exported machines.",
            "Type Clipboard, Command-Shift-V, now tells you if it stopped part way, and pressing Command-Shift-V again stops it.",
            "Cancel now really stops a Windows or Linux download. A machine left running after Guest House closed unexpectedly is now mentioned when Guest House opens.",
            "If another program asks Guest House to send a file from a private folder, such as Documents, Guest House now asks you first. Sending from Finder works as before.",
        ]),
        ReleaseNote(version: "0.4.20", changes: [
            "When a Windows machine has its own keyboard, chosen in its Settings under Devices, it and its Windows apps stay out of Command-Tab, so the Mac's keyboard never lands in Windows by accident. Turn either back on in Settings, General.",
            "Rocky Linux has a shared folder now, and Remote Desktop works in AlmaLinux and Rocky Linux, with GNOME's own Remote Desktop.",
            "A Fedora, AlmaLinux, Rocky Linux or openSUSE machine installed by an older Guest House can be repaired: choose Virtual Machine, Repair for Guest House, while it's signed in, and type your password when it asks. Then Send File, the shared folder and Remote Desktop work in it.",
            "While your keyboard is in a machine and its screen reader is talking, Guest House's routine updates wait, and Guest House says them when you come back to the Mac. Problems are still said at once. Turn this off in Settings, Watching Machines.",
            "Describe Screen, Command-Option-Shift-O, says what a machine's screen looks like: its colour and its text by where it is, worked out on your Mac. For a fuller description, you can let Guest House ask Anthropic's Claude, in Settings, Watching Machines, with your own API key; Guest House asks before sending each machine's screen.",
            "Take the Guest House Tour, in the Help menu, walks you through Guest House in ten spoken steps.",
        ]),
        ReleaseNote(version: "0.4.19", changes: [
            "Download Linux now offers Kali Linux, AlmaLinux, Rocky Linux and openSUSE Tumbleweed as well as Ubuntu, Debian and Fedora. Each installs with no questions and starts with Orca on.",
            "On Fedora, AlmaLinux, Rocky Linux and openSUSE, Send File, the shared folder and Remote Desktop now work. A machine of these installed with an earlier Guest House can't receive files: install it again.",
            "AlmaLinux and Rocky Linux have no Remote Desktop host to install, so their Settings don't offer Remote Desktop. Rocky Linux also has no shared folder service, so it has no shared folder setting.",
            "Guest House watches running Windows and Linux machines: while no screen reader is running, such as during Setup or a restart, new text on the screen is read out. A screen reader that stops is started again. Each can be turned off in Settings, Watching Machines.",
            "Guest House can take a restore point before Windows or Linux installs updates, so you can go back if an update breaks something. It's off until you turn it on in Settings, Watching Machines.",
            "Windows comes back after a restart that follows a restore point taken while it ran. Before, it could stop on a blank screen.",
            "A running machine's restore points are listed in its Settings. Before, the list was empty until the machine stopped.",
            "In Finder, Send to Virtual Machine in the right-click menu's Quick Actions sends the chosen files to Downloads in a running Windows or Linux machine.",
            "Set up macOS for me knows Apple's newer words for skipping the Apple Account, so it no longer goes round in circles on that screen.",
        ]),
        ReleaseNote(version: "0.4.18", changes: [
            "Guest House speaks in VoiceOver again while you're in other apps. In 0.4.17 every line there failed and the system voice took over until Guest House quit.",
            "The Permissions window now sees VoiceOver Utility's Allow VoiceOver to be controlled with AppleScript when it's on, and says whether that switch or Guest House's Automation permission is the one still missing.",
            "Download Windows works in the setup wizard: the installer Guest House makes from Microsoft's download is no longer called unreadable.",
        ]),
        ReleaseNote(version: "0.4.17", changes: [
            "New macOS machines can set themselves up: turn on Set up macOS for me in New macOS Virtual Machine, give your name and a password, and Guest House goes through Setup Assistant, signs in, and turns on VoiceOver. If a screen stops it, Guest House reads that screen to you.",
            "A Permissions window, in the Guest House menu, lists everything macOS has to allow for Guest House, what each is for, and a button to allow it. It opens by itself only when something you use isn't allowed.",
            "When Guest House opens at login, only the machine that starts shows. Guest House's own window stays away until you open Guest House from the Dock or Applications.",
            "If no keyboard is chosen for Windows when a Windows machine starts, Guest House offers the second keyboard it finds.",
            "Virtual Machine menu: Type Clipboard (Command-Shift-V) types what you copied into Windows, Read Screen (Command-Shift-O) reads out the text on a machine's screen, and Speak Updates and Disk (Command-Option-Shift-I) says the free disk space and pending updates in Windows or Linux.",
            "A machine's Sound settings can send its sound to any output device, such as headphones or a hearing aid, instead of the Mac's own.",
            "Report a Problem can email the whole log, and the Guest House menu has Remove Guest House, which takes Guest House, its USB helper and its settings off your Mac.",
            "A saved macOS machine started while the Mac is locked now resumes when you unlock it, instead of starting afresh and losing where you were.",
        ]),
        ReleaseNote(version: "0.4.16", changes: [
            "Each virtual machine's name is a heading in the dashboard's table, so VO-Command-H goes from machine to machine. The table also says Memory and Disk in gigabytes.",
            "A machine's Settings come in five categories: General, Sharing, Devices, Display and Sound, and Startup and Recovery. Choose one in the Categories toolbar at the top, or with Command-1 to Command-5.",
            "The setup wizard can download Linux: Download Linux gets Ubuntu Desktop, Debian or Fedora, checks it, and chooses it as the installer.",
            "Each machine's Settings can leave it out of Command-Tab.",
            "Guest House comes to the front whenever it starts a machine that takes your keyboard, so the keyboard goes in and Guest House stays in Command-Tab.",
            "A new Ubuntu machine has the guest agent, so Guest House can shut it down and send it files. Machines made earlier don't: install qemu-guest-agent in Ubuntu once.",
            "The setup wizard downloads Windows 11 for ARM itself, straight from Microsoft, in your Mac's language: no web page to use. It checks the download and makes it into the installer.",
            "Installing Windows no longer stops for good when an installer hangs during setup, as the one Microsoft's download gives did. Anything that didn't finish installs when you first sign in.",
            "When Guest House opens at login and starts a machine, the list of machines opens too, behind it, so the other machines and Guest House's settings are a window away.",
            "Guest House has Settings of its own: Command-Comma from any Guest House window. General has updates and What's New, Startup and Background has opening at login and running in the background, Keyboard has Caps Lock as the screen reader key, and Devices has Restart USB Helper. A machine's own Settings are now Command-Option-Comma.",
        ]),
        ReleaseNote(version: "0.4.15", changes: [
            "Guest House no longer freezes for a moment when Windows apps or virtual machines are added to Command-Tab.",
            "The dashboard and the virtual machine window do less work in the background, so Guest House stays quicker while machines run.",
        ]),
        ReleaseNote(version: "0.4.14", changes: [
            "The dashboard lists your virtual machines in a table: Name, Status, System, Cores, Memory, Disk and Drive. Choose one with the arrow keys. Return starts it, or enters it when it's running. VO-Shift-M opens its other actions, and its buttons are below the table.",
            "Each running virtual machine is in Command-Tab under its own name. Switch to it and your keyboard goes straight in. Control-Command-Escape brings you back.",
            "With Guest House opening at login and a machine starting with it, Guest House now comes to the front, so the machine gets your keyboard and Guest House is in Command-Tab.",
            "After an update, this window says what's new. It's in the Help menu too.",
        ]),
        ReleaseNote(version: "0.4.13", changes: [
            "Windows apps you keep are in the Applications folder that Command-Shift-A opens, in Guest House Windows Apps. Ones kept before move there by themselves.",
            "Opening two kept Windows apps at once works, and a slow app has 90 seconds to open.",
            "AVM Keyboard is gone from Windows: it didn't work. To swap Option and Command, use a remapping tool inside Windows, such as SharpKeys.",
        ]),
        ReleaseNote(version: "0.4.12", changes: [
            "Keep a Windows app in your Dock and Applications: Command-Tab to it and choose Keep in Dock and Applications. Opening it starts Guest House and Windows if needed.",
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
            AVMLog.write("Guest House: updated from \(last ?? "an earlier version") to \(current); showing what's new")
            showWhenOnTheMac(notes)
        }
    }

    /// This version's notes and the two before, for the Help menu and the
    /// accessibility audit.
    static var recent: [ReleaseNote] { Array(since(nil).prefix(3)) }

    static func showRecent() { show(recent) }

    private static func showWhenOnTheMac(_ notes: [ReleaseNote]) {
        // Nor at a quiet login (2026-11-09, fifth audit #31): Guest House's windows
        // stay away until the user opens Guest House, and this took the front from
        // whatever they had started. It waits for that, as for the lock.
        guard !machineHasKeyboard, !BackgroundMode.shared.quietUntilOpened else {
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
        let title = notes.count == 1 ? "What's New in Guest House \(notes[0].version)" : "What's New in Guest House"
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
                                Text("Guest House \(note.version)")
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
