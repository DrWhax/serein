// AxoDialog stories (ts/axo/AxoDialog.dom.stories.tsx). Dialogs open in a portal, so the
// reference is the whole 1200×900 viewport: the story root (the auto-clicked
// StoryTrigger) at 16,16 under the modal host.

import SwiftUI
import Testing
@testable import SignalUI

/// The Storybook viewport with the story root at 16,16 and a modal layer above it.
struct PortalStage<Root: View, Modal: View>: View {
    @ViewBuilder var root: Root
    @ViewBuilder var modal: Modal
    var body: some View {
        ZStack(alignment: .topLeading) {
            root.padding(16)
            modal.frame(width: 1200, height: 900)
        }
        .frame(width: 1200, height: 900, alignment: .topLeading)
    }
}

let loremShort = "Lorem ipsum dolor"
let loremLong = "Lorem ipsum dolor sit amet consectetur, adipisicing elit. Eum repudiandae repellendus quo natus, placeat incidunt neque, exercitationem itaque, error molestiae omnis laudantium? Ex aperiam quas impedit ut ratione cumque repudiandae!"
let loremBasic = "Lorem ipsum dolor sit amet consectetur adipisicing elit. Laboriosam est cum consequuntur natus repudiandae vel aperiam minus pariatur, repellendus reprehenderit ad unde, sit magnam dicta ut deleniti veniam modi ea."

/// Story `Template`
struct AxoDialogTemplate: View {
    var back = false
    let size: AxoDialog.ContentSize
    var iconAction = false
    var footerContent: String? = nil
    let text: String

    var body: some View {
        PortalStage {
            AxoButton.Root("Open Dialog", variant: .strongPrimary, size: .md)   // AxoDialog.StoryTrigger
        } modal: {
            AxoBaseDialog.Host {
                AxoDialog.Content(size: size) {
                    AxoDialog.Header {
                        if back { AxoDialog.Back {} }
                        AxoDialog.Title("Title")
                        AxoDialog.Close()
                    }
                    AxoDialog.Body { AxoDialog.Description(text) }
                    AxoDialog.Footer {
                        if let footerContent { AxoDialog.FooterContent(footerContent) }
                        AxoDialog.Actions {
                            if iconAction {
                                AxoDialog.IconAction(label: "Send message", variant: .strongPrimary, symbol: "send-fill") {}
                            } else {
                                AxoDialog.Action("Cancel", variant: .subtleSecondary) {}
                                AxoDialog.Action("Save", variant: .strongPrimary) {}
                            }
                        }
                    }
                }
            }
        }
    }
}

@MainActor
@Suite struct AxoDialogTests {
    static let stories: [String: AxoDialogTemplate] = [
        "basic": AxoDialogTemplate(size: .md, text: loremBasic),
        "small": AxoDialogTemplate(size: .sm, text: loremLong),
        "large": AxoDialogTemplate(size: .lg, text: loremLong),
        "icon-action": AxoDialogTemplate(size: .sm, iconAction: true, text: loremLong),
        "back-button": AxoDialogTemplate(back: true, size: .md, text: loremLong),
        "footer-content": AxoDialogTemplate(size: .md, footerContent: loremShort, text: loremLong),
        "footer-content-long": AxoDialogTemplate(size: .md, footerContent: loremLong, text: loremLong),
        "footer-content-long-and-tight": AxoDialogTemplate(size: .sm, footerContent: loremLong, text: loremLong),
    ]

