// Crypto formats: production SignalCore against the Lean model in Verification/Crypto.
//
//   transportPadding  MessageSender.pad and MessageReceiver.unpad, on messages and byte strings
//                     heavy in 0x00 and 0x80.
//   derivations       every key SignalCore derives (storage, manifests, records, GV1 migration,
//                     sticker packs, call link room ids, access-key verifiers), recomputed here
//                     with CryptoKit from the model's table.
//   profilePadding    encryptName and encryptPadded: the padded plaintext, decrypted here.
//   manifests, records, profileFields, stickers, provisioning, deviceNames: values sealed here
//                     (CryptoKit, CommonCrypto, keys from the model's table) under the right key,
//                     under keys one parameter away, under unrelated keys, by key holders with bad
//                     contents, and changed after sealing; production's verdict against the
//                     model's. Production's own provisioning envelopes and device names are also
//                     decrypted here with the model's keys, and ours by production.
//
// Run through Tools/verify-crypto.sh, or set SEREIN_CRYPTO_ORACLE to the oracle executable.

import CommonCrypto
import CryptoKit
import Foundation
import LibSignalClient
import SignalProtos
import Testing
@testable import SignalCore

enum CryptoOracle {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../Verification/Crypto").standardized
    static var path: String {
        ProcessInfo.processInfo.environment["SEREIN_CRYPTO_ORACLE"] ?? root.appendingPathComponent(".lake/build/bin/oracle").path
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: path) }

    struct Failed: Error {}

    static func call(_ mode: String, _ lines: [String]) throws -> [String] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("serein-crypto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let inURL = dir.appendingPathComponent("in.txt"), outURL = dir.appendingPathComponent("out.txt")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: inURL)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = [mode]
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failed() }
        let out = String(decoding: try Data(contentsOf: outURL), as: UTF8.self).split(separator: "\n").map(String.init)
        guard out.count == lines.count else { throw Failed() }
        return out
    }

    /// The model's derivation for each use (`derive`), by use.
    static func table(_ uses: [String]) throws -> [String: String] {
        let unique = Array(Set(uses))
        return Dictionary(uniqueKeysWithValues: zip(unique, try call("derive", unique)))
    }
}

/// Bytes as the oracle writes them: hex, `-` for none.
func dashHex(_ d: Data) -> String { d.isEmpty ? "-" : d.hex }
func undash<S: StringProtocol>(_ s: S) -> Data { s == "-" ? Data() : Data(hexString: String(s)) }

/// An oracle `derive` answer (`<source> hmac <input>` or `<source> hkdf:<salt>:<length> <info>`)
/// applied to `secret`, with CryptoKit.
func applyDerivation(_ answer: String, _ secret: Data) -> Data {
    let w = answer.split(separator: " ")
    let input = undash(w[2])
    if w[1] == "hmac" { return hmac(secret, input) }
    let p = w[1].split(separator: ":")
    let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: undash(p[1]), info: input, outputByteCount: Int(p[2])!)
    return unsafe key.withUnsafeBytes { unsafe Data($0) }
}

/// X25519 with CryptoKit (libsignal's public keys are 0x05 ‖ the 32 bytes).
func x25519(_ ours: PrivateKey, _ theirs: Data) throws -> Data {
    let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ours.serialize())
    let secret = try priv.sharedSecretFromKeyAgreement(with: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs.dropFirst()))
    return unsafe secret.withUnsafeBytes { unsafe Data($0) }
}

/// Whether two encodings of a public key are the same key to libsignal and X25519: libsignal
/// reads the first 33 bytes (trailing bytes are ignored), and X25519 ignores the top bit.
func sameSecret(_ ours: PrivateKey, _ a: Data, _ b: Data) -> Bool {
    guard let ka = try? PublicKey(a), let kb = try? PublicKey(b),
          let x = try? x25519(ours, ka.serialize()), let y = try? x25519(ours, kb.serialize()) else { return false }
    return x == y
}

/// AES-256-CBC encryption (CommonCrypto), with PKCS#7 padding or none (whole blocks).
func cbcEncrypt(key: Data, iv: Data, _ plaintext: Data, pkcs7: Bool = true) -> Data {
    var out = Data(count: plaintext.count + 16)
    var moved = 0
    let outCount = out.count
    let status = unsafe out.withUnsafeMutableBytes { o in
        unsafe key.withUnsafeBytes { k in
            unsafe iv.withUnsafeBytes { i in
                unsafe plaintext.withUnsafeBytes { p in
                    unsafe CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(pkcs7 ? kCCOptionPKCS7Padding : 0), k.baseAddress, key.count,
                                   i.baseAddress, p.baseAddress, plaintext.count, o.baseAddress, outCount, &moved)
                }
            }
        }
    }
    precondition(status == kCCSuccess)
    return out.prefix(moved)
}

