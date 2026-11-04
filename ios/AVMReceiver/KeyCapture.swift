// KeyCapture.swift
// AVM Receiver
//
// A hardware keyboard's keys, to the open machine (2026-11-04): every press and
// release as the HID usage UIKit reports, which is what AVM on the Mac already
// takes from a keyboard for Windows. Keys still down go up when this view stops
// being first responder or the app goes to the background, so none sticks.

import SwiftUI
import UIKit

struct KeyCaptureView: UIViewRepresentable {
    let machineName: String
    let send: (Int, Bool) -> Void

    func makeUIView(context: Context) -> KeyCaptureUIView {
        let view = KeyCaptureUIView()
        view.send = send
        view.setName(machineName)
        return view
    }

    func updateUIView(_ view: KeyCaptureUIView, context: Context) {
        view.send = send
        view.setName(machineName)
    }
}

final class KeyCaptureUIView: UIView {
    var send: ((Int, Bool) -> Void)?
    private var held = Set<Int>()
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = [.allowsDirectInteraction]
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseAll() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.becomeFirstResponder() }
        })
    }

    required init?(coder: NSCoder) { fatalError("not from a storyboard") }

    func setName(_ name: String) {
        accessibilityLabel = "Keyboard for \(name)"
        accessibilityHint = "Keys on a connected keyboard type into the machine."
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { _ = becomeFirstResponder() } else { releaseAll() }
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    private func releaseAll() {
        for usage in held { send?(usage, false) }
        held.removeAll()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var others = Set<UIPress>()
        for press in presses {
            if let usage = press.key?.keyCode.rawValue {
                held.insert(usage)
                send?(usage, true)
            } else {
                others.insert(press)
            }
        }
        if !others.isEmpty { super.pressesBegan(others, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var others = Set<UIPress>()
        for press in presses {
            if let usage = press.key?.keyCode.rawValue {
                held.remove(usage)
                send?(usage, false)
            } else {
                others.insert(press)
            }
        }
        if !others.isEmpty { super.pressesEnded(others, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}
