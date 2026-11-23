// Opus 1.6.1 RDOVAE. See LICENSE-Opus.txt for source and redistribution terms.
struct DREDNetwork {
    struct Encoded {
        let state: [Float]
        let latent: [Float]
    }

    private var recurrent: [[Float]]
    private var convolution = [[Float]](repeating: [], count: 5)

    init(encoding: Bool) {
        recurrent = Array(repeating: Array(repeating: 0, count: encoding ? 32 : 64), count: 5)
    }

    private mutating func stack(_ input: [Float], model: DREDModel, encoding: Bool) -> [Float] {
        let prefix = encoding ? "enc_" : "dec_"
        var buffer = model[prefix + "dense1"].apply(input, .tanh)
        for i in recurrent.indices {
            let number = String(i+1)
            model.gru(prefix + "gru" + number, input: buffer, state: &recurrent[i])
            buffer += encoding ? recurrent[i] : model.glu(prefix + "glu" + number, recurrent[i])
            let reduced = model[prefix + "conv_dense" + number].apply(buffer, .tanh)
            buffer += model.convolution(prefix + "conv" + number, input: reduced, history: &convolution[i],
                                        dilation: encoding && i > 0 ? 2 : 1)
        }
        return buffer
    }

    /// Two consecutive 10 ms analysis frames in chronological order.
    mutating func encode(_ input: [Float], model: DREDModel) -> Encoded {
        let buffer = stack(input, model: model, encoding: true)
        let summary = model["gdense1"].apply(buffer, .tanh)
        return Encoded(state: Array(model["gdense2"].apply(summary, .linear).prefix(50)),
                       latent: Array(model["enc_zdense"].apply(buffer, .linear).prefix(25)))
    }

    /// The wire orders 40 ms redundancy chunks and their feature frames newest first.
    static func decode(state: [Float], latents: [[Float]], model: DREDModel) -> [[Float]] {
        guard state.count == 50, (1...26).contains(latents.count), latents.allSatisfy({ $0.count == 26 })
        else { return [] }
        let hidden = model["dec_hidden_init"].apply(state, .tanh)
        let initial = model["dec_gru_init"].apply(hidden, .tanh)
        var decoder = DREDNetwork(encoding: false)
        for i in decoder.recurrent.indices { decoder.recurrent[i] = Array(initial[64*i..<64*(i+1)]) }
        var features: [[Float]] = []
        for latent in latents {
            let buffer = decoder.stack(latent, model: model, encoding: false)
            let output = model["dec_output"].apply(buffer, .linear)
            for f in 0..<4 { features.append(Array(output[f*20..<(f+1)*20])) }
        }
        return features
    }
}
