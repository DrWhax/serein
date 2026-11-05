// Port of ts/components/preferences/chatFolders/PreferencesChatFolderItems.dom.tsx and the
// `.Preferences__ChatFolders__ChatSelection__*` rules of stylesheets/components/Preferences.scss:
// the rows of the chat folder pages (a 36px round icon or avatar, a title, a description).

import SwiftUI

/// `ItemAvatarKind`
enum ChatFolderItemAvatarKind {
    case folder, add, unreadChats, directChats, groupChats

    var icon: String {
        switch self {
        case .folder: "v3/folder/folder"
        case .add: "v3/plus/plus"
        case .unreadChats: "v3/chat/chat-badge"
        case .directChats: "v3/person/person"
        case .groupChats: "v3/group/group"
        }
    }
}

/// `ItemAvatar`: a 20px label-secondary glyph in a 36px fill-primary circle.
struct ChatFolderItemAvatar: View {
    let kind: ChatFolderItemAvatarKind
    var body: some View {
        SignalIcon(kind.icon, size: 20, color: .labelSecondary)
            .frame(width: 36, height: 36)
            .background(Circle().fill(AxoColor.fillPrimary))
    }
}

/// `ItemContent`: flex, items-center, gap 12, padding 8px 24px, radius 8; `ItemBody` (flex-1,
/// column) holds `ItemTitle` (body-1, primary) and `ItemDescription` (body-2, secondary).
struct ChatFolderItemContent<Leading: View, Trailing: View>: View {
    let title: String
    let description: String?
    let leading: Leading
    let trailing: Trailing
    var highlighted = false
    var focused = false

    init(title: String, description: String? = nil, highlighted: Bool = false, focused: Bool = false,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.description = description
        self.highlighted = highlighted
        self.focused = focused
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 0) {
                CSSText(title, style: LegacyType.body1(), color: .labelPrimary)
                if let description { CSSText(description, style: LegacyType.body2(), color: .labelSecondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 24)
        .background { if highlighted { shape.fill(AxoColor.fillPrimary) } }
        .axoFocusRingInset(focused, in: shape)
        .contentShape(shape)
    }
}

/// `itemClassName + itemButtonClassName`: a full-width button row (hover: fill-primary).
struct ChatFolderItemButton<Leading: View>: View {
    let title: String
    let action: () -> Void
    let leading: Leading
    var focused: Bool
    @State private var hovered = false

    init(title: String, focused: Bool = false, action: @escaping () -> Void, @ViewBuilder leading: () -> Leading) {
        self.title = title
        self.focused = focused
        self.action = action
        self.leading = leading()
    }

    var body: some View {
        SwiftUI.Button(action: action) {
            ChatFolderItemContent(title: title, highlighted: hovered, focused: focused) { leading }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
    }
}