/// AES-256-CTR (CommonCrypto, a 128-bit big-endian counter).
func ctrCrypt(key: Data, iv: Data, _ data: Data) -> Data {
    guard !data.isEmpty else { return Data() }
    var cryptor: CCCryptorRef?
    let created = unsafe key.withUnsafeBytes { k in
        unsafe iv.withUnsafeBytes { i in
            unsafe CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                           i.baseAddress, k.baseAddress, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        }
    }
    precondition(created == kCCSuccess)
    defer { unsafe CCCryptorRelease(cryptor) }
    var out = Data(count: data.count)
    var moved = 0
    let outCount = out.count
    let status = unsafe out.withUnsafeMutableBytes { o in
        unsafe data.withUnsafeBytes { d in unsafe CCCryptorUpdate(cryptor, d.baseAddress, data.count, o.baseAddress, outCount, &moved) }
    }
    precondition(status == kCCSuccess && moved == data.count)
    return out
}

func gcmSeal(_ key: Data, _ plaintext: Data) throws -> Data {
    try #require(try AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined)
}

/// Disagreements: the first few are recorded, all are counted; and how often the model gave each
/// verdict (printed, so a run shows every path was taken).
struct Disagreements {
    var count = 0
    var verdicts: [String: Int] = [:]
    static let tags: Set = ["ok", "name", "text", "invalid", "tooLong", "tooShort", "malformed", "badKey", "badMAC", "badPadding", "proto",
                            "versionMismatch", "unrequested", "cannotDecrypt"]
    mutating func check(_ got: String, _ want: String, _ what: @autoclosure () -> String) {
        let tag = String(want.prefix { $0 != ":" })
        verdicts[Self.tags.contains(tag) ? tag : "bytes", default: 0] += 1
        guard got != want else { return }
        count += 1
        if count <= 3 { Issue.record("disagree: \(what()): production \(got), model \(want)") }
    }
    func done(_ test: String) {
        print("model verdicts in \(test): " + verdicts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        #expect(count == 0, "disagree: \(count) cases in \(test)")
    }
}

@Suite(.serialized, .enabled(if: CryptoOracle.available, "build the oracle: Tools/verify-crypto.sh, or lake build in Verification/Crypto"))
struct CryptoConformanceTests {
    static var count: Int { ProcessInfo.processInfo.environment["SEREIN_CRYPTO_CASES"].flatMap { Int($0) } ?? 1000 }

    /// Bytes mostly from a few values (0, 0x80, 1, 255, 'A'), so that near misses are common.
    static func bytes(_ r: inout SplitMix, _ maxLen: Int, min: Int = 0) -> Data {
        let n = min + r.below(maxLen - min + 1)
        var out = Data()
        for _ in 0..<n {
            let k = r.below(8)
            out.append(k < 2 ? 0 : k == 2 ? 0x80 : k == 3 ? 1 : k == 4 ? 255 : k == 5 ? 0x41 : UInt8(truncatingIfNeeded: r.next()))
        }
        return out
    }

    static let pool = ["a", "Z", " ", "\u{0}", "é", "😀", "ж", "1"]
    static func text(_ r: inout SplitMix, _ maxChars: Int) -> String {
        var s = ""
        for _ in 0..<r.below(maxChars + 1) { s += pool[r.below(pool.count)] }
        return s
    }

    /// One of: a byte changed, cut, extended, or something else entirely; never the input.
    static func alter(_ r: inout SplitMix, _ d: Data) -> Data {
        var d = d
        switch r.below(4) {
        case 0 where !d.isEmpty: d[d.startIndex + r.below(d.count)] ^= UInt8(1 + r.below(255))
        case 1 where !d.isEmpty: d = d.prefix(r.below(d.count))
        case 2: d += randomBytes(&r, 1 + r.below(20))
        default: d = randomBytes(&r, d.count + 1 + r.below(5))
        }
        return d
    }

    static func name(_ e: Error) -> String {
        switch e {
        case StorageServiceError.cannotDecrypt(_): "cannotDecrypt"
        case StorageServiceError.manifestVersionMismatch: "versionMismatch"
        case StorageServiceError.invalidWrite(_): "unrequested"
        case SignalCryptoError.badLength(_): "tooShort"
        case SignalCryptoError.badMAC: "badMAC"
        case AttachmentError.tooShort: "tooShort"
        case AttachmentError.badMAC: "badMAC"
        case ProvisioningError.malformedEnvelope(_), ProvisioningError.missingField(_): "malformed"
        case ProvisioningError.badMAC: "badMAC"
        case SignalError.invalidKey(_): "badKey"
        case SignalError.invalidArgument(_): "badPadding"
        case ProfileWriteError.tooLong: "tooLong"
        default: "\(type(of: e))".contains("Decoding") ? "proto" : "other:\(e)"
        }
    }

