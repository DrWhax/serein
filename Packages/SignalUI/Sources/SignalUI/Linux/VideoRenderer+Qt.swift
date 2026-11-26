#if os(Linux)
import CodecCore
import Foundation

/// Converts already-decoded planar video to straight RGBA for the Qt window.
public enum VideoRenderer {
    private static let pq = HDRToneMap(pq: true, bt2020: true), hlg = HDRToneMap(pq: false, bt2020: true)

    static func image(_ frame: VideoPlanes, rotation: Int = 0, mirrored: Bool = false) -> RGBAImage? {
        guard frame.isValid else { return nil }
        let w = frame.width, h = frame.height, cw = (w + 1) / 2, ch = (h + 1) / 2
        let turn = ((rotation / 90) % 4 + 4) % 4
        let (ow, oh) = turn.isMultiple(of: 2) ? (w, h) : (h, w)
        let deep = frame.bitDepth > 8
        let scale = Double(1 << (frame.bitDepth - 8))
        let full = frame.fullRange, mode = colour(matrix: frame.matrix, transfer: frame.transfer, height: frame.decodedHeight)
        let tone: HDRToneMap? = mode == .pq ? pq : mode == .hlg ? hlg : nil
        let yOffset = full ? 0.0 : 16.0, yScale = full ? 255.0 : 219.0, cScale = full ? 255.0 : 224.0
        let coefficients: (r: Double, gu: Double, gv: Double, b: Double) = switch mode {
        case .bt601: (1.402, 0.344136, 0.714136, 1.772)
        case .bt709: (1.5748, 0.1873, 0.4681, 1.8556)
        default: (1.4746, 0.16455, 0.57135, 1.8814)
        }
        func sample(_ plane: [UInt8], _ index: Int) -> Double {
            if deep { return Double(Int(plane[2 * index]) | Int(plane[2 * index + 1]) << 8) / scale }
            return Double(plane[index])
        }
        // Match the Metal sampler's center-aligned, bilinear chroma upsampling.
        func taps(_ i: Int, _ source: Int, _ target: Int) -> (Int, Int, Double) {
            let x = (Double(i) + 0.5) * Double(source) / Double(target) - 0.5
            let lo = Int(floor(x))
            return (min(source - 1, max(0, lo)), min(source - 1, max(0, lo + 1)), x - Double(lo))
        }
        let horizontal = (0..<w).map { taps($0, cw, w) }
        func byte(_ v: Double) -> UInt8 { UInt8((min(1, max(0, v)) * 255).rounded()) }
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let (top, bottom, fy) = taps(y, ch, h)
            for x in 0..<w {
                let (left, right, fx) = horizontal[x]
                func chroma(_ plane: [UInt8]) -> Double {
                    let a = sample(plane, top * cw + left) * (1 - fx) + sample(plane, top * cw + right) * fx
                    let b = sample(plane, bottom * cw + left) * (1 - fx) + sample(plane, bottom * cw + right) * fx
                    return (a * (1 - fy) + b * fy - 128) / cScale
                }
                let l = (sample(frame.y, y * w + x) - yOffset) / yScale
                let u = chroma(frame.u), v = chroma(frame.v)
                var r = l + coefficients.r * v, g = l - coefficients.gu * u - coefficients.gv * v, b = l + coefficients.b * u
                if let tone { (r, g, b) = tone.map(r, g, b) }
                let mx = mirrored ? w - 1 - x : x
                let offset: Int = switch turn {
                case 1: mx * ow + h - 1 - y
                case 2: (h - 1 - y) * ow + w - 1 - mx
                case 3: (w - 1 - mx) * ow + y
                default: y * ow + mx
                }
                rgba[offset * 4] = byte(r)
                rgba[offset * 4 + 1] = byte(g)
                rgba[offset * 4 + 2] = byte(b)
            }
        }
        return RGBAImage(width: ow, height: oh, pixels: Data(rgba))
    }
}
#endif
