// Port of ts/components/CallingToast.dom.tsx + CallingToastManager.dom.tsx (+ CallingToast /
// CallingRaisedHandsToasts .scss): the call's toast queue (keyed, auto-closing after their
// lifetime, paused while hovered, at most N at once) and the button toasts above the
// controls — muted / unmuted, ringing on / off, raised hands, "Lower your hand?", muted by
// someone, someone muted someone.

import Observation
import SignalI18n
import SwiftUI

public struct CallingToastItem: Identifiable, Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String)
        /// `CallingRaisedHandsToast__Content`: the hand, the message and a link.
        case raisedHand(message: String, link: String, action: String)
        /// `CallingReactionsToasts__reaction`: the 28px emoji floated outside the pill, the name.
        case reaction(emoji: String, name: String)
    }
    public var key: String
    public var content: Content
    public var autoClose: Bool
    public var dismissable: Bool
    public var lifetime: Duration
    public var id: String { key }

    public init(key: String, content: Content, autoClose: Bool, dismissable: Bool = false, lifetime: Duration = .seconds(5)) {
        self.key = key
        self.content = content
        self.autoClose = autoClose
        self.dismissable = dismissable
        self.lifetime = lifetime
    }
}

/// `CallingToastProvider`'s state.
@MainActor @Observable
public final class CallingToastQueue {
    public private(set) var toasts: [CallingToastItem] = []
    let maxNonPersistentToasts: Int
    @ObservationIgnored var timers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var paused = false

    public init(maxNonPersistentToasts: Int = 5) { self.maxNonPersistentToasts = maxNonPersistentToasts }

    /// Replaces a toast with the same key; the oldest auto-closing toast goes when over the cap.
    public func show(_ toast: CallingToastItem) {
        if let i = toasts.firstIndex(where: { $0.key == toast.key }) {
            toasts[i] = toast
        } else {
            toasts.append(toast)
        }
        let autoClosing = toasts.filter(\.autoClose)
        if autoClosing.count > maxNonPersistentToasts, let oldest = autoClosing.first { hide(oldest.key) }
        if toast.autoClose { schedule(toast.key, after: toast.lifetime) }
    }

    public func hide(_ key: String) {
        timers.removeValue(forKey: key)?.cancel()
        toasts.removeAll { $0.key == key }
    }

    func schedule(_ key: String, after lifetime: Duration) {
        timers[key]?.cancel()
        timers[key] = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, !self.paused else { return }
            self.hide(key)
        }
    }

    /// Hovering or focusing the region pauses the timers; leaving restarts them.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        if !paused { for t in toasts where t.autoClose { schedule(t.key, after: t.lifetime) } }
    }
}

/// `.CallingToasts__inner`: the toasts centred in a column, 8px apart.
public struct CallingToastsRegion: View {
    let queue: CallingToastQueue
    let onAction: (String) -> Void
    public init(queue: CallingToastQueue, onAction: @escaping (String) -> Void = { _ in }) {
        self.queue = queue
        self.onAction = onAction
    }

    public var body: some View {
        VStack(spacing: 8) {
            ForEach(queue.toasts) { toast in
                CallingToastPill(toast: toast, onAction: onAction) { queue.hide(toast.key) }
                    .transition(.opacity)
            }
        }
        .onHover { queue.setPaused($0) }
    }
}

struct CallingToastPill: View {
    let toast: CallingToastItem
    let onAction: (String) -> Void
    let dismiss: () -> Void

    var body: some View {
        let gray15 = AxoColor(light: LegacyColor.gray15, dark: LegacyColor.gray15)
        let pill = CallingToastView {
            switch toast.content {
            case .text(let s):
                CSSText(s, style: LegacyType.subtitle(), alignment: .center, color: gray15)
            case .raisedHand(let message, let link, let action):
                let style = CSSTextStyle(fontName: AxoFonts.interName(weight: 500), size: 12, lineHeight: 16)
                HStack(spacing: 0) {
                    SignalIcon("v3/raise_hand/raise_hand-light", size: 16, color: AxoColor(light: LegacyColor.white, dark: LegacyColor.white), mask: true)
                        .frame(width: 16, height: 16).padding(.trailing, 8)
                    CSSText(message, style: style, wrap: .nowrap, color: gray15)
                    Button { onAction(action) } label: {
                        CSSText(link, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 600), size: 12, lineHeight: 16), wrap: .nowrap,
                                color: AxoColor(light: LegacyColor.ultramarinePastel, dark: LegacyColor.ultramarinePastel))
                    }
                    .buttonStyle(UndimmedButtonStyle())
                    .padding(.leading, 16)
                }
                .padding(.vertical, 4).padding(.horizontal, 8)
            case .reaction(let emoji, let name):
                CSSText(name, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 15, lineHeight: 20), wrap: .nowrap,
                        color: AxoColor(light: LegacyColor.gray20, dark: LegacyColor.gray20))
                    .padding(.horizontal, 4)     // padding-inline: 16px (the pill gives 12)
                    .overlay(alignment: .topLeading) { FunStaticEmoji(emoji, size: 28).offset(x: -60 + 4, y: -5) }
            }
        }
        if toast.dismissable {
            Button(action: dismiss) { pill }.buttonStyle(UndimmedButtonStyle())
        } else {
            pill
        }
    }
}

