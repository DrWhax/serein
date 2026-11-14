// A parsed protobuf message as the message parser service hands it to the app: the known fields
// of a typed message (unknown ones are dropped), as a flat list, so that neither side's decoder
// recurses on what the other sent.
//
//   tree  = node*                    node 0 is the root message
//   node  = parent field kind bits bytes
//
// Every node after the root belongs to an earlier message node (`parent`), in field order;
// a message node's fields are the nodes naming it. One node carries one value: a repeated field
// is a node per element. `kind` is the protobuf wire type the value would have (varint, fixed32,
// fixed64, bytes, or a nested message); `bits` holds the numbers (an integer's two's-complement
// bits, a float's or double's IEEE bits), `bytes` strings (UTF-8) and bytes.
//
// `validated()` checks the whole shape before anything is decoded from it: the root, parents
// before children and only message nodes as parents, field numbers in range, values only where
// their kind has them, a bounded depth and size. The app decodes only a validated tree
// (TreeDecoder).

import Foundation

public struct ProtoTree: Codable, Sendable, Equatable {
    public enum Kind: UInt8, Codable, Sendable {
        case message = 0, varint, fixed32, fixed64, bytes
    }

    public struct Node: Codable, Sendable, Equatable {
        public var p: UInt32
        public var f: UInt32
        public var k: Kind
        public var v: UInt64
        public var d: Data

        public init(parent: UInt32, field: UInt32, kind: Kind, bits: UInt64 = 0, bytes: Data = Data()) {
            p = parent
            f = field
            k = kind
            v = bits
            d = bytes
        }
    }

    public var nodes: [Node]

    public init(nodes: [Node] = [Node(parent: 0, field: 0, kind: .message)]) { self.nodes = nodes }

    private enum CodingKeys: String, CodingKey { case nodes }

    /// Enforce limits while decoding the helper's wire representation, not after an unbounded
    /// array has already been materialized. `validated` still checks shape before typed decode.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var input = try container.nestedUnkeyedContainer(forKey: .nodes)
        var nodes: [Node] = []
        var bytes = 0
        while !input.isAtEnd {
            guard nodes.count < Limits.maxNodes else { throw TreeError.tooLarge }
            let node = try input.decode(Node.self)
            guard node.d.count <= Limits.maxBytes - bytes else { throw TreeError.tooLarge }
            bytes += node.d.count
            nodes.append(node)
        }
        self.nodes = nodes
    }

    /// A reply's budget is aggregate: splitting values among trees must not multiply it.
    public static func validateBudget(_ trees: [ProtoTree], maxNodes: Int = Limits.maxNodes, maxBytes: Int = Limits.maxBytes) throws {
        var budget = Budget(nodes: maxNodes, bytes: maxBytes)
        for tree in trees { try budget.consume(tree) }
    }

    struct Budget {
        var nodes = Limits.maxNodes
        var bytes = Limits.maxBytes
        mutating func consume(_ tree: ProtoTree) throws {
            guard nodes >= 0, bytes >= 0, tree.nodes.count <= nodes else { throw TreeError.tooLarge }
            nodes -= tree.nodes.count
            for node in tree.nodes {
                guard node.d.count <= bytes else { throw TreeError.tooLarge }
                bytes -= node.d.count
            }
        }
    }

    public enum Limits {
        /// Message nesting (SwiftProtobuf's own default is 100; Signal's messages nest a handful).
        public static let maxDepth = 64
        public static let maxNodes = 1 << 20
        public static let maxBytes = 64 << 20
        /// The largest protobuf field number.
        public static let maxField: UInt32 = (1 << 29) - 1
    }

    public enum TreeError: Error, Equatable {
        case malformed(String)
        case tooDeep
        case tooLarge
    }

    /// The fields of each message node, in order (empty for the other nodes), once the tree is
    /// known to be well formed.
    public struct Validated: Sendable {
        public let tree: ProtoTree
        public let children: [[Int]]
    }

    public func validated() throws -> Validated {
        try Self.validateBudget([self])
        guard !nodes.isEmpty, nodes.count <= Limits.maxNodes else { throw nodes.isEmpty ? TreeError.malformed("empty") : TreeError.tooLarge }
        let root = nodes[0]
        guard root.k == .message, root.p == 0, root.f == 0, root.v == 0, root.d.isEmpty else { throw TreeError.malformed("root") }
        var children = [[Int]](repeating: [], count: nodes.count)
        var depth = [Int](repeating: 0, count: nodes.count)
        for i in 1..<nodes.count {
            let n = nodes[i]
            let parent = Int(n.p)
            guard parent < i, nodes[parent].k == .message else { throw TreeError.malformed("parent of node \(i)") }
            guard n.f >= 1, n.f <= Limits.maxField, !(19000...19999).contains(n.f) else { throw TreeError.malformed("field number of node \(i)") }
            switch n.k {
            case .message: guard n.v == 0, n.d.isEmpty else { throw TreeError.malformed("message node \(i) has a value") }
            case .varint: guard n.d.isEmpty else { throw TreeError.malformed("varint node \(i) has bytes") }
            case .fixed32: guard n.d.isEmpty, n.v <= UInt64(UInt32.max) else { throw TreeError.malformed("fixed32 node \(i)") }
            case .fixed64: guard n.d.isEmpty else { throw TreeError.malformed("fixed64 node \(i) has bytes") }
            case .bytes: guard n.v == 0 else { throw TreeError.malformed("bytes node \(i) has bits") }
            }
            depth[i] = depth[parent] + 1
            guard depth[i] <= Limits.maxDepth else { throw TreeError.tooDeep }
            children[parent].append(i)
        }
        return Validated(tree: self, children: children)
    }
}
