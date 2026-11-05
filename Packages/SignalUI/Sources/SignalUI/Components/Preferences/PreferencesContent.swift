// `PreferencesContent` of ts/components/Preferences.dom.tsx: the legacy page frame — a 52px
// title (body-1 bold, centred; an optional back button), then the pane (max 750px, pt 8)
// centred between spacers, and optional actions.

import SwiftUI

public struct PreferencesContent<Contents: View, Actions: View>: View {
    let title: String?
    let backButton: AnyView?
    let contents: Contents
    let actions: Actions
    @Environment(\.titleBarDragAreaHeight) var dragAreaHeight

    public init(title: String?, backButton: AnyView? = nil, @ViewBuilder contents: () -> Contents, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.backButton = backButton
        self.contents = contents()
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .leading) {
                // With a back button, the title keeps centred clear of it (margin-inline-end 32).
                CSSText(title ?? "", style: LegacyType.body1(weight: 700), alignment: .center, color: .labelPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, backButton == nil ? 0 : 32)
                    .accessibilityAddTraits(.isHeader)
                if let backButton { backButton }
            }
            .frame(height: 52)
            .padding(.top, dragAreaHeight)
            AxoDialog.AxoScrollContainer {
                VStack(alignment: .leading, spacing: 0) { contents }
                    .padding(.top, 8)
                    .frame(maxWidth: 750)
                    .frame(maxWidth: .infinity)
            }
            if Actions.self != EmptyView.self {
                // .Preferences__actions: flex-end row, gap 16, padding 16.
                HStack(spacing: 16) { actions }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
