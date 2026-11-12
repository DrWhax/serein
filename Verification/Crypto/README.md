# Crypto formats: padding, key separation, profile padding, encrypted formats

The twelfth verification slice: the cryptographic constructions SignalCore puts together itself
around the primitives. It contains a Lean 4 model of four parts, machine-checked proofs, Swift
tests comparing production with the model, and mutants:

1. **Transport padding** around every message (`MessageSender.pad`, `MessageReceiver.unpad`).
2. **Key separation**: every key, MAC and identifier SignalCore derives, with the exact HMAC or
   HKDF input of each (`Labels.lean` has the table).
3. **Profile padding**: profile fields padded to fixed lengths (`ProfileService.encryptName`,
   `encryptPadded`, `decryptName`, `decryptString`).
4. **Encrypted formats**: storage manifests and records, profile fields, sticker images and
   manifests, provisioning envelopes, device names: which checks pass in which order, and what an
   accepted value can have been.

**The app is not formally verified.** The proofs are about the model. Parts 1–3 are proved with
no assumptions. Part 4 is proved **by the cryptographic contracts**, which are assumed:
authenticated decryption (AES-256-GCM, encrypt-then-MAC with HMAC-SHA256, the device names'
synthetic IV) succeeds only on the intact output of an encryption under the same key; HMAC and
HKDF are pseudorandom functions; X25519 secrets are known only to the two key holders. The
primitives themselves (CryptoKit, libsignal) are not modelled. They are tested against Signal
Desktop's own code by `Tools/crypto-vectors/check.sh`.

```
Tools/verify-crypto.sh                 # everything
SKIP_MUTANTS=1 Tools/verify-crypto.sh
SKIP_SWIFT=1 Tools/verify-crypto.sh    # the Lean side only
```

## 1. What is proved

### Transport padding (no assumptions)

| Theorem | Statement |
|---|---|
| `unpad_pad` | **Unpadding inverts padding**, for every message. |
| `unpad_eq_some` | `unpad` accepts exactly a message, the terminator 0x80, and zeros. |
| `pad_length_bounds` | A padded message plus one byte is whole 80-byte blocks, holding the message, the terminator and at least one more byte, and less than a block more. |
| `pad_length_iff` | **The length shows only the block count**: two messages pad to the same length exactly when `(length + 1) / 80` is the same. |
| `unpad_upstream_differs`, `unpad_upstream_same` | **The one difference from upstream**: input with no terminator (empty, or only zeros) is refused, where upstream's `#unpad` hands it back as the message. On every other input the two agree. Ours is the stricter. |

### Key separation (no assumptions)

| Theorem | Statement |
|---|---|
| `dec_inj`, `b64_inj` | Different versions have different decimal forms; different byte strings have different base64 forms (the decoders are in `Proofs.lean`). |
| `separated` | **No two uses put the same input through the same primitive keyed by the same source**: not two manifest versions, not two storage record ids, not a manifest and a record, not the device names' `auth` and `cipher` keys. It holds even with HKDF salts that differ only in trailing zeros counted as one (HMAC pads short keys with zeros, so no salt and 32 zero bytes are the same salt), and with HKDF's output length ignored (its first bytes do not depend on it). |
| `key_binds` | Keys with the same material are the same key: the same secret and the same use. |

### Profile padding (no assumptions)

| Theorem | Statement |
|---|---|
| `lengths_sorted`, `bucket_least` | Each field's lengths are sorted, so the first length that fits is the smallest. |
| `padTo_length` | **The padded length is the bucket**: a ciphertext shows only which length was used. The item comes first, then zeros. |
| `padTo_none` | An item is refused exactly when no length fits. |
| `name_roundtrip`, `string_roundtrip` | A name reads back as written (given and family name), and so does an about text or emoji, if it has no NUL. |

### Encrypted formats (by the contracts)

