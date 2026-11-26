import Foundation
#if canImport(AppKit)
import AppKit
#else
@_spi(Qt) import SwiftUI
#endif

@MainActor public enum DesktopDisplay {
    public static var screenSize: CGSize? {
        #if canImport(AppKit)
        NSScreen.main?.frame.size
        #else
        QtDesktop.primaryScreenSize
        #endif
    }

    public static var isShiftPressed: Bool {
        #if canImport(AppKit)
        NSEvent.modifierFlags.contains(.shift)
        #else
        QtDesktop.keyboardModifiers.contains(.shift)
        #endif
    }

    public static func copy(_ string: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        QtDesktop.copy(string)
        #endif
    }
}
