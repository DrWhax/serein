import CryptoKit
import Foundation
import Testing
@testable import SwiftCalling

struct CELTPVQTests {
    @Test func pulseEnumerationMatchesOpus() throws {
        // For each codebook the Opus 1.5.2 oracle encoded every unsigned index
        // with ec_enc_uint and decoded its signed vector with decode_pulses.
        let books = [(2,128,512), (3,5,102), (4,3,88), (8,4,2816), (176,1,352)]
        var digest = SHA256()
        for (dimensions, pulses, count) in books {
            #expect(try CELTPVQ.size(dimensions: dimensions, pulses: pulses) == UInt32(count))
            for i in 0..<count {
                let vector = try CELTPVQ.vector(dimensions: dimensions, pulses: pulses, index: UInt32(i))
                digest.update(data: Data(vector.map { UInt8(truncatingIfNeeded: $0) }))
            }
        }
        #expect(Array(digest.finalize()) == callingTestBytes("08216ff5081a5698a1920b6a864f9a30308c6a106ea35ac7b6fdd65e977ceb24"))
        #expect(throws: OpusPacket.Failure.invalidPacket) { try CELTPVQ.vector(dimensions: 3, pulses: 5, index: 102) }
        #expect(throws: OpusPacket.Failure.invalidPacket) { try CELTPVQ.size(dimensions: 176, pulses: 128) }
    }
}
