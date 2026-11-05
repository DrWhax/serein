// SVG path data (SVG 2 §9.3, the `d` attribute grammar) → SwiftUI Path, for upstream's
// inline vector artwork (AxoBrand, …). A recursive-descent parser over the bytes of a
// trusted, compile-time string; elliptical arcs become cubic Béziers (SVG 2 appendix B.2).
//
//   path      ::= wsp* (command (wsp* args)*)*
//   number    ::= sign? (digits ('.' digits?)? | '.' digits) exponent?
//   flag      ::= '0' | '1'                  (arc flags need no separator)
//   comma-wsp ::= (wsp+ ','? wsp*) | (',' wsp*)

import CoreGraphics
import Foundation
import SwiftUI

public enum SVGPathData {
    /// Parses path data; nil if it does not follow the grammar.
    public static func parse(_ d: String) -> Path? {
        var parser = Parser(bytes: Array(d.utf8))
        return parser.parsePath()
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        /// Reflection source for S/s (last cubic control) and T/t (last quadratic control).
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { i >= bytes.count }
        var peek: UInt8? { i < bytes.count ? bytes[i] : nil }

        static func isWsp(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }
        static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

        mutating func skipWsp() { while let c = peek, Self.isWsp(c) { i += 1 } }
        mutating func skipCommaWsp() {
            skipWsp()
            if peek == 0x2C { i += 1 }
            skipWsp()
        }

        /// Does a number (or flag) start here?
        var atNumberStart: Bool {
            guard let c = peek else { return false }
            return Self.isDigit(c) || c == 0x2B || c == 0x2D || c == 0x2E
        }

        mutating func number() -> CGFloat? {
            let start = i
            if peek == 0x2B || peek == 0x2D { i += 1 }
            var digits = 0
            while let c = peek, Self.isDigit(c) { i += 1; digits += 1 }
            if peek == 0x2E {
                i += 1
                while let c = peek, Self.isDigit(c) { i += 1; digits += 1 }
            }
            guard digits > 0 else { i = start; return nil }
            if peek == 0x65 || peek == 0x45 {                       // e / E
                let mark = i
                i += 1
                if peek == 0x2B || peek == 0x2D { i += 1 }
                var expDigits = 0
                while let c = peek, Self.isDigit(c) { i += 1; expDigits += 1 }
                if expDigits == 0 { i = mark }
            }
            guard let s = String(bytes: bytes[start..<i], encoding: .ascii), let v = Double(s) else { return nil }
            return CGFloat(v)
        }

        mutating func flag() -> Bool? {
            guard let c = peek, c == 0x30 || c == 0x31 else { return nil }
            i += 1
            return c == 0x31
        }

        /// One argument group of `count` numbers, separated by comma-wsp.
        mutating func numbers(_ count: Int) -> [CGFloat]? {
            var out: [CGFloat] = []
            for k in 0..<count {
                if k > 0 { skipCommaWsp() }
                guard let n = number() else { return nil }
                out.append(n)
            }
            return out
        }

        mutating func parsePath() -> Path? {
            skipWsp()
            var first = true
            while let c = peek {
                i += 1
                guard command(c, first: first) else { return nil }
                first = false
                skipWsp()
            }
            return path
        }

        /// A command letter and its repeated argument groups.
        mutating func command(_ c: UInt8, first: Bool) -> Bool {
            let relative = c >= 0x61
            let upper = relative ? c - 0x20 : c
            if first && upper != 0x4D { return false }               // must start with M/m
            skipWsp()
            var groups = 0
            repeat {
                if groups > 0 { skipCommaWsp() }
                switch upper {
                case 0x5A:                                           // Z
                    path.closeSubpath()
                    current = subpathStart
                    lastCubicControl = nil
                    lastQuadControl = nil
                    return true
                case 0x4D:                                           // M (later pairs are L)
                    guard let a = numbers(2) else { return false }
                    let p = point(a[0], a[1], relative)
                    if groups == 0 {
                        path.move(to: p)
                        subpathStart = p
                    } else {
                        path.addLine(to: p)
                    }
                    current = p
                    clearControls()
                case 0x4C:                                           // L
                    guard let a = numbers(2) else { return false }
                    lineTo(point(a[0], a[1], relative))
                case 0x48:                                           // H
                    guard let x = number() else { return false }
                    lineTo(CGPoint(x: relative ? current.x + x : x, y: current.y))
                case 0x56:                                           // V
                    guard let y = number() else { return false }
                    lineTo(CGPoint(x: current.x, y: relative ? current.y + y : y))
                case 0x43:                                           // C
                    guard let a = numbers(6) else { return false }
                    cubic(point(a[0], a[1], relative), point(a[2], a[3], relative), point(a[4], a[5], relative))
                case 0x53:                                           // S
                    guard let a = numbers(4) else { return false }
                    let c1 = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    cubic(c1, point(a[0], a[1], relative), point(a[2], a[3], relative))
                case 0x51:                                           // Q
                    guard let a = numbers(4) else { return false }
                    quad(point(a[0], a[1], relative), point(a[2], a[3], relative))
                case 0x54:                                           // T
                    guard let a = numbers(2) else { return false }
                    let c1 = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    quad(c1, point(a[0], a[1], relative))
                case 0x41:                                           // A
                    guard let r = numbers(3) else { return false }
                    skipCommaWsp()
                    guard let large = flag() else { return false }
                    skipCommaWsp()
                    guard let sweep = flag() else { return false }
                    skipCommaWsp()
                    guard let e = numbers(2) else { return false }
                    arc(rx: r[0], ry: r[1], rotation: r[2], large: large, sweep: sweep, to: point(e[0], e[1], relative))
                default:
                    return false
                }
                groups += 1
                let mark = i
                skipCommaWsp()
                let more = atNumberStart
                i = mark
                if !more { return true }
            } while true
        }

        func point(_ x: CGFloat, _ y: CGFloat, _ relative: Bool) -> CGPoint {
            relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        mutating func clearControls() {
            lastCubicControl = nil
            lastQuadControl = nil
        }

        mutating func lineTo(_ p: CGPoint) {
            path.addLine(to: p)
            current = p
            clearControls()
        }

        mutating func cubic(_ c1: CGPoint, _ c2: CGPoint, _ p: CGPoint) {
            path.addCurve(to: p, control1: c1, control2: c2)
            current = p
            lastCubicControl = c2
            lastQuadControl = nil
        }

        mutating func quad(_ c: CGPoint, _ p: CGPoint) {
            path.addQuadCurve(to: p, control: c)
            current = p
            lastQuadControl = c
            lastCubicControl = nil
        }

        /// Endpoint → centre parameterisation (SVG 2 B.2.4), then ≤ 90° cubic segments.
        mutating func arc(rx rx0: CGFloat, ry ry0: CGFloat, rotation: CGFloat, large: Bool, sweep: Bool, to p: CGPoint) {
            let p1 = current
            var rx = abs(rx0), ry = abs(ry0)
            if p1 == p { clearControls(); return }
            if rx == 0 || ry == 0 { lineTo(p); return }
            let phi = rotation * .pi / 180
            let cosPhi = cos(phi), sinPhi = sin(phi)
            let dx = (p1.x - p.x) / 2, dy = (p1.y - p.y) / 2
            let x1 = cosPhi * dx + sinPhi * dy
            let y1 = -sinPhi * dx + cosPhi * dy
            let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
            if lambda > 1 {
                rx *= sqrt(lambda)
                ry *= sqrt(lambda)
            }
            let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
            let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
            let coef = (large != sweep ? 1 : -1) * sqrt(max(0, num / den))
            let cx1 = coef * rx * y1 / ry
            let cy1 = -coef * ry * x1 / rx
            let cx = cosPhi * cx1 - sinPhi * cy1 + (p1.x + p.x) / 2
            let cy = sinPhi * cx1 + cosPhi * cy1 + (p1.y + p.y) / 2
            func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
                atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            }
            let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
            var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
            if !sweep && delta > 0 { delta -= 2 * .pi }
            if sweep && delta < 0 { delta += 2 * .pi }
            let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
            let step = delta / CGFloat(segments)
            let k = 4 / 3 * tan(step / 4)
            func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * cosPhi * x - ry * sinPhi * y, y: cy + rx * sinPhi * x + ry * cosPhi * y)
            }
            var t = theta1
            for s in 0..<segments {
                let t2 = t + step
                let c1 = map(cos(t) - k * sin(t), sin(t) + k * cos(t))
                let c2 = map(cos(t2) + k * sin(t2), sin(t2) - k * cos(t2))
                let end = s == segments - 1 ? p : map(cos(t2), sin(t2))
                path.addCurve(to: end, control1: c1, control2: c2)
                t = t2
            }
            current = p
            clearControls()
        }
    }
}

/// Fills SVG path data drawn in a `viewBox` (origin 0,0), scaled to the frame.
public struct SVGPathShape: Shape {
    let path: Path
    let viewBox: CGSize

    public init(_ path: Path, viewBox: CGSize) {
        self.path = path
        self.viewBox = viewBox
    }

    public func path(in rect: CGRect) -> Path {
        guard viewBox.width > 0, viewBox.height > 0 else { return Path() }
        // preserveAspectRatio="xMidYMid meet"
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let ox = rect.minX + (rect.width - viewBox.width * scale) / 2
        let oy = rect.minY + (rect.height - viewBox.height * scale) / 2
        return path.applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: ox, ty: oy))
    }
}
