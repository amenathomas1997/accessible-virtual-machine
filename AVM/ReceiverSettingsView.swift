// ReceiverSettingsView.swift
// AVM — Accessible Virtual Machine
//
// AVM's Settings, iPhone Receiver (2026-11-04): turn it on, pair a device with
// a code, see and remove paired devices, and where a device can reach this
// Mac. See ReceiverServer.swift.

import AppKit
import SwiftUI

struct ReceiverSettingsView: View {
    @ObservedObject private var server = ReceiverServer.shared
    @AppStorage(ReceiverServer.enabledKey) private var enabled = false

    private var macName: String { Host.current().localizedName ?? "this Mac" }
    private var localName: String { (Host.current().names.first { $0.hasSuffix(".local") }) ?? macName }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Let paired iPhones and iPads use this Mac's machines", isOn: Binding(
                get: { enabled },
                set: { enabled = $0; server.setEnabled($0) }))
            Text("With the AVM Receiver app, a paired device lists your machines, starts and stops them, and opens one: you hear it, type on a Bluetooth keyboard, and see its screen. While a device has a machine open, its sound goes to that device and not to this Mac.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = server.problem {
                Text(problem).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if enabled {
                pairing
                pairedDevices
                reaching
            }
        }
    }

    @ViewBuilder private var pairing: some View {
        Text("Pair a Device").font(.headline).accessibilityAddTraits(.isHeader)
        if let code = server.pairingCode {
            Text("In AVM Receiver on your device, enter this code. It works once, for two minutes.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            // Not selectable, Copy Code is right below (2026-11-05): in 0.4.33
            // .textSelection with .accessibilityLabel on one Text sent SwiftUI's
            // label lookup round in circles when VoiceOver read it, and AVM
            // crashed as soon as the code appeared.
            Text(code)
                .font(.system(.title2, design: .monospaced))
                .accessibilityLabel("Pairing code: \(code.map { String($0) }.joined(separator: " "))")
            HStack {
                Button("Copy Code") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                }
                Button("Stop Pairing") { server.endPairing() }
            }
        } else {
            Button("Pair a Device…") {
                if let code = server.beginPairing() {
                    Announcer.shared.announce("Pairing code: \(code.map { String($0) }.joined(separator: " "))", tone: .info)
                }
            }
        }
    }

    @ViewBuilder private var pairedDevices: some View {
        Text("Paired Devices").font(.headline).accessibilityAddTraits(.isHeader)
        if server.devices.isEmpty {
            Text("None yet.").font(.callout)
        }
        ForEach(server.devices) { device in
            HStack {
                Text(device.name)
                Spacer()
                Button("Remove") { server.forget(device) }
                    .accessibilityLabel("Remove \(device.name)")
            }
        }
    }

    @ViewBuilder private var reaching: some View {
        Text("Reaching This Mac").font(.headline).accessibilityAddTraits(.isHeader)
        Text("On the same network, AVM Receiver finds \(macName) by itself, or you can enter \(localName).")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        if let tailscale = ReceiverServer.tailscaleAddress() {
            Text("Away from home, enter \(tailscale) in AVM Receiver, with Tailscale on in both places.")
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Away from home, install Tailscale on this Mac and on your device and sign in to the same account on both; its address for this Mac then shows here. The Mac has to stay on and awake while you're out.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
