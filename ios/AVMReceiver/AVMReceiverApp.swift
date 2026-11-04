// AVMReceiverApp.swift
// AVM Receiver
//
// An accessible receiver for virtual machines running in AVM on a Mac
// (2026-11-04): VoiceOver first. The machine stays on the Mac; this lists them,
// starts and stops them, and opens one: its sound here, a keyboard's keys there,
// and its screen. Every state change that matters is also announced, because
// someone not looking at the screen has no other way to learn it.

import Network
import SwiftUI

@main
struct AVMReceiverApp: App {
    @StateObject private var link = ReceiverLink()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(link)
                .onChange(of: phase) { _, now in
                    if now == .active { link.becameActive() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var link: ReceiverLink

    var body: some View {
        NavigationStack {
            if link.pairing == nil {
                PairView()
            } else {
                MachinesView()
            }
        }
    }
}

// MARK: - Pairing

struct PairView: View {
    @EnvironmentObject private var link: ReceiverLink
    @State private var code = ""
    @State private var address = ""
    @State private var chosen: ReceiverFoundMac?
    @State private var problem: String?
    @State private var working = false

    private var canPair: Bool {
        !working && (chosen != nil || !address.trimmingCharacters(in: .whitespaces).isEmpty) && !code.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Text("On your Mac, open AVM's Settings, choose iPhone Receiver, turn it on, and choose Pair a Device.")
            }
            Section("Your Mac") {
                if link.foundMacs.isEmpty {
                    Text("Looking for a Mac showing a pairing code on this network.")
                }
                ForEach(link.foundMacs) { mac in
                    Button {
                        chosen = mac
                        address = ""
                    } label: {
                        HStack {
                            Text(mac.name)
                            Spacer()
                            if chosen == mac { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                    }
                    .accessibilityAddTraits(chosen == mac ? .isSelected : [])
                }
                TextField("Or its address", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: address) { _, now in if !now.isEmpty { chosen = nil } }
                    .accessibilityHint("For example a Tailscale address, when you're away from home.")
            }
            Section("Pairing Code") {
                TextField("Code from your Mac", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
            }
            if let problem {
                Section { Text(problem) }
            }
            Section {
                Button(working ? "Pairing…" : "Pair") { pair() }
                    .disabled(!canPair)
            }
        }
        .navigationTitle("Pair with Your Mac")
        .onAppear { link.startLookingForMacs() }
    }

    private func pair() {
        working = true
        problem = nil
        let typed = address.trimmingCharacters(in: .whitespaces)
        let endpoint: NWEndpoint = chosen?.endpoint
            ?? .hostPort(host: NWEndpoint.Host(typed), port: NWEndpoint.Port(rawValue: ReceiverWire.pairingPort)!)
        Task {
            let result = await link.pair(endpoint: endpoint, address: typed.isEmpty ? nil : typed, serviceName: chosen?.name, code: code)
            working = false
            problem = result
            if let result { UIAccessibility.post(notification: .announcement, argument: result) }
        }
    }
}

// MARK: - The list

struct MachinesView: View {
    @EnvironmentObject private var link: ReceiverLink
    @State private var showsSettings = false

    var body: some View {
        List {
            statusSection
            if !link.machines.isEmpty {
                Section("Machines") {
                    ForEach(link.machines) { machine in
                        MachineRow(machine: machine)
                    }
                }
            } else if link.status == .connected {
                Section { Text("No virtual machines are set up on this Mac.") }
            }
        }
        .navigationTitle(link.pairing?.macName ?? "AVM")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Connection") { showsSettings = true }
            }
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack { ConnectionView() }
        }
        .navigationDestination(isPresented: Binding(
            get: { link.openMachineID != nil },
            set: { if !$0 { Task { await link.closeMachine() } } })) {
            MachineView()
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch link.status {
        case .connecting:
            Section { Text("Connecting to your Mac.") }
        case .offline(let text):
            Section {
                Text(text)
                Button("Try Again") { link.connect() }
            }
        default:
            EmptyView()
        }
    }
}

struct MachineRow: View {
    @EnvironmentObject private var link: ReceiverLink
    let machine: ReceiverMachine

    private var canSaveOrStop: Bool { machine.isRunning || machine.state == "paused" }
    private var canStart: Bool { machine.state == "shut down" || machine.state == "saved" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading) {
                Text(machine.name).font(.headline)
                Text("\(machine.kind), \(machine.state)").font(.subheadline)
            }
            .accessibilityElement(children: .combine)
            HStack {
                if machine.isRunning, !machine.isMac {
                    Button("Open") { Task { await link.open(machine) } }
                        .accessibilityLabel("Open \(machine.name)")
                }
                if canStart {
                    Button("Start") { Task { await link.command("start", machine) } }
                        .accessibilityLabel("Start \(machine.name)")
                }
                if canSaveOrStop {
                    Menu("More") {
                        Button("Save") { Task { await link.command("save", machine) } }
                        Button("Shut Down") { Task { await link.command("stop", machine) } }
                        Button("Turn Off", role: .destructive) { Task { await link.command("force-stop", machine) } }
                    }
                    .accessibilityLabel("More for \(machine.name)")
                }
            }
            .buttonStyle(.bordered)
            if machine.isMac, machine.isRunning {
                Text("macOS machines can be started and stopped from here, but not opened yet.").font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - One machine

struct MachineView: View {
    @EnvironmentObject private var link: ReceiverLink
    @State private var typing = false
    @State private var text = ""
    @State private var confirmsDelete = false

    private var name: String { link.openMachine?.name ?? "Machine" }

    var body: some View {
        ZStack(alignment: .top) {
            // The keys' first responder, behind everything. It's an element so
            // VoiceOver can say what it's for, and it has the whole page's space.
            KeyCaptureView(machineName: name) { usage, down in
                link.send(key: usage, down: down)
            }
            ScrollView {
                VStack(spacing: 16) {
                    screen
                    Toggle("Show Screen", isOn: Binding(
                        get: { link.showsPicture },
                        set: { value in Task { await link.setShowsPicture(value) } }))
                    Button("Read Screen") { Task { await link.readScreen() } }
                        .accessibilityHint("Says the text on the machine's screen.")
                    Button("Type Text…") { typing = true }
                    Button("Send Control-Alt-Delete") { Task { await link.controlAltDelete() } }
                    Button("Close Machine", role: .destructive) { Task { await link.closeMachine() } }
                        .accessibilityHint("The machine keeps running on your Mac, and its sound goes back there.")
                }
                .buttonStyle(.bordered)
                .padding()
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Type into \(name)", isPresented: $typing) {
            TextField("Text", text: $text)
            Button("Type") {
                let toType = text
                text = ""
                Task { await link.type(toType) }
            }
            Button("Cancel", role: .cancel) { text = "" }
        }
    }

    @ViewBuilder private var screen: some View {
        if link.showsPicture {
            if let picture = link.picture {
                Image(uiImage: picture)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("\(name)'s screen")
                    .accessibilityHint("A picture of the machine's screen. Use Read Screen to hear its text.")
            } else {
                Text("Waiting for the screen.")
            }
        }
    }
}

// MARK: - Connection

struct ConnectionView: View {
    @EnvironmentObject private var link: ReceiverLink
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var confirmsForget = false

    var body: some View {
        Form {
            Section("Away from Home") {
                TextField("Your Mac's address", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("With Tailscale on this device and your Mac, use the address AVM shows under iPhone Receiver. At home, the Mac is found without it. Your Mac has to stay on and awake.")
                    .font(.footnote)
                Button("Save Address") {
                    link.setAddress(address)
                    dismiss()
                }
            }
            Section {
                Button("Forget This Mac", role: .destructive) { confirmsForget = true }
            }
        }
        .navigationTitle("Connection")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        }
        .onAppear { address = link.pairing?.address ?? "" }
        .confirmationDialog("Forget \(link.pairing?.macName ?? "this Mac")? You'd need a new pairing code to connect again.", isPresented: $confirmsForget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                link.unpair()
                dismiss()
            }
        }
    }
}
