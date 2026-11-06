// Message search (upstream searchMessages in ts/sql/Server.node.ts): the query's tokens as
// FTS5 prefix phrases over messages_fts, newest first, with a snippet whose matches are
// marked <<left>>…<<right>> and cuts <<truncation>>; within one conversation or all.

import Foundation
import GRDB

public struct MessageSearchHit: Sendable, Equatable {
    public var id: String
    public var conversationId: String
    public var sentAt: Int64
    public var body: String
    public var snippet: String
    public var author: String?
    public var outgoing: Bool
}

extension ConversationQueries {
    /// `signalTokenize`'s role: words (letters, digits, marks), each as `"word"*`.
    static func ftsQuery(_ query: String) -> String {
        var tokens: [String] = []
        var current = ""
        for scalar in query.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " ")
    }

    public static func searchMessages(_ db: Database, query: String, conversationId: String? = nil, limit: Int? = nil) throws -> [MessageSearchHit] {
        let q = ftsQuery(query)
        guard !q.isEmpty else { return [] }
        return try Row.fetchAll(db, sql: """
            SELECT m.id, m.conversationId, m.sent_at, m.body, m.sourceServiceId, m.type,
              snippet(messages_fts, -1, '<<left>>', '<<right>>', '<<truncation>>', 10) AS snippet
            FROM messages_fts JOIN messages m ON m.rowid = messages_fts.rowid
            WHERE messages_fts.body MATCH ? AND (? IS NULL OR m.conversationId = ?) AND m.type IN ('incoming', 'outgoing')
              AND coalesce(json_extract(m.json, '$.deletedForEveryone'), 0) = 0
            ORDER BY m.received_at DESC, m.sent_at DESC LIMIT ?
            """, arguments: [q, conversationId, conversationId, limit ?? (conversationId != nil ? 100 : 500)]).map { row in
                MessageSearchHit(id: row["id"], conversationId: row["conversationId"], sentAt: row["sent_at"] ?? 0, body: row["body"] ?? "",
                                 snippet: row["snippet"] ?? "", author: row["sourceServiceId"], outgoing: (row["type"] as String?) == "outgoing")
            }
    }
}
