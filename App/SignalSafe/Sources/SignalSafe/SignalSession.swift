// The app on SignalCore (upstream background.preload.ts start-up + the conversations slice):
// open the encrypted database, resume the stored account or link this Mac by QR code, then
// keep the inbox and the open conversation's timeline live from the database and send through
// the messenger. Untrusted media goes to SignalMediaDecoder.xpc (MediaXPCClient).

import AppKit
import AVFAudio
import Foundation
import GRDB
import LibSignalClient
import MediaXPCInterface
import Observation
import UniformTypeIdentifiers
import SignalCore
import SignalRingRTC
import SignalUI

@MainActor @Observable final class SignalSession {
    enum Phase: Equatable {
        case starting
        /// Install screen: the QR code (or its loading/error state).
        case linking(InstallScreenProvisioningURL)
        case linkError(InstallScreenError)
        /// The database could not be opened (upstream: the database-error dialog).
        case failed(String)
        case ready
    }

    /// `SIGNALSAFE_ENV=staging` (or the `signalEnvironment` default) selects staging; each
    /// environment has its own folder and database key.
    static var environment: SignalEnvironment {
        let raw = ProcessInfo.processInfo.environment["SIGNALSAFE_ENV"] ?? UserDefaults.standard.string(forKey: "signalEnvironment")
        return raw == "staging" ? .staging : .production
    }

