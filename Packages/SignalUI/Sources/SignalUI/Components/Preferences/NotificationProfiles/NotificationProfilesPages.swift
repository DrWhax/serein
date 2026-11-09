// Port of ts/components/PreferencesNotificationProfiles.dom.tsx: Settings → Notifications →
// Notification profiles.
//   NotificationProfilesHome        the list (create, each profile, sync with other devices)
//                                   and, per profile, the edit page (name, on / off now,
//                                   allowed chats, schedule, exceptions, delete) with its name
//                                   and schedule sub-pages
//   NotificationProfilesCreateFlow  name → allowed chats and exceptions → schedule → done
// Pages share the legacy Preferences title bar, a centred column (max 798px) and a bottom-end
// button bar. Upstream has no Storybook stories for these pages (only the onboarding dialog),
// so they follow the TSX and its Tailwind classes directly.

import SignalI18n
import SwiftUI

/// `NotificationProfileType` as the pages need it (`allowedMembers`: conversation ids).
public struct NotificationProfileData: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var emoji: String?
    /// 0xAARRGGBB.
    public var color: UInt32
    public var allowAllCalls: Bool
    public var allowAllMentions: Bool
    public var allowedMembers: [String]
    public var scheduleEnabled: Bool
    /// HHMM.
    public var scheduleStartTime: Int?
    public var scheduleEndTime: Int?
    /// DayOfWeek (1 Monday … 7 Sunday) → on.
    public var scheduleDaysEnabled: [Int: Bool]?

    public init(id: String = "", name: String, emoji: String? = nil, color: UInt32, allowAllCalls: Bool = NotificationProfileDefaults.allowCalls,
                allowAllMentions: Bool = NotificationProfileDefaults.allowMentions, allowedMembers: [String] = [],
                scheduleEnabled: Bool = NotificationProfileDefaults.enabled, scheduleStartTime: Int? = NotificationProfileDefaults.start,
                scheduleEndTime: Int? = NotificationProfileDefaults.end, scheduleDaysEnabled: [Int: Bool]? = NotificationProfileDefaults.weekdays) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.color = color
        self.allowAllCalls = allowAllCalls
        self.allowAllMentions = allowAllMentions
        self.allowedMembers = allowedMembers
        self.scheduleEnabled = scheduleEnabled
        self.scheduleStartTime = scheduleStartTime
        self.scheduleEndTime = scheduleEndTime
        self.scheduleDaysEnabled = scheduleDaysEnabled
    }
}

public enum NotificationProfileDefaults {
    public static let allowCalls = true
    public static let allowMentions = false
    public static let enabled = false
    public static let start = 900          // NINE_AM
    public static let end = 1700           // FIVE_PM
    public static let weekdays: [Int: Bool] = [1: true, 2: true, 3: true, 4: true, 5: true, 6: false, 7: false]
    public static let weekends: [Int: Bool] = [1: false, 2: false, 3: false, 4: false, 5: false, 6: true, 7: true]
    public static let daily: [Int: Bool] = [1: true, 2: true, 3: true, 4: true, 5: true, 6: true, 7: true]

    /// `getRandomColor`: a random avatar colour's background, opaque.
    public static func randomColor() -> UInt32 {
        let name = AxoTokens.Avatar.allColorNames.randomElement() ?? "A100"
        let bg = AxoTokens.Avatar.colorValues(name).bg
        func c(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return 0xFF00_0000 | c(bg.r) << 16 | c(bg.g) << 8 | c(bg.b)
    }
}

public struct NotificationProfilesActions {
    /// Back to Settings → Notifications.
    public var onBackToNotifications: () -> Void = {}
    public var onOpenCreateFlow: () -> Void = {}
    /// The create flow's back (from its first page) and Done: to the profiles list.
    public var onOpenHome: () -> Void = {}
    public var createProfile: (NotificationProfileData) -> Void = { _ in }
    public var updateProfile: (NotificationProfileData) -> Void = { _ in }
    public var markProfileDeleted: (String) -> Void = { _ in }
    public var setProfileOverride: (_ id: String, _ enabled: Bool) -> Void = { _, _ in }
    public var setIsSyncEnabled: (Bool) -> Void = { _ in }
    public var setHasOnboardingBeenSeen: (Bool) -> Void = { _ in }
    public init() {}
}

// MARK: - Home

public struct NotificationProfilesHome: View {
    enum Page { case list, edit, name, schedule }

