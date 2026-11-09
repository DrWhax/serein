# Crypto port review

How the Swift port of Signal-Desktop's cryptography is checked, and what has been
reviewed by hand. The reference is always the `Signal-Desktop` checkout: where upstream
does something, SignalCore does the same, and the few places where it is deliberately
stricter are listed at the end.

## How each kind of code is checked

| Kind | Where | Checked by |
|---|---|---|
| Primitive wrappers (AES-CBC from our libsignal patch, AES-CTR, AES-GCM, HMAC, HKDF) | `Support/Crypto.swift` | `WycheproofTests` (edge cases per primitive), `UpstreamVectorTests` (upstream's output) |
| Hand-ported constructions (provisioning, device names, attachments v1/v2, stickers, storage service, profiles, transport padding, safety numbers) | see the table below | `UpstreamVectorTests`: byte-identical output and the same accept/reject verdict as upstream on malformed input; `check.sh`: upstream decrypts what Swift encrypts |
| State and policy around libsignal (identity trust, receive path, pre-keys, sender keys, sealed-sender access, group changes) | `Protocol/`, `Messaging/`, `Groups/` | Rule-by-rule tests written from the upstream function, plus flows against the mock server |
| Pass-through calls into libsignal (zkgroup, usernames, contact discovery, fingerprints) | call sites | Read against the upstream call site; tests where the mock server cannot tell right from wrong |

`Tools/crypto-vectors/check.sh` runs the whole cross-check against the checkout: the
committed vectors must be exactly what upstream's TypeScript produces now (the generator is
deterministic), and upstream must read everything `exportsForUpstream` encrypts. Run it
after moving the `Signal-Desktop` checkout; if the vectors are out of date, regenerate with
`generate.sh` and run the SignalCore tests. A failure there is a construction upstream
changed.

## Misuse review, per construction

Known-answer tests cannot show these properties. Each row was read in the source; the
last column is what keeps it true.

| Construction | Randomness | Key / nonce reuse | Authenticated before use | Guard |
|---|---|---|---|---|
| Provisioning envelope (`ProvisioningCipher.decrypt`) | We only decrypt; our key pair is `PrivateKey.generate()` per link | One ECDH per envelope | HMAC compared in constant time, then CBC decrypt | `cbcDecryptOnlyBehindAReviewedMAC` |
| Device name (`DeviceNameCipher`) | Fresh ephemeral key per name | CTR key is derived from the synthetic IV, so the zero counter is used once per (secret, plaintext) | Synthetic IV recomputed and compared in constant time before the name is returned | `everyEncryptionIsRandomised`, vectors with tampered inputs |
| Attachment v2 (`AttachmentCipher`) | 64 random key bytes and a random IV per attachment; the IV cannot be chosen by callers | New keys per attachment and per local re-encryption | HMAC, then digest or plaintext hash, then incremental MAC; all constant time; CBC decrypt only after the HMAC | `noCallerChoosesAnIVAndPrimitivesStayPut`, `attachmentV2DecryptVerdicts` |
| Attachment v1 / stickers (`decryptV1`, `StickerPackUpload`) | Random pack key, random IV per sticker | Pack key encrypts a bounded set, each with its own IV | HMAC in constant time before CBC decrypt | as above |
| Storage service (`StorageService`) | Random 96-bit GCM nonce per encryption; callers cannot supply one | Item key is derived per record id and a changed record gets a new id; manifest key is per version | GCM tag (every failure maps to one error) | `everyEncryptionIsRandomised` |
| Profile fields (`ProfileService`) | Random GCM nonce | Profile key is long-lived but encrypts a handful of short fields, as upstream | GCM tag; minimum length as upstream | vectors with tampered inputs |
| Transport padding | none | n/a | Applied inside the Signal ciphertext; never trusted before decryption | vectors |
| Database key (`KeychainDatabaseKeyStore`) | 32 random bytes | n/a | Keychain item, this device only, available after first unlock | read |

Across all of them:

- **One source of randomness.** `SignalCrypto.randomBytes` and Swift's `random(in:)` both
  use `SystemRandomNumberGenerator` (the kernel CSPRNG). No other generator is referenced.
- **MAC and digest comparisons** all go through `SignalCrypto.constantTimeEqual`; no `==`
  on a MAC anywhere (`macsAreComparedInConstantTime`).
- **CBC is never decrypted before its MAC is verified**, so the padding check is not
  reachable by an attacker. The three call sites are pinned by a test; a fourth fails it.
- **No secret reaches a log.** The trace and diagnostic calls were searched for keys,
  passwords and serialized records; they log counts and booleans only.
- **Not done:** secrets are not wiped from memory after use (`Data` is not zeroised).
  Upstream's JavaScript does not do this either.

## Pass-through calls (tier C)

Read against the upstream call sites:

| Area | Result |
|---|---|
| Group changes delivered inside a member's message | **Was missing:** the group server's notary signature over the actions was not verified, so any member could rewrite our view of the group. Now `GroupsService.verifiedActions` (signature, epoch, group id), as upstream's `getGroupUpdates`. |
| Group send endorsements | Receive, expiry window and token construction match upstream; `GroupSendTokenTests` verifies the tokens against a zkgroup issuer run in the test, since the mock server does not check them. |
| Group auth credentials | Same request range, same `receiveAuthCredentialWithPniAsServiceId` call and presentation as upstream (which also only logs a PNI mismatch). |
| Profile key credentials, profile key versions | Same libsignal calls and arguments. |
| Account entropy pool → storage key | `AccountEntropyPool.deriveSvrKey`, then the vector-tested HMAC; master key used only when there is no pool, as upstream. |
| Safety numbers | Vector-tested against upstream's own code. |
| Usernames and links, contact discovery | libsignal's typed chat APIs; nothing derived by hand. |
| Group calls | Empty HKDF extra info and member list as upstream; keys are ringrtc's. |
| Key transparency | Only mock-tested; the lookups now use the profile-key-derived access key only. |

Not reviewed in this pass: group invite-link flows, call-link administration, and the
calling signalling checks (who may ring a group). They pass their flow tests against the
mock server but were not read side by side with upstream.

## Where Swift is deliberately stricter than upstream

Each is an explicit exception in the tests:

- Transport padding with no `0x80` terminator (empty or all zeros) is rejected; upstream
  returns it unchanged.
- An identity key for one of our own service ids is compared with our real key, not with
  whatever was first recorded.
- AES-CTR refuses a counter that would wrap 32 bits (never reached by Signal's uses).
- A storage record that changed while its upload was in flight keeps its needs-sync mark;
  upstream appears to clear it.
