// AxoContactList stories (ts/axo/items/AxoContactList.dom.stories.tsx).

import SwiftUI
import Testing
@testable import SignalUI

/// The stories' `Avatar`: 32px initials on A100.
@MainActor func contactAvatar(_ label: String, _ initials: String) -> some View {
    AxoAvatar.Root(size: 32) {
        AxoAvatar.Content(label: label) { AxoAvatar.Initials(initials: initials, color: "A100") }
    }
}

/// The stories' `About`: `<FunInlineEmoji/> {label}`. The 17px emoji box raises the 12px
/// line to 17px and sits on its baseline, which moves 1px down.
struct ContactAbout: View {
    let emoji: String
    let label: String
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            StoryInlineEmoji(emoji: emoji)
            AxoContactList.DescriptionText(" " + label).padding(.top, 1)
        }
    }
}

enum ContactStoryText {
    static let lorem = "Lorem ipsum dolor sit amet, consectetur adipisicing elit. Magni ipsum exercitationem est facilis, rerum ea reiciendis tempore sit magnam adipisci dolorem hic possimus illo optio ipsam. Repudiandae, pariatur saepe. Aperiam."
    static let wave = "👋", coffee = "☕"
}

@MainActor
@Suite struct AxoContactListTests {
    @Test(arguments: ["light", "dark"]) func basic(theme: String) throws {
        let view = StoryMaxWidth {
            AxoContactList.Root {
                AxoContactList.Item(title: "Jamie", onClick: {}) { contactAvatar("Jamie's Avatar", "JK") }
                AxoContactList.Item(title: "Tyler", onClick: {}) { contactAvatar("Tyler's Avatar", "TN") }
                AxoContactList.Item(title: "Adrian", onClick: {}) { contactAvatar("Adrian's Avatar", "AS") }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axocontactlist--basic", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func description(theme: String) throws {
        let view = StoryMaxWidth {
            AxoContactList.Root {
                AxoContactList.Item(title: "Jamie", onClick: {}) { contactAvatar("Jamie's Avatar", "JK") } description: {
                    AxoContactList.DescriptionText(ContactStoryText.lorem)
                }
                AxoContactList.Item(title: "Tyler", onClick: {}) { contactAvatar("Tyler's Avatar", "TN") } description: {
                    ContactAbout(emoji: ContactStoryText.wave, label: "Speak Freely")
                }
                AxoContactList.Item(title: "Adrian", onClick: {}) { contactAvatar("Adrian's Avatar", "AS") } description: {
                    ContactAbout(emoji: ContactStoryText.coffee, label: "Coffee lover")
                }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axocontactlist--description", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func value(theme: String) throws {
        let view = StoryMaxWidth {
            AxoContactList.Root {
                AxoContactList.Item(title: "Jamie", value: "Admin", onClick: {}) { contactAvatar("Jamie's Avatar", "JK") }
                AxoContactList.Item(title: "Tyler", value: "Admin", onClick: {}) { contactAvatar("Tyler's Avatar", "TN") } description: {
                    ContactAbout(emoji: ContactStoryText.wave, label: "Speak Freely")
                }
                AxoContactList.Item(title: "Adrian", value: "Admin", onClick: {}) { contactAvatar("Adrian's Avatar", "AS") } description: {
                    AxoContactList.DescriptionText(ContactStoryText.lorem)
                }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axocontactlist--value", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func itemActions(theme: String) throws {
        let button = { AxoContactList.ItemAction("Button", variant: .subtleSecondary) }
        let view = StoryMaxWidth {
            AxoContactList.Root {
                AxoContactList.Item(title: "Jamie", onClick: {}) { contactAvatar("Jamie's Avatar", "JK") } accessory: { button() }
                AxoContactList.Item(title: "Tyler", onClick: {}) { contactAvatar("Tyler's Avatar", "TN") } description: {
                    ContactAbout(emoji: ContactStoryText.wave, label: "Speak Freely")
                } accessory: { button() }
                AxoContactList.Item(title: "Adrian", onClick: {}) { contactAvatar("Adrian's Avatar", "AS") } accessory: { button() }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axocontactlist--item-actions", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func itemIconActions(theme: String) throws {
        let video = { AxoContactList.ItemIconAction(label: "Start video call", variant: .impliedSecondary, symbol: "videocamera") }
        let view = StoryMaxWidth {
            AxoContactList.Root {
                AxoContactList.Item(title: "Jamie", onClick: {}) { contactAvatar("Jamie's Avatar", "JK") } accessory: { video() }
                AxoContactList.Item(title: "Tyler", onClick: {}) { contactAvatar("Tyler's Avatar", "TN") } description: {
                    ContactAbout(emoji: ContactStoryText.wave, label: "Speak Freely")
                } accessory: {
                    AxoContactList.ItemIconAction(label: "Start audio call", variant: .impliedSecondary, symbol: "phone")
                    video()
                }
                AxoContactList.Item(title: "Adrian", onClick: {}) { contactAvatar("Adrian's Avatar", "AS") } accessory: { video() }
            }
        }
        try itemsSnapshot(view, story: "axo-items-axocontactlist--item-icon-actions", theme: theme)
    }

    @Test(arguments: ["light", "dark"]) func actionItems(theme: String) throws {
        let view = StoryMaxWidth {
            AxoContactList.Root {
                AxoContactList.ActionItem(symbol: "plus", title: "Add members", onClick: {})
                AxoContactList.Item(title: "Jamie", onClick: {}) { contactAvatar("Jamie's Avatar", "JK") } description: {
                    ContactAbout(emoji: ContactStoryText.coffee, label: "Coffee lover")
                }
                AxoContactList.Item(title: "Tyler", onClick: {}) { contactAvatar("Tyler's Avatar", "TN") } description: {
                    ContactAbout(emoji: ContactStoryText.wave, label: "Speak Freely")
                }
                AxoContactList.ActionItem(symbol: "chevron-down", title: "See all", onClick: {})
            }
        }
        try itemsSnapshot(view, story: "axo-items-axocontactlist--action-items", theme: theme)
    }
}