    let activeProfileId: String?
    let allProfiles: [NotificationProfileData]
    let conversations: [SearchableConversation]
    let conversationSelector: (String) -> SelectedChatPill
    let doWeHaveOtherDevices: Bool
    let hasOnboardingBeenSeen: Bool
    let isSyncEnabled: Bool
    let actions: NotificationProfilesActions
    @State private var page = Page.list
    @State private var profileId: String?
    @State private var showingOnboarding = false
    @Environment(\.i18n) var i18n

    public init(activeProfileId: String?, allProfiles: [NotificationProfileData], conversations: [SearchableConversation],
                conversationSelector: @escaping (String) -> SelectedChatPill, doWeHaveOtherDevices: Bool, hasOnboardingBeenSeen: Bool,
                isSyncEnabled: Bool, actions: NotificationProfilesActions) {
        self.activeProfileId = activeProfileId
        self.allProfiles = allProfiles
        self.conversations = conversations
        self.conversationSelector = conversationSelector
        self.doWeHaveOtherDevices = doWeHaveOtherDevices
        self.hasOnboardingBeenSeen = hasOnboardingBeenSeen
        self.isSyncEnabled = isSyncEnabled
        self.actions = actions
    }

    var profile: NotificationProfileData? { allProfiles.first { $0.id == profileId } }

    public var body: some View {
        Group {
            switch page {
            case .list: list
            case .edit:
                if let profile { edit(profile) } else { list }
            case .name:
                if let profile {
                    NotificationProfilesNamePage(initialName: profile.name, initialEmoji: profile.emoji, isEditing: true,
                                                 onBack: { page = .edit }, onNext: { page = .edit }) { name, emoji in
                        var p = profile
                        p.name = name
                        p.emoji = emoji
                        actions.updateProfile(p)
                    }
                } else { list }
            case .schedule:
                if let profile {
                    NotificationProfilesSchedulePage(
                        isEnabled: Binding(get: { profile.scheduleEnabled }, set: { v in update { $0.scheduleEnabled = v } }),
                        scheduleDays: Binding(get: { profile.scheduleDaysEnabled ?? NotificationProfileDefaults.weekdays },
                                              set: { v in update { $0.scheduleDaysEnabled = v } }),
                        startTime: Binding(get: { profile.scheduleStartTime ?? NotificationProfileDefaults.start },
                                           set: { v in update { $0.scheduleStartTime = v } }),
                        endTime: Binding(get: { profile.scheduleEndTime ?? NotificationProfileDefaults.end }, set: { v in update { $0.scheduleEndTime = v } }),
                        isEditing: true, onBack: { page = .edit }, onNext: { page = .edit })
                } else { list }
            }
        }
        .onAppear {
            // The onboarding dialog the first time, if there are no profiles yet.
            if !hasOnboardingBeenSeen {
                if allProfiles.isEmpty { showingOnboarding = true } else { actions.setHasOnboardingBeenSeen(true) }
            }
        }
        .onChange(of: allProfiles) {
            // The profile being edited went (deleted elsewhere): back to the list.
            if page != .list, profile == nil { page = .list }
        }
        .overlay {
            if showingOnboarding {
                AxoBaseDialog.Host {
                    NotificationProfilesOnboardingDialog {
                        actions.setHasOnboardingBeenSeen(true)
                        showingOnboarding = false
                    }
                }
            }
        }
    }

    func update(_ change: (inout NotificationProfileData) -> Void) {
        guard var p = profile else { return }
        change(&p)
        actions.updateProfile(p)
    }

