// The TimelineMessage stories' message props (Fixtures/timelinemessage-stories.json): every
// <TimelineMessage> each story renders, evaluated from the story file with a recording JSX
// factory and the captures' fixed clock (functions and stubbed imports dropped).

import Foundation
import SwiftUI
@testable import SignalUI

struct StoryMessage: Decodable {
    struct Author: Decodable { var title: String?; var isMe: Bool?; var color: String?; var avatarUrl: String? }
    struct BubbleColorJSON: Decodable { var bubbleColorPreset: String? }
    struct TextAttachment: Decodable {
        var pending: Bool?; var digest: String?; var key: String?; var path: String?; var wasTooBig: Bool?; var isPermanentlyUndownloadable: Bool?
    }

    var direction: String?
    /// Inside a `module-timeline--width-wide` div (600px bubbles; else 306px).
    var _wide: Bool?
    var text: String?
    var status: String?
    var conversationType: String?
    var contactNameColor: String?
    var shouldCollapseAbove: Bool?
    var shouldCollapseBelow: Bool?
    var shouldHideMetadata: Bool?
    var expirationLength: Double?
    var expirationTimestamp: Double?
    var timestamp: Double?
    var attachments: [StoryAttachment]?
    var author: Author?
    var bubbleColor: BubbleColorJSON?
    var deletedForEveryone: Bool?
    var isTapToView: Bool?
    var isTapToViewExpired: Bool?
    var isTapToViewError: Bool?
    var isPinned: Bool?
    var isSMS: Bool?
    var isEditedMessage: Bool?
    var textAttachment: TextAttachment?
    var _forceTapToPlay: Bool?
    var attachmentDroppedDueToSize: Bool?
    struct Preview: Decodable {
        var url: String?
        var domain: String?
        var title: String?
        var description: String?
        var date: Double?
        var image: StoryAttachment?
        var isStickerPack: Bool?
        var isCallLink: Bool?
        var callLinkRoomId: String?
    }
    var previews: [Preview]?
    struct QuoteJSON: Decodable {
        var text: String?
        var authorTitle: String?
        var isFromMe: Bool?
        var referencedMessageNotFound: Bool?
        var isViewOnce: Bool?
    }
    var quote: QuoteJSON?
    var isSticker: Bool?
    struct ContactJSON: Decodable {
        struct Name: Decodable { var givenName: String?; var familyName: String? }
        struct Avatar: Decodable { var avatar: StoryAttachment? }
        struct Resolution: Decodable { var type: String? }
        var name: Name?
        var organization: String?
        var avatar: Avatar?
        var resolution: Resolution?
    }
    var contact: ContactJSON?
    var readStatus: Int?
    var isVoiceMessagePlayed: Bool?
    struct PollJSON: Decodable {
        struct Voter: Decodable { var isMe: Bool? }
        var question: String?
        var options: [String]?
        var allowMultiple: Bool?
        var terminatedAt: Double?
        var totalNumVotes: Int?
        var uniqueVoters: Int?
        var votesByOption: [String: [Voter]]?
        var pendingVoteDiff: [String: String]?
    }
    var poll: PollJSON?
    var canSendPollVote: Bool?
    var activeCallConversationId: String?
    struct StoryJSON: Decodable {
        var authorTitle: String?
        var isFromMe: Bool?
        var text: String?
        var emoji: String?
        var storyId: String?
        var rawAttachment: StoryAttachment?
    }
    var storyReplyContext: StoryJSON?
    var isSignalConversation: Bool?

    struct ReactionJSON: Decodable {
        struct From: Decodable { var isMe: Bool?; var title: String? }
        var emoji: String?
        var from: From?
        var timestamp: Double?
    }
    var reactions: [ReactionJSON]?
    var conversationTitle: String?
    struct LabelJSON: Decodable { var labelString: String?; var labelEmoji: String? }
    var contactLabel: LabelJSON?

