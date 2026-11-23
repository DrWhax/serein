import Foundation
import Testing
@testable import SwiftCalling

struct OpusSpeechDecoderTests {
    /// Pinned WebRTC encoded a synthesized phrase in SILK and on a RingRTC call using
    /// hybrid. A fresh decoder from the same native archive rendered each packet sequence.
    /// Reference PCM contains every 31st signed little-endian sample at 48 kHz.
    @Test func rendersReferenceSpeech() throws {
        for vector in Self.vectors {
            try compare(packets: vector.packets, samples: vector.samples, ranges: [], tolerance: 0.03)
        }
    }

    @Test func reorderedRingRTCPacketsDecodeIdenticallyAcrossTimestampAndSequenceWrap() throws {
        let data = [UInt8](try #require(Data(base64Encoded: Self.vectors[4].packets, options: .ignoreUnknownCharacters)))
        var packets = [OpusPacket](), offset = 0
        while offset < data.count {
            try #require(data.count-offset >= 2)
            let size = 256*Int(data[offset]) + Int(data[offset+1])
            offset += 2
            try #require(size <= data.count-offset)
            packets.append(try OpusPacket(Data(data[offset..<offset+size])))
            offset += size
        }
        // Two distinct captured packets plus a repeated payload with a fresh RTP sequence.
        try #require(packets.count == 2)
        packets.append(packets[0])
        let origin = ContinuousClock.now
        var reference = OpusSpeechDecoder(), receiver = OpusJitterBuffer()
        var expected = [Int16](), stamps = [UInt32](), stamp = UInt32.max - 499
        for packet in packets {
            stamps.append(stamp)
            expected += try reference.decode(packet)
            stamp &+= UInt32(packet.sampleCount)
        }
        for (i, arrival) in [(0, 0), (2, 22), (1, 25)] {
            receiver.insert(packets[i], timestamp: stamps[i], sequence: UInt16.max &+ UInt16(i),
                            marker: i == 0, now: origin + .milliseconds(arrival))
        }
        var actual = [Int16]()
        for tick in 0..<(expected.count/960) {
            let candidate = receiver.render(now: origin + .milliseconds(100+20*tick))
            let frame = try #require(candidate)
            #expect(frame.timestamp == stamps[0] &+ UInt32(960*tick))
            actual += frame.pcm
        }
        #expect(actual == expected)
        #expect(receiver.reorderedPackets == 1)
        #expect(receiver.concealedSamples == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"] != nil))
    func jitterConcealsWithRegisteredModelWhenRingRTCPacketHasNoRedundancy() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"])
        let model = try DREDModel(weights: Data(contentsOf: URL(fileURLWithPath: path)))
        let config = try #require(DREDConfiguration(model: model, duration: 6))
        let bytes = [UInt8](try #require(Data(base64Encoded: Self.vectors[3].packets, options: .ignoreUnknownCharacters)))
        var packets = [OpusPacket](), offset = 0
        while offset < bytes.count {
            try #require(bytes.count-offset >= 2)
            let size = Int(bytes[offset])*256 + Int(bytes[offset+1])
            offset += 2
            try #require(size <= bytes.count-offset)
            packets.append(try OpusPacket(Data(bytes[offset..<offset+size])))
            offset += size
        }
        // Independent 16 kHz Opus 1.6.1 encoder with OPUS_SET_INBAND_FEC(0).
        let plain = try OpusPacket(#require(Data(base64Encoded: "SLV2om4dLOlxxof0VK2rng9YhpwJAO3Uxm9JbZkulm2EIB9vOXKW")))
        try #require(packets.count == 3 && !plain.containsLBRR)
        let origin = ContinuousClock.now
        var decoder = OpusSpeechDecoder(), predictor = DeepPLC(model: model), receiver = OpusJitterBuffer()
        receiver.setDRED(config)
        let decoded = try decoder.decode(packets[0])
        predictor.update(decoded)
        let prediction = predictor.conceal(samples: 960)
        receiver.insert(packets[0], timestamp: 0, sequence: 9, marker: true, now: origin)
        receiver.insert(plain, timestamp: 1920, sequence: 11, marker: false, now: origin + .milliseconds(40))
        let good = receiver.render(now: origin + .milliseconds(100))
        let loss = receiver.render(now: origin + .milliseconds(120))
        let resumed = receiver.render(now: origin + .milliseconds(140))
        #expect(good?.pcm == decoded && loss?.pcm == prediction && resumed?.timestamp == 1920)
        #expect(prediction.contains { $0 != 0 })
        #expect(receiver.statistics.concealedSamples == 960)
        #expect(receiver.statistics.dredRecoveredSamples == 0 && receiver.statistics.fecRecoveredPackets == 0)
    }

    @Test func preservesFirstLBRRBlockOfOtherwiseLostSixtyMilliseconds() throws {
        // Native Opus 1.6.1, 16 kHz mono, 18 kb/s, 25% expected loss. The 60 ms
        // SILK frame protects the first 20 ms of the preceding frame (LBRR mask 001).
        let data = try #require(Data(base64Encoded: "OPI/PA1djPWqcsZ9zlfIqB210Gk/IDBF5hOQN6VaiU7i4v5j+novZQ1Kih/FsRQbF5gVVI79/PYPGvb56p2MiwrkYm9EoAF4YqvAWM3o2hs9U/jp43GcqMrt6XOKHDzxBVZqGoRO97TSLEHs1Ol1FPDtRAOHKXpAabMTSXmbfj4j7LQb+uSpPjkyHuGWk+C5niHJ"))
        let packet = try OpusPacket(data)
        var decoder = OpusSpeechDecoder()
        _ = try decoder.recover(before: packet, samples: 2880)
        #expect(decoder.recoveredIntervals == [0..<960])
        _ = try decoder.recover(before: packet, samples: 3840)
        #expect(decoder.recoveredIntervals == [960..<1920])
    }

    /// Render native packets containing 9.7 and 17.9 kHz components together with speech.
    /// Check the final entropy range of each packet and mono 48 kHz reference samples.
    @Test func rendersPinnedCELTAndHybrid() throws {
        for vector in Self.transformVectors {
            try compare(packets: vector.packets, samples: vector.samples, ranges: vector.ranges, tolerance: 0.00002)
        }
    }

    private func compare(packets: String, samples: String, ranges: [UInt32], tolerance: Double) throws {
        let encoded = [UInt8](try #require(Data(base64Encoded: packets, options: .ignoreUnknownCharacters)))
        let bytes = [UInt8](try #require(Data(base64Encoded: samples, options: .ignoreUnknownCharacters)))
        let expected = stride(from: 0, to: bytes.count, by: 2).map { i in
            Double(Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i+1]) << 8)))
        }
        var decoder = OpusSpeechDecoder()
        var pcm: [Int16] = []
        var offset = 0, frame = 0
        while offset < encoded.count {
            try #require(encoded.count - offset >= 2)
            let size = Int(encoded[offset]) * 256 + Int(encoded[offset+1])
            offset += 2
            try #require(encoded.count - offset >= size)
            let packet = try OpusPacket(Data(encoded[offset..<offset+size]))
            let samples = try decoder.decode(packet)
            #expect(samples.count == packet.sampleCount)
            if !ranges.isEmpty {
                try #require(frame < ranges.count)
                #expect(decoder.finalRange == ranges[frame])
            }
            frame += 1
            pcm += samples
            offset += size
        }
        let actual = stride(from: 0, to: pcm.count, by: 31).map { Double(pcm[$0]) }
        try #require(actual.count == expected.count)
        let signal = expected.reduce(0) { $0 + $1 * $1 }
        let error = zip(expected, actual).reduce(0.0) { sum, pair in
            let difference = pair.0 - pair.1
            return sum + difference * difference
        }
        #expect(signal > 1_000_000)
        #expect(error < tolerance * signal)
        if !ranges.isEmpty { #expect(frame == ranges.count) }
    }

    /// A native stereo hybrid encoder with 35% simulated loss sent three 20 ms packets.
    /// Omit the middle packet and render it from the LBRR and CELT noise of the third.
    @Test func recoversDroppedNativeSpeechFromFollowingPacket() throws {
        let first = try OpusPacket(#require(Data(base64Encoded: """
            fKgDno1LuufwarYIHuN+4o/a2JXhnzx+CIhrBItXqWHgpzm+xnEoNszmyq43TCpCztZqDHpqVhH0M7c9/tSI1h9ImmmldkWAOx9grDdG
            puLhGAjvHhgo7AXG0kgGtJzUk7uXOQxy4Z9/LmZ+kVIGZxXuc5ZZxIwoQKcRRcgg0rZRSuHxFiiDDSQaXX9vHzkyA5JkzjDB/umaYrWp
            HgA9rp/YgOb1Ew==
            """, options: .ignoreUnknownCharacters)))
        let third = try OpusPacket(#require(Data(base64Encoded: """
            fPeZmH80Vz6gD8BaAq1/AsKRO+Km8ZxlxyfEFVzx3g/PgAFE0iCSRZESoXnvmaeQyq3WwBAowTW+zIc6fRKdTKIbT6QOavaxg+nrDjI6
            JZrMMsrsOOEiRpyKvk0FhwIzx+QwYWdu2MMNb/aevhjI90B+AaGoZzP0K5a1gtlhgUjkM8UppPEo0teJd8bxezwvFzoReOWQZz8ImGFh
            JsHvZT+Qiy/G
            """, options: .ignoreUnknownCharacters)))
        let reference = [UInt8](try #require(Data(base64Encoded: """
            dQRDBI754/69BGz/JQDw+2H7rvpDAHYAXP/qBZMJ8wC1/l7qS/H6+9z6JQMoCUcKVgWZ/Z3rx/OL9kL/SAk=
            """, options: .ignoreUnknownCharacters)))
        var source = OpusJitterBuffer()
        let origin = ContinuousClock.now
        source.insert(first, timestamp: 0, sequence: .max, marker: true, now: origin)
        source.insert(third, timestamp: 1920, sequence: 1, marker: false, now: origin + .milliseconds(40))
        let firstPlayed = source.render(now: origin + .milliseconds(40))
        #expect(firstPlayed?.timestamp == 0)
        let candidate = source.render(now: origin + .milliseconds(60))
        let recovered = try #require(candidate)
        #expect(recovered.timestamp == 960 && recovered.pcm.count == 960)
        for i in 0..<reference.count/2 {
            let sample = Int16(bitPattern: UInt16(reference[i*2]) | UInt16(reference[i*2+1]) << 8)
            #expect(abs(Int(sample) - Int(recovered.pcm[i*31])) <= 30)
        }
        source.insert(first, timestamp: 960, sequence: 0, marker: false, now: origin + .milliseconds(80))
        #expect(source.latePackets == 1)
        #expect(source.statistics.fecReceivedPackets > 0 && source.statistics.fecRecoveredPackets == 1)
        #expect(source.statistics.concealedSamples == 0)
    }

    @Test func initialDTXProducesSilence() throws {
        var decoder = OpusSpeechDecoder()
        for bytes in [[UInt8(0x48)], [0x48, 0], [0x4c, 0], [0xf8, 0]] {
            let samples = try decoder.decode(OpusPacket(Data(bytes)))
            #expect(samples == Array(repeating: 0, count: 960))
        }
    }

    private static let transformVectors: [(packets: String, samples: String, ranges: [UInt32])] = [
        (packets: """
            AAOA//4ACoByTBbhciNTTAYAC4BpKnth6USsODYEAAmAelLVbDfayAEACIApAIYeayX1
            """, samples: """
            AAAAAAAAAAAAAPn/GQAiACcAJwAwASAEpQ2TEwAMa/3z9KHw2vNt9Q==
            """, ranges: [0x1000000, 0x2386650, 0x22b47e00, 0x42a8de00, 0x2e1ad100]),
        (packets: """
            ARH43/PwihwTww/wcJdWBn+L2ab3LLbEis6hVgxvrE6IxLiiwSzG7qWtRSPH7M/04gh3l/nfKKZVfE0d9HL7EVcrbYklAfLe1eIthRQ/
            kORitaTV4kaToj9s5lXkGf0reSSgL/xr64Nh1DjJWsLT63vT3RF5kMax6GC3dTzGeul3IolDOOi1t1tQecB75kjhYAAa1yrxAag9Svjz
            XRUwPBTepWHDHi9AePjoarT6P9YXYhtVIteO+EgbrwF6xfHMqZ16hZE7GSMvvIFpWmi6ggwF4zEJDU4wxDlbWf6lBJdjnuGPe3jlw+cF
            NnMUU07kSpGoLV5uGuia2ovvwxj1qeI+vAwXkpETNVs2EOOyJ2djhD0A0fh7Gx5yQvGqN/MdaNWcCYcsrOgHRXOX5mYkkbWPuyxHvofR
            tXqHzYxJGTx28ntSmGE/UQYgMwKwoN0q/jWuLg24oCU97gEQMAfi/hYbpWGlzXbtw689xIN8qUlT8K9CrX+jI6l4gozZ0k08ykD059SE
            1z05yK76v5uCosTrs4ZyBh+bLgROOVRVgc+KSJ/ewwE4728s0inAwHfAW0xe7nxdFXr9LolBqb+X5f6/yJ38XYYHI9kxQH0fFHs1Fg4b
            8HARd0DCZZ3710Vx0MuTVa0NAKH4em3oRwmc4wPP0ithMgNV+dPwEOe3NLHrmCL51NNFCMJH9dcEqAEH38/wca9Jc3zMUtRmoqmP371Y
            V0xK2JgvVOMDnt/wXI8t2X5GgXjkiiqrugebPtdTf5Z/A/NjsjszVBvxABj/Odh0EfztnR5TcZXV35IeSlkvau9Mua89VrvWDdhLEypO
            UshLSMdx6q2iO1A+Z9Sphuxi8noO0WgxXg==
            """, samples: """
            AAACAP//+f8GADEAJgAJAHX/w/7v/mUHyhPTDccFlQVT9Rfvy+4W+4D9zf++EmUXog0D+lH93/yw7sjv6PwRDrAHJwulCRMIkgH28V3y
            pvH29h0JfSDCEtbmDRNWDj3qE9aC93UV1ORFBe4YJiP7AVTxjw8H747l8vbYENgGN+WiGHYcEP9044D/0wsD3oPvCgehFQwL/w/bDL38
            g/Vu7vbyJfuM+8gIJhRgBysEGwRB/trpZeaY/P0C
            """, ranges: [0x342e000, 0xaa8800, 0x7e65600]),
        (packets: """
            ATf8f4tTfopWYyku0mxhyVmeyv2sgircfgmX0wPhNRiG5QlNJMla+f/uzWLX/EHBcWLRhwa5EGwL685YP+QVzdgISCZalWUGveBoazmj
            ig3+li5Zw6j/UgtUgebAttTBIYVQqIoeQz34JvP5ijw9X4rlP72k9AnUwkZQhkcENXMsqvCc1Oj2WQtfSWEI6C6DHFCHieMYpCMAxgvf
            oEgu0hTqGR8ntIappQEHBYx2GqlXfvFaeFI70+xMCep0MpH+BVbIhoQu+1UAE94xrqITecY6sVwnclW611rC7ODOgrV4lsf6AQRW3N+i
            9iO8EZWzgYwk6as4x0unYGQ5y1nTnh0AM30OglMQR13ILoHNsGjrGrfZgts7y5A9Sy1vmROY3+jJNv6Da4tfbu89TZ7i8hs82pLa/d6x
            WQCr/Hr+8xnqIODZJlFD7ePzVy/a9xri65Uv6Mi9+FpbjOB+Dv6Erov7fuxtpoCbKR7Lf52bJm9F05kAvU7JB1J5Nv3HcXDj/Hf3S81N
            m6mM9Nm034J0xVD1kgSGGdS7RJwcQIZSB6Qoe1nEes5XE60JQ+v5aOh8BLwdGmEdwV38xgW09eQinQrUzOcTY/dPf1v5LgNNE6tGjwCI
            CLVG0+gxiI9ylJoCV2NV0k35AKH8evgZdwI+aFiPwOSwl6R3MZSeRGtaqW/7NAUgbMymv39rqWoXdGLsjmHuFUH9t3dxGQuB+SjAicNR
            fvvzR1lCFZudgVbhB1yUVV8ZtH39rBsUmhRxRfynDtK132eDLiu6J4Y7M3JZ+kLaHU5VgcR8rJtWDLiOt1WTKcyOrNQeNxvcPwcaevC7
            HrQHnDTcSQLfJxJRugtFMfmGUcgA7xzP1A==
            """, samples: """
            AAAVAAgAJACv/2kACwC0/+/+9v9gAX8C5xKMC2QBMgEM7jPuC/fl/8IGegPtBsYMzP+b8V/9L/qn/ZUBnP4lCqv5uPjp/vMDb/sn+aMF
            4fgk+G//b/mdFjDj1xGaHt7nv+6c/OD8ffMM9cMLHS99+4D0mQ0p4Dn2ku/XCfAbv+D/Gk4HFguf3PcGAxJV4vMNlQESBsEDM/cyAZ/9
            AP1gAn0GrP8w+/j8CwHpBEb2LghGAgb9z/h39fn7
            """, ranges: [0x1e270400, 0x628d0200, 0x869c67]),
        (packets: """
            AIB4ggGm2rKHIyIAAADGAK/3e0k6xQ4ZygDEqV8i6piZx2NSpZ4cLS/ISi4NCiHzRXDBKs6FNJwROJ9p1pSdPHvRvUxw7WE8YOSqDA0v
            TfYkjDOsKFQuXZR774bTA+JRiatuflcYP/gIfQKhFOOAcW/Nc3JSJ43IPDfodwuNLd91ogCceKiPJKG/mA7GRPol5rrG39xwEcABNeij
            6aA+Yob47IJ7KrK0oOZYl50co9G1Guxb5aJ5+qWkOuI9Zfa/HgcoDSvL8+6Xsrn+/ScWCiJxVal5/6/2KUNKk1sl5x03nzu6CFpelsfX
            AUxtdSrCmPG6XH2Gf/bhhUVuKNEFI2n9wyx/9X7nu6jnzuDu1jNb6iHisVe83Uf+P6ccQkhz
            """, samples: """
            AAAAAC8AHQAgABMAOQDx/kQAQ/8oAL8LPhJWDNMFZwVc9nzsWe7e+377kf20D3gXlAuv+ZX5avri7N/sR/kvDfwIXwwiDKoE2f009qPx
            p/KF9JMTrCMNE1noYAgmE5Dzh90i8zoVROXp+3AfOB6e+JP0qwwy7cfmavWqFA==
            """, ranges: [0x1303300, 0x3e50600]),
        (packets: """
            ADlkqGBicNqJELMPx6rXuGW3jLJ0iOE6XGcmeznXI8G4HF7Zzjz1wClDgUqj+i3HiXVS0fbmb6WKam0AQ2SnUXmLeAVOUNR6R8f36f+1
            OsQPMgsZGgVomjPfhQ5Q3Ck7M2pUum6k+9JmvYYpwgQPDvtv0cTu6G7qWVNe3mDo+No=
            """, samples: """
            AAAAAE0ALwA0AMz/1f+Y/3f/zwD0Av4FhBKnDDgCAwNE89fvtvNf/HgHcAmACS4MVfuk9RLuTxhU8LDtFB0=
            """, ranges: [0xa91bf00, 0x37b47600]),
    ]

    private static let vectors: [(packets: String, samples: String)] = [
        // Stereo SILK, forced on the pinned WebRTC encoder. Reference output is mono.
        (packets: """
            AbRc7pOJ1+kOMMcItT1DTUECv/opalH0Mqr+agSqbDe24JnN4D9fLHYHF7isQaGEpj3X+Ovkc1VyNAcCvYttuLkbW351szarhLgN
            dsrBpdunVj5q2TH1PzbV8uBs7xRqcEUCWsPxoY49rR7X0mcHSZlCtXy6CKzrj1qSUQVGpab0llbmuBjzwVbV8E7pqM313IGV/cs8
            BDpuQ41LP/dHPNWKpWEDOpoWI4DMrGC7f6QqdW3uXLET8epPRNtFECl0JTkCAuQ7hUQFemcljTMXs5yHZn5Cn0oUXKb+/UWJk07l
            /k6LaUOjbHhQA2K71ZD9yEgIovgAKtqUSAVf0HalSMQI0UucocI6qybMklhiSGYQMHd/qzCy82QmhKOFxhSDwUfCC+wbVAUjcu3K
            6kEPP18bkVpCVGcUKkImyvo+EV5r8Z0dC5oPgcQXTtln9MVHS0hgq5ws0IwMtfdlNJkSufDWV3gg+XKIXOHuui7ScLOK/0+BBGpv
            n6masW43UIOW9QdfuyXDCbuLvvJQBs6dpUggVbQTViyT5IPXUl+U8qOzNo51qgVJcsKUu6ATt8rKVm6XJ+swAhZc//TfZV8KL4eV
            Fwm4sSX02bpZM5ZD0jYSPGRmHWWn9rmVjvRmyKkOEEJVOEwWxlDfovz4UKD8Jcc8+dyer+L38otuCy3xt2F236OGn81GdUzPEtUR
            3P2gR5KYmdNp98/8e/XuywfYHC8k3WeGPzwvigz6KcpGw6Gb3mnwQYPCJFVfXU4Nw2wvY0/agoEUJmKySMtg+nvcL1Ca+L2AypDD
            Hycf0CNoLlcWqe76jG0s5irMERyN48ianFxmJ7xkqMpdtegqkdDs6IelG5/gnMZafmolawuJQjwozY6Y+UE8i8q0GDTUXme/8XOf
            tLSxvbLCW5Ev4YBcuCb88vSKXNnIf0voimpVWb/LMCXbPwEpEj8nLnpxjEGdfTXo8kqhS2WYLuCFhjgzPVp9Vj9aEJW6S9WnA2xW
            fx7AJNxDXgDylsNxtSjFy8Nz4JwE40ZIdXCzpM/oEKNV6yrA3gU9j+pCjrnsATr5dSENEfeX3b9gXXokPSisHGMPBxBSnRznUiTM
            c+eI/SRN690gpWJuBmrABprBXGJHqO7PGBSpVc6cLUngQpEFmARhGZfV0NRJo3OEy6xjoNEr6ixjY4MWS/IaAAG834VATqQIBVLj
            Ph2I2/JotklIZI2nqwwmrfX8ZLc1ZtInpD7zzYzzy5E8VAncK6AH+W5pc9ceGLumKCrqKZOyew8l6lEQ5W1lh044jDcIZ8C68tA=
            """, samples: """
            AAAAAJYAAwDq/zL/lf8i/3T/pgBHBT8PxhEo/pbrld+u9qgJtAzQEA0B5vfT8aP+jf4oB8QCcgSI/+sFJ/+Z+/D2tfkI/3wQ+xWw
            ARP2IuYt79f+ex9FFXsKfO+r5TvnkAfoFhwVnwrp89LprO+HBwgGGxDEA8b+EPWdAkP60fyd/PcBpQTnDRwK0/Ti8AztB/7BDX8g
            iAjx+WjlSOjp94kYlRsgDRj7sObf6Cj7IxQDDkYPk/rK9C3xAwSM/oQF1gM+BAMBUga//iXzs/UT+HwLBxL4FfD3qe7Z5R346Ql9
            IRkSBv4E7NfjgfT/DFYdww3GA3PujO6+87QLOQj3CqABifyl+a0BFPzS9jMAxQFTDKAL1wi76zvvtvBsBosURR3GAT7uUeYJ7MgF
            uRoWGw8AlfVD5C7x/QGYF3AJvQdr+GbzcPeeA6QB0v2lBqcBowfJAen+1elf+ML9VBFEEyIQE/BP553s1vw4Feoddg4z71rr
            """),
        // Stereo HYBRID, forced on the pinned WebRTC encoder. Reference output is mono.
        (packets: """
            AG18qTidjSCdV7XHbWbKxf5knd4gvDRfZM0JFMZBFzy1UKT+3wzXjpIEyEQL3DPPKXQPwejVYB96S1DBHopR+Xa2dlh247SCA4mw
            6Sn5BTUYw68xWAA1oo5pwX2r6BdgOiiF68YZdTmW8Vwy4ihuAJ98+Ti9VPjXjpGI4OFEYhluNl3pE00OjQkSiKGVg53CeTh7M0ji
            lyxCGB5OEcNiJbbbV0tms7zS+0dYQNQE5nb4/Z4zcBJyztB3OK43kKEHuPnlYFZXJZFEDJjhXXtTi2mvtNDzrvtTv6Bebs5DQd9S
            +vPh0JvxKybB4mskEI6kDl9jEJa/KDm16r4Jza57c+r0QlBnZvZYytmPYP/07/k=
            """, samples: """
            AAAAAJUABADq/x//kP8m/3n/lgCNBZcPDxDw/izrcN419egJ3AyFDjwAMfqs9C78XAIcB9EBHQKA/lIG2/5f+7L4vPms/xAQTRY4
            ArT0IecL7+/+TB84FXMK0vDL5KbnkgeJFg0V9Qp99APqBvDrBgIGTxBnAzH/kvXLAQ==
            """),
        (packets: """
            ALQY+wH8TvOgSN9HaGCYpyvOivcDGHUlpmc4eg6CSTsbrM2lQ0l9+FwQZ+KJH/zzYTiES32R8eXlf7JIVhJyvuCGsYL0Ft7K
            PwIQp75R3fe31bAToyrNma/h0q7sZefHsQviQrd7MX3bHEgoQtKGa5xKw22FgUfKMrtdXUjfBCSwcR4LoAk+SOmoJFEd2Dm7
            uH1JB0tEQ/Y8FFVfsmqVyqQTA+Tkanj//m95HXtwZ4DRuOfPz+wAtBtBAP9RNmGDcbv1HiIF1C4YhW0nIVwagKCpfPiKu5ow
            03QxMEekLLqOs+/OuX0t6ZFUiwIW0dgwXGI202ZzCYILQHslVb4dn/kTP3iHqPnETxuBYEXX8d8IEZAd2JBcBKW65IefLr8M
            Ib2gbr2M/qWfMi32v69rMUovmHBCYPG5n0+xwYHIqVIVo1d+FMvpd4fR6gvPOPfxPp7jJlm/nf5J4PoppaugyWOaA7iUX6LM
            qctQwA==
            """, samples: """
            AAAGAP3/JgAeAFEA+wBGAQwBwwAoAH//Ov9e//z/bwArAAMAsv+y/gr+aP6+/x0BywFLATEASP9P/hT+vv7p/z8AUf2C/Af9
            gQOZCZ4JkAZ5AEr6Ofhi+Mn5afvMAPgHFwxtDJoF+/uW9lz1BvfN+Rn+xwUWC/INOgorAPr3w/Rz9TX4mvvXAQMIPQxhDKwF
            +/wn+MT2UvcF+fT8iwJRB/YJowcIAmf9yfrp+U36LPy0/+gCKAUbBYACp//J/er8+fy0/Ub/FQFcAs8C+gGnAK//Df+v/n3+
            wv6I/2AAGQFIAQkBtQBFALn/Kf/o/hb/iv8kAJEA1wAHAfMARwA5/z7/LgC/AOcB8QDE/rH+Bv5T/ij/3QCJAXwHeAUA/wb+
            +vsm+zv7A/7UAPAJyQitAqv99fgI+Fn7Cv9wB2EMxAlEASL1H/C88sb6bQe4FZQXVAZW8yPqd+l59Sz9GB0VJnANq/BV5Xvm
            hfDE/CsVIircG+Xz
            """),
        (packets: """
            ADxI9O+1f2l4AYar3IqbMYsQ6d9BHBvwdYmwBFTL40VpwGzmY43ZcfD08kjlp1IipV8MPoVxLugeOOZgK9AAPEjxu7Z/99vv
            AiLZIKmSWwOsxeTG0ktCLt4i/zz5uGAGQpwll6c/LM0z5MyIfWm6Zf0ryWkzaOiuU3278AA8SO3uMkNW1YVgAgQlo9/WLnGO
            30vw/2E/H8A1fFkTnB5M7/XnZNCUsj6biPRQXMcPf0RevZd25yrDzJ+A
            """, samples: """
            AAAAACgA7foL9hn9ggEhDRUNO/a99m0DXPRc9s8C+AnbFlcEpuu0ACT96PAw/iYCKBFxFB70ffGT/Mf0VfZZAIL/WgvQ+7fr
            hu8l8wP3hf+/CAITHhVTBnr3XfHO8cH2q///BT8POg7EAzT6A/WU9cb6T/9xBuYK6QdYAU37FPhV+bb83//6BMcHfAXaAGL8
            cPpj+4j9x/+HA5cF7AOsAIb9EPyx/Ib+BQBKAusD1QKIAED+9fyC/RD/
            """),
        (packets: """
            APB7QwOx6OFNE1JQMKnLpNnz1tO3AkNqUAAKjzNrSk7Q7uT69E2F3H98V70OSwGrzTw9rxsSLQnRE/CzUbG7u1AaC/OwaNe5
            +7nxdIUFS4VmVw6t5ADulnolEDs0M26urmszrQIWVGWjO4Vdv9C3JH7rAidiH2LJ7h1QOyhjya0JhgrxyuJ7xDol7ixpHeYL
            NR2xWuVaCJg8kpyv+YhdG+eA+QAT+4la70rayfPra6MP+tdI9b27gQvRJqsSAwKvSZyHETpQHF24IddHbb/TnnViwG9HHcEl
            ndNOZqzC3HMj/WQgW+p0J8F10KQEfkUAAAAA8HtDAwv8ylEHiEbZJaEa+PMI88FXA9FV1M84Pg8wr6zegUV5QZKEgjmOqEK9
            zE1o+w7gUBRph8veHmlKXIImf/UntlJXj2W9RZ0/uii85jCmxoBjyl9ySSOojeFDpu+tEfnpljOD0V+cASNgY6OJWqmNdYgw
            56p5G15RfpA2GCI7F81vrH7YCnMZ5deZ5ZWY0DgYmWjZo2mf3/RwF/EMloJWyfMxTKaSG0UINAruuCcE4Xy7iSKyPggcTQBF
            hFKK7bPSE3Nw/52dhy9+2J2XMpxNXGJzlxYPTemcaPy7MQgSMy1FzZKQiF/BiZoreQAAAA==
            """, samples: """
            AAD9/8760/BM+kwH8AXT+D73hhSPBp/0jQg+EtcOsAq8AHwBpw7R+sTdb/F4C9MQI/+B4jsAPx4c8obXLfnTHtMTqvks+bEL
            cxGd7NHZ/PYjDMgNqwPk/0oPhwz6+ArwKPcTCUgP2wY2AqQJDg4gBNb2nvesAhMIVgSjAV4FxQhlBkkANf2d/xsDiwO7AZQB
            MQOEA7QAuv1a/S//rwDKAIMA6QALAScADv+y/k//HACOAJAAmgDOAIkAwP8n/yz/qv8jAFUAUQBoAFUA6/+L/3X/sP/8/ywA
            RgBXAEoAEwDM/6j/tf/e/wsALQBBAEMAKAD3/8X/uP/V/wAADQAgACYAGAAHAN7//v8sAL7/8/8pADYAHQBU//j/VQFk/p8A
            2ABR/cAAIQFD/2v/fv93AUYCP/7qAc38FgGyAcL8HwNQ/w3+NwJF/5v7HALqAVL6KAU+AVv5zwaj+83+PAWt+l8EQgMl+e8C
            eQIm+kAE2QEz/9j/
            """),
    ]
}
