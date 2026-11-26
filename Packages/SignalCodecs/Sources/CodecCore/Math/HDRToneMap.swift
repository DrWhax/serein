/// PQ / HLG signal → SDR display values (VideoRenderer's COLOUR 3 / 4 path and HDRConvert).
public struct HDRToneMap: Sendable {
    let pq: Bool
    let bt2020: Bool
    /// Signal (0…1, 4096 steps) → linear light relative to 203 cd/m² (PQ), or scene light (HLG).
    let lut: [Double]

    public init(pq: Bool, bt2020: Bool) {
        self.pq = pq
        self.bt2020 = bt2020
        var lut = [Double](repeating: 0, count: 4097)
        for i in 0...4096 {
            let v = Double(i) / 4096
            if pq {
                let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
                let e = LibM.pow(v, 1 / m2)
                lut[i] = LibM.pow(max(e - c1, 0) / (c2 - c3 * e), 1 / m1) * 10000 / 203
            } else {
                let a = 0.17883277, b = 0.28466892, c = 0.55991073
                lut[i] = v <= 0.5 ? v * v * 3 / 12 : (LibM.exp((v - c) / a) + b) / 12
            }
        }
        self.lut = lut
    }

    func signal(_ v: Double) -> Double {
        let x = min(max(v, 0), 1) * 4096
        let i = min(Int(x), 4095), f = x - Double(i)
        return lut[i] + (lut[i + 1] - lut[i]) * f
    }

    public func map(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        var lr = signal(r), lg = signal(g), lb = signal(b)
        if !pq {
            // HLG OOTF for a 1000 cd/m² display, then relative to 203 cd/m².
            let ys = 0.2627 * lr + 0.6780 * lg + 0.0593 * lb
            let k = LibM.pow(max(ys, 1e-6), 0.2) * 1000 / 203
            lr *= k; lg *= k; lb *= k
        }
        let lumIn = 0.2627 * lr + 0.6780 * lg + 0.0593 * lb
        let lumOut = lumIn <= 0.8 ? lumIn : 0.8 + 0.2 * (1 - LibM.exp(-(lumIn - 0.8) / 0.2))
        let k = lumIn > 0 ? lumOut / lumIn : 0
        lr *= k; lg *= k; lb *= k
        if bt2020 {
            (lr, lg, lb) = (1.6605 * lr - 0.5876 * lg - 0.0728 * lb, -0.1246 * lr + 1.1329 * lg - 0.0083 * lb, -0.0182 * lr - 0.1006 * lg + 1.1187 * lb)
        }
        func encode(_ v: Double) -> Double { LibM.pow(min(max(v, 0), 1), 1 / 2.4) }
        return (encode(lr), encode(lg), encode(lb))
    }
}
