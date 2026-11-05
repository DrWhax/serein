// Port of ts/components/preferences/PreferencesList.dom.tsx: an AxoList with an optional
// label and footer description around an item group.

import SwiftUI

public struct PreferencesList<Content: View>: View {
    let accessibilityLabel: String?
    let label: String?
    let footerDescription: String?
    let content: Content

    public init(accessibilityLabel: String? = nil, label: String? = nil, footerDescription: String? = nil, @ViewBuilder content: () -> Content) {
        self.accessibilityLabel = accessibilityLabel
        self.label = label
        self.footerDescription = footerDescription
        self.content = content()
    }

    public var body: some View {
        AxoList.Root(accessibilityLabel: accessibilityLabel) {
            if let label { AxoList.Header { AxoList.Label(label) } }
            AxoList.Body { AxoItem.Group { content } }
            if let footerDescription { AxoList.Footer { AxoList.FooterDescription(footerDescription) } }
        }
    }
}
