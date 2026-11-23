/// Profile-0 VP9 for 8-bit YUV 4:2:0 calls. Key pictures use spatial DC prediction.
/// Subsequent pictures code their change from a decoded reference with zero motion.
/// Frame-parallel error-resilient pictures keep probabilities independent of packet loss.
public struct VP9VideoEncoder: Sendable {
    private var reference: [EncoderPlane] = []
    private var sinceKey = 0

    public init() {}

    public mutating func encode(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8],
                                quantizer: Int = 72, keyframe: Bool = false) -> [UInt8]? {
        guard (1...4096).contains(width), (1...4096).contains(height), width*height <= 3840*2160,
              y.count == width*height, u.count == ((width+1)/2)*((height+1)/2), v.count == u.count,
              (0...255).contains(quantizer) else { return nil }
        let key = keyframe || sinceKey >= 119 || reference.first?.width != width || reference.first?.height != height
        let result = picture(width:width,height:height,y:y,u:u,v:v,q:quantizer,key:key,independent:false,readSlot:0,writeSlot:0)
        sinceKey = key ? 0 : sinceKey+1
        return result
    }

    fileprivate mutating func picture(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8],
                                      q: Int, key: Bool, independent: Bool, readSlot: Int, writeSlot: Int) -> [UInt8] {
        let w = (width+1)/2, h = (height+1)/2
        let planes = [EncoderPlane(y,width,height),EncoderPlane(u,w,h),EncoderPlane(v,w,h)]
        let intra = key || independent
        let scaled = !intra && (reference[0].width != width || reference[0].height != height)
        var prediction = intra ? [] : reference
        if scaled {
            let sx = (reference[0].width << 14) / width, sy = (reference[0].height << 14) / height
            for i in planes.indices {
                prediction[i] = reference[i].scaled(width:planes[i].width,height:planes[i].height,
                                                   sx:sx,sy:sy,subsampling:i == 0 ? 0 : 1)
            }
        }
        var tile = EncoderTile(planes:planes, reference:prediction, q:q, key:intra)
        let payload = tile.encode()
        let compressed = Self.compressedHeader(key:intra,lossless:q == 0)
        var raw = EncoderBits()
        raw.write(2,2) // frame marker
        raw.write(0,3) // profile 0, regular coded picture
        raw.write(key ? 0 : 1,1)
        raw.write(independent ? 0 : 1,1) // intra-only pictures are displayed by show_existing_frame
        raw.write(1,1) // error resilient
        if independent { raw.write(1,1) }
        if intra {
            raw.write(0x498342,24)
            if key { raw.write(0,4) } // unspecified colour space, studio range
            else { raw.write(1 << writeSlot,8) }
        } else {
            raw.write(1 << writeSlot,8)
            for _ in 0..<3 { raw.write(readSlot,3); raw.write(0,1) }
            if scaled { raw.write(0,3) } else { raw.write(1,1) }
        }
        if intra || scaled {
            raw.write(width-1,16)
            raw.write(height-1,16)
        }
        raw.write(0,1) // display and coded dimensions match
        if !intra { raw.write(3,4) } // no high precision motion; fixed bilinear interpolation
        raw.write(0,2) // frame context
        raw.write(0,10) // loop filter level, sharpness and deltas
        raw.write(q,8)
        raw.write(0,4) // quantizer deltas and segmentation
        if (width+63)/64 >= 8 { raw.write(0,1) } // single tile column
        raw.write(0,1) // single tile row
        raw.write(compressed.count,16)
        reference = tile.planes
        var bytes = raw.bytes + compressed + payload
        if independent {
            // An intra-only enhancement refreshes just its own slot in a shared decoder.
            // This superframe then displays it. A receiver selecting only this spatial
            // stream can start independently at the same access point.
            let size = bytes.count, magnitude = size < 256 ? 1 : size < 65536 ? 2 : 3
            let marker = UInt8(0xc1 | ((magnitude-1) << 3))
            bytes += [0x88 | UInt8(writeSlot), marker]
            for length in [size,1] {
                for i in 0..<magnitude { bytes.append(UInt8(truncatingIfNeeded:length >> (i*8))) }
            }
            bytes.append(marker)
        }
        return bytes
    }

    private static func compressedHeader(key: Bool, lossless: Bool) -> [UInt8] {
        var w = EncoderBoolean()
        if !lossless { w.literal(0, bits: 2) } // Only 4x4 residual transforms.
        w.put(false) // Keep the default coefficient model.
        for _ in 0..<3 { w.put(false,252) } // Skip probabilities.
        if !key {
            // Inter modes, intra/inter, single reference, luma mode, partition and
            // motion vector probabilities, with fixed interpolation and no high precision.
            for _ in 0..<(21+4+10+36+48+3+2*(1+10+1+10+6+3)) { w.put(false,252) }
        }
        return w.finish()
    }
}

