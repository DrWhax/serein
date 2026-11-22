import Foundation
import Testing
@testable import SwiftCalling

struct DREDInteropTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_DRED_FIXTURE"] != nil))
    func exchangeRedundancyWithRingRTC() throws {
        let env = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: try #require(env["SEREIN_DRED_FIXTURE"]), isDirectory: true)
        let weights = URL(fileURLWithPath: try #require(env["SEREIN_DRED_WEIGHTS"]))
        let model = try DREDModel(weights: Data(contentsOf: weights))
        let configuration = try #require(DREDConfiguration(model: model, duration: 50))
        let pcm = try readPCM(directory.appending(path: "input.pcm"))
        try #require(pcm.count.isMultiple(of: 960))
        var encoder = CallOpusEncoder()
        encoder.setDRED(configuration)
        encoder.setPacketLoss(26) // Match the pinned reference encoder’s 10% reported loss.
        var output = Data()
        for start in stride(from: 0, to: pcm.count, by: 960) {
            let packet = try encoder.transmission(Array(pcm[start..<start+960]))?.payload ?? Data([0x48])
            try #require(packet.count <= 80)
            output.append(UInt8(packet.count >> 8))
            output.append(UInt8(truncatingIfNeeded: packet.count))
            output.append(packet)
        }
        try output.write(to: directory.appending(path: "swift.frames"))
        let bytes = try Data(contentsOf: directory.appending(path: "native.frames"))
        var packets = [OpusPacket](), position = 0
        while position < bytes.count {
            try #require(position + 2 <= bytes.count)
            let length = Int(bytes[position]) * 256 + Int(bytes[position + 1])
            position += 2
            try #require(length > 0 && length <= bytes.count - position)
            packets.append(try OpusPacket(Data(bytes[position..<position+length])))
            position += length
        }
        try #require(packets.count == pcm.count / 960)
        let loss = try String(contentsOf: directory.appending(path: "loss-index.txt"), encoding: .utf8)
        let firstLost = try #require(Int(loss.trimmingCharacters(in: .whitespacesAndNewlines)))
        try #require(firstLost >= 4 && firstLost + 3 < packets.count)
        var playout = OpusJitterBuffer()
        playout.setDRED(configuration)
        let clock = ContinuousClock.now
        var repaired = [Int16]()
        var received = 0
        for played in 0..<firstLost+3 {
            // Keep three packets of normal lookahead. At the loss deadline the
            // first following packet is available, and its redundancy is due.
            let through = min(packets.count-1, max(played+2, played >= firstLost ? firstLost+3 : 0))
            while received <= through {
                if !(firstLost..<firstLost+3).contains(received) {
                    playout.insert(packets[received], timestamp: UInt32(received*960), sequence: UInt16(received),
                                   marker: received == 0, now: clock + .milliseconds(received*20))
                }
                received += 1
            }
            let rendered = playout.render(now: clock + .milliseconds(60 + played*20))
            let block = try #require(rendered)
            #expect(block.timestamp == UInt32(played*960))
            if played >= firstLost { repaired += block.pcm }
        }
        #expect(playout.statistics.dredRecoveredSamples == 2880)
        let reference = try readPCM(directory.appending(path: "native-recovery.pcm"))
        try #require(reference.count == repaired.count && repaired.count == 2880)
        func rms(_ values: ArraySlice<Int16>) -> Double {
            sqrt(values.reduce(0.0) { $0 + Double($1)*Double($1) } / Double(values.count))
        }
        let swiftEnergy = rms(repaired[...]), referenceEnergy = rms(reference[...])
        let ratio = swiftEnergy / max(1, referenceEnergy)
        print("RingRTC DRED received by Swift: \(repaired.count) repaired samples, RMS \(swiftEnergy), native RMS \(referenceEnergy)")
        #expect(swiftEnergy > 30)
        #expect((0.2...5).contains(ratio))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"] != nil), arguments: [960, 2880])
    func captureBudgetFollowsLoss(samples: Int) throws {
        let path = try #require(ProcessInfo.processInfo.environment["SEREIN_DRED_WEIGHTS"])
        let model = try DREDModel(weights: Data(contentsOf: URL(fileURLWithPath: path)))
        let configuration = try #require(DREDConfiguration(model: model, duration: 50))
        var sender = CallOpusEncoder(), reference = OpusSpeechEncoder()
        sender.setDRED(configuration)
        var protected = 0, sentBytes = 0
        for i in 0..<24 {
            let losing = (8..<19).contains(i)
            sender.setPacketLoss(losing ? 51 : 0)
            let pcm = (0..<samples).map { j -> Int16 in
                let t = 2*Double.pi*Double(i*samples+j)/48_000
                return Int16(6000*sin(600*t) + 3000*sin(10_500*t))
            }
            let encoded = try sender.transmission(pcm)
            let payload = try #require(encoded?.payload)
            let packet = try OpusPacket(payload)
            let redundancy = try DREDWire.decode(packet)
            if !losing { #expect(redundancy == nil) }
            if i < 8 { #expect(try reference.encode(pcm) == payload) }
            if redundancy != nil { protected += 1 }
            #expect(packet.sampleCount == samples && payload.count <= samples/12)
            sentBytes += payload.count
        }
        #expect(protected > 5)
        #expect(sentBytes * 8 * 48_000 <= 32_000 * samples * 24)
    }

    private func readPCM(_ file: URL) throws -> [Int16] {
        let bytes = try Data(contentsOf: file)
        try #require(!bytes.isEmpty && bytes.count.isMultiple(of: 2))
        return stride(from: 0, to: bytes.count, by: 2).map { i in
            Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8)
        }
    }
}
