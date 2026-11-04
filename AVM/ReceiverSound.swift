// ReceiverSound.swift
// AVM — Accessible Virtual Machine
//
// A machine's sound for the AVM Receiver (2026-11-04): what the sound card
// sends (qemu-10.0.12-utm+hda-stream-to-socket.patch, 16-bit stereo at the
// guest's rate) into Opus, and back. Apple's converters do both ends. Built
// into the Mac app and the iOS app. Neither type is safe from two threads.

import AVFoundation
import Foundation

nonisolated enum ReceiverSoundFormat {
    static let rate = 48000.0
    /// 20 ms, the packet Apple's Opus encoder takes.
    static let framesPerPacket: AVAudioFrameCount = 960
    static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
    static let opus: AVAudioFormat = {
        var description = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)!
    }()
}

nonisolated final class ReceiverSoundEncoder {
    private let encoder: AVAudioConverter
    private var resampler: AVAudioConverter?
    private var resamplerRate = 0.0
    private var left: [Float] = []
    private var right: [Float] = []

    init?() {
        guard let encoder = AVAudioConverter(from: ReceiverSoundFormat.pcm, to: ReceiverSoundFormat.opus) else { return nil }
        encoder.bitRate = 64000
        self.encoder = encoder
    }

    /// Samples from the card; gives any Opus packets now complete.
    func add(samples: UnsafeRawBufferPointer, rate: Int) -> [Data] {
        let frames = samples.count / 4
        guard frames > 0, rate > 0,
              let input = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 2, interleaved: false)!,
                                           frameCapacity: AVAudioFrameCount(frames)) else { return [] }
        input.frameLength = AVAudioFrameCount(frames)
        let values = samples.bindMemory(to: Int16.self)
        for i in 0..<frames {
            input.floatChannelData![0][i] = Float(Int16(littleEndian: values[i * 2])) / 32768
            input.floatChannelData![1][i] = Float(Int16(littleEndian: values[i * 2 + 1])) / 32768
        }
        append(rate == Int(ReceiverSoundFormat.rate) ? input : resample(input, rate: Double(rate)))
        var packets: [Data] = []
        let size = Int(ReceiverSoundFormat.framesPerPacket)
        while left.count >= size {
            if let packet = encode(size) { packets.append(packet) }
            left.removeFirst(size)
            right.removeFirst(size)
        }
        return packets
    }

    private func append(_ buffer: AVAudioPCMBuffer?) {
        guard let buffer, let channels = buffer.floatChannelData else { return }
        left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
        right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: Int(buffer.frameLength)))
    }

    /// Most guests run their card at 48 kHz or 44.1 kHz, and it can change
    /// while a machine runs; Opus here takes only 48 kHz.
    private func resample(_ input: AVAudioPCMBuffer, rate: Double) -> AVAudioPCMBuffer? {
        if resampler == nil || resamplerRate != rate {
            resampler = AVAudioConverter(from: input.format, to: ReceiverSoundFormat.pcm)
            resamplerRate = rate
        }
        guard let resampler else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ReceiverSoundFormat.rate / rate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: ReceiverSoundFormat.pcm, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        resampler.convert(to: output, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }

    private func encode(_ size: Int) -> Data? {
        guard let input = AVAudioPCMBuffer(pcmFormat: ReceiverSoundFormat.pcm, frameCapacity: AVAudioFrameCount(size)) else { return nil }
        input.frameLength = AVAudioFrameCount(size)
        left.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: size) }
        right.withUnsafeBufferPointer { input.floatChannelData![1].update(from: $0.baseAddress!, count: size) }
        let output = AVAudioCompressedBuffer(format: ReceiverSoundFormat.opus, packetCapacity: 1, maximumPacketSize: 1500)
        var given = false
        var error: NSError?
        let status = encoder.convert(to: output, error: &error) { _, inputStatus in
            if given { inputStatus.pointee = .noDataNow; return nil }
            given = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.packetCount > 0, output.byteLength > 0 else { return nil }
        return Data(bytes: output.data, count: Int(output.byteLength))
    }
}

nonisolated final class ReceiverSoundDecoder {
    private let decoder: AVAudioConverter

    init?() {
        guard let decoder = AVAudioConverter(from: ReceiverSoundFormat.opus, to: ReceiverSoundFormat.pcm) else { return nil }
        self.decoder = decoder
    }

    func decode(_ packet: Data) -> AVAudioPCMBuffer? {
        guard !packet.isEmpty, packet.count <= 1500,
              let output = AVAudioPCMBuffer(pcmFormat: ReceiverSoundFormat.pcm, frameCapacity: ReceiverSoundFormat.framesPerPacket * 3) else { return nil }
        let input = AVAudioCompressedBuffer(format: ReceiverSoundFormat.opus, packetCapacity: 1, maximumPacketSize: 1500)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        var given = false
        var error: NSError?
        let status = decoder.convert(to: output, error: &error) { _, inputStatus in
            if given { inputStatus.pointee = .noDataNow; return nil }
            given = true
            inputStatus.pointee = .haveData
            return input
        }
        return status != .error && error == nil && output.frameLength > 0 ? output : nil
    }
}
