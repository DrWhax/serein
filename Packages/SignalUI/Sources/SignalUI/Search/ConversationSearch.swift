// Port of ts/util/filterAndSortConversations.std.ts: conversations filtered by a search term
// (Fuse with upstream's keys, threshold 0.2, distance 200, extended search; `!command:query`
// debug commands; a parsed phone number OR-ed in) and sorted by recency, score and title.

import Foundation

/// A conversation as the search sees it (`ConversationType`'s searchable fields).
public struct SearchableConversation: Identifiable {
    public var id: String
    public var title: String
    public var listItem: ContactListItemData
    public var activeAt: Double?
    public var isArchived = false
    public var left = false
    public var announcementsOnly = false
    public var areWeAdmin = false
    public var searchableTitle: String?
    public var name: String?
    public var profileName: String?
    public var nicknameGivenName: String?
    public var nicknameFamilyName: String?
    public var systemNickname: String?
    public var systemGivenName: String?
    public var systemFamilyName: String?
    public var firstName: String?
    public var familyName: String?
    public var username: String?
    public var e164: String?
    public var serviceId: String?
    public var pni: String?
    public var groupId: String?
    public var unreadCount = 0
    public var markedUnread = false

    public init(listItem: ContactListItemData, activeAt: Double? = nil) {
        id = listItem.id
        title = listItem.title
        self.listItem = listItem
        self.activeAt = activeAt
    }
}

public enum ConversationSearch {
    static let week: Double = 7 * 24 * 60 * 60 * 1000
    static let activeAtScoreFactor = (1 / week) * 0.01
    static let archivedPenalty = 0.3
    static let leftGroupPenalty = 1.0