    var list: some View {
        ProfilesPage(title: i18n("icu:NotificationProfiles--title"), onBack: actions.onBackToNotifications) {
            ProfilesRow { CSSText(i18n("icu:NotificationProfiles--list--header"), type: .titleSmall, color: .labelPrimary) }
                .frame(minHeight: 40, alignment: .bottom)
                .padding(.top, 12)
            ProfilesButton(minHeight: 52, action: actions.onOpenCreateFlow) {
                PlusIconInCircle()
                CSSText(i18n("icu:NotificationProfiles--create"), type: .bodyLarge, color: .labelPrimary)
            }
            ForEach(allProfiles) { p in
                ProfilesButton(minHeight: 52, action: {
                    profileId = p.id
                    page = .edit
                }) {
                    NotificationProfileAvatar(emoji: p.emoji, color: p.color, size: .medium)
                    CSSText(p.name, type: .bodyLarge, color: .labelPrimary).padding(.leading, 16)
                }
            }
            if doWeHaveOtherDevices {
                ProfilesDivider()
                ProfilesRow {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(alignment: .leading, spacing: 4) {
                            CSSText(i18n("icu:NotificationProfiles--list--sync"), type: .bodyLarge, color: .labelPrimary)
                            CSSText(i18n("icu:NotificationProfiles--list--sync--description"), type: .bodySmall, color: .labelSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        AxoSwitch.Root(checked: Binding(get: { isSyncEnabled }, set: { actions.setIsSyncEnabled($0) }))
                            .padding(.leading, 16)
                    }
                }
                .frame(minHeight: 40, alignment: .top)
                .padding(.top, 4)
            }
        }
    }

    func edit(_ profile: NotificationProfileData) -> some View {
        NotificationProfilesEditPage(profile: profile, isActive: activeProfileId == profile.id, conversations: conversations,
                                     conversationSelector: conversationSelector, onBack: { page = .list },
                                     onDeleteProfile: {
                                         actions.markProfileDeleted(profile.id)
                                         page = .list
                                     },
                                     onEditName: { page = .name }, onEditSchedule: { page = .schedule },
                                     onEditProfile: actions.updateProfile,
                                     onUpdateOverrideState: { actions.setProfileOverride(profile.id, $0) })
    }
}

// MARK: - Create flow

public struct NotificationProfilesCreateFlow: View {
    enum Page { case name, allowed, schedule, done }

    let conversations: [SearchableConversation]
    let conversationSelector: (String) -> SelectedChatPill
    let actions: NotificationProfilesActions
    @State private var page = Page.name
    @State private var draft = NotificationProfileData(name: "", color: NotificationProfileDefaults.randomColor())
    @State private var confirmDiscard = false
    @Environment(\.i18n) var i18n

    public init(conversations: [SearchableConversation], conversationSelector: @escaping (String) -> SelectedChatPill,
                actions: NotificationProfilesActions) {
        self.conversations = conversations
        self.conversationSelector = conversationSelector
        self.actions = actions
    }

    public var body: some View {
        Group {
            switch page {
            case .name:
                NotificationProfilesNamePage(initialName: draft.name, initialEmoji: draft.emoji, isEditing: false,
                                             onBack: tryClose, onNext: { page = .allowed }) { name, emoji in
                    draft.name = name
                    draft.emoji = emoji
                }
            case .allowed:
                ProfilesPage(title: nil, onBack: { page = .name }) {
                    ProfilesTitle(i18n("icu:NotificationProfiles--allowed-title"))
                    CSSText(i18n("icu:NotificationProfiles--allowed-description"), type: .bodyMedium, alignment: .center, color: .labelPrimary)
                        .frame(maxWidth: 335)
                        .padding(.top, 16).padding(.bottom, 52)          // mt-4 mb-13
                    AllowedMembersSection(allowedMembers: $draft.allowedMembers, conversations: conversations,
                                          conversationSelector: conversationSelector, title: i18n("icu:NotificationProfiles--allowed-title"))
                    ExceptionsSection(allowAllCalls: $draft.allowAllCalls, allowAllMentions: $draft.allowAllMentions)
                } buttons: {
                    AxoButton.Root(i18n("icu:next2"), variant: .strongPrimary, size: .lg) { page = .schedule }
                }
            case .schedule:
                NotificationProfilesSchedulePage(
                    isEnabled: $draft.scheduleEnabled,
                    scheduleDays: Binding(get: { draft.scheduleDaysEnabled ?? NotificationProfileDefaults.weekdays }, set: { draft.scheduleDaysEnabled = $0 }),
                    startTime: Binding(get: { draft.scheduleStartTime ?? NotificationProfileDefaults.start }, set: { draft.scheduleStartTime = $0 }),
                    endTime: Binding(get: { draft.scheduleEndTime ?? NotificationProfileDefaults.end }, set: { draft.scheduleEndTime = $0 }),
                    isEditing: false, onBack: { page = .allowed }, onNext: {
                        actions.createProfile(draft)
                        page = .done
                    })
            case .done:
                done
            }
        }
        .overlay {
            if confirmDiscard {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:ConfirmDiscardDialog--discard")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmDiscard = false }
                        AxoConfirmDialog.Action(i18n("icu:discard"), variant: .strongDestructive) {
                            confirmDiscard = false
                            actions.onOpenHome()
                        }
                    }
                }
            }
        }
    }

