// Port of ts/components/GroupV2JoinDialog.dom.tsx: joining a group from its link — the
// group's avatar, title, member count and description, then join (or request to join).

import SignalI18n
import SwiftUI

public struct GroupV2JoinDialog: View {
    let title: String
    let avatar: RGBAImage?
    let avatarLoading: Bool
    let memberCount: Int
    let groupDescription: String?
    let approvalRequired: Bool
    let onJoin: () -> Void
    let onClose: () -> Void
    /// GroupDescription's "Read more" (shows the whole description).
    let onReadMoreDescription: () -> Void
    @Environment(\.i18n) var i18n

    public init(title: String, avatar: RGBAImage? = nil, avatarLoading: Bool = false, memberCount: Int, groupDescription: String? = nil,
                approvalRequired: Bool = false, onJoin: @escaping () -> Void = {}, onClose: @escaping () -> Void = {},
                onReadMoreDescription: @escaping () -> Void = {}) {
        self.onReadMoreDescription = onReadMoreDescription
        self.title = title
        self.avatar = avatar
        self.avatarLoading = avatarLoading
        self.memberCount = memberCount
        self.groupDescription = groupDescription
        self.approvalRequired = approvalRequired
        self.onJoin = onJoin
        self.onClose = onClose
    }

    public var body: some View {
        AxoDialog.Content(size: .sm, hasHeader: false) {
            AxoDialog.Body {
                VStack(spacing: 0) {
                    Avatar(strings: AvatarStrings(i18n: i18n), title: title, size: 80, conversationType: .group,
                           image: avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: avatar != nil, loading: avatarLoading)
                        .padding(.bottom, 12)
                    // <AxoDialog.Title><span type-title-medium> in an h2 with mb-2.5.
                    CSSText(title, style: CSSTextStyle(AxoType.titleMedium), alignment: .center, color: .labelPrimary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.bottom, 10)
                    CSSText(i18n("icu:GroupV2--join--group-metadata--full", ["memberCount": .number(Double(memberCount))]), type: .bodyMedium,
                            alignment: .center, color: .labelSecondary)
                    if let groupDescription, !groupDescription.isEmpty {
                        GroupDescription(title: title, text: groupDescription, alignment: .center, style: CSSTextStyle(AxoType.bodyMedium),
                                         color: .labelSecondary, onReadMore: onReadMoreDescription)
                            .padding(.top, 12)
                    }
                    Group {
                        if approvalRequired {
                            CSSText(i18n("icu:GroupV2--join--prompt-with-approval"), type: .bodySmall, alignment: .center, color: .labelSecondary)
                        } else {
                            CSSText(i18n("icu:GroupV2--join--prompt"), type: .bodyMedium, alignment: .center, color: .labelPrimary)
                        }
                    }
                    .padding(.top, 24)
                }
                .frame(maxWidth: .infinity)
                // The sm body's fixed 272px: wrap there exactly, as Blink does.
                .environment(\.cssTextWrapWidth, 272)
            }
            AxoDialog.Footer {
                AxoDialog.Actions(width: .fill) {
                    AxoDialog.Action(i18n("icu:cancel"), variant: .subtleSecondary, action: onClose)
                    AxoDialog.Action(i18n(approvalRequired ? "icu:GroupV2--join--request-to-join-button" : "icu:GroupV2--join--join-button"),
                                     variant: .strongPrimary, autoFocus: true, action: onJoin)
                }
            }
        }
        .overlay(alignment: .top) {
            // Join has autoFocus, so Close does not take the initial focus.
            AxoDialog.Header(floating: true, focusesClose: false) { AxoDialog.Close(action: onClose) }
        }
    }
}
