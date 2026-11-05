// Port of ts/components/conversation/media-gallery/EmptyState.dom.tsx: the centred title
// (type-title-small) and description (type-body-medium) of an empty gallery tab.

import SignalI18n
import SwiftUI

/// The gallery's tabs.
public enum MediaGalleryTab: String, Sendable, CaseIterable { case media, audio, links, documents }

public struct MediaGalleryEmptyState: View {
    let tab: MediaGalleryTab
    @Environment(\.i18n) var i18n
    public init(tab: MediaGalleryTab) { self.tab = tab }

    var strings: (String, String) {
        switch tab {
        case .media: ("icu:MediaGallery__EmptyState__title--media", "icu:MediaGallery__EmptyState__description--media")
        case .audio: ("icu:MediaGallery__EmptyState__title--audio", "icu:MediaGallery__EmptyState__description--audio")
        case .documents: ("icu:MediaGallery__EmptyState__title--documents", "icu:MediaGallery__EmptyState__description--documents-2")
        case .links: ("icu:MediaGallery__EmptyState__title--links", "icu:MediaGallery__EmptyState__description--links-2")
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            CSSText(i18n(strings.0), type: .titleSmall, alignment: .center).accessibilityAddTraits(.isHeader)
            CSSText(i18n(strings.1), type: .bodyMedium, alignment: .center)
        }
        .fixedSize()
        .cssTextColor(.labelPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}
