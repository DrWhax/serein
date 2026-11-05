// LeftPaneFindByUsernameHelper / LeftPaneFindByPhoneNumberHelper
// (ts/components/leftPane/LeftPaneFindBy*Helper.dom.tsx): a back header, the username (or
// country + number) field, and Next in the footer (a spinner while the lookup runs).

import SignalI18n
import SwiftUI

public struct LeftPaneFindByUsernameHelper: LeftPaneHelper {
    public var searchTerm: String
    public var isFetching: Bool
    public var doLookup: () -> Void

    public init(searchTerm: String, isFetching: Bool = false, doLookup: @escaping () -> Void = {}) {
        self.searchTerm = searchTerm
        self.isFetching = isFetching
        self.doLookup = doLookup
    }

    var isLookupDisabled: Bool { isFetching || UsernameSearch.username(from: searchTerm) == nil }

    public func headerContents(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(LeftPaneHeaderContents(backLabel: ctx.i18n("icu:setGroupMetadata__back-button"), back: { if !isFetching { ctx.startComposing() } },
                                       title: ctx.i18n("icu:LeftPaneFindByHelper__title--findByUsername")))
    }

    public func backAction(_ ctx: LeftPaneContext) -> (() -> Void)? { isFetching ? nil : ctx.startComposing }

    public func searchInput(_ ctx: LeftPaneContext) -> AnyView? {
        // __search-input: margin-top 8, padding-inline 12 (no search icon).
        AnyView(SearchInput(value: .constant(searchTerm), placeholder: ctx.i18n("icu:LeftPaneFindByHelper__placeholder--findByUsername"),
                            disabled: isFetching, hasSearchIcon: false,
                            description: ctx.i18n("icu:LeftPaneFindByHelper__description--findByUsername"), focusesOnAppear: true,
                            onEnter: doLookup)
            .environment(\.searchInputInlinePadding, 12)
            .padding(.top, 8))
    }

    public func footer(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(FindByNextButton(isFetching: isFetching, disabled: isLookupDisabled, action: doLookup))
    }

    public func rows(_ i18n: Localizer) -> [ConversationListRow] { [] }
}

public struct LeftPaneFindByPhoneNumberHelper: LeftPaneHelper {
    public var searchTerm: String
    public var regionCode: String?
    public var selectedRegion: String?
    public var isFetching: Bool
    public var doLookup: () -> Void
    public var onShowCountryModal: () -> Void

    public init(searchTerm: String, regionCode: String? = "US", selectedRegion: String? = nil, isFetching: Bool = false,
                doLookup: @escaping () -> Void = {}, onShowCountryModal: @escaping () -> Void = {}) {
        self.searchTerm = searchTerm
        self.regionCode = regionCode
        self.selectedRegion = selectedRegion
        self.isFetching = isFetching
        self.doLookup = doLookup
        self.onShowCountryModal = onShowCountryModal
    }

    var phoneNumber: ParsedPhoneNumber? { PhoneNumberParsing.parse(searchTerm, regionCode: selectedRegion ?? regionCode) }
    var isLookupDisabled: Bool { isFetching || !(phoneNumber?.isValid ?? false) }

    public func headerContents(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(LeftPaneHeaderContents(backLabel: ctx.i18n("icu:setGroupMetadata__back-button"), back: { if !isFetching { ctx.startComposing() } },
                                       title: ctx.i18n("icu:LeftPaneFindByHelper__title--findByPhoneNumber")))
    }

    public func backAction(_ ctx: LeftPaneContext) -> (() -> Void)? { isFetching ? nil : ctx.startComposing }

    public func searchInput(_ ctx: LeftPaneContext) -> AnyView? {
        // __container: margin-top 8, column, gap 12.
        AnyView(VStack(spacing: 12) {
            CountryCodeSelect(countries: CountryDataSource.countries(locale: ctx.i18n.locale), defaultRegion: regionCode ?? "",
                              value: selectedRegion, onShowModal: onShowCountryModal)
            SearchInput(value: .constant(searchTerm), placeholder: ctx.i18n("icu:LeftPaneFindByHelper__placeholder--findByPhoneNumber"),
                        disabled: isFetching, hasSearchIcon: false, focusesOnAppear: true, onEnter: doLookup)
                .environment(\.searchInputInlinePadding, 12)
        }
        .padding(.top, 8))
    }

    public func footer(_ ctx: LeftPaneContext) -> AnyView? {
        AnyView(FindByNextButton(isFetching: isFetching, disabled: isLookupDisabled, action: doLookup))
    }

    public func rows(_ i18n: Localizer) -> [ConversationListRow] { [] }
}

/// The footer's Next button (a 20px on-avatar spinner while fetching).
struct FindByNextButton: View {
    let isFetching: Bool
    let disabled: Bool
    let action: () -> Void
    @Environment(\.i18n) var i18n
    var body: some View {
        if isFetching {
            LegacyButton(nil, disabled: disabled, ariaLabel: i18n("icu:loading"), action: action)
                .overlay { Spinner(svgSize: .small, direction: .onAvatar, size: 20).frame(width: 20) }
        } else {
            LegacyButton(i18n("icu:next2"), disabled: disabled, action: action)
        }
    }
}