private struct EncoderBits {
    var bytes: [UInt8] = []
    private var bitCount = 0
    mutating func write(_ value: Int, _ width: Int) {
        for i in (0..<width).reversed() {
            if bitCount == 0 { bytes.append(0) }
            bytes[bytes.count-1] |= UInt8((value >> i) & 1) << (7-bitCount)
            bitCount = (bitCount+1) & 7
        }
    }
}

private struct EncoderTile {
    var planes: [EncoderPlane]
    let reference: [EncoderPlane]
    let q: Int, key: Bool
    let rows, cols: Int
    private var above, left: [Int]
    private var skips: [Bool]
    private var writer = EncoderBoolean()
    init(planes: [EncoderPlane], reference: [EncoderPlane], q: Int, key: Bool) {
        self.planes = planes
        self.reference = reference
        self.q = q
        self.key = key
        cols = (planes[0].width+7)/8
        rows = (planes[0].height+7)/8
        above = .init(repeating:0,count:cols)
        left = .init(repeating:0,count:rows)
        skips = .init(repeating:false,count:rows*cols)
    }

    mutating func encode() -> [UInt8] {
        for y in stride(from:0,to:rows,by:8) {
            for x in stride(from:0,to:cols,by:8) { partition(x,y,level:3) }
        }
        return writer.finish()
    }

    private mutating func partition(_ x: Int, _ y: Int, level: Int) {
        guard x < cols && y < rows else { return }
        let half = (1 << level) / 2
        let hasRows = y+half < rows, hasCols = x+half < cols
        let offset = 3*(level*4 + ((above[x] >> level) & 1) + 2*((left[y] >> level) & 1))
        let probs = key ? VP9Table.kfPartitionProbs : VP9Table.partitionProbs
        if hasCols && hasRows { writer.put(level > 0,probs[offset]) }
        if level > 0 {
            if hasCols { writer.put(true,probs[offset+1]) }
            if hasRows { writer.put(true,probs[offset+2]) }
            for yy in [y,y+half] { for xx in [x,x+half] { partition(xx,yy,level:level-1) } }
            return
        }
        block(x,y)
        above[x] = 14
        left[y] = 14
    }

    private mutating func block(_ x: Int, _ y: Int) {
        let pos = y*cols+x
        var same = !key
        for p in 0..<3 where same {
            let n = p == 0 ? 8 : 4
            same = planes[p].canSkip(reference[p], x: x*n, y: y*n, size: n, q: q)
        }
        let skip = (x > 0 && skips[pos-1] ? 1 : 0)+(y > 0 && skips[pos-cols] ? 1 : 0)
        writer.put(same,VP9Table.skipProbs[skip])
        skips[pos] = same
        if key {
            writer.put(false,VP9Table.KFYModeProbs[0]) // DC_PRED, both neighbours DC
            writer.put(false,VP9Table.KFUVModeProbs[0])
        } else {
            let neighbours = (x > 0 ? 1 : 0) + (y > 0 ? 1 : 0)
            writer.put(true,VP9Table.isInterProbs[0])
            writer.put(false,VP9Table.singleRefProbs[(neighbours == 0 ? 2 : 4)*2])
            writer.put(false,VP9Table.interModeProbs[(2-neighbours)*3]) // ZEROMV
        }
        for p in 0..<3 {
            let n = p == 0 ? 8 : 4
            for dy in stride(from:0,to:n,by:4) {
                for dx in stride(from:0,to:n,by:4) {
                    planes[p].block(x:x*n+dx,y:y*n+dy,q:q,chroma:p != 0,reference:key ? nil : reference[p],skip:same,writer:&writer)
                }
            }
        }
    }
}

