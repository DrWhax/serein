// Port of ts/components/QrCode.dom.tsx: data as a plain QR code (level L), one module per
// unit, black on white (qrcode-generator's `createSvgTag({ cellSize: 1, margin: 0 })`),
// scaled to the frame.

import SwiftUI

public struct QrCode: View {
    let modules: [[Bool]]
    let alt: String

    public init(data: [UInt8], alt: String) {
        self.init(modules: QRCodeGenerator(bytes: data, level: .L).map(Self.matrix) ?? [], alt: alt)
    }

    public init(text: String, alt: String) {
        self.init(modules: QRCodeGenerator(string: text, level: .L).map(Self.matrix) ?? [], alt: alt)
    }

    /// Already encoded modules (row-major).
    public init(modules: [[Bool]], alt: String) {
        self.modules = modules
        self.alt = alt
    }

    nonisolated static func matrix(_ qr: QRCodeGenerator) -> [[Bool]] {
        (0..<qr.moduleCount).map { r in (0..<qr.moduleCount).map { qr.isDark(row: r, col: $0) } }
    }

    struct Modules: Shape {
        let modules: [[Bool]]
        func path(in rect: CGRect) -> Path {
            let n = CGFloat(max(modules.count, 1))
            let cell = CGSize(width: rect.width / n, height: rect.height / n)
            var p = Path()
            for (r, row) in modules.enumerated() {
                for (c, dark) in row.enumerated() where dark {
                    p.addRect(CGRect(x: rect.minX + CGFloat(c) * cell.width, y: rect.minY + CGFloat(r) * cell.height, width: cell.width, height: cell.height))
                }
            }
            return p
        }
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(Color.white)
            Modules(modules: modules).fill(Color.black)
        }
        .accessibilityElement()
        .accessibilityLabel(alt)
        .accessibilityAddTraits(.isImage)
    }
}
