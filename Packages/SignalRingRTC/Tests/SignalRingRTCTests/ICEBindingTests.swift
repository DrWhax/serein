import CryptoKit
import Foundation
import Testing
@testable import SwiftCalling

struct ICEBindingTests {
    // RFC 5769 sections 2.1 and 2.2. Padding is included in the authenticated bytes.
    let request = """
    000100582112a442b7e7a701bc34d686fa87dfae
    802200105354554e207465737420636c69656e74
    002400046e0001ff80290008932ff9b151263b36
    000600096576746a3a68367659202020
    000800149aeaa70cbfd8cb56781ef2b5b2d3f249c1b571a2
    80280004e57a3bcf
    """
    let response = """
    0101003c2112a442b7e7a701bc34d686fa87dfae
    8022000b7465737420766563746f7220
    002000080001a147e112a643
    000800142b91f599fd9e90c38c7489f92af9ba53f06be7d7
    80280004c07d4c96
    """
    let key = SymmetricKey(data: Data("VOkJxbRl1RmTxUk/WvJxBt".utf8))

    @Test func referencePackets() throws {
        let check = try ICEBinding(packet: callingTestBytes(request), password: key)
        #expect(check.username == "evtj:h6vY" && check.priority == 0x6e0001ff)
        #expect(check.role == .controlled(0x932ff9b151263b36))
        let reply = try ICEBinding(packet: callingTestBytes(response), password: key)
        #expect(reply.isResponse && reply.transaction == check.transaction)
        #expect(reply.mapped == .init(ip: [192, 0, 2, 1], port: 32853))
    }

    @Test func rejectsDamagedAndUnauthenticatedChecks() throws {
        let original = callingTestBytes(request)
        for count in 0..<original.count {
            #expect(throws: (any Error).self) { try ICEBinding(packet: Array(original.prefix(count)), password: key) }
        }
        for i in original.indices {
            var changed = original
            changed[i] ^= 1
            #expect(throws: (any Error).self) { try ICEBinding(packet: changed, password: key) }
        }
        #expect(throws: (any Error).self) { try ICEBinding(packet: original, password: SymmetricKey(size: .bits256)) }
    }

    @Test func nominateAndReturnMappedAddress() throws {
        let id = Array(UInt8(0)..<12)
        let wire = try ICEBinding.request(transaction: id, username: "peer:local", role: .controlling(12),
                                          priority: 12345, nominate: true, password: key)
        let check = try ICEBinding(packet: wire, password: key)
        #expect(check.nominated && check.transaction == id && check.role == .controlling(12))
        for ip in [[192, 0, 2, 1] as [UInt8], Array(UInt8(0)..<16)] {
            let address = ICEBinding.Address(ip: ip, port: 50217)
            let reply = try ICEBinding(packet: check.response(mapped: address, password: key), password: key)
            #expect(reply.isResponse && reply.transaction == id && reply.mapped == address)
        }
    }
}