    /// Upstream getUserAgent: `Signal-Desktop/<version> macOS <release>`. The chat server
    /// gates clients by this string; we report the upstream release this port tracks.
    static var userAgent: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "Signal-Desktop/8.36.0 macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    let environment = SignalSession.environment
    private(set) var phase: Phase = .starting
    private(set) var conversations: [ConversationSummary] = []
    private(set) var messages: [TimelineMessage] = []
    private(set) var contacts: [String: ContactInfo] = [:]
    /// The Stories tab: unexpired stories (newest first) and the distribution lists.
    private(set) var stories: [StoryFeedItem] = []
    private(set) var storyLists: [StoryDistributionLists.List] = []
    private var storiesTask: Task<Void, Never>?
    /// Chat folders (the left pane's folder bar) and the selected one (nil: All chats).
    private(set) var chatFolders: [SignalCore.ChatFolder] = []
    var selectedChatFolderId: String?
    private var foldersTask: Task<Void, Never>?
    /// The left pane's archive view (More actions → Archived chats).
    var isShowingArchive = false
    /// Notification profiles (the More actions submenu), live.
    var notificationProfiles = NotificationProfilesMenuState(profiles: [], activeProfileId: nil, enabledOverrideEndsAt: nil)
    private var profilesTask: Task<Void, Never>?
    /// Settings → Notifications, and Settings → Privacy → Blocked (conversation ids).
    private(set) var notificationSettings = SignalCore.NotificationSettings()
    private(set) var blockedConversationIds: [String] = []
    private var notificationSettingsTask: Task<Void, Never>?
    private var blockedTask: Task<Void, Never>?
    private var storyListsTask: Task<Void, Never>?
    /// Account-wide settings (Preferences), live.
    private(set) var accountSettings = AccountSettings()
    private var settingsTask: Task<Void, Never>?
    private(set) var ourAci: String?
    var selectedConversationId: String? {
        didSet { if selectedConversationId != oldValue { observeTimeline(leaving: oldValue) } }
    }
    var draft = "" {
        didSet {
            if draft != oldValue {
                maybeGrabLinkPreview()
                // A restored draft going in is not typing.
                if draft == restoredDraftText { return }
                restoredDraftText = nil
                draftChangedForTyping()
                scheduleDraftSave()
            }
        }
    }
    /// The open chat's saved draft as the composer shows it, while it is going in.
    @ObservationIgnored var restoredDraftText: String?
    @ObservationIgnored var draftSaveTask: Task<Void, Never>?
    /// Paging: how many of the newest messages the timeline loads, whether that is all of them,
    /// and whether a larger page is on its way.
    @ObservationIgnored var timelineLimit = SignalSession.timelinePage
    private(set) var haveOldest = true
    private(set) var isLoadingOlder = false
    static let timelinePage = 100
    /// The "unread messages" divider: the oldest message unread when the chat opened, and how
    /// many were unread (upstream's oldestUnseen / totalUnseen, fixed while the chat is open).
    private(set) var unreadMarker: UnseenSummary?
    /// Who is typing where (conversation → sender → since), and their expiry timers.
    var typing: [String: [String: Date]] = [:]
    @ObservationIgnored var typingExpiry: [String: Task<Void, Never>] = [:]
    /// Our own indicator: where "started" was last sent, when, and the idle timer.
    @ObservationIgnored var typingSentTo: String?
    @ObservationIgnored var typingSentAt: Date?
    @ObservationIgnored var typingIdleTask: Task<Void, Never>?
    /// The composer's link preview (upstream's `linkPreviews` duck and LinkPreview service): the
    /// link being previewed and, once fetched, the preview and its decoded image.
    var linkPreview: ComposerLinkPreview?
    /// Links whose preview was closed or failed (`excludedPreviewUrls`), until the next send.
    var linkPreviewExcluded: Set<String> = []
    var linkPreviewTask: Task<Void, Never>?
    var linkPreviewDebounce: Task<Void, Never>?
    /// Previews are fetched by SignalLinkPreviewFetcher.xpc (straight from the site, as upstream
    /// Desktop does), which has the page parsed by SignalLinkPreviewParser.xpc: the app only
    /// brokers the connection between them and gets validated fields and image bytes back.
    let linkPreviewFetcher = LinkPreviewFetcherClient()
    /// The strings a preview carries (in our language), set by the conversation pane.
    var linkPreviewStrings: LinkPreviewStrings?
    /// Calls (Calls.swift): the service, the call on screen, an incoming ring, our audio/video,
    /// picture-in-picture, the camera and its preview.
    var calling: CallingService?
    var activeCall: ActiveCallState?
    var ringingCall: (conversationId: String, isVideo: Bool)?
    var callLocalAudio = true
    var callLocalVideo = false
    var callPip = false
    @ObservationIgnored var camera: CameraCapture?
    @ObservationIgnored var cameraSends = false
    /// Starts and stops the camera to match `cameraWanted`, rechecking after every wait.
    @ObservationIgnored var cameraControl: CaptureReconciler?
    /// Bumped by `releaseCallMedia()` (every way a call ends): call setup and screen-share
    /// starts still waiting note it when they begin and give up if it changed.
    @ObservationIgnored var callGeneration: UInt64 = 0
    @ObservationIgnored var callSetupTask: Task<Void, Never>?
    /// The current screen share's token (nil: none). Each share gets a new one; its frame and
    /// stop callbacks carry it, so an old stream's late frame or error cannot reach a newer
    /// share or call (a call generation alone does not tell two shares in one call apart).
    @ObservationIgnored var screenShareToken: UInt64?
    @ObservationIgnored var lastScreenShareToken: UInt64 = 0
    var preferredCameraId: String?
    var preferredMicrophoneId: String?
    var preferredSpeakerId: String?
    var callDevices = CallDevices()
    @ObservationIgnored let callLocalVideoModel = LocalVideoModel()
    @ObservationIgnored var groupVideoSources: [String: GroupCallVideo] = [:]
    @ObservationIgnored var directVideo: DirectCallVideo?
    var callHistory: [CallHistoryStore.Group] = []
    @ObservationIgnored var callHistoryTask: Task<Void, Never>?
    /// Call links (ours and joined), live; the call link modal on screen.
    var callLinks: [CallLinkRecord] = []
    @ObservationIgnored var callLinksTask: Task<Void, Never>?
    var callLinkModal: CallLinkModal?
    /// Text to send to chats the user picks (the forward dialog), e.g. a shared call link.
    var shareText: String?
    /// Sharing presenting: the ScreenCaptureKit sources to pick from, and the capture running.
    var presentingSources: [PresentableSource]?
    @ObservationIgnored var screenCapture: ScreenShareCapture?
    @ObservationIgnored var ringtone: NSSound?
    /// The voice note being recorded (VoiceRecorder.swift), and its engine, samples and task.
    var recording: VoiceRecording?
    @ObservationIgnored var recorderEngine: AVAudioEngine?
    @ObservationIgnored var recorderSamples: MicSamples?
    @ObservationIgnored var recorderTask: Task<Void, Never>?
    /// The live composer's rich text (mentions, styles) and its "@query" (MentionSuggestions).
    @ObservationIgnored let composer = ComposerController()
    var mentionQuery: String?
    /// Which message text holds the mouse selection (one at a time).
    @ObservationIgnored let textSelection = TextSelectionCenter()
    /// The video playing in its bubble (one at a time), by message.
    var inlineVideo: (messageId: String, player: VideoPlaybackEngine)?
    /// A chat's avatar shown large (AvatarLightbox), by conversation.
    var avatarLightboxFor: String?
    /// The poll dialog (PollCreateModal) is open.
    var isCreatingPoll = false
    /// The message whose edit history is shown (EditHistoryMessagesModal).
    var editHistoryMessageId: String?
    /// ⌘⇧E: the message whose reaction picker to toggle, and a counter so each press counts.
    var reactionPickerMessageId: String?
    var reactionPickerCount = 0
    /// The toast over the left pane (ToastManager), until it times out or is closed.
    var toast: ToastType?
    /// Audio playback (VoiceNotes.swift): the playing (or paused) message, its play head.
    var activeAudioMessageId: String?
    /// The playing message's sender (nil: ours), for the mini-player's title.
    var activeAudioAuthor: String?
    var audioPlaying = false
    var audioTime: Double = 0
    var audioRate: Double = 1
    @ObservationIgnored var audioEngine: AudioPlaybackEngine?
    @ObservationIgnored var audioClockTask: Task<Void, Never>?
    @ObservationIgnored let audioWaveforms = ObservedCache<AudioWaveform>()
    @ObservationIgnored var audioWaveformLoading: Set<String> = []
    /// The reply being composed: the message the composer quotes.
    var quotedMessageId: String?
    /// The sent message being edited (the composer holds its new text).
    var editingMessageId: String?
    /// Select mode: the selected messages, in timeline order (nil: not selecting).
    var selectedMessageIds: [String]?
    /// The open message dialogs (delete, pin) and the message-details panel.
    var deleteRequest: DeleteMessagesRequest?
    var pinRequest: PinMessageRequest?
    var messageDetailId: String? { didSet { if messageDetailId != oldValue { observeMessageDetail() } } }
    var messageDetail: MessageDeliveryDetail?
    var messageDetailTask: Task<Void, Never>?
    /// The open conversation's pinned messages (newest first) and the one the bar shows.
    var pins: [PinnedMessageSummary] = []
    var currentPinIndex: Int?
    var pinsTask: Task<Void, Never>?
    /// A scroll request for the timeline (a pin's or a quote's message), bumped per request.
    var scrollToMessageId: String?
    var scrollCounter = 0
    /// The Fun picker's installed sticker packs (live) and decoded sticker images.
    var stickerPacks: [StickerPackSummary] = []
    @ObservationIgnored let stickerImages = ObservedCache<RGBAImage>()
    @ObservationIgnored var stickerLoading: Set<String> = []
    /// Looping players of the timeline's GIFs, by attachment path (the newest few kept).
    @ObservationIgnored let gifPlayers = ObservedCache<VideoPlaybackEngine>()
    @ObservationIgnored var gifOrder: [String] = []
    @ObservationIgnored var gifLoading: Set<String> = []
    /// The open chat's details (header, details panel), live.
    var details: ConversationDetailsInfo?
    var detailsTask: Task<Void, Never>?
    /// The conversation panels pushed over the chat (upstream PanelType names), top last.
    var panels: [String] = []
    /// The open ContactModal (a member's service id).
    var contactModalId: String?
    /// Search (the left pane): the term, the chat it is limited to (the header's 🔍), results.
    var searchTerm = ""
    var searchConversationId: String?
    var searchHits: [MessageSearchHit] = []
    var searchTask: Task<Void, Never>?
    /// A message to scroll to once its chat's timeline has loaded (a search result).
    var pendingScrollMessageId: String?
    /// The custom-duration dialogs: the chat they are for.
    var customTimerFor: String?
    var customMuteFor: String?
    /// AddGroupMembersModal / EditConversationAttributesModal, and their request state.
    var isAddingMembers = false
    var addMembersState = RequestState.inactive
    var isEditingGroup = false
    /// The edit dialog opens on its avatar editor (the details' avatar was clicked).
    var editGroupStartsWithAvatar = false
    var editGroupState = RequestState.inactive
    /// The photo picked for the group's avatar (its bytes, re-encoded by the media service on save).
    var pendingGroupPhoto: (data: Data, contentType: String)?
    /// Chat colours (live) and the open chat's own colour; the open custom-colour editor.
    var chatColors = ChatColorsState(customColors: [], defaultColor: nil)
    var conversationColor: ChatBubbleColor?
    var chatColorsTask: Task<Void, Never>?
    var conversationColorTask: Task<Void, Never>?
    var customColorEditor: CustomColorEditing?
    /// ForwardMessagesModal: the messages being forwarded.
    var forwardMessageIds: [String]?
    /// Compose's sub-screens (new group, find by username / phone number) and their state.
    var composeMode = ComposeMode.compose
    var groupSelection: [String] = []
    var newGroupName = ""
    var newGroupTimer = 0
    /// The new group's avatar (AvatarEditor's result; a photo's bytes are in `newGroupPhoto`).
    var newGroupAvatar: AvatarData?
    /// Its preview pixels (a photo's, or the preset drawn once).
    var newGroupAvatarPreview: RGBAImage?
    var newGroupPhoto: (data: Data, contentType: String)?
    var isEditingNewGroupAvatar = false
    /// Find by phone number: the chosen country (`composeSelectedRegion`), and its chooser.
    var composeSelectedRegion: String?
    var isChoosingCountry = false
    var isCreatingGroup = false
    var isLookingUp = false
    /// A lookup's "not a Signal user" (or invalid) message.
    var composeError: ComposeError?
    /// AllMedia: the chat's attachments, live while the panel is open.
    var mediaItems: [ConversationMediaItem] = []
    var mediaTask: Task<Void, Never>?
    var stickersTask: Task<Void, Never>?
    /// Left pane compose mode (the ✏️ button): the composable contacts and groups, live.
    private(set) var isComposing = false
    var composeSearch = ""
    private(set) var composable: [ConversationSummary] = []
    private var composeTask: Task<Void, Never>?
    /// A conversation opened from compose that is not in the inbox yet (no messages).
    var opened: ConversationSummary?
    var onEvent: ((ReceiveEvent, SignalSession) -> Void)?

