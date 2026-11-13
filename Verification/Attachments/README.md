# Attachment authentication and processing

The ninth verification slice: what an attachment's bytes must pass before anything decodes,
displays or exports them. It contains a Lean 4 model of decryption (`AttachmentCipher.decrypt`)
and of the download pipeline (`AttachmentDownloadManager`, `AttachmentStore`, the response bound
of `HTTPClient`), machine-checked proofs, Swift tests comparing production with the model, and
mutants.

**The app is not formally verified.** The proofs are about the model. **The cryptographic
primitives are assumed to meet their contracts**: HMAC-SHA256 is unforgeable without the key,
SHA-256 is collision resistant, and AES-256-CBC and the incremental MAC do what libsignal says.

```
Tools/verify-attachments.sh                 # everything
SKIP_MUTANTS=1 Tools/verify-attachments.sh
SKIP_SWIFT=1 Tools/verify-attachments.sh    # the Lean side only
```

## 1. The pipeline

1. A pointer whose size exceeds the incoming limit is too big: nothing is fetched.
2. The response is read **no further than** the ciphertext size for the pointer's size plus
   64 KiB. A larger declared length is refused before the body is read, and the transfer stops at
   the limit whatever is declared. An oversized response leaves the attachment pending, to be
   retried.
3. Decryption, in this order:
   - the keys' length;
   - the blob's shape (IV, at least one block, the tag, whole blocks);
   - **the HMAC tag**;
   - the incremental MAC, if the pointer has one (an impossible chunk size is an error);
   - AES-256-CBC with its PKCS#7 padding;
   - the trim to the pointer's size;
   - **the integrity source**: a non-empty digest of the blob, else the plaintext's hash. A
     pointer with neither is refused.
4. The plaintext is re-encrypted under a fresh local key and written. **Only then** is the path
   published. Any failure publishes nothing: the attachment is marked as failed, or too big.
5. Consumers (decoding, export, the thumbnail) read a published path through `decryptLocal`.
   Its MAC fails on a file changed on disk.

## 2. What is proved

| Theorem | Statement |
|---|---|
| `decrypt_ok` | A plaintext comes out only if the keys and shape are right, the tag verifies, the incremental MAC (if any) is valid, the padding is valid, and the integrity source matches. It is no longer than the pointer's size, nor than what decryption yielded. |
| `describe_ok` | **By the contracts, a response passes only if it is the named upload's own blob**, and the pointer had a digest or a plaintext hash. |
| `delivered_holds` | **Unauthenticated bytes never reach decoding or export.** In every reachable state, everything a consumer was handed is the plaintext of the upload its pointer names: not another upload's blob, not forged bytes, not a file changed on disk. It is never longer than the pointer's size. |
| `published_holds` | **Nothing partially validated is published.** An attachment has a path exactly when it is published, and its file holds the named upload's verified plaintext. |
| `Publication.publish_current` | A delayed validated result publishes only for its current job generation and unchanged full pointer snapshot, while live, pending and uncancelled. |
| `fetched_holds` | **Malformed lengths cannot bypass the limits.** A download holds at most the bound for its pointer's size (plus one byte), and only for an attachment within the incoming limit. |

The explorer finds `delivered-authentic` and `published-validated` false when the pipeline
skips decryption's verdict.

## 3. Production changes made for this slice

- **A1: the response bound is enforced during the transfer** (`HTTPClient.bounded`). Before,
  `maxResponseBytes` was checked only after `URLSession` had buffered the whole body in memory,
  so a CDN (or server) sending gigabytes for a small attachment would be read in full first. Now a
  larger `Content-Length` is refused before the body is read, and reading stops at the limit.
  Every `HTTPClient` request benefits: attachments, stickers, contact sync, avatars, storage.
  Streamed responses ask the task's delegate for the server-trust challenge, so it now applies
  the same pinning there (`pinningRefusesOtherRoots` tests it).
- **A2: an incremental-MAC chunk size beyond 32 bits is an error, not a trap.** `UInt32(chunkSize)`
  would have crashed the process on a value from a malformed record.

