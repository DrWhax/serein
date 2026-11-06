// The Stories tab over SignalCore's story feed (upstream SmartStories / SmartStoryViewer /
// SmartStoryCreator / SmartSendStoryModal): stories grouped by sender or group, My Stories by
// list, a viewer that advances every five seconds and marks stories viewed, the text-story
// creator and media stories, and the send modal to pick lists and groups.

import Foundation
import SignalCore
import SignalI18n
import SignalUI
import SwiftUI

struct StoriesScreen: View {
    @Bindable var model: AppModel
    @Bindable var session: SignalSession
    let i18n: Localizer

    /// The stories open in the viewer and the current one.
    @State private var viewing: [StoryFeedItem] = []
    @State private var index = 0
    @State private var progress = 0.0
    @State private var paused = false
    @State private var creatingText = false
    /// A finished draft waiting for its audience (the send modal).
    @State private var draft: StoryDraft?

    enum StoryDraft {
        case text(TextAttachmentData)
        case media(SignalSession.StagedAttachment)
    }

    static let storyDuration = 5.0

    var body: some View {
        StoriesTab(me: me, myStories: myStories, stories: incoming, hiddenStories: [], hasViewReceiptSetting: session.accountSettings.readReceipts,
                   preferredLeftPaneWidth: model.preferredLeftPaneWidth, navTabsCollapsed: model.navTabsCollapsed, isCreatingStory: creatingText,
                   actions: actions) {
            TextStoryCreator(onClose: { creatingText = false }, onDone: { t in
                creatingText = false
                draft = .text(t)
            })
        }
        .overlay { viewer }
        .overlay { sendModal }
    }

    // MARK: data

    func conversation(for serviceId: String) -> StoryConversation {
        if serviceId == session.ourAci {
            let mine = session.contacts[serviceId]
            return StoryConversation(id: serviceId, title: i18n("icu:you"), color: mine?.color ?? "A200", avatar: session.avatarImage(mine?.avatar))
        }
        let c = session.contacts[serviceId]
        let title = c?.title ?? i18n("icu:unknownContact")
        return StoryConversation(id: serviceId, title: title, firstName: title.split(separator: " ").first.map(String.init),
                                 color: c?.color ?? "A200", avatar: session.avatarImage(c?.avatar))
    }

    func group(_ id: String?) -> StoryConversation? {
        guard let id, let c = session.conversation(id) else { return nil }
        return StoryConversation(id: id, title: c.title, color: c.color, avatar: session.avatarImage(c.avatar))
    }

    var me: StoryConversation { conversation(for: session.ourAci ?? "") }

    func attachment(_ item: StoryFeedItem) -> StoryAttachmentData? {
        if let t = item.text {
            var data = TextAttachmentData(text: t.text, textStyle: TextAttachmentStyle(rawValue: t.textStyle), textForegroundColor: t.textForegroundColor,
                                          textBackgroundColor: t.textBackgroundColor, color: t.color)
            if !t.gradientColors.isEmpty {
                data.gradient = StoryGradient(angle: Double(t.gradientAngle ?? 0), startColor: t.gradientColors.first, endColor: t.gradientColors.last,
                                              colors: t.gradientColors, positions: t.gradientPositions.isEmpty ? nil : t.gradientPositions.map(Double.init))
            }
            return StoryAttachmentData(contentType: "text/x-signal-story", textAttachment: data, width: nil, height: nil)
        }
        guard let a = item.media else { return nil }
        let image = session.image(for: a)
        return StoryAttachmentData(contentType: a.contentType, image: image, thumbnail: image, width: a.width, height: a.height,
                                   isNotResolved: !a.isDownloaded, pending: a.pending ?? false)
    }

