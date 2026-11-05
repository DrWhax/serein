// Port of ts/axo/items/AxoFieldList.dom.tsx + AxoFieldList.css: a list of fields in the
// `listitem` field variant, separated by hairlines.

import SwiftUI

public enum AxoFieldList {
    /// `<AxoFieldList.Root>`
    public struct Root<Content: View>: View {
        let title: String?
        let description: String?
        let footerDescription: String?
        /// A footer description with inline elements (a link or button run); `onFooterAction` gets its action.
        var footerRuns: [CSSTextRun]?
        var onFooterAction: ((String) -> Void)?
        let content: Content

        public init(title: String? = nil, description: String? = nil, footerDescription: String? = nil, @ViewBuilder content: () -> Content) {
            self.title = title
            self.description = description
            self.footerDescription = footerDescription
            self.content = content()
        }

        public init(title: String? = nil, footerRuns: [CSSTextRun], onFooterAction: @escaping (String) -> Void, @ViewBuilder content: () -> Content) {
            self.init(title: title, content: content)
            self.footerRuns = footerRuns
            self.onFooterAction = onFooterAction
        }

        public var body: some View {
            AxoList.Root {
                if let title {
                    AxoList.Header {
                        AxoList.Label(title)
                        // We probably don't ever want to show a description without a title
                        if let description { AxoList.Description(description) }
                    }
                }
                AxoList.Body { Items { content } }
                if let footerRuns {
                    AxoList.Footer {
                        CSSText(runs: footerRuns, style: CSSTextStyle(AxoType.bodySmall), color: .labelSecondary, onTap: onFooterAction)
                    }
                } else if let footerDescription {
                    AxoList.Footer { AxoList.FooterDescription(footerDescription) }
                }
            }
        }
    }

    /// `.axo-field-list-item + .axo-field-list-item::before`: a `mx-2 my-[2.5px]` block with a
    /// 1px `border-b-primary`, between consecutive items.
    struct Items<Content: View>: View {
        @ViewBuilder var content: Content
        var body: some View {
            Group(subviews: content) { subviews in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(subviews.enumerated()), id: \.offset) { i, item in
                        if i > 0 {
                            Rectangle().fill(AxoColor.borderPrimary).frame(height: 1)
                                .padding(.horizontal, 8).padding(.vertical, 2.5)
                        }
                        item
                    }
                }
            }
        }
    }

    /// `<AxoFieldList.Item>`: forces the `listitem` field variant.
    public struct Item<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View {
            AxoBaseField.VariantOverride(variant: .listitem) { content }
        }
    }
}
