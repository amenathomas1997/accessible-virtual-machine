// SoundOutputDevices.swift
// Guest House — accessible virtual machines
//
// The Mac's sound outputs, for a machine's Sound Output setting
// (2026-10-30, the user's request): a machine can play through its own
// device, headphones say, while VoiceOver stays on the Mac's default
// output, so the two screen readers don't talk over each other in the same
// ear. QEMU takes the device by its unique ID (out.dev, Guest House's coreaudio
// patch), which stays the same across restarts and reconnections.

import AudioToolbox
import CoreAudio
import Foundation

enum SoundOutputDevices {
    struct Device: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    /// Every device with output channels, in the order Core Audio lists them.
    static func list() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard outputChannels(id) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Device(uid: uid, name: name)
        }
    }

    private static func outputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let text = value?.takeRetainedValue() else { return nil }
        return text as String
    }

    /// The device's ID as a QEMU option value: commas doubled.
    static func qemuValue(_ uid: String) -> String {
        uid.replacingOccurrences(of: ",", with: ",,")
    }
}

// MARK: - Whether the Mac's sound answers

/// QEMU opens its sound output while it builds the machine, on its main
/// thread, before it answers Guest House at all. On 2026-11-10 that call into Core
/// Audio never came back (a sample of the stuck QEMU: coreaudio_init_out,
/// AudioDeviceCreateIOProcID, waiting on coreaudiod), and every Start
/// ended minutes later with "Timed out waiting for a QMP response" (audit
/// of 2026-11-10 #43). The cause, found the next day: the Mac's default
/// output was a wireless headset whose USB receiver stays connected, and
/// so stays the output, while the headset itself is off. Opening it then
/// blocks; the built-in speakers opened in the same minute. The screen's
/// lock, first suspected, has nothing to do with it. So before QEMU is
/// launched Guest House opens the same output itself, off to one side, and a
/// Start that would hang is ended in seconds, naming the device.
extension SoundOutputDevices {
    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var probeRunning = false

    /// Opens the output QEMU will open: the device with this unique ID, or
    /// the default output when there's none or it isn't connected.
    private static func openOutputOnce(uid: String?) {
        // For the test of this very check: a sound system that doesn't answer.
        if CommandLine.arguments.contains("--test-sound-stall") { Thread.sleep(forTimeInterval: 120) }
        let device = uid.flatMap(deviceID(forUID:))
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                    componentSubType: device == nil ? kAudioUnitSubType_DefaultOutput : kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { return }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(component, &unit) == noErr, let unit else { return }
        if var device {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        if AudioUnitInitialize(unit) == noErr { AudioUnitUninitialize(unit) }
        AudioComponentInstanceDispose(unit)
    }

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { outputChannels($0) > 0 && string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// The name of the output QEMU will open, when Core Audio gives it at
    /// once: the chosen device if it's connected, or the default output.
    static func outputName(uid: String?) async -> String? {
        final class Box: @unchecked Sendable { var name: String? }
        let box = Box()
        let came = await Stalls.finishes(within: 2) {
            if let uid, let device = deviceID(forUID: uid) { box.name = string(device, kAudioObjectPropertyName); return }
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var device = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return }
            box.name = string(device, kAudioObjectPropertyName)
        }
        return came ? box.name : nil
    }

    /// True when the Mac's sound output opened within `seconds`. One look at
    /// a time: while an earlier one is still stuck, no more threads are
    /// spent on it, and the answer is whether that one has come back.
    static func answers(within seconds: Double, uid: String?) async -> Bool {
        probeLock.lock()
        let earlierStuck = probeRunning
        if !earlierStuck { probeRunning = true }
        probeLock.unlock()
        if earlierStuck {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                probeLock.lock(); let still = probeRunning; probeLock.unlock()
                if !still { return await answers(within: max(1, deadline.timeIntervalSinceNow), uid: uid) }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }
        return await Stalls.finishes(within: seconds) {
            openOutputOnce(uid: uid)
            probeLock.lock(); probeRunning = false; probeLock.unlock()
        }
    }
}

