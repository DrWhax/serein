extension CELTFrame {
    /// Interpolate the two bracketing allocation vectors. Budget that cannot represent a PVQ
    /// shape may still buy one raw fine-energy bit per channel in a folded high band.
    mutating func allocate(_ budget: Int, trim: Int, caps: [Int], boosts: [Int], choose: (Int) throws -> Int) throws {
        let edges = CELTTables.edges, floor = channels * 8
        let skipReserve = budget >= 8 ? 8 : 0
        var total = budget - skipReserve
        var stereoReserve = channels == 2 ? CELTTables.logLengths[end - start] : 0
        if stereoReserve > total { stereoReserve = 0 }
        total -= stereoReserve
        var dualReserve = stereoReserve != 0 && total >= 8 ? 8 : 0
        total -= dualReserve
        let bands = start..<end
        let threshold = (0..<21).map { max(floor, 3 * width($0) / 2) }
        let trimOffsets = (0..<21).map { band -> Int in
            let bins = width(band)
            return ((channels * bins * (trim - 5 - lm) * (end - band - 1) * 8) >> 6) - (bins == 1 ? floor : 0)
        }
        func bits(row: Int, band: Int) -> Int {
            let base = row >= 11 ? caps[band] : channels * width(band) * CELTTables.allocation[row * 21 + band] / 4
            return (base > 0 ? max(0, base + trimOffsets[band]) : 0) + (row > 0 ? boosts[band] : 0)
        }
        func thresholded(_ vector: [Int]) -> [Int] {
            var used = vector, started = false
            for band in bands.reversed() {
                if vector[band] >= threshold[band] { started = true }
                used[band] = min(caps[band], started ? vector[band] : (vector[band] >= floor ? floor : 0))
            }
            return used
        }
        var low = 0, high = 11
        while low + 1 < high {
            let mid = (low + high) / 2
            var vector = [Int](repeating: 0, count: 21)
            for band in bands { vector[band] = bits(row: mid, band: band) }
            if thresholded(vector).reduce(0,+) <= total { low = mid } else { high = mid }
        }
        var base = [Int](repeating: 0, count: 21), delta = base
        var skipStart = start
        for band in bands {
            base[band] = bits(row: low, band: band)
            delta[band] = max(0, bits(row: high, band: band) - base[band])
            if boosts[band] > 0 { skipStart = band }
        }
        func interpolated(_ fraction: Int) -> [Int] {
            thresholded(zip(base, delta).map { $0 + (fraction * $1 / 64) })
        }
        var lower = 0, upper = 64
        for _ in 0..<6 {
            let mid = (lower + upper) / 2
            if interpolated(mid).reduce(0,+) <= total { lower = mid } else { upper = mid }
        }
        shapeBits = interpolated(lower)
        var sum = shapeBits.reduce(0,+)
        codedBands = end
        while codedBands > start {
            let band = codedBands - 1
            if band <= skipStart { total += skipReserve; break }
            let bins = edges[codedBands] - edges[start]
            let perBin = (total - sum) / bins
            let left = total - sum - perBin * bins
            var bandBits = shapeBits[band] + perBin * (edges[codedBands] - edges[band]) + max(0, left - edges[band] + edges[start])
            if bandBits >= max(threshold[band], floor + 8) {
                if try choose(2) != 0 { break }
                sum += 8
                bandBits -= 8
            }
            sum -= shapeBits[band] + stereoReserve
            if stereoReserve > 0 { stereoReserve = CELTTables.logLengths[band-start] }
            shapeBits[band] = bandBits >= floor ? floor : 0
            sum += shapeBits[band] + stereoReserve
            codedBands -= 1
        }
        if stereoReserve > 0 { intensity = start + (try choose(codedBands + 1 - start)) }
        if intensity <= start { total += dualReserve; dualReserve = 0 }
        if dualReserve > 0 { dualStereo = try choose(2) != 0 }
        guard codedBands > start, total >= sum else { throw OpusPacket.Failure.invalidPacket }
        let bins = edges[codedBands] - edges[start]
        let perBin = (total - sum) / bins
        var remaining = (total - sum) % bins
        for band in start..<codedBands {
            let n = edges[band+1] - edges[band], extra = min(remaining, n)
            shapeBits[band] += perBin * n + extra
            remaining -= extra
        }
        for band in start..<codedBands {
            let n = width(band)
            shapeBits[band] += balance
            var excess: Int
            if n > 1 {
                excess = max(0, shapeBits[band] - caps[band])
                shapeBits[band] -= excess
                let den = channels * n + (channels == 2 && n > 2 && !dualStereo && band < intensity ? 1 : 0)
                let ncLog = den * (CELTTables.logWidths[band] + lm * 8)
                var offset = (ncLog >> 1) - den * 21
                if n == 2 { offset += den * 2 }
                if shapeBits[band] + offset < den * 16 { offset += ncLog >> 2 }
                else if shapeBits[band] + offset < den * 24 { offset += ncLog >> 3 }
                let fine = max(0, (shapeBits[band] + offset + den * 4) / (den * 8))
                fineBits[band] = min(8, shapeBits[band] / floor, fine)
                finePriority[band] = fineBits[band] * den * 8 >= shapeBits[band] + offset ? 1 : 0
                shapeBits[band] -= floor * fineBits[band]
            } else {
                excess = max(0, shapeBits[band] - floor)
                shapeBits[band] -= excess
                finePriority[band] = 1
            }
            if excess > 0 {
                let extra = min(excess / floor, 8 - fineBits[band])
                fineBits[band] += extra
                finePriority[band] = extra * floor >= excess - balance ? 1 : 0
                excess -= extra * floor
            }
            balance = excess
        }
        for band in codedBands..<end {
            fineBits[band] = shapeBits[band] / floor
            shapeBits[band] = 0
            finePriority[band] = fineBits[band] < 1 ? 1 : 0
        }
    }
}
