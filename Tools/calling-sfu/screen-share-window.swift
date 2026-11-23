import AppKit
import QuartzCore
import ScreenCaptureKit
import SignalUI
@testable import SignalSafe

/// A real WindowServer surface whose two patterns can be verified after remote decoding.
@MainActor final class FixtureShareWindow {
    private final class Pattern: NSView {
        enum Phase { case initial, reversed, stopped }
        var phase = Phase.initial
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            let dark = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            let light = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1)
            (phase == .reversed ? dark : light).setFill()
            bounds.fill()
            (phase == .reversed ? light : dark).setFill()
            if phase == .stopped {
                NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height / 2).fill()
                return
            }
            let quadrant = NSSize(width: bounds.width / 2, height: bounds.height / 2)
            NSRect(origin: .zero, size: quadrant).fill()
            NSRect(origin: NSPoint(x: quadrant.width, y: quadrant.height), size: quadrant).fill()
        }
    }

    private let window: NSWindow
    private let pattern: Pattern

    init() {
        _ = NSApplication.shared
        let size = NSSize(width: 320, height: 180)
        window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 32, y: 32), size: size),
                          styleMask: .borderless, backing: .buffered, defer: false)
        pattern = Pattern(frame: NSRect(origin: .zero, size: size))
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.title = "Serein screen-share test pattern"
        window.contentView = pattern
        window.orderFrontRegardless()
        redraw()
    }

    func start(in session: SignalSession) async throws {
        guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String,
              !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CallTestPeerQA.Failure("The signed app is missing its screen recording purpose string")
        }
        let windowID = CGWindowID(window.windowNumber)
        // Supply the window the user would select in the system picker. ScreenCaptureKit's
        // current-process API scopes the fixture to its own windows without global permission.
        session.screenShareBackend.isGranted = { false }
        session.screenShareBackend.pickFilter = { _ in
            let content = try await SCShareableContent.currentProcess
            guard let selected = content.windows.first(where: { $0.windowID == windowID }) else {
                throw ScreenShareError.sourceGone
            }
            return SCContentFilter(desktopIndependentWindow: selected)
        }
        session.togglePresenting()
        try await CallTestPeerQA.wait("ScreenCaptureKit shared the chosen window without global recording access", seconds: 15) {
            session.screenCapture?.isCapturing == true && session.callControl?.isPresenting == true
        }
    }

    func advance() {
        pattern.phase = .reversed
        redraw()
    }

    func showStoppedPattern() {
        pattern.phase = .stopped
        redraw()
    }

    private func redraw() {
        pattern.needsDisplay = true
        window.display()
        CATransaction.flush()
    }

    func stop(in session: SignalSession) {
        session.stopPresenting()
        session.screenShareBackend = .system
        window.close()
    }
}