private struct EncoderPlane: Sendable {
    let input: [UInt8]
    let width, height, stride: Int
    var decoded: [UInt8]
    private var above, left: [Int]
    init(_ input: [UInt8], _ width: Int, _ height: Int) {
        self.input = input
        self.width = width
        self.height = height
        stride = ((width+7)/8)*8
        let rows = ((height+7)/8)*8
        decoded = .init(repeating:0,count:stride*rows)
        above = .init(repeating:0,count:stride/4)
        left = .init(repeating:0,count:rows/4)
    }

    func canSkip(_ reference: Self, x: Int, y: Int, size: Int, q: Int) -> Bool {
        if reference.input.count == input.count {
            let unchanged = (y..<min(y+size, height)).allSatisfy { row in
                let range = (row*width+x)..<(row*width+min(x+size, width))
                return input[range] == reference.input[range]
            }
            if unchanged { return true }
        }

        // VP9 infers skip on inter blocks whose quantized coefficients are all zero
        // across all three planes. Signal it explicitly so the next block's skip probability
        // agrees with the decoder, including when scaled prediction is almost exact.
        for dy in Swift.stride(from: 0, to: size, by: 4) {
            for dx in Swift.stride(from: 0, to: size, by: 4) {
                var coefficients = [Int](repeating: 0, count: 16)
                for r in 0..<4 {
                    let row = min(height-1, y+dy+r)
                    for c in 0..<4 {
                        let col = min(width-1, x+dx+c)
                        coefficients[r*4+c] = Int(input[row*width+col]) - Int(reference.decoded[row*stride+col])
                    }
                }
                if coefficients.allSatisfy({ $0 == 0 }) { continue }
                Self.forward(&coefficients, lossless: q == 0)
                if coefficients.indices.contains(where: { Self.quantize(coefficients[$0], at: $0, q: q) != 0 }) {
                    return false
                }
            }
        }
        return true
    }

    private static func quantize(_ value: Int, at coefficient: Int, q: Int) -> Int {
        let step = coefficient == 0 ? VP9Table.dcQLookup[q] : VP9Table.acQLookup[q]
        let level = (abs(value) + step/2) / step
        return value < 0 ? -level : level
    }

    /// Scale the reference at each 8x8 motion block using VP9's Q14 scaling factors,
    /// Q4 stepping and separable bilinear interpolation, including chroma phase.
    func scaled(width w: Int, height h: Int, sx: Int, sy: Int, subsampling: Int) -> Self {
        var plane = Self([],w,h)
        let n = 8 >> subsampling
        let stepX = (sx*16) >> 14, stepY = (sy*16) >> 14
        func coordinate(_ pixel: Int, _ scale: Int, _ step: Int) -> Int {
            let base = pixel - pixel % n
            let frac = ((scale * (base << (4+subsampling))) >> 14) & 15
            return (((base*scale) >> 14) << 4) + frac + (pixel-base)*step
        }
        for y in 0..<h {
            let ty = coordinate(y,sy,stepY), fy = ty & 15
            let a = min(height-1,ty >> 4)*stride, b = min(height-1,(ty >> 4)+1)*stride
            for x in 0..<w {
                let tx = coordinate(x,sx,stepX), fx = tx & 15
                let l = min(width-1,tx >> 4), r = min(width-1,(tx >> 4)+1)
                let top = (Int(decoded[a+l])*(16-fx) + Int(decoded[a+r])*fx + 8) >> 4
                let bottom = (Int(decoded[b+l])*(16-fx) + Int(decoded[b+r])*fx + 8) >> 4
                plane.decoded[y*plane.stride+x] = UInt8((top*(16-fy) + bottom*fy + 8) >> 4)
            }
        }
        return plane
    }

