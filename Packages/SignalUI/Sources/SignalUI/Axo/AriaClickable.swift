// Port of ts/axo/AriaClickable.dom.tsx: a card-like region that acts as one clickable
// control. A `HiddenTrigger` (named by visible text, upstream aria-labelledby) is the
// accessible button and is stretched over the `Root`; clicking anywhere in the Root runs
// it, except inside a `DeadArea`, where `SubWidget`s (buttons, links) work on their own.
// The Root's hover / press / focus state is passed to its content for styling
// (`data-hovered`, `data-pressed`, `data-focused`).

import SwiftUI

public enum AriaClickable {
    public struct State: Sendable, Equatable {
        public var hovered = false
        public var pressed = false
        public var focused = false
    }

    struct Trigger: Equatable {
        let id: String
        let label: String
        let run: @MainActor () -> Void
        static func == (a: Trigger, b: Trigger) -> Bool { a.id == b.id && a.label == b.label }
    }

    struct TriggerKey: PreferenceKey {
        static var defaultValue: Trigger? { nil }
        static func reduce(value: inout Trigger?, nextValue: () -> Trigger?) { value = value ?? nextValue() }
    }

    /// `<AriaClickable.Root>`: the content is built from the current state.
    public struct Root<Content: View>: View {
        let content: (State) -> Content
        @SwiftUI.State private var hovered = false
        @SwiftUI.State private var pressed = false
        @SwiftUI.State private var trigger: Trigger?
        @FocusState private var focused: Bool

        public init(@ViewBuilder content: @escaping (State) -> Content) { self.content = content }

        public var body: some View {
            let state = State(hovered: hovered, pressed: pressed, focused: focused)
            content(state)
                .environment(\.ariaClickableState, state)
                .onPreferenceChange(TriggerKey.self) { trigger = $0 }
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false })
                .onTapGesture { trigger?.run() }
                .focusable()
                .focused($focused)
                .onKeyPress(keys: [.space, .return]) { _ in
                    trigger?.run()
                    return .handled
                }
                .accessibilityElement(children: .contain)
                .accessibilityAction(named: Text(trigger?.label ?? "")) { trigger?.run() }
        }
    }

    /// `<AriaClickable.HiddenTrigger>`: the Root's accessible action, named by `label`
    /// (the visible text upstream's `labelledby` points at). Draws nothing.
    public struct HiddenTrigger: View {
        let label: String
        let onClick: @MainActor @Sendable () -> Void
        @SwiftUI.State private var id = UUID().uuidString
        public init(label: String, onClick: @escaping @MainActor @Sendable () -> Void) {
            self.label = label
            self.onClick = onClick
        }
        public var body: some View {
            Color.clear.frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .preference(key: TriggerKey.self, value: Trigger(id: id, label: label, run: onClick))
        }
    }

    /// `<AriaClickable.DeadArea>`: clicks here don't reach the Root's trigger.
    public struct DeadArea<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View {
            content.contentShape(Rectangle()).onTapGesture {}
        }
    }

    /// `<AriaClickable.SubWidget>`: an interactive child (its own control) inside a DeadArea.
    public struct SubWidget<Content: View>: View {
        let content: Content
        public init(@ViewBuilder content: () -> Content) { self.content = content() }
        public var body: some View { content }
    }

    struct StateKey: EnvironmentKey { static let defaultValue = State() }
}

extension EnvironmentValues {
    /// The enclosing `AriaClickable.Root`'s state (for `group-data-*` styling).
    public var ariaClickableState: AriaClickable.State {
        get { self[AriaClickable.StateKey.self] }
        set { self[AriaClickable.StateKey.self] = newValue }
    }
}
