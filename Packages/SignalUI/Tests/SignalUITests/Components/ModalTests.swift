// Modal stories (ts/components/Modal.dom.stories.tsx) and their SwiftUI twins.

import SwiftUI
import Testing
@testable import SignalUI

let modalLorem = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Donec a diam lectus. Sed sit amet ipsum mauris. Maecenas congue ligula ac quam viverra nec consectetur ante hendrerit. Donec et mollis dolor. Praesent et diam eget libero egestas mattis sit amet vitae augue. Nam tincidunt congue enim, ut porta lorem lacinia consectetur. Donec ut libero sed arcu vehicula ultricies a non tortor. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Aenean ut gravida lorem. Ut turpis felis, pulvinar a semper sed, adipiscing id dolor. Pellentesque auctor nisi id magna consequat sagittis. Curabitur dapibus enim sit amet elit pharetra tincidunt feugiat nisl imperdiet. Ut convallis libero in urna ultrices accumsan. Donec sed odio eros. Donec viverra mi quis quam pulvinar at malesuada arcu rhoncus. Cum sociis natoque penatibus et magnis dis parturient montes, nascetur ridiculus mus. In rutrum accumsan ultricies. Mauris vitae nisi at sem facilisis semper ac in est."

/// English `icu:back` / `icu:close` (_locales/en/messages.json).
let modalStrings = ModalStrings(back: "Back", close: "Close")

/// Body text: the modal body's font-body-1, inherited by text and `<p>`s (no margins in Storybook).
@MainActor func ModalText(_ s: String) -> CSSBlockText { CSSBlockText(s, style: LegacyType.body1()) }

@MainActor struct ModalLoremParagraphs: View {
    var count = 4
    var body: some View { ForEach(0..<count, id: \.self) { _ in ModalText(modalLorem) } }
}

/// The long footers of LotsOfButtonsInTheFooter / StickyFooterLotsOfButtons.
@MainActor struct ModalLotsOfButtons: View {
    let first: String
    let autoFocus: Bool
    var body: some View {
        LegacyButton(first, autoFocus: autoFocus)
        LegacyButton("OK")
        LegacyButton("OK")
        LegacyButton("This is a button with a fairly large amount of text")
        LegacyButton("OK")
        LegacyButton("This is a button with a fairly large amount of text")
        LegacyButton("OK")
    }
}

@MainActor
@Suite struct ModalTests {
    static func stage(_ modal: some View) -> some View {
        PortalStage { EmptyView() } modal: { modal }
    }

    static func story(_ name: String) -> AnyView {
        switch name {
        case "bare-bones-short":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings) { ModalText("Hello world!") }))
        case "bare-bones-long":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings) { ModalLoremParagraphs() }))
        case "bare-bones-long-with-button":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings) { ModalLoremParagraphs() } footer: { LegacyButton("OK", autoFocus: true) }))
        case "title-x-button-body-and-button-footer":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings, title: "Hello world", hasXButton: true) { ModalText(modalLorem) }
                footer: { LegacyButton("OK") }))
        case "lots-of-buttons-in-the-footer":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings) { ModalText("Hello world!") }
                footer: { ModalLotsOfButtons(first: "OK X", autoFocus: true) }))
        case "long-body-with-title":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings, title: "Hello world") { ModalLoremParagraphs() }))
        case "long-body-with-title-and-button":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings, title: "Hello world") { ModalLoremParagraphs() }
                footer: { LegacyButton("OK", autoFocus: true) }))
        case "long-body-with-long-title-and-x-button":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings, title: String(modalLorem.prefix(104)), hasXButton: true) {
                ModalLoremParagraphs()
            }))
        case "with-sticky-buttons-long-body":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings, hasXButton: true) { ModalLoremParagraphs() }
                footer: { LegacyButton("OK"); LegacyButton("OK") }))
        case "with-sticky-buttons-short-body":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings, hasXButton: true) { ModalText(String(modalLorem.prefix(140))) }
                footer: { LegacyButton("OK"); LegacyButton("OK") }))
        case "sticky-footer-lots-of-buttons":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings, title: "OK") { ModalText(modalLorem) }
                footer: { ModalLotsOfButtons(first: "OK", autoFocus: true) }))
        case "with-back-button":
            AnyView(stage(Modal(modalName: "test", strings: modalStrings, title: "The Modal Title", hasXButton: true, onBackButtonClick: {}) {
                ModalText("Hello world!")
            }))
        default: fatalError(name)
        }
    }

    @Test(arguments: ["bare-bones-short", "bare-bones-long", "bare-bones-long-with-button", "title-x-button-body-and-button-footer",
                      "lots-of-buttons-in-the-footer", "long-body-with-title", "long-body-with-title-and-button",
                      "long-body-with-long-title-and-x-button", "with-sticky-buttons-long-body", "with-sticky-buttons-short-body",
                      "sticky-footer-lots-of-buttons", "with-back-button"],
          ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.story(name), story: "components-modal--\(name)", theme: theme)
    }
}
