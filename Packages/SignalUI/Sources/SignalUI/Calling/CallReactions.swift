// Port of CallScreen.dom.tsx's useReactionsToast / CallingReactionsToastsContainer and
// CallReactionBurst.dom.tsx (+ CallingReactionsToasts.scss): each reaction is a toast in a
// column 65px from the left, 32px above the controls (newest at the bottom, the 4th and 5th
// newest faded), and when 3+ people send the same emoji within 4s it bursts (at most 3
// bursts per 4s; a reaction joins a burst less than 2s old).

import Observation
import SignalI18n
import SwiftUI

/// `ActiveCallReactionsType` entries.
public struct CallReaction: Sendable, Hashable {
    /// ms
    public var timestamp: Int64
    public var demuxId: UInt32
    public var value: String
    public init(timestamp: Int64, demuxId: UInt32, value: String) {
        self.timestamp = timestamp
        self.demuxId = demuxId
        self.value = value
    }
}

public struct CallReactionBurst: Sendable, Hashable, Identifiable {
    public var id: Int
    public var values: [String]
    public var startedAt: Date
}

@MainActor @Observable
public final class CallReactionsModel {
    public let queue = CallingToastQueue(maxNonPersistentToasts: 5)
    public private(set) var bursts: [CallReactionBurst] = []
    @ObservationIgnored var previous: [CallReaction]?
    @ObservationIgnored var shown: [String: (value: String, original: String, isBursted: Bool, expireAt: Int64, reactor: String)] = [:]
    @ObservationIgnored var burstsShown: [String: Int64] = [:]
    @ObservationIgnored var nextBurstId = 0
    let i18n: Localizer

    static let burstThreshold = 3, burstWindow: Int64 = 4000, trailingWindow: Int64 = 2000, maxInShortWindow = 3, shortWindow: Int64 = 4000

    public init(i18n: Localizer) { self.i18n = i18n }

    /// - Parameters:
    ///   - people: demux id → (title, service id), nil when unknown.
    ///   - now: ms.
    public func update(_ reactions: [CallReaction], people: (UInt32) -> (title: String, serviceId: String?)?, localDemuxId: UInt32?,
                       ourServiceId: String?, now: Int64) {
        guard reactions != previous else { return }
        previous = reactions
        var anyShown = false
        for r in reactions {
            guard let person = people(r.demuxId) else { continue }
            let key = "reactions-\(r.timestamp)-\(r.demuxId)"
            if !queue.toasts.contains(where: { $0.key == key }) && shown[key] == nil {
                let isMe = r.demuxId == localDemuxId || (ourServiceId != nil && person.serviceId == ourServiceId)
                queue.show(CallingToastItem(key: key, content: .reaction(emoji: Self.ignoringSkinTone(r.value), name: isMe ? i18n("icu:CallingReactions--me") : person.title),
                                            autoClose: true))
            }
            if shown[key] != nil { continue }
            let parent = Self.ignoringSkinTone(r.value)
            let isBursted = (burstsShown[parent].map { $0 + Self.trailingWindow > now }) ?? false
            shown[key] = (parent, r.value, isBursted, r.timestamp + Self.burstWindow, person.serviceId ?? "\(r.demuxId)")
            anyShown = true
        }
        guard anyShown else { return }
        var unbursted: [String: [String]] = [:]
        var reactors: [String: Set<String>] = [:]
        for (key, s) in shown {
            if s.expireAt < now { shown[key] = nil; continue }
            if s.isBursted { continue }
            unbursted[s.value, default: []].append(key)
            reactors[s.value, default: []].insert(s.reactor)
        }
        burstsShown = burstsShown.filter { $0.value >= now - Self.shortWindow }
        if burstsShown.count >= Self.maxInShortWindow { return }
        for (value, ids) in reactors.sorted(by: { $0.key < $1.key }) where ids.count >= Self.burstThreshold {
            guard let keys = unbursted[value] else { continue }
            burstsShown[value] = now
            let values = keys.sorted().compactMap { key -> String? in
                shown[key]?.isBursted = true
                return shown[key]?.original
            }
            nextBurstId += 1
            bursts.append(CallReactionBurst(id: nextBurstId, values: values, startedAt: Date()))
            if burstsShown.count >= Self.maxInShortWindow { break }
        }
    }

    func burstEnded(_ id: Int) { bursts.removeAll { $0.id == id } }

    /// `Emoji.ignorePreferredSkinTone` / `getParent`: the emoji without skin-tone modifiers.
    static func ignoringSkinTone(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !(0x1F3FB...0x1F3FF).contains($0.value) }))
    }
}

/// `.CallingReactionsToasts`: the reaction toasts and the bursts above the controls.
struct CallingReactionsToastsRegion: View {
    let model: CallReactionsModel

    var body: some View {
        let toasts = model.queue.toasts
        ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(toasts.enumerated()), id: \.element.key) { i, toast in
                    let fromNewest = toasts.count - 1 - i
                    CallingToastPill(toast: toast, onAction: { _ in }, dismiss: {})
                        .opacity(fromNewest == 3 ? 0.9 : fromNewest == 4 ? 0.7 : 1)
                }
            }
            .padding(.leading, 65)
            ForEach(model.bursts) { burst in
                CallReactionBurstView(burst: burst) { model.burstEnded(burst.id) }
                    .padding(.leading, 15)
            }
        }
        .allowsHitTesting(false)
    }
}

/// `CallReactionBurst`: the burst's emojis float up from the bottom-left and fade (~2.5s).
struct CallReactionBurstView: View {
    let burst: CallReactionBurst
    let onEnd: () -> Void
    static let duration = 2.5

    var body: some View {
        TimelineView(.animation) { context in
            let t = min(1, context.date.timeIntervalSince(burst.startedAt) / Self.duration)
            ZStack(alignment: .bottomLeading) {
                ForEach(Array(burst.values.enumerated()), id: \.offset) { i, value in
                    let delay = Double(i) * 0.08
                    let p = max(0, min(1, (t - delay) / (1 - delay)))
                    FunStaticEmoji(value, size: 48)
                        .offset(x: CGFloat((i * 37) % 120), y: -CGFloat(p) * 400)
                        .opacity(p < 0.8 ? 1 : (1 - p) / 0.2)
                }
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(Self.duration))
            onEnd()
        }
    }
}
