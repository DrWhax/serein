// Port of ts/components/CallingRaisedHandsList.dom.tsx (+ CallingRaisedHandsList.scss): the
// raised-hands panel (the participants-list panel, sized to its rows, 8px from the call's
// leading edge and 72px above its bottom) and the white "✋ N" pill that opens it.

import SignalI18n
import SwiftUI

public struct CallingRaisedHandsList: View {
    /// The conversations behind each raised hand, in raise order (one per demux id).
    let raisedHands: [CallingConversation]
    let ourAci: String?
    let localHandRaised: Bool
    let onClose: () -> Void
    let onLowerMyHand: () -> Void
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering

    public init(raisedHands: [CallingConversation], ourAci: String?, localHandRaised: Bool, onClose: @escaping () -> Void,
                onLowerMyHand: @escaping () -> Void) {
        self.raisedHands = raisedHands
        self.ourAci = ourAci
        self.localHandRaised = localHandRaised
        self.onClose = onClose
        self.onLowerMyHand = onLowerMyHand
    }

    /// One row per person: a participant on several devices raises one hand.
    var forDisplay: [CallingConversation] {
        var seen = Set<String>()
        return raisedHands.filter { c in
            guard let aci = c.aci else { return true }
            return seen.insert(aci).inserted
        }
    }

    func row(_ c: CallingConversation, index: Int, count: Int) -> some View {
        let white = AxoColor(light: LegacyColor.white, dark: LegacyColor.white)
        let nameStyle = CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 13, lineHeight: 20)
        let isMe = ourAci != nil && c.aci == ourAci
        return ParticipantRow(isMe: isMe) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Avatar(strings: AvatarStrings(i18n: i18n), title: c.title, size: 36, conversationType: .direct, color: c.color,
                           image: c.avatar.map { AnyView(PixelImage($0, fit: .cover)) }, hasAvatar: c.avatar != nil)
                    CSSText(isMe ? i18n("icu:you") : c.title, style: nameStyle, wrap: .wrap, color: white)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 4)
                if localHandRaised && isMe {
                    Button(action: onLowerMyHand) {
                        CSSText(i18n("icu:CallControls__RaiseHands--lower"), style: CSSTextStyle(fontName: AxoFonts.interName(weight: 500), size: 13, lineHeight: 20),
                                wrap: .nowrap, color: AxoColor(light: LegacyColor.ultramarinePastel, dark: LegacyColor.ultramarinePastel))
                    }
                    .buttonStyle(UndimmedButtonStyle())
                    .padding(.trailing, 16)
                }
                CallingStatusIndicatorHandRaised(isOnlyHandRaised: count == 1, raisedHandOrder: index, inRaisedHandsList: true)
                    .padding(.trailing, 8)
            }
        }
    }

    public var body: some View {
        let hands = forDisplay
        VStack(spacing: 0) {
            ParticipantsListHeader(title: i18n("icu:CallingRaisedHandsList__Title", ["count": .number(Double(hands.count))]), onClose: onClose)
            // 2px between rows, 2px above the first and 4px below the last.
            let rows = VStack(spacing: 2) {
                ForEach(Array(hands.enumerated()), id: \.offset) { i, c in row(c, index: i, count: hands.count) }
            }
            .padding(.top, 2).padding(.bottom, 4)
            if staticRendering {
                rows.fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                    .clipped()
            } else {
                ScrollView(.vertical) { rows }.scrollIndicators(.never).scrollBounceBehavior(.basedOnSize)
            }
        }
        .padding(.top, 5).padding(.horizontal, 5)
        .frame(width: 318)
        .participantsPanelChrome(shadow: false)
    }
}

/// `height: auto` up to a maximum: the subview gets its ideal height, capped at `max`.
struct CappedHeight: Layout {
    let max: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let ideal = s.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, max))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// `CallingRaisedHandsList__modal`: the panel at the bottom leading corner of the call, 9px in,