    private var client: SignalClient?
    var clientDatabase: SignalDatabase? { client?.database }
    var signalClient: SignalClient? { client }
    /// The Fun picker's GIFs: SignalGifSearch.xpc talks to Giphy through Signal's content proxy
    /// and decodes its JSON; the app gets validated results and MP4 bytes (for the decoder).
    let gifSearch = GifSearchClient()
    var giphy: (any GifSearching)? { client.map { _ in gifSearch } }
    /// The sandboxed decoder (SignalMediaDecoder.xpc); shared with SignalClient.
    let media = MediaXPCClient()
    /// Decoded attachment pixels for the timeline, by local attachment path.
    @ObservationIgnored let images = ObservedCache<RGBAImage>()
    @ObservationIgnored private var loadingImages: Set<String> = []
    /// The open Lightbox (MediaViewer).
    var lightbox: LightboxState?
    var signalSession: SignalClient.Session? { session }
    /// Largest side of a decoded timeline image (the bubble is at most ~ 480 pt wide at 2×).
    static let displayMaxDimension = 1024
    private(set) var session: SignalClient.Session?
    private var inboxTask: Task<Void, Never>?
    private var contactsTask: Task<Void, Never>?
    private var timelineTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var identityStopsTask: Task<Void, Never>?
    /// The open safety-number review (IdentityReview.swift).
    var identityReview: IdentityReview?
    /// The open safety-number viewer for one contact.
    var safetyNumberSheet: SafetyNumberSheet?
    private var linkTask: Task<Void, Never>?

    var isStaging: Bool { environment == .staging }

    /// Development only: `SIGNALSAFE_MOCK_READY=<file>` runs against a local
    /// @signalapp/mock-server (Tools/run-app-mock.py), in a throwaway folder with an in-memory
    /// database key; the provisioning URL is written to `<file>.url` for the driver to scan.
    nonisolated static let mockReadyPath = ProcessInfo.processInfo.environment["SIGNALSAFE_MOCK_READY"]

    struct MockReady: Decodable {
        var port: UInt16
        var certificateAuthority: String
        var serverTrustRoots: [String]
        var serverPublicParams: String
        var genericServerPublicParams: String
    }

    struct EphemeralKeyStore: DatabaseKeyStore {
        let key = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
        func loadOrCreateKey() throws -> Data { key }
        func deleteKey() throws {}
    }

