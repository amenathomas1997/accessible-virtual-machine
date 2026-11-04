// ReceiverWire.swift
// AVM — Accessible Virtual Machine
//
// What AVM on the Mac and the AVM Receiver app on an iPhone or iPad say to
// each other (2026-11-04). This one file is built into both.
//
// One TCP connection, inside TLS, carrying frames: a kind byte, a 4-byte
// big-endian length, the payload. Messages are JSON; sound is one Opus packet
// a frame; a picture is one JPEG; a key is a HID usage and whether it's down.
//
// THE KEYS: TLS with a pre-shared key, ECDHE_PSK with AES-GCM. Measured on this
// Mac the same day: the wrong key and an unknown device are both refused, and
// Network.framework would not do TLS 1.3 with a pre-shared key at all. ECDHE
// keeps recorded traffic safe even if a key is stolen later, which plain PSK
// wouldn't. Pairing uses a one-time code, stretched with PBKDF2, on its own
// port, open for two minutes; the Mac then gives that device its own 32-byte
// key, and only those keys open the main port.

import CommonCrypto
import CryptoKit
import Foundation
import Network

nonisolated enum ReceiverWire {
    static let port: UInt16 = 49661
    static let pairingPort: UInt16 = 49662
    static let bonjourType = "_avm-receiver._tcp"
    /// Only while pairing is open, so a device can find a Mac it has no key for yet.
    static let pairingBonjourType = "_avm-pairing._tcp"
    static let pairingIdentity = "avm-pairing"
    /// TLS_ECDHE_PSK_WITH_AES_128_GCM_SHA256 (RFC 8442).
    private static let cipherSuite: UInt16 = 0xD001
    /// More than any picture or message should ever be.
    static let largestFrame = 8 << 20

    enum Kind: UInt8 {
        case message = 1, sound = 2, picture = 3, key = 4
    }

    static func frame(_ kind: Kind, _ payload: Data) -> Data {
        var data = Data(capacity: payload.count + 5)
        data.append(kind.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func message(_ object: [String: Any]) -> Data {
        frame(.message, (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
    }

    static func keyPayload(usage: Int, down: Bool) -> Data {
        Data([UInt8((usage >> 8) & 0xFF), UInt8(usage & 0xFF), down ? 1 : 0])
    }

    static func readKey(_ payload: Data) -> (usage: Int, down: Bool)? {
        guard payload.count == 3 else { return nil }
        let bytes = [UInt8](payload)
        return (Int(bytes[0]) << 8 | Int(bytes[1]), bytes[2] != 0)
    }

    /// Takes bytes as they come from the network and gives whole frames.
    struct FrameReader {
        private var buffer = Data()
        /// True once something impossible came: the connection should end.
        private(set) var failed = false

        mutating func add(_ data: Data) -> [(kind: Kind, payload: Data)] {
            buffer.append(data)
            var frames: [(Kind, Data)] = []
            while !failed, buffer.count >= 5 {
                let start = buffer.startIndex
                let length = buffer[(start + 1)..<(start + 5)].reduce(0) { $0 << 8 | Int($1) }
                guard length <= ReceiverWire.largestFrame, let kind = Kind(rawValue: buffer[start]) else {
                    failed = true
                    break
                }
                guard buffer.count >= 5 + length else { break }
                frames.append((kind, Data(buffer[(start + 5)..<(start + 5 + length)])))
                buffer = Data(buffer[(start + 5 + length)...])
            }
            return frames
        }
    }

    // MARK: Pairing codes

    /// No 0, O, 1, I, L or U: nothing to mix up when it's read out or typed.
    private static let codeLetters = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Three groups of four, about 58 bits, from the system's random source.
    static func makeCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let letters = (0..<12).map { _ in codeLetters.randomElement(using: &generator)! }
        return stride(from: 0, to: 12, by: 4).map { String(letters[$0..<($0 + 4)]) }.joined(separator: "-")
    }

    /// As typed: any case, with or without spaces and dashes.
    static func normalized(code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The pre-shared key for pairing with a code.
    static func pairingKey(code: String) -> Data {
        let password = Array(normalized(code: code).utf8)
        let salt = Array("AVM Receiver pairing 2026-11-04".utf8)
        var key = [UInt8](repeating: 0, count: 32)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 password.map { Int8(bitPattern: $0) }, password.count,
                                 salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000,
                                 &key, key.count)
        return Data(key)
    }

    static func newDeviceKey() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
    }

    /// Says which device this is, once inside TLS: any paired device's key
    /// opens the port, and this ties the connection to the name it gives.
    static func helloToken(key: Data) -> String {
        SHA256.hash(data: Data("AVM Receiver hello".utf8) + key).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: TLS

    static func parameters(keys: [(identity: String, key: Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (identity, key) in keys {
            sec_protocol_options_add_pre_shared_key(options, dispatchData(key), dispatchData(Data(identity.utf8)))
        }
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: cipherSuite)!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        // Speech can't wait for Nagle.
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.serviceClass = .interactiveVoice
        return parameters
    }

    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) as __DispatchData }
    }
}