    /// Text answers compared as production makes them: bytes decoded as UTF-8 (invalid sequences
    /// replaced), then encoded again.
    static func asText(_ hexBytes: Substring) -> String { dashHex(Data(String(decoding: undash(hexBytes), as: UTF8.self).utf8)) }
    static func utf8Hex(_ s: String?) -> String { dashHex(Data((s ?? "").utf8)) }

    // MARK: transport padding

    @Test func transportPadding() throws {
        var r = SplitMix(s: 41)
        var messages: [Data] = [], inputs: [Data] = []
        for _ in 0..<Self.count {
            let m = r.coin(4) ? Self.bytes(&r, 3) : Self.bytes(&r, 400)
            messages.append(m)
            let p = MessageSender.pad(m)
            switch r.below(8) {
            case 0, 1: inputs.append(p)
            case 2: inputs.append(m + Data([0x80]) + Data(count: r.below(5)))
            case 3: inputs.append(Data(count: r.below(6)))   // no terminator: refused here, handed back upstream
            case 4: inputs.append(p.prefix(r.below(p.count + 1)))
            case 5: inputs.append(p + Data([UInt8(1 + r.below(255))]) + Data(count: r.below(3)))
            default: inputs.append(Self.bytes(&r, 8))
            }
        }
        var d = Disagreements()
        for (m, want) in zip(messages, try CryptoOracle.call("pad", messages.map(dashHex))) {
            d.check(dashHex(MessageSender.pad(m)), want, "pad \(dashHex(m))")
        }
        for (x, want) in zip(inputs, try CryptoOracle.call("unpad", inputs.map(dashHex))) {
            d.check((try? MessageReceiver.unpad(x)).map(dashHex) ?? "invalid", want, "unpad \(dashHex(x))")
        }
        d.done("transportPadding")
    }

    // MARK: derivations

    @Test func derivations() throws {
        var r = SplitMix(s: 43)
        var cases: [(use: String, secret: Data, production: Data)] = []
        for _ in 0..<Self.count {
            let secret = randomBytes(&r, 32)
            switch r.below(8) {
            case 0: cases.append(("storageKey", secret, StorageService.deriveStorageKey(masterKey: secret)))
            case 1:
                let v: UInt64 = r.coin() ? UInt64(r.below(25)) : r.coin() ? UInt64(r.below(1000)) * 10 : r.next()
                cases.append(("manifestKey \(v)", secret, StorageService.manifestKey(storageKey: secret, version: v)))
            case 2:
                let raw = Self.bytes(&r, 40)
                // No record IKM, or an empty one (the same).
                cases.append(("itemKey \(dashHex(raw))", secret, try StorageService.itemKey(storageKey: secret, recordIkm: r.coin() ? nil : Data(), raw: raw)))
            case 3:
                let raw = Self.bytes(&r, 40), ikm = randomBytes(&r, 32)
                cases.append(("itemKeyIkm \(dashHex(raw))", ikm, try StorageService.itemKey(storageKey: secret, recordIkm: ikm, raw: raw)))
            case 4:
                let id = randomBytes(&r, 16)
                cases.append(("groupV1MasterKey", id, try StorageService.masterKey(groupV1Id: id)))
            case 5: cases.append(("stickerPackKeys", secret, try Stickers.derivePackKey(secret)))
            case 6:
                let root = randomBytes(&r, 16 + r.below(17))
                cases.append(("callLinkRoomId", root.prefix(16), Data(hexString: try StorageRecords.roomId(rootKey: root))))
            default:
                let accessKey = randomBytes(&r, 16)
                cases.append(("accessKeyVerifier", accessKey, ProfileService.accessKeyVerifier(accessKey)))
            }
        }
        var d = Disagreements()
        for (c, answer) in zip(cases, try CryptoOracle.call("derive", cases.map(\.use))) {
            d.check(c.production.hex, applyDerivation(answer, c.secret).hex, "derive \(c.use) (model: \(answer))")
        }
        d.done("derivations")
    }

    // MARK: profile padding

