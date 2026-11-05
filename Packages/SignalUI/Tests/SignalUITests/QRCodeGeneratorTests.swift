// QRCodeGenerator against qrcode-generator 2.0.4 (Fixtures/qrcode-generator-vectors.json,
// written by running the JS library on the same inputs at every level).

import Foundation
import Testing
@testable import SignalUI

@Suite struct QRCodeGeneratorTests {
    @Test func matchesQrcodeGenerator() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/qrcode-generator-vectors", withExtension: "json"))
        let vectors = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
        #expect(vectors.count == 20)
        for (key, rows) in vectors {
            let level = try #require(QRCodeGenerator.ErrorCorrectionLevel(name: String(key.prefix(1))))
            let qr = try #require(QRCodeGenerator(string: String(key.dropFirst(2)), level: level))
            let actual = (0..<qr.moduleCount).map { r in String((0..<qr.moduleCount).map { qr.isDark(row: r, col: $0) ? "1" : "0" }) }
            #expect(actual == rows, "\(key.prefix(40))")
        }
    }
}

extension QRCodeGenerator.ErrorCorrectionLevel {
    init?(name: String) {
        switch name {
        case "L": self = .L
        case "M": self = .M
        case "Q": self = .Q
        case "H": self = .H
        default: return nil
        }
    }
}
