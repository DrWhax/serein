// The window's modal layer (upstream: dialogs portal into the modal host over the app). A
// view presents a dialog with `axoModalStack.present(id:)`; the root view draws the stack
// with `.axoModalHost()`, each entry in an AxoBaseDialog.Host (overlay + centred panel).

import Observation
import SwiftUI

@MainActor @Observable
public final class AxoModalStack {
    public struct Entry: Identifiable {
        public let id: String
        let content: AnyView
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Shows `content` (replacing an entry with the same id).
    public func present(id: String, @ViewBuilder _ content: () -> some View) {
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, content: AnyView(content())))
    }

    public func dismiss(id: String) { entries.removeAll { $0.id == id } }
}

extension EnvironmentValues {
    /// The window's modal stack (nil when no `.axoModalHost()` is installed).
    @Entry public var axoModalStack: AxoModalStack? = nil
}

struct AxoModalHost: ViewModifier {
    @State private var stack = AxoModalStack()
    func body(content: Content) -> some View {
        content
            .environment(\.axoModalStack, stack)
            .overlay {
                ForEach(stack.entries) { entry in
                    AxoBaseDialog.Host { entry.content }.environment(\.axoModalStack, stack)
                }
            }
    }
}

extension View {
    /// Installs the window's modal layer.
    public func axoModalHost() -> some View { modifier(AxoModalHost()) }
}
