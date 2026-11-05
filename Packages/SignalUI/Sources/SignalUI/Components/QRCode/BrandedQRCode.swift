// Port of ts/components/BrandedQRCode.dom.tsx: the link as a QR code (level H) with rounded
// modules, the centre cleared for a ring and the Signal logo. Drawn in a `size` × `size`
// view box scaled to the frame, as upstream's <svg viewBox>.

import SwiftUI

public struct BrandedQRCode: View {
    let size: CGFloat
    let link: String
    let color: Color

    static let logoPath = "M16.904 32.723V35a17.034 17.034 0 0 1-5.594-1.334l.595-2.22a14.763 14.763 0 0 0 5 1.277ZM9.119 33.064l.667-2.49-5.707 1.338 1.18-5.034-2.382.209-1.22 5.204A1.7 1.7 0 0 0 3.7 34.334l5.419-1.27ZM3.28 19.159c.15 1.91.671 3.77 1.53 5.477l-2.41.21a17.037 17.037 0 0 1-1.397-5.688H3.28ZM3.277 16.885H1c.146-2.223.727-4.4 1.712-6.403l1.972 1.139a14.765 14.765 0 0 0-1.407 5.264ZM5.821 9.652 3.85 8.513a17.035 17.035 0 0 1 4.69-4.68l1.138 1.972a14.763 14.763 0 0 0-3.856 3.847ZM11.648 4.672l-1.139-1.973c2-.978 4.172-1.556 6.395-1.699v2.277a14.762 14.762 0 0 0-5.256 1.395ZM19.177 3.283c1.816.145 3.593.625 5.24 1.42l1.137-1.973a17.034 17.034 0 0 0-6.377-1.725v2.278ZM29.795 9.118c.14.186.276.376.407.568l1.971-1.139a17.035 17.035 0 0 0-4.654-4.675l-1.138 1.973a14.763 14.763 0 0 1 3.414 3.273ZM32.52 15.322c.096.518.163 1.04.203 1.563H35a17.048 17.048 0 0 0-1.694-6.367l-1.973 1.14c.552 1.16.952 2.391 1.187 3.664ZM32.188 22.09a14.759 14.759 0 0 1-.871 2.287l1.972 1.139a17.032 17.032 0 0 0 1.708-6.357H32.72a14.768 14.768 0 0 1-.532 2.93ZM28.867 27.995a14.757 14.757 0 0 1-2.504 2.173l1.139 1.973a17.028 17.028 0 0 0 4.65-4.657l-1.972-1.139c-.396.58-.835 1.13-1.313 1.65ZM23.259 31.797c-1.314.5-2.69.809-4.082.92v2.278a17.033 17.033 0 0 0 6.358-1.716l-1.139-1.972c-.371.179-.75.342-1.137.49Z M11.66 7.265a12.463 12.463 0 0 1 11.9-.423 12.466 12.466 0 0 1 6.42 14.612 12.47 12.47 0 0 1-13.21 8.954 12.462 12.462 0 0 1-5.411-1.857L6.246 29.75l1.199-5.115a12.47 12.47 0 0 1 4.216-17.37Z"
    static let centerCutawayPercentage: CGFloat = 30 / 184
    static let centerLogoPercentage: CGFloat = 38 / 184
    static let qrNativeSize: CGFloat = 36

    public init(size: CGFloat, link: String, color: Color) {
        self.size = size
        self.link = link
        self.color = color
    }

    /// `compute`: the module path (in units of half a module) and the cleared radius.
    static func compute(_ link: String) -> (path: Path, moduleCount: Int, radius: CGFloat)? {
        guard let qr = QRCodeGenerator(string: link, level: .H) else { return nil }
        let n = qr.moduleCount
        let center = CGFloat(n) / 2
        let radius = centerCutawayPercentage * CGFloat(n)
        func hasPixel(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < n, y < n else { return false }
            let distance = ((CGFloat(x) - center + 0.5) * (CGFloat(x) - center + 0.5) + (CGFloat(y) - center + 0.5) * (CGFloat(y) - center + 0.5)).squareRoot()
            // The centre and one dot around it stay clear for the logo.
            if distance.rounded(.up) <= radius + 3 { return false }
            return qr.isDark(row: x, col: y)    // upstream passes (x, y) as (row, col)
        }
        var d = ""
        for y in 0..<n {
            for x in 0..<n where hasPixel(x, y) {
                let top = hasPixel(x, y - 1), bottom = hasPixel(x, y + 1), left = hasPixel(x - 1, y), right = hasPixel(x + 1, y)
                d += "M\(2 * x) \(2 * y + 1)"
                d += !left && !top ? "a1 1 0 0 1 1 -1" : "v-1h1"
                d += !top && !right ? "a1 1 0 0 1 1 1" : "h1v1"
                d += !right && !bottom ? "a1 1 0 0 1 -1 1" : "v1h-1"
                d += !bottom && !left ? "a1 1 0 0 1 -1 -1" : "h-1v-1"
                d += "z"
            }
        }
        return (SVGPathData.parse(d) ?? Path(), n, radius)
    }

    public var body: some View {
        let computed = Self.compute(link)
        let n = CGFloat(computed?.moduleCount ?? 1)
        let qrScale = size / 2 / n
        let logoSize = Self.centerLogoPercentage * size
        let logoScale = logoSize / Self.qrNativeSize
        let box = CGSize(width: size, height: size)
        let scale = CGAffineTransform(scaleX: qrScale, y: qrScale)
        ZStack {
            if let computed { SVGPathShape(computed.path.applying(scale), viewBox: box).fill(color) }
            SVGPathShape((SVGPathData.parse(Self.logoPath) ?? Path())
                .applying(CGAffineTransform(scaleX: logoScale, y: logoScale).concatenating(CGAffineTransform(translationX: size / 2 - logoSize / 2,
                                                                                                           y: size / 2 - logoSize / 2))),
                         viewBox: box).fill(color)
        }
        .overlay {
            // <circle cx=cy={moduleCount} r={radius*2} stroke-width={2}> in module units, scaled
            // with the view box (its centre is the view's).
            GeometryReader { geo in
                let k = min(geo.size.width, geo.size.height) / size
                Circle().stroke(color, lineWidth: 2 * qrScale * k)
                    .frame(width: (computed?.radius ?? 0) * 4 * qrScale * k, height: (computed?.radius ?? 0) * 4 * qrScale * k)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .accessibilityHidden(true)
    }

}