/// `ObservedRemoteMuteType`
public struct ObservedRemoteMute: Sendable, Hashable {
    public var source: UInt32
    public var target: UInt32
    public init(source: UInt32, target: UInt32) {
        self.source = source
        self.target = target
    }
}

/// `CallingButtonToasts`: the hooks that turn call-state changes into toasts (one at a time).
@MainActor
public final class CallingButtonToasts {
    public struct State: Equatable {
        public var hasLocalAudio: Bool
        public var outgoingRing: Bool?
        public var raisedHands: [UInt32]
        public var suggestLowerHand: Bool
        public var isHandRaised: Bool
        public var mutedBy: UInt32?
        public var observedRemoteMute: ObservedRemoteMute?
        public init(hasLocalAudio: Bool, outgoingRing: Bool? = nil, raisedHands: [UInt32] = [], suggestLowerHand: Bool = false, isHandRaised: Bool = false,
                    mutedBy: UInt32? = nil, observedRemoteMute: ObservedRemoteMute? = nil) {
            self.hasLocalAudio = hasLocalAudio
            self.outgoingRing = outgoingRing
            self.raisedHands = raisedHands
            self.suggestLowerHand = suggestLowerHand
            self.isHandRaised = isHandRaised
            self.mutedBy = mutedBy
            self.observedRemoteMute = observedRemoteMute
        }
    }

    /// Who a demux id is: title, and whether it is us (and our ACI, to skip self-mutes).
    public struct Person: Sendable {
        public var title: String
        public var isMe: Bool
        public var aci: String?
        public init(title: String, isMe: Bool, aci: String?) {
            self.title = title
            self.isMe = isMe
            self.aci = aci
        }
    }

    public let queue = CallingToastQueue(maxNonPersistentToasts: 1)
    var previous: State?
    /// Raised hands become toasts only 2s after the call screen opens (LOAD_DELAY).
    var loadedAt: Date
    var handsToastShownAt: Date = .distantPast
    var handsForLastToast: [UInt32] = []
    let i18n: Localizer

    public init(i18n: Localizer, now: Date = Date()) {
        self.i18n = i18n
        loadedAt = now.addingTimeInterval(2)
    }