    @Test func profilePadding() throws {
        var r = SplitMix(s: 47)
        let key = randomBytes(&r, 32)
        var lines: [String] = [], got: [String] = []
        for _ in 0..<Self.count {
            let result: Result<Data, Error>
            switch r.below(4) {
            case 0, 1:
                let given = Self.text(&r, r.coin(4) ? 150 : 40)
                let family: String? = r.coin(3) ? nil : r.coin(5) ? "" : Self.text(&r, r.coin(4) ? 150 : 30)
                lines.append("name \(Self.utf8Hex(given)) \(Self.utf8Hex(family))")
                result = Result { try ProfileService.encryptName(given: given, family: family, profileKey: key) }
            case 2:
                let about = Data(Self.text(&r, r.coin(3) ? 200 : 60).utf8)
                lines.append("about \(dashHex(about))")
                result = Result { try ProfileService.encryptPadded(about, lengths: ProfileService.PaddedLengths.about, profileKey: key) }
            default:
                let emoji = Data(Self.text(&r, 12).utf8)
                lines.append("aboutEmoji \(dashHex(emoji))")
                result = Result { try ProfileService.encryptPadded(emoji, lengths: ProfileService.PaddedLengths.aboutEmoji, profileKey: key) }
            }
            switch result {
            case .success(let sealed): got.append(dashHex(try AES.GCM.open(try AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: key))))
            case .failure(let e): got.append(Self.name(e))
            }
        }
        var d = Disagreements()
        for (i, want) in try CryptoOracle.call("profilePad", lines).enumerated() { d.check(got[i], want, lines[i]) }
        d.done("profilePadding")
    }

    // MARK: storage manifests

    @Test func manifests() throws {
        var r = SplitMix(s: 53)
        let storageKeys = (0..<3).map { _ in randomBytes(&r, 32) }
        struct Case { var ours: Int; var version: UInt64; var current: UInt64?; var use: String; var keyName: String; var secret: Int
                      var parses: Bool; var inner: UInt64; var change: Bool }
        var cases: [Case] = []
        for _ in 0..<Self.count {
            let s = r.below(3)
            let v: UInt64 = r.coin(8) ? r.next() >> 1 : UInt64(r.below(6))
            let current: UInt64? = r.coin(4) ? nil : [0, v &- 1, v, v &+ 1, UInt64(r.below(6))][r.below(5)]
            // The key it is sealed under: the right one, another version's, another account's, a record's.
            var sv = v, ss = s, use = "", keyName = ""
            switch r.below(7) {
            case 4: sv = r.coin() ? v &+ 1 : v &- 1
            case 5: ss = (s + 1) % 3
            case 6:
                let raw = Self.bytes(&r, 4, min: 1)
                use = "itemKey \(raw.hex)"; keyName = "item:\(s):\(raw.hex)"
            default: break
            }
            if use.isEmpty { use = "manifestKey \(sv)"; keyName = "manifest:\(ss):\(sv)" }
            // What the writer put inside: its own version, mostly.
            cases.append(Case(ours: s, version: v, current: current, use: use, keyName: keyName, secret: ss, parses: !r.coin(8),
                              inner: r.coin(6) ? UInt64(r.below(6)) : sv, change: r.coin(5)))
        }
        let table = try CryptoOracle.table(cases.map(\.use))
        var lines: [String] = [], got: [String] = []
        for c in cases {
            var record = Signalservice_ManifestRecord()
            record.version = c.inner
            record.sourceDevice = 2
            let plaintext = c.parses ? try record.serializedData() : Data([0x08, 0x80])
            var value = try gcmSeal(applyDerivation(table[c.use]!, storageKeys[c.secret]), plaintext)
            var origin = "sealed \(c.keyName) \(c.parses ? 1 : 0) \(c.inner)"
            if c.change { value = Self.alter(&r, value); origin = "other" }
            var m = Signalservice_StorageManifest()
            m.version = c.version
            m.value = value
            do {
                got.append("ok:\(try StorageService.verifyManifest(m, storageKey: storageKeys[c.ours], current: c.current).version)")
            } catch { got.append(Self.name(error)) }
            lines.append("\(c.ours) \(c.version) \(c.current.map(String.init) ?? "-") \(origin)")
        }
        var d = Disagreements()
        for (i, want) in try CryptoOracle.call("manifest", lines).enumerated() { d.check(got[i], want, lines[i]) }
        d.done("manifests")
    }

    // MARK: storage records

