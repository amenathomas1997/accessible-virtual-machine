//
//  main.swift
//  AVMUSBHelper
//
//  The root USB helper for Guest House. Runs as a launchd daemon registered
//  by Guest House through SMAppService, on demand, and exits when idle.
//
//  Scope contract (handoff 46, decision 1b): claim, stream, release,
//  report. Nothing else. No enumeration, no policy, no persistence,
//  no speech. Guest House does the talking. This process supplies honest
//  state.
//
//  Increment 1 (2026-09-12): attach, detach and status are real.
//  The claim / stream / release path is probe3's, compiled in as
//  usbstream.c and reached through the bridging header. Each device
//  gets its own serial queue that runs the blocking pump; state
//  changes go back to Guest House through the client protocol.
//
//  The listener, the code signing gate and the idle exit were proven
//  live on 2026-09-07 and are unchanged.
//
//  Log levels: lifecycle lines are .default so `log show` keeps them.
//  .info is dropped by default and was invisible in the first proof.
//
import Foundation
import SystemConfiguration
import Security
import os.log
// MARK: - Identity
/// Bumped whenever the helper's behavior changes so Guest House can tell a
/// stale helper from a current one.
let helperBuildVersion = AVMUSBHelperNames.helperBuildVersion
let log = OSLog(subsystem: AVMUSBHelperNames.machServiceName, category: "helper")
/// usbredir debug logging for every stream. Off in normal use: it is
/// chatty, and a root process should not narrate USB traffic into the
/// unified log by default.
let verboseStreamLogging = false
/// Who may talk to this helper: Guest House, signed by the same team that
/// signed this helper. A Debug helper carries the development
/// certificate and trusts Debug Guest House; a Developer ID helper trusts only
/// Developer ID Guest House from its own team, so a release helper still never
/// trusts the development team.
///
/// Read from the helper's own signature (2026-10-25). The two team IDs
/// used to be written in here, so a build signed by any other team got
/// a helper that refused every connection, and USB stopped working
/// with nothing pointing at the signature. nil when the helper has no
/// team (ad-hoc or unsigned); the listener then refuses everything.
let clientTeamID: String? = ownTeamIdentifier()

/// The Developer ID Application certificate's marker in its leaf. A
/// helper signed with one requires it of the client too (2026-10-25,
/// security audit): the team's development certificates carry the same
/// team in subject.OU, so without this a release helper would also serve a
/// development build of Guest House, which is debuggable (get-task-allow) and so
/// can be driven by any process the user runs.
let developerIDMarker = "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
let helperIsDeveloperID: Bool = signatureSatisfies("anchor apple generic and " + developerIDMarker)

let clientRequirement: String? = clientTeamID.map { team in
    "anchor apple generic"
        + " and identifier \"\(AVMUSBHelperNames.clientBundleIdentifier)\""
        + " and certificate leaf[subject.OU] = \"\(team)\""
        + (helperIsDeveloperID ? " and " + developerIDMarker : "")
        // Build 5 (0.2.0) is the first without disable-library-validation
        // (2026-11-09, fifth audit #20): an older signed copy could have code
        // injected and speak to this root helper as Guest House. XPC honours this
        // clause and compares it as a number (tested with signed bundles).
        + " and info[CFBundleVersion] >= \"5\""
}

/// True when this process's own signature meets `requirement`.
func signatureSatisfies(_ requirement: String) -> Bool {
    var code: SecCode?
    var req: SecRequirement?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else {
        return false
    }
    return SecCodeCheckValidity(code, [], req) == errSecSuccess
}

