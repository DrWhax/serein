#if canImport(AppKit)
import AppKit
import SwiftUI

/// A within-window NSVisualEffectView: blurs whatever the window draws behind the panel. The
/// 90% material-dialog fill on top supplies the colour.
struct WithinWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .withinWindow
        v.material = .hudWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif
