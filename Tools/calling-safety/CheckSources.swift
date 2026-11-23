import Foundation
import SwiftParser
import SwiftSyntax

// Use syntax tokens so comments, string contents and whitespace between annotations
// cannot change the verdict. Inspect inactive compilation branches and interpolations too.
let forbidden = Set(["unsafe", "unsafeBitCast", "unsafeDowncast",
                     "Unmanaged", "OpaquePointer", "unsafeAddress", "unsafeMutableAddress",
                     "_silgen_name", "_cdecl", "_extern", "_semantics"])
var violations = 0
for path in CommandLine.arguments.dropFirst() {
    let tree = Parser.parse(source: try String(contentsOfFile: path, encoding: .utf8))
    let locations = SourceLocationConverter(fileName: path, tree: tree)
    var previous = ""
    for token in tree.tokens(viewMode: .sourceAccurate) {
        let name = token.text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        switch token.tokenKind {
        case .keyword, .identifier:
            if forbidden.contains(name) || name.hasPrefix("Unsafe") || name.contains("withUnsafe")
                || (previous == "@" && ["safe", "unchecked", "preconcurrency", "c", "convention"].contains(name)) {
                let line = locations.location(for: token.positionAfterSkippingLeadingTrivia).line
                print("\(path):\(line): calling safety policy rejects '\(name)'")
                violations += 1
            }
        default: break
        }
        previous = token.text
    }
}
if violations > 0 { exit(1) }