    func props(author fallback: String = "Mattie Grady") -> MessageProps {
        var a = MessageProps.Author(id: "a", title: author?.title ?? fallback)
        a.isMe = author?.isMe ?? false
        a.color = author?.color
        a.avatar = fixtureByURL(author?.avatarUrl)
        var p = MessageProps(id: "m", direction: direction == "outgoing" ? .outgoing : .incoming, author: a, text: text,
                             timestamp: Date(timeIntervalSince1970: (timestamp ?? 1_793_793_600_000) / 1000))
        p.status = status.flatMap(MessageStatus.init(rawValue:))
        p.conversationType = conversationType == "group" ? .group : .direct
        p.contactNameColor = contactNameColor
        p.shouldCollapseAbove = shouldCollapseAbove ?? false
        p.shouldCollapseBelow = shouldCollapseBelow ?? false
        p.shouldHideMetadata = shouldHideMetadata ?? false
        p.expirationLength = (expirationLength ?? 0) / 1000
        p.expirationTimestamp = (expirationTimestamp ?? 0) > 0 ? Date(timeIntervalSince1970: expirationTimestamp! / 1000) : nil
        p.attachments = (attachments ?? []).map(\.model)
        if let preset = bubbleColor?.bubbleColorPreset { p.bubbleColor = .preset(preset) }
        p.deletedForEveryone = deletedForEveryone ?? false
        if isTapToView == true {
            p.tapToView = TapToViewState(isExpired: isTapToViewExpired ?? false, isError: isTapToViewError ?? false, isViewed: readStatus == 2)
        }
        p.isPinned = isPinned ?? false
        p.isSMS = isSMS ?? false
        p.isEdited = isEditedMessage ?? false
        if let t = textAttachment {
            p.textPending = t.pending ?? false
            p.textCanDownload = t.digest != nil && t.key != nil && t.wasTooBig != true && t.path == nil
            p.textAttachmentUndownloadable = t.isPermanentlyUndownloadable ?? false
        }
        p.attachmentDroppedDueToSize = attachmentDroppedDueToSize ?? false
        p.previews = (previews ?? []).map {
            var l = LinkPreview(url: $0.url ?? "", domain: $0.domain, title: $0.title, description: $0.description, date: $0.date,
                                image: $0.image?.model)
            l.isStickerPack = $0.isStickerPack ?? false
            l.isCallLink = $0.isCallLink ?? false
            l.callLinkRoomId = $0.callLinkRoomId
            return l
        }
        p.openLink = { _ in }
        p.isSticker = isSticker ?? false
        p.conversationTitle = conversationTitle
        p.isVoiceMessagePlayed = isVoiceMessagePlayed ?? false
        p.isSignalConversation = isSignalConversation ?? false
        p.activeCallConversationId = activeCallConversationId
        if let st = storyReplyContext {
            // The story author's seeded firstName in the captures ("Celia").
            var c = StoryReplyContext(authorTitle: st.authorTitle ?? "Celia", text: st.text)
            c.isFromMe = st.isFromMe ?? false
            c.emoji = st.emoji
            c.storyId = st.storyId
            if let a = st.rawAttachment?.model {
                c.rawAttachment = QuotedAttachment(contentType: a.contentType, fileName: a.fileName, thumbnail: a.thumbnailImage ?? a.image)
            }
            p.storyReplyContext = c
            p.viewStory = {}
        }

        if let j = poll {
            var mp = MessagePoll(question: j.question ?? "", options: j.options ?? [])
            mp.allowMultiple = j.allowMultiple ?? false
            mp.terminated = j.terminatedAt != nil
            mp.totalNumVotes = j.totalNumVotes ?? 0
            mp.uniqueVoters = j.uniqueVoters ?? 0
            for (k, v) in j.votesByOption ?? [:] { if let i = Int(k) { mp.votesByOption[i] = v.map { $0.isMe ?? false } } }
            for (k, v) in j.pendingVoteDiff ?? [:] { if let i = Int(k), let d = MessagePoll.PendingVote(rawValue: v) { mp.pendingVoteDiff[i] = d } }
            p.poll = mp
            p.canSendPollVote = canSendPollVote ?? false
            p.sendPollVote = { _ in }
            p.showPollVotes = {}
        }
        p.playAudio = {}
        p.reactions = (reactions ?? []).compactMap { r in
            r.emoji.map { MessageReaction(emoji: $0, fromIsMe: r.from?.isMe ?? false, fromTitle: r.from?.title ?? "", timestamp: r.timestamp ?? 0) }
        }
        if let c = contact {
            var sc = SharedContact(givenName: c.name?.givenName, familyName: c.name?.familyName, organization: c.organization)
            sc.avatar = c.avatar?.avatar?.model
            sc.canMessage = c.resolution?.type != "not-on-signal"
            p.contact = sc
        }
        if let l = contactLabel, let text = l.labelString { p.contactLabel = ContactLabel(labelString: text, labelEmoji: l.labelEmoji) }
        if let q = quote {
            var m = QuoteModel(authorTitle: q.authorTitle ?? "", text: q.text)
            m.isFromMe = q.isFromMe ?? false
            m.referencedMessageNotFound = q.referencedMessageNotFound ?? false
            m.isViewOnce = q.isViewOnce ?? false
            p.quote = m
            p.scrollToQuotedMessage = {}
        }
        p.theme = .light
        // The captures run with prefers-reduced-motion: GIFs show tap-to-play.
        p.forceTapToPlay = true
        p.showLightbox = { _ in }
        p.showMediaNoLongerAvailableToast = {}
        p.kickOffAttachmentDownload = {}
        p.cancelAttachmentDownload = {}
        return p
    }
}

/// One story's messages; a story whose props do not decode is left out (and reported).
struct Story: Decodable {
    var messages: [StoryMessage]?
    init(from decoder: Decoder) throws {
        do { messages = try [StoryMessage](from: decoder) } catch {
            print("TimelineFixtures: \(decoder.codingPath.map(\.stringValue).joined(separator: ".")): \(error)")
            messages = nil
        }
    }
}

enum TimelineFixtures {
    static let all: [String: [StoryMessage]] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/timelinemessage-stories.json")
        guard let data = try? Data(contentsOf: url), let all = try? JSONDecoder().decode([String: Story].self, from: data) else { return [:] }
        return all.compactMapValues(\.messages)
    }()

    /// The author names the captures show (seeded getDefaultConversation titles, which the
    /// extraction stubs), in order of the messages that render an author.
    static let authors: [String: [String]] = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/timelinemessage-authors.json")
        return (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }()

    /// The story's messages, one after another (block wrappers, no gaps).
    /// Stories whose messages are separated by `<br />` (a 20px line each).
    static let brSeparated: Set<String> = ["emoji-messages"]

    @MainActor static func messages(_ story: String, configure: (Int, inout MessageProps) -> Void = { _, _ in }) -> some View {
        var names = authors[story] ?? [], current: String?
        let source = all[story] ?? []
        let list = source.enumerated().map { i, m in
            var p = m.props()
            if m.author?.title == nil, p.conversationType == .group, p.direction == .incoming {
                if !p.shouldCollapseAbove, !names.isEmpty { current = names.removeFirst() }
                if let current { p.author.title = current }
            }
            configure(i, &p)
            return p
        }
        return VStack(spacing: brSeparated.contains(story) ? 20 : 0) {
            ForEach(list.indices, id: \.self) { i in
                Message(props: list[i]).environment(\.messageContainerMaxWidth, source[i]._wide == false ? 306 : 600)
            }
        }
    }
}
