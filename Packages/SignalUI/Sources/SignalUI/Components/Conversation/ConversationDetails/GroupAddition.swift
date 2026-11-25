// Port of ts/groups/toggleSelectedContactForGroupAddition.std.ts (and OneTimeModalState): adding
// someone stops at the hard limit, shows the maximum-size dialog once on reaching it, else the
// recommended-size warning once on reaching that. Shared by "Add members" and the new-group
// member chooser.

/// `OneTimeModalState`
public enum OneTimeModalState: Sendable, Equatable { case neverShown, showing, shown }

public struct GroupAddition: Sendable, Equatable {
    public var selectedConversationIds: [String]
    public var maximumGroupSizeModalState: OneTimeModalState
    public var recommendedGroupSizeModalState: OneTimeModalState

    public init(selectedConversationIds: [String] = [], maximumGroupSizeModalState: OneTimeModalState = .neverShown,
                recommendedGroupSizeModalState: OneTimeModalState = .neverShown) {
        self.selectedConversationIds = selectedConversationIds
        self.maximumGroupSizeModalState = maximumGroupSizeModalState
        self.recommendedGroupSizeModalState = recommendedGroupSizeModalState
    }

    /// `toggleSelectedContactForGroupAddition`
    public mutating func toggle(_ conversationId: String, maxGroupSize: Int, maxRecommendedGroupSize: Int, numberOfContactsAlreadyInGroup: Int) {
        let old = selectedConversationIds
        var next = old.filter { $0 != conversationId }
        if next.count == old.count {
            let expected = next.count + numberOfContactsAlreadyInGroup + 1
            if expected <= maxGroupSize {
                if expected == maxGroupSize && maximumGroupSizeModalState == .neverShown {
                    maximumGroupSizeModalState = .showing
                } else if expected >= maxRecommendedGroupSize && recommendedGroupSizeModalState == .neverShown {
                    recommendedGroupSizeModalState = .showing
                }
                next.append(conversationId)
            }
        }
        selectedConversationIds = next
    }

    /// `getGroupSizeRecommendedLimit(151)` and `max(getGroupSizeHardLimit(1001), recommended + 1)`
    /// from the remote config's values.
    public static func limits(recommended: Int?, hard: Int?) -> (recommended: Int, hard: Int) {
        let r = recommended ?? 151
        return (r, max(hard ?? 1001, r + 1))
    }
}
