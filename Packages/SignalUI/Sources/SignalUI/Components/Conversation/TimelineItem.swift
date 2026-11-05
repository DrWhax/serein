// Port of ts/components/conversation/TimelineItem.dom.tsx: one timeline row. A message
// renders as TimelineMessage, a collapse set as CollapseSetViewer, and every other item as
// its notification inside InlineNotificationWrapper (select mode, targeting).
//
// The notification cases carry the notification view itself (its props are its init
// arguments). Payment events are not ported (payments are out of scope). An item type the
// client does not know renders ErrorBoundary's fallback, which is what upstream shows when
// TimelineItem throws "Unknown type".

import SignalI18n
import SwiftUI

/// `TimelineItemType`
public enum TimelineItemType {
    case message(MessageProps)
    case collapseSet(AnyView)
    case unsupportedMessage(UnsupportedMessage)
    case callHistory(CallingNotification)
    case chatSessionRefreshed(ChatSessionRefreshedNotification)
    case deliveryIssue(DeliveryIssueNotification)
    case timerNotification(TimerNotification)
    case universalTimerNotification(UniversalTimerNotification)
    case contactRemovedNotification
    case changeNumberNotification(ChangeNumberNotification)
    case joinedSignalNotification(JoinedSignalNotification)
    case titleTransitionNotification(TitleTransitionNotification)
    case safetyNumberNotification(SafetyNumberNotification)
    case verificationNotification(VerificationNotification)
    case groupNotification(GroupNotification)
    case groupV2Change(GroupV2Change)
    case groupV1Migration(GroupV1Migration)
    case conversationMerge(ConversationMergeNotification)
    case phoneNumberDiscovery(PhoneNumberDiscoveryNotification)
    case resetSessionNotification
    case profileChange(ProfileChangeNotification)
    case pinnedMessage(PinnedMessageNotification)
    case messageRequestResponse(MessageRequestResponseNotification)
    /// A type this client does not render.
    case unknown(String)
}

public struct TimelineItem: View {
    let item: TimelineItemType?
    let isSelectMode: Bool
    let isSelected: Bool
    let toggleSelectMessage: (_ shift: Bool, _ selected: Bool) -> Void
    let showDebugLog: () -> Void
    @Environment(\.i18n) var i18n

    public init(item: TimelineItemType?, isSelectMode: Bool = false, isSelected: Bool = false,
                toggleSelectMessage: @escaping (Bool, Bool) -> Void = { _, _ in }, showDebugLog: @escaping () -> Void = {}) {
        self.item = item
        self.isSelectMode = isSelectMode
        self.isSelected = isSelected
        self.toggleSelectMessage = toggleSelectMessage
        self.showDebugLog = showDebugLog
    }

    public var body: some View {
        // No item: the row was removed from the store before the timeline re-rendered.
        if let item {
            switch item {
            case .message(let props): Message(props: props)
            case .collapseSet(let view): view
            case .unknown: ErrorBoundaryNotification(showDebugLog: showDebugLog)
            default:
                InlineNotificationWrapper(isSelectMode: isSelectMode, isSelected: isSelected, toggleSelectMessage: toggleSelectMessage) {
                    notification(item)
                }
            }
        }
    }

    @ViewBuilder func notification(_ item: TimelineItemType) -> some View {
        switch item {
        case .unsupportedMessage(let v): v
        case .callHistory(let v): v
        case .chatSessionRefreshed(let v): v
        case .deliveryIssue(let v): v
        case .timerNotification(let v): v
        case .universalTimerNotification(let v): v
        case .contactRemovedNotification:
            SystemMessage(.icon("v3/info/info-compact"), text: i18n("icu:ContactRemovedNotification__text"))
        case .changeNumberNotification(let v): v
        case .joinedSignalNotification(let v): v
        case .titleTransitionNotification(let v): v
        case .safetyNumberNotification(let v): v
        case .verificationNotification(let v): v
        case .groupNotification(let v): v
        case .groupV2Change(let v): v
        case .groupV1Migration(let v): v
        case .conversationMerge(let v): v
        case .phoneNumberDiscovery(let v): v
        case .resetSessionNotification: ResetSessionNotification()
        case .profileChange(let v): v
        case .pinnedMessage(let v): v
        case .messageRequestResponse(let v): v
        case .message, .collapseSet, .unknown: EmptyView()
        }
    }
}