/// The Team ID in this process's own code signature, or nil.
func ownTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(
              staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
          ) == errSecSuccess,
          let dict = info as? [String: Any],
          let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
          !team.isEmpty else { return nil }
    return team
}
// MARK: - Idle exit
/// The helper exits after this long with no connections and no
/// claimed devices. launchd starts it again on the next XPC call.
let idleGracePeriod: TimeInterval = 30
final class IdleWatch {
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "idle")
    private(set) var connectionCount = 0
    private(set) var claimedDeviceCount = 0
    /// A keyboard for Windows wanted or held (KeyboardHold.swift): the
    /// helper stays while it is.
    private(set) var keyboardHeld = false
    /// Bluetooth devices held for a virtual machine (BluetoothHold.swift).
    private(set) var bluetoothHeld = 0
    /// Synchronous (2026-10-25, code audit): counted before the connection
    /// resumes, so its first attach can never meet an idle exit already on
    /// its way. Called from the listener's queue, never from this one.
    func connectionOpened() {
        queue.sync {
            self.connectionCount += 1
            self.cancelTimer()
        }
    }

    /// Arms the idle clock from outside this queue (the launch path used
    /// to call armIfIdle from the main thread, racing the queue).
    func armIfIdleFromOutside() {
        queue.async { self.armIfIdle() }
    }
    func connectionClosed() {
        queue.async {
            self.connectionCount = max(0, self.connectionCount - 1)
            self.armIfIdle()
        }
    }
    func devicesChanged(count: Int) {
        queue.async {
            self.claimedDeviceCount = count
            if count > 0 {
                self.cancelTimer()
            } else {
                self.armIfIdle()
            }
        }
    }
    func bluetoothChanged(count: Int) {
        queue.async {
            self.bluetoothHeld = count
            if count > 0 { self.cancelTimer() } else { self.armIfIdle() }
        }
    }
    func keyboardChanged(held: Bool) {
        queue.async {
            self.keyboardHeld = held
            if held { self.cancelTimer() } else { self.armIfIdle() }
        }
    }
    func armIfIdle() {
        guard connectionCount == 0, claimedDeviceCount == 0, !keyboardHeld, bluetoothHeld == 0 else { return }
        cancelTimer()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + idleGracePeriod)
        t.setEventHandler {
            // Still idle? A connection or device may have arrived as the
            // timer fired. Then libusb is stopped on the registry's queue,
            // where every attach runs, so none can be using it as it goes
            // (2026-10-25, code audit: libusb_exit under a running open in
            // a root process).
            guard self.connectionCount == 0, self.claimedDeviceCount == 0, !self.keyboardHeld, self.bluetoothHeld == 0 else { return }
            registry.queue.sync {
                guard registry.isEmpty else { return }
                os_log("idle for %{public}.0f s with no connections and no devices; exiting", log: log, type: .default, idleGracePeriod)
                // Not under a release set aside (2026-10-29, sixth audit): its
                // pump still uses libusb's context, which libusb_exit freed.
                // The process exiting lets go of its device either way.
                if registry.noStreamsLeft { avm_usb_runtime_stop() }
                exit(0)
            }
        }
        t.resume()
        timer = t
    }
    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}