    /// `removeDiacritics`: NFD without `\p{Diacritic}`.
    static func removeDiacritics(_ s: String) -> String {
        String(String.UnicodeScalarView(s.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !$0.properties.isDiacritic }))
    }

    /// `toSearchableTokens`: diacritics removed, punctuation as spaces.
    static func toSearchableTokens(_ s: String) -> String {
        String(String.UnicodeScalarView(removeDiacritics(s).unicodeScalars.map { scalar in
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation, .finalPunctuation, .otherPunctuation:
                " "
            default: scalar
            }
        }))
    }

    static let keys: [Fuse.Key] = ["searchableTitle", "title", "name", "profileName", "nicknameGivenName", "nicknameFamilyName", "systemNickname",
                                   "systemGivenName", "systemFamilyName", "firstName", "familyName", "username"].map { Fuse.Key($0) }
        + [Fuse.Key("e164", weight: 0.5)]

    static func fields(_ c: SearchableConversation) -> [String?] {
        let text: [String?] = [c.searchableTitle, c.title, c.name, c.profileName, c.nicknameGivenName, c.nicknameFamilyName, c.systemNickname,
                               c.systemGivenName, c.systemFamilyName, c.firstName, c.familyName, c.username]
        return text.map { $0.map(toSearchableTokens) } + [c.e164 ?? ""]
    }

    static var fuseOptions: Fuse.Options {
        Fuse.Options(threshold: 0.2, distance: 200, useExtendedSearch: true)
    }

    /// `parseAndFormatPhoneNumber(…).e164`, for the search: `+` and 7–15 digits, or a national
    /// number in a region whose calling code we know. (Upstream uses libphonenumber.)
    public static func phoneNumberE164(_ input: String, regionCode: String?) -> String? {
        let digits = input.filter(\.isASCII).filter(\.isNumber)
        let allowed = input.allSatisfy { $0.isNumber || " +-().".contains($0) }
        guard allowed, !digits.isEmpty else { return nil }
        if input.trimmingCharacters(in: .whitespaces).hasPrefix("+") { return (7...15).contains(digits.count) ? "+" + digits : nil }
        let callingCodes = ["US": "1", "CA": "1", "GB": "44", "DE": "49", "FR": "33"]
        guard let region = regionCode, let code = callingCodes[region] else { return nil }
        if code == "1" { return digits.count == 10 ? "+1" + digits : digits.count == 11 && digits.hasPrefix("1") ? "+" + digits : nil }
        let national = digits.hasPrefix("0") ? String(digits.dropFirst()) : digits
        return (6...12).contains(national.count) ? "+" + code + national : nil
    }

    /// `COMMANDS`
    static func command(_ name: String, _ query: String, _ conversations: [SearchableConversation]) -> [SearchableConversation]? {
        switch name {
        case "serviceIdEndsWith", "aciEndsWith": conversations.filter { $0.serviceId?.hasSuffix(query) ?? false }
        case "pniEndsWith": conversations.filter { $0.pni?.hasSuffix(query) ?? false }
        case "idEndsWith": conversations.filter { $0.id.hasSuffix(query) }
        case "e164EndsWith": conversations.filter { $0.e164?.hasSuffix(query) ?? false }
        case "groupIdEndsWith": conversations.filter { $0.groupId?.hasSuffix(query) ?? false }
        case "unread": conversations.filter { $0.unreadCount > 0 || $0.markedUnread }
        default: nil
        }
    }

    /// `searchConversations`: (conversation, Fuse score) in Fuse's order.
    static func searchConversations(_ conversations: [SearchableConversation], _ searchTerm: String, regionCode: String?) -> [(SearchableConversation, Double?)] {
        if searchTerm.hasPrefix("!"), !searchTerm.contains(where: \.isWhitespace) {
            let body = searchTerm.dropFirst()
            let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if let name = parts.first, !name.isEmpty, let found = command(String(name), parts.count > 1 ? String(parts[1]) : "", conversations) {
                return found.map { ($0, nil) }
            }
        }
        var query = toSearchableTokens(searchTerm)
        if let e164 = phoneNumberE164(searchTerm, regionCode: regionCode) { query += " | \(e164)" }
        let fuse = Fuse(documents: conversations.map(fields), keys: keys, options: fuseOptions)
        return fuse.search(query).map { (conversations[$0.refIndex], $0.score) }
    }

    /// `startsWithLetter` / `sortAlphabetically`: titles starting with a letter first, then
    /// `localeCompare`.
    static func alphabeticalOrder(_ a: SearchableConversation, _ b: SearchableConversation) -> Bool {
        func startsWithLetter(_ s: String) -> Bool {
            guard let first = s.unicodeScalars.first else { return false }
            switch first.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
            default: return false
            }
        }
        let la = startsWithLetter(a.title), lb = startsWithLetter(b.title)
        if la != lb { return la }
        return a.title.compare(b.title, locale: Locale(identifier: "en")) == .orderedAscending
    }

    /// `filterAndSortConversations`
    public static func filterAndSort(_ conversations: [SearchableConversation], searchTerm: String, regionCode: String?,
                                     now: Double = Date().timeIntervalSince1970 * 1000) -> [SearchableConversation] {
        if !searchTerm.isEmpty {
            let titled = conversations.filter { !$0.title.isEmpty }
            let results = searchConversations(titled, searchTerm, regionCode: regionCode)
            func score(_ r: (SearchableConversation, Double?)) -> Double {
                (now - (r.0.activeAt ?? 0)) * activeAtScoreFactor + (r.1 ?? 0) + (r.0.left ? leftGroupPenalty : 0) + (r.0.isArchived ? archivedPenalty : 0)
            }
            // A stable sort, as Array.prototype.sort.
            return results.enumerated().sorted { x, y in
                let d = score(x.element) - score(y.element)
                if d != 0 { return d < 0 }
                if alphabeticalOrder(x.element.0, y.element.0) { return true }
                if alphabeticalOrder(y.element.0, x.element.0) { return false }
                return x.offset < y.offset
            }.map(\.element.0)
        }
        return conversations.enumerated().sorted { x, y in
            let d = (y.element.activeAt ?? 0) - (x.element.activeAt ?? 0)
            if d != 0 { return d < 0 }
            if alphabeticalOrder(x.element, y.element) { return true }
            if alphabeticalOrder(y.element, x.element) { return false }
            return x.offset < y.offset
        }.map(\.element)
    }
}