    /// `useConfirmDiscard`: leaving with a name or emoji typed asks first.
    func tryClose() {
        if page != .done && (!draft.name.isEmpty || draft.emoji != nil) { confirmDiscard = true } else { actions.onOpenHome() }
    }

    /// `NotificationProfilesDonePage`: the avatar, title and description floating 40% down.
    var done: some View {
        VStack(spacing: 0) {
            ProfilesHeader(title: nil, onBack: nil)
            GeometryReader { geo in
                VStack(spacing: 0) {
                    NotificationProfileAvatar(emoji: draft.emoji, color: draft.color, size: .large).padding(.bottom, 16)
                    ProfilesTitle(i18n("icu:NotificationProfiles--done-title"))
                    CSSText(i18n("icu:NotificationProfiles--done-description"), type: .bodyMedium, alignment: .center, color: .labelPrimary)
                        .frame(maxWidth: 350)
                        .padding(.top, 16).padding(.bottom, 24)
                    AxoButton.Root(i18n("icu:done"), variant: .strongPrimary, size: .lg, action: actions.onOpenHome)
                }
                .padding(.horizontal, 16)
                .frame(width: geo.size.width)
                .alignmentGuide(.top) { d in d.height * 0.4 }       // translateY(-40%)
                .position(x: geo.size.width / 2, y: geo.size.height * 0.4)
            }
        }
    }
}

// MARK: - Pages

/// `NotificationProfilesNamePage`: the name (with its emoji picker) and five sample names.
struct NotificationProfilesNamePage: View {
    let isEditing: Bool
    let onBack: () -> Void
    let onNext: () -> Void
    let onUpdate: (String, String?) -> Void
    @State private var name: String
    @State private var emoji: String?
    @State private var pickerOpen = false
    @Environment(\.i18n) var i18n

    init(initialName: String, initialEmoji: String?, isEditing: Bool, onBack: @escaping () -> Void, onNext: @escaping () -> Void,
         onUpdate: @escaping (String, String?) -> Void) {
        _name = State(initialValue: initialName)
        _emoji = State(initialValue: initialEmoji)
        self.isEditing = isEditing
        self.onBack = onBack
        self.onNext = onNext
        self.onUpdate = onUpdate
    }

    var samples: [(emoji: String, text: String)] {
        [("💪", i18n("icu:NotificationProfiles--sample-name__work")), ("😴", i18n("icu:NotificationProfiles--sample-name__sleep")),
         ("🚗", i18n("icu:NotificationProfiles--sample-name__driving")), ("😊", i18n("icu:NotificationProfiles--sample-name__downtime")),
         ("💡", i18n("icu:NotificationProfiles--sample-name__focus"))]
    }

