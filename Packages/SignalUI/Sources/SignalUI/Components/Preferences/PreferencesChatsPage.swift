// The Chats page of ts/components/Preferences.dom.tsx: contact photos and archiving, text
// input (spell check, formatting, link previews, emoticons, skin tone), chat folders, chat
// history export and contact sync.

import SignalI18n
import SwiftUI

public struct ChatsSettings: Sendable, Hashable {
    public var hasPreferContactAvatars = true
    public var hasKeepMutedChatsArchived = false
    public var hasSpellCheck: Bool? = true
    public var initialSpellCheckSetting = true
    public var hasTextFormatting = true
    public var hasLinkPreviews = true
    public var hasAutoConvertEmoji = true
    public var emojiSkinToneDefault: EmojiSkinTone? = EmojiSkinTone.none
    public var currentChatFoldersCount = 0
    public var hasAnyCurrentCustomChatFolders = false
    public var isSyncSupported = true
    /// The last contact sync, as `toLocaleDateString()` / `toLocaleTimeString()` print it.
    public var lastSyncDate = ""
    public var lastSyncTime = ""
    public init() {}
}

public struct PreferencesChatsPage: View {
    @Binding var settings: ChatsSettings
    let onOpenChatFolders: () -> Void
    let startPlaintextExport: () -> Void
    let makeSyncRequest: @Sendable () async throws -> Void
    @State private var nowSyncing = false
    @State private var showSyncFailed = false
    @Environment(\.i18n) var i18n

    public init(settings: Binding<ChatsSettings>, onOpenChatFolders: @escaping () -> Void = {}, startPlaintextExport: @escaping () -> Void = {},
                makeSyncRequest: @escaping @Sendable () async throws -> Void = {}) {
        _settings = settings
        self.onOpenChatFolders = onOpenChatFolders
        self.startPlaintextExport = startPlaintextExport
        self.makeSyncRequest = makeSyncRequest
    }

    var spellCheckDirtyText: String? {
        guard let on = settings.hasSpellCheck, on != settings.initialSpellCheckSetting else { return nil }
        return i18n(on ? "icu:spellCheckWillBeEnabled" : "icu:spellCheckWillBeDisabled")
    }

    public var body: some View {
        let folders = settings.hasAnyCurrentCustomChatFolders
        AxoPanel.Root {
            AxoPanel.Header { AxoPanel.Label(i18n("icu:Preferences__button--chats")) }
            AxoPanel.Content {
                AxoList.Group {
                    PreferencesList(accessibilityLabel: i18n("icu:Preferences__button--chats")) {
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__address-book-photos--title"),
                                           description: i18n("icu:Preferences__address-book-photos--description"), checked: $settings.hasPreferContactAvatars)
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__keep-muted-chats-archived--title"),
                                           description: i18n("icu:Preferences__keep-muted-chats-archived--description"), checked: $settings.hasKeepMutedChatsArchived)
                    }
                    PreferencesList(label: i18n("icu:Preferences__Chats__TextInputSection__Title")) {
                        AxoSwitchItem.Root(label: i18n("icu:spellCheckDescription"), description: spellCheckDirtyText, disabled: settings.hasSpellCheck == nil,
                                           checked: Binding { settings.hasSpellCheck ?? false } set: { settings.hasSpellCheck = $0 })
                        AxoSwitchItem.Root(label: i18n("icu:textFormattingDescription"), checked: $settings.hasTextFormatting)
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__link-previews--title"), description: i18n("icu:Preferences__link-previews--new-description"),
                                           checked: $settings.hasLinkPreviews)
                        AxoSwitchItem.Root(label: i18n("icu:Preferences__auto-convert-emoji--title"),
                                           checked: $settings.hasAutoConvertEmoji)
                            // <I18n>: plain text (the emoji from the font fallback).
                            .descriptionRuns(CSSTextRun.runs(i18n.richText("icu:Preferences__auto-convert-emoji--description"))) { _ in }
                        AxoItem.Root {
                            AxoItem.Content {
                                AxoItem.Label(i18n("icu:Preferences__EmojiSkinToneDefaultSetting__Label"))
                                AxoItem.Accessory {
                                    FunSkinTonesList(emoji: "✋", skinTone: settings.emojiSkinToneDefault) { settings.emojiSkinToneDefault = $0 }
                                }
                            }
                        }
                    }
                    PreferencesList(label: i18n("icu:Preferences__Chats__ChatFoldersSection__Title")) {
                        AxoClickableItem.Root(label: i18n(folders ? "icu:Preferences__ChatsPage__ChatFoldersSection__AddChatFolderItem__Title--WithChatFolders"
                                                          : "icu:Preferences__ChatsPage__ChatFoldersSection__AddChatFolderItem__Title"),
                                              description: i18n("icu:Preferences__ChatsPage__ChatFoldersSection__AddChatFolderItem__Description"),
                                              value: folders ? i18n("icu:Preferences__ChatsPage__ChatFoldersSection__AddChatFolderItem__Description--WithChatFolders",
                                                                    ["chatFoldersCount": .number(Double(settings.currentChatFoldersCount))]) : nil,
                                              arrow: .next, onClick: onOpenChatFolders)
                    }
                    PreferencesList {
                        PreferencesItemWithAction(label: i18n("icu:PlaintextExport--PreferencesRow--Header"),
                                                  description: i18n("icu:PlaintextExport--PreferencesRow--Description")) {
                            AxoItem.Action(i18n("icu:PlaintextExport--ActionButton"), variant: .subtleSecondary, action: startPlaintextExport)
                        }
                    }
                    if settings.isSyncSupported {
                        PreferencesList {
                            AxoItem.Root {
                                AxoItem.Content {
                                    AxoItem.Label(i18n("icu:sync"))
                                    AxoItem.Description {
                                        VStack(alignment: .leading, spacing: 0) {
                                            AxoBaseItem.Text(i18n("icu:syncExplanation") + " " + i18n("icu:Preferences--lastSynced",
                                                                                                      ["date": .string(settings.lastSyncDate), "time": .string(settings.lastSyncTime)]),
                                                             type: .bodySmall)
                                            if showSyncFailed {
                                                CSSText(i18n("icu:syncFailed"), type: .bodySmall, color: .labelDestructive)
                                            }
                                        }
                                    }
                                    AxoItem.Accessory {
                                        AxoItem.Action(i18n("icu:syncNow"), variant: .subtleSecondary, pending: nowSyncing) {
                                            showSyncFailed = false
                                            nowSyncing = true
                                            Task {
                                                do { try await makeSyncRequest() } catch { showSyncFailed = true }
                                                nowSyncing = false
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
