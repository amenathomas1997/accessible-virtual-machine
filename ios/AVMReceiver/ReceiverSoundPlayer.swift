// ReceiverSoundPlayer.swift
// AVM Receiver
//
// A machine's sound on this device (2026-11-04). Speech has to keep up with
// typing, so little is held back: playback starts with 60 ms in hand, and past
// 240 ms of backlog new sound is dropped to catch up. Sound keeps playing with
// the screen locked (the audio background mode). VoiceOver stays separate:
// iOS plays it over this.
//
// THE LOCK IS NEVER HELD ACROSS AN AUDIO ENGINE CALL (2026-11-04, the UI test
// froze on Close): stopping a player waits for its buffers' completion
// handlers, which need the lock. And the engine is only ever touched on its own
// queue, because starting or stopping it can wait on the audio system, and the
// main thread is what VoiceOver talks to.

import AVFoundation
import Foundation

final class ReceiverSoundPlayer: @unchecked Sendable {
    private let lock = NSLock()
    private let control = DispatchQueue(label: "AVM Receiver sound", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    // Guarded by the lock:
    private var decoder: ReceiverSoundDecoder?
    private var running = false
    private var engineReady = false
    private var queued = 0
    private var primed = false
    private var waiting: [AVAudioPCMBuffer] = []
    private var generation = 0

    private static let startWith = 3     // packets of 20 ms
    private static let mostQueued = 12
    private var observers: [NSObjectProtocol] = []

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: ReceiverSoundFormat.pcm)
        let center = NotificationCenter.default
        // Headphones, AirPods or a route change stop the engine.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in self?.restart() })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restart()
        })
    }

    func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        decoder = ReceiverSoundDecoder()
        resetLocked()
        lock.unlock()
        control.async { [self] in startEngine() }
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        decoder = nil
        resetLocked()
        lock.unlock()
        control.async { [self] in
            player.stop()
            engine.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func restart() {
        lock.lock()
        guard running else { lock.unlock(); return }
        resetLocked()
        lock.unlock()
        control.async { [self] in
            player.stop()
            startEngine()
        }
    }

    private func resetLocked() {
        generation += 1
        engineReady = false
        queued = 0
        primed = false
        waiting = []
    }

    /// On the control queue.
    private func startEngine() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            if !engine.isRunning { try engine.start() }
            lock.lock()
            engineReady = running
            lock.unlock()
        } catch {
            NSLog("AVM Receiver: sound didn't start: \(error)")
        }
    }

    /// From the network's queue.
    func take(packet: Data) {
        lock.lock()
        guard running, engineReady, queued < Self.mostQueued, let buffer = decoder?.decode(packet) else { lock.unlock(); return }
        var ready: [AVAudioPCMBuffer] = []
        if primed {
            ready = [buffer]
        } else {
            waiting.append(buffer)
            if waiting.count >= Self.startWith {
                primed = true
                ready = waiting
                waiting = []
            }
        }
        queued += ready.count
        let thisGeneration = generation
        let startPlaying = ready.count > 1
        lock.unlock()
        guard !ready.isEmpty else { return }
        control.async { [self] in
            for piece in ready {
                player.scheduleBuffer(piece) { [weak self] in self?.finishedOne(thisGeneration) }
            }
            if startPlaying, engine.isRunning { player.play() }
        }
    }

    private func finishedOne(_ fromGeneration: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard fromGeneration == generation else { return }
        queued = max(0, queued - 1)
        // Ran dry: hold back a little again before carrying on.
        if queued == 0, running { primed = false }
    }
}