    @Test func records() throws {
        var r = SplitMix(s: 59)
        let storageKeys = (0..<3).map { _ in randomBytes(&r, 32) }
        let ikms = (0..<3).map { _ in randomBytes(&r, 32) }
        struct Item { var raw: Data; var use: String; var keyName: String; var secret: Data; var parses: Bool; var change: Bool }
        var cases: [(s: Int, ikm: Int?, emptyIkm: Bool, requested: [Data], items: [Item])] = []
        for _ in 0..<Self.count {
            let s = r.below(3)
            let ikm: Int? = r.coin(3) ? nil : 1 + r.below(2)
            var requested: [Data] = []
            for _ in 0..<(1 + r.below(4)) {
                let id = r.coin(3) && !requested.isEmpty ? requested[0].prefix(1) + Self.bytes(&r, 3) : Self.bytes(&r, 18, min: 1)
                if !requested.contains(id) { requested.append(id) }
            }
            func key(_ raw: Data, legacy: Bool, storage: Int) -> (String, String, Data) {
                if let ikm, !legacy { return ("itemKeyIkm \(raw.hex)", "ikm:\(ikm):\(raw.hex)", ikms[ikm]) }
                return ("itemKey \(raw.hex)", "item:\(storage):\(raw.hex)", storageKeys[storage])
            }
            var items: [Item] = []
            for _ in 0..<r.below(5) {
                let raw = r.coin(8) ? Self.bytes(&r, 6, min: 1) : requested[r.below(requested.count)]
                let k: (String, String, Data)
                switch r.below(8) {
                case 4: k = key(requested[r.below(requested.count)], legacy: false, storage: s)   // another record's value
                case 5:   // the other derivation
                    k = ikm == nil ? ("itemKeyIkm \(raw.hex)", "ikm:1:\(raw.hex)", ikms[1]) : key(raw, legacy: true, storage: s)
                case 6:   // another account's storage key, or another record IKM
                    k = ikm.map { ("itemKeyIkm \(raw.hex)", "ikm:\(3 - $0):\(raw.hex)", ikms[3 - $0]) } ?? key(raw, legacy: true, storage: (s + 1) % 3)
                case 7: k = ("manifestKey 1", "manifest:\(s):1", storageKeys[s])
                default: k = key(raw, legacy: false, storage: s)
                }
                items.append(Item(raw: raw, use: k.0, keyName: k.1, secret: k.2, parses: !r.coin(8), change: r.coin(6)))
            }
            cases.append((s, ikm, ikm == nil && r.coin(), requested, items))
        }
        let table = try CryptoOracle.table(cases.flatMap { $0.items.map(\.use) })
        var lines: [String] = [], got: [String] = []
        for c in cases {
            var items: [Signalservice_StorageItem] = [], described: [String] = []
            for it in c.items {
                var record = Signalservice_StorageRecord()
                var contact = Signalservice_ContactRecord()
                contact.aci = "aci-\(it.raw.hex)"
                record.contact = contact
                var item = Signalservice_StorageItem()
                item.key = it.raw
                item.value = try gcmSeal(applyDerivation(table[it.use]!, it.secret), it.parses ? try record.serializedData() : Data([0x08, 0x80]))
                var origin = "sealed \(it.keyName) \(it.parses ? 1 : 0)"
                if it.change { item.value = Self.alter(&r, item.value); origin = "other" }
                items.append(item)
                described.append("\(it.raw.hex)=\(origin)")
            }
            let ikm: Data? = c.ikm.map { ikms[$0] } ?? (c.emptyIkm ? Data() : nil)
            do {
                let missing = try StorageService.requestedOnly(items, requested: c.requested)
                for item in items { _ = try StorageService.decryptItem(item, storageKey: storageKeys[c.s], recordIkm: ikm) }
                got.append("ok:\(items.count):\(missing.count)")
            } catch { got.append(Self.name(error)) }
            lines.append("\(c.s) \(c.ikm.map(String.init) ?? "-") | \(c.requested.map(\.hex).joined(separator: ",")) | \(described.isEmpty ? "-" : described.joined(separator: ";"))")
        }
        var d = Disagreements()
        for (i, want) in try CryptoOracle.call("items", lines).enumerated() { d.check(got[i], want, lines[i]) }
        d.done("records")
    }

    // MARK: profile fields

    @Test func profileFields() throws {
        var r = SplitMix(s: 61)
        let keys = (0..<3).map { _ in randomBytes(&r, 32) }
        let fields = ["name", "about", "aboutEmoji"]
        var lines: [String] = [], got: [String] = []
        for _ in 0..<Self.count {
            let k = r.below(3), field = r.below(3)
            let sealer = r.coin(6) ? (k + 1) % 3 : k
            let written = r.coin(5) ? r.below(3) : field
            var plain = r.coin(12) ? Data() : Self.bytes(&r, 60) + Data(count: r.below(200))
            if r.coin(3) { plain = Data(Self.text(&r, 20).utf8) + Data(count: r.below(40)) }
            var value = try gcmSeal(keys[sealer], plain)
            var origin = "sealed profile:\(sealer) \(fields[written]) \(dashHex(plain))"
            if r.coin(6) { value = Self.alter(&r, value); origin = "other" }
            lines.append("\(k) \(fields[field]) \(value.count) \(origin)")
            do {
                if field == 0 {
                    let (g, f) = try ProfileService.decryptName(value, profileKey: keys[k])
                    got.append("name:\(Self.utf8Hex(g)):\(Self.utf8Hex(f))")
                } else {
                    got.append("text:\(Self.utf8Hex(try ProfileService.decryptString(value, profileKey: keys[k])))")
                }
            } catch { got.append(Self.name(error)) }
        }
        var d = Disagreements()
        for (i, want) in try CryptoOracle.call("profile", lines).enumerated() {
            let w = want.split(separator: ":", omittingEmptySubsequences: false)
            let model = w[0] == "name" ? "name:\(Self.asText(w[1])):\(Self.asText(w[2]))" : w[0] == "text" ? "text:\(Self.asText(w[1]))" : want
            d.check(got[i], model, lines[i])
        }
        d.done("profileFields")
    }