    private func dcPrediction(_ x: Int, _ y: Int) -> Int {
        let sides = (x > 0 ? 4 : 0) + (y > 0 ? 4 : 0)
        guard sides > 0 else { return 128 }
        var sum = 0
        for d in 0..<4 {
            if y > 0 { sum += Int(decoded[(y-1)*stride+min(width-1,x+d)]) }
            if x > 0 { sum += Int(decoded[min(height-1,y+d)*stride+x-1]) }
        }
        return (sum + sides/2) / sides
    }

    mutating func block(x: Int, y: Int, q: Int, chroma: Bool, reference: Self?, skip: Bool, writer: inout EncoderBoolean) {
        let context = above[x/4] + left[y/4]
        let prediction = reference == nil ? dcPrediction(x,y) : 0
        var residual = [Int](repeating:0,count:16)
        for r in 0..<4 {
            for c in 0..<4 {
                let pos = (y+r)*stride+x+c
                let predictor = reference.map { Int($0.decoded[min(height-1,y+r)*stride+min(width-1,x+c)]) } ?? prediction
                decoded[pos] = UInt8(predictor)
                residual[r*4+c] = Int(input[min(height-1,y+r)*width+min(width-1,x+c)]) - predictor
            }
        }
        var nonzero = false
        if !skip {
            Self.forward(&residual, lossless:q == 0)
            var quantized = residual
            for i in residual.indices {
                let step = i == 0 ? VP9Table.dcQLookup[q] : VP9Table.acQLookup[q]
                quantized[i] = Self.quantize(residual[i], at: i, q: q)
                residual[i] = quantized[i]*step
                nonzero = nonzero || quantized[i] != 0
            }
            writer.residual(quantized,chroma:chroma,inter:reference != nil,context:context)
            if nonzero {
                VP9Transform.apply(&residual,size:4,type:0,lossless:q == 0)
                for r in 0..<4 { for c in 0..<4 {
                    let pos = (y+r)*stride+x+c
                    decoded[pos] = UInt8(clamping:Int(decoded[pos])+residual[r*4+c])
                } }
            }
        }
        above[x/4] = nonzero ? 1 : 0
        left[y/4] = nonzero ? 1 : 0
    }

    private static func forward(_ values: inout [Int], lossless: Bool) {
        if !lossless {
            for i in values.indices { values[i] *= 16 }
            if values[0] != 0 { values[0] += 1 }
        }
        var out = values
        for _ in 0..<2 {
            for i in 0..<4 {
                var a = values[i], b = values[4+i], c = values[8+i], d = values[12+i]
                if lossless {
                    a += b
                    d -= c
                    let e = (a-d) >> 1
                    b = e-b
                    c = e-c
                    out[4*i] = a-c
                    out[4*i+1] = c
                    out[4*i+2] = d+b
                    out[4*i+3] = b
                } else {
                    let p = a+d, t = b+c, r = b-c, s = a-d
                    out[4*i] = ((p+t)*11585+8192) >> 14
                    out[4*i+2] = ((p-t)*11585+8192) >> 14
                    out[4*i+1] = (r*6270+s*15137+8192) >> 14
                    out[4*i+3] = (s*6270-r*15137+8192) >> 14
                }
            }
            swap(&out,&values)
        }
        for i in values.indices { values[i] = lossless ? values[i]*4 : (values[i]+1) >> 2 }
    }
}

private struct EncoderBoolean {
    init() { put(false) }
    private var bytes: [UInt8] = []
    private var low: UInt32 = 0
    private var range = 255
    private var count = -24

    mutating func put(_ bit: Bool, _ probability: Int = 128) {
        let split = 1 + (((range - 1) * probability) >> 8)
        if bit { low &+= UInt32(split); range -= split } else { range = split }
        var shift = UInt8(range).leadingZeroBitCount
        range <<= shift
        count += shift
        if count >= 0 {
            let offset = shift - count
            if low & (UInt32(1) << (32 - offset)) != 0 {
                var i = bytes.count
                while i > 0, bytes[i-1] == 255 { i -= 1; bytes[i] = 0 }
                if i > 0 { bytes[i-1] += 1 } else { bytes.insert(1, at: 0) }
            }
            bytes.append(UInt8(truncatingIfNeeded: low >> (24 - offset)))
            low = (low << offset) & 0xff_ffff
            shift = count
            count -= 8
        }
        low <<= shift
    }