let idle = IdleWatch()
// MARK: - Device registry
/// One held device: its identity, where it is in its life, the C
/// stream behind it, and which Guest House connection asked for it.
final class DeviceEntry {
    let device: AVMUSBDeviceIdentity
    let socketPath: String
    /// Serial queue that runs this device's pump. One per device so a
    /// blocked pump never stalls another device or the registry.
    let queue: DispatchQueue
    var state: AVMUSBDeviceState = .attaching
    var stream: OpaquePointer?
    /// What ended the stream, if anything did, so the final released
    /// report can say why.
    var endDetail: String?
    weak var connection: NSXPCConnection?
    /// A detach waiting for the pump to finish.
    var detachReply: ((Bool, String?) -> Void)?
    var detachTimeout: DispatchWorkItem?
    /// Already told to stop because its user left the screen (2026-11-09,
    /// fifth audit #38), so a release that hangs isn't asked for every 3 s.
    var stoppedForConsole = false
    /// The user whose Guest House attached this device. One root helper serves
    /// every user on the Mac (fast user switching), so another user's Guest House
    /// must not see or release it (2026-10-25, code audit).
    let ownerUID: uid_t
    init(device: AVMUSBDeviceIdentity, socketPath: String, connection: NSXPCConnection?) {
        self.device = device
        self.socketPath = socketPath
        self.connection = connection
        self.ownerUID = connection?.effectiveUserIdentifier ?? uid_t.max
        self.queue = DispatchQueue(label: "device." + device.vidPidString)
    }
}
/// Everything the helper holds. All access on `queue`.
final class DeviceRegistry {
    let queue = DispatchQueue(label: "registry")
    private var entries: [AVMUSBDeviceIdentity: DeviceEntry] = [:]
    /// For the idle exit, which reads it inside queue.sync.
    var isEmpty: Bool { entries.isEmpty }
    /// Devices attached by an account other than `uid` (2026-11-05, second
    /// audit): a restart would yank them from that account's machine.
    func hasEntries(notOwnedBy uid: uid_t) -> Bool { entries.values.contains { $0.ownerUID != uid } }
    /// Entries whose release never finished; kept so their streams'
    /// callbacks stay valid. The process exiting releases their devices.
    private var abandoned: [DeviceEntry] = []
    /// No stream left that could still call libusb, live or set aside
    /// (2026-10-29, sixth audit): a pump stuck in its release still does,
    /// so libusb is stopped only then. Read inside queue.sync.
    var noStreamsLeft: Bool { entries.isEmpty && abandoned.isEmpty }
    private var runtimeStarted = false
    // MARK: Attach
    func attach(_ device: AVMUSBDeviceIdentity,
                streamSocketPath: String,
                peerPID: Int,
                connection: NSXPCConnection?,
                reply: @escaping (Bool, String?, String?) -> Void) {
        // The socket path comes from the client, and this process is root:
        // check it before connecting (2026-10-25, security audit).
        guard let uid = connection?.effectiveUserIdentifier else {
            os_log("attach refused: no client identity", log: log, type: .error)
            reply(false, "socket", "the helper could not tell which user asked")
            return
        }
        // Only for the person at the screen (2026-10-26, security audit),
        // as the keyboard hold already was: with fast user switching, a
        // background user's Guest House must not take a device the person at the
        // screen just plugged in.
        var consoleUID: uid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) != nil, consoleUID == uid else {
            os_log("attach refused: the asking user isn't at the screen", log: log, type: .default)
            reply(false, "console", "Only the person using this Mac's screen can send a USB device to a virtual machine.")
            return
        }
        if let problem = streamSocketProblem(streamSocketPath, uid: uid) {
            os_log("attach refused: %{public}@", log: log, type: .error, problem)
            reply(false, "socket", problem)
            return
        }
        queue.async {
            if let existing = self.entries[device] {
                os_log("attach refused: %{public}@ is already held (state %{public}d)",
                       log: log, type: .default, device.description, existing.state.rawValue)
                reply(false, "already attached",
                      "\(device.displayName) is already attached to a VM.")
                return
            }
            if self.runtimeStarted == false {
                var step = [CChar](repeating: 0, count: 128)
                var detail = [CChar](repeating: 0, count: 512)
                if avm_usb_runtime_start(&step, step.count, &detail, detail.count) != 0 {
                    let s = String(cString: step)
                    let d = String(cString: detail)
                    os_log("USB runtime failed to start at %{public}@: %{public}@", log: log, type: .error, s, d)
                    reply(false, s, d)
                    return
                }
                self.runtimeStarted = true
                os_log("USB runtime started", log: log, type: .default)
            }
            let entry = DeviceEntry(device: device, socketPath: streamSocketPath, connection: connection)
            // Listed before the slow part (2026-11-09, fifth audit #39): the
            // open and capture run on the device's own queue, up to 10 s a
            // try, and on this one every other device's release waited behind
            // them. Being listed is also what keeps libusb running under
            // them, since the idle exit and Restart stop it only with nothing
            // listed, and what refuses a second attach of the same device.
            self.entries[device] = entry
            idle.devicesChanged(count: self.entries.count)
            self.watchConsoleWhileListed()
            entry.queue.async {
                let context = Unmanaged.passUnretained(entry).toOpaque()
                var step = [CChar](repeating: 0, count: 128)
                var detail = [CChar](repeating: 0, count: 512)
                os_log("attaching %{public}@ to %{public}@", log: log, type: .default,
                       device.description, streamSocketPath)
                let stream = avm_usb_stream_attach(device.vendorID, device.productID,
                                                   device.busNumber, device.deviceAddress,
                                                   streamSocketPath, uid, pid_t(clamping: peerPID),
                                                   verboseStreamLogging ? 1 : 0,
                                                   streamEventCallback, context,
                                                   &step, step.count, &detail, detail.count)
                let stepText = String(cString: step)
                let detailText = String(cString: detail)
                let startPump = self.queue.sync {
                    self.finishAttach(entry, stream: stream, step: stepText, detail: detailText, reply: reply)
                }
                guard let stream else { return }
                // The pump owns the device from here until it returns. The
                // stream is freed only after run has come back, on the same
                // queue, so nothing else can touch a dead pointer. Asked to
                // let go while attaching, free alone releases the device,
                // and "is now in Windows" is never said for it.
                if startPump { avm_usb_stream_run(stream) }
                avm_usb_stream_free(stream)
            }
        }
    }

    /// The attach is back from its own queue. On `queue`. True when the pump
    /// should run.
    private func finishAttach(_ entry: DeviceEntry, stream: OpaquePointer?, step: String, detail: String,
                              reply: @escaping (Bool, String?, String?) -> Void) -> Bool {
        let device = entry.device
        guard let stream else {
            os_log("attach of %{public}@ failed at %{public}@: %{public}@",
                   log: log, type: .error, device.description, step, detail)
            if entries[device] === entry { entries[device] = nil }
            idle.devicesChanged(count: entries.count)
            watchConsoleWhileListed()
            entry.state = .failed
            report(entry, detail: "\(step): \(detail)")
            reply(false, step, detail)
            if let pending = entry.detachReply {
                entry.detachReply = nil
                pending(false, "\(device.displayName) is not attached, so there is nothing to release.")
            }
            return false
        }
        entry.stream = stream
        reply(true, nil, nil)
        // A release that came in while the device was attaching.
        if let pending = entry.detachReply {
            entry.detachReply = nil
            beginRelease(entry, stream: stream, reply: pending)
            return false
        }
        return true
    }
    // MARK: Detach
    /// requester: the asking connection's user; nil only for the helper's
    /// own release when a connection ends.
    func detach(_ device: AVMUSBDeviceIdentity,
                requester: uid_t?,
                reply: @escaping (Bool, String?) -> Void) {
        queue.async {
            if let requester, let entry = self.entries[device], entry.ownerUID != requester {
                os_log("detach refused: %{public}@ belongs to another user", log: log, type: .error, device.description)
                reply(false, "\(device.displayName) is not attached by you, so there is nothing to release.")
                return
            }
            guard let entry = self.entries[device] else {
                os_log("detach refused: %{public}@ is not held", log: log, type: .default, device.description)
                reply(false, "\(device.displayName) is not attached, so there is nothing to release.")
                return
            }
            if entry.detachReply != nil {
                reply(false, "\(device.displayName) is already being released.")
                return
            }
            guard let stream = entry.stream else {
                // Still attaching on its own queue (2026-11-09, fifth audit
                // #39): done when that comes back (finishAttach). Refused
                // here, a Guest House quitting mid-attach left the device held.
                if entry.state == .attaching {
                    entry.detachReply = reply
                    return
                }
                os_log("detach refused: %{public}@ is not held", log: log, type: .default, device.description)
                reply(false, "\(device.displayName) is not attached, so there is nothing to release.")
                return
            }
            self.beginRelease(entry, stream: stream, reply: reply)
        }
    }

    /// Tells a device's stream to stop. On `queue`.
    private func beginRelease(_ entry: DeviceEntry, stream: OpaquePointer,
                              reply: @escaping (Bool, String?) -> Void) {
        let device = entry.device
        os_log("releasing %{public}@", log: log, type: .default, device.description)
        entry.state = .releasing
        entry.detachReply = reply
        report(entry, detail: nil)
        // If the pump does not come back, answer anyway rather than
        // leave Guest House waiting forever. The device stays listed as
        // releasing so status stays honest.
        let timeout = DispatchWorkItem {
            if let pending = entry.detachReply {
                entry.detachReply = nil
                os_log("release of %{public}@ timed out", log: log, type: .error, device.description)
                pending(false, "The helper asked the stream for \(device.displayName) to stop, but it did not finish within 10 seconds.")
            }
            self.setAsideIfStuck(entry, after: 50)
        }
        entry.detachTimeout = timeout
        queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        avm_usb_stream_stop(stream)
    }

    /// Still not back a minute on (2026-10-26, code audit): the device would
    /// be refused as "already attached" until the helper restarted, and the
    /// helper never went idle. The entry is set aside (kept alive: the
    /// stream's callbacks still point at it), so the device can be attached
    /// again. Tests the stream, not the state (2026-11-09, fifth audit #19):
    /// an unplug's DEVICE_LOST overwrites `.releasing`, and a close hanging
    /// on a device just gone is the case this exists for.
    private func setAsideIfStuck(_ entry: DeviceEntry, after seconds: Double) {
        queue.asyncAfter(deadline: .now() + seconds) {
            guard self.entries[entry.device] === entry, entry.stream != nil else { return }
            os_log("release of %{public}@ never finished; setting it aside", log: log, type: .error, entry.device.description)
            self.entries[entry.device] = nil
            self.abandoned.append(entry)
            // Counted out (2026-10-28, fifth audit): otherwise the idle
            // exit, the one thing that frees a stuck device, never came.
            idle.devicesChanged(count: self.entries.count)
            self.watchConsoleWhileListed()
        }
    }

    // MARK: Only for the person at the screen

    private var consoleWatch: DispatchSourceTimer?

    /// While anything is listed (2026-11-09, fifth audit #38): attach checks
    /// only once, so after a fast user switch a USB device stayed streaming
    /// into the previous user's machine, where the person at the screen could
    /// neither use it nor detach it. The same 3 s watch a Bluetooth device
    /// and a keyboard for Windows have. On `queue`.
    private func watchConsoleWhileListed() {
        if entries.isEmpty {
            consoleWatch?.cancel()
            consoleWatch = nil
            return
        }
        guard consoleWatch == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.releaseDevicesOfUsersAway() }
        timer.resume()
        consoleWatch = timer
    }

    private func releaseDevicesOfUsersAway() {
        var consoleUID: uid_t = 0
        // No answer isn't another person at the screen: a braille display
        // must not leave a machine over one failed query.
        guard SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) != nil else { return }
        for entry in entries.values where entry.ownerUID != consoleUID && !entry.stoppedForConsole && entry.detachReply == nil {
            entry.stoppedForConsole = true
            entry.endDetail = "its user left the Mac's screen"
            os_log("%{public}@ going back to the Mac: its user left the screen", log: log, type: .default, entry.device.description)
            detach(entry.device, requester: nil) { _, _ in }
        }
    }
    // MARK: Release on disconnect (2026-10-25, code audit)

    /// Releases every device the given connection attached. Guest House's client
    /// treats dropping its connection as the release path for all its
    /// devices (USBHelperClient), but nothing here did it: after Guest House
    /// crashed, or Unregister, the helper kept streaming a braille display
    /// or keyboard into a VM nobody controlled, and the relaunched Guest House
    /// couldn't list it to detach. Each device goes through the same stop
    /// as Detach, so it returns to the Mac.
    func releaseAll(ownedBy connection: NSXPCConnection) {
        queue.async {
            let owned = self.entries.values.filter { $0.connection === connection }
            for entry in owned where entry.detachReply == nil {
                os_log("client gone; releasing %{public}@", log: log, type: .default, entry.device.description)
                self.detach(entry.device, requester: nil) { ok, detail in
                    if !ok {
                        os_log("release after disconnect of %{public}@ failed: %{public}@",
                               log: log, type: .error, entry.device.description, detail ?? "")
                    }
                }
            }
        }
    }

    /// Every device back to the Mac, then exit (2026-11-09, fifth audit #6):
    /// the helper used to die with its streams live, so libusb never gave a
    /// claimed device back. A stuck stream can't hold the exit up. Only with
    /// no stream left is libusb stopped (2026-10-29, sixth audit: Restart is
    /// the remedy for a stuck one, whose pump used libusb's context after
    /// libusb_exit freed it).
    func releaseEverythingThenExit(within seconds: Double) {
        queue.async {
            for entry in self.entries.values where entry.detachReply == nil {
                os_log("exiting; releasing %{public}@", log: log, type: .default, entry.device.description)
                self.detach(entry.device, requester: nil) { _, _ in }
            }
            let deadline = Date().addingTimeInterval(seconds)
            func look() {
                if self.noStreamsLeft { avm_usb_runtime_stop(); exit(0) }
                if Date() >= deadline { exit(0) }
                self.queue.asyncAfter(deadline: .now() + 0.1) { look() }
            }
            // After the detaches queued above have started.
            self.queue.asyncAfter(deadline: .now() + 0.1) { look() }
        }
    }

    // MARK: Status
    func status(requester: uid_t?, reply: @escaping ([AVMUSBDeviceStatus]) -> Void) {
        queue.async {
            let rows = self.entries.values.filter { requester == nil || $0.ownerUID == requester }.map {
                AVMUSBDeviceStatus(device: $0.device, state: $0.state, streamSocketPath: $0.socketPath)
            }
            reply(rows)
        }
    }
    // MARK: Events from the stream
    /// Called on `queue`. `event` is the C event; `step` and `detail`
    /// are already copied out of C memory.
    func handle(entry: DeviceEntry, event: UInt32, step: String, detail: String) {
        switch event {
        case AVM_USB_EVENT_LOG.rawValue:
            let type: OSLogType = (step == "error") ? .error : (step == "warning" ? .default : .info)
            os_log("%{public}@ usbredir %{public}@: %{public}@", log: log, type: type,
                   entry.device.displayName, step, detail)
        case AVM_USB_EVENT_ATTACHED.rawValue:
            // Not over a release already begun (2026-11-09, third audit of
            // the day #17): Guest House then said "is now in the machine" of a device
            // on its way back.
            guard entry.state != .releasing else {
                os_log("attached %{public}@ while releasing; ignored", log: log, type: .default, entry.device.description)
                return
            }
            os_log("attached %{public}@ (%{public}@)", log: log, type: .default, entry.device.description, detail)
            entry.state = .attached
            report(entry, detail: detail)
        case AVM_USB_EVENT_DEVICE_LOST.rawValue:
            os_log("%{public}@ unplugged while attached", log: log, type: .default, entry.device.description)
            entry.state = .yanked
            entry.endDetail = detail
            report(entry, detail: detail)
            setAsideIfStuck(entry, after: 60)      // no detach follows an unplug (fifth audit #19)
        case AVM_USB_EVENT_REJECTED.rawValue, AVM_USB_EVENT_ERROR.rawValue:
            os_log("%{public}@ stream ended at %{public}@: %{public}@", log: log, type: .error,
                   entry.device.description, step, detail)
            entry.state = .failed
            entry.endDetail = "\(step): \(detail)"
            report(entry, detail: entry.endDetail)
            setAsideIfStuck(entry, after: 60)
        case AVM_USB_EVENT_SOCKET_CLOSED.rawValue:
            os_log("%{public}@: %{public}@", log: log, type: .default, entry.device.description, detail)
            entry.endDetail = detail
            setAsideIfStuck(entry, after: 60)
        case AVM_USB_EVENT_RELEASED.rawValue:
            os_log("released %{public}@", log: log, type: .default, entry.device.description)
            entry.stream = nil
            entry.state = .released
            // Only its own entry (2026-10-28, code review): one set aside
            // could otherwise remove a newer attach of the same device.
            if entries[entry.device] === entry { entries[entry.device] = nil }
            abandoned.removeAll { $0 === entry }
            idle.devicesChanged(count: entries.count)
            watchConsoleWhileListed()
            report(entry, detail: entry.endDetail)
            entry.detachTimeout?.cancel()
            entry.detachTimeout = nil
            if let pending = entry.detachReply {
                entry.detachReply = nil
                pending(true, nil)
            }
        default:
            os_log("unknown stream event %{public}u for %{public}@", log: log, type: .error, event, entry.device.description)
        }
    }
    /// Tell the Guest House that asked for this device where it is now.
    private func report(_ entry: DeviceEntry, detail: String?) {
        guard let connection = entry.connection else {
            os_log("no client to report %{public}@ state %{public}d to", log: log, type: .default,
                   entry.device.description, entry.state.rawValue)
            return
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            os_log("stateChanged delivery failed: %{public}@", log: log, type: .error, error.localizedDescription)
        }
        guard let client = proxy as? AVMUSBHelperClientProtocol else {
            os_log("client proxy does not speak the client protocol", log: log, type: .error)
            return
        }
        client.stateChanged(entry.device, state: entry.state, detail: detail)
    }
}
let registry = DeviceRegistry()
/// The one C callback. Fires on the pump thread or the libusb event
/// thread. Copies the strings, then hands off. RELEASED is delivered
/// synchronously so that by the time the pump returns and frees the
/// stream, the registry has already forgotten the pointer.
private func streamEventCallback(_ context: UnsafeMutableRawPointer?,
                                 _ stream: OpaquePointer?,
                                 _ event: avm_usb_event,
                                 _ step: UnsafePointer<CChar>?,
                                 _ detail: UnsafePointer<CChar>?) {
    guard let context else { return }
    let entry = Unmanaged<DeviceEntry>.fromOpaque(context).takeUnretainedValue()
    let stepText = step.map { String(cString: $0) } ?? ""
    let detailText = detail.map { String(cString: $0) } ?? ""
    let code = event.rawValue
    if code == AVM_USB_EVENT_RELEASED.rawValue {
        registry.queue.sync {
            registry.handle(entry: entry, event: code, step: stepText, detail: detailText)
        }
    } else {
        registry.queue.async {
            registry.handle(entry: entry, event: code, step: stepText, detail: detailText)
        }
    }
}
// MARK: - The exported service
final class HelperService: NSObject, AVMUSBHelperProtocol {
    /// The connection this service object belongs to, so stateChanged
    /// callbacks can reach the right Guest House.
    weak var connection: NSXPCConnection?
    func attach(_ device: AVMUSBDeviceIdentity,
                streamSocketPath: String,
                peerPID: Int,
                reply: @escaping (Bool, String?, String?) -> Void) {
        os_log("attach requested for %{public}@ to %{public}@", log: log, type: .default,
               device.description, streamSocketPath)
        registry.attach(device, streamSocketPath: streamSocketPath, peerPID: peerPID, connection: connection, reply: reply)
    }
    func detach(_ device: AVMUSBDeviceIdentity,
                reply: @escaping (Bool, String?) -> Void) {
        os_log("detach requested for %{public}@", log: log, type: .default, device.description)
        guard let uid = connection?.effectiveUserIdentifier else {
            reply(false, "The helper could not tell which user asked.")
            return
        }
        registry.detach(device, requester: uid, reply: reply)
    }
    func status(reply: @escaping ([AVMUSBDeviceStatus]) -> Void) {
        os_log("status requested", log: log, type: .default)
        guard let uid = connection?.effectiveUserIdentifier else {
            reply([])
            return
        }
        registry.status(requester: uid, reply: reply)
    }
    func helperVersion(reply: @escaping (String) -> Void) {
        os_log("version requested", log: log, type: .default)
        reply(AVMUSBHelperNames.machServiceName + " " + helperBuildVersion)
    }