    public func update(_ state: State, people: (UInt32) -> Person?, localDemuxId: UInt32?, now: Date = Date()) {
        defer { previous = state }
        guard let previous else { return }
        // useMutedToast
        if state.hasLocalAudio != previous.hasLocalAudio && state.mutedBy == nil {
            queue.hide("muted")
            queue.show(CallingToastItem(key: "muted", content: .text(i18n(state.hasLocalAudio ? "icu:CallControls__MutedToast--unmuted"
                                                                         : "icu:CallControls__MutedToast--muted")), autoClose: true, dismissable: true))
        }
        // useOutgoingRingToast
        if let ring = state.outgoingRing, let was = previous.outgoingRing, ring != was {
            queue.hide("ringing")
            queue.show(CallingToastItem(key: "ringing", content: .text(i18n(ring ? "icu:CallControls__RingingToast--ringing-on"
                                                                           : "icu:CallControls__RingingToast--ringing-off")), autoClose: true, dismissable: true))
        }
        raisedHandsToast(state, previous, people: people, localDemuxId: localDemuxId, now: now)
        // useLowerHandSuggestionToast
        if state.suggestLowerHand != previous.suggestLowerHand, state.suggestLowerHand, state.isHandRaised {
            queue.show(CallingToastItem(key: "SUGGEST_LOWER_HAND_TOAST_KEY",
                                        content: .raisedHand(message: i18n("icu:CallControls__LowerHandSuggestionToast"),
                                                             link: i18n("icu:CallControls__LowerHandSuggestionToast--button"), action: "lowerHand"),
                                        autoClose: true, lifetime: .seconds(10)))
        }
        if !state.isHandRaised { queue.hide("SUGGEST_LOWER_HAND_TOAST_KEY") }
        // useMutedByToast
        if let by = state.mutedBy, by != previous.mutedBy, let person = people(by) {
            queue.hide("MUTED_BY_TOAST_KEY")
            let text = person.isMe ? i18n("icu:CallControls__YouMutedYourselfToast")
                : i18n("icu:CallControls__MutedBySomeoneToast", ["otherName": .string(person.title)])
            queue.show(CallingToastItem(key: "MUTED_BY_TOAST_KEY", content: .text(text), autoClose: true, dismissable: true, lifetime: .seconds(10)))
        }
        // useObservedRemoteMuteToast
        if let m = state.observedRemoteMute, m != previous.observedRemoteMute, let target = people(m.target) {
            let source = people(m.source)
            if source?.aci == nil || source?.aci != target.aci {
                let text: String? = source?.isMe == true
                    ? i18n("icu:CallControls__YouMutedSomeoneToast", ["otherName": .string(target.title)])
                    : source.map { i18n("icu:CallControls__SomeoneMutedSomeoneToast", ["name": .string($0.title), "otherName": .string(target.title)]) }
                if let text {
                    queue.hide("OBSERVED_REMOTE_MUTE_TOAST_KEY")
                    queue.show(CallingToastItem(key: "OBSERVED_REMOTE_MUTE_TOAST_KEY", content: .text(text), autoClose: true, dismissable: true,
                                                lifetime: .seconds(10)))
                }
            }
        }
    }

    /// `useRaisedHandsToast` with CallScreen's `renderRaisedHandsToast`.
    func raisedHandsToast(_ state: State, _ previous: State, people: (UInt32) -> Person?, localDemuxId: UInt32?, now: Date) {
        if state.raisedHands.isEmpty { queue.hide("raised-hands") }
        guard now >= loadedAt else { return }
        let newHands = state.raisedHands.filter { !previous.raisedHands.contains($0) }
        let lowered = previous.raisedHands.filter { !state.raisedHands.contains($0) }
        if newHands.isEmpty && lowered.isEmpty { return }
        var hands: [UInt32]
        if now.timeIntervalSince(handsToastShownAt) < 4 {
            hands = handsForLastToast.filter { !lowered.contains($0) } + newHands
            if newHands.isEmpty && !lowered.isEmpty && !hands.isEmpty && hands.count == handsForLastToast.count { return }
        } else {
            hands = newHands
        }
        handsForLastToast = hands
        queue.hide("raised-hands")
        guard let content = Self.raisedHandsContent(hands.reversed(), people: people, localDemuxId: localDemuxId, i18n: i18n) else { return }
        queue.show(CallingToastItem(key: "raised-hands", content: content, autoClose: true, lifetime: .seconds(4)))
        handsToastShownAt = now
    }

    static func raisedHandsContent(_ demuxIds: [UInt32], people: (UInt32) -> Person?, localDemuxId: UInt32?, i18n: Localizer) -> CallingToastItem.Content? {
        var names: [String] = []
        var yours = false
        for id in demuxIds {
            if id == localDemuxId { yours = true; continue }
            if let p = people(id) { names.append(p.title) }
        }
        let name = names.first ?? "", other = names.count > 1 ? names[1] : ""
        let message: String
        var link = (i18n("icu:CallControls__RaiseHands--open-queue"), "openQueue")
        switch names.count {
        case 0: return nil
        case 1:
            if yours {
                message = i18n("icu:CallControls__RaiseHandsToast--you")
                link = (i18n("icu:CallControls__RaiseHands--lower"), "lowerHand")
            } else {
                message = i18n("icu:CallControls__RaiseHandsToast--one", ["name": .string(name)])
            }
        case 2:
            message = yours ? i18n("icu:CallControls__RaiseHandsToast--you-and-one", ["otherName": .string(other)])
                : i18n("icu:CallControls__RaiseHandsToast--two", ["name": .string(name), "otherName": .string(other)])
        default:
            let overflow = I18nArgument.number(Double(names.count - 2))
            message = yours ? i18n("icu:CallControls__RaiseHandsToast--you-and-more", ["otherName": .string(other), "overflowCount": overflow])
                : i18n("icu:CallControls__RaiseHandsToast--more", ["name": .string(name), "otherName": .string(other), "overflowCount": overflow])
        }
        return .raisedHand(message: message, link: link.0, action: link.1)
    }
}