    var body: some View {
        ProfilesPage(title: isEditing ? i18n("icu:NotificationProfiles--name-title--editing") : nil, onBack: onBack) {
            if !isEditing { ProfilesTitle(i18n("icu:NotificationProfiles--name-title")) }
            VStack(spacing: 0) {
                Input(value: Binding(get: { name }, set: { new in
                          name = new
                          if new.isEmpty { emoji = nil } else { onUpdate(new, emoji) }
                      }),
                      placeholder: i18n("icu:NotificationProfiles--name-placeholder"), clearLabel: i18n("icu:cancel"), expandable: true,
                      hasClearButton: true, maxByteCount: 512, maxLengthCount: 140, whenToShowRemainingCount: 40,
                      icon: AnyView(FunEmojiPickerButton(isOpen: $pickerOpen, picker: AnyView(FunEmojiPicker(panel: FunPanelEmojis(recentEmojis: [],
                          onSelectEmoji: { e in
                              emoji = e
                              pickerOpen = false
                              if !name.isEmpty { onUpdate(name, e) }
                          }))))
                          .overlay { if let emoji { Text(emoji).font(.system(size: 20)).allowsHitTesting(false) } }))
                VStack(spacing: 0) {
                    ForEach(samples, id: \.text) { item in
                        ProfilesButton(minHeight: 52, leading: 16 - 4, trailing: 12, action: {
                            name = item.text
                            emoji = item.emoji
                            onUpdate(item.text, item.emoji)
                        }) {
                            Text(item.emoji).font(.system(size: 24)).frame(width: 24, height: 24)
                            CSSText(item.text, type: .bodyLarge, color: .labelPrimary).padding(.leading, 16)
                        }
                    }
                }
                .frame(maxWidth: 320)
            }
            .padding(.top, 36)                                       // mt-9
        } buttons: {
            AxoButton.Root(i18n(isEditing ? "icu:done" : "icu:next2"), variant: .strongPrimary, size: .lg, disabled: name.isEmpty, action: onNext)
        }
    }
}

/// `NotificationProfilesSchedulePage`: on / off, from and until, and the days.
struct NotificationProfilesSchedulePage: View {
    @Binding var isEnabled: Bool
    @Binding var scheduleDays: [Int: Bool]
    @Binding var startTime: Int
    @Binding var endTime: Int
    let isEditing: Bool
    let onBack: () -> Void
    let onNext: () -> Void
    @Environment(\.i18n) var i18n

    /// Sunday first, as upstream's `daysInUIOrder`.
    var days: [(day: Int, label: String)] {
        [(7, "sunday"), (1, "monday"), (2, "tuesday"), (3, "wednesday"), (4, "thursday"), (5, "friday"), (6, "saturday")].map {
            ($0.0, i18n("icu:NotificationProfiles--schedule-\($0.1)"))
        }
    }

