import CryptoKit
import Foundation
import Synchronization

/// RingRTC group frame encryption, shared by encoded media and DeviceToDevice messages. Frame
/// counters are independent of RTP sequence numbers and are shared across the sender's tracks.
package final class GroupFrameCrypto: GroupMediaProtection {
    package typealias SendingKey = (ratchet: UInt8, secret: Data)
    enum Failure: Error, Equatable { case invalidKey, unknownSender, unauthenticated, replay, tooLarge, exhausted }
    private static let maxPayload = 4 << 20
    private static let footer = 21

    private struct Keys: Sendable {
        let ratchet: UInt8
        let secret: SymmetricKey
        let cipher: AESBlockCipher?
        let mac: SymmetricKey

        init(ratchet: UInt8, secret: SymmetricKey) {
            self.ratchet = ratchet
            self.secret = secret
            cipher = try? AESBlockCipher(Self.derive("RingRTC AES Key", secret))
            mac = Self.derive("RingRTC HMAC Key", secret)
        }

        static func derive(_ label: String, _ secret: SymmetricKey) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, info: Data(label.utf8), outputByteCount: 32)
        }

        func next() -> Self { Self(ratchet: ratchet &+ 1, secret: Self.derive("RingRTC Ratchet", secret)) }

        var signaling: SendingKey {
            let bytes = secret.bytes
            return (ratchet, Data((0..<bytes.byteCount).map { bytes[$0] }))
        }

        func crypt(_ bytes: Data, frame: UInt32) throws -> Data {
            guard let cipher else { throw Failure.invalidKey }
            var iv = SIMD16<UInt8>()
            for i in 0..<4 { iv[7-i] = UInt8(truncatingIfNeeded: frame >> (8*i)) }
            var output = [UInt8](bytes)
            for offset in stride(from: 0, to: output.count, by: 16) {
                let block = UInt32(offset / 16)
                for i in 0..<4 { iv[15-i] = UInt8(truncatingIfNeeded: block >> (8*i)) }
                let mask = cipher.encrypt(iv)
                for i in 0..<min(16, output.count - offset) { output[offset+i] ^= mask[i] }
            }
            return Data(output)
        }

        func tag(_ bytes: Data, frame: UInt32) -> [UInt8] {
            // HMAC authenticates the IV, length-prefixed ciphertext and empty associated data.
            var mac = HMAC<SHA256>(key: mac)
            var iv = Data(repeating: 0, count: 4)
            iv.append(contentsOf: GroupFrameCrypto.be(frame))
            iv.append(Data(repeating: 0, count: 8))
            mac.update(data: iv)
            mac.update(data: Data(GroupFrameCrypto.be(UInt32(bytes.count))))
            mac.update(data: bytes)
            mac.update(data: Data(repeating: 0, count: 4))
            return Array(mac.finalize().prefix(16))
        }

        func authenticates(_ bytes: Data, frame: UInt32, tag expected: [UInt8]) -> Bool {
            let calculated = tag(bytes, frame: frame)
            var difference: UInt8 = 0
            for i in 0..<16 { difference |= calculated[i] ^ expected[i] }
            return difference == 0
        }
    }

    private struct Chain: Sendable {
        var keys: [Keys] // newest first, up to five old ratchets for delayed frames
    }

    private struct Receiver: Sendable {
        var chains: [Chain] = []
        var highest: UInt32 = 0
        var seen = [UInt32](repeating: 0, count: 512)
        var lastExpensiveSearch: ContinuousClock.Instant?
    }

    private struct State: Sendable {
        var sender: Keys
        var pending: (key: Keys, due: ContinuousClock.Instant, again: Bool)?
        var nextFrame: UInt64 = 1
        var members: [UInt32: UUID] = [:]
        var receivers: [UInt32: Receiver] = [:]
    }
    private let state: Mutex<State>

    package init() { state = Mutex(State(sender: Keys(ratchet: 0, secret: SymmetricKey(size: .bits256)))) }

    init(secret: Data) throws {
        guard secret.count == 32 else { throw Failure.invalidKey }
        state = Mutex(State(sender: Keys(ratchet: 0, secret: SymmetricKey(data: secret))))
    }

    package var sendingKey: SendingKey { state.withLock { $0.sender.signaling } }
    package var pendingKey: SendingKey? { state.withLock { $0.pending?.key.signaling } }

    @discardableResult package func advance() -> SendingKey {
        state.withLock { s in s.sender = s.sender.next(); return s.sender.signaling }
    }

    /// Announce a new chain before using it, as RingRTC does. Departures during the
    /// five-second delivery window require a further key unknown to the later leavers.
    package func scheduleRotation(at now: ContinuousClock.Instant = .now) {
        state.withLock { s in
            if s.pending == nil {
                s.pending = (Keys(ratchet: 0, secret: SymmetricKey(size: .bits256)), now + .seconds(5), false)
            } else { s.pending?.again = true }
        }
    }

    /// Returns a fresh key requiring distribution if another rotation was queued.
    package func applyRotation(at now: ContinuousClock.Instant = .now) -> SendingKey? {
        state.withLock { s in
            guard let pending = s.pending, now >= pending.due else { return nil }
            s.sender = pending.key
            s.pending = nil
            guard pending.again else { return nil }
            let next = Keys(ratchet: 0, secret: SymmetricKey(size: .bits256))
            s.pending = (next, now + .seconds(5), false)
            return next.signaling
        }
    }

    package func setMembers(_ members: [UInt32: UUID]) throws {
        guard members.count <= 1024, members[0] == nil else { throw Failure.unknownSender }
        state.withLock { s in
            s.receivers = s.receivers.filter { members[$0.key] == s.members[$0.key] && members[$0.key] != nil }
            s.members = members
        }
    }

    package func install(secret: Data, ratchet: UInt8, demuxID: UInt32, sender: UUID) throws {
        guard secret.count == 32 else { throw Failure.invalidKey }
        let key = SymmetricKey(data: secret)
        try state.withLock { s in
            guard s.members[demuxID] == sender else { throw Failure.unknownSender }
            var receiver = s.receivers[demuxID] ?? Receiver()
            if receiver.chains.contains(where: { $0.keys.contains { $0.ratchet == ratchet && $0.secret == key } }) { return }
            receiver.chains.insert(Chain(keys: [Keys(ratchet: ratchet, secret: key)]), at: 0)
            if receiver.chains.count > 5 { receiver.chains.removeLast() }
            s.receivers[demuxID] = receiver
        }
    }

    package func seal(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= Self.maxPayload else { throw Failure.tooLarge }
        let (keys, frame) = try state.withLock { s -> (Keys, UInt32) in
            guard let frame = UInt32(exactly: s.nextFrame) else { throw Failure.exhausted }
            s.nextFrame += 1
            return (s.sender, frame)
        }
        var result = try keys.crypt(plaintext, frame: frame)
        let tag = keys.tag(result, frame: frame)
        result.append(keys.ratchet)
        result.append(contentsOf: Self.be(frame))
        result.append(contentsOf: tag)
        return result
    }

    package func open(_ ciphertext: Data, from demuxID: UInt32) throws -> Data {
        guard (Self.footer...Self.maxPayload + Self.footer).contains(ciphertext.count) else { throw Failure.tooLarge }
        let footer = ciphertext.suffix(Self.footer)
        let frame = footer.dropFirst().prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let ratchet = footer[footer.startIndex]
        let tag = Array(footer.suffix(16))
        let payload = ciphertext.dropLast(Self.footer)
        let keys = try state.withLock { s -> Keys in
            guard var receiver = s.receivers[demuxID] else { throw Failure.unknownSender }
            let slot = Int(frame % 512)
            guard frame > 0, receiver.seen[slot] != frame,
                  receiver.highest <= frame || receiver.highest - frame < 512 else { throw Failure.replay }
            do {
                let key = try Self.authenticate(payload, frame: frame, ratchet: ratchet, tag: tag, receiver: &receiver)
                receiver.seen[slot] = frame
                receiver.highest = max(receiver.highest, frame)
                s.receivers[demuxID] = receiver
                return key
            } catch {
                // Retain only the expensive-search throttle on failure.
                s.receivers[demuxID]?.lastExpensiveSearch = receiver.lastExpensiveSearch
                throw error
            }
        }
        return try keys.crypt(payload, frame: frame)
    }

    private static func authenticate(_ payload: Data, frame: UInt32, ratchet: UInt8, tag: [UInt8],
                                     receiver: inout Receiver) throws -> Keys {
        for chain in receiver.chains {
            for key in chain.keys where key.ratchet == ratchet {
                if key.authenticates(payload, frame: frame, tag: tag) { return key }
            }
        }
        // A reconnect can skip many ratchets. Rate-limit speculative long walks for this sender.
        let now = ContinuousClock.now
        let allowLong = receiver.lastExpensiveSearch.map { $0.duration(to: now) >= .seconds(1) } ?? true
        for i in receiver.chains.indices {
            guard let newest = receiver.chains[i].keys.first else { continue }
            let distance = Int(ratchet &- newest.ratchet)
            guard distance > 0, distance <= 5 || allowLong else { continue }
            if distance > 5 { receiver.lastExpensiveSearch = now }
            // Derive AES and HMAC keys only for the last six steps of a long jump.
            var secret = newest.secret
            var recent: [Keys] = []
            for step in 1...distance {
                secret = Keys.derive("RingRTC Ratchet", secret)
                if distance - step < 6 { recent.append(Keys(ratchet: newest.ratchet &+ UInt8(step), secret: secret)) }
            }
            guard let candidate = recent.last, candidate.authenticates(payload, frame: frame, tag: tag) else { continue }
            receiver.chains[i].keys = Array((recent.reversed() + receiver.chains[i].keys).prefix(6))
            return candidate
        }
        throw Failure.unauthenticated
    }

    private static func be(_ value: UInt32) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }
}
