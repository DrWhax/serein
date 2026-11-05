// Port of ts/axo/AxoConfirmDialog.dom.tsx: AxoAlertDialog preset with a title, a
// description and actions (Cancel / Ok / Action).

import SwiftUI

public enum AxoConfirmDialog {
    /// `<AxoConfirmDialog.Root>` content (present inside `AxoBaseDialog.Host`).
    public struct Root<Description: View, Actions: View>: View {
        let title: String?
        let description: Description
        let actions: Actions
        /// `description` as nodes (e.g. paragraphs), in the Description's body-medium style.
        public init(title: String?, @ViewBuilder description: () -> Description, @ViewBuilder actions: () -> Actions) {
            self.title = title
            self.description = description()
            self.actions = actions()
        }
        public var body: some View {
            AxoAlertDialog.Content {
                AxoAlertDialog.Body {
                    if let title { AxoAlertDialog.Title(title) }
                    description
                }
                AxoAlertDialog.Footer { actions }
            }
        }
    }

    public typealias Cancel = AxoAlertDialog.Cancel
    public typealias Ok = AxoAlertDialog.Ok
    public typealias Action = AxoAlertDialog.Action
}

extension AxoConfirmDialog.Root where Description == AxoAlertDialog.Description? {
    public init(title: String?, description: String?, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, description: { description.map { AxoAlertDialog.Description($0) } }, actions: actions)
    }
}