/// 73px up (its 1px padded container sits 72px above the button row), at most the call's
/// height less 8px at the top.
public struct CallingRaisedHandsListOverlay: View {
    let list: CallingRaisedHandsList
    public init(_ list: CallingRaisedHandsList) { self.list = list }
    public var body: some View {
        GeometryReader { g in
            CappedHeight(max: max(0, g.size.height - 8 - 72 - 2 - 20)) { list }
                .padding(.leading, 9)
                .padding(.bottom, 73)
                .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
        }
    }
}

/// `CallingRaisedHandsListButton`: "✋ You + N" / "✋ N", fading in when hands go up and out
/// (keeping the last label) when the last one comes down, with a small bounce on each new hand.
public struct CallingRaisedHandsListButton: View {
    let syncedLocalHandRaised: Bool
    let raisedHandsCount: Int
    let onClick: () -> Void
    @State var opacity: Double = 0
    @State var scale: Double = 0.9
    @State var shown: (count: Int, local: Bool)
    @Environment(\.i18n) var i18n
    @Environment(\.axoStaticRendering) var staticRendering
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    public init(syncedLocalHandRaised: Bool, raisedHandsCount: Int, onClick: @escaping () -> Void) {
        self.syncedLocalHandRaised = syncedLocalHandRaised
        self.raisedHandsCount = raisedHandsCount
        self.onClick = onClick
        _shown = State(initialValue: (raisedHandsCount, syncedLocalHandRaised))
    }

    var label: String {
        let (count, local) = raisedHandsCount > 0 ? (raisedHandsCount, syncedLocalHandRaised) : (shown.count, shown.local)
        guard local else { return "\(count)" }
        return count > 1 ? i18n("icu:you") + " + \(count - 1)" : i18n("icu:you")
    }

    public var body: some View {
        let black = AxoColor(light: LegacyColor.black, dark: LegacyColor.black)
        Button(action: onClick) {
            HStack(spacing: 0) {
                SignalIcon("v3/raise_hand/raise_hand-light", size: 20, color: black, mask: true).frame(width: 20, height: 20).padding(.trailing, 4)
                CSSText(label, style: CSSTextStyle(fontName: AxoFonts.interName(weight: 400), size: 14, lineHeight: 20), wrap: .nowrap, color: black)
            }
            .padding(.vertical, 14).padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color(rgba: LegacyColor.white)))
        }
        .buttonStyle(UndimmedButtonStyle())
        .opacity(staticRendering ? (raisedHandsCount > 0 ? 1 : 0) : opacity)
        .scaleEffect(staticRendering || reduceMotion ? 1 : scale)
        .allowsHitTesting(raisedHandsCount > 0)
        .onAppear {
            guard raisedHandsCount > 0 else { return }
            withAnimation(.spring(response: 0.43, dampingFraction: 0.69)) { opacity = 1 }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.22)) { scale = 1 }
        }
        .onChange(of: raisedHandsCount) { old, new in
            if new > old {
                // The bounce: from 0.99 back to 1.
                scale = 0.99
                withAnimation(.spring(response: 0.5, dampingFraction: 0.22)) { scale = 1 }
            }
            if new > 0 {
                shown = (new, syncedLocalHandRaised)
                withAnimation(.spring(response: 0.43, dampingFraction: 0.69)) { opacity = 1 }
            } else {
                withAnimation(.spring(response: 0.43, dampingFraction: 0.69)) { opacity = 0 }
            }
        }
        // While fading out, the label keeps the last count and "You" shown.
        .onChange(of: syncedLocalHandRaised) { _, new in
            if raisedHandsCount > 0 { shown.local = new }
        }
    }
}

/// `CallingRaisedHandsList__Button`'s place in the call: 16px from the leading and bottom edges.
public struct CallingRaisedHandsListButtonOverlay: View {
    let button: CallingRaisedHandsListButton
    public init(_ button: CallingRaisedHandsListButton) { self.button = button }
    public var body: some View {
        button.padding(.leading, 16).padding(.bottom, 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}