    static func mockClient(_ path: String, media: MediaXPCClient) throws -> SignalClient {
        let ready = try JSONDecoder().decode(MockReady.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let pem = ready.certificateAuthority.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        guard let ca = Data(base64Encoded: pem), let spp = Data(base64Encoded: ready.serverPublicParams),
              let gspp = Data(base64Encoded: ready.genericServerPublicParams) else { throw InstallError() }
        let roots = try ready.serverTrustRoots.map { b64 -> PublicKey in
            guard let d = Data(base64Encoded: b64) else { throw InstallError() }
            return try PublicKey(d)
        }
        let config = SignalClient.Config(net: Net.localTestServer(userAgent: userAgent, chatPort: ready.port, rootCertificateDer: ca),
                                         endpoints: .mockServer(port: Int(ready.port), rootCertificateDER: ca), trustRoots: roots,
                                         serverPublicParams: spp, genericServerPublicParams: gspp)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SignalSafe-mock-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try SignalClient(config: config, directory: folder, keyStore: EphemeralKeyStore(), media: media)
    }

    func start() {
        connectComposer()
        guard client == nil else { return }
        if Self.tracing { SignalClient.diagnostics.withLock { $0 = { Self.trace($0) } } }
        if let path = Self.mockReadyPath {
            do {
                let client = try Self.mockClient(path, media: media)
                self.client = client
                observeInbox(client.database)
            } catch {
                phase = .failed("mock server: \(error)")
                return
            }
            Task { await resumeOrLink() }
            return
        }
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = support.appendingPathComponent(isStaging ? "signal-safe-staging" : "signal-safe", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let keys = KeychainDatabaseKeyStore(account: isStaging ? "sqlcipher-key-staging" : "sqlcipher-key")
            let client = try SignalClient(config: try .signal(environment, userAgent: Self.userAgent), directory: folder, keyStore: keys,
                                          media: media)
            self.client = client
            observeInbox(client.database)
        } catch {
            phase = .failed(String(describing: error))
            return
        }
        Task { await resumeOrLink() }
    }

    private func resumeOrLink() async {
        guard let client else { return }
        do {
            if let session = try await client.resume() {
                Self.trace("resumed stored account, device \(session.account.deviceId)")
                becameReady(session, client: client)
                // The primary never answered the link-time sync request: ask again.
                if (try? await client.database.pool.read({ try ConversationQueries.contacts($0) }))?.isEmpty ?? true {
                    do {
                        try await session.messenger.requestSync()
                        Self.trace("sync requests re-sent (no contacts yet)")
                    } catch {
                        Self.trace("sync request failed: \(error)")
                    }
                }
                return
            }
        } catch {
            // Stored account but no connection (offline, deregistered): keep the account and
            // show the inbox; SocketManager keeps reconnecting.
            if (try? await client.storedAccount()) != nil { phase = .ready; return }
        }
        link()
    }

    /// Install screen: request a provisioning URL and wait for the phone to scan it.
    func link() {
        guard let client else { return }
        linkTask?.cancel()
        phase = .linking(.loading)
        let name = Host.current().localizedName ?? "Mac"
        linkTask = Task {
            do {
                Self.trace("link: requesting provisioning URL")
                _ = try await client.link(deviceName: name) { url in
                    Self.trace("link: QR code shown")
                    if let path = Self.mockReadyPath { try? Data(url.utf8).write(to: URL(fileURLWithPath: path + ".url")) }
                    Task { @MainActor in self.phase = .linking(.loaded(url)) }
                }
                guard let session = await client.session else { throw InstallError() }
                Self.trace("link: linked as device \(session.account.deviceId)")
                becameReady(session, client: client)
                // Upstream after linking: ask the primary for contacts, blocked list,
                // configuration and keys (the storage sync runs in becameReady). No history.
                do {
                    try await session.messenger.requestSync()
                    Self.trace("sync requests sent")
                } catch {
                    Self.trace("sync request failed: \(error)")
                }
            } catch is CancellationError {
            } catch {
                Self.trace("link failed: \(error)")    // errors carry no message content
                if let e = error as? ChatRequestError, case .http(_, _, let body) = e {
                    Self.trace("link failed: server said \(String(decoding: body.prefix(300), as: UTF8.self))")
                }
                phase = Self.failure(error, scanned: { if case .linking(.loaded) = phase { true } else { false } }())
            }
        }
    }

    struct InstallError: Error {}

    /// Mock-server runs only (`SIGNALSAFE_MOCK_REPLY=<text>`): open the first chat that has a
    /// message and send the text through the composer path, once.
    private var mockReplied = false
    private func mockAutoReply() {
        guard Self.mockReadyPath != nil, !mockReplied, let text = ProcessInfo.processInfo.environment["SIGNALSAFE_MOCK_REPLY"],
              phase == .ready, let first = conversations.first(where: { $0.lastMessage?.direction == .incoming }) else { return }
        mockReplied = true
        selectedConversationId = first.id
        Task {
            try? await Task.sleep(for: .seconds(2))
            if !first.isAccepted { respond(first.id, .accept) }
            try? await Task.sleep(for: .seconds(1))
            draft = text
            sendDraft()
            // SIGNALSAFE_MOCK_KEYCHANGE_REPLY=<text>: once the chat shows a safety-number
            // notice, send this through the composer (the review dialog comes up), and
            // confirm the dialog a few seconds later.
            if let second = ProcessInfo.processInfo.environment["SIGNALSAFE_MOCK_KEYCHANGE_REPLY"] {
                for _ in 0..<240 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard messages.contains(where: { if case .keyChange = $0.notice { true } else { false } }) else { continue }
                    draft = second
                    sendDraft()
                    try? await Task.sleep(for: .seconds(1))
                    Self.trace("identity review \(identityReview == nil ? "not shown" : "shown for \(identityReview?.contacts.count ?? 0) contact(s)")")
                    try? await Task.sleep(for: .seconds(6))
                    confirmIdentityReview()
                    break
                }
            }
            // SIGNALSAFE_MOCK_LIGHTBOX=1: open the newest downloaded video in the Lightbox.
            guard ProcessInfo.processInfo.environment["SIGNALSAFE_MOCK_LIGHTBOX"] == "1" else { return }
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(250))
                if let m = messages.last(where: { $0.attachments.contains { AttachmentPolicy.isVideo($0.attachment.contentType) && $0.attachment.isDownloaded } }),
                   let i = m.attachments.map(\.attachment).filter({ AttachmentPolicy.isImage($0.contentType) || AttachmentPolicy.isVideo($0.contentType) })
                    .firstIndex(where: { AttachmentPolicy.isVideo($0.contentType) }) {
                    openLightbox(m, index: i)
                    return
                }
            }
            Self.trace("lightbox: no downloaded video")
        }
    }

    /// A line on stderr: mock-server runs (full detail, fake data), or `SIGNALSAFE_TRACE=1`
    /// (event kinds and counts only — never message text, names or numbers).
    nonisolated static let tracing = mockReadyPath != nil || ProcessInfo.processInfo.environment["SIGNALSAFE_TRACE"] == "1"
    nonisolated static func kind(_ e: ReceiveEvent) -> String { String(String(describing: e).prefix { $0 != "(" }) }
    nonisolated static func trace(_ s: some StringProtocol) {
        guard tracing else { return }
        FileHandle.standardError.write(Data((String(s) + "\n").utf8))
    }

    /// Upstream InstallScreen: 409 → TooManyDevices, 499 → TooOld; other failures once the
    /// QR code was shown → ConnectionFailed; before that the QR step's own error.
    static func failure(_ error: Error, scanned: Bool) -> Phase {
        if let e = error as? ChatRequestError, case .http(let status, _, _) = e {
            if status == 409 { return .linkError(.tooManyDevices) }
            if status == 499 { return .linkError(.tooOld) }
        }
        // The provisioning socket closing before a scan is the QR code expiring (retry).
        if case .provisioningClosed = error as? LinkError { return .linking(.loadFailed(.timeout)) }
        if scanned, error is LinkError || error is ChatRequestError { return .linkError(.connectionFailed) }
        return .linking(.loadFailed(qrError(error)))
    }

    static func qrError(_ error: Error) -> InstallScreenQRCodeError {
        let text = String(describing: error).lowercased()
        if text.contains("timeout") || text.contains("timed out") { return .timeout }
        if text.contains("connect") || text.contains("network") || text.contains("offline") { return .networkIssue }
        return .unknown
    }

    private func becameReady(_ session: SignalClient.Session, client: SignalClient) {
        self.session = session
        ourAci = session.account.aci
        phase = .ready
        // Startup storage-service sync (upstream runStorageServiceSyncJob): contacts, groups,
        // account settings, pinned chats.
        Task {
            do {
                if let r = try await session.storage.sync() {
                    Self.trace("storage sync: version \(r.version), \(r.contacts) contacts, \(r.groups) groups, account \(r.account), \(r.other) other, \(r.errors) errors")
                } else {
                    Self.trace("storage sync: up to date")
                }
            } catch {
                Self.trace("storage sync failed: \(error)")
            }
            await client.refreshIncomplete()
        }
        startCalling()
        traceSendHealth(session)
        identityStopsTask?.cancel()
        identityStopsTask = observeIdentityStops(session)
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            for await e in await client.events() {
                if case .callMessage(let call) = e { self?.handleCallMessage(call) }
                Self.trace(Self.mockReadyPath != nil ? "event \(e)".prefix(160) : "event \(Self.kind(e))")
                if case .message(_, let conversationId, let sender, _, _, _, _, _) = e { self?.clearTyping(conversationId, sender) }
                self.map { $0.onEvent?(e, $0) }
            }
        }
    }

    private func observeInbox(_ db: SignalDatabase) {
        inboxTask?.cancel()
        inboxTask = Task { [weak self] in
            do {
                for try await rows in db.inboxUpdates() {
                    Self.trace(Self.mockReadyPath != nil ? "inbox \(rows.map { "\($0.title): \($0.lastMessage?.body ?? "-") (\($0.unreadCount))" })"
                                                         : "inbox: \(rows.count) conversations, \(rows.reduce(0) { $0 + $1.unreadCount }) unread")
                    self?.conversations = rows
                    self?.mockAutoReply()
                }
            } catch {}
        }
        storiesTask?.cancel()
        storiesTask = Task { [weak self] in
            do { for try await rows in db.storyUpdates() { self?.stories = rows } } catch {}
        }
        notificationSettingsTask?.cancel()
        notificationSettingsTask = Task { [weak self] in
            do { for try await n in db.notificationSettingsUpdates() { self?.notificationSettings = n } } catch {}
        }
        blockedTask?.cancel()
        blockedTask = Task { [weak self] in
            do { for try await ids in db.blockedUpdates() { self?.blockedConversationIds = ids } } catch {}
        }
        foldersTask?.cancel()
        foldersTask = Task { [weak self] in
            do { for try await f in db.chatFolderUpdates() { self?.chatFolders = f } } catch {}
        }
        profilesTask?.cancel()
        profilesTask = Task { [weak self] in
            do { for try await p in db.notificationProfilesUpdates() { self?.notificationProfiles = p } } catch {}
        }
        storyListsTask?.cancel()
        storyListsTask = Task { [weak self] in
            do { for try await lists in db.storyListUpdates() { self?.storyLists = lists } } catch {}
        }
        settingsTask?.cancel()
        settingsTask = Task { [weak self] in
            do {
                for try await s in db.accountSettingsUpdates() { self?.accountSettings = s }
            } catch {}
        }
        contactsTask?.cancel()
        contactsTask = Task { [weak self] in
            do {
                for try await all in db.contactUpdates() { self?.contacts = all }
            } catch {}
        }
    }

    private func observeTimeline(leaving previous: String? = nil) {
        if let previous { saveDraft(previous) }
        composer.cancelPendingDraft()
        restoredDraftText = nil
        unreadMarker = nil
        timelineLimit = Self.timelinePage
        haveOldest = true
        isLoadingOlder = false
        if let c = selectedConversationId.flatMap(conversation) {
            Self.trace("open chat: \(c.kind), accepted \(c.isAccepted), serviceId \(c.serviceId != nil), masterKey \(c.masterKey != nil)")
        }
        timelineTask?.cancel()
        messages = []
        cancelRecording()
        stopInlineVideo()
        resetLinkPreview()
        draft = ""
        quotedMessageId = nil
        editingMessageId = nil
        selectedMessageIds = nil
        messageDetailId = nil
        closeGifPlayers()
        draftSaveTask?.cancel()    // clearing the composer above is not an edit of the next chat's draft
        panels = []
        observePins()
        observeDetails()
        observeConversationColor()
        guard let id = selectedConversationId, let db = client?.database else { return }
        restoreDraft(id)
        observeTimelineRows(id)
        // A message we are waiting to be resent keeps its later place once the chat has been read.
        if let messenger = session?.messenger { Task { try? await messenger.conversationOpened(id) } }
        // The divider is placed from what was unread before the chat is marked read; a page
        // large enough to hold it is loaded.
        Task { [weak self] in
            let unseen = try? await db.unseen(conversationId: id)
            guard let self, self.selectedConversationId == id else { return }
            self.unreadMarker = unseen
            if let unseen, unseen.count + 10 > self.timelineLimit {
                self.timelineLimit = unseen.count + 10
                self.observeTimelineRows(id)
            }
            self.markRead(id)
        }
    }

    /// (Re)starts the open chat's timeline at the current page size.
    private func observeTimelineRows(_ id: String) {
        guard let db = client?.database else { return }
        timelineTask?.cancel()
        let limit = timelineLimit
        timelineTask = Task { [weak self] in
            do {
                for try await rows in db.timelineUpdates(conversationId: id, limit: limit) {
                    guard let self else { return }
                    self.messages = rows
                    self.haveOldest = rows.count < limit
                    self.isLoadingOlder = false
                    if let target = self.pendingScrollMessageId {
                        if rows.contains(where: { $0.id == target }) {
                            self.pendingScrollMessageId = nil
                            self.goToMessage(target)
                        } else if !self.haveOldest {
                            self.loadOlderMessages()    // the message to show is further back
                        }
                    }
                }
            } catch {}
        }
    }

    /// The timeline scrolled near its top: load the next older page.
    func loadOlderMessages() {
        guard !haveOldest, !isLoadingOlder, let id = selectedConversationId else { return }
        isLoadingOlder = true
        timelineLimit += Self.timelinePage
        observeTimelineRows(id)
    }

    // MARK: drafts

    /// Puts the chat's saved draft into its composer (once its text view exists).
    private func restoreDraft(_ id: String) {
        guard let c = conversation(id), let body = c.draft else { return }
        let ranges = draftRanges(c)
        restoredDraftText = ComposerController.displayText(body: body, ranges: ranges)
        composer.load(body: body, ranges: ranges, intoNewView: true)
    }

    /// A saved draft's ranges for the composer (mentions titled with the contact's name).
    func draftRanges(_ c: ConversationSummary) -> [BodyRange] {
        c.draftBodyRanges.map { r in
            switch r.kind {
            case .mention(let aci):
                BodyRange(start: r.start, length: r.length, kind: .mention(aci: aci, conversationID: aci, replacementText: contactTitle(aci)))
            case .style(let style):
                BodyRange(start: r.start, length: r.length, kind: .formatting(BodyRange.Style(rawValue: style) ?? .none))
            }
        }
    }

    /// Saves the draft a second after typing stops (so it survives quitting).
    func scheduleDraftSave() {
        guard editingMessageId == nil, let id = selectedConversationId else { return }
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self?.selectedConversationId == id else { return }
            self?.saveDraft(id)
        }
    }

    /// Stores the composer's text as `conversationId`'s draft (empty: clears it).
    func saveDraft(_ conversationId: String) {
        draftSaveTask?.cancel()
        guard let session, editingMessageId == nil else { return }
        let (body, ranges) = Self.trimmed(composer.outgoing(), fallback: draft)
        let coreRanges = Self.coreRanges(ranges)
        let saved = conversation(conversationId)
        if body.isEmpty && saved?.draft == nil { return }
        if body == saved?.draft && coreRanges == saved?.draftBodyRanges { return }
        Task { try? await session.messenger.saveDraft(conversationId, body: body, bodyRanges: coreRanges) }
    }

    /// The composer's ranges as SignalCore stores and sends them.
    static func coreRanges(_ ranges: [BodyRange]) -> [MessageBodyRange] {
        ranges.compactMap { r in
            switch r.kind {
            case .mention(let aci, _, _): MessageBodyRange(start: r.start, length: r.length, kind: .mention(aci: aci))
            case .formatting(let style, _) where style != .none: MessageBodyRange(start: r.start, length: r.length, kind: .style(style.rawValue))
            default: nil
            }
        }
    }

    func markRead(_ conversationId: String, force: Bool = false) {
        guard let session else { return }
        let c = conversations.first(where: { $0.id == conversationId })
        // Opening a chat marked unread clears the mark (upstream markConversationRead).
        if c?.folderProps.markedUnread == true { Task { try? await session.messenger.setMarkedUnread(conversationId, false) } }
        guard force || c?.unreadCount ?? 0 > 0 else { return }
        Task { _ = try? await session.messenger.markRead(conversationId: conversationId) }
    }

    /// A group member's or contact's title for message authors.
    func contactTitle(_ serviceId: String?) -> String { serviceId.flatMap { contacts[$0]?.title } ?? "Unknown contact" }

    func contactColor(_ serviceId: String?) -> String {
        serviceId.flatMap { contacts[$0]?.color } ?? ConversationQueries.avatarColor(serviceId: serviceId, e164: nil, groupId: nil)
    }

    var selectedConversation: ConversationSummary? { selectedConversationId.flatMap(conversation) }

    func conversation(_ id: String) -> ConversationSummary? {
        conversations.first { $0.id == id } ?? composable.first { $0.id == id } ?? (opened?.id == id ? opened : nil)
    }

    func startComposing() {
        guard let db = client?.database else { return }
        isComposing = true
        composeSearch = ""
        composeMode = .compose
        composeTask?.cancel()
        composeTask = Task { [weak self] in
            do {
                for try await rows in db.composableUpdates() { self?.composable = rows }
            } catch {}
        }
    }

    /// A one-off load of the composable list (the story send modal), when not composing.
    func loadComposable() {
        guard !isComposing, let db = client?.database else { return }
        Task { if let rows = try? await db.pool.read({ try ConversationQueries.composable($0) }) { composable = rows } }
    }

    func stopComposing() {
        isComposing = false
        composeSearch = ""
        composeMode = .compose
        groupSelection = []
        newGroupName = ""
        newGroupTimer = 0
        newGroupAvatar = nil
        newGroupAvatarPreview = nil
        newGroupPhoto = nil
        isEditingNewGroupAvatar = false
        composeSelectedRegion = nil
        isChoosingCountry = false
        composeTask?.cancel()
    }

    /// A contact's 1:1 chat, by service id (a group member's "Message"), created if new.
    func openDirect(serviceId: String) {
        guard let session else { return }
        Task {
            guard let id = try? await session.messenger.directConversation(serviceId: serviceId) else { return Self.trace("open direct failed") }
            await openNew(id)
        }
    }

    /// Blocks a contact by service id (from a member's contact modal).
    func blockContact(_ serviceId: String) {
        guard let db = client?.database, let session else { return }
        Task {
            guard let c = (try? await db.pool.read({ try ConversationQueries.composable($0) }))?.first(where: { $0.serviceId == serviceId }) else { return }
            try? await session.messenger.setBlocked(c.id, true)
        }
    }

    /// A contact or group chosen in compose: open it (it joins the inbox with its first message).
    func openFromCompose(_ id: String) {
        opened = composable.first { $0.id == id }
        stopComposing()
        selectedConversationId = id
    }

    /// The decoded image for a downloaded image attachment, loading it (plaintext from the
    /// local store → the media service → validated RGBA) the first time it is asked for.
    func image(for a: SignalCore.MessageAttachment) -> RGBAImage? {
        guard let path = a.path, a.isDownloaded, AttachmentPolicy.isImage(a.contentType) else { return nil }
        if let hit = images[path] { return hit }
        return loadImage(key: path, maxDimension: Self.displayMaxDimension) { store in try store.plaintext(of: a) }
    }

    /// Decodes a stored file's pixels once (plaintext from the local store → the media
    /// service → validated RGBA), caching them under `key`.
    func loadImage(key: String, maxDimension: Int, plaintext: @escaping @Sendable (AttachmentStore) throws -> Data?) -> RGBAImage? {
        guard let session, !loadingImages.contains(key) else { return nil }
        loadingImages.insert(key)
        let store = session.attachmentStore, media = media
        Task {
            defer { loadingImages.remove(key) }
            guard let bytes = try? await Task.detached(operation: { try plaintext(store) }).value ?? nil,
                  let shown = try? await media.displayImage(bytes, maxDimension: maxDimension) else { return }
            images[key] = RGBAImage(width: shown.width, height: shown.height, pixels: shown.rgba, scale: 2)
        }
        return nil
    }

    /// A file chosen for the next message (CompositionArea's draft attachments).
    struct StagedAttachment: Identifiable {
        let id = UUID()
        var data: Data
        var contentType: String
        var fileName: String
        var preview: RGBAImage?
        var width: Int?
        var height: Int?
    }
    private(set) var staged: [StagedAttachment] = [] {
        // "If we have attachments, don't add link preview".
        didSet {
            if staged.isEmpty != oldValue.isEmpty { maybeGrabLinkPreview() }
            if staged.isEmpty { composerHighQuality = nil }   // REPLACE_ATTACHMENTS with none
        }
    }
    /// The composer's HD button for this draft (`shouldSendHighQualityAttachments`); nil
    /// follows Settings → Data usage → Sent media quality.
    var composerHighQuality: Bool?
    var sendsHighQuality: Bool { composerHighQuality ?? (accountSettings.sentMediaQuality == .high) }
    /// Upstream's outgoing limit (getMaximumOutgoingAttachmentSize default, 100 MiB).
    static let maxAttachmentBytes = 100 * 1024 * 1024

    /// The 📎 menu: an open panel for photos and videos, or any file.
    func pickAttachments(mediaOnly: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if mediaOnly { panel.allowedContentTypes = [.image, .movie] }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { stage(url) }
    }

    /// Reads a chosen file; images get a preview decoded by the media service (never here).
    func stage(_ url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxAttachmentBytes,
              let data = try? Data(contentsOf: url) else { return Self.trace("attach: file unreadable or too large") }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        stage(data, contentType: type, fileName: url.lastPathComponent)
    }

    /// ⌘V in the composer (`handlePaste`): files on the pasteboard, or an image (PNG or JPEG
    /// bytes; other image types would need ImageIO, so they are left alone).
    func pasteAttachments(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls { stage(url) }
            return true
        }
        for (type, mime, ext) in [(NSPasteboard.PasteboardType.png, "image/png", "png"), (NSPasteboard.PasteboardType("public.jpeg"), "image/jpeg", "jpg")] {
            if let data = pasteboard.data(forType: type), data.count <= Self.maxAttachmentBytes {
                stage(data, contentType: mime, fileName: "image.\(ext)")
                return true
            }
        }
        return false
    }

    func stage(_ data: Data, contentType type: String, fileName: String) {
        guard selectedConversationId != nil, editingMessageId == nil else { return }
        let item = StagedAttachment(data: data, contentType: type, fileName: fileName)
        staged.append(item)
        let heic = AttachmentServices.isHeic(type, fileName: fileName)
        guard AttachmentPolicy.isImage(type) || heic else { return }
        let media = media
        Task {
            var shownData = data
            // handleImageAttachment: a HEIC photo's draft is the JPEG it converts to (quality
            // 0.75, no file name). If it cannot be converted it stays the file it is.
            if heic {
                guard let converted = try? await media.convertHEIC(data) else { return }
                guard let i = staged.firstIndex(where: { $0.id == item.id }) else { return }
                staged[i].data = converted.data
                staged[i].contentType = "image/jpeg"
                staged[i].fileName = ""
                shownData = converted.data
            }
            guard let shown = try? await media.displayImage(shownData, maxDimension: 512) else { return }
            if let i = staged.firstIndex(where: { $0.id == item.id }) {
                staged[i].preview = RGBAImage(width: shown.width, height: shown.height, pixels: shown.rgba, scale: 2)
                staged[i].width = shown.originalWidth
                staged[i].height = shown.originalHeight
            }
        }
    }

    func removeStaged(at index: Int) { if staged.indices.contains(index) { staged.remove(at: index) } }
    func clearStaged() { staged.removeAll() }

    /// A received message's notification (upstream maybeNotify): nil when the policy says
    /// none (muted, profile, read already, our own, a story we do not show…).
    func notification(for messageId: String) async -> (PendingNotification, SignalCore.NotificationSettings)? {
        guard let db = client?.database, let aci = ourAci else { return nil }
        return try? await db.pool.read { db -> (PendingNotification, SignalCore.NotificationSettings)? in
            guard let p = try NotificationPolicy.pending(db, messageId: messageId, ourAci: aci) else { return nil }
            return (p, try SignalCore.NotificationSettings.load(db))
        }
    }

    /// The Dock badge (upstream getUnreadCountForBadge), live.
    func badgeUpdates() -> AsyncThrowingStream<Int, Error>? {
        client?.database.observe { try NotificationPolicy.badgeCount($0) }
    }

    /// The selected folder's chats (All chats, or no folder: every chat).
    var folderFilteredConversations: [ConversationSummary] {
        guard let id = selectedChatFolderId, let folder = chatFolders.first(where: { $0.id == id }), folder.folderType == .custom else {
            return conversations
        }
        return conversations.filter { ChatFolderStore.contains(folder, $0.folderProps) }
    }

    func saveNotificationSettings(_ change: (inout SignalCore.NotificationSettings) -> Void) {
        var n = notificationSettings
        change(&n)
        guard n != notificationSettings, let session else { return }
        notificationSettings = n
        let saved = n
        // Saved, and "notify … while muted" synced to our other devices (AccountRecord).
        Task {
            do { try await session.messenger.saveNotificationSettings(saved) } catch { Self.trace("notification settings failed: \(error)") }
        }
    }

    /// Chat folder changes (stored, and written back to the storage service).
    func editChatFolders(_ change: @escaping @Sendable (Database) throws -> Void) {
        guard let db = client?.database else { return }
        Task {
            do { try await db.pool.write { try change($0) } } catch { Self.trace("chat folder change failed: \(error)") }
        }
    }

    /// Unblock (upstream: the message-request ACCEPT response, synced to our devices).
    func unblock(_ conversationId: String) { respond(conversationId, .accept) }

    func accountEntropyPool() async -> String? { try? await client?.database.accountEntropyPool() }

    /// Upstream `markChatFolderRead`: every unread chat in the folder.
    func markFolderRead(_ id: String) {
        guard let folder = chatFolders.first(where: { $0.id == id }) else { return }
        for c in conversations where c.unreadCount > 0 && ChatFolderStore.contains(folder, c.folderProps, ignoreShowOnlyUnread: true) {
            markRead(c.id, force: true)
        }
    }

    /// The sticker creator's upload: encrypt the pack, upload it, and return its share link.
    func stickerUpload() -> ((String, String, [(Data, String?)], Data, @escaping @MainActor () -> Void) async throws -> URL)? {
        guard let session, let client else { return nil }
        let cdn = client.config.endpoints.cdnURLs[0]
        return { title, author, stickers, cover, progress in
            guard let cdn else { throw InstallError() }
            let draft = StickerPackDraft(title: title, author: author, stickers: stickers.map { .init(data: $0.0, emoji: $0.1) }, cover: cover)
            let pack = try StickerPackUpload.encrypt(draft)
            let id = try await StickerPackUpload.upload(pack, socket: client.socket, http: session.http, cdn: cdn) {
                Task { @MainActor in progress() }
            }
            return StickerPackUpload.shareURL(packId: id, packKey: pack.packKey)
        }
    }

    // MARK: plaintext export (Settings → Chats → Export chat history)

    var exportStep: PlaintextExportStep?
    private var exportTask: Task<Void, Never>?

    func startPlaintextExport() { exportStep = .confirmingExport }

    func cancelPlaintextExport() {
        exportTask?.cancel()
        exportStep = nil
    }

    /// After the OS check: pick a folder, export into a new folder there, with progress.
    func runPlaintextExport(includeMedia: Bool) {
        guard let session, let db = client?.database else { return }
        exportStep = .choosingLocation(includeMedia: includeMedia)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let target = panel.url else { exportStep = nil; return }
        exportStep = .exportingMessages(exportPath: target.path)
        let account = session.account, store = session.attachmentStore
        exportTask = Task {
            do {
                let result = try await PlaintextExport.export(database: db, account: account, attachments: includeMedia ? store : nil, to: target,
                                                              includeMedia: includeMedia) { current, total in
                    // Media progress once there are bytes to copy (messages first, without a bar).
                    guard total > 0 else { return }
                    Task { @MainActor in
                        guard self.exportStep != nil else { return }
                        self.exportStep = .exportingAttachments(exportPath: target.path, totalBytes: Int(total), currentBytes: Int(current))
                    }
                }
                exportStep = .complete(exportPath: result.exportDirectory.path)
            } catch PlaintextExportError.notEnoughStorage(let needed) {
                exportStep = .error(.notEnoughStorage(bytesNeeded: Int(needed)))
            } catch is CancellationError {
                exportStep = nil
            } catch let e as CocoaError where e.code == .fileWriteNoPermission {
                exportStep = .error(.storagePermissions)
            } catch {
                Self.trace("export failed: \(error)")
                exportStep = .error(.general)
            }
        }
    }

    // MARK: stories

    func markStoryViewed(_ id: String) {
        guard let session, stories.first(where: { $0.id == id })?.isUnread == true else { return }
        Task { try? await session.messenger.markStoryViewed(storyId: id) }
    }

    /// Sends a story to distribution lists and group conversations (their master keys).
    func sendStory(_ content: OutgoingStoryContent, listIds: [String], groupConversationIds: [String]) {
        guard let session else { return }
        let keys = groupConversationIds.compactMap { conversation($0)?.masterKey }
        Task {
            do {
                _ = try await session.messenger.sendStory(content, listIds: listIds, groupMasterKeys: keys)
                Self.trace("story: queued to \(listIds.count) lists, \(keys.count) groups")
            } catch {
                Self.trace("story failed: \(error)")
            }
        }
    }

    func replyToStory(_ id: String, body: String = "", emoji: String? = nil) {
        guard let session else { return }
        Task {
            do { _ = try await session.messenger.sendStoryReply(storyId: id, body: body, emoji: emoji) }
            catch { Self.trace("story reply failed: \(error)") }
        }
    }

    /// An image or video for a media story, chosen in an open panel (preview via the service).
    func pickStoryMedia() async -> StagedAttachment? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        guard panel.runModal() == .OK, let url = panel.url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maxAttachmentBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        var item = StagedAttachment(data: data, contentType: type, fileName: url.lastPathComponent)
        if AttachmentPolicy.isImage(type), let shown = try? await media.displayImage(data, maxDimension: 1024) {
            item.preview = RGBAImage(width: shown.width, height: shown.height, pixels: shown.rgba, scale: 2)
            item.width = shown.originalWidth
            item.height = shown.originalHeight
        }
        return item
    }

    /// A notification was clicked: open its chat.
    func open(conversationId: String) {
        stopComposing()
        selectedConversationId = conversationId
    }

    /// A contact's or group's avatar, decoded by the media service the first time it is shown.
    @ObservationIgnored let avatars = ObservedCache<RGBAImage>()
    @ObservationIgnored private var loadingAvatars: Set<String> = []
    func avatarImage(_ file: LocalFile?) -> RGBAImage? {
        guard let file else { return nil }
        if let hit = avatars[file.path] { return hit }
        guard let session, !loadingAvatars.contains(file.path) else { return nil }
        loadingAvatars.insert(file.path)
        let store = session.attachmentStore, media = media
        Task {
            defer { loadingAvatars.remove(file.path) }
            guard let plaintext = try? await Task.detached(operation: { try store.plaintext(of: file) }).value,
                  let shown = try? await media.displayImage(plaintext, maxDimension: 256) else { return }
            avatars[file.path] = RGBAImage(width: shown.width, height: shown.height, pixels: shown.rgba, scale: 2)
        }
        return nil
    }

    /// MessageRequestActions: accept / block / delete / report (synced to our other devices);
    /// accepting downloads the media that waited for it.
    func respond(_ conversationId: String, _ response: MessageRequestResponse) {
        guard let session else { return }
        Task {
            try? await session.messenger.respondToMessageRequest(conversationId: conversationId, response, groups: session.groups)
            await session.downloads.tick()
            if response != .accept, selectedConversationId == conversationId { selectedConversationId = nil }
        }
    }

    /// Changes account settings (saved to the database and the storage service); only actual
    /// changes are written.
    func updateAccountSettings(_ change: (inout AccountSettings) -> Void) {
        var s = accountSettings
        change(&s)
        guard s != accountSettings, let db = client?.database else { return }
        accountSettings = s
        Task { try? await db.saveAccountSettings(s) }
    }

    /// Settings → Privacy → Phone number → Who can see my number. The setting changes once
    /// the server has the profile carrying it (ProfileWriter); a failure leaves it as it was.
    func setSharesPhoneNumber(_ everybody: Bool) {
        guard everybody != accountSettings.sharesPhoneNumber, let writer = session?.profileWriter else { return }
        Task {
            do { try await writer.setSharesNumber(everybody) } catch {
                Self.trace("phone number sharing not changed: \(error)")
                toast = .error
            }
        }
    }

    /// … → Who can find me by number.
    func setDiscoverableByPhoneNumber(_ on: Bool) {
        guard on != accountSettings.discoverableByPhoneNumber, let writer = session?.profileWriter else { return }
        Task {
            do { try await writer.setDiscoverable(on) } catch {
                Self.trace("phone number discoverability not changed: \(error)")
                toast = .error
            }
        }
    }

    /// The body without leading and trailing whitespace, its ranges moved (and clipped) to match.
    /// Falls back to the plain draft when the composer has no text view (tests, previews).
    static func trimmed(_ out: (body: String, ranges: [BodyRange]), fallback: String) -> (String, [BodyRange]) {
        let raw = out.body.isEmpty && !fallback.isEmpty ? fallback : out.body
        let units = Array(raw.utf16)
        func isSpace(_ u: UInt16) -> Bool { Unicode.Scalar(u).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false }
        var lo = 0, hi = units.count
        while lo < hi, isSpace(units[lo]) { lo += 1 }
        while hi > lo, isSpace(units[hi - 1]) { hi -= 1 }
        let body = String(decoding: units[lo..<hi], as: UTF16.self)
        let ranges = (out.body.isEmpty ? [] : out.ranges).compactMap { r -> BodyRange? in
            let s = max(r.start, lo), e = min(r.start + r.length, hi)
            guard e > s else { return nil }
            var moved = r
            moved.start = s - lo
            moved.length = e - s
            return moved
        }
        return (body, ranges)
    }

    /// Sends the composer's text to the open conversation.
    func sendDraft() {
        // The composer's body (mentions as U+FFFC) and its ranges, trimmed like the text.
        let (body, bodyRanges) = Self.trimmed(composer.outgoing(), fallback: draft)
        Self.trace("send: draft \(body.count) chars, \(staged.count) attachments, session \(session != nil), conversation \(selectedConversation.map { "\($0.kind)" } ?? "none")")
        if let editing = editingMessageId {
            // An edit: the new text replaces the message's body (here and for everyone).
            guard !body.isEmpty, let session else { return }
            editingMessageId = nil
            draft = ""
            Task {
                do { try await session.messenger.edit(editing, newBody: body) } catch { Self.trace("edit failed: \(error)") }
            }
            return
        }
        guard !body.isEmpty || !staged.isEmpty, let session, let c = selectedConversation else { return }
        let attachments = staged.map { OutgoingAttachment(data: $0.data, contentType: $0.contentType, fileName: $0.fileName.isEmpty ? nil : $0.fileName) }
        // `canSendInHighQuality` (an image among the drafts) and the HD choice.
        let highQuality = sendsHighQuality && staged.contains { AttachmentPolicy.isImage($0.contentType) }
        let coreRanges = Self.coreRanges(bodyRanges)
        let preview = attachments.isEmpty ? linkPreviewForSend(body) : nil
        resetLinkPreview()
        unreadMarker = nil    // upstream: sending clears the divider
        draft = ""
        staged = []
        let quoting = quotedMessageId
        quotedMessageId = nil
        let stagedBefore = staged
        // Upstream blockSendUntilConversationsAreVerified: a changed safety number is put to
        // the user before anything is queued; cancelling leaves the draft as it was.
        afterIdentityReview(conversationId: c.id, send: { Task {
            do {
                if c.kind == .group {
                    guard let key = c.masterKey else { return Self.trace("send failed: group has no master key") }
                    do {
                        _ = try await session.messenger.sendGroupMessage(body, attachments: attachments, preview: preview, quoting: quoting, bodyRanges: coreRanges, masterKey: key,
                                                                         highQuality: highQuality)
                    } catch GroupsServiceError.notAMember {
                        // No group state yet (the post-link group fetch is still running) or a stale
                        // one: bring the group up to date now, then send once more.
                        Self.trace("send: group state missing, fetching it")
                        _ = try await session.groups.update(try GroupKeys(masterKey: key))
                        _ = try await session.messenger.sendGroupMessage(body, attachments: attachments, preview: preview, quoting: quoting, bodyRanges: coreRanges, masterKey: key,
                                                                         highQuality: highQuality)
                    }
                } else {
                    guard let to = c.serviceId else { return Self.trace("send failed: contact has no service id") }
                    _ = try await session.messenger.sendMessage(body, attachments: attachments, preview: preview, quoting: quoting, bodyRanges: coreRanges, to: to,
                                                                    highQuality: highQuality)
                }
                Self.trace("send: queued")
            } catch {
                Self.trace("send failed: \(error)")
            }
        } }, cancelled: { [weak self] in
            guard let self, self.selectedConversationId == c.id, self.draft.isEmpty, self.staged.isEmpty else { return }
            self.draft = ComposerController.displayText(body: body, ranges: bodyRanges)
            self.composer.load(body: body, ranges: bodyRanges)
            self.staged = stagedBefore
            self.quotedMessageId = quoting
        })
    }
}