    // MARK: stickers

    @Test func stickers() throws {
        var r = SplitMix(s: 67)
        let packs = (0..<3).map { _ in randomBytes(&r, 32) }
        let derivation = try CryptoOracle.table(["stickerPackKeys"])["stickerPackKeys"]!
        var lines: [String] = [], got: [String] = []
        for _ in 0..<Self.count {
            let k = r.below(3)
            let sealer = r.coin(6) ? (k + 1) % 3 : k
            let keys = applyDerivation(derivation, packs[sealer])
            let iv = randomBytes(&r, 16)
            let ciphertext: Data, content: String
            switch r.below(6) {
            case 0:   // a key holder's: whole blocks without valid padding (or none at all)
                let blocks = randomBytes(&r, 16 * r.below(4))
                ciphertext = cbcEncrypt(key: keys.prefix(32), iv: iv, blocks, pkcs7: false)
                content = cbcDecrypt(key: keys.prefix(32), iv: iv, ciphertext).map { "\($0.count)" } ?? "bad"
            default:
                let plain = randomBytes(&r, r.below(100))
                ciphertext = cbcEncrypt(key: keys.prefix(32), iv: iv, plain)
                content = "\(plain.count)"
            }
            var blob = iv + ciphertext
            blob += hmac(keys.suffix(32), blob)
            var origin = "sealed sticker:\(sealer) \(content)"
            if r.coin(4) { blob = Self.alter(&r, blob); origin = "other" }
            lines.append("\(k) \(blob.count) \(origin)")
            do { got.append("ok:\(try Stickers.decrypt(blob, packKey: packs[k]).count)") } catch { got.append(Self.name(error)) }
        }
        var d = Disagreements()
        for (i, want) in try CryptoOracle.call("sticker", lines).enumerated() { d.check(got[i], want, lines[i]) }
        d.done("stickers")
    }

    // MARK: provisioning

    /// An envelope sealed here with the model's keys: version 1, IV, AES-256-CBC, HMAC.
    static func sealProvision(_ plaintext: Data, to recipient: PublicKey, derivation: String, pkcs7: Bool = true, r: inout SplitMix) throws -> Data {
        let ephemeral = PrivateKey.generate()
        let keys = applyDerivation(derivation, try x25519(ephemeral, recipient.serialize()))
        let iv = randomBytes(&r, 16)
        let signed = Data([1]) + iv + cbcEncrypt(key: keys.prefix(32), iv: iv, plaintext, pkcs7: pkcs7)
        var env = Signalservice_ProvisionEnvelope()
        env.publicKey = ephemeral.publicKey.serialize()
        env.body = signed + hmac(keys.suffix(32), signed)
        return try env.serializedData()
    }

