import CryptoKit
import Foundation
import Testing
@testable import VideoVP9

/// Expected SHA-256 values come from the scalar predictor, convolve and loop
/// filter functions of libvpx on these same generated sample planes.
struct VP9PredictionTests {
    private func pixel(_ x: Int, _ y: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: 29*x + 71*y + ((x*y)>>2))
    }

    private func source() -> VP9Plane {
        var plane = VP9Plane(width: 64, height: 64)
        for y in 0..<64 {
            for x in 0..<64 { plane.bytes[y*plane.stride+x] = pixel(x,y) }
        }
        return plane
    }

    private func record(_ plane: VP9Plane, x: Int, y: Int, width: Int, height: Int, into output: inout Data) {
        for row in y..<(y+height) {
            let offset = row*plane.stride+x
            output.append(contentsOf: plane.bytes[offset..<(offset+width)])
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
    }

    @Test func directionalAndEdgePredictorsMatchLibvpx() {
        let original = source()
        var output = Data()
        for size in [4,8,16,32] {
            for edges in 0..<8 {
                for mode in 0..<10 {
                    var plane = original
                    plane.predictIntra(mode: mode, x: 16, y: 16, size: size,
                                       tileLeft: edges&2 != 0 ? 0 : 16, tileTop: edges&1 != 0 ? 0 : 16,
                                       haveRight: edges&4 != 0)
                    record(plane, x: 16, y: 16, width: size, height: size, into: &output)
                }
            }
        }
        #expect(digest(output) == "09c8c56e9edd0907a564f2dd292ae6a84226bb21818d33fc79a2b0408a7ad0b2")
    }

    @Test func scaledAndUnscaledPhasesMatchLibvpx() {
        let reference = source()
        var output = Data()
        for filter in 0..<4 {
            for phaseX in 0..<16 {
                for phaseY in 0..<16 {
                    for scaled in [false,true] {
                        var plane = VP9Plane(width: 8, height: 8)
                        plane.predictInter(reference: reference, x: 0, y: 0, width: 8, height: 8,
                                           sourceX16: 256+phaseX, sourceY16: 256+phaseY,
                                           stepX16: scaled ? 21 : 16, stepY16: scaled ? 11 : 16, filter: filter)
                        record(plane, x: 0, y: 0, width: 8, height: 8, into: &output)
                    }
                }
            }
        }
        #expect(digest(output) == "a6017f7ce646ef30c9706515b1d04316b4abcfae5120db7bf00c869de2d80a22")
    }

    /// A DCT block whose only coefficient is DC skips the 2-D transform (libvpx's idct*_1 path):
    /// the shortcut must equal the full transform at every position, for every Int16 DC value
    /// and every size.
    @Test func dcOnlyBlocksMatchTheFullTransform() {
        for size in [4, 8, 16, 32] {
            var mismatches = 0
            for dc in Int(Int16.min)...Int(Int16.max) {
                var block = [Int](repeating: 0, count: size*size)
                block[0] = dc
                VP9Transform.apply(&block, size: size, type: 0, lossless: false)
                let value = VP9Transform.dcOnly(dc, size: size)
                if block.contains(where: { $0 != value }) { mismatches += 1 }
            }
            #expect(mismatches == 0, "size \(size)")
        }
    }

    /// The plane filter runs two units along an edge as 8 vector lanes; each lane must equal
    /// the scalar kernel on its own line, for every mix of widths (incl. unfiltered units),
    /// levels, sharpness and direction, on content built to reach the flat and wide paths.
    @Test func vectorDeblockingMatchesScalar() {
        var seed: UInt64 = 0x9e3779b97f4a7c15
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        var cases = 0
        for trial in 0..<1500 {
            var original = VP9Plane(width: 32, height: 32)
            let base = 40 + next(160), jump = [0, 1, 2, 5, 12, 40][next(6)], noise = [0, 1, 2, 4][next(4)]
            for y in 0..<32 { for x in 0..<32 {
                let side = trial.isMultiple(of: 2) ? x : y
                original.bytes[y*original.stride+x] = UInt8(clamping: base + (side >= 16 ? jump : 0) + next(noise+1))
            } }
            let vertical = trial.isMultiple(of: 2)
            let taps = ([0, 4, 8, 16][next(4)], [0, 4, 8, 16][next(4)])
            let levels = (1 + next(63), 1 + next(63)), sharpness = next(8)
            let along = 8 + next(16)
            let index = vertical ? along*original.stride + 16 : 16*original.stride + along
            let step = vertical ? 1 : original.stride, increment = vertical ? original.stride : 1
            var scalar = original, lanes = original
            for (unit, (width, level)) in [(taps.0, levels.0), (taps.1, levels.1)].enumerated() where width != 0 {
                for i in 0..<4 {
                    scalar.filterSample(at: index + (unit*4 + i)*increment, step: step, taps: width, level: level, sharpness: sharpness)
                }
            }
            lanes.filterPair(at: index, step: step, increment: increment, taps: taps, levels: levels, sharpness: sharpness)
            #expect(lanes.bytes == scalar.bytes, "trial \(trial): taps \(taps) levels \(levels) sharpness \(sharpness)")
            if lanes.bytes != original.bytes { cases += 1 }
        }
        #expect(cases > 500)
    }

    @Test func deblockingThresholdsAndWidthsMatchLibvpx() {
        var output = Data()
        for taps in [4,8,16] {
            for pattern in 0..<8 {
                var original = VP9Plane(width: 8, height: 16)
                for y in 0..<16 {
                    for x in 0..<8 {
                        let noise = Int(pixel(x,y*7)) % (pattern+1)
                        let step = y < 8 ? -2 : 3
                        let outer = !pattern.isMultiple(of: 2) && y > 9 ? 2 : 0
                        original.bytes[y*original.stride+x] = UInt8(114+step+outer+noise)
                    }
                }
                for level in stride(from: 1, to: 64, by: 3) {
                    for sharpness in 0..<8 {
                        var plane = original
                        for x in 0..<8 {
                            plane.filterSample(at: 8*plane.stride+x, step: plane.stride, taps: taps,
                                               level: level, sharpness: sharpness)
                        }
                        record(plane, x: 0, y: 0, width: 8, height: 16, into: &output)
                    }
                }
            }
        }
        #expect(digest(output) == "9d70afba806b4c8b31b78c0192076adbe6053dc49ea91d91d633d17214b6fbb9")
    }
}