    func view(_ item: StoryFeedItem) -> StoryViewData {
        let status: StorySendStatus = item.sendStatuses.contains("Failed")
            ? (item.sendStatuses.allSatisfy { $0 == "Failed" } ? .failed : .partiallySent)
            : item.sendStatuses.contains("Pending") ? .sending : .sent
        return StoryViewData(messageId: item.id, sender: conversation(for: item.author), attachment: attachment(item), isUnread: item.isUnread,
                             timestamp: Date(milliseconds: item.sentAt), sendStatus: status, views: item.isOutgoing ? item.views : nil,
                             hasLocalFile: item.media?.isDownloaded ?? (item.text != nil))
    }

    /// Incoming stories: one row per sender (or group), its newest story; unread first upstream.
    var incomingGroups: [(key: String, items: [StoryFeedItem])] {
        var order: [String] = []
        var byKey: [String: [StoryFeedItem]] = [:]
        for item in session.stories where !item.isOutgoing {
            let key = item.groupConversationId ?? item.author
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.map { ($0, byKey[$0] ?? []) }
    }

    var incoming: [ConversationStoryData] {
        incomingGroups.compactMap { key, items in
            guard let newest = items.first else { return nil }
            var v = view(newest)
            v.isUnread = items.contains { $0.isUnread }
            return ConversationStoryData(conversationId: key, group: group(newest.groupConversationId), storyView: v)
        }
    }

    var myStories: [MyStoryList] {
        var order: [String] = []
        var byKey: [String: [StoryFeedItem]] = [:]
        for item in session.stories where item.isOutgoing {
            let key = item.groupConversationId ?? item.distributionListId ?? StoryStore.myStoryId
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order.map { key in
            let name = key == StoryStore.myStoryId ? i18n("icu:Stories__mine")
                : group(key)?.title ?? session.storyLists.first { $0.id == key }?.name ?? ""
            return MyStoryList(id: key, name: name, stories: (byKey[key] ?? []).map(view))
        }
    }

    var actions: StoriesActions {
        var a = StoriesActions()
        a.onAddText = { creatingText = true }
        a.onAddMedia = {
            Task { if let staged = await session.pickStoryMedia() { draft = .media(staged) } }
        }
        a.viewUserStories = { key, _ in
            guard let g = incomingGroups.first(where: { $0.key == key }) else { return }
            // Oldest unread first, as upstream; else from the oldest.
            let items = Array(g.items.reversed())
            open(items, at: items.firstIndex { $0.isUnread } ?? 0)
        }
        a.viewStory = { id in
            let mine = session.stories.filter(\.isOutgoing)
            if let i = mine.firstIndex(where: { $0.id == id }) { open(Array(mine), at: i) }
        }
        a.showConversation = { id in
            model.selectedTab = .chats
            session.open(conversationId: id)
        }
        a.onToggleNavTabsCollapse = { model.navTabsCollapsed = $0 }
        a.savePreferredLeftPaneWidth = { model.preferredLeftPaneWidth = $0 }
        return a
    }

    // MARK: viewer

    func open(_ items: [StoryFeedItem], at i: Int) {
        guard !items.isEmpty else { return }
        viewing = items
        index = min(max(i, 0), items.count - 1)
        progress = 0
        paused = false
        session.markStoryViewed(items[index].id)
    }

    func close() { viewing = [] }

    func step(_ delta: Int) {
        let next = index + delta
        guard viewing.indices.contains(next) else { return close() }
        index = next
        progress = 0
        session.markStoryViewed(viewing[index].id)
    }

    @ViewBuilder var viewer: some View {
        if viewing.indices.contains(index) {
            let item = viewing[index]
            let current = session.stories.first { $0.id == item.id } ?? item
            StoryViewer(data: StoryViewerData(story: view(current), group: group(current.groupConversationId),
                                              distributionListName: session.storyLists.first { $0.id == current.distributionListId }?.name,
                                              isMe: current.isOutgoing, numStories: viewing.count, currentIndex: index, progress: progress,
                                              canReply: current.canReply && !current.isOutgoing, isGroupStory: current.groupConversationId != nil,
                                              isSent: current.isOutgoing, hasViewReceiptSetting: session.accountSettings.readReceipts,
                                              viewCount: current.views),
                        actions: {
                var a = StoryViewerActions()
                a.onClose = { close() }
                a.viewNext = { step(1) }
                a.viewPrevious = { step(-1) }
                a.setPaused = { paused = $0 }
                a.goToConversation = {
                    close()
                    model.selectedTab = .chats
                    session.open(conversationId: current.groupConversationId ?? current.conversationId)
                }
                return a
            }())
            .task(id: "\(item.id)-\(paused)") {
                // Five seconds per story (upstream DEFAULT_DURATION), then the next one.
                guard !paused else { return }
                let start = ContinuousClock.now - .milliseconds(Int(progress * Self.storyDuration * 1000))
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    let elapsed = Double((ContinuousClock.now - start).components.attoseconds) / 1e18 + Double((ContinuousClock.now - start).components.seconds)
                    progress = min(1, elapsed / Self.storyDuration)
                    if progress >= 1 { step(1); return }
                }
            }
        }
    }

    // MARK: send

    @ViewBuilder var sendModal: some View {
        if let draft {
            let attachment: StoryAttachmentData = switch draft {
            case .text(let t): StoryAttachmentData(contentType: "text/x-signal-story", textAttachment: t, width: nil, height: nil)
            case .media(let m): StoryAttachmentData(contentType: m.contentType, image: m.preview, thumbnail: m.preview, width: m.width, height: m.height)
            }
            SendStoryModal(draftAttachment: attachment, candidateConversations: candidates, distributionLists: lists, groupConversations: groups,
                           groupStories: [], ourConversationId: session.ourAci, me: ConversationAvatarData(title: me.title, color: me.color),
                           signalConnections: candidates, actions: {
                var a = SendStoryActions()
                a.onClose = { self.draft = nil }
                a.onSend = { listIds, conversationIds in
                    let content: OutgoingStoryContent = switch draft {
                    case .text(let t): .text(Self.storyText(t))
                    case .media(let m): .file(OutgoingAttachment(data: m.data, contentType: m.contentType, fileName: m.fileName))
                    }
                    session.sendStory(content, listIds: listIds, groupConversationIds: conversationIds)
                    self.draft = nil
                }
                return a
            }())
            .onAppear { session.loadComposable() }
        }
    }

    static func storyText(_ t: TextAttachmentData) -> StoryText {
        StoryText(text: t.text, textStyle: t.textStyle?.rawValue ?? 0, textForegroundColor: t.textForegroundColor, textBackgroundColor: t.textBackgroundColor,
                  color: t.color, gradientAngle: t.gradient.map { Int($0.angle) },
                  gradientColors: t.gradient.map { $0.colors ?? [$0.startColor, $0.endColor].compactMap { $0 } } ?? [],
                  gradientPositions: t.gradient?.positions?.map(Float.init) ?? [])
    }

    var candidates: [SearchableConversation] {
        session.composable.filter { $0.kind == .private }.map {
            SearchableConversation(listItem: ContactListItemData(id: $0.serviceId ?? $0.id, title: $0.title,
                                                                 avatar: ConversationAvatarData(title: $0.title, color: $0.color)))
        }
    }

    var lists: [StoryDistributionList] {
        session.storyLists.map { l in
            StoryDistributionList(id: l.id, name: l.id == StoryStore.myStoryId ? i18n("icu:Stories__mine") : l.name, allowsReplies: l.allowsReplies,
                                  isBlockList: l.isBlockList)
        }
    }

    var groups: [GroupStoryInfo] {
        session.composable.filter { $0.kind == .group }.map {
            GroupStoryInfo(id: $0.id, title: $0.title, avatar: ConversationAvatarData(title: $0.title, conversationType: .group, color: $0.color),
                           membersCount: $0.membersCount)
        }
    }
}
