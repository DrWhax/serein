// The live composer stops growing at four lines and scrolls: the text view inside its scroll
// view is as tall as the text, so the lines past the box can be scrolled to.

import AppKit
import SwiftUI
import Testing
@testable import SignalUI

@MainActor @Suite struct ComposerScrollTests {
    func scrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, s.documentView is PlaceholderTextView { return s }
        for sub in view.subviews { if let s = scrollView(in: sub) { return s } }
        return nil
    }

    @Test func textTallerThanTheBoxScrolls() throws {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n")
        let host = NSHostingView(rootView: CompositionInput(text: .constant(text)).frame(width: 400))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollView(in: host))
        let doc = try #require(scroll.documentView)
        doc.layoutSubtreeIfNeeded()
        (doc as? NSTextView)?.sizeToFit()
        // The box stops at about four lines; the text inside goes on.
        #expect(scroll.contentSize.height <= CGFloat(CompositionInput.liveMaxLines) * LegacyType.body1().lineHeight + 1)
        #expect(doc.frame.height > scroll.contentSize.height + 2 * LegacyType.body1().lineHeight)
    }

    /// Up to four lines the box grows with the text (as the composer lays it out: its own height).
    @Test func shortTextGrowsTheBox() throws {
        let host = NSHostingView(rootView: CompositionInput(text: .constant("one\ntwo")).frame(width: 400).fixedSize(horizontal: false, vertical: true))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(scrollView(in: host))
        let line = LegacyType.body1().lineHeight
        #expect(abs(scroll.contentSize.height - 2 * line) <= 2)
    }
}
