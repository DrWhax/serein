// What an AV1 video decoder keeps between frames: the eight reference slots (7.20, reference
// frame update; 7.21, loading), and the processes of the uncompressed header that read them —
// set_frame_refs (7.8), get_relative_dist, skip mode references, load_previous.

/// Reference frame names (LAST_FRAME = 1 … ALTREF_FRAME = 7; INTRA_FRAME = 0, NONE = -1).
enum AV1Ref {
    static let none = -1, intra = 0, last = 1, last2 = 2, last3 = 3, golden = 4, bwdref = 5, altref2 = 6, altref = 7
    static let primaryRefNone = 7
}

enum AV1FrameType {
    static let key = 0, inter = 1, intraOnly = 2, switchFrame = 3
}

/// One reference slot: the frame's size, order, samples (after the loop filters, before film
/// grain), motion field, and the coding state later frames may load from it.
struct AV1RefSlot: Sendable {
    var valid = false
    var frameId = 0
    var upscaledWidth = 0, frameWidth = 0, frameHeight = 0, renderWidth = 0, renderHeight = 0
    var miCols = 0, miRows = 0
    var frameType = 0
    var subX = 1, subY = 1, bitDepth = 8
    var orderHint = 0
    /// OrderHints[LAST_FRAME …ALTREF_FRAME] of that frame (index by reference name).
    var savedOrderHints = [Int](repeating: 0, count: 8)
    /// Its samples, once its reconstruction job has run.
    var pixels: AV1Pixels?
    /// MfRefFrames and MfMvs (row, col) per mode info unit.
    var savedRefFrames: [Int8] = []
    var savedMvs: [Int32] = []
    var gmParams = AV1Global.identityParams
    var segmentIds: [UInt8] = []
    /// Units per row of segmentIds.
    var segmentStride = 0
    var cdf: [UInt16] = []
    var filmGrain = AV1FilmGrainParams()
    var lfRefDeltas = AV1Global.defaultRefDeltas
    var lfModeDeltas = [0, 0]
    var featureEnabled = [[Bool]](repeating: [Bool](repeating: false, count: 8), count: 8)
    var featureData = [[Int]](repeating: [Int](repeating: 0, count: 8), count: 8)
    var showableFrame = false
}

enum AV1Global {
    static let warpedModelPrecBits = 16
    static let identityParams: [[Int]] = (0..<8).map { _ in (0..<6).map { $0 % 3 == 2 ? 1 << 16 : 0 } }
    static let defaultRefDeltas = [1, 0, 0, 0, -1, 0, -1, -1]
}

extension AV1SequenceHeader {
    /// get_relative_dist (5.9.2).
    func relativeDist(_ a: Int, _ b: Int) -> Int {
        guard enableOrderHint else { return 0 }
        var diff = a - b
        let m = 1 << (orderHintBits - 1)
        diff = (diff & (m - 1)) - (diff & m)
        return diff
    }
}

extension AV1FrameHeader {
    /// set_frame_refs (7.8): ref_frame_idx from last_frame_idx and gold_frame_idx.
    static func setFrameRefs(_ s: AV1SequenceHeader, refs: [AV1RefSlot], orderHint: Int, last: Int, gold: Int) -> [Int] {
        var idx = [Int](repeating: -1, count: 7)
        idx[AV1Ref.last - 1] = last
        idx[AV1Ref.golden - 1] = gold
        var used = [Bool](repeating: false, count: 8)
        used[last] = true
        used[gold] = true
        let cur = 1 << (s.orderHintBits - 1)
        let shifted = refs.map { cur + s.relativeDist($0.orderHint, orderHint) }
        func latestBackward() -> Int {
            var ref = -1, latest = 0
            for i in 0..<8 where !used[i] && shifted[i] >= cur && (ref < 0 || shifted[i] >= latest) { ref = i; latest = shifted[i] }
            return ref
        }
        func earliestBackward() -> Int {
            var ref = -1, earliest = 0
            for i in 0..<8 where !used[i] && shifted[i] >= cur && (ref < 0 || shifted[i] < earliest) { ref = i; earliest = shifted[i] }
            return ref
        }
        func latestForward() -> Int {
            var ref = -1, latest = 0
            for i in 0..<8 where !used[i] && shifted[i] < cur && (ref < 0 || shifted[i] >= latest) { ref = i; latest = shifted[i] }
            return ref
        }
        var r = latestBackward()
        if r >= 0 { idx[AV1Ref.altref - 1] = r; used[r] = true }
        r = earliestBackward()
        if r >= 0 { idx[AV1Ref.bwdref - 1] = r; used[r] = true }
        r = earliestBackward()
        if r >= 0 { idx[AV1Ref.altref2 - 1] = r; used[r] = true }
        for ref in [AV1Ref.last2, AV1Ref.last3, AV1Ref.bwdref, AV1Ref.altref2, AV1Ref.altref] where idx[ref - 1] < 0 {
            r = latestForward()
            if r >= 0 { idx[ref - 1] = r; used[r] = true }
        }
        var earliestRef = -1, earliest = 0
        for i in 0..<8 where earliestRef < 0 || shifted[i] < earliest { earliestRef = i; earliest = shifted[i] }
        for i in 0..<7 where idx[i] < 0 { idx[i] = earliestRef }
        return idx
    }

    /// skip_mode_params (5.9.22): the two references skip mode uses, or nil.
    static func skipModeFrames(_ s: AV1SequenceHeader, refs: [AV1RefSlot], refFrameIdx: [Int], orderHint: Int) -> (Int, Int)? {
        var forwardIdx = -1, backwardIdx = -1, forwardHint = 0, backwardHint = 0
        for i in 0..<7 {
            let refHint = refs[refFrameIdx[i]].orderHint
            if s.relativeDist(refHint, orderHint) < 0 {
                if forwardIdx < 0 || s.relativeDist(refHint, forwardHint) > 0 { forwardIdx = i; forwardHint = refHint }
            } else if s.relativeDist(refHint, orderHint) > 0 {
                if backwardIdx < 0 || s.relativeDist(refHint, backwardHint) < 0 { backwardIdx = i; backwardHint = refHint }
            }
        }
        if forwardIdx < 0 { return nil }
        if backwardIdx >= 0 { return (AV1Ref.last + min(forwardIdx, backwardIdx), AV1Ref.last + max(forwardIdx, backwardIdx)) }
        var secondIdx = -1, secondHint = 0
        for i in 0..<7 {
            let refHint = refs[refFrameIdx[i]].orderHint
            if s.relativeDist(refHint, forwardHint) < 0 {
                if secondIdx < 0 || s.relativeDist(refHint, secondHint) > 0 { secondIdx = i; secondHint = refHint }
            }
        }
        if secondIdx < 0 { return nil }
        return (AV1Ref.last + min(forwardIdx, secondIdx), AV1Ref.last + max(forwardIdx, secondIdx))
    }
}
