// VP8 macroblock mode trees and motion-vector contexts, RFC 6386 §§11–13.
struct VP8Vector: Equatable, Sendable {
    var x = 0, y = 0
    static func + (lhs: Self, rhs: Self) -> Self {
        Self(x: Int(Int16(truncatingIfNeeded: lhs.x + rhs.x)), y: Int(Int16(truncatingIfNeeded: lhs.y + rhs.y)))
    }
}

struct VP8Motion: Sendable {
    var reference = 0
    var vector = VP8Vector()
    var split: [VP8Vector] = []
    var filterMode = 1

    func at(_ index: Int) -> VP8Vector { split.isEmpty ? vector : split[index] }
}

struct VP8ModeProbabilities: Sendable {
    var coeff = VP8Tables.coeffsProba0.map(Int.init)
    var yMode = [112,86,140,37], uvMode = [162,101,204]
    var mv = [[162,128,225,146,172,147,214,39,156,128,129,132,75,145,178,206,239,254,254],
              [164,128,204,170,119,235,140,230,228,128,130,130,74,148,180,203,236,254,254]]
    var inter = 0, last = 0, golden = 0

    static let mvUpdates = [[237,246,253,253,254,254,254,254,254,254,254,254,254,254,250,250,252,254,254],
                       [231,243,245,253,254,254,254,254,254,254,254,254,254,254,251,251,254,254,254]]

    mutating func update(_ br: inout VP8BoolDecoder) {
        inter = br.value(8); last = br.value(8); golden = br.value(8)
        if br.flag() { for i in yMode.indices { yMode[i] = br.value(8) } }
        if br.flag() { for i in uvMode.indices { uvMode[i] = br.value(8) } }
        for axis in 0..<2 {
            for i in 0..<19 where br.bit(Self.mvUpdates[axis][i]) == 1 { mv[axis][i] = max(1, br.value(7) * 2) }
        }
    }

    private func vector(_ br: inout VP8BoolDecoder) -> VP8Vector {
        func component(_ p: [Int], _ br: inout VP8BoolDecoder) -> Int {
            var v: Int
            if br.bit(p[0]) == 1 {
                v = 0
                for i in 0...2 { v |= br.bit(p[9+i]) << i }
                for i in (4...9).reversed() { v |= br.bit(p[9+i]) << i }
                if v < 16 || br.bit(p[12]) == 1 { v += 8 }
            } else if br.bit(p[2]) == 0 {
                v = br.bit(p[3]) == 0 ? br.bit(p[4]) : 2 + br.bit(p[5])
            } else {
                v = br.bit(p[6]) == 0 ? 4 + br.bit(p[7]) : 6 + br.bit(p[8])
            }
            return v != 0 && br.bit(p[1]) == 1 ? -2*v : 2*v
        }
        let y = component(mv[0], &br)
        return VP8Vector(x: component(mv[1], &br), y: y)
    }

    func intra(_ br: inout VP8BoolDecoder, _ b: inout VP8Decoder.MBData) {
        let y = yMode, uv = uvMode
        let mode = br.bit(y[0]) == 0 ? 0 : br.bit(y[1]) == 0 ? (br.bit(y[2]) == 0 ? 2 : 3) : (br.bit(y[3]) == 0 ? 1 : 4)
        b.isI4x4 = mode == 4
        b.imodes[0] = mode
        if b.isI4x4 {
            for i in 0..<16 {
                if br.bit(120) == 0 { b.imodes[i] = 0 }
                else if br.bit(90) == 0 { b.imodes[i] = 1 }
                else if br.bit(79) == 0 { b.imodes[i] = 2 }
                else if br.bit(133) == 0 { b.imodes[i] = br.bit(87) == 0 ? 3 : 4 + br.bit(85) }
                else if br.bit(80) == 0 { b.imodes[i] = 6 }
                else { b.imodes[i] = br.bit(111) == 0 ? 7 : 8 + br.bit(151) }
            }
        }
        b.uvmode = br.bit(uv[0]) == 0 ? 0 : br.bit(uv[1]) == 0 ? 2 : br.bit(uv[2]) == 0 ? 3 : 1
    }

    func motion(_ br: inout VP8BoolDecoder, left: VP8Motion, top: VP8Motion, corner: VP8Motion,
                biases: [Bool], x: Int, y: Int, width: Int, height: Int) -> VP8Motion {
        let ref = br.bit(last) == 0 ? 1 : 2 + br.bit(golden)
        var result = VP8Motion(reference: ref)
        var near = Array(repeating: VP8Vector(), count: 4)
        var count = [0,0,0,0], index = 0
        for (block, weight) in [(top,2), (left,2), (corner,1)] where block.reference != 0 {
            let v = block.vector
            if v == VP8Vector() { count[0] += weight; continue }
            let candidate = biases[ref] == biases[block.reference] ? v : VP8Vector(x: -v.x, y: -v.y)
            if candidate != near[index] { index += 1; near[index] = candidate }
            count[index] += weight
        }
        if index == 3, near[3] == near[1] { count[1] += 1 }
        if count[2] > count[1] { count.swapAt(1,2); near.swapAt(1,2) }
        if count[1] >= count[0] { near[0] = near[1] }
        count[3] = (top.split.isEmpty ? 0 : 2) + (left.split.isEmpty ? 0 : 2) + (corner.split.isEmpty ? 0 : 1)
        let p = [[7,1,1,143],[14,18,14,107],[135,64,57,68],[60,56,128,65],[159,134,128,34],[234,188,128,28]]
        func clamp(_ v: VP8Vector) -> VP8Vector {
            .init(x: min((width-x)*128, max(-(x+1)*128,v.x)), y: min((height-y)*128,max(-(y+1)*128,v.y)))
        }
        guard br.bit(p[count[0]][0]) == 1 else { return result }
        result.filterMode = 2
        if br.bit(p[count[1]][1]) == 0 { result.vector = clamp(near[1]); return result }
        if br.bit(p[count[2]][2]) == 0 { result.vector = clamp(near[2]); return result }
        let best = clamp(near[0])
        if br.bit(p[count[3]][3]) == 0 { result.vector = best + vector(&br); return result }

        result.filterMode = 3
        result.split = Array(repeating: .init(), count: 16)
        let shape = br.bit(110) == 0 ? 3 : br.bit(111) == 0 ? 2 : br.bit(150)
        let maps = [[0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1], [0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1],
                    [0,0,1,1,0,0,1,1,2,2,3,3,2,2,3,3], Array(0..<16)]
        let map = maps[shape]
        let sub = [[147,136,18],[106,145,1],[179,121,1],[223,1,34],[208,1,1]]
        for j in 0...map[15] {
            guard let k = map.firstIndex(of: j) else { continue }
            let a = k < 4 ? top.at(k+12) : result.split[k-4]
            let l = k.isMultiple(of: 4) ? left.at(k+3) : result.split[k-1]
            let ctx = l == a ? (l == VP8Vector() ? 4 : 3) : a == VP8Vector() ? 2 : l == VP8Vector() ? 1 : 0
            let s = sub[ctx]
            let value = br.bit(s[0]) == 0 ? l : br.bit(s[1]) == 0 ? a : br.bit(s[2]) == 0 ? VP8Vector() : best + vector(&br)
            for n in k..<16 where map[n] == j { result.split[n] = value }
        }
        result.vector = result.split[15]
        return result
    }
}