    @Test func provisioning() throws {
        var r = SplitMix(s: 71)
        let ours = [PrivateKey.generate(), PrivateKey.generate()]
        let derivation = try CryptoOracle.table(["provisioningKeys"])["provisioningKeys"]!
        var message = Signalservice_ProvisionMessage()
        message.aci = "aci"
        message.number = "+31600000000"
        message.provisioningCode = "123"
        let messageBytes = try message.serializedData()
        var lines: [String] = [], got: [String] = []
        var d = Disagreements()
        for i in 0..<(Self.count / 2) {
            let o = r.below(2)
            let e = 2 * i   // the ephemeral key's id; 2i + 1 for a swapped-in one
            var bytes: Data, origin: String, eph = e
            switch r.below(8) {
            case 0, 1:
                // Production's own envelope, which the model's keys must open too.
                bytes = try ProvisioningCipher.encrypt(message, to: ours[o].publicKey)
                origin = "sealed prov:\(o):\(e) ok"
                let env = try Signalservice_ProvisionEnvelope(serializedBytes: bytes)
                let keys = applyDerivation(derivation, try x25519(ours[o], env.publicKey))
                let body = env.body
                let opened = hmac(keys.suffix(32), body.prefix(body.count - 32)) == body.suffix(32)
                    ? cbcDecrypt(key: keys.prefix(32), iv: body.dropFirst().prefix(16), body.dropFirst(17).dropLast(32)) : nil
                d.check(opened.map(dashHex) ?? "unopened", dashHex(messageBytes), "the model's keys open production's envelope")
            case 2:
                bytes = try ProvisioningCipher.encrypt(message, to: ours[1 - o].publicKey)   // for someone else
                origin = "sealed prov:\(1 - o):\(e) ok"
            case 3:
                // Sealed here with the model's keys: the message, something that does not parse,
                // or raw blocks (valid PKCS#7 only by chance).
                let kind = r.below(3)
                let plain = kind == 0 ? messageBytes : kind == 1 ? Data([0x08, 0x80]) : randomBytes(&r, 16 * (1 + r.below(3)))
                bytes = try Self.sealProvision(plain, to: ours[o].publicKey, derivation: derivation, pkcs7: kind != 2, r: &r)
                var content = kind == 0 ? "ok" : "noparse"
                if kind == 2 {
                    let env = try Signalservice_ProvisionEnvelope(serializedBytes: bytes)
                    let keys = applyDerivation(derivation, try x25519(ours[o], env.publicKey))
                    let unpadded = cbcDecrypt(key: keys.prefix(32), iv: env.body.dropFirst().prefix(16), env.body.dropFirst(17).dropLast(32))
                    content = unpadded.map { (try? Signalservice_ProvisionMessage(serializedBytes: $0)) != nil ? "ok" : "noparse" } ?? "bad"
                }
                origin = "sealed prov:\(o):\(e) \(content)"
            case 4:
                var env = try Signalservice_ProvisionEnvelope(serializedBytes: try ProvisioningCipher.encrypt(message, to: ours[o].publicKey))
                env.publicKey = PrivateKey.generate().publicKey.serialize()
                eph = e + 1
                bytes = try env.serializedData()
                origin = "sealed prov:\(o):\(e) ok"
            case 5:
                var env = try Signalservice_ProvisionEnvelope(serializedBytes: try ProvisioningCipher.encrypt(message, to: ours[o].publicKey))
                env.body = r.coin(3) ? Data([UInt8(2 + r.below(3))]) + env.body.dropFirst() : Self.alter(&r, env.body)
                bytes = try env.serializedData()
                origin = "other"
            default:
                var env = try Signalservice_ProvisionEnvelope(serializedBytes: try ProvisioningCipher.encrypt(message, to: ours[o].publicKey))
                origin = "other"
                switch r.below(4) {
                case 0: env.clearPublicKey()
                case 1: env.clearBody()
                default:
                    let original = env.publicKey
                    env.publicKey = Self.alter(&r, env.publicKey)
                    // Another encoding of the same key (trailing bytes, the top bit) is the same key.
                    if sameSecret(ours[o], original, env.publicKey) { origin = "sealed prov:\(o):\(e) ok" }
                }
                bytes = try env.serializedData()
                if r.coin(4) { bytes = randomBytes(&r, r.below(80)); origin = "other" }
            }
            let env = try? Signalservice_ProvisionEnvelope(serializedBytes: bytes)
            let body = env?.body ?? Data()
            let keyOK = env.map { (try? PublicKey($0.publicKey)) != nil } ?? false
            let fields = env.map { $0.hasPublicKey && $0.hasBody } ?? false
            lines.append("\(env != nil ? 1 : 0) \(fields ? 1 : 0) \(body.count) \(body.first ?? 0) \(keyOK ? 1 : 0) \(o) \(eph) \(origin)")
            do {
                _ = try ProvisioningCipher(privateKey: ours[o]).decrypt(envelope: bytes)
                got.append("ok")
            } catch { got.append(Self.name(error)) }
        }
        for (i, want) in try CryptoOracle.call("provision", lines).enumerated() { d.check(got[i], want, lines[i]) }
        d.done("provisioning")
    }

    // MARK: device names

    /// A device name sealed here with the model's keys, by anyone who has the identity public key.
    static func sealDeviceName(_ plaintext: Data, to identity: PublicKey, auth: String, cipher: String) throws -> Data {
        let ephemeral = PrivateKey.generate()
        let master = try x25519(ephemeral, identity.serialize())
        let siv = hmac(applyDerivation(auth, master), plaintext).prefix(16)
        let cipherKey = hmac(applyDerivation(cipher, master), siv)
        var proto = Signalservice_DeviceName()
        proto.ephemeralPublic = ephemeral.publicKey.serialize()
        proto.syntheticIv = siv
        proto.ciphertext = ctrCrypt(key: cipherKey, iv: Data(count: 16), plaintext)
        return try proto.serializedData()
    }