    var body: some View {
        ProfilesPage(title: isEditing ? i18n("icu:NotificationProfiles--schedule-title--editing") : nil, onBack: onBack) {
            if !isEditing {
                ProfilesTitle(i18n("icu:NotificationProfiles--schedule-title"))
                ProfilesRow {
                    CSSText(i18n("icu:NotificationProfiles--schedule-description"), type: .bodyMedium, alignment: .center, color: .labelPrimary)
                        .frame(maxWidth: 335)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 8).padding(.bottom, 16)
            }
            ProfilesRow {
                HStack(spacing: 0) {
                    CSSText(i18n("icu:NotificationProfiles--schedule-enable"), type: .bodyLarge, color: .labelPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AxoSwitch.Root(checked: $isEnabled).padding(.leading, 16)
                }
            }
            .frame(minHeight: 40)
            .padding(.vertical, 8)
            .padding(.top, 16)
            ProfilesRow { CSSText(i18n("icu:NotificationProfiles--schedule"), type: .titleSmall, color: .labelPrimary) }
                .frame(minHeight: 40, alignment: .leading)
                .padding(.top, 12 + 12).padding(.bottom, 8)
            timeRow(i18n("icu:NotificationProfiles--schedule-from"), $startTime)
            timeRow(i18n("icu:NotificationProfiles--schedule-until"), $endTime)
            ProfilesRow {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(days, id: \.day) { d in
                        Checkbox(label: d.label, name: "dayEnabled-\(d.day)", checked: scheduleDays[d.day] == true, disabled: !isEnabled) { on in
                            var days = scheduleDays
                            days[d.day] = on
                            scheduleDays = days
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(.top, 12)
        } buttons: {
            AxoButton.Root(i18n(isEditing ? "icu:done" : "icu:next2"), variant: .strongPrimary, size: .lg, action: onNext)
        }
    }

    func timeRow(_ label: String, _ time: Binding<Int>) -> some View {
        ProfilesRow {
            HStack(spacing: 0) {
                CSSText(label, type: .bodyMedium, color: .labelPrimary).frame(maxWidth: .infinity, alignment: .leading)
                TimePicker(time: time, disabled: !isEnabled, label: label)
            }
        }
        .frame(minHeight: 40)
    }
}

/// `NotificationProfilesEditPage`.
struct NotificationProfilesEditPage: View {
    let profile: NotificationProfileData
    let isActive: Bool
    let conversations: [SearchableConversation]
    let conversationSelector: (String) -> SelectedChatPill
    let onBack: () -> Void
    let onDeleteProfile: () -> Void
    let onEditName: () -> Void
    let onEditSchedule: () -> Void
    let onEditProfile: (NotificationProfileData) -> Void
    let onUpdateOverrideState: (Bool) -> Void
    @State private var confirmingDelete = false
    @State private var nameHovered = false
    @Environment(\.i18n) var i18n

    var body: some View {
        let active = i18n("icu:NotificationProfiles--edit--is-active")
        let notActive = i18n("icu:NotificationProfiles--edit--is-not-active")
        ProfilesPage(title: profile.name, onBack: onBack) {
            HStack(spacing: 0) {
                Button(action: onEditName) {
                    HStack(spacing: 0) {
                        NotificationProfileAvatar(emoji: profile.emoji, color: profile.color, size: .medium)
                        CSSText(profile.name, type: .bodyMedium, color: .labelPrimary).padding(.leading, 12)
                        AxoSymbol.Icon("pencil", size: 20, label: i18n("icu:NotificationProfiles--edit--edit-name-label"))
                            .padding(.leading, 8)
                            .opacity(nameHovered ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { nameHovered = $0 }
                Spacer(minLength: 0)
                AxoSelect.Root(label: nil, value: Binding(get: { isActive ? active : notActive }, set: { v in
                    if let v { onUpdateOverrideState(v == active) }
                })) {
                    AxoSelect.Trigger(placeholder: "")
                    AxoSelect.Content {
                        AxoSelect.Item(value: active) { AxoSelect.ItemText(active) }
                        AxoSelect.Item(value: notActive) { AxoSelect.ItemText(notActive) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 80)
            .padding(.bottom, 12)
            AllowedMembersSection(allowedMembers: Binding(get: { profile.allowedMembers }, set: { m in
                                      var p = profile
                                      p.allowedMembers = m
                                      onEditProfile(p)
                                  }),
                                  conversations: conversations, conversationSelector: conversationSelector,
                                  title: i18n("icu:NotificationProfiles--edit--allowed"))
            ProfilesRow { CSSText(i18n("icu:NotificationProfiles--schedule"), type: .titleSmall, color: .labelPrimary) }
                .padding(.top, 32).padding(.bottom, 8)
            ProfilesButton(minHeight: 55, vertical: 8, action: onEditSchedule) {
                VStack(alignment: .leading, spacing: 2) {
                    CSSText(i18n("icu:NotificationProfiles--edit--schedule-timing",
                                 ["startTime": .string(Self.formatTime(profile.scheduleStartTime ?? NotificationProfileDefaults.start)),
                                  "endTime": .string(Self.formatTime(profile.scheduleEndTime ?? NotificationProfileDefaults.end))]),
                            type: .bodyMedium, color: .labelPrimary)
                    CSSText(Self.scheduleSummary(profile.scheduleDaysEnabled ?? NotificationProfileDefaults.weekdays, i18n), type: .bodySmall,
                            color: .labelSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CSSText(i18n(profile.scheduleEnabled ? "icu:NotificationProfiles--edit--schedule-enabled" : "icu:NotificationProfiles--edit--schedule-disabled"),
                        type: .bodyMedium, color: .labelPrimary)
                    .padding(.leading, 20)
            }
            ExceptionsSection(allowAllCalls: Binding(get: { profile.allowAllCalls }, set: { v in
                                  var p = profile
                                  p.allowAllCalls = v
                                  onEditProfile(p)
                              }),
                              allowAllMentions: Binding(get: { profile.allowAllMentions }, set: { v in
                                  var p = profile
                                  p.allowAllMentions = v
                                  onEditProfile(p)
                              }))
            ProfilesButton(minHeight: 52, action: { confirmingDelete = true }) {
                AxoSymbol.Icon("trash", size: 24, label: nil).cssTextColor(.labelDestructive).padding(.trailing, 16)
                CSSText(i18n("icu:NotificationProfiles--delete"), type: .bodyMedium, color: .labelDestructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 24)
        } buttons: {
            AxoButton.Root(i18n("icu:done"), variant: .strongPrimary, size: .lg, action: onBack)
        }
        .overlay {
            if confirmingDelete {
                AxoBaseDialog.Host {
                    AxoConfirmDialog.Root(title: nil, description: i18n("icu:NotificationProfiles--delete-confirmation")) {
                        AxoConfirmDialog.Cancel(i18n("icu:cancel")) { confirmingDelete = false }
                        AxoConfirmDialog.Action(i18n("icu:NotificationProfiles--delete-button"), variant: .strongDestructive) {
                            confirmingDelete = false
                            onDeleteProfile()
                        }
                    }
                }
            }
        }
    }

    /// `formatTimeForDisplay`: the HHMM time today, `timeStyle: short`.
    static func formatTime(_ hhmm: Int) -> String {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = hhmm / 100
        c.minute = hhmm % 100
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// `ScheduleSummary`: weekdays / weekends / daily, else the short day names (Sunday first).
    static func scheduleSummary(_ days: [Int: Bool], _ i18n: Localizer) -> String {
        func normalized(_ d: [Int: Bool]) -> [Int: Bool] { Dictionary(uniqueKeysWithValues: (1...7).map { ($0, d[$0] == true) }) }
        let n = normalized(days)
        if n == NotificationProfileDefaults.weekdays { return i18n("icu:NotificationProfiles--schedule-weekdays") }
        if n == NotificationProfileDefaults.weekends { return i18n("icu:NotificationProfiles--schedule-weekends") }
        if n == NotificationProfileDefaults.daily { return i18n("icu:NotificationProfiles--schedule-daily") }
        let order = [(7, "sunday"), (1, "monday"), (2, "tuesday"), (3, "wednesday"), (4, "thursday"), (5, "friday"), (6, "saturday")]
        return order.filter { n[$0.0] == true }.map { i18n("icu:NotificationProfiles--schedule-\($0.1)-short") }
            .joined(separator: i18n("icu:NotificationProfiles--schedule-separator"))
    }
}

// MARK: - Sections

/// `AllowedMembersSection`: "Add people or groups" (the chat chooser) and the chosen chats.
struct AllowedMembersSection: View {
    @Binding var allowedMembers: [String]
    let conversations: [SearchableConversation]
    let conversationSelector: (String) -> SelectedChatPill
    let title: String
    @State private var choosing = false
    @Environment(\.i18n) var i18n

    var body: some View {
        ProfilesRow { CSSText(title, type: .titleSmall, color: .labelPrimary) }.padding(.bottom, 4)
        ProfilesButton(minHeight: 52, action: { choosing = true }) {
            PlusIconInCircle()
            CSSText(i18n("icu:NotificationProfiles--allowed-add-label"), type: .bodyLarge, color: .labelPrimary)
        }
        ForEach(allowedMembers, id: \.self) { id in
            let pill = conversationSelector(id)
            ProfilesButton(minHeight: 52, action: { choosing = true }) {
                Avatar(strings: AvatarStrings(i18n: i18n), title: pill.data.title, size: 36,
                       conversationType: pill.data.type == .group ? .group : .direct, color: pill.data.avatar.color ?? "A200",
                       image: pill.data.avatar.image.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: pill.data.avatar.image != nil)
                    .padding(.trailing, 12)
                CSSText(pill.data.title, type: .bodyLarge, color: .labelPrimary)
            }
        }
        .viewportPortal {
            if choosing {
                AxoBaseDialog.Host {
                    PreferencesSelectChatsDialog(title: i18n("icu:NotificationProfiles--allowed-title"), conversations: conversations,
                                                 conversationSelector: conversationSelector,
                                                 initialSelection: ChatFolderSelection(selectedRecipientIds: allowedMembers)) { s in
                        allowedMembers = s.selectedRecipientIds
                        choosing = false
                    }
                }
            }
        }
    }
}

/// `ExceptionsSection`: allow all calls, notify for all mentions.
struct ExceptionsSection: View {
    @Binding var allowAllCalls: Bool
    @Binding var allowAllMentions: Bool
    @Environment(\.i18n) var i18n

    var body: some View {
        ProfilesRow { CSSText(i18n("icu:NotificationProfiles--exceptions"), type: .titleSmall, color: .labelPrimary) }
            .padding(.top, 32).padding(.bottom, 4)
        toggle(i18n("icu:NotificationProfiles--exceptions--allow-all-calls"), $allowAllCalls)
        toggle(i18n("icu:NotificationProfiles--exceptions--notify-for-mentions"), $allowAllMentions)
    }

    func toggle(_ label: String, _ value: Binding<Bool>) -> some View {
        ProfilesRow {
            HStack(spacing: 0) {
                CSSText(label, type: .bodyLarge, color: .labelPrimary).frame(maxWidth: .infinity, alignment: .leading)
                AxoSwitch.Root(checked: value).padding(.leading, 16)
            }
        }
        .frame(minHeight: 40)
    }
}

// MARK: - Layout helpers

/// `Header` + `Container` + `ButtonContainer`.
struct ProfilesPage<Content: View, Buttons: View>: View {
    let title: String?
    let onBack: (() -> Void)?
    let content: Content
    let buttons: Buttons

    init(title: String?, onBack: (() -> Void)?, @ViewBuilder content: () -> Content, @ViewBuilder buttons: () -> Buttons = { EmptyView() }) {
        self.title = title
        self.onBack = onBack
        self.content = content()
        self.buttons = buttons()
    }

    var body: some View {
        VStack(spacing: 0) {
            ProfilesHeader(title: title, onBack: onBack)
            AxoDialog.AxoScrollContainer {
                VStack(spacing: 0) { content }
                    .padding(.horizontal, 10)                        // px-[10px]
                    .frame(maxWidth: 798)
                    .frame(maxWidth: .infinity)
            }
            if Buttons.self != EmptyView.self {
                HStack(spacing: 0) { buttons }
                    .padding(24).padding(.trailing, 33 - 24)         // p-6 pe-[33px]
                    .frame(maxWidth: 798, alignment: .trailing)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// `.Preferences__title`: 52px, the title centred (body-1 bold) and the back chevron.
struct ProfilesHeader: View {
    let title: String?
    let onBack: (() -> Void)?
    @Environment(\.titleBarDragAreaHeight) var dragAreaHeight
    @Environment(\.i18n) var i18n

    var body: some View {
        ZStack(alignment: .leading) {
            CSSText(title ?? "", style: LegacyType.body1(weight: 700), alignment: .center, color: .labelPrimary)
                .frame(maxWidth: .infinity)
                .padding(.trailing, onBack == nil ? 0 : 32)
                .accessibilityAddTraits(.isHeader)
            if let onBack { PreferencesBackButton(label: i18n("icu:goBack"), action: onBack) }
        }
        .frame(height: 52)
        .padding(.top, dragAreaHeight)
    }
}

/// `Title`: type-title-medium.
struct ProfilesTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { CSSText(text, type: .titleMedium, alignment: .center, color: .labelPrimary).accessibilityAddTraits(.isHeader) }
}

/// `FullWidthRow`: full width, 14px inline padding.
struct ProfilesRow<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View { content.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14) }
}

/// `FullWidthDivider`: a 0.5px border-primary rule, 12px above and below.
struct ProfilesDivider: View {
    var body: some View {
        Rectangle().fill(AxoColor.borderPrimary).frame(height: 0.5).padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// `FullWidthButton`: a full-width row button (2.5px transparent border + 11.5px padding:
/// 14px to the content), rounded-md.
struct ProfilesButton<Content: View>: View {
    let minHeight: CGFloat
    var leading: CGFloat = 14
    var trailing: CGFloat = 14
    var vertical: CGFloat = 0
    let action: () -> Void
    let content: Content

    init(minHeight: CGFloat, leading: CGFloat = 14, trailing: CGFloat = 14, vertical: CGFloat = 0, action: @escaping () -> Void,
         @ViewBuilder content: () -> Content) {
        self.minHeight = minHeight
        self.leading = leading
        self.trailing = trailing
        self.vertical = vertical
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .padding(.leading, leading).padding(.trailing, trailing).padding(.vertical, vertical)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// `PlusIconInCircle`: a 36px surface-secondary circle with the plus, 12px before the label.
struct PlusIconInCircle: View {
    var body: some View {
        AxoSymbol.Icon("plus", size: 20, label: nil)
            .frame(width: 36, height: 36)
            .background(Circle().fill(AxoColor.surfaceSecondary))
            .padding(.trailing, 12)
    }
}
