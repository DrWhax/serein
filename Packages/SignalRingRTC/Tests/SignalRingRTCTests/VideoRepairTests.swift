import Foundation
import Testing
@testable import SwiftCalling

@Suite struct VideoRepairTests {
    @Test func feedbackAndRollover() throws {
        let missing: [UInt16] = [65533,65535,0,11,22,24]
        let nack = try #require(VideoRepair.nack(missing, from: 1003, for: 2003))
        #expect(Array(nack.suffix(8)) == [255,253,32,6,0,22,0,2])
        #expect(try VideoRepair.requested(nack, for: 2003) == missing)
        #expect(try VideoRepair.requested(nack, for: 1003).isEmpty)
        let padded = Data([0xa1,205,0,4]) + nack.dropFirst(4).prefix(12) + Data([0,0,0,4])
        #expect(try VideoRepair.requested(padded, for: 2003) == [65533,65535,0,11])
    }

    @Test func receiverBitrateEstimateAppliesOnlyToListedStreams() throws {
        let nack = try #require(VideoRepair.nack([17],from:1003,for:2003))
        // REMB for SSRC 1002 and 2003, mantissa 100000, exponent 3.
        let remb = Data([0x8f,206,0,6, 0,0,3,0xeb, 0,0,0,0, 0x52,0x45,0x4d,0x42,
                         2,0x0d,0x86,0xa0, 0,0,3,0xea, 0,0,7,0xd3])
        #expect(try VideoFeedback.maximumBitrate(nack+remb,for:2003) == 800_000)
        #expect(try VideoFeedback.maximumBitrate(remb,for:1002) == 800_000)
        #expect(try VideoFeedback.maximumBitrate(remb,for:1003) == nil)
    }

    @Test func lateRepairRestoresPacketsAcrossPictures() throws {
        let time = ContinuousClock.now
        func fragment(_ sequence: UInt16, _ timestamp: UInt32) -> RTPPayload {
            .init(type:108,timestamp:timestamp,sequence:sequence,marker:true,rotation:1,transportNumber:nil,bytes:Data([16,7]))
        }
        var queue = VideoReceiveQueue()
        #expect(queue.insert(fragment(65534,100), now: time).ready.map(\.sequence) == [65534])
        let gap = queue.insert(fragment(0,200), now: time)
        #expect(gap.ready.isEmpty && gap.missing == [65535])
        #expect(queue.insert(fragment(1,300), now: time).ready.isEmpty)
        let rtx = RTPPayload(type:118,timestamp:100,sequence:22,marker:true,rotation:1,transportNumber:nil,
                             bytes:Data([255,255,16,7]))
        let original = try VideoRepair.unpack(rtx)
        #expect(original.type == 108 && original.rotation == 1 && original.bytes == Data([16,7]))
        #expect(queue.insert(original,now:time).ready.map(\.sequence) == [65535,0,1])
        #expect(!queue.waiting && queue.insert(original,now:time).ready.isEmpty)
        #expect(queue.insert(fragment(3,400), now: time).missing == [2])
        #expect(queue.poll(now: time + .milliseconds(20)).missing.isEmpty)
        #expect(queue.poll(now: time + .milliseconds(60)).missing == [2])
        #expect(queue.poll(now: time + .milliseconds(260)).ready.map(\.sequence) == [3])
        #expect(!queue.waiting)
    }

    @Test func longULPFECMaskRestoresRolloverAndPadding() throws {
        // RFC 5109 wire layout for the first and last bits of a long mask.
        // The second packet has two-byte RTP extensions, orientation 3, and padding.
        let base: UInt16 = 65510, last = base &+ 47
        let first = RTPPayload(type:108,timestamp:400,sequence:base,marker:false,rotation:0,transportNumber:nil,
                               bytes:Data([0x10,0x22,0x33]),protectedHeader:.init(flags:0,tail:[]))
        let protected: [UInt8] = [0x10,0,0,1,4,1,3,0,0x10,0x55,0x66,2]
        var payload = protected
        for i in first.bytes.indices { payload[i] ^= first.bytes[i] }
        let time = ContinuousClock.now
        let header: [UInt8] = [0x70,0x80,UInt8(base >> 8),UInt8(truncatingIfNeeded:base),0,0,0,1,
                               0,15,0,12,0x80,0,0,0,0,1]
        let fec = RTPPayload(type:122,timestamp:0,sequence:last &+ 1,marker:false,rotation:0,transportNumber:nil,bytes:Data(header+payload))
        var decoder = VideoFEC()
        #expect(decoder.ingest(fec,at:time).isEmpty)
        let restored = try #require(decoder.ingest(first,at:time).first)
        #expect(restored.sequence == last && restored.timestamp == 401 && restored.marker && restored.rotation == 3)
        #expect(restored.bytes == Data([0x10,0x55]))
        #expect(restored.protectedHeader?.padding == Data([0x66,2]))
        var expired = VideoFEC()
        #expect(expired.ingest(fec,at:time).isEmpty)
        #expect(expired.ingest(first,at:time + .seconds(2)).isEmpty)
    }

    @Test func retransmissionHistoryExpiresAndDeduplicates() {
        var history = VideoSendHistory()
        let time = ContinuousClock.now
        func record(_ sequence: UInt16) -> VideoSendHistory.Fragment {
            .init(sequence:sequence,type:108,timestamp:50,marker:false,extensions:[],bytes:Data([7]),sent:time)
        }
        history.record(record(7))
        #expect(history.repairs([7,7,8],now:time).map(\.sequence) == [7])
        #expect(history.repairs([7],now:time + .milliseconds(50)).map(\.sequence) == [7])
        history.record(record(519))
        #expect(history.repairs([7,519],now:time + .milliseconds(100)).map(\.sequence) == [519])
        #expect(history.repairs([519],now:time + .seconds(2)).isEmpty)
    }
}
