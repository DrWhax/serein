// Compose / search rows: StartNewConversation, UsernameSearchResultListItem and the loading
// skeleton (SearchResultsLoadingFakeHeader / Row) from ts/components/conversationList.

import SignalI18n
import SwiftUI

/// `ParsedE164Type` for a typed phone number.
public struct ParsedPhoneNumber: Sendable, Hashable {
    public var isValid: Bool
    public var userInput: String
    public var e164: String
    public init(isValid: Bool, userInput: String, e164: String) {
        self.isValid = isValid
        self.userInput = userInput
        self.e164 = e164
    }
}

/// A search-result ListTile: the search avatar, the query as the title, a spinner while
/// the lookup runs.
struct LookupListTile: View {
    let title: String
    let isFetching: Bool
    let onClick: () -> Void

    var body: some View {
        ListTile(onClick: onClick) {
            ListAvatar(data: ConversationAvatarData(title: title, conversationType: .direct, searchResult: true), size: 32)
        } title: {
            CSSText(title, style: ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.titleStyle, wrap: .clamp(1))
        } subtitle: {
            EmptyView()
        } trailing: {
            if isFetching { Spinner(svgSize: .small, direction: .onProgressDialog, size: 20).frame(width: 20) }
        }
    }
}

/// StartNewConversation: start a chat with a typed phone number (an invalid number shows a
/// confirm dialog through `onInvalid`).
public struct StartNewConversation: View {
    let phoneNumber: ParsedPhoneNumber
    let isFetching: Bool
    let lookup: (ParsedPhoneNumber) -> Void
    let onInvalid: (ParsedPhoneNumber) -> Void

    public init(phoneNumber: ParsedPhoneNumber, isFetching: Bool, lookup: @escaping (ParsedPhoneNumber) -> Void = { _ in },
                onInvalid: @escaping (ParsedPhoneNumber) -> Void = { _ in }) {
        self.phoneNumber = phoneNumber
        self.isFetching = isFetching
        self.lookup = lookup
        self.onInvalid = onInvalid
    }

    public var body: some View {
        LookupListTile(title: phoneNumber.userInput, isFetching: isFetching) {
            if !phoneNumber.isValid { onInvalid(phoneNumber) } else if !isFetching { lookup(phoneNumber) }
        }
    }
}

public struct UsernameSearchResultListItem: View {
    let username: String
    let isFetchingUsername: Bool
    let lookup: (String) -> Void

    public init(username: String, isFetchingUsername: Bool, lookup: @escaping (String) -> Void = { _ in }) {
        self.username = username
        self.isFetchingUsername = isFetchingUsername
        self.lookup = lookup
    }

    public var body: some View {
        LookupListTile(title: username, isFetching: isFetchingUsername) { if !isFetchingUsername { lookup(username) } }
    }
}

/// `search-results-loading-pulsating-background`: gray boxes pulsing 1 → 0.55 → 1 over 2s.
struct SearchLoadingBox: View {
    let width: CGFloat?
    let height: CGFloat
    let radius: CGFloat
    @Environment(\.axoAnimationsDisabled) var animationsDisabled

    var body: some View {
        let fill = AxoColor(light: LegacyColor.gray05, dark: LegacyColor.gray65)
        Group {
            if animationsDisabled {
                RoundedRectangle(cornerRadius: radius).fill(fill)
            } else {
                TimelineView(.animation) { t in
                    let p = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
                    RoundedRectangle(cornerRadius: radius).fill(fill).opacity(1 - 0.45 * (1 - abs(2 * p - 1)))
                }
            }
        }
        .frame(width: width, height: height)
    }
}

public struct SearchResultsLoadingFakeHeader: View {
    public init() {}
    public var body: some View {
        GeometryReader { geo in
            SearchLoadingBox(width: (geo.size.width - 28) * 0.25, height: 12, radius: 4)
                .padding(14)
                .frame(maxHeight: .infinity)
        }
    }
}

public struct SearchResultsLoadingFakeRow: View {
    public init() {}
    public var body: some View {
        HStack(spacing: 0) {
            SearchLoadingBox(width: 48, height: 48, radius: 24)
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 8) {
                    SearchLoadingBox(width: geo.size.width * 0.3, height: 12, radius: 4)
                    SearchLoadingBox(width: geo.size.width * 0.9, height: 12, radius: 4)
                    SearchLoadingBox(width: geo.size.width * 0.6, height: 12, radius: 4)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 52)
            .padding(.leading, 12)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
    }
}

/// PhoneNumberCheckbox / UsernameCheckbox: a search-avatar ListTile.checkbox for a typed
/// number or username (a spinner tile while the lookup runs).
public struct LookupCheckbox: View {
    let title: String
    let isChecked: Bool
    let isFetching: Bool
    let onClick: () -> Void

    public init(title: String, isChecked: Bool, isFetching: Bool, onClick: @escaping () -> Void = {}) {
        self.title = title
        self.isChecked = isChecked
        self.isFetching = isFetching
        self.onClick = onClick
    }

    public var body: some View {
        if isFetching {
            LookupListTile(title: title, isFetching: true, onClick: {})
        } else {
            ListTileCheckbox(isChecked: isChecked, onClick: onClick) {
                ListAvatar(data: ConversationAvatarData(title: title, conversationType: .direct, searchResult: true), size: 32)
            } title: {
                CSSText(title, style: ListTile<EmptyView, EmptyView, EmptyView, EmptyView>.titleStyle, wrap: .clamp(1))
            } subtitle: {
                EmptyView()
            }
        }
    }
}