    @Test func deviceNames() throws {
        var r = SplitMix(s: 73)
        let identities = [PrivateKey.generate(), PrivateKey.generate()]
        let table = try CryptoOracle.table(["deviceNameAuth", "deviceNameCipher", "deviceNameIv 41", "deviceNameCipherKey 42"])
        let auth = table["deviceNameAuth"]!, cipher = table["deviceNameCipher"]!
        // The synthetic IV and the cipher key are HMACs of the name and of the IV themselves.
        #expect(table["deviceNameIv 41"] == "deviceNameAuth hmac 41" && table["deviceNameCipherKey 42"] == "deviceNameCipher hmac 42")
        var lines: [String] = [], got: [String] = []
        var d = Disagreements()
        for i in 0..<(Self.count / 2) {
            let o = r.below(2)
            let e = 2 * i
            let name = Self.text(&r, 20)
            let plain = Data(name.utf8)
            var bytes: Data, origin: String, eph = e
            switch r.below(8) {
            case 0, 1:
                bytes = try DeviceNameCipher.encrypt(name, identityPublicKey: identities[o].publicKey)
                origin = "sealed device:\(o):\(e) us \(dashHex(plain))"
                // The model's keys open production's.
                let p = try Signalservice_DeviceName(serializedBytes: bytes)
                let master = try x25519(identities[o], p.ephemeralPublic)
                let opened = ctrCrypt(key: hmac(applyDerivation(cipher, master), p.syntheticIv), iv: Data(count: 16), p.ciphertext)
                let ok = hmac(applyDerivation(auth, master), opened).prefix(16) == p.syntheticIv
                d.check(ok ? dashHex(opened) : "unopened", dashHex(plain), "the model's keys open production's device name")
            case 2, 3:
                // Anyone (the server too) can encrypt a name to our public identity key.
                let junk = r.coin(4) ? randomBytes(&r, r.below(12)) : plain
                bytes = try Self.sealDeviceName(junk, to: identities[o].publicKey, auth: auth, cipher: cipher)
                origin = "sealed device:\(o):\(e) other \(dashHex(junk))"
            case 4:
                bytes = try DeviceNameCipher.encrypt(name, identityPublicKey: identities[1 - o].publicKey)
                origin = "sealed device:\(1 - o):\(e) us \(dashHex(plain))"
            case 5:
                var p = try Signalservice_DeviceName(serializedBytes: try DeviceNameCipher.encrypt(name, identityPublicKey: identities[o].publicKey))
                p.ephemeralPublic = PrivateKey.generate().publicKey.serialize()
                eph = e + 1
                bytes = try p.serializedData()
                origin = "sealed device:\(o):\(e) us \(dashHex(plain))"
            case 6:
                var p = try Signalservice_DeviceName(serializedBytes: try DeviceNameCipher.encrypt(name, identityPublicKey: identities[o].publicKey))
                origin = "other"
                switch r.below(3) {
                case 0: p.syntheticIv = Self.alter(&r, p.syntheticIv)
                case 1: p.ciphertext = Self.alter(&r, p.ciphertext)
                default:
                    let original = p.ephemeralPublic
                    p.ephemeralPublic = Self.alter(&r, p.ephemeralPublic)
                    // Another encoding of the same key (trailing bytes, the top bit) is the same key.
                    if sameSecret(identities[o], original, p.ephemeralPublic) { origin = "sealed device:\(o):\(e) us \(dashHex(plain))" }
                }
                bytes = try p.serializedData()
            default:
                var p = try Signalservice_DeviceName(serializedBytes: try DeviceNameCipher.encrypt(name, identityPublicKey: identities[o].publicKey))
                switch r.below(3) {
                case 0: p.clearEphemeralPublic()
                case 1: p.clearSyntheticIv()
                default: p.clearCiphertext()
                }
                bytes = r.coin(4) ? randomBytes(&r, r.below(60)) : try p.serializedData()
                origin = "other"
            }
            let p = try? Signalservice_DeviceName(serializedBytes: bytes)
            let fields = p.map { $0.hasEphemeralPublic && $0.hasSyntheticIv && $0.hasCiphertext && $0.syntheticIv.count == 16 } ?? false
            let keyOK = p.map { (try? PublicKey($0.ephemeralPublic)) != nil } ?? false
            lines.append("\(p != nil ? 1 : 0) \(fields ? 1 : 0) \(keyOK ? 1 : 0) \(o) \(eph) \(origin)")
            do { got.append("ok:\(Self.utf8Hex(try DeviceNameCipher.decrypt(bytes, identityPrivateKey: identities[o])))") } catch { got.append(Self.name(error)) }
        }
        for (i, want) in try CryptoOracle.call("device", lines).enumerated() {
            d.check(got[i], want.hasPrefix("ok:") ? "ok:\(Self.asText(want.dropFirst(3)))" : want, lines[i])
        }
        d.done("deviceNames")
    }
}