    func listKeyboards(reply: @escaping ([NSDictionary]) -> Void) {
        reply(KeyboardHold.shared.list())
    }

    func holdKeyboard(_ keyboardID: String, reply: @escaping (Bool, String?) -> Void) {
        KeyboardHold.shared.hold(keyboardID, owner: connection, reply: reply)
    }

    func releaseKeyboard(reply: @escaping () -> Void) {
        KeyboardHold.shared.release(owner: connection)
        reply()
    }

    func listBluetoothDevices(reply: @escaping ([NSDictionary]) -> Void) {
        reply(BluetoothHold.shared.list())
    }

    func holdBluetoothDevice(_ id: String, streamSocketPath: String, peerPID: Int, reply: @escaping (Bool, String?) -> Void) {
        BluetoothHold.shared.hold(id, streamSocketPath: streamSocketPath, peerPID: peerPID, owner: connection, reply: reply)
    }

    func releaseBluetoothDevice(_ id: String, reply: @escaping () -> Void) {
        BluetoothHold.shared.release(id, owner: connection)
        reply()
    }

    /// Restart USB Helper (2026-10-27). Guest House returns its devices to the Mac
    /// first; whatever is still held is let go when the process ends.
    /// libusb is stopped on the registry's queue, as for the idle exit.
    func restart(reply: @escaping () -> Void) {
        // Only the person at the screen (2026-10-28, security review): a
        // background user's Guest House must not drop the console user's devices.
        var consoleUID: uid_t = 0
        guard let uid = connection?.effectiveUserIdentifier,
              SCDynamicStoreCopyConsoleUser(nil, &consoleUID, nil) != nil, consoleUID == uid else {
            os_log("restart refused: the asking user isn't at the screen", log: log, type: .default)
            reply()
            return
        }
        if registry.queue.sync(execute: { registry.hasEntries(notOwnedBy: uid) }) {
            os_log("restart refused: another account has a device attached", log: log, type: .default)
            reply()
            return
        }
        os_log("restart requested by pid %{public}d; exiting so launchd starts a fresh helper",
               log: log, type: .default, connection?.processIdentifier ?? 0)
        reply()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            registry.releaseEverythingThenExit(within: 3)
        }
    }
}
// MARK: - Listener
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // The gate. macOS checks the caller's code signature against
        // this requirement before any message is delivered. A caller
        // that is not Guest House, signed by our team, never gets a reply.
        guard let clientRequirement else {
            os_log("helper has no Team ID in its own signature; refusing connection (pid %{public}d)",
                   log: log, type: .error, newConnection.processIdentifier)
            return false
        }
        if #available(macOS 13.0, *) {
            newConnection.setCodeSigningRequirement(clientRequirement)
        } else {
            os_log("macOS too old for setCodeSigningRequirement; refusing connection", log: log, type: .error)
            return false
        }
        let service = HelperService()
        service.connection = newConnection
        newConnection.exportedInterface = AVMUSBHelperInterfaces.helper()
        newConnection.exportedObject = service
        newConnection.remoteObjectInterface = AVMUSBHelperInterfaces.client()
        newConnection.invalidationHandler = {
            os_log("connection invalidated (pid %{public}d)", log: log, type: .default, newConnection.processIdentifier)
            registry.releaseAll(ownedBy: newConnection)
            KeyboardHold.shared.release(owner: newConnection)
            BluetoothHold.shared.releaseAll(owner: newConnection)
            idle.connectionClosed()
        }
        newConnection.interruptionHandler = {
            os_log("connection interrupted (pid %{public}d)", log: log, type: .default, newConnection.processIdentifier)
        }
        idle.connectionOpened()
        newConnection.resume()
        os_log("accepted connection from pid %{public}d", log: log, type: .default, newConnection.processIdentifier)
        return true
    }
}
// MARK: - Main
os_log("%{public}@ %{public}@ starting as uid %{public}d, requiring team %{public}@",
       log: log, type: .default,
       AVMUSBHelperNames.machServiceName, helperBuildVersion, getuid(),
       clientTeamID ?? "none (no Team ID in own signature; every connection will be refused)")
let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: AVMUSBHelperNames.machServiceName)
listener.delegate = delegate
listener.resume()
// Nobody may ever connect. Start the idle clock now so a spurious
// launch doesn't leave a root process sitting around.
idle.armIfIdleFromOutside()
// launchd's stop (unregistering, an update): devices go back first.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler { registry.releaseEverythingThenExit(within: 8) }
terminationSource.resume()
dispatchMain()
