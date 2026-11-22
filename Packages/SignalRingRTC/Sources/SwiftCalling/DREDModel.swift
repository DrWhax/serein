import CryptoKit
import Foundation

/// The Opus control expresses the protected duration in units of 10 ms.
package struct DREDConfiguration: Sendable {
    let model: DREDModel
    let duration: Int
    package init?(model: DREDModel?, duration: UInt64) {
        guard let model, duration > 0 else { return nil }
        self.model = model
        self.duration = Int(min(duration, 100))
    }
}

/// Read the optional Signal Opus 1.6.1 model once. Immutable weights are shared across
/// calls. Each media stream owns its convolution history and recurrent state.
package final class DREDModel: Sendable {
    enum Failure: Error { case invalidModel }
    private struct Record {
        let type: Int
        let bytes: ArraySlice<UInt8>
        func words() throws -> [UInt32] {
            guard bytes.count.isMultiple(of: 4) else { throw Failure.invalidModel }
            return stride(from: bytes.startIndex, to: bytes.endIndex, by: 4).map { p in
                UInt32(bytes[p]) | UInt32(bytes[p+1]) << 8 | UInt32(bytes[p+2]) << 16 | UInt32(bytes[p+3]) << 24
            }
        }
        func floats() throws -> [Float] {
            guard type == 0 else { throw Failure.invalidModel }
            return try words().map(Float.init(bitPattern:))
        }
    }

    enum Activation { case linear, tanh, sigmoid }
    struct Layer: Sendable {
        var columns = 0, rows = 0
        var dense: [Float] = []
        var bias: [Float] = []
        var scale: [Float] = []
        var diagonal: [Float] = []
        // Each block spans eight outputs and four inputs; offsets delimit output groups.
        var offsets: [Int] = [], positions: [Int] = []
        var weights: [SIMD8<Float>] = []

        func apply(_ input: [Float], _ activation: Activation) -> [Float] {
            precondition(input.count == columns)
            var result = bias
            if !dense.isEmpty {
                for col in input.indices {
                    let base = col * rows, x = input[col]
                    for row in 0..<rows { result[row] += x * dense[base + row] }
                }
            } else {
                let x = input.map { min(127, max(-127, (127 * $0 + 0.5).rounded(.down))) }
                for group in 0..<(rows/8) {
                    var accum = SIMD8<Float>(repeating: 0)
                    for b in offsets[group]..<offsets[group+1] {
                        let col = positions[b], w = b * 4
                        for i in 0..<4 { accum += weights[w+i] * x[col+i] }
                    }
                    for i in 0..<8 {
                        let row = group*8+i
                        result[row] += accum[i] * scale[row]
                    }
                }
            }
            for i in diagonal.indices { result[i] += diagonal[i] * input[i % columns] }
            switch activation {
            case .linear: break
            case .tanh: for i in result.indices { result[i] = DREDModel.tanhApprox(result[i]) }
            case .sigmoid: for i in result.indices { result[i] = DREDModel.sigmoid(result[i]) }
            }
            return result
        }
    }

    private let layers: [String: Layer]
    let pitchConvolutions: [(weights: [Float], bias: [Float])]
    subscript(_ name: String) -> Layer {
        // Names come exclusively from the graph built and checked during initialization.
        layers[name]!
    }

    package static let assetSize = 1_998_208

    package init(weights content: Data) throws {
        // RingRTC's manifest authenticates the declared prefix of padded assets.
        let data = content.prefix(Self.assetSize)
        guard data.count == Self.assetSize,
              Data(SHA512.hash(data: data)).base64EncodedString() == "sdfpdb/u3wiTfBr2s0gx1LJX6jii4tquyax/UBThTGWTEXyOCSKjYmYV+9tKQZcO+Q1B1ReoGSW3VbvzeMGKaQ=="
        else { throw Failure.invalidModel }
        let bytes = Array(data)
        func word(_ p: Int) -> Int {
            Int(bytes[p]) | Int(bytes[p+1]) << 8 | Int(bytes[p+2]) << 16 | Int(bytes[p+3]) << 24
        }
        var p = 0, records = [String: Record]()
        while p < bytes.count {
            guard bytes.count-p >= 64, bytes[p..<p+4].elementsEqual("DNNw".utf8), word(p+4) == 0,
                  let end = bytes[p+20..<p+64].firstIndex(of: 0) else { throw Failure.invalidModel }
            let type = word(p+8), size = word(p+12), padded = word(p+16)
            let name = String(decoding: bytes[p+20..<end], as: UTF8.self)
            p += 64
            guard size > 0, padded >= size, padded <= bytes.count-p, padded.isMultiple(of: 64),
                  records[name] == nil else { throw Failure.invalidModel }
            records[name] = Record(type: type, bytes: bytes[p..<p+size])
            p += padded
        }
        var layers = [String: Layer]()
        for (name, cols, rows) in Self.layout {
            var layer = Layer(columns: cols, rows: rows)
            layer.bias = try records[name+"_bias"]?.floats() ?? [Float](repeating: 0, count: rows)
            layer.diagonal = try records[name+"_diag"]?.floats() ?? []
            guard layer.bias.count == rows, layer.diagonal.isEmpty || layer.diagonal.count == rows else { throw Failure.invalidModel }
            if let dense = records[name+"_weights_float"] {
                layer.dense = try dense.floats()
                guard layer.dense.count == rows * cols else { throw Failure.invalidModel }
            } else {
                guard let record = records[name+"_weights_int8"], record.type == 3, rows.isMultiple(of: 8), cols.isMultiple(of: 4),
                      let scale = try records[name+"_scale"]?.floats(), scale.count == rows else { throw Failure.invalidModel }
                layer.scale = scale
                let sparse = try records[name+"_weights_idx"]?.words()
                var index = 0
                for _ in 0..<(rows/8) {
                    layer.offsets.append(layer.positions.count)
                    if let sparse {
                        guard index < sparse.count else { throw Failure.invalidModel }
                        let count = Int(sparse[index])
                        index += 1
                        guard count <= sparse.count-index else { throw Failure.invalidModel }
                        for col in sparse[index..<index+count] {
                            guard col <= cols-4 && col.isMultiple(of: 4) else { throw Failure.invalidModel }
                            layer.positions.append(Int(col))
                        }
                        index += count
                    } else { layer.positions += stride(from: 0, to: cols, by: 4) }
                }
                layer.offsets.append(layer.positions.count)
                guard sparse == nil || index == sparse?.count, record.bytes.count == layer.positions.count * 32 else { throw Failure.invalidModel }
                for base in stride(from: record.bytes.startIndex, to: record.bytes.endIndex, by: 32) {
                    for c in 0..<4 {
                        var vector = SIMD8<Float>(repeating: 0)
                        for r in 0..<8 { vector[r] = Float(Int8(bitPattern: record.bytes[base+4*r+c])) }
                        layer.weights.append(vector)
                    }
                }
            }
            layers[name] = layer
        }
        self.layers = layers
        self.pitchConvolutions = try [4, 1].enumerated().map { index, count in
            let name = "conv2d_" + String(index+1)
            guard let weights = try records[name+"_weight_float"]?.floats(), weights.count == 36,
                  let bias = try records[name+"_bias"]?.floats(), bias.count == count else { throw Failure.invalidModel }
            return (weights, bias)
        }
    }

    static func tanhApprox(_ x: Float) -> Float {
        let x2 = x*x
        let num = (0.60863042*x2 + 96.39235687)*x2 + 952.52801514
        let den = (11.88600922*x2 + 413.36801147)*x2 + 952.72399902
        return max(-1, min(1, x * num / den))
    }
    static func sigmoid(_ x: Float) -> Float { 0.5 + 0.5*tanhApprox(0.5*x) }

    func gru(_ name: String, input: [Float], state: inout [Float]) {
        let a = self[name+"_input"].apply(input, .linear)
        let b = self[name+"_recurrent"].apply(state, .linear)
        let n = state.count
        for i in 0..<n {
            let z = Self.sigmoid(a[i]+b[i]), r = Self.sigmoid(a[n+i]+b[n+i])
            state[i] = z*state[i] + (1-z)*Self.tanhApprox(a[2*n+i]+b[2*n+i]*r)
        }
    }

    func glu(_ name: String, _ input: [Float]) -> [Float] {
        zip(input, self[name].apply(input, .sigmoid)).map(*)
    }

    func convolution(_ name: String, input: [Float], history: inout [Float], dilation: Int = 1) -> [Float] {
        let size = input.count, taps = self[name].columns / size
        if history.isEmpty { history = [Float](repeating: 0, count: size * (taps-1) * dilation) }
        var joined: [Float] = []
        for tap in 0..<(taps-1) {
            let offset = tap*dilation*size
            joined += history[offset..<offset+size]
        }
        joined += input
        history = Array((history + input).suffix(history.count))
        return self[name].apply(joined, .tanh)
    }
}
