// Port of ts/components/AvatarLightbox.dom.tsx: a conversation's avatar in the Lightbox (view
// once: close only), as AvatarPreview at the full height, at most 512px, initials at 16em.

import SwiftUI

public struct AvatarLightbox: View {
    let avatarColor: String?
    let avatarImage: RGBAImage?
    let placeholderGradient: (start: RGBA, end: RGBA)?
    let conversationTitle: String?
    let hasAvatar: Bool
    let isGroup: Bool
    let noteToSelf: Bool
    let onClose: () -> Void

    public init(avatarColor: String? = nil, avatarImage: RGBAImage? = nil, placeholderGradient: (start: RGBA, end: RGBA)? = nil,
                conversationTitle: String? = nil, hasAvatar: Bool = false, isGroup: Bool = false, noteToSelf: Bool = false, onClose: @escaping () -> Void = {}) {
        self.avatarColor = avatarColor
        self.avatarImage = avatarImage
        self.placeholderGradient = placeholderGradient
        self.conversationTitle = conversationTitle
        self.hasAvatar = hasAvatar
        self.isGroup = isGroup
        self.noteToSelf = noteToSelf
        self.onClose = onClose
    }

    public var body: some View {
        Lightbox(media: [], isViewOnce: true, closeLightbox: onClose, children: {
            GeometryReader { geo in
                // height 100% (max 512), plus the avatar's 4px / 16px margins.
                let side = max(64, min(512, geo.size.height - 20))
                AvatarPreview(avatarColor: avatarColor, avatarImage: avatarImage, placeholderGradient: placeholderGradient, hasAvatar: hasAvatar,
                              conversationTitle: conversationTitle, isGroup: isGroup, noteToSelf: noteToSelf, size: side)
                    .initialsFontSize(224)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        })
    }
}
