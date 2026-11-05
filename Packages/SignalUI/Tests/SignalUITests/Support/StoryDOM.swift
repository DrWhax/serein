// A story's captured DOM (References/<id>.<theme>.dom.json, Tools/capture-storybook.mjs):
// the elements in document order, for stories whose data is random (getDefaultConversation
// names, kitten-N avatars) and has to be read back from the capture.

import Foundation

struct StoryDOM {
    struct Node {
        let tag: String
        let cls: String
        let text: String?
        let src: String?
        let rect: [Double]
        let style: [String: String]
        /// The fixture file named in a `url(…/fixtures/<name>)` background image or src.
        var fixture: String? {
            for s in [style["backgroundImage"], src].compactMap({ $0 }) {
                if let r = s.range(of: "fixtures/") {
                    return String(s[r.upperBound...].prefix { $0 != "\"" && $0 != ")" && $0 != "?" })
                }
            }
            return nil
        }
    }

    let nodes: [Node]

    init(_ id: String, theme: String = "light") {
        let url = Bundle.module.url(forResource: "References", withExtension: nil)!.appendingPathComponent("\(id).\(theme).dom.json")
        var out: [Node] = []
        func walk(_ v: Any) {
            if let a = v as? [Any] { a.forEach(walk); return }
            guard let o = v as? [String: Any] else { return }
            out.append(Node(tag: o["tag"] as? String ?? "", cls: o["cls"] as? String ?? "", text: o["text"] as? String, src: o["src"] as? String,
                            rect: o["rect"] as? [Double] ?? [], style: (o["style"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }))
            (o["children"] as? [Any])?.forEach(walk)
        }
        if let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) { walk(json) }
        nodes = out
    }

    /// The nodes from each element whose class list contains `cls` up to the next one.
    func groups(startingWith cls: String) -> [[Node]] {
        var out: [[Node]] = []
        for n in nodes {
            if n.cls.split(separator: " ").contains(Substring(cls)) { out.append([n]) } else if !out.isEmpty { out[out.count - 1].append(n) }
        }
        return out
    }
}