    mutating func literal(_ value: Int, bits: Int) {
        for i in (0..<bits).reversed() { put(value & (1 << i) != 0) }
    }

    mutating func finish() -> [UInt8] {
        for _ in 0..<32 { put(false) }
        if let final = bytes.last, final & 224 == 192 { bytes.append(0) }
        return bytes
    }

    private static let bands = [0,1,1,2,2,2,3,3,3,3,4,4,4,5,5,5]
    private static let thresholds = [5,7,11,19,35,67]
    private static let extra = [[159],[165,145],[173,148,140],[176,155,140,135],[180,157,141,134,130],
                                 [254,254,254,252,249,243,230,196,177,153,140,133,130,129]]

    mutating func residual(_ values: [Int], chroma: Bool, inter: Bool, context: Int) {
        let scan = VP9Table.defaultScan4x4, adj = VP9Table.defaultScanNb4x4
        let end = (scan.lastIndex(where: { values[$0] != 0 }) ?? -1) + 1
        let base = ((chroma ? 2 : 0)+(inter ? 1 : 0))*108
        var energy = [Int](repeating:0,count:16)
        var ctx = context, afterZero = false
        for i in scan.indices {
            let p = base + Self.bands[i]*18 + 3*ctx
            if !afterZero { put(i < end,VP9Table.coefProbs[p]) }
            if i == end { break }
            let index = scan[i], value = abs(values[index])
            afterZero = value == 0
            put(!afterZero,VP9Table.coefProbs[p+1])
            if value != 0 {
                let prob = VP9Table.coefProbs[p+2]
                put(value > 1,prob)
                var token = 1
                if value > 1 {
                    let t = (prob-1)*8, probs = VP9Table.pareto8Full
                    put(value >= 5,probs[t])
                    if value < 5 {
                        put(value > 2,probs[t+1])
                        if value > 2 { put(value == 4,probs[t+2]) }
                        token = min(3,value)
                    } else {
                        let category = Self.thresholds.lastIndex(where: { value >= $0 }) ?? 0
                        put(category >= 2,probs[t+3])
                        if category < 2 { put(category == 1,probs[t+4]) }
                        else {
                            put(category >= 4,probs[t+5])
                            put(category % 2 != 0,probs[t+(category < 4 ? 6 : 7)])
                        }
                        let bits = Self.extra[category], offset = value-Self.thresholds[category]
                        for (i,p) in bits.enumerated() { put(offset & (1 << (bits.count-i-1)) != 0,p) }
                        token = category < 2 ? 4 : 5
                    }
                }
                put(values[index] < 0)
                energy[index] = token
            }
            if i < 15 { ctx = (1+energy[adj[2*i+2]]+energy[adj[2*i+3]]) >> 1 }
        }
    }
}

/// Dependencies are relative to source pictures. A lower spatial reference always
/// belongs to this same picture; temporal distances count whole pictures on RTP.
public struct VP9EncodedLayer: Sendable {
    public let bytes: [UInt8]
    public let width, height, spatialID, temporalID: Int
    public let temporalReferenceDiff: Int?
    public let dependsOnLower, switchingUp, refresh: Bool
}

public struct VP9ScalableEncoder: Sendable {
    private let spatialCount, temporalCount: Int
    private let independent, keyOnly, shift, twoThirds: Bool
    private var slots = [VP9VideoEncoder](repeating:.init(),count:8)
    private var pictureNumbers = [Int](repeating:0,count:8)
    private var temporalIDs = [Int](repeating:0,count:8)
    private var pictureNumber = 0
    private var lastWidth = 0, lastHeight = 0