| Theorem | Statement |
|---|---|
| `manifest_ok`, `manifest_bound` | **An accepted storage manifest was sealed under our storage key's manifest key for exactly the version the server named.** It was not another version's manifest, nor a storage record, nor under any other key. Its record parses and names that version, and that version is newer than ours (or both are 0, upstream's rule): no rollback. |
| `items_ok`, `items_bound` | **Every accepted storage record was asked for, and was sealed under the item key for exactly its own id** (from the manifest's record IKM, or the legacy storage-key derivation). The server cannot hand us another record's value under this id. |
| `profile_ok` | An accepted profile field was sealed under the contact's profile key and is its plaintext, read as the field asked for. |
| `sticker_ok`, `sticker_bound` | An accepted sticker was sealed under exactly this pack's derived keys, with valid padding. |
| `sticker_mac_first` | **No padding oracle**: whatever was not sealed under the pack's keys gets an answer that depends on its length alone; AES and its padding are never reached. |
| `provision_ok`, `provision_bound` | An accepted provisioning envelope passed every check before the tag and was sealed for our provisioning key and the envelope's own ephemeral key, so by someone who had our provisioning public key. Only the QR code carries that key; the server never sees it. |
| `provision_mac_first` | No padding oracle: an envelope not sealed for us gets the verdict of the checks before the tag, or `badMAC`. |
| `deviceName_ok`, `deviceName_bound` | An accepted device name was sealed for our identity key and the name's own ephemeral key. |

## 2. Limits, proved by counterexample

The explorer also finds each of these (its four `FAIL` verdicts in `explore-expected.txt`), so
the checks behind the other verdicts are not vacuous.

| Theorem | Limit |
|---|---|
| `unpad_upstream_differs` | `unpad-matches-upstream` fails: see above. It is the deliberate difference, also in `UpstreamVectorTests.transportPadding`. |
| `name_nul_splits` | `name-roundtrip-any-bytes` fails: a NUL inside a given name splits it, and the rest reads as a family name. Upstream reads names the same way. |
| `profile_field_unbound` | `profile-field-bound` fails: **profile fields are not bound to their kind**. All are AES-256-GCM under the same profile key with no associated data, so the server can serve a contact's about text as their name, or an older value of a field under the same key. This is upstream's format; changing it would break interop. |
| `deviceName_unauthenticated` | `device-name-from-our-devices` fails: **anyone can make a device name we accept**, the server included, because device names are encrypted to our public identity key. The synthetic IV gives integrity against changes, not authenticity. Device names are only displayed. This is upstream's format too. |

## 3. What is only tested against Swift

`CryptoConformanceTests` (SignalCore, 3,000 cases per test by default) compares production's
answers with the oracle's:

- **`transportPadding`**: `pad` on messages heavy in 0x00 and 0x80; `unpad` on padded messages,
  messages with a few zeros, only zeros, cut and extended ones, and junk.
- **`derivations`**: production's storage key, manifest keys (small and full 64-bit versions),
  legacy and record-IKM item keys (and an empty IKM, which is none), GV1 migration keys, sticker
  pack keys, call link room ids and access-key verifiers. Each is recomputed here with
  CryptoKit from the model's table.
- **`profilePadding`**: names (with NULs, multibyte characters, without a family name, too long),
  about texts and emoji. Production encrypts them, the rig decrypts them with CryptoKit, and the
  padded plaintext is compared with the model's.
- **Formats** (`manifests`, `records`, `profileFields`, `stickers`, `provisioning`,
  `deviceNames`): values are sealed in the rig with keys from the model's table:
  - under the right key;
  - one parameter away (another version, another record's id, the other item-key derivation,
    another account or pack, another recipient, a swapped ephemeral key);
  - under unrelated keys;
  - by key holders with bad contents (wrong inner version, unparseable records, invalid
    padding);
  - then changed after sealing.

  The rig computes the shape facts (lengths, fields present, whether a key parses). Production's
  verdict is compared with the model's. Production's own provisioning envelopes and device names
  are also decrypted with the model's keys, and the rig's by production, which checks the labels
  and the AES and MAC halves both ways. Every verdict occurs in every run; the counts are printed.

**Two encodings of one key are one key.** libsignal reads the first 33 bytes of a public key and
ignores the rest, and X25519 ignores the top bit. A key changed only there gives the same secret,
so production rightly accepts it; the rig treats it as the same key.

## 4. Mutants

Each must make the conformance tests fail: 24 bugs planted in production.

- **Transport padding:** a 64-byte block; no room for the extra byte; a zero terminator; any
  non-zero terminator accepted; input without a terminator handed back (upstream's behaviour);
  the terminator kept.
- **Key separation:** manifest keys from the last three digits; legacy item keys from 8 bytes of
  the id; record-IKM item keys without the id; an empty IKM used as one; another sticker salt;
  call link room ids from the whole root key; the provisioning MAC under the AES half; device
  names checked with the cipher key.
- **Profile padding:** the last length that fits; no NUL between the name's parts; nonce and tag
  alone accepted.
- **Encrypted formats:** the manifest's own version not checked; the current manifest accepted
  again; unrequested records accepted; a sticker decrypted before its MAC; a provisioning
  envelope decrypted before its MAC; the provisioning version not checked; a device name's
  synthetic IV not checked.

## 5. Production changes made for this slice

None to behaviour. `StorageService.verifyManifest` (decryption, the manifest's own version, no
rollback) and `StorageService.requestedOnly` (the unrequested-record check) were moved out of
`syncManifest` and `fetchItems` into static functions, unchanged, so the rig can call them.
Reading the code against upstream found no bugs: the checks are already in upstream's order, MACs
come before decryption, and rollback is refused.

## 6. Not covered

- The primitives, and the Signal protocol itself (X3DH/PQXDH, the ratchets, sealed sender,
  sender keys, zkgroup), are libsignal's.
- Keys libsignal derives: the access key from a profile key, the master key's other uses.
- The attachment format is the Attachments slice. Its padding bucket, `logPadSize`, uses floating
  point to match upstream byte for byte, which Lean cannot reason about. It was instead checked
  exhaustively for every size from 0 to 2³¹−1 with Apple's math library: the bucket is never
  smaller than the size, never decreases, and never adds more than 5%.
- That `syncManifest` calls `verifyManifest`, and `fetchItems` calls `requestedOnly`, is read in
  the code, not tested here. The storage sync tests (`StorageReadTests`) run the whole path
  against the mock server.