    @Test(arguments: ["basic", "small", "large", "icon-action", "back-button", "footer-content", "footer-content-long", "footer-content-long-and-tight"],
          ["light", "dark"])
    func story(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.stories[name]!, story: "axo-axodialog--\(name)", theme: theme)
    }

    /// The stories' `Box`: a centred title-large number on fill-accent, rounded 16, padding 40.
    static func box(_ n: Int) -> some View {
        CSSText(String(n), type: AxoType.titleLarge, color: .labelPrimaryOncolor)
            .padding(40).frame(maxWidth: .infinity)
            .background(AxoColor.fillAccent, in: RoundedRectangle(cornerRadius: 16))
    }

    static func stage(_ dialog: some View) -> some View {
        PortalStage { AxoButton.Root("Open Dialog", variant: .strongPrimary, size: .md) } modal: { AxoBaseDialog.Host { dialog } }
    }

    static func cancelOK(_ ok: String = "OK", width: AxoDialog.Actions<AnyView>.Width = .fit) -> some View {
        AxoDialog.Footer {
            AxoDialog.Actions(width: width) {
                AnyView(Group {
                    AxoDialog.Action("Cancel", variant: .subtleSecondary) {}
                    AxoDialog.Action(ok, variant: .strongPrimary) {}
                })
            }
        }
    }

    static var moreStories: [String: AnyView] {
        [
            "long-content": AnyView(stage(AxoDialog.Content(size: .md) {
                AxoDialog.Header { AxoDialog.Title("Title"); AxoDialog.Close() }
                AxoDialog.Body { VStack(spacing: 8) { ForEach(1...10, id: \.self) { box($0) } } }
                cancelOK("Save")
            })),
            "floating-header": AnyView(stage(AxoDialog.Content(size: .sm, hasHeader: false) {
                AxoDialog.Body {
                    AxoAvatar.Root(size: 72) { AxoAvatar.Content(label: nil) { AxoAvatar.Icon(symbol: "securitykey") } }
                        .frame(maxWidth: .infinity).padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 8) {
                        AxoDialog.Description("Lorem ipsum dolor sit amet consectetur adipisicing elit. Aspernatur repudiandae, provident accusamus sed velit possimus tenetur.")
                        AxoDialog.Description("Numquam explicabo, aliquid commodi, expedita ut facere aut eos, omnis velit qui quos consequatur.")
                    }
                }
                cancelOK()
            }
            .overlay(alignment: .top) { AxoDialog.Header(floating: true) { AxoDialog.Title("Floating Header"); AxoDialog.Close() } })),
            "full-width-actions": AnyView(stage(AxoDialog.Content(size: .sm) {
                AxoDialog.Header { AxoDialog.Title("Full Width Actions"); AxoDialog.Close() }
                AxoDialog.Body { AxoDialog.Description("This dialog demonstrates full width actions.") }
                cancelOK(width: .fill)
            })),
            "tabs": AnyView(stage(AxoDialog.Content(size: .md) {
                AxoDialog.Header { AxoDialog.Title("Tabs"); AxoDialog.Close() }
                AxoDialog.Tabs(value: .constant("short")) {
                    AxoDialog.TabList {
                        AxoDialog.Tab(value: "short", "Short")
                        AxoDialog.Tab(value: "long", "Long")
                        AxoDialog.Tab(value: "cards", "Cards")
                    }
                    AxoDialog.TabContent(value: "short") { AxoDialog.Body { AxoDialog.Description(loremShort) } }
                }
                cancelOK("Save")
            })),
        ]
    }

    @Test(arguments: ["long-content", "floating-header", "full-width-actions", "tabs"], ["light", "dark"])
    func moreStory(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.moreStories[name]!, story: "axo-axodialog--\(name)", theme: theme)
    }

    /// The example stories' raw `<input>`: px-3, 18px text in the inherited text-secondary; the
    /// placeholder is currentcolor at 50% (Tailwind preflight).
    static func inputText(_ placeholder: String) -> some View {
        CSSText(placeholder, type: .bodyMedium, wrap: .nowrap, color: .labelSecondary).opacity(0.5)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `TextInputField`: py-1.5 around an elevation-0 control input, 8px wider than the body.
    static func textInputField(_ placeholder: String) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        // The 1px border adds to the box (border-box: py-1.5 + border).
        return inputText(placeholder).padding(.vertical, 7).padding(.horizontal, 1)
            .background(shape.fill(AxoColor.fillControl))
            .overlay(shape.strokeBorder(AxoColor.borderPrimary, lineWidth: 1))
            .axoShadow(.shadowElevation0, in: shape)
            .padding(.vertical, 6).padding(.horizontal, -8)
    }

    /// `CheckboxField`: a square checkbox and a truncated body-large label, gap 12, py 10.
    static func checkboxField(_ label: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AxoCheckbox.Root(variant: .square, checked: .constant(false), label: label)
            CSSText(label, type: .bodyLarge, wrap: .truncate, color: .labelPrimary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    /// `ExampleItem`: label and description, rounded-lg px 13 py 10.
    static func exampleItem(_ label: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CSSText(label, type: .bodyLarge, wrap: .truncate, color: .labelPrimary)
            CSSText(description, type: .bodySmall, wrap: .truncate, color: .labelSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 10)
    }

    static var exampleStories: [String: AnyView] {
        let languages = [("System Language", "English"), ("Afrikaans", "Afrikaans"), ("Arabic", "العربية"), ("Azerbaijani", "Azərbaycan dili"),
                         ("Bulgarian", "Български"), ("Bangla", "বাংলা"), ("Bosnian", "bosanski"), ("Catalan", "català"), ("Czech", "Čeština")]
        return [
            "example-nickname-and-note-dialog": AnyView(stage(AxoDialog.Content(size: .sm) {
                AxoDialog.Header { AxoDialog.Title("Nickname"); AxoDialog.Close() }
                AxoDialog.Body {
                    CSSText("Nicknames & notes are stored with Signal and end-to-end encrypted. They are only visible to you.", type: .bodySmall,
                            color: .labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 16)
                    Circle().fill(AxoColor.fillAccent).frame(width: 80, height: 80).frame(maxWidth: .infinity)
                    Color.clear.frame(height: 12)
                    textInputField("First name")
                    textInputField("Last name")
                    textInputField("Note")
                    Color.clear.frame(height: 12)
                }
                cancelOK("Save")
            })),
            "example-mute-notifications-dialog": AnyView(stage(AxoDialog.Content(size: .sm) {
                AxoDialog.Header { AxoDialog.Title("Mute notifications"); AxoDialog.Close() }
                AxoDialog.Body {
                    Color.clear.frame(height: 8)
                    ForEach(["Mute for 1 hour", "Mute for 8 hours", "Mute for 1 day", "Mute for 1 week", "Mute always"], id: \.self) { checkboxField($0) }
                    Color.clear.frame(height: 8)
                }
                cancelOK("Save")
            })),
            "example-language-dialog": AnyView(stage(AxoDialog.Content(size: .sm) {
                // The search input has autoFocus.
                AxoDialog.Header(focusesClose: false) { AxoDialog.Title("Language"); AxoDialog.Close() }
                AxoDialog.Search {
                    inputText("Search languages").padding(.vertical, 5)
                        .background(AxoColor.fillPrimary, in: RoundedRectangle(cornerRadius: 8))
                        .overlay { ChromiumFocusOutline(shape: RoundedRectangle(cornerRadius: 8)) }
                }
                AxoDialog.Body(padding: .sm) {
                    VStack(spacing: 0) { ForEach(languages, id: \.0) { exampleItem($0.0, $0.1) } }.padding(.horizontal, 11)
                }
                cancelOK("Set")
            })),
        ]
    }

    @Test(arguments: ["example-nickname-and-note-dialog", "example-mute-notifications-dialog", "example-language-dialog"], ["light", "dark"])
    func exampleStory(name: String, theme: String) throws {
        try Snapshot.assertMatches(Self.exampleStories[name]!, story: "axo-axodialog--\(name)", theme: theme)
    }
}