- **A3: publication checks the state in the writer, after awaits.** Jobs carry durable leases;
  requeueing replaces the lease. Publication compares the full original attachment snapshot,
  pending state, message erasure/expiry and lease. Old jobs cannot delete or retry replacements.
  The held-completion regression also verifies GRDB's cancellation of an awaited writer: an
  extra application cancellation flag proved redundant under mutation testing and was removed.
  A stale result may leave an orphan file, but cannot publish it. The migration adds
  `attachment_downloads.leaseId`.

## 4. What is only tested against Swift

`AttachmentConformanceTests` (SignalCore):
- **`randomDecrypts`** (3,000 cases):
  - production's `encrypt`, then the blob is changed: a byte changed, truncated, extended, or the
    body changed and re-tagged by a key holder;
  - other keys or a short key; sizes equal, smaller, larger, or far larger than the plaintext;
  - every integrity source, right or wrong;
  - incremental MACs valid, changed, absent, or with an impossible chunk size.

  The descriptors are computed independently: tags and digests with CryptoKit, AES and PKCS#7
  with CommonCrypto and a strict padding check. Production's result (length or error) is compared
  with the model's, and the plaintext with the original's prefix.
- **`randomDownloads`** (300 cases, the real `AttachmentDownloadManager.run` over the mock
  server's CDN):
  - responses that are the genuine blob, another upload's blob, forged bytes, an oversized blob
    or a truncated one;
  - pointers with a right or wrong digest, a plaintext hash or neither, sizes against a random
    incoming limit.

  Checked: what is published and its plaintext, and that a published file changed on disk is
  refused on reading.
- **`boundedTransfer`**: reading stops at the limit. **`pinningRefusesOtherRoots`**: a client
  pinned to Signal's root refuses the mock server, and the correctly pinned one reaches it.

`AttachmentPublicationTests` gates the real download after validation, cancels it before the
writer, then verifies that an uncancelled retry succeeds. Writer-boundary cases also cover pointer
replacement with the same digest, cancellation, erasure, expiry, deletion and requeueing. The
separate `Publication` model abstracts full snapshot equality as a version and assumes the held
bytes already passed the authentication model; composition with Swift is tested, not proved.

Mutants (step 6), each of which must fail step 5:
- decryption: no MAC check; no digest check; empty digest accepted; no plaintext-hash check; no
  incremental-MAC check; huge chunk sizes trapping; no shape check; padding not trimmed;
- the download: the incoming limit ignored; the response unbounded; pointers without digest or
  hash accepted; unverified blobs stored as received;
- the transfer: not stopped at the limit; streamed responses skipping pinning.

## 5. Assumptions and limitations

- The contracts above are hypotheses of the model (`describe`), not proved. The rig's
  descriptors are what the bytes actually do, computed with other implementations.
- A plaintext hash covers only the plaintext trimmed to the pointer's size. Bytes past it are
  covered by the MAC, which only the key's holder (the sender) can produce, as upstream.
- The pointer's size is the sender's claim: a larger one yields the padding (upstream does the
  same), a smaller one a prefix. Both are bounded by the limit.
- Thumbnails, screenshots and image information come from the media decoder (a sandboxed
  process) and are validated there (the media and containment work). Here they are only fed the
  verified plaintext.
- Other remote bytes have their own paths: stickers (`decryptV1`: MAC under the pack key),
  contact sync (digest required), avatars (their own ciphers). They share the response bound, not
  this model.
- A cancelled or failed download can leave an unpublished local file behind
  (`deleteOrphans` removes it later); nothing refers to it.

## 6. Files

`Attachments/Publication.lean`, `Attachments/Nonvacuity.lean`, `Attachments/Model.lean`, `Attachments/Props.lean`, `Attachments/Proofs.lean`,
`Attachments/Trace.lean`, `Main.lean` (the `oracle`: `decrypt`, `download`, `explore`),
`Audit.lean`, `audit-expected.txt`, `explore-expected.txt`.
