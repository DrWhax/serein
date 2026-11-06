// A vertical ScrollView that, in static rendering (snapshots: ImageRenderer draws no
// ScrollView content), lays its content out top-aligned and clipped, as scrolled to the top.

import SwiftUI

public struct StaticAwareScrollView<Content: View>: View {
    let content: Content
    @Environment(\.axoStaticRendering) var staticRendering
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        if staticRendering {
            Color.clear.overlay(alignment: .top) { content.fixedSize(horizontal: false, vertical: true) }.clipped()
        } else {
            ScrollView(.vertical) { content }
        }
    }
}