    public init?(mode: String) {
        let letters = Array(mode.utf8)
        guard (4...14).contains(letters.count), letters[0] == 76 || letters[0] == 83,
              (49...51).contains(letters[1]), letters[2] == 84, (49...51).contains(letters[3]) else { return nil }
        spatialCount = Int(letters[1]-48)
        temporalCount = Int(letters[3]-48)
        independent = letters[0] == 83
        let suffix = String(decoding:letters.dropFirst(4),as:UTF8.self)
        keyOnly = suffix == "_KEY" || suffix == "_KEY_SHIFT"
        shift = suffix == "_KEY_SHIFT"
        twoThirds = suffix == "h"
        guard suffix.isEmpty || keyOnly || twoThirds,
              !independent || (spatialCount >= 2 && !keyOnly),
              spatialCount > 1 || suffix.isEmpty,
              !shift || (spatialCount == 2 && temporalCount == 2) else { return nil }
    }

    public mutating func encode(width: Int, height: Int, y: [UInt8], u: [UInt8], v: [UInt8],
                                quantizer: Int = 72, keyframe: Bool = false) -> [VP9EncodedLayer]? {
        guard (1...4096).contains(width), (1...4096).contains(height), width*height <= 3840*2160,
              y.count == width*height, u.count == ((width+1)/2)*((height+1)/2), v.count == u.count,
              (0...255).contains(quantizer) else { return nil }
        let refresh = keyframe || width != lastWidth || height != lastHeight || pictureNumber >= 120
        if refresh { pictureNumber = 0 }
        let clock = pictureNumber
        var sizes = [(width,height)]
        for _ in 1..<spatialCount {
            let prior = sizes[sizes.count-1]
            if twoThirds { sizes.append((max(1,prior.0*2/3),max(1,prior.1*2/3))) }
            else { sizes.append((max(1,prior.0/2),max(1,prior.1/2))) }
        }
        var result: [VP9EncodedLayer] = []
        var lowerSlot = 0
        for (sid,(w,h)) in sizes.reversed().enumerated() {
            let phase = shift && sid == 1 && !refresh ? clock+1 : clock
            let tid = refresh || temporalCount == 1 ? 0 : temporalCount == 2 ? phase % 2 : [0,2,1,2][phase % 4]
            let spatial = sid > 0 && !independent && (refresh || !keyOnly)
            let temporalSlot = temporalCount == 3 && tid == 2 && clock % 4 == 3 ? sid+3 : sid
            let read = spatial ? lowerSlot : temporalSlot
            let write = tid == 0 ? sid : (temporalCount == 3 && tid == 1 ? sid+3 : 6+sid%2)
            let diff = spatial || refresh ? nil : clock-pictureNumbers[read]
            let switches = tid > 0 && (spatial || temporalIDs[read] < tid)
            var encoder = slots[read]
            let bytes = encoder.picture(width:w,height:h,
                y:Self.scale(y,width,height,w,h),u:Self.scale(u,(width+1)/2,(height+1)/2,(w+1)/2,(h+1)/2),
                v:Self.scale(v,(width+1)/2,(height+1)/2,(w+1)/2,(h+1)/2),q:quantizer,
                key:refresh && sid == 0, independent:refresh && independent && sid > 0,
                readSlot:read,writeSlot:write)
            slots[write] = encoder
            pictureNumbers[write] = clock
            temporalIDs[write] = tid
            lowerSlot = write
            result.append(.init(bytes:bytes,width:w,height:h,spatialID:sid,temporalID:tid,temporalReferenceDiff:diff,
                                dependsOnLower:spatial,switchingUp:switches,refresh:refresh))
        }
        lastWidth = width
        lastHeight = height
        pictureNumber += 1
        return result
    }

    private static func scale(_ input: [UInt8], _ width: Int, _ height: Int, _ w: Int, _ h: Int) -> [UInt8] {
        if w == width && h == height { return input }
        var output = [UInt8](repeating:0,count:w*h)
        for row in 0..<h {
            let src = (row*height/h)*width
            for col in 0..<w { output[row*w+col] = input[src+col*width/w] }
        }
        return output
    }
}
